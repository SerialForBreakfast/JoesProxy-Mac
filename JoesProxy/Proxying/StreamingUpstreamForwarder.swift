//
//  StreamingUpstreamForwarder.swift
//  JoesProxy
//
//  Real-time streaming upstream response forwarder and backpressure coordinator.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import os

final class StreamingUpstreamForwarder: ChannelInboundHandler, RemovableChannelHandler {
    /// Owning-event-loop only. An early valid response supersedes a later upload-write failure.
    private(set) var hasCompletedResponse = false
    typealias InboundIn = ByteBuffer

    enum ForwarderState {
        case accumulatingHeaders
        case streamingDirect
        case bufferingForMutation(expectedLength: Int?)
        case transformingCollectionMock
        case completed
    }

    private let request: HTTPProxyRequest
    private let upstreamScheme: SessionScheme
    private let keepConnectionOpen: Bool
    private let downstreamChannel: Channel
    private let downstreamThrottleWriter: NetworkThrottleWriter
    private let responseParser: HTTPResponseParser
    private let timingRecorder: UpstreamWireTimingRecorder
    private let boundedCaptureAccumulator: BoundedCaptureAccumulator
    private let sessionRecorder: ProxySessionRecorder?
    private let sessionIDTask: Task<UUID?, Never>
    private let syntheticRequestID = UUID()
    private let responseSource: CapturedResponseSource
    private let responseSourceDescription: String?
    private let liveResponseRewriteContext: LiveResponseRewriteContext?
    private let liveCollectionMockContext: LiveCollectionMockContext?
    private let liveCollectionTransformationExecutor: LiveCollectionTransformationExecutor
    private let appConfiguration: (any AppConfiguration)?
    private let responseOverrideStore: ResponseOverrideStore?
    private let bookmarkResponseInterceptStore: BookmarkResponseInterceptStore?
    private let transportDiagnostics: CaptureTransportDiagnostics?
    private let onSessionCompleted: @Sendable (CapturedResponse, WireTimingProfile) -> Void
    private let onSessionFailed: @Sendable (Error) -> Void
    private let onConnectionDone: @Sendable (Bool) -> Void
    private let logger = Logger(subsystem: "com.joesproxyapp", category: "StreamingUpstreamForwarder")

    private var state: ForwarderState = .accumulatingHeaders
    private var headerBuffer = Data()
    private var lastDelivery: EventLoopFuture<Void>?
    private var mutationBuffer = Data()
    private let mutationBudget: MutationBufferBudget
    private var mutationReservation: MutationBufferBudget.Reservation?
    private var mutationAdvisory: String?
    private var collectionTransformationTask: Task<Void, Never>?
    private var collectionObservationID: UUID?
    private var upstreamEnded = false
    private var completesCollectionAfterEOF = false
    private var isHandlerRemoved = false
    private var parsedStatusCode: Int = 200
    private var parsedHeaders: [HTTPHeaderField] = []
    private var parsedFrameState: HTTPResponseFrameState?
    private var headerByteCount: Int = 0
    private var totalReceivedBytes: Int = 0
    private var chunkedFraming: HTTPChunkedFramingValidator?
    private var isCompleted: Bool = false
    private var hasReportedCaptureTerminal = false
    private(set) var cancelForDownstreamClosure: (@Sendable () -> Void)?
    private weak var upstreamChannel: Channel?

