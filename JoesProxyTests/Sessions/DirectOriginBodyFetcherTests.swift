import Network
import XCTest
@testable import JoesProxy

/// Integration coverage for `URLSessionDirectOriginBodyFetcher` against a real local HTTP server —
/// proves the actual network mechanics (streaming via `URLSession.bytes(for:)`, ceiling
/// enforcement, header forwarding) work, not just the mock used by `MCPOpenWorldToolsTests`.
///
/// P3 (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): on-demand body
/// recapture needs its own ceiling larger than `CaptureBodyLimiter`'s 1MB live-capture cap — these
/// tests prove a body over that 1MB cap is retrieved in full when under the recapture ceiling, and
/// is stopped (not buffered without limit) when it exceeds even that.
final class DirectOriginBodyFetcherTests: XCTestCase {
    private final class RecordingHTTPTestServer {
        private let queue = DispatchQueue(label: "com.joesproxyapp.tests.direct-origin", qos: .userInitiated)
        private var listener: NWListener?
        private let responseBody: Data
        private let lock = NSLock()
        private var lastRequestString: String?

        init(responseBody: Data) {
            self.responseBody = responseBody
        }

        var port: UInt16 {
            listener?.port?.rawValue ?? 0
        }

        var recordedRequestString: String? {
            lock.withLock { lastRequestString }
        }

        func start() async throws {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16.random(in: 20_000...60_000))!)
            self.listener = listener
            let responseBody = self.responseBody

            listener.newConnectionHandler = { [queue, weak self] connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                    if let data, let requestString = String(data: data, encoding: .utf8) {
                        self?.lock.withLock { self?.lastRequestString = requestString }
                    }
                    let header =
                        "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: application/octet-stream\r\n" +
                        "Content-Length: \(responseBody.count)\r\n" +
                        "Connection: close\r\n" +
                        "\r\n"
                    var payload = Data(header.utf8)
                    payload.append(responseBody)
                    connection.send(content: payload, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                final class ResumeState { var didResume = false }
                let state = ResumeState()
                listener.stateUpdateHandler = { stateUpdate in
                    guard !state.didResume else { return }
                    switch stateUpdate {
                    case .ready:
                        state.didResume = true
                        continuation.resume()
                    case .failed(let error):
                        state.didResume = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener?.cancel()
        }
    }

    private func sampleRequest(port: UInt16, headers: [HTTPHeaderField] = []) -> CapturedRequest {
        CapturedRequest(
            method: "GET",
            scheme: .http,
            host: "127.0.0.1",
            port: Int(port),
            path: "/large-body",
            headers: headers,
            bodyData: nil,
            bodySize: nil
        )
    }

    func testFetchRetrievesFullBodyLargerThanOneMegabyteCaptureLimit() async throws {
        // Deliberately larger than CaptureBodyLimiter's 1MB live-capture cap — proves this path
        // actually bypasses that cap rather than silently inheriting it.
        let fullBody = Data(repeating: 0x5A, count: 3 * 1_048_576)
        let server = RecordingHTTPTestServer(responseBody: fullBody)
        try await server.start()
        defer { server.stop() }

        let fetcher = URLSessionDirectOriginBodyFetcher()
        let result = try await fetcher.fetch(
            request: sampleRequest(port: server.port),
            includeCredentials: false,
            maxBodyBytes: 5 * 1_048_576
        )

        XCTAssertEqual(result.bodyData.count, fullBody.count)
        XCTAssertEqual(result.bodyData, fullBody)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertFalse(result.bodyTruncatedAtCeiling)
    }

    func testFetchStopsAtCeilingRatherThanBufferingUnboundedResponse() async throws {
        let oversizedBody = Data(repeating: 0x42, count: 2 * 1_048_576)
        let server = RecordingHTTPTestServer(responseBody: oversizedBody)
        try await server.start()
        defer { server.stop() }

        let ceiling = 1_048_576
        let fetcher = URLSessionDirectOriginBodyFetcher()
        let result = try await fetcher.fetch(
            request: sampleRequest(port: server.port),
            includeCredentials: false,
            maxBodyBytes: ceiling
        )

        XCTAssertEqual(result.bodyData.count, ceiling)
        XCTAssertTrue(result.bodyTruncatedAtCeiling)
    }

    func testFetchStripsCredentialHeadersByDefaultButForwardsWhenIncluded() async throws {
        let server = RecordingHTTPTestServer(responseBody: Data("ok".utf8))
        try await server.start()
        defer { server.stop() }

        let headers = [HTTPHeaderField(name: "Authorization", value: "Bearer secret-token")]
        let fetcher = URLSessionDirectOriginBodyFetcher()

        _ = try await fetcher.fetch(
            request: sampleRequest(port: server.port, headers: headers),
            includeCredentials: false,
            maxBodyBytes: SessionBodyRecaptureBudget.maxBodyBytes
        )
        XCTAssertFalse(server.recordedRequestString?.contains("secret-token") ?? true)

        _ = try await fetcher.fetch(
            request: sampleRequest(port: server.port, headers: headers),
            includeCredentials: true,
            maxBodyBytes: SessionBodyRecaptureBudget.maxBodyBytes
        )
        XCTAssertTrue(server.recordedRequestString?.contains("secret-token") ?? false)
    }
}
