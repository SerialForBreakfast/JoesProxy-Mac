import Foundation

enum MCPScenarioLifecycleError: Error, Equatable, Sendable {
    case scenarioNotFound
    case duplicateScenarioID
    case invalidTransition(from: MCPScenarioPhase, to: MCPScenarioPhase)
    case globalScenarioSlotBusy
    case storeUnavailable
    case validationRequired
    case scenarioExpired
}

/// Owns the scenario state machine and the V1 "one active mutation scenario globally" lock
/// (AI-1). Legal transitions are enforced centrally here so no caller can silently skip a phase
/// (e.g. `draft` straight to `running`).
///
/// The global mutation-scenario lock is a PARALLEL flag, independent of
/// `MCPProposalCoordinator.lockedTargetKeys` — the two have incompatible lock durations
/// (per-call vs. per-scenario-lifetime); merging them would either deadlock or reopen the exact
/// race target-locking exists to prevent. Each fault's real per-target lock is still acquired
/// through the existing proposal/journal path when the executor applies it.
///
/// Concurrency: `@MainActor` — shared with the store, executor, and management UI.
@MainActor
final class MCPScenarioLifecycleCoordinator: ObservableObject {
    /// Every legal (from, to) transition. Anything not listed here is rejected.
    private static let legalTransitions: [MCPScenarioPhase: Set<MCPScenarioPhase>] = [
        .draft: [.validating],
        .validating: [.awaitingApproval, .failed],
        .awaitingApproval: [.armed, .canceled, .failed],
        .armed: [.running, .canceled],
        .running: [.observing, .cleaningUp],
        .observing: [.evaluating, .cleaningUp],
        .evaluating: [.cleaningUp],
        .cleaningUp: [.completed, .failed, .inconclusive, .cleanupRequired],
        .cleanupRequired: [.cleaningUp],
        .completed: [],
        .failed: [],
        .inconclusive: [],
        .canceled: []
    ]

    @Published private(set) var armedScenarioIDs: [String] = []
    @Published private(set) var activeScenarioIDs: [String] = []

    private let store: MCPScenarioStore
    private var activeMutationScenarioID: MCPScenarioID?

    init(store: MCPScenarioStore) {
        self.store = store
    }

    func bootstrap() {
        store.load()
        guard store.isLoaded else { return }
        // Reconcile scenarios that were mid-flight when the process last exited — never leave one
        // silently `running`/`observing`/etc. after a restart (AI-1 exit criterion: restart).
        for record in store.unresolvedScenarios() {
            switch record.phase {
            case .cleaningUp, .cleanupRequired:
                continue
            case .draft, .validating, .awaitingApproval, .armed:
                // Pre-activation phases never applied effects — cancel directly, no cleanup.
                var updated = record
                updated.phase = .canceled
                updated.lastError = "Recovered pre-activation scenario at launch."
                try? store.updateScenario(updated)
            case .running, .observing, .evaluating:
                var updated = record
                updated.phase = .cleaningUp
                updated.cleanupResolvedOutcome = .failed
                updated.lastError = "Recovered incomplete scenario at launch."
                try? store.updateScenario(updated)
            case .completed, .failed, .inconclusive, .canceled:
                break
            }
        }
        refreshPublishedState()
    }

    /// Persists a new scenario in `.draft` without compile-time validation. Full validation runs
    /// through `validate(scenarioID:)` (AI-1).
    @discardableResult
    func createDraft(
        from draft: MCPScenarioDraftInput,
        validationRunID: MCPValidationRunID? = nil,
        now: Date = Date()
    ) throws -> MCPScenarioRecord {
        guard store.isLoaded else {
            throw MCPScenarioLifecycleError.storeUnavailable
        }
        if store.scenario(id: draft.id) != nil {
            throw MCPScenarioLifecycleError.duplicateScenarioID
        }
        let definition = MCPScenarioCompiler.materializeDraft(draft, createdAt: now)
        return try store.createScenario(definition, validationRunID: validationRunID, now: now)
    }

