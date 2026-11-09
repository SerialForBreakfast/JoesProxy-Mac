import Combine
import Foundation

enum CertificateNaming {
    static let productionRootCA = "JoesProxy Root CA"
}

enum LaunchArgument {
    static let verboseHTTPSLogging = "--verbose-https-logging"
    static let longCaptureDiagnostics = "--long-capture-diagnostics"
    static let debugUILifecycle = "--debug-ui-lifecycle"
    static let debugFindLogging = "--debug-find-logging"
    static let screenshotDemo = "--screenshot-demo"
    static let screenshotBrowserModePrefix = "--screenshot-browser-mode="
    static let screenshotTextSizePrefix = "--screenshot-text-size="
    static let screenshotDemoSessionCountPrefix = "--screenshot-demo-session-count="
    static let uiTestFixturePrefix = "--ui-test-fixture="
    static let uiTestBrowserModePrefix = "--ui-test-browser-mode="
    static let uiTestTextSizePrefix = "--ui-test-text-size="
    static let uiTestSessionCountPrefix = "--ui-test-session-count="
    static let uiTestProxyPortPrefix = "--ui-test-proxy-port="
    static let uiTestCertificateStatePrefix = "--ui-test-certificate-state="
    static let uiTestVerificationStatePrefix = "--ui-test-verification-state="
    static let uiTestGuidedSetupSectionPrefix = "--ui-test-guided-setup-section="
    static let uiTestGuidedSetupModePrefix = "--ui-test-guided-setup-mode="
    static let uiTestGuidedSetupBlockingStatePrefix = "--ui-test-guided-setup-blocking-state="
    static let uiTestOpenCertificateSetup = "--ui-test-open-certificate-setup"
    static let uiTestOpenSimulatorSetup = "--ui-test-open-simulator-setup"
    static let uiTestOpenIOSSetup = "--ui-test-open-ios-setup"
    static let uiTestExportDestinationPathPrefix = "--ui-test-export-destination-path="
    static let uiTestMCPStatusPrefix = "--ui-test-mcp-status="
    /// In-memory rolling-capture restore offer for UI tests (`offered`). Does not read or write snapshots.
    static let uiTestRollingRestorePrefix = "--ui-test-rolling-restore="
    static let uiTestSuppressLaunchRecovery = "--ui-test-suppress-launch-recovery"
    /// Forces this launch to start in compact mode regardless of the persisted
    /// `preferredWorkingView` preference — for agent/automated launches that only need the proxy
    /// running and MCP approvals reachable, never the full session UI (`ContentView`, and with it
    /// `JSONViewerSheet`/Explorer/Timeline, is not constructed at all in compact mode). Does not
    /// overwrite the persisted preference, so a human's own last manual choice is unaffected once
    /// they launch normally again.
    static let forceCompactMode = "--compact-mode"
    static let forceAgentWorkspace = "--agent-workspace"
}

enum RuntimeDebugFlag {
    static var isVerboseHTTPSLoggingEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(LaunchArgument.verboseHTTPSLogging)
    }

    static var isLongCaptureDiagnosticsEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(LaunchArgument.longCaptureDiagnostics)
    }

    static var isUILifecycleLoggingEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(LaunchArgument.debugUILifecycle)
    }

    static var isFindDebugLoggingEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(LaunchArgument.debugFindLogging)
    }

    static var suppressesLaunchRecoveryForUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains(LaunchArgument.uiTestSuppressLaunchRecovery)
    }

    static var isCompactModeForced: Bool {
        ProcessInfo.processInfo.arguments.contains(LaunchArgument.forceCompactMode)
    }

    static var isAgentWorkspaceForced: Bool {
        ProcessInfo.processInfo.arguments.contains(LaunchArgument.forceAgentWorkspace)
    }
}

enum AppLogLevel: String, CaseIterable, Codable {
    case debug
    case info
    case warning
    case error
}

enum AppTextSize: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case small
    case standard
    case large
    case extraLarge
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small:
            return "Small"
        case .standard:
            return "Standard"
        case .large:
            return "Large"
        case .extraLarge:
            return "Extra Large"
        case .accessibility:
            return "Accessibility"
        }
    }
}

