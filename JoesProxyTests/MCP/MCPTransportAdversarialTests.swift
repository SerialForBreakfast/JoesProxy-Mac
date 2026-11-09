import Foundation
import NIO
import NIOPosix
import XCTest
@testable import JoesProxy

@MainActor
final class MCPTransportAdversarialTests: XCTestCase {
    private struct TestStack {
        var transport: MCPNIOHTTPTransport
        var protocolService: MCPProtocolService
        var clientRegistry: MCPClientRegistry
        var port: UInt16
    }

    func testDuplicateContentLengthHeaderRejected() async throws {
        let stack = try await startTransport()
        defer { Task { await stack.transport.shutdown() } }
        let rawResponse = try await sendRawRequest(
            buildRawRequest(lines: [
                "POST /mcp HTTP/1.1",
                "Host: 127.0.0.1:\(stack.port)",
                "Content-Length: 1",
                "Content-Length: 2"
            ], body: "x"),
            port: stack.port
        )
        XCTAssertTrue(rawResponse.hasPrefix("HTTP/1.1 400"), rawResponse)
    }

    func testContentLengthWithChunkedTransferEncodingRejected() async throws {
        let stack = try await startTransport()
        defer { Task { await stack.transport.shutdown() } }
        let rawResponse = try await sendRawRequest(
            buildRawRequest(
                lines: [
                    "POST /mcp HTTP/1.1",
                    "Host: 127.0.0.1:\(stack.port)",
                    "Content-Length: 2",
                    "Transfer-Encoding: chunked"
                ],
                body: "0\r\n\r\n"
            ),
            port: stack.port
        )
        XCTAssertTrue(rawResponse.hasPrefix("HTTP/1.1 400"), rawResponse)
    }