    /// Runs `draft` → `validating` → `awaitingApproval` with compile/risk/disclosure bundling.
    /// On compiler failure the scenario lands in `.failed` with `lastError` populated.
    @discardableResult
    func validate(
        scenarioID: MCPScenarioID,
        now: Date = Date(),
        loopbackPolicy: LoopbackDestinationPolicy = .disabled
    ) throws -> MCPScenarioValidationResultDTO {
        guard var record = store.scenario(id: scenarioID) else {
            throw MCPScenarioLifecycleError.scenarioNotFound
        }
        guard record.phase == .draft else {
            throw MCPScenarioLifecycleError.invalidTransition(from: record.phase, to: .validating)
        }

        _ = try transition(scenarioID, to: .validating)

        do {
            let draft = MCPScenarioDraftInput.fromDefinition(record.definition)
            var result = try MCPScenarioValidationService.validate(
                draft: draft,
                now: now,
                loopbackPolicy: loopbackPolicy
            )
            result.definition.createdAt = record.definition.createdAt
            record = store.scenario(id: scenarioID) ?? record
            record.definition = result.definition
            record.validationResult = result
            record.lastError = nil
            try store.updateScenario(record)
            _ = try transition(scenarioID, to: .awaitingApproval)
            return result
        } catch {
            let message = Self.validationErrorMessage(for: error)
            recordError(scenarioID: scenarioID, message: message)
            try? transition(scenarioID, to: .failed)
            throw error
        }
    }

    /// Human/app-owned approval step: `awaitingApproval` → `armed`. Does not activate effects.
    @discardableResult
    func approve(scenarioID: MCPScenarioID, now: Date = Date()) throws -> MCPScenarioRecord {
        guard let record = store.scenario(id: scenarioID) else {
            throw MCPScenarioLifecycleError.scenarioNotFound
        }
        guard record.phase == .awaitingApproval else {
            throw MCPScenarioLifecycleError.invalidTransition(from: record.phase, to: .armed)
        }
        guard record.validationResult != nil else {
            throw MCPScenarioLifecycleError.validationRequired
        }
        if let expiresAt = record.definition.expiresAt, expiresAt <= now {
            recordError(scenarioID: scenarioID, message: "Scenario expired before approval.")
            try? transition(scenarioID, to: .failed)
            throw MCPScenarioLifecycleError.scenarioExpired
        }

        var armed = try transition(scenarioID, to: .armed)
        armed.approvedAt = now
        try store.updateScenario(armed)
        refreshPublishedState()
        return armed
    }

    /// Validates and performs a phase transition, persisting the result.
    @discardableResult
    func transition(_ id: MCPScenarioID, to newPhase: MCPScenarioPhase) throws -> MCPScenarioRecord {
        guard var record = store.scenario(id: id) else {
            throw MCPScenarioLifecycleError.scenarioNotFound
        }
        // cleaningUp -> cleaningUp is a legal no-op (idempotent re-entry from multiple trigger
        // paths racing to clean up the same scenario).
        if record.phase == newPhase, record.phase == .cleaningUp {
            return record
        }
        guard Self.legalTransitions[record.phase]?.contains(newPhase) == true else {
            throw MCPScenarioLifecycleError.invalidTransition(from: record.phase, to: newPhase)
        }
        record.phase = newPhase
        switch newPhase {
        case .armed:
            record.armedAt = Date()
        case .running:
            record.activatedAt = Date()
        case .completed, .failed, .inconclusive, .canceled:
            record.cleanupCompletedAt = Date()
        default:
            break
        }
        try store.updateScenario(record)
        refreshPublishedState()
        return record
    }

    func recordConflicts(scenarioID: MCPScenarioID, conflicts: [MCPEffectConflictItem]) {
        guard var record = store.scenario(id: scenarioID) else { return }
        record.conflicts.append(contentsOf: conflicts)
        try? store.updateScenario(record)
    }

