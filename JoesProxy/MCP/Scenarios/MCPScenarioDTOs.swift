import Foundation

/// Stable scenario identifier (AI-0).
struct MCPScenarioID: Equatable, Sendable, Codable, Hashable {
    var rawValue: String
}

enum MCPScenarioSchemaVersion {
    static let current = 1
}

/// Resource budgets for scenario definitions (AI-0).
enum MCPScenarioResourceBudget {
    static let maxFaults = 8
    static let maxAssertions = 32
    static let maxDurationSeconds: TimeInterval = 86_400
    static let maxObservationWindowSeconds: TimeInterval = 86_400
    static let maxEvidenceRecords = 500
    static let maxEvidenceRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60
}

/// Scenario lifecycle phase (parent ADR "Scenario Lifecycle").
///
/// `armed` means validated + approved but NOT yet affecting traffic — this is why armed scenarios
/// live in `MCPOperationSummary.armedScenarioIDs`, never `MCPEffectSummary.activeScenarioIDs`.
/// Every non-terminal phase must reach `cleaningUp` before any terminal phase (AI-2 exit
/// criterion: "no scenario can report completion before cleanup is verified").
enum MCPScenarioPhase: String, Equatable, Sendable, Codable, CaseIterable {
    case draft
    case validating
    case awaitingApproval
    case armed
    case running
    case observing
    case evaluating
    case cleaningUp
    case completed
    case failed
    case inconclusive
    case cleanupRequired
    case canceled

    /// Phases exempt from `MCPScenarioStore`'s terminal-record pruning — unresolved state a human
    /// must still resolve, mirroring `MCPEffectJournalStore`'s `.conflict` exemption.
    var isPrunableTerminal: Bool {
        switch self {
        case .completed, .failed, .inconclusive, .canceled:
            return true
        case .draft, .validating, .awaitingApproval, .armed, .running, .observing, .evaluating,
             .cleaningUp, .cleanupRequired:
            return false
        }
    }

    /// Phases where the scenario currently owns live proxy effects (drives
    /// `MCPEffectSummary.activeScenarioIDs` — armed scenarios are excluded on purpose).
    var ownsActiveEffects: Bool {
        switch self {
        case .running, .observing, .evaluating, .cleaningUp:
            return true
        case .draft, .validating, .awaitingApproval, .armed, .completed, .failed, .inconclusive,
             .cleanupRequired, .canceled:
            return false
        }
    }
}

struct MCPScenarioTarget: Equatable, Sendable, Codable {
    var appIdentifier: String?
    var environment: String?
    var hosts: [String]
    var paths: [String]?
}

/// Allowlisted scenario preconditions (AI-0).
enum MCPScenarioPreconditionKind: String, Equatable, Sendable, Codable, CaseIterable {
    case proxyRunning
    case mcpServerRunning
    case clientEnrolled
    case captureActive
    case bookmarkExists
}

struct MCPScenarioPrecondition: Equatable, Sendable, Codable {
    var kind: MCPScenarioPreconditionKind
    var detail: String?
}

struct MCPScenarioCaptureScope: Equatable, Sendable, Codable {
    var hosts: [String]
    var includeBodies: Bool
}

struct MCPScenarioObservationWindow: Equatable, Sendable, Codable {
    var startTrigger: String
    var duration: TimeInterval
}

/// Identifies whether assertion evidence is directly observed or inferred (ADR observations).
enum MCPScenarioEvidenceSource: String, Equatable, Sendable, Codable, CaseIterable {
    case captured
    case sdkReported
    case inferredCorrelation
    case externalRunner
}

/// Full ADR assertion catalog. Evaluation is AI-3; compile-time shape validation is AI-0.
enum MCPScenarioAssertionKind: String, Equatable, Sendable, Codable, CaseIterable {
    case requestOccurred
    case requestNotOccurred
    case retryCount
    case retryCadence
    case fallbackHostUsed
    case errorResponseReachedClient
    case requestSequenceChanged
    case latencyThreshold
    case mediaManifestBehaviorChanged
    case mediaSegmentBehaviorChanged
    case bookmarkMatched
    case overrideMatched
    case ruleConflictOrBypass
    case sdkStateTransition
    case sdkErrorCategory
    case sdkRetryState
    case sdkPlaybackState
    case sdkBufferingOrStall
    case sdkFallbackActivated
    case sdkUserVisibleRecovery
    case sdkTestStepMarker
    case externalTestStepBegin
    case externalTestStepEnd
}

/// One declarative assertion evaluated during AI-3 observation windows.
struct MCPScenarioAssertion: Equatable, Sendable, Codable {
    var kind: MCPScenarioAssertionKind
    var matcher: MCPMutationMatcher?
    var host: String?
    var path: String?
    var statusCode: Int?
    var thresholdSeconds: TimeInterval?
    var expectedCount: Int?
    var markerName: String?
    var detail: String?
    var evidenceSource: MCPScenarioEvidenceSource
    /// Required when `evidenceSource` is `inferredCorrelation` — documents why inference is allowed.
    var notes: String?
}

enum MCPScenarioAssertionSeverity: String, Equatable, Sendable, Codable {
    case informational
    case warning
    case blocking
}

struct MCPScenarioEvidenceRetentionSpec: Equatable, Sendable, Codable {
    var maxRecords: Int
    var retention: TimeInterval
}

/// Declares which fault a cleanup action reverts. Enforces 1:1 fault<->cleanup coverage — AI-0's
/// compiler rejects any scenario with a fault index missing a corresponding action.
struct MCPScenarioCleanupAction: Equatable, Sendable, Codable {
    var faultIndex: Int
    var kind: MCPEffectKind
}

