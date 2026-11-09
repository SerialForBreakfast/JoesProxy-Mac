//
//  StreamingUpstreamForwarderTests.swift
//  JoesProxyTests
//
//  Unit tests for StreamingUpstreamForwarder: immediate TTFB header delivery,
//  chunk streaming, bounded capture accumulation, and 5 MB mutation guard trip.
//

import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOTLS
import XCTest
@testable import JoesProxy

private final class ReceiptWriteFailureHandler: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.ioOnClosedChannel)
    }
}

private actor ForwarderWorkerGate {
    private var entered = false
    private var entryObserver: CheckedContinuation<Void, Never>?
    private var worker: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        entryObserver?.resume()
        entryObserver = nil
        await withCheckedContinuation { worker = $0 }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryObserver = $0 }
    }

    func release() {
        worker?.resume()
        worker = nil
    }
}

private final class StalledMutationWriteHandler: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    private var promises: [EventLoopPromise<Void>] = []
    private var buffers: [ByteBuffer] = []
    var pendingWriteCount: Int { promises.count }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        buffers.append(unwrapOutboundIn(data))
        if let promise { promises.append(promise) }
    }

    func complete(_ result: Result<Void, Error>) {
        let pending = promises
        promises = []
        buffers = []
        pending.forEach { $0.completeWith(result) }
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        complete(.failure(ChannelError.ioOnClosedChannel))
        context.close(mode: mode, promise: promise)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        complete(.failure(ChannelError.ioOnClosedChannel))
    }
}

