//
//  JoesProxyApp.swift
//  JoesProxy
//
//  Created by Joseph McCraw on 11/5/24.
//

import SwiftUI

#if !AGW4_AGENT_TARGET
import Combine
import UniformTypeIdentifiers
import os

@main
struct JoesProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var dismissedCapacityGap: UInt64?
    @Environment(\.dismissWindow) private var dismissWindow
    private let logger = Logger(subsystem: "com.JoesProxyApp.UI", category: "Lifecycle")
    private let coordinator: AppCoordinator
    private let uiTestLaunchConfiguration: UITestLaunchConfiguration?
    private let profilingMemoryGuard: ProfilingMemoryGuard?
    private let agentProfile: AgentWorkspaceProfile?
    private let recordingFileCoordinator = RecordingFileCoordinator()
    private let reproFileCoordinator = ReproFileCoordinator()
    @StateObject private var inspectorHost: InspectorWorkspaceHost
    @StateObject private var settingsViewModel: SettingsViewModel
    @StateObject private var presentationState: AppPresentationState
    @ObservedObject private var mcpServerController: MCPServerController
    @ObservedObject private var compactModeController: CompactModeController
    @State private var isMenuBarItemInsertionAllowed = false
    @State private var hasAppliedStartupPresentation = false
    @StateObject private var transportAssetScenario = TransportAssetUITestScenario()

    init() {
#if DEBUG
        MCPTransportSpikeLaunchHarness.startIfRequested()
#endif
        if RuntimeDebugFlag.isUILifecycleLoggingEnabled {
            logger.info("UI lifecycle: JoesProxyApp init start")
        }
        let uiTestLaunchConfiguration = UITestLaunchConfiguration.current
        self.uiTestLaunchConfiguration = uiTestLaunchConfiguration
        AgentWorkspaceDiagnostics.shared.configure(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment,
            isolated: uiTestLaunchConfiguration != nil
        )
        if let guardConfiguration = ProfilingMemoryGuardConfiguration(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment,
            isolated: uiTestLaunchConfiguration != nil
        ) {
            let guardService = ProfilingMemoryGuard(configuration: guardConfiguration)
            profilingMemoryGuard = guardService
            guardService.start()
        } else {
            profilingMemoryGuard = nil
        }
        let suppressesLaunchRecoveryOffers = RuntimeDebugFlag.suppressesLaunchRecoveryForUITesting
        let coordinator: AppCoordinator
        let profileConfiguration = AgentWorkspaceProfileConfiguration(
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        precondition(!ProcessInfo.processInfo.arguments.contains("--agent-workspace-profile") || profileConfiguration != nil,
                     "Invalid isolated Agent profiling configuration")
        let agentProfile = profileConfiguration.map { AgentWorkspaceProfile(configuration: $0) }
        self.agentProfile = agentProfile
        if let agentProfile {
            coordinator = agentProfile.coordinator
        } else if let uiTestConfiguration = uiTestLaunchConfiguration {
            let uiTestStorage: RuntimeStorageScope
            do {
                uiTestStorage = try RuntimeStorageScope.uiTest(environment: ProcessInfo.processInfo.environment)
            } catch {
                fatalError("UI test storage unavailable. Use the serial host wrapper; user storage will not be used. \(error)")
            }
            let uiTestDefaults = uiTestStorage.defaults
            guard let fixtureRoot = Bundle.main.resourceURL?.appendingPathComponent("Fixtures/HLS"),
                  FileManager.default.fileExists(atPath: fixtureRoot.path) else {
                fatalError("Packaged HLS fixtures are missing; UI tests will not use user fixture storage.")
            }

            let uiTestConfigurationStore = UserDefaultsAppConfiguration(userDefaults: uiTestDefaults)
            uiTestConfigurationStore.rollingCaptureAutoSaveEnabled = false
            if let browserMode = uiTestConfiguration.browserMode {
                uiTestConfigurationStore.sessionBrowserModeRawValue = browserMode.rawValue
            }
            if let textSize = uiTestConfiguration.textSize {
                uiTestConfigurationStore.appTextSizeRawValue = textSize.rawValue
            }
            if let proxyPort = uiTestConfiguration.proxyPort {
                uiTestConfigurationStore.proxyPort = proxyPort
            }

            let uiTestSessionStore: any SessionStore
            switch uiTestConfiguration.fixture {
            case .demoSessions:
                uiTestSessionStore = ScreenshotDemoSessions.makePreSeededSessionStore(
                    count: uiTestConfiguration.sessionCount
                )
            case .epgRewriteClient, .authoredEvidence, .guidedMockAuthoring, .captionEvidence, .captionPlayer,
                 .transportAssets, .streamingAssets, .mockJourney:
                uiTestSessionStore = InMemorySessionStore(
                    retentionPolicy: uiTestConfigurationStore.captureRetentionPolicy
                )
            case nil:
                uiTestSessionStore = InMemorySessionStore(
                    retentionPolicy: uiTestConfigurationStore.captureRetentionPolicy
                )
            }

            let certificateIdentity: RootCertificateIdentity?
            let trustStatus: TrustInstallationStatus
            switch uiTestConfiguration.certificateState {
            case .notSetUp, nil:
                certificateIdentity = nil
                trustStatus = .notInstalled
            case .installedTrustRequired:
                certificateIdentity = UITestCertificateAuthority.demoIdentity
                trustStatus = .trustRequired(reason: "Not trusted")
            case .needsCleanup:
                certificateIdentity = UITestCertificateAuthority.demoIdentity
                trustStatus = .invalid(reason: "Needs cleanup")
            case .ready:
                certificateIdentity = UITestCertificateAuthority.demoIdentity
                trustStatus = .installed
            }

            let setupVerificationState: ProxyViewModel.SetupVerificationState?
            switch uiTestConfiguration.verificationState {
            case .inspected:
                setupVerificationState = .inspected
            case .tunneled:
                setupVerificationState = .tunneled
            case .noTrafficObserved:
                setupVerificationState = .noTrafficObserved
            case .proxyStopped:
                setupVerificationState = .proxyStopped
            case nil:
                setupVerificationState = nil
            }

            let proxyRuntime: (any ProxyRuntime)?
            if let verificationState = uiTestConfiguration.verificationState {
                let initialState: ProxyRuntimeState
                switch verificationState {
                case .proxyStopped:
                    initialState = .stopped
                case .inspected, .tunneled, .noTrafficObserved:
                    initialState = .running(port: uiTestConfigurationStore.proxyPort)
                }
                proxyRuntime = UITestProxyRuntime(
                    initialState: initialState,
                    configuredPort: uiTestConfigurationStore.proxyPort
                )
            } else {
                proxyRuntime = nil
            }

            coordinator = AppCoordinator(
                configuration: uiTestConfigurationStore,
                proxyRuntime: proxyRuntime,
                sessionStore: uiTestSessionStore,
                certificateStore: UITestCertificateStore(identity: certificateIdentity),
                certificateAuthority: UITestCertificateAuthority(currentIdentity: certificateIdentity),
                trustInstaller: UITestTrustInstaller(status: trustStatus),
                setupVerificationState: setupVerificationState,
                localNetworkInfoProvider: SyntheticLocalNetworkInfoProvider(bonjourName: nil),
                mcpCredentialStore: MCPInMemoryCredentialStore(),
                suppressesLaunchRecoveryOffers: suppressesLaunchRecoveryOffers,
                recoveryStorageAccessEnabled: false,
                storageScope: uiTestStorage,
                hlsFixtureProfileRoot: fixtureRoot
            )
            if uiTestConfiguration.uploadStorageFailure {
                coordinator.uploadSpoolService.recordStorageFailure()
            }
        } else if ScreenshotDemoSessions.isEnabled {
            let screenshotDefaultsSuiteName = "com.ShowBlender.JoesProxy.ScreenshotDemo"
            let screenshotDefaults = UserDefaults(suiteName: screenshotDefaultsSuiteName) ?? .standard
            screenshotDefaults.removePersistentDomain(forName: screenshotDefaultsSuiteName)

            let screenshotConfiguration = UserDefaultsAppConfiguration(userDefaults: screenshotDefaults)
            screenshotConfiguration.rollingCaptureAutoSaveEnabled = false
            if let browserModeOverride = ScreenshotDemoSessions.browserModeOverride {
                screenshotConfiguration.sessionBrowserModeRawValue = browserModeOverride.rawValue
            }
            if let textSizeOverride = ScreenshotDemoSessions.textSizeOverride {
                screenshotConfiguration.appTextSizeRawValue = textSizeOverride.rawValue
            }

            coordinator = AppCoordinator(
                configuration: screenshotConfiguration,
                sessionStore: ScreenshotDemoSessions.makePreSeededSessionStore(count: ScreenshotDemoSessions.sessionCountOverride ?? 25),
                localNetworkInfoProvider: SyntheticLocalNetworkInfoProvider(),
                mcpCredentialStore: MCPInMemoryCredentialStore(),
                suppressesLaunchRecoveryOffers: suppressesLaunchRecoveryOffers
            )
        } else {
            coordinator = AppCoordinator()
            if NSClassFromString("XCTestCase") == nil {
                // Preserve the previous run's evidence and incident before this run's monitor can write.
                let responsivenessMonitor = coordinator.responsivenessMonitor
                coordinator.previousRunDiagnosticsCoordinator.start { responsivenessMonitor?.start() }
            }
        }
        self.coordinator = coordinator
        profilingMemoryGuard?.attachCaptureDiagnostics(coordinator.captureTransportDiagnostics)
        coordinator.bootstrapSharedServices(preserveSeededStatus: uiTestLaunchConfiguration?.mcpStatusFixture != nil)
        agentProfile?.start()
        if let uiTestLaunchConfiguration,
           let mcpStatusFixture = uiTestLaunchConfiguration.mcpStatusFixture {
            coordinator.mcpServerController.applyUITestMCPStatusFixture(mcpStatusFixture)
        }
        let inspectorHost = InspectorWorkspaceHost(
            coordinator: coordinator, forceAgent: RuntimeDebugFlag.isAgentWorkspaceForced)
        _inspectorHost = StateObject(wrappedValue: inspectorHost)
        coordinator.previousRunDiagnosticsCoordinator.contextProvider = { [weak coordinator, weak inspectorHost] in
            coordinator?.previousRunOperatingContext(workspace: inspectorHost?.activeWorkspace)
                ?? PreviousRunOperatingContext(observedAt: Date())
        }
        _settingsViewModel = StateObject(
            wrappedValue: SettingsViewModel(
                configuration: coordinator.configuration,
                proxyRuntime: coordinator.proxyRuntime,
                diagnosticsCoordinator: coordinator.previousRunDiagnosticsCoordinator
            )
        )
        let resolvedPresentationState = AppPresentationState(configuration: coordinator.configuration)
        _presentationState = StateObject(wrappedValue: resolvedPresentationState)
        _mcpServerController = ObservedObject(wrappedValue: coordinator.mcpServerController)
        _compactModeController = ObservedObject(wrappedValue: coordinator.compactModeController)
        coordinator.mcpSystemNotificationCoordinator.start { route in
            MainWindowActivation.activateMainWindow()
            switch route {
            case .approvals:
                resolvedPresentationState.presentCompactApprovals()
            case .clients:
                resolvedPresentationState.presentMCPManagement(destination: .clients)
            case .agentRuns:
                MenuBarOnlyActivation.ensureRegularActivationPolicy()
                resolvedPresentationState.presentMCPManagement(destination: .agentRuns)
            }
        }
        appDelegate.hasUnsavedSessions = { !coordinator.sessionStore.sessions.isEmpty }
        appDelegate.cleanUpSystemProxyOnQuit = {
            coordinator.systemProxyController.cleanUpForQuit()
        }
        appDelegate.recordCleanShutdownOnQuit = {
            coordinator.previousRunDiagnosticsCoordinator.recordCleanShutdown()
        }
        appDelegate.shouldWarnBeforeQuit = {
            coordinator.configuration.warnsBeforeQuittingWithUnsavedSessions
        }
        appDelegate.setShouldWarnBeforeQuit = { shouldWarn in
            coordinator.configuration.warnsBeforeQuittingWithUnsavedSessions = shouldWarn
        }
        appDelegate.saveRecordingBeforeQuit = {
            let fileCoordinator = RecordingFileCoordinator()
            guard let selection = fileCoordinator.promptForSaveSelection(defaultName: "Recording") else {
                return false
            }

            do {
                try coordinator.viewModel.saveRecording(to: selection.url, fidelity: selection.fidelity)
                return true
            } catch {
                return false
            }
        }
        if RuntimeDebugFlag.isUILifecycleLoggingEnabled {
            logger.info("UI lifecycle: JoesProxyApp init complete")
        }
    }

    var body: some Scene {
        inspectorScenes
    }

    private var isAgentWorkspaceActive: Bool {
        inspectorHost.activeWorkspace == .agent
    }

    private var viewModel: ProxyViewModel {
        inspectorHost.loadInspector()
    }

    @SceneBuilder
    private var inspectorScenes: some Scene {
        Window("JoesProxy", id: JoesProxyMainWindowID.rawValue) {
            Group {
                if isAgentWorkspaceActive {
                    agentMainWindowContent
                } else if uiTestLaunchConfiguration?.fixture == .epgRewriteClient {
                    MCPEPGRewriteFixtureClientView()
                } else if uiTestLaunchConfiguration?.fixture == .mockJourney {
                    MockJourneyUITestView()
                } else if uiTestLaunchConfiguration?.fixture == .transportAssets {
                    TransportAssetEvidenceUITestView(scenario: transportAssetScenario)
                        .environment(\.appTextScale, (uiTestLaunchConfiguration?.textSize ?? .standard).fontScale)
                } else if uiTestLaunchConfiguration?.fixture == .authoredEvidence {
                    EffectBundleEvidenceUITestView()
                        .environment(\.appTextScale, (uiTestLaunchConfiguration?.textSize ?? .standard).fontScale)
                } else if uiTestLaunchConfiguration?.fixture == .captionEvidence {
                    EffectBundleEvidenceUITestView(captions: true)
                        .environment(\.appTextScale, (uiTestLaunchConfiguration?.textSize ?? .standard).fontScale)
                } else if uiTestLaunchConfiguration?.fixture == .captionPlayer {
                    CaptionPlayerUITestView()
                } else if compactModeController.isCompactModeActive {
                    // Compact mode: only the lightweight HUD is constructed here. ContentView
                    // (session table, timeline, explorer, and everything they own) is not built at
                    // all while this branch is active — that's what keeps this mode cheap.
                    MinimalMonitoringView(
                        viewModel: compactModeController.monitoringViewModel,
                        onSizeChange: { compactModeController.recordMeasuredContentSize($0) },
                        onOpenApprovals: { presentationState.presentCompactApprovals() },
                        onOpenActiveEffect: { openActiveEffectDestination($0) },
                        onDisableAllActiveEffect: { disableAllActiveEffect($0) },
                        onManageModifications: { openWindow(id: TrafficModificationsWindowView.windowID) },
                        capacityNotice: capacityNotice,
                        uploadSpoolService: coordinator.uploadSpoolService
                    )
                    .environment(\.appTextScale, settingsViewModel.appTextSize.fontScale)
                    .dynamicTypeSize(settingsViewModel.appTextSize.dynamicTypeSize)
                } else if compactModeController.isRestoringFullView {
                    CompactModeRestoringView()
                } else {
                    ContentView(
                        viewModel: viewModel,
                        simulatorSetupViewModel: coordinator.simulatorSetupViewModel,
                        routingModel: coordinator.systemProxyRoutingModel,
                        systemProxyController: coordinator.systemProxyController,
                        mcpServerController: coordinator.mcpServerController,
                        selfValidationCoordinator: coordinator.selfValidationCoordinator,
                        sessionStartCoordinator: coordinator.sessionStartCoordinator,
                        compactModeController: compactModeController,
                        uploadSpoolService: coordinator.uploadSpoolService
                    )
                    .environmentObject(presentationState)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if TransportAssetUITestScenario.isEnabled(uiTestLaunchConfiguration?.fixture) {
                    Text(transportAssetScenario.status)
                        .padding(8)
                        .accessibilityIdentifier("transportAssetScenarioStatus")
                }
            }
            .task {
                if TransportAssetUITestScenario.isEnabled(uiTestLaunchConfiguration?.fixture),
                   let storage = try? RuntimeStorageScope.uiTest(environment: ProcessInfo.processInfo.environment) {
                    await transportAssetScenario.run(fixture: uiTestLaunchConfiguration?.fixture,
                        store: coordinator.sessionStore, root: storage.root)
                }
            }
            .alert("Capture not cleared", isPresented: $presentationState.isClearCaptureBusyPresented) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(ProxyViewModel.clearSnapshotBusyMessage)
            }
            .onAppear {
                    if isAgentWorkspaceActive {
                        isMenuBarItemInsertionAllowed = true
                        presentationState.installUtilityWindowOpener { [openWindow] kind in
                            MenuBarOnlyActivation.ensureRegularActivationPolicy()
                            openWindow(id: kind.rawValue)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        MainWindowActivation.openMainWindowHandler = { [openWindow] in
                            openWindow(id: JoesProxyMainWindowID.rawValue)
                        }
                        return
                    }
                    guard !hasAppliedStartupPresentation else { return }
                    hasAppliedStartupPresentation = true
                    Task { @MainActor in
                        await Task.yield()
                        if let uiTestLaunchConfiguration {
                            applyUITestPresentationStateIfNeeded(using: uiTestLaunchConfiguration)
                        } else if ScreenshotDemoSessions.isEnabled {
                            // Screenshot mode — suppress first-run overlays so the session UI is unobstructed.
                            isMenuBarItemInsertionAllowed = true
                        } else {
                            // Restore outranks first-run path choice so the two never stack (BA-2 / BA-3).
                            if viewModel.rollingCaptureRestoreOffer == nil {
                                presentationState.presentInitialGuidedSetupIfNeeded()
                            }
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            isMenuBarItemInsertionAllowed = true
                        }
                        if settingsViewModel.runInMenuBarOnly {
                            settingsViewModel.applyMenuBarOnlyActivationPolicy()
                        }
                    }
                    guard RuntimeDebugFlag.isUILifecycleLoggingEnabled else {
                        return
                    }
                    logger.info("UI lifecycle: main Window content appeared")
                }
                .onDisappear {
                    guard RuntimeDebugFlag.isUILifecycleLoggingEnabled else {
                        return
                    }
                    logger.info("UI lifecycle: main Window content disappeared")
                }
            .background(MainWindowConfigurator(compactModeController: compactModeController))
            .safeAreaInset(edge: .bottom) {
                if !compactModeController.isCompactModeActive {
                    capacityNotice
                }
            }
            .sheet(item: rollingCaptureRestoreOfferBinding, onDismiss: {
                // Wait until recovery has actually left the presentation stack.
                guard viewModel.rollingCaptureRestoreOffer == nil,
                      uiTestLaunchConfiguration != nil || !ScreenshotDemoSessions.isEnabled else { return }
                if uiTestLaunchConfiguration == nil || uiTestLaunchConfiguration?.guidedSetupMode == .firstRun {
                    presentationState.presentInitialGuidedSetupIfNeeded()
                }
            }) { offer in
                RollingCaptureRestoreSheetView(
                    offer: offer,
                    viewModel: viewModel,
                    settingsViewModel: settingsViewModel,
                    compactModeController: compactModeController,
                    openRecoverySettings: {
                        settingsViewModel.requestRecoverySettings()
                        openSettings()
                    }
                )
                    .environment(\.appTextScale, viewModel.appTextSize.fontScale)
            }
            .sheet(isPresented: $presentationState.isFirstRunPathChoicePresented) {
                FirstRunPathChoiceView(
                    onStartFirstCapture: {
                        presentationState.chooseStartFirstCapture()
                        coordinator.sessionStartCoordinator.syncPersistedOnboardingState()
                        compactModeController.performRequiringFullView {}
                    },
                    onConnectAnAgent: {
                        presentationState.chooseConnectAnAgent()
                        coordinator.sessionStartCoordinator.syncPersistedOnboardingState()
                        compactModeController.enterCompactWorkingView()
                    },
                    onOpenInspector: {
                        presentationState.chooseOpenInspector()
                        coordinator.sessionStartCoordinator.syncPersistedOnboardingState()
                        compactModeController.performRequiringFullView {}
                    }
                )
                .interactiveDismissDisabled()
            }
            .onAppear {
                presentationState.installUtilityWindowOpener { [openWindow] kind in
                    MenuBarOnlyActivation.ensureRegularActivationPolicy()
                    openWindow(id: kind.rawValue)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .onOpenURL(perform: handleOpenURL)
            .onAppear {
                MainWindowActivation.openMainWindowHandler = { [openWindow] in
                    openWindow(id: JoesProxyMainWindowID.rawValue)
                }
                _ = MainWindowDeduper.closeDuplicateMainWindows()
            }
        }
        .defaultSize(width: 1440, height: 900)

        Window("About JoesProxy", id: UtilityWindowKind.about.rawValue) {
            utilityWindow(.about)
        }
        .windowResizability(.contentSize)

        Window("MCP Management", id: UtilityWindowKind.mcpManagement.rawValue) {
            utilityWindow(.mcpManagement)
        }
        .defaultSize(width: 1000, height: 740)
        .windowResizability(.contentMinSize)

        Window("MCP Approvals", id: UtilityWindowKind.approvals.rawValue) {
            utilityWindow(.approvals)
        }
        .defaultSize(width: 560, height: 540)
        .windowResizability(.contentMinSize)

        WindowGroup(for: URL.self) { $url in
            if let url {
                JSONViewerSheet(fileURL: url)
            }
        }
        .defaultSize(width: 640, height: 560)

        Window("Traffic Modifications", id: TrafficModificationsWindowView.windowID) {
            if !isAgentWorkspaceActive {
                TrafficModificationsWindowView()
                    .environmentObject(viewModel)
                    .environmentObject(presentationState)
                    .environment(\.appTextScale, viewModel.appTextSize.fontScale)
                    .onAppear { presentationState.isTrafficModificationWindowOpen = true }
                    .onDisappear { presentationState.isTrafficModificationWindowOpen = false }
            }
        }
        .defaultSize(width: 960, height: 720)
        .windowResizability(.contentMinSize)

        Window("Current Screen Help", id: "contextual-help") {
            if !isAgentWorkspaceActive {
                ContextualHelpWindowView()
                    .environmentObject(presentationState)
                    .environmentObject(viewModel)
            }
        }
        .defaultSize(width: 420, height: 640)
        .windowResizability(.contentSize)

        Window("Media Info", id: "media-info") {
            if !isAgentWorkspaceActive {
                MediaInfoWindowView()
                    .environmentObject(presentationState)
                    .environmentObject(viewModel)
                    .environmentObject(coordinator.mediaInspectionIndex)
            }
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)
        AgentSupervisionScenes(coordinator: coordinator, textScale: settingsViewModel.appTextSize.fontScale)

        Settings {
            if isAgentWorkspaceActive {
                AgentWorkspaceSettingsView(viewModel: settingsViewModel, openInspector: {
                    compactModeController.performRequiringFullView { inspectorHost.openInspector() }
                })
                .environment(\.appTextScale, settingsViewModel.appTextSize.fontScale)
            } else {
                SettingsView(
                    viewModel: settingsViewModel,
                    captureViewModel: viewModel,
                    reviewSavedCapture: {
                        openWindow(id: JoesProxyMainWindowID.rawValue)
                        MainWindowActivation.activateMainWindow()
                        viewModel.reviewRollingCapture()
                    },
                    mcpSystemNotificationCoordinator: coordinator.mcpSystemNotificationCoordinator
                )
            }
        }
        .commands {
            if isAgentWorkspaceActive {
                agentWorkspaceCommands
            } else {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("Settings…")
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // MARK: Apple menu — About
            CommandGroup(replacing: .appInfo) {
                Button("About JoesProxy") {
                    presentationState.presentAbout()
                }
            }

            // JoesProxy is a single-main-window app: replace SwiftUI's synthesized WindowGroup
            // "New Window" (⌘N) with the File open actions (no legitimate multi-main-window feature).
            CommandGroup(replacing: .newItem) {
                Button("Open Recording…") {
                    guard let url = recordingFileCoordinator.promptForOpenURL() else { return }
                    if !viewModel.hasSessions {
                        Task { await viewModel.openRecording(from: url, mode: .replace) }
                    } else {
                        presentationState.pendingRecordingURL = IdentifiableURL(url: url)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open Reproduction Package…") {
                    guard let url = reproFileCoordinator.promptForOpenReproURL() else { return }
                    openReproPackage(url)
                }

                Button("Import HAR as Reproduction…") {
                    guard let url = reproFileCoordinator.promptForHARURL() else { return }
                    importHARAsReproPackage(url)
                }

                Button("Open JSON…") {
                    presentationState.openJSONFileFromPicker()
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            }

            // MARK: File menu — save / export commands (standard Save position)
            CommandGroup(replacing: .saveItem) {
                Button("Save Recording…") {
                    showSaveRecordingPanel(selectedOnly: false)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!viewModel.hasSessions)

                Button("Save Selected as Recording…") {
                    showSaveRecordingPanel(selectedOnly: true)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!viewModel.hasSelectedSessions)

                Divider()

                Button("Export to HAR…") {
                    showExportPanel(format: .har)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!viewModel.hasSessions)

                Button("Export Reproduction Package…") {
                    presentCurrentReproPackage()
                }
                .disabled(!viewModel.hasSessions)

                Button("Export MCP Skill…") {
                    showExportSkillPanel()
                }
            }

            // MARK: View menu — injected into the system View menu to avoid a duplicate top-level entry
            CommandGroup(after: .sidebar) {
                // Every pane-switch command below assumes ContentView is mounted — a
                // WorkspaceCommandCenter post reaches nobody if it isn't. performRequiringFullView
                // exits compact mode first (if needed) and defers the post until ContentView has
                // actually remounted, so these gracefully bring the full UI back instead of
                // silently doing nothing.
                Button("Captured Sessions") {
                    compactModeController.performRequiringFullView {
                        WorkspaceCommandCenter.post(.showSessions)
                    }
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Bookmarks") {
                    compactModeController.performRequiringFullView {
                        WorkspaceCommandCenter.post(.showBookmarks)
                    }
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Traffic Modifications…") {
                    openWindow(id: TrafficModificationsWindowView.windowID)
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .accessibilityIdentifier("joesProxyOpenLocalOverridesMenuItem")

                Button("New OpenAPI Mock…") {
                    presentationState.trafficModificationEditor = .openAPI
                    openWindow(id: TrafficModificationsWindowView.windowID)
                }
                .accessibilityIdentifier("joesProxyNewOpenAPIMockMenuItem")

                Divider()

                Button("Table Browser") {
                    compactModeController.performRequiringFullView {
                        WorkspaceCommandCenter.post(.showTable)
                    }
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Explorer Browser") {
                    compactModeController.performRequiringFullView {
                        WorkspaceCommandCenter.post(.showExplorer)
                    }
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Timeline Browser") {
                    compactModeController.performRequiringFullView {
                        WorkspaceCommandCenter.post(.showTimeline)
                    }
                }
                .keyboardShortcut("5", modifiers: .command)

                Divider()

                Button(compactModeController.isCompactModeActive ? "Exit Compact Mode" : "Enter Compact Mode") {
                    compactModeController.toggle()
                }
                .keyboardShortcut("0", modifiers: .command)

                Toggle("Keep JoesProxy in Foreground", isOn: Binding(
                    get: { compactModeController.isPinnedToForeground },
                    set: { _ in compactModeController.toggleForegroundPin() }
                ))
            }

            // MARK: Session actions menu
            CommandMenu("Tools") {
                Button("Return to Agent Workspace") {
                    if inspectorHost.returnToAgent(presentationBlocked: presentationState.blocksAgentTransition) {
                        presentationState.finishInspectorPresentation()
                        dismissWindow(id: "media-info")
                        dismissWindow(id: "contextual-help")
                        dismissWindow(id: TrafficModificationsWindowView.windowID)
                        compactModeController.enterAgentPresentation()
                    }
                }
                if let failure = inspectorHost.transitionFailure {
                    Text(failure)
                }
                Button("Traffic Modifications…") {
                    openWindow(id: TrafficModificationsWindowView.windowID)
                }
                .accessibilityIdentifier("toolsTrafficModifications")
                Button("New Test Stream…") {
                    presentationState.trafficModificationEditor = .testStream
                    openWindow(id: TrafficModificationsWindowView.windowID)
                }
                Button("New OpenAPI Mock…") {
                    presentationState.trafficModificationEditor = .openAPI
                    openWindow(id: TrafficModificationsWindowView.windowID)
                }
            }

            CommandMenu("Session") {
                Button("Find in Bodies...") {
                    compactModeController.performRequiringFullView {
                        presentationState.presentBodyFind()
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!viewModel.hasSessions)

                Button("Clear All Sessions") {
                    if viewModel.clearAllSessions() == .busy {
                        presentationState.isClearCaptureBusyPresented = true
                    }
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!viewModel.hasSessions)
                .accessibilityIdentifier("clearAllSessionsMenuItem")

                Divider()

                Button("Map Selected Local") {
                    compactModeController.performRequiringFullView {
                        WorkspaceCommandCenter.post(.mapSelectedLocal)
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(viewModel.selectedSession.map { !viewModel.canCreateResponseOverride(from: $0) } ?? true)

                Button("Replace Selected with Test Stream…") {
                    compactModeController.performRequiringFullView {
                        WorkspaceCommandCenter.post(.replaceSelectedWithHLSTestStream)
                    }
                }
                .disabled(viewModel.selectedSession.map { !viewModel.canReplaceWithHLSTestStream($0) } ?? true)
                .accessibilityIdentifier("replaceSelectedWithHLSTestStreamMenuItem")

                Button("Bookmark Selected Session") {
                    compactModeController.performRequiringFullView {
                        WorkspaceCommandCenter.post(.bookmarkSelectedSession)
                    }
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(viewModel.selectedSession == nil)

                Button("Copy Selected as curl") {
                    compactModeController.performRequiringFullView {
                        WorkspaceCommandCenter.post(.copySelectedAsCurl)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(viewModel.selectedSession == nil && viewModel.selectedBookmark == nil)

                Divider()

                Button("Run Selected Bookmark") {
                    compactModeController.performRequiringFullView {
                        WorkspaceCommandCenter.post(.runSelectedBookmark)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!viewModel.canExecuteSelectedBookmark)
            }

            // MARK: Proxy menu
            CommandMenu("Proxy") {
                Button("Start Proxy") {
                    viewModel.startProxy()
                }
                .disabled(!viewModel.canStartProxy)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Stop Proxy") {
                    viewModel.stopProxy()
                }
                .disabled(!viewModel.canStopProxy)
                .keyboardShortcut(".", modifiers: [.command, .option])
            }

            // MARK: Certificate menu
            CommandMenu("Certificate") {
                Button(viewModel.certificateSetupEntryPointTitle) {
                    compactModeController.performRequiringFullView {
                        presentationState.presentCertificateSetup()
                    }
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Reset Certificate State") {
                    compactModeController.performRequiringFullView {
                        viewModel.confirmResetCertificateState()
                    }
                }
                .disabled(!viewModel.canResetCertificateState)
            }

            // MARK: MCP menu
            CommandMenu("MCP") {
                Button("Open MCP Management…") {
                    presentationState.presentMCPManagement()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .accessibilityIdentifier("joesProxyOpenMCPManagementMenuItem")

                // The Compact HUD and notifications open this window too; the menu is the
                // keyboard and VoiceOver path from the Inspector.
                Button("Pending Approvals…") {
                    presentationState.presentCompactApprovals()
                }
                .accessibilityIdentifier("joesProxyOpenMCPApprovalsMenuItem")

                Divider()

                Button("Start MCP") {
                    Task {
                        await mcpServerController.start()
                    }
                }
                .disabled(!mcpServerController.canStartMCP)
                .accessibilityIdentifier("joesProxyStartMCPMenuItem")

                Button("Stop MCP") {
                    Task {
                        await mcpServerController.stop()
                    }
                }
                .disabled(!mcpServerController.canStopMCP)
                .accessibilityIdentifier("joesProxyStopMCPMenuItem")
            }
            }
        }
        .commands {
            if isAgentWorkspaceActive {
                CommandGroup(replacing: .help) {
                    Button("Agent Workspace Help") { openWindow(id: "agent-help") }
                        .keyboardShortcut("/", modifiers: [.command, .shift])
                }
            } else {
            // MARK: Help menu
            CommandGroup(replacing: .help) {
                Button("Current Screen Help") {
                    presentationState.presentContextualHelp(topic: .capturedSessions)
                    openWindow(id: "contextual-help")
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])

                Divider()

                Button("Help Topics & Glossary") {
                    compactModeController.performRequiringFullView {
                        presentationState.presentHelpHub()
                    }
                }
                .accessibilityIdentifier("joesProxyHelpMenuItem")

                Divider()

                Button("Guided Setup & Repair") {
                    compactModeController.performRequiringFullView {
                        presentationState.presentGuidedSetup()
                    }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .accessibilityIdentifier("joesProxyGuidedSetupMenuItem")

                Divider()

                Button("macOS Setup Guide") {
                    compactModeController.performRequiringFullView {
                        presentationState.presentMacOSSetupWalkthrough()
                    }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("iOS Setup Guide") {
                    compactModeController.performRequiringFullView {
                        presentationState.presentIOSSetupWalkthrough()
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Apple TV Setup Guide") {
                    compactModeController.performRequiringFullView {
                        presentationState.presentTVOSSetupWalkthrough()
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Simulator Setup Guide") {
                    compactModeController.performRequiringFullView {
                        presentationState.presentSimulatorSetupWalkthrough()
                    }
                }
            }
            }
        }

        MenuBarExtra(isInserted: menuBarItemInsertedBinding) {
            if isAgentWorkspaceActive {
                EmptyView()
            } else {
                SystemProxyMenuBarView(
                    viewModel: viewModel,
                    systemProxyController: coordinator.systemProxyController,
                    routingModel: coordinator.systemProxyRoutingModel,
                    compactModeController: coordinator.compactModeController,
                    mcpServerController: coordinator.mcpServerController,
                    presentationState: presentationState
                )
            }
        } label: {
            SystemProxyMenuBarLabel(
                systemProxyController: coordinator.systemProxyController,
                routingModel: coordinator.systemProxyRoutingModel
            )
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var agentMainWindowContent: some View {
        AgentMonitoringView(coordinator: coordinator, compact: compactModeController)
        .environment(\.appTextScale, settingsViewModel.appTextSize.fontScale)
    }

    /// The Agent shell intentionally exposes only supervision routes. Opening Inspector is the
    /// sole command that can construct its presentation model.
    @CommandsBuilder
    private var agentWorkspaceCommands: some Commands {
        CommandGroup(replacing: .appSettings) {
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .appInfo) {
            Button("About JoesProxy") { presentationState.presentAbout() }
        }
        CommandGroup(replacing: .newItem) { }
        CommandGroup(replacing: .saveItem) { }

        CommandMenu("Agent Workspace") {
            Button("Open Inspector") {
                compactModeController.performRequiringFullView {
                    inspectorHost.openInspector()
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Button("MCP Approvals") { openWindow(id: "agent-approvals") }
            Button("MCP Management…") { openWindow(id: "agent-management") }
            Button("Setup Readiness") { openWindow(id: "agent-setup-readiness") }
            Button("Capture Recovery") { openWindow(id: "agent-capture-recovery") }
            Button("Save Capture…") { openWindow(id: "agent-save-capture") }
        }

        CommandMenu("Proxy") {
            Button("Start Proxy") { coordinator.agentRuntimeControls.start() }
                .disabled(!coordinator.agentRuntimeControls.canStart)
            Button("Stop Proxy") { coordinator.agentRuntimeControls.stop() }
                .disabled(!coordinator.agentRuntimeControls.canStop)
        }

        CommandMenu("MCP") {
            Button("Start MCP") { Task { await mcpServerController.start() } }
                .disabled(!mcpServerController.canStartMCP)
            Button("Stop MCP") { Task { await mcpServerController.stop() } }
                .disabled(!mcpServerController.canStopMCP)
        }
    }

    /// Status-item insertion is deferred until the main window appears and suppressed for UI-test
    /// launches. UI tests run XCTest in a separate process, so checking for XCTest classes in the
    /// app process does not identify them reliably.
    private var menuBarItemInsertedBinding: Binding<Bool> {
        let menuBarRequired = settingsViewModel.runInMenuBarOnly || settingsViewModel.showSystemProxyMenuBarItem
        if uiTestLaunchConfiguration != nil
            || NSClassFromString("XCTestCase") != nil
            || !isMenuBarItemInsertionAllowed
            || !menuBarRequired {
            return .constant(false)
        }
        return Binding(
            get: { true },
            set: { isInserted in
                guard settingsViewModel.showSystemProxyMenuBarItem != isInserted else { return }
                settingsViewModel.showSystemProxyMenuBarItem = isInserted
            }
        )
    }

    // MARK: - Private helpers

    private var rollingCaptureRestoreOfferBinding: Binding<RollingCaptureRestoreOffer?> {
        guard !isAgentWorkspaceActive else { return .constant(nil) }
        return Binding(
            get: { viewModel.rollingCaptureRestoreOffer },
            set: { viewModel.rollingCaptureRestoreOffer = $0 }
        )
    }

    private func utilityWindow(_ kind: UtilityWindowKind) -> some View {
        UtilityWindowView(kind: kind, presentation: presentationState, controller: mcpServerController,
            validation: coordinator.selfValidationCoordinator, compact: compactModeController,
            textScale: settingsViewModel.appTextSize.fontScale)
    }

    private func handleOpenURL(_ url: URL) {
        if url.scheme == "joesproxy", url.host == "automation", url.path == "/start-mcp" {
            Task { await coordinator.mcpServerController.startFromCLI() }
            return
        }

        // joesproxy://session/<uuid> — deep link from the iOS SDK developer overlay.
        if url.scheme == "joesproxy",
           url.host == "session",
           let uuidString = url.pathComponents.dropFirst().first,
           let uuid = UUID(uuidString: uuidString) {
            compactModeController.performRequiringFullView {
                inspectorHost.openInspector()
                viewModel.selectSessionFromUser(uuid)
            }
            return
        }

        // Launch Services may not know debug-build UTIs yet, so prefer the extension.
        let isReproPackage = url.pathExtension.lowercased() == "jproxy-repro"
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .jproxyReproductionPackage) == true
        if isReproPackage {
            openReproPackage(url)
            return
        }

        let isRecording = url.pathExtension.lowercased() == "jproxy"
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .jproxyRecording) == true
        guard isRecording else { return }

        compactModeController.performRequiringFullView {
            inspectorHost.openInspector()
            if !viewModel.hasSessions {
                Task { await viewModel.openRecording(from: url, mode: .replace) }
            } else {
                presentationState.pendingRecordingURL = IdentifiableURL(url: url)
            }
        }
    }

    private func presentCurrentReproPackage() {
        compactModeController.performRequiringFullView {
            do {
                let package = try viewModel.makeCurrentReproPackage()
                presentationState.reproPackageContext = ReproPackagePresentationContext(
                    package: package,
                    allowsSaving: true
                )
            } catch {
                viewModel.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func openReproPackage(_ url: URL) {
        compactModeController.performRequiringFullView {
            inspectorHost.openInspector()
            Task {
                do {
                    let package = try await viewModel.openReproPackage(from: url)
                    presentationState.reproPackageContext = ReproPackagePresentationContext(
                        package: package,
                        allowsSaving: false
                    )
                } catch {
                    viewModel.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func importHARAsReproPackage(_ url: URL) {
        compactModeController.performRequiringFullView {
            Task {
                do {
                    let package = try await viewModel.makeReproPackage(fromHAR: url)
                    presentationState.reproPackageContext = ReproPackagePresentationContext(
                        package: package,
                        allowsSaving: true
                    )
                } catch {
                    viewModel.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func showSaveRecordingPanel(selectedOnly: Bool) {
        guard let selection = recordingFileCoordinator.promptForSaveSelection(
            defaultName: selectedOnly ? "Selected Recording" : "Recording"
        ) else { return }

        // Encode + write run off the main thread; progress/failure surface via exportState.
        Task {
            if selectedOnly {
                try? await viewModel.saveSelectedRecordingInBackground(to: selection.url, fidelity: selection.fidelity)
            } else {
                try? await viewModel.saveRecordingInBackground(to: selection.url, fidelity: selection.fidelity)
            }
        }
    }

    private func showExportPanel(format: ProxyViewModel.ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = format == .har ? "export.har" : "export.json"
        panel.title = format == .har ? "Export to HAR" : "Export JSON"
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            try? await viewModel.exportAllSessionsInBackground(to: url, as: format)
        }
    }

    private func showExportSkillPanel() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = MCPAgentExportService.skillFileName
        panel.title = "Export MCP Skill"
        panel.prompt = "Export"
        panel.message = "Portable diagnostic playbook for AI agents — no credential, endpoint, or captured traffic data. Drop into .claude/skills/, .cursor/skills/, etc."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MCPAgentExportService.standaloneSkillMarkdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("MCP skill export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Applies UI-test launch arguments to presentation state.
    ///
    /// MainActor-only. When first-run path choice and an in-memory rolling-capture restore
    /// are both requested, ``LaunchInterruptionArbitrator`` keeps a single primary surface (BA-2).
    @MainActor
    private func applyUITestPresentationStateIfNeeded(using configuration: UITestLaunchConfiguration) {
        if configuration.opensCertificateSetup, !presentationState.isCertificateSetupPresented {
            presentationState.presentCertificateSetup()
        }

        if configuration.opensSimulatorSetup, !presentationState.isSimulatorSetupWalkthroughPresented {
            presentationState.presentSimulatorSetupWalkthrough()
        }

        if configuration.opensIOSSetup, !presentationState.isIOSSetupWalkthroughPresented {
            presentationState.presentIOSSetupWalkthrough()
        }

        if let exportDestinationPath = configuration.exportDestinationPath {
            presentationState.visualizationExportPNGDestinationOverride = URL(fileURLWithPath: exportDestinationPath)
        }

        if configuration.rollingRestore == .offered {
            viewModel.installUITestRollingCaptureRestoreOffer()
            coordinator.previousRunDiagnosticsCoordinator.installUITestReport()
        }

        guard presentationState.guidedSetupContext == nil else {
            return
        }

        let firstRunPending = configuration.guidedSetupMode == .firstRun
        let launchFacts = LaunchInterruptionArbitrator.LaunchFacts(
            hasUnsavedCaptureRestorationOffer: viewModel.rollingCaptureRestoreOffer != nil,
            onboardingLifecycle: firstRunPending ? .notStarted : .completed
        )
        if LaunchInterruptionArbitrator.nextInterruption(from: launchFacts) == .savedCaptureRestoration {
            return
        }

        guard let mode = configuration.guidedSetupMode ?? (configuration.guidedSetupBlockingState != nil ? .repair : nil) else {
            return
        }

        let section = configuration.guidedSetupSection ?? .welcome
        switch mode {
        case .firstRun:
            presentationState.presentFirstRunPathChoiceIfNeeded()
        case .replay:
            presentationState.presentGuidedSetup(section: section, mode: .replay)
        case .repair:
            let blockingState = configuration.guidedSetupBlockingState ?? .installedTrustRequired
            presentationState.presentGuidedSetup(section: section, mode: .repair(blockingState))
        }
    }

    // MARK: - Compact Mode active-effects tile actions

    /// Traffic modification management opens independently of the capture workspace.
    /// Bookmark navigation still explicitly enters the investigation workspace.
    private var capacityNotice: CaptureAdmissionNotice {
        CaptureAdmissionNotice(budget: coordinator.sessionRecorder.admission, store: coordinator.sessionStore,
                               dismissedGap: $dismissedCapacityGap) {
            settingsViewModel.requestCapacitySettings()
            openSettings()
        }
    }

    private func openActiveEffectDestination(_ tileID: String) {
        switch tileID {
        case "mapLocal", "mapRemote", "block", "liveRewrite",
             "hlsSubstitution", "openAPIMock", "syntheticInjection":
            openWindow(id: TrafficModificationsWindowView.windowID)
        case "bookmarkRewrite":
            compactModeController.performRequiringFullView {
                WorkspaceCommandCenter.post(.showBookmarks)
            }
        default: // "throttle", "tunnel"
            openSettings()
        }
    }

    /// Option B: right-click → quick, blunt "turn it off" without leaving compact mode. Always
    /// category-wide (never a single rule) — see the ADR discussion on why per-rule control from a
    /// passive HUD isn't offered, particularly for MCP-origin rules whose approval/attribution trail
    /// this shortcut deliberately does not try to replicate.
    private func disableAllActiveEffect(_ tileID: String) {
        Task { @MainActor in
            if tileID == "tunnel" {
                coordinator.systemProxyRoutingModel.isRoutingEnabled = false
                return
            }
            do {
                try await coordinator.agentEffectsMonitor.disableAll(in: tileID)
            } catch {
                logger.error("Agent effect stop failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Settings that remain useful before the Inspector exists.  Detailed capture and export
/// preferences remain in the Inspector settings surface and therefore retain its ownership.

/// Shown for one brief tick while exiting compact mode, before `ContentView` remounts — see
/// `CompactModeController.exitCompactMode()`. Keeps the window from appearing frozen or blank
/// while the heavier full-UI view hierarchy builds back up.
private struct CompactModeRestoringView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Restoring JoesProxy…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
