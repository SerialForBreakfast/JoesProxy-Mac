import Foundation

/// Thin orchestrator for Return To Normal, disable, detach, and conflict resolution.
///
/// Concurrency: `@MainActor` — delegates effect-state publication to ``MCPRecoveryCoordinator``.
@MainActor
final class MCPRecoveryService {
    private let recoveryCoordinator: MCPRecoveryCoordinator
    private let journalStore: MCPEffectJournalStore
    private let restorer: MCPRecoveryRestorer
    private let responseOverrideStore: ResponseOverrideStore
    private let bookmarkStore: any BookmarkStore
    private let throttleConfigurationReader: () -> NetworkThrottleConfiguration
    private let throttleConfigurationWriter: (NetworkThrottleConfiguration) -> Void
    private let approvalStore: MCPApprovalStore
    private let proposalCoordinator: MCPProposalCoordinator
    private let auditStore: MCPAuditStore
    private let grantStore: MCPClientGrantStore?
    private let scenarioLifecycleCoordinator: MCPScenarioLifecycleCoordinator?
    private let drainScenarioCleanups: (() async -> Void)?
    private let fixtureRunStore: HLSFixtureRunStore?
    private let openAPIMockPackCoordinator: OpenAPIMockPackCoordinator?
    private let diagnosticRunCoordinator: DiagnosticRunCoordinator?

    init(
        recoveryCoordinator: MCPRecoveryCoordinator,
        journalStore: MCPEffectJournalStore,
        restorer: MCPRecoveryRestorer,
        responseOverrideStore: ResponseOverrideStore,
        bookmarkStore: any BookmarkStore,
        throttleConfigurationReader: @escaping () -> NetworkThrottleConfiguration,
        throttleConfigurationWriter: @escaping (NetworkThrottleConfiguration) -> Void,
        approvalStore: MCPApprovalStore,
        proposalCoordinator: MCPProposalCoordinator,
        auditStore: MCPAuditStore,
        grantStore: MCPClientGrantStore? = nil,
        scenarioLifecycleCoordinator: MCPScenarioLifecycleCoordinator? = nil,
        drainScenarioCleanups: (() async -> Void)? = nil,
        fixtureRunStore: HLSFixtureRunStore? = nil,
        openAPIMockPackCoordinator: OpenAPIMockPackCoordinator? = nil,
        diagnosticRunCoordinator: DiagnosticRunCoordinator? = nil
    ) {
        self.recoveryCoordinator = recoveryCoordinator
        self.journalStore = journalStore
        self.restorer = restorer
        self.responseOverrideStore = responseOverrideStore
        self.bookmarkStore = bookmarkStore
        self.throttleConfigurationReader = throttleConfigurationReader
        self.throttleConfigurationWriter = throttleConfigurationWriter
        self.approvalStore = approvalStore
        self.proposalCoordinator = proposalCoordinator
        self.auditStore = auditStore
        self.grantStore = grantStore
        self.scenarioLifecycleCoordinator = scenarioLifecycleCoordinator
        self.drainScenarioCleanups = drainScenarioCleanups
        self.fixtureRunStore = fixtureRunStore
        self.openAPIMockPackCoordinator = openAPIMockPackCoordinator
        self.diagnosticRunCoordinator = diagnosticRunCoordinator
    }

    func disableEffect(itemID: String) async throws {
        let inventory = await buildInventory()
        guard let item = inventory.first(where: { $0.id == itemID }) else {
            throw MCPStructuredError(code: .conflict, message: "Effect item not found.")
        }
        try await restorer.disable(item: item)
        await refreshEffectSummary()
    }

    func buildInventory() async -> [MCPEffectInventoryItem] {
        let rules = await responseOverrideStore.rules()
        let bookmarks = bookmarkStore.loadBookmarks()
        let throttle = throttleConfigurationReader()
        return MCPEffectInventoryBuilder.build(
            rules: rules,
            bookmarks: bookmarks,
            throttleConfiguration: throttle,
            journalEntries: journalStore.entries,
            openAPIMockPacks: openAPIMockPackCoordinator?.packs ?? []
        )
    }

