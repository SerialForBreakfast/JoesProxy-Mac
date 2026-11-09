import Foundation

/// UI-only destructive MCP recovery orchestrator (AH-7).
///
/// Concurrency: `@MainActor` — coordinates registry, grants, audit, and effect stores from the panel.
@MainActor
final class MCPDestructiveRecoveryService {
    private let clientRegistry: MCPClientRegistry
    private let grantStore: MCPClientGrantStore
    private let auditStore: MCPAuditStore
    private let approvalStore: MCPApprovalStore
    private let proposalCoordinator: MCPProposalCoordinator
    private let recoveryService: MCPRecoveryService
    private let restorer: MCPRecoveryRestorer
    private let journalStore: MCPEffectJournalStore
    private let invalidateSessions: (String) -> Void
    private let stopServer: () async -> Void

    init(
        clientRegistry: MCPClientRegistry,
        grantStore: MCPClientGrantStore,
        auditStore: MCPAuditStore,
        approvalStore: MCPApprovalStore,
        proposalCoordinator: MCPProposalCoordinator,
        recoveryService: MCPRecoveryService,
        restorer: MCPRecoveryRestorer,
        journalStore: MCPEffectJournalStore,
        invalidateSessions: @escaping (String) -> Void,
        stopServer: @escaping () async -> Void
    ) {
        self.clientRegistry = clientRegistry
        self.grantStore = grantStore
        self.auditStore = auditStore
        self.approvalStore = approvalStore
        self.proposalCoordinator = proposalCoordinator
        self.recoveryService = recoveryService
        self.restorer = restorer
        self.journalStore = journalStore
        self.invalidateSessions = invalidateSessions
        self.stopServer = stopServer
    }

    func revokeAllClients() async throws -> MCPDestructiveRecoverySummary {
        let count = clientRegistry.clients.filter { $0.credentialState == .active }.count
        try clientRegistry.revokeAll()
        for client in clientRegistry.clients {
            grantStore.clearUntilSessionEndGrants(clientID: client.id)
            invalidateSessions(client.id)
            approvalStore.prunePending(for: client.id)
        }
        recordDestructive(.revokeAllClients, detail: "revoked=\(count)")
        return MCPDestructiveRecoverySummary(
            action: .revokeAllClients,
            revokedClientCount: count,
            deletedEffectCount: 0,
            grantsCleared: 0,
            auditErased: false,
            serverStopped: false
        )
    }

    func resetMCPConfiguration(isServerRunning: () -> Bool) async throws -> MCPDestructiveRecoverySummary {
        let revoked = clientRegistry.clients.filter { $0.credentialState == .active }.count
        try clientRegistry.revokeAll()
        let grantsBefore = grantStore.grants.count + grantStore.denials.count
        grantStore.clearAllGrantsAndDenials()
        approvalStore.clearAllForRecovery()
        proposalCoordinator.invalidateAll()
        for client in clientRegistry.clients {
            invalidateSessions(client.id)
        }
        var serverStopped = false
        if isServerRunning() {
            await stopServer()
            serverStopped = true
        }
        recordDestructive(.resetMCPConfiguration, detail: "revoked=\(revoked) grants=\(grantsBefore)")
        return MCPDestructiveRecoverySummary(
            action: .resetMCPConfiguration,
            revokedClientCount: revoked,
            deletedEffectCount: 0,
            grantsCleared: grantsBefore,
            auditErased: false,
            serverStopped: serverStopped
        )
    }

    func deleteAllMCPOriginObjects() async throws -> MCPDestructiveRecoverySummary {
        var deleted = 0
        let inventory = await recoveryService.buildInventory()
        for item in inventory where item.mcpOrigin == .mcp {
            try await deleteEffect(itemID: item.id)
            deleted += 1
        }
        recordDestructive(.deleteMCPOriginObjects, detail: "deleted=\(deleted)")
        return MCPDestructiveRecoverySummary(
            action: .deleteMCPOriginObjects,
            revokedClientCount: 0,
            deletedEffectCount: deleted,
            grantsCleared: 0,
            auditErased: false,
            serverStopped: false
        )
    }

    func deleteEffect(itemID: String) async throws {
        let inventory = await recoveryService.buildInventory()
        guard let item = inventory.first(where: { $0.id == itemID }) else {
            throw MCPStructuredError(code: .conflict, message: "Effect item not found.")
        }
        guard item.mcpOrigin == .mcp else {
            throw MCPStructuredError(code: .conflict, message: "Only MCP-origin effects can be deleted.")
        }

        if item.kind == .responseOverride,
           !item.id.contains(":"),
           let bookmarkID = UUID(uuidString: item.id) {
            try restorer.deleteBookmark(bookmarkID: bookmarkID)
        } else {
            try await restorer.delete(item: item)
        }

        try journalStore.removeEntries(forTargetID: item.id)
        await recoveryService.refreshEffectSummaryPublic()
        recordDestructive(.deleteEffect, detail: item.id)
    }

    func eraseAuditHistory() async -> MCPDestructiveRecoverySummary {
        await auditStore.eraseHistoryRecordingDestructiveAction(detail: "User erased MCP audit history.")
        return MCPDestructiveRecoverySummary(
            action: .eraseAuditHistory,
            revokedClientCount: 0,
            deletedEffectCount: 0,
            grantsCleared: 0,
            auditErased: true,
            serverStopped: false
        )
    }

    private func recordDestructive(_ action: MCPDestructiveRecoveryAction, detail: String) {
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .destructiveAction,
                timestamp: Date(),
                clientID: nil,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: action.rawValue,
                detail: detail
            )
        )
    }
}
