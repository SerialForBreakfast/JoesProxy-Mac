import Foundation

/// Opaque durable identity for one diagnostic investigation (AN-0 / AN-2).
struct DiagnosticRunID: Codable, Hashable, Sendable, Equatable {
    var rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Envelope and per-record schema version for the diagnostic-run store.
enum DiagnosticRunSchemaVersion {
    static let current = 2
}

/// Owner of a diagnostic run. MCP ownership is by enrolled client ID.
enum DiagnosticRunOwner: Codable, Equatable, Sendable {
    case localUser
    case mcpClient(id: String, displayNameSnapshot: String)

    /// Stable owner key used for quotas and attach/cleanup authorization.
    static let localUserOwnerID = "joesproxy-local-user"

    /// Stable owner key used for quotas and attach/cleanup authorization.
    var ownerID: String {
        switch self {
        case .localUser:
            return Self.localUserOwnerID
        case .mcpClient(let id, _):
            return id
        }
    }
}

/// Provenance of owner-authored inert text on a run.
enum DiagnosticRunTextSource: String, Codable, Sendable {
    case localUser
    case mcpClient
}

/// Bounded owner-authored hypothesis. Never executed by JoesProxy.
struct DiagnosticRunHypothesis: Codable, Equatable, Sendable {
    var summary: String
    var expectedObservation: String
    var source: DiagnosticRunTextSource
}

/// How an HTTP path scope matches request paths.
enum DiagnosticPathMatch: String, Codable, Sendable {
    case exact
    case prefix
    case suffix
    case filename
}

/// Captured-session scope: fingerprint is query-insensitive and frozen at Watching start.
struct DiagnosticCapturedSessionScope: Codable, Equatable, Sendable {
    var sessionID: UUID
    var captureEpoch: MCPCaptureEpoch
    var requestFingerprint: String
}

/// Exact HTTP matcher scope. Port is always materialized.
struct DiagnosticHTTPScope: Codable, Equatable, Sendable {
    var method: String
    var scheme: SessionScheme
    var host: String
    var port: Int
    var path: String
    var pathMatch: DiagnosticPathMatch
}

/// Observe an existing JoesProxy effect by opaque ID (no embedded definition copy).
struct DiagnosticEffectScope: Codable, Equatable, Sendable {
    var kind: DiagnosticReferenceKind
    var effectID: String
    var targetRevision: String?
}

/// Explicit observation boundary. Empty lists are invalid outside Draft.
enum DiagnosticRunScope: Codable, Equatable, Sendable {
    case capturedSession(DiagnosticCapturedSessionScope)
    case http(DiagnosticHTTPScope)
    case effect(DiagnosticEffectScope)
}

/// Kind of opaque object a run may reference.
enum DiagnosticReferenceKind: String, Codable, Sendable {
    case captureMarker
    case proposal
    case overrideRule
    case scenario
    case fixtureRun
    case hlsSubstitution
    case openAPIMockPack
    case operation
}

/// How a reference relates to cleanup authority.
enum DiagnosticReferenceRelationship: String, Codable, Sendable {
    case evidence
    case observeOnly
    case ownerScopedCleanup
}

/// Opaque link to an existing JoesProxy object. Does not transfer ownership.
struct DiagnosticRunReference: Codable, Equatable, Sendable {
    var kind: DiagnosticReferenceKind
    var opaqueID: String
    var relationship: DiagnosticReferenceRelationship
    var ownerIDSnapshot: String?
    var targetRevision: String?
    var attachedAt: Date
}

/// Lifecycle status for one diagnostic run.
enum DiagnosticRunStatus: String, Codable, Sendable {
    case draft
    case watching
    case active
    case closing
    case passed
    case failed
    case inconclusive
    case expired
    case cleanupRequired

    /// Terminal states eligible for retention pruning.
    var isPrunableTerminal: Bool {
        switch self {
        case .passed, .failed, .inconclusive, .expired:
            return true
        case .draft, .watching, .active, .closing, .cleanupRequired:
            return false
        }
    }

    /// Nonterminal statuses that count toward concurrent quotas.
    var isNonterminal: Bool {
        switch self {
        case .draft, .watching, .active, .closing, .cleanupRequired:
            return true
        case .passed, .failed, .inconclusive, .expired:
            return false
        }
    }
}

/// Intended terminal status retained while Closing / Cleanup Required.
enum DiagnosticRunRequestedTerminal: String, Codable, Sendable {
    case passed
    case failed
    case inconclusive
    case expired
}

/// Why observation evidence became unavailable.
enum DiagnosticEvidenceUnavailableReason: String, Codable, Sendable {
    case captureEpochChanged
    case captureUnavailable
    case targetMissing
    case targetChanged
    case operationInterrupted
}

/// Aggregated observation facts (AN-3 expands cursored DTOs; AN-2 persists this summary).
struct DiagnosticRunObservationSummary: Codable, Equatable, Sendable {
    var matchedRequestCount: Int = 0
    var matcherMissCount: Int = 0
    var statusFamilies: [String: Int] = [:]
    var minimumLatencyMilliseconds: Int?
    var maximumLatencyMilliseconds: Int?
    var lastObservedAt: Date?
    var lastMarkerID: UUID?
    var captureEpochs: [MCPCaptureEpoch] = []
    var droppedObservationCount: Int = 0
    var evidenceUnavailableReason: DiagnosticEvidenceUnavailableReason?