    func runtimeStatus(activeOperationCount: Int) async -> MCPRuntimeStatusDTO {
        let inventory = await buildInventory()
        let effectStateName: String
        let conflictCount: Int
        switch recoveryCoordinator.effectState {
        case .clean:
            effectStateName = "clean"
            conflictCount = 0
        case .active:
            effectStateName = "active"
            conflictCount = 0
        case .conflict(let conflicts):
            effectStateName = "conflict"
            conflictCount = conflicts.count
        }
        return MCPRuntimeStatusDTO(
            effectState: effectStateName,
            activeEffectCount: inventory.filter(\.isEnabled).count,
            cleanupConflictCount: conflictCount,
            activeOperationCount: activeOperationCount,
            pendingApprovalCount: approvalStore.pendingCount,
            activeScenarioCount: scenarioLifecycleCoordinator?.unresolvedScenarioCount ?? 0
        )
    }

    func clientCleanupStatus(
        clientID: String,
        activeOperationCount: Int,
        policyRevision: MCPPolicyRevision
    ) async -> MCPClientCleanupStatusDTO {
        let inventory = await buildInventory()
        let activeEffectCount = inventory.filter {
            $0.clientID == clientID && $0.isEnabled
        }.count
        let cleanupConflictCount = journalStore.entries.count {
            $0.clientID == clientID && $0.phase == .conflict
        }
        let pendingApprovalCount = approvalStore.pendingRequests.filter {
            $0.clientID == clientID
        }.count
        let activeScenarioCount = scenarioLifecycleCoordinator?
            .unresolvedScenarioIDs(forClientID: clientID).count ?? 0
        let activeFixtureRunCount = fixtureRunStore?.unresolvedRunIDs(forClientID: clientID).count ?? 0
        let activeDiagnosticRunCount = diagnosticRunCoordinator?.nonterminalCount(ownedBy: clientID) ?? 0

        var reasonCodes: [String] = []
        if activeEffectCount > 0 { reasonCodes.append("active_effects") }
        if cleanupConflictCount > 0 { reasonCodes.append("cleanup_conflicts") }
        if activeOperationCount > 0 { reasonCodes.append("active_operations") }
        if pendingApprovalCount > 0 { reasonCodes.append("pending_approvals") }
        if activeScenarioCount > 0 { reasonCodes.append("active_scenarios") }
        if activeFixtureRunCount > 0 { reasonCodes.append("active_fixture_runs") }
        if activeDiagnosticRunCount > 0 { reasonCodes.append("active_diagnostic_runs") }

        let recommendedAction: String
        if cleanupConflictCount > 0 {
            recommendedAction = "resolve_cleanup_conflicts"
        } else if activeOperationCount > 0 {
            recommendedAction = "cancel_or_wait_for_operations"
        } else if activeScenarioCount > 0 || activeFixtureRunCount > 0 || activeDiagnosticRunCount > 0
                    || activeEffectCount > 0 || pendingApprovalCount > 0 {
            recommendedAction = "terminate_session_for_automatic_cleanup"
        } else {
            recommendedAction = "safe_to_terminate"
        }

        return MCPClientCleanupStatusDTO(
            isClean: reasonCodes.isEmpty,
            state: reasonCodes.isEmpty ? "clean" : "cleanup_required",
            reasonCodes: reasonCodes,
            recommendedAction: recommendedAction,
            activeEffectCount: activeEffectCount,
            cleanupConflictCount: cleanupConflictCount,
            activeOperationCount: activeOperationCount,
            pendingApprovalCount: pendingApprovalCount,
            activeScenarioCount: activeScenarioCount,
            activeFixtureRunCount: activeFixtureRunCount,
            policyRevision: policyRevision,
            recentApprovalOutcomes: approvalStore.recentStatuses(clientID: clientID)
        )
    }