protocol AppConfiguration: AnyObject {
    var proxyPort: UInt16 { get set }
    var logLevel: AppLogLevel { get set }
    var verboseHTTPSLoggingEnabled: Bool { get set }
    var isFindDebugLoggingEnabled: Bool { get set }
    var appTextSizeRawValue: String { get set }
    var isInspectorCopyRedactionEnabled: Bool { get set }
    var sessionSortFieldRawValue: String { get set }
    var isSessionSortAscending: Bool { get set }
    var isSessionAutoScrollEnabled: Bool { get set }
    var sessionBrowserModeRawValue: String { get set }
    var sessionExplorerGroupingRawValue: String { get set }
    var sessionExplorerHostGroupingRawValue: String { get set }
    var sessionExplorerExpandedNodeIDs: [String] { get set }
    var sessionInspectorSplitFraction: Double { get set }
    var httpsBypassDomains: [String] { get set }
    var httpsInterceptDomains: [String] { get set }
    var isNoCachingEnabled: Bool { get set }
    var noCachingDomains: [String] { get set }
    var isSystemProxyManagementEnabled: Bool { get set }
    var systemProxyStrictCapture: Bool { get set }
    var hasAcknowledgedSystemProxyRouting: Bool { get set }
    var showSystemProxyMenuBarItem: Bool { get set }
    /// When true, launch as menu-bar-only (``.accessory``) with no Dock icon until Open JoesProxy.
    var runInMenuBarOnly: Bool { get set }
    /// Versioned first-run lifecycle. This record contains no live runtime claims.
    var onboardingProgressRecord: OnboardingProgressRecord { get set }
    /// Safe presentation hints for returning launch projection.
    var sessionStartPresentationRecord: SessionStartPresentationRecord { get set }
    /// Global working surface restored before live-state reconciliation.
    var preferredWorkingView: WorkingViewPreference { get set }
    /// Persisted composition choice, intentionally distinct from Compact presentation.
    var launchWorkspacePreference: LaunchWorkspacePreference { get set }
    var hasCompletedInitialGuidedSetupPresentation: Bool { get set }
    var warnsBeforeQuittingWithUnsavedSessions: Bool { get set }
    /// User intent for silent, operator-actionable MCP system notifications.
    var mcpSystemNotificationsEnabled: Bool { get set }
    var sdkEventServerEnabled: Bool { get set }
    var sdkEventServerPort: UInt16 { get }
    var networkThrottleConfiguration: NetworkThrottleConfiguration { get set }
    var profileHostStrategyRawValue: String { get set }
    var manualProfileHost: String { get set }
    var responseOverridesData: Data? { get set }
    var certificateLabel: String { get }
    /// Active session retention policy. Production defaults cap retained bodies at 250 MiB.
    var captureRetentionPolicy: CaptureRetentionPolicy { get set }
    /// Maximum bytes retained from each individual live response body for inspection.
    /// Defaults to 1 MB (`RecordingConstants.liveCaptureBodySizeLimit`).
    var liveCaptureBodySizeLimit: Int { get set }
    /// When true, periodically writes rolling `.jproxy` snapshots for post-quit recovery.
    var rollingCaptureAutoSaveEnabled: Bool { get set }
    var rollingCaptureRestorePromptEnabled: Bool { get set }
    /// When true, periodically records content-free diagnostics for previous-run recovery.
    var previousRunDiagnosticsEnabled: Bool { get set }
    /// Seconds between debounced rolling saves while capture is active.
    var rollingCaptureSaveIntervalSeconds: Int { get set }
    /// Flush rolling save after this many newly captured sessions.
    var rollingCaptureSaveSessionThreshold: Int { get set }
    /// Number of rotated rolling snapshot files to retain.
    var rollingCaptureRetentionCount: Int { get set }
    /// Maximum on-disk budget for rolling snapshots, in megabytes.
    var rollingCaptureMaxDiskMB: Int { get set }
    var didChangePublisher: AnyPublisher<Void, Never> { get }

    func resetToDefaults()
}

/// Default rolling-capture settings for test and ephemeral ``AppConfiguration`` conformers.
/// Production ``UserDefaultsAppConfiguration`` overrides these with persisted values.
extension AppConfiguration {
    var rollingCaptureRestorePromptEnabled: Bool {
        get { true }
        set { _ = newValue }
    }
    var previousRunDiagnosticsEnabled: Bool {
        get { true }
        set { _ = newValue }
    }
    var liveCaptureBodySizeLimit: Int {
        get { RecordingConstants.liveCaptureBodySizeLimit }
        set { _ = newValue }
    }

    var onboardingProgressRecord: OnboardingProgressRecord {
        get { OnboardingProgressRecord(lifecycle: .notStarted) }
        set { _ = newValue }
    }

    var preferredWorkingView: WorkingViewPreference {
        get { .inspector }
        set { _ = newValue }
    }

    var launchWorkspacePreference: LaunchWorkspacePreference {
        get { .inspector }
        set { _ = newValue }
    }

    var mcpSystemNotificationsEnabled: Bool {
        get { false }
        set { _ = newValue }
    }

    var sessionStartPresentationRecord: SessionStartPresentationRecord {
        get { .default }
        set { _ = newValue }
    }

    var rollingCaptureAutoSaveEnabled: Bool {
        get { true }
        set { _ = newValue }
    }

    var rollingCaptureSaveIntervalSeconds: Int {
        get { 60 }
        set { _ = newValue }
    }

    var rollingCaptureSaveSessionThreshold: Int {
        get { 100 }
        set { _ = newValue }
    }

    var rollingCaptureRetentionCount: Int {
        get { 5 }
        set { _ = newValue }
    }

