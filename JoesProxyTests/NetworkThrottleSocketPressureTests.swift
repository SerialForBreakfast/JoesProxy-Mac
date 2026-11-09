import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import JoesProxy

final class NetworkThrottleSocketPressureTests: XCTestCase {
    private final class Receiver: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let lock = NSLock()
        private var count = 0
        private var corrupt = false
        private let expected: ByteBuffer
        init(byteCount: Int) {
            var bytes = ByteBufferAllocator().buffer(capacity: byteCount)
            bytes.writeRepeatingByte(42, count: byteCount)
            expected = bytes
        }
        var snapshot: (Int, Bool) { lock.withLock { (count, corrupt) } }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            let bad = expected.getSlice(at: 0, length: buffer.readableBytes) != buffer
            lock.withLock { count += buffer.readableBytes; corrupt = corrupt || bad }
        }
    }

    private func waitUntil(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw TestFailure.deadline(stage) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum TestFailure: Error { case deadline(String) }

    func testRealSocketPressureDrainDisconnectAndRetry() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        var channels: [Channel] = []
        let budget = RelayBacklogBudget()
        let byteCount = 8 * 1_024 * 1_024
        do {
            // A failed transfer is followed by a fresh successful connection, never an automatic replay.
            for cycle in 0..<3 {
                let accepted = group.next().makePromise(of: Channel.self)
                let receiver = Receiver(byteCount: byteCount)
                let listener = try await ServerBootstrap(group: group)
                    .childChannelOption(ChannelOptions.autoRead, value: false)
                    .childChannelInitializer { channel in
                        channel.pipeline.addHandler(receiver).map { accepted.succeed(channel) }
                    }.bind(host: "127.0.0.1", port: 0).get()
                channels.append(listener)
                let destination = try await ClientBootstrap(group: group)
                    .channelOption(ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 4_096, high: 8_192))
                    .connect(to: try XCTUnwrap(listener.localAddress)).get()
                channels.append(destination)
                let sink = try await accepted.futureResult.get()
                channels.append(sink)
                let writer = NetworkThrottleWriter(direction: .downstream,
                    configurationProvider: { .defaults }, relayBudget: budget)
                let diagnostics = RequestTransportDiagnostics()
                let started = ContinuousClock.now
                // The receiver deliberately does not read. This exercises real kernel socket pressure.
                let delivery = destination.eventLoop.flatSubmit {
                    var bytes = destination.allocator.buffer(capacity: byteCount)
                    bytes.writeRepeatingByte(42, count: byteCount)
                    return writer.relay(bytes, to: destination, readingFrom: destination, diagnostics: diagnostics)
                }
                try await waitUntil("socket pressure") { !destination.isWritable && budget.snapshot.operations > 0 }
                XCTAssertGreaterThan(diagnostics.snapshot().pendingWrites, 0)
                XCTAssertEqual(receiver.snapshot.0, 0)
                XCTAssertLessThanOrEqual(budget.snapshot.bytes, byteCount)
                print("Synthetic socket pressure reached: cycle=\(cycle) queued=\(budget.snapshot.bytes)")
                if cycle == 1 {
                    try await destination.close().get()
                    do { try await delivery.get(); XCTFail("Interrupted socket must fail delivery") }
                    catch { }
                    XCTAssertEqual(diagnostics.snapshot().deliveryState, "write_failed")
                } else {
                    try await sink.setOption(ChannelOptions.autoRead, value: true).get()
                    sink.read()
                    do {
                        try await waitUntil("receiver delivery") { receiver.snapshot.0 == byteCount && budget.snapshot.operations == 0 }
                    } catch {
                        print("Synthetic socket drain deadline: received=\(receiver.snapshot.0) queued=\(budget.snapshot.bytes) operations=\(budget.snapshot.operations)")
                        throw error
                    }
                    try await delivery.get()
                    XCTAssertFalse(receiver.snapshot.1)
                    XCTAssertEqual(diagnostics.snapshot().bytesWriteCompleted, byteCount)
                    XCTAssertEqual(diagnostics.snapshot().deliveryState, "writes_completed")
                }
                try await waitUntil("queue drain") { budget.snapshot.bytes == 0 && budget.snapshot.operations == 0 }
                XCTAssertEqual(diagnostics.snapshot().pendingWrites, 0)
                XCTAssertLessThanOrEqual(budget.snapshot.peakBytes, byteCount)
                let elapsed = started.duration(to: .now).components
                print("Synthetic socket pressure: cycle=\(cycle) interrupted=\(cycle == 1) peakBytes=\(budget.snapshot.peakBytes) drainedBytes=0 drainedOperations=0 elapsedSeconds=\(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)")
                for channel in channels { try? await channel.close().get() }
                channels.removeAll()
            }
            try await group.shutdownGracefully()
        } catch {
            for channel in channels { try? await channel.close().get() }
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
