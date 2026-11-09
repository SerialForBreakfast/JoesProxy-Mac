import Foundation

/// Outcome of evaluating whether a diagnostic view needs an interlock warning.
struct MCPDiagnosticInterlockEvaluation: Equatable, Sendable {
    var requiresWarning: Bool
    var relevantItems: [MCPEffectInventoryItem]
    var activeScenarioIDs: [String]
    var requiresScenarioStop: Bool
    var failClosedUnknownEffect: Bool
    var summaryMessage: String?
}

/// Result of beginning a scoped clean measurement.
enum MCPDiagnosticMeasurementBeginResult: Equatable, Sendable {
    case started
    case requiresScenarioStop(scenarioIDs: [String])
    case nothingToSuspend
    case failed(message: String)
}

/// Snapshot captured before temporarily disabling an effect for clean measurement.
struct MCPSuspendedEffectSnapshot: Equatable, Sendable {
    var item: MCPEffectInventoryItem
    var throttleConfiguration: NetworkThrottleConfiguration?
}