    var rollingCaptureMaxDiskMB: Int {
        get { 500 }
        set { _ = newValue }
    }
}

final class UserDefaultsAppConfiguration: AppConfiguration {
    private enum Keys {
        static let proxyPort = "proxyPort"
        static let logLevel = "logLevel"
        static let verboseHTTPSLoggingEnabled = "verboseHTTPSLoggingEnabled"
        static let isFindDebugLoggingEnabled = "isFindDebugLoggingEnabled"
        static let appTextSizeRawValue = "appTextSizeRawValue"
        static let isInspectorCopyRedactionEnabled = "isInspectorCopyRedactionEnabled"
        static let sessionSortFieldRawValue = "sessionSortFieldRawValue"
        static let isSessionSortAscending = "isSessionSortAscending"
        static let isSessionAutoScrollEnabled = "isSessionAutoScrollEnabled"
        static let sessionBrowserModeRawValue = "sessionBrowserModeRawValue"
        static let sessionExplorerGroupingRawValue = "sessionExplorerGroupingRawValue"
        static let sessionExplorerHostGroupingRawValue = "sessionExplorerHostGroupingRawValue"
        static let sessionExplorerExpandedNodeIDs = "sessionExplorerExpandedNodeIDs"
        static let sessionInspectorSplitFraction = "sessionInspectorSplitFraction"
        static let httpsBypassDomains = "httpsBypassDomains"
        static let httpsInterceptDomains = "httpsInterceptDomains"
        static let isNoCachingEnabled = "isNoCachingEnabled"
        static let noCachingDomains = "noCachingDomains"
        static let isSystemProxyManagementEnabled = "isSystemProxyManagementEnabled"
        static let systemProxyStrictCapture = "systemProxyStrictCapture"
        static let hasAcknowledgedSystemProxyRouting = "hasAcknowledgedSystemProxyRouting"
        static let showSystemProxyMenuBarItem = "showSystemProxyMenuBarItem"
        static let runInMenuBarOnly = "runInMenuBarOnly"
        static let onboardingProgressData = "onboardingProgressData"
        static let sessionStartPresentationData = "sessionStartPresentationData"
        static let preferredWorkingViewRawValue = "preferredWorkingViewRawValue"
        static let launchWorkspacePreferenceRawValue = "launchWorkspacePreferenceRawValue"
        static let hasCompletedInitialGuidedSetupPresentation = "hasCompletedInitialGuidedSetupPresentation"
        static let warnsBeforeQuittingWithUnsavedSessions = "warnsBeforeQuittingWithUnsavedSessions"
        static let mcpSystemNotificationsEnabled = "mcpSystemNotificationsEnabled"
        static let sdkEventServerEnabled = "sdkEventServerEnabled"
        static let networkThrottleConfigurationData = "networkThrottleConfigurationData"
        static let profileHostStrategyRawValue = "profileHostStrategyRawValue"
        static let manualProfileHost = "manualProfileHost"
        static let legacySuppressQuitWarning = "com.JoesProxyApp.suppressQuitWarning"
        static let responseOverridesData = "responseOverridesData"
        static let captureRetentionPolicyData = "captureRetentionPolicyData"
        static let liveCaptureBodySizeLimit = "liveCaptureBodySizeLimit"
        static let rollingCaptureAutoSaveEnabled = "rollingCaptureAutoSaveEnabled"
        static let rollingCaptureRestorePromptEnabled = "rollingCaptureRestorePromptEnabled"
        static let rollingCaptureSaveIntervalSeconds = "rollingCaptureSaveIntervalSeconds"
        static let rollingCaptureSaveSessionThreshold = "rollingCaptureSaveSessionThreshold"
        static let rollingCaptureRetentionCount = "rollingCaptureRetentionCount"
        static let rollingCaptureMaxDiskMB = "rollingCaptureMaxDiskMB"
        static let previousRunDiagnosticsEnabled = "previousRunDiagnosticsEnabled"
    }

