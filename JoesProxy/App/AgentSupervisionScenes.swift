import SwiftUI

/// Shared by both executable candidates so exclusion cannot remove supervision capabilities.
struct AgentSupervisionScenes: Scene {
    let coordinator: AppCoordinator
    let textScale: CGFloat

    var body: some Scene {
        Window("Agent Help", id: "agent-help") {
            AgentWorkspaceHelpView().environment(\.appTextScale, textScale)
        }.defaultSize(width: 560, height: 440)
        Window("Setup Readiness", id: "agent-setup-readiness") {
            AgentSetupReadinessView(recovery: coordinator.agentSetupRecoveryController,
                                   routing: coordinator.systemProxyRoutingModel)
                .environment(\.appTextScale, textScale)
        }.defaultSize(width: 500, height: 440)
        Window("Capture Recovery", id: "agent-capture-recovery") {
            AgentCaptureRecoveryView(persistence: coordinator.rollingCapturePersistence,
                                     recoveryController: coordinator.agentCaptureRecoveryController,
                                     sessionStore: coordinator.sessionStore)
                .environment(\.appTextScale, textScale)
        }.defaultSize(width: 440, height: 320)
        Window("Save Capture", id: "agent-save-capture") {
            AgentCaptureExportView(exportController: coordinator.agentCaptureExportController,
                                   sessionStore: coordinator.sessionStore)
                .environment(\.appTextScale, textScale)
        }.defaultSize(width: 440, height: 300)
        Window("Agent Approvals", id: "agent-approvals") {
            AgentApprovalsView(controller: coordinator.mcpServerController)
                .environment(\.appTextScale, textScale)
        }.defaultSize(width: 580, height: 440)
        Window("Agent Management", id: "agent-management") {
            MCPManagementView(controller: coordinator.mcpServerController,
                              selfValidationCoordinator: coordinator.selfValidationCoordinator,
                              textScale: textScale)
        }.defaultSize(width: 760, height: 620)
    }
}

private struct AgentApprovalsView: View {
    let controller: MCPServerController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        MCPCompactApprovalSheet(controller: controller, onDismiss: { dismiss() })
    }
}

struct AgentMonitoringView: View {
    let coordinator: AppCoordinator
    @ObservedObject var compact: CompactModeController
    @Environment(\.openWindow) private var openWindow
    @State private var stopFailure: String?

    var body: some View {
        MinimalMonitoringView(
            viewModel: compact.monitoringViewModel,
            onSizeChange: { compact.recordMeasuredContentSize($0) },
            onOpenApprovals: { openWindow(id: "agent-approvals") },
            onOpenActiveEffect: { _ in openWindow(id: "agent-management") },
            onDisableAllActiveEffect: { tileID in
                Task {
                    do { try await coordinator.agentEffectsMonitor.disableAll(in: tileID) }
                    catch { stopFailure = error.localizedDescription }
                }
            },
            onManageModifications: { openWindow(id: "agent-management") },
            captureAdmissionBudget: coordinator.sessionRecorder.admission,
            uploadSpoolService: coordinator.uploadSpoolService
        )
        .alert("Modification cleanup failed", isPresented: Binding(
            get: { stopFailure != nil }, set: { if !$0 { stopFailure = nil } }
        )) { Button("OK") { stopFailure = nil } } message: { Text(stopFailure ?? "") }
    }
}

struct AgentSupervisionCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandMenu("Agent Controls") {
            Button("Approvals…") { openWindow(id: "agent-approvals") }
            Button("Management and Effects…") { openWindow(id: "agent-management") }
            Button("Setup and Recovery…") { openWindow(id: "agent-setup-readiness") }
            Button("Capture Recovery…") { openWindow(id: "agent-capture-recovery") }
            Button("Save Capture…") { openWindow(id: "agent-save-capture") }
            Button("Help…") { openWindow(id: "agent-help") }
        }
    }
}
