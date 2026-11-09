import Foundation
import SwiftUI

@MainActor
final class AppCoordinator {
    let httpsProxyMode: HTTPSProxyMode
    let configuration: AppConfiguration
    let proxyRuntime: any ProxyRuntime
    let agentRuntimeControls: AgentRuntimeControls
    let agentCaptureHealthMonitor: AgentCaptureHealthMonitor
    let agentSetupReadinessMonitor: AgentSetupReadinessMonitor
    let agentSetupRecoveryController: AgentSetupRecoveryController
    let agentEffectsMonitor: AgentEffectsMonitor
    let sessionStore: any SessionStore
#if !AGW4_AGENT_TARGET
    private var mediaInspectionIndexStorage: MediaInspectionIndex?
#endif
    let deviceRegistry: DeviceRegistry
    let certificateStore: any CertificateStore
    let certificateAuthority: any CertificateAuthorityProviding
    let trustInstaller: any TrustInstalling
    let exportService: any ExportService
    let bookmarkStore: any BookmarkStore
    let bookmarkExecutor: any BookmarkExecuting
    let iosDeviceTrustProfileExporter: any IOSDeviceTrustProfileExporting
    let responseOverrideStore: ResponseOverrideStore
    let bookmarkResponseInterceptStore: BookmarkResponseInterceptStore
    /// Reserved-virtual-origin dispatch target for active HLS fixture runs (see
    /// `HLSFixtureOriginRegistry`) — empty, and therefore inert, until a fixture-run lifecycle
    /// store registers a run here.
    let fixtureOriginRegistry: HLSFixtureOriginRegistry
    let hlsSubstitutionCoordinator: HLSSubstitutionCoordinator
    private let effectBundleSleepObserver: EffectBundleSleepObserver
    let openAPIMockPackCoordinator: OpenAPIMockPackCoordinator
    /// App-owned diagnostic-run coordination object (AN-2 / AN-3).
    let diagnosticRunCoordinator: DiagnosticRunCoordinator
    let diagnosticRunObservationIndex: DiagnosticRunObservationIndex
    let diagnosticRunCaptureBridge: DiagnosticRunCaptureBridge
    let sessionRecorder: ProxySessionRecorder
#if !AGW4_AGENT_TARGET
    private let inspectorViewModelFactory: () -> ProxyViewModel
    private var inspectorViewModelStorage: ProxyViewModel?
    private var inspectorPreferences: ProxyViewModel.WorkspacePreferences?
    private let inspectorPresentationRelay: InspectorPresentationRelay
#endif
    private let suppressesLaunchRecoveryOffers: Bool
    private var responseOverrideLoadingTask: Task<Void, Never>?
    private var sharedServicesBootstrapped = false
    let simulatorSetupViewModel: SimulatorSetupViewModel
    let systemProxyController: SystemProxyController
    let systemProxyRoutingModel: SystemProxyRoutingModel
    let mcpServerController: MCPServerController
    let mcpSystemNotificationCoordinator: MCPSystemNotificationCoordinator
    let captureMarkerService: CaptureMarkerService
    let rollingCapturePersistence: RollingCapturePersistenceCoordinator
    let agentCaptureRecoveryController: AgentCaptureRecoveryController
    let agentCaptureExportController: AgentCaptureExportController
    let mcpEffectJournalStore: MCPEffectJournalStore
    let mcpRecoveryCoordinator: MCPRecoveryCoordinator
    let mcpProposalCoordinator: MCPProposalCoordinator
    let selfValidationCoordinator: MCPSelfValidationCoordinator
    let captureTransportDiagnostics: CaptureTransportDiagnostics
    let responsivenessMonitor: ResponsivenessMonitor?
    let previousRunDiagnosticsCoordinator: PreviousRunDiagnosticsCoordinator
    let uploadSpoolService: UploadSpoolService
    let compactModeController: CompactModeController
    let sessionStartCoordinator: SessionStartCoordinator
    let collectionMockAuthoringService: CollectionMockAuthoringService
    let mockIconSuggestionService: any MockIconSuggesting
    let similarItemTextGenerator: any SimilarItemTextGenerating
    /// Shared, app-owned revision and worker coordinator for live collection mocks.
    let liveCollectionTransformationExecutor: LiveCollectionTransformationExecutor

    /// The Inspector graph is constructed only when a caller explicitly requests it. Shared
    /// runtime/MCP paths must use the typed owners above instead of accessing this property.
#if !AGW4_AGENT_TARGET
    var viewModel: ProxyViewModel {
        if let inspectorViewModelStorage {
            return inspectorViewModelStorage
        }
        let viewModel = inspectorViewModelFactory()
        if let inspectorPreferences { viewModel.restoreWorkspacePreferences(inspectorPreferences) }
        viewModel.rollingCapturePersistence = rollingCapturePersistence
        viewModel.previousRunDiagnosticsCoordinator = previousRunDiagnosticsCoordinator
        rollingCapturePersistence.onPersistenceError = { [weak viewModel] message in
            viewModel?.rollingCapturePersistenceError = message
        }
        if !suppressesLaunchRecoveryOffers {
            viewModel.evaluateRollingCaptureRestoreOffer()
        }
        viewModel.setInspectorPresentationActive(!compactModeController.isCompactModeActive)
        inspectorViewModelStorage = viewModel
        return viewModel
    }

    var isInspectorViewModelConstructed: Bool { inspectorViewModelStorage != nil }

    @discardableResult
    func releaseInspector() -> String? {
        if let blocker = inspectorViewModelStorage?.agentTransitionBlocker { return blocker }
        if let inspector = inspectorViewModelStorage {
            inspectorPreferences = inspector.workspacePreferences
            inspector.suspendForAgentWorkspace()
        }
        inspectorPresentationRelay.viewModel = nil
        inspectorViewModelStorage = nil
        mediaInspectionIndexStorage = nil
        return nil
    }
#endif

