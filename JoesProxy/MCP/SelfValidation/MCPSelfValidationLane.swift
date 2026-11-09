import Combine
import Foundation

/// In-memory app configuration for isolated self-validation runs (AI-5).
///
/// Concurrency: read/written on the main actor by the validation lane and ephemeral proxy.
final class MCPSelfValidationAppConfiguration: AppConfiguration {
    var proxyPort: UInt16 = NetworkConstants.defaultPort { didSet { didChangeSubject.send(()) } }
    var logLevel: AppLogLevel = .info { didSet { didChangeSubject.send(()) } }
    var verboseHTTPSLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var isFindDebugLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var appTextSizeRawValue = AppTextSize.standard.rawValue { didSet { didChangeSubject.send(()) } }
    var isInspectorCopyRedactionEnabled = true { didSet { didChangeSubject.send(()) } }
    var sessionSortFieldRawValue = WorkspaceSortField.startedAt.rawValue { didSet { didChangeSubject.send(()) } }
    var isSessionSortAscending = false { didSet { didChangeSubject.send(()) } }
    var isSessionAutoScrollEnabled = false { didSet { didChangeSubject.send(()) } }
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
    var showSystemProxyMenuBarItem = true { didSet { didChangeSubject.send(()) } }
    var runInMenuBarOnly = false
    var hasCompletedInitialGuidedSetupPresentation = false { didSet { didChangeSubject.send(()) } }
    var warnsBeforeQuittingWithUnsavedSessions = true { didSet { didChangeSubject.send(()) } }
    var sdkEventServerEnabled = false { didSet { didChangeSubject.send(()) } }
    var sdkEventServerPort: UInt16 { 9091 }
    var networkThrottleConfiguration = NetworkThrottleConfiguration.defaults { didSet { didChangeSubject.send(()) } }
    var profileHostStrategyRawValue = ProfileHostStrategy.bonjourLocal.rawValue { didSet { didChangeSubject.send(()) } }
    var manualProfileHost = "" { didSet { didChangeSubject.send(()) } }
    var responseOverridesData: Data? { didSet { didChangeSubject.send(()) } }
    var captureRetentionPolicy: CaptureRetentionPolicy = .unlimited { didSet { didChangeSubject.send(()) } }
    let certificateLabel = "self-validation"

    private let didChangeSubject = PassthroughSubject<Void, Never>()

    var didChangePublisher: AnyPublisher<Void, Never> {
        didChangeSubject.eraseToAnyPublisher()
    }

    func resetToDefaults() {
        networkThrottleConfiguration = .defaults
    }
}

/// Isolated store bundle for one self-validation run — never wired to production stores (AI-5).
///
/// Concurrency: `@MainActor` — constructed and cleared by ``MCPSelfValidationCoordinator``.
@MainActor
final class MCPSelfValidationLane {
    let validationRunID: MCPValidationRunID
    let sessionStore: InMemorySessionStore
    let bookmarkStore: InMemoryBookmarkStore
    let responseOverrideStore: ResponseOverrideStore
    let bookmarkResponseInterceptStore: BookmarkResponseInterceptStore
    let policyStore: MCPPolicyStore
    let grantStore: MCPClientGrantStore
    let auditStore: MCPAuditStore
    let scenarioStore: MCPScenarioStore
    let effectJournalStore: MCPEffectJournalStore
    let recoveryCoordinator: MCPRecoveryCoordinator
    let configuration: MCPSelfValidationAppConfiguration
    let lifecycleCoordinator: MCPScenarioLifecycleCoordinator
    let approvalStore: MCPApprovalStore

    private let isolationDirectory: URL
    private let fileManager: FileManager

    init(validationRunID: MCPValidationRunID, fileManager: FileManager = .default) {
        self.validationRunID = validationRunID
        self.fileManager = fileManager
        self.isolationDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("JoesProxySelfValidation-\(validationRunID.rawValue)", isDirectory: true)

        try? fileManager.createDirectory(at: isolationDirectory, withIntermediateDirectories: true)

        self.sessionStore = InMemorySessionStore(retentionPolicy: .unlimited)
        self.bookmarkStore = InMemoryBookmarkStore()
        self.responseOverrideStore = ResponseOverrideStore()
        self.bookmarkResponseInterceptStore = BookmarkResponseInterceptStore()
        self.configuration = MCPSelfValidationAppConfiguration()

        self.policyStore = MCPPolicyStore()
        policyStore.load()

        self.grantStore = MCPClientGrantStore(
            persistenceURL: isolationDirectory.appendingPathComponent(MCPClientGrantStore.persistenceFileName)
        )
        grantStore.load()

        self.auditStore = MCPAuditStore(
            persistenceURL: isolationDirectory.appendingPathComponent("mcp-audit-self-validation.json")
        )
        auditStore.load()

        self.scenarioStore = MCPScenarioStore(
            persistenceURL: isolationDirectory.appendingPathComponent(MCPScenarioStore.persistenceFileName)
        )
        scenarioStore.load()

        self.effectJournalStore = MCPEffectJournalStore(
            persistenceURL: isolationDirectory.appendingPathComponent(MCPEffectJournalStore.persistenceFileName)
        )
        effectJournalStore.load()

        self.recoveryCoordinator = MCPRecoveryCoordinator(journalStore: effectJournalStore)
        recoveryCoordinator.bootstrap()

        self.lifecycleCoordinator = MCPScenarioLifecycleCoordinator(store: scenarioStore)
        lifecycleCoordinator.bootstrap()

        self.approvalStore = MCPApprovalStore()
    }

    /// Resets lane-owned state and removes the isolation directory.
    func clear() async {
        await responseOverrideStore.clearAll()
        sessionStore.clear()
        try? bookmarkStore.saveBookmarks([])
        auditStore.resetForSelfValidation()
        scenarioStore.resetForSelfValidation()
        effectJournalStore.resetForSelfValidation()
        grantStore.resetForSelfValidation()
        configuration.resetToDefaults()
        lifecycleCoordinator.bootstrap()
        try? fileManager.removeItem(at: isolationDirectory)
    }
}
