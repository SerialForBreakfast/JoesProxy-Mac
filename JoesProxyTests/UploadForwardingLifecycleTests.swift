import NIOCore
import NIOPosix
import XCTest
@testable import JoesProxy

final class UploadForwardingLifecycleTests: XCTestCase {
    func testShutdownClosesSocketButRetainsWorkerUntilFinalCallback() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let lifecycle = UploadForwardingLifecycle()
        let worker = try XCTUnwrap(lifecycle.begin(on: channel))
        let drain = Task { await lifecycle.stopAndDrain() }
        try await channel.closeFuture.get()
        XCTAssertEqual(lifecycle.activeCount, 1, "Closing the socket must not retire suspended disk work")
        XCTAssertNil(lifecycle.begin(on: channel), "Shutdown must reject late workers")
        // Model a disk completion arriving after socket close, while the loop is still owned.
        try await channel.eventLoop.submit {}.get()
        lifecycle.finish(worker)
        await drain.value
        XCTAssertEqual(lifecycle.activeCount, 0)
        await lifecycle.stopAndDrain()
        try await group.shutdownGracefully()
    }

    func testDrainWaitsForEveryWorkerAndCannotBeCancelledEarly() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let lifecycle = UploadForwardingLifecycle()
        let first = try XCTUnwrap(lifecycle.begin(on: channel))
        let second = try XCTUnwrap(lifecycle.begin(on: channel))
        let drain = Task { await lifecycle.stopAndDrain() }
        try await channel.closeFuture.get()
        drain.cancel()
        lifecycle.finish(first)
        lifecycle.finish(first)
        XCTAssertEqual(lifecycle.activeCount, 1)
        try await channel.eventLoop.submit {}.get()
        lifecycle.finish(second)
        await drain.value
        XCTAssertEqual(lifecycle.activeCount, 0)
        XCTAssertNil(lifecycle.begin(on: channel))
        try await group.shutdownGracefully()
    }
}