    /// Media browsing is an Inspector-only projection over retained sessions. It deliberately
    /// remains absent from Agent startup because it owns a store subscription and a bounded
    /// related-capture cache that no supervision route needs.
#if !AGW4_AGENT_TARGET
    var mediaInspectionIndex: MediaInspectionIndex {
        if let mediaInspectionIndexStorage {
            return mediaInspectionIndexStorage
        }
        let index = MediaInspectionIndex(store: sessionStore)
        mediaInspectionIndexStorage = index
        return index
    }

    var isMediaInspectionIndexConstructed: Bool { mediaInspectionIndexStorage != nil }
#endif

    /// Loads persisted mutation rules before startup reconciliation without constructing the
    /// Inspector. The operation is shared and idempotent for normal and Agent launches.
    func loadInitialResponseOverrides() async {
        if responseOverrideLoadingTask == nil {
            let responseOverrideStore = self.responseOverrideStore
            let configuration = self.configuration
            responseOverrideLoadingTask = Task {
                try? await responseOverrideStore.loadPersistedData(configuration.responseOverridesData)
            }
        }
        await responseOverrideLoadingTask?.value
    }

    /// Content-free, last-known facts for previous-run diagnostics. Counts and states only.
    func previousRunOperatingContext(workspace: LaunchWorkspacePreference?) -> PreviousRunOperatingContext {
        let mcpRunning: Bool
        if case .running = mcpServerController.state { mcpRunning = true } else { mcpRunning = false }
        return PreviousRunOperatingContext(
            observedAt: Date(),
            workspace: compactModeController.isCompactModeActive ? "compact" : workspace?.rawValue,
            retainedRequestCount: sessionStore.sessions.count,
            mcpRunning: mcpRunning,
            pendingApprovalCount: mcpServerController.approvalStore.pendingCount,
            checkpoint: rollingCapturePersistence.lastStatus)
    }

    /// The executable entry points share startup reconciliation. UI fixtures may explicitly
    /// preserve their seeded status, but normal launches never restore previously active effects.
    func bootstrapSharedServices(preserveSeededStatus: Bool = false) {
        guard !sharedServicesBootstrapped else { return }
        sharedServicesBootstrapped = true
        mcpServerController.bootstrap()
        Task { @MainActor [weak self] in
            await self?.diagnosticRunCoordinator.bootstrap()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !preserveSeededStatus else { return }
            await loadInitialResponseOverrides()
            await mcpServerController.enforceFreshLaunchMCPState()
#if !AGW4_AGENT_TARGET
            await refreshConstructedInspectorAfterMCPFreshLaunchPurge()
#endif
        }
    }

    /// Refreshes an already-visible Inspector after startup reconciliation without turning a
    /// background Agent launch into an implicit presentation-model construction.
#if !AGW4_AGENT_TARGET
    func refreshConstructedInspectorAfterMCPFreshLaunchPurge() async {
        await inspectorViewModelStorage?.reloadStateAfterMCPFreshLaunchPurge()
    }
#endif

