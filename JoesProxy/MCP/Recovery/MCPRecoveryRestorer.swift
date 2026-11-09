import Foundation

enum MCPRecoveryRestorerError: Error, Equatable, Sendable {
    case revisionMismatch
    case missingRollbackSnapshot
    case unsupportedTarget
    case storeWriteFailed(String)
}

/// Applies revision-safe rollback snapshots and disable paths for MCP-owned effects.
///
/// Concurrency: `@MainActor` — mutates app-owned stores wired from ``AppCoordinator``.
@MainActor
struct MCPRecoveryRestorer {
    let responseOverrideStore: ResponseOverrideStore
    let bookmarkStore: any BookmarkStore
    let throttleConfigurationWriter: (NetworkThrottleConfiguration) -> Void

    /// Attempts to restore a target from its latest committed journal entry.
    /// Returns `.revisionMismatch` when the user edited the target after the MCP mutation.
    func restore(
        item: MCPEffectInventoryItem,
        journalEntry: MCPEffectJournalEntry
    ) async throws {
        guard let snapshotData = journalEntry.rollbackSnapshot else {
            throw MCPRecoveryRestorerError.missingRollbackSnapshot
        }

        switch item.kind {
        case .block, .mapLocal, .mapRemote, .responseOverride, .liveResponseRewrite, .collectionMock:
            guard let overrideID = UUID(uuidString: item.id) else {
                throw MCPRecoveryRestorerError.unsupportedTarget
            }
            let rules = await responseOverrideStore.rules()
            if let rule = rules.first(where: { $0.id == overrideID }) {
                guard revisionsMatch(current: rule.mcpTargetRevision, baseline: journalEntry.baselineRevision) else {
                    throw MCPRecoveryRestorerError.revisionMismatch
                }
                // Prefer enable/disable snapshot; fall back to full delete restore only when decode fails.
                if let snapshot = try? MCPRollbackSnapshotReader.decodeRuleRollback(from: snapshotData) {
                    try await responseOverrideStore.setEnabled(snapshot.isEnabled, for: overrideID)
                } else {
                    throw MCPRecoveryRestorerError.unsupportedTarget
                }
            } else {
                let deleted = try MCPRollbackSnapshotReader.decodeDeletedRuleRollback(from: snapshotData)
                try await responseOverrideStore.restoreFromMCPDeleteRollbackData(deleted.persistedRuleJSON)
            }

        case .bookmarkRewrite:
            let parts = item.id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let bookmarkID = UUID(uuidString: parts[0]),
                  let rewriteID = UUID(uuidString: parts[1]) else {
                throw MCPRecoveryRestorerError.unsupportedTarget
            }
            guard let bookmark = bookmarkStore.loadBookmarks().first(where: { $0.id == bookmarkID }) else {
                throw MCPRecoveryRestorerError.unsupportedTarget
            }
            guard revisionsMatch(current: bookmark.mcpTargetRevision, baseline: journalEntry.baselineRevision) else {
                throw MCPRecoveryRestorerError.revisionMismatch
            }
            let snapshot = try MCPRollbackSnapshotReader.decodeBookmarkRewriteRollback(from: snapshotData)
            try MCPBookmarkRewritePersistence.setRewriteEnabled(
                bookmarkID: bookmarkID,
                rewriteID: rewriteID,
                isEnabled: snapshot.isRuleEnabled,
                bookmarkStore: bookmarkStore
            )

        case .throttle:
            let current = MCPTargetRevisionFingerprint.throttleByApplyingRevision(
                throttleConfigurationReader()
            )
            guard revisionsMatch(current: current.mcpTargetRevision, baseline: journalEntry.baselineRevision) else {
                throw MCPRecoveryRestorerError.revisionMismatch
            }
            let snapshot = try MCPRollbackSnapshotReader.decodeThrottleRollback(from: snapshotData)
            throttleConfigurationWriter(
                MCPTargetRevisionFingerprint.throttleByApplyingRevision(snapshot.configuration)
            )

        case .responseDraft, .hlsFixtureRun, .certificateTrustCleanup, .openAPIMockPack, .diagnosticRun, .effectBundle:
            throw MCPRecoveryRestorerError.unsupportedTarget
        }
    }

    /// Disables a live MCP-origin effect without deleting persisted objects.
    func disable(item: MCPEffectInventoryItem) async throws {
        switch item.kind {
        case .block, .mapLocal, .mapRemote, .responseOverride, .liveResponseRewrite, .collectionMock:
            guard let overrideID = UUID(uuidString: item.id) else {
                throw MCPRecoveryRestorerError.unsupportedTarget
            }
            try await responseOverrideStore.setEnabled(false, for: overrideID)

        case .bookmarkRewrite:
            let parts = item.id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let bookmarkID = UUID(uuidString: parts[0]),
                  let rewriteID = UUID(uuidString: parts[1]) else {
                throw MCPRecoveryRestorerError.unsupportedTarget
            }
            try MCPBookmarkRewritePersistence.setRewriteEnabled(
                bookmarkID: bookmarkID,
                rewriteID: rewriteID,
                isEnabled: false,
                bookmarkStore: bookmarkStore
            )

        case .throttle:
            var configuration = throttleConfigurationReader()
            configuration.isEnabled = false
            throttleConfigurationWriter(
                MCPTargetRevisionFingerprint.throttleByApplyingRevision(configuration)
            )

        case .responseDraft, .hlsFixtureRun, .certificateTrustCleanup, .openAPIMockPack, .diagnosticRun, .effectBundle:
            throw MCPRecoveryRestorerError.unsupportedTarget
        }
    }

