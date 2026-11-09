import SwiftUI

/// Read-only proxy/MCP run-state the compact view's Start/Stop buttons render from — a small
/// sibling to `MinimalMonitoringSnapshot`, kept separate since controls are an interaction concern
/// (enablement/labels) rather than an aggregate health stat.
///
/// Title/icon/tint are pre-computed by the caller (`AppCoordinator`, using the same
/// `MainTitleBarFormatter` logic the full toolbar's proxy button uses) rather than recomputed here
/// — that keeps this type, and `MinimalMonitoringViewModel`/`MinimalMonitoringView`, free of any
/// dependency on `ProxyRuntimeState`/`MCPServerController.ServerState` while still guaranteeing the
/// compact view's buttons look and read exactly like the full UI's.
struct MinimalMonitoringControlsState: Equatable, Sendable {
    var isProxyRunning: Bool
    var canStartProxy: Bool
    var canStopProxy: Bool
    var proxyButtonTitle: String
    var proxyButtonIcon: String
    var proxyButtonTint: Color

    var isMCPRunning: Bool
    var canStartMCP: Bool
    var canStopMCP: Bool
    var mcpButtonTitle: String
    var mcpButtonIcon: String
    var mcpButtonTint: Color
    var isProxyTransitioning = false

    static let empty = MinimalMonitoringControlsState(
        isProxyRunning: false,
        canStartProxy: false,
        canStopProxy: false,
        proxyButtonTitle: "Start",
        proxyButtonIcon: "play.fill",
        proxyButtonTint: .secondary,
        isMCPRunning: false,
        canStartMCP: false,
        canStopMCP: false,
        mcpButtonTitle: "Start",
        mcpButtonIcon: "play.fill",
        mcpButtonTint: .secondary
    )
}
