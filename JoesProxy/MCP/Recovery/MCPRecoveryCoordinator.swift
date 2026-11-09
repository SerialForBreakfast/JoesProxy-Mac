import Foundation

enum MCPRecoveryCoordinatorError: Error, Equatable, Sendable {
    case journalUnavailable
    case transactionNotFound
    case targetLocked
    case staleTargetRevision
}

/// Describes an MCP mutation about to be journaled and applied.
struct MCPMutationIntent: Equatable, Sendable {
    var clientID: String
    var targetKind: MCPEffectKind
    var targetID: String
    var baselineRevision: MCPTargetRevision?
    var intendedChangeDigest: String
    var rollbackSnapshot: Data?
    var expiresAt: Date
}

/// Owns durable MCP effect transactions, startup reconciliation, and effect-state projection.
///
/// Concurrency: `@MainActor` — coordinates with journal persistence and management UI.
@MainActor
final class MCPRecoveryCoordinator: ObservableObject {
    @Published private(set) var effectState: MCPEffectState = .clean

    private let journalStore: MCPEffectJournalStore
    private var activeTransactions: [String: MCPMutationIntent] = [:]
    private var cachedLiveEffectSummary: MCPEffectSummary = .empty
    /// When set, ``refreshEffectState()`` keeps this value (UI-test fixture seeding).
    private var uiTestEffectStateOverride: MCPEffectState?

    init(journalStore: MCPEffectJournalStore) {
        self.journalStore = journalStore
    }

    /// Updates the cached live-effect scan used when projecting `.active` state.
    func updateCachedLiveEffectSummary(_ summary: MCPEffectSummary) {
        cachedLiveEffectSummary = summary
        refreshEffectState()
    }

    func bootstrap() {
        journalStore.load()
        effectState = reconcileAtLaunch()
    }

    /// Writes intent before a mutation reaches an underlying store.
    @discardableResult
    func beginMutation(_ intent: MCPMutationIntent, now: Date = Date()) throws -> String {
        guard journalStore.isLoaded else {
            throw MCPRecoveryCoordinatorError.journalUnavailable
        }
        let transactionID = UUID().uuidString
        let entry = MCPEffectJournalEntry(
            id: UUID(),
            transactionID: transactionID,
            clientID: intent.clientID,
            targetKind: intent.targetKind,
            targetID: intent.targetID,
            baselineRevision: intent.baselineRevision,
            intendedChangeDigest: intent.intendedChangeDigest,
            rollbackSnapshot: intent.rollbackSnapshot,
            expiresAt: intent.expiresAt,
            phase: .intent,
            createdAt: now,
            conflictMessage: nil
        )
        try journalStore.appendIntent(entry)
        activeTransactions[transactionID] = intent
        refreshEffectState()
        return transactionID
    }

    /// Marks a journaled mutation committed after the target store succeeds.
    ///
    /// - Parameter resultingRevision: the target's revision immediately after the real store write
    ///   — pass this whenever the caller can compute it, so a later restore's drift check has the
    ///   correct post-mutation anchor to compare against instead of the pre-mutation baseline.
    func commitMutation(transactionID: String, resultingRevision: MCPTargetRevision? = nil) throws {
        guard journalStore.isLoaded else {
            throw MCPRecoveryCoordinatorError.journalUnavailable
        }
        guard activeTransactions[transactionID] != nil else {
            throw MCPRecoveryCoordinatorError.transactionNotFound
        }
        try journalStore.updatePhase(transactionID: transactionID, phase: .committed, resultingRevision: resultingRevision)
        activeTransactions.removeValue(forKey: transactionID)
        refreshEffectState()
    }

    /// Marks a journaled mutation rolled back when apply fails before commit.
    func rollbackMutation(transactionID: String) throws {
        guard journalStore.isLoaded else {
            throw MCPRecoveryCoordinatorError.journalUnavailable
        }
        try journalStore.updatePhase(transactionID: transactionID, phase: .rolledBack)
        activeTransactions.removeValue(forKey: transactionID)
        refreshEffectState()
    }