final class StreamingUpstreamForwarderTests: XCTestCase {
    func testFragmentedEOFWithCacheRewriteWaitsForDeliveryAndReportsFailure() throws {
        for rewriteHeaders in [false, true] {
            for succeeded in [false, true] {
                let loop = EmbeddedEventLoop()
                let sink = StalledMutationWriteHandler()
                let downstream = EmbeddedChannel(handler: sink, loop: loop)
                let upstream = EmbeddedChannel(loop: loop)
                let suite = "EOFCache-\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                let config = UserDefaultsAppConfiguration(userDefaults: defaults)
                config.isNoCachingEnabled = rewriteHeaders
                defer {
                    _ = try? upstream.finish(acceptAlreadyClosed: true)
                    _ = try? downstream.finish(acceptAlreadyClosed: true)
                    defaults.removePersistentDomain(forName: suite)
                }
                let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
                    host: "media.example.test", port: 443, path: "/segment", headers: [], body: Data())
                var completions = 0
                var connectionResults: [Bool] = []
                var result: WireTimingProfile?
                let forwarder = StreamingUpstreamForwarder(request: request, upstreamScheme: .https,
                    keepConnectionOpen: true, downstreamChannel: downstream,
                    downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
                    responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
                    boundedCaptureAccumulator: BoundedCaptureAccumulator(limit: 1024), sessionRecorder: nil,
                    sessionIDTask: Task { nil }, appConfiguration: config,
                    onSessionCompleted: { response, profile in
                        XCTAssertEqual(response.bodyData, Data("abc".utf8))
                        completions += 1; result = profile
                    }, onSessionFailed: { error in XCTFail("Upstream completed: \(error)") },
                    onConnectionDone: { connectionResults.append($0) })
                try upstream.pipeline.addHandler(forwarder).wait()
                for fragment in ["HTTP/1.1 200 OK\r\nCache-Control: max-age=60\r", "\n\r", "\na", "bc"] {
                    var input = upstream.allocator.buffer(capacity: fragment.utf8.count)
                    input.writeString(fragment)
                    try upstream.writeInbound(input)
                    loop.run()
                    XCTAssertEqual(completions, 0)
                }
                try upstream.close().wait()
                loop.run()
                XCTAssertTrue(connectionResults.isEmpty)
                XCTAssertGreaterThan(sink.pendingWriteCount, 0)
                sink.complete(succeeded ? .success(()) : .failure(ChannelError.ioOnClosedChannel))
                loop.run()
                XCTAssertEqual(completions, 1)
                XCTAssertEqual(connectionResults, [false])
                XCTAssertEqual(result?.transport?.pendingWrites, 0)
                XCTAssertEqual(result?.transport?.deliveryState, succeeded ? "writes_completed" : "write_failed")
                upstream.pipeline.fireChannelInactive()
                loop.run()
                XCTAssertEqual(completions, 1, "Late teardown must not duplicate completion")
                XCTAssertEqual(connectionResults, [false])
            }
        }
    }

    func testCloseDelimitedResponseClosesDownstreamOnlyAfterDeliveryDrains() throws {
        for closeDelimited in [true, false] {
            let loop = EmbeddedEventLoop()
            let downstream = EmbeddedChannel(loop: loop)
            let upstream = EmbeddedChannel(loop: loop)
            defer { _ = try? upstream.finish(acceptAlreadyClosed: true); _ = try? downstream.finish(acceptAlreadyClosed: true) }
            let stalled = StalledMutationWriteHandler()
            try downstream.pipeline.addHandler(stalled).wait()
            var completions = 0
            var keepOpen: Bool?
            let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
                host: "media.example.test", port: 443, path: "/eof", headers: [], body: Data())
            let forwarder = StreamingUpstreamForwarder(request: request, upstreamScheme: .https,
                keepConnectionOpen: true, downstreamChannel: downstream,
                downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
                responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
                boundedCaptureAccumulator: BoundedCaptureAccumulator(limit: 1024), sessionRecorder: nil,
                sessionIDTask: Task { nil }, onSessionCompleted: { response, _ in
                    XCTAssertEqual(response.bodyData, Data("abc".utf8)); completions += 1
                }, onSessionFailed: { error in XCTFail("Unexpected failure: \(error)") },
                onConnectionDone: { keepOpen = $0 })
            try upstream.pipeline.addHandler(forwarder).wait()
            var input = upstream.allocator.buffer(capacity: 128)
            input.writeString("HTTP/1.1 200 OK\r\n" + (closeDelimited ? "" : "Content-Length: 3\r\n") + "\r\nabc")
            try upstream.writeInbound(input)
            if closeDelimited { try upstream.close().wait() }
            loop.run()
            XCTAssertGreaterThan(stalled.pendingWriteCount, 0)
            XCTAssertNil(keepOpen, "Upstream EOF must not close before downstream writes finish")
            XCTAssertEqual(completions, 0)
            stalled.complete(.success(()))
            loop.run()
            XCTAssertEqual(keepOpen, !closeDelimited)
            XCTAssertEqual(completions, 1)
        }
    }

    func testChunkedFailureAndIdleCancellationAreTerminalExactlyOnce() throws {
        for body in ["4\r\nte", "X\r\n", ""] {
            let loop = EmbeddedEventLoop()
            let downstream = EmbeddedChannel(loop: loop)
            let upstream = EmbeddedChannel(loop: loop)
            defer { _ = try? upstream.finish(acceptAlreadyClosed: true); _ = try? downstream.finish(acceptAlreadyClosed: true) }
            let timing = UpstreamWireTimingRecorder(startedAt: Date())
            var failed = 0
            var connectionClosures = 0
            let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
                host: "media.example.test", port: 80, path: "/chunked", headers: [], body: Data())
            let forwarder = StreamingUpstreamForwarder(request: request, upstreamScheme: .http,
                keepConnectionOpen: true, downstreamChannel: downstream,
                downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
                responseParser: HTTPResponseParser(), timingRecorder: timing,
                boundedCaptureAccumulator: BoundedCaptureAccumulator(limit: 0), sessionRecorder: nil,
                sessionIDTask: Task { nil }, onSessionCompleted: { _, _ in XCTFail("Incomplete input must not succeed") },
                onSessionFailed: { _ in failed += 1 }, onConnectionDone: { keep in
                    XCTAssertFalse(keep); connectionClosures += 1
                })
            try upstream.pipeline.addHandler(forwarder).wait()
            var wire = upstream.allocator.buffer(capacity: 128)
            wire.writeString("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + body)
            try upstream.writeInbound(wire)
            if body.isEmpty {
                XCTAssertEqual(failed, 0, "Idle is not itself a timeout or a deadlock")
                forwarder.cancelForDownstreamClosure?()
                loop.run()
            } else if body != "X\r\n" { try upstream.close().wait() }
            loop.run()
            forwarder.cancelForDownstreamClosure?()
            loop.run()
            XCTAssertEqual(failed, 1)
            XCTAssertEqual(connectionClosures, 1)
            if !body.isEmpty {
                XCTAssertEqual(timing.transport.snapshot().failureReason,
                    body == "X\r\n" ? "upstream_chunk_framing_invalid" : "upstream_response_incomplete")
            }
        }
    }


    func testPrematureFixedLengthEOFFailsAndClosesReusableDownstream() throws {
        let loop = EmbeddedEventLoop()
        let downstream = EmbeddedChannel(loop: loop)
        let upstream = EmbeddedChannel(loop: loop)
        defer {
            _ = try? upstream.finish(acceptAlreadyClosed: true)
            _ = try? downstream.finish(acceptAlreadyClosed: true)
        }
        var failures = 0
        var keepOpen: Bool?
        let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
            host: "media.example.test", port: 443, path: "/segment", headers: [], body: Data())
        let forwarder = StreamingUpstreamForwarder(request: request, upstreamScheme: .https,
            keepConnectionOpen: true, downstreamChannel: downstream,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
            boundedCaptureAccumulator: BoundedCaptureAccumulator(limit: 1024), sessionRecorder: nil,
            sessionIDTask: Task { nil },
            onSessionCompleted: { _, _ in XCTFail("Premature EOF is not successful completion") },
            onSessionFailed: { _ in failures += 1 }, onConnectionDone: { keepOpen = $0 })
        try upstream.pipeline.addHandler(forwarder).wait()
        var input = upstream.allocator.buffer(capacity: 128)
        input.writeString("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort")
        try upstream.writeInbound(input)
        try upstream.close().wait()
        loop.run()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(keepOpen, false)
    }

    func testTransportEvidenceDistinguishesUpstreamEndFromStalledOrFailedDelivery() throws {
        for succeeded in [true, false] {
            let loop = EmbeddedEventLoop()
            let sink = StalledMutationWriteHandler()
            let downstream = EmbeddedChannel(handler: sink, loop: loop)
            let upstream = EmbeddedChannel(loop: loop)
            defer {
                _ = try? upstream.finish(acceptAlreadyClosed: true)
                _ = try? downstream.finish(acceptAlreadyClosed: true)
            }
            let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
                host: "media.example.test", port: 443, path: "/segment", headers: [], body: Data())
            let recorder = UpstreamWireTimingRecorder(startedAt: Date())
            var completed: WireTimingProfile?
            let forwarder = StreamingUpstreamForwarder(request: request, upstreamScheme: .https,
                keepConnectionOpen: true, downstreamChannel: downstream,
                downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
                responseParser: HTTPResponseParser(), timingRecorder: recorder,
                boundedCaptureAccumulator: BoundedCaptureAccumulator(limit: 0), sessionRecorder: nil,
                sessionIDTask: Task { nil }, onSessionCompleted: { _, profile in completed = profile },
                onSessionFailed: { _ in XCTFail("Completed upstream must keep its delivery evidence") }, onConnectionDone: { _ in })
            try upstream.pipeline.addHandler(forwarder).wait()
            upstream.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil))
            var input = upstream.allocator.buffer(capacity: 128)
            input.writeString("HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nContent-Range: bytes 0-3/4\r\n\r\ntest")
            try upstream.writeInbound(input)
            loop.run()
            XCTAssertNil(completed, "Capture terminal must not claim downstream completion early")
            XCTAssertGreaterThan(recorder.transport.snapshot().pendingWrites, 0)
            XCTAssertNotNil(recorder.profile.tlsHandshakeCompletedAt)
            sink.complete(succeeded ? .success(()) : .failure(ChannelError.ioOnClosedChannel))
            loop.run()
            let evidence = try XCTUnwrap(completed?.transport)
            XCTAssertEqual(evidence.pendingWrites, 0)
            XCTAssertEqual(evidence.deliveryState, succeeded ? "writes_completed" : "write_failed")
            XCTAssertNotNil(completed?.responseCompletedAt)
            XCTAssertNotNil(evidence.tlsReadySeconds)
        }
    }

    private var group: MultiThreadedEventLoopGroup!

    func testMetadataOnlyStreamingForwardsEveryByteWithoutRetainingBody() throws {
        let loop = EmbeddedEventLoop()
        let downstream = EmbeddedChannel(loop: loop)
        let upstream = EmbeddedChannel(loop: loop)
        defer {
            _ = try? upstream.finish(acceptAlreadyClosed: true)
            _ = try? downstream.finish(acceptAlreadyClosed: true)
        }
        let collector = BoundedCaptureAccumulator(limit: 0, countWithoutBody: true)
        var captured: CapturedResponse?
        let forwarder = StreamingUpstreamForwarder(
            request: HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
                host: "example.test", port: 80, path: "/media", headers: [], body: Data()),
            upstreamScheme: .http, keepConnectionOpen: true, downstreamChannel: downstream,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
            boundedCaptureAccumulator: collector, sessionRecorder: nil, sessionIDTask: Task { nil },
            onSessionCompleted: { response, _ in captured = response },
            onSessionFailed: { error in XCTFail("Unexpected failure: \(error)") }, onConnectionDone: { _ in })
        try upstream.pipeline.addHandler(forwarder).wait()
        var headers = upstream.allocator.buffer(capacity: 128)
        headers.writeString("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: 6553600\r\n\r\n")
        try upstream.writeInbound(headers)
        loop.run()
        XCTAssertNotNil(try downstream.readOutbound(as: ByteBuffer.self))
        for index in 0..<100 {
            let bytes = Array(repeating: UInt8(index), count: 65_536)
            var chunk = upstream.allocator.buffer(capacity: bytes.count)
            chunk.writeBytes(bytes)
            try upstream.writeInbound(chunk)
            loop.run()
            var received: [UInt8] = []
            while var output = try downstream.readOutbound(as: ByteBuffer.self) {
                received += output.readBytes(length: output.readableBytes) ?? []
            }
            XCTAssertEqual(received, bytes)
            XCTAssertNil(collector.finalize().data)
        }
        XCTAssertEqual(captured?.bodySize, 6_553_600)
        XCTAssertEqual(captured?.bodyTruncated, true)
        XCTAssertNil(captured?.bodyData)
        XCTAssertNil(collector.finalize().size)
    }

    func testMutationAllowanceRemainsReservedUntilDownstreamSuccessOrFailure() throws {
        try assertMutationAllowanceFollowsDelivery(closeDownstream: false)
    }

    func testMutationAllowanceReleasesWhenStalledDownstreamCloses() throws {
        try assertMutationAllowanceFollowsDelivery(closeDownstream: true)
    }

    func testOversizedFallbackKeepsBufferedAllowanceUntilDeliveryDrains() throws {
        let budget = MutationBufferBudget(limit: 1)
        let loop = EmbeddedEventLoop()
        let downstream = EmbeddedChannel(loop: loop)
        let upstream = EmbeddedChannel(loop: loop)
        let stall = StalledMutationWriteHandler()
        defer {
            _ = try? upstream.finish(acceptAlreadyClosed: true)
            _ = try? downstream.finish(acceptAlreadyClosed: true)
        }
        try downstream.pipeline.addHandler(stall).wait()
        let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
            host: "example.test", port: 80, path: "/oversized-fallback", headers: [], body: Data())
        let context = LiveResponseRewriteContext(ruleID: UUID(),
            rewrites: [BookmarkResponseFieldRewrite(jsonPath: "$.title", overrideValue: .string("test"))],
            sourceDescription: "Synthetic fallback test", expectedSchemaFingerprint: nil)
        let forwarder = StreamingUpstreamForwarder(request: request, upstreamScheme: .http,
            keepConnectionOpen: true, downstreamChannel: downstream,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
            boundedCaptureAccumulator: BoundedCaptureAccumulator(limit: 128), mutationBudget: budget,
            sessionRecorder: nil, sessionIDTask: Task { nil }, liveResponseRewriteContext: context,
            onSessionCompleted: { _, _ in }, onSessionFailed: { _ in XCTFail("Oversize must fail open") },
            onConnectionDone: { _ in })
        try upstream.pipeline.addHandler(forwarder).wait()
        var headers = upstream.allocator.buffer(capacity: 128)
        headers.writeString("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n")
        try upstream.writeInbound(headers)
        var body = upstream.allocator.buffer(capacity: SyntheticInjectionBudget.maxResponseBodyBytes)
        body.writeRepeatingByte(0x20, count: SyntheticInjectionBudget.maxResponseBodyBytes)
        try upstream.writeInbound(body)
        XCTAssertEqual(budget.activeCount, 1)
        var excess = upstream.allocator.buffer(capacity: 1)
        excess.writeInteger(UInt8(0x20))
        try upstream.writeInbound(excess)
        loop.run()
        XCTAssertEqual(budget.activeCount, 1, "Buffered prefix remains owned by stalled passthrough writes")
        XCTAssertGreaterThan(stall.pendingWriteCount, 0)
        try upstream.close().wait()
        loop.run()
        XCTAssertEqual(budget.activeCount, 1, "Upstream teardown cannot free the downstream allowance")
        stall.complete(.success(()))
        loop.run()
        XCTAssertEqual(budget.activeCount, 0)
    }

    private func assertMutationAllowanceFollowsDelivery(closeDownstream: Bool) throws {
        let engine = SyntheticCollectionInjectionEngine.shared
        let plan = SyntheticCollectionInjectionPlan(name: "Stalled delivery", urlPattern: "/stalled-mutation",
            collectionKeypath: "$.items", boundAssetKind: nil, clientScope: .allClients)
        engine.registerPlan(plan)
        defer { engine.removePlan(id: plan.id) }
        let budget = MutationBufferBudget(limit: 2)
        let loop = EmbeddedEventLoop()
        var upstreams: [EmbeddedChannel] = []
        var downstreams: [EmbeddedChannel] = []
        var stalls: [StalledMutationWriteHandler] = []
        defer {
            for channel in upstreams + downstreams { _ = try? channel.finish(acceptAlreadyClosed: true) }
        }
        let body = #"{"items":[{"id":"original"}]}"#
        let wire = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nETag: original\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        for index in 0..<3 {
            let downstream = EmbeddedChannel(loop: loop)
            let upstream = EmbeddedChannel(loop: loop)
            downstreams.append(downstream)
            upstreams.append(upstream)
            if index < 2 {
                let stall = StalledMutationWriteHandler()
                stalls.append(stall)
                try downstream.pipeline.addHandler(stall).wait()
            }
            let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
                host: "example.test", port: 80, path: "/stalled-mutation", headers: [], body: Data())
            let forwarder = StreamingUpstreamForwarder(request: request, upstreamScheme: .http,
                keepConnectionOpen: true, downstreamChannel: downstream,
                downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
                responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
                mutationBudget: budget, sessionRecorder: nil, sessionIDTask: Task { nil },
                onSessionCompleted: { _, _ in }, onSessionFailed: { _ in XCTFail("Must preserve upstream delivery") },
                onConnectionDone: { _ in })
            try upstream.pipeline.addHandler(forwarder).wait()
            var buffer = upstream.allocator.buffer(capacity: wire.utf8.count)
            buffer.writeString(wire)
            try upstream.writeInbound(buffer)
            loop.run()
            XCTAssertFalse(upstream.isActive, "Upstream handler teardown must not release downstream ownership")
            XCTAssertEqual(budget.activeCount, min(index + 1, 2))
        }
        XCTAssertEqual(stalls.map(\.pendingWriteCount), [1, 1])
        XCTAssertEqual(budget.rejectedCount, 1)
        var passthrough = Data()
        while let bytes = try downstreams[2].readOutbound(as: ByteBuffer.self) {
            passthrough.append(contentsOf: bytes.readableBytesView)
        }
        XCTAssertEqual(passthrough, Data(wire.utf8))
        if closeDownstream { try downstreams[0].close().wait() }
        else { stalls[0].complete(.success(())) }
        loop.run()
        XCTAssertEqual(budget.activeCount, 1)
        if closeDownstream { try downstreams[1].close().wait() }
        else { stalls[1].complete(.failure(ChannelError.ioOnClosedChannel)) }
        loop.run()
        XCTAssertEqual(budget.activeCount, 0)
    }

    func testSyntheticReceiptsUseActualDownstreamWriteResult() throws {
        let engine = SyntheticCollectionInjectionEngine.shared
        let plan = SyntheticCollectionInjectionPlan(name: "Receipt test", urlPattern: "/receipt-test",
            collectionKeypath: "$.items", boundAssetKind: nil, clientScope: .allClients)
        defer { engine.removePlan(id: plan.id) }
        for writeFails in [false, true] {
            engine.registerPlan(plan)
            let loop = EmbeddedEventLoop()
            let downstream = EmbeddedChannel(loop: loop)
            let upstream = EmbeddedChannel(loop: loop)
            if writeFails { try downstream.pipeline.addHandler(ReceiptWriteFailureHandler()).wait() }
            let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
                host: "example.test", port: 80, path: "/receipt-test", headers: [], body: Data())
            let forwarder = StreamingUpstreamForwarder(request: request, upstreamScheme: .http,
                keepConnectionOpen: true, downstreamChannel: downstream,
                downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
                responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
                sessionRecorder: nil, sessionIDTask: Task { nil }, onSessionCompleted: { _, _ in },
                onSessionFailed: { _ in XCTFail("Unexpected upstream failure") }, onConnectionDone: { _ in })
            try upstream.pipeline.addHandler(forwarder).wait()
            let body = #"{"items":[{"id":"original"}]}"#
            var buffer = upstream.allocator.buffer(capacity: 256)
            buffer.writeString("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            try upstream.writeInbound(buffer)
            loop.run()
            let receipt = try XCTUnwrap(engine.diagnostics(planID: plan.id)?.receipts.last)
            XCTAssertEqual(receipt.reason, .transformed)
            XCTAssertEqual(receipt.deliveryState, writeFails ? .downstreamWriteFailed : .downstreamWriteSucceeded)
            XCTAssertEqual(receipt.targetOutcome, "unknown")
            _ = try? upstream.finish()
            _ = try? downstream.finish()
        }
    }

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func testMutationCapacityFailurePreservesOriginalWireAndReportsReason() throws {
        let engine = SyntheticCollectionInjectionEngine.shared
        let plan = SyntheticCollectionInjectionPlan(name: "Capacity evidence", urlPattern: "/capacity-test",
            collectionKeypath: "$.items", boundAssetKind: nil, clientScope: .allClients)
        engine.registerPlan(plan)
        defer { engine.removePlan(id: plan.id) }
        let budget = MutationBufferBudget(limit: 1)
        let occupied = try XCTUnwrap(budget.reserve())
        defer { withExtendedLifetime(occupied) {} }
        let loop = EmbeddedEventLoop()
        let downstream = EmbeddedChannel(loop: loop)
        let upstream = EmbeddedChannel(loop: loop)
        let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
            host: "example.test", port: 80, path: "/capacity-test", headers: [], body: Data())
        let forwarder = StreamingUpstreamForwarder(request: request, upstreamScheme: .http,
            keepConnectionOpen: true, downstreamChannel: downstream,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
            mutationBudget: budget, sessionRecorder: nil, sessionIDTask: Task { nil },
            onSessionCompleted: { response, _ in
                XCTAssertEqual(response.sourceDescription, SyntheticInjectionReason.capacityUnavailable.recovery)
            }, onSessionFailed: { _ in XCTFail("Capacity exhaustion must preserve delivery") }, onConnectionDone: { _ in })
        try upstream.pipeline.addHandler(forwarder).wait()
        let body = #"{"items":[{"id":"original"}]}"#
        let wire = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nETag: original\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        var buffer = upstream.allocator.buffer(capacity: wire.utf8.count)
        buffer.writeString(wire)
        try upstream.writeInbound(buffer)
        loop.run()
        var delivered = Data()
        while let bytes = try downstream.readOutbound(as: ByteBuffer.self) { delivered.append(contentsOf: bytes.readableBytesView) }
        XCTAssertEqual(delivered, Data(wire.utf8))
        XCTAssertEqual(engine.diagnostics(planID: plan.id)?.receipts.last?.reason, .capacityUnavailable)
        XCTAssertEqual(budget.activeCount, 1)
        XCTAssertEqual(budget.rejectedCount, 1)
        _ = try upstream.finish(acceptAlreadyClosed: true)
        _ = try downstream.finish(acceptAlreadyClosed: true)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
        super.tearDown()
    }

    func testImmediateHeaderDeliveryAndDirectStreaming() throws {
        let loop = EmbeddedEventLoop()
        let downstreamChannel = EmbeddedChannel(loop: loop)
        let upstreamChannel = EmbeddedChannel(loop: loop)

        let request = HTTPProxyRequest(
            kind: .standard,
            method: "GET",
            version: "HTTP/1.1",
            host: "media.example.com",
            port: 80,
            path: "/stream/video.mp4",
            headers: [],
            body: Data()
        )

        let sessionCompletedExpectation = expectation(description: "Session completed")
        let timingRecorder = UpstreamWireTimingRecorder(startedAt: Date())
        let accumulator = BoundedCaptureAccumulator(limit: 1024)

        var finalResponse: CapturedResponse?
        var finalProfile: WireTimingProfile?

        let forwarder = StreamingUpstreamForwarder(
            request: request,
            upstreamScheme: .http,
            keepConnectionOpen: true,
            downstreamChannel: downstreamChannel,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(),
            timingRecorder: timingRecorder,
            boundedCaptureAccumulator: accumulator,
            sessionRecorder: nil,
            sessionIDTask: Task { nil },
            onSessionCompleted: { response, profile in
                finalResponse = response
                finalProfile = profile
                sessionCompletedExpectation.fulfill()
            },
            onSessionFailed: { error in
                XCTFail("Unexpected failure: \(error)")
            },
            onConnectionDone: { _ in }
        )

        try upstreamChannel.pipeline.addHandler(forwarder).wait()

        // 1. Deliver headers chunk with a small initial body slice
        let headerText = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nConnection: close\r\n\r\nPARTIAL_BODY_1_"
        var headerBuf = upstreamChannel.allocator.buffer(capacity: headerText.utf8.count)
        headerBuf.writeString(headerText)
        try upstreamChannel.writeInbound(headerBuf)

        // Verify downstream immediately received header + initial body
        var deliveredDownstream = Data()
        while let outBuf: ByteBuffer = try downstreamChannel.readOutbound() {
            outBuf.withUnsafeReadableBytes { ptr in
                if let base = ptr.baseAddress {
                    deliveredDownstream.append(base.assumingMemoryBound(to: UInt8.self), count: ptr.count)
                }
            }
        }

        let deliveredString = String(data: deliveredDownstream, encoding: .utf8) ?? ""
        XCTAssertTrue(deliveredString.contains("HTTP/1.1 200"))
        XCTAssertTrue(deliveredString.contains("Content-Type: video/mp4"))
        XCTAssertTrue(deliveredString.contains("PARTIAL_BODY_1_"))

        // 2. Deliver chunk 2
        var chunk2Buf = upstreamChannel.allocator.buffer(capacity: 64)
        chunk2Buf.writeString("PARTIAL_BODY_2_")
        try upstreamChannel.writeInbound(chunk2Buf)

        var chunk2Downstream = Data()
        while let outBuf: ByteBuffer = try downstreamChannel.readOutbound() {
            outBuf.withUnsafeReadableBytes { ptr in
                if let base = ptr.baseAddress {
                    chunk2Downstream.append(base.assumingMemoryBound(to: UInt8.self), count: ptr.count)
                }
            }
        }
        XCTAssertEqual(String(data: chunk2Downstream, encoding: .utf8), "PARTIAL_BODY_2_")

        // 3. Complete connection
        try upstreamChannel.close().wait()

        wait(for: [sessionCompletedExpectation], timeout: 2.0)

        XCTAssertNotNil(finalResponse)
        XCTAssertEqual(finalResponse?.statusCode, 200)
        XCTAssertEqual(finalResponse?.bodySize, "PARTIAL_BODY_1_PARTIAL_BODY_2_".utf8.count)
        XCTAssertEqual(
            finalResponse?.bodyData,
            Data("PARTIAL_BODY_1_PARTIAL_BODY_2_".utf8)
        )
        XCTAssertFalse(finalResponse?.bodyTruncated ?? true)
        XCTAssertNotNil(finalProfile?.transfer)
        XCTAssertGreaterThan(finalProfile?.transfer?.headerByteCount ?? 0, 0)
    }

    func testLargeResponseBoundedCaptureRetention() throws {
        let loop = EmbeddedEventLoop()
        let downstreamChannel = EmbeddedChannel(loop: loop)
        let upstreamChannel = EmbeddedChannel(loop: loop)

        let request = HTTPProxyRequest(
            kind: .standard,
            method: "GET",
            version: "HTTP/1.1",
            host: "cdn.example.com",
            port: 80,
            path: "/large/payload.bin",
            headers: [],
            body: Data()
        )

        let sessionCompletedExpectation = expectation(description: "Session completed")
        let timingRecorder = UpstreamWireTimingRecorder(startedAt: Date())
        // Limit capture accumulator to 100 bytes for testing
        let accumulator = BoundedCaptureAccumulator(limit: 100)

        var finalResponse: CapturedResponse?

        let forwarder = StreamingUpstreamForwarder(
            request: request,
            upstreamScheme: .http,
            keepConnectionOpen: true,
            downstreamChannel: downstreamChannel,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(),
            timingRecorder: timingRecorder,
            boundedCaptureAccumulator: accumulator,
            sessionRecorder: nil,
            sessionIDTask: Task { nil },
            onSessionCompleted: { response, _ in
                finalResponse = response
                sessionCompletedExpectation.fulfill()
            },
            onSessionFailed: { error in
                XCTFail("Unexpected failure: \(error)")
            },
            onConnectionDone: { _ in }
        )

        try upstreamChannel.pipeline.addHandler(forwarder).wait()

        let headerText = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n"
        var headerBuf = upstreamChannel.allocator.buffer(capacity: headerText.utf8.count)
        headerBuf.writeString(headerText)
        try upstreamChannel.writeInbound(headerBuf)

        // Write 500 bytes across multiple chunks
        let chunkData = Data(repeating: 0x41, count: 100) // 100 'A's
        for _ in 0..<5 {
            var chunkBuf = upstreamChannel.allocator.buffer(capacity: 100)
            chunkBuf.writeBytes(chunkData)
            try upstreamChannel.writeInbound(chunkBuf)
        }

        try upstreamChannel.close().wait()
        wait(for: [sessionCompletedExpectation], timeout: 2.0)

        XCTAssertEqual(finalResponse?.statusCode, 200)
        XCTAssertEqual(finalResponse?.bodySize, 500)
        XCTAssertEqual(finalResponse?.bodyData?.count, 100) // bounded to 100
        XCTAssertTrue(finalResponse?.bodyTruncated ?? false)
    }

    func testLargeBodyMutationCeilingFailOpen() throws {
        let loop = EmbeddedEventLoop()
        let downstreamChannel = EmbeddedChannel(loop: loop)
        let upstreamChannel = EmbeddedChannel(loop: loop)

        let request = HTTPProxyRequest(
            kind: .standard,
            method: "GET",
            version: "HTTP/1.1",
            host: "api.example.com",
            port: 80,
            path: "/v1/huge-feed",
            headers: [],
            body: Data()
        )

        let ruleID = UUID()
        let rewrite = BookmarkResponseFieldRewrite(
            jsonPath: "$.title",
            overrideValue: .string("Modified Title")
        )
        let liveContext = LiveResponseRewriteContext(
            ruleID: ruleID,
            rewrites: [rewrite],
            sourceDescription: "Rewrite Item Title",
            expectedSchemaFingerprint: nil
        )

        let sessionCompletedExpectation = expectation(description: "Session completed")
        let timingRecorder = UpstreamWireTimingRecorder(startedAt: Date())
        let accumulator = BoundedCaptureAccumulator(limit: 1024)

        var finalResponse: CapturedResponse?

        let forwarder = StreamingUpstreamForwarder(
            request: request,
            upstreamScheme: .http,
            keepConnectionOpen: true,
            downstreamChannel: downstreamChannel,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(),
            timingRecorder: timingRecorder,
            boundedCaptureAccumulator: accumulator,
            sessionRecorder: nil,
            sessionIDTask: Task { nil },
            liveResponseRewriteContext: liveContext,
            onSessionCompleted: { response, _ in
                finalResponse = response
                sessionCompletedExpectation.fulfill()
            },
            onSessionFailed: { error in
                XCTFail("Unexpected failure: \(error)")
            },
            onConnectionDone: { _ in }
        )

        try upstreamChannel.pipeline.addHandler(forwarder).wait()

        // Send header with JSON content type
        let headerText = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
        var headerBuf = upstreamChannel.allocator.buffer(capacity: headerText.utf8.count)
        headerBuf.writeString(headerText)
        try upstreamChannel.writeInbound(headerBuf)

        // Send chunks exceeding 5 MB (e.g. 6 MB)
        let largeChunk = Data(repeating: 0x20, count: 1024 * 1024) // 1 MB spaces
        for _ in 0..<6 {
            var chunkBuf = upstreamChannel.allocator.buffer(capacity: 1024 * 1024)
            chunkBuf.writeBytes(largeChunk)
            try upstreamChannel.writeInbound(chunkBuf)
        }

        try upstreamChannel.close().wait()
        wait(for: [sessionCompletedExpectation], timeout: 2.0)

        // Verify guard tripped and stream completed without failure
        XCTAssertEqual(finalResponse?.statusCode, 200)
        XCTAssertEqual(finalResponse?.bodySize, 6 * 1024 * 1024)
        XCTAssertTrue(finalResponse?.bodyTruncated ?? false)
    }

    // MARK: - Live collection mock (R181-3 pipeline wiring)

    private func collectionMockPlan() throws -> CompiledCollectionMock {
        try CollectionMockCompiler.prepare(
            source: Data(#"{"items":[{"id":"original"}],"total":1}"#.utf8),
            draft: .init(collectionPointer: "/items", item: .object(["id": .string("synthetic")]),
                templateIndex: nil, edits: [], identityPointers: ["/id"], countPointers: ["/total"],
                position: .append)
        )
    }

    @MainActor
    private func runCollectionMockForwarder(
        context: LiveCollectionMockContext,
        body: Data,
        executor: LiveCollectionTransformationExecutor = LiveCollectionTransformationExecutor(),
        onSessionFailed: @escaping @Sendable (Error) -> Void = { XCTFail("Unexpected failure: \($0)") }
    ) async throws -> CapturedResponse {
        let budget = MutationBufferBudget(limit: 1)
        let loop = EmbeddedEventLoop()
        let downstreamChannel = EmbeddedChannel(loop: loop)
        let upstreamChannel = EmbeddedChannel(loop: loop)
        defer {
            _ = try? upstreamChannel.finish(acceptAlreadyClosed: true)
            _ = try? downstreamChannel.finish(acceptAlreadyClosed: true)
        }
        let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
            host: "api.example.com", port: 80, path: "/v1/collection-mock", headers: [], body: Data())
        var finalResponse: CapturedResponse?
        var completionCount = 0
        let forwarder = StreamingUpstreamForwarder(
            request: request, upstreamScheme: .http, keepConnectionOpen: true,
            downstreamChannel: downstreamChannel,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
            boundedCaptureAccumulator: BoundedCaptureAccumulator(limit: 1024), mutationBudget: budget,
            sessionRecorder: nil, sessionIDTask: Task { nil },
            liveCollectionMockContext: context,
            liveCollectionTransformationExecutor: executor,
            onSessionCompleted: { response, _ in
                finalResponse = response
                completionCount += 1
            },
            onSessionFailed: onSessionFailed,
            onConnectionDone: { _ in }
        )
        try upstreamChannel.pipeline.addHandler(forwarder).wait()
        let headerText = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
        var headerBuf = upstreamChannel.allocator.buffer(capacity: headerText.utf8.count)
        headerBuf.writeString(headerText)
        try upstreamChannel.writeInbound(headerBuf)
        var bodyBuf = upstreamChannel.allocator.buffer(capacity: body.count)
        bodyBuf.writeBytes(body)
        try upstreamChannel.writeInbound(bodyBuf)
        try upstreamChannel.close().wait()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while finalResponse == nil, ContinuousClock.now < deadline {
            loop.run()
            try await Task.sleep(for: .milliseconds(1))
        }
        loop.run()
        let response = try XCTUnwrap(finalResponse)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(budget.activeCount, 0, "EOF delivery must release its reservation after drain")
        var delivered = Data()
        while let buffer = try downstreamChannel.readOutbound(as: ByteBuffer.self) {
            delivered.append(contentsOf: buffer.readableBytesView)
        }
        let expected = try XCTUnwrap(response.bodyData)
        XCTAssertEqual(Data(delivered.suffix(expected.count)), expected, "Capture completion must correspond to actual downstream bytes")
        return response
    }

    @MainActor
    func testLiveCollectionMockAppliesTransformationEndToEnd() async throws {
        let ruleID = UUID()
        LiveTransformationActivationTracker.shared.recordActivationStart(ruleID: ruleID)
        defer { LiveTransformationActivationTracker.shared.clear(ruleID: ruleID) }
        let context = LiveCollectionMockContext(
            ruleID: ruleID, plan: try collectionMockPlan(), sourceDescription: "Mock item"
        )
        let response = try await runCollectionMockForwarder(
            context: context, body: Data(#"{"items":[{"id":"fresh"}],"total":1}"#.utf8)
        )
        XCTAssertEqual(response.source, .liveResponseRewrite)
        XCTAssertEqual(
            try CollectionMockCompiler.parse(try XCTUnwrap(response.bodyData)),
            try CollectionMockCompiler.parse(Data(#"{"items":[{"id":"fresh"},{"id":"synthetic"}],"total":2}"#.utf8))
        )
        XCTAssertEqual(response.sourceDescription, "Mock item · applied: 1 → 2 items")
    }

    @MainActor
    func testBundleCollectionReceiptsFollowRealForwarderWritesForAppliedAndSkippedBodies() async throws {
        let draft = CollectionMockDraft(collectionPointer: "/items", item: .object(["id": .string("synthetic")]),
            templateIndex: nil, edits: [], identityPointers: ["/id"], countPointers: ["/total"], position: .append)
        let package = try CapturedMockPackageCompiler.prepare(id: UUID(), name: "Synthetic delivery",
            source: Data(#"{"items":[],"total":0}"#.utf8), draft: draft,
            scope: .init(host: "api.example.test", scheme: .http, port: 80, path: "/items", clients: .address("192.0.2.1")),
            images: [], appVersion: "test", createdAt: Date())
        let manifest = package.manifest, ruleID = manifest.responseEffects[0].id
        let gate = EffectBundleActivationGate.shared, executor = LiveCollectionTransformationExecutor()
        let plan = try collectionMockPlan()
        gate.register(bundleID: manifest.id, responseRuleIDs: [ruleID], hlsExperimentIDs: [])
        gate.registerResources(manifest: manifest)
        gate.open(bundleID: manifest.id)
        LiveTransformationActivationTracker.shared.recordActivationStart(ruleID: ruleID)
        defer {
            executor.stop(effectID: ruleID)
            gate.close(bundleID: manifest.id)
            gate.unregister(bundleID: manifest.id)
            LiveTransformationActivationTracker.shared.clear(ruleID: ruleID)
        }
        let revision = try executor.begin(effectID: ruleID, plan: plan, bundleGate: gate)
        let context = LiveCollectionMockContext(ruleID: ruleID, plan: plan, sourceDescription: "Synthetic", revision: revision)
        for body in [Data(#"{"items":[{"id":"fresh"}],"total":1}"#.utf8),
                     Data(#"{"items":[{"id":"synthetic"}],"total":1}"#.utf8)] {
            _ = try await runCollectionMockForwarder(context: context, body: body, executor: executor)
        }
        let receipts = gate.observationSnapshot(bundleID: manifest.id)
        XCTAssertEqual(receipts.map(\.outcome), ["applied", "alreadyPresent"])
        XCTAssertTrue(receipts.allSatisfy { $0.delivery == .downstreamWriteSucceeded && $0.authored == nil })
    }

    @MainActor
    func testLiveCollectionMockExpiredActivationFailsOpen() async throws {
        let ruleID = UUID()
        // 901s in the past exceeds `LiveTransformationExecutionBudget.activationLifetimeSeconds` (900s).
        LiveTransformationActivationTracker.shared.recordActivationStart(
            ruleID: ruleID, now: Date().addingTimeInterval(-901)
        )
        defer { LiveTransformationActivationTracker.shared.clear(ruleID: ruleID) }
        let context = LiveCollectionMockContext(
            ruleID: ruleID, plan: try collectionMockPlan(), sourceDescription: "Mock item"
        )
        let untouchedBody = Data(#"{"items":[{"id":"fresh"}],"total":1}"#.utf8)
        let response = try await runCollectionMockForwarder(context: context, body: untouchedBody)
        XCTAssertEqual(response.bodyData, untouchedBody, "expired activation must fail open, serving the untransformed body")
        XCTAssertEqual(response.source, .liveResponseRewrite)
    }

    @MainActor
    func testLiveCollectionMockOverHitBudgetFailsOpen() async throws {
        let ruleID = UUID()
        LiveTransformationActivationTracker.shared.recordActivationStart(ruleID: ruleID)
        defer { LiveTransformationActivationTracker.shared.clear(ruleID: ruleID) }
        for _ in 0..<LiveTransformationExecutionBudget.maxTransformedResponsesPerActivation {
            LiveTransformationActivationTracker.shared.recordTransformed(ruleID: ruleID)
        }
        let context = LiveCollectionMockContext(
            ruleID: ruleID, plan: try collectionMockPlan(), sourceDescription: "Mock item"
        )
        let untouchedBody = Data(#"{"items":[{"id":"fresh"}],"total":1}"#.utf8)
        let response = try await runCollectionMockForwarder(context: context, body: untouchedBody)
        XCTAssertEqual(response.bodyData, untouchedBody, "a rule past its hit-count budget must fail open")
        XCTAssertEqual(response.source, .liveResponseRewrite)
    }

    @MainActor
    func testLiveCollectionMockSkipOutcomeSurfacesInCaptureDescription() async throws {
        let ruleID = UUID()
        LiveTransformationActivationTracker.shared.recordActivationStart(ruleID: ruleID)
        defer { LiveTransformationActivationTracker.shared.clear(ruleID: ruleID) }
        let context = LiveCollectionMockContext(
            ruleID: ruleID, plan: try collectionMockPlan(), sourceDescription: "Mock item"
        )
        let invalidBody = Data("not JSON".utf8)
        let response = try await runCollectionMockForwarder(context: context, body: invalidBody)
        XCTAssertEqual(response.bodyData, invalidBody, "a skipped transform must preserve the exact original bytes")
        XCTAssertEqual(response.sourceDescription, "Mock item · skipped: contract mismatch (invalidJSON)")
    }

    func testLiveCollectionMockCapacityFailureStreamsExactOriginalBytesWithoutWorker() throws {
        let ruleID = UUID()
        LiveTransformationActivationTracker.shared.recordActivationStart(ruleID: ruleID)
        defer { LiveTransformationActivationTracker.shared.clear(ruleID: ruleID) }
        let budget = MutationBufferBudget(limit: 1)
        let occupied = try XCTUnwrap(budget.reserve())
        defer { withExtendedLifetime(occupied) {} }
        let loop = EmbeddedEventLoop()
        let downstream = EmbeddedChannel(loop: loop)
        let upstream = EmbeddedChannel(loop: loop)
        defer {
            _ = try? upstream.finish(acceptAlreadyClosed: true)
            _ = try? downstream.finish(acceptAlreadyClosed: true)
        }
        let body = Data(#"{"items":[{"id":"fresh"}],"total":1}"#.utf8)
        let wire = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
            host: "api.example.com", port: 80, path: "/v1/collection-mock", headers: [], body: Data())
        let completion = expectation(description: "Unmodified capture completes")
        var captured: CapturedResponse?
        let forwarder = StreamingUpstreamForwarder(
            request: request, upstreamScheme: .http, keepConnectionOpen: true, downstreamChannel: downstream,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
            mutationBudget: budget, sessionRecorder: nil, sessionIDTask: Task { nil },
            liveCollectionMockContext: .init(ruleID: ruleID, plan: try collectionMockPlan(), sourceDescription: "Mock item"),
            onSessionCompleted: { response, _ in
                captured = response
                completion.fulfill()
            },
            onSessionFailed: { error in XCTFail("Capacity exhaustion must fail open: \(error)") },
            onConnectionDone: { _ in }
        )
        try upstream.pipeline.addHandler(forwarder).wait()
        var response = upstream.allocator.buffer(capacity: wire.utf8.count + body.count)
        response.writeString(wire)
        response.writeBytes(body)
        try upstream.writeInbound(response)
        loop.run()

        wait(for: [completion], timeout: 1)
        XCTAssertEqual(captured?.bodyData, body)
        XCTAssertEqual(captured?.sourceDescription,
            "Mock item · skipped: capacity limited")
        XCTAssertEqual(budget.activeCount, 1, "Only the pre-existing reservation may be active")
        XCTAssertEqual(budget.rejectedCount, 1)
        var delivered = Data()
        while let buffer = try downstream.readOutbound(as: ByteBuffer.self) {
            delivered.append(contentsOf: buffer.readableBytesView)
        }
        XCTAssertEqual(delivered, Data(wire.utf8) + body)
    }

    @MainActor
    func testBlockedCollectionWorkerDistinguishesAdvanceFromStopAndReplacement() async throws {
        for invalidation in ["replacement", "phase", "stop"] {
        let gate = ForwarderWorkerGate()
        let routingGate = EffectBundleActivationGate()
        let bundleID = UUID()
        let executor = LiveCollectionTransformationExecutor(worker: { method, status, headers, body, plan in
            await gate.enter()
            return LiveResponseTransformation.transformCollection(method: method, statusCode: status,
                headers: headers, body: body, plan: plan)
        })
        let ruleID = UUID()
        routingGate.register(bundleID: bundleID, responseRuleIDs: [ruleID], hlsExperimentIDs: [])
        routingGate.selectPhase(bundleID: bundleID, responseRuleIDs: [ruleID])
        routingGate.open(bundleID: bundleID)
        let plan = try collectionMockPlan()
        let revision = try XCTUnwrap(executor.begin(effectID: ruleID, plan: plan, bundleGate: routingGate))
        LiveTransformationActivationTracker.shared.recordActivationStart(ruleID: ruleID)
        defer { LiveTransformationActivationTracker.shared.clear(ruleID: ruleID) }
        let budget = MutationBufferBudget(limit: 1)
        let loop = EmbeddedEventLoop()
        let downstream = EmbeddedChannel(loop: loop)
        let upstream = EmbeddedChannel(loop: loop)
        defer {
            _ = try? upstream.finish(acceptAlreadyClosed: true)
            _ = try? downstream.finish(acceptAlreadyClosed: true)
        }
        let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
            host: "api.example.com", port: 80, path: "/v1/collection-mock", headers: [], body: Data())
        let body = Data(#"{"items":[{"id":"fresh"}],"total":1}"#.utf8)
        var captured: CapturedResponse?
        var completionCount = 0
        let forwarder = StreamingUpstreamForwarder(
            request: request, upstreamScheme: .http, keepConnectionOpen: true, downstreamChannel: downstream,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
            mutationBudget: budget, sessionRecorder: nil, sessionIDTask: Task { nil },
            liveCollectionMockContext: .init(ruleID: ruleID, plan: plan, sourceDescription: "Mock item", revision: revision),
            liveCollectionTransformationExecutor: executor,
            onSessionCompleted: { response, _ in
                captured = response
                completionCount += 1
            },
            onSessionFailed: { error in XCTFail("Replacement must fail open, not fail the response: \(error)") },
            onConnectionDone: { _ in }
        )
        try upstream.pipeline.addHandler(forwarder).wait()
        var headers = upstream.allocator.buffer(capacity: 128)
        headers.writeString("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n")
        try upstream.writeInbound(headers)
        var payload = upstream.allocator.buffer(capacity: body.count)
        payload.writeBytes(body)
        try upstream.writeInbound(payload)
        try upstream.close().wait()
        await gate.waitForEntry()

        switch invalidation {
        case "phase": routingGate.selectPhase(bundleID: bundleID, responseRuleIDs: [])
        case "stop": routingGate.close(bundleID: bundleID)
        default: _ = executor.begin(effectID: ruleID, plan: plan, bundleGate: routingGate)
        }
        await gate.release()

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while captured == nil, ContinuousClock.now < deadline {
            loop.run()
            try await Task.sleep(for: .milliseconds(1))
        }
        loop.run()
        if invalidation == "phase" {
            XCTAssertNotEqual(captured?.bodyData, body, "Admitted old-phase response must still apply its reviewed plan")
            XCTAssertEqual(captured?.sourceDescription, "Mock item · applied: 1 → 2 items")
        } else {
            XCTAssertEqual(captured?.bodyData, body)
            XCTAssertEqual(captured?.sourceDescription, "Mock item · skipped: inactive revision")
        }
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(budget.activeCount, 0)
        }
    }

    @MainActor
    func testRemovingHandlerCancelsBlockedCollectionMockAndDrainsReservation() async throws {
        let gate = ForwarderWorkerGate()
        let executor = LiveCollectionTransformationExecutor(worker: { method, status, headers, body, plan in
            await gate.enter()
            return LiveResponseTransformation.transformCollection(method: method, statusCode: status,
                headers: headers, body: body, plan: plan)
        })
        let ruleID = UUID()
        let plan = try collectionMockPlan()
        let revision = try XCTUnwrap(executor.begin(effectID: ruleID, plan: plan))
        LiveTransformationActivationTracker.shared.recordActivationStart(ruleID: ruleID)
        defer { LiveTransformationActivationTracker.shared.clear(ruleID: ruleID) }
        let budget = MutationBufferBudget(limit: 1)
        let loop = EmbeddedEventLoop()
        let downstream = EmbeddedChannel(loop: loop)
        let upstream = EmbeddedChannel(loop: loop)
        defer {
            _ = try? upstream.finish(acceptAlreadyClosed: true)
            _ = try? downstream.finish(acceptAlreadyClosed: true)
        }
        let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
            host: "api.example.com", port: 80, path: "/v1/collection-mock", headers: [], body: Data())
        let body = Data(#"{"items":[{"id":"fresh"}],"total":1}"#.utf8)
        var completionCount = 0
        var failureCount = 0
        let forwarder = StreamingUpstreamForwarder(
            request: request, upstreamScheme: .http, keepConnectionOpen: true, downstreamChannel: downstream,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
            mutationBudget: budget, sessionRecorder: nil, sessionIDTask: Task { nil },
            liveCollectionMockContext: .init(ruleID: ruleID, plan: plan, sourceDescription: "Mock item", revision: revision),
            liveCollectionTransformationExecutor: executor,
            onSessionCompleted: { _, _ in completionCount += 1 },
            onSessionFailed: { _ in failureCount += 1 },
            onConnectionDone: { _ in }
        )
        try upstream.pipeline.addHandler(forwarder, name: "blocked-collection-forwarder").wait()
        var response = upstream.allocator.buffer(capacity: body.count + 128)
        response.writeString("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n")
        response.writeBytes(body)
        try upstream.writeInbound(response)
        await gate.waitForEntry()

        try upstream.pipeline.removeHandler(name: "blocked-collection-forwarder").wait()
        await gate.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while budget.activeCount != 0, ContinuousClock.now < deadline {
            loop.run()
            try await Task.sleep(for: .milliseconds(1))
        }
        loop.run()
        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(failureCount, 1, "Cancelled work must terminate capture ownership exactly once")
        XCTAssertEqual(budget.activeCount, 0)
        XCTAssertNil(try downstream.readOutbound(as: ByteBuffer.self))
    }

    func testIncompleteStreamTeardownReleasesCollectorExactlyOnce() throws {
        for removeHandler in [false, true] {
            let loop = EmbeddedEventLoop()
            let downstream = EmbeddedChannel(loop: loop)
            let upstream = EmbeddedChannel(loop: loop)
            let collector = BoundedCaptureAccumulator(limit: 1024)
            var failures = 0
            var connectionsDone = 0
            let request = HTTPProxyRequest(kind: .standard, method: "GET", version: "HTTP/1.1",
                host: "example.test", port: 80, path: "/stream", headers: [], body: Data())
            let forwarder = StreamingUpstreamForwarder(request: request, upstreamScheme: .http,
                keepConnectionOpen: true, downstreamChannel: downstream,
                downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
                responseParser: HTTPResponseParser(), timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
                boundedCaptureAccumulator: collector, sessionRecorder: nil, sessionIDTask: Task { nil },
                onSessionCompleted: { _, _ in XCTFail("Incomplete cancelled response is not a completed capture") },
                onSessionFailed: { _ in failures += 1 }, onConnectionDone: { _ in connectionsDone += 1 })
            try upstream.pipeline.addHandler(forwarder, name: "capture").wait()
            var response = upstream.allocator.buffer(capacity: 128)
            response.writeString("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\npartial")
            try upstream.writeInbound(response)
            if removeHandler {
                try upstream.pipeline.removeHandler(name: "capture").wait()
            } else {
                try downstream.close().wait()
                try XCTUnwrap(forwarder.cancelForDownstreamClosure)()
            }
            loop.run()
            XCTAssertEqual(failures, 1)
            XCTAssertEqual(connectionsDone, 1)
            XCTAssertNil(collector.takeFinalizedBody().data)
            _ = try upstream.finish(acceptAlreadyClosed: true)
            _ = try downstream.finish(acceptAlreadyClosed: true)
            loop.run()
            XCTAssertEqual(failures, 1)
        }
    }

    func testNoCachingPolicyAppliedOnStreamingHeaders() throws {
        let loop = EmbeddedEventLoop()
        let downstreamChannel = EmbeddedChannel(loop: loop)
        let upstreamChannel = EmbeddedChannel(loop: loop)

        let request = HTTPProxyRequest(
            kind: .standard,
            method: "GET",
            version: "HTTP/1.1",
            host: "api.nocache.com",
            port: 80,
            path: "/data",
            headers: [],
            body: Data()
        )

        let config = UserDefaultsAppConfiguration(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        config.isNoCachingEnabled = true
        config.noCachingDomains = []

        let sessionCompletedExpectation = expectation(description: "Session completed")
        let timingRecorder = UpstreamWireTimingRecorder(startedAt: Date())

        let forwarder = StreamingUpstreamForwarder(
            request: request,
            upstreamScheme: .http,
            keepConnectionOpen: true,
            downstreamChannel: downstreamChannel,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(),
            timingRecorder: timingRecorder,
            sessionRecorder: nil,
            sessionIDTask: Task { nil },
            appConfiguration: config,
            onSessionCompleted: { _, _ in
                sessionCompletedExpectation.fulfill()
            },
            onSessionFailed: { error in
                XCTFail("Unexpected failure: \(error)")
            },
            onConnectionDone: { _ in }
        )

        try upstreamChannel.pipeline.addHandler(forwarder).wait()

        let headerText = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: max-age=3600\r\n\r\nhello"
        var headerBuf = upstreamChannel.allocator.buffer(capacity: headerText.utf8.count)
        headerBuf.writeString(headerText)
        try upstreamChannel.writeInbound(headerBuf)

        var deliveredDownstream = Data()
        while let outBuf: ByteBuffer = try downstreamChannel.readOutbound() {
            outBuf.withUnsafeReadableBytes { ptr in
                if let base = ptr.baseAddress {
                    deliveredDownstream.append(base.assumingMemoryBound(to: UInt8.self), count: ptr.count)
                }
            }
        }

        let deliveredString = String(data: deliveredDownstream, encoding: .utf8) ?? ""
        XCTAssertTrue(deliveredString.contains("no-store, no-cache, must-revalidate"))
        XCTAssertTrue(deliveredString.contains("Pragma: no-cache"))

        try upstreamChannel.close().wait()
        wait(for: [sessionCompletedExpectation], timeout: 2.0)
    }

    func testHighVolumeMultiGigabyteSimulationChunkTimingCapAndRetention() throws {
        let loop = EmbeddedEventLoop()
        let downstreamChannel = EmbeddedChannel(loop: loop)
        let upstreamChannel = EmbeddedChannel(loop: loop)

        let request = HTTPProxyRequest(
            kind: .standard,
            method: "GET",
            version: "HTTP/1.1",
            host: "stream.cdn.example.com",
            port: 80,
            path: "/vod/movie-4k.mp4",
            headers: [],
            body: Data()
        )

        let sessionCompletedExpectation = expectation(description: "Session completed")
        let timingRecorder = UpstreamWireTimingRecorder(startedAt: Date())
        let accumulator = BoundedCaptureAccumulator(limit: 1024 * 1024) // 1 MB cap

        var finalResponse: CapturedResponse?
        var finalProfile: WireTimingProfile?

        let forwarder = StreamingUpstreamForwarder(
            request: request,
            upstreamScheme: .http,
            keepConnectionOpen: true,
            downstreamChannel: downstreamChannel,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(),
            timingRecorder: timingRecorder,
            boundedCaptureAccumulator: accumulator,
            sessionRecorder: nil,
            sessionIDTask: Task { nil },
            onSessionCompleted: { response, profile in
                finalResponse = response
                finalProfile = profile
                sessionCompletedExpectation.fulfill()
            },
            onSessionFailed: { error in
                XCTFail("Unexpected failure: \(error)")
            },
            onConnectionDone: { _ in }
        )

        try upstreamChannel.pipeline.addHandler(forwarder).wait()

        // 1. Send status line + headers
        let headerText = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\n\r\n"
        var headerBuf = upstreamChannel.allocator.buffer(capacity: headerText.utf8.count)
        headerBuf.writeString(headerText)
        try upstreamChannel.writeInbound(headerBuf)

        // 2. Stream 1,000 chunks of 64 KB = 64 MB (simulating high-throughput download)
        let chunkPayload = Data(repeating: 0x55, count: 64 * 1024)
        for _ in 0..<1000 {
            var chunkBuf = upstreamChannel.allocator.buffer(capacity: chunkPayload.count)
            chunkBuf.writeBytes(chunkPayload)
            try upstreamChannel.writeInbound(chunkBuf)

            // Drain downstream outbound buffer to avoid memory buildup in test harness
            while let _: ByteBuffer = try downstreamChannel.readOutbound() {}
        }

        try upstreamChannel.close().wait()
        wait(for: [sessionCompletedExpectation], timeout: 2.0)

        // Verify accurate total size accounting
        XCTAssertEqual(finalResponse?.statusCode, 200)
        XCTAssertEqual(finalResponse?.bodySize, 1000 * 64 * 1024)
        // Verify capture retention capped at exactly 1 MB
        XCTAssertEqual(finalResponse?.bodyData?.count, 1024 * 1024)
        XCTAssertTrue(finalResponse?.bodyTruncated == true)

        // Verify timing profile chunk cap (512 max samples + 489 omitted from 1001 total chunks)
        XCTAssertEqual(finalProfile?.chunks.count, 512)
        XCTAssertEqual(finalProfile?.omittedChunkCount, 489)
        XCTAssertEqual(finalProfile?.transfer?.transferBodyByteCount, 1000 * 64 * 1024)
    }

    func testMediaDetectorAndInspectionOnTruncatedStreamSession() throws {
        let manifestPrefix = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-STREAM-INF:BANDWIDTH=3200000,RESOLUTION=1920x1080
        video/1080/prog.m3u8
        """
        let truncatedBody = Data(manifestPrefix.utf8)

        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .http,
                host: "cdn.example.com",
                port: 80,
                path: "/hls/master.m3u8",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [
                    HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")
                ],
                bodyData: truncatedBody,
                bodySize: 10 * 1024 * 1024, // 10 MB total
                bodyTruncated: true
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )

        XCTAssertEqual(MediaDetector.mediaType(for: session), .hls)
        XCTAssertEqual(session.response?.bodySize, 10 * 1024 * 1024)
        XCTAssertTrue(session.response?.bodyTruncated == true)
        XCTAssertEqual(session.response?.bodyData?.count, truncatedBody.count)
    }

    func testCustomConfiguredBodyRetentionLimitCappedAccurately() throws {
        let loop = EmbeddedEventLoop()
        let downstreamChannel = EmbeddedChannel(loop: loop)
        let upstreamChannel = EmbeddedChannel(loop: loop)

        let request = HTTPProxyRequest(
            kind: .standard,
            method: "GET",
            version: "HTTP/1.1",
            host: "api.example.com",
            port: 80,
            path: "/feed.json",
            headers: [],
            body: Data()
        )

        let sessionCompletedExpectation = expectation(description: "Session completed")
        let customCap = 256 * 1024 // 256 KB custom limit
        let accumulator = BoundedCaptureAccumulator(limit: customCap)

        var finalResponse: CapturedResponse?

        let forwarder = StreamingUpstreamForwarder(
            request: request,
            upstreamScheme: .http,
            keepConnectionOpen: true,
            downstreamChannel: downstreamChannel,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(),
            timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
            boundedCaptureAccumulator: accumulator,
            sessionRecorder: nil,
            sessionIDTask: Task { nil },
            onSessionCompleted: { response, _ in
                finalResponse = response
                sessionCompletedExpectation.fulfill()
            },
            onSessionFailed: { error in
                XCTFail("Unexpected failure: \(error)")
            },
            onConnectionDone: { _ in }
        )

        try upstreamChannel.pipeline.addHandler(forwarder).wait()

        let headerText = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 524288\r\n\r\n"
        var headerBuf = upstreamChannel.allocator.buffer(capacity: headerText.utf8.count)
        headerBuf.writeString(headerText)
        try upstreamChannel.writeInbound(headerBuf)

        // Write 512 KB of data (exceeding the 256 KB custom limit)
        let dataChunk = [UInt8](repeating: 0x41, count: 64 * 1024)
        for _ in 0..<8 {
            var chunkBuf = upstreamChannel.allocator.buffer(capacity: dataChunk.count)
            chunkBuf.writeBytes(dataChunk)
            try upstreamChannel.writeInbound(chunkBuf)
            while let _: ByteBuffer = try downstreamChannel.readOutbound() {}
        }

        if upstreamChannel.isActive { try upstreamChannel.close().wait() }
        wait(for: [sessionCompletedExpectation], timeout: 2.0)

        XCTAssertEqual(finalResponse?.statusCode, 200)
        XCTAssertEqual(finalResponse?.bodySize, 512 * 1024)
        XCTAssertEqual(finalResponse?.bodyData?.count, customCap)
        XCTAssertTrue(finalResponse?.bodyTruncated == true)
    }
}
