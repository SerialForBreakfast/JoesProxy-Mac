import SwiftUI

struct AgentWorkspaceSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var supportsInspector = true
    var openInspector: (() -> Void)?
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Text Size", selection: $viewModel.appTextSize) {
                    ForEach(AppTextSize.allCases) { textSize in
                        Text(textSize.title).tag(textSize)
                    }
                }
                .accessibilityIdentifier("agentSettingsTextSizePicker")
            }

            Section("Startup Workspace") {
              if supportsInspector {
                Picker("Workspace", selection: $viewModel.launchWorkspacePreference) {
                    Text("Inspector").tag(LaunchWorkspacePreference.inspector)
                    Text("Agent").tag(LaunchWorkspacePreference.agent)
                }
                .accessibilityIdentifier("agentSettingsLaunchWorkspacePicker")

                Text("This preference is applied on the next normal launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let openInspector {
                    Button("Open Inspector Now", action: openInspector)
                        .accessibilityIdentifier("agentSettingsOpenInspector")
                }
              } else {
                Text("This experimental executable contains only the Agent workspace.")
              }
            }
        }
        .padding(20)
        .appFont(.body, scale: textScale)
        .frame(width: 420)
    }
}

struct AgentWorkspaceHelpView: View {
    @Environment(\.appTextScale) private var textScale
    @State private var topicID = "agent-documentation"
    @State private var catalog: DocumentationCatalog?
    @State private var failure: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let catalog {
                    Picker("Documentation topic", selection: $topicID) {
                        ForEach(catalog.index.topics) { topic in Text(topic.title).tag(topic.id) }
                    }
                    ForEach(catalog.topicSections(topicID), id: \.id) { section in
                        Text(section.title).appFont(.headline, scale: textScale, weight: .semibold)
                        Text(verbatim: section.markdown).textSelection(.enabled)
                    }
                } else if let failure {
                    Text(failure)
                    Button("Retry") { Task { await load() } }
                } else { ProgressView("Loading documentation…") }
            }
        }
        .padding(24)
        .appFont(.body, scale: textScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .task { await load() }
    }

    private func load() async {
        do {
            catalog = try await DocumentationService.shared.snapshot()
            failure = nil
        } catch {
            failure = "Bundled documentation could not be loaded. Reopen a complete JoesProxy installation."
        }
    }
}

struct AgentSetupReadinessView: View {
    @Environment(\.appTextScale) private var textScale
    @ObservedObject var recovery: AgentSetupRecoveryController
    @ObservedObject var routing: SystemProxyRoutingModel
    @State private var confirmInstall = false

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            if let readiness = recovery.readiness {
                Form {
                    LabeledContent("Local trust", value: trustTitle(readiness.localTrustState))
                    LabeledContent("Profile", value: readiness.profileHealth.title)
                    LabeledContent("Capture verification", value: verificationTitle(readiness.verificationState))
                    LabeledContent(
                        "Profile delivery observed",
                        value: readiness.profileDownloadObserved ? "Yes" : "Not observed"
                    )
                }
            } else {
                ProgressView("Checking setup readiness…")
            }
            if recovery.isWorking { ProgressView("Updating setup…") }
            if let failure = recovery.failure {
                Text(failure).foregroundStyle(.red).accessibilityIdentifier("agentSetupFailure")
            }
            if let receipt = recovery.receipt { Text(receipt).accessibilityIdentifier("agentSetupReceipt") }
            Button("Refresh Readiness") { Task { await recovery.refresh() } }
                .disabled(recovery.isWorking)
            Button("Install Local Certificate…") { confirmInstall = true }
                .disabled(recovery.isWorking)
                .accessibilityIdentifier("agentSetupInstallCertificate")
            Toggle("Route Mac traffic through JoesProxy", isOn: $routing.isRoutingEnabled)
            Text("Local trust does not prove device trust or successful traffic inspection.")
                .foregroundStyle(.secondary)
          }
        }
        .padding(20)
        .appFont(.body, scale: textScale)
        .task { await recovery.refresh() }
        .alert("Install JoesProxy's local certificate?", isPresented: $confirmInstall) {
            Button("Install") { Task { await recovery.installCertificate() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This changes the local certificate store and may request system permission. It does not establish trust on another device.")
        }
        .alert(SystemProxyRoutingCopy.consentTitle, isPresented: $routing.pendingConsent) {
            Button("Enable Routing") { routing.confirmConsent() }
            Button("Cancel", role: .cancel) { routing.cancelConsent() }
        } message: { Text(routing.consentMessage) }
        .accessibilityIdentifier("agentSetupReadiness")
    }

    private func trustTitle(_ state: MCPSetupReadinessState.LocalTrustState) -> String {
        switch state {
        case .notSetUp: return "Not set up"
        case .installedTrustRequired: return "Trust required"
        case .ready: return "Ready"
        case .needsCleanup: return "Needs cleanup"
        }
    }

    private func verificationTitle(_ state: MCPSetupReadinessState.VerificationState?) -> String {
        switch state {
        case .inspected: return "Inspected traffic observed"
        case .tunneled: return "Tunnel traffic observed"
        case .noTrafficObserved: return "No traffic observed"
        case .proxyStopped: return "Proxy stopped"
        case nil: return "Unavailable"
        }
    }
}

