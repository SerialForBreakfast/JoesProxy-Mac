import Foundation

/// Glanceable MCP title-bar status derived from server, effect, and operation state (AJ-1).
///
/// Mirrors the shape of ``CapturePipelineStatus`` — pure data with no SwiftUI dependency.
struct MCPPipelineStatus: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case idle
        case healthy
        case attention
        case problem
    }

    enum ManagementDestination: String, Equatable, Sendable {
        case overview
        case effects
        case clients
        case activity
        case approvals
        case scenarios
        case agentRuns
    }

    /// When false the title-bar pill is not rendered. Production projection keeps this true so
    /// MCP Management is always reachable from the main window title bar.
    let isVisible: Bool
    let label: String
    let detail: String?
    let systemImage: String
    let tone: Tone
    let badgeCount: Int
    /// True only for active or conflicted **effects** — not transient operations.
    let shouldPulse: Bool
    /// The management section that explains or resolves this exact status.
    let managementDestination: ManagementDestination

    static let hidden = MCPPipelineStatus(
        isVisible: false,
        label: "",
        detail: nil,
        systemImage: "antenna.radiowaves.left.and.right",
        tone: .idle,
        badgeCount: 0,
        shouldPulse: false,
        managementDestination: .overview
    )
}
