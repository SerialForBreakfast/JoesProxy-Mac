import SwiftUI

struct RollingCaptureRestoreSheetView: View {
    let offer: RollingCaptureRestoreOffer
    @ObservedObject var viewModel: ProxyViewModel
    @ObservedObject var settingsViewModel: SettingsViewModel
    @ObservedObject var compactModeController: CompactModeController
    let openRecoverySettings: () -> Void
    @StateObject private var operation = RollingCaptureRecoveryOperation()
    @Environment(\.appTextScale) private var textScale
    @State private var diagnosticsSaveMessage: String?

    private var isCompact: Bool { compactModeController.isCompactModeActive }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Restore saved capture?")
                            .appFont(.title2, scale: textScale, weight: .semibold)
                        Text(verbatim: "\(offer.sessionCount) sessions in your saved capture.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let diagnostics = viewModel.previousRunDiagnosticsCoordinator {
                        PreviousRunDiagnosticsCopyButton(
                            coordinator: diagnostics,
                            accessibilityIdentifier: "rollingCaptureCopyDiagnosticsButton")
                    }
                }
                VStack(spacing: 10) {
                    LabeledContent("Saved") {
                        Text(offer.savedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let bytes = offer.fileSizeBytes, bytes > 0 {
                        Divider()
                        LabeledContent("Size") {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                        }
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                Text("Load saved requests and responses for inspection.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !viewModel.canRestoreRollingCapture {
                    Text("Your current capture already has sessions. Save a copy instead; restoring would replace them.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("rollingCaptureRestoreUnavailable")
                }
                if operation.isRunning {
                    ProgressView(operation.progressMessage)
                        .accessibilityIdentifier("rollingCaptureRestoreProgress")
                }
                if let error = operation.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("rollingCaptureRestoreError")
                }
                if let diagnosticsSaveMessage {
                    Text(diagnosticsSaveMessage)
                        .appFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("rollingCaptureDiagnosticsSaveMessage")
                }
                if isCompact {
                    restoreButton
                    HStack { freshButton; Spacer(); exportMenu }
                        .disabled(operation.isRunning)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Don’t ask to restore on launch", isOn: Binding(
                        get: { !settingsViewModel.rollingCaptureRestorePromptEnabled },
                        set: { settingsViewModel.rollingCaptureRestorePromptEnabled = !$0 }
                    ))
                    .toggleStyle(.checkbox)
                    .accessibilityHint("Hides future saved-capture prompts, without disabling recovery checkpoints.")
                    .accessibilityIdentifier("rollingCaptureSuppressPromptToggle")
                    Text("Saved captures remain available in Settings.")
                        .appFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                    Button("Open Recovery Settings…", action: openRecoverySettings)
                        .buttonStyle(.link)
                        .accessibilityIdentifier("rollingCaptureOpenSettingsButton")
                }
                if !isCompact {
                    HStack { exportMenu; Spacer(); freshButton; restoreButton }
                        .disabled(operation.isRunning)
                }
            }
            .padding(isCompact ? 24 : 28)
        }
        .appFont(.body, scale: textScale)
        .frame(width: isCompact ? 380 : 560, height: isCompact ? 540 : 460)
        .interactiveDismissDisabled()
        .background(UITestPrimaryScreenWindowConfigurator().frame(width: 0, height: 0))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rollingCaptureRestoreSheet")
    }

    private var restoreButton: some View {
        Button {
            Task { await operation.run { try await viewModel.restoreRollingCapture() } }
        } label: {
            Text("Restore Capture")
                .frame(maxWidth: isCompact ? .infinity : nil)
                .padding(.vertical, isCompact ? 6 : 0)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(operation.isRunning || !viewModel.canRestoreRollingCapture)
        .accessibilityIdentifier("rollingCaptureRestoreResumeButton")
    }

    private var freshButton: some View {
        Button("Start Fresh") { viewModel.dismissRollingCaptureRestoreOffer() }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("rollingCaptureStartFreshButton")
    }

    private var exportMenu: some View {
        Menu("Save a Copy…") {
            Button("Save .jproxy File…") { export(.recording) }
                .accessibilityIdentifier("rollingCaptureSaveRecordingButton")
            Button("Export .har File…") { export(.har) }
                .accessibilityIdentifier("rollingCaptureExportHARButton")
            if let diagnostics = viewModel.previousRunDiagnosticsCoordinator {
                Divider()
                PreviousRunDiagnosticsSaveButton(
                    coordinator: diagnostics,
                    accessibilityIdentifier: "rollingCaptureSaveDiagnosticsButton"
                ) { diagnosticsSaveMessage = $0.message }
            }
        }
        .fixedSize()
        .accessibilityHint("Choose a recording, HAR copy, or diagnostics without loading it into the app.")
        .accessibilityIdentifier("rollingCaptureExportMenu")
    }

    private func export(_ format: RollingCaptureExportFormat) {
        Task {
            await operation.run(exporting: true) {
                try await viewModel.promptSaveRollingCaptureSnapshot(format: format)
            }
        }
    }
}
