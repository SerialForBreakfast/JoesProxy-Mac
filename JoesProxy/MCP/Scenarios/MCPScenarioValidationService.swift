import Foundation

/// Bundles compile output for approval flows. Lifecycle orchestration that persists the result
/// lives in `MCPScenarioLifecycleCoordinator.validate` (AI-1).
@MainActor
enum MCPScenarioValidationService {
    static func validate(
        draft: MCPScenarioDraftInput,
        now: Date = Date(),
        loopbackPolicy: LoopbackDestinationPolicy = .disabled
    ) throws -> MCPScenarioValidationResultDTO {
        let definition = try MCPScenarioCompiler.compile(draft: draft, now: now, loopbackPolicy: loopbackPolicy)
        let tier = MCPScenarioCompiler.riskTier(for: definition)
        let disclosure = MCPScenarioCompiler.approvalDisclosure(for: definition)
        var warnings: [String] = []
        if definition.assertions.contains(where: { $0.evidenceSource == .inferredCorrelation }) {
            warnings.append(
                "One or more assertions use inferredCorrelation; reports must label them as inferred, not directly observed."
            )
        }
        if definition.assertions.contains(where: {
            switch $0.kind {
            case .sdkStateTransition, .sdkErrorCategory, .sdkRetryState, .sdkPlaybackState,
                 .sdkBufferingOrStall, .sdkFallbackActivated, .sdkUserVisibleRecovery, .sdkTestStepMarker:
                return true
            default:
                return false
            }
        }) {
            warnings.append("SDK assertion kinds are schema-valid; evaluation returns inconclusive until AI-3 SDK observation plumbing lands.")
        }
        return MCPScenarioValidationResultDTO(
            definition: definition,
            riskTier: tier.rawValue,
            affectedTargetKeys: Array(MCPScenarioCompiler.affectedTargetKeys(for: definition)).sorted(),
            approvalDisclosure: disclosure,
            warnings: warnings
        )
    }
}