    private enum Defaults {
        static let proxyPort = NetworkConstants.defaultPort
        static let logLevel: AppLogLevel = .info
        static let verboseHTTPSLoggingEnabled = false
        static let isFindDebugLoggingEnabled = false
        static let appTextSizeRawValue = "standard"
        static let isInspectorCopyRedactionEnabled = true
        static let sessionSortFieldRawValue = "startedAt"
        static let isSessionSortAscending = false
        static let isSessionAutoScrollEnabled = true
        static let sessionBrowserModeRawValue = "table"
        static let sessionExplorerGroupingRawValue = "byHost"
        static let sessionExplorerHostGroupingRawValue = "exactHosts"
        static let sessionExplorerExpandedNodeIDs: [String] = []
        static let sessionInspectorSplitFraction = 0.62
        static let httpsBypassDomains: [String] = []
        static let httpsInterceptDomains: [String] = []
        static let isNoCachingEnabled = false
        static let noCachingDomains: [String] = []
        static let isSystemProxyManagementEnabled = false
        static let systemProxyStrictCapture = false
        static let hasAcknowledgedSystemProxyRouting = false
        static let showSystemProxyMenuBarItem = false
        static let runInMenuBarOnly = false
        static let onboardingProgressRecord = OnboardingProgressRecord(lifecycle: .notStarted)
        static let sessionStartPresentationRecord = SessionStartPresentationRecord.default
        static let preferredWorkingView: WorkingViewPreference = .inspector
        static let launchWorkspacePreference: LaunchWorkspacePreference = .inspector
        static let hasCompletedInitialGuidedSetupPresentation = false
        static let warnsBeforeQuittingWithUnsavedSessions = true
        static let mcpSystemNotificationsEnabled = false
        static let sdkEventServerEnabled = false
        static let sdkEventServerPort: UInt16 = 9091
        static let networkThrottleConfiguration = NetworkThrottleConfiguration.defaults
        static let profileHostStrategyRawValue = "bonjourLocal"
        static let manualProfileHost = ""
        static let responseOverridesData: Data? = nil
        static let captureRetentionPolicy: CaptureRetentionPolicy = .keepLastBodyBytes(250 * 1_048_576)
        static let liveCaptureBodySizeLimit = RecordingConstants.liveCaptureBodySizeLimit
        static let rollingCaptureAutoSaveEnabled = true
        static let rollingCaptureRestorePromptEnabled = true
        static let rollingCaptureSaveIntervalSeconds = 60
        static let rollingCaptureSaveSessionThreshold = 100
        static let rollingCaptureRetentionCount = 5
        static let rollingCaptureMaxDiskMB = 500
        static let previousRunDiagnosticsEnabled = true
    }

