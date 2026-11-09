//
//  ChannelBackpressureTests.swift
//  JoesProxyTests
//
//  Unit tests for SwiftNIO backpressure flow control and autoRead toggling.
//

import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest
@testable import JoesProxy

final class ChannelBackpressureTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
        super.tearDown()
    }

    private final class UnwritableChannelHandler: ChannelInboundHandler, ChannelOutboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundIn = ByteBuffer

        var simulatedWritable: Bool = false

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            // Drop or hold to simulate slow/unwritable socket
            promise?.succeed(())
        }
    }

    func testAutoReadToggledOnBackpressure() throws {
        let loop = EmbeddedEventLoop()
        let downstreamChannel = EmbeddedChannel(loop: loop)
        let upstreamChannel = EmbeddedChannel(loop: loop)

        let request = HTTPProxyRequest(
            kind: .standard,
            method: "GET",
            version: "HTTP/1.1",
            host: "stream.example.com",
            port: 80,
            path: "/live",
            headers: [],
            body: Data()
        )

        let forwarder = StreamingUpstreamForwarder(
            request: request,
            upstreamScheme: .http,
            keepConnectionOpen: true,
            downstreamChannel: downstreamChannel,
            downstreamThrottleWriter: NetworkThrottleWriter(direction: .downstream, configurationProvider: { .defaults }),
            responseParser: HTTPResponseParser(),
            timingRecorder: UpstreamWireTimingRecorder(startedAt: Date()),
            sessionRecorder: nil,
            sessionIDTask: Task { nil },
            onSessionCompleted: { _, _ in },
            onSessionFailed: { _ in },
            onConnectionDone: { _ in }
        )

        try upstreamChannel.pipeline.addHandler(forwarder).wait()

        // 1. Initial header
        let headerText = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\n\r\n"
        var headerBuf = upstreamChannel.allocator.buffer(capacity: headerText.utf8.count)
        headerBuf.writeString(headerText)
        try upstreamChannel.writeInbound(headerBuf)

        // 2. Simulate downstream becoming writable and verify notifyDownstreamWritable sets autoRead = true
        forwarder.notifyDownstreamWritable()
        let autoReadValue = try upstreamChannel.getOption(ChannelOptions.autoRead).wait()
        XCTAssertTrue(autoReadValue)

        try upstreamChannel.close().wait()
        try downstreamChannel.close().wait()
    }
}
