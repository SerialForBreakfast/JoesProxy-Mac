import Foundation

struct MCPManagedRuntimeHostStatusDTO: Equatable, Sendable, Codable {
    var appState: String
    var cliAutomationStartEnabled: Bool
    var proxyState: String
    var proxyPort: Int?
    /// Mirrors the user's persisted "Automatically set macOS system proxy while capturing"
    /// preference (`AppConfiguration.isSystemProxyManagementEnabled`) — `true` means this setting
    /// was left on from a *previous* session and will silently re-engage the next time the proxy
    /// starts, routing every app on the machine's HTTP(S) traffic through JoesProxy, not just
    /// traffic this MCP client generates. Root-caused from a live session where `proxy_start`
    /// captured ~3,200 ambient sessions with no explanation (see
    /// `memlog/Research/MCPAndCLIUserExperienceValidation.md`). Defaults to `false`.
    var systemProxyManagementEnabled: Bool = false
}

struct MCPRuntimeReadinessCheckDTO: Equatable, Sendable, Codable {
    var id: String
    var state: String
    var detail: String
    var recommendedAction: String?
}

struct MCPRuntimeReadinessDTO: Equatable, Sendable, Codable {
    var readyForUnattendedControl: Bool
    var state: String
    var clientID: String
    var profileID: MCPDisclosureProfileID
    var runtimeControlGrantMode: MCPClientGrantMode?
    var runtimeControlGrantExpiresAt: Date?
    var host: MCPManagedRuntimeHostStatusDTO
    var cleanup: MCPClientCleanupStatusDTO
    var checks: [MCPRuntimeReadinessCheckDTO]
    var recommendedNextCommands: [String]
    var capabilitiesBundleVersion: String
    var runtimeIdentity: MCPRuntimeIdentityDTO
    var compatibility: MCPRuntimeCompatibilityDTO
    var policyRevision: MCPPolicyRevision
    /// Active standing grants for this client (capability raw values), for agent discoverability.
    var activeStandingGrants: [String]?
}
