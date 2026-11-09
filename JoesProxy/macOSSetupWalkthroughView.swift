import SwiftUI

/// Walkthrough for installing and trusting the JoesProxy root CA on this Mac.
/// Accessible from Help > macOS Setup Guide.
struct macOSSetupWalkthroughView: View {
    @EnvironmentObject private var presentationState: AppPresentationState
    @State private var documentationLoaded = false
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: ProxyViewModel

    @State private var stepCompletedAt: [Int: Date] = [:]

    // MARK: - Sidebar helpers

    private var hasRootCA: Bool { viewModel.rootCertificate != nil }

    private var isMacKeychainInstalled: Bool {
        switch viewModel.certificateWorkflowState {
        case .installedTrustRequired, .ready: return true
        default: return false
        }
    }

    private var isMacCertTrusted: Bool { viewModel.certificateWorkflowState == .ready }

    private var isMacVerifyCaptured: Bool {
        if case .captured = viewModel.macVerifyResult { return true }
        return false
    }

    private var sidebarSteps: [SidebarStep] {
        [
            SidebarStep(
                id: 1,
                icon: "key.fill",
                title: "Root CA Created",
                detail: hasRootCA
                    ? viewModel.configuration.certificateLabel
                    : "Tap Create Root CA in Step 1",
                state: hasRootCA ? .done(stepCompletedAt[1]) : .pending
            ),
            SidebarStep(
                id: 2,
                icon: "externaldrive.badge.checkmark",
                title: "In Login Keychain",
                detail: isMacKeychainInstalled
                    ? "Added to login keychain"
                    : "Complete Step 1 first",
                state: isMacKeychainInstalled ? .done(stepCompletedAt[2]) : .pending
            ),
            SidebarStep(
                id: 3,
                icon: "lock.shield.fill",
                title: "Certificate Trusted",
                detail: isMacCertTrusted
                    ? "Always Trust in Keychain Access"
                    : "Trust via button or Keychain Access",
                state: viewModel.isTrustingCertificate ? .inProgress("Trusting…")
                    : isMacCertTrusted ? .done(stepCompletedAt[3]) : .pending
            ),
            SidebarStep(
                id: 4,
                icon: "checkmark.shield",
                title: "HTTPS Verified",
                detail: isMacVerifyCaptured
                    ? "Request intercepted"
                    : "Run verify test in Step 4",
                state: {
                    switch viewModel.macVerifyResult {
                    case .captured:          return .done(stepCompletedAt[4])
                    case .watching:          return .inProgress("Watching…")
                    case .noTrafficDetected: return .attention("No traffic")
                    case .ready:             return .pending
                    }
                }()
            )
        ]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    createCertStep
                    installCertStep
                    trustCertStep
                    verifyStep
                    troubleshootingDisclosure
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            SetupProgressSidebar(title: "Setup Status", steps: sidebarSteps)
                .frame(width: 210)
        }
        .frame(minWidth: 740, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 740, minHeight: 520)
        .opacity(documentationLoaded ? 1 : 0)
        .loadHelpDocumentation { documentationLoaded = true }
        .onDisappear { viewModel.cancelMacVerify() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { isPresented = false }
            }
        }
        .alert(item: $viewModel.trustAlertContext) { context in
            Alert(
                title: Text(context.title),
                message: Text(context.message),
                primaryButton: .default(Text("OK")) { viewModel.dismissTrustAlert() },
                secondaryButton: context.primaryAction == .resetCertificateState
                    ? .destructive(Text("Reset Certificate State")) { viewModel.confirmResetCertificateState() }
                    : .cancel(Text("Cancel")) { viewModel.dismissTrustAlert() }
            )
        }
        .onChange(of: hasRootCA) { _, has in
            if has { stepCompletedAt[1] = stepCompletedAt[1] ?? Date() }
        }
        .onChange(of: isMacKeychainInstalled) { _, installed in
            if installed { stepCompletedAt[2] = stepCompletedAt[2] ?? Date() }
        }
        .onChange(of: isMacCertTrusted) { _, trusted in
            if trusted { stepCompletedAt[3] = stepCompletedAt[3] ?? Date() }
        }
        .onChange(of: isMacVerifyCaptured) { _, verified in
            if verified { stepCompletedAt[4] = stepCompletedAt[4] ?? Date() }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("macOS Certificate Setup")
                .font(.title)
                .fontWeight(.semibold)
            Text(HelpDocumentation.text("setup-macos", section: "p1"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step status helpers

    private var createStatus: WalkthroughStepStatus {
        switch viewModel.certificateWorkflowState {
        case .notSetUp: return .attention("Not created")
        case .needsCleanup: return .attention("Needs cleanup")
        default: return .done("Created")
        }
    }

    private var installStatus: WalkthroughStepStatus {
        switch viewModel.certificateWorkflowState {
        case .notSetUp: return .todo
        case .needsCleanup: return .attention("Needs cleanup")
        case .installedTrustRequired, .ready: return .done("Installed")
        }
    }

    private var trustStatus: WalkthroughStepStatus {
        if viewModel.isTrustingCertificate { return .inProgress("Trusting…") }
        switch viewModel.certificateWorkflowState {
        case .ready: return .done("Trusted")
        case .installedTrustRequired: return .attention("Trust required")
        default: return .todo
        }
    }

    // MARK: - Steps

    private var createCertStep: some View {
        walkthroughStepCard(1, "Create Root CA", status: createStatus) {
            Text(HelpDocumentation.text("setup-macos", section: "p2"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch viewModel.certificateWorkflowState {
            case .notSetUp where viewModel.rootCertificate == nil:
                Button("Create Root CA") {
                    viewModel.createOrLoadRootCertificate()
                }
                .buttonStyle(.borderedProminent)

            case .needsCleanup:
                VStack(alignment: .leading, spacing: 8) {
                    Label("A stale certificate needs cleanup before a new one can be created.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(viewModel.certificateSetupEntryPointTitle) {
                        isPresented = false
                        presentationState.presentCertificateSetup()
                    }
                    .buttonStyle(.borderedProminent)
                }

            default:
                Label("Root CA exists.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            }
        }
    }

    private var installCertStep: some View {
        walkthroughStepCard(2, "Install in Login Keychain", status: installStatus) {
            Text(HelpDocumentation.text("setup-macos", section: "p3"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch viewModel.certificateWorkflowState {
            case .notSetUp where viewModel.rootCertificate != nil:
                Button("Install in Login Keychain") {
                    viewModel.installRootCertificate()
                }
                .buttonStyle(.borderedProminent)

            case .notSetUp:
                Text("Complete Step 1 first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .needsCleanup:
                VStack(alignment: .leading, spacing: 8) {
                    Label("A stale certificate needs to be cleaned up before reinstalling.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(viewModel.certificateSetupEntryPointTitle) {
                        isPresented = false
                        presentationState.presentCertificateSetup()
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .installedTrustRequired, .ready:
                Label("Certificate is installed in the login keychain.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            }
        }
    }

    private var trustCertStep: some View {
        walkthroughStepCard(3, "Trust the Certificate", status: trustStatus) {
            Text(HelpDocumentation.text("setup-macos", section: "p4"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch viewModel.certificateWorkflowState {
            case .installedTrustRequired:
                if viewModel.isTrustingCertificate {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Setting trust — approve the macOS password dialog…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Trust Root CA") {
                            viewModel.trustRootCertificate()
                        }
                        .buttonStyle(.borderedProminent)

                        Text(HelpDocumentation.text("setup-macos", section: "p5"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            case .ready:
                Label("Certificate is trusted. Ready for HTTPS inspection.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)

            default:
                Text("Complete Steps 1 and 2 first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.certificateWorkflowState == .installedTrustRequired && !viewModel.isTrustingCertificate {
                HStack(spacing: 8) {
                    Button("Refresh Status") {
                        viewModel.refreshCertificateStatus()
                    }
                    .buttonStyle(.bordered)
                    Button("Why trust is required") {
                        openHelpTopic(.certificateSetup)
                    }
                    .buttonStyle(.link)
                }
            }

            DisclosureGroup("Trust manually (Keychain Access)") {
                VStack(alignment: .leading, spacing: 6) {
                    instructionStep(1, "Open Keychain Access (Spotlight → Keychain Access).")
                    instructionStep(2, "Select the login keychain in the sidebar.")
                    instructionStep(3, "Find \(viewModel.configuration.certificateLabel) in the list.")
                    instructionStep(4, "Double-click the certificate.")
                    instructionStep(5, "Expand the Trust section.")
                    instructionStep(6, "Set When using this certificate to Always Trust.")
                    instructionStep(7, "Close the window. macOS may prompt to confirm.")
                    instructionStep(8, "Return here and tap Refresh Status above.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
    }

    private var macVerifyStatus: WalkthroughStepStatus {
        switch viewModel.macVerifyResult {
        case .ready: return .todo
        case .watching: return .inProgress("Watching…")
        case .captured: return .done("Captured")
        case .noTrafficDetected: return .attention("No traffic")
        }
    }

    private var verifyStep: some View {
        walkthroughStepCard(4, "Verify HTTPS Interception", status: macVerifyStatus) {
            Text(HelpDocumentation.text("setup-macos", section: "p6"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch viewModel.macVerifyResult {
            case .ready:
                if viewModel.certificateWorkflowState == .ready {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Run Verify Test") { viewModel.startMacVerify() }
                            .buttonStyle(.borderedProminent)
                        Text(HelpDocumentation.text("setup-macos", section: "p7"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Complete Steps 1–3 first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .watching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Opening test page and watching for traffic…")
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { viewModel.cancelMacVerify() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

            case .captured(let id):
                Label("HTTPS traffic captured — JoesProxy is intercepting successfully.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("View in JoesProxy") {
                        viewModel.selectSessionFromUser(id)
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Test Again") { viewModel.startMacVerify() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }

            case .noTrafficDetected:
                VStack(alignment: .leading, spacing: 8) {
                    Label("No traffic detected within 15 seconds.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(HelpDocumentation.text("setup-macos", section: "p8"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { viewModel.startMacVerify() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Troubleshooting

    private var troubleshootingDisclosure: some View {
        DisclosureGroup("Troubleshooting") {
            VStack(alignment: .leading, spacing: 12) {
                troubleshootingRow(
                    "Status doesn't update after trusting",
                    "Confirm the trust change was saved in the login keychain. Tap Refresh Status or close and reopen the setup sheet."
                )
                troubleshootingRow(
                    "Trust Root CA button shows an error",
                    "macOS may reject this if JoesProxy is running in the App Sandbox or the login keychain is locked. Use the manual Keychain Access steps instead."
                )
                troubleshootingRow(
                    "HTTPS still fails",
                    "Ensure the certificate shows Always Trust in Keychain Access. Restart the app making the request."
                )
                troubleshootingRow(
                    "Certificate not found in Keychain Access",
                    "Re-run Install in Login Keychain from Step 2 above."
                )
                troubleshootingRow(
                    "Stale or duplicate certificate",
                    "Use Reset Certificate State in the Certificate Setup sheet, then remove any leftover \(viewModel.configuration.certificateLabel) manually in Keychain Access."
                )
                Button("Troubleshoot missing HTTPS bodies or tunneled traffic") {
                    openHelpTopic(.trafficStates)
                }
                .buttonStyle(.link)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Helpers

    private func instructionStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .fontWeight(.medium)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func troubleshootingRow(_ issue: String, _ resolution: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(issue)
                .fontWeight(.medium)
            Text(resolution)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openHelpTopic(_ topic: MainWindowHelpTopic) {
        isPresented = false
        presentationState.presentHelpHub(topic: topic)
    }
}

#Preview {
    macOSSetupWalkthroughView(
        isPresented: .constant(true),
        viewModel: AppCoordinator().viewModel
    )
}
