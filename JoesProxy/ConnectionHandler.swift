import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import os

final class ProxyConnectionHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    typealias ThrottleConfigurationProvider = () -> NetworkThrottleConfiguration

    private enum ConnectionState {
        case awaitingRequest
        case processingRequest
        case tunneling(peer: Channel)
        case interceptingTLS(connectHost: String, connectPort: Int)
        case closed
    }

    private let requestParser: HTTPRequestParser
    private let responseParser: HTTPResponseParser
    private let upstreamConnector: HTTPUpstreamConnector
    private let httpsProxyMode: HTTPSProxyMode
    private let configuration: (any AppConfiguration)?
    private let certificateAuthority: (any CertificateAuthorityProviding)?
    private let sessionRecorder: ProxySessionRecorder?
    private let responseOverrideStore: ResponseOverrideStore?
    private let bookmarkResponseInterceptStore: BookmarkResponseInterceptStore?
    private let fixtureOriginRegistry: HLSFixtureOriginRegistry?
    private let hlsSubstitutionRouteStore: HLSSubstitutionRouteStore?
    private let openAPIMockRouteStore: OpenAPIMockRouteStore?
    private let throttleConfigurationProvider: ThrottleConfigurationProvider
    private let eventLoopGroup: EventLoopGroup
    private let transportDiagnostics: CaptureTransportDiagnostics?
    private var captureBodyLimiter: CaptureBodyLimiter {
        CaptureBodyLimiter(limit: configuration?.liveCaptureBodySizeLimit ?? RecordingConstants.liveCaptureBodySizeLimit)
    }
    private let logger: Logger
    private let downstreamThrottleWriter: NetworkThrottleWriter
    private let upstreamThrottleWriter: NetworkThrottleWriter
    private var tlsInterceptionRules: TLSInterceptionRules {
        TLSInterceptionRules(
            bypassDomains: configuration?.httpsBypassDomains ?? [],
            interceptDomains: configuration?.httpsInterceptDomains ?? []
        )
    }

    private var state: ConnectionState = .awaitingRequest
    private var buffer = Data()
    private var requestReadsPaused = false
    private let uploadSpoolService: UploadSpoolService?
    private let uploadForwardingLifecycle: UploadForwardingLifecycle?
    private var uploadWork: Task<Void, Never>?
    private var pendingUpload: PendingUpload?
    private var activeUploadSpool: UploadBodySpool?

    private final class PendingUpload {
        let head: HTTPProxyRequest
        let size: Int
        let prefix: BoundedCaptureAccumulator
        var remaining: Int
        var spool: UploadBodySpool?
        init(head: HTTPProxyRequest, size: Int, captureLimit: Int) {
            self.head = head
            self.size = size
            self.remaining = size
            self.prefix = BoundedCaptureAccumulator(limit: captureLimit)
        }
    }
    private let traceID = String(UUID().uuidString.prefix(8))
    /// The proxy client's peer IP, captured at channelActive and attached to recorded requests
    /// so traffic can be classified by source (Mac / Simulator / device).
    private var clientAddress: String?
    /// Cached expected total byte length for the frame currently accumulating in `buffer`.
    /// Set once the header delimiter is found so subsequent chunks skip a full-buffer rescan.
    /// Reset to nil whenever a frame is consumed or an error occurs.
    private var pendingFrameExpectedLength: Int?
    /// Fingerprint of the root CA that signed the most recently issued intercepted leaf on this connection.
    private var activeLocalCAFingerprint: String?
    /// Active streaming forwarder for upstream backpressure coordination.
    private weak var activeStreamingForwarder: StreamingUpstreamForwarder?
    private var activeUpstreamCancellation: (@Sendable () -> Void)?
    private var activeUpstreamRequestID: UUID?
    private var activeMapRemoteSessionID: UUID?
    nonisolated(unsafe) static var beforeLoopbackRegistrationPauseForTesting: (@Sendable () async -> Void)?

    init(
        requestParser: HTTPRequestParser,
        responseParser: HTTPResponseParser,
        upstreamConnector: HTTPUpstreamConnector,
        httpsProxyMode: HTTPSProxyMode,
        configuration: (any AppConfiguration)?,
        certificateAuthority: (any CertificateAuthorityProviding)?,
        sessionRecorder: ProxySessionRecorder?,
        responseOverrideStore: ResponseOverrideStore?,
        bookmarkResponseInterceptStore: BookmarkResponseInterceptStore? = nil,
        fixtureOriginRegistry: HLSFixtureOriginRegistry? = nil,
        hlsSubstitutionRouteStore: HLSSubstitutionRouteStore? = nil,
        openAPIMockRouteStore: OpenAPIMockRouteStore? = nil,
        throttleConfigurationProvider: @escaping ThrottleConfigurationProvider = { .defaults },
        eventLoopGroup: EventLoopGroup,
        transportDiagnostics: CaptureTransportDiagnostics? = nil,
        uploadSpoolService: UploadSpoolService? = nil,
        uploadForwardingLifecycle: UploadForwardingLifecycle? = nil,
        logger: Logger = Logger(subsystem: "com.joesproxyapp", category: "ProxyConnectionHandler")
    ) {
        self.requestParser = requestParser
        self.responseParser = responseParser
        self.upstreamConnector = upstreamConnector
        self.httpsProxyMode = httpsProxyMode
        self.configuration = configuration
        self.certificateAuthority = certificateAuthority
        self.sessionRecorder = sessionRecorder
        self.responseOverrideStore = responseOverrideStore
        self.bookmarkResponseInterceptStore = bookmarkResponseInterceptStore
        self.fixtureOriginRegistry = fixtureOriginRegistry
        self.hlsSubstitutionRouteStore = hlsSubstitutionRouteStore
        self.openAPIMockRouteStore = openAPIMockRouteStore
        self.throttleConfigurationProvider = throttleConfigurationProvider
        self.eventLoopGroup = eventLoopGroup
        self.transportDiagnostics = transportDiagnostics
        self.uploadSpoolService = uploadSpoolService
        self.uploadForwardingLifecycle = uploadForwardingLifecycle
        self.logger = logger
        self.downstreamThrottleWriter = NetworkThrottleWriter(
            direction: .downstream,
            configurationProvider: throttleConfigurationProvider
        )
        self.upstreamThrottleWriter = NetworkThrottleWriter(
            direction: .upstream,
            configurationProvider: throttleConfigurationProvider
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch state {
        case .tunneling(let peer):
            forwardToPeer(peer, payload: data, context: context)
        case .closed:
            break
        default:
            let byteBuffer = unwrapInboundIn(data)
            byteBuffer.withUnsafeReadableBytes { ptr in
                buffer.append(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), count: ptr.count)
            }
            logHTTPS("Buffered \(self.buffer.count) bytes while in state \(String(describing: self.state))")
            processBufferedDataIfPossible(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        clientAddress = context.channel.remoteAddress?.ipAddress
        transportDiagnostics?.recordChannelOpened()
        logger.info(
            "Proxy channel active [\(self.traceID, privacy: .public)] remote=\(self.channelAddressDescription(context.channel.remoteAddress), privacy: .public) local=\(self.channelAddressDescription(context.channel.localAddress), privacy: .public)"
        )
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        transportDiagnostics?.recordChannelClosed()
        logger.info(
            "Proxy channel inactive [\(self.traceID, privacy: .public)] remote=\(self.channelAddressDescription(context.channel.remoteAddress), privacy: .public) local=\(self.channelAddressDescription(context.channel.localAddress), privacy: .public)"
        )
        if case .tunneling(let peer) = state {
            peer.close(promise: nil)
        }
        state = .closed
        uploadWork?.cancel()
        releaseUploadSpool()
        pendingUpload = nil
        buffer = Data()
        pendingFrameExpectedLength = nil
        activeUpstreamCancellation?()
        activeUpstreamCancellation = nil
        activeStreamingForwarder = nil
        activeUpstreamRequestID = nil
        ActiveMapRemoteSessionRegistry.shared.unregister(activeMapRemoteSessionID)
        activeMapRemoteSessionID = nil
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            activeStreamingForwarder?.notifyDownstreamWritable()
            if case .tunneling(let peer) = state {
                peer.pipeline.handler(type: TunnelPeerRelayHandler.self).whenSuccess { handler in
                    handler.resumeReads(from: peer)
                }
            }
        }
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        switch ProxyChannelErrorClassifier.classify(error) {
        case .expectedDisconnect:
            transportDiagnostics?.recordExpectedClientDisconnect()
            logger.info(
                "Proxy channel expected disconnect [\(self.traceID, privacy: .public)] remote=\(self.channelAddressDescription(context.channel.remoteAddress), privacy: .public) local=\(self.channelAddressDescription(context.channel.localAddress), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        case .unexpectedFailure:
            transportDiagnostics?.recordUnexpectedChannelError()
            logger.error(
                "Proxy channel error [\(self.traceID, privacy: .public)] remote=\(self.channelAddressDescription(context.channel.remoteAddress), privacy: .public) local=\(self.channelAddressDescription(context.channel.localAddress), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        logHTTPS("Channel error in state \(String(describing: self.state)): \(error.localizedDescription)")
        if case .tunneling(let peer) = state {
            peer.close(promise: nil)
        }
        state = .closed
        pendingFrameExpectedLength = nil
        context.close(promise: nil)
    }

    private func processBufferedDataIfPossible(context: ChannelHandlerContext) {
        defer { updateRequestReadAdmission(context: context) }
        if handleUploadSpooling(context: context) { return }
        switch state {
        case .awaitingRequest:
            // Fast path: if we already know the expected frame length, skip rescanning.
            if let expected = pendingFrameExpectedLength, buffer.count < expected {
                logHTTPS("Waiting for complete initial request. Current buffer bytes: \(buffer.count) / expected \(expected)")
                return
            }

            guard requestParser.isCompleteRequest(buffer) else {
                // Cache the expected length if the header delimiter has been found (analysis found it).
                let analysis = requestParser.isCompleteRequestAnalysis(buffer)
                if let expected = analysis.expectedLength {
                    pendingFrameExpectedLength = expected
                }
                logHTTPS("Waiting for complete initial request. Current buffer bytes: \(buffer.count)")
                return
            }

            do {
                let parsed = try requestParser.parseRequestFrame(buffer)
                logHTTPS("Parsed initial request \(parsed.request.method) \(requestTargetDescription(parsed.request))")
                buffer.removeFirst(parsed.consumedLength)
                pendingFrameExpectedLength = nil
                state = .processingRequest
                handleInitialRequest(parsed.request, context: context)
            } catch {
                logHTTPS("Failed to parse initial request: \(error.localizedDescription)")
                pendingFrameExpectedLength = nil
                sendFailureResponse(for: error, context: context)
            }

        case .interceptingTLS(let connectHost, let connectPort):
            // Fast path: if we already know the expected frame length, skip rescanning.
            if let expected = pendingFrameExpectedLength, buffer.count < expected {
                logHTTPS("Waiting for complete decrypted HTTPS request for \(connectHost):\(connectPort). Current buffer bytes: \(buffer.count) / expected \(expected)")
                return
            }

            let completionAnalysis = requestParser.isCompleteRequestAnalysis(buffer)
            guard completionAnalysis.isComplete else {
                if let expected = completionAnalysis.expectedLength {
                    pendingFrameExpectedLength = expected
                }
                logHTTPS(
                    "Waiting for complete decrypted HTTPS request for \(connectHost):\(connectPort). Current buffer bytes: \(buffer.count). Reason: \(completionAnalysis.reason). Content-Length: \(completionAnalysis.contentLength.map(String.init) ?? "nil"). Expected length: \(completionAnalysis.expectedLength.map(String.init) ?? "nil"). Preview: \(bufferPreview(buffer, byteCount: 128))"
                )
                return
            }

            do {
                let parsed = try requestParser.parseRequestFrame(buffer)
                logHTTPS("Parsed decrypted HTTPS request \(parsed.request.method) \(connectHost):\(connectPort)\(parsed.request.path)")
                buffer.removeFirst(parsed.consumedLength)
                pendingFrameExpectedLength = nil
                state = .processingRequest
                handleInterceptedRequest(
                    parsed.request,
                    connectHost: connectHost,
                    connectPort: connectPort,
                    context: context
                )
            } catch {
                logHTTPS("Failed to parse decrypted HTTPS request for \(connectHost):\(connectPort): \(error.localizedDescription)")
                pendingFrameExpectedLength = nil
                sendFailureResponse(for: error, context: context)
            }

        case .processingRequest, .tunneling, .closed:
            break
        }
    }

    private func updateRequestReadAdmission(context: ChannelHandlerContext) {
        let processing: Bool
        if case .processingRequest = state { processing = true } else { processing = uploadWork != nil }
        if processing, !requestReadsPaused {
            requestReadsPaused = true
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        } else if !processing, requestReadsPaused {
            requestReadsPaused = false
            guard context.channel.isActive else { return }
            context.channel.setOption(ChannelOptions.autoRead, value: true).whenSuccess {
                context.channel.read()
            }
        }
    }

    /// Event-loop confined admission and geometry; at most one disk task/chunk per connection.
    private func handleUploadSpooling(context: ChannelHandlerContext) -> Bool {
        guard let service = uploadSpoolService else { return false }
        switch state {
        case .awaitingRequest, .interceptingTLS: break
        default: return false
        }
        if uploadWork != nil { return true }
        let loop = context.eventLoop
        let owner = NIOLoopBound(self, eventLoop: loop)
        let boundContext = context.loopBound
        let lifecycle = uploadForwardingLifecycle
        if pendingUpload == nil {
            guard let head = try? requestParser.parseRequestHead(buffer), head.request.kind == .standard,
                  !head.request.headers.contains(where: { $0.name.lowercased() == "transfer-encoding" }),
                  let size = head.request.headers.first(where: { $0.name.lowercased() == "content-length" })
                    .flatMap({ Int($0.value.trimmingCharacters(in: .whitespaces)) }),
                  size > UploadSpoolService.memoryThreshold else { return false }
            pendingUpload = PendingUpload(head: head.request, size: size, captureLimit: captureBodyLimiter.limit)
            guard let lease = service.budget.reserve() else {
                failUpload(UploadBodySpoolError.capacityUnavailable, context: context)
                return true
            }
            let workerID = lifecycle?.begin(on: context.channel)
            if lifecycle != nil && workerID == nil {
                failUpload(ChannelError.ioOnClosedChannel, context: context)
                return true
            }
            buffer.removeFirst(head.consumedLength)
            uploadWork = Task {
                do {
                    let spool = try await service.create(lease: lease)
                    if Task.isCancelled {
                        await service.release(spool)
                        if let workerID { lifecycle?.finish(workerID) }
                        return
                    }
                    loop.execute {
                        defer { if let workerID { lifecycle?.finish(workerID) } }
                        let handler = owner.value
                        handler.uploadWork = nil
                        guard let upload = handler.pendingUpload else { return }
                        upload.spool = spool
                        handler.activeUploadSpool = spool
                        handler.processBufferedDataIfPossible(context: boundContext.value)
                    }
                } catch {
                    loop.execute {
                        defer { if let workerID { lifecycle?.finish(workerID) } }
                        owner.value.failUpload(error, context: boundContext.value)
                    }
                }
            }
            return true
        }
        guard let upload = pendingUpload, let spool = upload.spool else { return true }
        if upload.remaining > 0, buffer.isEmpty { return true }
        let workerID = lifecycle?.begin(on: context.channel)
        if lifecycle != nil && workerID == nil {
            failUpload(ChannelError.ioOnClosedChannel, context: context)
            return true
        }
        let count = min(upload.remaining, min(buffer.count, UploadBodySpool.maximumChunkBytes))
        let chunk = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        upload.prefix.append(data: chunk)
        upload.remaining -= count
        let complete = upload.remaining == 0
        uploadWork = Task {
            do {
                if !chunk.isEmpty { try await spool.append(chunk) }
                if complete { try await spool.seal() }
                try Task.checkCancellation()
                loop.execute {
                    defer { if let workerID { lifecycle?.finish(workerID) } }
                    let handler = owner.value
                    handler.uploadWork = nil
                    if complete { handler.finishUpload(context: boundContext.value) }
                    else { handler.processBufferedDataIfPossible(context: boundContext.value) }
                }
            } catch {
                loop.execute {
                    defer { if let workerID { lifecycle?.finish(workerID) } }
                    owner.value.failUpload(error, context: boundContext.value)
                }
            }
        }
        return true
    }

    private func finishUpload(context: ChannelHandlerContext) {
        guard let upload = pendingUpload else { return }
        let prefix = upload.prefix.finalize()
        let head = upload.head
        let request = HTTPProxyRequest(kind: head.kind, method: head.method, version: head.version,
            host: head.host, port: head.port, path: head.path, headers: head.headers,
            body: prefix.data ?? Data(), bodySpool: upload.spool, originalBodySize: upload.size)
        pendingUpload = nil
        pendingFrameExpectedLength = nil
        let previous = state
        state = .processingRequest
        updateRequestReadAdmission(context: context)
        if case .interceptingTLS(let host, let port) = previous {
            handleInterceptedRequest(request, connectHost: host, connectPort: port, context: context)
        } else { handleInitialRequest(request, context: context) }
    }

    private func failUpload(_ error: Error, context: ChannelHandlerContext) {
        if let upload = pendingUpload, let recorder = sessionRecorder {
            let body = upload.prefix.finalize()
            let scheme: SessionScheme
            let host: String
            let port: Int
            if case .interceptingTLS(let connectHost, let connectPort) = state {
                scheme = .https; host = connectHost; port = connectPort
            } else { scheme = .http; host = upload.head.host; port = upload.head.port }
            let request = CapturedRequest(method: upload.head.method, scheme: scheme,
                inspectionKind: scheme == .https ? .interceptedTLS : .plain,
                host: host, port: port, path: upload.head.path, headers: upload.head.headers,
                bodyData: body.data, bodySize: upload.size,
                bodyTruncated: upload.size > (body.data?.count ?? 0), clientAddress: clientAddress)
            if let admission = recorder.admitSession(request: request, responseBodyLimit: 0) {
                Task { if let id = await admission.value { await recorder.failSession(id: id, error: error) } }
            }
        }
        uploadWork = nil
        pendingUpload = nil
        buffer = Data()
        releaseUploadSpool()
        guard context.channel.isActive else { return }
        sendFailureResponse(for: error, context: context)
    }

    private func releaseUploadSpool() {
        guard let spool = activeUploadSpool else { return }
        activeUploadSpool = nil
        let logger = logger
        let service = uploadSpoolService
        Task {
            if let service {
                await service.release(spool)
                if service.needsCleanup { logger.error("Upload spool cleanup failed; startup recovery required") }
                return
            }
            do { try await spool.close() }
            catch { logger.error("Upload spool cleanup failed; startup recovery required: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func handleInitialRequest(_ request: HTTPProxyRequest, context: ChannelHandlerContext) {
        if let response = DeviceProxyAutoConfiguration.response(
            for: request, localHost: context.channel.localAddress?.ipAddress,
            localPort: context.channel.localAddress?.port
        ) {
            write(response, keepConnectionOpen: false, nextState: .closed, context: context)
            return
        }
        logHTTPS("Handling initial request kind=\(String(describing: request.kind)) method=\(request.method) target=\(requestTargetDescription(request))")
        switch request.kind {
        case .standard:
            executeProxyRequest(
                request,
                sessionScheme: .http,
                upstreamScheme: .http,
                keepConnectionOpen: false,
                nextState: .closed,
                context: context
            )
        case .connect:
            switch httpsProxyMode {
            case .passThrough:
                establishPassThroughTunnel(for: request, context: context)
            case .intercepting:
                let decision = TLSInterceptionPolicy.decision(for: request.host, rules: tlsInterceptionRules)
                switch decision {
                case .bypass(let reason):
                    logHTTPS("Bypassing TLS interception for \(request.host):\(request.port). Reason: \(reason)")
                    establishPassThroughTunnel(for: request, reason: reason, context: context)
                case .intercept(let reason):
                    logHTTPS("Intercepting TLS for \(request.host):\(request.port). Reason: \(reason)")
                    beginTLSInterception(for: request, context: context)
                }
            }
        }
    }

    private func requestTargetDescription(_ request: HTTPProxyRequest) -> String {
        switch request.kind {
        case .standard:
            return "\(request.host):\(request.port)\(request.path)"
        case .connect:
            return "\(request.host):\(request.port)"
        }
    }

    private func handleInterceptedRequest(
        _ request: HTTPProxyRequest,
        connectHost: String,
        connectPort: Int,
        context: ChannelHandlerContext
    ) {
        logHTTPS("Handling intercepted HTTPS request \(request.method) \(connectHost):\(connectPort)\(request.path)")
        let upstreamRequest = HTTPProxyRequest(
            kind: .standard,
            method: request.method,
            version: request.version,
            host: connectHost,
            port: connectPort,
            path: request.path,
            headers: request.headers,
            body: request.body,
            bodySpool: request.bodySpool,
            originalBodySize: request.originalBodySize
        )

        let capturedBody = request.capturedBody(using: captureBodyLimiter)
        let recordedRequest = CapturedRequest(
            method: request.method,
            scheme: .https,
            inspectionKind: .interceptedTLS,
            inspectionReason: "HTTPS inspected",
            host: connectHost,
            port: connectPort,
            path: request.path,
            headers: request.headers,
            bodyData: capturedBody.data,
            bodySize: capturedBody.size,
            bodyTruncated: capturedBody.truncated,
            clientAddress: clientAddress,
            localCACertificateSHA256Fingerprint: activeLocalCAFingerprint,
            remoteTrustState: activeLocalCAFingerprint == nil
                ? .remoteTrustInventoryUnavailable
                : .inspectedUnderCurrentCA
        )

        executeProxyRequest(
            upstreamRequest,
            recordedRequest: recordedRequest,
            sessionScheme: .https,
            upstreamScheme: .https,
            keepConnectionOpen: true,
            nextState: .interceptingTLS(connectHost: connectHost, connectPort: connectPort),
            context: context
        )
    }

    private func executeProxyRequest(
        _ request: HTTPProxyRequest,
        recordedRequest: CapturedRequest? = nil,
        sessionScheme: SessionScheme,
        upstreamScheme: SessionScheme,
        keepConnectionOpen: Bool,
        nextState: ConnectionState,
        context: ChannelHandlerContext
    ) {
        logHTTPS("Executing \(sessionScheme.rawValue.uppercased()) proxy request \(request.method) \(request.host):\(request.port)\(request.path)")
        let eventLoop = context.eventLoop
        let loopBoundContext = context.loopBound
        let loopBoundSelf = NIOLoopBound(self, eventLoop: eventLoop)
        let requestBody = request.capturedBody(using: captureBodyLimiter)
        let sessionRequest = recordedRequest ?? CapturedRequest(
            method: request.method,
            scheme: sessionScheme,
            inspectionKind: sessionScheme == .https ? .interceptedTLS : .plain,
            inspectionReason: sessionScheme == .https ? "HTTPS inspected" : nil,
            host: request.host,
            port: request.port,
            path: request.path,
            headers: request.headers,
            bodyData: requestBody.data,
            bodySize: requestBody.size,
            bodyTruncated: requestBody.truncated,
            clientAddress: clientAddress
        )

        transportDiagnostics?.recordProgress(.routingStarted)
        let admission = self.sessionRecorder?.admitPlaybackFirst(request: sessionRequest,
            responseBodyLimit: configuration?.liveCaptureBodySizeLimit ?? RecordingConstants.liveCaptureBodySizeLimit)
        let captureBodyLimit = admission?.responseBodyLimit ?? 0
        let admittedTask = admission?.session
        let sessionRecorder = admittedTask == nil ? nil : self.sessionRecorder
        let sessionIDTask = admittedTask ?? ProxySessionRecorder.uncapturedSession
        let observationTickets = DiagnosticExperimentWindowIndex.shared.admit(sessionRequest)
        if !observationTickets.isEmpty {
            Task { DiagnosticExperimentWindowIndex.shared.attach(observationTickets, sessionID: await sessionIDTask.value) }
        }

        let bookmarkResponseInterceptStore = self.bookmarkResponseInterceptStore
        let fixtureOriginRegistry = self.fixtureOriginRegistry
        let hlsSubstitutionRouteStore = self.hlsSubstitutionRouteStore
        let openAPIMockRouteStore = self.openAPIMockRouteStore

        Task {
            do {
                // Reserved fixture hosts (`fixture-<uuid>.hls.joesproxy.invalid`, minted by
                // `HLSFixtureRunStore.reservedHost(for:)`) are proxy-synthesized ownership — not
                // real captured origins. Checked unconditionally, ahead of Map Local /
                // `bookmarkResponseInterceptStore`, so a live fixture run always resolves locally
                // even when no override store is configured (test/self-validation lanes) and even
                // if MCP authored a bookmark whose matcher host coincidentally matches a reserved
                // suffix. Bookmark/Map Local rules targeting these hosts remain inert while a
                // fixture run owns the host; that is intentional, not an oversight.
                if let fixtureOriginRegistry,
                   sessionRequest.host.hasSuffix(HLSFixtureRunStore.reservedHostSuffix),
                   let fixtureEntry = await fixtureOriginRegistry.activeEntry(forHost: sessionRequest.host) {
                    // JoePlayer diagnostic POSTs ride the same reserved fixture host so capture
                    // already owns the request; return 204 without consulting the fixture file tree.
                    if fixtureEntry.permitsDirectAccess, sessionRequest.method.uppercased() == "POST",
                       DiagnosticIngestionRoute.matches(sessionRequest.path) {
                        let resolvedOverride = ResolvedResponseOverride(
                            ruleID: fixtureEntry.runID,
                            statusCode: 204,
                            headers: [HTTPHeaderField(name: "Content-Length", value: "0")],
                            bodyData: Data(),
                            sourceKind: .inlineText,
                            sourceDescription: "JoePlayer diagnostic ingestion \(fixtureEntry.runID.uuidString.prefix(8))"
                        )
                        await self.serveResolvedOverride(
                            resolvedOverride,
                            captureBodyLimit: captureBodyLimit,
                            requestHost: request.host,
                            responseSource: .localOverride,
                            logMessage: "Accepted JoePlayer diagnostic POST for \(request.host)\(request.path). Run: \(fixtureEntry.runID.uuidString)",
                            keepConnectionOpen: keepConnectionOpen,
                            nextState: nextState,
                            sessionRecorder: sessionRecorder,
                            sessionIDTask: sessionIDTask,
                            responseOverrideStore: responseOverrideStore,
                            bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                            eventLoop: eventLoop,
                            loopBoundSelf: loopBoundSelf,
                            loopBoundContext: loopBoundContext
                        )
                        return
                    }

                    let rangeHeader = request.headers.first {
                        $0.name.caseInsensitiveCompare("Range") == .orderedSame
                    }?.value
                    let fixtureResponse = fixtureEntry.permitsDirectAccess ? fixtureEntry.server.response(
                        forPath: sessionRequest.path,
                        method: sessionRequest.method,
                        rangeHeader: rangeHeader
                    ) : HLSFixtureResponse(status: 403, headers: ["Content-Length": "0"], body: Data())
                    let resolvedOverride = ResolvedResponseOverride(
                        ruleID: fixtureEntry.runID,
                        statusCode: fixtureResponse.status,
                        headers: fixtureResponse.headers.map { HTTPHeaderField(name: $0.key, value: $0.value) },
                        bodyData: fixtureResponse.body,
                        sourceKind: .inlineText,
                        sourceDescription: "HLS fixture run \(fixtureEntry.runID.uuidString.prefix(8))"
                    )
                    await self.serveResolvedOverride(
                        resolvedOverride,
                        captureBodyLimit: captureBodyLimit,
                        requestHost: request.host,
                        responseSource: .localOverride,
                        logMessage: "Served HLS fixture response for \(request.method) \(request.host):\(request.port)\(request.path). Run: \(fixtureEntry.runID.uuidString)",
                        keepConnectionOpen: keepConnectionOpen,
                        nextState: nextState,
                        sessionRecorder: sessionRecorder,
                        sessionIDTask: sessionIDTask,
                        responseOverrideStore: responseOverrideStore,
                        bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                        eventLoop: eventLoop,
                        loopBoundSelf: loopBoundSelf,
                        loopBoundContext: loopBoundContext
                    )
                    return
                }

                // Mock Media Server Interception (images.joesproxy.invalid, epg.joesproxy.invalid, media.joesproxy.invalid)
                if MockMediaAssetServer.isMockMediaHost(sessionRequest.host),
                   let assetURL = URL(string: "https://\(sessionRequest.host)\(sessionRequest.path)"),
                   let asset = MockMediaAssetServer.shared.response(for: assetURL) {
                    let assetOverride = ResolvedResponseOverride(
                        ruleID: UUID(),
                        statusCode: 200,
                        headers: [
                            HTTPHeaderField(name: "Content-Type", value: asset.contentType),
                            HTTPHeaderField(name: "Content-Length", value: String(asset.data.count)),
                            HTTPHeaderField(name: "Cache-Control", value: "public, max-age=86400")
                        ],
                        bodyData: asset.data,
                        sourceKind: .localFile,
                        sourceDescription: "Synthetic Mock Media Server"
                    )
                    await self.serveResolvedOverride(
                        assetOverride,
                        captureBodyLimit: captureBodyLimit,
                        requestHost: request.host,
                        responseSource: .localOverride,
                        logMessage: "Served synthetic mock media for \(request.host)\(request.path)",
                        keepConnectionOpen: keepConnectionOpen,
                        nextState: nextState,
                        sessionRecorder: sessionRecorder,
                        sessionIDTask: sessionIDTask,
                        responseOverrideStore: responseOverrideStore,
                        bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                        eventLoop: eventLoop,
                        loopBoundSelf: loopBoundSelf,
                        loopBoundContext: loopBoundContext
                    )
                    return
                }

                // Synthetic Asset Origin Interception (assets.joesproxy.invalid, *.synthetic.joesproxy.invalid)
                if SyntheticAssetOriginServer.isSyntheticHost(sessionRequest.host),
                   let assetResponse = SyntheticAssetOriginServer.shared.response(for: sessionRequest) {
                    let assetOverride = ResolvedResponseOverride(
                        ruleID: UUID(),
                        statusCode: assetResponse.statusCode,
                        headers: assetResponse.headers,
                        bodyData: assetResponse.bodyData,
                        sourceKind: .localFile,
                        sourceDescription: "Synthetic Bound Asset (\(sessionRequest.path))"
                    )
                    await self.serveResolvedOverride(
                        assetOverride,
                        captureBodyLimit: captureBodyLimit,
                        requestHost: request.host,
                        responseSource: .localOverride,
                        logMessage: "Served synthetic bound asset for \(request.host)\(request.path)",
                        keepConnectionOpen: keepConnectionOpen,
                        nextState: nextState,
                        sessionRecorder: sessionRecorder,
                        sessionIDTask: sessionIDTask,
                        responseOverrideStore: responseOverrideStore,
                        bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                        eventLoop: eventLoop,
                        loopBoundSelf: loopBoundSelf,
                        loopBoundContext: loopBoundContext
                    )
                    return
                }

                // First-class HLS substitutions are dual routes: an entry matcher on the real
                // playlist plus a private mount on the same origin for fixture children. Consult
                // them ahead of ordinary overrides so host-wide `.m3u8` matching cannot consume
                // its own rewritten child playlists as new entries.
                if let hlsSubstitutionRouteStore,
                   let substitution = await hlsSubstitutionRouteStore.decision(for: sessionRequest),
                   let fixtureOriginRegistry,
                   let fixtureEntry = await fixtureOriginRegistry.activeEntry(forRunID: substitution.fixtureRunID) {
                    let rangeHeader = request.headers.first {
                        $0.name.caseInsensitiveCompare("Range") == .orderedSame
                    }?.value
                    var fixtureResponse = fixtureEntry.server.response(
                        forPath: "/\(substitution.fixturePath)",
                        method: sessionRequest.method,
                        rangeHeader: rangeHeader
                    )
                    if let track = substitution.missingTextTrackID,
                       HLSRequestPolicy.failsTextRequest(substitution.fixturePath, trackID: track) {
                        fixtureResponse = HLSFixtureResponse(status: 404,
                            headers: ["Content-Length": "0", "Cache-Control": "no-store"], body: Data(),
                            textTrack: fixtureResponse.textTrack)
                    }
                    if case .entryPlaylist = substitution.kind {
                        fixtureResponse = HLSSubstitutionManifestRouter.rewriteMaster(
                            fixtureResponse,
                            mountPath: substitution.mountPath,
                            method: sessionRequest.method,
                            cacheControlHeader: substitution.playbackConfiguration.cacheControlHeader
                        )
                    }
                    let resolvedOverride = ResolvedResponseOverride(
                        ruleID: substitution.experimentID,
                        statusCode: fixtureResponse.status,
                        headers: fixtureResponse.headers.map { HTTPHeaderField(name: $0.key, value: $0.value) },
                        bodyData: fixtureResponse.body,
                        sourceKind: .fixtureRun,
                        sourceDescription: "HLS test-stream substitution \(substitution.experimentID.uuidString.prefix(8))",
                        mcpAttribution: substitution.mcpProvenance.flatMap {
                            MCPSessionAttributionService.attributionForActiveEffects(
                                effectKinds: [.mapLocal],
                                provenance: $0
                            )
                        }
                    )
                    await self.serveResolvedOverride(
                        resolvedOverride,
                        captureBodyLimit: captureBodyLimit,
                        requestHost: request.host,
                        responseSource: .localOverride,
                        logMessage: "Served HLS test-stream substitution for \(request.method) \(request.host):\(request.port)\(request.path). Experiment: \(substitution.experimentID.uuidString)",
                        keepConnectionOpen: keepConnectionOpen,
                        nextState: nextState,
                        sessionRecorder: sessionRecorder,
                        sessionIDTask: sessionIDTask,
                        responseOverrideStore: responseOverrideStore,
                        bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                        eventLoop: eventLoop,
                        loopBoundSelf: loopBoundSelf,
                        loopBoundContext: loopBoundContext,
                        observationID: substitution.observation.map { identity in
                            let path = substitution.fixturePath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
                            let parts = path.split(separator: "/")
                            let mediaIndex = parts.firstIndex(of: "__jp_media")
                            let prepared = mediaIndex.flatMap { parts.indices.contains($0 + 1) ? UUID(uuidString: String(parts[$0 + 1])) : nil }
                            let sequence = URLComponents(string: "http://fixture.invalid/" + substitution.fixturePath)?.queryItems?
                                .first { $0.name == "jp_hls_sequence" }?.value.flatMap(Int.init)
                            return EffectBundleActivationGate.shared.observe(identity: identity,
                                kind: path.hasSuffix(".m3u8") ? .hlsPlaylist : .hlsSegment,
                                outcome: "http_\(fixtureResponse.status)", preparedMediaID: prepared, segmentSequence: sequence,
                                segmentPath: path.hasSuffix(".m3u8") ? nil : path, textTrack: fixtureResponse.textTrack)
                        }
                    )
                    return
                }

                if let openAPIMockRouteStore,
                   let mockDecision = await openAPIMockRouteStore.decision(for: sessionRequest) {
                    let provenance = mockDecision.mcpProvenance ?? MCPProvenance(
                        clientID: OpenAPIMockPackCoordinator.localUserOwnerID,
                        operationID: mockDecision.packID.rawValue.uuidString,
                        capability: .overrideInspect,
                        createdAt: Date()
                    )
                    let resolvedOverride = ResolvedResponseOverride(
                        ruleID: mockDecision.packID.rawValue,
                        statusCode: mockDecision.status,
                        headers: mockDecision.headers.map { HTTPHeaderField(name: $0.key, value: $0.value) },
                        bodyData: mockDecision.body,
                        sourceKind: .inlineText,
                        sourceDescription: "OpenAPI mock pack \(mockDecision.packID.rawValue.uuidString.prefix(8))",
                        mcpAttribution: MCPSessionAttributionService.attributionForActiveEffects(
                            effectKinds: [.openAPIMockPack],
                            provenance: provenance,
                            openAPIMockPackID: mockDecision.packID.rawValue.uuidString,
                            openAPIMockOperation: mockDecision.routeID,
                            openAPIMockVariantID: mockDecision.variant.id
                        )
                    )
                    await self.serveResolvedOverride(
                        resolvedOverride,
                        captureBodyLimit: captureBodyLimit,
                        requestHost: request.host,
                        responseSource: .localOverride,
                        logMessage: "Served OpenAPI mock pack for \(request.method) \(request.host):\(request.port)\(request.path). Pack: \(mockDecision.packID.rawValue.uuidString)",
                        keepConnectionOpen: keepConnectionOpen,
                        nextState: nextState,
                        sessionRecorder: sessionRecorder,
                        sessionIDTask: sessionIDTask,
                        responseOverrideStore: responseOverrideStore,
                        bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                        eventLoop: eventLoop,
                        loopBoundSelf: loopBoundSelf,
                        loopBoundContext: loopBoundContext
                    )
                    return
                }

                guard let responseOverrideStore else {
                    eventLoop.execute {
                        loopBoundSelf.value.executeUpstreamRequest(
                            request,
                            captureBodyLimit: captureBodyLimit,
                            upstreamScheme: upstreamScheme,
                            keepConnectionOpen: keepConnectionOpen,
                            nextState: nextState,
                            context: loopBoundContext.value,
                            sessionRecorder: sessionRecorder,
                            sessionIDTask: sessionIDTask
                        )
                    }
                    return
                }

                let currentLoopbackPolicy = self.configuration?.loopbackDestinationPolicy ?? .disabled
                let initialDecision = try await responseOverrideStore.ruleDecision(
                    for: sessionRequest,
                    loopbackPolicy: currentLoopbackPolicy,
                    reservedRegistry: .shared,
                    observationSessionIDTask: sessionIDTask
                )
                let decision: ProxyRuleDecision
                if case .noMatch = initialDecision,
                   let bookmarkResponseInterceptStore,
                   let bookmarkDecision = try await bookmarkResponseInterceptStore.ruleDecision(for: sessionRequest) {
                    decision = bookmarkDecision
                    if case .mapLocal(let resolved) = bookmarkDecision,
                       resolved.capturedResponseSource == .bookmarkResponseRewrite {
                        self.logHTTPS(
                            "Bookmark response intercept matched \(request.method) \(request.host):\(request.port)\(request.path). Source: \(resolved.sourceDescription)"
                        )
                    }
                } else {
                    decision = initialDecision
                }

                switch decision {
                case .noMatch:
                    eventLoop.execute {
                        loopBoundSelf.value.executeUpstreamRequest(
                            request,
                            captureBodyLimit: captureBodyLimit,
                            upstreamScheme: upstreamScheme,
                            keepConnectionOpen: keepConnectionOpen,
                            nextState: nextState,
                            context: loopBoundContext.value,
                            sessionRecorder: sessionRecorder,
                            sessionIDTask: sessionIDTask
                        )
                    }

                case .fixtureRedirect(let ruleID, let runID, let relativePath):
                    // Fail-open: a fixture-backed Map Local rule matched, but the referenced fixture
                    // run may have since stopped or hit its bounded max duration
                    // (`HLSFixtureRunStore.maxRunDuration`). Rather than serve an error or silently
                    // blackhole real traffic, treat this exactly like `.noMatch` and fall through to
                    // the genuine upstream (ADR-Streaming-Source-Redirect-To-Fixture.md).
                    guard let fixtureOriginRegistry,
                          let fixtureEntry = await fixtureOriginRegistry.activeEntry(forRunID: runID) else {
                        eventLoop.execute {
                            loopBoundSelf.value.executeUpstreamRequest(
                                request,
                                captureBodyLimit: captureBodyLimit,
                                upstreamScheme: upstreamScheme,
                                keepConnectionOpen: keepConnectionOpen,
                                nextState: nextState,
                                context: loopBoundContext.value,
                                sessionRecorder: sessionRecorder,
                                sessionIDTask: sessionIDTask
                            )
                        }
                        return
                    }
                    let fixtureRangeHeader = request.headers.first {
                        $0.name.caseInsensitiveCompare("Range") == .orderedSame
                    }?.value
                    let fixtureResponse = fixtureEntry.server.response(
                        forPath: "/\(relativePath)",
                        method: sessionRequest.method,
                        rangeHeader: fixtureRangeHeader
                    )
                    let fixtureResolvedOverride = ResolvedResponseOverride(
                        ruleID: ruleID,
                        statusCode: fixtureResponse.status,
                        headers: fixtureResponse.headers.map { HTTPHeaderField(name: $0.key, value: $0.value) },
                        bodyData: fixtureResponse.body,
                        sourceKind: .fixtureRun,
                        sourceDescription: "HLS fixture run \(runID.uuidString.prefix(8))"
                    )
                    await self.serveResolvedOverride(
                        fixtureResolvedOverride,
                        captureBodyLimit: captureBodyLimit,
                        requestHost: request.host,
                        responseSource: .localOverride,
                        logMessage: "Served fixture-redirected response for \(request.method) \(request.host):\(request.port)\(request.path). Run: \(runID.uuidString)",
                        keepConnectionOpen: keepConnectionOpen,
                        nextState: nextState,
                        sessionRecorder: sessionRecorder,
                        sessionIDTask: sessionIDTask,
                        responseOverrideStore: responseOverrideStore,
                        bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                        eventLoop: eventLoop,
                        loopBoundSelf: loopBoundSelf,
                        loopBoundContext: loopBoundContext
                    )

                case .localDirectoryRedirect(let ruleID, let relativePath):
                    // Fail-open: directory bookmark stale, folder deleted, or permission revoked →
                    // real upstream (ADR-Map-Local-Directory-Mocking.md).
                    guard let directoryRule = await responseOverrideStore.rule(id: ruleID),
                          case .directory(let directoryURL) = directoryRule.bodySource else {
                        eventLoop.execute {
                            loopBoundSelf.value.executeUpstreamRequest(
                                request,
                                captureBodyLimit: captureBodyLimit,
                                upstreamScheme: upstreamScheme,
                                keepConnectionOpen: keepConnectionOpen,
                                nextState: nextState,
                                context: loopBoundContext.value,
                                sessionRecorder: sessionRecorder,
                                sessionIDTask: sessionIDTask
                            )
                        }
                        return
                    }
                    let didAccess = directoryURL.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess {
                            directoryURL.stopAccessingSecurityScopedResource()
                        }
                    }
                    var isDirectory = false
                    if let values = try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]) {
                        isDirectory = values.isDirectory == true
                    }
                    guard isDirectory else {
                        eventLoop.execute {
                            loopBoundSelf.value.executeUpstreamRequest(
                                request,
                                captureBodyLimit: captureBodyLimit,
                                upstreamScheme: upstreamScheme,
                                keepConnectionOpen: keepConnectionOpen,
                                nextState: nextState,
                                context: loopBoundContext.value,
                                sessionRecorder: sessionRecorder,
                                sessionIDTask: sessionIDTask
                            )
                        }
                        return
                    }
                    let rangeHeader = request.headers.first {
                        $0.name.caseInsensitiveCompare("Range") == .orderedSame
                    }?.value
                    let server = LocalDirectoryServer(
                        rootDirectory: directoryURL,
                        notFoundRelativePath: directoryRule.notFoundRelativePath
                    )
                    if directoryRule.missingFilePolicy == .overlayFailOpen,
                       !server.hasLocalFile(forPath: "/\(relativePath)") {
                        // Overlay/fail-open: this specific relative path isn't in the local folder —
                        // reach the real upstream instead of 404ing an otherwise-legitimate sibling.
                        eventLoop.execute {
                            loopBoundSelf.value.executeUpstreamRequest(
                                request,
                                captureBodyLimit: captureBodyLimit,
                                upstreamScheme: upstreamScheme,
                                keepConnectionOpen: keepConnectionOpen,
                                nextState: nextState,
                                context: loopBoundContext.value,
                                sessionRecorder: sessionRecorder,
                                sessionIDTask: sessionIDTask
                            )
                        }
                        return
                    }
                    let directoryResponse = server.response(
                        forPath: "/\(relativePath)",
                        method: sessionRequest.method,
                        rangeHeader: rangeHeader
                    )
                    var headers = directoryResponse.headers.map { HTTPHeaderField(name: $0.key, value: $0.value) }
                    for extra in directoryRule.headers {
                        headers.removeAll { $0.name.caseInsensitiveCompare(extra.name) == .orderedSame }
                        headers.append(extra)
                    }
                    let directoryResolvedOverride = ResolvedResponseOverride(
                        ruleID: ruleID,
                        statusCode: directoryResponse.status,
                        headers: headers,
                        bodyData: directoryResponse.body,
                        sourceKind: .localDirectory,
                        sourceDescription: directoryRule.sourceDescription,
                        forceNoCache: directoryRule.forceNoCache
                    )
                    await self.serveResolvedOverride(
                        directoryResolvedOverride,
                        captureBodyLimit: captureBodyLimit,
                        requestHost: request.host,
                        responseSource: .localOverride,
                        logMessage: "Served local-directory response for \(request.method) \(request.host):\(request.port)\(request.path). Dir: \(directoryURL.lastPathComponent)",
                        keepConnectionOpen: keepConnectionOpen,
                        nextState: nextState,
                        sessionRecorder: sessionRecorder,
                        sessionIDTask: sessionIDTask,
                        responseOverrideStore: responseOverrideStore,
                        bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                        eventLoop: eventLoop,
                        loopBoundSelf: loopBoundSelf,
                        loopBoundContext: loopBoundContext
                    )

                case .mapLocal(let resolvedOverride):
                    let responseSource = resolvedOverride.capturedResponseSource ?? .localOverride
                    await self.serveResolvedOverride(
                        resolvedOverride,
                        captureBodyLimit: captureBodyLimit,
                        requestHost: request.host,
                        responseSource: responseSource,
                        logMessage: "Served local override for \(request.method) \(request.host):\(request.port)\(request.path). Source: \(resolvedOverride.sourceDescription)",
                        keepConnectionOpen: keepConnectionOpen,
                        nextState: nextState,
                        sessionRecorder: sessionRecorder,
                        sessionIDTask: sessionIDTask,
                        responseOverrideStore: responseOverrideStore,
                        bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                        eventLoop: eventLoop,
                        loopBoundSelf: loopBoundSelf,
                        loopBoundContext: loopBoundContext
                    )

                case .block(_, _, let sourceDescription, let dropConnection) where dropConnection:
                    if let sessionRecorder, let sessionID = await sessionIDTask.value {
                        await sessionRecorder.failSession(
                            id: sessionID,
                            message: "Connection dropped by JoesProxy (\(sourceDescription))"
                        )
                    }
                    eventLoop.execute {
                        let handler = loopBoundSelf.value
                        let context = loopBoundContext.value
                        handler.logHTTPS("Dropped connection for \(request.method) \(request.host):\(request.port)\(request.path). Source: \(sourceDescription)")
                        context.close(promise: nil)
                    }

                case .block(let ruleID, let statusCode, let sourceDescription, _):
                    let blockOverride = ResolvedResponseOverride(
                        ruleID: ruleID,
                        statusCode: statusCode,
                        headers: [HTTPHeaderField(name: "Content-Type", value: "text/plain; charset=utf-8")],
                        bodyData: "Blocked by JoesProxy".data(using: .utf8),
                        sourceKind: .block,
                        sourceDescription: sourceDescription
                    )
                    let responseData = self.makeLocalOverrideResponseData(
                        from: blockOverride,
                        keepConnectionOpen: false
                    )
                    let response = CapturedResponse(
                        statusCode: statusCode,
                        headers: self.headersWithContentLength(
                            blockOverride.headers,
                            bodyData: blockOverride.bodyData,
                            keepConnectionOpen: false
                        ),
                        bodyData: nil,
                        bodySize: nil,
                        source: .blocked,
                        sourceDescription: sourceDescription
                    )
                    eventLoop.execute {
                        let handler = loopBoundSelf.value
                        let context = loopBoundContext.value
                        handler.logHTTPS("Blocked request \(request.method) \(request.host):\(request.port)\(request.path) with \(statusCode).")
                        handler.write(responseData, keepConnectionOpen: false, nextState: .closed, context: context)
                    }
                    if let sessionRecorder {
                        let throttleConfig = self.throttleConfigurationProvider
                        Task {
                            if let sessionID = await sessionIDTask.value {
                                let stamped = await Self.attributedResponse(
                                    response,
                                    ruleID: ruleID,
                                    responseSource: .blocked,
                                    responseOverrideStore: responseOverrideStore,
                                    bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                                    throttleConfigurationProvider: throttleConfig
                                )
                                await sessionRecorder.completeSession(id: sessionID, response: stamped)
                            }
                        }
                    }

                case .deniedMapRemote(_, let reason, let detail):
                    if let sessionRecorder, let sessionID = await sessionIDTask.value {
                        await sessionRecorder.failSession(
                            id: sessionID,
                            message: "Map Remote denied [\(reason.rawValue)]: \(detail)"
                        )
                    }
                    eventLoop.execute {
                        let handler = loopBoundSelf.value
                        let context = loopBoundContext.value
                        handler.logHTTPS("Map Remote denied [\(reason.rawValue)] for \(request.method) \(request.host):\(request.port)\(request.path): \(detail)")
                        handler.sendMapRemoteErrorResponse(
                            statusLine: "403 Forbidden",
                            reasonCode: reason.rawValue,
                            body: detail,
                            context: context
                        )
                    }

                case .mapRemote(
                    let ruleID,
                    let remoteHost,
                    let remotePort,
                    let remoteScheme,
                    let requestTarget,
                    let allowLoopbackDestination,
                    let preserveHostHeader
                ):
                    let incomingHop = Self.highestMapRemoteHopCount(in: request.headers)
                    if incomingHop >= 3 {
                        let loopMessage = "Map Remote forwarding loop detected (hop count \(incomingHop) >= 3)."
                        if let sessionRecorder, let sessionID = await sessionIDTask.value {
                            await sessionRecorder.failSession(id: sessionID, message: loopMessage)
                        }
                        eventLoop.execute {
                            let handler = loopBoundSelf.value
                            let context = loopBoundContext.value
                            handler.logHTTPS("Map Remote loop detected for \(request.method) \(request.host):\(request.port)\(request.path)")
                            handler.sendMapRemoteErrorResponse(
                                statusLine: "508 Loop Detected",
                                reasonCode: "map_remote_loop_detected",
                                body: loopMessage,
                                context: context
                            )
                        }
                        break
                    }

                    let livePolicy = self.configuration?.loopbackDestinationPolicy ?? .disabled
                    let validatedEndpoint: ValidatedUpstreamEndpoint
                    do {
                        validatedEndpoint = try LoopbackAddressInspector.resolveAndValidate(
                            destinationHost: remoteHost,
                            port: remotePort,
                            scheme: remoteScheme,
                            incomingHeaders: request.headers,
                            originalRequestHost: request.host,
                            originalRequestPort: request.port,
                            originalRequestScheme: upstreamScheme,
                            isMapRemote: true,
                            allowLoopbackDestination: allowLoopbackDestination,
                            preserveHostHeader: preserveHostHeader,
                            policy: livePolicy,
                            reservedRegistry: .shared
                        )
                    } catch MapRemoteValidationError.policyDenied(let reason, let detail) {
                        let statusLine = (reason == .resolutionFailed) ? "502 Bad Gateway" : "403 Forbidden"
                        if let sessionRecorder, let sessionID = await sessionIDTask.value {
                            await sessionRecorder.failSession(
                                id: sessionID,
                                message: "Map Remote denied [\(reason.rawValue)]: \(detail)"
                            )
                        }
                        eventLoop.execute {
                            let handler = loopBoundSelf.value
                            let context = loopBoundContext.value
                            handler.logHTTPS("Map Remote failed [\(reason.rawValue)] for \(request.method) \(request.host):\(request.port)\(request.path): \(detail)")
                            handler.sendMapRemoteErrorResponse(
                                statusLine: statusLine,
                                reasonCode: reason.rawValue,
                                body: detail,
                                context: context
                            )
                        }
                        break
                    } catch MapRemoteValidationError.malformedRequest(let detail) {
                        if let sessionRecorder, let sessionID = await sessionIDTask.value {
                            await sessionRecorder.failSession(
                                id: sessionID,
                                message: "Map Remote denied [malformed_destination]: \(detail)"
                            )
                        }
                        eventLoop.execute {
                            let handler = loopBoundSelf.value
                            let context = loopBoundContext.value
                            handler.sendMapRemoteErrorResponse(
                                statusLine: "403 Forbidden",
                                reasonCode: MapRemoteDenialReason.malformedDestination.rawValue,
                                body: detail,
                                context: context
                            )
                        }
                        break
                    }

                    var remappedHeaders = request.headers.filter {
                        $0.name.caseInsensitiveCompare("X-JoesProxy-MapRemote-Hop") != .orderedSame
                    }
                    remappedHeaders.append(HTTPHeaderField(name: "X-JoesProxy-MapRemote-Hop", value: String(incomingHop + 1)))

                    let remappedRequest = HTTPProxyRequest(
                        kind: request.kind,
                        method: request.method,
                        version: request.version,
                        host: validatedEndpoint.destinationHost,
                        port: validatedEndpoint.port,
                        path: requestTarget ?? request.path,
                        headers: remappedHeaders,
                        body: request.body,
                        bodySpool: request.bodySpool,
                        originalBodySize: request.originalBodySize
                    )
                    if validatedEndpoint.isLoopback,
                       let pauseHook = Self.beforeLoopbackRegistrationPauseForTesting {
                        await pauseHook()
                    }
                    let hostAttributionSuffix = preserveHostHeader ? " (Host: original \(validatedEndpoint.httpHostHeaderValue))" : ""
                    eventLoop.execute {
                        let handler = loopBoundSelf.value
                        let context = loopBoundContext.value
                        handler.logHTTPS("Remapping \(request.method) \(request.host):\(request.port)\(request.path) → \(remoteScheme.rawValue)://\(validatedEndpoint.destinationHost):\(validatedEndpoint.port)\(remappedRequest.path)\(hostAttributionSuffix)")
                        handler.executeUpstreamRequest(
                            remappedRequest,
                            captureBodyLimit: captureBodyLimit,
                            upstreamScheme: remoteScheme,
                            validatedEndpoint: validatedEndpoint,
                            keepConnectionOpen: keepConnectionOpen,
                            nextState: nextState,
                            context: context,
                            sessionRecorder: sessionRecorder,
                            sessionIDTask: sessionIDTask,
                            responseSource: .mapRemote,
                            responseSourceDescription: "Remapped to \(remoteScheme.rawValue)://\(validatedEndpoint.destinationHost):\(validatedEndpoint.port)\(hostAttributionSuffix)",
                            ruleID: ruleID
                        )
                    }

                case .bookmarkRewrite(_, let rewriteRequest, let sourceDescription):
                    let rewrittenRequest = self.makeProxyRequest(from: rewriteRequest, version: request.version)
                    eventLoop.execute {
                        let handler = loopBoundSelf.value
                        let context = loopBoundContext.value
                        handler.logHTTPS("Rewriting \(request.method) \(request.host):\(request.port)\(request.path) to \(rewrittenRequest.method) \(rewrittenRequest.host):\(rewrittenRequest.port)\(rewrittenRequest.path)")
                        handler.executeUpstreamRequest(
                            rewrittenRequest,
                            captureBodyLimit: captureBodyLimit,
                            upstreamScheme: rewriteRequest.scheme,
                            keepConnectionOpen: keepConnectionOpen,
                            nextState: nextState,
                            context: context,
                            sessionRecorder: sessionRecorder,
                            sessionIDTask: sessionIDTask,
                            responseSource: .bookmarkRewrite,
                            responseSourceDescription: sourceDescription
                        )
                    }

                case .liveResponseRewrite(let ruleID, let rewrites, let sourceDescription, let expectedSchemaFingerprint):
                    eventLoop.execute {
                        let handler = loopBoundSelf.value
                        let context = loopBoundContext.value
                        handler.logHTTPS(
                            "Live response rewrite matched \(request.method) \(request.host):\(request.port)\(request.path). Source: \(sourceDescription)"
                        )
                        handler.executeUpstreamRequest(
                            request,
                            captureBodyLimit: captureBodyLimit,
                            upstreamScheme: upstreamScheme,
                            keepConnectionOpen: keepConnectionOpen,
                            nextState: nextState,
                            context: context,
                            sessionRecorder: sessionRecorder,
                            sessionIDTask: sessionIDTask,
                            liveResponseRewriteContext: LiveResponseRewriteContext(
                                ruleID: ruleID,
                                rewrites: rewrites,
                                sourceDescription: sourceDescription,
                                expectedSchemaFingerprint: expectedSchemaFingerprint
                            )
                        )
                    }

                case .liveCollectionMock(let ruleID, let plan, let sourceDescription, let revision):
                    eventLoop.execute {
                        let handler = loopBoundSelf.value
                        let context = loopBoundContext.value
                        handler.logHTTPS(
                            "Live collection mock matched \(request.method) \(request.host):\(request.port)\(request.path). Source: \(sourceDescription)"
                        )
                        handler.executeUpstreamRequest(
                            request,
                            captureBodyLimit: captureBodyLimit,
                            upstreamScheme: upstreamScheme,
                            keepConnectionOpen: keepConnectionOpen,
                            nextState: nextState,
                            context: context,
                            sessionRecorder: sessionRecorder,
                            sessionIDTask: sessionIDTask,
                            liveCollectionMockContext: LiveCollectionMockContext(
                                ruleID: ruleID,
                                plan: plan,
                                sourceDescription: sourceDescription,
                                revision: revision
                            )
                        )
                    }
                }
            } catch {
                if let sessionRecorder, let sessionID = await sessionIDTask.value {
                    await sessionRecorder.failSession(id: sessionID, error: error)
                }
                eventLoop.execute {
                    loopBoundSelf.value.sendFailureResponse(for: error, context: loopBoundContext.value)
                }
            }
        }
    }

    private func executeUpstreamRequest(
        _ request: HTTPProxyRequest,
        captureBodyLimit: Int,
        upstreamScheme: SessionScheme,
        validatedEndpoint: ValidatedUpstreamEndpoint? = nil,
        keepConnectionOpen: Bool,
        nextState: ConnectionState,
        context: ChannelHandlerContext,
        sessionRecorder: ProxySessionRecorder?,
        sessionIDTask: Task<UUID?, Never>,
        responseSource: CapturedResponseSource = .upstream,
        responseSourceDescription: String? = nil,
        liveResponseRewriteContext: LiveResponseRewriteContext? = nil,
        liveCollectionMockContext: LiveCollectionMockContext? = nil,
        ruleID: UUID? = nil
    ) {
        let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        let loopBoundContext = context.loopBound
        let effectiveRuleID = ruleID ?? liveResponseRewriteContext?.ruleID ?? liveCollectionMockContext?.ruleID
        let requestID = UUID()
        activeUpstreamRequestID = requestID
        if let activeMapRemoteSessionID {
            ActiveMapRemoteSessionRegistry.shared.unregister(activeMapRemoteSessionID)
            self.activeMapRemoteSessionID = nil
        }
        if let validatedEndpoint, validatedEndpoint.isLoopback {
            let eventLoop = context.eventLoop
            let registrationID = ActiveMapRemoteSessionRegistry.shared.register(
                port: validatedEndpoint.port,
                isLoopback: true
            ) {
                eventLoop.execute {
                    let handler = loopBoundSelf.value
                    let ctx = loopBoundContext.value
                    guard handler.activeUpstreamRequestID == requestID else { return }
                    handler.activeUpstreamRequestID = nil
                    handler.activeUpstreamCancellation?()
                    handler.activeUpstreamCancellation = nil
                    handler.activeStreamingForwarder = nil
                    ActiveMapRemoteSessionRegistry.shared.unregister(handler.activeMapRemoteSessionID)
                    handler.activeMapRemoteSessionID = nil
                    handler.state = .closed
                    ctx.close(promise: nil)
                }
            }
            self.activeMapRemoteSessionID = registrationID

            // Revalidate under the lock-ordered barrier established by `register(...)` so a
            // concurrent Settings revocation between preflight and connect fails closed before any
            // upstream socket connects.
            let currentPolicy = self.configuration?.loopbackDestinationPolicy ?? .disabled
            let denialReason: MapRemoteDenialReason? = !currentPolicy.isEnabled
                ? .permissionDisabled
                : (!currentPolicy.authorizedPorts.contains(validatedEndpoint.port) ? .portNotAuthorized : nil)
            if let denialReason {
                ActiveMapRemoteSessionRegistry.shared.unregister(registrationID)
                self.activeMapRemoteSessionID = nil
                self.activeUpstreamRequestID = nil
                self.releaseUploadSpool()
                let detail = denialReason == .permissionDisabled
                    ? "Local-server Map Remote access was revoked before upstream connect."
                    : "Authorized local destination port \(validatedEndpoint.port) was revoked before upstream connect."
                if let sessionRecorder {
                    Task {
                        if let sessionID = await sessionIDTask.value {
                            await sessionRecorder.failSession(
                                id: sessionID,
                                message: "Map Remote denied [\(denialReason.rawValue)]: \(detail)"
                            )
                        }
                    }
                }
                self.sendMapRemoteErrorResponse(
                    statusLine: "403 Forbidden",
                    reasonCode: denialReason.rawValue,
                    body: detail,
                    context: context
                )
                return
            }
        }

        transportDiagnostics?.recordProgress(.upstreamStarted)
        self.upstreamConnector.executeStreaming(
            request,
            scheme: upstreamScheme,
            validatedEndpoint: validatedEndpoint,
            downstreamChannel: context.channel,
            downstreamThrottleWriter: self.downstreamThrottleWriter,
            keepConnectionOpen: keepConnectionOpen,
            liveResponseRewriteContext: liveResponseRewriteContext,
            liveCollectionMockContext: liveCollectionMockContext,
            responseSource: responseSource,
            responseSourceDescription: responseSourceDescription,
            sessionRecorder: sessionRecorder,
            sessionIDTask: sessionIDTask,
            responseOverrideStore: self.responseOverrideStore,
            captureEnabled: sessionRecorder != nil,
            captureBodyLimit: captureBodyLimit,
            bookmarkResponseInterceptStore: self.bookmarkResponseInterceptStore,
            transportDiagnostics: self.transportDiagnostics,
            onSessionCompleted: { response, wireProfile in
                if let sessionRecorder {
                    let responseOverrideStore = self.responseOverrideStore
                    let bookmarkResponseInterceptStore = self.bookmarkResponseInterceptStore
                    let throttleConfig = self.throttleConfigurationProvider
                    Task {
                        if let sessionID = await sessionIDTask.value {
                            let stamped = await Self.attributedResponse(
                                response,
                                ruleID: effectiveRuleID,
                                responseSource: response.source,
                                responseOverrideStore: responseOverrideStore,
                                bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                                throttleConfigurationProvider: throttleConfig
                            )
                            await sessionRecorder.completeSession(
                                id: sessionID,
                                response: stamped,
                                wireProfile: wireProfile
                            )
                        }
                    }
                }
            },
            onSessionFailed: { error in
                if let sessionRecorder {
                    Task {
                        if let sessionID = await sessionIDTask.value {
                            await sessionRecorder.failSession(id: sessionID, error: error)
                        }
                    }
                }
            },
            onCancellationReady: { cancel in
                context.eventLoop.execute {
                    let handler = loopBoundSelf.value
                    guard handler.activeUpstreamRequestID == requestID else {
                        cancel()
                        return
                    }
                    handler.activeUpstreamCancellation = cancel
                }
            },
            onConnectionDone: { shouldKeepOpen in
                context.eventLoop.execute {
                    let handler = loopBoundSelf.value
                    let ctx = loopBoundContext.value
                    guard handler.activeUpstreamRequestID == requestID else { return }
                    handler.activeUpstreamRequestID = nil
                    handler.activeUpstreamCancellation = nil
                    handler.activeStreamingForwarder = nil
                    ActiveMapRemoteSessionRegistry.shared.unregister(handler.activeMapRemoteSessionID)
                    handler.activeMapRemoteSessionID = nil
                    handler.releaseUploadSpool()
                    if shouldKeepOpen {
                        handler.state = nextState
                        handler.processBufferedDataIfPossible(context: ctx)
                    } else {
                        handler.state = .closed
                        ctx.close(promise: nil)
                    }
                }
            }
        ).whenComplete { result in
            guard loopBoundSelf.value.activeUpstreamRequestID == requestID else { return }
            switch result {
            case .success(let forwarder):
                let handler = loopBoundSelf.value
                handler.activeStreamingForwarder = forwarder
            case .failure(let error):
                let handler = loopBoundSelf.value
                let ctx = loopBoundContext.value
                handler.activeStreamingForwarder = nil
                handler.logHTTPS("Upstream request failed for \(request.method) \(request.host):\(request.port)\(request.path): \(error.localizedDescription)")
                handler.sendFailureResponse(for: error, context: ctx)
            }
        }
    }

    private func makeProxyRequest(from request: CapturedRequest, version: String) -> HTTPProxyRequest {
        HTTPProxyRequest(
            kind: .standard,
            method: request.method,
            version: version,
            host: request.host,
            port: request.port ?? (request.scheme == .https ? 443 : 80),
            path: request.path,
            headers: request.headers,
            body: request.bodyData ?? Data()
        )
    }

    private func establishPassThroughTunnel(
        for request: HTTPProxyRequest,
        reason: String = "HTTPS pass-through",
        context: ChannelHandlerContext
    ) {
        logHTTPS("Establishing CONNECT pass-through tunnel for \(request.host):\(request.port). Reason: \(reason)")
        let clientAddress = self.clientAddress
        let admittedTask = self.sessionRecorder?.admitSession(
                request: CapturedRequest(
                    method: request.method,
                    scheme: .https,
                    inspectionKind: .tunneledTLS,
                    inspectionReason: reason,
                    host: request.host,
                    port: request.port,
                    path: request.path,
                    headers: request.headers,
                    bodyData: nil,
                    bodySize: nil,
                    clientAddress: clientAddress,
                    localCACertificateSHA256Fingerprint: nil,
                    remoteTrustState: .routedButTunneled
                ), responseBodyLimit: 0
            )
        let sessionRecorder = admittedTask == nil ? nil : self.sessionRecorder
        let sessionIDTask = admittedTask ?? ProxySessionRecorder.uncapturedSession

        let bootstrap = ClientBootstrap(group: self.eventLoopGroup)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384))
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        bootstrap.connect(host: request.host, port: request.port).whenComplete { result in
            switch result {
            case .success(let upstreamChannel):
                let peerHandler = TunnelPeerRelayHandler(
                    peer: context.channel,
                    throttleWriter: NetworkThrottleWriter(
                        direction: .downstream,
                        configurationProvider: self.throttleConfigurationProvider
                    )
                )
                upstreamChannel.pipeline.addHandler(peerHandler).whenComplete { addResult in
                    switch addResult {
                    case .success:
                        if let sessionRecorder {
                            Task {
                                if let sessionID = await sessionIDTask.value {
                                    await sessionRecorder.completeSession(
                                        id: sessionID,
                                        response: CapturedResponse(
                                            statusCode: 200,
                                            headers: [HTTPHeaderField(name: "Connection", value: "close")],
                                            bodyData: nil,
                                            bodySize: nil
                                        )
                                    )
                                }
                            }
                        }

                        self.state = .tunneling(peer: upstreamChannel)
                        self.write(
                            Data("HTTP/1.1 200 Connection Established\r\nConnection: close\r\n\r\n".utf8),
                            keepConnectionOpen: true,
                            nextState: .tunneling(peer: upstreamChannel),
                            context: context
                        )
                    case .failure(let error):
                        upstreamChannel.close(promise: nil)
                        if let sessionRecorder {
                            Task {
                                if let sessionID = await sessionIDTask.value {
                                    await sessionRecorder.failSession(id: sessionID, error: error)
                                }
                            }
                        }
                        self.sendFailureResponse(for: error, context: context)
                    }
                }
            case .failure(let error):
                if let sessionRecorder {
                    Task {
                        if let sessionID = await sessionIDTask.value {
                            await sessionRecorder.failSession(id: sessionID, error: error)
                        }
                    }
                }
                self.sendFailureResponse(for: error, context: context)
            }
        }
    }

    private func beginTLSInterception(for request: HTTPProxyRequest, context: ChannelHandlerContext) {
        logHTTPS("Beginning TLS interception for \(request.host):\(request.port)")
        guard let certificateAuthority else {
            sendFailureResponse(for: CertificateAuthorityError.identityUnavailable, context: context)
            return
        }

        do {
            let tlsContext = try makeServerTLSContext(
                host: request.host,
                certificateAuthority: certificateAuthority
            )

            var connectResponse = context.channel.allocator.buffer(capacity: 128)
            connectResponse.writeString("HTTP/1.1 200 Connection Established\r\nConnection: keep-alive\r\n\r\n")

            downstreamThrottleWriter.writeAndFlush(connectResponse, to: context.channel).whenComplete { result in
                switch result {
                case .success:
                    do {
                        try context.channel.pipeline.syncOperations.addHandler(
                            NIOSSLServerHandler(context: tlsContext),
                            position: .first
                        )
                        self.logHTTPS("Installed TLS handler for \(request.host):\(request.port). Buffered bytes waiting: \(self.buffer.count)")
                        self.state = .interceptingTLS(connectHost: request.host, connectPort: request.port)
                        self.processBufferedDataIfPossible(context: context)
                    } catch {
                        self.logHTTPS("Failed to install TLS handler for \(request.host):\(request.port): \(error.localizedDescription)")
                        self.sendFailureResponse(for: error, context: context)
                    }
                case .failure(let error):
                    self.logHTTPS("Failed to write CONNECT response for \(request.host):\(request.port): \(error.localizedDescription)")
                    self.sendFailureResponse(for: error, context: context)
                }
            }
        } catch {
            logHTTPS("Failed to create TLS context for \(request.host):\(request.port): \(error.localizedDescription)")
            sendFailureResponse(for: error, context: context)
        }
    }

    private func makeServerTLSContext(
        host: String,
        certificateAuthority: any CertificateAuthorityProviding
    ) throws -> NIOSSLContext {
        let leaf = try certificateAuthority.issueLeafCertificate(for: host)
        activeLocalCAFingerprint = leaf.issuerCertificateSHA256Fingerprint
        let certificate = try NIOSSLCertificate(bytes: Array(leaf.certificateData), format: .der)
        let privateKey = try NIOSSLPrivateKey(bytes: Array(leaf.privateKeyData), format: .pem)
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(privateKey)
        )
        return try NIOSSLContext(configuration: configuration)
    }

    private func write(
        _ data: Data,
        keepConnectionOpen: Bool,
        nextState: ConnectionState,
        context: ChannelHandlerContext,
        authoredReceiptID: UUID? = nil
    ) {
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        let writeFuture = downstreamThrottleWriter.writeAndFlush(buffer, to: context.channel)
        if let authoredReceiptID {
            EffectBundleActivationGate.shared.trackDelivery(writeFuture, receiptID: authoredReceiptID)
        }
        writeFuture.whenComplete { result in
            self.releaseUploadSpool()
            switch result {
            case .success:
                self.logHTTPS("Wrote \(data.count) bytes back to client. keepConnectionOpen=\(keepConnectionOpen) nextState=\(String(describing: nextState))")
                self.state = nextState
                if keepConnectionOpen {
                    self.processBufferedDataIfPossible(context: context)
                } else {
                    context.close(promise: nil)
                }
            case .failure(let error):
                switch ProxyChannelErrorClassifier.classify(error) {
                case .expectedDisconnect:
                    self.transportDiagnostics?.recordExpectedClientWriteFailure()
                    self.logger.info("Expected client write failure [\(self.traceID, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
                case .unexpectedFailure:
                    self.transportDiagnostics?.recordUnexpectedClientWriteFailure()
                    self.logger.error("Failed to write proxy response: \(error.localizedDescription, privacy: .public)")
                }
                self.logHTTPS("Failed to write response back to client: \(error.localizedDescription)")
                self.state = .closed
                context.close(promise: nil)
            }
        }
    }

    fileprivate func resumeTunnelReads(from source: Channel, to destination: Channel) {
        upstreamThrottleWriter.resumeReadsIfDrained(from: source, to: destination)
    }

    private func forwardToPeer(_ peer: Channel, payload: NIOAny, context: ChannelHandlerContext) {
        let outbound = unwrapInboundIn(payload)
        upstreamThrottleWriter.relay(outbound, to: peer, readingFrom: context.channel).whenComplete { result in
            if case .failure = result {
                context.close(promise: nil)
                peer.close(promise: nil)
            }
        }
    }

    private func sendFailureResponse(for error: Error, context: ChannelHandlerContext) {
        if let storageError = error as? UploadBodySpoolError, storageError != .capacityUnavailable {
            uploadSpoolService?.recordStorageFailure()
        }
        let presentation = NetworkFailureClassifier.presentation(for: error)
        logHTTPS("Sending failure response [\(presentation.bucket.rawValue)]: \(presentation.message)")
        let statusLine = responseStatusLine(for: error)
        let body = (error as? UploadBodySpoolError)?.errorDescription ?? presentation.userFacingMessage
        let response = """
        HTTP/1.1 \(statusLine)\r
        Content-Type: text/plain; charset=utf-8\r
        Connection: close\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """

        state = .closed
        write(Data(response.utf8), keepConnectionOpen: false, nextState: .closed, context: context)
    }

    private func sendMapRemoteErrorResponse(
        statusLine: String,
        reasonCode: String,
        body: String,
        context: ChannelHandlerContext
    ) {
        let response = """
        HTTP/1.1 \(statusLine)\r
        Content-Type: text/plain; charset=utf-8\r
        X-JoesProxy-Denial-Reason: \(reasonCode)\r
        Connection: close\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """
        state = .closed
        write(Data(response.utf8), keepConnectionOpen: false, nextState: .closed, context: context)
    }

    private static func highestMapRemoteHopCount(in headers: [HTTPHeaderField]) -> Int {
        headers
            .filter { $0.name.caseInsensitiveCompare("X-JoesProxy-MapRemote-Hop") == .orderedSame }
            .compactMap { Int($0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .max() ?? 0
    }

    private func responseStatusLine(for error: Error) -> String {
        switch error {
        case is UploadBodySpoolError:
            return "507 Insufficient Storage"
        case is HTTPRequestParserError:
            return "400 Bad Request"
        case is CertificateAuthorityError:
            return "502 Bad Gateway"
        default:
            return "502 Bad Gateway"
        }
    }

    /// Packages a resolved local response into wire bytes, stamps and records the session, and
    /// writes it back on the event loop. Shared by every "serve locally, never contact upstream"
    /// decision (Map Local rules, HLS fixture runs) so they stay behaviorally identical.
    private func serveResolvedOverride(
        _ resolvedOverride: ResolvedResponseOverride,
        captureBodyLimit: Int,
        requestHost: String,
        responseSource: CapturedResponseSource,
        logMessage: String,
        keepConnectionOpen: Bool,
        nextState: ConnectionState,
        sessionRecorder: ProxySessionRecorder?,
        sessionIDTask: Task<UUID?, Never>,
        responseOverrideStore: ResponseOverrideStore?,
        bookmarkResponseInterceptStore: BookmarkResponseInterceptStore?,
        eventLoop: EventLoop,
        loopBoundSelf: NIOLoopBound<ProxyConnectionHandler>,
        loopBoundContext: NIOLoopBound<ChannelHandlerContext>,
        observationID: UUID? = nil
    ) async {
        let authoredReceiptID = observationID ?? resolvedOverride.authoredResource.map { resource in
            let body = [204, 304].contains(resolvedOverride.statusCode) ? Data() : (resolvedOverride.bodyData ?? Data())
            return EffectBundleActivationGate.shared.observe(resource: resource,
                servedSHA256: EffectBundleValidator.sha256Hex(body))
        }
        let resolvedOverride = Self.applyingNoCachingPolicyIfNeeded(
            to: resolvedOverride,
            requestHost: requestHost,
            configuration: configuration
        )
        let responseData = makeLocalOverrideResponseData(
            from: resolvedOverride,
            keepConnectionOpen: keepConnectionOpen
        )
        let capturedBody = CaptureBodyLimiter(limit: sessionRecorder == nil ? 0 : captureBodyLimit)
            .retainedBody(from: resolvedOverride.bodyData ?? Data())
        let response = CapturedResponse(
            statusCode: resolvedOverride.statusCode,
            headers: headersWithContentLength(
                resolvedOverride.headers,
                bodyData: resolvedOverride.bodyData,
                keepConnectionOpen: keepConnectionOpen
            ),
            bodyData: capturedBody.data,
            bodySize: capturedBody.size,
            source: responseSource,
            sourceDescription: resolvedOverride.sourceDescription,
            bodyTruncated: capturedBody.truncated
        )
        eventLoop.execute {
            let handler = loopBoundSelf.value
            let context = loopBoundContext.value
            handler.logHTTPS(logMessage)
            handler.write(responseData, keepConnectionOpen: keepConnectionOpen, nextState: nextState, context: context,
                authoredReceiptID: authoredReceiptID)
        }

        if let authoredReceiptID {
            Task {
                let sessionID = await sessionIDTask.value
                EffectBundleActivationGate.shared.completeReceipt(id: authoredReceiptID, sessionID: sessionID)
            }
        }

        if let sessionRecorder {
            let throttleConfig = self.throttleConfigurationProvider
            Task {
                if let sessionID = await sessionIDTask.value {
                    let stamped = await Self.attributedResponse(
                        response,
                        ruleID: resolvedOverride.ruleID,
                        responseSource: responseSource,
                        responseOverrideStore: responseOverrideStore,
                        bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                        throttleConfigurationProvider: throttleConfig,
                        directOverrideAttribution: resolvedOverride.mcpAttribution
                    )
                    await sessionRecorder.completeSession(id: sessionID, response: stamped)
                }
            }
        }
    }

    /// Returns `resolvedOverride` unchanged, or with `NoCachingPolicy`-adjusted headers when the
    /// rule's own `forceNoCache` flag is set or the existing global/per-domain Settings toggle
    /// applies to `requestHost` — the same mechanism already used for Map Remote/live-rewrite
    /// upstream responses, now also reachable for locally-served overrides.
    static func applyingNoCachingPolicyIfNeeded(
        to resolvedOverride: ResolvedResponseOverride,
        requestHost: String,
        configuration: AppConfiguration?
    ) -> ResolvedResponseOverride {
        let noCachingPolicy = NoCachingPolicy(
            isGloballyEnabled: configuration?.isNoCachingEnabled ?? false,
            perDomainList: configuration?.noCachingDomains ?? []
        )
        guard resolvedOverride.forceNoCache || noCachingPolicy.applies(to: requestHost) else {
            return resolvedOverride
        }
        var result = ResolvedResponseOverride(
            ruleID: resolvedOverride.ruleID,
            statusCode: resolvedOverride.statusCode,
            headers: NoCachingPolicy.applyToResponseHeaders(resolvedOverride.headers),
            bodyData: resolvedOverride.bodyData,
            sourceKind: resolvedOverride.sourceKind,
            sourceDescription: resolvedOverride.sourceDescription,
            capturedResponseSource: resolvedOverride.capturedResponseSource,
            forceNoCache: resolvedOverride.forceNoCache,
            mcpAttribution: resolvedOverride.mcpAttribution
        )
        result.authoredResource = resolvedOverride.authoredResource
        return result
    }

    private func makeLocalOverrideResponseData(
        from response: ResolvedResponseOverride,
        keepConnectionOpen: Bool
    ) -> Data {
        let isBodylessStatus = response.statusCode == 204 || response.statusCode == 304
        let bodyData = isBodylessStatus ? Data() : (response.bodyData ?? Data())
        let headers = headersWithContentLength(
            response.headers,
            bodyData: isBodylessStatus ? nil : response.bodyData,
            keepConnectionOpen: keepConnectionOpen
        )
        let reasonPhrase = HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized
        var responseHead = "HTTP/1.1 \(response.statusCode) \(reasonPhrase)\r\n"

        for header in headers {
            responseHead += "\(header.name): \(header.value)\r\n"
        }

        responseHead += "\r\n"
        var responseData = Data(responseHead.utf8)
        if !isBodylessStatus {
            responseData.append(bodyData)
        }
        return responseData
    }

    /// Rebuilds the raw HTTP/1.1 response bytes from (possibly modified) headers and body.
    /// Used when no-caching policy mutates response headers so the wire bytes sent to the
    /// client reflect the modified headers.
    private func makeModifiedResponseData(
        statusCode: Int,
        headers: [HTTPHeaderField],
        body: Data,
        keepConnectionOpen: Bool
    ) -> Data {
        let finalHeaders = headersWithContentLength(headers, bodyData: body, keepConnectionOpen: keepConnectionOpen)
        let reasonPhrase = HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
        var responseHead = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
        for header in finalHeaders {
            responseHead += "\(header.name): \(header.value)\r\n"
        }
        responseHead += "\r\n"
        var responseData = Data(responseHead.utf8)
        responseData.append(body)
        return responseData
    }

    private func headersWithContentLength(
        _ headers: [HTTPHeaderField],
        bodyData: Data?,
        keepConnectionOpen: Bool
    ) -> [HTTPHeaderField] {
        var resolvedHeaders = headers.filter { header in
            let lowercasedName = header.name.lowercased()
            return lowercasedName != "content-length" &&
                lowercasedName != "connection" &&
                lowercasedName != "transfer-encoding"
        }

        if let bodyData {
            resolvedHeaders.append(
                HTTPHeaderField(
                    name: "Content-Length",
                    value: String(bodyData.count)
                )
            )
        }
        resolvedHeaders.append(
            HTTPHeaderField(name: "Connection", value: keepConnectionOpen ? "keep-alive" : "close")
        )
        return resolvedHeaders
    }

    private func logHTTPS(_ message: @autoclosure () -> String) {
        guard configuration?.verboseHTTPSLoggingEnabled == true else {
            return
        }

        let text = message()
        logger.info("[HTTPS \(self.traceID, privacy: .public)] \(text, privacy: .public)")
    }

    private func bufferPreview(_ data: Data, byteCount: Int = 48) -> String {
        let prefix = data.prefix(byteCount)
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        let ascii = prefix.map { byte -> Character in
            if byte >= 32, byte < 127 {
                return Character(UnicodeScalar(byte))
            }
            return "."
        }
        let escapedText = String(decoding: prefix, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")

        return "hex=[\(hex)] ascii=[\(String(ascii))] escaped=[\(escapedText)]"
    }

    private func channelAddressDescription(_ address: SocketAddress?) -> String {
        address?.description ?? "unknown"
    }

    /// Stamps MCP capture attribution for override, bookmark intercept, and throttle effects.
    private static func attributedResponse(
        _ response: CapturedResponse,
        ruleID: UUID?,
        responseSource: CapturedResponseSource?,
        responseOverrideStore: ResponseOverrideStore?,
        bookmarkResponseInterceptStore: BookmarkResponseInterceptStore?,
        throttleConfigurationProvider: @escaping @Sendable () -> NetworkThrottleConfiguration,
        directOverrideAttribution: MCPCaptureAttribution? = nil
    ) async -> CapturedResponse {
        var overrideAttribution = directOverrideAttribution
        if let ruleID, let responseOverrideStore {
            let rules = await responseOverrideStore.rules()
            if let rule = rules.first(where: { $0.id == ruleID }) {
                overrideAttribution = MCPActiveEffectAttributionResolver.attribution(for: rule)
            }
        }
        if overrideAttribution == nil,
           responseSource == .bookmarkResponseRewrite,
           let ruleID,
           let bookmarkResponseInterceptStore {
            overrideAttribution = await bookmarkResponseInterceptStore.mcpAttribution(forBookmarkID: ruleID)
        }
        let throttleAttribution = MCPActiveEffectAttributionResolver.attribution(
            for: throttleConfigurationProvider()
        )
        let stamped = MCPActiveEffectAttributionResolver.stampedResponse(
            response,
            overrideAttribution: overrideAttribution,
            throttleAttribution: throttleAttribution
        )
        return MCPSessionAttributionService.measurementSuspensionAttributionIfNeeded(on: stamped)
    }
}

private final class TunnelPeerRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let peer: Channel
    private let throttleWriter: NetworkThrottleWriter

    init(peer: Channel, throttleWriter: NetworkThrottleWriter) {
        self.peer = peer
        self.throttleWriter = throttleWriter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let outbound = unwrapInboundIn(data)
        throttleWriter.relay(outbound, to: peer, readingFrom: context.channel).whenComplete { result in
            if case .failure = result {
                context.close(promise: nil)
                self.peer.close(promise: nil)
            }
        }
    }

    func resumeReads(from source: Channel) {
        throttleWriter.resumeReadsIfDrained(from: source, to: peer)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            peer.pipeline.handler(type: ProxyConnectionHandler.self).whenSuccess { handler in
                handler.resumeTunnelReads(from: self.peer, to: context.channel)
            }
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(promise: nil)
        context.close(promise: nil)
    }
}