    func disableMCPCreatedEffects() async -> MCPRecoverySummary {
        var summary = MCPRecoverySummary.empty(action: .disableEffects)
        let inventory = await buildInventory()
        for item in inventory where item.mcpOrigin == .mcp && item.isEnabled && item.kind != .openAPIMockPack {
            do {
                try await restorer.disable(item: item)
                summary.disabledCount += 1
            } catch {
                summary.conflicts.append(
                    MCPEffectConflictItem(
                        id: item.id,
                        kind: item.kind,
                        message: "Failed to disable MCP effect: \(item.displayLabel).",
                        targetID: item.id
                    )
                )
            }
        }
        await fixtureRunStore?.stopAllActiveRuns()
        if let coordinator = openAPIMockPackCoordinator {
            for pack in coordinator.packs where pack.isServing && pack.mcpProvenance != nil {
                _ = try? await coordinator.stop(id: pack.id, requestingOwnerID: pack.owner.ownerID)
            }
        }
        await refreshEffectSummary()
        recordRecovery(summary: summary)
        return summary
    }

    /// Cancels and reverses state owned by one MCP client before its final logical session ends.
    ///
    /// Conflicts are returned to the caller instead of silently detaching or deleting user-edited
    /// state. The transport keeps the session alive when conflicts remain so the client can inspect
    /// and resolve them before retrying termination.
    func cleanupClientState(clientID: String) async -> MCPRecoverySummary {
        var summary = MCPRecoverySummary.empty(action: .terminateSession)

        scenarioLifecycleCoordinator?.cancelScenarios(forClientID: clientID)
        if let drainScenarioCleanups {
            await drainScenarioCleanups()
        }
        if let fixtureRunStore {
            try? await fixtureRunStore.stopAll(ownedBy: clientID)
        }
        await openAPIMockPackCoordinator?.stopAll(ownedBy: clientID)
        let remainingPackCount = openAPIMockPackCoordinator?.activeCount(ownedBy: clientID) ?? 0
        if remainingPackCount > 0 {
            summary.cleanupRequired = true
            summary.conflicts.append(
                MCPEffectConflictItem(
                    id: "openapi-mock-pack-cleanup-required",
                    kind: .openAPIMockPack,
                    message: "Client-owned OpenAPI mock packs still require cleanup.",
                    targetID: nil
                )
            )
        }
        await diagnosticRunCoordinator?.markCleanupRequired(ownedBy: clientID)
        let remainingDiagnosticRunCount = diagnosticRunCoordinator?.nonterminalCount(ownedBy: clientID) ?? 0
        if remainingDiagnosticRunCount > 0 {
            summary.cleanupRequired = true
            summary.conflicts.append(
                MCPEffectConflictItem(
                    id: "diagnostic-run-cleanup-required",
                    kind: .responseOverride,
                    message: "Client-owned diagnostic runs still require cleanup.",
                    targetID: nil
                )
            )
        }
        let remainingScenarioIDs = scenarioLifecycleCoordinator?.unresolvedScenarioIDs(forClientID: clientID) ?? []
        if !remainingScenarioIDs.isEmpty {
            summary.cleanupRequired = true
            summary.conflicts.append(
                MCPEffectConflictItem(
                    id: "scenario-cleanup-required",
                    kind: .responseOverride,
                    message: "Client-owned test scenarios still require cleanup.",
                    targetID: nil
                )
            )
        }
        let remainingFixtureCount = fixtureRunStore?.unresolvedRunIDs(forClientID: clientID).count ?? 0
        if remainingFixtureCount > 0 {
            summary.cleanupRequired = true
            summary.conflicts.append(
                MCPEffectConflictItem(
                    id: "fixture-cleanup-required",
                    kind: .hlsFixtureRun,
                    message: "Client-owned HLS fixture runs still require cleanup.",
                    targetID: nil
                )
            )
        }

        let pendingBefore = approvalStore.pendingRequests.filter { $0.clientID == clientID }.count
        approvalStore.prunePending(for: clientID)
        proposalCoordinator.invalidate(clientID: clientID)
        grantStore?.clearUntilSessionEndGrants(clientID: clientID)
        summary.approvalsCancelled = pendingBefore

        let inventory = await buildInventory()
        for item in inventory where item.mcpOrigin == .mcp && item.clientID == clientID && item.kind != .openAPIMockPack {
            guard let journalEntry = MCPEffectInventoryBuilder.latestCommittedEntry(
                for: item.id,
                in: journalStore.entries
            ), journalEntry.rollbackSnapshot != nil else {
                if item.isEnabled {
                    do {
                        try await restorer.disable(item: item)
                        summary.disabledCount += 1
                    } catch {
                        appendDisableConflict(item: item, summary: &summary)
                    }
                }
                continue
            }

            do {
                try await restorer.restore(item: item, journalEntry: journalEntry)
                summary.restoredCount += 1
            } catch MCPRecoveryRestorerError.revisionMismatch {
                try? recoveryCoordinator.markConflict(
                    transactionID: journalEntry.transactionID,
                    message: "Target edited after MCP mutation; prior state not restored."
                )
                summary.conflicts.append(
                    MCPEffectConflictItem(
                        id: journalEntry.transactionID,
                        kind: item.kind,
                        message: "Target edited after MCP mutation; left disabled for safety.",
                        targetID: item.id
                    )
                )
                if item.isEnabled {
                    do {
                        try await restorer.disable(item: item)
                        summary.disabledCount += 1
                    } catch {
                        appendDisableConflict(item: item, summary: &summary)
                    }
                }
            } catch {
                if item.isEnabled {
                    do {
                        try await restorer.disable(item: item)
                        summary.disabledCount += 1
                    } catch {
                        appendDisableConflict(item: item, summary: &summary)
                    }
                }
            }
        }

        await refreshEffectSummary()
        summary.cleanupRequired = summary.cleanupRequired || !summary.conflicts.isEmpty
        recordRecovery(summary: summary, clientID: clientID)
        return summary
    }

