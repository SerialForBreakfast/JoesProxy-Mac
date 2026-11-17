import SwiftUI
import UniformTypeIdentifiers

/// Common setup destination for capture, certificate repair, devices and agent connections.
struct GuidedSetupRepairView: View {
    @Environment(\.appTextScale) private var appTextScale
    @Binding var isPresented: Bool
    let context: GuidedSetupContext
    @ObservedObject var certificateModel: ProxyViewModel
    let accessChecklist: SetupAccessChecklist
    let setupChecklistItems: [ProxyViewModel.GuidedSetupChecklistItem]
    let openMacOSGuide: () -> Void
    let openIOSGuide: () -> Void
    let openTVOSGuide: () -> Void
    let exportSkill: () -> Void
    let openHelpTopic: (MainWindowHelpTopic) -> Void
    let startProxy: () -> Void
    let runSetupVerification: () -> Void
    let retryStatusValidation: () -> Void
    let resetCertificateState: () -> Void
    let captureSetupNetworkSnapshot: () -> Void
    @Binding var profileHostStrategy: ProfileHostStrategy
    @Binding var manualProfileHost: String
    let profileHostResolution: ProfileHostResolution
    let latestProfileSnapshot: GeneratedProfileSnapshot?
    let profileSnapshotDiagnosis: ProfileSnapshotDiagnosis
    let currentCertificateFingerprint: String?
    let currentProxyPort: UInt16
    let profileServerURL: URL?
    let exportIOSTrustProfile: (URL) throws -> Void
    let exportTVOSManagedProfile: (URL) throws -> Void
    let copyProfileValue: (String) -> Void
    let certificateIdentity: CAInstanceMetadata?
    let certificateIdentityStatus: CertificateIdentityStatus?
    let adoptLegacyCertificateIdentity: () -> Void
    let updateCertificateIdentityNickname: (String) -> Void
    let copyCertificateFingerprint: () -> Void
    let copyCertificateShortCode: () -> Void

    @State private var selectedSection: GuidedSetupSection
    @State private var devicePlatform = "iOS"
    @State private var openingSize: CGSize
    @State private var profileActionMessage: String?

