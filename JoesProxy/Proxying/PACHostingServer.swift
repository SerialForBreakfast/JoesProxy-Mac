import Foundation
import Network
import os

/// Serves a tiny proxy auto-config (PAC) file on loopback while JoesProxy is managing the macOS
/// system proxy in fail-open mode.
///
/// The PAC returns `"PROXY 127.0.0.1:<proxyPort>; DIRECT"`. The `; DIRECT` fallback is what makes
/// the system proxy fail open: if JoesProxy is not listening (crash/quit), macOS gets an immediate
/// connection refusal on loopback and falls through to a direct connection, so the network keeps
/// working. macOS also caches the last PAC, so the fallback survives even after this server dies.
///
/// Binds loopback-only on an ephemeral port. One request per connection, no keep-alive.
protocol PACHosting: Sendable {
    /// Starts serving the PAC for the given proxy port and returns the loopback PAC URL.
    func start(proxyPort: UInt16) async throws -> String
    func stop() async
}

actor PACHostingServer: PACHosting {
    enum ServerError: LocalizedError {
        case bindFailed(String)

        var errorDescription: String? {
            switch self {
            case .bindFailed(let reason):
                return "PAC server could not start: \(reason)"
            }
        }
    }

    static let path = "/joesproxy.pac"

    private var listener: NWListener?
    private var proxyPort: UInt16 = 0
    private var listenerReservation: ReservedListenerRegistry.ReservationToken?
    private let logger = Logger(subsystem: "com.JoesProxyApp.SystemProxy", category: "PAC")

    init() {}

    func start(proxyPort: UInt16) async throws -> String {
        // Restart cleanly so the served port always matches the current proxy port.
        if listener != nil {
            stop()
        }
        self.proxyPort = proxyPort

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            throw ServerError.bindFailed(error.localizedDescription)
        }

        newListener.newConnectionHandler = { [weak self] connection in
            Task { [weak self] in
                await self?.handleConnection(connection)
            }
        }
        newListener.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                await self?.listenerDidChangeState(state)
            }
        }
        newListener.start(queue: .global(qos: .utility))
        listener = newListener

        let boundPort = try await waitForBoundPort(newListener)
        listenerReservation = ReservedListenerRegistry.shared.reserve(
            owner: "PACHostingServer",
            port: boundPort,
            boundHost: "127.0.0.1"
        )
        let url = "http://127.0.0.1:\(boundPort)\(Self.path)"
        logger.info("PAC server started at \(url, privacy: .public) → PROXY 127.0.0.1:\(proxyPort, privacy: .public); DIRECT")
        return url
    }

    func stop() {
        listener?.cancel()
        listener = nil
        ReservedListenerRegistry.shared.release(listenerReservation)
        listenerReservation = nil
        logger.info("PAC server stopped")
    }

    // MARK: - Internals

    private func waitForBoundPort(_ listener: NWListener, attempts: Int = 50) async throws -> UInt16 {
        for _ in 0..<attempts {
            if let port = listener.port?.rawValue, port != 0 {
                return port
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ServerError.bindFailed("Listener did not report a bound port")
    }

    private func listenerDidChangeState(_ state: NWListener.State) {
        if case .failed(let error) = state {
            logger.error("PAC server listener failed: \(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            listener = nil
            ReservedListenerRegistry.shared.release(listenerReservation)
            listenerReservation = nil
        }
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .utility))
        _ = await receiveData(from: connection)
        let response = httpResponse(
            status: "200 OK",
            contentType: "application/x-ns-proxy-autoconfig",
            body: Data(Self.pacScript(proxyPort: proxyPort).utf8)
        )
        await send(response, on: connection)
        connection.cancel()
    }

    private func receiveData(from connection: NWConnection) async -> Data {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                continuation.resume(returning: data ?? Data())
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    static func pacScript(proxyPort: UInt16) -> String {
        """
        function FindProxyForURL(url, host) {
            return "PROXY 127.0.0.1:\(proxyPort); DIRECT";
        }
        """
    }

    private func httpResponse(status: String, contentType: String, body: Data) -> Data {
        let headerLines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ]
        var response = Data(headerLines.joined(separator: "\r\n").utf8)
        response.append(body)
        return response
    }
}
