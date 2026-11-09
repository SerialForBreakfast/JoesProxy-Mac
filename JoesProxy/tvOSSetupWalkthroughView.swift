import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Walkthrough for configuring an Apple TV to use JoesProxy for HTTPS inspection.
/// Accessible from Help > Apple TV Setup Guide.
struct TVOSSetupWalkthroughView: View {
    @EnvironmentObject private var presentationState: AppPresentationState
    @State private var documentationLoaded = false
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: ProxyViewModel
    @State private var networkInfo = LocalNetworkInfo(lanIP: nil, bonjourName: nil)
    @State private var proxyHostOverride: String = ""
    @State private var stepCompletedAt: [Int: Date] = [:]
    @State private var confirmedSteps: Set<Int> = []
    @State private var managedExportAlert: ExportAlertContext?
    @State private var showLimitations = false
    @State private var showTroubleshooting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                leftPanel
                Divider()
                rightPanel
            }
            statusBar
        }
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: 580, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 820, minHeight: 580)
        .opacity(documentationLoaded ? 1 : 0)
        .loadHelpDocumentation { documentationLoaded = true }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Reset") {
                    confirmedSteps = []
                    stepCompletedAt = [:]
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { isPresented = false }
            }
        }
        .onAppear {
            networkInfo = viewModel.currentLocalNetworkInfo()
            if proxyHostOverride.isEmpty {
                proxyHostOverride = networkInfo.lanIP ?? ""
            }
            viewModel.captureSetupNetworkSnapshot()
            Task {
                await viewModel.refreshSDKEventServerStatus()
                if confirmedSteps.isSuperset(of: [1, 2]) {
                    viewModel.startDeviceVerify()
                }
            }
        }
        .onDisappear {
            viewModel.cancelDeviceVerify()
        }
        .alert(item: $managedExportAlert) { ctx in
            Alert(title: Text(ctx.title), message: Text(ctx.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up JoesProxy")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(HelpDocumentation.text("setup-tvos", section: "p1"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 20)

            macConnectionCard
                .padding(.bottom, 14)

            profileExportCard
                .padding(.bottom, 14)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 10) {
                statusPill("Proxy", status: proxyPrerequisiteStatus,
                           actionTitle: viewModel.canStartProxy ? "Start" : nil,
                           action: viewModel.canStartProxy ? { viewModel.startProxy() } : nil)
                statusPill("Certificate", status: certificatePrerequisiteStatus,
                           actionTitle: certificateActionTitle == nil ? nil : "Setup",
                           action: certificateActionTitle == nil ? nil : { presentationState.presentCertificateSetup() })
                statusPill("Firewall", status: .manual, actionTitle: nil, action: nil)
            }
        }
        .padding(20)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var macConnectionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Text("This Mac")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Circle()
                    .fill(proxyIsRunning ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(proxyIsRunning ? "Proxy running" : "Proxy off")
                    .font(.caption2)
                    .foregroundStyle(proxyIsRunning ? .green : .orange)
            }
            if let bonjour = networkInfo.bonjourName {
                Text(normalizedHost(bonjour))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let ip = networkInfo.lanIP {
                Text(ip)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var profileExportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export Profile")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Mac proxy address baked into the profile.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("IP address", text: $proxyHostOverride)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: 140)
                Text(verbatim: ":\(viewModel.configuration.proxyPort)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button("Export Profile\u{2026}", action: exportManagedProfile)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(proxyHostOverride.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepStrip
                        .padding(.bottom, 4)
                    step1Card
                    step2Card
                    step3Card
                    DisclosureGroup("Limitations", isExpanded: $showLimitations) {
                        limitationsContent
                    }
                    .id("limitations")
                    DisclosureGroup("Troubleshooting", isExpanded: $showTroubleshooting) {
                        troubleshootingContent
                    }
                    .id("troubleshooting")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: showLimitations) { _, open in
                if open { withAnimation { proxy.scrollTo("limitations", anchor: .top) } }
            }
            .onChange(of: showTroubleshooting) { _, open in
                if open { withAnimation { proxy.scrollTo("troubleshooting", anchor: .top) } }
            }
        }
    }

    // MARK: - Step Strip

    private var stepStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            stepPill(number: 1, label: "Install Profile", done: confirmedSteps.contains(1))
            connectorLine(done: confirmedSteps.contains(1))
            stepPill(number: 2, label: "Trust Cert", done: confirmedSteps.contains(2))
            connectorLine(done: confirmedSteps.contains(2))
            stepPill(number: 3, label: "Verify", done: step3Done)
        }
    }

    private func stepPill(number: Int, label: String, done: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(done ? Color.accentColor : Color.secondary.opacity(0.15))
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(done ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 66)
        }
    }

    private func connectorLine(done: Bool) -> some View {
        Rectangle()
            .fill(done ? Color.accentColor : Color.secondary.opacity(0.2))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .padding(.top, 13)
    }

    private var step3Done: Bool {
        if case .captured = viewModel.deviceVerifyResult { return true }
        return false
    }

    private var deviceVerifyStatus: WalkthroughStepStatus {
        switch viewModel.deviceVerifyResult {
        case .ready:      return .manual
        case .watching:   return .inProgress("Watching\u{2026}")
        case .captured:   return .done("Traffic captured")
        case .noTrafficDetected: return .attention("No traffic seen")
        }
    }

    // MARK: - Step 1: Install Profile

    private var step1Card: some View {
        walkthroughStepCard(1, "Install Profile", status: confirmedSteps.contains(1) ? .done("Installed") : .manual) {
            instructionStep(1, "Click \u{201c}Export Profile\u{2026}\u{201d} on the left and save the .mobileconfig file.")
            instructionStep(2, "On the supervising Mac, open Apple Configurator \u{2192} select your Apple TV \u{2192} Add \u{2192} Profiles \u{2192} choose the file.")
            instructionStep(3, "On the Apple TV: review the profile and tap Install. A warning screen lists Unmanaged Root Certificate, Global HTTP Proxy, and Unsigned Profile \u{2014} tap the red Install button to confirm.")

            if !confirmedSteps.contains(1) {
                Button("I Installed It") {
                    confirmedSteps.insert(1)
                    stepCompletedAt[1] = Date()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Step 2: Trust Certificate

    private var step2Card: some View {
        walkthroughStepCard(2, "Trust Certificate", status: confirmedSteps.contains(2) ? .done("Trusted") : .manual) {
            Text(HelpDocumentation.text("setup-tvos", section: "p2"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            instructionStep(1, "On the Apple TV: Settings \u{2192} General \u{2192} About.")
            instructionStep(2, "Scroll to the bottom and tap Certificate Trust Settings.")
            instructionStep(3, "Tap JoesProxy Root CA (shows \u{201c}Not Trusted\u{201d}).")
            instructionStep(4, "Tap Continue on the Root Certificate warning. It will now show \u{201c}Trusted\u{201d}.")

            if !confirmedSteps.contains(2) {
                Button("I Trusted It") {
                    confirmedSteps.insert(2)
                    stepCompletedAt[2] = Date()
                    viewModel.startDeviceVerify()
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Why trust is required") { openHelpTopic(.certificateSetup) }
                .buttonStyle(.link)
        }
    }

    // MARK: - Step 3: Verify Capture

    private var step3Card: some View {
        walkthroughStepCard(3, "Verify Capture", status: deviceVerifyStatus) {
            switch viewModel.deviceVerifyResult {
            case .ready:
                Text(HelpDocumentation.text("setup-tvos", section: "p3"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Watch for Traffic") { viewModel.startDeviceVerify() }
                    .buttonStyle(.borderedProminent)

            case .watching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Watching for Apple TV traffic\u{2026}")
                        .foregroundStyle(.secondary)
                }
                Text("Open any app, browse, or stream on the Apple TV now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { viewModel.cancelDeviceVerify() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

            case .captured(let id):
                Label("Traffic captured. JoesProxy is intercepting your Apple TV.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                if let ip = viewModel.deviceVerifyClientAddress {
                    let display = viewModel.deviceVerifyHostname.map { "\($0) (\(ip))" } ?? ip
                    Text(display)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("View Session") {
                        viewModel.selectSessionFromUser(id)
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Watch Again") { viewModel.startDeviceVerify() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }

            case .noTrafficDetected:
                Label("No traffic seen in 60 seconds.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(HelpDocumentation.text("setup-tvos", section: "p4"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { viewModel.startDeviceVerify() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Collapsible sections

    private var limitationsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            bulletItem("Requires a supervised Apple TV and the Apple Configurator app on the supervising Mac.")
            bulletItem("The supervision identity is tied to one Mac \u{2014} the profile must be pushed from the Mac that originally supervised the device.")
            bulletItem("Many streaming apps (Netflix, Disney+, Prime Video) use certificate pinning and will not appear in JoesProxy.")
            bulletItem("Apple\u{2019}s own apps may bypass the proxy or use pinning.")
        }
        .padding(.top, 4)
    }

    private var troubleshootingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            troubleshootingRow(
                "Profile won\u{2019}t appear in Configurator",
                "You must be on the Mac that supervised this Apple TV. Open Apple Configurator on that Mac, select the device, and check that it shows as supervised."
            )
            troubleshootingRow(
                "Certificate shows \u{201c}Not Trusted\u{201d} after install",
                "Go to Settings \u{2192} General \u{2192} About \u{2192} Certificate Trust Settings. Tap JoesProxy Root CA \u{2192} Continue."
            )
            troubleshootingRow(
                "No traffic appears after trusting",
                "Confirm the proxy is running (green dot, left panel). Reboot the Apple TV after profile install if traffic still doesn\u{2019}t flow."
            )
            troubleshootingRow(
                "App traffic not visible",
                "The app likely uses certificate pinning. No workaround \u{2014} pinned apps bypass the proxy entirely."
            )
            Button("Troubleshoot missing HTTPS bodies or pinned traffic") {
                openHelpTopic(.trafficStates)
            }
            .buttonStyle(.link)
        }
        .padding(.top, 4)
    }

    // MARK: - Bottom Status Bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            statusDot("Proxy", status: proxyPrerequisiteStatus)
            statusDot("Certificate", status: certificatePrerequisiteStatus)
            statusDot("SDK", status: sdkPrerequisiteStatus)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Prerequisite state

    private var proxyIsRunning: Bool {
        if case .running = viewModel.proxyState { return true }
        return false
    }

    private var proxyPrerequisiteStatus: WalkthroughStepStatus {
        switch viewModel.proxyState {
        case .running: return .done("Running")
        case .starting, .stopping: return .inProgress("Working\u{2026}")
        case .stopped, .failed: return .attention("Not running")
        }
    }

    private var certificatePrerequisiteStatus: WalkthroughStepStatus {
        switch viewModel.certificateWorkflowState {
        case .ready: return .done("Ready")
        case .installedTrustRequired, .notSetUp, .needsCleanup: return .attention("Needs setup")
        }
    }

    private var certificateActionTitle: String? {
        viewModel.certificateWorkflowState == .ready ? nil : "HTTPS Setup"
    }

    private var sdkPrerequisiteStatus: WalkthroughStepStatus {
        if !viewModel.sdkEventServerEnabled { return .attention("Off") }
        if viewModel.sdkEventServerStatus.isRunning { return .done("Advertising") }
        switch viewModel.proxyState {
        case .running, .starting: return .inProgress("Starting")
        case .stopped, .stopping, .failed: return .attention("Proxy stopped")
        }
    }

    private func normalizedHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    // MARK: - Reusable row builders

    private func statusPill(_ label: String, status: WalkthroughStepStatus, actionTitle: String?, action: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor(status))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
    }

    private func statusDot(_ label: String, status: WalkthroughStepStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusDotColor(status))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func statusDotColor(_ status: WalkthroughStepStatus) -> Color {
        switch status {
        case .done:       return .green
        case .attention:  return .orange
        case .inProgress: return .blue
        case .todo, .manual: return Color.secondary.opacity(0.35)
        }
    }

    private func instructionStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .fontWeight(.medium)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bulletItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func troubleshootingRow(_ issue: String, _ resolution: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(issue).fontWeight(.medium)
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

    // MARK: - Export

    private func exportManagedProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mobileconfig") ?? .data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "JoesProxy-AppleTV.mobileconfig"
        panel.title = "Export Apple TV Managed Proxy Profile"
        panel.message = "Install this profile on the supervised Apple TV via Apple Configurator."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let host = proxyHostOverride.trimmingCharacters(in: .whitespaces)
            try viewModel.exportTVOSManagedProfile(to: url, host: host.isEmpty ? nil : host)
            managedExportAlert = ExportAlertContext(
                title: "Profile Exported",
                message: "Saved \(url.lastPathComponent). In Apple Configurator, select the Apple TV, then Add \u{2192} Profiles \u{2192} choose this file."
            )
        } catch {
            managedExportAlert = ExportAlertContext(title: "Export Failed", message: error.localizedDescription)
        }
    }
}

#Preview {
    TVOSSetupWalkthroughView(isPresented: .constant(true), viewModel: AppCoordinator().viewModel)
}