    /// First half of the launch-time fresh-state reset: cancels/drains scenarios, clears pending
    /// approvals and proposals, and clears only session-scoped grants — never touches clients,
    /// bearer tokens, or durable/persistent grants. Unconditionally clears the entire effect
    /// journal (unlike ``returnToNormal``, which never aborts on remaining state here since there
    /// is no live client session to protect at launch), so no stale `.intent`/`.conflict` entry can
    /// resurface the recovery banner in a new session, and so the guarded
    /// `removeEntries(forTargetID:)` inside the destructive delete pass that follows (driven by the
    /// caller via ``MCPDestructiveRecoveryService/deleteAllMCPOriginObjects()``) never has anything
    /// left to trip on. Split out of `MCPServerController.enforceFreshLaunchMCPState()` because the
    /// destructive delete pass itself lives on `MCPDestructiveRecoveryService`, which depends on
    /// this type (not the reverse) — the controller, which holds both, orchestrates the full
    /// sequence and refreshes effect state afterward.
    func prepareForFreshLaunchTeardown() async {
        scenarioLifecycleCoordinator?.cancelAllScenarios()
        if let drainScenarioCleanups {
            await drainScenarioCleanups()
        }

        approvalStore.clearAllForRecovery()
        proposalCoordinator.invalidateAll()
        grantStore?.clearTemporaryGrants()
        journalStore.clearAllForFreshLaunch()
    }