    init(
        request: HTTPProxyRequest,
        upstreamScheme: SessionScheme,
        keepConnectionOpen: Bool,
        downstreamChannel: Channel,
        downstreamThrottleWriter: NetworkThrottleWriter,
        responseParser: HTTPResponseParser,
        timingRecorder: UpstreamWireTimingRecorder,
        boundedCaptureAccumulator: BoundedCaptureAccumulator = BoundedCaptureAccumulator(),
        mutationBudget: MutationBufferBudget = .shared,
        sessionRecorder: ProxySessionRecorder?,
        sessionIDTask: Task<UUID?, Never>,
        responseSource: CapturedResponseSource = .upstream,
        responseSourceDescription: String? = nil,
        liveResponseRewriteContext: LiveResponseRewriteContext? = nil,
        liveCollectionMockContext: LiveCollectionMockContext? = nil,
        liveCollectionTransformationExecutor: LiveCollectionTransformationExecutor = LiveCollectionTransformationExecutor(),
        appConfiguration: (any AppConfiguration)? = nil,
        responseOverrideStore: ResponseOverrideStore? = nil,
        bookmarkResponseInterceptStore: BookmarkResponseInterceptStore? = nil,
        transportDiagnostics: CaptureTransportDiagnostics? = nil,
        onSessionCompleted: @escaping @Sendable (CapturedResponse, WireTimingProfile) -> Void,
        onSessionFailed: @escaping @Sendable (Error) -> Void,
        onConnectionDone: @escaping @Sendable (Bool) -> Void
    ) {
        self.request = request
        self.upstreamScheme = upstreamScheme
        self.keepConnectionOpen = keepConnectionOpen
        self.downstreamChannel = downstreamChannel
        self.downstreamThrottleWriter = downstreamThrottleWriter
        self.responseParser = responseParser
        self.timingRecorder = timingRecorder
        self.boundedCaptureAccumulator = boundedCaptureAccumulator
        self.mutationBudget = mutationBudget
        self.sessionRecorder = sessionRecorder
        self.sessionIDTask = sessionIDTask
        self.responseSource = responseSource
        self.responseSourceDescription = responseSourceDescription
        self.liveResponseRewriteContext = liveResponseRewriteContext
        self.liveCollectionMockContext = liveCollectionMockContext
        self.liveCollectionTransformationExecutor = liveCollectionTransformationExecutor
        self.appConfiguration = appConfiguration
        self.responseOverrideStore = responseOverrideStore
        self.bookmarkResponseInterceptStore = bookmarkResponseInterceptStore
        self.transportDiagnostics = transportDiagnostics
        self.onSessionCompleted = onSessionCompleted
        self.onSessionFailed = onSessionFailed
        self.onConnectionDone = onConnectionDone
        if let identity = liveCollectionMockContext?.revision?.observation {
            let id = EffectBundleActivationGate.shared.observe(identity: identity, kind: .liveCollection, outcome: "awaitingResponse")
            collectionObservationID = id
            Task {
                EffectBundleActivationGate.shared.completeReceipt(id: id, sessionID: await sessionIDTask.value)
            }
        }
    }

