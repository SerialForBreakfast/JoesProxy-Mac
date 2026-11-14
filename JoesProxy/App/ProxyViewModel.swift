import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import os

@MainActor
final class ProxyViewModel: ObservableObject {
    struct SetupNetworkSnapshot: Equatable {
        let proxyPort: UInt16
        let lanIP: String?
        let bonjourName: String?

        static func current(
            proxyPort: UInt16,
            localNetworkInfoProvider: any LocalNetworkInfoProviding = SystemLocalNetworkInfoProvider()
        ) -> SetupNetworkSnapshot {
            let networkInfo = localNetworkInfoProvider.current()
            return SetupNetworkSnapshot(
                proxyPort: proxyPort,
                lanIP: networkInfo.lanIP,
                bonjourName: networkInfo.bonjourName
            )
        }
    }

    struct GuidedSetupChecklistItem: Identifiable, Equatable {
        enum State: Equatable {
            case complete
            case needsAction
            case waiting
            case warning
            case neutral
            case stale
        }

        enum Action: Equatable {
            case openCertificateSetup
            case openMacOSGuide
            case openIOSGuide
            case openTVOSGuide
            case openTrafficHelp
            case startProxy
            case verifyCapture
            case retryStatusValidation
            case resetCertificateState
        }

        let id: String
        let title: String
        let detail: String
        let state: State
        let primaryActionTitle: String?
        let primaryAction: Action?
        let secondaryActionTitle: String?
        let secondaryAction: Action?
        let helpTopic: MainWindowHelpTopic?
        let accessibilityIdentifier: String
    }

    enum CertificateWorkflowState: String, Equatable {
        case notSetUp = "Not set up"
        case installedTrustRequired = "Installed, trust required"
        case ready = "Ready for HTTPS inspection"
        case needsCleanup = "Needs cleanup"
    }

    typealias SetupVerificationState = AgentSetupVerificationState

    typealias SessionSortField = WorkspaceSortField

    enum ExportState: Equatable {
        case idle
        case exporting(scopeDescription: String)
        case succeeded(fileName: String)
        case failed(message: String)
    }

    enum BookmarkExecutionState: Equatable {
        case idle
        case executing(bookmarkID: Bookmark.ID)
        case failed(bookmarkID: Bookmark.ID, message: String)
    }

    enum SessionFindState: Equatable, Sendable {
        case idle
        case searching
        case emptyQuery
        case bodyUnavailable
        case noMatches(searchedBodyCount: Int)
        case results(matchCount: Int, searchedBodyCount: Int)
    }

    struct MapLocalMatchContext: Identifiable, Equatable {
        let sessionID: SessionRecord.ID

        var id: SessionRecord.ID { sessionID }
    }

    struct BookmarkUpdateContext: Equatable, Identifiable {
        let bookmarkID: Bookmark.ID
        let candidateSessionIDs: [SessionRecord.ID]

        var id: Bookmark.ID { bookmarkID }
    }

    /// Export format for captured sessions.
    enum ExportFormat: Equatable {
        case json
        case har
    }

    enum SessionFollowState: String, CaseIterable, Equatable {
        case staticInspection
        case followingLive
        case paused

        var title: String {
            switch self {
            case .staticInspection:
                return "Static"
            case .followingLive:
                return "Following"
            case .paused:
                return "Paused"
            }
        }
    }

    struct TrustAlertContext: Identifiable {
        enum Action {
            case acknowledge
            case resetCertificateState
        }

        let id = UUID()
        let title: String
        let message: String
        let primaryAction: Action
    }

    @Published private(set) var proxyState: ProxyRuntimeState
    @Published private var proxyStartRequested = false
    @Published private(set) var rootCertificate: RootCertificateIdentity?
    @Published private(set) var trustStatus: TrustInstallationStatus
    /// Adopted or minted CA-instance metadata for the live root fingerprint.
    @Published private(set) var certificateIdentity: CAInstanceMetadata?
    /// Identity health for the live root (orthogonal to ``trustStatus``).
    @Published private(set) var certificateIdentityStatus: CertificateIdentityStatus?
    var sessionCount: Int { captureWorkspace.totalCount }
    // @Published is required here: the health strip previously free-rode on the workspace
    // objectWillChange rebroadcast for re-renders; with that gone, health updates (throttled
    // to 2s during capture) must publish their own invalidation.
    @Published private(set) var captureHealth: CaptureHealthMetrics = .empty
    var filteredSessions: [SessionRecord] { captureWorkspace.filteredSessions }
    var sessionTableVisibleLimit: Int { captureWorkspace.visibleLimit }
    var sessionSummaries: [SessionSummary] { captureWorkspace.sessionSummaries }
    var sessionExplorerTree: SessionExplorerTree { captureWorkspace.explorerTree }
    var sessionExplorerVisibleRows: [SessionExplorerVisibleRow] { captureWorkspace.explorerVisibleRows }
    var sessionExplorerRevision: UInt64 { captureWorkspace.explorerRevision }
    var isRebuildingExplorer: Bool { captureWorkspace.isRebuildingExplorer }
    var timelineAnalysisResult: TimelineAnalysisResult { captureWorkspace.timelineAnalysisResult }
    var isAnalyzingTimeline: Bool { captureWorkspace.isAnalyzingTimeline }
    var timelinePinCount: Int { captureWorkspace.timelinePins.count }
    @Published private(set) var bookmarks: [Bookmark]
    /// Bookmark response rewrites enabled for the current proxy session only; never persisted.
    @Published private(set) var enabledBookmarkResponseRewriteIDs: Set<Bookmark.ID> = []
    /// Session-scoped intercept telemetry keyed by bookmark ID; cleared when rewrites are disabled or the proxy stops.
    @Published private(set) var bookmarkResponseRewriteActivityByID: [Bookmark.ID: BookmarkResponseRewriteActivity] = [:]
    @Published var sessionFilterCriteria = SessionFilterCriteria() {
        didSet {
            guard oldValue != sessionFilterCriteria else { return }
            captureWorkspace.filterCriteria = sessionFilterCriteria
        }
    }
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published var sessionSearchText = ""
    @Published var sessionFindQuery = "" {
        didSet {
            guard oldValue != sessionFindQuery else {
                return
            }

            clearSessionFindResults()
        }
    }
    @Published private(set) var sessionFindResults: [SessionFindResult] = []
    /// Number of `sessionFindResults` rows currently exposed to the Find panel list.
    @Published private(set) var sessionFindVisibleResultLimit = SessionFindPresentation.initialVisibleResultCount
    @Published private(set) var sessionFindState: SessionFindState = .idle
    /// The body location (request or response) of the most recently selected find result.
    /// Consumed by `SessionDetailView` to auto-switch the JSON view mode to Prettified.
    /// Cleared when the find query changes or results are cleared.
    @Published private(set) var activeFindResultLocation: SessionFindResult.MatchLocation? = nil
    /// The session ID of the most recently selected find result.
    /// Used with `activeFindResultLocation` to avoid applying find-navigation UI work to
    /// manual session selections that merely happen to match the current query.
    @Published private(set) var activeFindResultSessionID: SessionRecord.ID? = nil
    /// Unique token for each Find result navigation, including repeated selections of the
    /// same result. Downstream views use it to re-run native scroll/pulse behavior.
    @Published private(set) var activeFindNavigationID: UUID? = nil
    @Published var appTextSize: AppTextSize
    @Published var isFindDebugLoggingEnabled: Bool {
        didSet {
            guard oldValue != isFindDebugLoggingEnabled else {
                return
            }

            configuration.isFindDebugLoggingEnabled = isFindDebugLoggingEnabled
        }
    }
    @Published var sessionSortField: SessionSortField {
        didSet {
            guard oldValue != sessionSortField else { return }
            captureWorkspace.sortField = sessionSortField
        }
    }
    @Published var isSessionSortAscending: Bool {
        didSet {
            guard oldValue != isSessionSortAscending else { return }
            captureWorkspace.isSortAscending = isSessionSortAscending
        }
    }
    @Published private(set) var sessionFollowState: SessionFollowState = .staticInspection
    var isSessionAutoScrollEnabled: Bool {
        get { sessionFollowState == .followingLive }
        set { setFollowLiveEnabled(newValue) }
    }
    @Published var sessionBrowserMode: SessionBrowserMode {
        didSet {
            guard oldValue != sessionBrowserMode else { return }
            pauseFollowLiveForUserInteraction()
            let fromMode = oldValue.rawValue
            let toMode = sessionBrowserMode.rawValue
            let count = captureWorkspace.filteredSessionCount
            BrowserPerformanceSignposts.signposter.emitEvent(
                "SessionBrowser.modeTransition",
                "\(fromMode) → \(toMode), \(count) sessions"
            )
            if sessionBrowserMode == .explorer {
                modeSwitchSignpost = BrowserPerformanceSignposts.signposter.beginInterval(
                    "SessionBrowser.modeSwitch",
                    "\(count) sessions"
                )
            }
            captureWorkspace.browserMode = sessionBrowserMode
        }
    }
    @Published var sessionExplorerGrouping: SessionExplorerGrouping {
        didSet {
            guard oldValue != sessionExplorerGrouping else { return }
            pauseFollowLiveForUserInteraction()
            captureWorkspace.explorerGrouping = sessionExplorerGrouping
        }
    }
    @Published var sessionExplorerHostGrouping: SessionExplorerHostGrouping {
        didSet {
            guard oldValue != sessionExplorerHostGrouping else { return }
            pauseFollowLiveForUserInteraction()
            captureWorkspace.explorerHostGrouping = sessionExplorerHostGrouping
        }
    }
    @Published var sessionExplorerExpandedNodeIDs: Set<String> {
        didSet {
            guard oldValue != sessionExplorerExpandedNodeIDs else { return }
            if !isApplyingProgrammaticExplorerExpansion {
                pauseFollowLiveForUserInteraction()
            }
            let expandedCount = sessionExplorerExpandedNodeIDs.count
            let sp = BrowserPerformanceSignposts.signposter.beginInterval(
                "SessionBrowser.nodeExpansion",
                "\(expandedCount) expanded"
            )
            captureWorkspace.explorerExpandedNodeIDs = sessionExplorerExpandedNodeIDs
            BrowserPerformanceSignposts.signposter.endInterval("SessionBrowser.nodeExpansion", sp)
        }
    }
    @Published var timelineFilterState: TimelineFilterState = .empty {
        didSet {
            guard oldValue != timelineFilterState else { return }
            pauseFollowLiveForUserInteraction()
            captureWorkspace.timelineFilterState = timelineFilterState
        }
    }
    @Published var sessionInspectorSplitFraction: Double
    @Published var httpsBypassDomains: [String]
    @Published var httpsInterceptDomains: [String]
    @Published var isNoCachingEnabled: Bool
    @Published var noCachingDomains: [String]
    @Published var networkThrottleConfiguration: NetworkThrottleConfiguration
    @Published var proxyPortDraft: String
    @Published var selectedSessionID: SessionRecord.ID? {
        didSet {
            guard oldValue != selectedSessionID else { return }
            captureWorkspace.selectedSessionID = selectedSessionID
        }
    }
    @Published var selectedBookmarkID: Bookmark.ID?
    @Published var lastErrorMessage: String?
    @Published var trustAlertContext: TrustAlertContext?
    @Published private(set) var exportState: ExportState = .idle
    @Published private(set) var recordingLoadState: RecordingLoadCoordinator.LoadState = .idle
    /// Advisory notice set when a version-0 or future-schema recording was opened successfully.
    @Published private(set) var recordingSchemaNotice: String?
    @Published var rollingCapturePersistenceError: String?
    @Published private(set) var isClearSnapshotPending = false
    private var clearSnapshotTask: Task<Void, Never>?
    /// Deterministic test seam for a stalled explicit-snapshot write; no disk access is required.
    var clearSnapshotWriterOverride: (@MainActor ([SessionRecord]) async -> Void)?
    static let clearSnapshotBusyMessage = "The previous clear is still processing its recovery snapshot. This capture has not been cleared. Wait for that operation to finish, then try Clear All again."
    /// Non-nil while a "schema too new" warning is awaiting user confirmation.
    /// The UI should present a sheet offering "Load Anyway" / "Cancel".
    @Published private(set) var pendingSchemaWarning: RecordingLoadCoordinator.SchemaVersionWarning?
    @Published private(set) var bookmarkExecutionState: BookmarkExecutionState = .idle
    @Published private(set) var bookmarkUpdateContext: BookmarkUpdateContext?
    @Published private(set) var responseOverrides: [ResponseOverrideRule] = []
    @Published private(set) var hlsSubstitutionExperiments: [HLSSubstitutionExperiment] = []
    @Published private(set) var hlsFixtureProfiles: [HLSFixtureProfileDescriptor] = []
    @Published private(set) var openAPIMockPacks: [OpenAPIMockPack] = []
    @Published private(set) var isResettingTrafficModifications = false
    @Published private(set) var setupVerificationState: SetupVerificationState?
    @Published private(set) var setupNetworkSnapshot: SetupNetworkSnapshot?
    /// Base URL of the running profile server (e.g. `http://192.168.1.5:8765`).
    /// `nil` when the server is not running.
    @Published private(set) var profileServerURL: URL?
    /// User-facing profile-server startup failure; cleared on successful start or stop.
    @Published private(set) var profileServerStartErrorMessage: String?
    /// True after the profile server has successfully served the trust profile to a device.
    /// Reset when the profile server stops.
    @Published private(set) var profileServerDownloadDetected = false
    /// True while `trustRootCertificate()` is running the `security add-trusted-cert` command.
    @Published private(set) var isTrustingCertificate = false
    /// Live result of the macOS verify step (watching for Mac traffic via captive.apple.com).
    @Published private(set) var macVerifyResult: TrafficWatchResult = .ready
    /// Live result of the iOS/tvOS device verify step (watching for any device traffic).
    @Published private(set) var deviceVerifyResult: TrafficWatchResult = .ready
    /// The source IP of the device whose traffic triggered `.captured` in the last device verify.
    @Published private(set) var deviceVerifyClientAddress: String? = nil
    /// The reverse-DNS hostname for `deviceVerifyClientAddress` (e.g. "appletv.local"), if resolved.
    @Published private(set) var deviceVerifyHostname: String? = nil
    /// Current SDK event server status, used by device setup walkthroughs.
    @Published private(set) var sdkEventServerStatus: SDKEventServerStatus = .stopped
    @Published var profileHostStrategy: ProfileHostStrategy {
        didSet {
            guard oldValue != profileHostStrategy else { return }
            configuration.profileHostStrategyRawValue = profileHostStrategy.rawValue
            refreshProfileMaintenanceStatus()
        }
    }
    @Published var manualProfileHost: String {
        didSet {
            guard oldValue != manualProfileHost else { return }
            configuration.manualProfileHost = manualProfileHost
            refreshProfileMaintenanceStatus()
        }
    }
    @Published private(set) var profileSnapshots: [GeneratedProfileSnapshot] = []
    @Published private(set) var profileSnapshotDiagnosis: ProfileSnapshotDiagnosis = .evaluate(
        snapshot: nil,
        currentNetworkInfo: LocalNetworkInfo(lanIP: nil, bonjourName: nil),
        currentProxyPort: NetworkConstants.defaultPort,
        currentCertificateFingerprint: nil
    )

    let httpsProxyMode: HTTPSProxyMode
    let configuration: AppConfiguration
    /// Optional rolling auto-save coordinator wired from ``AppCoordinator`` after initialization.
    var rollingCapturePersistence: RollingCapturePersistenceCoordinator?
    /// Optional previous-run diagnostics coordinator wired from ``AppCoordinator``.
    var previousRunDiagnosticsCoordinator: PreviousRunDiagnosticsCoordinator?
    /// Non-blocking launch offer to restore the latest rolling capture snapshot.
    @Published var rollingCaptureRestoreOffer: RollingCaptureRestoreOffer?
    private var isUITestRollingCaptureRestoreOffer = false
    private var isRestoringRollingCapture = false

    private let proxyRuntime: any ProxyRuntime
    private let sessionStore: any SessionStore
    private let exportService: any ExportService
    private let bookmarkStore: any BookmarkStore
    private let bookmarkExecutor: any BookmarkExecuting
    private let harExportService: any ExportService
    private let reproPackageEngine = ReproPackageEngine()
    private let reproHARImportService = ReproHARImportService()
    private let iosDeviceTrustProfileExporter: any IOSDeviceTrustProfileExporting
    private let tvOSManagedProfileExporter: any TVOSManagedProfileExporting
    private let responseOverrideStore: ResponseOverrideStore
    private let bookmarkResponseInterceptStore: BookmarkResponseInterceptStore
    private let hlsSubstitutionCoordinator: HLSSubstitutionCoordinator?
    private let openAPIMockPackCoordinator: OpenAPIMockPackCoordinator?
    let effectBundleRepository: EffectBundleRepository
    let collectionMockAuthoringService: CollectionMockAuthoringService
    let mockIconSuggestionService: any MockIconSuggesting
    let similarItemTextGenerator: any SimilarItemTextGenerating
    let effectBundleCoordinator: EffectBundleActivationCoordinator
    let openAPISchemaStore: OpenAPISchemaStore
    /// Completes once the initial persisted response-override load finishes. `JoesProxyApp.init`
    /// awaits this before running the MCP fresh-launch state purge, so the purge never races the
    /// async load and misses rules that were about to be rehydrated into `responseOverrideStore`.
    /// Assigned a placeholder early in `init` (a `self`-capturing `Task` can't be assigned to a
    /// stored property before every other property is set) and replaced with the real task at the
    /// end of `init`, once `self` is fully initialized.
    private(set) var initialResponseOverrideLoadTask: Task<Void, Never>
    /// Observes `responseOverrideStore.changes` for the app's lifetime so rules created/enabled/
    /// disabled/removed via MCP (not just this view model's own UI-driven mutation methods) are
    /// reflected in the "Local Overrides" UI. Started at the end of `init`, alongside
    /// `initialResponseOverrideLoadTask` — see that property's comment for why `self`-capturing
    /// tasks can't be assigned any earlier.
    private var responseOverrideChangeObservationTask: Task<Void, Never>?
    private let certificateAuthority: any CertificateAuthorityProviding
    private let certificateStore: any CertificateStore
    private let trustInstaller: any TrustInstalling
    private let certificateStatusReader: (any CertificateStatusReading)?
    private let caInstanceMetadataStore: CAInstanceMetadataStore
    private let certificateDistributionRecordStore: CertificateDistributionRecordStore
    private let systemProxyController: SystemProxyController?
    private let localNetworkInfoProvider: any LocalNetworkInfoProviding
    private let processMetricsSampler: any ProcessMetricsSampling
    private let profileHostingServer: ProfileHostingServer
    private let profileSnapshotStore: any ProfileSnapshotStoring
    private let profileHostResolver = ProfileHostResolver()
    private let trafficWatcher: TrafficWatchVerifier
    private let captureWorkspace: CaptureWorkspaceViewModel

    func setInspectorPresentationActive(_ active: Bool) {
        guard captureWorkspace.isInspectorPresentationActive != active else { return }
        AgentWorkspaceDiagnostics.shared.recordInspectorPresentation(active: active)
        captureWorkspace.setInspectorPresentationActive(active)
    }

    enum PrimaryPaneMode: String, CaseIterable, Identifiable {
        case sessions
        case bookmarks
        var id: String { rawValue }
        var title: String { self == .sessions ? "Sessions" : "Bookmarks" }
    }

    @Published var primaryPaneMode: PrimaryPaneMode = .sessions
    @Published var selectedExplorerNodeID: String?
    @Published var workspacePaneFocus: WorkspacePaneFocus = .browser
    @Published var hasInspectorEditorPresented = false

    struct WorkspacePreferences {
        let filters: SessionFilterCriteria
        let search: String
        let sort: SessionSortField
        let ascending: Bool
        let mode: SessionBrowserMode
        let grouping: SessionExplorerGrouping
        let hostGrouping: SessionExplorerHostGrouping
        let expandedIDs: Set<String>
        let selectedID: SessionRecord.ID?
        let bookmarkID: Bookmark.ID?
        let primaryPane: PrimaryPaneMode
        let explorerNodeID: String?
        let paneFocus: WorkspacePaneFocus
        let findQuery: String
        let follow: Bool
    }

    var workspacePreferences: WorkspacePreferences {
        WorkspacePreferences(filters: sessionFilterCriteria, search: sessionSearchText,
            sort: sessionSortField, ascending: isSessionSortAscending, mode: sessionBrowserMode,
            grouping: sessionExplorerGrouping, hostGrouping: sessionExplorerHostGrouping,
            expandedIDs: sessionExplorerExpandedNodeIDs, selectedID: selectedSessionID,
            bookmarkID: selectedBookmarkID, primaryPane: primaryPaneMode,
            explorerNodeID: selectedExplorerNodeID, paneFocus: workspacePaneFocus,
            findQuery: sessionFindQuery,
            follow: isSessionAutoScrollEnabled)
    }

    func restoreWorkspacePreferences(_ saved: WorkspacePreferences) {
        sessionFilterCriteria = saved.filters
        sessionSearchText = saved.search
        sessionSortField = saved.sort
        isSessionSortAscending = saved.ascending
        sessionBrowserMode = saved.mode
        sessionExplorerGrouping = saved.grouping
        sessionExplorerHostGrouping = saved.hostGrouping
        sessionExplorerExpandedNodeIDs = saved.expandedIDs
        // Preserve a missing ID as an unavailable destination, not a request to select newest.
        selectedSessionID = saved.selectedID
        selectedBookmarkID = saved.bookmarkID
        primaryPaneMode = saved.primaryPane
        selectedExplorerNodeID = saved.explorerNodeID
        workspacePaneFocus = saved.paneFocus
        sessionFindQuery = saved.findQuery
        isSessionAutoScrollEnabled = saved.follow
    }

    /// These operations still have Inspector-owned presentation. Refuse to tear them down until
    /// their owners have completed; never abandon a save or recovery to achieve a lean graph.
    var agentTransitionBlocker: String? {
        if hasInspectorEditorPresented { return "Finish or close the Inspector editor before switching workspaces." }
        if isTrustingCertificate || isResettingTrafficModifications {
            return "Wait for the current trust or modification operation to finish."
        }
        if pendingSchemaWarning != nil { return "Resolve the pending recording warning first." }
        if case .exporting = exportState { return "Wait for the current export to finish." }
        if recordingLoadState == .loading || isRestoringRollingCapture || clearSnapshotTask != nil {
            return "Wait for capture recovery or loading to finish."
        }
        if case .executing = bookmarkExecutionState { return "Wait for bookmark execution to finish." }
        if profileServerURL != nil { return "Stop profile hosting before leaving Inspector." }
        return nil
    }

