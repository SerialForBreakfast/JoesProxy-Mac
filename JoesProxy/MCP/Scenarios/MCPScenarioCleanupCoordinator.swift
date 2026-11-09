import Foundation

/// Shared teardown routine invoked from every scenario-cleanup trigger path so behavior can't
/// drift between them (AI-2 exit criterion: "completion, failure, cancellation, disconnect,
/// server stop, and Return To Normal" all funnel through the same code).
///
/// Distinct from `MCPScenarioExecutor.rollbackAll`: that routine reverts faults that were **not
/// yet fully committed** mid-activation (a partial-failure path). This routine reverts faults
/// from a **fully-activated, already-running** scenario — a different situation that happens to
/// share terminal outcomes (`.failed`/`.cleanupRequired`). Keeping them separate avoids
/// conflating "rollback an incomplete activation" with "clean up a completed activation."
///
/// Concurrency: `@MainActor`.
@MainActor
final class MCPScenarioCleanupCoordinator {
    private let lifecycleCoordinator: MCPScenarioLifecycleCoordinator
    private let scenarioStore: MCPScenarioStore
    private let executor: MCPScenarioExecutor
    private let faultApplicator: MCPScenarioFaultApplicator

    init(
        lifecycleCoordinator: MCPScenarioLifecycleCoordinator,
        scenarioStore: MCPScenarioStore,
        executor: MCPScenarioExecutor,
        faultApplicator: MCPScenarioFaultApplicator
    ) {
        self.lifecycleCoordinator = lifecycleCoordinator
        self.scenarioStore = scenarioStore
        self.executor = executor
        self.faultApplicator = faultApplicator
    }

    /// Terminal state to use when cleanup succeeds. When AI-3 evaluation ran, callers should pass
    /// `record.cleanupResolvedOutcome` (or let `finishScenario` derive it from assertion severity).
    func cleanup(scenarioID: MCPScenarioID, resolvedOutcome: MCPScenarioPhase = .completed) async {
        guard var record = scenarioStore.scenario(id: scenarioID) else { return }
        guard !record.phase.isPrunableTerminal else { return }

        if record.phase != .cleaningUp {
            record.cleanupResolvedOutcome = resolvedOutcome
            try? scenarioStore.updateScenario(record)
            try? lifecycleCoordinator.transition(scenarioID, to: .cleaningUp)
            record = scenarioStore.scenario(id: scenarioID) ?? record
        }

        let outcome = record.cleanupResolvedOutcome ?? resolvedOutcome
        var conflicts: [MCPEffectConflictItem] = []
        let receipts = record.appliedFaultReceipts.sorted { $0.faultIndex > $1.faultIndex }
        for receipt in receipts {
            let fault = record.definition.faults[safe: receipt.faultIndex]
            do {
                try await faultApplicator.revert(receipt: receipt, fault: fault)
                if let fault {
                    executor.clearOwnership(forTargetLockKey: fault.targetLockKey)
                }
            } catch {
                conflicts.append(
                    MCPEffectConflictItem(
                        id: receipt.transactionID,
                        kind: receipt.effectKind,
                        message: "Cleanup failed to revert fault at \(receipt.inventoryTargetID) for scenario \(scenarioID.rawValue).",
                        targetID: fault?.targetLockKey
                    )
                )
            }
        }

        if conflicts.isEmpty {
            lifecycleCoordinator.releaseActivation(for: scenarioID)
            try? lifecycleCoordinator.transition(scenarioID, to: outcome)
        } else {
            lifecycleCoordinator.recordConflicts(scenarioID: scenarioID, conflicts: conflicts)
            try? lifecycleCoordinator.transition(scenarioID, to: .cleanupRequired)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