    init(
        collectionMockAuthoringService: CollectionMockAuthoringService? = nil,
        configuration: AppConfiguration? = nil,
        proxyRuntime: (any ProxyRuntime)? = nil,
        sessionStore: (any SessionStore)? = nil,
        certificateStore: (any CertificateStore)? = nil,
        certificateAuthority: (any CertificateAuthorityProviding)? = nil,
        trustInstaller: (any TrustInstalling)? = nil,
        exportService: (any ExportService)? = nil,
        bookmarkStore: (any BookmarkStore)? = nil,
        bookmarkExecutor: (any BookmarkExecuting)? = nil,
        systemProxyController: SystemProxyController? = nil,
        setupVerificationState: AgentSetupVerificationState? = nil,
        localNetworkInfoProvider: any LocalNetworkInfoProviding = SystemLocalNetworkInfoProvider(),
        mcpCredentialStore: (any MCPClientCredentialStoring)? = nil,
        mcpSystemNotificationCoordinator: MCPSystemNotificationCoordinator? = nil,
        captureTransportDiagnostics: CaptureTransportDiagnostics? = nil,
        suppressesLaunchRecoveryOffers: Bool = false,
        recoveryStorageAccessEnabled: Bool = true,
        storageScope: RuntimeStorageScope? = nil,
        hlsFixtureProfileRoot: URL? = nil
    ) {
        let resolvedConfiguration = configuration ?? UserDefaultsAppConfiguration(userDefaults: storageScope?.defaults ?? .standard)
        let resolvedCaptureTransportDiagnostics = captureTransportDiagnostics ?? CaptureTransportDiagnostics()
        let diagnosticsDirectory = storageScope?.file("Diagnostics") ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JoesProxy/Diagnostics", isDirectory: true)
        // Unscoped unit and UI-test processes never write previous-run history to the user's Application Support.
        let persistsPreviousRunDiagnostics = storageScope != nil
            || (NSClassFromString("XCTestCase") == nil && UITestLaunchConfiguration.current == nil)
        let previousRunStore = diagnosticsDirectory.flatMap { root in
            persistsPreviousRunDiagnostics
                ? PreviousRunDiagnosticsStore(
                    directory: root.appendingPathComponent("PreviousRun", isDirectory: true),
                    incidentDirectory: root,
                    transport: resolvedCaptureTransportDiagnostics)
                : nil
        }
        let resolvedDiagnosticsCoordinator = PreviousRunDiagnosticsCoordinator(
            store: previousRunStore,
            isEnabled: { resolvedConfiguration.previousRunDiagnosticsEnabled })
        self.previousRunDiagnosticsCoordinator = resolvedDiagnosticsCoordinator
        self.responsivenessMonitor = diagnosticsDirectory.map { root in
            ResponsivenessMonitor(diagnostics: resolvedCaptureTransportDiagnostics,
                store: ResponsivenessIncidentStore(directory: root),
                appVersion: Bundle.main.marketingVersionOrDev,
                runID: resolvedDiagnosticsCoordinator.runID)
        }
        let resolvedSessionStore = sessionStore ?? InMemorySessionStore(
            retentionPolicy: resolvedConfiguration.captureRetentionPolicy
        )
        let resolvedSessionRecorder = ProxySessionRecorder(sessionStore: resolvedSessionStore)
        resolvedCaptureTransportDiagnostics.observeAdmission(resolvedSessionRecorder.admission)
        let resolvedDeviceRegistry = DeviceRegistry(aliasStore: storageScope.map {
            DeviceAliasStore(defaults: $0.defaults)
        } ?? .shared)
        let resolvedCertificateStore = certificateStore ?? PersistentKeychainCertificateStore()
        let resolvedCertificateAuthority = certificateAuthority ?? PersistentCertificateAuthorityProvider(
            configuration: resolvedConfiguration,
            certificateStore: resolvedCertificateStore,
            transportDiagnostics: resolvedCaptureTransportDiagnostics
        )
        let resolvedTrustInstaller = trustInstaller ?? PersistentTrustInstaller(certificateStore: resolvedCertificateStore)
        // Single instances shared by the view model and the MCP certificate tools: both persist by
        // rewriting the whole JSON sidecar, so two in-memory copies would clobber each other.
        let resolvedCAInstanceMetadataStore = CAInstanceMetadataStore(persistenceURL: storageScope?.file("ca-metadata.json"))
        resolvedCAInstanceMetadataStore.load()
        let resolvedCertificateDistributionRecordStore = CertificateDistributionRecordStore(persistenceURL: storageScope?.file("certificate-distribution.json"))
        resolvedCertificateDistributionRecordStore.load()
        let resolvedCertificateStatusReader: (any CertificateStatusReading)? =
            certificateStore == nil && certificateAuthority == nil && trustInstaller == nil
            ? PersistentCertificateStatusReader(label: resolvedConfiguration.certificateLabel)
            : nil
        let resolvedProfileSnapshotStore = storageScope.map {
            ProfileSnapshotStore(fileURL: $0.file("ProfileSnapshots.json"))
        } ?? ProfileSnapshotStore.defaultStore()
        let resolvedExportService = exportService ?? JSONSessionExportService()
        let resolvedBookmarkStore = bookmarkStore ?? UserDefaultsBookmarkStore(userDefaults: storageScope?.defaults ?? .standard)
        let resolvedBookmarkExecutor = bookmarkExecutor ?? URLSessionBookmarkExecutor()
        let resolvedHARExportService = HARSessionExportService()
        let resolvedIOSDeviceTrustProfileExporter = IOSDeviceTrustProfileExporter(
            configuration: resolvedConfiguration,
            certificateAuthority: resolvedCertificateAuthority
        )
        let resolvedLiveCollectionTransformationExecutor = LiveCollectionTransformationExecutor()
        let resolvedResponseOverrideStore = ResponseOverrideStore(
            liveCollectionTransformationExecutor: resolvedLiveCollectionTransformationExecutor
        )
        let resolvedBookmarkResponseInterceptStore = BookmarkResponseInterceptStore()
        let resolvedFixtureOriginRegistry = HLSFixtureOriginRegistry()
        let resolvedHLSSubstitutionRouteStore = HLSSubstitutionRouteStore()
        let resolvedOpenAPIMockRouteStore = OpenAPIMockRouteStore()
        let resolvedHLSFixtureRunStore = HLSFixtureRunStore(
            persistenceURL: storageScope?.file("fixture-runs.json"),
            profileRootURL: hlsFixtureProfileRoot ?? storageScope?.file("FixtureProfiles"),
            originRegistry: resolvedFixtureOriginRegistry)
        resolvedHLSFixtureRunStore.load()
        let resolvedHLSSubstitutionCoordinator = HLSSubstitutionCoordinator(
            runStore: resolvedHLSFixtureRunStore,
            routeStore: resolvedHLSSubstitutionRouteStore,
            responseOverrideStore: resolvedResponseOverrideStore,
            persistenceURL: storageScope?.file("hls-substitutions.json")
        )
        let resolvedOpenAPIMockPackCoordinator = OpenAPIMockPackCoordinator(
            routeStore: resolvedOpenAPIMockRouteStore,
            responseOverrideStore: resolvedResponseOverrideStore,
            persistenceURL: storageScope?.file("mock-packs.json")
        )
        let resolvedEffectBundleRepository = EffectBundleRepository(
            persistenceURL: storageScope?.file("effect-bundles.json"),
            packagesRootURL: storageScope?.file("EffectBundles"))
        let resolvedEffectBundleActivationCoordinator = EffectBundleActivationCoordinator(
            repository: resolvedEffectBundleRepository,
            responseOverrideStore: resolvedResponseOverrideStore,
            hlsCoordinator: resolvedHLSSubstitutionCoordinator
        )
        self.effectBundleSleepObserver = EffectBundleSleepObserver(coordinator: resolvedEffectBundleActivationCoordinator)
        let resolvedOpenAPISchemaStore = OpenAPISchemaStore()
        let resolvedDiagnosticRunStore = DiagnosticRunStore(persistenceURL: storageScope?.file("diagnostic-runs.json"))
        let resolvedDiagnosticRunObservationIndex = DiagnosticRunObservationIndex()
        let resolvedDiagnosticRunWatchInstaller = DiagnosticRunObservationWatchInstaller(
            index: resolvedDiagnosticRunObservationIndex,
            sessionStore: resolvedSessionStore,
            effectScopeResolver: OverrideRuleEffectScopeResolver(store: resolvedResponseOverrideStore)
        )
        let resolvedDiagnosticRunCoordinator = DiagnosticRunCoordinator(
            store: resolvedDiagnosticRunStore,
            watchInstaller: resolvedDiagnosticRunWatchInstaller,
            observationIndex: resolvedDiagnosticRunObservationIndex,
            policyRevisionProvider: { .initial }
        )
        let resolvedSystemProxyController = systemProxyController ?? SystemProxyController(
            stateStore: UserDefaultsSystemProxyStateStore(userDefaults: storageScope?.defaults ?? .standard))
        let resolvedUploadSpoolService = UploadSpoolService(directory: storageScope?.file("UploadSpool") ?? UploadSpoolService.applicationDirectory)
        self.uploadSpoolService = resolvedUploadSpoolService
        let resolvedHTTPSProxyMode: HTTPSProxyMode = .intercepting
        let resolvedSDKEventServer = SDKEventServer(sessionStore: resolvedSessionStore)
        let resolvedProxyRuntime = proxyRuntime ?? DefaultProxyRuntime(
            configuration: resolvedConfiguration,
            server: ProxyServer(
                port: resolvedConfiguration.proxyPort,
                httpsProxyMode: resolvedHTTPSProxyMode,
                configuration: resolvedConfiguration,
                certificateAuthority: resolvedCertificateAuthority,
                sessionRecorder: resolvedSessionRecorder,
                responseOverrideStore: resolvedResponseOverrideStore,
                bookmarkResponseInterceptStore: resolvedBookmarkResponseInterceptStore,
                fixtureOriginRegistry: resolvedFixtureOriginRegistry,
                hlsSubstitutionRouteStore: resolvedHLSSubstitutionRouteStore,
                openAPIMockRouteStore: resolvedOpenAPIMockRouteStore,
                transportDiagnostics: resolvedCaptureTransportDiagnostics,
                uploadSpoolService: resolvedUploadSpoolService,
                liveCollectionTransformationExecutor: resolvedLiveCollectionTransformationExecutor
            ),
            sdkEventServer: resolvedSDKEventServer
        )

        let resolvedCollectionMockAuthoringService = collectionMockAuthoringService ?? CollectionMockAuthoringService()
#if !AGW4_AGENT_TARGET
        let resolvedInspectorPresentationRelay = InspectorPresentationRelay()
#endif
        self.httpsProxyMode = resolvedHTTPSProxyMode
        self.collectionMockAuthoringService = resolvedCollectionMockAuthoringService
        let mockInferenceGate = LocalMockInferenceGate()
        let resolvedIconSuggestionService = MockIconSuggestionUITestFixture.makeService(gate: mockInferenceGate)
        let resolvedSimilarTextGenerator = SimilarItemTextUITestFixture.makeService(gate: mockInferenceGate)
        self.similarItemTextGenerator = resolvedSimilarTextGenerator
        self.mockIconSuggestionService = resolvedIconSuggestionService
        self.liveCollectionTransformationExecutor = resolvedLiveCollectionTransformationExecutor
#if !AGW4_AGENT_TARGET
        self.inspectorPresentationRelay = resolvedInspectorPresentationRelay
#endif
        self.suppressesLaunchRecoveryOffers = suppressesLaunchRecoveryOffers
        self.configuration = resolvedConfiguration
        self.proxyRuntime = resolvedProxyRuntime
        self.agentRuntimeControls = AgentRuntimeControls(proxyRuntime: resolvedProxyRuntime)
        self.agentCaptureHealthMonitor = AgentCaptureHealthMonitor(
            sessionStore: resolvedSessionStore,
            proxyRuntime: resolvedProxyRuntime
        )
        self.agentSetupReadinessMonitor = AgentSetupReadinessMonitor(
            configuration: resolvedConfiguration,
            proxyRuntime: resolvedProxyRuntime,
            sessionStore: resolvedSessionStore,
            certificateAuthority: resolvedCertificateAuthority,
            trustInstaller: resolvedTrustInstaller,
            certificateStatusReader: resolvedCertificateStatusReader,
            profileSnapshotStore: resolvedProfileSnapshotStore,
            localNetworkInfoProvider: localNetworkInfoProvider
        )
        let readinessMonitor = self.agentSetupReadinessMonitor
        self.agentSetupRecoveryController = AgentSetupRecoveryController(
            read: { await readinessMonitor.readinessState() },
            install: {
                let identity = try resolvedCertificateAuthority.loadOrCreateRootCertificate()
                try resolvedTrustInstaller.install(identity)
            }
        )
        self.agentEffectsMonitor = AgentEffectsMonitor(
            configuration: resolvedConfiguration,
            responseOverrideStore: resolvedResponseOverrideStore,
            bookmarkStore: resolvedBookmarkStore,
            hlsSubstitutionCoordinator: resolvedHLSSubstitutionCoordinator,
            openAPIMockPackCoordinator: resolvedOpenAPIMockPackCoordinator,
            systemProxyController: resolvedSystemProxyController
        )
        self.sessionStore = resolvedSessionStore
        self.deviceRegistry = resolvedDeviceRegistry
        self.certificateStore = resolvedCertificateStore
        self.certificateAuthority = resolvedCertificateAuthority
        self.trustInstaller = resolvedTrustInstaller
        self.exportService = resolvedExportService
        self.bookmarkStore = resolvedBookmarkStore
        self.bookmarkExecutor = resolvedBookmarkExecutor
        self.iosDeviceTrustProfileExporter = resolvedIOSDeviceTrustProfileExporter
        self.responseOverrideStore = resolvedResponseOverrideStore
        self.bookmarkResponseInterceptStore = resolvedBookmarkResponseInterceptStore
        self.fixtureOriginRegistry = resolvedFixtureOriginRegistry
        self.hlsSubstitutionCoordinator = resolvedHLSSubstitutionCoordinator
        self.openAPIMockPackCoordinator = resolvedOpenAPIMockPackCoordinator
        self.diagnosticRunCoordinator = resolvedDiagnosticRunCoordinator
        resolvedDiagnosticRunCoordinator.configureExperiments(repository: resolvedEffectBundleRepository,
            bundles: resolvedEffectBundleActivationCoordinator,
            admission: { resolvedCaptureTransportDiagnostics.snapshot().captureAdmission })
        resolvedEffectBundleActivationCoordinator.diagnosticRuns = resolvedDiagnosticRunCoordinator
        self.diagnosticRunObservationIndex = resolvedDiagnosticRunObservationIndex
        self.sessionRecorder = resolvedSessionRecorder
        self.captureTransportDiagnostics = resolvedCaptureTransportDiagnostics
#if !AGW4_AGENT_TARGET
        self.inspectorViewModelFactory = {
            AgentWorkspaceDiagnostics.shared.recordInspectorModelConstruction()
            let viewModel = ProxyViewModel(
                configuration: resolvedConfiguration,
                httpsProxyMode: resolvedHTTPSProxyMode,
                proxyRuntime: resolvedProxyRuntime,
                sessionStore: resolvedSessionStore,
                exportService: resolvedExportService,
                bookmarkStore: resolvedBookmarkStore,
                bookmarkExecutor: resolvedBookmarkExecutor,
                harExportService: resolvedHARExportService,
                iosDeviceTrustProfileExporter: resolvedIOSDeviceTrustProfileExporter,
                responseOverrideStore: resolvedResponseOverrideStore,
                bookmarkResponseInterceptStore: resolvedBookmarkResponseInterceptStore,
                hlsSubstitutionCoordinator: resolvedHLSSubstitutionCoordinator,
                openAPIMockPackCoordinator: resolvedOpenAPIMockPackCoordinator,
                openAPISchemaStore: resolvedOpenAPISchemaStore,
                certificateAuthority: resolvedCertificateAuthority,
                certificateStore: resolvedCertificateStore,
                trustInstaller: resolvedTrustInstaller,
                certificateStatusReader: resolvedCertificateStatusReader,
                caInstanceMetadataStore: resolvedCAInstanceMetadataStore,
                certificateDistributionRecordStore: resolvedCertificateDistributionRecordStore,
                loadsPersistedResponseOverrides: false,
                systemProxyController: resolvedSystemProxyController,
                setupVerificationState: setupVerificationState,
                localNetworkInfoProvider: localNetworkInfoProvider,
                profileSnapshotStore: resolvedProfileSnapshotStore,
                captureTransportDiagnostics: resolvedCaptureTransportDiagnostics,
                deviceRegistry: resolvedDeviceRegistry,
                effectBundleRepository: resolvedEffectBundleRepository,
                effectBundleCoordinator: resolvedEffectBundleActivationCoordinator,
                collectionMockAuthoringService: resolvedCollectionMockAuthoringService,
                mockIconSuggestionService: resolvedIconSuggestionService,
                similarItemTextGenerator: resolvedSimilarTextGenerator
            )
            resolvedInspectorPresentationRelay.viewModel = viewModel
            return viewModel
        }
#endif
        self.systemProxyController = resolvedSystemProxyController
        self.systemProxyRoutingModel = SystemProxyRoutingModel(configuration: resolvedConfiguration)
        let resolvedMCPEffectJournalStore = MCPEffectJournalStore(persistenceURL: storageScope?.file("effect-journal.json"))
        let resolvedMCPRecoveryCoordinator = MCPRecoveryCoordinator(journalStore: resolvedMCPEffectJournalStore)
        let resolvedMCPSystemNotificationCoordinator = mcpSystemNotificationCoordinator
            ?? MCPSystemNotificationCoordinator(configuration: resolvedConfiguration)
        self.mcpEffectJournalStore = resolvedMCPEffectJournalStore
        self.mcpRecoveryCoordinator = resolvedMCPRecoveryCoordinator
        self.mcpSystemNotificationCoordinator = resolvedMCPSystemNotificationCoordinator
        let artifactWorker = ArtifactAnalysisWorker()
        let resolvedMCPServerController = MCPServerController(
            sessionStore: resolvedSessionStore,
            credentialStore: mcpCredentialStore,
            artifactWorker: artifactWorker,
            recoveryCoordinator: resolvedMCPRecoveryCoordinator,
            bookmarkStore: resolvedBookmarkStore,
            responseOverrideStore: resolvedResponseOverrideStore,
            fixtureRunStore: resolvedHLSFixtureRunStore,
            fixtureOriginRegistry: resolvedFixtureOriginRegistry,
            deviceRegistry: resolvedDeviceRegistry,
            systemNotificationCoordinator: resolvedMCPSystemNotificationCoordinator,
            userDefaults: storageScope?.defaults ?? .standard,
            storageScope: storageScope
        )
        self.mcpServerController = resolvedMCPServerController
        let artifactSources = ArtifactSourceRegistry(worker: artifactWorker,
            approvals: resolvedMCPServerController.approvalStore, fileCoordinator: ArtifactSourceUITestFixture.fileCoordinator())
        resolvedMCPServerController.configureArtifactSources(artifactSources)
        let resolvedCaptureMarkerService = CaptureMarkerService(sessionStore: resolvedSessionStore)
        let resolvedRollingCapturePersistence = RollingCapturePersistenceCoordinator(
            sessionStore: resolvedSessionStore,
            configuration: resolvedConfiguration,
            exportService: resolvedExportService as? JSONSessionExportService ?? JSONSessionExportService(),
            proxyPortProvider: { resolvedConfiguration.proxyPort },
            storageDirectoryOverride: storageScope?.file("RollingCapture"),
            storageAccessEnabled: recoveryStorageAccessEnabled
        )
        self.captureMarkerService = resolvedCaptureMarkerService
        self.rollingCapturePersistence = resolvedRollingCapturePersistence
        self.agentCaptureRecoveryController = AgentCaptureRecoveryController(
            sessionStore: resolvedSessionStore,
            persistence: resolvedRollingCapturePersistence,
            diagnosticsCoordinator: resolvedDiagnosticsCoordinator
        )
        self.agentCaptureExportController = AgentCaptureExportController(
            sessionStore: resolvedSessionStore,
            configuration: resolvedConfiguration
        )
        resolvedMCPServerController.snapshotService.configureMarkerService(resolvedCaptureMarkerService)
        resolvedDiagnosticRunWatchInstaller.snapshotService = resolvedMCPServerController.snapshotService
        self.diagnosticRunCaptureBridge = DiagnosticRunCaptureBridge(
            sessionStore: resolvedSessionStore,
            snapshotService: resolvedMCPServerController.snapshotService,
            index: resolvedDiagnosticRunObservationIndex,
            coordinator: resolvedDiagnosticRunCoordinator
        )
        resolvedMCPServerController.protocolService.configureCaptureEvidenceServices(
            markerService: resolvedCaptureMarkerService,
            rollingCaptureStatusProvider: { resolvedRollingCapturePersistence.lastStatus },
            rollingCaptureRestoreHandler: { [weak agentCaptureRecoveryController = self.agentCaptureRecoveryController] in
                guard let agentCaptureRecoveryController else {
                    throw RollingCaptureRestoreError.noSnapshot
                }
                let sessionCount = try await agentCaptureRecoveryController.restoreLatestCapture()
                return [
                    "state": "restored",
                    "sessionCount": sessionCount,
                    "captureEpochReason": "capture_restored"
                ]
            }
        )
        let resolvedMCPProposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: resolvedMCPRecoveryCoordinator,
            policyRevisionProvider: { [weak resolvedMCPServerController] in
                resolvedMCPServerController?.policyStore.policyRevision ?? .initial
            }
        )
        self.mcpProposalCoordinator = resolvedMCPProposalCoordinator
        self.selfValidationCoordinator = MCPSelfValidationCoordinator()
        resolvedMCPServerController.configureMutationService(
            bookmarkStore: resolvedBookmarkStore,
            responseOverrideStore: resolvedResponseOverrideStore,
            proposalCoordinator: resolvedMCPProposalCoordinator,
            configuration: resolvedConfiguration,
            collectionMockAuthoringService: self.collectionMockAuthoringService
        )
        resolvedMCPServerController.configureOpenWorldService(
            bookmarkStore: resolvedBookmarkStore,
            sessionStore: resolvedSessionStore,
            responseOverrideStore: resolvedResponseOverrideStore,
            bookmarkExecutor: resolvedBookmarkExecutor,
            proposalCoordinator: resolvedMCPProposalCoordinator,
            configuration: resolvedConfiguration,
            runningProxyPort: { [weak resolvedProxyRuntime] in
                if case .running(let port) = resolvedProxyRuntime?.currentState {
                    return port
                }
                return nil
            }
        )
        resolvedMCPServerController.configureScenarioRuntime(
            bookmarkStore: resolvedBookmarkStore,
            responseOverrideStore: resolvedResponseOverrideStore,
            bookmarkExecutor: resolvedBookmarkExecutor,
            configuration: resolvedConfiguration,
            runningProxyPort: { [weak resolvedProxyRuntime] in
                if case .running(let port) = resolvedProxyRuntime?.currentState {
                    return port
                }
                return nil
            }
        )
        resolvedMCPServerController.configureHLSFixtureService(
            proposalCoordinator: resolvedMCPProposalCoordinator,
            sessionStore: resolvedSessionStore,
            substitutionCoordinator: resolvedHLSSubstitutionCoordinator
        )
        resolvedMCPServerController.configureOpenAPIMockPackService(
            packCoordinator: resolvedOpenAPIMockPackCoordinator,
            proposalCoordinator: resolvedMCPProposalCoordinator,
            schemaStore: resolvedOpenAPISchemaStore,
            sessionStore: resolvedSessionStore
        )
        resolvedMCPServerController.configureEffectBundleService(
            repository: resolvedEffectBundleRepository,
            activationCoordinator: resolvedEffectBundleActivationCoordinator,
            proposalCoordinator: resolvedMCPProposalCoordinator,
            authoringService: self.collectionMockAuthoringService,
            sessionStore: resolvedSessionStore,
            admissionSnapshot: { resolvedCaptureTransportDiagnostics.snapshot().captureAdmission }
        )
        let diagnosticRunRecheckService = DiagnosticRunRegressionRecheckService(
            store: resolvedDiagnosticRunStore,
            effectResolver: nil,
            effectRecreator: nil,
            captureHistory: MCPSessionSnapshotCaptureHistory(snapshotService: resolvedMCPServerController.snapshotService),
            policyRevisionProvider: { .initial }
        )
        resolvedMCPServerController.configureDiagnosticRunService(
            runCoordinator: resolvedDiagnosticRunCoordinator,
            recheckService: diagnosticRunRecheckService,
            proposalCoordinator: resolvedMCPProposalCoordinator
        )
        resolvedMCPServerController.configureCertificateIdentityService(
            configuration: resolvedConfiguration,
            certificateStore: resolvedCertificateStore,
            trustInstaller: resolvedTrustInstaller,
            metadataStore: resolvedCAInstanceMetadataStore,
            distributionStore: resolvedCertificateDistributionRecordStore,
            proposalCoordinator: resolvedMCPProposalCoordinator
        )
        resolvedMCPServerController.configureRecoveryService(
            journalStore: resolvedMCPEffectJournalStore,
            bookmarkStore: resolvedBookmarkStore,
            responseOverrideStore: resolvedResponseOverrideStore,
            proposalCoordinator: resolvedMCPProposalCoordinator,
            configuration: resolvedConfiguration,
            diagnosticRunCoordinator: resolvedDiagnosticRunCoordinator
        )
        resolvedMCPServerController.protocolService.setCaptureStatusProvider {
            [resolvedProxyRuntime, resolvedConfiguration, resolvedSessionRecorder, resolvedSessionStore] in
            MCPCaptureStatusDTO(proxyState: resolvedProxyRuntime.currentState.accessibilityRuntimeValue,
                admission: resolvedSessionRecorder.admission.snapshot,
                perResponseByteLimit: resolvedConfiguration.liveCaptureBodySizeLimit,
                retainedBodyByteLimit: resolvedSessionStore.retentionPolicy.bodyByteLimit)
        }
        resolvedMCPServerController.protocolService.configureHTTPSRules(globalMode: resolvedHTTPSProxyMode,
            recoveryURL: persistsPreviousRunDiagnostics ? diagnosticsDirectory?.appendingPathComponent("HTTPSRecovery.json") : nil, reader: { [resolvedConfiguration] in
            TLSInterceptionRules(bypassDomains: resolvedConfiguration.httpsBypassDomains,
                                 interceptDomains: resolvedConfiguration.httpsInterceptDomains)
        }, writer: { [resolvedConfiguration] rules in
            resolvedConfiguration.httpsBypassDomains = rules.bypassDomains
            resolvedConfiguration.httpsInterceptDomains = rules.interceptDomains
        })
        resolvedMCPServerController.protocolService.setTransportEvidenceProvider { [resolvedCaptureTransportDiagnostics] id in
            resolvedCaptureTransportDiagnostics.evidence(for: id)
        }
        resolvedMCPServerController.protocolService.setRuntimeControlHandler {
            [weak resolvedProxyRuntime, weak resolvedMCPServerController, weak resolvedConfiguration] action in
            guard let resolvedProxyRuntime, let resolvedMCPServerController else {
                throw MCPStructuredError(code: .internalFailure, message: "Runtime control is unavailable.")
            }
            try MCPRuntimeControlSafetyPolicy.validateRemoteAction(
                action,
                systemProxyManagementEnabled: resolvedConfiguration?.isSystemProxyManagementEnabled ?? false
            )
            switch action {
            case .startProxy, .resumeCapture:
                await resolvedProxyRuntime.start()
                switch resolvedProxyRuntime.currentState {
                case .running(let port):
                    return ["action": action.rawValue, "state": "running", "proxyPort": Int(port)]
                case .failed(let message):
                    throw MCPStructuredError(code: .internalFailure, message: message)
                default:
                    return ["action": action.rawValue, "state": "not_running"]
                }
            case .stopProxy:
                await resolvedProxyRuntime.stop()
                return ["action": action.rawValue, "state": "stopped"]
            case .stopMCP:
                guard case .clean = resolvedMCPServerController.recoveryCoordinator.effectState,
                      case .idle = resolvedMCPServerController.operationState else {
                    throw MCPStructuredError(
                        code: .policyDenied,
                        message: "MCP cannot stop while effects, approvals, scenarios, or operations still require attention."
                    )
                }
                Task { @MainActor [weak resolvedMCPServerController] in
                    try? await Task.sleep(for: .milliseconds(250))
                    await resolvedMCPServerController?.stop()
                }
                return [
                    "action": action.rawValue,
                    "state": "shutdown_scheduled",
                    "cleanupVerified": true
                ]
            }
        }
        resolvedMCPServerController.protocolService.setManagedRuntimeStatusProvider {
            [weak resolvedProxyRuntime, weak resolvedMCPServerController] in
            guard let resolvedProxyRuntime, let resolvedMCPServerController else {
                return MCPManagedRuntimeHostStatusDTO(
                    appState: "unavailable",
                    cliAutomationStartEnabled: false,
                    proxyState: "unavailable",
                    proxyPort: nil
                )
            }
            let proxyState: String
            let proxyPort: Int?
            switch resolvedProxyRuntime.currentState {
            case .stopped:
                proxyState = "stopped"
                proxyPort = nil
            case .starting(let port):
                proxyState = "starting"
                proxyPort = Int(port)
            case .running(let port):
                proxyState = "running"
                proxyPort = Int(port)
            case .stopping:
                proxyState = "stopping"
                proxyPort = nil
            case .failed:
                proxyState = "failed"
                proxyPort = nil
            }
            return MCPManagedRuntimeHostStatusDTO(
                appState: "running",
                cliAutomationStartEnabled: resolvedMCPServerController.isCLIAutomationStartEnabled,
                proxyState: proxyState,
                proxyPort: proxyPort,
                systemProxyManagementEnabled: resolvedConfiguration.isSystemProxyManagementEnabled
            )
        }
        resolvedMCPServerController.protocolService.setSetupReadinessProvider {
            [weak resolvedProxyRuntime, weak resolvedMCPServerController,
             weak agentSetupReadinessMonitor = self.agentSetupReadinessMonitor]
            target, credentialState in
            guard let resolvedProxyRuntime,
                  let resolvedMCPServerController,
                  let agentSetupReadinessMonitor else {
                return MCPSetupReadinessDTO(
                    schemaVersion: MCPSetupReadinessDTO.schemaVersion,
                    target: target,
                    state: "unavailable",
                    checks: [MCPSetupReadinessCheckDTO(
                        id: "host.app",
                        state: .notObservable,
                        detail: "JoesProxy setup state is unavailable.",
                        evidence: nil,
                        actor: .app,
                        nextHumanAction: "Open JoesProxy and retry setup readiness.",
                        confidenceBoundary: "The app instance that owned this MCP session is no longer available."
                    )],
                    recommendedNextActions: ["Open JoesProxy and retry setup readiness."],
                    remoteTrustNotObservable: true
                )
            }
            let proxyState: String
            let proxyPort: Int?
            switch resolvedProxyRuntime.currentState {
            case .stopped:
                proxyState = "stopped"
                proxyPort = nil
            case .starting(let port):
                proxyState = "starting"
                proxyPort = Int(port)
            case .running(let port):
                proxyState = "running"
                proxyPort = Int(port)
            case .stopping:
                proxyState = "stopping"
                proxyPort = nil
            case .failed:
                proxyState = "failed"
                proxyPort = nil
            }
            let host = MCPManagedRuntimeHostStatusDTO(
                appState: "running",
                cliAutomationStartEnabled: resolvedMCPServerController.isCLIAutomationStartEnabled,
                proxyState: proxyState,
                proxyPort: proxyPort,
                systemProxyManagementEnabled: resolvedConfiguration.isSystemProxyManagementEnabled
            )
            return MCPSetupReadinessBuilder.make(
                target: target,
                host: host,
                credentialState: credentialState,
                readinessState: await agentSetupReadinessMonitor.readinessState()
            )
        }
        self.simulatorSetupViewModel = SimulatorSetupViewModel(
            proxyPort: resolvedConfiguration.proxyPort,
            discoveryService: SimulatorDiscoveryService(),
            certificateInstaller: SimulatorCertificateInstaller(
                certificateAuthority: resolvedCertificateAuthority
            ),
            verificationService: SimulatorVerificationService(
                sessionStore: resolvedSessionStore
            ),
            certificateAuthority: resolvedCertificateAuthority,
            configuration: resolvedConfiguration
        )

