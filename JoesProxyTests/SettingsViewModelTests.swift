import Combine
import XCTest
@testable import JoesProxy

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testRestorePromptDefaultsOnPersistsAndResetsWithoutDisablingCheckpoints() {
        let defaults = makeDefaults()
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        XCTAssertTrue(configuration.rollingCaptureRestorePromptEnabled)
        configuration.rollingCaptureRestorePromptEnabled = false
        XCTAssertFalse(UserDefaultsAppConfiguration(userDefaults: defaults).rollingCaptureRestorePromptEnabled)
        XCTAssertTrue(configuration.rollingCaptureAutoSaveEnabled)
        configuration.resetToDefaults()
        XCTAssertTrue(configuration.rollingCaptureRestorePromptEnabled)
    }
    func testSystemProxyRoutingDefaultsOffAndResetDisablesIt() {
        let defaults = makeDefaults()
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertFalse(configuration.isSystemProxyManagementEnabled)
        XCTAssertFalse(configuration.hasAcknowledgedSystemProxyRouting)

        configuration.isSystemProxyManagementEnabled = true
        configuration.hasAcknowledgedSystemProxyRouting = true
        configuration.resetToDefaults()

        XCTAssertFalse(configuration.isSystemProxyManagementEnabled)
        XCTAssertFalse(configuration.hasAcknowledgedSystemProxyRouting)
    }

    func testSDKEventServerToggleDefaultsToFalse() {
        let defaults = makeDefaults()
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertFalse(configuration.sdkEventServerEnabled)
        XCTAssertEqual(configuration.sdkEventServerPort, 9091)
    }

    func testSDKEventServerTogglePersistsAndReloads() {
        let defaults = makeDefaults()
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        configuration.sdkEventServerEnabled = true
        let reloaded = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertTrue(reloaded.sdkEventServerEnabled)
        XCTAssertEqual(reloaded.sdkEventServerPort, 9091)
    }

    func testResetRestoresSDKEventServerDisabled() {
        let defaults = makeDefaults()
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.sdkEventServerEnabled = true

        configuration.resetToDefaults()

        XCTAssertFalse(configuration.sdkEventServerEnabled)
    }

    func testNetworkThrottleDefaultsPersistAndReset() {
        let defaults = makeDefaults()
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertFalse(configuration.networkThrottleConfiguration.isEnabled)
        XCTAssertEqual(configuration.networkThrottleConfiguration.presets.count, 6)
        XCTAssertEqual(configuration.networkThrottleConfiguration.selectedPreset?.name, "Mobile 3G")

        var throttling = configuration.networkThrottleConfiguration
        throttling.isEnabled = true
        throttling.selectedPresetID = NetworkThrottlePresetID.modem56k
        configuration.networkThrottleConfiguration = throttling

        let reloaded = UserDefaultsAppConfiguration(userDefaults: defaults)
        XCTAssertTrue(reloaded.networkThrottleConfiguration.isEnabled)
        XCTAssertEqual(reloaded.networkThrottleConfiguration.selectedPreset?.name, "56k Modem")

        reloaded.resetToDefaults()

        XCTAssertFalse(reloaded.networkThrottleConfiguration.isEnabled)
        XCTAssertEqual(reloaded.networkThrottleConfiguration.selectedPreset?.name, "Mobile 3G")
    }

    func testSettingsViewModelUpdatesSDKEventServerSettingWhileProxyStopped() {
        let configuration = SettingsTestConfiguration()
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: SettingsTestProxyRuntime())

        viewModel.sdkEventServerEnabled = true

        XCTAssertTrue(configuration.sdkEventServerEnabled)
    }

    func testSettingsViewModelUpdatesSDKEventServerSettingWhileProxyRunning() {
        let configuration = SettingsTestConfiguration()
        let runtime = SettingsTestProxyRuntime(initialState: .running(port: 9090))
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: runtime)

        viewModel.sdkEventServerEnabled = true

        XCTAssertTrue(configuration.sdkEventServerEnabled)
        XCTAssertEqual(viewModel.proxyStatusDescription, "Running")
    }

    func testSettingsViewModelRefreshesSDKEventServerStatus() async {
        let configuration = SettingsTestConfiguration()
        let runtime = SettingsTestProxyRuntime(
            sdkEventServerStatus: SDKEventServerStatus(
                isRunning: true,
                port: 9091,
                pairingToken: "abc123",
                connectedClientCount: 2
            )
        )
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: runtime)

        await viewModel.refreshSDKEventServerStatus()

        XCTAssertEqual(viewModel.sdkEventServerStatusDescription, "Running")
        XCTAssertEqual(viewModel.sdkEventServerPortDescription, "9091")
        XCTAssertEqual(viewModel.sdkEventServerPairingTokenDescription, "abc123")
        XCTAssertEqual(viewModel.sdkEventServerClientCountDescription, "2")
        XCTAssertTrue(viewModel.shouldShowSDKEventServerPairingToken)
    }

    func testSettingsViewModelHidesPairingTokenWhenSDKServerIsStopped() async {
        let configuration = SettingsTestConfiguration()
        let runtime = SettingsTestProxyRuntime(
            sdkEventServerStatus: SDKEventServerStatus(
                isRunning: false,
                port: nil,
                pairingToken: "abc123",
                connectedClientCount: 0
            )
        )
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: runtime)

        await viewModel.refreshSDKEventServerStatus()

        XCTAssertEqual(viewModel.sdkEventServerStatusDescription, "Stopped")
        XCTAssertEqual(viewModel.sdkEventServerPairingTokenDescription, "abc123")
        XCTAssertFalse(viewModel.shouldShowSDKEventServerPairingToken)
    }

    func testSettingsViewModelAppliesThrottlePresetDraft() {
        let configuration = SettingsTestConfiguration()
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: SettingsTestProxyRuntime())
        viewModel.selectedThrottlePresetID = NetworkThrottlePresetID.custom

        viewModel.throttleDownstreamDraft = "512"
        viewModel.throttleUpstreamDraft = "128"
        viewModel.throttleLatencyDraft = "75"
        viewModel.applySelectedThrottlePresetDraft()

        let preset = configuration.networkThrottleConfiguration.selectedPreset
        XCTAssertEqual(preset?.id, NetworkThrottlePresetID.custom)
        XCTAssertEqual(preset?.downstreamKbps, 512)
        XCTAssertEqual(preset?.upstreamKbps, 128)
        XCTAssertEqual(preset?.latencyMs, 75)
        XCTAssertNil(viewModel.networkThrottleValidationMessage)
    }

    func testSettingsViewModelRejectsInvalidThrottleDraft() {
        let configuration = SettingsTestConfiguration()
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: SettingsTestProxyRuntime())
        viewModel.selectedThrottlePresetID = NetworkThrottlePresetID.custom

        viewModel.throttleDownstreamDraft = "0"
        viewModel.throttleUpstreamDraft = "128"
        viewModel.throttleLatencyDraft = "75"
        viewModel.applySelectedThrottlePresetDraft()

        XCTAssertEqual(
            viewModel.networkThrottleValidationMessage,
            "Enter downstream bandwidth as a whole number greater than 0 Kbps."
        )
        XCTAssertNotEqual(configuration.networkThrottleConfiguration.selectedPreset?.downstreamKbps, 0)
    }

    func testLiveCaptureBodySizeLimitDefaultsTo1MBAndPersists() {
        let defaults = makeDefaults()
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertEqual(configuration.liveCaptureBodySizeLimit, 1_048_576)

        configuration.liveCaptureBodySizeLimit = 2_097_152
        let reloaded = UserDefaultsAppConfiguration(userDefaults: defaults)
        XCTAssertEqual(reloaded.liveCaptureBodySizeLimit, 2_097_152)

        reloaded.resetToDefaults()
        XCTAssertEqual(reloaded.liveCaptureBodySizeLimit, 1_048_576)
    }

    func testLiveCaptureBodySizeLimitClampsToBounds() {
        let defaults = makeDefaults()
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        configuration.liveCaptureBodySizeLimit = 100 // Below 64 KB minimum
        XCTAssertEqual(configuration.liveCaptureBodySizeLimit, 65_536)

        configuration.liveCaptureBodySizeLimit = 100_000_000 // Above 50 MB maximum
        XCTAssertEqual(configuration.liveCaptureBodySizeLimit, 52_428_800)
    }

    func testSettingsViewModelValidatesAndAppliesLiveCaptureBodyLimit() {
        let configuration = SettingsTestConfiguration()
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: SettingsTestProxyRuntime())

        XCTAssertEqual(viewModel.liveCaptureBodyLimitDraft, "1024")

        viewModel.liveCaptureBodyLimitDraft = "2048"
        viewModel.applyLiveCaptureBodyLimit()

        XCTAssertEqual(configuration.liveCaptureBodySizeLimit, 2_097_152)
        XCTAssertEqual(viewModel.liveCaptureBodyLimitDraft, "2048")
        viewModel.liveCaptureBodyLimitDraft = "10" // Invalid < 64
        viewModel.applyLiveCaptureBodyLimit()

        XCTAssertEqual(
            viewModel.liveCaptureBodyLimitValidationMessage,
            "Enter a whole-number limit between 64 KB and 51,200 KB (50 MB)."
        )
        XCTAssertEqual(configuration.liveCaptureBodySizeLimit, 2_097_152)
    }

    func testAutoScrollPreferenceDefaultsToTrueAndPersists() {
        let defaults = makeDefaults()
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertTrue(configuration.isSessionAutoScrollEnabled)

        configuration.isSessionAutoScrollEnabled = false
        let reloaded = UserDefaultsAppConfiguration(userDefaults: defaults)
        XCTAssertFalse(reloaded.isSessionAutoScrollEnabled)

        reloaded.resetToDefaults()
        XCTAssertTrue(reloaded.isSessionAutoScrollEnabled)
    }

    func testSettingsViewModelUpdatesAutoScrollPreference() {
        let configuration = SettingsTestConfiguration()
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: SettingsTestProxyRuntime())

        XCTAssertTrue(viewModel.isSessionAutoScrollEnabled)

        viewModel.isSessionAutoScrollEnabled = false
        XCTAssertFalse(configuration.isSessionAutoScrollEnabled)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SettingsViewModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class SettingsTestProxyRuntime: ProxyRuntime {
    private let stateSubject: CurrentValueSubject<ProxyRuntimeState, Never>
    private let sdkStatus: SDKEventServerStatus

    init(
        initialState: ProxyRuntimeState = .stopped,
        sdkEventServerStatus: SDKEventServerStatus = .stopped
    ) {
        self.stateSubject = CurrentValueSubject(initialState)
        self.sdkStatus = sdkEventServerStatus
    }

    var currentState: ProxyRuntimeState {
        stateSubject.value
    }

    var statePublisher: AnyPublisher<ProxyRuntimeState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    func start() async {}
    func stop() async {}

    func sdkEventServerStatus() async -> SDKEventServerStatus {
        sdkStatus
    }
}

