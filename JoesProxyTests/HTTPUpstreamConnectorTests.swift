import Foundation
import Network
import NIOPosix
import XCTest
@testable import JoesProxy

/// Confirms `HTTPUpstreamConnector` derives the outbound request line's request-target, and the
/// `Host` header, from whatever `HTTPProxyRequest.host`/`.path` it's given — already-correct
/// behavior today, but now load-bearing for Map Remote's `remotePath` override (AI's ADR
/// `ADR-MCP-Agent-Diagnostic-Skill.md`-adjacent Feature 1 work): a path override only reaches the
/// real wire correctly if the connector keeps using whatever `path` `ConnectionHandler` puts on
/// the remapped request, exactly as it already does for `host`.
final class HTTPUpstreamConnectorTests: XCTestCase {
    /// Minimal loopback TCP listener that captures the first request's raw bytes (mirrors
    /// `MCPSelfValidationFixtureOrigin`'s connection-handling pattern) and replies with a bare
    /// 200 so the connector's `execute` completes normally.
    private final class CapturingServer {
        private let queue = DispatchQueue(label: "com.joesproxyapp.tests.capturingserver")
        private var listener: NWListener?
        private let capturedBox = CapturedBox()

        final class CapturedBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: String?
            func set(_ newValue: String) {
                lock.withLock { value = newValue }
            }
            func get() -> String? {
                lock.withLock { value }
            }
        }

        var port: UInt16 { listener?.port?.rawValue ?? 0 }

        func start() async throws {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16.random(in: 20_000...60_000))!)
            self.listener = listener
            let capturedBox = self.capturedBox
            listener.newConnectionHandler = { connection in
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                    if let data, let text = String(data: data, encoding: .utf8) {
                        capturedBox.set(text)
                    }
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        continuation.resume()
                    case .failed(let error):
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func capturedRequestText(timeout: TimeInterval = 2) async -> String? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let text = capturedBox.get() {
                    return text
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return capturedBox.get()
        }

        func stop() {
            listener?.cancel()
        }
    }

    func testUpstreamRequestUsesOverriddenHostAndPath() async throws {
        let server = CapturingServer()
        try await server.start()
        defer { server.stop() }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let connector = HTTPUpstreamConnector(group: group)

        let request = HTTPProxyRequest(
            kind: .standard,
            method: "GET",
            version: "HTTP/1.1",
            host: "127.0.0.1",
            port: Int(server.port),
            // Simulates ConnectionHandler's `path: requestTarget ?? request.path` with a Map
            // Remote path override resolved to a different path than the original request had.
            path: "/v2/items?y=2",
            headers: [],
            body: Data()
        )

        let upstreamResponse = try await connector.execute(request, scheme: .http).get()

        XCTAssertFalse(upstreamResponse.data.isEmpty)
        XCTAssertNotNil(upstreamResponse.wireProfile.connectionEstablishedAt)
        XCTAssertNotNil(upstreamResponse.wireProfile.requestSentAt)
        XCTAssertNotNil(upstreamResponse.wireProfile.firstResponseByteAt)
        XCTAssertNotNil(upstreamResponse.wireProfile.responseCompletedAt)
        XCTAssertFalse(upstreamResponse.wireProfile.chunks.isEmpty)
        XCTAssertGreaterThan(upstreamResponse.wireProfile.transfer?.headerByteCount ?? 0, 0)

        let captured = await server.capturedRequestText()
        let requestText = try XCTUnwrap(captured, "upstream server never received a request")
        XCTAssertTrue(
            requestText.hasPrefix("GET /v2/items?y=2 HTTP/1.1\r\n"),
            "request line must use the overridden request-target, got: \(requestText.prefix(80))"
        )
        XCTAssertTrue(
            requestText.localizedCaseInsensitiveContains("Host: 127.0.0.1"),
            "Host header must reflect the connector's target host, got: \(requestText.prefix(300))"
        )
    }
}
