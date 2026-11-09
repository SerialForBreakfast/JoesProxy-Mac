import Foundation

/// Scenario stack wired to an isolated validation lane (AI-5).
struct MCPSelfValidationScenarioStack {
    let service: MCPScenarioService
    let runtime: MCPScenarioRuntimeService
    let validationRunID: MCPValidationRunID
    let validationClient: MCPClientRecord
}

/// Builds scenario lifecycle/runtime/service stacks against isolated lane stores.
///
/// Concurrency: `@MainActor` — mirrors production MCP scenario wiring without touching production stores.
@MainActor
enum MCPSelfValidationScenarioStackFactory {
    static func makeStack(
        lane: MCPSelfValidationLane,
        validationProxyPort: UInt16,
        validationClientID: String = "self-validation-client"
    ) -> MCPSelfValidationScenarioStack {
        let restorer = MCPRecoveryRestorer(
            responseOverrideStore: lane.responseOverrideStore,
            bookmarkStore: lane.bookmarkStore,
            throttleConfigurationReader: { lane.configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                lane.configuration.networkThrottleConfiguration = updated
            }
        )
        let applicator = MCPScenarioFaultApplicator(
            responseOverrideStore: lane.responseOverrideStore,
            bookmarkStore: lane.bookmarkStore,
            runningProxyPort: { validationProxyPort },
            restorer: restorer,
            throttleConfigurationReader: { lane.configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                lane.configuration.networkThrottleConfiguration = updated
            }
        )
        let snapshotService = MCPSessionSnapshotService(sessionStore: lane.sessionStore)
        let observationService = MCPScenarioObservationService(
            sessionStore: lane.sessionStore,
            snapshotService: snapshotService,
            policyStore: lane.policyStore,
            scenarioStore: lane.scenarioStore,
            lifecycleCoordinator: lane.lifecycleCoordinator
        )
        let runtime = MCPScenarioRuntimeService(
            lifecycleCoordinator: lane.lifecycleCoordinator,
            scenarioStore: lane.scenarioStore,
            recoveryCoordinator: lane.recoveryCoordinator,
            faultApplicator: applicator,
            observationService: observationService
        )
        let service = MCPScenarioService(
            lifecycleCoordinator: lane.lifecycleCoordinator,
            scenarioStore: lane.scenarioStore,
            runtimeServiceProvider: { runtime },
            policyStore: lane.policyStore,
            grantStore: lane.grantStore,
            approvalStore: lane.approvalStore,
            auditStore: lane.auditStore,
            validationRunID: lane.validationRunID
        )
        let client = MCPClientRecord(
            id: validationClientID,
            displayName: "Self-Validation Client",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return MCPSelfValidationScenarioStack(
            service: service,
            runtime: runtime,
            validationRunID: lane.validationRunID,
            validationClient: client
        )
    }
}