    private let userDefaults: UserDefaults
    private let didChangeSubject = PassthroughSubject<Void, Never>()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        migrateLegacyOnboardingStateIfNeeded()
    }

    var didChangePublisher: AnyPublisher<Void, Never> {
        didChangeSubject.eraseToAnyPublisher()
    }

    var proxyPort: UInt16 {
        get {
            let storedPort = userDefaults.integer(forKey: Keys.proxyPort)
            guard storedPort > 0, storedPort <= Int(UInt16.max) else {
                return Defaults.proxyPort
            }
            return UInt16(storedPort)
        }
        set {
            userDefaults.set(Int(newValue), forKey: Keys.proxyPort)
            notifyDidChange()
        }
    }

    var logLevel: AppLogLevel {
        get {
            guard let rawValue = userDefaults.string(forKey: Keys.logLevel),
                  let level = AppLogLevel(rawValue: rawValue) else {
                return Defaults.logLevel
            }
            return level
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Keys.logLevel)
            notifyDidChange()
        }
    }

    var verboseHTTPSLoggingEnabled: Bool {
        get {
            if RuntimeDebugFlag.isVerboseHTTPSLoggingEnabled {
                return true
            }
            return userDefaults.object(forKey: Keys.verboseHTTPSLoggingEnabled) as? Bool
                ?? Defaults.verboseHTTPSLoggingEnabled
        }
        set {
            userDefaults.set(newValue, forKey: Keys.verboseHTTPSLoggingEnabled)
            notifyDidChange()
        }
    }

    var isFindDebugLoggingEnabled: Bool {
        get {
            if RuntimeDebugFlag.isFindDebugLoggingEnabled {
                return true
            }
            return userDefaults.object(forKey: Keys.isFindDebugLoggingEnabled) as? Bool
                ?? Defaults.isFindDebugLoggingEnabled
        }
        set {
            userDefaults.set(newValue, forKey: Keys.isFindDebugLoggingEnabled)
            notifyDidChange()
        }
    }

    var appTextSizeRawValue: String {
        get {
            userDefaults.string(forKey: Keys.appTextSizeRawValue)
                ?? Defaults.appTextSizeRawValue
        }
        set {
            userDefaults.set(newValue, forKey: Keys.appTextSizeRawValue)
            notifyDidChange()
        }
    }

    var isInspectorCopyRedactionEnabled: Bool {
        get {
            userDefaults.object(forKey: Keys.isInspectorCopyRedactionEnabled) as? Bool
                ?? Defaults.isInspectorCopyRedactionEnabled
        }
        set {
            userDefaults.set(newValue, forKey: Keys.isInspectorCopyRedactionEnabled)
            notifyDidChange()
        }
    }

    var sessionSortFieldRawValue: String {
        get {
            userDefaults.string(forKey: Keys.sessionSortFieldRawValue)
                ?? Defaults.sessionSortFieldRawValue
        }
        set {
            userDefaults.set(newValue, forKey: Keys.sessionSortFieldRawValue)
            notifyDidChange()
        }
    }

    var isSessionSortAscending: Bool {
        get {
            userDefaults.object(forKey: Keys.isSessionSortAscending) as? Bool
                ?? Defaults.isSessionSortAscending
        }
        set {
            userDefaults.set(newValue, forKey: Keys.isSessionSortAscending)
            notifyDidChange()
        }
    }

    var isSessionAutoScrollEnabled: Bool {
        get {
            userDefaults.object(forKey: Keys.isSessionAutoScrollEnabled) as? Bool
                ?? Defaults.isSessionAutoScrollEnabled
        }
        set {
            userDefaults.set(newValue, forKey: Keys.isSessionAutoScrollEnabled)
            notifyDidChange()
        }
    }

    var sessionBrowserModeRawValue: String {
        get {
            userDefaults.string(forKey: Keys.sessionBrowserModeRawValue)
                ?? Defaults.sessionBrowserModeRawValue
        }
        set {
            userDefaults.set(newValue, forKey: Keys.sessionBrowserModeRawValue)
            notifyDidChange()
        }
    }

    var sessionExplorerGroupingRawValue: String {
        get {
            userDefaults.string(forKey: Keys.sessionExplorerGroupingRawValue)
                ?? Defaults.sessionExplorerGroupingRawValue
        }
        set {
            userDefaults.set(newValue, forKey: Keys.sessionExplorerGroupingRawValue)
            notifyDidChange()
        }
    }

    var sessionExplorerHostGroupingRawValue: String {
        get {
            userDefaults.string(forKey: Keys.sessionExplorerHostGroupingRawValue)
                ?? Defaults.sessionExplorerHostGroupingRawValue
        }
        set {
            userDefaults.set(newValue, forKey: Keys.sessionExplorerHostGroupingRawValue)
            notifyDidChange()
        }
    }

    var sessionExplorerExpandedNodeIDs: [String] {
        get {
            userDefaults.stringArray(forKey: Keys.sessionExplorerExpandedNodeIDs)
                ?? Defaults.sessionExplorerExpandedNodeIDs
        }
        set {
            userDefaults.set(newValue, forKey: Keys.sessionExplorerExpandedNodeIDs)
            notifyDidChange()
        }
    }

    var sessionInspectorSplitFraction: Double {
        get {
            let storedFraction = userDefaults.double(forKey: Keys.sessionInspectorSplitFraction)
            guard storedFraction > 0, storedFraction < 1 else {
                return Defaults.sessionInspectorSplitFraction
            }
            return storedFraction
        }
        set {
            userDefaults.set(newValue, forKey: Keys.sessionInspectorSplitFraction)
            notifyDidChange()
        }
    }

    var httpsBypassDomains: [String] {
        get {
            userDefaults.stringArray(forKey: Keys.httpsBypassDomains) ?? Defaults.httpsBypassDomains
        }
        set {
            userDefaults.set(newValue, forKey: Keys.httpsBypassDomains)
            notifyDidChange()
        }
    }

    var httpsInterceptDomains: [String] {
        get {
            userDefaults.stringArray(forKey: Keys.httpsInterceptDomains) ?? Defaults.httpsInterceptDomains
        }
        set {
            userDefaults.set(newValue, forKey: Keys.httpsInterceptDomains)
            notifyDidChange()
        }
    }

    var isNoCachingEnabled: Bool {
        get {
            userDefaults.object(forKey: Keys.isNoCachingEnabled) as? Bool ?? Defaults.isNoCachingEnabled
        }
        set {
            userDefaults.set(newValue, forKey: Keys.isNoCachingEnabled)
            notifyDidChange()
        }
    }

    var isSystemProxyManagementEnabled: Bool {
        get {
            userDefaults.object(forKey: Keys.isSystemProxyManagementEnabled) as? Bool ?? Defaults.isSystemProxyManagementEnabled
        }
        set {
            userDefaults.set(newValue, forKey: Keys.isSystemProxyManagementEnabled)
            notifyDidChange()
        }
    }

    var systemProxyStrictCapture: Bool {
        get {
            userDefaults.object(forKey: Keys.systemProxyStrictCapture) as? Bool ?? Defaults.systemProxyStrictCapture
        }
        set {
            userDefaults.set(newValue, forKey: Keys.systemProxyStrictCapture)
            notifyDidChange()
        }
    }

    var hasAcknowledgedSystemProxyRouting: Bool {
        get {
            userDefaults.object(forKey: Keys.hasAcknowledgedSystemProxyRouting) as? Bool ?? Defaults.hasAcknowledgedSystemProxyRouting
        }
        set {
            userDefaults.set(newValue, forKey: Keys.hasAcknowledgedSystemProxyRouting)
            notifyDidChange()
        }
    }

    var showSystemProxyMenuBarItem: Bool {
        get {
            userDefaults.object(forKey: Keys.showSystemProxyMenuBarItem) as? Bool ?? Defaults.showSystemProxyMenuBarItem
        }
        set {
            userDefaults.set(newValue, forKey: Keys.showSystemProxyMenuBarItem)
            notifyDidChange()
        }
    }

    var runInMenuBarOnly: Bool {
        get {
            userDefaults.object(forKey: Keys.runInMenuBarOnly) as? Bool ?? Defaults.runInMenuBarOnly
        }
        set {
            userDefaults.set(newValue, forKey: Keys.runInMenuBarOnly)
            notifyDidChange()
        }
    }

    var onboardingProgressRecord: OnboardingProgressRecord {
        get {
            guard let data = userDefaults.data(forKey: Keys.onboardingProgressData),
                  let record = try? JSONDecoder().decode(OnboardingProgressRecord.self, from: data),
                  record.schemaVersion == OnboardingProgressRecord.currentSchemaVersion else {
                return legacyOnboardingProgressRecord
            }
            return record
        }
        set {
            let normalizedRecord = OnboardingProgressRecord(lifecycle: newValue.lifecycle)
            let data = try? JSONEncoder().encode(normalizedRecord)
            userDefaults.set(data, forKey: Keys.onboardingProgressData)
            notifyDidChange()
        }
    }

    var sessionStartPresentationRecord: SessionStartPresentationRecord {
        get {
            guard let data = userDefaults.data(forKey: Keys.sessionStartPresentationData),
                  let record = try? JSONDecoder().decode(SessionStartPresentationRecord.self, from: data),
                  record.schemaVersion == SessionStartPresentationRecord.currentSchemaVersion else {
                return Defaults.sessionStartPresentationRecord
            }
            return record
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            userDefaults.set(data, forKey: Keys.sessionStartPresentationData)
            notifyDidChange()
        }
    }

    var preferredWorkingView: WorkingViewPreference {
        get {
            guard let rawValue = userDefaults.string(forKey: Keys.preferredWorkingViewRawValue),
                  let preference = WorkingViewPreference(rawValue: rawValue) else {
                return Defaults.preferredWorkingView
            }
            return preference
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Keys.preferredWorkingViewRawValue)
            notifyDidChange()
        }
    }

    var launchWorkspacePreference: LaunchWorkspacePreference {
        get {
            guard let rawValue = userDefaults.string(forKey: Keys.launchWorkspacePreferenceRawValue),
                  let preference = LaunchWorkspacePreference(rawValue: rawValue) else {
                return Defaults.launchWorkspacePreference
            }
            return preference
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Keys.launchWorkspacePreferenceRawValue)
            notifyDidChange()
        }
    }

    var noCachingDomains: [String] {
        get {
            userDefaults.stringArray(forKey: Keys.noCachingDomains) ?? Defaults.noCachingDomains
        }
        set {
            userDefaults.set(newValue, forKey: Keys.noCachingDomains)
            notifyDidChange()
        }
    }

    var hasCompletedInitialGuidedSetupPresentation: Bool {
        get {
            userDefaults.object(forKey: Keys.hasCompletedInitialGuidedSetupPresentation) as? Bool
                ?? Defaults.hasCompletedInitialGuidedSetupPresentation
        }
        set {
            userDefaults.set(newValue, forKey: Keys.hasCompletedInitialGuidedSetupPresentation)
            if newValue, onboardingProgressRecord.lifecycle == .notStarted {
                let compatibilityRecord = OnboardingProgressRecord(lifecycle: .legacyDismissed)
                let data = try? JSONEncoder().encode(compatibilityRecord)
                userDefaults.set(data, forKey: Keys.onboardingProgressData)
            }
            notifyDidChange()
        }
    }

    var warnsBeforeQuittingWithUnsavedSessions: Bool {
        get {
            if let stored = userDefaults.object(forKey: Keys.warnsBeforeQuittingWithUnsavedSessions) as? Bool {
                return stored
            }
            if let legacySuppressed = userDefaults.object(forKey: Keys.legacySuppressQuitWarning) as? Bool {
                return !legacySuppressed
            }
            return Defaults.warnsBeforeQuittingWithUnsavedSessions
        }
        set {
            userDefaults.set(newValue, forKey: Keys.warnsBeforeQuittingWithUnsavedSessions)
            notifyDidChange()
        }
    }

    var mcpSystemNotificationsEnabled: Bool {
        get {
            userDefaults.object(forKey: Keys.mcpSystemNotificationsEnabled) as? Bool
                ?? Defaults.mcpSystemNotificationsEnabled
        }
        set {
            userDefaults.set(newValue, forKey: Keys.mcpSystemNotificationsEnabled)
            notifyDidChange()
        }
    }

    var sdkEventServerEnabled: Bool {
        get {
            userDefaults.object(forKey: Keys.sdkEventServerEnabled) as? Bool
                ?? Defaults.sdkEventServerEnabled
        }
        set {
            userDefaults.set(newValue, forKey: Keys.sdkEventServerEnabled)
            notifyDidChange()
        }
    }

    var sdkEventServerPort: UInt16 {
        Defaults.sdkEventServerPort
    }

    var networkThrottleConfiguration: NetworkThrottleConfiguration {
        get {
            guard let data = userDefaults.data(forKey: Keys.networkThrottleConfigurationData),
                  let configuration = try? JSONDecoder().decode(NetworkThrottleConfiguration.self, from: data),
                  !configuration.presets.isEmpty else {
                return Defaults.networkThrottleConfiguration
            }
            return configuration
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            userDefaults.set(data, forKey: Keys.networkThrottleConfigurationData)
            notifyDidChange()
        }
    }

    var profileHostStrategyRawValue: String {
        get {
            userDefaults.string(forKey: Keys.profileHostStrategyRawValue)
                ?? Defaults.profileHostStrategyRawValue
        }
        set {
            userDefaults.set(newValue, forKey: Keys.profileHostStrategyRawValue)
            notifyDidChange()
        }
    }

    var manualProfileHost: String {
        get {
            userDefaults.string(forKey: Keys.manualProfileHost)
                ?? Defaults.manualProfileHost
        }
        set {
            userDefaults.set(newValue, forKey: Keys.manualProfileHost)
            notifyDidChange()
        }
    }

    var responseOverridesData: Data? {
        get {
            userDefaults.data(forKey: Keys.responseOverridesData) ?? Defaults.responseOverridesData
        }
        set {
            userDefaults.set(newValue, forKey: Keys.responseOverridesData)
            notifyDidChange()
        }
    }

    var captureRetentionPolicy: CaptureRetentionPolicy {
        get {
            guard let data = userDefaults.data(forKey: Keys.captureRetentionPolicyData),
                  let policy = try? JSONDecoder().decode(CaptureRetentionPolicy.self, from: data) else {
                return Defaults.captureRetentionPolicy
            }
            return policy
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            userDefaults.set(data, forKey: Keys.captureRetentionPolicyData)
            notifyDidChange()
        }
    }

    var liveCaptureBodySizeLimit: Int {
        get {
            let stored = userDefaults.integer(forKey: Keys.liveCaptureBodySizeLimit)
            return (stored >= 65_536 && stored <= 52_428_800) ? stored : Defaults.liveCaptureBodySizeLimit
        }
        set {
            let clamped = min(max(65_536, newValue), 52_428_800)
            userDefaults.set(clamped, forKey: Keys.liveCaptureBodySizeLimit)
            notifyDidChange()
        }
    }

    var rollingCaptureAutoSaveEnabled: Bool {
        get {
            if userDefaults.object(forKey: Keys.rollingCaptureAutoSaveEnabled) == nil {
                return Defaults.rollingCaptureAutoSaveEnabled
            }
            return userDefaults.bool(forKey: Keys.rollingCaptureAutoSaveEnabled)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.rollingCaptureAutoSaveEnabled)
            notifyDidChange()
        }
    }

    var rollingCaptureRestorePromptEnabled: Bool {
        get {
            guard userDefaults.object(forKey: Keys.rollingCaptureRestorePromptEnabled) != nil else {
                return Defaults.rollingCaptureRestorePromptEnabled
            }
            return userDefaults.bool(forKey: Keys.rollingCaptureRestorePromptEnabled)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.rollingCaptureRestorePromptEnabled)
            notifyDidChange()
        }
    }

    var previousRunDiagnosticsEnabled: Bool {
        get {
            guard userDefaults.object(forKey: Keys.previousRunDiagnosticsEnabled) != nil else {
                return Defaults.previousRunDiagnosticsEnabled
            }
            return userDefaults.bool(forKey: Keys.previousRunDiagnosticsEnabled)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.previousRunDiagnosticsEnabled)
            notifyDidChange()
        }
    }

    var rollingCaptureSaveIntervalSeconds: Int {
        get {
            let stored = userDefaults.integer(forKey: Keys.rollingCaptureSaveIntervalSeconds)
            return stored > 0 ? stored : Defaults.rollingCaptureSaveIntervalSeconds
        }
        set {
            userDefaults.set(max(5, newValue), forKey: Keys.rollingCaptureSaveIntervalSeconds)
            notifyDidChange()
        }
    }

    var rollingCaptureSaveSessionThreshold: Int {
        get {
            let stored = userDefaults.integer(forKey: Keys.rollingCaptureSaveSessionThreshold)
            return stored > 0 ? stored : Defaults.rollingCaptureSaveSessionThreshold
        }
        set {
            userDefaults.set(max(1, newValue), forKey: Keys.rollingCaptureSaveSessionThreshold)
            notifyDidChange()
        }
    }

    var rollingCaptureRetentionCount: Int {
        get {
            let stored = userDefaults.integer(forKey: Keys.rollingCaptureRetentionCount)
            return stored > 0 ? stored : Defaults.rollingCaptureRetentionCount
        }
        set {
            userDefaults.set(max(1, newValue), forKey: Keys.rollingCaptureRetentionCount)
            notifyDidChange()
        }
    }

    var rollingCaptureMaxDiskMB: Int {
        get {
            let stored = userDefaults.integer(forKey: Keys.rollingCaptureMaxDiskMB)
            return stored > 0 ? stored : Defaults.rollingCaptureMaxDiskMB
        }
        set {
            userDefaults.set(max(50, newValue), forKey: Keys.rollingCaptureMaxDiskMB)
            notifyDidChange()
        }
    }

    var certificateLabel: String {
        CertificateNaming.productionRootCA
    }

    func resetToDefaults() {
        proxyPort = Defaults.proxyPort
        logLevel = Defaults.logLevel
        verboseHTTPSLoggingEnabled = Defaults.verboseHTTPSLoggingEnabled
        isFindDebugLoggingEnabled = Defaults.isFindDebugLoggingEnabled
        appTextSizeRawValue = Defaults.appTextSizeRawValue
        isInspectorCopyRedactionEnabled = Defaults.isInspectorCopyRedactionEnabled
        sessionSortFieldRawValue = Defaults.sessionSortFieldRawValue
        isSessionSortAscending = Defaults.isSessionSortAscending
        isSessionAutoScrollEnabled = Defaults.isSessionAutoScrollEnabled
        sessionBrowserModeRawValue = Defaults.sessionBrowserModeRawValue
        sessionExplorerGroupingRawValue = Defaults.sessionExplorerGroupingRawValue
        sessionExplorerHostGroupingRawValue = Defaults.sessionExplorerHostGroupingRawValue
        sessionExplorerExpandedNodeIDs = Defaults.sessionExplorerExpandedNodeIDs
        sessionInspectorSplitFraction = Defaults.sessionInspectorSplitFraction
        httpsBypassDomains = Defaults.httpsBypassDomains
        httpsInterceptDomains = Defaults.httpsInterceptDomains
        isNoCachingEnabled = Defaults.isNoCachingEnabled
        noCachingDomains = Defaults.noCachingDomains
        isSystemProxyManagementEnabled = Defaults.isSystemProxyManagementEnabled
        systemProxyStrictCapture = Defaults.systemProxyStrictCapture
        hasAcknowledgedSystemProxyRouting = Defaults.hasAcknowledgedSystemProxyRouting
        showSystemProxyMenuBarItem = Defaults.showSystemProxyMenuBarItem
        runInMenuBarOnly = Defaults.runInMenuBarOnly
        onboardingProgressRecord = Defaults.onboardingProgressRecord
        sessionStartPresentationRecord = Defaults.sessionStartPresentationRecord
        preferredWorkingView = Defaults.preferredWorkingView
        launchWorkspacePreference = Defaults.launchWorkspacePreference
        hasCompletedInitialGuidedSetupPresentation = Defaults.hasCompletedInitialGuidedSetupPresentation
        warnsBeforeQuittingWithUnsavedSessions = Defaults.warnsBeforeQuittingWithUnsavedSessions
        mcpSystemNotificationsEnabled = Defaults.mcpSystemNotificationsEnabled
        sdkEventServerEnabled = Defaults.sdkEventServerEnabled
        networkThrottleConfiguration = Defaults.networkThrottleConfiguration
        profileHostStrategyRawValue = Defaults.profileHostStrategyRawValue
        manualProfileHost = Defaults.manualProfileHost
        responseOverridesData = Defaults.responseOverridesData
        captureRetentionPolicy = Defaults.captureRetentionPolicy
        liveCaptureBodySizeLimit = Defaults.liveCaptureBodySizeLimit
        rollingCaptureAutoSaveEnabled = Defaults.rollingCaptureAutoSaveEnabled
        rollingCaptureRestorePromptEnabled = Defaults.rollingCaptureRestorePromptEnabled
        rollingCaptureSaveIntervalSeconds = Defaults.rollingCaptureSaveIntervalSeconds
        rollingCaptureSaveSessionThreshold = Defaults.rollingCaptureSaveSessionThreshold
        rollingCaptureRetentionCount = Defaults.rollingCaptureRetentionCount
        rollingCaptureMaxDiskMB = Defaults.rollingCaptureMaxDiskMB
        previousRunDiagnosticsEnabled = Defaults.previousRunDiagnosticsEnabled
    }

    private func notifyDidChange() {
        didChangeSubject.send(())
    }

    private var legacyOnboardingProgressRecord: OnboardingProgressRecord {
        let wasPresented = userDefaults.object(
            forKey: Keys.hasCompletedInitialGuidedSetupPresentation
        ) as? Bool ?? Defaults.hasCompletedInitialGuidedSetupPresentation
        return OnboardingProgressRecord(
            lifecycle: wasPresented ? .legacyDismissed : .notStarted
        )
    }

    private func migrateLegacyOnboardingStateIfNeeded() {
        guard userDefaults.object(forKey: Keys.onboardingProgressData) == nil else {
            return
        }
        let data = try? JSONEncoder().encode(legacyOnboardingProgressRecord)
        userDefaults.set(data, forKey: Keys.onboardingProgressData)
    }
}
