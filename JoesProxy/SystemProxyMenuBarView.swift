import AppKit
import SwiftUI

/// Menu bar icon whose symbol reflects the live routing state:
/// off → `network.slash`, armed → `network`, active → shielded network, problem → warning triangle.
struct SystemProxyMenuBarLabel: View {
    @ObservedObject var systemProxyController: SystemProxyController
    @ObservedObject var routingModel: SystemProxyRoutingModel

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel("JoesProxy macOS routing status")
    }

    private var symbolName: String {
        if systemProxyController.pendingRecovery != nil {
            return "exclamationmark.triangle.fill"
        }
        switch systemProxyController.status {
        case .failed:
            return "exclamationmark.triangle.fill"
        case .active:
            return "network.badge.shield.half.filled"
        case .inactive:
            return routingModel.isRoutingEnabled ? "network" : "network.slash"
        }
    }
}

/// Menu bar dropdown: status line, consent-gated routing toggle, proxy start/stop,
/// crash-recovery restore, compact mode, pending MCP approvals, and a shortcut to the main window.
struct SystemProxyMenuBarView: View {
    @ObservedObject var viewModel: ProxyViewModel
    @ObservedObject var systemProxyController: SystemProxyController
    @ObservedObject var routingModel: SystemProxyRoutingModel
    @ObservedObject var compactModeController: CompactModeController
    @ObservedObject var mcpServerController: MCPServerController
    @ObservedObject var presentationState: AppPresentationState

    var body: some View {
        Text(statusLine)

        Divider()

        Toggle("Route macOS Traffic Through JoesProxy", isOn: routingBinding)

        Button(viewModel.isProxyRunningNow ? "Stop Proxy" : "Start Proxy") {
            if viewModel.isProxyRunningNow {
                viewModel.stopProxy()
            } else {
                viewModel.startProxy()
            }
        }
        .disabled(!viewModel.isProxyRunningNow && !viewModel.canStartProxy)

        if systemProxyController.pendingRecovery != nil {
            Button("Restore Previous Proxy Settings…") {
                Task { await systemProxyController.confirmRecovery() }
            }
        }

        Divider()

        Button(compactModeController.isCompactModeActive ? "Exit Compact Mode" : "Enter Compact Mode") {
            compactModeController.toggle()
        }

        let pendingCount = mcpServerController.approvalStore.pendingCount
        if pendingCount > 0 {
            Button("Approve Pending (\(pendingCount.formatted()))…") {
                Self.activateMainWindow()
                presentationState.presentCompactApprovals()
            }
            .accessibilityIdentifier("menuBarApprovePending")
        }

        Divider()

        Button("Open JoesProxy") {
            Self.activateMainWindow()
        }
    }

    private var statusLine: String {
        if systemProxyController.pendingRecovery != nil {
            return "Previous proxy settings need restoring"
        }
        switch systemProxyController.status {
        case .active(let host, let port, _):
            return "Routing active — \(host):\(port)"
        case .failed:
            return "Routing failed — see main window"
        case .inactive:
            if routingModel.isRoutingEnabled {
                return viewModel.isProxyRunningNow
                    ? "Routing activating…"
                    : "Routing armed — starts with proxy"
            }
            return "macOS routing off"
        }
    }

    /// Toggle that defers the first enable to the consent alert (presented in the main window).
    private var routingBinding: Binding<Bool> {
        Binding(
            get: { routingModel.isRoutingEnabled },
            set: { newValue in
                routingModel.isRoutingEnabled = newValue
                if routingModel.pendingConsent {
                    // Consent alert is attached to the main window — bring it forward.
                    Self.activateMainWindow()
                }
            }
        )
    }

    /// Brings JoesProxy forward and restores a normal Dock presence when running as accessory.
    static func activateMainWindow() {
        MainWindowActivation.activateMainWindow()
    }
}
