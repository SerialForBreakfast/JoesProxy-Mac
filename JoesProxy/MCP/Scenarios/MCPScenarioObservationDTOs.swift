import Foundation

/// Outcome of evaluating one scenario assertion (AI-3).
enum MCPScenarioAssertionOutcome: String, Equatable, Sendable, Codable {
    case passed
    case failed
    case inconclusive
}

/// One bounded observation captured during a scenario window (AI-3).
struct MCPScenarioEvidenceRecord: Equatable, Sendable, Codable, Identifiable {
    var id: String
    var sessionID: String
    var captureSequence: UInt64?
    var method: String?
    var sanitizedHost: String?
    var sanitizedPath: String?
    var statusCode: Int?
    var durationSeconds: Double?
    var evidenceSource: MCPScenarioEvidenceSource
    var observedAt: Date
    /// When `evidenceSource` is `inferredCorrelation`, explains why inference is allowed.
    var inferenceNotes: String?
}

/// Result of evaluating one declarative assertion (AI-3).
struct MCPScenarioAssertionResult: Equatable, Sendable, Codable {
    var assertionIndex: Int
    var kind: MCPScenarioAssertionKind
    var outcome: MCPScenarioAssertionOutcome
    var evidenceSource: MCPScenarioEvidenceSource
    var detail: String?
    var supportingEvidenceIDs: [String]
}

/// Bundled evaluation output returned before cleanup/report handoff (AI-3).
struct MCPScenarioEvaluationResultDTO: Equatable, Sendable, Codable {
    var scenarioID: MCPScenarioID
    var evidence: [MCPScenarioEvidenceRecord]
    var assertionResults: [MCPScenarioAssertionResult]
    var resolvedOutcome: MCPScenarioPhase
    var report: MCPScenarioReportDTO
    var warnings: [String]
}

/// Privacy-filtered scenario report for MCP tools and management UI (AI-3).
struct MCPScenarioReportDTO: Equatable, Sendable, Codable {
    var scenarioID: String
    var scenarioName: String
    var phase: MCPScenarioPhase
    var riskTier: String?
    var activatedAt: Date?
    var evaluatedAt: Date
    var observationWindowSeconds: TimeInterval
    var evidenceCount: Int
    var assertionResults: [MCPScenarioAssertionResult]
    /// Session summaries included when profile allows scenario evidence disclosure.
    var sessionSummaries: [MCPSessionSummaryDTO]?
    var cleanupResult: MCPScenarioPhase?
    var redactionSummary: [String]
    var warnings: [String]
}
