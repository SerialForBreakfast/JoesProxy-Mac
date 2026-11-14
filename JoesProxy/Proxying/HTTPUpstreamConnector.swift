import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import os

enum HTTPUpstreamConnectorError: LocalizedError {
    case invalidPort(Int)
    case tlsConfigurationFailed(String)
    case incompleteResponse

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "The upstream port '\(port)' is invalid."
        case .tlsConfigurationFailed(let message):
            return message
        case .incompleteResponse:
            return "The upstream server closed the connection before sending a complete response."
        }
    }
}

struct HTTPUpstreamConnectorConfiguration: Sendable {
    var trustedRootCertificates: [Data] = []
}

struct HTTPUpstreamResponse: Sendable {
    let data: Data
    let wireProfile: WireTimingProfile
}

final class UpstreamWireTimingRecorder {
    private static let maximumChunkSamples = 512

    private(set) var profile: WireTimingProfile
    let transport = RequestTransportDiagnostics()

    init(startedAt: Date) {
        profile = WireTimingProfile(connectionStartedAt: startedAt)
    }

    func recordConnectionEstablished(at date: Date = Date()) {
        profile.connectionEstablishedAt = date
        transport.connected()
    }

    func recordTLSHandshake(protocolName: String?, at date: Date = Date()) {
        profile.tlsHandshakeCompletedAt = date
        transport.tlsReady(protocolName: protocolName)
    }

    func recordRequestSendStarted(at date: Date = Date()) {
        profile.requestSendStartedAt = date
    }

    func recordRequestSent(at date: Date = Date()) {
        profile.requestSentAt = date
    }

    func recordResponseChunk(byteCount: Int, at date: Date = Date()) {
        guard byteCount > 0 else { return }
        transport.upstreamRead()
        if profile.firstResponseByteAt == nil {
            profile.firstResponseByteAt = date
        }
        guard let firstResponseByteAt = profile.firstResponseByteAt else { return }
        if profile.chunks.count < Self.maximumChunkSamples {
            profile.chunks.append(
                WireChunkSample(offset: max(0, date.timeIntervalSince(firstResponseByteAt)), byteCount: byteCount)
            )
        } else {
            profile.omittedChunkCount += 1
        }
    }

    func snapshot(responseData: Data, completedAt: Date = Date()) -> WireTimingProfile {
        let delimiter = Data("\r\n\r\n".utf8)
        let headerByteCount = responseData.range(of: delimiter)?.upperBound ?? 0
        return snapshot(
            headerByteCount: headerByteCount,
            bodyByteCount: max(0, responseData.count - headerByteCount),
            completedAt: completedAt
        )
    }

    func snapshot(headerByteCount: Int, bodyByteCount: Int, completedAt: Date = Date()) -> WireTimingProfile {
        profile.responseCompletedAt = completedAt
        profile.transport = transport.snapshot()
        profile.transfer = WireTransferMetrics(
            headerByteCount: headerByteCount,
            transferBodyByteCount: bodyByteCount,
            decodedBodyByteCount: nil,
            contentEncoding: nil
        )
        return profile
    }
}

final class HTTPUpstreamConnector {
    typealias ThrottleConfigurationProvider = () -> NetworkThrottleConfiguration

    private let group: EventLoopGroup
    private let responseParser: HTTPResponseParser
    private let configuration: HTTPUpstreamConnectorConfiguration
    private let appConfiguration: (any AppConfiguration)?
    private let throttleConfigurationProvider: ThrottleConfigurationProvider
    private let uploadForwardingLifecycle: UploadForwardingLifecycle?
    private let liveCollectionTransformationExecutor: LiveCollectionTransformationExecutor
    private let logger = Logger(subsystem: "com.joesproxyapp", category: "HTTPUpstreamConnector")

    init(
        group: EventLoopGroup,
        responseParser: HTTPResponseParser = HTTPResponseParser(),
        configuration: HTTPUpstreamConnectorConfiguration = HTTPUpstreamConnectorConfiguration(),
        appConfiguration: (any AppConfiguration)? = nil,
        throttleConfigurationProvider: @escaping ThrottleConfigurationProvider = { .defaults },
        uploadForwardingLifecycle: UploadForwardingLifecycle? = nil,
        liveCollectionTransformationExecutor: LiveCollectionTransformationExecutor = LiveCollectionTransformationExecutor()
    ) {
        self.group = group
        self.responseParser = responseParser
        self.configuration = configuration
        self.appConfiguration = appConfiguration
        self.throttleConfigurationProvider = throttleConfigurationProvider
        self.uploadForwardingLifecycle = uploadForwardingLifecycle
        self.liveCollectionTransformationExecutor = liveCollectionTransformationExecutor
    }