    func testTypedInitializeResponseRoundTrips() async throws {
        let stack = try await startTransport()
        defer { Task { await stack.transport.shutdown() } }
        let enrollment = try stack.clientRegistry.enroll(displayName: "Adversarial")
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{}}}"
        let response = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(enrollment.plaintextCredential)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(stack.port)",
                "accept": "application/json, text/event-stream"
            ],
            body: Data(json.utf8)
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertNotNil(response.headerValue(named: MCPNetworkConstants.sessionIDHeader))
    }

    func testEmptyChunkedPOSTIsRejectedWithoutAuth() async throws {
        let stack = try await startTransport()
        defer { Task { await stack.transport.shutdown() } }
        let rawResponse = try await sendRawRequest(
            buildRawRequest(
                lines: [
                    "POST /mcp HTTP/1.1",
                    "Host: 127.0.0.1:\(stack.port)",
                    "Accept: application/json, text/event-stream",
                    "Transfer-Encoding: chunked"
                ],
                body: "0\r\n\r\n"
            ),
            port: stack.port
        )
        XCTAssertTrue(rawResponse.hasPrefix("HTTP/1.1 401"), rawResponse)
    }

    func testChunkedAggregateBodyLimitRejected() async throws {
        let stack = try await startTransport()
        defer { Task { await stack.transport.shutdown() } }
        let chunkHex = String(1024, radix: 16)
        let chunk = String(repeating: "A", count: 1024)
        var chunkedBody = ""
        let chunksNeeded = (MCPNetworkConstants.maxRequestBodyBytes / 1024) + 1
        chunkedBody.reserveCapacity(chunksNeeded * (chunkHex.count + chunk.count + 4))
        for _ in 0..<chunksNeeded {
            chunkedBody += "\(chunkHex)\r\n\(chunk)\r\n"
        }
        chunkedBody += "0\r\n\r\n"
        let rawResponse = try await sendRawRequest(
            buildRawRequest(
                lines: [
                    "POST /mcp HTTP/1.1",
                    "Host: 127.0.0.1:\(stack.port)",
                    "Transfer-Encoding: chunked"
                ],
                body: chunkedBody
            ),
            port: stack.port
        )
        XCTAssertTrue(rawResponse.hasPrefix("HTTP/1.1 413"), rawResponse)
    }

    func testMalformedChunkedFramingDoesNotLeaveTransportUnresponsive() async throws {
        let stack = try await startTransport()
        defer { Task { await stack.transport.shutdown() } }
        _ = try? await sendRawRequest(
            buildRawRequest(
                lines: [
                    "POST /mcp HTTP/1.1",
                    "Host: 127.0.0.1:\(stack.port)",
                    "Transfer-Encoding: chunked"
                ],
                body: "5\r\nHELLO\r\nZZZZ\r\n\r\n"
            ),
            port: stack.port
        )
        let followUp = try await sendRawRequest(
            buildRawRequest(
                lines: [
                    "POST /mcp HTTP/1.1",
                    "Host: 127.0.0.1:\(stack.port)",
                    "Content-Length: 0",
                    "Accept: application/json, text/event-stream"
                ]
            ),
            port: stack.port
        )
        XCTAssertFalse(followUp.isEmpty, followUp)
    }

    func testEarlyAbortMidUploadStillReceives413() async throws {
        let stack = try await startTransport()
        defer { Task { await stack.transport.shutdown() } }
        let enrollment = try stack.clientRegistry.enroll(displayName: "Abort")
        let oversizedBody = Data(repeating: 0x41, count: MCPNetworkConstants.maxRequestBodyBytes + 1)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(stack.port)\(MCPNetworkConstants.endpointPath)")!)
        request.httpMethod = "POST"
        request.httpBody = oversizedBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(enrollment.plaintextCredential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)
    }

    func testPipelinedSecondRequestDoesNotProduceDoubleResponse() async throws {
        let stack = try await startTransport()
        defer { Task { await stack.transport.shutdown() } }
        let first = buildRawRequest(
            lines: [
                "POST /mcp HTTP/1.1",
                "Host: 127.0.0.1:\(stack.port)",
                "Content-Length: 0",
                "Accept: application/json, text/event-stream"
            ]
        )
        let second = buildRawRequest(
            lines: [
                "POST /mcp HTTP/1.1",
                "Host: 127.0.0.1:\(stack.port)",
                "Content-Length: 0",
                "Accept: application/json, text/event-stream"
            ]
        )
        let rawResponse = try await sendRawRequest(first + second, port: stack.port)
        let statusLines = rawResponse.components(separatedBy: "\r\n").filter { $0.hasPrefix("HTTP/1.1") }
        XCTAssertEqual(statusLines.count, 1, rawResponse)
    }

    private func buildRawRequest(lines: [String], body: String = "") -> String {
        lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    private func startTransport() async throws -> TestStack {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-adv.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-adv.json"),
            credentialStore: MCPInMemoryCredentialStore()
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-adv.json"))
        auditStore.load()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore(),
            boundPort: 0
        )
        let transport = MCPNIOHTTPTransport(protocolService: protocolService)
        try await transport.start(port: 0)
        let port = try XCTUnwrap(transport.boundPort)
        protocolService.rebindLoopbackPort(port)
        return TestStack(
            transport: transport,
            protocolService: protocolService,
            clientRegistry: clientRegistry,
            port: port
        )
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func sendRawRequest(_ request: String, port: UInt16) async throws -> String {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let promise = group.next().makePromise(of: String.self)
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(MCPAdversarialRawCollector(promise: promise))
            }
            .connect(host: "127.0.0.1", port: Int(port))
            .get()
        var buffer = channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try await channel.writeAndFlush(buffer).get()
        return try await promise.futureResult.get()
    }
}

private final class MCPAdversarialRawCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<String>
    private var bytes: [UInt8] = []
    private var completed = false

    init(promise: EventLoopPromise<String>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let incoming = buffer.readBytes(length: buffer.readableBytes) {
            bytes.append(contentsOf: incoming)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        promise.succeed(String(decoding: bytes, as: UTF8.self))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        completed = true
        promise.succeed(String(decoding: bytes, as: UTF8.self))
        context.close(promise: nil)
    }
}
