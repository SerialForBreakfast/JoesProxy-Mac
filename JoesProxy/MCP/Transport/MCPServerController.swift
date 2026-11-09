import Combine
import Foundation

/// AppCoordinator-owned MCP lifecycle controller (production NIO transport).
///
/// Concurrency: `@MainActor` — starts/stops transport and exposes status to the management panel.
@MainActor
final class MCPServerController: ObservableObject {
    enum ServerState: Equatable {
        case stopped
        case starting
        case running(port: UInt16, endpointURL: URL)
        case failed(message: String)
        case degraded(message: String)
    }

    @Published private(set) var state: ServerState = .stopped
    @Published private(set) var recentReadActivityAt: Date?
    @Published private(set) var connectedClientCount: Int = 0
    @Published private(set) var enrolledClients: [MCPClientRecord] = []
    @Published private(set) var operationState: MCPOperationState = .idle
    @Published var isCLIAutomationStartEnabled: Bool {
        didSet {
            userDefaults.set(isCLIAutomationStartEnabled, forKey: Self.cliAutomationStartKey)
        }
    }

    /// Armed (validated + approved, not yet activated) scenario IDs — drives the title-bar
    /// "scenario armed" projection. Sourced from `scenarioLifecycleCoordinator`, never a stored
    /// placeholder (AI-1).
    var armedScenarioIDs: [String] { scenarioLifecycleCoordinator.armedScenarioIDs }

    let policyStore: MCPPolicyStore
    let grantStore: MCPClientGrantStore
    let scenarioStore: MCPScenarioStore
    let responseDraftStore: ResponseDraftStore
    let fixtureRunStore: HLSFixtureRunStore
    let scenarioLifecycleCoordinator: MCPScenarioLifecycleCoordinator
    let clientRegistry: MCPClientRegistry
    let auditStore: MCPAuditStore
    let snapshotService: MCPSessionSnapshotService
    let agentQueries: AgentQueryServices
    let approvalStore: MCPApprovalStore
    private(set) var artifactSources: ArtifactSourceRegistry?

    func configureArtifactSources(_ registry: ArtifactSourceRegistry) {
        artifactSources = registry
        protocolService.configureArtifactSources(registry)
        registry.currentOwner = { [weak self] clientID in
            guard let self, let client = self.clientRegistry.client(id: clientID), client.credentialState == .active,
                  self.policyEvaluator.effectiveAllows(capability: .artifactSourceAccess, client: client) else { return nil }
            return ArtifactSourceRegistry.Owner(clientID: client.id, generation: client.credentialGeneration,
                policyRevision: self.policyStore.policyRevision, profile: client.assignedProfileID)
        }
        registry.currentBriefPermission = { [weak self] clientID in
            guard let self, let client = self.clientRegistry.client(id: clientID) else { return false }
            return self.policyEvaluator.effectiveAllows(capability: .artifactBrief, client: client)
        }
        registry.currentComparePermission = { [weak self] clientID in
            guard let self, let client = self.clientRegistry.client(id: clientID) else { return false }
            return self.policyEvaluator.effectiveAllows(capability: .artifactCompare, client: client)
        }
        registry.currentSearchPermission = { [weak self] clientID in
            guard let self, let client = self.clientRegistry.client(id: clientID) else { return false }
            return self.policyEvaluator.effectiveAllows(capability: .artifactSearch, client: client)
        }
        registry.currentCalculationPermission = { [weak self] clientID in
            guard let self, let client = self.clientRegistry.client(id: clientID) else { return false }
            return self.policyEvaluator.effectiveAllows(capability: .artifactCalculate, client: client)
        }
    }
    let mediaInspectionService: MCPMediaInspectionService
    let operationCoordinator: MCPOperationCoordinator
    let notificationHub: MCPNotificationHub
    let protocolService: MCPProtocolService
    let recoveryCoordinator: MCPRecoveryCoordinator
    private(set) var mutationService: MCPMutationService?
    private(set) var openWorldService: MCPOpenWorldService?
    private(set) var recoveryService: MCPRecoveryService?
    private(set) var destructiveRecoveryService: MCPDestructiveRecoveryService?
    private(set) var scenarioRuntimeService: MCPScenarioRuntimeService?
    private(set) var scenarioService: MCPScenarioService?
    private(set) var hlsFixtureService: MCPHLSFixtureService?
    private(set) var openAPIMockPackService: MCPOpenAPIMockPackService?
    private var openAPIMockPackCoordinator: OpenAPIMockPackCoordinator?
    private(set) var effectBundleService: MCPEffectBundleService?
    private(set) var diagnosticRunService: MCPDiagnosticRunService?
    private(set) var diagnosticRunCoordinator: DiagnosticRunCoordinator?
    private(set) var certificateIdentityService: MCPCertificateIdentityService?
    private(set) var diagnosticInterlockCoordinator: MCPDiagnosticInterlockCoordinator?
    let attentionCoordinator = MCPAttentionCoordinator()
    let clientConnectionTracker = MCPClientConnectionTracker()
    private let systemNotificationCoordinator: MCPSystemNotificationCoordinator?

