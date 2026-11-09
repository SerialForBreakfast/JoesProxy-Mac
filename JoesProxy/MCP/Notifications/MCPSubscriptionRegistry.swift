import Foundation

/// Tracks subscribed resource URIs for one logical MCP session.
struct MCPSubscriptionRegistry: Equatable, Sendable {
    private var subscriptions: [MCPLogicalSessionKey: Set<String>] = [:]

    mutating func subscribe(_ key: MCPLogicalSessionKey, uri: String) {
        var set = subscriptions[key, default: []]
        set.insert(uri)
        subscriptions[key] = set
    }

    mutating func unsubscribe(_ key: MCPLogicalSessionKey, uri: String) {
        guard var set = subscriptions[key] else { return }
        set.remove(uri)
        if set.isEmpty {
            subscriptions.removeValue(forKey: key)
        } else {
            subscriptions[key] = set
        }
    }

    mutating func removeSession(_ key: MCPLogicalSessionKey) {
        subscriptions.removeValue(forKey: key)
    }

    mutating func removeAll() {
        subscriptions.removeAll()
    }

    func subscribedURIs(for key: MCPLogicalSessionKey) -> Set<String> {
        subscriptions[key, default: []]
    }

    func sessionsSubscribed(to uri: String) -> [MCPLogicalSessionKey] {
        subscriptions.compactMap { key, uris in
            uris.contains(uri) ? key : nil
        }
    }

    var activeSessionCount: Int {
        subscriptions.count
    }

    var allKeys: [MCPLogicalSessionKey] {
        Array(subscriptions.keys)
    }
}