private final class SettingsTestConfiguration: AppConfiguration {
    var proxyPort: UInt16 = 9090 { didSet { didChangeSubject.send(()) } }
    var logLevel: AppLogLevel = .info { didSet { didChangeSubject.send(()) } }
    var verboseHTTPSLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var isFindDebugLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var appTextSizeRawValue = AppTextSize.standard.rawValue { didSet { didChangeSubject.send(()) } }
    var isInspectorCopyRedactionEnabled = true { didSet { didChangeSubject.send(()) } }
    var sessionSortFieldRawValue = ProxyViewModel.SessionSortField.startedAt.rawValue { didSet { didChangeSubject.send(()) } }
    var isSessionSortAscending = false { didSet { didChangeSubject.send(()) } }
    var isSessionAutoScrollEnabled = true { didSet { didChangeSubject.send(()) } }
    var sessionBrowserModeRawValue = SessionBrowserMode.table.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerGroupingRawValue = SessionExplorerGrouping.byHost.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.exactHosts.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerExpandedNodeIDs: [String] = [] { didSet { didChangeSubject.send(()) } }
    var sessionInspectorSplitFraction = 0.62 { didSet { didChangeSubject.send(()) } }
    var httpsBypassDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var httpsInterceptDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var isNoCachingEnabled = false { didSet { didChangeSubject.send(()) } }
    var noCachingDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var isSystemProxyManagementEnabled = false { didSet { didChangeSubject.send(()) } }
    var systemProxyStrictCapture = false { didSet { didChangeSubject.send(()) } }
    var hasAcknowledgedSystemProxyRouting = false { didSet { didChangeSubject.send(()) } }
    var showSystemProxyMenuBarItem = false { didSet { didChangeSubject.send(()) } }
    var runInMenuBarOnly = false
    var onboardingProgressRecord = OnboardingProgressRecord(lifecycle: .notStarted) { didSet { didChangeSubject.send(()) } }
    var preferredWorkingView: WorkingViewPreference = .inspector { didSet { didChangeSubject.send(()) } }
    var hasCompletedInitialGuidedSetupPresentation = false { didSet { didChangeSubject.send(()) } }
    var warnsBeforeQuittingWithUnsavedSessions = true { didSet { didChangeSubject.send(()) } }
    var sdkEventServerEnabled = false { didSet { didChangeSubject.send(()) } }
    var sdkEventServerPort: UInt16 { 9091 }
    var networkThrottleConfiguration = NetworkThrottleConfiguration.defaults { didSet { didChangeSubject.send(()) } }
    var profileHostStrategyRawValue = ProfileHostStrategy.bonjourLocal.rawValue { didSet { didChangeSubject.send(()) } }
    var manualProfileHost = "" { didSet { didChangeSubject.send(()) } }
    var responseOverridesData: Data? { didSet { didChangeSubject.send(()) } }
    var captureRetentionPolicy: CaptureRetentionPolicy = .unlimited { didSet { didChangeSubject.send(()) } }
    var liveCaptureBodySizeLimit: Int = 1_048_576 { didSet { didChangeSubject.send(()) } }
    let certificateLabel = "SettingsTestRoot"

    private let didChangeSubject = PassthroughSubject<Void, Never>()

    var didChangePublisher: AnyPublisher<Void, Never> {
        didChangeSubject.eraseToAnyPublisher()
    }

    func resetToDefaults() {
        onboardingProgressRecord = OnboardingProgressRecord(lifecycle: .notStarted)
        preferredWorkingView = .inspector
        hasCompletedInitialGuidedSetupPresentation = false
        sdkEventServerEnabled = false
        networkThrottleConfiguration = .defaults
        liveCaptureBodySizeLimit = 1_048_576
    }
}