    func suspendForAgentWorkspace() {
        setInspectorPresentationActive(false)
        captureWorkspace.stopPresentation()
        sessionFindTask?.cancel()
        sessionFindTask = nil
        macVerifyTask?.cancel()
        deviceVerifyTask?.cancel()
        certificateStatusRefreshTask?.cancel()
        responseOverrideChangeObservationTask?.cancel()
        cancellables.removeAll()
    }
    private let sessionFindEngine = SessionFindEngine()
    private var macVerifyTask: Task<Void, Never>?
    private var deviceVerifyTask: Task<Void, Never>?
    private var certificateStatusRefreshTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.JoesProxyApp.TrustFlow", category: "ProxyViewModel")
    private let captureDiagnosticsLogger = Logger(
        subsystem: "com.JoesProxyApp.Capture",
        category: "LongCaptureDiagnostics"
    )
    private let recordingLoadCoordinator: RecordingLoadCoordinator
    private let recordingFileCoordinator = RecordingFileCoordinator()
    private var cancellables: Set<AnyCancellable> = []
    private var latestProcessMetrics: AppProcessMetrics = .empty
    /// Signpost state for the full Table→Explorer mode-switch interval. Held from
    /// `sessionBrowserMode.didSet` until captureWorkspace's rebuild completes via `onExplorerRebuildComplete`.
    private var modeSwitchSignpost: OSSignpostIntervalState?
    private var sessionFindTask: Task<Void, Never>?
    /// Pre-decoded UTF-8 body text per session, populated lazily during find runs.
    private var sessionBodyTextCacheByID: [SessionRecord.ID: SessionBodyText] = [:]
    /// Running byte count for `sessionBodyTextCacheByID`. Reset to 0 whenever the cache is cleared.
    private var cachedBodyTextByteCount: Int = 0
    /// Find-run counter for budget eviction: entries carry the generation they were inserted
    /// in, and the oldest generations are evicted first when the cache budget overflows.
    private var bodyTextCacheGeneration: UInt64 = 0
    private var bodyTextCacheGenerationByID: [SessionRecord.ID: UInt64] = [:]
    private struct RetiredBodyTextCache: Sendable {
        let bodyTextByID: [SessionRecord.ID: SessionBodyText]
        let generationByID: [SessionRecord.ID: UInt64]
    }
    /// Test seam: overrides the 50 MB body-text cache budget so eviction can be exercised
    /// without decoding tens of megabytes. Always nil in production.
    var bodyTextCacheBudgetBytesOverride: Int?
    /// Test seam: session IDs currently held in the body-text cache.
    var cachedBodyTextSessionIDs: Set<SessionRecord.ID> { Set(sessionBodyTextCacheByID.keys) }
    private var lastHealthUpdateTime: Date = .distantPast
    private var captureDiagnosticsCadence = CaptureDiagnosticsLogCadence()
    private var didEmitFinalCaptureDiagnosticsSummary = false
    private let captureTransportDiagnostics: CaptureTransportDiagnostics
    private let deviceRegistry: DeviceRegistry
    private var isApplyingProgrammaticExplorerExpansion = false
    /// Set when the proxy transitions to `.running`; cleared on `.stopped`.
    private var captureStartedAt: Date?
    init(
        configuration: AppConfiguration,
        httpsProxyMode: HTTPSProxyMode,
        proxyRuntime: any ProxyRuntime,
        sessionStore: any SessionStore,
        exportService: any ExportService,
        bookmarkStore: any BookmarkStore,
        bookmarkExecutor: any BookmarkExecuting,
        harExportService: any ExportService,
        iosDeviceTrustProfileExporter: any IOSDeviceTrustProfileExporting,
        responseOverrideStore: ResponseOverrideStore,
        bookmarkResponseInterceptStore: BookmarkResponseInterceptStore = BookmarkResponseInterceptStore(),
        hlsSubstitutionCoordinator: HLSSubstitutionCoordinator? = nil,
        openAPIMockPackCoordinator: OpenAPIMockPackCoordinator? = nil,
        openAPISchemaStore: OpenAPISchemaStore = OpenAPISchemaStore(),
        certificateAuthority: any CertificateAuthorityProviding,
        certificateStore: any CertificateStore,
        trustInstaller: any TrustInstalling,
        certificateStatusReader: (any CertificateStatusReading)? = nil,
        caInstanceMetadataStore: CAInstanceMetadataStore? = nil,
        certificateDistributionRecordStore: CertificateDistributionRecordStore? = nil,
        loadsPersistedResponseOverrides: Bool = true,
        systemProxyController: SystemProxyController? = nil,
        setupVerificationState: SetupVerificationState? = nil,
        recordingImportService: (any SessionRecordingImportService)? = nil,
        processMetricsSampler: any ProcessMetricsSampling = CurrentProcessMetricsSampler(),
        localNetworkInfoProvider: any LocalNetworkInfoProviding = SystemLocalNetworkInfoProvider(),
        profileSnapshotStore: (any ProfileSnapshotStoring)? = nil,
        captureTransportDiagnostics: CaptureTransportDiagnostics = CaptureTransportDiagnostics(),
        deviceRegistry: DeviceRegistry = .shared,
        effectBundleRepository: EffectBundleRepository? = nil,
        effectBundleCoordinator: EffectBundleActivationCoordinator? = nil,
        collectionMockAuthoringService: CollectionMockAuthoringService? = nil,
        mockIconSuggestionService: any MockIconSuggesting = MockIconSuggestionService(),
        similarItemTextGenerator: any SimilarItemTextGenerating = LocalSimilarItemTextGenerator()
    ) {
        self.captureWorkspace = CaptureWorkspaceViewModel(store: sessionStore)
        self.configuration = configuration
        self.httpsProxyMode = httpsProxyMode
        self.proxyRuntime = proxyRuntime
        self.sessionStore = sessionStore
        self.exportService = exportService
        self.bookmarkStore = bookmarkStore
        self.bookmarkExecutor = bookmarkExecutor
        self.harExportService = harExportService
        self.iosDeviceTrustProfileExporter = iosDeviceTrustProfileExporter
        self.tvOSManagedProfileExporter = TVOSManagedProfileExporter(
            configuration: configuration,
            certificateAuthority: certificateAuthority
        )
        self.responseOverrideStore = responseOverrideStore
        self.bookmarkResponseInterceptStore = bookmarkResponseInterceptStore
        self.hlsSubstitutionCoordinator = hlsSubstitutionCoordinator
        self.openAPIMockPackCoordinator = openAPIMockPackCoordinator
        let resolvedEffectBundleRepository = effectBundleRepository ?? EffectBundleRepository()
        self.effectBundleRepository = resolvedEffectBundleRepository
        self.collectionMockAuthoringService = collectionMockAuthoringService ?? CollectionMockAuthoringService()
        self.mockIconSuggestionService = mockIconSuggestionService
        self.similarItemTextGenerator = similarItemTextGenerator
        self.effectBundleCoordinator = effectBundleCoordinator ?? EffectBundleActivationCoordinator(
            repository: resolvedEffectBundleRepository,
            responseOverrideStore: responseOverrideStore,
            hlsCoordinator: hlsSubstitutionCoordinator ?? HLSSubstitutionCoordinator(
                runStore: HLSFixtureRunStore(),
                routeStore: HLSSubstitutionRouteStore(),
                responseOverrideStore: responseOverrideStore
            ),
            loopbackPolicyProvider: { @MainActor [configuration] in
                configuration.loopbackDestinationPolicy
            }
        )
        self.openAPISchemaStore = openAPISchemaStore
        self.certificateAuthority = certificateAuthority
        self.certificateStore = certificateStore
        self.trustInstaller = trustInstaller
        self.certificateStatusReader = certificateStatusReader
        // An injected store may be shared with the MCP certificate tools and already loaded —
        // re-loading would discard whatever the other holder has in memory but not yet persisted.
        let resolvedCAInstanceMetadataStore = caInstanceMetadataStore ?? CAInstanceMetadataStore()
        if !resolvedCAInstanceMetadataStore.isLoaded { resolvedCAInstanceMetadataStore.load() }
        self.caInstanceMetadataStore = resolvedCAInstanceMetadataStore
        let resolvedDistributionStore = certificateDistributionRecordStore ?? CertificateDistributionRecordStore()
        if !resolvedDistributionStore.isLoaded { resolvedDistributionStore.load() }
        self.certificateDistributionRecordStore = resolvedDistributionStore
        self.systemProxyController = systemProxyController
        self.localNetworkInfoProvider = localNetworkInfoProvider
        self.processMetricsSampler = processMetricsSampler
        self.captureTransportDiagnostics = captureTransportDiagnostics
        self.deviceRegistry = deviceRegistry
        self.profileSnapshotStore = profileSnapshotStore ?? ProfileSnapshotStore.defaultStore()
        self.profileHostingServer = ProfileHostingServer(
            certificateAuthority: certificateAuthority,
            profileExporter: iosDeviceTrustProfileExporter
        )
        self.trafficWatcher = TrafficWatchVerifier(sessionStore: sessionStore)
        let resolvedImportService = recordingImportService ?? JSONSessionRecordingImportService()
        self.recordingLoadCoordinator = RecordingLoadCoordinator(
            importService: resolvedImportService,
            sessionStore: sessionStore
        )
        self.proxyState = proxyRuntime.currentState
        self.rootCertificate = certificateStatusReader == nil
            ? certificateAuthority.currentRootCertificate()
            : nil
        self.trustStatus = certificateStatusReader == nil
            ? trustInstaller.installationStatus(for: configuration.certificateLabel)
            : .notInstalled
        self.setupVerificationState = setupVerificationState
        self.bookmarks = Self.sortBookmarks(bookmarkStore.loadBookmarks())
        self.appTextSize = AppTextSize(rawValue: configuration.appTextSizeRawValue) ?? .standard
        self.isFindDebugLoggingEnabled = configuration.isFindDebugLoggingEnabled
        self.sessionSortField = SessionSortField(rawValue: configuration.sessionSortFieldRawValue) ?? .startedAt
        self.isSessionSortAscending = configuration.isSessionSortAscending
        self.sessionBrowserMode = SessionBrowserMode(rawValue: configuration.sessionBrowserModeRawValue) ?? .table
        self.sessionExplorerGrouping = SessionExplorerGrouping(rawValue: configuration.sessionExplorerGroupingRawValue) ?? .byHost
        self.sessionExplorerHostGrouping = SessionExplorerHostGrouping(rawValue: configuration.sessionExplorerHostGroupingRawValue) ?? .exactHosts
        self.sessionExplorerExpandedNodeIDs = Set(configuration.sessionExplorerExpandedNodeIDs)
        self.sessionInspectorSplitFraction = configuration.sessionInspectorSplitFraction
        self.httpsBypassDomains = configuration.httpsBypassDomains
        self.httpsInterceptDomains = configuration.httpsInterceptDomains
        self.isNoCachingEnabled = configuration.isNoCachingEnabled
        self.noCachingDomains = configuration.noCachingDomains
        self.networkThrottleConfiguration = MCPTargetRevisionFingerprint.throttleByApplyingRevision(
            configuration.networkThrottleConfiguration
        )
        self.proxyPortDraft = String(configuration.proxyPort)
        self.profileHostStrategy = ProfileHostStrategy(rawValue: configuration.profileHostStrategyRawValue) ?? .bonjourLocal
        self.manualProfileHost = configuration.manualProfileHost
        self.profileSnapshots = self.profileSnapshotStore.loadSnapshots()
        self.initialResponseOverrideLoadTask = Task {}
        self.hlsSubstitutionExperiments = hlsSubstitutionCoordinator?.experiments ?? []
        self.hlsFixtureProfiles = hlsSubstitutionCoordinator?.profiles ?? []
        self.openAPIMockPacks = openAPIMockPackCoordinator?.packs ?? []
        Self.wireProfileExportIdentity(
            iosExporter: iosDeviceTrustProfileExporter,
            tvOSExporter: tvOSManagedProfileExporter,
            viewModel: self
        )
        refreshCertificateIdentity(didCreateNewRoot: false)
        self.refreshProfileMaintenanceStatus()

        Task { [weak self] in
            await self?.syncBookmarkResponseInterceptStore()
        }

        // MARK: - Workspace setup (push loaded preferences into captureWorkspace)
        captureWorkspace.filterCriteria = sessionFilterCriteria
        captureWorkspace.searchText = sessionSearchText
        captureWorkspace.sortField = sessionSortField
        captureWorkspace.isSortAscending = isSessionSortAscending
        captureWorkspace.browserMode = sessionBrowserMode
        captureWorkspace.explorerGrouping = sessionExplorerGrouping
        captureWorkspace.explorerHostGrouping = sessionExplorerHostGrouping
        captureWorkspace.explorerExpandedNodeIDs = sessionExplorerExpandedNodeIDs
        captureWorkspace.selectedSessionID = selectedSessionID
        self.sessionFollowState = configuration.isSessionAutoScrollEnabled ? .followingLive : .staticInspection

        // The workspace is @Observable: views that read capture state through this view
        // model's computed properties are tracked per-property by SwiftUI, so the old
        // objectWillChange rebroadcast (which invalidated the entire ContentView tree on
        // every recompute pulse) is intentionally gone.
        // Deferred to the next runloop turn: this callback fires synchronously at the end
        // of every CaptureWorkspaceViewModel.runRecompute() pass, which during live capture
        // resumes on the MainActor roughly every 75ms (the recompute coalescing window) —
        // frequently enough to land mid-SwiftUI-render. reconcileSelectionForVisibleSessionsChange
        // writes `selectedSessionID`, a Combine @Published property on this ObservableObject,
        // so an undeferred write here is a "Publishing changes from within view updates"
        // candidate. This mirrors the deferral pattern the old captureWorkspace.objectWillChange
        // rebroadcast used before the @Observable migration removed it.
        captureWorkspace.onFilteredSessionsChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.reconcileSelectionForVisibleSessionsChange()
            }
        }

        captureWorkspace.onExplorerRebuildComplete = { [weak self] in
            guard let self, let sp = self.modeSwitchSignpost else { return }
            BrowserPerformanceSignposts.signposter.endInterval("SessionBrowser.modeSwitch", sp)
            self.modeSwitchSignpost = nil
        }

        proxyRuntime.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self else { return }
                self.proxyState = newState
                self.captureWorkspace.isCaptureActive = self.isCaptureActive
                switch newState {
                case .running:
                    if self.captureStartedAt == nil {
                        self.captureStartedAt = Date()
                        self.captureDiagnosticsCadence.reset()
                        self.didEmitFinalCaptureDiagnosticsSummary = false
                    }
                    if self.configuration.isSessionAutoScrollEnabled {
                        self.sessionFollowState = .followingLive
                        self.selectNewestVisibleSession()
                    }
                    Task { [weak self] in
                        await self?.syncBookmarkResponseInterceptStore()
                    }
                case .stopped:
                    self.emitFinalCaptureDiagnosticsSummaryIfNeeded()
                    self.clearEnabledBookmarkResponseRewritesForStoppedProxy()
                default:
                    break
                }
                self.reconcileSystemProxyManagement()
                self.sampleProcessMetrics()
                self.captureHealth = self.makeHealthMetrics()
                self.emitCaptureDiagnosticsSummary(force: false)
                Task { @MainActor [weak self] in
                    await self?.refreshSDKEventServerStatus()
                }
            }
            .store(in: &cancellables)

        hlsSubstitutionCoordinator?.$experiments
            .receive(on: RunLoop.main)
            .sink { [weak self] experiments in
                self?.hlsSubstitutionExperiments = experiments
            }
            .store(in: &cancellables)

        hlsSubstitutionCoordinator?.$profiles
            .receive(on: RunLoop.main)
            .sink { [weak self] profiles in
                self?.hlsFixtureProfiles = profiles
            }
            .store(in: &cancellables)

        openAPIMockPackCoordinator?.$packs
            .receive(on: RunLoop.main)
            .sink { [weak self] packs in
                self?.openAPIMockPacks = packs
            }
            .store(in: &cancellables)

        // React to the system-proxy preference changing while the proxy is already running, so
        // enabling the toggle mid-session takes effect immediately instead of waiting for a restart.
        configuration.didChangePublisher
            .debounce(for: .zero, scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.reconcileSystemProxyManagement()
                self?.refreshProfileMaintenanceStatus()
            }
            .store(in: &cancellables)

        sessionStore.sessionChangesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                self.applyBodyTextCacheChange(change)
                self.applyBookmarkRewriteIntercept(change)
                self.applyDeviceRegistryUpdate(change)
                self.updateCaptureHealthThrottled()
            }
            .store(in: &cancellables)

        $sessionSearchText
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] newValue in
                guard let self else { return }
                self.pauseFollowLiveForUserInteraction()
                self.captureWorkspace.searchText = newValue
            }
            .store(in: &cancellables)

        $sessionSortField
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.sessionSortFieldRawValue = newValue.rawValue
            }
            .store(in: &cancellables)

        $appTextSize
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.appTextSizeRawValue = newValue.rawValue
            }
            .store(in: &cancellables)

        $isSessionSortAscending
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.isSessionSortAscending = newValue
            }
            .store(in: &cancellables)

        $sessionBrowserMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.sessionBrowserModeRawValue = newValue.rawValue
            }
            .store(in: &cancellables)

        $sessionExplorerGrouping
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.sessionExplorerGroupingRawValue = newValue.rawValue
            }
            .store(in: &cancellables)

        $sessionExplorerHostGrouping
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.sessionExplorerHostGroupingRawValue = newValue.rawValue
            }
            .store(in: &cancellables)

        $sessionExplorerExpandedNodeIDs
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.sessionExplorerExpandedNodeIDs = newValue.sorted()
            }
            .store(in: &cancellables)

        $sessionInspectorSplitFraction
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.sessionInspectorSplitFraction = newValue
            }
            .store(in: &cancellables)

        $httpsBypassDomains
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.httpsBypassDomains = newValue
            }
            .store(in: &cancellables)

        $httpsInterceptDomains
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.httpsInterceptDomains = newValue
            }
            .store(in: &cancellables)

        $isNoCachingEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.isNoCachingEnabled = newValue
            }
            .store(in: &cancellables)

        $noCachingDomains
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.configuration.noCachingDomains = newValue
            }
            .store(in: &cancellables)

        $networkThrottleConfiguration
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                // Recompute here — this is the single funnel every throttle edit (legacy Settings
                // UI included) passes through before persistence. Without this, `mcpTargetRevision`
                // would stay frozen at whatever it was before the edit, silently defeating the MCP
                // proposal system's staleness check.
                self?.configuration.networkThrottleConfiguration =
                    MCPTargetRevisionFingerprint.throttleByApplyingRevision(newValue)
            }
            .store(in: &cancellables)

        configuration.didChangePublisher
            .debounce(for: .zero, scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.reloadPersistedPreferencesFromConfiguration()
            }
            .store(in: &cancellables)

        // captureWorkspace subscribes to sessionStore and runs a recompute automatically

        initialResponseOverrideLoadTask = loadsPersistedResponseOverrides
            ? Task { [weak self] in
                await self?.loadPersistedResponseOverrides()
                await self?.refreshResponseOverrides()
            }
            : Task {}

        let overrideChanges = responseOverrideStore.changes
        responseOverrideChangeObservationTask = Task { [weak self] in
            for await _ in overrideChanges {
                await self?.refreshResponseOverrides()
            }
        }

        refreshDiscoveredDevices()
    }

    deinit {
        AgentWorkspaceDiagnostics.shared.recordInspectorModelRelease()
    }

    var selectedSessionContentRevision: UInt64 { captureWorkspace.selectedSessionContentRevision }

    var selectedSession: SessionRecord? {
        guard let selectedSessionID else {
            guard let newestID = captureWorkspace.newestVisibleSessionID() else { return nil }
            return captureWorkspace.visibleSession(for: newestID)
        }

        return captureWorkspace.visibleSession(for: selectedSessionID) ?? captureWorkspace.sessionRecord(for: selectedSessionID)
    }

    var selectedBookmark: Bookmark? {
        guard let selectedBookmarkID else {
            return bookmarks.first
        }

        return bookmarks.first(where: { $0.id == selectedBookmarkID })
    }

    var canExecuteSelectedBookmark: Bool {
        guard let selectedBookmark else {
            return false
        }

        return canExecuteBookmark(id: selectedBookmark.id)
    }

    var selectedBookmarkExecutionMessage: String? {
        guard let selectedBookmark else {
            return nil
        }

        return bookmarkExecutionMessage(for: selectedBookmark.id)
    }

    var proxyStatusText: String {
        switch proxyState {
        case .stopped:
            return "Stopped"
        case .starting(let port):
            return "Starting on port \(port)"
        case .running(let port):
            return "Running on port \(port)"
        case .stopping:
            return "Stopping"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    var canStartProxy: Bool {
        guard !proxyStartRequested else { return false }
        switch proxyState {
        case .stopped, .failed:
            return true
        case .starting, .running, .stopping:
            return false
        }
    }

    var isProxyRunningNow: Bool {
        if case .running = proxyState { return true }
        return false
    }

    var canEditProxyPort: Bool {
        switch proxyState {
        case .stopped, .failed:
            return true
        case .starting, .running, .stopping:
            return false
        }
    }

    var canResetPersistedPreferences: Bool {
        canEditProxyPort
    }

    var builtInHTTPSBypassDomains: [String] {
        TLSInterceptionPolicy.builtInBypassDomains
    }

    var hasCustomHTTPSRules: Bool {
        !httpsBypassDomains.isEmpty || !httpsInterceptDomains.isEmpty
    }

    var proxyPortErrorGuidance: String? {
        guard case .failed(let message) = proxyState else {
            return nil
        }

        if message.localizedCaseInsensitiveContains("port") {
            return message
        }

        return nil
    }

    var canStopProxy: Bool {
        guard !proxyStartRequested else { return false }
        switch proxyState {
        case .running, .starting:
            return true
        case .stopped, .stopping:
            return false
        case .failed:
            return false
        }
    }

    var certificateWorkflowState: CertificateWorkflowState {
        switch trustStatus {
        case .installed:
            return .ready
        case .trustRequired:
            return .installedTrustRequired
        case .invalid:
            return .needsCleanup
        case .notInstalled:
            return .notSetUp
        }
    }

    var certificateSectionTitle: String {
        certificateWorkflowState.rawValue
    }

    var certificateStatusText: String {
        switch trustStatus {
        case .notInstalled:
            return "Not installed"
        case .trustRequired(let reason):
            return "Trust required: \(reason)"
        case .installed:
            return "Installed and trusted"
        case .invalid(let reason):
            return "Needs cleanup: \(reason)"
        }
    }

    var certificateStatusGuidance: String {
        if let lastErrorMessage, certificateWorkflowState == .needsCleanup {
            return lastErrorMessage
        }

        switch certificateWorkflowState {
        case .notSetUp:
            if rootCertificate == nil {
                return "Create the JoesProxy root certificate, then install it in your login keychain."
            }
            return "Install the JoesProxy root certificate in your login keychain to continue HTTPS setup."
        case .installedTrustRequired:
            return "JoesProxy will not inspect HTTPS traffic until you trust the JoesProxy Root CA in Keychain Access."
        case .ready:
            return "HTTPS inspection is ready. Normal certificate controls stay tucked away unless you need diagnostics or cleanup."
        case .needsCleanup:
            return "JoesProxy found stale or conflicting certificate state. Use Reset Certificate State to clean it up before continuing."
        }
    }

    var httpsProxyStatusText: String {
        switch proxyState {
        case .stopped:
            return "The proxy is stopped. Start the proxy to capture traffic."
        case .starting:
            return "The proxy is starting. HTTPS traffic will be captured once startup finishes."
        case .stopping:
            return "The proxy is stopping. HTTPS traffic will no longer be captured."
        case .failed(let message):
            return "The proxy failed to start, so HTTPS traffic is not being captured. \(message)"
        case .running:
            switch httpsProxyMode {
            case .passThrough:
                return "CONNECT tunneling is active in pass-through mode. TLS interception wiring is still pending."
            case .intercepting:
                return "HTTPS interception is active."
            }
        }
    }

    var captureExampleCommand: String {
        "curl -x http://127.0.0.1:\(configuration.proxyPort) http://example.com/ -v"
    }

    var httpsCaptureExampleCommand: String {
        "curl --http1.1 -x http://127.0.0.1:\(configuration.proxyPort) https://example.com/ -H 'Connection: close' -o /dev/null -v"
    }

    var certificateSetupEntryPointTitle: String {
        httpsProxyMode == .intercepting ? "HTTPS Setup" : "Certificate Setup"
    }

    var certificateSetupSheetTitle: String {
        switch certificateWorkflowState {
        case .notSetUp:
            return "Set Up HTTPS Inspection"
        case .installedTrustRequired:
            return "Finish HTTPS Trust Setup"
        case .ready:
            return "HTTPS Setup Complete"
        case .needsCleanup:
            return "Recover Certificate Setup"
        }
    }

    var certificateSetupSheetMessage: String {
        switch certificateWorkflowState {
        case .notSetUp:
            if rootCertificate == nil {
                return "JoesProxy needs its own root certificate before it can inspect HTTPS traffic."
            }
            return "The JoesProxy root certificate is ready. Install it in your login keychain to continue."
        case .installedTrustRequired:
            return "The JoesProxy root certificate is installed. Trust it in Keychain Access, then come back and check again."
        case .ready:
            return "JoesProxy is ready to inspect HTTPS traffic on this Mac."
        case .needsCleanup:
            return "The current certificate state is stale or incomplete. Reset Certificate State before trying setup again."
        }
    }

    var certificatePrimaryActionTitle: String? {
        switch certificateWorkflowState {
        case .notSetUp:
            return rootCertificate == nil ? "Create JoesProxy Root CA" : "Install In Login Keychain"
        case .installedTrustRequired:
            return "Check Again"
        case .ready:
            return nil
        case .needsCleanup:
            return "Reset Certificate State"
        }
    }

    var certificatePrimaryActionDetail: String {
        switch certificateWorkflowState {
        case .notSetUp:
            if rootCertificate == nil {
                return "Creates the app-owned JoesProxy Root CA used for HTTPS inspection."
            }
            return "Adds the JoesProxy Root CA to your login keychain."
        case .installedTrustRequired:
            return "Re-checks trust status after you make the Keychain Access change."
        case .ready:
            return "No further setup is required unless you want diagnostics or cleanup."
        case .needsCleanup:
            return "Removes installed JoesProxy root certificates, clears stored CA material, and reports if manual cleanup is still needed."
        }
    }

    var shouldShowTrustInstructions: Bool {
        certificateWorkflowState == .installedTrustRequired || certificateWorkflowState == .ready
    }

    var shouldShowSetupVerificationSection: Bool {
        certificateWorkflowState == .ready || setupVerificationState != nil
    }

    var setupVerificationIntroText: String {
        "Use Verify Capture after routing a client or diagnostic command through the proxy to confirm whether HTTPS traffic is inspected, tunneled, or not observed yet."
    }

    var setupVerificationButtonTitle: String {
        "Verify Capture"
    }

    var setupVerificationStateTint: String {
        switch setupVerificationState {
        case .inspected:
            return "green"
        case .tunneled:
            return "yellow"
        case .noTrafficObserved:
            return "orange"
        case .proxyStopped:
            return "red"
        case nil:
            return "secondary"
        }
    }

    var certificateTrustInstructions: [String] {
        [
            "Open Keychain Access.",
            "Select the login keychain.",
            "Find \(configuration.certificateLabel).",
            "Open the certificate details window.",
            "Expand Trust.",
            "Set When using this certificate to Always Trust.",
            "Return to JoesProxy and choose Check Again."
        ]
    }

    var certificateTrustSuccessText: String {
        "Success looks like the certificate state changing to Ready for HTTPS inspection with no cleanup warning."
    }

    var certificateRefreshHelpText: String {
        "Keep this sheet open after trusting the certificate. JoesProxy checks automatically while the sheet is open. If the state still does not update, confirm the trust change was saved in the login keychain, then choose Check Again."
    }

    func runSetupVerification() {
        switch proxyState {
        case .stopped, .stopping, .failed:
            setupVerificationState = .proxyStopped
            return
        case .starting:
            setupVerificationState = .noTrafficObserved
            return
        case .running:
            break
        }

        if captureWorkspace.allSessions.contains(where: { session in
            session.request.scheme == .https &&
            session.response != nil &&
            session.request.inspectionKind != .tunneledTLS
        }) {
            setupVerificationState = .inspected
            return
        }

        if captureWorkspace.allSessions.contains(where: { session in
            session.request.scheme == .https &&
            session.request.inspectionKind == .tunneledTLS
        }) {
            setupVerificationState = .tunneled
            return
        }

        setupVerificationState = .noTrafficObserved
    }

    var shouldShowMainScreenDiagnostics: Bool {
        rootCertificate != nil || trustStatus != .notInstalled || lastErrorMessage != nil
    }

    var certificateDiagnosticsText: String {
        var lines: [String] = []
        lines.append("User-facing state: \(certificateWorkflowState.rawValue)")
        lines.append("Technical trust status: \(certificateStatusText)")
        lines.append("Built-in HTTPS bypass domains: \(builtInHTTPSBypassDomains.joined(separator: ", "))")

        if !httpsBypassDomains.isEmpty {
            lines.append("Custom HTTPS bypass domains: \(httpsBypassDomains.joined(separator: ", "))")
        }

        if !httpsInterceptDomains.isEmpty {
            lines.append("Custom HTTPS intercept domains: \(httpsInterceptDomains.joined(separator: ", "))")
        }

        if let rootCertificate {
            lines.append("Stored CA summary: \(rootCertificate.subjectSummary)")
            lines.append("Stored private key available: \(rootCertificate.privateKeyData != nil ? "Yes" : "No")")
        } else {
            lines.append("Stored CA summary: Missing")
        }

        if let lastErrorMessage {
            lines.append("Last error: \(lastErrorMessage)")
        }

        return lines.joined(separator: "\n")
    }

    var canResetCertificateState: Bool {
        rootCertificate != nil || trustStatus != .notInstalled
    }

    var hasActiveSessionFilters: Bool {
        !sessionFilterCriteria.isEmpty || !sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredSessionCount: Int {
        captureWorkspace.filteredSessionCount
    }

    var filteredOutSessionCount: Int {
        max(0, sessionCount - filteredSessionCount)
    }

    /// Whether the session table is windowed to reduce row churn during an active capture.
    var isSessionTableWindowingActive: Bool {
        captureWorkspace.hiddenSessionCount > 0
    }

    /// Sessions currently rendered in the capture table, paginated by captureWorkspace.
    var sessionTableDisplayedSessions: [SessionRecord] {
        captureWorkspace.displayedSessions
    }

    /// Summary rows for the capture table — same order/windowing as
    /// `sessionTableDisplayedSessions` without retaining full records per row.
    var sessionTableDisplayedSummaries: [SessionSummary] {
        captureWorkspace.displayedSummaries
    }

    var sessionTableDisplayedRowIdentities: [SessionTableRowPresentation] {
        captureWorkspace.displayedRowIdentities
    }

    /// Sessions captured but not yet shown in the windowed table.
    var sessionTableHiddenSessionCount: Int {
        captureWorkspace.hiddenSessionCount
    }

    /// Expands the live-capture session table window by one increment.
    func showMoreSessionTableSessions() {
        captureWorkspace.showMoreSessions()
    }

    var hasSelectedTimelineRequestPin: Bool {
        guard let selectedSessionID else { return false }
        return captureWorkspace.timelinePins.contains(.request(selectedSessionID))
    }

    func toggleTimelinePinForSelectedSession() {
        guard let selectedSessionID else { return }
        let pin = TimelinePin.request(selectedSessionID)
        if let index = captureWorkspace.timelinePins.firstIndex(of: pin) {
            captureWorkspace.timelinePins.remove(at: index)
        } else {
            captureWorkspace.timelinePins.append(pin)
        }
    }

    func pinTimelineVisibleRange() {
        let events = timelineAnalysisResult.renderedEvents
        guard let start = events.lazy.map(\.startedAt).min(),
              let end = events.lazy.map(\.completedAt).max(),
              end > start else { return }
        captureWorkspace.timelinePins.append(.timeRange(id: UUID(), start: start, end: end))
    }

    func clearTimelineFilters() {
        timelineFilterState = .empty
    }

    func clearTimelinePins() {
        captureWorkspace.timelinePins = []
    }

    private var isCaptureActive: Bool {
        if case .running = proxyState {
            return true
        }

        return false
    }


    var hasSessions: Bool {
        captureWorkspace.hasSessions
    }

    var canRunSessionFind: Bool {
        hasSessions && !sessionFindQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Find matches currently rendered in the panel list (capped for large result sets).
    var sessionFindDisplayedResults: [SessionFindResult] {
        SessionFindPresentation.displayedResults(
            from: sessionFindResults,
            visibleLimit: sessionFindVisibleResultLimit
        )
    }

    /// Matches found but not yet shown in the Find panel list.
    var sessionFindHiddenResultCount: Int {
        SessionFindPresentation.hiddenResultCount(
            totalCount: sessionFindResults.count,
            visibleLimit: sessionFindVisibleResultLimit
        )
    }

    /// Reveals the next page of Find matches in the panel list.
    func showMoreSessionFindResults() {
        let nextLimit = SessionFindPresentation.nextVisibleLimit(
            currentLimit: sessionFindVisibleResultLimit,
            totalCount: sessionFindResults.count
        )
        guard nextLimit != sessionFindVisibleResultLimit else {
            return
        }

        sessionFindVisibleResultLimit = nextLimit
        logFind("Expanded Find visible results to \(nextLimit) of \(sessionFindResults.count)")
    }

    var hasVisibleSessions: Bool {
        captureWorkspace.hasVisibleSessions
    }

    var hasBookmarks: Bool {
        !bookmarks.isEmpty
    }

    var guidedSetupChecklistItems: [GuidedSetupChecklistItem] {
        guidedSetupChecklistItems(
            currentNetworkSnapshot: currentSetupNetworkSnapshot()
        )
    }

    var guidedSetupNextActionItem: GuidedSetupChecklistItem? {
        guidedSetupChecklistItems.first { item in
            item.primaryAction != nil && item.state != .complete
        }
    }

    func captureSetupNetworkSnapshot() {
        setupNetworkSnapshot = currentSetupNetworkSnapshot()
    }

    /// Prior vs current LAN/port copy for the Inspector companion (BA-3). Detection stays here; the companion owns presentation.
    var setupNetworkDriftSummary: String? {
        guard let setupNetworkSnapshot else {
            return nil
        }
        return setupDriftSummary(from: setupNetworkSnapshot, to: currentSetupNetworkSnapshot())
    }

    var hasSetupNetworkDrift: Bool {
        setupNetworkDriftSummary != nil
    }

    func recordSetupNetworkSnapshot(_ snapshot: SetupNetworkSnapshot) {
        setupNetworkSnapshot = snapshot
    }

    func currentLocalNetworkInfo() -> LocalNetworkInfo {
        localNetworkInfoProvider.current()
    }

    func currentSetupNetworkSnapshot() -> SetupNetworkSnapshot {
        SetupNetworkSnapshot.current(
            proxyPort: configuration.proxyPort,
            localNetworkInfoProvider: localNetworkInfoProvider
        )
    }

    func guidedSetupChecklistItems(
        currentNetworkSnapshot: SetupNetworkSnapshot
    ) -> [GuidedSetupChecklistItem] {
        [
            GuidedSetupChecklistItem(
                id: "certificate",
                title: "Root CA and certificate trust",
                detail: guidedSetupCertificateSummary,
                state: guidedSetupCertificateState,
                primaryActionTitle: guidedSetupCertificateActionTitle,
                primaryAction: guidedSetupCertificateAction,
                secondaryActionTitle: certificateWorkflowState == .needsCleanup ? "Reset Certificate State" : nil,
                secondaryAction: certificateWorkflowState == .needsCleanup ? .resetCertificateState : nil,
                helpTopic: .certificateSetup,
                accessibilityIdentifier: "setupChecklistCertificateRow"
            ),
            GuidedSetupChecklistItem(
                id: "proxy",
                title: "Proxy listener",
                detail: guidedSetupProxySummary,
                state: guidedSetupProxyState,
                primaryActionTitle: guidedSetupProxyActionTitle,
                primaryAction: guidedSetupProxyAction,
                secondaryActionTitle: nil,
                secondaryAction: nil,
                helpTopic: .trafficStates,
                accessibilityIdentifier: "setupChecklistProxyRow"
            ),
            GuidedSetupChecklistItem(
                id: "traffic",
                title: "Traffic captured",
                detail: guidedSetupTrafficObservedSummary(currentNetworkSnapshot: currentNetworkSnapshot),
                state: guidedSetupTrafficObservedState(currentNetworkSnapshot: currentNetworkSnapshot),
                primaryActionTitle: guidedSetupTrafficObservedActionTitle(currentNetworkSnapshot: currentNetworkSnapshot),
                primaryAction: guidedSetupTrafficObservedAction(currentNetworkSnapshot: currentNetworkSnapshot),
                secondaryActionTitle: "macOS Setup Guide",
                secondaryAction: .openMacOSGuide,
                helpTopic: .trafficStates,
                accessibilityIdentifier: "setupChecklistRoutingRow"
            ),
            GuidedSetupChecklistItem(
                id: "verification",
                title: "HTTPS inspection verified",
                detail: guidedSetupVerificationSummary,
                state: guidedSetupVerificationState,
                primaryActionTitle: guidedSetupVerificationActionTitle,
                primaryAction: guidedSetupVerificationAction,
                secondaryActionTitle: "Troubleshoot HTTPS traffic",
                secondaryAction: .openTrafficHelp,
                helpTopic: .trafficStates,
                accessibilityIdentifier: "setupChecklistVerificationRow"
            ),
            GuidedSetupChecklistItem(
                id: "device",
                title: "Device traffic detected",
                detail: guidedSetupDeviceSummary(currentNetworkSnapshot: currentNetworkSnapshot),
                state: guidedSetupDeviceState(currentNetworkSnapshot: currentNetworkSnapshot),
                primaryActionTitle: "iOS Setup Guide",
                primaryAction: .openIOSGuide,
                secondaryActionTitle: "Apple TV Setup Guide",
                secondaryAction: .openTVOSGuide,
                helpTopic: .certificateSetup,
                accessibilityIdentifier: "setupChecklistDeviceRow"
            )
        ]
    }

    var bookmarkCount: Int {
        bookmarks.count
    }

    private var guidedSetupCertificateSummary: String {
        switch certificateWorkflowState {
        case .ready:
            return "The JoesProxy Root CA is installed and trusted on this Mac."
        case .installedTrustRequired:
            return "The Root CA exists, but trust is still required before HTTPS inspection can work."
        case .notSetUp:
            return "HTTPS setup has not been completed on this Mac yet."
        case .needsCleanup:
            return "The stored certificate state needs cleanup before HTTPS inspection can continue."
        }
    }

    private var guidedSetupCertificateState: GuidedSetupChecklistItem.State {
        switch certificateWorkflowState {
        case .ready:
            return .complete
        case .installedTrustRequired, .notSetUp, .needsCleanup:
            return .needsAction
        }
    }

    private var guidedSetupCertificateActionTitle: String? {
        certificateWorkflowState == .ready ? nil : certificateSetupEntryPointTitle
    }

    private var guidedSetupCertificateAction: GuidedSetupChecklistItem.Action? {
        certificateWorkflowState == .ready ? nil : .openCertificateSetup
    }

    private func setupDriftSummary(
        from previous: SetupNetworkSnapshot,
        to current: SetupNetworkSnapshot
    ) -> String? {
        var changes: [String] = []
        if previous.proxyPort != current.proxyPort {
            changes.append("port changed from \(previous.proxyPort) to \(current.proxyPort)")
        }
        if previous.lanIP != current.lanIP {
            changes.append("LAN IP changed from \(previous.lanIP ?? "unknown") to \(current.lanIP ?? "unknown")")
        }
        if previous.bonjourName != current.bonjourName {
            changes.append("Bonjour name changed from \(previous.bonjourName ?? "unknown") to \(current.bonjourName ?? "unknown")")
        }

        guard !changes.isEmpty else {
            return nil
        }

        return changes.joined(separator: "; ")
    }

    private func hasSetupDrift(currentNetworkSnapshot: SetupNetworkSnapshot) -> Bool {
        guard let setupNetworkSnapshot else {
            return false
        }

        return setupDriftSummary(from: setupNetworkSnapshot, to: currentNetworkSnapshot) != nil
    }

    private var guidedSetupProxySummary: String {
        switch proxyState {
        case .running(let port):
            return "The proxy listener is running on port \(port)."
        case .starting(let port):
            return "The proxy listener is starting on port \(port)."
        case .stopping:
            return "The proxy listener is stopping."
        case .stopped:
            return "The proxy listener is stopped."
        case .failed(let message):
            return "The proxy listener failed to start. \(message)"
        }
    }

    private var guidedSetupProxyState: GuidedSetupChecklistItem.State {
        switch proxyState {
        case .running:
            return .complete
        case .starting:
            return .waiting
        case .stopping:
            return .waiting
        case .stopped:
            return .needsAction
        case .failed:
            return .warning
        }
    }

    private var guidedSetupProxyActionTitle: String? {
        switch proxyState {
        case .stopped, .failed:
            return "Start Proxy"
        case .starting, .running, .stopping:
            return nil
        }
    }

    private var guidedSetupProxyAction: GuidedSetupChecklistItem.Action? {
        switch proxyState {
        case .stopped, .failed:
            return .startProxy
        case .starting, .running, .stopping:
            return nil
        }
    }

    private func guidedSetupTrafficObservedSummary(
        currentNetworkSnapshot: SetupNetworkSnapshot
    ) -> String {
        if let setupNetworkSnapshot,
           let drift = setupDriftSummary(from: setupNetworkSnapshot, to: currentNetworkSnapshot) {
            return "Proxy settings may be stale because \(drift). Update the client with the current host and port."
        }

        if sessionCount > 0 {
            let noun = sessionCount == 1 ? "session" : "sessions"
            return "JoesProxy has already captured \(sessionCount) \(noun) in this workspace."
        }

        if case .running(let port) = proxyState {
            return "No captured traffic has been observed yet. Route a browser, app, or diagnostic command through port \(port)."
        }

        return "No captured traffic has been observed yet. Start the proxy before routing a client through JoesProxy."
    }

    private func guidedSetupTrafficObservedState(
        currentNetworkSnapshot: SetupNetworkSnapshot
    ) -> GuidedSetupChecklistItem.State {
        if hasSetupDrift(currentNetworkSnapshot: currentNetworkSnapshot) {
            return .stale
        }

        if sessionCount > 0 {
            return .complete
        }

        switch proxyState {
        case .running:
            return .neutral
        case .starting, .stopping:
            return .waiting
        case .stopped, .failed:
            return .needsAction
        }
    }

    private func guidedSetupTrafficObservedActionTitle(
        currentNetworkSnapshot: SetupNetworkSnapshot
    ) -> String? {
        if hasSetupDrift(currentNetworkSnapshot: currentNetworkSnapshot) {
            return "Refresh Current Values"
        }

        switch proxyState {
        case .running:
            return "Verify Capture"
        case .stopped, .failed:
            return "Start Proxy"
        case .starting, .stopping:
            return nil
        }
    }

    private func guidedSetupTrafficObservedAction(
        currentNetworkSnapshot: SetupNetworkSnapshot
    ) -> GuidedSetupChecklistItem.Action? {
        if hasSetupDrift(currentNetworkSnapshot: currentNetworkSnapshot) {
            return .verifyCapture
        }

        switch proxyState {
        case .running:
            return .verifyCapture
        case .stopped, .failed:
            return .startProxy
        case .starting, .stopping:
            return nil
        }
    }

    private var guidedSetupVerificationSummary: String {
        guard let setupVerificationState else {
            if certificateWorkflowState == .ready {
                return "Run verification after routing traffic through JoesProxy to confirm HTTPS is inspected."
            }
            return "Finish certificate trust first, then verify that routed HTTPS traffic is inspected."
        }

        return setupVerificationState.message
    }

    private var guidedSetupVerificationState: GuidedSetupChecklistItem.State {
        switch setupVerificationState {
        case .inspected:
            return .complete
        case .tunneled:
            return .warning
        case .noTrafficObserved:
            return .neutral
        case .proxyStopped:
            return .needsAction
        case nil:
            return certificateWorkflowState == .ready ? .neutral : .waiting
        }
    }

    private var guidedSetupVerificationActionTitle: String? {
        switch setupVerificationState {
        case .proxyStopped:
            return "Start Proxy"
        case .inspected:
            return nil
        case .tunneled, .noTrafficObserved, nil:
            return certificateWorkflowState == .ready ? "Verify Capture" : certificateSetupEntryPointTitle
        }
    }

    private var guidedSetupVerificationAction: GuidedSetupChecklistItem.Action? {
        switch setupVerificationState {
        case .proxyStopped:
            return .startProxy
        case .inspected:
            return nil
        case .tunneled, .noTrafficObserved, nil:
            return certificateWorkflowState == .ready ? .verifyCapture : .openCertificateSetup
        }
    }

    private func guidedSetupDeviceSummary(
        currentNetworkSnapshot: SetupNetworkSnapshot
    ) -> String {
        if let setupNetworkSnapshot,
           let drift = setupDriftSummary(from: setupNetworkSnapshot, to: currentNetworkSnapshot) {
            return "Network values changed since setup was opened: \(drift). Update device proxy settings if capture stopped."
        }

        if sessionCount > 0 {
            return "Traffic has been observed. Device-specific setup remains optional unless you need iOS or Apple TV capture."
        }

        return "Open a device guide when you need to route iOS, iPadOS, or Apple TV traffic through this Mac."
    }

    private func guidedSetupDeviceState(
        currentNetworkSnapshot: SetupNetworkSnapshot
    ) -> GuidedSetupChecklistItem.State {
        if hasSetupDrift(currentNetworkSnapshot: currentNetworkSnapshot) {
            return .stale
        }

        return sessionCount > 0 ? .complete : .neutral
    }

    var activeResponseOverrideCount: Int {
        responseOverrides.filter(\.isEnabled).count + hlsSubstitutionExperiments.filter(\.isActive).count
    }

    var trafficModificationSnapshot: TrafficModificationSnapshot {
        let enabledRules = responseOverrides.filter(\.isEnabled)
        func count(_ kind: MCPEffectKind) -> Int {
            enabledRules.filter { MCPEffectInventoryBuilder.effectKind(for: $0.sourceKind) == kind }.count
        }
        let bookmarkRewriteCount = bookmarks.reduce(0) { total, bookmark in
            total + bookmark.responseRewrites.filter(\.isRuleEnabled).count
        }
        return TrafficModificationSnapshot(
            activeMapLocalCount: count(.mapLocal),
            activeMapRemoteCount: count(.mapRemote),
            activeBlockCount: count(.block),
            activeBookmarkRewriteCount: bookmarkRewriteCount,
            activeLiveRewriteCount: count(.liveResponseRewrite),
            isThrottlingEnabled: networkThrottleConfiguration.isEnabled,
            activeHLSSubstitutionCount: hlsSubstitutionExperiments.filter(\.isActive).count,
            activeOpenAPIMockPackCount: openAPIMockPacks.filter(\.isServing).count,
            activeSyntheticInjectionCount: syntheticInjectionPlans.filter(\.isEnabled).count,
            isSystemProxyTunnelingActive: false
        )
    }

    /// Restores unmodified response behavior without stopping capture, routing, HTTPS inspection,
    /// or MCP. Each feature uses its normal shutdown path so persistence and attribution remain
    /// consistent with disabling the same effect from its management surface.
    func disableAllTrafficModifications() async -> TrafficModificationResetResult {
        guard !isResettingTrafficModifications else {
            let active = trafficModificationSnapshot.activeModificationCount
            return TrafficModificationResetResult(disabledCount: 0, remainingCount: active)
        }
        isResettingTrafficModifications = true
        defer { isResettingTrafficModifications = false }

        let initialCount = trafficModificationSnapshot.activeModificationCount

        for rule in responseOverrides where rule.isEnabled {
            await setResponseOverrideEnabled(false, id: rule.id)
        }
        for bookmark in bookmarks {
            for rewrite in bookmark.responseRewrites where rewrite.isRuleEnabled {
                setBookmarkResponseRewriteEnabled(false, rewriteID: rewrite.id, for: bookmark.id)
            }
        }
        setNetworkThrottlingEnabled(false)
        for experiment in hlsSubstitutionExperiments where experiment.isActive {
            await stopHLSTestStream(id: experiment.id)
        }
        for pack in openAPIMockPacks where pack.isServing {
            await stopOpenAPIMockPack(id: pack.id)
        }
        clearAllSyntheticInjectionPlans()

        let remainingCount = trafficModificationSnapshot.activeModificationCount
        return TrafficModificationResetResult(
            disabledCount: max(0, initialCount - remainingCount),
            remainingCount: remainingCount
        )
    }

    var hasResponseOverrides: Bool {
        !responseOverrides.isEmpty || !hlsSubstitutionExperiments.isEmpty
    }

    var hasSelectedSessions: Bool {
        !selectedSessionIDs.isEmpty
    }

    var selectedSessionIDs: Set<SessionRecord.ID> {
        guard let selectedSessionID else {
            return []
        }
        return [selectedSessionID]
    }

    func makeVisualizationExportPresentationContext() -> VisualizationExportPresentationContext? {
        guard hasSessions else {
            return nil
        }

        if hasSelectedSessions {
            let ids = Array(selectedSessionIDs)
            let sessions = captureWorkspace.allSessions.filter { ids.contains($0.id) }
            let scope: VisualizationExportScope = ids.count == 1
                ? .selectedSession(ids[0])
                : .selectedSessions(ids)
            return VisualizationExportPresentationContext(
                sourceScope: scope,
                sourceSummary: scope.summary,
                sessionCount: ids.count,
                filteredSessionCount: filteredSessionCount,
                totalSessionCount: sessionCount,
                hasActiveFilters: hasActiveSessionFilters,
                provenance: visualizationExportProvenance(),
                sourceSessions: sessions
            )
        }

        let sessions = filteredSessions
        let scope = VisualizationExportScope.filteredResults(currentVisualizationExportFilterDescriptor())
        return VisualizationExportPresentationContext(
            sourceScope: scope,
            sourceSummary: hasActiveSessionFilters ? "Current filtered results" : "All captured sessions",
            sessionCount: sessions.count,
            filteredSessionCount: filteredSessionCount,
            totalSessionCount: sessionCount,
            hasActiveFilters: hasActiveSessionFilters,
            provenance: visualizationExportProvenance(),
            sourceSessions: sessions
        )
    }

    private func currentVisualizationExportFilterDescriptor() -> VisualizationExportFilterDescriptor {
        var statusCodes: [Int] = []
        if case .exact(let statusCode) = sessionFilterCriteria.statusMatch {
            statusCodes = [statusCode]
        }

        let trimmedSearchText = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = sessionFilterCriteria.hostContains.trimmingCharacters(in: .whitespacesAndNewlines)
        return VisualizationExportFilterDescriptor(
            searchText: trimmedSearchText.isEmpty ? nil : trimmedSearchText,
            hosts: trimmedHost.isEmpty ? [] : [trimmedHost],
            statusCodes: statusCodes
        )
    }

    private func visualizationExportProvenance() -> VisualizationExportProvenance {
        var provenance = VisualizationExportProvenance.proxyOnlyComplete
        provenance.isPartialCapture = sessionTableHiddenSessionCount > 0
        var hasStrippedBodies = false
        for session in filteredSessions {
            let requestBodyWasStripped = session.request.bodySize != nil && session.request.bodyData == nil
            let responseBodyWasStripped = session.response?.bodySize != nil && session.response?.bodyData == nil
            if requestBodyWasStripped || responseBodyWasStripped {
                hasStrippedBodies = true
                break
            }
        }
        provenance.hasStrippedBodies = hasStrippedBodies
        return provenance
    }

    func clearSessionFilters() {
        sessionFilterCriteria = SessionFilterCriteria()
        sessionSearchText = ""
    }

    func setSessionHostFilter(_ host: String) {
        sessionFilterCriteria = SessionFilterCriteria()
        sessionFilterCriteria.hostContains = host
        sessionSearchText = ""
    }

    enum ClearAllSessionsResult: Equatable { case cleared, busy }

    @discardableResult
    func clearAllSessions() -> ClearAllSessionsResult {
        guard !isClearSnapshotPending else { return .busy }
        let snapshotWriter: (@MainActor ([SessionRecord]) async -> Void)?
        if let override = clearSnapshotWriterOverride {
            snapshotWriter = override
        } else if let persistence = rollingCapturePersistence, persistence.acceptsExplicitSnapshots {
            snapshotWriter = { await persistence.flushSnapshot(sessions: $0) }
        } else {
            snapshotWriter = nil
        }
        if let snapshotWriter, !captureWorkspace.allSessions.isEmpty {
            // Admit before creating the task: repeated clears must not queue full capture graphs.
            let sessions = captureWorkspace.allSessions
            isClearSnapshotPending = true
            clearSnapshotTask = Task { [weak self] in
                await snapshotWriter(sessions)
                self?.clearSnapshotTask = nil
                self?.isClearSnapshotPending = false
            }
        }
        sessionFindTask?.cancel()
        sessionFindTask = nil
        let retiredFindResults = sessionFindResults
        sessionFindResults = []
        resetSessionFindVisibleLimit()
        sessionFindState = .idle
        activeFindResultLocation = nil
        activeFindResultSessionID = nil
        activeFindNavigationID = nil
        selectedSessionID = nil
        DeferredRelease.schedule(retiredFindResults)
        sessionStore.clear()
        if configuration.isSessionAutoScrollEnabled {
            sessionFollowState = .followingLive
        }
        return .cleared
    }

    func waitForClearSnapshot() async { await clearSnapshotTask?.value }

    /// Loads the latest rolling capture snapshot into the live session store.
    func restoreRollingCapture() async throws {
        guard !isRestoringRollingCapture else { throw RollingCaptureRestoreError.alreadyRestoring }
        guard sessionStore.sessions.isEmpty else { throw RollingCaptureRestoreError.captureChanged }
        // The seeded UI fixture must never read the user's real recovery files.
        guard !isUITestRollingCaptureRestoreOffer else { throw RollingCaptureRestoreError.noSnapshot }
        guard let rollingCapturePersistence else {
            throw RollingCaptureRestoreError.noSnapshot
        }
        isRestoringRollingCapture = true
        defer { isRestoringRollingCapture = false }
        let offerID = rollingCaptureRestoreOffer?.id
        let sessions = try await rollingCapturePersistence.restoreLatestSnapshotInBackground()
        try Task.checkCancellation()
        guard offerID == rollingCaptureRestoreOffer?.id, sessionStore.sessions.isEmpty else {
            throw RollingCaptureRestoreError.captureChanged
        }
        sessionStore.load(sessions: sessions, epochChangeReason: "capture_restored")
        rollingCaptureRestoreOffer = nil
    }

    /// Exports the on-disk rolling capture snapshot directly to a file without loading sessions into live memory.
    func exportRollingCaptureSnapshot(to destinationURL: URL, format: RollingCaptureExportFormat) async throws {
        guard let rollingCapturePersistence else {
            throw RollingCaptureRestoreError.noSnapshot
        }
        try await rollingCapturePersistence.exportSnapshotInBackground(to: destinationURL, format: format)
        dismissRollingCaptureRestoreOffer()
    }

    /// Prompts the user with a save panel to export/save the rolling snapshot off-path.
    func promptSaveRollingCaptureSnapshot(format: RollingCaptureExportFormat) async throws {
        guard let offer = rollingCaptureRestoreOffer else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let timestamp = formatter.string(from: offer.savedAt)
        let ext = format == .har ? "har" : "jproxy"
        let defaultName = "rolling_capture_\(timestamp).\(ext)"

        guard let destinationURL = recordingFileCoordinator.promptForRollingCaptureSave(
            defaultName: defaultName,
            format: format
        ) else {
            return
        }

        guard !isUITestRollingCaptureRestoreOffer else { throw RollingCaptureRestoreError.noSnapshot }
        try await exportRollingCaptureSnapshot(to: destinationURL, format: format)
    }

    var canReviewRollingCapture: Bool {
        rollingCaptureRestoreOffer != nil || rollingCapturePersistence?.availableRestoreOffer() != nil
    }

    var canRestoreRollingCapture: Bool { sessionStore.sessions.isEmpty }

    func reviewRollingCapture() {
        guard rollingCaptureRestoreOffer == nil else { return }
        rollingCaptureRestoreOffer = rollingCapturePersistence?.availableRestoreOffer()
    }

    /// Installs an in-memory rolling-capture restore offer for UI tests (BA-2).
    ///
    /// Does not read or write Application Support snapshots. Call only from the UI-test
    /// presentation path. MainActor-only, matching the rest of launch presentation.
    func installUITestRollingCaptureRestoreOffer() {
        isUITestRollingCaptureRestoreOffer = true
        rollingCaptureRestoreOffer = RollingCaptureRestoreOffer(
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionCount: 12,
            fileURL: URL(fileURLWithPath: "/nonexistent/ui-test-rolling-restore.jproxy"),
            fileSizeBytes: 1024
        )
    }

    /// Evaluates whether launch should offer restoring the latest rolling capture.
    func evaluateRollingCaptureRestoreOffer() {
        guard let rollingCapturePersistence else {
            rollingCaptureRestoreOffer = nil
            return
        }
        rollingCaptureRestoreOffer = rollingCapturePersistence.shouldOfferRestoreOnLaunch(
            sessionCount: sessionStore.sessions.count
        )
    }

    /// Dismisses the launch restore offer without loading sessions.
    func dismissRollingCaptureRestoreOffer() {
        if !isUITestRollingCaptureRestoreOffer {
            rollingCapturePersistence?.markRestoreDismissed()
        }
        isUITestRollingCaptureRestoreOffer = false
        rollingCaptureRestoreOffer = nil
    }

    func clearSelectedSessions() {
        sessionStore.remove(ids: selectedSessionIDs)
    }

    func canCreateResponseOverride(from session: SessionRecord) -> Bool {
        session.response != nil && session.request.inspectionKind != .tunneledTLS
    }

    func mapLocalLimitationMessage(for session: SessionRecord) -> String? {
        if session.request.inspectionKind == .tunneledTLS {
            return "Map Local needs an inspected or plain response. Tunneled HTTPS sessions do not contain a decrypted response body to reuse."
        }

        guard session.response != nil else {
            return "Map Local needs a completed captured response before it can create an override."
        }

        return nil
    }

    func canReplaceWithHLSTestStream(_ session: SessionRecord) -> Bool {
        let path = String(session.request.path.split(separator: "?", maxSplits: 1).first ?? "")
        if path.lowercased().hasSuffix(".m3u8") { return true }
        let contentType = session.response?.headers.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.lowercased() ?? ""
        return contentType.contains("mpegurl")
    }

    func startHLSTestStream(
        from session: SessionRecord,
        profileID: String,
        scope: HLSSubstitutionScope,
        conflictStrategy: HLSSubstitutionConflictStrategy = .cancel
    ) async {
        guard let hlsSubstitutionCoordinator else {
            lastErrorMessage = "HLS test-stream substitution is unavailable."
            return
        }
        do {
            _ = try await hlsSubstitutionCoordinator.start(
                owner: .localUser,
                profileID: profileID,
                origin: HLSSubstitutionOrigin(
                    scheme: session.request.scheme,
                    host: session.request.host,
                    port: session.request.port
                ),
                scope: scope,
                conflictStrategy: conflictStrategy,
                playbackConfiguration: hlsFixtureProfiles.first { $0.id == profileID }?.defaultPlaybackConfiguration ?? .conformant
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func startHLSTestStream(
        profileID: String,
        origin: HLSSubstitutionOrigin,
        scope: HLSSubstitutionScope,
        conflictStrategy: HLSSubstitutionConflictStrategy = .cancel
    ) async {
        guard let hlsSubstitutionCoordinator else {
            lastErrorMessage = "HLS test-stream substitution is unavailable."
            return
        }
        do {
            _ = try await hlsSubstitutionCoordinator.start(
                owner: .localUser,
                profileID: profileID,
                origin: origin,
                scope: scope,
                conflictStrategy: conflictStrategy,
                playbackConfiguration: hlsFixtureProfiles.first { $0.id == profileID }?.defaultPlaybackConfiguration ?? .conformant
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func stopHLSTestStream(id: UUID) async {
        do {
            _ = try await hlsSubstitutionCoordinator?.stop(
                id: id,
                requestingOwnerID: HLSSubstitutionCoordinator.localUserOwnerID
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func restartHLSTestStream(id: UUID) async {
        do {
            _ = try await hlsSubstitutionCoordinator?.restart(
                id: id,
                requestingOwnerID: HLSSubstitutionCoordinator.localUserOwnerID,
                conflictStrategy: .replaceExisting
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshHLSTestStreamStatus() async {
        await hlsSubstitutionCoordinator?.synchronizeMetricsAndExpiry()
    }

    func compileOpenAPIMockPack(
        bookmark: OpenAPIDocumentBookmark,
        origin: OpenAPIMockOrigin
    ) throws -> OpenAPIMockCompiledPack {
        let document = try OpenAPIMockDocumentReader.data(from: bookmark)
        return try OpenAPIMockCompiler.compile(
            OpenAPIMockCompileRequest(
                document: document,
                packID: OpenAPIMockPackID(rawValue: UUID()),
                originOverride: origin
            )
        )
    }

    func previewOpenAPIMockActivation(
        compiled: OpenAPIMockCompiledPack,
        conflictStrategy: OpenAPIMockConflictStrategy
    ) async -> OpenAPIMockActivationDecision {
        await openAPIMockPackCoordinator?.previewActivation(
            compiled: compiled,
            owner: .localUser,
            conflictStrategy: conflictStrategy
        ) ?? .refusedBusy
    }

    func submitOpenAPIMockPack(
        compiled: OpenAPIMockCompiledPack,
        bookmark: OpenAPIDocumentBookmark,
        origin _: OpenAPIMockOrigin,
        conflictStrategy: OpenAPIMockConflictStrategy,
        addWithoutStarting: Bool
    ) async {
        guard let openAPIMockPackCoordinator else {
            lastErrorMessage = "OpenAPI mock packs are unavailable."
            return
        }
        do {
            if addWithoutStarting {
                _ = try await openAPIMockPackCoordinator.prepare(
                    compiled: compiled,
                    owner: .localUser,
                    documentBookmark: bookmark
                )
            } else {
                _ = try await openAPIMockPackCoordinator.activate(
                    compiled: compiled,
                    owner: .localUser,
                    documentBookmark: bookmark,
                    conflictStrategy: conflictStrategy
                )
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func startOpenAPIMockPack(id: OpenAPIMockPackID) async {
        do {
            _ = try await openAPIMockPackCoordinator?.restart(
                id: id,
                requestingOwnerID: OpenAPIMockPackCoordinator.localUserOwnerID
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func stopOpenAPIMockPack(id: OpenAPIMockPackID) async {
        do {
            _ = try await openAPIMockPackCoordinator?.stop(
                id: id,
                requestingOwnerID: OpenAPIMockPackCoordinator.localUserOwnerID
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func restartOpenAPIMockPack(id: OpenAPIMockPackID) async {
        do {
            _ = try await openAPIMockPackCoordinator?.restart(
                id: id,
                requestingOwnerID: OpenAPIMockPackCoordinator.localUserOwnerID,
                conflictStrategy: .replaceConflicts
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func discardOpenAPIMockPack(id: OpenAPIMockPackID) async {
        do {
            try await openAPIMockPackCoordinator?.discard(
                id: id,
                requestingOwnerID: OpenAPIMockPackCoordinator.localUserOwnerID
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshOpenAPIMockPackStatus() async {
        await openAPIMockPackCoordinator?.synchronizeMetricsAndExpiry()
    }

    // MARK: - Synthetic Collection Injection (AG-1)

    /// `SyntheticCollectionInjectionEngine.shared` is a plain lock-protected singleton with no
    /// publisher of its own (see its doc comment — it must stay callable from a synchronous NIO
    /// hot path, so it can't be `@MainActor`/`ObservableObject`). This is the reactive read side:
    /// refresh explicitly after any mutation, or on the same poll cadence the UI already uses for
    /// HLS/OpenAPI status, rather than expecting the engine to push changes.
    @Published private(set) var syntheticInjectionPlans: [SyntheticCollectionInjectionPlan] = []
    @Published private(set) var syntheticInjectionDiagnostics: [UUID: SyntheticInjectionDiagnostics] = [:]

    func refreshSyntheticInjectionPlans() {
        syntheticInjectionPlans = SyntheticCollectionInjectionEngine.shared.allPlans()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        syntheticInjectionDiagnostics = Dictionary(uniqueKeysWithValues: syntheticInjectionPlans.compactMap { plan in
            SyntheticCollectionInjectionEngine.shared.diagnostics(planID: plan.id).map { (plan.id, $0) }
        })
    }

    func setSyntheticInjectionPlanEnabled(_ isEnabled: Bool, id: UUID) {
        guard var plan = SyntheticCollectionInjectionEngine.shared.allPlans().first(where: { $0.id == id }) else {
            return
        }
        plan.isEnabled = isEnabled
        SyntheticCollectionInjectionEngine.shared.registerPlan(plan)
        refreshSyntheticInjectionPlans()
    }

    func removeSyntheticInjectionPlan(id: UUID) {
        SyntheticCollectionInjectionEngine.shared.removePlan(id: id)
        refreshSyntheticInjectionPlans()
    }

    func clearAllSyntheticInjectionPlans() {
        SyntheticCollectionInjectionEngine.shared.clearAllPlans()
        refreshSyntheticInjectionPlans()
    }

    // MARK: - Named Effect Bundles (.jproxy-effects)

    var effectBundleRecords: [EffectBundleRecord] {
        effectBundleRepository.records
    }

    func importEffectBundle(from url: URL) async {
        do {
            try effectBundleRepository.importPackage(at: url, owner: .localUser)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func activateEffectBundle(reviewed record: EffectBundleRecord, ttl: TimeInterval? = nil) async {
        do {
            try await effectBundleCoordinator.activateFromLocalUI(reviewed: record, ttl: ttl)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func stopEffectBundle(id: UUID) async {
        do {
            try await effectBundleCoordinator.stopFromLocalUI(id: id)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func discardEffectBundle(id: UUID) async {
        do {
            try effectBundleRepository.discard(id: id, requestingOwnerID: EffectBundleOwner.localUser.ownerID)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func hlsTestStreamConflictSummary(
        origin: HLSSubstitutionOrigin,
        scope: HLSSubstitutionScope
    ) async -> HLSSubstitutionConflictSummary {
        await hlsSubstitutionCoordinator?.conflictSummary(origin: origin, scope: scope)
            ?? HLSSubstitutionConflictSummary(experimentCount: 0, responseRuleCount: 0)
    }

    func createCapturedResponseOverride(
        from session: SessionRecord,
        label: String? = nil,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        conflictStrategy: ResponseOverrideConflictStrategy = .keepBoth,
        forceNoCache: Bool = false
    ) async {
        do {
            let rule = try await responseOverrideStore.addCapturedResponseOverride(
                from: session,
                matchMode: matchMode,
                matchPath: matchPath,
                conflictStrategy: conflictStrategy,
                forceNoCache: forceNoCache
            )
            if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await responseOverrideStore.setLabel(label, for: rule.id)
            }
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func createInlineResponseOverride(
        from session: SessionRecord,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        conflictStrategy: ResponseOverrideConflictStrategy = .keepBoth,
        statusCode: Int,
        contentType: String?,
        bodyText: String,
        forceNoCache: Bool = false
    ) async {
        do {
            _ = try await responseOverrideStore.addInlineTextOverride(
                from: session,
                label: label,
                matchMode: matchMode,
                matchPath: matchPath,
                conflictStrategy: conflictStrategy,
                statusCode: statusCode,
                contentType: contentType,
                bodyText: bodyText,
                forceNoCache: forceNoCache
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func createFileBackedResponseOverride(
        from session: SessionRecord,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        conflictStrategy: ResponseOverrideConflictStrategy = .keepBoth,
        statusCode: Int,
        contentType: String?,
        fileURL: URL,
        forceNoCache: Bool = false
    ) async {
        do {
            _ = try await responseOverrideStore.addFileBackedOverride(
                from: session,
                label: label,
                matchMode: matchMode,
                matchPath: matchPath,
                conflictStrategy: conflictStrategy,
                statusCode: statusCode,
                contentType: contentType,
                fileURL: fileURL,
                forceNoCache: forceNoCache
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func createDirectoryBackedResponseOverride(
        from session: SessionRecord,
        label: String?,
        matchPath: String? = nil,
        conflictStrategy: ResponseOverrideConflictStrategy = .keepBoth,
        directoryURL: URL,
        forceNoCache: Bool = false
    ) async {
        do {
            _ = try await responseOverrideStore.addDirectoryBackedOverride(
                from: session,
                label: label,
                matchPath: matchPath,
                conflictStrategy: conflictStrategy,
                directoryURL: directoryURL,
                forceNoCache: forceNoCache
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func setResponseOverrideEnabled(_ isEnabled: Bool, id: ResponseOverrideRule.ID) async {
        if isEnabled, let rule = await responseOverrideStore.rule(id: id), rule.sourceKind == .mapRemote {
            let host = rule.mapRemoteHost ?? rule.host
            let scheme = rule.mapRemoteScheme ?? rule.requestScheme
            let port = rule.mapRemotePort
            do {
                try MCPMutationValidator.validateMapRemoteDestination(
                    host: host,
                    port: port,
                    scheme: scheme,
                    allowLoopbackDestination: rule.allowLoopbackDestination,
                    policy: configuration.loopbackDestinationPolicy,
                    reservedRegistry: .shared
                )
            } catch let error as MCPMutationValidationError {
                lastErrorMessage = MCPMutationValidator.structuredError(for: error).message
                await refreshResponseOverrides()
                return
            } catch {
                lastErrorMessage = error.localizedDescription
                await refreshResponseOverrides()
                return
            }
        }
        do {
            try await responseOverrideStore.setEnabled(isEnabled, for: id)
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func deleteResponseOverride(id: ResponseOverrideRule.ID) async {
        await responseOverrideStore.removeRule(id: id)
        do {
            try await persistResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        await refreshResponseOverrides()
    }

    func updateCapturedResponseOverride(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        statusCode: Int,
        contentType: String?,
        forceNoCache: Bool? = nil
    ) async {
        do {
            try await responseOverrideStore.updateCapturedResponseOverride(
                id: id,
                label: label,
                matchMode: matchMode,
                matchPath: matchPath,
                statusCode: statusCode,
                contentType: contentType,
                forceNoCache: forceNoCache
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func updateInlineTextResponseOverride(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        statusCode: Int,
        contentType: String?,
        bodyText: String,
        forceNoCache: Bool? = nil
    ) async {
        do {
            try await responseOverrideStore.updateInlineTextOverride(
                id: id,
                label: label,
                matchMode: matchMode,
                matchPath: matchPath,
                statusCode: statusCode,
                contentType: contentType,
                bodyText: bodyText,
                forceNoCache: forceNoCache
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func updateFileBackedResponseOverride(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        statusCode: Int,
        contentType: String?,
        fileURL: URL,
        forceNoCache: Bool? = nil
    ) async {
        do {
            try await responseOverrideStore.updateFileBackedOverride(
                id: id,
                label: label,
                matchMode: matchMode,
                matchPath: matchPath,
                statusCode: statusCode,
                contentType: contentType,
                fileURL: fileURL,
                forceNoCache: forceNoCache
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func updateDirectoryBackedResponseOverride(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchPath: String? = nil,
        directoryURL: URL,
        forceNoCache: Bool? = nil
    ) async {
        do {
            try await responseOverrideStore.updateDirectoryBackedOverride(
                id: id,
                label: label,
                matchPath: matchPath,
                directoryURL: directoryURL,
                forceNoCache: forceNoCache
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func updateBlockResponseOverride(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        statusCode: Int
    ) async {
        do {
            try await responseOverrideStore.updateBlockRule(id: id, label: label, matchMode: matchMode, matchPath: matchPath, statusCode: statusCode)
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func updateMapRemoteResponseOverride(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        remoteHost: String,
        remotePort: Int?,
        remoteScheme: SessionScheme,
        remotePath: String? = nil,
        allowLoopbackDestination: Bool? = nil,
        preserveHostHeader: Bool? = nil
    ) async {
        let existingRule = await responseOverrideStore.rule(id: id)
        let effectiveAllowLoopback = allowLoopbackDestination ?? existingRule?.allowLoopbackDestination ?? false
        do {
            try MCPMutationValidator.validateMapRemoteDestination(
                host: remoteHost,
                port: remotePort,
                scheme: remoteScheme,
                allowLoopbackDestination: effectiveAllowLoopback,
                policy: configuration.loopbackDestinationPolicy,
                reservedRegistry: .shared
            )
            if let remotePath {
                try MCPMutationValidator.validateMapRemoteRequestTarget(remotePath)
            }
        } catch let error as MCPMutationValidationError {
            lastErrorMessage = MCPMutationValidator.structuredError(for: error).message
            return
        } catch {
            lastErrorMessage = error.localizedDescription
            return
        }
        do {
            try await responseOverrideStore.updateMapRemoteRule(
                id: id,
                label: label,
                matchMode: matchMode,
                matchPath: matchPath,
                remoteHost: remoteHost,
                remotePort: remotePort,
                remoteScheme: remoteScheme,
                remotePath: remotePath,
                allowLoopbackDestination: allowLoopbackDestination,
                preserveHostHeader: preserveHostHeader
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func updateLiveResponseRewriteRule(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        rewrites: [BookmarkResponseFieldRewrite]
    ) async {
        do {
            try await responseOverrideStore.updateLiveResponseRewriteRule(
                id: id,
                label: label,
                matchMode: matchMode,
                matchPath: matchPath,
                rewrites: rewrites
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func clearResponseOverrides() async {
        await hlsSubstitutionCoordinator?.clearAll()
        await responseOverrideStore.clearAll()
        do {
            try await persistResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        await refreshResponseOverrides()
    }

    /// Creates a block rule that drops matching requests with a synthetic error response.
    func createBlockRule(
        from session: SessionRecord,
        statusCode: Int,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil
    ) async {
        do {
            try await responseOverrideStore.addBlockRule(
                from: session.request,
                statusCode: statusCode,
                label: label,
                matchMode: matchMode,
                matchPath: matchPath
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Creates a map-remote rule that forwards matching requests to a different upstream host.
    func createMapRemoteRule(
        from session: SessionRecord,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        remoteHost: String,
        remotePort: Int?,
        remoteScheme: SessionScheme,
        remotePath: String? = nil,
        allowLoopbackDestination: Bool = false,
        preserveHostHeader: Bool = false
    ) async {
        do {
            try MCPMutationValidator.validateMapRemoteDestination(
                host: remoteHost,
                port: remotePort,
                scheme: remoteScheme,
                allowLoopbackDestination: allowLoopbackDestination,
                policy: configuration.loopbackDestinationPolicy,
                reservedRegistry: .shared
            )
            if let remotePath {
                try MCPMutationValidator.validateMapRemoteRequestTarget(remotePath)
            }
        } catch let error as MCPMutationValidationError {
            lastErrorMessage = MCPMutationValidator.structuredError(for: error).message
            return
        } catch {
            lastErrorMessage = error.localizedDescription
            return
        }
        do {
            try await responseOverrideStore.addMapRemoteRule(
                from: session.request,
                label: label,
                matchMode: matchMode,
                matchPath: matchPath,
                remoteHost: remoteHost,
                remotePort: remotePort,
                remoteScheme: remoteScheme,
                remotePath: remotePath,
                allowLoopbackDestination: allowLoopbackDestination,
                preserveHostHeader: preserveHostHeader
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Creates a live-response rewrite rule that forwards matching requests upstream and patches JSON in the response.
    func createLiveResponseRewriteRule(
        from session: SessionRecord,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        jsonPath: String,
        operation: JSONMutationOperation,
        overrideValue: BookmarkJSONValue
    ) async {
        let rewrite = BookmarkResponseFieldRewrite(
            jsonPath: jsonPath,
            overrideValue: overrideValue,
            operation: operation
        )
        do {
            try BookmarkJSONRewriteEngine.validateLocatorSyntax(jsonPath)
            if operation == .insert {
                try BookmarkJSONRewriteEngine.validateInsertLocatorSyntax(jsonPath)
            }
            try await responseOverrideStore.addLiveResponseRewriteRule(
                from: session.request,
                label: label,
                matchMode: matchMode,
                matchPath: matchPath,
                rewrites: [rewrite]
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Creates a bookmark rewrite rule that replaces matching live requests with the selected bookmark request.
    func createBookmarkRewriteRule(
        from bookmark: Bookmark,
        label: String? = nil,
        matchMode: ResponseOverrideMatchMode = .exactPath
    ) async {
        do {
            try await responseOverrideStore.addBookmarkRewriteRule(
                from: bookmark,
                label: label,
                matchMode: matchMode
            )
            try await persistResponseOverrides()
            await refreshResponseOverrides()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func addBookmark(from session: SessionRecord) {
        let bookmark = Bookmark(
            name: defaultBookmarkName(for: session),
            request: session.request,
            savedResponse: BookmarkResponseEditing.savedResponse(from: session)
        )
        bookmarks.insert(bookmark, at: 0)
        persistBookmarks()
        selectedBookmarkID = bookmark.id
    }

    func isBookmarkResponseRewriteEnabled(id: Bookmark.ID) -> Bool {
        enabledBookmarkResponseRewriteIDs.contains(id)
    }

    func canEnableBookmarkResponseRewrite(id: Bookmark.ID) -> Bool {
        guard case .running = proxyState else {
            return false
        }

        guard let bookmark = bookmarks.first(where: { $0.id == id }) else {
            return false
        }

        return bookmark.savedResponse != nil && bookmark.enabledResponseRewriteCount > 0
    }

    /// Enables bookmark response intercept for the current proxy session and immediately syncs
    /// the runtime store so the next matching request is intercepted without a race.
    func enableBookmarkResponseRewrite(id: Bookmark.ID) async {
        guard canEnableBookmarkResponseRewrite(id: id) else {
            return
        }

        enabledBookmarkResponseRewriteIDs.insert(id)
        bookmarkResponseRewriteActivityByID[id] = BookmarkResponseRewriteActivity(enabledAt: Date())
        await syncBookmarkResponseInterceptStore()
    }

    /// Disables bookmark response intercept for the current proxy session.
    func disableBookmarkResponseRewrite(id: Bookmark.ID) async {
        enabledBookmarkResponseRewriteIDs.remove(id)
        bookmarkResponseRewriteActivityByID[id] = nil
        await syncBookmarkResponseInterceptStore()
    }

    /// Returns session-scoped intercept activity for a bookmark when rewrites are enabled.
    func bookmarkResponseRewriteActivity(for bookmarkID: Bookmark.ID) -> BookmarkResponseRewriteActivity? {
        bookmarkResponseRewriteActivityByID[bookmarkID]
    }

    /// Recent request paths on the same host/method that do not match this bookmark (endpoint mismatch hints).
    func bookmarkResponseRewriteTrafficHints(for bookmarkID: Bookmark.ID, limit: Int = 3) -> [String] {
        guard let bookmark = bookmarks.first(where: { $0.id == bookmarkID }),
              let activity = bookmarkResponseRewriteActivityByID[bookmarkID] else {
            return []
        }

        var seenPaths: Set<String> = []
        var hints: [String] = []
        let recentSessions = captureWorkspace.allSessions
            .filter { session in
                session.timing.startedAt >= activity.enabledAt &&
                session.request.method.caseInsensitiveCompare(bookmark.request.method) == .orderedSame &&
                session.request.host.caseInsensitiveCompare(bookmark.request.host) == .orderedSame
            }
            .sorted { $0.timing.startedAt > $1.timing.startedAt }
            .prefix(40)

        for session in recentSessions {
            let path = session.request.path
            if BookmarkRequestMatcher.matches(
                ruleRequest: bookmark.request,
                matchMode: bookmark.responseMatchMode,
                request: session.request
            ) {
                continue
            }
            if seenPaths.insert(path).inserted {
                hints.append(path)
                if hints.count >= limit {
                    break
                }
            }
        }

        return hints
    }

    func toggleBookmarkResponseRewrite(id: Bookmark.ID) {
        Task {
            if isBookmarkResponseRewriteEnabled(id: id) {
                await disableBookmarkResponseRewrite(id: id)
            } else {
                await enableBookmarkResponseRewrite(id: id)
            }
        }
    }

    func updateBookmarkResponseMatchMode(_ matchMode: ResponseOverrideMatchMode, for bookmarkID: Bookmark.ID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            return
        }

        bookmarks[index].responseMatchMode = matchMode
        persistBookmarks()
    }

    func updateBookmarkResponseRewrites(_ rewrites: [BookmarkResponseFieldRewrite], for bookmarkID: Bookmark.ID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            return
        }

        bookmarks[index].responseRewrites = rewrites
        persistBookmarks()
    }

    func addBookmarkResponseRewrite(
        jsonPath: String,
        overrideValue: BookmarkJSONValue,
        for bookmarkID: Bookmark.ID,
        operation: JSONMutationOperation = .set,
        valueInputMode: BookmarkResponseRewriteValueInputMode = .auto
    ) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            return
        }

        let bodyData = bookmarks[index].savedResponse?.bodyData
        let originalValue = operation == .set
            ? BookmarkJSONRewriteEngine.value(at: jsonPath, in: bodyData)
            : nil

        let rewrite = BookmarkResponseFieldRewrite(
            jsonPath: jsonPath,
            originalValueSnapshot: originalValue?.displayString,
            overrideValue: overrideValue,
            operation: operation
        )

        bookmarks[index].responseRewrites.removeAll { $0.jsonPath == jsonPath && $0.operation == operation }
        bookmarks[index].responseRewrites.append(rewrite)
        persistBookmarks()
    }

    func removeBookmarkResponseRewrite(id rewriteID: UUID, for bookmarkID: Bookmark.ID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            return
        }

        bookmarks[index].responseRewrites.removeAll { $0.id == rewriteID }
        persistBookmarks()
    }

    func setBookmarkResponseRewriteEnabled(
        _ isEnabled: Bool,
        rewriteID: UUID,
        for bookmarkID: Bookmark.ID
    ) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }),
              let rewriteIndex = bookmarks[index].responseRewrites.firstIndex(where: { $0.id == rewriteID }) else {
            return
        }

        bookmarks[index].responseRewrites[rewriteIndex].isRuleEnabled = isEnabled
        persistBookmarks()
    }

    /// Updates the override value for an existing bookmark response rewrite rule.
    func updateBookmarkResponseRewriteOverride(
        rewriteID: UUID,
        overrideValueText: String,
        for bookmarkID: Bookmark.ID,
        valueInputMode: BookmarkResponseRewriteValueInputMode = .auto
    ) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }),
              let rewriteIndex = bookmarks[index].responseRewrites.firstIndex(where: { $0.id == rewriteID }) else {
            return
        }

        bookmarks[index].responseRewrites[rewriteIndex].overrideValue = BookmarkJSONValue.fromUserInput(
            overrideValueText,
            mode: valueInputMode
        )
        persistBookmarks()
    }

    /// Updates the JSON path for an existing bookmark response rewrite rule.
    func updateBookmarkResponseRewritePath(
        rewriteID: UUID,
        jsonPath: String,
        for bookmarkID: Bookmark.ID
    ) {
        let trimmedPath = jsonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty,
              let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }),
              let rewriteIndex = bookmarks[index].responseRewrites.firstIndex(where: { $0.id == rewriteID }) else {
            return
        }

        let rewrite = bookmarks[index].responseRewrites[rewriteIndex]
        let originalValue = rewrite.operation == .set
            ? BookmarkJSONRewriteEngine.value(at: trimmedPath, in: bookmarks[index].savedResponse?.bodyData)
            : nil

        let updatedRewrite = BookmarkResponseFieldRewrite(
            id: rewrite.id,
            jsonPath: trimmedPath,
            originalValueSnapshot: originalValue?.displayString,
            overrideValue: rewrite.overrideValue,
            operation: rewrite.operation,
            isRuleEnabled: rewrite.isRuleEnabled
        )

        bookmarks[index].responseRewrites.removeAll { $0.id != rewrite.id && $0.jsonPath == trimmedPath }
        bookmarks[index].responseRewrites[rewriteIndex] = updatedRewrite
        persistBookmarks()
    }

    func setBookmarkResponseRewriteOperation(
        _ operation: JSONMutationOperation,
        rewriteID: UUID,
        for bookmarkID: Bookmark.ID
    ) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }),
              let rewriteIndex = bookmarks[index].responseRewrites.firstIndex(where: { $0.id == rewriteID }) else {
            return
        }

        bookmarks[index].responseRewrites[rewriteIndex].operation = operation
        if operation == .set {
            let jsonPath = bookmarks[index].responseRewrites[rewriteIndex].jsonPath
            let originalValue = BookmarkJSONRewriteEngine.value(
                at: jsonPath,
                in: bookmarks[index].savedResponse?.bodyData
            )
            bookmarks[index].responseRewrites[rewriteIndex].originalValueSnapshot = originalValue?.displayString
        } else {
            bookmarks[index].responseRewrites[rewriteIndex].originalValueSnapshot = nil
        }
        persistBookmarks()
    }

    /// Returns how many enabled rewrite rules resolve against the bookmark saved response body.
    func bookmarkResponseRewriteApplicability(for bookmarkID: Bookmark.ID) -> (applicable: Int, enabled: Int)? {
        guard let bookmark = bookmarks.first(where: { $0.id == bookmarkID }),
              let bodyData = bookmark.savedResponse?.bodyData else {
            return nil
        }

        let enabledRules = bookmark.responseRewrites.filter(\.isRuleEnabled)
        guard !enabledRules.isEmpty else {
            return (0, 0)
        }

        guard let result = try? BookmarkJSONRewriteEngine.apply(bodyData: bodyData, rewrites: enabledRules) else {
            return (0, enabledRules.count)
        }

        return (result.appliedRuleIDs.count, enabledRules.count)
    }

    func clearBookmarkSavedResponse(for bookmarkID: Bookmark.ID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            return
        }

        bookmarks[index].savedResponse = nil
        bookmarks[index].responseRewrites = []
        enabledBookmarkResponseRewriteIDs.remove(bookmarkID)
        bookmarkResponseRewriteActivityByID[bookmarkID] = nil
        persistBookmarks()
    }

    /// Describes the most recent captured session that can refresh this bookmark's saved response.
    func bookmarkSavedResponseRefreshCandidate(for bookmarkID: Bookmark.ID) -> BookmarkSavedResponseRefreshCandidate? {
        guard let bookmark = bookmarks.first(where: { $0.id == bookmarkID }),
              let latestSession = sessionsForBookmarkUpdate(bookmarkID: bookmarkID, bookmark: bookmark).first else {
            return nil
        }

        return BookmarkSavedResponseRefreshCandidate(
            method: latestSession.request.method,
            host: latestSession.request.host,
            path: latestSession.request.path,
            startedAt: latestSession.timing.startedAt
        )
    }

    @discardableResult
    func refreshBookmarkSavedResponseFromLatestMatchingSession(id bookmarkID: Bookmark.ID) -> BookmarkSavedResponseRefreshResult {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            return .noMatchingSession
        }

        guard let latestSession = sessionsForBookmarkUpdate(bookmarkID: bookmarkID, bookmark: bookmarks[index]).first else {
            return .noMatchingSession
        }

        guard let savedResponse = BookmarkResponseEditing.savedResponse(from: latestSession) else {
            return .noSavableBody
        }

        bookmarks[index].savedResponse = savedResponse
        let enabledRules = bookmarks[index].responseRewrites
        bookmarks[index].responseRewrites = enabledRules.map { rewrite in
            var updated = rewrite
            updated.originalValueSnapshot = BookmarkJSONRewriteEngine.value(
                at: rewrite.jsonPath,
                in: savedResponse.bodyData
            )?.displayString
            return updated
        }
        persistBookmarks()
        return .refreshed
    }

    func updateBookmarkName(_ name: String, for bookmarkID: Bookmark.ID) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            return
        }

        let fallbackName = defaultBookmarkName(for: bookmarks[index].request)
        bookmarks[index].name = trimmedName.isEmpty ? fallbackName : trimmedName
        persistBookmarks()
    }

    func updateBookmarkRequest(_ request: CapturedRequest, for bookmarkID: Bookmark.ID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            return
        }

        let originalRequest = bookmarks[index].request
        let originalDefaultName = defaultBookmarkName(for: originalRequest)
        let normalizedRequest = CapturedRequest(
            method: request.method,
            scheme: request.scheme,
            inspectionKind: request.inspectionKind,
            inspectionReason: request.inspectionReason,
            host: request.host,
            port: request.port,
            path: request.path,
            headers: request.headers,
            bodyData: request.bodyData?.isEmpty == true ? nil : request.bodyData,
            bodySize: request.bodyData?.isEmpty == true ? nil : request.bodyData?.count
        )
        bookmarks[index].request = normalizedRequest

        if bookmarks[index].name == originalDefaultName {
            bookmarks[index].name = defaultBookmarkName(for: normalizedRequest)
        }

        persistBookmarks()
    }

    func deleteSelectedBookmark() {
        guard let selectedBookmarkID else {
            return
        }

        deleteBookmark(id: selectedBookmarkID)
    }

    func deleteBookmark(id: Bookmark.ID) {
        bookmarks.removeAll { $0.id == id }
        if self.selectedBookmarkID == id {
            self.selectedBookmarkID = bookmarks.first?.id
        }
        if bookmarkUpdateContext?.bookmarkID == id {
            bookmarkUpdateContext = nil
        }
        persistBookmarks()
    }

    func beginBookmarkUpdate(id: Bookmark.ID) {
        guard let bookmark = bookmarks.first(where: { $0.id == id }) else {
            return
        }

        let candidates = sessionsForBookmarkUpdate(bookmarkID: id)
        bookmarkUpdateContext = BookmarkUpdateContext(
            bookmarkID: bookmark.id,
            candidateSessionIDs: candidates.map(\.id)
        )
        selectedBookmarkID = bookmark.id
        if let newestCandidate = candidates.first {
            pauseFollowLiveForUserInteraction()
            selectedSessionID = newestCandidate.id
        }
    }

    func cancelBookmarkUpdate() {
        bookmarkUpdateContext = nil
    }

    func bookmarkUpdateCandidates(for bookmarkID: Bookmark.ID) -> [SessionRecord] {
        guard let bookmark = bookmarks.first(where: { $0.id == bookmarkID }) else {
            return []
        }

        return sessionsForBookmarkUpdate(bookmarkID: bookmark.id, bookmark: bookmark)
    }

    func bookmarkUpdatePreview(
        bookmarkID: Bookmark.ID,
        sourceSessionID: SessionRecord.ID,
        preset: BookmarkUpdatePreset,
        customOptions: BookmarkCustomMergeOptions? = nil
    ) -> CapturedRequest? {
        guard
            let bookmark = bookmarks.first(where: { $0.id == bookmarkID }),
            let sourceSession = captureWorkspace.visibleSession(for: sourceSessionID) ?? captureWorkspace.sessionRecord(for: sourceSessionID)
        else {
            return nil
        }

        return BookmarkRequestEditing.merge(
            bookmarkRequest: bookmark.request,
            sourceRequest: sourceSession.request,
            preset: preset,
            customOptions: customOptions
        )
    }

    func canUseSessionForBookmarkUpdate(_ sessionID: SessionRecord.ID) -> Bool {
        guard let sourceSession = captureWorkspace.visibleSession(for: sessionID) ?? captureWorkspace.sessionRecord(for: sessionID) else {
            return false
        }

        return BookmarkRequestEditing.canUseAsBookmarkUpdateSource(sourceSession.request)
    }

    func bookmarkUpdateLimitationMessage(for sessionID: SessionRecord.ID) -> String? {
        guard let sourceSession = captureWorkspace.visibleSession(for: sessionID) ?? captureWorkspace.sessionRecord(for: sessionID) else {
            return nil
        }

        return BookmarkRequestEditing.bookmarkUpdateLimitationMessage(for: sourceSession.request)
    }

    func applyBookmarkUpdate(
        bookmarkID: Bookmark.ID,
        sourceSessionID: SessionRecord.ID,
        preset: BookmarkUpdatePreset,
        customOptions: BookmarkCustomMergeOptions? = nil
    ) {
        guard let updatedRequest = bookmarkUpdatePreview(
            bookmarkID: bookmarkID,
            sourceSessionID: sourceSessionID,
            preset: preset,
            customOptions: customOptions
        ) else {
            return
        }

        if let limitationMessage = bookmarkUpdateLimitationMessage(for: sourceSessionID) {
            lastErrorMessage = limitationMessage
            return
        }

        updateBookmarkRequest(updatedRequest, for: bookmarkID)
        bookmarkUpdateContext = nil
    }

    @discardableResult
    func refreshBookmarkAuthFromLatestMatchingSession(id: Bookmark.ID) -> Bool {
        guard let bookmark = bookmarks.first(where: { $0.id == id }) else {
            return false
        }

        let candidates = sessionsForBookmarkUpdate(bookmarkID: id, bookmark: bookmark)
        guard let sourceSession = candidates.first(where: { BookmarkRequestEditing.canUseAsBookmarkUpdateSource($0.request) }) else {
            if let newestCandidate = candidates.first,
               let limitationMessage = BookmarkRequestEditing.bookmarkUpdateLimitationMessage(for: newestCandidate.request) {
                lastErrorMessage = limitationMessage
            } else {
                lastErrorMessage = "No recent matching captured session was available to refresh auth for this bookmark."
            }
            return false
        }

        applyBookmarkUpdate(
            bookmarkID: id,
            sourceSessionID: sourceSession.id,
            preset: .authAndCookies
        )
        pauseFollowLiveForUserInteraction()
        selectedSessionID = sourceSession.id
        return true
    }

    @discardableResult
    func executeBookmark(id: Bookmark.ID) async -> Bool {
        guard let bookmark = bookmarks.first(where: { $0.id == id }) else {
            return false
        }

        guard case .running(let port) = proxyState else {
            bookmarkExecutionState = .failed(bookmarkID: id, message: "Start the proxy to execute bookmarks.")
            return false
        }

        if let validationMessage = BookmarkRequestEditing.validationMessage(for: bookmark.request) {
            bookmarkExecutionState = .failed(bookmarkID: id, message: validationMessage)
            return false
        }

        let preparedRequest = BookmarkRequestEditing.preparedRequest(forExecution: bookmark.request)
        let bookmarkToExecute = Bookmark(
            id: bookmark.id,
            name: bookmark.name,
            request: preparedRequest,
            createdAt: bookmark.createdAt,
            lastExecutedAt: bookmark.lastExecutedAt
        )

        bookmarkExecutionState = .executing(bookmarkID: id)

        do {
            let result = try await bookmarkExecutor.execute(bookmark: bookmarkToExecute, proxyPort: port)
            updateLastExecutedDate(for: id, at: Date())

            if let matchedSession = await waitForExecutedSessionMatch(
                request: preparedRequest,
                startedAt: result.startedAt
            ) {
                pauseFollowLiveForUserInteraction()
                selectedSessionID = matchedSession.id
                bookmarkExecutionState = .idle
                return true
            }

            bookmarkExecutionState = .failed(
                bookmarkID: id,
                message: "The request completed, but JoesProxy could not match the captured session yet."
            )
            return false
        } catch {
            bookmarkExecutionState = .failed(
                bookmarkID: id,
                message: NetworkFailureClassifier.presentation(for: error).userFacingMessage
            )
            return false
        }
    }

    func makeExportEnvelope(using sessions: [SessionRecord]) -> SessionExportEnvelope {
        SessionExportEnvelope(
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            proxyPort: configuration.proxyPort,
            sessionCount: sessions.count,
            sessions: sessions
        )
    }

    func makeCurrentReproPackage(
        title: String = "JoesProxy Reproduction",
        notes: String = "Sanitized capture evidence and safe replay instructions."
    ) throws -> ReproPackage {
        try reproPackageEngine.makePackage(
            title: title,
            notes: notes,
            sessions: captureWorkspace.allSessions,
            hypothesisGraphs: HypothesisDAGEngine.shared.allGraphs(),
            appVersion: Bundle.main.marketingVersionOrDev
        )
    }

    func makeReproPackage(fromHAR url: URL) async throws -> ReproPackage {
        let imported = try await reproHARImportService.open(from: url)
        let skippedNote = imported.skippedEntryCount > 0
            ? " \(imported.skippedEntryCount) malformed entries were skipped."
            : ""
        return try reproPackageEngine.makePackage(
            title: url.deletingPathExtension().lastPathComponent,
            notes: "Imported from HAR as sanitized capture evidence. HAR import does not prove that replay will reproduce the original client state." + skippedNote,
            source: .harImport,
            sessions: imported.sessions,
            appVersion: Bundle.main.marketingVersionOrDev
        )
    }

    func openReproPackage(from url: URL) async throws -> ReproPackage {
        let engine = reproPackageEngine
        return try await Task.detached(priority: .userInitiated) {
            try engine.read(from: url)
        }.value
    }

    func saveReproPackage(_ package: ReproPackage, to url: URL) async throws {
        let engine = reproPackageEngine
        try await runExportOffMain(scope: "Saving reproduction package", destinationURL: url) {
            try engine.write(package, to: url)
        }
    }

    func canReplayReproSession(_ session: ReproSession) -> Bool {
        reproPackageEngine.capturedRequest(for: session) != nil
    }

    func replayReproSession(_ session: ReproSession) async throws -> ReproReplayResult {
        guard case .running(let port) = proxyState else {
            throw ReproPackageError.proxyNotRunning
        }
        let engine = ReproReplayEngine(
            packageEngine: reproPackageEngine,
            bookmarkExecutor: bookmarkExecutor
        )
        return try await engine.replay(session: session, proxyPort: port)
    }

    func exportAllSessions(to destinationURL: URL, as format: ExportFormat = .json) throws {
        exportState = .exporting(scopeDescription: "Exporting all sessions")

        do {
            let service = format == .har ? harExportService : exportService
            try service.export(makeExportEnvelope(using: captureWorkspace.allSessions), to: destinationURL)
            exportState = .succeeded(fileName: destinationURL.lastPathComponent)
        } catch {
            exportState = .failed(message: Self.userFacingErrorMessage(from: error, surface: .fileExport))
            throw error
        }
    }

    func exportSelectedSessions(to destinationURL: URL, as format: ExportFormat = .json) throws {
        let selectedSessions = captureWorkspace.allSessions.filter { selectedSessionIDs.contains($0.id) }
        exportState = .exporting(scopeDescription: "Exporting selected sessions")

        do {
            let service = format == .har ? harExportService : exportService
            try service.export(makeExportEnvelope(using: selectedSessions), to: destinationURL)
            exportState = .succeeded(fileName: destinationURL.lastPathComponent)
        } catch {
            exportState = .failed(message: Self.userFacingErrorMessage(from: error, surface: .fileExport))
            throw error
        }
    }

    func dismissExportState() {
        exportState = .idle
    }

    // MARK: - Background export (interactive saves)
    //
    // The synchronous export/save methods above remain for the quit-preservation path,
    // which must block until the save finishes so applicationShouldTerminate can return
    // a decision. Interactive saves use these async variants: the envelope is snapshotted
    // on the main actor (a CoW reference, not a copy), then encoding and the atomic write
    // run detached so multi-second encodes of large captures never hang the UI.

    func exportAllSessionsInBackground(to destinationURL: URL, as format: ExportFormat = .json) async throws {
        let service = format == .har ? harExportService : exportService
        let envelope = makeExportEnvelope(using: captureWorkspace.allSessions)
        try await runExportOffMain(scope: "Exporting all sessions", destinationURL: destinationURL) {
            try service.export(envelope, to: destinationURL)
        }
    }

    func exportSelectedSessionsInBackground(to destinationURL: URL, as format: ExportFormat = .json) async throws {
        let selected = captureWorkspace.allSessions.filter { selectedSessionIDs.contains($0.id) }
        let service = format == .har ? harExportService : exportService
        let envelope = makeExportEnvelope(using: selected)
        try await runExportOffMain(scope: "Exporting selected sessions", destinationURL: destinationURL) {
            try service.export(envelope, to: destinationURL)
        }
    }

    func saveRecordingInBackground(
        to destinationURL: URL,
        fidelity: RecordingSaveFidelity = .fullRecording
    ) async throws {
        let recordingService = exportService as? JSONSessionExportService ?? JSONSessionExportService()
        let envelope = makeExportEnvelope(using: captureWorkspace.allSessions)
        try await runExportOffMain(scope: "Saving recording", destinationURL: destinationURL) {
            try recordingService.exportAsRecording(envelope, to: destinationURL, fidelity: fidelity)
        }
    }

    func saveSelectedRecordingInBackground(
        to destinationURL: URL,
        fidelity: RecordingSaveFidelity = .fullRecording
    ) async throws {
        let selected = captureWorkspace.allSessions.filter { selectedSessionIDs.contains($0.id) }
        let recordingService = exportService as? JSONSessionExportService ?? JSONSessionExportService()
        let envelope = makeExportEnvelope(using: selected)
        try await runExportOffMain(scope: "Saving selected recording", destinationURL: destinationURL) {
            try recordingService.exportAsRecording(envelope, to: destinationURL, fidelity: fidelity)
        }
    }

    /// Sets exporting/succeeded/failed state around a detached export, then rethrows so
    /// call sites with their own alert presentation can react as well.
    private func runExportOffMain(
        scope: String,
        destinationURL: URL,
        operation: @escaping () throws -> Void
    ) async throws {
        exportState = .exporting(scopeDescription: scope)
        do {
            // .utility, not .userInitiated: large exports (100+ MB HAR/recording, full
            // session bodies) are CPU-heavy encode+write work that can run for minutes on
            // a session with hundreds of sessions. .userInitiated schedules close to the
            // main thread's priority and was observed starving the UI of CPU time for
            // several minutes during a live capture (Instruments potential-hangs showed
            // >90% main-thread stall in some 60s windows) even though the work was already
            // off the main thread — moving work off-thread prevents a hard block but not
            // priority-driven starvation. Export isn't latency-critical for the user (they
            // are waiting on a file, not blocking further interaction), so .utility yields
            // to capture/UI work while still completing promptly.
            try await Task.detached(priority: .utility) {
                try operation()
            }.value
            exportState = .succeeded(fileName: destinationURL.lastPathComponent)
        } catch {
            exportState = .failed(message: Self.userFacingErrorMessage(from: error, surface: .fileExport))
            throw error
        }
    }

    // MARK: - Recording save

    /// Saves all current sessions as a `.jproxy` recording using the selected save fidelity.
    func saveRecording(
        to destinationURL: URL,
        fidelity: RecordingSaveFidelity = .fullRecording
    ) throws {
        exportState = .exporting(scopeDescription: "Saving recording")
        do {
            let recordingService = exportService as? JSONSessionExportService ?? JSONSessionExportService()
            try recordingService.exportAsRecording(
                makeExportEnvelope(using: captureWorkspace.allSessions),
                to: destinationURL,
                fidelity: fidelity
            )
            exportState = .succeeded(fileName: destinationURL.lastPathComponent)
        } catch {
            exportState = .failed(message: Self.userFacingErrorMessage(from: error, surface: .fileExport))
            throw error
        }
    }

    /// Saves the currently selected sessions as a `.jproxy` recording using the selected save fidelity.
    func saveSelectedRecording(
        to destinationURL: URL,
        fidelity: RecordingSaveFidelity = .fullRecording
    ) throws {
        let selected = captureWorkspace.allSessions.filter { selectedSessionIDs.contains($0.id) }
        exportState = .exporting(scopeDescription: "Saving selected recording")
        do {
            let recordingService = exportService as? JSONSessionExportService ?? JSONSessionExportService()
            try recordingService.exportAsRecording(
                makeExportEnvelope(using: selected),
                to: destinationURL,
                fidelity: fidelity
            )
            exportState = .succeeded(fileName: destinationURL.lastPathComponent)
        } catch {
            exportState = .failed(message: Self.userFacingErrorMessage(from: error, surface: .fileExport))
            throw error
        }
    }

    // MARK: - Recording open

    /// Opens the recording at `url` using the given `mode`.
    ///
    /// Concurrency: dispatched off the main thread via `RecordingLoadCoordinator`. Recording state
    /// properties are updated on the main actor after the coordinator completes each phase. A
    /// schema-too-new result surfaces via `pendingSchemaWarning` rather than a hard failure.
    func openRecording(from url: URL, mode: RecordingLoadCoordinator.LoadMode) async {
        await recordingLoadCoordinator.load(from: url, mode: mode)
        syncRecordingState()
    }

    /// Confirms the pending schema-version warning and re-attempts the load with best-effort
    /// decoding. The UI should call this when the user taps "Load Anyway".
    func confirmSchemaWarning() async {
        await recordingLoadCoordinator.confirmSchemaWarning()
        syncRecordingState()
    }

    /// Cancels the pending schema-version warning without loading the file.
    func cancelSchemaWarning() {
        recordingLoadCoordinator.cancelSchemaWarning()
        syncRecordingState()
    }

    /// Dismisses the current recording load warning or notice, resetting state to `.idle`.
    func dismissRecordingLoadState() {
        recordingLoadCoordinator.resetState()
        recordingLoadState = .idle
        recordingSchemaNotice = nil
        pendingSchemaWarning = nil
    }

    private func syncRecordingState() {
        recordingLoadState = recordingLoadCoordinator.loadState
        recordingSchemaNotice = recordingLoadCoordinator.schemaNotice
        pendingSchemaWarning = recordingLoadCoordinator.pendingSchemaWarning
    }

    var currentProfileHostResolution: ProfileHostResolution {
        profileHostResolver.resolve(
            strategy: profileHostStrategy,
            manualHost: manualProfileHost,
            networkInfo: localNetworkInfoProvider.current()
        )
    }

    var currentCertificateFingerprint: String? {
        rootCertificate.map { ProfileSnapshotFactory.certificateFingerprint(from: $0.certificateData) }
    }

    var latestProfileSnapshot: GeneratedProfileSnapshot? {
        profileSnapshots.first
    }

    func refreshProfileMaintenanceStatus() {
        let currentNetworkInfo = localNetworkInfoProvider.current()
        profileSnapshotDiagnosis = ProfileSnapshotDiagnosis.evaluate(
            snapshot: latestProfileSnapshot,
            currentNetworkInfo: currentNetworkInfo,
            currentProxyPort: configuration.proxyPort,
            currentCertificateFingerprint: currentCertificateFingerprint
        )
    }

    func copyProfileMaintenanceValue(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func exportIOSTrustProfile(to destinationURL: URL) throws {
        try iosDeviceTrustProfileExporter.exportTrustProfile(to: destinationURL)
        recordProfileSnapshot(kind: .iosTrustProfile, profileServerURL: nil)
    }

    func exportTVOSManagedProfile(to destinationURL: URL, host: String? = nil) throws {
        let resolution = currentProfileHostResolution
        let hostOverride = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = hostOverride?.isEmpty == false ? hostOverride ?? resolution.host : resolution.host
        let snapshotResolution = resolvedHost == resolution.host ? resolution : ProfileHostResolution(
            strategy: .manualHost,
            requestedStrategy: profileHostStrategy,
            host: resolvedHost,
            networkInfo: resolution.networkInfo,
            usedFallback: false
        )
        try tvOSManagedProfileExporter.exportManagedProfile(
            to: destinationURL,
            host: resolvedHost,
            port: Int(configuration.proxyPort)
        )
        recordProfileSnapshot(kind: .tvOSManagedProxyProfile, resolution: snapshotResolution, profileServerURL: nil)
    }

    /// Starts the local profile HTTP server on port 8765 and updates ``profileServerURL``.
    ///
    /// Call from device setup walkthroughs on `onAppear`. Safe to call if already running.
    func startProfileServer() async {
        profileServerStartErrorMessage = nil
        await profileHostingServer.setProfileServedHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.profileServerDownloadDetected = true
                self?.recordProfileSnapshot(kind: .iosTrustProfile, profileServerURL: self?.profileServerURL)
            }
        }
        do {
            let resolution = currentProfileHostResolution
            try await profileHostingServer.start(host: resolution.host)
            profileServerURL = await profileHostingServer.serverURL
            profileServerStartErrorMessage = nil
            refreshProfileMaintenanceStatus()
        } catch {
            profileServerStartErrorMessage = Self.userFacingErrorMessage(from: error, surface: .profileServer)
            profileServerURL = nil
            logger.error("Profile server failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops the local profile HTTP server and clears ``profileServerURL``.
    ///
    /// Call from device setup walkthroughs on `onDisappear`.
    func stopProfileServer() async {
        await profileHostingServer.stop()
        profileServerURL = nil
        profileServerStartErrorMessage = nil
        profileServerDownloadDetected = false
        refreshProfileMaintenanceStatus()
    }

    private func recordProfileSnapshot(
        kind: GeneratedProfileKind,
        resolution: ProfileHostResolution? = nil,
        profileServerURL: URL?
    ) {
        let resolved = resolution ?? currentProfileHostResolution
        let identity = certificateAuthority.currentRootCertificate()
        let fingerprint = identity.map {
            CertificateIdentityExtraction.sha256Fingerprint(from: $0.certificateData)
        }
        let metadata = fingerprint.flatMap { caInstanceMetadataStore.metadata(forFingerprint: $0) }
        let snapshot = ProfileSnapshotFactory.makeSnapshot(
            kind: kind,
            identity: identity,
            resolution: resolved,
            proxyPort: configuration.proxyPort,
            profileServerURL: profileServerURL,
            certificateLabel: configuration.certificateLabel,
            caInstanceMetadata: metadata,
            artifactID: nil
        )
        do {
            try profileSnapshotStore.appendSnapshot(snapshot)
            profileSnapshots = profileSnapshotStore.loadSnapshots()
            refreshProfileMaintenanceStatus()
        } catch {
            logger.error("Profile snapshot could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    var sdkEventServerEnabled: Bool {
        configuration.sdkEventServerEnabled
    }

    var sdkEventServerPort: UInt16 {
        configuration.sdkEventServerPort
    }

    func enableSDKEventServerForDeviceSetup() {
        guard !configuration.sdkEventServerEnabled else {
            return
        }
        configuration.sdkEventServerEnabled = true
        Task { @MainActor [weak self] in
            await self?.refreshSDKEventServerStatus()
        }
    }

    func refreshSDKEventServerStatus() async {
        sdkEventServerStatus = await proxyRuntime.sdkEventServerStatus()
    }

    func startProxy() {
        guard canStartProxy else { return }
        do {
            try applyProxyPortDraft()
        } catch {
            let message = NetworkFailureClassifier.presentation(for: error).userFacingMessage
            lastErrorMessage = message
            proxyState = .failed(message: message)
            return
        }

        proxyStartRequested = true
        proxyState = .starting(port: configuration.proxyPort)
        Task {
            await proxyRuntime.start()
            proxyState = proxyRuntime.currentState
            proxyStartRequested = false
            syncProxyPortDraftWithConfiguration()
        }
    }

    func stopProxy() {
        guard canStopProxy else { return }
        proxyState = .stopping
        Task {
            await proxyRuntime.stop()
            syncProxyPortDraftWithConfiguration()
        }
    }

    /// Brings the macOS system proxy in line with the preference and current proxy run state.
    /// Called on proxy start/stop and when the preference changes, so enabling the toggle while the
    /// proxy is already running activates immediately (and disabling restores immediately).
    private func reconcileSystemProxyManagement() {
        guard let controller = systemProxyController else { return }
        let runningPort: UInt16? = {
            if case .running(let port) = proxyState { return port }
            return nil
        }()

        if configuration.isSystemProxyManagementEnabled, let port = runningPort {
            if !controller.isActive {
                let mode: SystemProxyController.Mode = configuration.systemProxyStrictCapture ? .strictStatic : .pacFailOpen
                Task { await controller.enable(port: port, mode: mode) }
            }
        } else if controller.isActive {
            Task { await controller.disable() }
        }
    }

    func applyProxyPortDraft() throws {
        let trimmedDraft = proxyPortDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(trimmedDraft), port > 0 else {
            throw ProxyError.invalidPort
        }

        configuration.proxyPort = port
        proxyPortDraft = String(port)
        if case .failed = proxyState {
            proxyState = .stopped
        }
        lastErrorMessage = nil
    }

    func resetPersistedPreferences() {
        configuration.resetToDefaults()
        reloadPersistedPreferencesFromConfiguration()
        if case .failed = proxyState {
            proxyState = .stopped
        }
        lastErrorMessage = nil
        bookmarkUpdateContext = nil
        Task { [weak self] in
            await self?.loadPersistedResponseOverrides()
            await self?.refreshResponseOverrides()
        }
    }

    func addHTTPSBypassDomain(_ domain: String) {
        let normalizedDomain = normalizeHTTPSRuleDomain(domain)
        guard !normalizedDomain.isEmpty, !httpsBypassDomains.contains(normalizedDomain) else {
            return
        }

        httpsBypassDomains.append(normalizedDomain)
        httpsBypassDomains.sort()
    }

    func removeHTTPSBypassDomain(_ domain: String) {
        httpsBypassDomains.removeAll { $0 == domain }
    }

    func addHTTPSInterceptDomain(_ domain: String) {
        let normalizedDomain = normalizeHTTPSRuleDomain(domain)
        guard !normalizedDomain.isEmpty, !httpsInterceptDomains.contains(normalizedDomain) else {
            return
        }

        if case .bypass(let reason) = TLSInterceptionPolicy.decision(for: normalizedDomain, rules: .init()),
           reason.hasPrefix("Built-in compatibility bypass") {
            lastErrorMessage = "\(normalizedDomain) is covered by a built-in compatibility bypass and will continue to tunnel."
            return
        }

        httpsInterceptDomains.append(normalizedDomain)
        httpsInterceptDomains.sort()
    }

    func removeHTTPSInterceptDomain(_ domain: String) {
        httpsInterceptDomains.removeAll { $0 == domain }
    }

    func resetHTTPSRulesToDefaults() {
        httpsBypassDomains = []
        httpsInterceptDomains = []
        lastErrorMessage = nil
    }

    func addNoCachingDomain(_ domain: String) {
        let normalizedDomain = normalizeHTTPSRuleDomain(domain)
        guard !normalizedDomain.isEmpty, !noCachingDomains.contains(normalizedDomain) else {
            return
        }
        noCachingDomains.append(normalizedDomain)
        noCachingDomains.sort()
    }

    func removeNoCachingDomain(_ domain: String) {
        noCachingDomains.removeAll { $0 == domain }
    }

    func resetNoCachingToDefaults() {
        isNoCachingEnabled = false
        noCachingDomains = []
    }

    func performPrimaryCertificateAction() {
        switch certificateWorkflowState {
        case .notSetUp:
            if rootCertificate == nil {
                createOrLoadRootCertificate()
            } else {
                installRootCertificate()
            }
        case .installedTrustRequired:
            refreshCertificateStatus()
        case .ready:
            break
        case .needsCleanup:
            confirmResetCertificateState()
        }
    }

    func createOrLoadRootCertificate() {
        logger.info("Trust flow: create/load root CA requested for label '\(self.configuration.certificateLabel, privacy: .public)'")
        do {
            let previousData = certificateStore
                .loadRootCertificate(label: configuration.certificateLabel)?
                .certificateData
            rootCertificate = try certificateAuthority.loadOrCreateRootCertificate()
            let didCreateNewRoot = previousData == nil
                || previousData != rootCertificate?.certificateData
            refreshCertificateStatus(didCreateNewRoot: didCreateNewRoot)
            lastErrorMessage = nil
            logger.info("Trust flow: create/load root CA succeeded for label '\(self.configuration.certificateLabel, privacy: .public)'")
        } catch {
            logger.error("Trust flow: create/load root CA failed for label '\(self.configuration.certificateLabel, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentTrustFailure(
                title: "Root Certificate Error",
                message: error.localizedDescription,
                suggestsReset: false
            )
            refreshCertificateStatus()
        }
    }

    func installRootCertificate() {
        logger.info("Trust flow: install root CA requested for label '\(self.configuration.certificateLabel, privacy: .public)'")
        do {
            let previousData = certificateStore
                .loadRootCertificate(label: configuration.certificateLabel)?
                .certificateData
            let identity = try certificateAuthority.loadOrCreateRootCertificate()
            try trustInstaller.install(identity)
            rootCertificate = identity
            let didCreateNewRoot = previousData == nil || previousData != identity.certificateData
            refreshCertificateStatus(didCreateNewRoot: didCreateNewRoot)
            lastErrorMessage = nil
            logger.info("Trust flow: install root CA succeeded for label '\(self.configuration.certificateLabel, privacy: .public)'")
        } catch {
            logger.error("Trust flow: install root CA failed for label '\(self.configuration.certificateLabel, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentTrustFailure(
                title: "Install Failed",
                message: "\(error.localizedDescription)\n\nReset Certificate State to clear JoesProxy's stored CA material and remove any conflicting JoesProxy root certificates.",
                suggestsReset: true
            )
            refreshCertificateStatus()
        }
    }

    func removeRootCertificate() {
        logger.info("Trust flow: remove root CA requested for label '\(self.configuration.certificateLabel, privacy: .public)'")
        do {
            try trustInstaller.removeCertificate(label: configuration.certificateLabel)
            refreshCertificateStatus()
            lastErrorMessage = nil
            logger.info("Trust flow: remove root CA succeeded for label '\(self.configuration.certificateLabel, privacy: .public)'")
        } catch {
            logger.error("Trust flow: remove root CA failed for label '\(self.configuration.certificateLabel, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            presentTrustFailure(
                title: "Certificate Removal Failed",
                message: "\(error.localizedDescription)\n\nReset Certificate State if you want JoesProxy to clear stored CA material too. If the certificate still appears in Keychain Access, remove it manually.",
                suggestsReset: true
            )
            refreshCertificateStatus()
        }
    }

    func confirmResetCertificateState() {
        trustAlertContext = TrustAlertContext(
            title: "Reset Certificate State",
            message: "This removes installed JoesProxy root certificates and clears JoesProxy's stored CA material. If anything remains in Keychain Access afterward, JoesProxy will tell you what still needs manual cleanup.",
            primaryAction: .resetCertificateState
        )
    }

    func resetCertificateState() {
        logger.info("Trust flow: reset certificate state requested for label '\(self.configuration.certificateLabel, privacy: .public)'")

        let retiringFingerprint = rootCertificate.map {
            CertificateIdentityExtraction.sha256Fingerprint(from: $0.certificateData)
        }
        var failureMessages: [String] = []

        do {
            try trustInstaller.removeCertificate(label: configuration.certificateLabel)
            logger.info("Trust flow: reset removed installed certificate state for label '\(self.configuration.certificateLabel, privacy: .public)'")
        } catch {
            logger.error("Trust flow: reset could not remove installed certificate for label '\(self.configuration.certificateLabel, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            failureMessages.append("Installed certificate cleanup: \(error.localizedDescription)")
        }

        do {
            try certificateStore.removeRootCertificate(label: configuration.certificateLabel)
            logger.info("Trust flow: reset removed persisted root CA material for label '\(self.configuration.certificateLabel, privacy: .public)'")
        } catch {
            logger.error("Trust flow: reset could not remove persisted root CA material for label '\(self.configuration.certificateLabel, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            failureMessages.append("Persisted CA cleanup: \(error.localizedDescription)")
        }

        // Pending renewal Keychain labels are keyed by the *active* short code at prepare time.
        if let shortCode = certificateIdentity?.shortCode {
            let pendingLabel = PersistentCertificateAuthorityProvider.pendingRenewalLabel(
                baseLabel: configuration.certificateLabel,
                shortCode: shortCode
            )
            do {
                try certificateStore.removeRootCertificate(label: pendingLabel)
            } catch {
                // Absent pending material is fine; only surface unexpected Keychain failures.
                if certificateStore.loadRootCertificate(label: pendingLabel) != nil {
                    failureMessages.append("Pending renewal cleanup: \(error.localizedDescription)")
                }
            }
        }
        for pending in caInstanceMetadataStore.pendingRenewalInstances() {
            do {
                _ = try caInstanceMetadataStore.markRetired(fingerprint: pending.certificateSHA256Fingerprint)
            } catch {
                failureMessages.append("Pending renewal metadata (\(pending.shortCode)): \(error.localizedDescription)")
            }
        }
        if let provider = certificateAuthority as? PersistentCertificateAuthorityProvider {
            provider.invalidateLeafCertificateCache()
            provider.clearActiveIssuerFingerprint()
        }

        if let retiringFingerprint {
            do {
                try caInstanceMetadataStore.markRetired(fingerprint: retiringFingerprint)
            } catch CAInstanceMetadataStoreError.fingerprintNotFound {
                // Legacy root with no metadata record — nothing to retire.
            } catch {
                failureMessages.append("CA identity metadata: \(error.localizedDescription)")
            }
            do {
                _ = try certificateDistributionRecordStore.markRetired(fingerprint: retiringFingerprint)
            } catch {
                failureMessages.append("Distribution records: \(error.localizedDescription)")
            }
        }

        refreshCertificateStatus()

        if failureMessages.isEmpty {
            lastErrorMessage = nil
            trustAlertContext = TrustAlertContext(
                title: "Certificate State Reset",
                message: "JoesProxy removed its stored CA material and any visible installed JoesProxy root certificates.",
                primaryAction: .acknowledge
            )
            logger.info("Trust flow: reset completed successfully for label '\(self.configuration.certificateLabel, privacy: .public)'")
            return
        }

        let message = failureMessages.joined(separator: "\n")
        lastErrorMessage = "Reset completed with manual cleanup still required.\n\(message)"
        trustAlertContext = TrustAlertContext(
            title: "Manual Cleanup Still Required",
            message: "\(message)\n\nInspect Keychain Access for '\(configuration.certificateLabel)' and remove any leftover certificate manually.",
            primaryAction: .acknowledge
        )
        logger.error("Trust flow: reset completed with manual cleanup required for label '\(self.configuration.certificateLabel, privacy: .public)'")
    }

    /// Trusts the installed root CA via `security add-trusted-cert`, avoiding the 8-step
    /// manual Keychain Access flow. macOS shows its own password dialog. Non-sandboxed only.
    func trustRootCertificate() {
        guard let identity = rootCertificate else {
            presentTrustFailure(
                title: "Nothing to trust",
                message: "Create and install the root CA first (Steps 1 and 2).",
                suggestsReset: false
            )
            return
        }
        isTrustingCertificate = true
        let certData = identity.certificateData
        let keychainPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Keychains/login.keychain-db")
        Task {
            let errorMessage = await Self.runAddTrustedCert(certData: certData, keychainPath: keychainPath)
            isTrustingCertificate = false
            if let errorMessage {
                presentTrustFailure(title: "Could Not Trust Certificate", message: errorMessage, suggestsReset: false)
            }
            refreshCertificateStatus()
        }
    }

    private static func runAddTrustedCert(certData: Data, keychainPath: String) async -> String? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-trust-\(UUID().uuidString).cer")
        do {
            try certData.write(to: tempURL)
        } catch {
            return "Could not write certificate to a temporary file: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["add-trusted-cert", "-r", "trustRoot", "-k", keychainPath, tempURL.path]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else {
                    let raw = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let msg = raw.isEmpty
                        ? "The security command failed (exit \(p.terminationStatus))."
                        : raw
                    continuation.resume(returning: msg)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: "Could not launch security: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Walkthrough verify

    func startMacVerify() {
        cancelMacVerify()
        macVerifyResult = .watching
        NSWorkspace.shared.open(URL(string: "http://captive.apple.com")!)
        macVerifyTask = Task { [weak self] in
            guard let self else { return }
            let result = await trafficWatcher.watch(
                matching: { session in
                    TrafficSource.classify(
                        clientAddress: session.request.clientAddress,
                        userAgent: session.request.userAgent
                    ) == .mac
                    && session.request.host.caseInsensitiveCompare("captive.apple.com") == .orderedSame
                },
                timeoutNanoseconds: 15_000_000_000
            )
            macVerifyResult = result
        }
    }

    func cancelMacVerify() {
        macVerifyTask?.cancel()
        macVerifyTask = nil
        macVerifyResult = .ready
    }

    func startDeviceVerify() {
        cancelDeviceVerify()
        deviceVerifyResult = .watching
        deviceVerifyClientAddress = nil
        deviceVerifyHostname = nil
        deviceVerifyTask = Task { [weak self] in
            guard let self else { return }
            let result = await trafficWatcher.watch(
                matching: { session in
                    TrafficSource.classify(
                        clientAddress: session.request.clientAddress,
                        userAgent: session.request.userAgent
                    ) == .device
                },
                timeoutNanoseconds: 60_000_000_000
            )
            if case .captured(let id) = result,
               let record = sessionStore.sessions.first(where: { $0.id == id }),
               let ip = record.request.clientAddress {
                deviceVerifyClientAddress = ip
                deviceVerifyHostname = await resolveHostname(ip: ip)
            }
            deviceVerifyResult = result
        }
    }

    func cancelDeviceVerify() {
        deviceVerifyTask?.cancel()
        deviceVerifyTask = nil
        deviceVerifyResult = .ready
        deviceVerifyClientAddress = nil
        deviceVerifyHostname = nil
    }

    private func resolveHostname(ip: String) async -> String? {
        await Task.detached(priority: .utility) {
            Host(address: ip).names.first
        }.value
    }

    func refreshCertificateStatus(didCreateNewRoot: Bool = false) {
        rootCertificate = certificateAuthority.currentRootCertificate()
        trustStatus = trustInstaller.installationStatus(for: configuration.certificateLabel)
        refreshCertificateIdentity(didCreateNewRoot: didCreateNewRoot)
        refreshProfileMaintenanceStatus()
        logger.info(
            """
            Trust flow: refreshed status for label '\(self.configuration.certificateLabel, privacy: .public)' \
            rootCAExists=\(self.rootCertificate != nil) \
            hasPrivateKey=\(self.rootCertificate?.privateKeyData != nil) \
            trustStatus=\(String(describing: self.trustStatus), privacy: .public)
            """
        )
    }

    /// Adopts identity for a legacy root that predates CA-instance metadata.
    func adoptLegacyCertificateIdentity() {
        guard let rootCertificate else { return }
        do {
            certificateIdentity = try caInstanceMetadataStore.adoptLegacy(identity: rootCertificate)
            refreshCertificateIdentity(didCreateNewRoot: false)
        } catch {
            presentTrustFailure(
                title: "Could Not Adopt Identity",
                message: error.localizedDescription,
                suggestsReset: false
            )
        }
    }

    /// Updates the user-editable nickname for the live CA instance.
    func updateCertificateIdentityNickname(_ nickname: String) {
        guard let fingerprint = currentCertificateFingerprint else { return }
        do {
            certificateIdentity = try caInstanceMetadataStore.updateNickname(
                fingerprint: fingerprint,
                nickname: nickname
            )
        } catch {
            presentTrustFailure(
                title: "Could Not Save Nickname",
                message: error.localizedDescription,
                suggestsReset: false
            )
        }
    }

    func copyCertificateFingerprint() {
        guard let fingerprint = currentCertificateFingerprint else { return }
        copyProfileMaintenanceValue(fingerprint)
    }

    func copyCertificateShortCode() {
        guard let shortCode = certificateIdentity?.shortCode else { return }
        copyProfileMaintenanceValue(shortCode)
    }

    /// Surfaces a non-reset certificate identity/renewal failure in the existing trust alert sheet.
    func presentCertificateIdentityError(title: String, message: String) {
        presentTrustFailure(title: title, message: message, suggestsReset: false)
    }

    /// Phase D: prepare a pending renewal root under a non-colliding Keychain label.
    func prepareCertificateRenewal() throws -> CAInstanceMetadata {
        guard let provider = certificateAuthority as? PersistentCertificateAuthorityProvider else {
            throw CertificateAuthorityError.unsupportedOperation(
                "Certificate renewal requires PersistentCertificateAuthorityProvider."
            )
        }
        guard let current = certificateIdentity ?? (rootCertificate.map { CAInstanceMetadata.makeCurrent(from: $0) }) else {
            throw CertificateAuthorityError.identityUnavailable
        }
        let pendingLabel = PersistentCertificateAuthorityProvider.pendingRenewalLabel(
            baseLabel: configuration.certificateLabel,
            shortCode: current.shortCode
        )
        let pendingIdentity = try provider.prepareRenewalRoot(pendingLabel: pendingLabel)
        var pendingMeta = CAInstanceMetadata.makeCurrent(from: pendingIdentity)
        pendingMeta.storageState = .legacy
        pendingMeta.renewalState = .pending
        pendingMeta.nickname = current.nickname.map { "\($0) (pending renewal)" } ?? "Pending renewal"
        _ = try caInstanceMetadataStore.upsert(pendingMeta)
        var active = current
        active.renewalState = .pending
        _ = try caInstanceMetadataStore.upsert(active)
        refreshCertificateIdentity(didCreateNewRoot: false)
        return pendingMeta
    }

    /// Phase D: promote a pending root after verification evidence matches its fingerprint.
    func promoteCertificateRenewal(pendingFingerprint: String, verificationFingerprint: String) throws {
        let normalizedPending = pendingFingerprint.replacingOccurrences(of: ":", with: "").lowercased()
        let normalizedEvidence = verificationFingerprint.replacingOccurrences(of: ":", with: "").lowercased()
        guard normalizedPending == normalizedEvidence else {
            throw CertificateAuthorityError.unsupportedOperation(
                "Renewal promotion verification fingerprint does not match the pending root."
            )
        }
        guard let provider = certificateAuthority as? PersistentCertificateAuthorityProvider else {
            throw CertificateAuthorityError.unsupportedOperation(
                "Certificate renewal requires PersistentCertificateAuthorityProvider."
            )
        }
        guard let pendingMeta = caInstanceMetadataStore.metadata(forFingerprint: normalizedPending),
              pendingMeta.renewalState == .pending else {
            throw CertificateAuthorityError.unsupportedOperation("No pending renewal root matches that fingerprint.")
        }
        // Pending Keychain label is keyed by the *active* short code at prepare time.
        guard let activeShortCode = certificateIdentity?.shortCode else {
            throw CertificateAuthorityError.unsupportedOperation(
                "Active CA short code is required to locate the pending renewal Keychain item."
            )
        }
        let pendingLabel = PersistentCertificateAuthorityProvider.pendingRenewalLabel(
            baseLabel: configuration.certificateLabel,
            shortCode: activeShortCode
        )
        let previousFingerprint = currentCertificateFingerprint
        _ = try provider.promoteRenewalRoot(pendingLabel: pendingLabel)
        if let previousFingerprint {
            _ = try? caInstanceMetadataStore.markRetired(fingerprint: previousFingerprint)
        }
        var promoted = pendingMeta
        promoted.storageState = .current
        promoted.renewalState = .activePromoted
        _ = try caInstanceMetadataStore.upsert(promoted)
        refreshCertificateStatus(didCreateNewRoot: false)
    }

    /// Pending renewal metadata for the staged root (if any), distinct from the active identity card.
    var pendingCertificateRenewal: CAInstanceMetadata? {
        caInstanceMetadataStore.pendingRenewalInstances().first
    }

    /// Cancels a staged renewal: removes the pending Keychain label and clears renewal state.
    func cancelCertificateRenewal() throws {
        let pendingInstances = caInstanceMetadataStore.pendingRenewalInstances()
        guard !pendingInstances.isEmpty else {
            throw CertificateAuthorityError.unsupportedOperation("No pending renewal root to cancel.")
        }
        if let activeShortCode = certificateIdentity?.shortCode {
            let pendingLabel = PersistentCertificateAuthorityProvider.pendingRenewalLabel(
                baseLabel: configuration.certificateLabel,
                shortCode: activeShortCode
            )
            try? certificateStore.removeRootCertificate(label: pendingLabel)
        }
        for pending in pendingInstances {
            _ = try caInstanceMetadataStore.markRetired(fingerprint: pending.certificateSHA256Fingerprint)
        }
        if var active = certificateIdentity {
            active.renewalState = .none
            _ = try caInstanceMetadataStore.upsert(active)
        }
        refreshCertificateIdentity(didCreateNewRoot: false)
    }

    /// Phase D5: export root + private key for explicit multi-Mac sharing.
    func exportSharedRootPackage(to destinationURL: URL) throws {
        guard let identity = rootCertificate ?? certificateAuthority.currentRootCertificate() else {
            throw CertificateAuthorityError.identityUnavailable
        }
        let package = try SharedRootExportPackage.make(
            from: identity,
            shortCode: certificateIdentity?.shortCode
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(package).write(to: destinationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
    }

    /// Phase D5: import a shared-root package and mark metadata as ``CAStorageState/imported``.
    func importSharedRootPackage(from sourceURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(SharedRootExportPackage.self, from: data)
        let identity = try package.rootIdentity(relabeledAs: configuration.certificateLabel)
        try certificateStore.saveRootCertificate(identity)
        if let provider = certificateAuthority as? PersistentCertificateAuthorityProvider {
            provider.invalidateLeafCertificateCache()
        }
        var metadata = CAInstanceMetadata.makeCurrent(from: identity)
        metadata.storageState = .imported
        metadata.nickname = "Imported shared root"
        _ = try caInstanceMetadataStore.upsert(metadata)
        refreshCertificateStatus(didCreateNewRoot: false)
    }

    /// Wires Phase B stable payload metadata + distribution recording onto concrete exporters.
    private static func wireProfileExportIdentity(
        iosExporter: any IOSDeviceTrustProfileExporting,
        tvOSExporter: any TVOSManagedProfileExporting,
        viewModel: ProxyViewModel
    ) {
        let metadataProvider: () -> CAInstanceMetadata? = { [weak viewModel] in
            viewModel?.certificateIdentity
        }
        let recorder: @MainActor (CertificateDistributionRecord) throws -> Void = { [weak viewModel] record in
            guard let viewModel else { return }
            try viewModel.certificateDistributionRecordStore.append(record)
        }
        if let iosExporter = iosExporter as? IOSDeviceTrustProfileExporter {
            iosExporter.caInstanceMetadataProvider = metadataProvider
            iosExporter.distributionRecorder = recorder
        }
        if let tvOSExporter = tvOSExporter as? TVOSManagedProfileExporter {
            tvOSExporter.caInstanceMetadataProvider = metadataProvider
            tvOSExporter.distributionRecorder = recorder
        }
    }

    /// Syncs ``certificateIdentity`` / ``certificateIdentityStatus`` from the metadata store.
    ///
    /// - Parameter didCreateNewRoot: When `true`, mints a `.current` metadata record for the live fingerprint.
    private func refreshCertificateIdentity(didCreateNewRoot: Bool) {
        guard let rootCertificate else {
            certificateIdentity = nil
            certificateIdentityStatus = .missing
            return
        }

        let fingerprint = CertificateIdentityExtraction.sha256Fingerprint(from: rootCertificate.certificateData)

        if didCreateNewRoot, caInstanceMetadataStore.metadata(forFingerprint: fingerprint) == nil {
            do {
                _ = try caInstanceMetadataStore.upsert(CAInstanceMetadata.makeCurrent(from: rootCertificate))
            } catch {
                logger.error("Trust flow: failed to mint CA instance metadata: \(error.localizedDescription, privacy: .public)")
            }
        }

        let metadata = caInstanceMetadataStore.metadata(forFingerprint: fingerprint)
        certificateIdentity = metadata
        certificateIdentityStatus = CertificateIdentityExtraction.evaluateIdentityStatus(
            rootCertificateData: rootCertificate.certificateData,
            metadata: metadata
        )
    }

    /// Defers and coalesces lifecycle-driven refreshes so SwiftUI is not notified while it is
    /// evaluating `onAppear` or `scenePhase` updates.
    func scheduleCertificateStatusRefresh() {
        guard certificateStatusRefreshTask == nil else { return }
        certificateStatusRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            defer { self.certificateStatusRefreshTask = nil }
            if let certificateStatusReader = self.certificateStatusReader {
                let snapshot = await certificateStatusReader.readStatus()
                guard !Task.isCancelled else { return }
                self.rootCertificate = snapshot.rootCertificate
                self.trustStatus = snapshot.trustStatus
                self.refreshCertificateIdentity(didCreateNewRoot: false)
                self.refreshProfileMaintenanceStatus()
            } else {
                self.refreshCertificateStatus()
            }
        }
    }

    private func reloadPersistedPreferencesFromConfiguration() {
        assignIfChanged(&appTextSize, AppTextSize(rawValue: configuration.appTextSizeRawValue) ?? .standard)
        assignIfChanged(&isFindDebugLoggingEnabled, configuration.isFindDebugLoggingEnabled)
        assignIfChanged(
            &sessionSortField,
            SessionSortField(rawValue: configuration.sessionSortFieldRawValue) ?? .startedAt
        )
        assignIfChanged(&isSessionSortAscending, configuration.isSessionSortAscending)
        assignIfChanged(
            &sessionBrowserMode,
            SessionBrowserMode(rawValue: configuration.sessionBrowserModeRawValue) ?? .table
        )
        assignIfChanged(
            &sessionExplorerGrouping,
            SessionExplorerGrouping(rawValue: configuration.sessionExplorerGroupingRawValue) ?? .byHost
        )
        assignIfChanged(
            &sessionExplorerHostGrouping,
            SessionExplorerHostGrouping(rawValue: configuration.sessionExplorerHostGroupingRawValue) ?? .exactHosts
        )
        assignIfChanged(&sessionExplorerExpandedNodeIDs, Set(configuration.sessionExplorerExpandedNodeIDs))
        assignIfChanged(&sessionInspectorSplitFraction, configuration.sessionInspectorSplitFraction)
        assignIfChanged(&httpsBypassDomains, configuration.httpsBypassDomains)
        assignIfChanged(&httpsInterceptDomains, configuration.httpsInterceptDomains)
        assignIfChanged(&isNoCachingEnabled, configuration.isNoCachingEnabled)
        assignIfChanged(&noCachingDomains, configuration.noCachingDomains)
        assignIfChanged(&networkThrottleConfiguration, configuration.networkThrottleConfiguration)
        assignIfChanged(&proxyPortDraft, String(configuration.proxyPort))
        if configuration.isSessionAutoScrollEnabled {
            sessionFollowState = .followingLive
        } else {
            sessionFollowState = .staticInspection
        }
        if sessionStore.retentionPolicy != configuration.captureRetentionPolicy {
            sessionStore.retentionPolicy = configuration.captureRetentionPolicy
        }
    }

    private func assignIfChanged<Value: Equatable>(_ currentValue: inout Value, _ newValue: Value) {
        guard currentValue != newValue else { return }
        currentValue = newValue
    }

    func dismissTrustAlert() {
        trustAlertContext = nil
    }

    private func presentTrustFailure(title: String, message: String, suggestsReset: Bool) {
        lastErrorMessage = message
        trustAlertContext = TrustAlertContext(
            title: title,
            message: message,
            primaryAction: suggestsReset ? .resetCertificateState : .acknowledge
        )
    }

    func selectSessionFromUser(_ id: SessionRecord.ID?) {
        pauseFollowLiveForUserInteraction()
        selectedSessionID = id
    }

    func setFollowLiveEnabled(_ isEnabled: Bool) {
        let newState: SessionFollowState = isEnabled ? .followingLive : .staticInspection
        guard sessionFollowState != newState else { return }
        sessionFollowState = newState
        configuration.isSessionAutoScrollEnabled = isEnabled
        if isEnabled {
            selectNewestVisibleSession()
        }
    }

    func jumpToLatestSession() {
        sessionFollowState = .followingLive
        selectNewestVisibleSession()
    }

    func pauseFollowLiveForUserInteraction() {
        guard sessionFollowState == .followingLive else { return }
        sessionFollowState = .paused
    }

    var selectedNetworkThrottlePreset: NetworkThrottlePreset? {
        networkThrottleConfiguration.selectedPreset
    }

    var networkThrottleToolbarTitle: String {
        guard networkThrottleConfiguration.isEnabled,
              let preset = selectedNetworkThrottlePreset else {
            return "Throttling"
        }
        return "Throttling: \(preset.name)"
    }

    var networkThrottleToolbarAccessibilityValue: String {
        guard networkThrottleConfiguration.isEnabled,
              let preset = selectedNetworkThrottlePreset else {
            return "Off"
        }
        return "\(preset.name), \(preset.downstreamKbps) kilobits per second down, \(preset.upstreamKbps) kilobits per second up, \(preset.latencyMs) milliseconds latency"
    }

    func setNetworkThrottlingEnabled(_ isEnabled: Bool) {
        guard networkThrottleConfiguration.isEnabled != isEnabled else { return }
        networkThrottleConfiguration.isEnabled = isEnabled
    }

    func selectNetworkThrottlePreset(id: String) {
        guard networkThrottleConfiguration.presets.contains(where: { $0.id == id }) else { return }
        networkThrottleConfiguration.selectedPresetID = id
    }

    func expandExplorerAncestors(_ ancestorIDs: [String]) {
        let updated = sessionExplorerExpandedNodeIDs.union(ancestorIDs)
        guard updated != sessionExplorerExpandedNodeIDs else { return }
        isApplyingProgrammaticExplorerExpansion = true
        sessionExplorerExpandedNodeIDs = updated
        isApplyingProgrammaticExplorerExpansion = false
    }

    private func reconcileSelection() {
        if let selectedSessionID,
           captureWorkspace.sessionRecord(for: selectedSessionID) != nil {
            return
        }
        selectedSessionID = nil
    }

    private func selectNewestVisibleSession() {
        guard sessionFollowState == .followingLive else { return }
        let latestID = captureWorkspace.newestVisibleSessionID()
        guard selectedSessionID != latestID else { return }
        selectedSessionID = latestID
    }

    func visibleSession(for id: SessionRecord.ID) -> SessionRecord? {
        captureWorkspace.visibleSession(for: id)
    }

    func sessionRecord(for id: SessionRecord.ID) -> SessionRecord? {
        captureWorkspace.sessionRecord(for: id)
    }

    func preflightCapturedMock(revisionID: UUID) async throws -> CapturedMockPreflight {
        let snapshot = CapturedMockPreflightSnapshot.capture(from: sessionStore)
        return try await collectionMockAuthoringService.preflight(id: revisionID,
            ownerID: EffectBundleOwner.localUser.ownerID, snapshot: snapshot)
    }

    func visibleSessions(for ids: [SessionRecord.ID]) -> [SessionRecord] {
        captureWorkspace.visibleSessions(for: ids)
    }

    func visibleSessionSummaries(for ids: [SessionRecord.ID]) -> [SessionSummary] {
        captureWorkspace.visibleSessionSummaries(for: ids)
    }

    func explorerSessionSummaries(for nodeID: String) -> [SessionSummary] {
        captureWorkspace.explorerSessionSummaries(for: nodeID)
    }

    func sessionSummary(for id: SessionRecord.ID) -> SessionSummary? {
        captureWorkspace.summaryLookup(for: id)
    }

    func runSessionFind() {
        SessionFindPerformanceSignposts.emitSubmit()
        let trimmedQuery = sessionFindQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        sessionFindTask?.cancel()
        logFind("Run requested query='\(trimmedQuery)' sessionCount=\(captureWorkspace.totalCount) cachedBodyTexts=\(sessionBodyTextCacheByID.count)")

        guard !trimmedQuery.isEmpty else {
            sessionFindResults = []
            resetSessionFindVisibleLimit()
            sessionFindState = .emptyQuery
            logFind("Run stopped: empty query")
            return
        }

        resetSessionFindVisibleLimit()
        let snapshot = captureWorkspace.allSessions
        let bodyTextCacheSnapshot = sessionBodyTextCacheByID
        sessionFindState = .searching

        sessionFindTask = Task { [weak self, snapshot, trimmedQuery, sessionFindEngine, bodyTextCacheSnapshot] in
            let searchSignpost = SessionFindPerformanceSignposts.beginSearchTask()
            let searchTask = Task.detached(priority: .userInitiated) {
                sessionFindEngine.find(in: snapshot, query: trimmedQuery, bodyTextCache: bodyTextCacheSnapshot)
            }
            let outcome = await withTaskCancellationHandler {
                await searchTask.value
            } onCancel: {
                searchTask.cancel()
            }
            SessionFindPerformanceSignposts.endSearchTask(searchSignpost)

            guard !Task.isCancelled else {
                return
            }

            guard let self,
                  self.sessionFindQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery else {
                return
            }

            let publishSignpost = SessionFindPerformanceSignposts.beginPublishResults()
            self.sessionFindResults = outcome.results
            self.sessionFindVisibleResultLimit = SessionFindPresentation.initialVisibleLimit(
                for: outcome.results.count
            )
            self.updateBodyTextCache(with: outcome.decodedBodyTexts)
            self.logFind(
                "Run completed query='\(trimmedQuery)' results=\(outcome.results.count) visible=\(self.sessionFindVisibleResultLimit) searchedBodies=\(outcome.searchedBodyCount) decodedBodies=\(outcome.decodedBodyTexts.count)"
            )
            if outcome.searchedBodyCount == 0 {
                self.sessionFindState = .bodyUnavailable
            } else if outcome.results.isEmpty {
                self.sessionFindState = .noMatches(searchedBodyCount: outcome.searchedBodyCount)
            } else {
                self.sessionFindState = .results(
                    matchCount: outcome.results.count,
                    searchedBodyCount: outcome.searchedBodyCount
                )
            }
            SessionFindPerformanceSignposts.endPublishResults(publishSignpost)
            self.sessionFindTask = nil
        }
    }

    func clearSessionFind() {
        sessionFindTask?.cancel()
        sessionFindTask = nil
        sessionFindQuery = ""
        sessionFindResults = []
        resetSessionFindVisibleLimit()
        sessionFindState = .idle
        activeFindResultLocation = nil
        activeFindResultSessionID = nil
        activeFindNavigationID = nil
        logFind("Cleared active Find state")
    }

    func selectSessionFindResult(_ result: SessionFindResult) {
        let selectSignpost = SessionFindPerformanceSignposts.beginSelectResult()
        defer { SessionFindPerformanceSignposts.endSelectResult(selectSignpost) }

        let token = UUID()
        activeFindResultLocation = result.location
        activeFindResultSessionID = result.sessionID
        activeFindNavigationID = token
        logFind(
            "Selected result session=\(result.sessionID.uuidString) location=\(result.location.rawValue) matches=\(result.matchCount) method=\(result.method) host=\(result.host) path=\(result.path) token=\(token.uuidString)"
        )
        pauseFollowLiveForUserInteraction()
        selectedSessionID = result.sessionID
    }

    func sessionFindBodyMatchContext(
        for sessionID: SessionRecord.ID?,
        location: SessionFindResult.MatchLocation
    ) -> SessionFindBodyMatchContext? {
        let trimmedQuery = sessionFindQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionID, !trimmedQuery.isEmpty else {
            return nil
        }

        guard let result = sessionFindResults.first(where: { $0.sessionID == sessionID && $0.location == location }) else {
            return nil
        }

        return SessionFindBodyMatchContext(query: trimmedQuery, matchCount: result.matchCount)
    }

    private func clearSessionFindResults() {
        sessionFindTask?.cancel()
        sessionFindTask = nil
        sessionFindResults = []
        resetSessionFindVisibleLimit()
        sessionFindState = .idle
        activeFindResultLocation = nil
        activeFindResultSessionID = nil
        activeFindNavigationID = nil
        logFind("Cleared stale Find results")
    }

    private func resetSessionFindVisibleLimit() {
        sessionFindVisibleResultLimit = SessionFindPresentation.initialVisibleResultCount
    }

    private func logFind(_ message: String) {
        guard isFindDebugLoggingEnabled else { return }
        debugPrint("Find debug: \(message)")
    }

    /// Adds freshly decoded body texts to the cache, respecting per-body and total byte budgets.
    /// - Per-body limit: individual request or response texts larger than 512 KB are not cached.
    /// - Total budget: when an insert would exceed 50 MB, entries from the oldest find runs
    ///   are evicted down to 80% of the budget so new sessions keep getting cached on long
    ///   captures instead of the cache freezing at its first fill.
    private func updateBodyTextCache(with decodedTexts: [SessionRecord.ID: SessionBodyText]) {
        guard !decodedTexts.isEmpty else { return }

        bodyTextCacheGeneration &+= 1

        let maxBudgetBytes  = bodyTextCacheBudgetBytesOverride ?? 50 * 1024 * 1024   // 50 MB total
        let maxBodyBytes    = 512 * 1024           // 512 KB per individual body

        for (id, bodyText) in decodedTexts {
            // Never overwrite an existing entry — store-change invalidation evicts entries
            // whose bodies changed, so anything still present decodes to the same text.
            guard sessionBodyTextCacheByID[id] == nil else { continue }

            // Trim oversized individual bodies rather than skipping the whole entry —
            // a large request body shouldn't prevent a small response body from being cached.
            let reqText: String? = bodyText.requestText.flatMap { $0.utf8.count <= maxBodyBytes ? $0 : nil }
            let resText: String? = bodyText.responseText.flatMap { $0.utf8.count <= maxBodyBytes ? $0 : nil }

            // Nothing useful to cache if both bodies were skipped and response search was not evaluated.
            guard reqText != nil || resText != nil || bodyText.responseBodySearchWasEvaluated else { continue }

            let entryCost = (reqText?.utf8.count ?? 0) + (resText?.utf8.count ?? 0)

            if cachedBodyTextByteCount + entryCost > maxBudgetBytes {
                evictOldestBodyTextGenerations(budget: maxBudgetBytes)
            }
            // Entry still doesn't fit (pathologically large relative to the budget) — skip it.
            guard cachedBodyTextByteCount + entryCost <= maxBudgetBytes else { continue }

            sessionBodyTextCacheByID[id] = SessionBodyText(
                requestText: reqText,
                responseText: resText,
                responseBodySearchWasEvaluated: bodyText.responseBodySearchWasEvaluated
            )
            bodyTextCacheGenerationByID[id] = bodyTextCacheGeneration
            cachedBodyTextByteCount += entryCost
        }
    }

    /// Evicts entries inserted by the oldest find runs until usage drops to 80% of the budget.
    /// Entries from the current run are never evicted. Sorting runs only on overflow.
    private func evictOldestBodyTextGenerations(budget: Int) {
        let target = budget * 8 / 10
        guard cachedBodyTextByteCount > target else { return }

        let candidates = bodyTextCacheGenerationByID
            .filter { $0.value < bodyTextCacheGeneration }
            .sorted { $0.value < $1.value }

        for (id, _) in candidates {
            guard cachedBodyTextByteCount > target else { return }
            evictBodyTextCacheEntries(ids: [id])
        }
    }

    private func syncProxyPortDraftWithConfiguration() {
        proxyPortDraft = String(configuration.proxyPort)
    }

    private func canExecuteBookmark(id: Bookmark.ID) -> Bool {
        guard case .running = proxyState else {
            return false
        }

        if bookmarkValidationMessage(for: id) != nil {
            return false
        }

        switch bookmarkExecutionState {
        case .idle:
            return true
        case .executing:
            return false
        case .failed:
            return true
        }
    }

    private func bookmarkExecutionMessage(for bookmarkID: Bookmark.ID) -> String? {
        let validationMessage = bookmarkValidationMessage(for: bookmarkID)

        switch bookmarkExecutionState {
        case .idle:
            if case .running = proxyState {
                return validationMessage
            }
            return "Start the proxy to execute bookmarks."
        case .executing(let executingBookmarkID) where executingBookmarkID == bookmarkID:
            return "Running bookmark through JoesProxy…"
        case .executing:
            return "Another bookmark is currently running."
        case .failed(let failedBookmarkID, let message) where failedBookmarkID == bookmarkID:
            return validationMessage ?? message
        case .failed:
            return validationMessage
        }
    }

    private func bookmarkValidationMessage(for bookmarkID: Bookmark.ID) -> String? {
        guard let bookmark = bookmarks.first(where: { $0.id == bookmarkID }) else {
            return nil
        }

        return BookmarkRequestEditing.validationMessage(for: bookmark.request)
    }

    private func updateLastExecutedDate(for bookmarkID: Bookmark.ID, at date: Date) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            return
        }

        bookmarks[index].lastExecutedAt = date
        persistBookmarks()
    }

    /// Waits for the session produced by an executed bookmark. One initial scan covers
    /// sessions captured before the wait began; after that, only records arriving via
    /// store changes are checked — no repeated full-array polling.
    private func waitForExecutedSessionMatch(
        request: CapturedRequest,
        startedAt: Date
    ) async -> SessionRecord? {
        if let existing = newestMatchingSession(for: request, startedAt: startedAt) {
            return existing
        }

        // No suspension between the scan above and the subscription below (both on the
        // main actor), so a session can't slip through the gap.
        return await withCheckedContinuation { (continuation: CheckedContinuation<SessionRecord?, Never>) in
            var cancellable: AnyCancellable?
            var timeoutTask: Task<Void, Never>?
            var finished = false

            func finish(_ session: SessionRecord?) {
                guard !finished else { return }
                finished = true
                cancellable?.cancel()
                timeoutTask?.cancel()
                continuation.resume(returning: session)
            }

            cancellable = sessionStore.sessionChangesPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] change in
                    guard let self else {
                        finish(nil)
                        return
                    }
                    let candidates: [SessionRecord]
                    switch change {
                    case .appended(let session, _), .updated(let session, _):
                        candidates = [session]
                    case .updatedBatch(let sessions, _):
                        candidates = sessions
                    case .bodiesStripped, .removed, .cleared, .loaded:
                        return
                    }
                    for session in candidates where self.matchesExecutedRequest(session, request: request, startedAt: startedAt) {
                        finish(session)
                        return
                    }
                }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                finish(nil)
            }
        }
    }

    private func newestMatchingSession(for request: CapturedRequest, startedAt: Date) -> SessionRecord? {
        captureWorkspace.allSessions
            .filter { matchesExecutedRequest($0, request: request, startedAt: startedAt) }
            .max { lhs, rhs in
                lhs.timing.startedAt < rhs.timing.startedAt
            }
    }

    private func matchesExecutedRequest(
        _ session: SessionRecord,
        request: CapturedRequest,
        startedAt: Date
    ) -> Bool {
        session.timing.startedAt >= startedAt.addingTimeInterval(-1) &&
        session.request.method.caseInsensitiveCompare(request.method) == .orderedSame &&
        session.request.scheme == request.scheme &&
        session.request.host.caseInsensitiveCompare(request.host) == .orderedSame &&
        normalizeRequestPath(session.request.path) == normalizeRequestPath(request.path) &&
        canonicalPort(for: session.request) == canonicalPort(for: request)
    }

    private func sessionsForBookmarkUpdate(
        bookmarkID: Bookmark.ID,
        bookmark: Bookmark? = nil
    ) -> [SessionRecord] {
        guard let bookmark = bookmark ?? bookmarks.first(where: { $0.id == bookmarkID }) else {
            return []
        }

        return captureWorkspace.allSessions
            .filter { session in
                session.request.method.caseInsensitiveCompare(bookmark.request.method) == .orderedSame &&
                session.request.host.caseInsensitiveCompare(bookmark.request.host) == .orderedSame &&
                normalizeBookmarkUpdatePath(session.request.path) == normalizeBookmarkUpdatePath(bookmark.request.path)
            }
            .sorted { lhs, rhs in
                lhs.timing.startedAt > rhs.timing.startedAt
            }
    }

    private func normalizeRequestPath(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }

    private func normalizeBookmarkUpdatePath(_ path: String) -> String {
        let normalizedPath = normalizeRequestPath(path)
        if let querySeparator = normalizedPath.firstIndex(of: "?") {
            return String(normalizedPath[..<querySeparator])
        }
        return normalizedPath
    }

    private func canonicalPort(for request: CapturedRequest) -> Int {
        if let port = request.port {
            return port
        }

        switch request.scheme {
        case .http:
            return 80
        case .https:
            return 443
        }
    }

    private func normalizeHTTPSRuleDomain(_ domain: String) -> String {
        var normalizedDomain = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedDomain.hasPrefix("*.") {
            normalizedDomain = String(normalizedDomain.dropFirst(2))
        }

        if normalizedDomain.hasPrefix(".") {
            normalizedDomain = String(normalizedDomain.dropFirst())
        }

        return normalizedDomain
    }

    private func persistBookmarks() {
        bookmarks = Self.sortBookmarks(bookmarks)
        do {
            try bookmarkStore.saveBookmarks(bookmarks)
        } catch {
            let message = Self.userFacingErrorMessage(from: error, surface: .fileExport)
            lastErrorMessage = "Bookmark save failed: \(message)"
            logger.error("Bookmark save failed: \(error.localizedDescription, privacy: .public)")
        }

        Task { @MainActor [weak self] in
            await self?.syncBookmarkResponseInterceptStore()
        }
    }

    /// Pushes bookmark rewrite definitions and session-enabled IDs to the proxy runtime store.
    private func syncBookmarkResponseInterceptStore() async {
        await bookmarkResponseInterceptStore.syncBookmarks(bookmarks)
        await bookmarkResponseInterceptStore.setEnabledBookmarkIDs(enabledBookmarkResponseRewriteIDs)
    }

    private func clearEnabledBookmarkResponseRewritesForStoppedProxy() {
        guard !enabledBookmarkResponseRewriteIDs.isEmpty else {
            return
        }

        enabledBookmarkResponseRewriteIDs.removeAll()
        bookmarkResponseRewriteActivityByID.removeAll()
        Task { @MainActor [weak self] in
            await self?.syncBookmarkResponseInterceptStore()
        }
    }

    /// Records intercept telemetry when a captured session was served from a bookmark response rewrite.
    private func recordBookmarkResponseRewriteIntercept(from session: SessionRecord) {
        guard session.response?.source == .bookmarkResponseRewrite else {
            return
        }

        let matchingBookmarks = bookmarks
            .filter { enabledBookmarkResponseRewriteIDs.contains($0.id) }
            .filter {
                BookmarkRequestMatcher.matches(
                    ruleRequest: $0.request,
                    matchMode: $0.responseMatchMode,
                    request: session.request
                )
            }
            .sorted { $0.createdAt > $1.createdAt }

        guard let bookmark = matchingBookmarks.first else {
            return
        }

        let rewriteByID = Dictionary(uniqueKeysWithValues: bookmark.responseRewrites.map { ($0.id, $0) })
        var appliedPaths: [String] = []
        var skippedPaths: [String] = []

        if let bodyData = bookmark.savedResponse?.bodyData,
           let result = try? BookmarkJSONRewriteEngine.apply(
            bodyData: bodyData,
            rewrites: bookmark.responseRewrites
           ) {
            appliedPaths = result.appliedRuleIDs.compactMap { rewriteByID[$0]?.jsonPath }
            skippedPaths = result.skippedRuleIDs.compactMap { rewriteByID[$0]?.jsonPath }
        } else if let description = session.response?.sourceDescription {
            appliedPaths = Self.parseListedPaths(from: description, marker: "applied:")
            skippedPaths = Self.parseListedPaths(from: description, marker: "skipped:")
        }

        var activity = bookmarkResponseRewriteActivityByID[bookmark.id]
            ?? BookmarkResponseRewriteActivity(enabledAt: session.timing.startedAt)
        activity.lastInterceptAt = session.timing.completedAt ?? session.timing.startedAt
        activity.lastInterceptPath = session.request.path
        activity.lastAppliedCount = appliedPaths.count
        activity.lastSkippedCount = skippedPaths.count
        activity.lastAppliedPaths = Array(appliedPaths.prefix(5))
        activity.lastSkippedPaths = Array(skippedPaths.prefix(5))
        bookmarkResponseRewriteActivityByID[bookmark.id] = activity
    }

    private static func parseListedPaths(from description: String, marker: String) -> [String] {
        guard let range = description.range(of: marker) else {
            return []
        }
        let remainder = description[range.upperBound...]
        let segment = remainder.split(separator: "·", maxSplits: 1).first.map(String.init) ?? String(remainder)
        return segment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("+") }
    }

    private func defaultBookmarkName(for session: SessionRecord) -> String {
        defaultBookmarkName(for: session.request)
    }

    private func defaultBookmarkName(for request: CapturedRequest) -> String {
        "\(request.method) \(request.host)\(request.path)"
    }

    private static func sortBookmarks(_ bookmarks: [Bookmark]) -> [Bookmark] {
        bookmarks.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
    }

    private func applyBodyTextCacheChange(_ change: SessionStoreChange) {
        switch change {
        case .appended(_, let droppedIDs):
            evictBodyTextCacheEntries(ids: droppedIDs)
        case .updated(let session, _):
            // Response overrides / Map Local / pending→completed can change body content;
            // evict so the next find re-decodes the current bytes.
            evictBodyTextCacheEntries(ids: [session.id])
        case .updatedBatch(let sessions, _):
            // Includes phase-2 recording body restoration — cached text (if any) predates
            // the restored bodies.
            evictBodyTextCacheEntries(ids: Set(sessions.map(\.id)))
        case .bodiesStripped(let sessions):
            // Bodies are gone; keeping decoded text would pin memory the store just freed
            // and let find report hits whose bodies can no longer be shown.
            evictBodyTextCacheEntries(ids: Set(sessions.map(\.id)))
        case .removed(let ids):
            evictBodyTextCacheEntries(ids: ids)
        case .cleared, .loaded:
            let retiredCache = RetiredBodyTextCache(
                bodyTextByID: sessionBodyTextCacheByID,
                generationByID: bodyTextCacheGenerationByID
            )
            sessionBodyTextCacheByID = [:]
            bodyTextCacheGenerationByID = [:]
            cachedBodyTextByteCount = 0
            DeferredRelease.schedule(retiredCache)
        }
    }

    private func evictBodyTextCacheEntries(ids: Set<SessionRecord.ID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            bodyTextCacheGenerationByID[id] = nil
            guard let removed = sessionBodyTextCacheByID.removeValue(forKey: id) else { continue }
            let cost = (removed.requestText?.utf8.count ?? 0) + (removed.responseText?.utf8.count ?? 0)
            cachedBodyTextByteCount = Swift.max(0, cachedBodyTextByteCount - cost)
        }
    }

    private func applyBookmarkRewriteIntercept(_ change: SessionStoreChange) {
        switch change {
        case .appended(let session, _):
            recordBookmarkResponseRewriteIntercept(from: session)
        case .updated(let session, _):
            recordBookmarkResponseRewriteIntercept(from: session)
        case .updatedBatch(let sessions, _):
            sessions.forEach { recordBookmarkResponseRewriteIntercept(from: $0) }
        case .bodiesStripped, .removed, .cleared, .loaded:
            break
        }
    }

    private func refreshResponseOverrides() async {
        let overrides = await responseOverrideStore.rules()
        self.responseOverrides = overrides
    }

    /// Re-reads response overrides, bookmarks, and throttle configuration after
    /// `MCPServerController.enforceFreshLaunchMCPState()` deletes MCP-origin traffic mutations at
    /// launch, so the UI reflects the purge instead of the pre-purge snapshot taken during `init`.
    func reloadStateAfterMCPFreshLaunchPurge() async {
        await refreshResponseOverrides()
        self.bookmarks = Self.sortBookmarks(bookmarkStore.loadBookmarks())
        self.networkThrottleConfiguration = MCPTargetRevisionFingerprint.throttleByApplyingRevision(
            configuration.networkThrottleConfiguration
        )
    }

    private func loadPersistedResponseOverrides() async {
        do {
            try await responseOverrideStore.loadPersistedData(
                configuration.responseOverridesData,
                loopbackPolicy: configuration.loopbackDestinationPolicy
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func persistResponseOverrides() async throws {
        configuration.responseOverridesData = try await responseOverrideStore.persistedData()
    }

    // MARK: - Capture health

    /// Updates capture health metrics at most once every 2 seconds to avoid main-thread overhead
    /// during rapid session capture.
    private func updateCaptureHealthThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastHealthUpdateTime) >= 2.0 else { return }
        lastHealthUpdateTime = now
        sampleProcessMetrics()
        captureHealth = makeHealthMetrics()
        emitCaptureDiagnosticsSummary(force: false)
    }

    /// Samples process-level diagnostics. Sampling failures are represented by the sampler as
    /// `.empty`, so diagnostics never affect proxy state or session capture.
    private func sampleProcessMetrics() {
        latestProcessMetrics = processMetricsSampler.sample()
    }

    /// Assembles a `CaptureHealthMetrics` snapshot from the current session store state.
    private func makeHealthMetrics() -> CaptureHealthMetrics {
        CaptureHealthMetrics(
            sessionCount: sessionStore.sessions.count,
            retainedBodyBytes: sessionStore.retainedBodyBytes,
            droppedSessionCount: sessionStore.droppedSessionCount,
            evictedBodyCount: sessionStore.evictedBodyCount,
            captureStartedAt: captureStartedAt,
            processMetrics: latestProcessMetrics
        )
    }

    private func emitCaptureDiagnosticsSummary(force: Bool) {
        if !force, didEmitFinalCaptureDiagnosticsSummary {
            return
        }

        let isEnabled = RuntimeDebugFlag.isLongCaptureDiagnosticsEnabled
        let metrics = makeHealthMetrics()
        let now = Date()

        guard force || captureDiagnosticsCadence.shouldEmit(
            now: now,
            isEnabled: isEnabled,
            sessionCount: metrics.sessionCount
        ) else {
            return
        }

        guard isEnabled, metrics.sessionCount > 0 else { return }

        let summary = CaptureDiagnosticsSummary.make(
            metrics: metrics,
            sessions: sessionStore.sessions,
            transport: captureTransportDiagnostics.snapshot(),
            workspaceRetention: captureWorkspace.retentionCounts,
            retainedHeaderFieldCount: sessionStore.retainedHeaderFieldCount
        )
        captureDiagnosticsLogger.info("\(summary.logMessage, privacy: .public)")
    }

    private func emitFinalCaptureDiagnosticsSummaryIfNeeded() {
        guard !didEmitFinalCaptureDiagnosticsSummary else { return }
        didEmitFinalCaptureDiagnosticsSummary = true
        emitCaptureDiagnosticsSummary(force: true)
        captureStartedAt = nil
        captureDiagnosticsCadence.reset()
        captureTransportDiagnostics.reset()
    }

    private func reconcileSelectionForVisibleSessionsChange() {
        if sessionFollowState == .followingLive {
            selectNewestVisibleSession()
        } else {
            reconcileSelection()
        }
    }

    private static func userFacingErrorMessage(from error: Error, surface: UserFacingErrorSurface) -> String {
        NetworkFailureClassifier.userFacingMessage(for: error, surface: surface)
    }

    // MARK: - Device Registry & Attribution (Workstream DL)

    func refreshDiscoveredDevices() {
        Task { [weak self] in
            guard let self else { return }
            let devices = await deviceRegistry.discoveredDevices()
            await MainActor.run {
                self.discoveredDevices = devices
            }
        }
    }

    func setDeviceAlias(ipAddress: String, alias: String?) {
        Task { [weak self] in
            guard let self else { return }
            _ = await deviceRegistry.setDeviceAlias(ipAddress: ipAddress, alias: alias)
            let devices = await deviceRegistry.discoveredDevices()
            await MainActor.run {
                self.discoveredDevices = devices
            }
        }
    }

    func deviceDisplayName(for clientAddress: String?) -> String? {
        guard let clientAddress else { return nil }
        return discoveredDevices.first(where: { $0.ipAddress == clientAddress })?.displayName ?? clientAddress
    }

    private func recordDevices(for sessions: [SessionRecord], replacingRegistry: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            if replacingRegistry {
                await deviceRegistry.clear()
            }
            for session in sessions {
                guard let clientAddress = session.request.clientAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !clientAddress.isEmpty else {
                    continue
                }
                _ = await deviceRegistry.recordClientConnection(
                    ipAddress: clientAddress,
                    timestamp: session.timing.startedAt
                )
            }
            let devices = await deviceRegistry.discoveredDevices()
            await MainActor.run {
                if self.discoveredDevices != devices {
                    self.discoveredDevices = devices
                }
            }
        }
    }

    private func applyDeviceRegistryUpdate(_ change: SessionStoreChange) {
        switch change {
        case .appended(let session, _):
            recordDevices(for: [session])
        case .updated(let session, let inserted):
            if inserted { recordDevices(for: [session]) }
        case .updatedBatch(let sessions, let insertedIDs):
            recordDevices(for: sessions.filter { insertedIDs.contains($0.id) })
        case .loaded(let sessions, _):
            recordDevices(for: sessions, replacingRegistry: true)
        case .cleared:
            Task { [weak self] in
                guard let self else { return }
                await deviceRegistry.clear()
                let devices = await deviceRegistry.discoveredDevices()
                await MainActor.run {
                    self.discoveredDevices = devices
                }
            }
        default:
            break
        }
    }
}
