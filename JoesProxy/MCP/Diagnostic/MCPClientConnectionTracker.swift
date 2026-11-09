import Foundation

/// Tracks MCP client connection windows for per-connection recap (AJ-5).
///
/// Concurrency: `@MainActor` — updated from protocol session lifecycle on the main actor.
@MainActor
final class MCPClientConnectionTracker: ObservableObject {
    struct ConnectionWindow: Equatable, Identifiable, Sendable {
        var id: String { clientID }
        var clientID: String
        var connectedAt: Date
        var lastActivityAt: Date
        var isConnected: Bool
    }

    @Published private(set) var windows: [String: ConnectionWindow] = [:]

    func noteClientConnected(clientID: String, at date: Date = Date()) {
        if var existing = windows[clientID] {
            existing.lastActivityAt = date
            existing.isConnected = true
            windows[clientID] = existing
        } else {
            windows[clientID] = ConnectionWindow(
                clientID: clientID,
                connectedAt: date,
                lastActivityAt: date,
                isConnected: true
            )
        }
    }

    func noteClientActivity(clientID: String, at date: Date = Date()) {
        guard var existing = windows[clientID] else {
            noteClientConnected(clientID: clientID, at: date)
            return
        }
        existing.lastActivityAt = date
        windows[clientID] = existing
    }

    func noteClientDisconnected(clientID: String, at date: Date = Date()) {
        guard var existing = windows[clientID] else { return }
        existing.lastActivityAt = date
        existing.isConnected = false
        windows[clientID] = existing
    }

    var connectedClients: [ConnectionWindow] {
        windows.values.filter(\.isConnected).sorted { $0.connectedAt < $1.connectedAt }
    }
}
