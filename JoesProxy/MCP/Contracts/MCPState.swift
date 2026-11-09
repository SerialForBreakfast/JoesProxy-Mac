import Foundation

/// Listener and connection availability for the MCP server.
///
/// Concurrency: values are produced on the MCP service actor and consumed on the main actor for UI.
enum MCPServerState: Equatable, Sendable {
    case off
    case starting
    case running(endpoint: URL, connectedClientCount: Int)
    case stopping
    case failed(MCPStructuredError)
    /// Bootstrapped but a dependency (policy/audit persistence) is unhealthy; reads are denied but
    /// the process is not a bind/start failure — kept distinct so the UI doesn't conflate the two.
    case degraded(MCPStructuredError)
}

/// Current proxy behavior changes and unresolved cleanup conflicts caused by MCP.
///
/// Armed scenarios are **not** effects; they belong in ``MCPOperationState``.
enum MCPEffectState: Equatable, Sendable {
    case clean
    case active(MCPEffectSummary)
    case conflict([MCPEffectConflictItem])
}

/// Transient MCP work such as approvals, sensitive reads, probes, and armed scenarios.
enum MCPOperationState: Equatable, Sendable {
    case idle
    case active(MCPOperationSummary)
    case cancelling(operationIDs: [String])
}

/// Summary of active MCP-created or MCP-modified runtime effects.
struct MCPEffectSummary: Equatable, Sendable, Codable {
    var createdRuleCount: Int
    var changedRuleCount: Int
    var throttleChanged: Bool
    var activeScenarioIDs: [String]

    static let empty = MCPEffectSummary(
        createdRuleCount: 0,
        changedRuleCount: 0,
        throttleChanged: false,
        activeScenarioIDs: []
    )

    var hasEffects: Bool {
        createdRuleCount > 0
            || changedRuleCount > 0
            || throttleChanged
            || !activeScenarioIDs.isEmpty
    }
}

/// A single effect item requiring manual review before normal behavior can be claimed.
struct MCPEffectConflictItem: Equatable, Sendable, Codable, Identifiable {
    var id: String
    var kind: MCPEffectKind
    var message: String
    /// Optional persisted target identifier (override UUID, bookmark:rewrite pair, or `throttle`).
    var targetID: String?
}

/// Effect kinds referenced by attribution, recovery, and diagnostic interlock matrices.
enum MCPEffectKind: String, Equatable, Sendable, Codable, CaseIterable {
    case mapLocal
    case mapRemote
    case block
    case bookmarkRewrite
    case liveResponseRewrite
    /// Reviewed collection-shape mutation applied to real upstream JSON responses.
    case collectionMock
    case throttle
    case responseOverride
    /// JoesProxy-managed response draft create/commit/delete — not a live traffic effect.
    case responseDraft
    /// Active reserved-origin HLS fixture run (live virtual host, not a Map Local rule).
    case hlsFixtureRun
    /// Fingerprint-targeted retirement of CA trust material — irreversible, never restorable.
    case certificateTrustCleanup
    /// Active OpenAPI mock pack (one owned atomic local effect, not Map Local rows).
    case openAPIMockPack
    /// Diagnostic-run regression re-check mutation intent (not a live traffic effect by itself).
    case diagnosticRun
    /// Coordinated bundle lifecycle; recovery never silently reactivates its member effects.
    case effectBundle
}

/// Summary of in-flight MCP operations that do not change persistent effect indicators.
struct MCPOperationSummary: Equatable, Sendable, Codable {
    var pendingApprovalCount: Int
    var sensitiveReadCount: Int
    var liveProbeCount: Int
    var analysisCount: Int
    var armedScenarioIDs: [String]

    static let empty = MCPOperationSummary(
        pendingApprovalCount: 0,
        sensitiveReadCount: 0,
        liveProbeCount: 0,
        analysisCount: 0,
        armedScenarioIDs: []
    )

    var hasArmedScenario: Bool {
        !armedScenarioIDs.isEmpty
    }
}
