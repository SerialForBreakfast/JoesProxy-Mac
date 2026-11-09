import Foundation

enum MCPScenarioExecutorError: Error, Equatable, Sendable {
    case activationFailed(underlying: String)
    case cleanupRequired(conflicts: [MCPEffectConflictItem])
}

enum MCPScenarioRollbackOutcome: Equatable {
    case allRolledBack
    case partialRollbackFailure([MCPEffectConflictItem])
}

/// Atomically applies a scenario's composed fault set and guarantees all-or-nothing activation
/// (AI-2). Generalizes `MCPProposalCoordinator.applyProposal`'s single-target begin/commit/rollback
/// pattern to N faults — this type owns the journal bookkeeping (via `MCPRecoveryCoordinator`) and
/// the atomicity/cancellation guarantees; it does NOT reimplement fault application. The actual
/// target-store write (and its inverse, for rollback) is injected via `applyFault`/`rollbackFault`.
///
/// Concurrency: `@MainActor` — shares state with `MCPRecoveryCoordinator` and
/// `MCPScenarioLifecycleCoordinator`.
@MainActor
final class MCPScenarioExecutor {
    static let defaultFaultActivationTimeout: TimeInterval = 60

    private let recoveryCoordinator: MCPRecoveryCoordinator
    private let lifecycleCoordinator: MCPScenarioLifecycleCoordinator
    private let applyFault: (MCPScenarioFault, Int, String) async throws -> MCPFaultApplyReceipt
    private let rollbackFault: (MCPScenarioFault, MCPFaultApplyReceipt) async throws -> Void
    private let faultActivationTimeout: TimeInterval

    /// Maps a fault's target lock key to the scenario currently owning it — populated when a
    /// fault's transaction commits, cleared when its cleanup/rollback completes. This is the
    /// definitive "which scenario owns this activated fault" lookup `MCPActiveEffectAttributionResolver`
    /// consults to populate `MCPCaptureAttribution.scenarioID` (AI-2, C.5).
    private var activeFaultOwners: [String: MCPScenarioID] = [:]

    init(
        recoveryCoordinator: MCPRecoveryCoordinator,
        lifecycleCoordinator: MCPScenarioLifecycleCoordinator,
        applyFault: @escaping (MCPScenarioFault, Int, String) async throws -> MCPFaultApplyReceipt,
        rollbackFault: @escaping (MCPScenarioFault, MCPFaultApplyReceipt) async throws -> Void,
        faultActivationTimeout: TimeInterval = MCPScenarioExecutor.defaultFaultActivationTimeout
    ) {
        self.recoveryCoordinator = recoveryCoordinator
        self.lifecycleCoordinator = lifecycleCoordinator
        self.applyFault = applyFault
        self.rollbackFault = rollbackFault
        self.faultActivationTimeout = faultActivationTimeout
    }

    func activeScenarioID(forTargetLockKey key: String) -> MCPScenarioID? {
        activeFaultOwners[key]
    }

    /// Clears fault ownership once its cleanup action has completed (called by
    /// `MCPScenarioCleanupCoordinator` after successfully reverting a fault).
    func clearOwnership(forTargetLockKey key: String) {
        activeFaultOwners.removeValue(forKey: key)
    }

    /// Applies every fault in `definition.faults`, in order, all-or-nothing. On full success the
    /// scenario transitions to `.observing`. On any failure, already-applied faults are rolled
    /// back in reverse order; the scenario lands in `.failed` (clean rollback) or
    /// `.cleanupRequired` (rollback itself failed for at least one fault — exact conflicts
    /// recorded, never silently reported as full success).
    ///
    /// Returns persisted receipts for successfully activated faults when activation completes.
    /// No code path here reaches `.completed` — that transition only exists on the
    /// `cleaningUp -> completed` edge inside `MCPScenarioCleanupCoordinator`.
    @discardableResult
    func activate(
        scenarioID: MCPScenarioID,
        definition: MCPScenarioDefinition,
        clientID: String
    ) async throws -> [MCPScenarioAppliedFaultReceipt] {
        try lifecycleCoordinator.requestActivation(for: scenarioID)
        try lifecycleCoordinator.transition(scenarioID, to: .running)

        var applied: [(index: Int, transactionID: String, receipt: MCPFaultApplyReceipt)] = []
        do {
            for (index, fault) in definition.faults.enumerated() {
                let (transactionID, receipt) = try await applyOneFault(
                    fault,
                    faultIndex: index,
                    clientID: clientID,
                    scenarioID: scenarioID
                )
                applied.append((index, transactionID, receipt))
                activeFaultOwners[fault.targetLockKey] = scenarioID
            }
            let persistedReceipts = applied.map { entry -> MCPScenarioAppliedFaultReceipt in
                var receipt = entry.receipt
                receipt.transactionID = entry.transactionID
                return receipt.persisted(faultIndex: entry.index)
            }
            // Receipts must be durable BEFORE the phase flips to `.observing` — cleanup after a
            // crash/restart only knows what to revert by reading these receipts back, and the
            // lifecycle coordinator's restart reconciliation forces any non-terminal scenario
            // straight into `.cleaningUp` regardless of when the crash happened.
            try lifecycleCoordinator.recordAppliedFaultReceipts(scenarioID: scenarioID, receipts: persistedReceipts)
            try lifecycleCoordinator.transition(scenarioID, to: .observing)
            return persistedReceipts
        } catch {
            let outcome = await rollbackAll(applied, scenarioID: scenarioID, definition: definition)
            lifecycleCoordinator.releaseActivation(for: scenarioID)
            for fault in definition.faults {
                activeFaultOwners.removeValue(forKey: fault.targetLockKey)
            }
            switch outcome {
            case .allRolledBack:
                try lifecycleCoordinator.transition(scenarioID, to: .cleaningUp)
                try lifecycleCoordinator.transition(scenarioID, to: .failed)
                throw MCPScenarioExecutorError.activationFailed(underlying: "\(error)")
            case .partialRollbackFailure(let conflicts):
                try lifecycleCoordinator.transition(scenarioID, to: .cleaningUp)
                try lifecycleCoordinator.transition(scenarioID, to: .cleanupRequired)
                lifecycleCoordinator.recordConflicts(scenarioID: scenarioID, conflicts: conflicts)
                throw MCPScenarioExecutorError.cleanupRequired(conflicts: conflicts)
            }
        }
    }