    /// Persists applied-fault receipts. Callers must invoke this BEFORE transitioning the scenario
    /// to `.observing` (not after) — a crash between "phase says .observing" and "receipts written"
    /// would leave `MCPScenarioCleanupCoordinator` unable to find what to revert, orphaning the
    /// real applied effect forever (there would be no receipt for it to clean up on restart).
    func recordAppliedFaultReceipts(scenarioID: MCPScenarioID, receipts: [MCPScenarioAppliedFaultReceipt]) throws {
        guard var record = store.scenario(id: scenarioID) else {
            throw MCPScenarioLifecycleError.scenarioNotFound
        }
        record.appliedFaultReceipts = receipts
        try store.updateScenario(record)
    }

    func recordError(scenarioID: MCPScenarioID, message: String) {
        guard var record = store.scenario(id: scenarioID) else { return }
        record.lastError = message
        try? store.updateScenario(record)
    }

    // MARK: - Global mutation-scenario lock

    func requestActivation(for id: MCPScenarioID) throws {
        guard activeMutationScenarioID == nil || activeMutationScenarioID == id else {
            throw MCPScenarioLifecycleError.globalScenarioSlotBusy
        }
        activeMutationScenarioID = id
    }

    func releaseActivation(for id: MCPScenarioID) {
        if activeMutationScenarioID == id {
            activeMutationScenarioID = nil
        }
    }

    // MARK: - Teardown hooks (mirrors MCPOperationCoordinator.cancelOperations/cancelAll)

    /// Forces every non-terminal scenario owned by `clientID` into `cleaningUp`. Wired from
    /// `MCPServerController.revokeClient`/`rotateClient`.
    func cancelScenarios(forClientID clientID: String) {
        for record in store.scenarios where record.definition.originatingClientID == clientID {
            forceCleaningUp(record)
        }
    }

    func activeScenarioIDs(forClientID clientID: String) -> [String] {
        store.scenarios
            .filter {
                $0.definition.originatingClientID == clientID
                    && $0.phase.ownsActiveEffects
            }
            .map(\.id.rawValue)
    }

    func unresolvedScenarioIDs(forClientID clientID: String) -> [String] {
        store.scenarios
            .filter {
                $0.definition.originatingClientID == clientID
                    && !$0.phase.isPrunableTerminal
            }
            .map(\.id.rawValue)
    }

    var unresolvedScenarioCount: Int {
        store.scenarios.filter { !$0.phase.isPrunableTerminal }.count
    }

    /// Forces every non-terminal scenario into `cleaningUp`. Wired from
    /// `MCPServerController.stop()` and `MCPRecoveryService.returnToNormal`.
    func cancelAllScenarios() {
        for record in store.scenarios where !record.phase.isPrunableTerminal {
            forceCleaningUp(record)
        }
    }

    func cancel(scenarioID: MCPScenarioID) {
        guard let record = store.scenario(id: scenarioID) else { return }
        forceCleaningUp(record)
    }

    private func forceCleaningUp(_ record: MCPScenarioRecord, outcome: MCPScenarioPhase = .canceled) {
        guard !record.phase.isPrunableTerminal, record.phase != .cleaningUp else { return }
        // armed/awaitingApproval never activated effects — cancel directly, no cleanup needed.
        if record.phase == .armed || record.phase == .awaitingApproval {
            try? transition(record.id, to: .canceled)
            return
        }
        var updated = record
        updated.cleanupResolvedOutcome = outcome
        try? store.updateScenario(updated)
        try? transition(record.id, to: .cleaningUp)
    }

    // MARK: - UI-test seeding (replaces the old MCPServerController.testSetArmedScenarioIDs stub)

    func testSeedScenario(_ definition: MCPScenarioDefinition, phase: MCPScenarioPhase) {
        guard let record = try? store.createScenario(definition) else { return }
        var seeded = record
        seeded.phase = phase
        try? store.updateScenario(seeded)
        refreshPublishedState()
    }

    private func refreshPublishedState() {
        armedScenarioIDs = store.scenarios.filter { $0.phase == .armed }.map(\.id.rawValue)
        activeScenarioIDs = store.scenarios.filter { $0.phase.ownsActiveEffects }.map(\.id.rawValue)
    }

    private static func validationErrorMessage(for error: Error) -> String {
        if let compilerError = error as? MCPScenarioCompilerError {
            return MCPScenarioCompiler.structuredError(for: compilerError).message
        }
        return String(describing: error)
    }
}
