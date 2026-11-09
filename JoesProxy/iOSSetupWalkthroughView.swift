import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Walkthrough for configuring an iPhone or iPad to use JoesProxy for HTTPS inspection.
/// Accessible from Help > iOS Setup Guide.
struct iOSSetupWalkthroughView: View {
    @EnvironmentObject private var presentationState: AppPresentationState
    @State private var documentationLoaded = false
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: ProxyViewModel
    @State private var networkInfo = LocalNetworkInfo(lanIP: nil, bonjourName: nil)
    @State private var lastExportedProfileURL: URL?
    @State private var exportAlert: ExportAlertContext?
    @State private var isQRCodePresented = false
    @State private var stepCompletedAt: [Int: Date] = [:]
    @State private var confirmedSteps: Set<Int> = []
    @State private var automaticProxy = true
    @State private var allowsDirectFallback = false
    @State private var showProxyQRCode = false

    // MARK: - Sidebar helpers

    private var isDeviceVerifyCaptured: Bool {
        if case .captured = viewModel.deviceVerifyResult { return true }
        return false
    }

    private var sidebarSteps: [SidebarStep] {
        [
            SidebarStep(
                id: 1,
                icon: "arrow.down.doc.fill",
                title: "Profile Downloaded",
                detail: viewModel.profileServerDownloadDetected
                    ? "Install via Settings on the device"
                    : viewModel.profileServerURL != nil
                        ? "AirDrop or open in Safari"
                        : "Starting profile server…",
                state: viewModel.profileServerDownloadDetected
                    ? .done(stepCompletedAt[1])
                    : viewModel.profileServerURL != nil ? .inProgress("Server ready") : .pending
            ),
            SidebarStep(
                id: 2,
                icon: "lock.shield.fill",
                title: "Certificate Trusted",
                detail: confirmedSteps.contains(2)
                    ? "Full trust enabled on device"
                    : "Settings > General > About > Certificate Trust Settings",
                state: .manual(confirmed: confirmedSteps.contains(2)),
                onConfirm: confirmedSteps.contains(2) ? nil : {
                    confirmedSteps.insert(2)
                    stepCompletedAt[2] = Date()
                }
            ),
            SidebarStep(
                id: 3,
                icon: "wifi",
                title: "Proxy Configured",
                detail: confirmedSteps.contains(3)
                    ? "Proxy settings confirmed by you"
                    : "Wi-Fi > network > Configure Proxy",
                state: .manual(confirmed: confirmedSteps.contains(3)),
                onConfirm: confirmedSteps.contains(3) ? nil : {
                    confirmedSteps.insert(3)
                    stepCompletedAt[3] = Date()
                }
            ),
            SidebarStep(
                id: 4,
                icon: "checkmark.shield",
                title: "Traffic Verified",
                detail: isDeviceVerifyCaptured
                    ? "Device traffic seen in JoesProxy"
                    : "Tap Watch for Traffic in Step 4",
                state: {
                    switch viewModel.deviceVerifyResult {
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
                    prerequisitesSection
                    installCertStep
                    trustCertStep
                    proxyConfigStep
                    verifyStep
                    DisclosureGroup("Limitations") { limitationsContent }
                    DisclosureGroup("Troubleshooting") { troubleshootingContent }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            SetupProgressSidebar(title: "Setup Status", steps: sidebarSteps)
                .frame(width: 210)
        }
        .frame(minWidth: 740, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 740, minHeight: 560)
        .opacity(documentationLoaded ? 1 : 0)
        .loadHelpDocumentation { documentationLoaded = true }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export Trust Profile") { exportTrustProfile() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { isPresented = false }
            }
        }
        .onAppear {
            networkInfo = viewModel.currentLocalNetworkInfo()
            viewModel.captureSetupNetworkSnapshot()
            Task { await viewModel.startProfileServer() }
        }
        .onDisappear {
            Task { await viewModel.stopProfileServer() }
            viewModel.cancelDeviceVerify()
        }
        .alert(item: $exportAlert) { context in
            Alert(
                title: Text(context.title),
                message: Text(context.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $isQRCodePresented) { qrCodeSheet }
        .onChange(of: viewModel.profileServerDownloadDetected) { _, detected in
            if detected { stepCompletedAt[1] = stepCompletedAt[1] ?? Date() }
        }
        .onChange(of: isDeviceVerifyCaptured) { _, captured in
            if captured { stepCompletedAt[4] = stepCompletedAt[4] ?? Date() }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iOS Device Setup")
                .font(.title)
                .fontWeight(.semibold)
            Text(HelpDocumentation.text("setup-ios", section: "p1"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Prerequisites

    private var prerequisitesSection: some View {
        GroupBox("Prerequisites") {
            VStack(alignment: .leading, spacing: 8) {
                prerequisiteRow(
                    title: "Proxy is running on port \(String(viewModel.configuration.proxyPort))",
                    detail: proxyPrerequisiteDetail,
                    status: proxyPrerequisiteStatus,
                    actionTitle: viewModel.canStartProxy ? "Start Proxy" : nil,
                    action: viewModel.canStartProxy ? { viewModel.startProxy() } : nil
                )
                prerequisiteRow(
                    title: "HTTPS certificate is ready on this Mac",
                    detail: viewModel.certificateStatusGuidance,
                    status: certificatePrerequisiteStatus,
                    actionTitle: certificateActionTitle,
                    action: certificateActionTitle == nil ? nil : {
                        presentationState.presentCertificateSetup()
                    }
                )
                prerequisiteRow(
                    title: "The iPhone or iPad is on the same Wi-Fi network",
                    detail: "Use the same network as this Mac before configuring the proxy on the device.",
                    status: .manual
                )
                prerequisiteRow(
                    title: "Mac firewall allows inbound connections on port \(String(viewModel.configuration.proxyPort))",
                    detail: "If the device cannot connect, allow JoesProxy incoming connections in macOS Firewall settings.",
                    status: .manual
                )
            }
        }
    }

    // MARK: - Step status helpers

    private var installCertStepStatus: WalkthroughStepStatus {
        if viewModel.profileServerDownloadDetected { return .done("Downloaded — install in Settings") }
        if viewModel.profileServerURL != nil { return .inProgress("Server ready") }
        if viewModel.profileServerStartErrorMessage != nil { return .attention("Server error") }
        return .inProgress("Starting…")
    }

    private var deviceVerifyStatus: WalkthroughStepStatus {
        switch viewModel.deviceVerifyResult {
        case .ready: return .todo
        case .watching: return .inProgress("Watching…")
        case .captured: return .done("Captured")
        case .noTrafficDetected: return .attention("No traffic")
        }
    }

    // MARK: - Steps

    private var installCertStep: some View {
        walkthroughStepCard(1, "Install Trust Profile", status: installCertStepStatus) {
            // Primary path: AirDrop. Deterministic — it doesn't depend on which browser the
            // device treats as default, unlike a tapped URL (see the Safari path below).
            Text(HelpDocumentation.text("setup-ios", section: "p2"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                shareTrustProfile()
            } label: {
                Label("AirDrop to iPhone or iPad", systemImage: "airplayaudio")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Text(HelpDocumentation.text("setup-ios", section: "p3"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            // Alternative path: Safari URL / QR code. Only Safari has the special-cased download
            // handling that turns a tapped `.mobileconfig` link into the system install prompt —
            // any other browser (Chrome, Firefox, Edge, …) just downloads it as a generic file
            // that iOS never offers to install. If a third-party browser is the device's system
            // default, even scanning the QR code with the Camera app can route through it instead
            // of Safari, so this path can silently fail with no error shown to the user.
            Text("Alternative: open the profile URL in Safari")
                .font(.subheadline.weight(.semibold))

            if let serverURL = viewModel.profileServerURL {
                HStack(spacing: 8) {
                    Text(serverURL.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(serverURL.absoluteString, forType: .string)
                        exportAlert = ExportAlertContext(
                            title: "URL Copied",
                            message: "Open \(serverURL.absoluteString) in Safari on the iPhone or iPad."
                        )
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    isQRCodePresented = true
                } label: {
                    Label("Show QR Code", systemImage: "qrcode")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text(HelpDocumentation.text("setup-ios", section: "p4"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            } else if let errorMessage = viewModel.profileServerStartErrorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Profile Server Unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting profile server…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Manual fallback, for when AirDrop isn't available (e.g. Bluetooth/Wi-Fi off) and
            // Safari isn't an option either.
            DisclosureGroup("Other transfer methods (Files, Mail, …)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(HelpDocumentation.text("setup-ios", section: "p5"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        exportTrustProfile()
                    } label: {
                        Label("Export Trust Profile", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    instructionStep(1, "Click Export Trust Profile and save the .mobileconfig file.")
                    instructionStep(2, "Transfer it to the device using Files, Mail, or another method.")
                    instructionStep(3, "On the device, open Settings and tap Profile Downloaded (or Settings > General > VPN & Device Management).")
                    instructionStep(4, "Open the JoesProxy iOS Trust Profile, tap Install, enter your passcode, then tap Install again.")
                    instructionStep(5, "Tap Done after the profile installs.")

                    if let lastExportedProfileURL {
                        Text("Last exported: \(lastExportedProfileURL.lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Text(HelpDocumentation.text("setup-ios", section: "p6"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    private var trustCertStep: some View {
        walkthroughStepCard(2, "Trust the Certificate", status: .manual) {
            Text(HelpDocumentation.text("setup-ios", section: "p7"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            instructionStep(1, "Open Settings > General > About.")
            instructionStep(2, "Scroll to Certificate Trust Settings.")
            instructionStep(3, "Under Enable Full Trust For Root Certificates, find JoesProxy Root CA.")
            instructionStep(4, "Toggle JoesProxy Root CA ON and confirm the prompt.")

            Text(HelpDocumentation.text("setup-ios", section: "p8"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Why trust is required") { openHelpTopic(.certificateSetup) }
                .buttonStyle(.link)
        }
    }

    private var proxyConfigStep: some View {
        walkthroughStepCard(3, "Configure Proxy on Device", status: .manual) {
            Text(HelpDocumentation.text("setup-ios", section: "p9"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Setup method", selection: $automaticProxy) {
                Text("Automatic URL").tag(true)
                Text("Manual host and port").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("iosProxySetupMethod")

            if automaticProxy {
                automaticProxyControls
            } else {
                HStack(spacing: 10) {
                    Button { copyServerHost() } label: {
                        Label("Copy Host", systemImage: "doc.on.doc")
                    }
                    Button { copyProxyPort() } label: {
                        Label("Copy Port", systemImage: "number")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                instructionStep(1, "Open Settings > Wi-Fi on the iPhone or iPad.")
                instructionStep(2, "Tap the info icon next to the connected network.")
                instructionStep(3, "Tap Configure Proxy > Manual.")
                instructionStep(4, serverInstructionText)
                instructionStep(5, "Enter Port: \(String(viewModel.configuration.proxyPort))")
                instructionStep(6, "Leave Authentication Off. Tap Save.")
            }

            Text(HelpDocumentation.text("setup-ios", section: "p10"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var automaticProxyURL: URL? {
        guard case .running(let port) = viewModel.proxyState else { return nil }
        return DeviceProxyAutoConfiguration.url(host: networkInfo.lanIP, port: port,
                                               allowsDirect: allowsDirectFallback)
    }

    private var automaticProxyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Allow direct connections if the proxy is unavailable", isOn: $allowsDirectFallback)
                .accessibilityIdentifier("iosProxyDirectFallback")
            Text(allowsDirectFallback
                 ? "Direct fallback may bypass capture. It is not protection for risky requests."
                 : "Proxy required: connections may fail when JoesProxy stops. This does not prevent apps from bypassing the system proxy.")
                .font(.caption).foregroundStyle(.secondary)
            if let url = automaticProxyURL {
                Text(url.absoluteString).textSelection(.enabled)
                    .font(.system(.caption, design: .monospaced))
                    .accessibilityIdentifier("iosProxyPACURL")
                ViewThatFits(in: .horizontal) {
                    HStack { automaticProxyActions(url: url) }
                    VStack(alignment: .leading) { automaticProxyActions(url: url) }
                }
                if showProxyQRCode {
                    QRCodeView(urlString: url.absoluteString, size: 180)
                    Text("Scanning opens the configuration file; it does not change iOS settings. Copy its URL into Configure Proxy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                instructionStep(1, "Open Settings > Wi-Fi > your network’s info button > Configure Proxy.")
                instructionStep(2, "Choose Automatic, paste the Setup URL into URL, then tap Save.")
            } else {
                Text("Start the proxy and connect this Mac to the same LAN to obtain a Setup URL.")
                Button("Refresh Address") { networkInfo = viewModel.currentLocalNetworkInfo() }
            }
            Text("The URL stays available while the proxy runs, even after closing this guide. Update it if the Mac’s IP address or proxy port changes. iOS may cache the configuration: after changing fallback mode, paste the new URL and save again. When finished, set Configure Proxy to Off.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Opening or downloading this file does not confirm routing or certificate trust. Use Verify Routing below and confirm the request came from your device.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func automaticProxyActions(url: URL) -> some View {
        Button("Copy Setup URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        .accessibilityIdentifier("iosProxyCopyPACURL")
        Button(showProxyQRCode ? "Hide QR Code" : "Show QR Code") { showProxyQRCode.toggle() }
            .accessibilityIdentifier("iosProxyPACQRCode")
            .accessibilityValue(showProxyQRCode ? "Visible" : "Hidden")
        Button("Refresh Address") { networkInfo = viewModel.currentLocalNetworkInfo() }
    }

    private var verifyStep: some View {
        walkthroughStepCard(4, "Verify Routing", status: deviceVerifyStatus) {
            Text(HelpDocumentation.text("setup-ios", section: "p11"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch viewModel.deviceVerifyResult {
            case .ready:
                VStack(alignment: .leading, spacing: 8) {
                    Button("Watch for Device Traffic") { viewModel.startDeviceVerify() }
                        .buttonStyle(.borderedProminent)
                    Text(HelpDocumentation.text("setup-ios", section: "p12"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .watching:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Watching for device traffic…")
                            .foregroundStyle(.secondary)
                    }
                    Text("Open Safari or any app on the device now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { viewModel.cancelDeviceVerify() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

            case .captured(let id):
                Label("Traffic captured — device is routing through JoesProxy.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("View in JoesProxy") {
                        viewModel.selectSessionFromUser(id)
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Test Again") { viewModel.startDeviceVerify() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }

            case .noTrafficDetected:
                VStack(alignment: .leading, spacing: 8) {
                    Label("No device traffic seen in 60 seconds.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(HelpDocumentation.text("setup-ios", section: "p13"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { viewModel.startDeviceVerify() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Collapsed sections

    private var limitationsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            bulletItem("Proxy applies only to Wi-Fi, not cellular data.")
            bulletItem("Some apps bypass the system proxy or use certificate pinning.")
            bulletItem("Banking, streaming, and pinned apps may not be capturable.")
            bulletItem("Safari and most URLSession-based apps typically work.")
        }
        .padding(.top, 4)
    }

    private var troubleshootingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            troubleshootingRow("Profile won't install", "Open Settings > Profile Downloaded or Settings > General > VPN & Device Management, then install the JoesProxy iOS Trust Profile there.")
            troubleshootingRow("Link just downloads a file / opens as text", "The QR code is encoded to force-open Safari even when it isn't the device's default browser — only Safari turns a tapped profile link into the install prompt. If it still opens elsewhere on your iOS version, use AirDrop above instead of the URL/QR code.")
            troubleshootingRow("HTTPS fails after install", "Go to Settings > General > About > Certificate Trust Settings and turn ON JoesProxy Root CA.")
            troubleshootingRow("No traffic in JoesProxy", "Re-check proxy settings; try Safari first.")
            troubleshootingRow("Cannot connect to server", serverTroubleshootingText)
            Button("Troubleshoot missing HTTPS bodies or traffic") { openHelpTopic(.trafficStates) }
                .buttonStyle(.link)
        }
        .padding(.top, 4)
    }

    // MARK: - QR code sheet

    private var qrCodeSheet: some View {
        VStack(spacing: 16) {
            Text("Scan to Install Certificate")
                .font(.headline)
            if let serverURL = viewModel.profileServerURL {
                QRCodeView(
                    urlString: Self.safariForcedURLString(for: serverURL),
                    displayURLString: serverURL.absoluteString,
                    size: 240
                )
                Text(HelpDocumentation.text("setup-ios", section: "p14"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            Button("Dismiss") { isQRCodePresented = false }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .padding(24)
    }

    /// Prefixes a plain `http(s)://` URL with iOS's `x-safari-` scheme
    /// (`x-safari-https://…`/`x-safari-http://…`), which iOS resolves by stripping the prefix and
    /// opening the remainder specifically in Safari.app — regardless of the device's default
    /// browser. `.mobileconfig` profile installation only ever triggers from Safari, so a QR code
    /// that lands in Chrome/Firefox/Edge just downloads an inert file instead of prompting install.
    /// Verify on-device: this is a real, long-standing iOS mechanism, but only Apple's Camera app's
    /// own QR-to-banner heuristics can confirm it recognizes this scheme the same way as bare
    /// `https://` links.
    static func safariForcedURLString(for url: URL) -> String {
        "x-safari-" + url.absoluteString
    }

    // MARK: - Prerequisite helpers

    private var proxyPrerequisiteStatus: WalkthroughStepStatus {
        switch viewModel.proxyState {
        case .running: return .done("Running")
        case .starting, .stopping: return .inProgress("Working…")
        case .stopped, .failed: return .attention("Not running")
        }
    }

    private var proxyPrerequisiteDetail: String {
        switch viewModel.proxyState {
        case .running(let port): return "JoesProxy is listening on port \(port)."
        case .starting(let port): return "JoesProxy is starting on port \(port)."
        case .stopping: return "JoesProxy is stopping."
        case .stopped: return "Start the proxy before configuring the device."
        case .failed(let message): return message
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

    private var serverInstructionText: String {
        switch (networkInfo.lanIP, networkInfo.bonjourName) {
        case let (ip?, bonjour?): return "Enter Server: \(ip) or \(bonjour)"
        case let (ip?, _): return "Enter Server: \(ip)"
        case let (_, bonjour?): return "Enter Server: \(bonjour)"
        default: return "Enter Server: your Mac's LAN IP (e.g., 192.168.1.5) or Bonjour name (e.g., MacBook-Pro.local)"
        }
    }

    private var serverTroubleshootingText: String {
        "Ensure JoesProxy binds to LAN, not only localhost."
    }

    // MARK: - Reusable rows

    private func prerequisiteRow(
        title: String,
        detail: String,
        status: WalkthroughStepStatus,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            walkthroughStepIcon(number: 0, status: status)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                walkthroughStepBadge(status)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
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

    // MARK: - Actions

    private func exportTrustProfile() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "mobileconfig") ?? .data]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "JoesProxy-iOS-Trust-Profile.mobileconfig"
        savePanel.title = "Export iPhone/iPad Trust Profile"
        savePanel.message = "Install this profile on the device, then manually trust the certificate in Certificate Trust Settings."

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else { return }

        do {
            try viewModel.exportIOSTrustProfile(to: destinationURL)
            lastExportedProfileURL = destinationURL
            exportAlert = ExportAlertContext(
                title: "Trust Profile Exported",
                message: "Saved \(destinationURL.lastPathComponent). Transfer it to the device, install it, then enable trust in Certificate Trust Settings."
            )
        } catch {
            exportAlert = ExportAlertContext(title: "Export Failed", message: error.localizedDescription)
        }
    }

    private func shareTrustProfile() {
        let shareURL: URL
        do {
            if let lastExportedProfileURL {
                shareURL = lastExportedProfileURL
            } else {
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("JoesProxy-iOS-Trust-Profile-\(UUID().uuidString)")
                    .appendingPathExtension("mobileconfig")
                try viewModel.exportIOSTrustProfile(to: temporaryURL)
                lastExportedProfileURL = temporaryURL
                shareURL = temporaryURL
            }
        } catch {
            exportAlert = ExportAlertContext(title: "Share Failed", message: error.localizedDescription)
            return
        }

        if let airDropService = NSSharingService(named: .sendViaAirDrop) {
            airDropService.perform(withItems: [shareURL])
            return
        }
        if let sharingService = NSSharingService(named: .composeEmail) {
            sharingService.perform(withItems: [shareURL])
            return
        }
        exportAlert = ExportAlertContext(
            title: "Share Unavailable",
            message: "No supported sharing service is available. Export the profile and transfer it manually."
        )
    }

    private func copyServerHost() {
        let host = networkInfo.lanIP ?? networkInfo.bonjourName ?? ""
        guard !host.isEmpty else {
            exportAlert = ExportAlertContext(
                title: "Copy Failed",
                message: "JoesProxy could not determine this Mac's LAN address yet."
            )
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(host, forType: .string)
        exportAlert = ExportAlertContext(title: "Host Copied", message: "Copied \(host) to the clipboard.")
    }

    private func copyProxyPort() {
        let port = String(viewModel.configuration.proxyPort)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(port, forType: .string)
        exportAlert = ExportAlertContext(title: "Port Copied", message: "Copied proxy port \(port) to the clipboard.")
    }

    private func openHelpTopic(_ topic: MainWindowHelpTopic) {
        isPresented = false
        presentationState.presentHelpHub(topic: topic)
    }
}

#Preview {
    iOSSetupWalkthroughView(
        isPresented: .constant(true),
        viewModel: AppCoordinator().viewModel
    )
}