        let resolvedRoutingModel = self.systemProxyRoutingModel
        let monitoringViewModel = MinimalMonitoringViewModel(
            captureHealthProvider: { [weak agentCaptureHealthMonitor = self.agentCaptureHealthMonitor] in
                agentCaptureHealthMonitor?.health ?? .empty
            },
            transportSnapshotProvider: { [weak resolvedCaptureTransportDiagnostics] in
                resolvedCaptureTransportDiagnostics?.snapshot() ?? .empty
            },
            proxyStatusProvider: { [weak resolvedSystemProxyController, weak resolvedRoutingModel, weak agentRuntimeControls = self.agentRuntimeControls] in
                MinimalMonitoringProxyStatus.describe(
                    controllerStatus: resolvedSystemProxyController?.status ?? .inactive,
                    hasPendingRecovery: resolvedSystemProxyController?.pendingRecovery != nil,
                    isRoutingEnabled: resolvedRoutingModel?.isRoutingEnabled ?? false,
                    isProxyRunning: agentRuntimeControls?.isRunning ?? false
                )
            },
            pendingApprovalCountProvider: { [weak resolvedMCPServerController] in
                resolvedMCPServerController?.approvalStore.pendingCount ?? 0
            },
            activeEffectsProvider: { [weak agentEffectsMonitor = self.agentEffectsMonitor] in
                agentEffectsMonitor?.snapshot ?? .empty
            },
            refreshActiveEffects: { [weak agentEffectsMonitor = self.agentEffectsMonitor] in
                agentEffectsMonitor?.requestRefresh()
            },
            // Reuses MainTitleBarFormatter's exact title/icon/tint logic — the same functions the
            // full toolbar's proxy button calls — so the compact view's buttons are visually
            // identical, not a second approximation of the same design.
            controlsStateProvider: { [weak agentRuntimeControls = self.agentRuntimeControls, weak resolvedMCPServerController] in
                let proxyState = agentRuntimeControls?.proxyState ?? .stopped
                let canStartProxy = agentRuntimeControls?.canStart ?? false
                // Record semantics, matching the toolbar exactly: the button reads red while
                // actively capturing, not the neutral "running" tint.
                let isProxyCapturing: Bool
                if case .running = proxyState {
                    isProxyCapturing = true
                } else {
                    isProxyCapturing = false
                }
                let proxyTint: Color = isProxyCapturing ? .red : AgentRuntimeFormatter.runtimeTint(for: proxyState)

                let mcpState = resolvedMCPServerController?.state ?? .stopped
                let isMCPRunning: Bool
                let mcpTint: Color
                switch mcpState {
                case .running:
                    isMCPRunning = true
                    mcpTint = .green
                case .starting, .degraded:
                    isMCPRunning = false
                    mcpTint = .orange
                case .failed:
                    isMCPRunning = false
                    mcpTint = .red
                case .stopped:
                    isMCPRunning = false
                    mcpTint = .secondary
                }
                let canStartMCP = resolvedMCPServerController?.canStartMCP ?? false

                return MinimalMonitoringControlsState(
                    isProxyRunning: agentRuntimeControls?.isRunning ?? false,
                    canStartProxy: canStartProxy,
                    canStopProxy: agentRuntimeControls?.canStop ?? false,
                    // "Proxy"/"MCP" suffixes are deliberate here even though the full toolbar's
                    // button just says "Start"/"Stop" — there the adjacent status pill already
                    // says what it's for, but the compact view's two buttons sit side by side
                    // with only color to tell them apart otherwise.
                    proxyButtonTitle: "\(AgentRuntimeFormatter.buttonTitle(state: proxyState, canStart: canStartProxy)) Proxy",
                    proxyButtonIcon: AgentRuntimeFormatter.buttonIcon(canStart: canStartProxy),
                    proxyButtonTint: proxyTint,
                    isMCPRunning: isMCPRunning,
                    canStartMCP: canStartMCP,
                    canStopMCP: resolvedMCPServerController?.canStopMCP ?? false,
                    mcpButtonTitle: "\(canStartMCP ? "Start" : "Stop") MCP",
                    mcpButtonIcon: AgentRuntimeFormatter.buttonIcon(canStart: canStartMCP),
                    mcpButtonTint: mcpTint,
                    isProxyTransitioning: proxyState.isTransitioning
                )
            },
            startProxyAction: { [weak agentRuntimeControls = self.agentRuntimeControls] in
                agentRuntimeControls?.start()
            },
            stopProxyAction: { [weak agentRuntimeControls = self.agentRuntimeControls] in
                agentRuntimeControls?.stop()
            },
            startMCPAction: { [weak resolvedMCPServerController] in
                Task { await resolvedMCPServerController?.start() }
            },
            stopMCPAction: { [weak resolvedMCPServerController] in
                Task { await resolvedMCPServerController?.stop() }
            }
        )
        let onInspectorPresentationChanged: (Bool) -> Void
#if !AGW4_AGENT_TARGET
        onInspectorPresentationChanged = { [weak resolvedInspectorPresentationRelay] active in
            resolvedInspectorPresentationRelay?.setInspectorPresentationActive(active)
        }
#else
        onInspectorPresentationChanged = { _ in }
#endif
        self.compactModeController = CompactModeController(
            monitoringViewModel: monitoringViewModel,
            configuration: resolvedConfiguration,
            onInspectorPresentationChanged: onInspectorPresentationChanged
        )
        self.sessionStartCoordinator = SessionStartCoordinator(
            configuration: resolvedConfiguration
        )

        if !suppressesLaunchRecoveryOffers {
            resolvedSystemProxyController.recoverIfNeeded()
        }
    }

}

#if !AGW4_AGENT_TARGET
@MainActor
private final class InspectorPresentationRelay {
    weak var viewModel: ProxyViewModel?

    func setInspectorPresentationActive(_ isActive: Bool) {
        viewModel?.setInspectorPresentationActive(isActive)
    }
}
#endif