    func returnToNormal(
        stopServer: @escaping () async -> Void,
        isServerRunning: @escaping () -> Bool
    ) async -> MCPRecoverySummary {
        var summary = MCPRecoverySummary.empty(action: .returnToNormal)

        // Actively drive scenario cleanup rather than only detecting and reporting the conflict —
        // every non-terminal scenario is forced into `cleaningUp` here (AI-1/AI-2).
        scenarioLifecycleCoordinator?.cancelAllScenarios()
        if let drainScenarioCleanups {
            await drainScenarioCleanups()
        }

        if !(scenarioLifecycleCoordinator?.activeScenarioIDs.isEmpty ?? true) {
            summary.cleanupRequired = true
            summary.conflicts.append(
                MCPEffectConflictItem(
                    id: "scenario-cleanup-required",
                    kind: .responseOverride,
                    message: "Active test scenarios require cleanup before Return To Normal can succeed.",
                    targetID: nil
                )
            )
            recordRecovery(summary: summary)
            return summary
        }

        let pendingBefore = approvalStore.pendingCount
        approvalStore.clearAllForRecovery()
        proposalCoordinator.invalidateAll()
        grantStore?.clearTemporaryGrants()
        summary.approvalsCancelled = pendingBefore

        if let coordinator = openAPIMockPackCoordinator {
            for pack in coordinator.packs where pack.isServing && pack.mcpProvenance != nil {
                _ = try? await coordinator.stop(id: pack.id, requestingOwnerID: pack.owner.ownerID)
            }
        }
        await diagnosticRunCoordinator?.markAllNonterminalCleanupRequired()

        let inventory = await buildInventory()
        for item in inventory where item.mcpOrigin == .mcp && item.kind != .openAPIMockPack {
            guard let journalEntry = MCPEffectInventoryBuilder.latestCommittedEntry(
                for: item.id,
                in: journalStore.entries
            ), journalEntry.rollbackSnapshot != nil else {
                if item.isEnabled {
                    do {
                        try await restorer.disable(item: item)
                        summary.disabledCount += 1
                    } catch {
                        appendDisableConflict(item: item, summary: &summary)
                    }
                }
                continue
            }

            do {
                try await restorer.restore(item: item, journalEntry: journalEntry)
                summary.restoredCount += 1
            } catch MCPRecoveryRestorerError.revisionMismatch {
                try? recoveryCoordinator.markConflict(
                    transactionID: journalEntry.transactionID,
                    message: "Target edited after MCP mutation; prior state not restored."
                )
                summary.conflicts.append(
                    MCPEffectConflictItem(
                        id: journalEntry.transactionID,
                        kind: item.kind,
                        message: "Target edited after MCP mutation; left unchanged.",
                        targetID: item.id
                    )
                )
                if item.isEnabled {
                    do {
                        try await restorer.disable(item: item)
                        summary.disabledCount += 1
                    } catch {
                        appendDisableConflict(item: item, summary: &summary)
                    }
                }
            } catch {
                if item.isEnabled {
                    do {
                        try await restorer.disable(item: item)
                        summary.disabledCount += 1
                    } catch {
                        appendDisableConflict(item: item, summary: &summary)
                    }
                }
            }
        }

        await refreshEffectSummary()
        if case .conflict(let items) = recoveryCoordinator.effectState {
            for item in items where !summary.conflicts.contains(where: { $0.id == item.id }) {
                summary.conflicts.append(item)
            }
        }
        if isServerRunning() {
            await stopServer()
            summary.serverStopped = true
        }
        recordRecovery(summary: summary)
        return summary
    }

    func detachEffect(itemID: String) async throws {
        if itemID == "throttle" {
            var configuration = throttleConfigurationReader()
            configuration.mcpOrigin = .user
            throttleConfigurationWriter(
                MCPTargetRevisionFingerprint.throttleByApplyingRevision(configuration)
            )
            await refreshEffectSummary()
            return
        }

        if itemID.contains(":") {
            let parts = itemID.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let bookmarkID = UUID(uuidString: parts[0]) else {
                throw MCPStructuredError(code: .malformedRequest, message: "Invalid bookmark rewrite item ID.")
            }
            var bookmarks = bookmarkStore.loadBookmarks()
            guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
                throw MCPStructuredError(code: .conflict, message: "Bookmark not found.")
            }
            bookmarks[index].mcpOrigin = .user
            let updated = MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(bookmarks[index])
            bookmarks[index] = updated
            try MCPBookmarkStoreSupport.saveBookmarks(
                bookmarks,
                to: bookmarkStore,
                applyingRevisionToUpdated: updated,
                provenance: updated.mcpProvenance,
                origin: .user
            )
            await refreshEffectSummary()
            return
        }

        if let overrideID = UUID(uuidString: itemID) {
            let rules = await responseOverrideStore.rules()
            guard var rule = rules.first(where: { $0.id == overrideID }) else {
                throw MCPStructuredError(code: .conflict, message: "Override not found.")
            }
            rule.mcpOrigin = .user
            try await responseOverrideStore.addRule(rule)
            await refreshEffectSummary()
            return
        }

