import Foundation

/// Server-side limits enforced by the production MCP controller (ADR Phase 1 initial constants).
enum MCPServerLimits {
    static let concurrentConnections = 8
    static let concurrentInFlightRequestsPerClient = 4
    static let requestRatePerClientPerMinute = 60
    static let globalRequestRatePerMinute = 240
    /// Authenticated lifecycle/readiness/approval-status traffic has a separate bounded budget so
    /// an interactive approval wait cannot consume the caller's substantive tool-call allowance.
    static let controlPlaneRequestRatePerClientPerMinute = 600
    static let controlPlaneGlobalRequestRatePerMinute = 2_400
    static let activeMCPSessionsPerClient = 4
    static let activeMCPSessions = 32
    static let sessionIdleExpiry: TimeInterval = 30 * 60
    static let sessionTerminationRetention: TimeInterval = 10 * 60
    static let maxRetainedSessionTerminations = 128
    static let perRequestTimeout: TimeInterval = 60
    static let maxJSONDepth = 32
    static let gracefulStopDeadline: TimeInterval = 5
    /// Caps `MCPBoundSession.cancelledRequestIDs` so a client spamming `notifications/cancelled`
    /// with ids it never actually used can't grow the set unboundedly for the life of the session.
    static let maxTrackedCancelledRequestIDsPerSession = 128
    /// Per logical MCP session notification backlog before coalescing and priority drops apply.
    static let maxNotificationQueueEvents = 256
    /// Minimum progress delta before another operation progress notification is emitted.
    static let operationNotificationProgressDelta = 0.05
    /// SSE comment heartbeat interval; must stay below ``MCPNIOHTTPTransport`` idle timeout.
    static let sseHeartbeatInterval: TimeInterval = 15
    /// Concurrent short-lived POST/request connections.
    static let concurrentRequestConnections = 8
    /// Concurrent long-lived GET listen/SSE streams.
    static let maxConcurrentListenStreams = 4
}

/// Transport session binding for authenticated MCP clients.
struct MCPBoundSession: Equatable, Sendable {
    var sessionID: String
    var clientID: String
    var credentialGeneration: Int
    var protocolVersion: String
    var policyRevision: MCPPolicyRevision
    var initialized: Bool
    var restricted: Bool
    var lastActivityAt: Date
    /// Explicit client negotiation. False preserves legacy text fallback byte-for-byte.
    var structuredResultsOnly: Bool = false
    /// JSON-serialized request IDs cancelled via `notifications/cancelled` for this session.
    var cancelledRequestIDs: Set<String> = []
}

/// Bounded owner-only diagnostic retained after a logical MCP session is removed.
struct MCPSessionTerminationRecord: Equatable, Sendable {
    var clientID: String
    var state: String
    var terminatedAt: Date
    var expiresAt: Date
}