    /// Returns the current throttle configuration for interlock suspend snapshots.
    func currentThrottleConfiguration() -> NetworkThrottleConfiguration {
        throttleConfigurationReader()
    }

    /// Re-enables an effect suspended for diagnostic interlock measurement.
    func restoreSuspended(snapshot: MCPSuspendedEffectSnapshot) async throws {
        switch snapshot.item.kind {
        case .block, .mapLocal, .mapRemote, .responseOverride, .liveResponseRewrite, .collectionMock:
            guard let overrideID = UUID(uuidString: snapshot.item.id) else {
                throw MCPRecoveryRestorerError.unsupportedTarget
            }
            let rules = await responseOverrideStore.rules()
            guard rules.contains(where: { $0.id == overrideID }) else {
                throw MCPRecoveryRestorerError.unsupportedTarget
            }
            try await responseOverrideStore.setEnabled(true, for: overrideID)

        case .bookmarkRewrite:
            let parts = snapshot.item.id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let bookmarkID = UUID(uuidString: parts[0]),
                  let rewriteID = UUID(uuidString: parts[1]) else {
                throw MCPRecoveryRestorerError.unsupportedTarget
            }
            try MCPBookmarkRewritePersistence.setRewriteEnabled(
                bookmarkID: bookmarkID,
                rewriteID: rewriteID,
                isEnabled: true,
                bookmarkStore: bookmarkStore
            )

        case .throttle:
            guard let saved = snapshot.throttleConfiguration else {
                throw MCPRecoveryRestorerError.missingRollbackSnapshot
            }
            // Interlock snapshots are taken immediately before `disable`, which itself bumps
            // `mcpTargetRevision` — a revision equality check would always fail here.
            throttleConfigurationWriter(MCPTargetRevisionFingerprint.throttleByApplyingRevision(saved))

        case .responseDraft, .hlsFixtureRun, .certificateTrustCleanup, .openAPIMockPack, .diagnosticRun, .effectBundle:
            throw MCPRecoveryRestorerError.unsupportedTarget
        }
    }

    /// Permanently removes an MCP-origin effect from persistence (AH-7 destructive delete).
    func delete(item: MCPEffectInventoryItem) async throws {
        if item.isEnabled {
            try await disable(item: item)
        }

        switch item.kind {
        case .block, .mapLocal, .mapRemote, .responseOverride, .liveResponseRewrite, .collectionMock:
            guard let overrideID = UUID(uuidString: item.id) else {
                throw MCPRecoveryRestorerError.unsupportedTarget
            }
            await responseOverrideStore.removeRule(id: overrideID)

        case .bookmarkRewrite:
            let parts = item.id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let bookmarkID = UUID(uuidString: parts[0]),
                  let rewriteID = UUID(uuidString: parts[1]) else {
                throw MCPRecoveryRestorerError.unsupportedTarget
            }
            var bookmarks = bookmarkStore.loadBookmarks()
            guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
                throw MCPRecoveryRestorerError.unsupportedTarget
            }
            bookmarks[index].responseRewrites.removeAll { $0.id == rewriteID }
            try bookmarkStore.saveBookmarks(bookmarks)

        case .throttle:
            var configuration = throttleConfigurationReader()
            configuration.isEnabled = false
            configuration.mcpOrigin = nil
            configuration.mcpProvenance = nil
            throttleConfigurationWriter(
                MCPTargetRevisionFingerprint.throttleByApplyingRevision(configuration)
            )

        case .responseDraft, .hlsFixtureRun, .certificateTrustCleanup, .openAPIMockPack, .diagnosticRun, .effectBundle:
            throw MCPRecoveryRestorerError.unsupportedTarget
        }
    }

    /// Deletes an MCP-created bookmark when the inventory row represents the whole bookmark.
    func deleteBookmark(bookmarkID: UUID) throws {
        var bookmarks = bookmarkStore.loadBookmarks()
        bookmarks.removeAll { $0.id == bookmarkID }
        try bookmarkStore.saveBookmarks(bookmarks)
    }

    private let throttleConfigurationReader: () -> NetworkThrottleConfiguration

    init(
        responseOverrideStore: ResponseOverrideStore,
        bookmarkStore: any BookmarkStore,
        throttleConfigurationReader: @escaping () -> NetworkThrottleConfiguration,
        throttleConfigurationWriter: @escaping (NetworkThrottleConfiguration) -> Void
    ) {
        self.responseOverrideStore = responseOverrideStore
        self.bookmarkStore = bookmarkStore
        self.throttleConfigurationReader = throttleConfigurationReader
        self.throttleConfigurationWriter = throttleConfigurationWriter
    }

    private func revisionsMatch(current: MCPTargetRevision?, baseline: MCPTargetRevision?) -> Bool {
        current == baseline
    }
}
