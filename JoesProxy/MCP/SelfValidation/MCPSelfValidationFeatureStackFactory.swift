import Foundation

/// Mutation/open-world/recovery services wired to an isolated validation lane (AI-6).
///
/// Sibling to ``MCPSelfValidationScenarioStack`` — together the two stacks cover every MCP
/// capability family a feature-matrix self-validation test needs, all bound to the same lane
/// stores and the same real, isolated proxy port so control-plane calls and real proxy traffic
/// stay consistent.
struct MCPSelfValidationFeatureStack {
    let proposalCoordinator: MCPProposalCoordinator
    let mutationService: MCPMutationService
    let openWorldService: MCPOpenWorldService
    let recoveryService: MCPRecoveryService
}

/// Builds mutation/open-world/recovery service stacks against isolated lane stores (AI-6).
///
/// Concurrency: `@MainActor` — mirrors `MCPServerController.configureMutationService`/
/// `configureOpenWorldService`/`configureRecoveryService` without touching production stores.
@MainActor
enum MCPSelfValidationFeatureStackFactory {
    static func makeStack(
        lane: MCPSelfValidationLane,
        validationProxyPort: UInt16,
        scenarioStack: MCPSelfValidationScenarioStack
    ) -> MCPSelfValidationFeatureStack {
        let snapshotService = MCPSessionSnapshotService(sessionStore: lane.sessionStore)
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: lane.recoveryCoordinator,
            policyRevisionProvider: { lane.policyStore.policyRevision }
        )

        let mutationService = MCPMutationService(
            bookmarkStore: lane.bookmarkStore,
            responseOverrideStore: lane.responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: lane.recoveryCoordinator,
            approvalStore: lane.approvalStore,
            policyStore: lane.policyStore,
            grantStore: lane.grantStore,
            auditStore: lane.auditStore,
            snapshotService: snapshotService,
            throttleConfigurationReader: { lane.configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                lane.configuration.networkThrottleConfiguration = updated
            }
        )

        let sessionMatcher = MCPExecutedSessionMatcher(sessionStore: lane.sessionStore)
        let operationCoordinator = MCPOperationCoordinator(
            sessionStore: lane.sessionStore,
            mediaService: MCPMediaInspectionService(
                sessionStore: lane.sessionStore,
                snapshotService: snapshotService
            ),
            snapshotService: snapshotService,
            policyStore: lane.policyStore,
            auditStore: lane.auditStore
        )
        let openWorldService = MCPOpenWorldService(
            bookmarkStore: lane.bookmarkStore,
            sessionStore: lane.sessionStore,
            responseOverrideStore: lane.responseOverrideStore,
            bookmarkExecutor: URLSessionBookmarkExecutor(),
            sessionMatcher: sessionMatcher,
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: lane.recoveryCoordinator,
            operationCoordinator: operationCoordinator,
            approvalStore: lane.approvalStore,
            policyStore: lane.policyStore,
            grantStore: lane.grantStore,
            auditStore: lane.auditStore,
            runningProxyPort: { validationProxyPort },
            throttleConfigurationReader: { lane.configuration.networkThrottleConfiguration }
        )

        let restorer = MCPRecoveryRestorer(
            responseOverrideStore: lane.responseOverrideStore,
            bookmarkStore: lane.bookmarkStore,
            throttleConfigurationReader: { lane.configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                lane.configuration.networkThrottleConfiguration = updated
            }
        )
        let recoveryService = MCPRecoveryService(
            recoveryCoordinator: lane.recoveryCoordinator,
            journalStore: lane.effectJournalStore,
            restorer: restorer,
            responseOverrideStore: lane.responseOverrideStore,
            bookmarkStore: lane.bookmarkStore,
            throttleConfigurationReader: { lane.configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                lane.configuration.networkThrottleConfiguration = updated
            },
            approvalStore: lane.approvalStore,
            proposalCoordinator: proposalCoordinator,
            auditStore: lane.auditStore,
            grantStore: lane.grantStore,
            scenarioLifecycleCoordinator: lane.lifecycleCoordinator,
            drainScenarioCleanups: { await scenarioStack.runtime.drainPendingCleanups() }
        )

        return MCPSelfValidationFeatureStack(
            proposalCoordinator: proposalCoordinator,
            mutationService: mutationService,
            openWorldService: openWorldService,
            recoveryService: recoveryService
        )
    }
}