    @preconcurrency func executeStreaming(
        _ request: HTTPProxyRequest,
        scheme: SessionScheme,
        validatedEndpoint: ValidatedUpstreamEndpoint? = nil,
        downstreamChannel: Channel,
        downstreamThrottleWriter: NetworkThrottleWriter,
        keepConnectionOpen: Bool,
        liveResponseRewriteContext: LiveResponseRewriteContext? = nil,
        liveCollectionMockContext: LiveCollectionMockContext? = nil,
        responseSource: CapturedResponseSource = .upstream,
        responseSourceDescription: String? = nil,
        sessionRecorder: ProxySessionRecorder? = nil,
        sessionIDTask: Task<UUID?, Never>,
        responseOverrideStore: ResponseOverrideStore? = nil,
        captureEnabled: Bool = true,
        captureBodyLimit: Int,
        bookmarkResponseInterceptStore: BookmarkResponseInterceptStore? = nil,
        transportDiagnostics: CaptureTransportDiagnostics? = nil,
        onSessionCompleted: @escaping @Sendable (CapturedResponse, WireTimingProfile) -> Void,
        onSessionFailed: @escaping @Sendable (Error) -> Void,
        onCancellationReady: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { _ in },
        onConnectionDone: @escaping @Sendable (Bool) -> Void
    ) -> EventLoopFuture<StreamingUpstreamForwarder> {
        guard (1...Int(UInt16.max)).contains(request.port) else {
            let error = HTTPUpstreamConnectorError.invalidPort(request.port)
            onSessionFailed(error)
            return group.next().makeFailedFuture(error)
        }

        let timingRecorder = UpstreamWireTimingRecorder(startedAt: Date())
        timingRecorder.transport.configureCapture(enabled: captureEnabled, bodyLimit: captureBodyLimit,
            mutationConfigured: liveResponseRewriteContext != nil || liveCollectionMockContext != nil)
        if captureEnabled, let transportDiagnostics {
            let diagnostics = timingRecorder.transport
            let epoch = transportDiagnostics.requestEvidenceEpoch
            // At most the existing admitted-capture bound can await an ID; no rejected collectors.
            Task {
                if let id = await sessionIDTask.value {
                    transportDiagnostics.observeRequest(id: id, diagnostics: diagnostics, epoch: epoch)
                }
            }
        }

        logHTTPS(
            "Opening streaming upstream \(scheme.rawValue.uppercased()) request \(request.method) \(request.host):\(request.port)\(request.path)"
        )

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16_384))
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)

        return connectChannel(bootstrap: bootstrap, request: request, validatedEndpoint: validatedEndpoint).flatMap { channel in
            timingRecorder.recordConnectionEstablished()
            do {
                let forwarder = StreamingUpstreamForwarder(
                    request: request,
                    upstreamScheme: scheme,
                    keepConnectionOpen: keepConnectionOpen,
                    downstreamChannel: downstreamChannel,
                    downstreamThrottleWriter: downstreamThrottleWriter,
                    responseParser: self.responseParser,
                    timingRecorder: timingRecorder,
                    boundedCaptureAccumulator: BoundedCaptureAccumulator(
                        limit: captureEnabled
                            ? captureBodyLimit : 0,
                        countWithoutBody: captureEnabled
                    ),
                    sessionRecorder: sessionRecorder,
                    sessionIDTask: sessionIDTask,
                    responseSource: responseSource,
                    responseSourceDescription: responseSourceDescription,
                    liveResponseRewriteContext: liveResponseRewriteContext,
                    liveCollectionMockContext: liveCollectionMockContext,
                    liveCollectionTransformationExecutor: self.liveCollectionTransformationExecutor,
                    appConfiguration: self.appConfiguration,
                    responseOverrideStore: responseOverrideStore,
                    bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
                    transportDiagnostics: transportDiagnostics,
                    onSessionCompleted: onSessionCompleted,
                    onSessionFailed: onSessionFailed,
                    onConnectionDone: onConnectionDone
                )

                if scheme == .https {
                    let sni = self.resolvedTLSServerName(for: request.host, validatedEndpoint: validatedEndpoint)
                    try channel.pipeline.syncOperations.addHandler(self.makeClientTLSHandler(for: request.host, serverHostname: sni))
                }
                let forwarderFuture = channel.pipeline.addHandler(forwarder)

                return forwarderFuture.flatMap {
                    if let cancel = forwarder.cancelForDownstreamClosure { onCancellationReady(cancel) }
                    let outbound = self.makeUpstreamRequestBuffer(
                        for: request,
                        scheme: scheme,
                        hostHeaderOverride: validatedEndpoint?.httpHostHeaderValue,
                        allocator: channel.allocator
                    )
                    let upstreamThrottleWriter = NetworkThrottleWriter(
                        direction: .upstream,
                        configurationProvider: self.throttleConfigurationProvider
                    )

                    timingRecorder.recordRequestSendStarted()
                    return self.sendRequestBody(request, head: outbound, writer: upstreamThrottleWriter, channel: channel).map {
                        timingRecorder.recordRequestSent()
                        self.logHTTPS("Forwarded upstream request \(request.method) \(request.host):\(request.port)\(request.path)")
                        return forwarder
                    }.flatMapError { error in
                        if forwarder.hasCompletedResponse {
                            return channel.eventLoop.makeSucceededFuture(forwarder)
                        }
                        self.logHTTPS("Upstream request failed before response for \(request.method) \(request.host):\(request.port)\(request.path): \(error.localizedDescription)")
                        channel.close(promise: nil)
                        timingRecorder.transport.failed(error: error)
                        onSessionFailed(error)
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
            } catch {
                self.logHTTPS("Failed to prepare upstream request \(request.method) \(request.host):\(request.port)\(request.path): \(error.localizedDescription)")
                channel.close(promise: nil)
                timingRecorder.transport.failed(error: error)
                onSessionFailed(error)
                return channel.eventLoop.makeFailedFuture(error)
            }
        }.flatMapError { error in
            timingRecorder.transport.failed(error: error)
            onSessionFailed(error)
            return self.group.next().makeFailedFuture(error)
        }
    }

    @preconcurrency func execute(
        _ request: HTTPProxyRequest,
        scheme: SessionScheme,
        validatedEndpoint: ValidatedUpstreamEndpoint? = nil
    ) -> EventLoopFuture<HTTPUpstreamResponse> {
        guard (1...Int(UInt16.max)).contains(request.port) else {
            return group.next().makeFailedFuture(HTTPUpstreamConnectorError.invalidPort(request.port))
        }

        let timingRecorder = UpstreamWireTimingRecorder(startedAt: Date())

        logHTTPS(
            "Opening upstream \(scheme.rawValue.uppercased()) request \(request.method) \(request.host):\(request.port)\(request.path)"
        )

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)

        return connectChannel(bootstrap: bootstrap, request: request, validatedEndpoint: validatedEndpoint).flatMap { channel in
            timingRecorder.recordConnectionEstablished()
            do {
                let responsePromise = channel.eventLoop.makePromise(of: Data.self)
                let collector = UpstreamResponseCollector(
                    requestMethod: request.method,
                    responseParser: self.responseParser,
                    responsePromise: responsePromise,
                    timingRecorder: timingRecorder
                )

                if scheme == .https {
                    let sni = self.resolvedTLSServerName(for: request.host, validatedEndpoint: validatedEndpoint)
                    try channel.pipeline.syncOperations.addHandler(self.makeClientTLSHandler(for: request.host, serverHostname: sni))
                }
                let collectorFuture = channel.pipeline.addHandler(collector)

                return collectorFuture.flatMap {
                    responsePromise.futureResult.whenComplete { _ in
                        channel.close(promise: nil)
                    }

                    let outbound = self.makeUpstreamRequestBuffer(
                        for: request,
                        scheme: scheme,
                        hostHeaderOverride: validatedEndpoint?.httpHostHeaderValue,
                        allocator: channel.allocator
                    )
                    let upstreamThrottleWriter = NetworkThrottleWriter(
                        direction: .upstream,
                        configurationProvider: self.throttleConfigurationProvider
                    )

                    timingRecorder.recordRequestSendStarted()
                    return self.sendRequestBody(request, head: outbound, writer: upstreamThrottleWriter, channel: channel).flatMap {
                        timingRecorder.recordRequestSent()
                        self.logHTTPS("Forwarded upstream request \(request.method) \(request.host):\(request.port)\(request.path)")
                        return responsePromise.futureResult.map { responseData in
                            HTTPUpstreamResponse(
                                data: responseData,
                                wireProfile: timingRecorder.snapshot(responseData: responseData)
                            )
                        }
                    }.flatMapError { error in
                        self.logHTTPS("Upstream request failed before response for \(request.method) \(request.host):\(request.port)\(request.path): \(error.localizedDescription)")
                        channel.close(promise: nil)
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
            } catch {
                self.logHTTPS("Failed to prepare upstream request \(request.method) \(request.host):\(request.port)\(request.path): \(error.localizedDescription)")
                channel.close(promise: nil)
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
    }

    private func connectChannel(
        bootstrap: ClientBootstrap,
        request: HTTPProxyRequest,
        validatedEndpoint: ValidatedUpstreamEndpoint?
    ) -> EventLoopFuture<Channel> {
        let connected: EventLoopFuture<Channel>
        if let validatedEndpoint {
            connected = connectValidatedAddresses(
                validatedEndpoint.candidateAddresses,
                index: 0,
                port: validatedEndpoint.port,
                bootstrap: bootstrap
            )
        } else {
            connected = bootstrap.connect(host: request.host, port: request.port)
        }
        return connected.map { channel in
            // An origin listening inside the ephemeral port range can receive a connection whose
            // source port equals its own port; TCP then connects the socket to itself.
            if let local = channel.localAddress, let remote = channel.remoteAddress, local == remote {
                self.logger.notice("Upstream connection is connected to itself local=\(String(describing: local), privacy: .private) port=\(local.port ?? -1, privacy: .public)")
            }
            return channel
        }
    }

    private func connectValidatedAddresses(
        _ candidates: [ResolvedIPAddress],
        index: Int,
        port: Int,
        bootstrap: ClientBootstrap
    ) -> EventLoopFuture<Channel> {
        guard candidates.indices.contains(index) else {
            return group.next().makeFailedFuture(
                MapRemoteValidationError.policyDenied(.resolutionFailed, "No validated socket addresses available.")
            )
        }
        let socketAddress: SocketAddress
        do {
            if let v4 = candidates[index].unwrappedIPv4 {
                socketAddress = try SocketAddress(ipAddress: ResolvedIPAddress.ipv4(v4).canonicalIPString, port: port)
            } else {
                socketAddress = try SocketAddress(ipAddress: candidates[index].canonicalIPString, port: port)
            }
        } catch {
            if index + 1 < candidates.count {
                return connectValidatedAddresses(candidates, index: index + 1, port: port, bootstrap: bootstrap)
            }
            return group.next().makeFailedFuture(error)
        }
        return bootstrap.connect(to: socketAddress).flatMapError { error in
            if index + 1 < candidates.count {
                return self.connectValidatedAddresses(candidates, index: index + 1, port: port, bootstrap: bootstrap)
            }
            return self.group.next().makeFailedFuture(error)
        }
    }

    private func resolvedTLSServerName(for host: String, validatedEndpoint: ValidatedUpstreamEndpoint?) -> String? {
        if let validatedEndpoint {
            return validatedEndpoint.tlsServerName
        }
        if LoopbackAddressInspector.parseLiteralIP(host) != nil {
            return nil
        }
        return LoopbackAddressInspector.stripBracketsAndTrailingDot(host).host
    }

    private func makeClientTLSHandler(for host: String, serverHostname: String?) throws -> NIOSSLClientHandler {
        let additionalTrustRoots = try configuration.trustedRootCertificates.map {
            try NIOSSLCertificate(bytes: Array($0), format: .der)
        }

        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        if !additionalTrustRoots.isEmpty {
            tlsConfiguration.trustRoots = .certificates(additionalTrustRoots)
        }

        do {
            let context = try NIOSSLContext(configuration: tlsConfiguration)
            return try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
        } catch {
            throw HTTPUpstreamConnectorError.tlsConfigurationFailed(
                "Failed to configure the upstream TLS client for '\(host)': \(error.localizedDescription)"
            )
        }
    }

    private func makeUpstreamRequestBuffer(
        for request: HTTPProxyRequest,
        scheme: SessionScheme,
        hostHeaderOverride: String? = nil,
        allocator: ByteBufferAllocator
    ) -> ByteBuffer {
        var filteredHeaders = request.headers.filter { header in
            let name = header.name.lowercased()
            return name != "proxy-connection" && name != "connection"
        }

        let resolvedHost = hostHeaderOverride ?? LoopbackAddressInspector.canonicalHostAuthority(
            host: request.host,
            port: request.port,
            scheme: scheme
        )
        filteredHeaders.removeAll { $0.name.caseInsensitiveCompare("Host") == .orderedSame }
        filteredHeaders.append(HTTPHeaderField(name: "Host", value: resolvedHost))
        filteredHeaders.append(HTTPHeaderField(name: "Connection", value: "close"))

        let noCachingPolicy = NoCachingPolicy(
            isGloballyEnabled: appConfiguration?.isNoCachingEnabled ?? false,
            perDomainList: appConfiguration?.noCachingDomains ?? []
        )
        if noCachingPolicy.applies(to: request.host) {
            filteredHeaders = NoCachingPolicy.applyToRequestHeaders(filteredHeaders)
        }

        var lines = ["\(request.method) \(request.path) \(request.version)"]
        lines.append(contentsOf: filteredHeaders.map { "\($0.name): \($0.value)" })
        lines.append("")
        lines.append("")

        let head = lines.joined(separator: "\r\n")
        var buffer = allocator.buffer(capacity: head.utf8.count + (request.bodySpool == nil ? request.body.count : 0))
        buffer.writeString(head)
        if request.bodySpool == nil { buffer.writeBytes(request.body) }
        return buffer
    }

    /// The worker awaits each disk read and each socket write; it never schedules a body-sized
    /// chain. Writer state stays on its owning event loop, including throttled writes.
    private func sendRequestBody(_ request: HTTPProxyRequest, head: ByteBuffer,
                                 writer: NetworkThrottleWriter, channel: Channel) -> EventLoopFuture<Void> {
        let headSent = writer.writeAndFlush(head, to: channel)
        guard let spool = request.bodySpool else { return headSent }
        let boundWriter = NIOLoopBound(writer, eventLoop: channel.eventLoop)
        return headSent.flatMap {
            let lifecycle = self.uploadForwardingLifecycle
            let workerID = lifecycle?.begin(on: channel)
            if lifecycle != nil && workerID == nil {
                return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
            }
            let promise = channel.eventLoop.makePromise(of: Void.self)
            Task {
                do {
                    var offset = 0
                    let size = await spool.byteCount
                    while offset < size {
                        guard channel.isActive else { throw ChannelError.ioOnClosedChannel }
                        let bytes = try await spool.read(at: offset)
                        guard !bytes.isEmpty else { throw UploadBodySpoolError.invalidState }
                        let count = bytes.count
                        try await channel.eventLoop.flatSubmit {
                            var chunk = channel.allocator.buffer(capacity: count)
                            chunk.writeBytes(bytes)
                            return boundWriter.value.writeAndFlush(chunk, to: channel)
                        }.get()
                        offset += count
                    }
                    promise.succeed(())
                } catch { promise.fail(error) }
                // Complete downstream future callbacks before allowing the loop to shut down.
                try? await channel.eventLoop.submit {}.get()
                if let workerID { lifecycle?.finish(workerID) }
            }
            return promise.futureResult
        }
    }

    private func logHTTPS(_ message: String) {
        guard appConfiguration?.verboseHTTPSLoggingEnabled == true else {
            return
        }

        logger.info("\(message, privacy: .public)")
    }
}

private final class UpstreamResponseCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let requestMethod: String
    private let responseParser: HTTPResponseParser
    private let responsePromise: EventLoopPromise<Data>
    private let timingRecorder: UpstreamWireTimingRecorder
    private var buffer = Data()
    private var isCompleted = false
    private var pendingFrameState: HTTPResponseFrameState?

    init(
        requestMethod: String,
        responseParser: HTTPResponseParser,
        responsePromise: EventLoopPromise<Data>,
        timingRecorder: UpstreamWireTimingRecorder
    ) {
        self.requestMethod = requestMethod
        self.responseParser = responseParser
        self.responsePromise = responsePromise
        self.timingRecorder = timingRecorder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let byteBuffer = unwrapInboundIn(data)
        timingRecorder.recordResponseChunk(byteCount: byteBuffer.readableBytes)
        byteBuffer.withUnsafeReadableBytes { ptr in
            if let baseAddress = ptr.baseAddress, ptr.count > 0 {
                buffer.append(baseAddress.assumingMemoryBound(to: UInt8.self), count: ptr.count)
            }
        }

        guard !isCompleted else {
            return
        }

        if let frameState = pendingFrameState {
            if responseParser.isComplete(dataCount: buffer.count, bodyData: buffer, frameState: frameState) {
                isCompleted = true
                responsePromise.succeed(buffer)
                context.close(promise: nil)
            }
        } else if let frameState = responseParser.parseFrameState(from: buffer, requestMethod: requestMethod) {
            pendingFrameState = frameState
            if responseParser.isComplete(dataCount: buffer.count, bodyData: buffer, frameState: frameState) {
                isCompleted = true
                responsePromise.succeed(buffer)
                context.close(promise: nil)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !isCompleted else {
            return
        }

        isCompleted = true
        if buffer.isEmpty {
            responsePromise.fail(HTTPUpstreamConnectorError.incompleteResponse)
        } else {
            responsePromise.succeed(buffer)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !isCompleted else {
            context.close(promise: nil)
            return
        }

        isCompleted = true
        responsePromise.fail(error)
        context.close(promise: nil)
    }
}
