import SwiftUI

struct SimulatorSetupWalkthroughView: View {
    @State private var documentationLoaded = false
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: SimulatorSetupViewModel
    @ObservedObject var systemProxyController: SystemProxyController
    let isProxyRunning: Bool
    let startProxy: () -> Void

    @State private var stepCompletedAt: [Int: Date] = [:]

    // MARK: - Sidebar helpers

    private var isDeviceSelected: Bool { viewModel.selectedDevice?.isSelectable == true }

    private var selectedDeviceCertInstalled: Bool {
        guard let device = viewModel.selectedDevice else { return false }
        return viewModel.certInstallStatus(for: device) == .installed
    }

    private var isRoutingActive: Bool {
        if case .active = systemProxyController.status { return true }
        return false
    }

    private var isSimVerifyCaptured: Bool {
        if case .captured = viewModel.verificationResult { return true }
        return false
    }

    private var activeProxyAddress: String? {
        if case .active(let host, let port, _) = systemProxyController.status {
            return "\(host):\(port)"
        }
        return nil
    }

    private var sidebarSteps: [SidebarStep] {
        [
            SidebarStep(
                id: 1,
                icon: "iphone",
                title: "Simulator Selected",
                detail: viewModel.selectedDevice.map {
                    "\($0.name) · \($0.runtimeName ?? $0.runtimeIdentifier)"
                } ?? "Choose a booted simulator",
                state: isDeviceSelected ? .done(stepCompletedAt[1]) : .pending
            ),
            SidebarStep(
                id: 2,
                icon: "lock.shield.fill",
                title: "Root CA Installed",
                detail: selectedDeviceCertInstalled
                    ? "Certificate trusted in simulator"
                    : "Drag cert onto the simulator window",
                state: {
                    if selectedDeviceCertInstalled { return .done(stepCompletedAt[2]) }
                    if case .installing = viewModel.installState { return .inProgress("Installing…") }
                    return .pending
                }()
            ),
            SidebarStep(
                id: 3,
                icon: "globe",
                title: "Routing Active",
                detail: activeProxyAddress.map { "JoesProxy at \($0)" }
                    ?? "Enable system proxy in Step 3",
                state: {
                    if isRoutingActive { return .done(stepCompletedAt[3]) }
                    if viewModel.isSystemProxyRoutingEnabled {
                        return .inProgress(isProxyRunning ? "Activating…" : "Start the proxy")
                    }
                    return .pending
                }()
            ),
            SidebarStep(
                id: 4,
                icon: "antenna.radiowaves.left.and.right",
                title: "Traffic Verified",
                detail: isSimVerifyCaptured
                    ? "Request from simulator seen"
                    : "Run the routing test in Step 4",
                state: {
                    switch viewModel.verificationResult {
                    case .captured:              return .done(stepCompletedAt[4])
                    case .openingURL:            return .inProgress("Testing…")
                    case .noTrafficDetected,
                         .commandFailed:         return .attention("No traffic")
                    case .ready:                 return .pending
                    }
                }()
            )
        ]
    }

    // MARK: - Step status

    private var selectStatus: WalkthroughStepStatus {
        viewModel.selectedDevice?.isSelectable == true ? .done("Selected") : .todo
    }

    private var certStatus: WalkthroughStepStatus {
        if case .installing = viewModel.installState { return .inProgress("Installing…") }
        guard let device = viewModel.selectedDevice else { return .todo }
        switch viewModel.certInstallStatus(for: device) {
        case .installed: return .done("Installed")
        case .notInstalled: return .attention("Not installed")
        case .unknown, .none: return .todo
        }
    }

    private var routeStatus: WalkthroughStepStatus {
        switch systemProxyController.status {
        case .active: return .done("Active")
        case .failed: return .attention("Failed")
        case .inactive:
            if viewModel.isSystemProxyRoutingEnabled {
                return isProxyRunning ? .inProgress("Activating…") : .inProgress("Start proxy")
            }
            return .todo
        }
    }

