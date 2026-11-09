import Foundation

struct MCPEvidenceReferenceDTO: Codable, Equatable, Sendable {
    var evidenceRef: String
    var sourceKind: String
    var sourceID: String
    var captureSequence: UInt64
    var captureEpoch: MCPCaptureEpoch
    var policyRevision: MCPPolicyRevision
    var expiresAt: Date
}

struct MCPInvestigationEvidenceDTO: Codable, Equatable, Sendable {
    var reference: MCPEvidenceReferenceDTO
    var summary: MCPSessionSummaryDTO
}

struct MCPInvestigationSnapshotDTO: Codable, Equatable, Sendable {
    var stateToken: String
    var unchanged: Bool
    var captureEpoch: MCPCaptureEpoch
    var policyRevision: MCPPolicyRevision
    var latestSequence: UInt64
    var sessionCount: Int
    var completedCount: Int
    var pendingCount: Int
    var sampledSessionCount: Int
    var sampledStatusFamilies: [String: Int]
    var sampledHostCategories: [String: Int]
    var evidence: [MCPInvestigationEvidenceDTO]
    var recommendedNextTools: [String]
}

enum MCPEvidenceReferenceError: Error, Equatable {
    case notFound
    case staleCapture
    case stalePolicy
}

/// Bounded, memory-only references to projections already disclosed to one client.
///
/// A reference can reproduce only the exact sanitized summary retained here. It never resolves a
/// live record and therefore cannot expand disclosure after issuance.
@MainActor
final class MCPEvidenceReferenceStore {
    private struct Entry {
        var clientID: String
        var reference: MCPEvidenceReferenceDTO
        var summary: MCPSessionSummaryDTO
        var encodedByteCount: Int
    }

    static let maximumEntries = 256
    static let maximumAggregateBytes = 2 * 1_048_576
    static let timeToLive: TimeInterval = 15 * 60

    private var entriesByReference: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private var aggregateBytes = 0

    func retain(
        summary: MCPSessionSummaryDTO,
        clientID: String,
        captureEpoch: MCPCaptureEpoch,
        policyRevision: MCPPolicyRevision,
        now: Date = Date()
    ) throws -> MCPEvidenceReferenceDTO {
        prune(now: now)
        let encodedByteCount = try JSONEncoder().encode(summary).count
        let token = "evidence-\(UUID().uuidString)"
        let reference = MCPEvidenceReferenceDTO(
            evidenceRef: token,
            sourceKind: "session_summary_minimal",
            sourceID: summary.id,
            captureSequence: summary.captureSequence,
            captureEpoch: captureEpoch,
            policyRevision: policyRevision,
            expiresAt: now.addingTimeInterval(Self.timeToLive)
        )
        entriesByReference[token] = Entry(
            clientID: clientID,
            reference: reference,
            summary: summary,
            encodedByteCount: encodedByteCount
        )
        insertionOrder.append(token)
        aggregateBytes += encodedByteCount
        enforceBounds()
        return reference
    }

    func resolve(
        _ evidenceRef: String,
        clientID: String,
        captureEpoch: MCPCaptureEpoch,
        policyRevision: MCPPolicyRevision,
        now: Date = Date()
    ) throws -> MCPInvestigationEvidenceDTO {
        prune(now: now)
        guard let entry = entriesByReference[evidenceRef], entry.clientID == clientID else {
            throw MCPEvidenceReferenceError.notFound
        }
        guard entry.reference.captureEpoch == captureEpoch else {
            throw MCPEvidenceReferenceError.staleCapture
        }
        guard entry.reference.policyRevision == policyRevision else {
            throw MCPEvidenceReferenceError.stalePolicy
        }
        return MCPInvestigationEvidenceDTO(reference: entry.reference, summary: entry.summary)
    }

    func removeAll(forClientID clientID: String) {
        for token in insertionOrder where entriesByReference[token]?.clientID == clientID {
            remove(token)
        }
        insertionOrder.removeAll { entriesByReference[$0] == nil }
    }

    func removeAll() {
        entriesByReference.removeAll()
        insertionOrder.removeAll()
        aggregateBytes = 0
    }

    private func prune(now: Date) {
        for token in insertionOrder where (entriesByReference[token]?.reference.expiresAt ?? .distantPast) <= now {
            remove(token)
        }
        insertionOrder.removeAll { entriesByReference[$0] == nil }
    }

    private func enforceBounds() {
        while entriesByReference.count > Self.maximumEntries || aggregateBytes > Self.maximumAggregateBytes {
            guard let oldest = insertionOrder.first else { break }
            insertionOrder.removeFirst()
            remove(oldest)
        }
    }

    private func remove(_ token: String) {
        guard let removed = entriesByReference.removeValue(forKey: token) else { return }
        aggregateBytes = max(0, aggregateBytes - removed.encodedByteCount)
    }
}
