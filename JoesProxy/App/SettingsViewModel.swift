import AppKit
import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var showsRecoverySettings = false
    @Published var selectedSettingsTab = 0
    @Published var recoverySettingsRequest = UUID()

    @Published var showsCapacitySettings = false

    func requestCapacitySettings() {
        showsRecoverySettings = false
        showsCapacitySettings = true
        selectedSettingsTab = 4
        recoverySettingsRequest = UUID()
    }

    func requestRecoverySettings() {
        showsCapacitySettings = false
        showsRecoverySettings = true
        selectedSettingsTab = 4
        recoverySettingsRequest = UUID()
    }
    @Published var rollingCaptureRestorePromptEnabled: Bool {
        didSet {
            guard oldValue != rollingCaptureRestorePromptEnabled else { return }
            configuration.rollingCaptureRestorePromptEnabled = rollingCaptureRestorePromptEnabled
        }
    }
    @Published var previousRunDiagnosticsEnabled: Bool {
        didSet {
            guard oldValue != previousRunDiagnosticsEnabled else { return }
            configuration.previousRunDiagnosticsEnabled = previousRunDiagnosticsEnabled
            diagnosticsCoordinator?.setRecordingEnabled(previousRunDiagnosticsEnabled)
        }
    }
    /// Shared previous-run report owner; `nil` only in isolated view-model tests.
    let diagnosticsCoordinator: PreviousRunDiagnosticsCoordinator?
    enum RetentionPolicyMode: String, CaseIterable, Equatable, Identifiable {
        case unlimited
        case keepLastSessions
        case keepLastBodyMegabytes
        case bounded

        var id: String { rawValue }

        var title: String {
            switch self {
            case .unlimited:
                return "Unlimited"
            case .keepLastSessions:
                return "Only Keep Recent Sessions"
            case .keepLastBodyMegabytes:
                return "Only Keep Recent Bodies"
            case .bounded:
                return "Limit Sessions and Bodies"
            }
        }
    }

    private enum RetentionUI {
        static let bytesPerMegabyte = 1_048_576
    }

    private enum ThrottleUI {
        static let emptyPresetName = "Preset"
    }

    @Published var appTextSize: AppTextSize {
        didSet {
            guard oldValue != appTextSize else {
                return
            }

            configuration.appTextSizeRawValue = appTextSize.rawValue
        }
    }
    @Published var launchWorkspacePreference: LaunchWorkspacePreference {
        didSet {
            guard oldValue != launchWorkspacePreference else { return }
            configuration.launchWorkspacePreference = launchWorkspacePreference
        }
    }
    @Published var isInspectorCopyRedactionEnabled: Bool {
        didSet {
            guard oldValue != isInspectorCopyRedactionEnabled else {
                return
            }

            configuration.isInspectorCopyRedactionEnabled = isInspectorCopyRedactionEnabled
        }
    }
    @Published var isFindDebugLoggingEnabled: Bool {
        didSet {
            guard oldValue != isFindDebugLoggingEnabled else {
                return
            }

            configuration.isFindDebugLoggingEnabled = isFindDebugLoggingEnabled
        }
    }
    @Published var warnsBeforeQuittingWithUnsavedSessions: Bool {
        didSet {
            guard oldValue != warnsBeforeQuittingWithUnsavedSessions else {
                return
            }

            configuration.warnsBeforeQuittingWithUnsavedSessions = warnsBeforeQuittingWithUnsavedSessions
        }
    }
    @Published var isSessionAutoScrollEnabled: Bool {
        didSet {
            guard oldValue != isSessionAutoScrollEnabled else {
                return
            }

            configuration.isSessionAutoScrollEnabled = isSessionAutoScrollEnabled
        }
    }
    @Published var rollingCaptureAutoSaveEnabled: Bool {
        didSet {
            guard oldValue != rollingCaptureAutoSaveEnabled else {
                return
            }

            configuration.rollingCaptureAutoSaveEnabled = rollingCaptureAutoSaveEnabled
        }
    }
    @Published var sdkEventServerEnabled: Bool {
        didSet {
            guard oldValue != sdkEventServerEnabled else {
                return
            }

            configuration.sdkEventServerEnabled = sdkEventServerEnabled
        }
    }
    @Published var captureRetentionPolicyMode: RetentionPolicyMode {
        didSet {
            guard oldValue != captureRetentionPolicyMode else {
                return
            }

            captureRetentionValidationMessage = nil
        }
    }
    @Published var captureRetentionLimitDraft: String {
        didSet {
            guard oldValue != captureRetentionLimitDraft else {
                return
            }

            captureRetentionValidationMessage = nil
        }
    }
    @Published var captureRetentionBodyLimitDraft: String = "250" {
        didSet { captureRetentionValidationMessage = nil }
    }
    @Published var liveCaptureBodyLimitDraft: String {
        didSet {
            guard oldValue != liveCaptureBodyLimitDraft else {
                return
            }

            liveCaptureBodyLimitValidationMessage = nil
        }
    }
    @Published var isNoCachingEnabled: Bool {
        didSet {
            guard oldValue != isNoCachingEnabled else { return }
            configuration.isNoCachingEnabled = isNoCachingEnabled
        }
    }
    @Published var pendingRoutingConsent = false
    @Published var isSystemProxyManagementEnabled: Bool {
        didSet {
            guard oldValue != isSystemProxyManagementEnabled else { return }
            if isSystemProxyManagementEnabled, !configuration.hasAcknowledgedSystemProxyRouting {
                // Revert and gate the first enable behind a consent alert.
                isSystemProxyManagementEnabled = false
                pendingRoutingConsent = true
                return
            }
            configuration.isSystemProxyManagementEnabled = isSystemProxyManagementEnabled
        }
    }
    @Published var systemProxyStrictCapture: Bool {
        didSet {
            guard oldValue != systemProxyStrictCapture else { return }
            configuration.systemProxyStrictCapture = systemProxyStrictCapture
        }
    }
    @Published var showSystemProxyMenuBarItem: Bool {
        didSet {
            guard oldValue != showSystemProxyMenuBarItem else { return }
            configuration.showSystemProxyMenuBarItem = showSystemProxyMenuBarItem
        }
    }
    @Published var runInMenuBarOnly: Bool {
        didSet {
            guard oldValue != runInMenuBarOnly else { return }
            configuration.runInMenuBarOnly = runInMenuBarOnly
            if runInMenuBarOnly, !showSystemProxyMenuBarItem {
                showSystemProxyMenuBarItem = true
            }
        }
    }

    /// Applies Dock / activation-policy side effects for the menu-bar-only preference.
    ///
    /// Concurrency: main actor only — touches `NSApp`. Call from UI (`onChange` / launch), not from
    /// property `didSet` during `SettingsViewModel` construction (test-host bootstrap is sensitive).
    func applyMenuBarOnlyActivationPolicy() {
        MenuBarOnlyActivation.applyPreferredPolicy(isMenuBarOnly: runInMenuBarOnly)
        if runInMenuBarOnly {
            MenuBarOnlyActivation.hideMainWindowsForAccessoryLaunch()
        }
    }

    var systemProxyConsentMessage: String {
        SystemProxyRoutingCopy.consentMessage(strictCapture: systemProxyStrictCapture)
    }

    func confirmRoutingConsent() {
        configuration.hasAcknowledgedSystemProxyRouting = true
        pendingRoutingConsent = false
        isSystemProxyManagementEnabled = true
    }

    func cancelRoutingConsent() {
        pendingRoutingConsent = false
    }
    @Published var noCachingDomains: [String] {
        didSet {
            guard oldValue != noCachingDomains else { return }
            configuration.noCachingDomains = noCachingDomains
        }
    }
    @Published var isLoopbackMapRemoteEnabled: Bool {
        didSet {
            guard oldValue != isLoopbackMapRemoteEnabled else { return }
            configuration.isLoopbackMapRemoteEnabled = isLoopbackMapRemoteEnabled
            if !isLoopbackMapRemoteEnabled {
                revokeLoopbackAccess(forRemovedPorts: nil)
            }
        }
    }
    @Published private(set) var authorizedLoopbackPorts: [Int]
    @Published var authorizedLoopbackPortsDraft: String {
        didSet {
            guard oldValue != authorizedLoopbackPortsDraft else { return }
            loopbackPortsValidationMessage = nil
        }
    }
    @Published private(set) var loopbackPortsValidationMessage: String?
    @Published var networkThrottleConfiguration: NetworkThrottleConfiguration {
        didSet {
            guard oldValue != networkThrottleConfiguration else { return }
            // Recompute before persisting — this view model has its own independent write path
            // into `configuration.networkThrottleConfiguration` (ProxyViewModel has a separate
            // one, also fixed). Without this, editing throttle presets from Settings would leave
            // `mcpTargetRevision` frozen at whatever it was before the edit.
            configuration.networkThrottleConfiguration =
                MCPTargetRevisionFingerprint.throttleByApplyingRevision(networkThrottleConfiguration)
        }
    }
    @Published var throttleDownstreamDraft: String {
        didSet {
            guard oldValue != throttleDownstreamDraft else { return }
            networkThrottleValidationMessage = nil
        }
    }
    @Published var throttleUpstreamDraft: String {
        didSet {
            guard oldValue != throttleUpstreamDraft else { return }
            networkThrottleValidationMessage = nil
        }
    }
    @Published var throttleLatencyDraft: String {
        didSet {
            guard oldValue != throttleLatencyDraft else { return }
            networkThrottleValidationMessage = nil
        }
    }
    @Published var proxyPortDraft: String
    @Published private(set) var proxyState: ProxyRuntimeState
    @Published private(set) var sdkEventServerStatus: SDKEventServerStatus
    @Published private(set) var proxyPortValidationMessage: String?
    @Published private(set) var captureRetentionValidationMessage: String?
    @Published private(set) var liveCaptureBodyLimitValidationMessage: String?
    @Published private(set) var networkThrottleValidationMessage: String?

    private let configuration: AppConfiguration
    private let proxyRuntime: any ProxyRuntime
    private let responseOverrideStore: ResponseOverrideStore?
    private var cancellables: Set<AnyCancellable> = []

    init(
        configuration: AppConfiguration,
        proxyRuntime: any ProxyRuntime,
        diagnosticsCoordinator: PreviousRunDiagnosticsCoordinator? = nil,
        responseOverrideStore: ResponseOverrideStore? = nil
    ) {
        self.configuration = configuration
        self.proxyRuntime = proxyRuntime
        self.diagnosticsCoordinator = diagnosticsCoordinator
        self.responseOverrideStore = responseOverrideStore
        self.appTextSize = AppTextSize(rawValue: configuration.appTextSizeRawValue) ?? .standard
        self.launchWorkspacePreference = configuration.launchWorkspacePreference
        self.isInspectorCopyRedactionEnabled = configuration.isInspectorCopyRedactionEnabled
        self.isFindDebugLoggingEnabled = configuration.isFindDebugLoggingEnabled
        self.warnsBeforeQuittingWithUnsavedSessions = configuration.warnsBeforeQuittingWithUnsavedSessions
        self.isSessionAutoScrollEnabled = configuration.isSessionAutoScrollEnabled
        self.rollingCaptureAutoSaveEnabled = configuration.rollingCaptureAutoSaveEnabled
        self.rollingCaptureRestorePromptEnabled = configuration.rollingCaptureRestorePromptEnabled
        self.previousRunDiagnosticsEnabled = configuration.previousRunDiagnosticsEnabled
        self.sdkEventServerEnabled = configuration.sdkEventServerEnabled
        let retentionState = Self.retentionState(for: configuration.captureRetentionPolicy)
        self.captureRetentionPolicyMode = retentionState.mode
        self.captureRetentionLimitDraft = retentionState.limitDraft
        if case .bounded(_, let bytes) = configuration.captureRetentionPolicy {
            self.captureRetentionBodyLimitDraft = String(max(1, bytes / RetentionUI.bytesPerMegabyte))
        }
        self.liveCaptureBodyLimitDraft = String(max(64, configuration.liveCaptureBodySizeLimit / 1024))
        self.isNoCachingEnabled = configuration.isNoCachingEnabled
        self.isSystemProxyManagementEnabled = configuration.isSystemProxyManagementEnabled
        self.systemProxyStrictCapture = configuration.systemProxyStrictCapture
        self.showSystemProxyMenuBarItem = configuration.showSystemProxyMenuBarItem
        self.runInMenuBarOnly = configuration.runInMenuBarOnly
        self.noCachingDomains = configuration.noCachingDomains
        self.isLoopbackMapRemoteEnabled = configuration.isLoopbackMapRemoteEnabled
        self.authorizedLoopbackPorts = configuration.authorizedLoopbackMapRemotePorts
        self.authorizedLoopbackPortsDraft = LoopbackDestinationPolicy.formatPortsList(
            configuration.authorizedLoopbackMapRemotePorts
        )
        self.networkThrottleConfiguration = MCPTargetRevisionFingerprint.throttleByApplyingRevision(
            configuration.networkThrottleConfiguration
        )
        let throttleDrafts = Self.throttleDrafts(for: configuration.networkThrottleConfiguration.selectedPreset)
        self.throttleDownstreamDraft = throttleDrafts.downstream
        self.throttleUpstreamDraft = throttleDrafts.upstream
        self.throttleLatencyDraft = throttleDrafts.latency
        self.proxyPortDraft = String(configuration.proxyPort)
        self.proxyState = proxyRuntime.currentState
        self.sdkEventServerStatus = .stopped

        proxyRuntime.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.proxyState = newState
                Task { @MainActor [weak self] in
                    await self?.refreshSDKEventServerStatus()
                }
            }
            .store(in: &cancellables)

        configuration.didChangePublisher
            .debounce(for: .zero, scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.reloadFromConfiguration()
                Task { @MainActor [weak self] in
                    await self?.refreshSDKEventServerStatus()
                }
            }
            .store(in: &cancellables)
    }

    var canEditProxyPort: Bool {
        switch proxyState {
        case .stopped, .failed:
            return true
        case .starting, .running, .stopping:
            return false
        }
    }

    var canResetDefaults: Bool {
        canEditProxyPort
    }

    var proxyStatusDescription: String {
        switch proxyState {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .stopping:
            return "Stopping"
        case .failed:
            return "Failed"
        }
    }

    var proxyPortEditingHelpText: String {
        canEditProxyPort
            ? "Changes apply to the next proxy start."
            : "Stop the proxy before changing the listening port."
    }

    var sdkEventServerPortDescription: String {
        String(configuration.sdkEventServerPort)
    }

    var sdkEventServerStatusDescription: String {
        sdkEventServerStatus.isRunning ? "Running" : "Stopped"
    }

    var sdkEventServerClientCountDescription: String {
        String(sdkEventServerStatus.connectedClientCount)
    }

    var sdkEventServerPairingTokenDescription: String {
        sdkEventServerStatus.pairingToken ?? "-"
    }

    var shouldShowSDKEventServerPairingToken: Bool {
        sdkEventServerStatus.isRunning && sdkEventServerStatus.pairingToken != nil
    }

    var captureRetentionValueLabel: String {
        switch captureRetentionPolicyMode {
        case .unlimited:
            return "No limit"
        case .keepLastSessions, .bounded:
            return "Sessions to Keep"
        case .keepLastBodyMegabytes:
            return "Body Data to Keep (MB)"
        }
    }

    var captureRetentionHelpText: String {
        switch captureRetentionPolicyMode {
        case .unlimited:
            return "Retain all captured sessions and bodies until you clear them or quit."
        case .keepLastSessions:
            return "Keep only the newest sessions in memory. Older sessions are removed as new traffic arrives."
        case .keepLastBodyMegabytes:
            return "Keep all session metadata, but remove the oldest stored request and response bodies once the configured body-data limit is exceeded."
        case .bounded:
            return "Remove sessions beyond the session limit, then remove older bodies if needed to meet the body-data limit. Removed data is no longer available for inspection or export from this capture. These limits do not cap total app memory."
        }
    }

    var selectedThrottlePresetID: String {
        get {
            networkThrottleConfiguration.selectedPresetID
        }
        set {
            guard networkThrottleConfiguration.presets.contains(where: { $0.id == newValue }) else { return }
            networkThrottleConfiguration.selectedPresetID = newValue
            let drafts = Self.throttleDrafts(for: networkThrottleConfiguration.selectedPreset)
            throttleDownstreamDraft = drafts.downstream
            throttleUpstreamDraft = drafts.upstream
            throttleLatencyDraft = drafts.latency
        }
    }

    var selectedThrottlePresetName: String {
        networkThrottleConfiguration.selectedPreset?.name ?? ThrottleUI.emptyPresetName
    }

    var selectedThrottlePresetSummary: String {
        guard let preset = networkThrottleConfiguration.selectedPreset else {
            return "Select a preset to edit its simulated connection speed."
        }
        return "\(preset.downstreamKbps) Kbps down, \(preset.upstreamKbps) Kbps up, \(preset.latencyMs) ms latency."
    }

    func applyProxyPortDraft() {
        guard canEditProxyPort else {
            proxyPortValidationMessage = "Stop the proxy before changing the port."
            return
        }

        let trimmedDraft = proxyPortDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(trimmedDraft), port > 0 else {
            proxyPortValidationMessage = "Enter a whole-number port from 1 to 65535."
            return
        }

        configuration.proxyPort = port
        proxyPortDraft = String(port)
        proxyPortValidationMessage = nil
    }

    func applyCaptureRetentionPolicy() {
        switch captureRetentionPolicyMode {
        case .bounded:
            guard let count = Int(captureRetentionLimitDraft.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0,
                  let megabytes = Int(captureRetentionBodyLimitDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
                  megabytes > 0, megabytes <= Int.max / RetentionUI.bytesPerMegabyte else {
                captureRetentionValidationMessage = "Enter a positive session count and a valid body-data limit in megabytes."
                return
            }
            configuration.captureRetentionPolicy = .bounded(maxSessions: count, maxBodyBytes: megabytes * RetentionUI.bytesPerMegabyte)
            captureRetentionValidationMessage = nil
        case .unlimited:
            configuration.captureRetentionPolicy = .unlimited
            captureRetentionValidationMessage = nil

        case .keepLastSessions:
            let trimmedDraft = captureRetentionLimitDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let count = Int(trimmedDraft), count > 0 else {
                captureRetentionValidationMessage = "Enter a whole-number session count greater than 0."
                return
            }

            configuration.captureRetentionPolicy = .keepLastSessions(count)
            captureRetentionLimitDraft = String(count)
            captureRetentionValidationMessage = nil

        case .keepLastBodyMegabytes:
            let trimmedDraft = captureRetentionLimitDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let megabytes = Int(trimmedDraft), megabytes > 0,
                  megabytes <= Int.max / RetentionUI.bytesPerMegabyte else {
                captureRetentionValidationMessage = "Enter a whole-number body-data limit in megabytes."
                return
            }

            configuration.captureRetentionPolicy = .keepLastBodyBytes(megabytes * RetentionUI.bytesPerMegabyte)
            captureRetentionLimitDraft = String(megabytes)
            captureRetentionValidationMessage = nil
        }
    }

    func applyLiveCaptureBodyLimit() {
        let trimmedDraft = liveCaptureBodyLimitDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kb = Int(trimmedDraft), kb >= 64, kb <= 51_200 else {
            liveCaptureBodyLimitValidationMessage = "Enter a whole-number limit between 64 KB and 51,200 KB (50 MB)."
            return
        }

        let bytes = kb * 1024
        configuration.liveCaptureBodySizeLimit = bytes
        liveCaptureBodyLimitDraft = String(kb)
        liveCaptureBodyLimitValidationMessage = nil
    }

    func applySelectedThrottlePresetDraft() {
        let downstreamDraft = throttleDownstreamDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamDraft = throttleUpstreamDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let latencyDraft = throttleLatencyDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let downstreamKbps = Int(downstreamDraft), downstreamKbps > 0 else {
            networkThrottleValidationMessage = "Enter downstream bandwidth as a whole number greater than 0 Kbps."
            return
        }
        guard let upstreamKbps = Int(upstreamDraft), upstreamKbps > 0 else {
            networkThrottleValidationMessage = "Enter upstream bandwidth as a whole number greater than 0 Kbps."
            return
        }
        guard let latencyMs = Int(latencyDraft), latencyMs >= 0 else {
            networkThrottleValidationMessage = "Enter latency as a whole number of milliseconds, 0 or greater."
            return
        }
        guard let index = networkThrottleConfiguration.presets.firstIndex(where: {
            $0.id == networkThrottleConfiguration.selectedPresetID
        }) else {
            networkThrottleValidationMessage = "Select a throttling preset to edit."
            return
        }

        networkThrottleConfiguration.presets[index].downstreamKbps = downstreamKbps
        networkThrottleConfiguration.presets[index].upstreamKbps = upstreamKbps
        networkThrottleConfiguration.presets[index].latencyMs = latencyMs
        throttleDownstreamDraft = String(downstreamKbps)
        throttleUpstreamDraft = String(upstreamKbps)
        throttleLatencyDraft = String(latencyMs)
        networkThrottleValidationMessage = nil
    }

    func restoreNetworkThrottlePresets() {
        networkThrottleConfiguration = NetworkThrottleConfiguration.defaults
        let drafts = Self.throttleDrafts(for: networkThrottleConfiguration.selectedPreset)
        throttleDownstreamDraft = drafts.downstream
        throttleUpstreamDraft = drafts.upstream
        throttleLatencyDraft = drafts.latency
        networkThrottleValidationMessage = nil
    }

    func addNoCachingDomain(_ domain: String) {
        let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !noCachingDomains.contains(normalized) else { return }
        noCachingDomains.append(normalized)
        noCachingDomains.sort()
    }

    func removeNoCachingDomain(_ domain: String) {
        noCachingDomains.removeAll { $0 == domain }
    }

    func commitAuthorizedLoopbackPortsDraft() {
        let parsed = LoopbackDestinationPolicy.parsePortsList(authorizedLoopbackPortsDraft)
        if !parsed.invalidTokens.isEmpty {
            let joined = parsed.invalidTokens.joined(separator: ", ")
            loopbackPortsValidationMessage = "Enter comma-separated ports between 1 and 65535 (invalid: \(joined))."
            return
        }
        for port in parsed.ports {
            if let owner = ReservedListenerRegistry.shared.conflictsWithPort(port) {
                loopbackPortsValidationMessage = "Port \(port) is currently reserved by JoesProxy (\(owner))."
                return
            }
        }
        applyAuthorizedLoopbackPorts(parsed.ports)
    }

    func removeAuthorizedLoopbackPort(_ port: Int) {
        let updated = authorizedLoopbackPorts.filter { $0 != port }
        applyAuthorizedLoopbackPorts(updated)
    }

    private func applyAuthorizedLoopbackPorts(_ updatedPorts: [Int]) {
        let sanitized = Array(Set(updatedPorts.filter { (1...65_535).contains($0) })).sorted()
        let removed = Set(authorizedLoopbackPorts).subtracting(sanitized)
        authorizedLoopbackPorts = sanitized
        authorizedLoopbackPortsDraft = LoopbackDestinationPolicy.formatPortsList(sanitized)
        configuration.authorizedLoopbackMapRemotePorts = sanitized
        loopbackPortsValidationMessage = nil
        if !removed.isEmpty {
            revokeLoopbackAccess(forRemovedPorts: removed)
        }
    }

    private func revokeLoopbackAccess(forRemovedPorts removedPorts: Set<Int>?) {
        ActiveMapRemoteSessionRegistry.shared.cancelLoopbackSessions(forPorts: removedPorts)
        guard let store = responseOverrideStore else { return }
        Task { @MainActor in
            let didChange = await store.disableLoopbackMapRemoteRules(forRemovedPorts: removedPorts)
            if didChange {
                configuration.responseOverridesData = try? await store.persistedData()
            }
        }
    }

    func resetDefaults() {
        guard canResetDefaults else {
            proxyPortValidationMessage = "Stop the proxy before resetting defaults."
            return
        }

        configuration.resetToDefaults()
        revokeLoopbackAccess(forRemovedPorts: nil)
        proxyPortValidationMessage = nil
        loopbackPortsValidationMessage = nil
    }

    func refreshSDKEventServerStatus() async {
        sdkEventServerStatus = await proxyRuntime.sdkEventServerStatus()
    }

    private func reloadFromConfiguration() {
        assignIfChanged(&appTextSize, AppTextSize(rawValue: configuration.appTextSizeRawValue) ?? .standard)
        assignIfChanged(&launchWorkspacePreference, configuration.launchWorkspacePreference)
        assignIfChanged(&isInspectorCopyRedactionEnabled, configuration.isInspectorCopyRedactionEnabled)
        assignIfChanged(&isFindDebugLoggingEnabled, configuration.isFindDebugLoggingEnabled)
        assignIfChanged(
            &warnsBeforeQuittingWithUnsavedSessions,
            configuration.warnsBeforeQuittingWithUnsavedSessions
        )
        assignIfChanged(&isSessionAutoScrollEnabled, configuration.isSessionAutoScrollEnabled)
        assignIfChanged(&rollingCaptureAutoSaveEnabled, configuration.rollingCaptureAutoSaveEnabled)
        assignIfChanged(&rollingCaptureRestorePromptEnabled, configuration.rollingCaptureRestorePromptEnabled)
        assignIfChanged(&previousRunDiagnosticsEnabled, configuration.previousRunDiagnosticsEnabled)
        assignIfChanged(&sdkEventServerEnabled, configuration.sdkEventServerEnabled)
        let retentionState = Self.retentionState(for: configuration.captureRetentionPolicy)
        assignIfChanged(&captureRetentionPolicyMode, retentionState.mode)
        assignIfChanged(&captureRetentionLimitDraft, retentionState.limitDraft)
        if case .bounded(_, let bytes) = configuration.captureRetentionPolicy {
            assignIfChanged(&captureRetentionBodyLimitDraft, String(max(1, bytes / RetentionUI.bytesPerMegabyte)))
        }
        assignIfChanged(&liveCaptureBodyLimitDraft, String(max(64, configuration.liveCaptureBodySizeLimit / 1024)))
        assignIfChanged(&isNoCachingEnabled, configuration.isNoCachingEnabled)
        assignIfChanged(&isSystemProxyManagementEnabled, configuration.isSystemProxyManagementEnabled)
        assignIfChanged(&systemProxyStrictCapture, configuration.systemProxyStrictCapture)
        assignIfChanged(&showSystemProxyMenuBarItem, configuration.showSystemProxyMenuBarItem)
        assignIfChanged(&runInMenuBarOnly, configuration.runInMenuBarOnly)
        assignIfChanged(&noCachingDomains, configuration.noCachingDomains)
        assignIfChanged(&isLoopbackMapRemoteEnabled, configuration.isLoopbackMapRemoteEnabled)
        assignIfChanged(&authorizedLoopbackPorts, configuration.authorizedLoopbackMapRemotePorts)
        assignIfChanged(
            &authorizedLoopbackPortsDraft,
            LoopbackDestinationPolicy.formatPortsList(configuration.authorizedLoopbackMapRemotePorts)
        )
        assignIfChanged(&networkThrottleConfiguration, configuration.networkThrottleConfiguration)
        let throttleDrafts = Self.throttleDrafts(for: configuration.networkThrottleConfiguration.selectedPreset)
        assignIfChanged(&throttleDownstreamDraft, throttleDrafts.downstream)
        assignIfChanged(&throttleUpstreamDraft, throttleDrafts.upstream)
        assignIfChanged(&throttleLatencyDraft, throttleDrafts.latency)
        assignIfChanged(&proxyPortDraft, String(configuration.proxyPort))
    }

    private func assignIfChanged<Value: Equatable>(_ currentValue: inout Value, _ newValue: Value) {
        guard currentValue != newValue else { return }
        currentValue = newValue
    }

    private static func retentionState(
        for policy: CaptureRetentionPolicy
    ) -> (mode: RetentionPolicyMode, limitDraft: String) {
        switch policy {
        case .unlimited:
            return (.unlimited, "")
        case .keepLastSessions(let count):
            return (.keepLastSessions, String(count))
        case .keepLastBodyBytes(let maxBytes):
            let megabytes = max(1, Int(ceil(Double(maxBytes) / Double(RetentionUI.bytesPerMegabyte))))
            return (.keepLastBodyMegabytes, String(megabytes))
        case .bounded(let count, _):
            return (.bounded, String(count))
        }
    }

    private static func throttleDrafts(
        for preset: NetworkThrottlePreset?
    ) -> (downstream: String, upstream: String, latency: String) {
        guard let preset else {
            return ("", "", "")
        }
        return (String(preset.downstreamKbps), String(preset.upstreamKbps), String(preset.latencyMs))
    }
}