    var policyEvaluator: MCPPolicyEvaluator {
        MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)
    }

    private var transport: MCPNIOHTTPTransport?
    private let credentialStore: any MCPClientCredentialStoring
    private let port: UInt16
    private let userDefaults: UserDefaults
    private static let cliAutomationStartKey = "mcpCLIAutomationStartEnabled"
    private var approvalObservation: AnyCancellable?
    private var operationObservation: AnyCancellable?
    private var probeStreamObservation: AnyCancellable?

    /// - Parameter grantStore: Capability grants. Tests must pass a temp-backed store; omitting
    ///   this uses Application Support and can mutate the operator grant file on `bootstrap()`.
    init(
        sessionStore: any SessionStore,
        port: UInt16 = NetworkConstants.mcpDefaultPort,
        credentialStore: (any MCPClientCredentialStoring)? = nil,
        policyStore: MCPPolicyStore? = nil,
        grantStore: MCPClientGrantStore? = nil,
        clientRegistry: MCPClientRegistry? = nil,
        auditStore: MCPAuditStore? = nil,
        approvalStore: MCPApprovalStore? = nil,
        artifactWorker: ArtifactAnalysisWorker? = nil,
        recoveryCoordinator: MCPRecoveryCoordinator? = nil,
        bookmarkStore: (any BookmarkStore)? = nil,
        responseOverrideStore: ResponseOverrideStore? = nil,
        proposalCoordinator: MCPProposalCoordinator? = nil,
        mutationService: MCPMutationService? = nil,
        scenarioStore: MCPScenarioStore? = nil,
        responseDraftStore: ResponseDraftStore? = nil,
        collectionMockAuthoringService: CollectionMockAuthoringService? = nil,
        fixtureRunStore: HLSFixtureRunStore? = nil,
        fixtureOriginRegistry: HLSFixtureOriginRegistry? = nil,
        deviceRegistry: DeviceRegistry = .shared,
        systemNotificationCoordinator: MCPSystemNotificationCoordinator? = nil,
        userDefaults: UserDefaults = .standard,
        storageScope: RuntimeStorageScope? = nil
    ) {
        self.port = port
        let resolvedDefaults = storageScope?.defaults ?? userDefaults
        self.userDefaults = resolvedDefaults
        self.systemNotificationCoordinator = systemNotificationCoordinator
        self.isCLIAutomationStartEnabled = resolvedDefaults.bool(forKey: Self.cliAutomationStartKey)
        let resolvedCredentialStore = credentialStore ?? MCPClientCredentialKeychainStore()
        self.credentialStore = resolvedCredentialStore
        self.policyStore = policyStore ?? MCPPolicyStore(persistenceURL: storageScope?.file("mcp-policy.json"))
        self.grantStore = grantStore ?? MCPClientGrantStore(persistenceURL: storageScope?.file("mcp-grants.json"))
        let resolvedScenarioStore = scenarioStore ?? MCPScenarioStore(persistenceURL: storageScope?.file("mcp-scenarios.json"))
        self.scenarioStore = resolvedScenarioStore
        let resolvedResponseDraftStore = responseDraftStore ?? ResponseDraftStore(persistenceURL: storageScope?.file("response-drafts.json"))
        resolvedResponseDraftStore.load()
        self.responseDraftStore = resolvedResponseDraftStore
        let resolvedFixtureRunStore = fixtureRunStore ?? HLSFixtureRunStore(
            persistenceURL: storageScope?.file("fixture-runs.json"),
            profileRootURL: storageScope?.file("FixtureProfiles"),
            originRegistry: fixtureOriginRegistry
        )
        resolvedFixtureRunStore.load()
        self.fixtureRunStore = resolvedFixtureRunStore
        self.scenarioLifecycleCoordinator = MCPScenarioLifecycleCoordinator(store: resolvedScenarioStore)
        self.clientRegistry = clientRegistry ?? MCPClientRegistry(
            persistenceURL: storageScope?.file("mcp-clients.json"), credentialStore: resolvedCredentialStore)
        self.auditStore = auditStore ?? MCPAuditStore(persistenceURL: storageScope?.file("mcp-audit.json"))
        self.approvalStore = approvalStore ?? MCPApprovalStore()
        let resolvedRecoveryCoordinator = recoveryCoordinator ?? MCPRecoveryCoordinator(
            journalStore: MCPEffectJournalStore(persistenceURL: storageScope?.file("effect-journal.json"))
        )
        self.recoveryCoordinator = resolvedRecoveryCoordinator
        let agentQueries = AgentQueryServices(sessionStore: sessionStore)
        self.agentQueries = agentQueries
        let resolvedSnapshotService = agentQueries.snapshots
        let resolvedNotificationHub = MCPNotificationHub(
            sessionStore: sessionStore,
            policyStore: self.policyStore,
            auditStore: self.auditStore,
            snapshotService: resolvedSnapshotService
        )
        let resolvedMediaInspectionService = agentQueries.media
        let resolvedOperationCoordinator = MCPOperationCoordinator(
            sessionStore: sessionStore,
            mediaService: resolvedMediaInspectionService,
            snapshotService: resolvedSnapshotService,
            policyStore: self.policyStore,
            auditStore: self.auditStore,
            notificationHub: resolvedNotificationHub
        )
        self.snapshotService = resolvedSnapshotService
        self.notificationHub = resolvedNotificationHub
        self.mediaInspectionService = resolvedMediaInspectionService
        self.operationCoordinator = resolvedOperationCoordinator
        self.protocolService = MCPProtocolService(
            policyStore: self.policyStore,
            grantStore: self.grantStore,
            clientRegistry: self.clientRegistry,
            auditStore: self.auditStore,
            snapshotService: resolvedSnapshotService,
            approvalStore: self.approvalStore,
            artifactWorker: artifactWorker,
            mediaInspectionService: resolvedMediaInspectionService,
            operationCoordinator: resolvedOperationCoordinator,
            notificationHub: resolvedNotificationHub,
            deviceService: MCPDeviceService(registry: deviceRegistry),
            mutationService: mutationService,
            boundPort: port,
            sessionExportDirectory: storageScope?.file("SessionExports")
        )
        self.mutationService = mutationService
        if mutationService == nil,
           let bookmarkStore,
           let responseOverrideStore,
           let proposalCoordinator {
            let resolvedMutationService = MCPMutationService(
                bookmarkStore: bookmarkStore,
                responseOverrideStore: responseOverrideStore,
                proposalCoordinator: proposalCoordinator,
                recoveryCoordinator: resolvedRecoveryCoordinator,
                approvalStore: self.approvalStore,
                policyStore: self.policyStore,
                grantStore: self.grantStore,
                auditStore: self.auditStore,
                snapshotService: resolvedSnapshotService,
                responseDraftStore: resolvedResponseDraftStore,
                collectionMockAuthoringService: collectionMockAuthoringService
            )
            resolvedMutationService.hlsFixtureRunStore = resolvedFixtureRunStore
            resolvedMutationService.activeScenarioIDsProvider = { [weak self] in
                self?.scenarioLifecycleCoordinator.activeScenarioIDs ?? []
            }
            self.mutationService = resolvedMutationService
            self.protocolService.setMutationService(resolvedMutationService)
        }
        approvalObservation = self.approvalStore.$pendingRequests
            .receive(on: RunLoop.main)
            .sink { [weak self] requests in
                self?.refreshOperationState()
                guard let self else { return }
                self.systemNotificationCoordinator?.handlePendingApprovals(
                    requests,
                    clients: self.clientRegistry.clients
                )
            }
        operationObservation = resolvedOperationCoordinator.$activeAnalysisCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshOperationState()
            }
        probeStreamObservation = resolvedNotificationHub.$liveListenStreamCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshOperationState()
            }
        self.scenarioLifecycleCoordinator.$armedScenarioIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshOperationState()
            }
            .store(in: &cancellables)
        resolvedRecoveryCoordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        refreshOperationState()
        wireSessionEndGrantCleanup()
        wireAuditAttentionObserver()
    }

    private func wireAuditAttentionObserver() {
        auditStore.recordObserver = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleAuditEventForAttention(event)
            }
        }
    }

    private func handleAuditEventForAttention(_ event: MCPAuditEvent) {
        if event.kind == .authenticationFailure {
            systemNotificationCoordinator?.handleAuthenticationBlocked(
                reason: event.reasonCode,
                credentialFingerprint: event.credentialFingerprint
            )
            return
        }
        guard let clientID = event.clientID else { return }
        clientConnectionTracker.noteClientActivity(clientID: clientID, at: event.timestamp)
        switch event.kind {
        case .authenticationSuccess:
            clientConnectionTracker.noteClientConnected(clientID: clientID, at: event.timestamp)
        case .toolCall, .resourceRead:
            if event.reasonCode.contains("body")
                || event.reasonCode.contains("header")
                || event.reasonCode.contains("query") {
                attentionCoordinator.recordSensitiveRead(
                    clientID: clientID,
                    capability: .bodyRead,
                    fieldClass: event.reasonCode
                )
            }
        default:
            break
        }
        if case .policyBlocked(let capability) = event.operatorAttention,
           let client = clientRegistry.client(id: clientID) {
            systemNotificationCoordinator?.handlePolicyBlocked(client: client, capability: capability)
        }
    }

    private func wireSessionEndGrantCleanup() {
        protocolService.setSessionEndHandler { [weak self] clientID in
            self?.grantStore.clearUntilSessionEndGrants(clientID: clientID)
            self?.clientConnectionTracker.noteClientDisconnected(clientID: clientID)
        }
        protocolService.setSessionTerminationHandler { [weak self] clientID in
            guard let self, let recoveryService = self.recoveryService else {
                throw MCPStructuredError(code: .internalFailure, message: "Recovery service unavailable.")
            }
            self.operationCoordinator.cancelOperations(forClientID: clientID)
            return await recoveryService.cleanupClientState(clientID: clientID)
        }
    }

    private var cancellables = Set<AnyCancellable>()

    /// Wires AH-3 mutation tools after ``MCPProposalCoordinator`` is constructed in ``AppCoordinator``.
    func configureMutationService(
        bookmarkStore: any BookmarkStore,
        responseOverrideStore: ResponseOverrideStore,
        proposalCoordinator: MCPProposalCoordinator,
        configuration: any AppConfiguration,
        collectionMockAuthoringService: CollectionMockAuthoringService? = nil
    ) {
        let service = MCPMutationService(
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: auditStore,
            snapshotService: snapshotService,
            responseDraftStore: responseDraftStore,
            collectionMockAuthoringService: collectionMockAuthoringService,
            throttleConfigurationReader: { configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                configuration.networkThrottleConfiguration = updated
            }
        )
        service.hlsFixtureRunStore = fixtureRunStore
        service.activeScenarioIDsProvider = { [weak self] in
            self?.scenarioLifecycleCoordinator.activeScenarioIDs ?? []
        }
        mutationService = service
        protocolService.setMutationService(service)
        Task {
            await service.refreshLiveEffectSummary()
        }
    }

    /// Wires AH-5 open-world tools after mutation service and proposal coordinator are available.
    func configureOpenWorldService(
        bookmarkStore: any BookmarkStore,
        sessionStore: any SessionStore,
        responseOverrideStore: ResponseOverrideStore,
        bookmarkExecutor: any BookmarkExecuting,
        proposalCoordinator: MCPProposalCoordinator,
        configuration: any AppConfiguration,
        runningProxyPort: @escaping () -> UInt16?
    ) {
        let matcher = MCPExecutedSessionMatcher(sessionStore: sessionStore)
        let service = MCPOpenWorldService(
            bookmarkStore: bookmarkStore,
            sessionStore: sessionStore,
            responseOverrideStore: responseOverrideStore,
            bookmarkExecutor: bookmarkExecutor,
            sessionMatcher: matcher,
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            operationCoordinator: operationCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: auditStore,
            runningProxyPort: runningProxyPort,
            throttleConfigurationReader: { configuration.networkThrottleConfiguration }
        )
        openWorldService = service
        protocolService.setOpenWorldService(service)
    }

    /// Wires AH-6 recovery actions after mutation and open-world services are available.
    func configureRecoveryService(
        journalStore: MCPEffectJournalStore,
        bookmarkStore: any BookmarkStore,
        responseOverrideStore: ResponseOverrideStore,
        proposalCoordinator: MCPProposalCoordinator,
        configuration: any AppConfiguration,
        diagnosticRunCoordinator: DiagnosticRunCoordinator? = nil
    ) {
        let restorer = MCPRecoveryRestorer(
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            throttleConfigurationReader: { configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                configuration.networkThrottleConfiguration = updated
            }
        )
        let service = MCPRecoveryService(
            recoveryCoordinator: recoveryCoordinator,
            journalStore: journalStore,
            restorer: restorer,
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            throttleConfigurationReader: { configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                configuration.networkThrottleConfiguration = updated
            },
            approvalStore: approvalStore,
            proposalCoordinator: proposalCoordinator,
            auditStore: auditStore,
            grantStore: grantStore,
            scenarioLifecycleCoordinator: scenarioLifecycleCoordinator,
            drainScenarioCleanups: { [weak self] in
                await self?.drainScenarioCleanups()
            },
            fixtureRunStore: fixtureRunStore,
            openAPIMockPackCoordinator: openAPIMockPackCoordinator,
            diagnosticRunCoordinator: diagnosticRunCoordinator
        )
        recoveryService = service
        destructiveRecoveryService = MCPDestructiveRecoveryService(
            clientRegistry: clientRegistry,
            grantStore: grantStore,
            auditStore: auditStore,
            approvalStore: approvalStore,
            proposalCoordinator: proposalCoordinator,
            recoveryService: service,
            restorer: restorer,
            journalStore: journalStore,
            invalidateSessions: { [weak self] clientID in
                self?.protocolService.invalidateSessions(for: clientID)
            },
            stopServer: { [weak self] in
                await self?.stop()
            }
        )
        protocolService.setRecoveryService(service)
        protocolService.setReturnToNormalHandler { [weak self] in
            guard let self else {
                throw MCPStructuredError(code: .internalFailure, message: "MCP server unavailable.")
            }
            return try await self.returnToNormal(deferServerStop: true)
        }
        diagnosticInterlockCoordinator = MCPDiagnosticInterlockCoordinator(
            recoveryService: service,
            restorer: restorer,
            scenarioLifecycleCoordinator: scenarioLifecycleCoordinator,
            finishScenario: { [weak self] scenarioID, outcome in
                await self?.finishScenario(scenarioID, outcome: outcome)
            }
        )
    }

    /// Wires AI-2 scenario executor/cleanup against real mutation stores.
    func configureScenarioRuntime(
        bookmarkStore: any BookmarkStore,
        responseOverrideStore: ResponseOverrideStore,
        bookmarkExecutor: (any BookmarkExecuting)? = nil,
        configuration: any AppConfiguration,
        runningProxyPort: @escaping () -> UInt16? = { nil }
    ) {
        let restorer = MCPRecoveryRestorer(
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            throttleConfigurationReader: { configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                configuration.networkThrottleConfiguration = updated
            }
        )
        let applicator = MCPScenarioFaultApplicator(
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            bookmarkExecutor: bookmarkExecutor,
            runningProxyPort: runningProxyPort,
            restorer: restorer,
            throttleConfigurationReader: { configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                configuration.networkThrottleConfiguration = updated
            }
        )
        scenarioRuntimeService = MCPScenarioRuntimeService(
            lifecycleCoordinator: scenarioLifecycleCoordinator,
            scenarioStore: scenarioStore,
            recoveryCoordinator: recoveryCoordinator,
            faultApplicator: applicator,
            observationService: MCPScenarioObservationService(
                sessionStore: snapshotService.sourceSessionStore,
                snapshotService: snapshotService,
                policyStore: policyStore,
                scenarioStore: scenarioStore,
                lifecycleCoordinator: scenarioLifecycleCoordinator
            )
        )
        scenarioService = MCPScenarioService(
            lifecycleCoordinator: scenarioLifecycleCoordinator,
            scenarioStore: scenarioStore,
            runtimeServiceProvider: { [weak self] in self?.scenarioRuntimeService },
            policyStore: policyStore,
            grantStore: grantStore,
            approvalStore: approvalStore,
            auditStore: auditStore
        )
        protocolService.setScenarioService(scenarioService!)
    }

    /// Wires HLS fixture lifecycle tools after the shared proposal coordinator exists.
    func configureHLSFixtureService(
        proposalCoordinator: MCPProposalCoordinator,
        sessionStore: (any SessionStore)? = nil,
        substitutionCoordinator: HLSSubstitutionCoordinator? = nil
    ) {
        let service = MCPHLSFixtureService(
            runStore: fixtureRunStore,
            proposalCoordinator: proposalCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: auditStore,
            sessionStore: sessionStore,
            substitutionCoordinator: substitutionCoordinator
        )
        hlsFixtureService = service
        protocolService.setHLSFixtureService(service)
    }

    /// Wires OpenAPI mock-pack preview/propose/apply/status/stop tools.
    func configureOpenAPIMockPackService(
        packCoordinator: OpenAPIMockPackCoordinator,
        proposalCoordinator: MCPProposalCoordinator,
        schemaStore: OpenAPISchemaStore = OpenAPISchemaStore(),
        sessionStore: SessionStore? = nil
    ) {
        let service = MCPOpenAPIMockPackService(
            packCoordinator: packCoordinator,
            proposalCoordinator: proposalCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: auditStore,
            schemaStore: schemaStore,
            sessionStore: sessionStore
        )
        openAPIMockPackCoordinator = packCoordinator
        openAPIMockPackService = service
        protocolService.setOpenAPIMockPackService(service)
    }

    /// Wires Named Effect Bundle lifecycle tools.
    func configureEffectBundleService(
        repository: EffectBundleRepository,
        activationCoordinator: EffectBundleActivationCoordinator,
        proposalCoordinator: MCPProposalCoordinator,
        authoringService: CollectionMockAuthoringService? = nil,
        sessionStore: (any SessionStore)? = nil,
        admissionSnapshot: @escaping () -> CaptureAdmissionBudget.Snapshot? = { nil }
    ) {
        let service = MCPEffectBundleService(
            repository: repository,
            activationCoordinator: activationCoordinator,
            proposalCoordinator: proposalCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: auditStore,
            authoringService: authoringService,
            sessionStore: sessionStore,
            admissionSnapshot: admissionSnapshot
        )
        effectBundleService = service
        protocolService.setEffectBundleService(service)
    }

    /// Wires composite diagnostic-run create/start/status/observations/close/re-check tools (AN-6).
    func configureDiagnosticRunService(
        runCoordinator: DiagnosticRunCoordinator,
        recheckService: DiagnosticRunRegressionRecheckService,
        proposalCoordinator: MCPProposalCoordinator
    ) {
        let service = MCPDiagnosticRunService(
            runCoordinator: runCoordinator,
            recheckService: recheckService,
            proposalCoordinator: proposalCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: auditStore,
            systemNotificationCoordinator: systemNotificationCoordinator
        )
        diagnosticRunCoordinator = runCoordinator
        diagnosticRunService = service
        protocolService.setDiagnosticRunService(service)
    }

    /// Wires certificate identity/cleanup tools.
    ///
    /// The metadata and distribution stores must be the same instances ``ProxyViewModel`` holds —
    /// both sides persist by rewriting the whole sidecar, so a second copy would revert the other's
    /// edits on its next write.
    func configureCertificateIdentityService(
        configuration: AppConfiguration,
        certificateStore: any CertificateStore,
        trustInstaller: any TrustInstalling,
        metadataStore: CAInstanceMetadataStore,
        distributionStore: CertificateDistributionRecordStore,
        proposalCoordinator: MCPProposalCoordinator
    ) {
        // Fingerprint-scoped removal is not part of `TrustInstalling`; fall back to a Keychain-backed
        // installer when the injected one (e.g. a test double) cannot do it.
        let trustCleaner = (trustInstaller as? any CertificateFingerprintTrustCleaning)
            ?? PersistentTrustInstaller(certificateStore: certificateStore)
        let service = MCPCertificateIdentityService(
            configuration: configuration,
            certificateStore: certificateStore,
            trustInstaller: trustInstaller,
            trustCleaner: trustCleaner,
            metadataStore: metadataStore,
            distributionStore: distributionStore,
            proposalCoordinator: proposalCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: auditStore
        )
        certificateIdentityService = service
        protocolService.setCertificateIdentityService(service)
    }

    private func drainScenarioCleanups() async {
        await scenarioRuntimeService?.drainPendingCleanups()
    }

    func stopServerOnly() async {
        await stop()
    }

    @discardableResult
    func disableMCPCreatedEffects() async throws -> MCPRecoverySummary {
        guard let recoveryService else {
            throw MCPStructuredError(code: .internalFailure, message: "Recovery service unavailable.")
        }
        return await recoveryService.disableMCPCreatedEffects()
    }

    @discardableResult
    func returnToNormal(deferServerStop: Bool = false) async throws -> MCPRecoverySummary {
        guard let recoveryService else {
            throw MCPStructuredError(code: .internalFailure, message: "Recovery service unavailable.")
        }
        return await recoveryService.returnToNormal(
            stopServer: { [weak self] in
                guard let self else { return }
                if deferServerStop {
                    Task { await self.stop() }
                } else {
                    await self.stop()
                }
            },
            isServerRunning: { [weak self] in
                guard let self else { return false }
                if case .running = self.state { return true }
                return false
            }
        )
    }

    /// Forces every MCP-origin traffic-mutation effect (rules, bookmarks, throttle overrides,
    /// scenario state) back to a clean slate at app launch, while leaving clients, bearer tokens,
    /// durable/persistent grants, capability policy, and audit history untouched. No-op if the
    /// recovery stack hasn't been wired yet (`configureRecoveryService` not yet called).
    func enforceFreshLaunchMCPState() async {
        guard let recoveryService, let destructiveRecoveryService else { return }
        await recoveryService.prepareForFreshLaunchTeardown()
        let deleted = (try? await destructiveRecoveryService.deleteAllMCPOriginObjects().deletedEffectCount) ?? 0
        await recoveryService.refreshEffectSummaryPublic()
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .freshLaunchReset,
                timestamp: Date(),
                clientID: nil,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "app_launch",
                detail: "deleted=\(deleted)"
            )
        )
    }

    func detachMCPEffect(itemID: String) async throws {
        guard let recoveryService else {
            throw MCPStructuredError(code: .internalFailure, message: "Recovery service unavailable.")
        }
        try await recoveryService.detachEffect(itemID: itemID)
    }

    func restoreMCPEffect(itemID: String) async throws {
        guard let recoveryService else {
            throw MCPStructuredError(code: .internalFailure, message: "Recovery service unavailable.")
        }
        try await recoveryService.restoreEffect(itemID: itemID)
    }

    func disableMCPEffect(itemID: String) async throws {
        guard let recoveryService else {
            throw MCPStructuredError(code: .internalFailure, message: "Recovery service unavailable.")
        }
        try await recoveryService.disableEffect(itemID: itemID)
    }

    func resolveMCPEffectConflict(
        transactionID: String,
        resolution: MCPRecoveryConflictResolution
    ) async throws {
        guard let recoveryService else {
            throw MCPStructuredError(code: .internalFailure, message: "Recovery service unavailable.")
        }
        try await recoveryService.resolveConflict(
            transactionID: transactionID,
            resolution: resolution
        )
    }

    var pendingApprovals: [MCPApprovalRequest] {
        approvalStore.pendingRequests
    }

    func refreshPendingApprovals() {
        approvalStore.pruneExpired()
        refreshOperationState()
    }

    func bootstrap() {
        let startedAt = Date()
        policyStore.load()
        grantStore.load()
        try? clientRegistry.load()
        auditStore.load()
        recoveryCoordinator.bootstrap()
        scenarioLifecycleCoordinator.bootstrap()
        Task { await self.drainScenarioCleanups() }
        if !policyStore.isLoaded {
            let reason = policyStore.loadFailureReason ?? "Policy store failed to load."
            MCPLog.lifecycle.error("MCP degraded: \(reason, privacy: .public)")
            state = .degraded(message: reason)
        }
        if !auditStore.allowsSensitiveReads {
            let reason = auditStore.persistenceFailureReason ?? "Audit store unavailable."
            MCPLog.lifecycle.error("MCP degraded: \(reason, privacy: .public)")
            state = .degraded(message: reason)
        }
        refreshClients()
        refreshOperationState()
        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        MCPLog.lifecycle.info(
            "MCP bootstrap completed in \(elapsedMilliseconds, privacy: .public) ms"
        )
    }

    private func refreshClients() {
        enrolledClients = clientRegistry.clients
    }

    private func refreshOperationState() {
        let approvalCount = approvalStore.pendingCount
        let sensitiveReadCount = approvalStore.pendingRequests.filter {
            $0.capability.riskTier == .sensitiveReadTool
        }.count
        let analysisCount = operationCoordinator.activeAnalysisCount
        let probeCount = notificationHub.liveListenStreamCount
        let armed = armedScenarioIDs
        if approvalCount > 0 || analysisCount > 0 || probeCount > 0 || !armed.isEmpty {
            operationState = .active(
                MCPOperationSummary(
                    pendingApprovalCount: approvalCount,
                    sensitiveReadCount: sensitiveReadCount,
                    liveProbeCount: probeCount,
                    analysisCount: analysisCount,
                    armedScenarioIDs: armed
                )
            )
        } else {
            operationState = .idle
        }
    }

    /// Seeds deterministic MCP title-bar state for UI automation.
