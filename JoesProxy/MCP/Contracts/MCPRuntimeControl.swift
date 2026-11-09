import Foundation

enum MCPRuntimeControlAction: String, Equatable, Sendable {
    case startProxy = "proxy_start"
    case resumeCapture = "capture_resume"
    case stopProxy = "proxy_stop"
    case stopMCP = "mcp_stop"

    init?(toolName: String) {
        self.init(rawValue: toolName)
    }
}

/// Prevents remote runtime control from activating the Mac-wide system proxy as a side effect.
/// System-proxy routing is a local, human-operated control even when runtime control is granted.
enum MCPRuntimeControlSafetyPolicy {
    static func validateRemoteAction(
        _ action: MCPRuntimeControlAction,
        systemProxyManagementEnabled: Bool
    ) throws {
        guard action == .startProxy || action == .resumeCapture, systemProxyManagementEnabled else { return }
        throw MCPStructuredError(
            code: .policyDenied,
            message: "Mac traffic routing is armed. Start the proxy manually in JoesProxy, or manually turn Mac routing off before using MCP or CLI runtime control."
        )
    }
}