    /// Reconciles incomplete journal entries at launch before MCP-owned effects are usable.
    func reconcileAtLaunch(now: Date = Date()) -> MCPEffectState {
        guard journalStore.isLoaded else {
            return .conflict([
                MCPEffectConflictItem(
                    id: "journal-unavailable",
                    kind: .responseOverride,
                    message: journalStore.loadFailureReason ?? "Effect journal unavailable."
                )
            ])
        }

        let unresolved = journalStore.unresolvedEntries(now: now)
        guard !unresolved.isEmpty else {
            return .clean
        }

        var conflicts: [MCPEffectConflictItem] = []
        for entry in unresolved {
            switch entry.phase {
            case .intent:
                do {
                    try journalStore.updatePhase(
                        transactionID: entry.transactionID,
                        phase: .rolledBack,
                        conflictMessage: "Recovered incomplete MCP mutation at launch."
                    )
                } catch {
                    conflicts.append(
                        MCPEffectConflictItem(
                            id: entry.transactionID,
                            kind: entry.targetKind,
                            message: "Failed to reconcile incomplete MCP mutation."
                        )
                    )
                }
            case .conflict:
                conflicts.append(
                    MCPEffectConflictItem(
                        id: entry.transactionID,
                        kind: entry.targetKind,
                        message: entry.conflictMessage ?? "Unresolved MCP effect conflict."
                    )
                )
            case .committed, .rolledBack:
                break
            }
        }

        if conflicts.isEmpty {
            return .clean
        }
        return .conflict(conflicts)
    }

    func markConflict(transactionID: String, message: String) throws {
        try journalStore.updatePhase(transactionID: transactionID, phase: .conflict, conflictMessage: message)
        activeTransactions.removeValue(forKey: transactionID)
        refreshEffectState()
    }

    /// Resolves a journaled conflict after user review or a successful retry restore.
    func resolveConflict(
        transactionID: String,
        resolution: MCPRecoveryConflictResolution,
        message: String? = nil
    ) throws {
        guard journalStore.entry(transactionID: transactionID)?.phase == .conflict else {
            throw MCPRecoveryCoordinatorError.transactionNotFound
        }
        let resolvedMessage = message ?? {
            switch resolution {
            case .accept:
                return "Conflict accepted by user; target left unchanged."
            case .retryRestore:
                return "Conflict resolved after successful restore."
            }
        }()
        try journalStore.updatePhase(
            transactionID: transactionID,
            phase: .rolledBack,
            conflictMessage: resolvedMessage
        )
        refreshEffectState()
    }

    /// Recomputes cached live-effect summary from stores and refreshes published effect state.
    func refreshEffectSummary(
        rules: [ResponseOverrideRule],
        bookmarks: [Bookmark],
        throttleConfiguration: NetworkThrottleConfiguration,
        activeScenarioIDs: [String] = []
    ) {
        let summary = MCPEffectStateScanner.summarize(
            rules: rules,
            bookmarks: bookmarks,
            throttleConfiguration: throttleConfiguration,
            activeScenarioIDs: activeScenarioIDs
        )
        updateCachedLiveEffectSummary(summary)
    }

    var cachedLiveEffectSummarySnapshot: MCPEffectSummary {
        cachedLiveEffectSummary
    }

    private func refreshEffectState() {
        if let uiTestEffectStateOverride {
            effectState = uiTestEffectStateOverride
            return
        }
        guard journalStore.isLoaded else {
            effectState = .conflict([
                MCPEffectConflictItem(
                    id: "journal-unavailable",
                    kind: .responseOverride,
                    message: journalStore.loadFailureReason ?? "Effect journal unavailable."
                )
            ])
            return
        }

        let conflicts = journalStore.entries.compactMap { entry -> MCPEffectConflictItem? in
            guard entry.phase == .conflict else {
                return nil
            }
            return MCPEffectConflictItem(
                id: entry.transactionID,
                kind: entry.targetKind,
                message: entry.conflictMessage ?? "Unresolved MCP effect conflict.",
                targetID: entry.targetID
            )
        }
        if conflicts.isEmpty {
            effectState = MCPEffectStateScanner.effectState(from: cachedLiveEffectSummary)
        } else {
            effectState = .conflict(conflicts)
        }
    }

    /// UI-test hook to seed effect-state projection without live MCP effects.
    func testSetEffectState(_ state: MCPEffectState) {
        uiTestEffectStateOverride = state
        effectState = state
    }
}