#if !AGW4_AGENT_TARGET
    func applyUITestMCPStatusFixture(_ fixture: UITestLaunchConfiguration.MCPStatusFixture) {
        switch fixture {
        case .runningClean:
            let endpointURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
            state = .running(port: port, endpointURL: endpointURL)
        case .offActive:
            recoveryCoordinator.testSetEffectState(
                .active(.init(createdRuleCount: 1, changedRuleCount: 0, throttleChanged: false, activeScenarioIDs: []))
            )
        case .approvals:
            let endpointURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
            state = .running(port: port, endpointURL: endpointURL)
            if ArtifactSourceUITestFixture.seed(controller: self) {
                refreshOperationState()
                return
            }
            _ = approvalStore.createPendingRequest(
                clientID: "coding-assistant",
                capability: .createDisabledBlock,
                argumentDigest: "block:api.example.com:503",
                policyRevision: policyStore.policyRevision,
                reason: "Simulate upstream 503 Service Unavailable for retry logic validation on api.example.com"
            )
            refreshOperationState()
        case .conflict:
            let endpointURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
            state = .running(port: port, endpointURL: endpointURL)
            recoveryCoordinator.testSetEffectState(
                .conflict([
                    MCPEffectConflictItem(
                        id: "ui-test-conflict",
                        kind: .block,
                        message: "UI test recovery conflict",
                        targetID: "ui-test-target"
                    )
                ])
            )
        }
    }
