import Foundation
import CryptoKit

/// MainActor-owned write-ahead receipts. Restart only loads evidence; it never executes changes.
@MainActor
final class MCPHTTPSRecoveryJournal {
    struct Receipt: Codable {
        enum Phase: String, Codable { case applyPrepared, restorePrepared, restored, abandoned }
        let id: UUID
        let owner: String
        let host: String
        let mode: String
        let before: TLSInterceptionRules
        let after: TLSInterceptionRules
        let createdAt: Date
        var phase: Phase = .applyPrepared

        func projection(current: TLSInterceptionRules) -> [String: Any] {
            let matchesBefore = current == before
            let matchesAfter = current == after
            let state: String
            if before == after { state = "no_change" }
            else if phase == .abandoned { state = "not_applied_closed" }
            else if phase == .restored { state = "restored" }
            else if phase == .restorePrepared && matchesBefore { state = "restored" }
            else if matchesAfter { state = phase == .restorePrepared ? "restore_not_applied" : "applied" }
            else if matchesBefore { state = "not_applied" }
            else { state = "conflict" }
            return ["recoveryID": id.uuidString, "host": host, "mode": mode,
                    "state": state, "createdAt": ISO8601DateFormatter().string(from: createdAt),
                    "beforeRevision": MCPHTTPSRules.revision(before), "appliedRevision": MCPHTTPSRules.revision(after),
                    "priorCustomTunnelRule": before.bypassDomains.contains { $0.lowercased() == host },
                    "priorCustomInspectRule": before.interceptDomains.contains { $0.lowercased() == host },
                    "currentRevision": MCPHTTPSRules.revision(current), "currentMatchesBefore": matchesBefore,
                    "canRequestRestore": matchesAfter && before != after && phase != .restored && phase != .abandoned,
                    "scope": "host_and_subdomains_all_clients", "appliesTo": "new_connections_only",
                    "persistent": true, "automaticCleanup": false,
                    "verification": "Settings evidence only; no proof of connection replacement or playback. Inspect after an uncertain reply; never automatically reapply. Restore needs separate local approval and unchanged settings."]
        }
    }

    private struct Archive: Codable { let version: Int; var receipts: [Receipt]; var usedIDs: Data }
    static let limit = 32
    static let byteLimit = 4 * 1024 * 1024
    private let url: URL?
    private var receipts: [Receipt] = []
    // Fixed-size Bloom filter: possible false positives reject a fresh ID safely; retired IDs
    // never become new mutations. No growing tombstone array or silent replay after eviction.
    private var usedIDs = Data(repeating: 0, count: 8192)
    private var loadFailed = false

    init(url: URL? = nil) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= Self.byteLimit else { throw Self.unavailable() }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            guard archive.version == 1, archive.receipts.count <= Self.limit, archive.usedIDs.count == 8192,
                  Set(archive.receipts.map(\.id)).count == archive.receipts.count else { throw Self.unavailable() }
            receipts = archive.receipts
            usedIDs = archive.usedIDs
            for receipt in receipts { remember(receipt.id, in: &usedIDs) }
        } catch { loadFailed = true }
    }

    func receipt(id: UUID, owner: String) throws -> Receipt? {
        guard !loadFailed else { throw Self.unavailable() }
        guard let receipt = receipts.first(where: { $0.id == id }) else {
            guard !positions(id).allSatisfy({ usedIDs[$0 / 8] & (1 << ($0 % 8)) != 0 }) else {
                throw MCPStructuredError(code: .staleProposal, message: "Recovery ID retired or unavailable. Inspect current settings; never replay the old operation. A genuinely new reviewed change needs a fresh ID.")
            }
            return nil
        }
        guard receipt.owner == owner else {
            throw MCPStructuredError(code: .policyDenied, message: "Recovery receipt unavailable to this client.")
        }
        return receipt
    }

    func history(host: String, owner: String, current: TLSInterceptionRules) -> [String: Any] {
        guard !loadFailed else {
            return ["available": false, "reason": "recovery_journal_unavailable", "receipts": []]
        }
        let matching = receipts.filter { $0.host == host && $0.owner == owner }
        return ["available": true, "retainedCount": matching.count, "retentionLimit": Self.limit,
                "completedReceiptsMayRetire": true,
                "receipts": matching.map { $0.projection(current: current) }]
    }

    func save(_ receipt: Receipt) throws {
        guard !loadFailed else { throw Self.unavailable() }
        var next = receipts
        if let index = next.firstIndex(where: { $0.id == receipt.id }) { next[index] = receipt }
        else {
            if next.count >= Self.limit, let index = next.firstIndex(where: { $0.phase == .restored || $0.phase == .abandoned || $0.before == $0.after }) {
                next.remove(at: index)
            }
            guard next.count < Self.limit else {
                throw MCPStructuredError(code: .policyDenied, message: "Recovery journal is full (32 receipts). Restore outstanding changes first; no settings were changed.")
            }
            next.append(receipt)
        }
        var nextIDs = usedIDs
        remember(receipt.id, in: &nextIDs)
        let data = try JSONEncoder().encode(Archive(version: 1, receipts: next, usedIDs: nextIDs))
        guard data.count <= Self.byteLimit else { throw Self.unavailable() }
        if let url {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { throw Self.unavailable() }
        }
        receipts = next
        usedIDs = nextIDs
    }

    private func positions(_ id: UUID) -> [Int] {
        let bytes = Array(SHA256.hash(data: Data(id.uuidString.utf8)))
        return stride(from: 0, to: 8, by: 2).map { (Int(bytes[$0]) << 8) | Int(bytes[$0 + 1]) }
    }

    private func remember(_ id: UUID, in data: inout Data) {
        for position in positions(id) { data[position / 8] |= 1 << (position % 8) }
    }

    static func unavailable() -> MCPStructuredError {
        MCPStructuredError(code: .internalFailure, message: "Recovery journal unavailable. Inspect HTTPS rules locally; do not retry a mutation blindly or delete recovery evidence.")
    }
}