/// Composes existing, already-normalized/validated capability argument shapes. Each case wraps
/// EXACTLY the shape the standalone propose/apply tool for that capability already accepts —
/// never a bespoke shape — so a scenario fault can never expand scope beyond what the standalone
/// tool would already reject (parent ADR: "A scenario must not silently expand a rule's host,
/// path, query, method, or destination scope").
enum MCPScenarioFault: Equatable, Sendable, Codable {
    /// `dropConnection` selects a real dropped connection (no HTTP response, closed/reset) instead
    /// of serving `statusCode` — see `ResponseOverrideRule.dropConnection`. Defaults to `false`,
    /// the only behavior that existed before this field, so older persisted scenario definitions
    /// missing the key still decode.
    case block(matcher: MCPMutationMatcher, statusCode: Int, dropConnection: Bool = false)
    case mapLocal(matcher: MCPMutationMatcher, inlineBodyText: String, inlineContentType: String, inlineStatusCode: Int)
    case mapRemote(
        matcher: MCPMutationMatcher,
        remoteHost: String,
        remotePort: Int?,
        remoteScheme: SessionScheme,
        remotePath: String? = nil,
        remoteQueryPolicy: MapRemoteQueryPolicy = .preserve,
        remoteQuery: String? = nil,
        allowLoopbackDestination: Bool? = nil,
        preserveHostHeader: Bool? = nil
    )
    case jsonRewrite(
        matcher: MCPMutationMatcher,
        jsonPath: String,
        overrideValue: BookmarkJSONValue,
        operation: JSONMutationOperation = .set
    )
    case bookmarkRewrite(bookmarkID: UUID, jsonPath: String, overrideValue: BookmarkJSONValue)
    case throttle(configuration: NetworkThrottleConfiguration)
    case replay(bookmarkID: UUID)

    /// Which existing capability this fault activates as — drives dynamic risk classification
    /// (parent ADR "Scenario Tool Classification": highest-risk composed fault sets the tier).
    var capabilityID: MCPCapabilityID {
        switch self {
        case .block:
            return .createDisabledBlock
        case .mapLocal:
            return .createDisabledMapLocal
        case .mapRemote:
            return .activateMapRemote
        case .jsonRewrite:
            return .activateLiveRewrite
        case .bookmarkRewrite:
            return .createDisabledRewrite
        case .throttle:
            return .changeThrottle
        case .replay:
            return .replayRequest
        }
    }

    /// Effect kind this fault maps to for journal/conflict reporting.
    var effectKind: MCPEffectKind {
        switch self {
        case .block:
            return .block
        case .mapLocal:
            return .mapLocal
        case .mapRemote:
            return .mapRemote
        case .jsonRewrite:
            return .liveResponseRewrite
        case .bookmarkRewrite:
            return .bookmarkRewrite
        case .throttle:
            return .throttle
        case .replay:
            return .bookmarkRewrite
        }
    }

    /// Target lock key — matches the SAME derivation the standalone propose/apply tools already
    /// use for this matcher/bookmarkID, so the scenario's per-fault locking composes with (not
    /// parallels) the existing per-target lock in `MCPProposalCoordinator`.
    var targetLockKey: String {
        switch self {
        case .block(let matcher, _, _), .mapLocal(let matcher, _, _, _),
             .mapRemote(let matcher, _, _, _, _, _, _, _, _), .jsonRewrite(let matcher, _, _, _):
            return MCPScenarioFault.matcherLockKey(matcher)
        case .bookmarkRewrite(let bookmarkID, _, _), .replay(let bookmarkID):
            return "bookmark:\(bookmarkID.uuidString)"
        case .throttle:
            return "throttle"
        }
    }

    private static func matcherLockKey(_ matcher: MCPMutationMatcher) -> String {
        "\(matcher.method)|\(matcher.scheme.rawValue)|\(matcher.host)|\(matcher.port ?? -1)|\(matcher.path)|\(matcher.matchMode.rawValue)"
    }
}

/// Versioned, agent-authored test definition composing one or more existing MCP capabilities into
/// a single approved unit with an explicit lifecycle and mandatory cleanup (parent ADR
/// "Agent-Assisted Test Scenarios").
struct MCPScenarioDefinition: Equatable, Sendable, Codable, Identifiable {
    var id: MCPScenarioID
    var schemaVersion: Int
    var name: String
    var purpose: String
    var originatingClientID: String
    var target: MCPScenarioTarget
    var preconditions: [MCPScenarioPrecondition]
    var captureScope: MCPScenarioCaptureScope
    var disclosureProfileID: MCPDisclosureProfileID
    /// Order IS activation order — no separate ordering field.
    var faults: [MCPScenarioFault]
    var duration: TimeInterval?
    var expiresAt: Date?
    var observationWindow: MCPScenarioObservationWindow
    var assertions: [MCPScenarioAssertion]
    var assertionSeverity: MCPScenarioAssertionSeverity
    var evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec
    var cleanupActions: [MCPScenarioCleanupAction]
    var createdAt: Date
}

/// Bundles compile output for approval UI and future `validate_test_scenario` (AI-0).
struct MCPScenarioValidationResultDTO: Equatable, Sendable, Codable {
    var definition: MCPScenarioDefinition
    var riskTier: String
    var affectedTargetKeys: [String]
    var approvalDisclosure: MCPScenarioApprovalDisclosureDTO
    var warnings: [String]
}

extension MCPDisclosureProfileID {
    /// Phase 1 profiles assignable to enrolled MCP clients.
    var isSelectableInPhase1: Bool {
        switch self {
        case .metadataOnly, .shareable, .developerInspection:
            return true
        case .fullLocalInspection, .custom:
            return false
        }
    }
}
