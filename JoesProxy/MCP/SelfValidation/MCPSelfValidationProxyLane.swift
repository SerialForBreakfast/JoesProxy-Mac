import Foundation

/// Ephemeral loopback proxy bound to a validation lane's capture and effect stores (AI-5).
///
/// Concurrency: `@MainActor` — started/stopped by ``MCPSelfValidationCoordinator``.
@MainActor
final class MCPSelfValidationProxyLane {
    private let lane: MCPSelfValidationLane
    private let sessionRecorder: ProxySessionRecorder
    private let server: ProxyServer

    var port: UInt16 {
        server.port
    }

    init(lane: MCPSelfValidationLane, httpsProxyMode: HTTPSProxyMode = .passThrough) {
        self.lane = lane
        self.sessionRecorder = ProxySessionRecorder(sessionStore: lane.sessionStore)
        self.server = ProxyServer(
            port: 0,
            bindHost: "127.0.0.1",
            httpsProxyMode: httpsProxyMode,
            configuration: lane.configuration,
            sessionRecorder: sessionRecorder,
            responseOverrideStore: lane.responseOverrideStore,
            bookmarkResponseInterceptStore: lane.bookmarkResponseInterceptStore
        )
    }

    func start() async throws {
        try await server.start()
    }

    func stop() async {
        await server.stop()
    }
}