/// The Agent restore action is intentionally narrow: it either restores the latest safe snapshot
/// into an empty store or reports why it declined. It never opens captured-session presentation.
struct AgentCaptureRecoveryView: View {
    @Environment(\.appTextScale) private var textScale
    let persistence: RollingCapturePersistenceCoordinator
    @ObservedObject var recoveryController: AgentCaptureRecoveryController
    let sessionStore: any SessionStore
    private var isRestoring: Bool { recoveryController.isRestoring }
    private var resultMessage: String? { recoveryController.resultMessage }
    @State private var showsSavedOffer = true
    @State private var diagnosticsSaveMessage: String?

    private var availableOffer: RollingCaptureRestoreOffer? {
        showsSavedOffer ? persistence.availableRestoreOffer() : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Capture Recovery")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let diagnostics = recoveryController.diagnosticsCoordinator {
                    PreviousRunDiagnosticsCopyButton(
                        coordinator: diagnostics,
                        accessibilityIdentifier: "agentCaptureRecoveryCopyDiagnosticsButton")
                }
            }
            if !showsSavedOffer {
                Text("Automatic recovery is suppressed for this saved capture.")
                    .foregroundStyle(.secondary)
            } else if let offer = availableOffer {
                Text("A saved capture with \(offer.sessionCount) sessions is available.")
                if recoveryController.hasSessions {
                    Text("Restore is unavailable while this capture contains sessions.")
                        .foregroundStyle(.secondary)
                }
                Button(isRestoring ? "Restoring…" : "Restore Saved Capture") {
                    restore()
                }
                .disabled(isRestoring || recoveryController.hasSessions)
                .accessibilityIdentifier("agentCaptureRecoveryRestore")
                Button("Start Fresh") {
                    recoveryController.startFresh()
                    showsSavedOffer = false
                }
                .disabled(isRestoring)
                .accessibilityIdentifier("agentCaptureRecoveryStartFresh")
            } else {
                Text("No readable saved capture is available.")
                    .foregroundStyle(.secondary)
            }
            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let diagnostics = recoveryController.diagnosticsCoordinator {
                PreviousRunDiagnosticsSaveButton(
                    coordinator: diagnostics,
                    accessibilityIdentifier: "agentCaptureRecoverySaveDiagnosticsButton"
                ) { diagnosticsSaveMessage = $0.message }
                if let diagnosticsSaveMessage {
                    Text(diagnosticsSaveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("agentCaptureRecoveryDiagnosticsSaveMessage")
                }
            }
            Spacer()
        }
        .padding(24)
        .appFont(.body, scale: textScale)
        .accessibilityIdentifier("agentCaptureRecovery")
    }

    private func restore() {
        Task {
            // The shared owner retains progress and the outcome if this window closes.
            _ = try? await recoveryController.restoreLatestCapture()
        }
    }

}

/// Agent-side capture saving intentionally has no Inspector selection dependency.
struct AgentCaptureExportView: View {
    @Environment(\.appTextScale) private var textScale
    @ObservedObject var exportController: AgentCaptureExportController
    let sessionStore: any SessionStore
    private var isSaving: Bool { exportController.isSaving }
    private var resultMessage: String? { exportController.resultMessage }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Capture")
                .font(.title2.weight(.semibold))
            Text(!exportController.hasSessions
                ? "There are no captured sessions to save."
                : "Save all captured sessions as a recording without opening Inspector.")
                .foregroundStyle(.secondary)
            Button(isSaving ? "Saving…" : "Choose Save Location…") {
                chooseDestinationAndSave()
            }
            .disabled(isSaving || !exportController.hasSessions)
            .accessibilityIdentifier("agentSaveRecording")
            Button("Export All as HAR…") { chooseHARAndSave() }
                .disabled(isSaving || !exportController.hasSessions)
                .accessibilityIdentifier("agentExportHAR")
            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .appFont(.body, scale: textScale)
        .accessibilityIdentifier("agentSaveCapture")
    }

    private func chooseDestinationAndSave() {
        let fileCoordinator = RecordingFileCoordinator()
        guard let selection = fileCoordinator.promptForSaveSelection(defaultName: "Recording") else {
            return
        }
        Task {
            try? await exportController.saveAllSessions(to: selection.url, fidelity: selection.fidelity)
        }
    }

    private func chooseHARAndSave() {
        guard let destination = RecordingFileCoordinator().promptForHARExport() else { return }
        Task { try? await exportController.saveAllSessions(to: destination, asHAR: true) }
    }
}