    /// One fault's begin/apply/commit, journaled through `MCPRecoveryCoordinator` exactly like
    /// `MCPProposalCoordinator.applyProposal`'s single-target pattern, wrapped in the cancellation
    /// bridge (invariant 6).
    private func applyOneFault(
        _ fault: MCPScenarioFault,
        faultIndex: Int,
        clientID: String,
        scenarioID: MCPScenarioID
    ) async throws -> (transactionID: String, receipt: MCPFaultApplyReceipt) {
        let intent = MCPMutationIntent(
            clientID: clientID,
            targetKind: fault.effectKind,
            targetID: fault.targetLockKey,
            baselineRevision: nil,
            intendedChangeDigest: "scenario:\(scenarioID.rawValue):\(fault.targetLockKey)",
            rollbackSnapshot: nil,
            expiresAt: Date().addingTimeInterval(faultActivationTimeout * 2)
        )
        let transactionID = try recoveryCoordinator.beginMutation(intent)
        do {
            var receipt = try await applyOneFaultWithCancellationBridge(
                fault,
                faultIndex: faultIndex,
                clientID: clientID
            )
            receipt.transactionID = transactionID
            try recoveryCoordinator.commitMutation(transactionID: transactionID)
            return (transactionID, receipt)
        } catch {
            try? recoveryCoordinator.rollbackMutation(transactionID: transactionID)
            throw error
        }
    }

    /// Cancellation bridge (invariant 6) — reuses `MCPOperationCoordinator`'s proven
    /// `withThrowingTaskGroup` race-and-cancelAll shape verbatim rather than a bespoke
    /// `Task.detached`/`withTaskCancellationHandler` construction.
    private func applyOneFaultWithCancellationBridge(
        _ fault: MCPScenarioFault,
        faultIndex: Int,
        clientID: String
    ) async throws -> MCPFaultApplyReceipt {
        let timeout = faultActivationTimeout
        return try await withThrowingTaskGroup(of: MCPFaultApplyReceipt.self) { group in
            group.addTask { @MainActor [applyFault] in
                try await applyFault(fault, faultIndex, clientID)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MCPStructuredError(code: .timeout, message: "Fault activation timed out.")
            }
            guard let result = try await group.next() else {
                throw MCPStructuredError(code: .internalFailure, message: "Fault activation produced no result.")
            }
            group.cancelAll()
            return result
        }
    }

    /// Rolls back already-applied faults in reverse order. Continues past an individual rollback
    /// failure rather than abandoning the rest (invariant 8: every cleanup-path write's result is
    /// observed, not assumed) — reports ALL conflicts, not just the first.
    private func rollbackAll(
        _ applied: [(index: Int, transactionID: String, receipt: MCPFaultApplyReceipt)],
        scenarioID: MCPScenarioID,
        definition: MCPScenarioDefinition
    ) async -> MCPScenarioRollbackOutcome {
        var conflicts: [MCPEffectConflictItem] = []
        for (index, transactionID, receipt) in applied.reversed() {
            let fault = definition.faults[index]
            do {
                try await rollbackFault(fault, receipt)
                try recoveryCoordinator.rollbackMutation(transactionID: transactionID)
            } catch {
                conflicts.append(
                    MCPEffectConflictItem(
                        id: transactionID,
                        kind: fault.effectKind,
                        message: "Rollback failed for fault \(index) of scenario \(scenarioID.rawValue).",
                        targetID: fault.targetLockKey
                    )
                )
                // Continue rolling back the rest even after one failure.
            }
        }
        return conflicts.isEmpty ? .allRolledBack : .partialRollbackFailure(conflicts)
    }
}
