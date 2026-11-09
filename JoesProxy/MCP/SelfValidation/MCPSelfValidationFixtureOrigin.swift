import Foundation
import Network

/// Deterministic loopback HTTP origin for self-validation runs (AI-5).
///
/// Concurrency: start/stop are awaited from the main actor; connection handlers run on a private queue.
final class MCPSelfValidationFixtureOrigin {
    struct RouteResponse: Equatable, Sendable {
        var statusCode: Int
        var body: String
        var contentType: String
        var delay: Duration

        init(
            statusCode: Int = 200,
            body: String,
            contentType: String = "text/plain; charset=utf-8",
            delay: Duration = .zero
        ) {
            self.statusCode = statusCode
            self.body = body
            self.contentType = contentType
            self.delay = delay
        }
    }

    private let queue = DispatchQueue(label: "com.joesproxyapp.selfvalidation.fixture", qos: .userInitiated)
    private var listener: NWListener?
    private var routes: [String: RouteResponse] = [:]
    /// Checked, in order, after an exact-path match fails. Lets a fixture serve a whole family of
    /// dynamic paths (e.g. `/v1/sessions/{any-id}/heartbeat`) without registering one exact route
    /// per generated ID — used by the reference "kill one dependency" validation scenario, where
    /// the ID segment is intentionally unpredictable.
    private var suffixRoutes: [(suffix: String, response: RouteResponse)] = []
    private let lock = NSLock()
    private let loopbackOnly: Bool

    var port: UInt16 {
        listener?.port?.rawValue ?? 0
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    init(
        routes: [MCPSelfValidationFixtureRoute: RouteResponse]? = nil,
        exactRoutes: [String: RouteResponse] = [:],
        suffixRoutes: [(suffix: String, response: RouteResponse)] = [],
        loopbackOnly: Bool = false
    ) {
        self.loopbackOnly = loopbackOnly
        if let routes {
            for (route, response) in routes {
                self.routes[route.rawValue] = response
            }
        } else {
            for route in MCPSelfValidationFixtureRoute.allCases {
                self.routes[route.rawValue] = RouteResponse(
                    statusCode: route.defaultStatusCode,
                    body: route.defaultBody,
                    contentType: route.defaultContentType
                )
            }
        }
        for (path, response) in exactRoutes {
            self.routes[path] = response
        }
        self.suffixRoutes = suffixRoutes
    }

    /// Registers a response for any path ending in `suffix` (checked after exact matches, in
    /// registration order). Lets a fixture serve `/v1/sessions/{any-id}/heartbeat`-shaped requests
    /// without knowing the ID in advance.
    func registerSuffixRoute(suffix: String, response: RouteResponse) {
        lock.withLock { suffixRoutes.append((suffix, response)) }
    }

    /// Registers (or replaces) an exact-path response after the fixture is already running — lets a
    /// caller simulate a value changing mid-run (e.g. a bootstrap endpoint handing out a new session
    /// id after a dependency is killed) without tearing down and restarting the fixture.
    func registerExactRoute(path: String, response: RouteResponse) {
        lock.withLock { routes[path] = response }
    }

    func start() async throws {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        let listener = try NWListener(
            using: parameters,
            on: .any
        )
        self.listener = listener

        listener.newConnectionHandler = { [weak self, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
                guard let self else { return }
                let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map(String.init) ?? ""
                let path = Self.path(fromRequestLine: requestLine)
                let response = self.lock.withLock {
                    if let exact = self.routes[path] { return exact }
                    if let suffixMatch = self.suffixRoutes.first(where: { path.hasSuffix($0.suffix) }) {
                        return suffixMatch.response
                    }
                    return self.routes[MCPSelfValidationFixtureRoute.ok.rawValue]!
                }
                let payload = Self.httpResponse(for: response)
                connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
                    Task {
                        if response.delay > .zero {
                            try? await Task.sleep(for: response.delay)
                        }
                        connection.cancel()
                    }
                })
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class State: @unchecked Sendable {
                var didResume = false
            }
            let state = State()

            listener.stateUpdateHandler = { update in
                guard !state.didResume else { return }
                switch update {
                case .ready:
                    state.didResume = true
                    continuation.resume()
                case .failed(let error):
                    state.didResume = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    state.didResume = true
                    continuation.resume(throwing: MCPSelfValidationError.fixtureUnavailable)
                default:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
    }

    private static func path(fromRequestLine requestLine: String) -> String {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return MCPSelfValidationFixtureRoute.ok.rawValue
        }
        let target = String(parts[1])
        if let url = URL(string: target), let path = url.path.nilIfEmpty {
            return path
        }
        if target.hasPrefix("/") {
            return target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        }
        return MCPSelfValidationFixtureRoute.ok.rawValue
    }

    private static func httpResponse(for route: RouteResponse) -> String {
        let reason = route.statusCode == 200 ? "OK" : "Error"
        return """
        HTTP/1.1 \(route.statusCode) \(reason)\r
        Content-Type: \(route.contentType)\r
        Content-Length: \(route.body.utf8.count)\r
        Connection: close\r
        \r
        \(route.body)
        """
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
