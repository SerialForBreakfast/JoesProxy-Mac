#if AGW4_AGENT_TARGET
import SwiftUI

/// Candidate C's non-shipping entry point. It deliberately composes the same runtime-backed HUD
/// as the Agent workspace while using an isolated in-memory capture store and configuration suite.
/// Inspector presentation is not available in this target.
@main
struct AgentPrototypeApp: App {
    private let coordinator: AppCoordinator
    private let agentProfile: AgentWorkspaceProfile?
    @ObservedObject private var compactModeController: CompactModeController
    @StateObject private var settings: SettingsViewModel
    private let profilingMemoryGuard: ProfilingMemoryGuard?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        let profileConfiguration = AgentWorkspaceProfileConfiguration(arguments: arguments, environment: environment)
        precondition(!arguments.contains("--agent-workspace-profile") || profileConfiguration != nil,
                     "Invalid isolated Agent profiling configuration")
        let isUITesting = arguments.contains { $0.hasPrefix("--ui-test-") }
        let testPort = arguments.first { $0.hasPrefix(LaunchArgument.uiTestProxyPortPrefix) }
            .flatMap { UInt16($0.dropFirst(LaunchArgument.uiTestProxyPortPrefix.count)) }
        let demoSessions = arguments.contains(LaunchArgument.uiTestFixturePrefix + "demo-sessions")
        let sessionCount = arguments.first { $0.hasPrefix(LaunchArgument.uiTestSessionCountPrefix) }
            .flatMap { Int($0.dropFirst(LaunchArgument.uiTestSessionCountPrefix.count)) }
        let isolated = isUITesting || profileConfiguration != nil
        AgentWorkspaceDiagnostics.shared.configure(arguments: arguments, environment: environment, isolated: isolated)
        if let guardConfiguration = ProfilingMemoryGuardConfiguration(
            arguments: arguments, environment: environment, isolated: isolated
        ) {
            let guardService = ProfilingMemoryGuard(configuration: guardConfiguration)
            profilingMemoryGuard = guardService
            guardService.start()
        } else { profilingMemoryGuard = nil }
        let profile = profileConfiguration.map { AgentWorkspaceProfile(configuration: $0) }
        agentProfile = profile
        let coordinator: AppCoordinator
        if let profile {
            coordinator = profile.coordinator
        } else {
            let defaultsSuiteName = !isUITesting
                ? "com.ShowBlender.JoesProxy.AgentPrototype"
                : "com.ShowBlender.JoesProxy.AgentPrototype.UITest"
            guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
                fatalError("The Agent Prototype requires its isolated preferences suite.")
            }
            if isUITesting {
                defaults.removePersistentDomain(forName: defaultsSuiteName)
            }
            let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
            configuration.rollingCaptureAutoSaveEnabled = false
            if let proxyPort = testPort {
                configuration.proxyPort = proxyPort
            }
            let sessionStore: any SessionStore
            if demoSessions {
                sessionStore = ScreenshotDemoSessions.makePreSeededSessionStore(count: sessionCount)
            } else {
                sessionStore = InMemorySessionStore(retentionPolicy: configuration.captureRetentionPolicy)
            }
            let certificateStore = UITestCertificateStore(identity: nil)
            let certificateAuthority = UITestCertificateAuthority(currentIdentity: nil)
            let storageRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("JoesProxyAgentPrototype", isDirectory: true)

            coordinator = AppCoordinator(
                configuration: configuration,
                sessionStore: sessionStore,
                certificateStore: certificateStore,
                certificateAuthority: certificateAuthority,
                trustInstaller: UITestTrustInstaller(status: .notInstalled),
                mcpCredentialStore: MCPInMemoryCredentialStore(),
                suppressesLaunchRecoveryOffers: true,
                recoveryStorageAccessEnabled: false,
                storageScope: RuntimeStorageScope(root: storageRoot, defaults: defaults)
            )
        }
        self.coordinator = coordinator
        coordinator.bootstrapSharedServices()
        profile?.start()
        _compactModeController = ObservedObject(wrappedValue: coordinator.compactModeController)
        _settings = StateObject(wrappedValue: SettingsViewModel(configuration: coordinator.configuration,
                                                               proxyRuntime: coordinator.proxyRuntime))
    }

    var body: some Scene {
        Window("JoesProxy Agent Prototype", id: "agent-prototype") {
            AgentMonitoringView(coordinator: coordinator, compact: compactModeController)
                .environment(\.appTextScale, settings.appTextSize.fontScale)
        }
        .defaultSize(width: 320, height: 260)
        .commands { AgentSupervisionCommands() }
        AgentSupervisionScenes(coordinator: coordinator, textScale: settings.appTextSize.fontScale)
        Settings {
            AgentWorkspaceSettingsView(viewModel: settings, supportsInspector: false)
                .environment(\.appTextScale, settings.appTextSize.fontScale)
        }
    }
}
#endif