    init(
        isPresented: Binding<Bool>,
        context: GuidedSetupContext,
        certificateModel: ProxyViewModel,
        accessChecklist: SetupAccessChecklist,
        setupChecklistItems: [ProxyViewModel.GuidedSetupChecklistItem],
        openMacOSGuide: @escaping () -> Void,
        openIOSGuide: @escaping () -> Void,
        openTVOSGuide: @escaping () -> Void,
        exportSkill: @escaping () -> Void,
        openHelpTopic: @escaping (MainWindowHelpTopic) -> Void,
        startProxy: @escaping () -> Void,
        runSetupVerification: @escaping () -> Void,
        retryStatusValidation: @escaping () -> Void,
        resetCertificateState: @escaping () -> Void,
        captureSetupNetworkSnapshot: @escaping () -> Void,
        profileHostStrategy: Binding<ProfileHostStrategy>,
        manualProfileHost: Binding<String>,
        profileHostResolution: ProfileHostResolution,
        latestProfileSnapshot: GeneratedProfileSnapshot?,
        profileSnapshotDiagnosis: ProfileSnapshotDiagnosis,
        currentCertificateFingerprint: String?,
        currentProxyPort: UInt16,
        profileServerURL: URL?,
        exportIOSTrustProfile: @escaping (URL) throws -> Void,
        exportTVOSManagedProfile: @escaping (URL) throws -> Void,
        copyProfileValue: @escaping (String) -> Void,
        certificateIdentity: CAInstanceMetadata?,
        certificateIdentityStatus: CertificateIdentityStatus?,
        adoptLegacyCertificateIdentity: @escaping () -> Void,
        updateCertificateIdentityNickname: @escaping (String) -> Void,
        copyCertificateFingerprint: @escaping () -> Void,
        copyCertificateShortCode: @escaping () -> Void
    ) {
        _isPresented = isPresented
        self.context = context
        self.certificateModel = certificateModel
        self.accessChecklist = accessChecklist
        self.setupChecklistItems = setupChecklistItems
        self.openMacOSGuide = openMacOSGuide
        self.openIOSGuide = openIOSGuide
        self.openTVOSGuide = openTVOSGuide
        self.exportSkill = exportSkill
        self.openHelpTopic = openHelpTopic
        self.startProxy = startProxy
        self.runSetupVerification = runSetupVerification
        self.retryStatusValidation = retryStatusValidation
        self.resetCertificateState = resetCertificateState
        self.captureSetupNetworkSnapshot = captureSetupNetworkSnapshot
        _profileHostStrategy = profileHostStrategy
        _manualProfileHost = manualProfileHost
        self.profileHostResolution = profileHostResolution
        self.latestProfileSnapshot = latestProfileSnapshot
        self.profileSnapshotDiagnosis = profileSnapshotDiagnosis
        self.currentCertificateFingerprint = currentCertificateFingerprint
        self.currentProxyPort = currentProxyPort
        self.profileServerURL = profileServerURL
        self.exportIOSTrustProfile = exportIOSTrustProfile
        self.exportTVOSManagedProfile = exportTVOSManagedProfile
        self.copyProfileValue = copyProfileValue
        self.certificateIdentity = certificateIdentity
        self.certificateIdentityStatus = certificateIdentityStatus
        self.adoptLegacyCertificateIdentity = adoptLegacyCertificateIdentity
        self.updateCertificateIdentityNickname = updateCertificateIdentityNickname
        self.copyCertificateFingerprint = copyCertificateFingerprint
        self.copyCertificateShortCode = copyCertificateShortCode
        _selectedSection = State(initialValue: context.section)
        let parent = NSApp.keyWindow
        let visible = (parent?.screen ?? NSScreen.main)?.visibleFrame
        let top = min(parent?.frame.maxY ?? .infinity, visible?.maxY ?? .infinity)
        let availableHeight = visible.map { top - $0.minY - 64 } ?? 800
        _openingSize = State(initialValue: CGSize(
            width: max(360, min(960, (visible?.width ?? 1008) - 48)),
            height: max(300, min(800, availableHeight))
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ViewThatFits(in: .horizontal) {
                topicPicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                topicPicker.pickerStyle(.menu)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 360, idealWidth: openingSize.width, maxWidth: .infinity,
               minHeight: 300, idealHeight: openingSize.height, maxHeight: .infinity)
        #if DEBUG
        .frame(width: compactFixture ? 400 : nil, height: compactFixture ? 320 : nil)
        .frame(width: SetupPageScreenshotFixture.isEnabled ? 800 : nil,
               height: SetupPageScreenshotFixture.isEnabled ? (context.section == .mcpCLI ? 720 : 560) : nil)
        #endif
        .joesProxyResizableWorkspaceSheet(minWidth: 360, minHeight: 300)
        .presentationSizing(.fitted)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guidedSetupRepairView")
        #if DEBUG
        .background {
            if SetupPageScreenshotFixture.isEnabled {
                SetupPageScreenshotFixture(section: selectedSection)
            }
        }
        #endif
        .onAppear(perform: captureSetupNetworkSnapshot)
        .certificateTrustAlert(certificateModel)
    }

    #if DEBUG
    private var compactFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-compact-setup-sheet")
    }
    #endif

    private var topicPicker: some View {
        Picker("Setup section", selection: $selectedSection) {
            ForEach(GuidedSetupSection.allCases) { section in
                Text(section.title).tag(section)
            }
        }
        .labelsHidden()
        .accessibilityIdentifier("guidedSetupSectionPicker")
    }

    private var footer: some View {
        let pages = GuidedSetupSection.allCases
        let index = pages.firstIndex(of: selectedSection) ?? 0
        let finishes = selectedSection == .verifyCapture || selectedSection == .mcpCLI
        let nextTitle = finishes ? "Finish setup" : pages[index + 1].title
        return SetupNavigationFooter(nextTitle: nextTitle, finishes: finishes,
            back: index == 0 ? nil : { selectedSection = pages[index - 1] },
            close: { isPresented = false },
            next: {
                if finishes { isPresented = false } else { selectedSection = pages[index + 1] }
            })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerTitle)
                .appFont(.title2, scale: appTextScale, weight: .semibold)

        }
    }

    private var headerTitle: String {
        switch context.mode {
        case .firstRun:
            return "Guided Setup"
        case .replay:
            return "Guided Setup & Repair"
        case .repair:
            return "Repair HTTPS Setup"
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .certificate:
            sectionCard(title: "Set up HTTPS on this Mac", summary: "For HTTP only, continue to Proxy.") {
                CertificateApprovalChecklist(model: certificateModel)
                if case .repair(let state) = context.mode { repairStatusCard(for: state) }
                DisclosureGroup("Advanced certificate settings") {
                    AdvancedCertificateControls(viewModel: certificateModel)
                }
                DisclosureGroup("Diagnostics & repair") {
                    setupChecklist
                }
            }
        case .proxy:
            sectionCard(title: "Start the proxy", summary: "Choose a port, save any changes, then start listening.") {
                accessChecklist.scoped(to: .proxy)
                Divider()
                SetupStep("Start the listener", listenerStatus)
                if case .running(let port) = certificateModel.proxyState {
                    Text("Listening on port \(String(port))")
                } else {
                    Button("Start proxy", action: startProxy).buttonStyle(.borderedProminent)
                        .disabled(!certificateModel.canStartProxy)
                }
            }
        case .verifyCapture:
            sectionCard(title: "Verify a live request", summary: "Send a test request to example.org through this proxy. A trusted certificate also enables the HTTPS inspection check.") {
                SetupLiveChecks(model: certificateModel)
                SetupCaptureHistory(viewModel: certificateModel, openHelpTopic: openHelpTopic)
                Divider()
                Text("Finished on this Mac? Choose Finish setup. Devices and MCP/CLI are optional.").font(.callout)
                Button("Connect a device instead") { selectedSection = .devices }
            }
        case .devices:
            sectionCard(title: "Connect a device (optional)", summary: "Skip this page if you only capture traffic on this Mac.") {
                Picker("Platform", selection: $devicePlatform) {
                    ForEach(["iOS", "macOS", "Apple TV"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                SetupStep("Proxy listener on this Mac", listenerStatus)
                SetupStep("1. Set the device proxy", .manual)
                LabeledContent("Host", value: profileHostResolution.host)
                LabeledContent("Port", value: String(currentProxyPort))
                SetupStep("2. Install and trust the root on the device", .manual)
                actionButton("\(devicePlatform) Setup Guide") {
                    performChecklistAction(devicePlatform == "iOS" ? .openIOSGuide : devicePlatform == "macOS" ? .openMacOSGuide : .openTVOSGuide)
                }
                DisclosureGroup {
                    setupChecklist
                } label: {
                    SetupStep("3. Check device traffic", .manual)
                }
                DisclosureGroup("Profiles and connection details") { profileMaintenanceCard }
            }
        case .mcpCLI:
            sectionCard(title: "Connect a command-line client (optional)", summary: "Skip this page if you only use the app.") {
                accessChecklist.scoped(to: .client)
                Button("Export MCP Skill…", action: exportSkill)
                    .accessibilityIdentifier("guidedSetupExportSkillButton")
            }
        }
    }

    private func repairStatusCard(for blockingState: GuidedSetupBlockingState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(blockingState.title, systemImage: "exclamationmark.triangle.fill")
                .appFont(.headline, scale: appTextScale, weight: .semibold)
                .foregroundStyle(.red)

            Text(blockingState.message)
                .appFont(.body, scale: appTextScale)
                .fixedSize(horizontal: false, vertical: true)

            repairActions(for: blockingState)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.yellow.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func repairActions(for blockingState: GuidedSetupBlockingState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            actionButton("Retry Status Check", action: retryStatusValidation)

            if blockingState == .needsCleanup {
                Button("Reset Certificate State…", action: {
                    resetCertificateState()
                })
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Button(blockingState == .needsCleanup ? "Why cleanup is required" : "Why trust is required") {
                openHelpTopic(.certificateSetup)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("guidedSetupRepairTrustHelpButton")
        }
    }

    private var listenerStatus: SetupStep.Status {
        switch certificateModel.proxyState {
        case .running: .complete
        case .starting, .stopping: .working
        case .stopped: .pending
        case .failed: .needsAttention
        }
    }

    private var profileMaintenanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Profiles & Certificates")
                    .appFont(.headline, scale: appTextScale, weight: .semibold)
                Spacer()
                Label(profileSnapshotDiagnosis.health.title, systemImage: profileStatusIconName)
                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                    .foregroundStyle(profileStatusColor)
            }

            Text(profileSnapshotDiagnosis.message)
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Picker("Profile host", selection: $profileHostStrategy) {
                    ForEach(ProfileHostStrategy.allCases) { strategy in
                        Text(strategy.title)
                            .tag(strategy)
                            .help(strategy.detail)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("profileHostStrategyPicker")

                if profileHostStrategy == .manualHost {
                    TextField("Manual host", text: $manualProfileHost)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("manualProfileHostField")
                }
            }

            profileMetadataGrid

            CertificateIdentityCard(
                needsUnlock: certificateModel.certificateAuthorityNeedsUnlock,
                metadata: certificateIdentity,
                identityStatus: certificateIdentityStatus,
                fingerprint: currentCertificateFingerprint,
                serialNumber: certificateIdentity?.certificateSerialNumber,
                notBefore: certificateIdentity?.notBefore,
                notAfter: certificateIdentity?.notAfter,
                appTextScale: appTextScale,
                onCopyFingerprint: {
                    copyCertificateFingerprint()
                    profileActionMessage = "Copied fingerprint."
                },
                onCopyShortCode: {
                    copyCertificateShortCode()
                    profileActionMessage = "Copied short code."
                },
                onAdoptLegacy: certificateIdentityStatus == .legacyIdentityUnknown
                    ? { adoptLegacyCertificateIdentity() }
                    : nil,
                onNicknameChange: certificateIdentity != nil
                    ? { updateCertificateIdentityNickname($0) }
                    : nil
            )

            HStack(spacing: 8) {
                Button("Copy Host") {
                    copyProfileValue(profileHostResolution.host)
                    profileActionMessage = "Copied host."
                }
                .buttonStyle(.bordered)

                Button("Copy Port") {
                    copyProfileValue(String(currentProxyPort))
                    profileActionMessage = "Copied port."
                }
                .buttonStyle(.bordered)

                if let profileServerURL {
                    Button("Copy Profile URL") {
                        copyProfileValue(profileServerURL.absoluteString)
                        profileActionMessage = "Copied profile URL."
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 8) {
                Button("Export iOS Profile…") {
                    exportProfile(kind: .iosTrustProfile)
                }
                .buttonStyle(.bordered)

                Button("Export Apple TV Profile…") {
                    exportProfile(kind: .tvOSManagedProxyProfile)
                }
                .buttonStyle(.bordered)

                Button("Repair Certificate…") {
                    selectedSection = .certificate
                }
                .buttonStyle(.bordered)
            }

            DisclosureGroup("Removal limits") {
                Text("JoesProxy can diagnose stale unmanaged profiles, but iOS and Apple TV profiles must be removed or replaced on the device unless they were installed through a managed path.")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            if let profileActionMessage {
                Text(profileActionMessage)
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profileMaintenanceActionMessage")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profileMaintenanceCard")
    }

    private var profileMetadataGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            profileMetadataRow("Resolved host", profileHostResolution.host)
            profileMetadataRow("Proxy port", String(currentProxyPort))
            profileMetadataRow("Certificate", currentCertificateFingerprint?.prefix(12).description ?? "Not available")
            if let latestProfileSnapshot {
                profileMetadataRow("Latest profile", latestProfileSnapshot.kind.title)
                profileMetadataRow("Generated", latestProfileSnapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))
            } else {
                profileMetadataRow("Latest profile", "None")
            }
        }
        .appFont(.caption, scale: appTextScale)
    }

    private func profileMetadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var profileStatusIconName: String {
        profileSnapshotDiagnosis.health.isStale ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var profileStatusColor: Color {
        latestProfileSnapshot == nil ? .secondary : (profileSnapshotDiagnosis.health.isStale ? .red : .green)
    }

    private func exportProfile(kind: GeneratedProfileKind) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mobileconfig") ?? .data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = kind == .iosTrustProfile
            ? "JoesProxy-iOS-Trust-Profile.mobileconfig"
            : "JoesProxy-AppleTV.mobileconfig"
        panel.message = "Save the profile, then install or replace it on the target device."
        guard panel.runModal() == .OK, let url = panel.url else {
            profileActionMessage = "Export canceled."
            return
        }

        do {
            switch kind {
            case .iosTrustProfile:
                try exportIOSTrustProfile(url)
            case .tvOSManagedProxyProfile:
                try exportTVOSManagedProfile(url)
            }
            profileActionMessage = "Saved \(url.lastPathComponent)."
        } catch {
            profileActionMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private var setupChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup status")
                .appFont(.headline, scale: appTextScale, weight: .semibold)

            ForEach(setupChecklistItems.filter { section(for: $0) == selectedSection }) { item in
                setupChecklistRow(item)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setupChecklistView")
    }

    private func setupChecklistRow(_ item: ProxyViewModel.GuidedSetupChecklistItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    if let action = item.primaryAction {
                        performChecklistAction(action)
                    } else {
                        selectedSection = section(for: item)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: setupStatusSymbolName(for: item.state))
                            .foregroundStyle(setupStatusColor(for: item.state))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .appFont(.body, scale: appTextScale, weight: .semibold)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(item.detail)
                                .appFont(.caption, scale: appTextScale)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .layoutPriority(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .layoutPriority(1)

                if let actionTitle = item.primaryActionTitle,
                   let action = item.primaryAction {
                    Button {
                        performChecklistAction(action)
                    } label: {
                        Label(actionTitle, systemImage: checklistActionIconName(for: action))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minWidth: 30)
                    .help(actionTitle)
                    .accessibilityLabel(actionTitle)
                    .accessibilityHint("\(item.title). \(item.detail)")
                }
            }

            if let secondaryActionTitle = item.secondaryActionTitle,
               let secondaryAction = item.secondaryAction {
                Button(secondaryActionTitle) {
                    performChecklistAction(secondaryAction)
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(item.accessibilityIdentifier)
        .accessibilityLabel("\(item.title). \(setupStatusText(for: item.state)). \(item.detail)")
    }

    private func checklistActionIconName(for action: ProxyViewModel.GuidedSetupChecklistItem.Action) -> String {
        switch action {
        case .openCertificateSetup:
            return "checkmark.shield"
        case .openMacOSGuide, .openIOSGuide, .openTVOSGuide, .openTrafficHelp:
            return "book"
        case .startProxy:
            return "play.fill"
        case .verifyCapture, .retryStatusValidation, .refreshDeviceStatus:
            return "arrow.clockwise"
        case .resetCertificateState:
            return "trash"
        }
    }

    private func setupStatusSymbolName(for state: ProxyViewModel.GuidedSetupChecklistItem.State) -> String {
        switch state {
        case .complete:
            return "checkmark.circle.fill"
        case .needsAction:
            return "exclamationmark.triangle.fill"
        case .waiting:
            return "clock.fill"
        case .warning:
            return "exclamationmark.circle.fill"
        case .stale:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .neutral:
            return "circle.dashed"
        }
    }

    private func setupStatusColor(for state: ProxyViewModel.GuidedSetupChecklistItem.State) -> Color {
        switch state {
        case .complete:
            return .green
        case .needsAction, .warning, .stale:
            return .red
        case .waiting, .neutral:
            return .secondary
        }
    }

    private func setupStatusText(for state: ProxyViewModel.GuidedSetupChecklistItem.State) -> String {
        switch state {
        case .complete:
            return "Complete"
        case .needsAction:
            return "Needs action"
        case .waiting:
            return "Waiting"
        case .warning:
            return "Warning"
        case .neutral:
            return "Not verified yet"
        case .stale:
            return "Stale"
        }
    }

    private func sectionCard<Content: View>(
        title: String,
        summary: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .appFont(.title3, scale: appTextScale, weight: .semibold)

            Text(summary)
                .appFont(.body, scale: appTextScale)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func performChecklistAction(_ action: ProxyViewModel.GuidedSetupChecklistItem.Action) {
        switch action {
        case .openCertificateSetup:
            selectedSection = .certificate
        case .openMacOSGuide:
            isPresented = false
            captureSetupNetworkSnapshot()
            openMacOSGuide()
        case .openIOSGuide:
            isPresented = false
            captureSetupNetworkSnapshot()
            openIOSGuide()
        case .openTVOSGuide:
            isPresented = false
            captureSetupNetworkSnapshot()
            openTVOSGuide()
        case .openTrafficHelp:
            openHelpTopic(.trafficStates)
        case .startProxy:
            startProxy()
        case .verifyCapture:
            selectedSection = .verifyCapture
        case .refreshDeviceStatus:
            captureSetupNetworkSnapshot()
        case .retryStatusValidation:
            retryStatusValidation()
        case .resetCertificateState:
            resetCertificateState()
        }
    }

    private func section(for item: ProxyViewModel.GuidedSetupChecklistItem) -> GuidedSetupSection {
        switch item.id {
        case "proxy": return .proxy
        case "traffic", "verification": return .verifyCapture
        case "device": return .devices
        default: return .certificate
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}
