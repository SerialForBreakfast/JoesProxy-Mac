import os

/// Shared unified-logging (`os.Logger`) subsystem for the entire MCP server, so all MCP activity
/// can be filtered together in Console.app / `log stream` regardless of which internal component
/// emitted it: `log stream --predicate 'subsystem == "com.JoesProxyApp.MCP"'`.
///
/// Never log secrets here: bearer tokens, verifier hashes, and raw captured request/response
/// bodies must not appear in any message, even at `.debug` level. Log identifiers (client IDs,
/// session IDs, method names, error/reason codes) freely — they're already opaque or non-sensitive.
enum MCPLog {
    private static let subsystem = "com.JoesProxyApp.MCP"

    /// Process start/stop, bind failures, degraded-state transitions.
    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    /// Connection accept/reject, idle timeouts, per-request timeout fallback.
    static let transport = Logger(subsystem: subsystem, category: "Transport")
    /// JSON-RPC method dispatch, session lifecycle, malformed/rejected requests.
    static let protocolLog = Logger(subsystem: subsystem, category: "Protocol")
    /// Authentication and rate-limiting outcomes.
    static let auth = Logger(subsystem: subsystem, category: "Auth")
    /// Client enrollment, rotation, and revocation.
    static let clients = Logger(subsystem: subsystem, category: "Clients")
    /// Policy resolution and disclosure-serialization outcomes.
    static let disclosure = Logger(subsystem: subsystem, category: "Disclosure")
    /// Approval request, resolution, retry-consumption, expiry, and invalidation outcomes.
    static let approvals = Logger(subsystem: subsystem, category: "Approvals")
    /// Capture-only media classification, correlation, and parser outcomes.
    static let media = Logger(subsystem: subsystem, category: "Media")
}