#endif

    var mcpPipelineStatus: MCPPipelineStatus {
        MCPStatusProjection.pipelineStatus(
            controllerState: state,
            connectedClientCount: connectedClientCount,
            effect: recoveryCoordinator.effectState,
            operation: operationState,
            mcpPort: port
        )
    }

    /// Menu and management-panel Start MCP affordance.
    var canStartMCP: Bool {
        if case .stopped = state { return true }
        return false
    }

    /// Menu and management-panel Stop MCP affordance.
    var canStopMCP: Bool {
        if case .stopped = state { return false }
        return true
    }

    func start() async {
        guard case .stopped = state else { return }
        bootstrap()
        guard policyStore.isLoaded, auditStore.allowsSensitiveReads else {
            state = .degraded(message: "MCP reads denied until policy and audit stores are healthy.")
            return
        }
        state = .starting
        MCPLog.lifecycle.info("Starting MCP server on port \(self.port, privacy: .public).")
        let transport = MCPNIOHTTPTransport(protocolService: protocolService)
        do {
            try await transport.start(port: port)
            self.transport = transport
            protocolService.rebindLoopbackPort(port)
            let endpointURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
            state = .running(port: port, endpointURL: endpointURL)
        } catch let error as MCPNIOHTTPTransport.TransportError {
            switch error {
            case .bindFailed(let message):
                MCPLog.lifecycle.error("MCP server failed to start: \(message, privacy: .public)")
                state = .failed(message: message)
            case .alreadyRunning, .notRunning:
                MCPLog.lifecycle.error("MCP server failed to start: \(String(describing: error), privacy: .public)")
                state = .failed(message: String(describing: error))
            }
        } catch {
            MCPLog.lifecycle.error("MCP server failed to start: \(error.localizedDescription, privacy: .public)")
            state = .failed(message: error.localizedDescription)
        }
    }

    @discardableResult
    func startFromCLI() async -> Bool {
        guard isCLIAutomationStartEnabled else {
            MCPLog.lifecycle.notice("Ignored CLI MCP start request because automation startup is disabled.")
            return false
        }
        await start()
        if case .running = state { return true }
        return false
    }

    func stop() async {
        MCPLog.lifecycle.info("Stopping MCP server.")
        operationCoordinator.cancelAll()
        scenarioLifecycleCoordinator.cancelAllScenarios()
        await drainScenarioCleanups()
        await notificationHub.closeAllWriters()
        approvalStore.invalidateAllPending()
        mutationService?.invalidateTransientState()
        protocolService.invalidateResponseEditState()
        await transport?.shutdown(waitForInFlight: true, protocolService: protocolService)
        await auditStore.flush()
        transport = nil
        state = .stopped
        connectedClientCount = 0
        refreshOperationState()
    }

    func refreshStatus() {
        connectedClientCount = protocolService.connectedClientIDs.count
    }

    // MARK: - Scenario lifecycle (AI-1 controller API; MCP tools in AI-4)

    @discardableResult
    func createScenarioDraft(_ draft: MCPScenarioDraftInput) throws -> MCPScenarioRecord {
        try scenarioLifecycleCoordinator.createDraft(from: draft)
    }

    @discardableResult
    func validateScenario(_ scenarioID: MCPScenarioID) throws -> MCPScenarioValidationResultDTO {
        try scenarioLifecycleCoordinator.validate(scenarioID: scenarioID)
    }

    @discardableResult
    func approveScenario(_ scenarioID: MCPScenarioID) throws -> MCPScenarioRecord {
        try scenarioLifecycleCoordinator.approve(scenarioID: scenarioID)
    }

    func activateScenario(_ scenarioID: MCPScenarioID) async throws {
        guard let scenarioRuntimeService else {
            throw MCPStructuredError(code: .internalFailure, message: "Scenario runtime unavailable.")
        }
        try await scenarioRuntimeService.activateScenario(scenarioID)
    }

    @discardableResult
    func evaluateScenario(_ scenarioID: MCPScenarioID) throws -> MCPScenarioEvaluationResultDTO {
        guard let scenarioRuntimeService else {
            throw MCPStructuredError(code: .internalFailure, message: "Scenario runtime unavailable.")
        }
        return try scenarioRuntimeService.evaluateScenario(scenarioID)
    }

    func finishScenario(_ scenarioID: MCPScenarioID, outcome: MCPScenarioPhase? = nil) async {
        await scenarioRuntimeService?.finishScenario(scenarioID, outcome: outcome)
    }

    func recordReadActivity() {
        recentReadActivityAt = Date()
        refreshStatus()
    }

    func enrollClient(displayName: String, profileID: MCPDisclosureProfileID = .metadataOnly) throws -> MCPClientRegistry.EnrollmentResult {
        let result = try clientRegistry.enroll(displayName: displayName, assignedProfileID: profileID)
        MCPLog.clients.info("Enrolled client \(result.client.id, privacy: .public) (\(profileID.rawValue, privacy: .public)).")
        refreshClients()
        return result
    }

    func rotateClient(clientID: String) throws -> MCPClientRegistry.EnrollmentResult {
        let result = try clientRegistry.rotateCredential(clientID: clientID)
        protocolService.invalidateSessions(for: clientID)
        mutationService?.invalidateTransientState(clientID: clientID)
        protocolService.invalidateResponseEditState(clientID: clientID)
        approvalStore.prunePending(for: clientID)
        operationCoordinator.cancelOperations(forClientID: clientID)
        scenarioLifecycleCoordinator.cancelScenarios(forClientID: clientID)
        MCPLog.clients.info("Rotated credential for client \(clientID, privacy: .public).")
        refreshClients()
        refreshOperationState()
        return result
    }

    func revokeClient(clientID: String) throws {
        try clientRegistry.revoke(clientID: clientID)
        protocolService.invalidateSessions(for: clientID)
        mutationService?.invalidateTransientState(clientID: clientID)
        protocolService.invalidateResponseEditState(clientID: clientID)
        grantStore.clearUntilSessionEndGrants(clientID: clientID)
        approvalStore.prunePending(for: clientID)
        operationCoordinator.cancelOperations(forClientID: clientID)
        scenarioLifecycleCoordinator.cancelScenarios(forClientID: clientID)
        MCPLog.clients.info("Revoked client \(clientID, privacy: .public).")
        refreshClients()
        refreshOperationState()
    }

    /// Removes one or more enrolled clients from the registry and clears their grants.
    ///
    /// Concurrency: `@MainActor` — invalidates live MCP sessions before deleting persistence.
    func removeClients(clientIDs: Set<String>) throws {
        guard !clientIDs.isEmpty else { return }
        for clientID in clientIDs {
            protocolService.invalidateSessions(for: clientID)
            grantStore.clearGrantsAndDenials(clientID: clientID)
            approvalStore.prunePending(for: clientID)
            operationCoordinator.cancelOperations(forClientID: clientID)
            scenarioLifecycleCoordinator.cancelScenarios(forClientID: clientID)
        }
        try clientRegistry.remove(clientIDs: clientIDs)
        MCPLog.clients.info("Removed \(clientIDs.count, privacy: .public) enrolled client(s).")
        refreshClients()
        refreshOperationState()
    }

    func revokeAllClients() async throws -> MCPDestructiveRecoverySummary {
        guard let destructiveRecoveryService else {
            throw MCPStructuredError(code: .internalFailure, message: "Destructive recovery unavailable.")
        }
        let summary = try await destructiveRecoveryService.revokeAllClients()
        refreshClients()
        refreshOperationState()
        return summary
    }

    func resetMCPConfiguration() async throws -> MCPDestructiveRecoverySummary {
        guard let destructiveRecoveryService else {
            throw MCPStructuredError(code: .internalFailure, message: "Destructive recovery unavailable.")
        }
        let summary = try await destructiveRecoveryService.resetMCPConfiguration(isServerRunning: { [weak self] in
            guard let self else { return false }
            if case .running = self.state { return true }
            return false
        })
        refreshClients()
        refreshOperationState()
        return summary
    }

    func deleteAllMCPOriginObjects() async throws -> MCPDestructiveRecoverySummary {
        guard let destructiveRecoveryService else {
            throw MCPStructuredError(code: .internalFailure, message: "Destructive recovery unavailable.")
        }
        return try await destructiveRecoveryService.deleteAllMCPOriginObjects()
    }

    func deleteMCPEffect(itemID: String) async throws {
        guard let destructiveRecoveryService else {
            throw MCPStructuredError(code: .internalFailure, message: "Destructive recovery unavailable.")
        }
        try await destructiveRecoveryService.deleteEffect(itemID: itemID)
    }

    func eraseAuditHistory() async throws -> MCPDestructiveRecoverySummary {
        guard let destructiveRecoveryService else {
            throw MCPStructuredError(code: .internalFailure, message: "Destructive recovery unavailable.")
        }
        return await destructiveRecoveryService.eraseAuditHistory()
    }

    func resolvePending(requestID: String, resolution: MCPApprovalResolution) throws -> MCPApprovalAuthorization? {
        guard let request = approvalStore.pendingRequest(requestID: requestID) else {
            throw MCPApprovalStoreError.requestNotFound
        }
        if request.capability.requiresOneUseApproval {
            switch resolution {
            case .untilSessionEnd, .untilDate, .durablePolicy:
                throw MCPStructuredError(code: .policyDenied, message: "Persistent HTTPS rule changes require Allow Once for the exact reviewed change.")
            default: break
            }
        }
        switch resolution {
        case .allowOnce:
            if request.capability == .artifactCompare {
                throw MCPStructuredError(code: .policyDenied, message: "Review both saved responses and choose Compare once.")
            }
            guard request.capability != .artifactSourceAccess else {
                throw MCPStructuredError(code: .policyDenied, message: "Select a source and use Share snapshot after reviewing its exact scope.")
            }
            let authorization = try approvalStore.approve(requestID: requestID)
            refreshOperationState()
            return authorization
        case .untilSessionEnd:
            try grantStore.addGrant(
                clientID: request.clientID,
                capability: request.capability,
                mode: .untilSessionEnd,
                grantedByRequestID: request.requestID
            )
            auditStore.record(grantAudit(kind: .grantAdded, capability: request.capability, clientID: request.clientID, detail: "until_session_end"))
            // Also approve the call that triggered this prompt — the grant only covers *future*
            // calls; without this, the client's in-flight request still fails and must be retried.
            let authorization = try approvalStore.approve(requestID: requestID)
            refreshOperationState()
            return authorization
        case .untilDate(let date):
            try grantStore.addGrant(
                clientID: request.clientID,
                capability: request.capability,
                mode: .untilDate,
                expiresAt: date,
                grantedByRequestID: request.requestID
            )
            auditStore.record(grantAudit(kind: .grantAdded, capability: request.capability, clientID: request.clientID, detail: "until_date"))
            let authorization = try approvalStore.approve(requestID: requestID)
            refreshOperationState()
            return authorization
        case .durablePolicy:
            try grantStore.addGrant(
                clientID: request.clientID,
                capability: request.capability,
                mode: .durablePolicy,
                grantedByRequestID: request.requestID
            )
            auditStore.record(grantAudit(kind: .grantAdded, capability: request.capability, clientID: request.clientID, detail: "durable_policy"))
            let authorization = try approvalStore.approve(requestID: requestID)
            refreshOperationState()
            return authorization
        case .denyOnce:
            try approvalStore.deny(requestID: requestID)
            refreshOperationState()
            return nil
        case .alwaysDeny:
            _ = grantStore.addDenial(clientID: request.clientID, capability: request.capability)
            auditStore.record(grantAudit(kind: .alwaysDenied, capability: request.capability, clientID: request.clientID, detail: nil))
            try approvalStore.deny(requestID: requestID)
            refreshOperationState()
            return nil
        }
    }

    func revokeGrant(id: UUID) throws {
        let grant = grantStore.grants.first { $0.id == id }
        try grantStore.removeGrant(id: id)
        if let grant {
            auditStore.record(grantAudit(kind: .grantRemoved, capability: grant.capability, clientID: grant.clientID, detail: nil))
        }
    }

    private func grantAudit(
        kind: MCPAuditEventKind,
        capability: MCPCapabilityID,
        clientID: String,
        detail: String?
    ) -> MCPAuditEvent {
        MCPAuditEvent(
            id: UUID(),
            kind: kind,
            timestamp: Date(),
            clientID: clientID,
            credentialFingerprint: nil,
            sourceProcess: nil,
            reasonCode: capability.rawValue,
            detail: detail
        )
    }

    func approvePending(requestID: String) throws -> MCPApprovalAuthorization {
        try resolvePending(requestID: requestID, resolution: .allowOnce)!
    }

    func denyPending(requestID: String) throws {
        try approvalStore.deny(requestID: requestID)
        refreshOperationState()
    }
}
