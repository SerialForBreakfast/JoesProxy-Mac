import Foundation

/// Recovery action requested by the management panel or MCP tool.
enum MCPRecoveryAction: String, Equatable, Sendable, Codable {
    case returnToNormal
    case disableEffects
    case stopServerOnly
    case terminateSession
}

/// One MCP-origin proxy effect row for inventory and per-item recovery actions.
struct MCPEffectInventoryItem: Equatable, Sendable, Identifiable, Codable {
    var id: String
    var kind: MCPEffectKind
    var displayLabel: String
    var sanitizedTarget: String
    var isEnabled: Bool
    var mcpOrigin: MCPObjectOrigin
    var clientID: String?
    var canRestore: Bool
    var canDetach: Bool
}

/// Structured outcome of a recovery action for UI and MCP disclosure.
struct MCPRecoverySummary: Equatable, Sendable, Codable {
    var action: MCPRecoveryAction
    var disabledCount: Int
    var restoredCount: Int
    var skippedDetachedCount: Int
    var conflicts: [MCPEffectConflictItem]
    var serverStopped: Bool
    var approvalsCancelled: Int
    var cleanupRequired: Bool

    static func empty(action: MCPRecoveryAction) -> MCPRecoverySummary {
        MCPRecoverySummary(
            action: action,
            disabledCount: 0,
            restoredCount: 0,
            skippedDetachedCount: 0,
            conflicts: [],
            serverStopped: false,
            approvalsCancelled: 0,
            cleanupRequired: false
        )
    }
}

/// User resolution for a journaled `.conflict` entry.
enum MCPRecoveryConflictResolution: String, Equatable, Sendable {
    case accept
    case retryRestore
}

/// Destructive recovery action requested from the management panel (UI-only, AH-7).
enum MCPDestructiveRecoveryAction: String, Equatable, Sendable, Codable {
    case revokeAllClients
    case resetMCPConfiguration
    case deleteMCPOriginObjects
    case eraseAuditHistory
    case deleteEffect
}

/// Outcome of a destructive recovery action for UI disclosure.
struct MCPDestructiveRecoverySummary: Equatable, Sendable, Codable {
    var action: MCPDestructiveRecoveryAction
    var revokedClientCount: Int
    var deletedEffectCount: Int
    var grantsCleared: Int
    var auditErased: Bool
    var serverStopped: Bool
}