    static let empty = DiagnosticRunObservationSummary()
}

/// Allowlisted conclusion reason codes.
enum DiagnosticConclusionReasonCode: String, Codable, Sendable {
    case expectedObserved = "expected_observed"
    case contraryObserved = "contrary_observed"
    case noRequest = "no_request"
    case matcherMiss = "matcher_miss"
    case captureUnavailable = "capture_unavailable"
    case targetChanged = "target_changed"
    case targetMissing = "target_missing"
    case operationInterrupted = "operation_interrupted"
    case approvalDenied = "approval_denied"
    case cleanupConflict = "cleanup_conflict"
    case insufficientEvidence = "insufficient_evidence"
    /// AN-5: the saved record references a scope form, effect kind, or schema version the
    /// current app build cannot recreate or compare against.
    case unsupportedCapability = "unsupported_capability"
}

enum DiagnosticConclusionOutcome: String, Codable, Sendable {
    case passed
    case failed
    case inconclusive
}

enum DiagnosticConclusionConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
    case unassessed
}

/// Bounded conclusion attached before a verified-clean terminal transition.
struct DiagnosticRunConclusion: Codable, Equatable, Sendable {
    var outcome: DiagnosticConclusionOutcome
    var reasonCode: DiagnosticConclusionReasonCode
    var summary: String
    var confidence: DiagnosticConclusionConfidence
    var concludedAt: Date
    var evidenceDigest: String
}

/// Machine-verifiable cleanup proof required before Passed/Failed/Inconclusive/Expired.
struct DiagnosticRunCleanupProof: Codable, Equatable, Sendable {
    var startedAt: Date
    var completedAt: Date?
    var checkedReferenceIDs: [String]
    var cleanedReferenceIDs: [String]
    var observeOnlyReferenceIDs: [String]
    var conflictReasonCodes: [String]
    var remainingLiveEffectCount: Int
    var policyRevision: MCPPolicyRevision
    var verifiedClean: Bool
    var verificationDigest: String?
}

/// Durable diagnostic-run record. Coordinates existing effects; never embeds their definitions.
struct DiagnosticRun: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion: Int
    var id: DiagnosticRunID
    var owner: DiagnosticRunOwner
    var hypothesis: DiagnosticRunHypothesis
    var scopes: [DiagnosticRunScope]
    var references: [DiagnosticRunReference]
    var status: DiagnosticRunStatus
    var requestedTerminal: DiagnosticRunRequestedTerminal?
    var observationSummary: DiagnosticRunObservationSummary
    var conclusion: DiagnosticRunConclusion?
    var cleanupProof: DiagnosticRunCleanupProof?
    var createdAt: Date
    var watchingStartedAt: Date?
    var activeAt: Date?
    var closingStartedAt: Date?
    var expiresAt: Date
    var terminalAt: Date?
    var lastUpdatedAt: Date
    /// Installed watch tokens owned by this run (cleared on close / relaunch). Not a traffic effect.
    var installedWatchIDs: [UUID]
}

/// Server-owned numeric budgets from the AN-0 ADR.
enum DiagnosticRunBudget {
    static let maxConcurrentNonterminalPerMCPOwner = 2
    static let maxConcurrentNonterminalLocalUser = 4
    static let maxConcurrentNonterminalGlobal = 8
    static let maxScopesPerRun = 4
    static let maxReferencesPerRun = 16
    static let maxActiveOwnerScopedEffectsPerRun = 8
    static let maxHypothesisUTF8Bytes = 1_024
    static let maxExpectedObservationUTF8Bytes = 1_024
    static let maxConclusionUTF8Bytes = 2_048
    static let maxCaptureEpochsPerRun = 4
    static let maxCleanupConflictsPerRun = 50
    static let defaultLifetime: TimeInterval = 30 * 60
    static let minimumLifetime: TimeInterval = 60
    static let maximumLifetime: TimeInterval = 24 * 60 * 60
    static let terminalRetention: TimeInterval = 30 * 24 * 60 * 60
    static let maxTerminalRunsGlobal = 200
    static let maxTerminalRunsPerOwner = 50
    static let listPageDefault = 20
    static let listPageMax = 50
    static let observationPageDefault = 50
    static let observationPageMax = 100
    /// Live observation ring (AN-3). AN-4 immutable evidence uses the same ceiling.
    static let maxLiveObservationsPerRun = 500
    static let maxImmutableEvidenceRecordsPerRun = 500
    static let maxEncodedEvidenceBytesPerRun = 256 * 1024
    static let maxAttributionIDsPerObservation = 8
    static let maxAttributionIDUTF8Bytes = 128
}
