import Foundation

/// Orchestrates scenario activation and cleanup against real stores (AI-2).
///
/// Concurrency: `@MainActor` — owns ``MCPScenarioExecutor`` and ``MCPScenarioCleanupCoordinator``
/// wired to the MCP controller's stores.
@MainActor
final class MCPScenarioRuntimeService {
    let executor: MCPScenarioExecutor
    let cleanupCoordinator: MCPScenarioCleanupCoordinator
    let faultApplicator: MCPScenarioFaultApplicator
    let observationService: MCPScenarioObservationService

    private let lifecycleCoordinator: MCPScenarioLifecycleCoordinator
    private let scenarioStore: MCPScenarioStore
    private let activationContext = ActivationContext()

    private final class ActivationContext {
        var scenarioID: MCPScenarioID?
    }

    init(
        lifecycleCoordinator: MCPScenarioLifecycleCoordinator,
        scenarioStore: MCPScenarioStore,
        recoveryCoordinator: MCPRecoveryCoordinator,
        faultApplicator: MCPScenarioFaultApplicator,
        observationService: MCPScenarioObservationService
    ) {
        self.lifecycleCoordinator = lifecycleCoordinator
        self.scenarioStore = scenarioStore
        self.faultApplicator = faultApplicator
        self.observationService = observationService
        let context = activationContext
        self.executor = MCPScenarioExecutor(
            recoveryCoordinator: recoveryCoordinator,
            lifecycleCoordinator: lifecycleCoordinator,
            applyFault: { fault, index, clientID in
                guard let scenarioID = context.scenarioID else {
                    throw MCPStructuredError(code: .internalFailure, message: "Scenario activation context missing.")
                }
                return try await faultApplicator.apply(
                    fault: fault,
                    faultIndex: index,
                    clientID: clientID,
                    scenarioID: scenarioID
                )
            },
            rollbackFault: { fault, receipt in
                try await faultApplicator.rollback(fault: fault, receipt: receipt)
            }
        )
        self.cleanupCoordinator = MCPScenarioCleanupCoordinator(
            lifecycleCoordinator: lifecycleCoordinator,
            scenarioStore: scenarioStore,
            executor: executor,
            faultApplicator: faultApplicator
        )
    }

    func activateScenario(_ scenarioID: MCPScenarioID) async throws {
        guard let record = scenarioStore.scenario(id: scenarioID) else {
            throw MCPScenarioLifecycleError.scenarioNotFound
        }
        guard record.phase == .armed else {
            throw MCPScenarioLifecycleError.invalidTransition(from: record.phase, to: .running)
        }

        activationContext.scenarioID = scenarioID
        defer { activationContext.scenarioID = nil }

        // `executor.activate` persists applied-fault receipts itself before flipping the phase to
        // `.observing` (atomicity is owned there, not here) — no second write needed.
        try await executor.activate(
            scenarioID: scenarioID,
            definition: record.definition,
            clientID: record.definition.originatingClientID
        )
    }

    @discardableResult
    func evaluateScenario(_ scenarioID: MCPScenarioID, now: Date = Date()) throws -> MCPScenarioEvaluationResultDTO {
        try observationService.evaluateScenario(scenarioID, now: now)
    }

    func finishScenario(_ scenarioID: MCPScenarioID, outcome: MCPScenarioPhase? = nil) async {
        var resolvedOutcome = outcome
        if let record = scenarioStore.scenario(id: scenarioID) {
            switch record.phase {
            case .observing:
                if let evaluation = try? observationService.evaluateScenario(scenarioID) {
                    if resolvedOutcome == nil {
                        resolvedOutcome = evaluation.resolvedOutcome
                    }
                } else if resolvedOutcome == nil {
                    resolvedOutcome = .failed
                }
            case .evaluating:
                if resolvedOutcome == nil {
                    resolvedOutcome = record.cleanupResolvedOutcome ?? .completed
                }
            default:
                break
            }
        }
        await cleanupCoordinator.cleanup(
            scenarioID: scenarioID,
            resolvedOutcome: resolvedOutcome ?? .completed
        )
    }

    /// Runs cleanup for every scenario currently in `cleaningUp` or retrying from
    /// `cleanupRequired`.
    func drainPendingCleanups() async {
        let pending = scenarioStore.scenarios.filter {
            $0.phase == .cleaningUp || $0.phase == .cleanupRequired
        }
        for record in pending {
            let outcome = record.cleanupResolvedOutcome ?? defaultOutcome(for: record.phase)
            await cleanupCoordinator.cleanup(scenarioID: record.id, resolvedOutcome: outcome)
        }
    }

    func scheduleCleanup(for scenarioID: MCPScenarioID, outcome: MCPScenarioPhase) {
        guard let record = scenarioStore.scenario(id: scenarioID) else { return }
        guard !record.phase.isPrunableTerminal else { return }
        if record.phase == .armed || record.phase == .awaitingApproval {
            try? lifecycleCoordinator.transition(scenarioID, to: .canceled)
            return
        }
        var updated = record
        updated.cleanupResolvedOutcome = outcome
        try? scenarioStore.updateScenario(updated)
        if record.phase != .cleaningUp {
            try? lifecycleCoordinator.transition(scenarioID, to: .cleaningUp)
        }
        Task { await self.cleanupCoordinator.cleanup(scenarioID: scenarioID, resolvedOutcome: outcome) }
    }

    private func defaultOutcome(for phase: MCPScenarioPhase) -> MCPScenarioPhase {
        switch phase {
        case .cleanupRequired:
            return .failed
        default:
            return .canceled
        }
    }
}
