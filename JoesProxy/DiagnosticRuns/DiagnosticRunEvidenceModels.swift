import Foundation

/// Per-record schema for immutable diagnostic evidence envelopes (AN-4).
enum DiagnosticEvidenceSchemaVersion {
    static let current = 1
}

/// Immutable provenance captured at verified terminal close. Never mutated after persist.
struct DiagnosticEvidenceImmutablePayload: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var runID: DiagnosticRunID
    var ownerID: String
    var hypothesis: DiagnosticRunHypothesis
    var scopes: [DiagnosticRunScope]
    var references: [DiagnosticRunReference]
    var observationSummary: DiagnosticRunObservationSummary
    var observations: [DiagnosticRunObservationRecord]
    var conclusion: DiagnosticRunConclusion?
    var cleanupProof: DiagnosticRunCleanupProof
    var terminalStatus: DiagnosticRunStatus
    var terminalAt: Date
    var captureEpochs: [MCPCaptureEpoch]
    var markerIDs: [UUID]
    var referencedSessionIDs: [UUID]
    var materializedAt: Date
    /// False when live observation truncation or capture-unavailable state affected the envelope.
    var isEvidenceComplete: Bool
    var incompleteReasonCode: String?
}

/// Durable, queryable closed-run record with separately updatable human notes (AN-4).
struct DiagnosticEvidenceRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var runID: DiagnosticRunID
    var ownerID: String
    var createdAt: Date
    var immutable: DiagnosticEvidenceImmutablePayload
    /// Sorted-key digest over `immutable` only — tamper detection for provenance.
    var provenanceDigest: String
    /// Digest over immutable payload plus record identity — conclusion attachment point.
    var evidenceDigest: String
    /// Editable human notes; updates never change digests or immutable fields.
    var editableNotes: String?
    var notesUpdatedAt: Date?
}

/// Paginated evidence list for one owner.
struct DiagnosticEvidenceListPage: Equatable, Sendable {
    var records: [DiagnosticEvidenceRecord]
    var totalCount: Int
    var hasMore: Bool
}

/// Full export envelope for local backup or future MCP/CLI (AN-4).
struct DiagnosticRunEvidenceExportEnvelope: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var record: DiagnosticEvidenceRecord
}

/// Metadata-only disclosure projection — no exact host/path (AN-4 privacy boundary).
struct DiagnosticEvidenceDisclosedRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var runID: DiagnosticRunID
    var ownerID: String
    var createdAt: Date
    var terminalStatus: DiagnosticRunStatus
    var terminalAt: Date
    var hypothesisSummary: String
    var conclusionOutcome: DiagnosticConclusionOutcome?
    var conclusionReasonCode: DiagnosticConclusionReasonCode?
    var confidence: DiagnosticConclusionConfidence?
    var matchedRequestCount: Int
    var matcherMissCount: Int
    var droppedObservationCount: Int
    var isEvidenceComplete: Bool
    var cleanupVerified: Bool
    var evidenceDigest: String
    var observationCount: Int
}

enum DiagnosticRunEvidenceDisclosure: Sendable {
    case localFull
    case metadataOnly
}
