import SwiftUI
import UniformTypeIdentifiers

/// Repair and Help-menu replay for HTTPS setup. First-run no longer uses this sheet (BA-3);
/// use ``FirstRunPathChoiceView`` and ``InspectorSetupCompanionView`` instead.
struct GuidedSetupRepairView: View {
    @Environment(\.appTextScale) private var appTextScale
    @Binding var isPresented: Bool
    let context: GuidedSetupContext
    let setupChecklistItems: [ProxyViewModel.GuidedSetupChecklistItem]
    let nextSetupActionItem: ProxyViewModel.GuidedSetupChecklistItem?
    let certificateSetupTitle: String
    let openCertificateSetup: () -> Void
    let openMacOSGuide: () -> Void
    let openIOSGuide: () -> Void
    let openTVOSGuide: () -> Void
    let exportSkill: () -> Void
    let openHelpTopic: (MainWindowHelpTopic) -> Void
    let openHelpHub: () -> Void
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
    @State private var profileActionMessage: String?

    init(
        isPresented: Binding<Bool>,
        context: GuidedSetupContext,
        setupChecklistItems: [ProxyViewModel.GuidedSetupChecklistItem],
        nextSetupActionItem: ProxyViewModel.GuidedSetupChecklistItem?,
        certificateSetupTitle: String,
        openCertificateSetup: @escaping () -> Void,
        openMacOSGuide: @escaping () -> Void,
        openIOSGuide: @escaping () -> Void,
        openTVOSGuide: @escaping () -> Void,
        exportSkill: @escaping () -> Void,
        openHelpTopic: @escaping (MainWindowHelpTopic) -> Void,
        openHelpHub: @escaping () -> Void,
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
        self.setupChecklistItems = setupChecklistItems
        self.nextSetupActionItem = nextSetupActionItem
        self.certificateSetupTitle = certificateSetupTitle
        self.openCertificateSetup = openCertificateSetup
        self.openMacOSGuide = openMacOSGuide
        self.openIOSGuide = openIOSGuide
        self.openTVOSGuide = openTVOSGuide
        self.exportSkill = exportSkill
        self.openHelpTopic = openHelpTopic
        self.openHelpHub = openHelpHub
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("Setup section", selection: $selectedSection) {
                ForEach(GuidedSetupSection.allCases) { section in
                    Text(section.compactTitle)
                        .help(section.title)
                        .accessibilityLabel(section.title)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("guidedSetupSectionPicker")

            if case .repair(let blockingState) = context.mode {
                repairStatusCard(for: blockingState)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .padding(18)
        .frame(minWidth: 700, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 700, minHeight: 620)
        .accessibilityIdentifier("guidedSetupRepairView")
        .onAppear(perform: captureSetupNetworkSnapshot)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerTitle)
                .appFont(.title2, scale: appTextScale, weight: .semibold)

            Text(headerMessage)
                .appFont(.body, scale: appTextScale)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var headerMessage: String {
        switch context.mode {
        case .firstRun:
            return "Get JoesProxy ready for your first capture and learn where the core tools live."
        case .replay:
            return "Use this flow to revisit setup, refresh trust, or relearn the core traffic workflow."
        case .repair:
            return "A blocking setup problem needs attention before HTTPS inspection can work as expected."
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .welcome:
            welcomeSection
        case .startCapturing:
            startCapturingSection
        case .httpsAndTrust:
            httpsAndTrustSection
        case .exploreTraffic:
            exploreTrafficSection
        case .needHelp:
            needHelpSection
        }
    }

    private func repairStatusCard(for blockingState: GuidedSetupBlockingState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(blockingState.title, systemImage: "exclamationmark.triangle.fill")
                .appFont(.headline, scale: appTextScale, weight: .semibold)
                .foregroundStyle(.yellow)

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
            actionButton(certificateSetupTitle, action: {
                isPresented = false
                openCertificateSetup()
            })

            actionButton("macOS Setup Guide", action: {
                isPresented = false
                openMacOSGuide()
            })
            actionButton("iOS Setup Guide", action: {
                isPresented = false
                openIOSGuide()
            })
            actionButton("Apple TV Setup Guide", action: {
                isPresented = false
                openTVOSGuide()
            })

            actionButton("Retry Status Check", action: retryStatusValidation)

            if blockingState == .needsCleanup {
                Button("Reset Certificate State…", action: {
                    isPresented = false
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

    private var welcomeSection: some View {
        sectionCard(
            title: "Setup Checklist",
            summary: "Follow the next recommended action, then watch each setup step move from blocked or waiting to complete."
        ) {
            nextRecommendedAction
            setupChecklist
            profileMaintenanceCard
            Button("Export MCP Skill…") {
                exportSkill()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("guidedSetupExportSkillButton")
            helpLinkButton("Learn about traffic states") {
                openHelpTopic(.trafficStates)
            }
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
                    isPresented = false
                    openCertificateSetup()
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
        profileSnapshotDiagnosis.health.isStale ? .yellow : .green
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

    @ViewBuilder
    private var nextRecommendedAction: some View {
        if let item = nextSetupActionItem,
           let actionTitle = item.primaryActionTitle,
            let action = item.primaryAction {
            VStack(alignment: .leading, spacing: 8) {
                Text("Next step")
                    .appFont(.headline, scale: appTextScale, weight: .semibold)

                Text(item.detail)
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(actionTitle) {
                    performChecklistAction(action)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("setupNextActionButton")
                .accessibilityLabel("\(actionTitle). \(item.title). \(item.detail)")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var setupChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup status")
                .appFont(.headline, scale: appTextScale, weight: .semibold)

            ForEach(setupChecklistItems) { item in
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
                        Image(systemName: checklistActionIconName(for: action))
                            .frame(width: 18, height: 18)
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
        case .verifyCapture, .retryStatusValidation:
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
        case .needsAction, .warning:
            return .yellow
        case .waiting:
            return .blue
        case .stale:
            return .orange
        case .neutral:
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

    private var startCapturingSection: some View {
        sectionCard(
            title: "Start Capturing",
            summary: "Start the proxy, point a client or this Mac at the proxy host and port, then confirm sessions appear."
        ) {
            sectionBullet("Use the Proxy controls to start the listener on the configured local port.")
            sectionBullet("Configure the Mac, device, simulator, or app you care about to use JoesProxy as its HTTP/HTTPS proxy.")
            sectionBullet("If traffic still does not appear, revisit the setup guides and confirm the client is using the current host and port.")
            helpLinkButton("Troubleshoot missing traffic") {
                openHelpTopic(.trafficStates)
            }
        }
    }

    private var httpsAndTrustSection: some View {
        sectionCard(
            title: "HTTPS & Trust",
            summary: "HTTPS inspection requires the JoesProxy Root CA to exist and be trusted by the device generating the request."
        ) {
            sectionBullet("Without trust, you may still see tunneled metadata, but decrypted request and response bodies will stay unavailable.")
            sectionBullet("If trust is broken, expired, or stale, use the certificate flow and device guides here instead of guessing.")
            VStack(alignment: .leading, spacing: 8) {
                actionButton(certificateSetupTitle, action: {
                    isPresented = false
                    openCertificateSetup()
                })
                actionButton("macOS Setup Guide", action: {
                    isPresented = false
                    openMacOSGuide()
                })
                actionButton("iOS Setup Guide", action: {
                    isPresented = false
                    openIOSGuide()
                })
                actionButton("Apple TV Setup Guide", action: {
                    isPresented = false
                    openTVOSGuide()
                })
            }
            helpLinkButton("Why trust is required") {
                openHelpTopic(.certificateSetup)
            }
            helpLinkButton("Understand inspected vs tunneled traffic") {
                openHelpTopic(.trafficStates)
            }
        }
    }

    private var exploreTrafficSection: some View {
        sectionCard(
            title: "Explore Traffic",
            summary: "Once traffic is flowing, use the two browser modes and the inspector to narrow in on the requests that matter."
        ) {
            sectionBullet("Table is best for chronological scanning and sorting through recent traffic quickly.")
            sectionBullet("Explorer is best for grouped navigation by host and path when captures get dense.")
            sectionBullet("Use the Request Inspector to understand whether a session was inspected, tunneled, truncated, or omitted in a saved recording.")
        }
    }

    private var needHelpSection: some View {
        sectionCard(
            title: "Need Help",
            summary: "When something looks wrong, reopen this flow, the Help hub, or the device-specific guides instead of relying on stale setup assumptions."
        ) {
            sectionBullet("Use Help Topics & Glossary for terminology, recording guidance, and troubleshooting explanations.")
            sectionBullet("Reopen Guided Setup & Repair any time from the Help menu.")
            sectionBullet("Use the certificate setup and device guides when trust, proxy settings, or local configuration have changed.")
            helpLinkButton("Troubleshoot HTTPS bodies still missing") {
                openHelpTopic(.trafficStates)
            }
            actionButton("Open Help Topics & Glossary", action: {
                isPresented = false
                openHelpHub()
            })
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

    private func sectionBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6 * appTextScale))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .accessibilityHidden(true)

            Text(text)
                .appFont(.body, scale: appTextScale)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func performChecklistAction(_ action: ProxyViewModel.GuidedSetupChecklistItem.Action) {
        switch action {
        case .openCertificateSetup:
            isPresented = false
            openCertificateSetup()
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
            runSetupVerification()
        case .retryStatusValidation:
            retryStatusValidation()
        case .resetCertificateState:
            isPresented = false
            resetCertificateState()
        }
    }

    private func section(for item: ProxyViewModel.GuidedSetupChecklistItem) -> GuidedSetupSection {
        switch item.id {
        case "certificate", "verification":
            return .httpsAndTrust
        case "proxy", "traffic":
            return .startCapturing
        case "device":
            return .httpsAndTrust
        default:
            return .welcome
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func helpLinkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.link)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