    private func noteCollectionOutcome(_ outcome: LiveCollectionTransformationResult.Outcome) {
        if let collectionObservationID {
            EffectBundleActivationGate.shared.updateOutcome(id: collectionObservationID, outcome: outcome.evidenceCode)
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // One replaceable cancellation belongs to the downstream connection. Registering a
        // closeFuture callback per request would accumulate on a long-lived keep-alive channel.
        let cancellation = NIOLoopBound({ [weak self, weak context] in
            guard let self, let context else { return }
            self.fail(context: context, error: ChannelError.ioOnClosedChannel)
        }, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        cancelForDownstreamClosure = {
            eventLoop.execute { cancellation.value() }
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.upstreamChannel = context.channel
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? TLSUserEvent,
           case .handshakeCompleted(let protocolName) = event {
            timingRecorder.recordTLSHandshake(protocolName: protocolName)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let byteBuffer = unwrapInboundIn(data)
        let byteCount = byteBuffer.readableBytes
        guard byteCount > 0 else { return }

        timingRecorder.recordResponseChunk(byteCount: byteCount)
        transportDiagnostics?.recordUpstreamResponseBytes(byteCount)
        totalReceivedBytes += byteCount

        switch state {
        case .accumulatingHeaders:
            byteBuffer.withUnsafeReadableBytes { ptr in
                if let base = ptr.baseAddress, ptr.count > 0 {
                    headerBuffer.append(base.assumingMemoryBound(to: UInt8.self), count: ptr.count)
                }
            }

            let delimiter = Data("\r\n\r\n".utf8)
            if let delimiterRange = headerBuffer.range(of: delimiter) {
                let headerEndIndex = delimiterRange.upperBound
                self.headerByteCount = headerEndIndex

                guard let frameState = responseParser.parseFrameState(from: headerBuffer, requestMethod: request.method) else {
                    fail(context: context, error: HTTPResponseParserError.invalidStatusLine)
                    return
                }

                self.parsedFrameState = frameState
                if case .chunked = frameState.framing { chunkedFraming = HTTPChunkedFramingValidator() }
                transportDiagnostics?.recordProgress(.responseHead)
                self.parsedStatusCode = frameState.statusCode
                self.parsedHeaders = frameState.headers

                let rawHeaderData = headerBuffer.subdata(in: headerBuffer.startIndex..<headerEndIndex)
                let initialBodyData = headerBuffer.subdata(in: headerEndIndex..<headerBuffer.endIndex)
                headerBuffer.removeAll(keepingCapacity: false)

                guard validateChunkFraming(initialBodyData, context: context) else { return }
                evaluateMutationEligibilityAndTransition(rawHeaders: rawHeaderData, initialBody: initialBodyData, context: context)
            } else if headerBuffer.count > 65_536 {
                fail(context: context, error: HTTPResponseParserError.invalidStatusLine)
            }

        case .streamingDirect:
            guard validateChunkFraming(byteBuffer.readableBytesView, context: context) else { return }
            byteBuffer.withUnsafeReadableBytes { ptr in
                boundedCaptureAccumulator.append(bytes: ptr)
            }

            lastDelivery = downstreamThrottleWriter.relay(byteBuffer, to: downstreamChannel, readingFrom: context.channel, diagnostics: timingRecorder.transport)

            if !downstreamChannel.isWritable {
                _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
            }

            if let frameState = parsedFrameState,
               isResponseComplete(frameState) {
                finishStreaming(context: context)
            }

        case .bufferingForMutation:
            guard validateChunkFraming(byteBuffer.readableBytesView, context: context) else { return }
            guard byteBuffer.readableBytes <= SyntheticInjectionBudget.maxResponseBodyBytes - mutationBuffer.count else {
                tripMutationGuardAndStreamDirect(context: context)
                byteBuffer.withUnsafeReadableBytes { boundedCaptureAccumulator.append(bytes: $0) }
                lastDelivery = downstreamThrottleWriter.relay(byteBuffer, to: downstreamChannel, readingFrom: context.channel, diagnostics: timingRecorder.transport)
                if let frameState = parsedFrameState,
                   isResponseComplete(frameState) {
                    finishStreaming(context: context)
                }
                return
            }
            byteBuffer.withUnsafeReadableBytes { ptr in
                if let base = ptr.baseAddress, ptr.count > 0 {
                    mutationBuffer.append(base.assumingMemoryBound(to: UInt8.self), count: ptr.count)
                }
            }

            if mutationBuffer.count > SyntheticInjectionBudget.maxResponseBodyBytes {
                tripMutationGuardAndStreamDirect(context: context)
            } else if let frameState = parsedFrameState,
                      isResponseComplete(frameState) {
                completeMutationAndDeliver(context: context)
            }

        case .transformingCollectionMock, .completed:
            break
        }
    }

    private func isResponseComplete(_ frame: HTTPResponseFrameState) -> Bool {
        if let chunkedFraming { return chunkedFraming.isComplete }
        return responseParser.isComplete(dataCount: totalReceivedBytes, bodyData: nil, frameState: frame)
    }

    private func validateChunkFraming<C: RandomAccessCollection>(_ bytes: C, context: ChannelHandlerContext) -> Bool where C.Element == UInt8 {
        chunkedFraming?.consume(bytes)
        if chunkedFraming?.isInvalid == true {
            fail(context: context, error: HTTPResponseParserError.invalidChunkFraming)
            return false
        }
        return true
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstreamEnded = true
        if let chunkedFraming, !chunkedFraming.isComplete {
            fail(context: context, error: HTTPResponseParserError.incompleteResponse)
            return
        }
        if let frame = parsedFrameState,
           case .fixedLength(let expectedTotalBytes) = frame.framing,
           totalReceivedBytes < expectedTotalBytes {
            fail(context: context, error: HTTPResponseParserError.incompleteResponse)
            return
        }
        switch state {
        case .accumulatingHeaders:
            fail(context: context, error: HTTPResponseParserError.incompleteResponse)
        case .streamingDirect:
            finishStreaming(context: context)
        case .bufferingForMutation:
            completeMutationAndDeliver(context: context)
        case .transformingCollectionMock, .completed:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(context: context, error: error)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        isHandlerRemoved = true
        // EOF can delimit a complete response. Its bounded worker still owns downstream delivery.
        if case .transformingCollectionMock = state, upstreamEnded, hasCompletedResponse {
            completesCollectionAfterEOF = true
            return
        }
        collectionTransformationTask?.cancel()
        collectionTransformationTask = nil
        if case .transformingCollectionMock = state, let collectionObservationID {
            noteCollectionOutcome(.cancelled)
            EffectBundleActivationGate.shared.completeReceipt(id: collectionObservationID, succeeded: false)
        }
        fail(context: context, error: ChannelError.ioOnClosedChannel, closeChannel: false)
        mutationBuffer = Data()
        headerBuffer = Data()
        mutationReservation = nil
    }

    func notifyDownstreamWritable() {
        guard let upstreamChannel, upstreamChannel.isActive else { return }
        downstreamThrottleWriter.resumeReadsIfDrained(from: upstreamChannel, to: downstreamChannel, diagnostics: timingRecorder.transport)
    }

    private func evaluateMutationEligibilityAndTransition(rawHeaders: Data, initialBody: Data, context: ChannelHandlerContext) {
        noteCollectionOutcome(.ineligibleResponse)
        let isMedia = Self.isMediaContentType(headers: parsedHeaders, path: request.path)
        let canonicalSchemePort = upstreamScheme == .https ? 443 : 80
        let requestURLString = "\(upstreamScheme.rawValue)://\(request.host)"
            + (request.port == canonicalSchemePort ? "" : ":\(request.port)")
            + request.path

        let contentLength = parsedHeaders.first(where: {
            $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame
        }).flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) }

        let bypassReason: SyntheticInjectionReason? = isMedia ? .unsupportedMedia
            : ((contentLength ?? 0) > SyntheticInjectionBudget.maxResponseBodyBytes ? .inputTooLarge : nil)
        let hasSyntheticPlan = SyntheticCollectionInjectionEngine.shared.observeEligibility(
            requestURL: requestURLString, headers: request.headers, bypassReason: bypassReason, requestID: syntheticRequestID)
        attachSyntheticCaptureID()
        let hasLiveRewrite = liveResponseRewriteContext != nil
        let hasLiveCollectionMock = liveCollectionMockContext != nil
        let isCandidateForMutation = !isMedia && (hasLiveRewrite || hasLiveCollectionMock || hasSyntheticPlan)

        if isCandidateForMutation {
            if let contentLength, contentLength > SyntheticInjectionBudget.maxResponseBodyBytes {
                noteCollectionOutcome(.sizeLimit)
                if let mockContext = liveCollectionMockContext {
                    mutationAdvisory = LiveCollectionMockDescriptions.captureSourceDescription(
                        baseDescription: mockContext.sourceDescription,
                        outcome: .sizeLimit
                    )
                }
                startStreamingDirect(rawHeaders: rawHeaders, initialBody: initialBody, context: context)
            } else {
                guard initialBody.count <= SyntheticInjectionBudget.maxResponseBodyBytes else {
                    noteCollectionOutcome(.sizeLimit)
                    SyntheticCollectionInjectionEngine.shared.recordBufferLimit(requestURL: requestURLString,
                        headers: request.headers, requestID: syntheticRequestID)
                    attachSyntheticCaptureID()
                    startStreamingDirect(rawHeaders: rawHeaders, initialBody: initialBody, context: context)
                    return
                }
                guard let reservation = mutationBudget.reserve() else {
                    noteCollectionOutcome(.capacityLimited)
                    if let mockContext = liveCollectionMockContext {
                        mutationAdvisory = LiveCollectionMockDescriptions.captureSourceDescription(
                            baseDescription: mockContext.sourceDescription,
                            outcome: .capacityLimited
                        )
                    }
                    if mutationAdvisory == nil {
                        mutationAdvisory = SyntheticInjectionReason.capacityUnavailable.recovery
                    }
                    _ = SyntheticCollectionInjectionEngine.shared.observeEligibility(requestURL: requestURLString,
                        headers: request.headers, bypassReason: .capacityUnavailable, requestID: syntheticRequestID)
                    attachSyntheticCaptureID()
                    startStreamingDirect(rawHeaders: rawHeaders, initialBody: initialBody, context: context)
                    return
                }
                mutationReservation = reservation
                state = .bufferingForMutation(expectedLength: contentLength)
                mutationBuffer.append(initialBody)

                if mutationBuffer.count > SyntheticInjectionBudget.maxResponseBodyBytes {
                    tripMutationGuardAndStreamDirect(context: context)
                } else if let frameState = parsedFrameState,
                          isResponseComplete(frameState) {
                    completeMutationAndDeliver(context: context)
                }
            }
        } else {
            startStreamingDirect(rawHeaders: rawHeaders, initialBody: initialBody, context: context)
        }
    }

    private func startStreamingDirect(rawHeaders: Data, initialBody: Data, context: ChannelHandlerContext) {
        state = .streamingDirect

        let noCachingPolicy = NoCachingPolicy(
            isGloballyEnabled: appConfiguration?.isNoCachingEnabled ?? false,
            perDomainList: appConfiguration?.noCachingDomains ?? []
        )
        let headerData: Data
        if noCachingPolicy.applies(to: request.host) {
            let finalHeaders = NoCachingPolicy.applyToResponseHeaders(parsedHeaders)
            self.parsedHeaders = finalHeaders
            headerData = makeHeaderData(statusCode: parsedStatusCode, headers: finalHeaders, keepConnectionOpen: streamingKeepConnectionOpen)
        } else {
            headerData = rawHeaders
        }

        var outBuf = downstreamChannel.allocator.buffer(capacity: headerData.count + initialBody.count)
        outBuf.writeBytes(headerData)
        if !initialBody.isEmpty {
            boundedCaptureAccumulator.append(data: initialBody)
            outBuf.writeBytes(initialBody)
        }
        lastDelivery = downstreamThrottleWriter.relay(outBuf, to: downstreamChannel, readingFrom: context.channel, diagnostics: timingRecorder.transport)

        if let frameState = parsedFrameState,
           isResponseComplete(frameState) {
            finishStreaming(context: context)
        }
    }

    private func tripMutationGuardAndStreamDirect(context: ChannelHandlerContext) {
        noteCollectionOutcome(.sizeLimit)
        let canonicalPort = upstreamScheme == .https ? 443 : 80
        let requestURL = "\(upstreamScheme.rawValue)://\(request.host)"
            + (request.port == canonicalPort ? "" : ":\(request.port)") + request.path
        SyntheticCollectionInjectionEngine.shared.recordBufferLimit(requestURL: requestURL, headers: request.headers, requestID: syntheticRequestID)
        attachSyntheticCaptureID()
        logger.warning("Trip mutation guard: response exceeded \(SyntheticInjectionBudget.maxResponseBodyBytes) bytes. Streaming unmodified.")
        state = .streamingDirect

        let noCachingPolicy = NoCachingPolicy(
            isGloballyEnabled: appConfiguration?.isNoCachingEnabled ?? false,
            perDomainList: appConfiguration?.noCachingDomains ?? []
        )
        let finalHeaders: [HTTPHeaderField]
        if noCachingPolicy.applies(to: request.host) {
            finalHeaders = NoCachingPolicy.applyToResponseHeaders(parsedHeaders)
        } else {
            finalHeaders = parsedHeaders
        }
        self.parsedHeaders = finalHeaders

        let headerData = makeHeaderData(statusCode: parsedStatusCode, headers: finalHeaders, keepConnectionOpen: streamingKeepConnectionOpen)
        var outHeaderBuf = downstreamChannel.allocator.buffer(capacity: headerData.count)
        outHeaderBuf.writeBytes(headerData)
        lastDelivery = downstreamThrottleWriter.relay(outHeaderBuf, to: downstreamChannel, readingFrom: context.channel, diagnostics: timingRecorder.transport)

        if !mutationBuffer.isEmpty {
            boundedCaptureAccumulator.append(data: mutationBuffer)
            var outBodyBuf = downstreamChannel.allocator.buffer(capacity: mutationBuffer.count)
            outBodyBuf.writeBytes(mutationBuffer)
            lastDelivery = downstreamThrottleWriter.relay(outBodyBuf, to: downstreamChannel, readingFrom: context.channel, diagnostics: timingRecorder.transport)
            mutationBuffer.removeAll(keepingCapacity: false)
        }
        if let lastDelivery { handoffMutationReservation(to: lastDelivery) }
    }

    private func completeMutationAndDeliver(context: ChannelHandlerContext) {
        guard !isCompleted else { return }
        transportDiagnostics?.recordProgress(.responseComplete)
        hasCompletedResponse = true
        isCompleted = true
        state = .completed

        var responseBody = mutationBuffer
        mutationBuffer = Data()
        var responseHeaders = parsedHeaders
        var captureSource = responseSource
        var captureSourceDescription = responseSourceDescription

        if let liveContext = liveResponseRewriteContext {
            let tracker = LiveTransformationActivationTracker.shared
            if tracker.isExpired(ruleID: liveContext.ruleID) {
                let ruleID = liveContext.ruleID
                if let store = responseOverrideStore {
                    Task { try? await store.setEnabled(false, for: ruleID) }
                }
            } else if tracker.isWithinBudget(ruleID: liveContext.ruleID) {
                let transformResult = LiveResponseTransformation.transform(
                    requestMethod: request.method,
                    statusCode: parsedStatusCode,
                    headers: parsedHeaders,
                    bodyData: responseBody,
                    mutations: LiveResponseTransformation.jsonMutations(from: liveContext.rewrites),
                    expectedSchemaFingerprint: liveContext.expectedSchemaFingerprint
                )
                captureSource = .liveResponseRewrite
                captureSourceDescription = LiveResponseRewriteDescriptions.captureSourceDescription(
                    baseDescription: liveContext.sourceDescription,
                    result: transformResult
                )
                if transformResult.wasTransformed {
                    responseBody = transformResult.bodyData
                    responseHeaders = transformResult.headers
                    tracker.recordTransformed(ruleID: liveContext.ruleID)
                }
            }
        }

        // At most one of `liveResponseRewriteContext`/`liveCollectionMockContext` is ever set per
        // request. Collection work must leave the owning event loop before JSON/gzip processing;
        // the reservation obtained before buffering remains held until this worker and its
        // downstream write have both reached a terminal state.
        if let mockContext = liveCollectionMockContext {
            noteCollectionOutcome(.inactiveRevision)
            let tracker = LiveTransformationActivationTracker.shared
            if tracker.isExpired(ruleID: mockContext.ruleID) {
                let ruleID = mockContext.ruleID
                if let store = responseOverrideStore {
                    Task { try? await store.setEnabled(false, for: ruleID) }
                }
                captureSource = .liveResponseRewrite
                captureSourceDescription = LiveCollectionMockDescriptions.captureSourceDescription(
                    baseDescription: mockContext.sourceDescription,
                    outcome: .inactiveRevision
                )
            } else if !tracker.isWithinBudget(ruleID: mockContext.ruleID) {
                captureSource = .liveResponseRewrite
                captureSourceDescription = LiveCollectionMockDescriptions.captureSourceDescription(
                    baseDescription: mockContext.sourceDescription,
                    outcome: .inactiveRevision
                )
            } else {
                let revision = mockContext.revision
                    ?? liveCollectionTransformationExecutor.begin(effectID: mockContext.ruleID, plan: mockContext.plan)
                guard let revision else {
                    captureSource = .liveResponseRewrite
                    captureSourceDescription = LiveCollectionMockDescriptions.captureSourceDescription(
                        baseDescription: mockContext.sourceDescription,
                        outcome: .inactiveRevision
                    )
                    finishMutationAndDeliver(
                        context: context,
                        responseBody: responseBody,
                        responseHeaders: responseHeaders,
                        captureSource: captureSource,
                        captureSourceDescription: captureSourceDescription
                    )
                    return
                }
                state = .transformingCollectionMock
                let method = request.method
                let statusCode = parsedStatusCode
                let headers = responseHeaders
                let originalBody = responseBody
                let eventLoop = context.eventLoop
                let reservation = mutationReservation
                collectionTransformationTask = Task { @MainActor [self] in
                    let result = await self.liveCollectionTransformationExecutor.transform(
                        revision: revision,
                        method: method,
                        statusCode: statusCode,
                        headers: headers,
                        body: originalBody
                    )
                    eventLoop.execute { [self, reservation] in
                        defer { withExtendedLifetime(reservation) {} }
                        finishCollectionTransformation(
                            result,
                            mockContext: mockContext,
                            revision: revision,
                            originalBody: originalBody,
                            originalHeaders: headers,
                            context: context
                        )
                    }
                }
                return
            }
        }

        finishMutationAndDeliver(
            context: context,
            responseBody: responseBody,
            responseHeaders: responseHeaders,
            captureSource: captureSource,
            captureSourceDescription: captureSourceDescription
        )
    }

    private func finishCollectionTransformation(
        _ result: LiveCollectionTransformationResult,
        mockContext: LiveCollectionMockContext,
        revision: LiveCollectionTransformationExecutor.Revision,
        originalBody: Data,
        originalHeaders: [HTTPHeaderField],
        context: ChannelHandlerContext
    ) {
        collectionTransformationTask = nil
        guard !hasReportedCaptureTerminal, !isHandlerRemoved || completesCollectionAfterEOF else { return }
        state = .completed

        let tracker = LiveTransformationActivationTracker.shared
        let isActive = liveCollectionTransformationExecutor.isCurrent(revision)
        let stillWithinBudget = !tracker.isExpired(ruleID: mockContext.ruleID)
            && tracker.isWithinBudget(ruleID: mockContext.ruleID)
        let committedResult: LiveCollectionTransformationResult
        if !isActive || !stillWithinBudget {
            committedResult = .init(body: originalBody, headers: originalHeaders, outcome: .inactiveRevision)
            if tracker.isExpired(ruleID: mockContext.ruleID), let store = responseOverrideStore {
                Task { try? await store.setEnabled(false, for: mockContext.ruleID) }
            }
        } else {
            committedResult = result
        }

        var body = originalBody
        var headers = originalHeaders
        var deliveredOutcome = committedResult.outcome
        if case .applied = committedResult.outcome {
            if tracker.recordTransformedIfWithinBudget(ruleID: mockContext.ruleID) {
                body = committedResult.body
                headers = committedResult.headers
            } else {
                deliveredOutcome = .inactiveRevision
            }
        }
        noteCollectionOutcome(deliveredOutcome)
        finishMutationAndDeliver(
            context: context,
            responseBody: body,
            responseHeaders: headers,
            captureSource: .liveResponseRewrite,
            captureSourceDescription: LiveCollectionMockDescriptions.captureSourceDescription(
                baseDescription: mockContext.sourceDescription,
                outcome: deliveredOutcome
            )
        )
    }

    private func finishMutationAndDeliver(
        context: ChannelHandlerContext,
        responseBody initialResponseBody: Data,
        responseHeaders initialResponseHeaders: [HTTPHeaderField],
        captureSource initialCaptureSource: CapturedResponseSource,
        captureSourceDescription initialCaptureSourceDescription: String?
    ) {
        guard !hasReportedCaptureTerminal else { return }
        var responseBody = initialResponseBody
        var responseHeaders = initialResponseHeaders
        var captureSource = initialCaptureSource
        var captureSourceDescription = initialCaptureSourceDescription
        let canonicalSchemePort = upstreamScheme == .https ? 443 : 80
        let requestURLString = "\(upstreamScheme.rawValue)://\(request.host)"
            + (request.port == canonicalSchemePort ? "" : ":\(request.port)")
            + request.path
        if let injected = SyntheticCollectionInjectionEngine.shared.processResponse(
            responseData: responseBody,
            requestURL: requestURLString,
            requestHeaders: request.headers,
            requestID: syntheticRequestID
        ) {
            responseBody = injected.transformedData
            captureSource = .liveResponseRewrite
            captureSourceDescription = "Synthetic collection injection · plan \(injected.result.planID) · request \(syntheticRequestID). Upstream response modified; delivery is recorded separately."
        }

        boundedCaptureAccumulator.append(data: responseBody)
        let capturedBody = boundedCaptureAccumulator.takeFinalizedBody()

        let noCachingPolicy = NoCachingPolicy(
            isGloballyEnabled: appConfiguration?.isNoCachingEnabled ?? false,
            perDomainList: appConfiguration?.noCachingDomains ?? []
        )
        let finalHeaders: [HTTPHeaderField]
        if noCachingPolicy.applies(to: request.host) {
            finalHeaders = NoCachingPolicy.applyToResponseHeaders(responseHeaders)
        } else {
            finalHeaders = responseHeaders
        }

        let wireData = makeFullResponseData(
            statusCode: parsedStatusCode,
            headers: finalHeaders,
            body: responseBody,
            keepConnectionOpen: keepConnectionOpen
        )

        let capturedResponse = CapturedResponse(
            statusCode: parsedStatusCode,
            headers: finalHeaders,
            bodyData: capturedBody.data,
            bodySize: capturedBody.size,
            source: captureSource,
            sourceDescription: captureSourceDescription,
            bodyTruncated: capturedBody.truncated
        )

        let wireProfile = timingRecorder.snapshot(
            headerByteCount: headerByteCount,
            bodyByteCount: responseBody.count
        )

        hasReportedCaptureTerminal = true

        var outBuf = downstreamChannel.allocator.buffer(capacity: wireData.count)
        outBuf.writeBytes(wireData)
        let receiptRequestID = syntheticRequestID
        attachSyntheticCaptureID()
        let diagnostics = timingRecorder.transport
        diagnostics.submitted(bytes: wireData.count)
        let delivery = downstreamThrottleWriter.writeAndFlush(outBuf, to: downstreamChannel)
        if let collectionObservationID { EffectBundleActivationGate.shared.trackDelivery(delivery, receiptID: collectionObservationID) }
        handoffMutationReservation(to: delivery)
        delivery.whenComplete { result in
            let succeeded: Bool
            switch result {
            case .success: succeeded = true
            case .failure: succeeded = false
            }
            diagnostics.completed(bytes: wireData.count, succeeded: succeeded)
            var deliveredProfile = wireProfile
            deliveredProfile.transport = diagnostics.snapshot()
            self.onSessionCompleted(capturedResponse, deliveredProfile)
            SyntheticCollectionInjectionEngine.shared.updateReceipt(requestID: receiptRequestID, writeSucceeded: succeeded)
            self.onConnectionDone(self.keepConnectionOpen)
        }

        if !isHandlerRemoved { context.close(promise: nil) }
    }

    /// Buffered bytes remain owned by downstream writes after the upstream handler is removed.
    /// Transfer the allowance to their terminal promise rather than admitting another full body.
    private func handoffMutationReservation(to delivery: EventLoopFuture<Void>) {
        let reservation = mutationReservation
        mutationReservation = nil
        delivery.whenComplete { _ in withExtendedLifetime(reservation) {} }
    }

    private func attachSyntheticCaptureID() {
        let requestID = syntheticRequestID
        guard SyntheticCollectionInjectionEngine.shared.hasReceipt(requestID: requestID) else { return }
        let captureIDTask = sessionIDTask
        Task {
            let sessionID = await captureIDTask.value
            SyntheticCollectionInjectionEngine.shared.updateReceipt(requestID: requestID, sessionID: sessionID)
        }
    }

    // Unmodified EOF-framed bodies must end with downstream EOF after queued writes drain.
    // Buffered mutations produce a new Content-Length and can retain the original reuse policy.
    private var streamingKeepConnectionOpen: Bool {
        if case .closeDelimited = parsedFrameState?.framing { return false }
        return keepConnectionOpen
    }

    private func finishStreaming(context: ChannelHandlerContext) {
        guard !isCompleted else { return }
        transportDiagnostics?.recordProgress(.responseComplete)
        hasCompletedResponse = true
        isCompleted = true
        state = .completed

        let capturedBody = boundedCaptureAccumulator.takeFinalizedBody()
        let capturedResponse = CapturedResponse(
            statusCode: parsedStatusCode,
            headers: parsedHeaders,
            bodyData: capturedBody.data,
            bodySize: capturedBody.size,
            source: responseSource,
            sourceDescription: mutationAdvisory ?? responseSourceDescription,
            bodyTruncated: capturedBody.truncated
        )

        let wireProfile = timingRecorder.snapshot(
            headerByteCount: headerByteCount,
            bodyByteCount: capturedBody.size ?? max(0, totalReceivedBytes - headerByteCount)
        )

        hasReportedCaptureTerminal = true

        let drainFuture = lastDelivery ?? downstreamChannel.eventLoop.makeSucceededFuture(())
        let diagnostics = timingRecorder.transport
        if let collectionObservationID { EffectBundleActivationGate.shared.trackDelivery(drainFuture, receiptID: collectionObservationID) }
        drainFuture.whenComplete { _ in
            var deliveredProfile = wireProfile
            deliveredProfile.transport = diagnostics.snapshot()
            self.onSessionCompleted(capturedResponse, deliveredProfile)
            self.onConnectionDone(self.streamingKeepConnectionOpen)
        }
        context.close(promise: nil)
    }

    private func fail(context: ChannelHandlerContext, error: Error, closeChannel: Bool = true) {
        guard !hasReportedCaptureTerminal else { return }
        hasReportedCaptureTerminal = true
        timingRecorder.transport.failed(error: error)
        if let collectionObservationID { EffectBundleActivationGate.shared.completeReceipt(id: collectionObservationID, succeeded: false) }
        transportDiagnostics?.recordProgress(.responseFailed)
        isCompleted = true
        state = .completed
        collectionTransformationTask?.cancel()
        collectionTransformationTask = nil
        mutationBuffer = Data()
        mutationReservation = nil

        _ = boundedCaptureAccumulator.takeFinalizedBody()
        onSessionFailed(error)
        onConnectionDone(false)
        if closeChannel { context.close(promise: nil) }
    }

    private func makeHeaderData(
        statusCode: Int,
        headers: [HTTPHeaderField],
        keepConnectionOpen: Bool
    ) -> Data {
        var resolvedHeaders = headers.filter { header in
            let name = header.name.lowercased()
            return name != "connection"
        }
        resolvedHeaders.append(
            HTTPHeaderField(name: "Connection", value: keepConnectionOpen ? "keep-alive" : "close")
        )

        let reason = reasonPhrase(for: statusCode)
        var responseHead = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        for header in resolvedHeaders {
            responseHead += "\(header.name): \(header.value)\r\n"
        }
        responseHead += "\r\n"
        return Data(responseHead.utf8)
    }

    private func makeFullResponseData(
        statusCode: Int,
        headers: [HTTPHeaderField],
        body: Data,
        keepConnectionOpen: Bool
    ) -> Data {
        var resolvedHeaders = headers.filter { header in
            let name = header.name.lowercased()
            return name != "content-length" && name != "connection" && name != "transfer-encoding"
        }
        resolvedHeaders.append(HTTPHeaderField(name: "Content-Length", value: String(body.count)))
        resolvedHeaders.append(
            HTTPHeaderField(name: "Connection", value: keepConnectionOpen ? "keep-alive" : "close")
        )

        let reason = reasonPhrase(for: statusCode)
        var responseHead = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        for header in resolvedHeaders {
            responseHead += "\(header.name): \(header.value)\r\n"
        }
        responseHead += "\r\n"
        var data = Data(responseHead.utf8)
        data.append(body)
        return data
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default:
            let phrase = HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
            return phrase.isEmpty ? "OK" : phrase
        }
    }

    private static func isMediaContentType(headers: [HTTPHeaderField], path: String) -> Bool {
        let contentType = headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased() ?? ""

        if contentType.hasPrefix("video/") ||
           contentType.hasPrefix("audio/") ||
           contentType.hasPrefix("image/") ||
           contentType.contains("octet-stream") ||
           contentType.contains("application/mp4") ||
           contentType.contains("application/vnd.apple.mpegurl") ||
           contentType.contains("application/dash+xml") {
            return true
        }

        let lowerPath = path.lowercased()
        let mediaExtensions = [
            ".mp4", ".ts", ".m4s", ".m4v", ".mov", ".m4a", ".aac", ".mp3",
            ".flac", ".webm", ".m3u8", ".mpd", ".png", ".jpg", ".jpeg",
            ".gif", ".webp", ".bin", ".iso", ".dmg", ".zip", ".tar", ".gz"
        ]
        return mediaExtensions.contains(where: { lowerPath.hasSuffix($0) || lowerPath.contains($0 + "?") })
    }
}
