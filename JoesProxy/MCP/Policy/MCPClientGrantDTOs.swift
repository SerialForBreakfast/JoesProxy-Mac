import Foundation

/// How long an in-app approval grant remains effective for a client capability.
enum MCPClientGrantMode: String, Equatable, Sendable, Codable {
    /// Cleared when the client's last active MCP session is removed (idle-expiry, eviction, restriction prune).
    case untilSessionEnd
    /// Cleared at `expiresAt`, bounded by ``MCPClientGrantStore/maxGrantDuration``.
    case untilDate
    /// Survives Return To Normal; cleared only by explicit revoke or reset.
    case durablePolicy
}

/// Persisted capability grant minted from the management panel approval flow.
struct MCPClientCapabilityGrant: Equatable, Sendable, Codable, Identifiable {
    var id: UUID
    var clientID: String
    var capability: MCPCapabilityID
    var mode: MCPClientGrantMode
    var expiresAt: Date?
    var createdAt: Date
    var grantedByRequestID: String?
}

/// Persistent always-deny entry for a client capability.
struct MCPClientCapabilityDenial: Equatable, Sendable, Codable, Identifiable {
    var id: UUID
    var clientID: String
    var capability: MCPCapabilityID
    var createdAt: Date
}

/// Sanitized grant row for disclosure preview and client detail UI.
struct MCPClientCapabilityGrantSummary: Equatable, Sendable, Codable {
    var capability: MCPCapabilityID
    var mode: MCPClientGrantMode
    var expiresAt: Date?
    var label: String
}

/// User-selected outcome when resolving a pending MCP approval in the management panel.
enum MCPApprovalResolution: Equatable, Sendable {
    case allowOnce
    case untilSessionEnd
    case untilDate(Date)
    case durablePolicy
    case denyOnce
    case alwaysDeny
}