    private var verifyStatus: WalkthroughStepStatus {
        switch viewModel.verificationResult {
        case .captured: return .done("Captured")
        case .openingURL: return .inProgress("Testing…")
        case .noTrafficDetected: return .attention("No traffic")
        case .commandFailed: return .attention("Command failed")
        case .ready: return .todo
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    simulatorSelectionSection
                    certificateSection
                    routingSection
                    verificationSection
                    limitationsSection
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("simulatorSetupGuide")

            Divider()

            SetupProgressSidebar(title: "Setup Status", steps: sidebarSteps)
                .frame(width: 210)
        }
        .alert("Route system proxy through JoesProxy?", isPresented: $viewModel.pendingRoutingConsent) {
            Button("Cancel", role: .cancel) { viewModel.cancelRoutingConsent() }
            Button("Enable") { viewModel.confirmRoutingConsent() }
        } message: {
            Text(viewModel.systemProxyConsentMessage)
        }
        .frame(minWidth: 780, maxWidth: .infinity, minHeight: 580, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 780, minHeight: 580)
        .opacity(documentationLoaded ? 1 : 0)
        .loadHelpDocumentation { documentationLoaded = true }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.refreshDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    isPresented = false
                }
            }
        }
        .onAppear {
            if case .idle = viewModel.discoveryState {
                viewModel.refreshDevices()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user drags the cert onto the Simulator (leaving JoesProxy), accepts the install,
            // then returns. There is no OS callback for the drop, so re-read the TrustStore whenever
            // JoesProxy regains focus to flip "not detected" → "installed".
            viewModel.refreshCertInstallStatuses()
        }
        .onChange(of: isDeviceSelected) { _, selected in
            if selected { stepCompletedAt[1] = stepCompletedAt[1] ?? Date() }
        }
        .onChange(of: selectedDeviceCertInstalled) { _, installed in
            if installed { stepCompletedAt[2] = stepCompletedAt[2] ?? Date() }
        }
        .onChange(of: isRoutingActive) { _, active in
            if active { stepCompletedAt[3] = stepCompletedAt[3] ?? Date() }
        }
        .onChange(of: isSimVerifyCaptured) { _, captured in
            if captured { stepCompletedAt[4] = stepCompletedAt[4] ?? Date() }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Simulator Setup")
                .font(.title)
                .fontWeight(.semibold)
            Text(HelpDocumentation.text("setup-simulator", section: "p1"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step card

    @ViewBuilder
    private func stepCard<Content: View>(
        _ number: Int,
        _ title: String,
        status: WalkthroughStepStatus,
        @ViewBuilder content: () -> Content
    ) -> some View {
        walkthroughStepCard(number, title, status: status, content: content)
    }

    // MARK: - Step 1: Select Simulator

    private var simulatorSelectionSection: some View {
        stepCard(1, "Select Simulator", status: selectStatus) {
            switch viewModel.discoveryState {
            case .idle, .loading:
                labelProgress("Loading simulators…")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    statusMessage(
                        title: SimulatorSetupViewModel.isSandboxError(message)
                            ? "Simulator discovery requires Terminal"
                            : "Simulator discovery failed",
                        detail: SimulatorSetupViewModel.isSandboxError(message)
                            ? "JoesProxy cannot run xcrun simctl inside the macOS App Sandbox. Run the list command in Terminal, then paste a booted simulator UDID below."
                            : message,
                        systemImage: "exclamationmark.triangle.fill"
                    )

                    if SimulatorSetupViewModel.isSandboxError(message) {
                        manualSimulatorSelectionSection
                    }
                }
            case .loaded:
                Toggle("Show booted simulators only", isOn: $viewModel.showBootedOnly)
                    .accessibilityIdentifier("simulatorSetupBootedOnlyToggle")

                if viewModel.devices.isEmpty {
                    statusMessage(
                        title: "No simulators found",
                        detail: "Open Xcode and install at least one iOS, tvOS, or visionOS simulator runtime, then refresh.",
                        systemImage: "iphone.slash"
                    )
                } else if viewModel.bootedFilterHidesDevices {
                    statusMessage(
                        title: "No booted simulators",
                        detail: "Boot a simulator (open it in Xcode or Simulator.app), or turn off \"Show booted simulators only\" to pick one to boot.",
                        systemImage: "iphone.slash"
                    )
                } else {
                    ForEach(viewModel.devicesByPlatform, id: \.platform) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.platform.title)
                                .font(.headline)
                            ForEach(group.devices) { device in
                                simulatorRow(device)
                            }
                        }
                    }
                }
            }
        }
    }

    private var manualSimulatorSelectionSection: some View {
        DisclosureGroup("Select manually by UDID") {
            VStack(alignment: .leading, spacing: 10) {
                Text(HelpDocumentation.text("setup-simulator", section: "p2"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                copyableTextRow(
                    title: "List simulators",
                    value: viewModel.simulatorListCommandText,
                    copyIdentifier: "simulatorSetupListDevicesCopyButton"
                )

                HStack(spacing: 8) {
                    TextField("Simulator UDID", text: $viewModel.manualSimulatorUDID)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("simulatorSetupManualUDIDField")

                    Button {
                        viewModel.selectManualSimulator()
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("simulatorSetupSelectManualUDIDButton")
                }

                if let error = viewModel.manualSimulatorSelectionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("simulatorSetupManualUDIDError")
                }

                if let selectedDevice = viewModel.selectedDevice {
                    Label("Selected \(selectedDevice.udid)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("simulatorSetupManualUDIDSelected")
                }
            }
            .padding(.top, 4)
        }
        .accessibilityIdentifier("simulatorSetupManualUDIDDisclosure")
    }

    private func simulatorRow(_ device: SimulatorDevice) -> some View {
        Button {
            guard device.isSelectable else { return }
            viewModel.selectedDeviceID = device.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: viewModel.selectedDeviceID == device.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewModel.selectedDeviceID == device.id ? .blue : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(device.name)
                            .fontWeight(.medium)
                        Text(device.state)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(device.runtimeName ?? device.runtimeIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("\(device.supportTier.title): \(device.supportTier.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !device.availability.isAvailable {
                        Text(device.availability.displayText)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                certInstallIcon(for: device)
            }
            .padding(8)
            .background(rowBackground(for: device))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!device.isSelectable)
        .accessibilityIdentifier("simulatorSetupDeviceRow-\(device.udid)")
    }

    /// Compact, icon-only cert indicator on each device row. The worded, authoritative status for
    /// the selected simulator lives in Step 2 to avoid duplication.
    @ViewBuilder
    private func certInstallIcon(for device: SimulatorDevice) -> some View {
        if device.isBooted, let status = viewModel.certInstallStatus(for: device) {
            switch status {
            case .installed:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .help("JoesProxy Root CA installed in this simulator")
            case .notInstalled:
                Image(systemName: "seal")
                    .foregroundStyle(.orange)
                    .help("JoesProxy Root CA not detected in this simulator")
            case .unknown:
                EmptyView()
            }
        }
    }

    private func rowBackground(for device: SimulatorDevice) -> Color {
        if viewModel.selectedDeviceID == device.id {
            return Color.accentColor.opacity(0.12)
        }
        return Color.secondary.opacity(0.08)
    }

    // MARK: - Step 2: Install Root CA

    private var certificateSection: some View {
        stepCard(2, "Install Root CA", status: certStatus) {
            Text(HelpDocumentation.text("setup-simulator", section: "p3"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            certificateDragRow

            selectedCertStatusRow

            Label {
                Text(viewModel.rootCertificateExpiryDescription)
            } icon: {
                Image(systemName: "calendar.badge.clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("simulatorSetupRootCAExpiry")

            DisclosureGroup("Install manually (Terminal)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(HelpDocumentation.text("setup-simulator", section: "p4"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    commandBlock(viewModel.installCommandText)

                    HStack {
                        Button {
                            viewModel.installCertificateInSelectedSimulator()
                        } label: {
                            Label("Install CA in Selected Simulator", systemImage: "key.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.canInstallCertificate)

                        if let command = viewModel.installCommandText {
                            copyButton(command)
                        }
                    }

                    installStatusView

                    Text(HelpDocumentation.text("setup-simulator", section: "p5"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .accessibilityIdentifier("simulatorSetupManualInstallDisclosure")
        }
    }

    private var certificateDragRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("JoesProxy Root CA.cer")
                    .fontWeight(.medium)
                Text("Drag to Simulator")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "hand.draw")
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onDrag {
            viewModel.logCertificateDragInitiated()
            if let url = viewModel.rootCertificateDragURL() {
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
            return NSItemProvider()
        }
        .help("Drag onto a booted Simulator window to install the root certificate")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("JoesProxy Root CA certificate, draggable to Simulator")
        .accessibilityIdentifier("simulatorSetupCertificateDragIcon")
    }

    private var selectedCertStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            selectedCertStatusLabel
            Spacer()
            Button {
                viewModel.refreshCertInstallStatuses()
            } label: {
                Label("Recheck", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Re-read the simulator trust store to update the install status.")
            .accessibilityIdentifier("simulatorSetupRecheckCertButton")
        }
    }

    @ViewBuilder
    private var selectedCertStatusLabel: some View {
        if case .installing = viewModel.installState {
            labelProgress("Installing certificate…")
        } else if let device = viewModel.selectedDevice {
            switch viewModel.certInstallStatus(for: device) {
            case .installed:
                Label("\(device.name): Root CA installed", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .notInstalled:
                Label("\(device.name): Root CA not detected — drag the certificate above", systemImage: "seal")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .unknown, .none:
                if device.isBooted {
                    Label("\(device.name): checking trust status…", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Boot the selected simulator to check its trust status.")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Select a simulator in Step 1.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var installStatusView: some View {
        switch viewModel.installState {
        case .idle, .installing:
            EmptyView()
        case .succeeded(let result):
            statusMessage(title: "Certificate install command completed", detail: result.commandText, systemImage: "checkmark.circle.fill")
        case .failed(let message, let fallbackCommand):
            VStack(alignment: .leading, spacing: 8) {
                statusMessage(
                    title: SimulatorSetupViewModel.isSandboxError(message)
                        ? "Certificate install requires Terminal"
                        : "Certificate install failed",
                    detail: SimulatorSetupViewModel.isSandboxError(message)
                        ? "JoesProxy cannot run xcrun simctl inside the macOS App Sandbox. Copy the command above and run it in Terminal."
                        : message,
                    systemImage: "exclamationmark.triangle.fill"
                )
                if let fallbackCommand {
                    commandBlock(fallbackCommand.commandText)
                }
            }
        }
    }

    // MARK: - Step 3: Route Traffic

    private var routingSection: some View {
        stepCard(3, "Route Traffic Through JoesProxy", status: routeStatus) {
            Text(HelpDocumentation.text("setup-simulator", section: "p6"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Route macOS system proxy through JoesProxy while capturing", isOn: $viewModel.isSystemProxyRoutingEnabled)
                .accessibilityIdentifier("simulatorSetupSystemProxyToggle")

            Text(viewModel.isSystemProxyStrictCapture ? Self.strictCaption : Self.failOpenCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            systemProxyStatusRow

            DisclosureGroup("Configure manually") {
                VStack(alignment: .leading, spacing: 8) {
                    instructionStep(1, "Open System Settings > Network > your connection > Details > Proxies.")
                    instructionStep(2, "Enable Web Proxy (HTTP) and Secure Web Proxy (HTTPS).")
                    instructionStep(3, "Use server 127.0.0.1 and port \(viewModel.proxyPort) for both proxy entries.")
                    instructionStep(4, "Restart Simulator if it was already running before proxy settings changed.")
                }
                .padding(.top, 4)
            }
            .accessibilityIdentifier("simulatorSetupManualRoutingDisclosure")
        }
    }

    private static let failOpenCaption = "Fails open: if JoesProxy stops unexpectedly, traffic falls back to a direct connection so your network keeps working."
    private static let strictCaption = "Strict capture: if JoesProxy stops unexpectedly, internet won't work until you reopen JoesProxy or turn the proxy off in System Settings."

    @ViewBuilder
    private var systemProxyStatusRow: some View {
        switch systemProxyController.status {
        case .active(let host, let port, _):
            VStack(alignment: .leading, spacing: 6) {
                statusMessage(
                    title: "Routing active",
                    detail: "macOS and Simulator traffic now route through JoesProxy at \(host):\(port).",
                    systemImage: "checkmark.circle.fill"
                )
                Text(HelpDocumentation.text("setup-simulator", section: "p7"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            statusMessage(
                title: "Couldn't change the system proxy",
                detail: message,
                systemImage: "exclamationmark.triangle.fill"
            )
        case .inactive:
            if viewModel.isSystemProxyRoutingEnabled {
                if isProxyRunning {
                    labelProgress("Activating routing…")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Routing is armed. Start the proxy to activate it.")
                            .foregroundStyle(.secondary)
                        Button {
                            startProxy()
                        } label: {
                            Label("Start Proxy", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("simulatorSetupStartProxyButton")
                    }
                }
            } else {
                Text(HelpDocumentation.text("setup-simulator", section: "p8"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Step 4: Verify

    private var verificationSection: some View {
        stepCard(4, "Verify Routing", status: verifyStatus) {
            Text(HelpDocumentation.text("setup-simulator", section: "p9"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                viewModel.verifySelectedSimulatorRouting()
            } label: {
                Label("Run Routing Test", systemImage: "checkmark.seal")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canVerifyRouting)

            verificationStatusView

            DisclosureGroup("Test manually") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(HelpDocumentation.text("setup-simulator", section: "p10"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    copyableTextRow(title: "Test URL", value: viewModel.verificationURLString, copyIdentifier: "simulatorSetupVerificationURLCopyButton")

                    commandBlock(viewModel.verificationCommandText)
                    if let command = viewModel.verificationCommandText {
                        copyButton(command)
                    }
                }
                .padding(.top, 4)
            }
            .accessibilityIdentifier("simulatorSetupManualVerifyDisclosure")
        }
    }

    @ViewBuilder
    private var verificationStatusView: some View {
        switch viewModel.verificationResult {
        case .ready:
            EmptyView()
        case .openingURL:
            labelProgress("Opening the test page and watching for traffic…")
        case .captured:
            statusMessage(title: "Captured", detail: "JoesProxy saw the Simulator's request to captive.apple.com.", systemImage: "checkmark.circle.fill")
        case .noTrafficDetected:
            statusMessage(
                title: "No traffic detected yet",
                detail: "A Simulator that was already running may need a few seconds or a restart to route through JoesProxy. Confirm Step 3 shows Active, then run the test again.",
                systemImage: "exclamationmark.triangle.fill"
            )
        case .commandFailed(let message):
            statusMessage(
                title: SimulatorSetupViewModel.isSandboxError(message)
                    ? "Routing verification requires Terminal"
                    : "Command failed",
                detail: SimulatorSetupViewModel.isSandboxError(message)
                    ? "JoesProxy cannot open a URL in the simulator inside the macOS App Sandbox. Use the manual test below to trigger the verification request."
                    : message,
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    // MARK: - Limitations

    private var limitationsSection: some View {
        DisclosureGroup("Limitations") {
            VStack(alignment: .leading, spacing: 8) {
                bulletItem("This verifies HTTP routing; HTTPS inspection is a separate check.")
                bulletItem("Apps with certificate pinning or custom networking may bypass proxy inspection.")
                bulletItem("tvOS and visionOS simulator behavior should be verified on the specific runtime.")
            }
            .padding(.top, 4)
        }
        .accessibilityIdentifier("simulatorSetupLimitationsDisclosure")
    }

    // MARK: - Shared building blocks

    private func labelProgress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    private func copyableTextRow(title: String, value: String, copyIdentifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 8)

                Button("Copy") {
                    viewModel.copyToPasteboard(value)
                }
                .controlSize(.small)
                .accessibilityLabel("Copy \(title)")
                .accessibilityIdentifier(copyIdentifier)
            }

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func commandBlock(_ command: String?) -> some View {
        Text(command ?? "Select a simulator to show the command.")
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            viewModel.copyToPasteboard(text)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .help("Copy command")
    }

    private func statusMessage(title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(systemImage == "checkmark.circle.fill" ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