        if let bookmarkID = UUID(uuidString: itemID) {
            var bookmarks = bookmarkStore.loadBookmarks()
            guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
                throw MCPStructuredError(code: .conflict, message: "Bookmark not found.")
            }
            bookmarks[index].mcpOrigin = .user
            let updated = MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(bookmarks[index])
            bookmarks[index] = updated
            try MCPBookmarkStoreSupport.saveBookmarks(
                bookmarks,
                to: bookmarkStore,
                applyingRevisionToUpdated: updated,
                provenance: updated.mcpProvenance,
                origin: .user
            )
            await refreshEffectSummary()
            return
        }

        throw MCPStructuredError(code: .malformedRequest, message: "Unknown effect item ID.")
    }

    func restoreEffect(itemID: String) async throws {
        let inventory = await buildInventory()
        guard let item = inventory.first(where: { $0.id == itemID }) else {
            throw MCPStructuredError(code: .conflict, message: "Effect item not found.")
        }
        guard let journalEntry = MCPEffectInventoryBuilder.latestCommittedEntry(
            for: item.id,
            in: journalStore.entries
        ),
              journalEntry.rollbackSnapshot != nil else {
            throw MCPStructuredError(code: .conflict, message: "No rollback snapshot available for this item.")
        }
        do {
            try await restorer.restore(item: item, journalEntry: journalEntry)
            if journalStore.entry(transactionID: journalEntry.transactionID)?.phase == .conflict {
                try recoveryCoordinator.resolveConflict(
                    transactionID: journalEntry.transactionID,
                    resolution: .retryRestore
                )
            }
            await refreshEffectSummary()
        } catch MCPRecoveryRestorerError.revisionMismatch {
            try recoveryCoordinator.markConflict(
                transactionID: journalEntry.transactionID,
                message: "Target edited after MCP mutation; prior state not restored."
            )
            throw MCPStructuredError(code: .conflict, message: "Target edited after MCP mutation.")
        }
    }

    func resolveConflict(
        transactionID: String,
        resolution: MCPRecoveryConflictResolution
    ) async throws {
        switch resolution {
        case .accept:
            try recoveryCoordinator.resolveConflict(transactionID: transactionID, resolution: .accept)
        case .retryRestore:
            guard let entry = journalStore.entry(transactionID: transactionID) else {
                throw MCPStructuredError(code: .conflict, message: "Conflict entry not found.")
            }
            let targetID = entry.targetID
            try await restoreEffect(itemID: targetID)
            try recoveryCoordinator.resolveConflict(transactionID: transactionID, resolution: .retryRestore)
        }
        await refreshEffectSummary()
    }

    private func refreshEffectSummary() async {
        let rules = await responseOverrideStore.rules()
        let bookmarks = bookmarkStore.loadBookmarks()
        let throttle = throttleConfigurationReader()
        recoveryCoordinator.refreshEffectSummary(
            rules: rules,
            bookmarks: bookmarks,
            throttleConfiguration: throttle,
            activeScenarioIDs: scenarioLifecycleCoordinator?.activeScenarioIDs ?? []
        )
    }

    /// Exposed for destructive recovery to refresh inventory after deletes.
    func refreshEffectSummaryPublic() async {
        await refreshEffectSummary()
    }

    private func appendDisableConflict(item: MCPEffectInventoryItem, summary: inout MCPRecoverySummary) {
        summary.conflicts.append(
            MCPEffectConflictItem(
                id: item.id,
                kind: item.kind,
                message: "Failed to disable MCP effect: \(item.displayLabel).",
                targetID: item.id
            )
        )
    }

    private func recordRecovery(summary: MCPRecoverySummary, clientID: String? = nil) {
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .returnToNormal,
                timestamp: Date(),
                clientID: clientID,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: summary.action.rawValue,
                detail: "disabled=\(summary.disabledCount) restored=\(summary.restoredCount) conflicts=\(summary.conflicts.count)"
            )
        )
    }
}
