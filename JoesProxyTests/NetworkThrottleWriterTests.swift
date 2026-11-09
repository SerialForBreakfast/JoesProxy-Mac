import NIOCore
import NIOEmbedded
import XCTest
@testable import JoesProxy

final class NetworkThrottleWriterTests: XCTestCase {
    private final class HeldWrites: ChannelOutboundHandler {
        typealias OutboundIn = ByteBuffer
        var held: [(ByteBuffer, EventLoopPromise<Void>?)] = []
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            held.append((unwrapOutboundIn(data), promise))
        }
        func drain() -> [ByteBuffer] {
            let batch = held
            held = []
            for (_, promise) in batch { promise?.succeed(()) }
            return batch.map(\.0)
        }
        func fail() {
            let batch = held
            held = []
            for (_, promise) in batch { promise?.fail(ChannelError.ioOnClosedChannel) }
        }
    }

    func testRelayPausesUntilAcceptedWritesDrainAndPreservesBytes() throws {
        let loop = EmbeddedEventLoop()
        let source = EmbeddedChannel(loop: loop)
        let sink = HeldWrites()
        let destination = EmbeddedChannel(handler: sink, loop: loop)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
        try source.connect(to: address).wait()
        try destination.connect(to: address).wait()
        let writer = NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults })
        var first = destination.allocator.buffer(capacity: 16_384)
        first.writeRepeatingByte(7, count: 16_384)
        var second = destination.allocator.buffer(capacity: 16_384)
        second.writeRepeatingByte(9, count: 16_384)
        let diagnostics = RequestTransportDiagnostics()
        let firstWrite = writer.relay(first, to: destination, readingFrom: source, diagnostics: diagnostics)
        let secondWrite = writer.relay(second, to: destination, readingFrom: source, diagnostics: diagnostics)
        loop.run()
        // EmbeddedChannel.getOption(autoRead) always returns true; inspect recorded writes.
        XCTAssertEqual(source.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool, false)
        XCTAssertEqual(writer.pendingRelayBytes, 32_768)
        XCTAssertEqual(diagnostics.snapshot().pendingWrites, 2)
        XCTAssertEqual(diagnostics.snapshot().deliveryState, "pending")
        XCTAssertEqual(sink.drain(), [first, second])
        loop.run()
        try firstWrite.wait()
        try secondWrite.wait()
        XCTAssertEqual(writer.pendingRelayBytes, 0)
        XCTAssertEqual(diagnostics.snapshot().pendingWrites, 0)
        XCTAssertEqual(diagnostics.snapshot().bytesWriteCompleted, 32_768)
        XCTAssertEqual(source.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool, true)
        _ = try source.finish()
        _ = try destination.finish()
    }

    func testPlannedChunkSizesSplitByMaximumChunkSize() {
        XCTAssertEqual(
            NetworkThrottleWriter.plannedChunkSizes(byteCount: 40_000, maxChunkSize: 16_384),
            [16_384, 16_384, 7_232]
        )
    }

    func testAggregatePressureUsesHysteresisAndReturnsToBaseline() {
        let budget = RelayBacklogBudget()
        var states: [Bool] = []
        let registration = budget.register { states.append($0) }
        budget.adjust(bytes: 32 * 1_024 * 1_024, operations: 2)
        XCTAssertTrue(budget.snapshot.paused)
        budget.adjust(bytes: -8 * 1_024 * 1_024, operations: -1)
        XCTAssertTrue(budget.snapshot.paused)
        budget.adjust(bytes: -24 * 1_024 * 1_024, operations: -1)
        XCTAssertEqual(budget.snapshot.bytes, 0)
        XCTAssertEqual(budget.snapshot.operations, 0)
        XCTAssertEqual(states, [false, true, false])
        budget.unregister(registration)
    }

    func testDelayedAggregatePauseUsesCurrentPressureOnSourceLoop() throws {
        let sourceLoop = EmbeddedEventLoop()
        let destinationLoop = EmbeddedEventLoop()
        let source = EmbeddedChannel(loop: sourceLoop)
        let destination = EmbeddedChannel(loop: destinationLoop)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
        try source.connect(to: address).wait()
        try destination.connect(to: address).wait()
        let budget = RelayBacklogBudget()
        let writer = NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }, relayBudget: budget)
        try source.setOption(ChannelOptions.autoRead, value: false).wait()

        budget.adjust(bytes: 32 * 1_024 * 1_024, operations: 1)
        writer.reconcileAggregatePressure(from: source, to: destination)
        // A concurrent delivery drains pressure before the queued callback reaches source.
        budget.adjust(bytes: -32 * 1_024 * 1_024, operations: -1)
        writer.resumeReadsIfDrained(from: source, to: destination)
        destinationLoop.run()
        sourceLoop.run()
        destinationLoop.run()
        sourceLoop.run()

        XCTAssertEqual(source.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool, true)
        XCTAssertEqual(budget.snapshot.bytes, 0)
        _ = try source.finish()
        _ = try destination.finish()
    }

    func testQueuedResumeRechecksPressureBeforeEnablingSourceReads() throws {
        let sourceLoop = EmbeddedEventLoop()
        let destinationLoop = EmbeddedEventLoop()
        let source = EmbeddedChannel(loop: sourceLoop)
        let destination = EmbeddedChannel(loop: destinationLoop)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
        try source.connect(to: address).wait()
        try destination.connect(to: address).wait()
        let budget = RelayBacklogBudget()
        let writer = NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }, relayBudget: budget)
        try source.setOption(ChannelOptions.autoRead, value: false).wait()

        writer.resumeReadsIfDrained(from: source, to: destination)
        destinationLoop.run()
        // The destination approved resuming, but another relay saturates before source applies it.
        budget.adjust(bytes: 32 * 1_024 * 1_024, operations: 1)
        sourceLoop.run()
        XCTAssertEqual(source.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool, false)

        budget.adjust(bytes: -32 * 1_024 * 1_024, operations: -1)
        writer.reconcileAggregatePressure(from: source, to: destination)
        sourceLoop.run()
        destinationLoop.run()
        sourceLoop.run()
        XCTAssertEqual(source.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool, true)
        _ = try source.finish()
        _ = try destination.finish()
    }

    func testQueuedResumeCannotOvertakeNewSourceAdmission() throws {
        let sourceLoop = EmbeddedEventLoop()
        let destinationLoop = EmbeddedEventLoop()
        let source = EmbeddedChannel(loop: sourceLoop)
        let sink = HeldWrites()
        let destination = EmbeddedChannel(handler: sink, loop: destinationLoop)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
        try source.connect(to: address).wait()
        try destination.connect(to: address).wait()
        let budget = RelayBacklogBudget()
        let writer = NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }, relayBudget: budget)
        writer.resumeReadsIfDrained(from: source, to: destination)
        destinationLoop.run()

        var payload = destination.allocator.buffer(capacity: 64)
        payload.writeRepeatingByte(42, count: 64)
        let delivery = writer.relay(payload, to: destination, readingFrom: source)
        sourceLoop.run()
        destinationLoop.run()
        sourceLoop.run()
        XCTAssertEqual(writer.pendingRelayAdmissions, 1)
        XCTAssertEqual(source.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool, false)

        XCTAssertEqual(sink.drain(), [payload])
        sourceLoop.run()
        destinationLoop.run()
        sourceLoop.run()
        try delivery.wait()
        XCTAssertEqual(writer.pendingRelayAdmissions, 0)
        XCTAssertEqual(budget.snapshot.bytes, 0)
        XCTAssertEqual(source.options.first { $0.option is ChannelOptions.Types.AutoReadOption }?.value as? Bool, true)
        _ = try source.finish()
        _ = try destination.finish()
    }

    func testFailedRelayReleasesAdmissionAndClosesBothChannels() throws {
        let loop = EmbeddedEventLoop()
        let source = EmbeddedChannel(loop: loop)
        let sink = HeldWrites()
        let destination = EmbeddedChannel(handler: sink, loop: loop)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
        try source.connect(to: address).wait()
        try destination.connect(to: address).wait()
        let budget = RelayBacklogBudget()
        let writer = NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }, relayBudget: budget)
        var payload = destination.allocator.buffer(capacity: 64)
        payload.writeRepeatingByte(42, count: 64)
        let delivery = writer.relay(payload, to: destination, readingFrom: source)
        loop.run()
        XCTAssertEqual(writer.pendingRelayAdmissions, 1)
        sink.fail()
        loop.run()
        XCTAssertThrowsError(try delivery.wait())
        XCTAssertEqual(writer.pendingRelayAdmissions, 0)
        XCTAssertEqual(writer.pendingRelayBytes, 0)
        XCTAssertEqual(budget.snapshot.bytes, 0)
        XCTAssertEqual(budget.snapshot.operations, 0)
        XCTAssertFalse(source.isActive)
        XCTAssertFalse(destination.isActive)
        _ = try source.finish(acceptAlreadyClosed: true)
        _ = try destination.finish(acceptAlreadyClosed: true)
    }

    func testDestinationCloseReleasesDelayedRelayAdmission() throws {
        let loop = EmbeddedEventLoop()
        let source = EmbeddedChannel(loop: loop)
        let destination = EmbeddedChannel(loop: loop)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
        try source.connect(to: address).wait()
        try destination.connect(to: address).wait()
        let budget = RelayBacklogBudget()
        var configuration = NetworkThrottleConfiguration.defaults
        configuration.isEnabled = true
        let writer = NetworkThrottleWriter(direction: .downstream, configurationProvider: { configuration }, relayBudget: budget)
        var payload = destination.allocator.buffer(capacity: 64)
        payload.writeRepeatingByte(42, count: 64)
        let delivery = writer.relay(payload, to: destination, readingFrom: source)
        loop.run()
        XCTAssertEqual(writer.pendingRelayAdmissions, 1)
        try destination.close().wait()
        loop.run()
        XCTAssertThrowsError(try delivery.wait())
        XCTAssertEqual(writer.pendingRelayAdmissions, 0)
        XCTAssertEqual(writer.pendingRelayBytes, 0)
        XCTAssertEqual(budget.snapshot.bytes, 0)
        XCTAssertEqual(budget.snapshot.operations, 0)
        loop.advanceTime(by: .seconds(1))
        XCTAssertNil(try destination.readOutbound(as: ByteBuffer.self))
        _ = try source.finish(acceptAlreadyClosed: true)
        _ = try destination.finish(acceptAlreadyClosed: true)
    }

    func testRepeatedHeldRelayDrainCyclesReturnToBaseline() throws {
        let loop = EmbeddedEventLoop()
        let source = EmbeddedChannel(loop: loop)
        let sink = HeldWrites()
        let destination = EmbeddedChannel(handler: sink, loop: loop)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
        try source.connect(to: address).wait()
        try destination.connect(to: address).wait()
        let writer = NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults })
        let baseline = RelayBacklogBudget.shared.snapshot
        let diagnostics = RequestTransportDiagnostics()
        var transferred = 0
        for cycle in 0..<100 {
            var payloads: [ByteBuffer] = []
            var writes: [EventLoopFuture<Void>] = []
            for index in 0..<4 {
                var payload = destination.allocator.buffer(capacity: 16_384)
                payload.writeRepeatingByte(UInt8((cycle + index) % 256), count: 16_384)
                payloads.append(payload)
                writes.append(writer.relay(payload, to: destination, readingFrom: source, diagnostics: diagnostics))
            }
            loop.run()
            XCTAssertEqual(writer.pendingRelayBytes, 65_536)
            XCTAssertEqual(RelayBacklogBudget.shared.snapshot.bytes, baseline.bytes + 65_536)
            XCTAssertEqual(sink.drain(), payloads)
            loop.run()
            for write in writes { try write.wait() }
            XCTAssertEqual(writer.pendingRelayBytes, 0)
            XCTAssertEqual(diagnostics.snapshot().pendingWrites, 0)
            XCTAssertEqual(RelayBacklogBudget.shared.snapshot.bytes, baseline.bytes)
            XCTAssertEqual(RelayBacklogBudget.shared.snapshot.operations, baseline.operations)
            transferred += 65_536
        }
        XCTAssertEqual(writer.peakRelayBytes, 65_536)
        XCTAssertEqual(diagnostics.snapshot().peakPendingBytes, 65_536)
        XCTAssertEqual(diagnostics.snapshot().bytesWriteCompleted, transferred)
        let evidence = XCTAttachment(string: "Synthetic embedded relay: cycles=100 bytes=\(transferred) peakQueuedBytes=\(writer.peakRelayBytes) finalQueuedBytes=\(writer.pendingRelayBytes). Byte fidelity checked every cycle. Not a real-socket or process-memory measurement.")
        evidence.lifetime = .keepAlways
        add(evidence)
        _ = try source.finish()
        _ = try destination.finish()
    }

    func testThrottledPumpReleasesDelayedWriteOnDisconnect() throws {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        var buffer = channel.allocator.buffer(capacity: 65_536)
        buffer.writeRepeatingByte(3, count: 65_536)
        let pump = ThrottledBufferPump(buffer: buffer, channel: channel, kbps: 8)
        let completion = pump.start(latencyMs: 60_000)
        try channel.close().wait()
        loop.run()
        XCTAssertThrowsError(try completion.wait())
        loop.advanceTime(by: .seconds(60))
        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self))
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    func testPlannedChunkSizesAreEmptyForEmptyPayload() {
        XCTAssertEqual(NetworkThrottleWriter.plannedChunkSizes(byteCount: 0), [])
    }

    func testDelayAfterChunkUsesKilobitsPerSecondRate() {
        let delay = NetworkThrottleWriter.delayAfterChunk(byteCount: 1_000, kbps: 8)

        XCTAssertEqual(delay, .seconds(1))
    }

    func testDelayAfterChunkIsZeroWhenDisabledInputsAreInvalid() {
        XCTAssertEqual(NetworkThrottleWriter.delayAfterChunk(byteCount: 1_000, kbps: 0), .nanoseconds(0))
        XCTAssertEqual(NetworkThrottleWriter.delayAfterChunk(byteCount: 0, kbps: 8), .nanoseconds(0))
    }
}
