import Foundation
import CryptoKit

/// Retains only bounded digest receipts, never bodies or full projections. Callers must authorize
/// every read before lookup and bind all source revisions/selection inputs into scope.
@MainActor
final class MCPBriefReadCache {
    static let capacity = 64
    static let lifetime: TimeInterval = 300
    private struct Entry {
        var owner: String
        var scope: String
        var status: String
        var expires: Date
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    static func validDigest(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let text = value as? String, text.utf8.count == 64 else { return false }
        return text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func scope(_ components: [String]) throws -> String {
        digest(try JSONEncoder().encode(components))
    }

    func unchanged(_ token: String?, owner: String, scope: String, analysisReused: Bool = true,
                   now: Date = Date()) -> [String: Any]? {
        prune(now: now)
        guard let token, let entry = entries[token], entry.owner == owner, entry.scope == scope else { return nil }
        return ["schemaVersion": 1, "briefDigest": token, "unchanged": true,
                "analysisReused": analysisReused, "status": entry.status,
                "reuseScope": "Reuse the previous qualified brief only; unchanged does not mean complete, passed or clean."]
    }

    func retain(payload: [String: Any], owner: String, scope: String, now: Date = Date()) throws -> String {
        prune(now: now)
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let token = Self.digest(Data(scope.utf8) + encoded)
        if entries[token] == nil { order.append(token) }
        entries[token] = Entry(owner: owner, scope: scope, status: payload["status"] as? String ?? "incomplete",
            expires: now.addingTimeInterval(Self.lifetime))
        while order.count > Self.capacity { entries.removeValue(forKey: order.removeFirst()) }
        return token
    }

    func removeAll(owner: String? = nil) {
        if let owner { entries = entries.filter { $0.value.owner != owner }; order.removeAll { entries[$0] == nil } }
        else { entries.removeAll(); order.removeAll() }
    }

    private func prune(now: Date) {
        entries = entries.filter { $0.value.expires > now }
        order.removeAll { entries[$0] == nil }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
