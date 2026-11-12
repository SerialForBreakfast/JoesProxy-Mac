import Foundation

/// Production MCP JSON-RPC handler extracted from AG-0 spike semantics.
///
/// Concurrency: `@MainActor` because it reads policy, audit, and session state from main-actor stores.
@MainActor
final class MCPProtocolService {
    @MainActor final class RequestContext {
        let headers: [String: String]
        let remoteAddress: String?
        let isConnected: @Sendable () -> Bool
        var finalPairCheck: (() -> MCPHTTPResponse?)?

        init(headers: [String: String], remoteAddress: String?, isConnected: @escaping @Sendable () -> Bool = { true }) {
            self.headers = headers
            self.remoteAddress = remoteAddress
            self.isConnected = isConnected
        }
    }

    struct ResourceReadResult: Equatable, Sendable {
        var uri: String
        var mimeType: String
        var text: String
    }

    enum SSEListenResult: Equatable {
        case accepted(key: MCPLogicalSessionKey)
        case rejected(response: MCPHTTPResponse)
    }

    private let policyStore: MCPPolicyStore
    private let grantStore: MCPClientGrantStore
    private let policyEvaluator: MCPPolicyEvaluator
    private let clientRegistry: MCPClientRegistry
    private let auditStore: MCPAuditStore
    private let snapshotService: MCPSessionSnapshotService
    private let disclosureSerializer: MCPDisclosureSerializer
    private let evidenceReferenceStore = MCPEvidenceReferenceStore()
    private let briefReadCache = MCPBriefReadCache()
    /// Content-free work counter for repeat-read regression measurements; process lifetime only.
    private(set) var briefAnalysisExecutionCount = 0
    private let approvalStore: MCPApprovalStore
    private let artifactWorker: ArtifactAnalysisWorker
    private var artifactSources: ArtifactSourceRegistry?

    func configureArtifactSources(_ registry: ArtifactSourceRegistry) { artifactSources = registry }
    private let mediaInspectionService: MCPMediaInspectionService
    private let agenticService: MCPAgenticService
    private let llmInspectionService: MCPLLMInspectionService
    private let concurrencyFuzzingService: MCPConcurrencyFuzzingService
    private let resilienceService: MCPResilienceService
    private let trajectoryService: MCPTrajectoryService
    private let semanticMockService: MCPSemanticMockService
    private let contractDiffService: MCPContractDiffService
    private let dataLineageService: MCPDataLineageService
    private let localizationMockService: MCPLocalizationMockService
    private let statefulMockService: MCPStatefulMockService
    private let faultBisectionService: MCPFaultBisectionService
    private let syntheticInjectionService: MCPSyntheticInjectionService
    private let responseEditService: MCPResponseEditService
    private let operationCoordinator: MCPOperationCoordinator
    private let deviceService: MCPDeviceService
    private let notificationHub: MCPNotificationHub?
    private var mutationService: MCPMutationService?
    private var openWorldService: MCPOpenWorldService?
    private var scenarioService: MCPScenarioService?
    private var hlsFixtureService: MCPHLSFixtureService?
    private var openAPIMockPackService: MCPOpenAPIMockPackService?
    private var diagnosticRunService: MCPDiagnosticRunService?
    private var certificateIdentityService: MCPCertificateIdentityService?
    private var recoveryService: MCPRecoveryService?
    private var returnToNormalHandler: (() async throws -> MCPRecoverySummary)?
    private var runtimeControlHandler: ((MCPRuntimeControlAction) async throws -> [String: Any])?
    private var captureStatusProvider: (() -> MCPCaptureStatusDTO)?
    private var transportEvidenceProvider: ((UUID) -> RequestTransportEvidence?)?
    private var httpsRulesReader: (() -> TLSInterceptionRules)?
    private var httpsRulesWriter: ((TLSInterceptionRules) -> Void)?
    private var httpsRulesGlobalMode: HTTPSProxyMode?
    private var httpsRecoveryJournal = MCPHTTPSRecoveryJournal()
    private var managedRuntimeStatusProvider: (() async -> MCPManagedRuntimeHostStatusDTO)?
    private var setupReadinessProvider: ((MCPSetupReadinessTarget, MCPClientCredentialState) async -> MCPSetupReadinessDTO)?
    private var captureMarkerService: CaptureMarkerService?
    private var rollingCaptureStatusProvider: (() -> RollingCaptureStatus)?
    private var rollingCaptureRestoreHandler: (() async throws -> [String: Any])?
    private var effectBundleService: MCPEffectBundleService?
    private var boundPort: UInt16
    /// Directory for file-delivered / spilled `sessions_export` artifacts (injectable for tests).
    private let sessionExportDirectory: URL
    private var sessions: [String: MCPBoundSession] = [:]
    private var sessionTerminations: [String: MCPSessionTerminationRecord] = [:]
    private var sessionEndHandler: ((String) -> Void)?
    private var sessionTerminationHandler: ((String) async throws -> MCPRecoverySummary)?
    private var rateLimiter: MCPRateLimiter
    private var inFlightByClient: [String: Int] = [:]
    private var slowToolTasks: [SlowToolTaskKey: Task<Void, Error>] = [:]
    private let exposeDebugTools: Bool
    private var sessionCursors: [String: MCPSessionQueryCursor] = [:]
    private var sessionCursorOrder: [String] = []
    private var mediaCursors: [String: MCPMediaRelatedCursor] = [:]
    private var mediaCursorOrder: [String] = []
    private var terminatingSessionIDs: Set<String> = []
    private(set) var inFlightHTTPRequestCount = 0
    private let encoder = JSONEncoder()
    /// Input schemas are immutable for the lifetime of one server instance. Build the canonical
    /// catalog once, then apply live policy, toolset, and service-availability filtering by name.
    private lazy var productionToolDescriptorsByName: [String: [String: Any]] = Dictionary(
        uniqueKeysWithValues: MCPCapabilitiesManifestBuilder.productionTools.map { tool in
            (tool.name, toolDescriptor(name: tool.name, description: tool.description))
        }
    )

    private struct SlowToolTaskKey: Hashable {
        var sessionID: String
        var requestID: String
    }

    private let instrumentsCoordinator: InstrumentsTraceCoordinator = InstrumentsTraceCoordinator()

    init(
        policyStore: MCPPolicyStore,
        grantStore: MCPClientGrantStore? = nil,
        clientRegistry: MCPClientRegistry,
        auditStore: MCPAuditStore,
        snapshotService: MCPSessionSnapshotService,
        approvalStore: MCPApprovalStore,
        artifactWorker: ArtifactAnalysisWorker? = nil,
        mediaInspectionService: MCPMediaInspectionService? = nil,
        agenticService: MCPAgenticService? = nil,
        llmInspectionService: MCPLLMInspectionService? = nil,
        concurrencyFuzzingService: MCPConcurrencyFuzzingService? = nil,
        resilienceService: MCPResilienceService? = nil,
        trajectoryService: MCPTrajectoryService? = nil,
        semanticMockService: MCPSemanticMockService? = nil,
        contractDiffService: MCPContractDiffService? = nil,
        dataLineageService: MCPDataLineageService? = nil,
        localizationMockService: MCPLocalizationMockService? = nil,
        statefulMockService: MCPStatefulMockService? = nil,
        faultBisectionService: MCPFaultBisectionService? = nil,
        syntheticInjectionService: MCPSyntheticInjectionService? = nil,
        responseEditService: MCPResponseEditService? = nil,
        operationCoordinator: MCPOperationCoordinator? = nil,
        notificationHub: MCPNotificationHub? = nil,
        deviceService: MCPDeviceService = .shared,
        disclosureSerializer: MCPDisclosureSerializer = MCPDisclosureSerializer(),
        mutationService: MCPMutationService? = nil,
        boundPort: UInt16 = NetworkConstants.mcpDefaultPort,
        exposeDebugTools: Bool = false,
        sessionExportDirectory: URL? = nil,
        rateLimiter: MCPRateLimiter = MCPRateLimiter()
    ) {
        self.policyStore = policyStore
        let resolvedGrantStore = grantStore ?? MCPClientGrantStore()
        self.grantStore = resolvedGrantStore
        self.policyEvaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: resolvedGrantStore)
        self.clientRegistry = clientRegistry
        self.auditStore = auditStore
        self.snapshotService = snapshotService
        self.approvalStore = approvalStore
        self.artifactWorker = artifactWorker ?? ArtifactAnalysisWorker()
        let resolvedMediaInspectionService = mediaInspectionService ?? MCPMediaInspectionService(
            sessionStore: snapshotService.sourceSessionStore,
            snapshotService: snapshotService
        )
        self.mediaInspectionService = resolvedMediaInspectionService
        self.agenticService = agenticService ?? MCPAgenticService(
            sessionStore: snapshotService.sourceSessionStore,
            snapshotService: snapshotService
        )
        self.llmInspectionService = llmInspectionService ?? MCPLLMInspectionService(
            sessionStore: snapshotService.sourceSessionStore,
            snapshotService: snapshotService
        )
        self.concurrencyFuzzingService = concurrencyFuzzingService ?? MCPConcurrencyFuzzingService(
            sessionStore: snapshotService.sourceSessionStore,
            snapshotService: snapshotService
        )
        self.resilienceService = resilienceService ?? MCPResilienceService(
            sessionStore: snapshotService.sourceSessionStore,
            snapshotService: snapshotService
        )
        self.trajectoryService = trajectoryService ?? MCPTrajectoryService(
            sessionStore: snapshotService.sourceSessionStore,
            snapshotService: snapshotService
        )
        self.semanticMockService = semanticMockService ?? MCPSemanticMockService(
            sessionStore: snapshotService.sourceSessionStore,
            snapshotService: snapshotService
        )
        self.contractDiffService = contractDiffService ?? MCPContractDiffService(
            sessionStore: snapshotService.sourceSessionStore
        )
        self.dataLineageService = dataLineageService ?? MCPDataLineageService(
            sessionStore: snapshotService.sourceSessionStore,
            snapshotService: snapshotService
        )
        self.localizationMockService = localizationMockService ?? MCPLocalizationMockService(
            sessionStore: snapshotService.sourceSessionStore
        )
        self.statefulMockService = statefulMockService ?? MCPStatefulMockService(
            coordinator: StatefulMockCoordinator()
        )
        self.faultBisectionService = faultBisectionService ?? MCPFaultBisectionService(
            sessionStore: snapshotService.sourceSessionStore
        )
        self.syntheticInjectionService = syntheticInjectionService ?? MCPSyntheticInjectionService(
            sessionStore: snapshotService.sourceSessionStore,
            snapshotService: snapshotService
        )
        self.responseEditService = responseEditService ?? MCPResponseEditService(
            snapshotService: snapshotService,
            policyStore: policyStore,
            grantStore: resolvedGrantStore,
            auditStore: auditStore
        )
        self.operationCoordinator = operationCoordinator ?? MCPOperationCoordinator(
            sessionStore: snapshotService.sourceSessionStore,
            mediaService: resolvedMediaInspectionService,
            snapshotService: snapshotService,
            policyStore: policyStore,
            auditStore: auditStore,
            notificationHub: notificationHub
        )
        self.notificationHub = notificationHub
        self.deviceService = deviceService
        self.disclosureSerializer = disclosureSerializer
        self.mutationService = mutationService
        mutationService?.responseEditService = self.responseEditService
        self.boundPort = boundPort
        self.sessionExportDirectory = sessionExportDirectory ?? MCPSessionExportFileStore.defaultDirectory()
        self.exposeDebugTools = exposeDebugTools
        self.rateLimiter = rateLimiter
        encoder.dateEncodingStrategy = .iso8601
    }

    /// Installs the mutation adapter after ``AppCoordinator`` constructs ``MCPProposalCoordinator``.
    func setMutationService(_ service: MCPMutationService) {
        mutationService = service
        service.responseEditService = responseEditService
    }

    /// Drops match-ref and read-budget state for one client or all clients.
    func invalidateResponseEditState(clientID: String? = nil) {
        responseEditService.invalidateTransientState(clientID: clientID)
    }

    func setOpenWorldService(_ service: MCPOpenWorldService) {
        openWorldService = service
    }

    func setScenarioService(_ service: MCPScenarioService) {
        scenarioService = service
    }

    func setHLSFixtureService(_ service: MCPHLSFixtureService) {
        hlsFixtureService = service
    }

    func setOpenAPIMockPackService(_ service: MCPOpenAPIMockPackService) {
        openAPIMockPackService = service
    }

    func setEffectBundleService(_ service: MCPEffectBundleService) {
        effectBundleService = service
    }

    func setDiagnosticRunService(_ service: MCPDiagnosticRunService) {
        diagnosticRunService = service
    }

    func setCertificateIdentityService(_ service: MCPCertificateIdentityService) {
        certificateIdentityService = service
    }

    func setRecoveryService(_ service: MCPRecoveryService) {
        recoveryService = service
    }

    func setReturnToNormalHandler(_ handler: @escaping () async throws -> MCPRecoverySummary) {
        returnToNormalHandler = handler
    }

    func setRuntimeControlHandler(
        _ handler: @escaping (MCPRuntimeControlAction) async throws -> [String: Any]
    ) {
        runtimeControlHandler = handler
    }

    func setCaptureStatusProvider(_ provider: @escaping () -> MCPCaptureStatusDTO) {
        captureStatusProvider = provider
    }

    func setTransportEvidenceProvider(_ provider: @escaping (UUID) -> RequestTransportEvidence?) {
        transportEvidenceProvider = provider
    }

    func configureHTTPSRules(globalMode: HTTPSProxyMode? = nil, recoveryURL: URL? = nil, reader: @escaping () -> TLSInterceptionRules,
                             writer: @escaping (TLSInterceptionRules) -> Void) {
        httpsRulesGlobalMode = globalMode
        httpsRecoveryJournal = MCPHTTPSRecoveryJournal(url: recoveryURL)
        httpsRulesReader = reader
        httpsRulesWriter = writer
    }

    func setManagedRuntimeStatusProvider(
        _ provider: @escaping () async -> MCPManagedRuntimeHostStatusDTO
    ) {
        managedRuntimeStatusProvider = provider
    }

    func setSetupReadinessProvider(
        _ provider: @escaping (MCPSetupReadinessTarget, MCPClientCredentialState) async -> MCPSetupReadinessDTO
    ) {
        setupReadinessProvider = provider
    }

    /// Wires capture-marker creation and rolling-save status for digest/runtime tools.
    func configureCaptureEvidenceServices(
        markerService: CaptureMarkerService,
        rollingCaptureStatusProvider: @escaping () -> RollingCaptureStatus,
        rollingCaptureRestoreHandler: @escaping () async throws -> [String: Any]
    ) {
        captureMarkerService = markerService
        self.rollingCaptureStatusProvider = rollingCaptureStatusProvider
        self.rollingCaptureRestoreHandler = rollingCaptureRestoreHandler
    }

    func setSessionEndHandler(_ handler: @escaping (String) -> Void) {
        sessionEndHandler = handler
    }

    func setSessionTerminationHandler(
        _ handler: @escaping (String) async throws -> MCPRecoverySummary
    ) {
        sessionTerminationHandler = handler
    }

    var activeSessionCount: Int { sessions.count }

    func activeSessionCount(forClientID clientID: String) -> Int {
        sessions.values.filter { $0.clientID == clientID && !$0.restricted }.count
    }

    /// Test hook: registers a synthetic session for session-end grant lifecycle tests.
    func testRegisterSession(clientID: String, sessionID: String = UUID().uuidString) -> String {
        sessions[sessionID] = MCPBoundSession(
            sessionID: sessionID,
            clientID: clientID,
            credentialGeneration: 1,
            protocolVersion: "2025-03-26",
            policyRevision: policyStore.policyRevision,
            initialized: true,
            restricted: false,
            lastActivityAt: Date()
        )
        return sessionID
    }

    /// Test hook: removes a session through the production removal path.
    func testRemoveSession(sessionID: String) {
        removeSession(sessionID: sessionID, reason: "test_remove")
    }
    var connectedClientIDs: Set<String> { Set(sessions.values.map(\.clientID)) }

    /// Exposed for tests: `invalidateSessions(for:)` marks a session `restricted` in place rather
    /// than removing it, so `activeSessionCount`/`connectedClientIDs` don't change and can't be
    /// used to verify it actually ran — every real client request re-authenticates via bearer
    /// anyway, so a revoked client's credential alone already blocks future HTTP requests
    /// regardless of whether session restriction also ran, making that outcome unobservable over
    /// HTTP. This lets a regression test check the actual state `invalidateSessions` is
    /// responsible for.
    func isSessionRestricted(sessionID: String) -> Bool {
        sessions[sessionID]?.restricted == true
    }

    /// Updates the expected loopback Host port after the transport binds (tests and controller startup).
    func rebindLoopbackPort(_ port: UInt16) {
        boundPort = port
    }

    func invalidateSessions(for clientID: String) {
        for key in sessions.keys where sessions[key]?.clientID == clientID {
            sessions[key]?.restricted = true
            notificationHub?.invalidateSession(
                MCPLogicalSessionKey(clientID: clientID, mcpSessionID: key),
                reason: "client_revoked"
            )
        }
        operationCoordinator.cancelOperations(forClientID: clientID)
        evidenceReferenceStore.removeAll(forClientID: clientID)
        briefReadCache.removeAll(owner: clientID)
    }

    func invalidateSessionsForPolicyChange() {
        notificationHub?.invalidateAllSessions(reason: "policy_changed")
        for key in sessions.keys {
            sessions[key]?.restricted = true
        }
        approvalStore.invalidateAllPending()
        operationCoordinator.cancelAll()
        evidenceReferenceStore.removeAll()
        briefReadCache.removeAll()
    }

    /// Handles one Streamable HTTP request and returns a typed response for the NIO transport.
    func handleHTTPRequest(method: String, path: String, headers: [String: String], body: Data,
                           isConnected: @escaping @Sendable () -> Bool = { true }) async -> MCPHTTPResponse {
        inFlightHTTPRequestCount += 1
        defer { inFlightHTTPRequestCount -= 1 }
        let normalizedHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        guard path == MCPNetworkConstants.endpointPath else {
            return MCPHTTPResponse.response(status: 404, headers: [:], body: Data())
        }
        // Host/Origin checks run before authentication: a request that doesn't target this loopback
        // endpoint (e.g. DNS-rebinding, or a browser page whose Origin isn't this server) is rejected
        // outright, the same protection the AG-0 spike already validated against real clients.
        if let rejection = validateHost(normalizedHeaders) ?? validateOrigin(normalizedHeaders) {
            MCPLog.protocolLog.notice("Rejected request: Host/Origin validation failed.")
            return rejection
        }
        if method == "DELETE" {
            return await handleSessionTermination(headers: normalizedHeaders)
        }
        guard method == "POST" else {
            return MCPHTTPResponse.response(
                status: 405,
                headers: ["Allow": "POST, GET, DELETE"],
                body: Data()
            )
        }
        guard let accept = normalizedHeaders["accept"]?.lowercased(),
              accept.contains("application/json"), accept.contains("text/event-stream") else {
            MCPLog.protocolLog.notice("Rejected request: Accept header missing required media types.")
            return MCPHTTPResponse.response(status: 406, headers: [:], body: Data("Not Acceptable".utf8))
        }
        guard let authorization = normalizedHeaders["authorization"],
              authorization.lowercased().hasPrefix("bearer ") else {
            recordAuthFailure(fingerprint: nil, reason: "authorization_missing")
            return unauthorizedResponse()
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        let fingerprint = MCPRateLimiter.fingerprint(for: token)
        let rateClass = MCPRequestRateClassifier.rateClass(httpMethod: method, body: body)

        guard policyStore.isLoaded, auditStore.allowsSensitiveReads else {
            MCPLog.lifecycle.error("Rejected request: MCP subsystem degraded (policy or audit store unavailable).")
            return policyDeniedResponse(message: "MCP subsystem is degraded.")
        }

        let client: MCPClientRecord
        do {
            client = try clientRegistry.authenticate(bearerToken: token)
        } catch {
            guard rateLimiter.allowGlobalRequest(), rateLimiter.allowFingerprintRequest(fingerprint) else {
                return rateLimitedResponse()
            }
            recordAuthFailure(fingerprint: fingerprint, reason: "authorization_invalid")
            return unauthorizedResponse()
        }
        guard client.credentialState == .active else {
            guard rateLimiter.allowGlobalRequest(), rateLimiter.allowFingerprintRequest(fingerprint) else {
                return rateLimitedResponse()
            }
            recordAuthFailure(fingerprint: fingerprint, reason: "credential_inactive")
            return unauthorizedResponse()
        }
        guard rateLimiter.allowGlobalRequest(rateClass: rateClass),
              rateLimiter.allowFingerprintRequest(fingerprint, rateClass: rateClass),
              rateLimiter.allowClientRequest(clientID: client.id, rateClass: rateClass) else {
            MCPLog.auth.notice("Rate limited client \(client.id, privacy: .public).")
            return rateLimitedResponse()
        }
        guard beginInFlight(clientID: client.id) else {
            MCPLog.protocolLog.notice("Rejected request: client in-flight limit reached for \(client.id, privacy: .public).")
            return busyResponse()
        }
        defer { endInFlight(clientID: client.id) }

        let context = RequestContext(headers: normalizedHeaders, remoteAddress: nil, isConnected: isConnected)
        let response = await handleAuthenticatedBody(body: body, client: client, context: context)
        return context.finalPairCheck?() ?? response
    }

    private func handleSessionTermination(headers: [String: String]) async -> MCPHTTPResponse {
        guard let authorization = headers["authorization"],
              authorization.lowercased().hasPrefix("bearer ") else {
            recordAuthFailure(fingerprint: nil, reason: "authorization_missing")
            return unauthorizedResponse()
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        let fingerprint = MCPRateLimiter.fingerprint(for: token)
        guard policyStore.isLoaded, auditStore.allowsSensitiveReads else {
            return policyDeniedResponse(message: "MCP subsystem is degraded.")
        }

        let client: MCPClientRecord
        do {
            client = try clientRegistry.authenticate(bearerToken: token)
        } catch {
            guard rateLimiter.allowGlobalRequest(), rateLimiter.allowFingerprintRequest(fingerprint) else {
                return rateLimitedResponse()
            }
            recordAuthFailure(fingerprint: fingerprint, reason: "authorization_invalid")
            return unauthorizedResponse()
        }
        guard client.credentialState == .active else {
            guard rateLimiter.allowGlobalRequest(), rateLimiter.allowFingerprintRequest(fingerprint) else {
                return rateLimitedResponse()
            }
            recordAuthFailure(fingerprint: fingerprint, reason: "credential_inactive")
            return unauthorizedResponse()
        }
        guard rateLimiter.allowGlobalRequest(rateClass: .controlPlane),
              rateLimiter.allowFingerprintRequest(fingerprint, rateClass: .controlPlane),
              rateLimiter.allowClientRequest(clientID: client.id, rateClass: .controlPlane) else {
            return rateLimitedResponse()
        }
        guard beginInFlight(clientID: client.id) else {
            return busyResponse()
        }
        defer { endInFlight(clientID: client.id) }
        guard let sessionID = headers[MCPNetworkConstants.sessionIDHeader.lowercased()] else {
            return MCPHTTPResponse.response(status: 400, headers: [:], body: Data("Mcp-Session-Id is required.".utf8))
        }
        guard let session = sessions[sessionID] else {
            return MCPHTTPResponse.response(status: 404, headers: [:], body: Data())
        }
        guard session.clientID == client.id,
              session.credentialGeneration == client.credentialGeneration,
              session.policyRevision == policyStore.policyRevision,
              !session.restricted else {
            return MCPHTTPResponse.response(status: 404, headers: [:], body: Data())
        }
        let protocolHeader = headers[MCPNetworkConstants.protocolVersionHeader.lowercased()]
        guard protocolHeader == session.protocolVersion || (
            protocolHeader == nil && session.protocolVersion == "2025-03-26"
        ) else {
            return MCPHTTPResponse.response(
                status: 400,
                headers: [MCPNetworkConstants.sessionIDHeader: sessionID],
                body: Data("MCP protocol version does not match the negotiated session.".utf8)
            )
        }
        guard terminatingSessionIDs.insert(sessionID).inserted else {
            return MCPHTTPResponse.response(
                status: 409,
                headers: [MCPNetworkConstants.sessionIDHeader: sessionID],
                body: Data("Session termination is already in progress.".utf8)
            )
        }
        defer { terminatingSessionIDs.remove(sessionID) }

        operationCoordinator.cancelOperations(forMCPSessionID: sessionID)
        let isFinalClientSession = activeSessionCount(forClientID: client.id) == 1
        if isFinalClientSession {
            guard let sessionTerminationHandler else {
                return policyDeniedResponse(message: "Session cleanup service is unavailable.")
            }
            do {
                let summary = try await sessionTerminationHandler(client.id)
                if summary.cleanupRequired || !summary.conflicts.isEmpty {
                    let payload = (try? jsonObject(from: encoder.encode(summary))) ?? [
                        "cleanupRequired": true
                    ]
                    return MCPHTTPResponse.jsonResponse(
                        status: 409,
                        headers: [MCPNetworkConstants.sessionIDHeader: sessionID],
                        object: payload
                    )
                }
            } catch {
                return MCPHTTPResponse.response(
                    status: 503,
                    headers: [MCPNetworkConstants.sessionIDHeader: sessionID],
                    body: Data("Session cleanup failed.".utf8)
                )
            }
        }

        removeSession(sessionID: sessionID, reason: "client_terminated")
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .sessionTerminated,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: isFinalClientSession ? "final_session" : "logical_session",
                detail: nil
            )
        )
        return MCPHTTPResponse.response(status: 204, headers: [:], body: Data())
    }

    /// Validates a GET listen request and reserves an SSE writer slot for the logical MCP session.
    ///
    /// Concurrency: `@MainActor` — reads session and policy state; the transport writes the open
    /// response head on the channel event loop after acceptance.
    func handleSSEListenRequest(headers: [String: String]) async -> SSEListenResult {
        let normalizedHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        if let rejection = validateHost(normalizedHeaders) ?? validateOrigin(normalizedHeaders) {
            return .rejected(response: rejection)
        }
        guard let accept = normalizedHeaders["accept"]?.lowercased(),
              accept.contains("text/event-stream") else {
            return .rejected(
                response: MCPHTTPResponse.response(status: 406, headers: [:], body: Data("Not Acceptable".utf8))
            )
        }
        guard let authorization = normalizedHeaders["authorization"],
              authorization.lowercased().hasPrefix("bearer ") else {
            recordAuthFailure(fingerprint: nil, reason: "authorization_missing")
            return .rejected(response: unauthorizedResponse())
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        let fingerprint = MCPRateLimiter.fingerprint(for: token)
        guard policyStore.isLoaded, auditStore.allowsSensitiveReads else {
            return .rejected(response: policyDeniedResponse(message: "MCP subsystem is degraded."))
        }
        let client: MCPClientRecord
        do {
            client = try clientRegistry.authenticate(bearerToken: token)
        } catch {
            guard rateLimiter.allowGlobalRequest(), rateLimiter.allowFingerprintRequest(fingerprint) else {
                return .rejected(response: rateLimitedResponse())
            }
            recordAuthFailure(fingerprint: fingerprint, reason: "authorization_invalid")
            return .rejected(response: unauthorizedResponse())
        }
        guard client.credentialState == .active else {
            guard rateLimiter.allowGlobalRequest(), rateLimiter.allowFingerprintRequest(fingerprint) else {
                return .rejected(response: rateLimitedResponse())
            }
            recordAuthFailure(fingerprint: fingerprint, reason: "credential_inactive")
            return .rejected(response: unauthorizedResponse())
        }
        guard rateLimiter.allowGlobalRequest(rateClass: .controlPlane),
              rateLimiter.allowFingerprintRequest(fingerprint, rateClass: .controlPlane),
              rateLimiter.allowClientRequest(clientID: client.id, rateClass: .controlPlane) else {
            return .rejected(response: rateLimitedResponse())
        }
        let context = RequestContext(headers: normalizedHeaders, remoteAddress: nil)
        if let rejection = sessionHTTPRejection(for: "GET", id: nil, client: client, context: context) {
            return .rejected(response: rejection)
        }
        if let sessionError = validateSession(for: "GET", id: nil, client: client, context: context) {
            return .rejected(response: MCPHTTPResponse.jsonResponse(status: 400, headers: [:], object: sessionError))
        }
        guard let notificationHub else {
            return .rejected(
                response: MCPHTTPResponse.response(
                    status: 503,
                    headers: ["Content-Type": "application/json"],
                    body: Data("""
                    {"code":"event_stream_unavailable","message":"Live subscriptions are unavailable."}
                    """.utf8)
                )
            )
        }
        guard notificationHub.liveListenStreamCount < MCPServerLimits.maxConcurrentListenStreams else {
            return .rejected(response: busyResponse())
        }
        guard let sessionID = normalizedHeaders[MCPNetworkConstants.sessionIDHeader.lowercased()] else {
            return .rejected(response: unauthorizedResponse())
        }
        let key = MCPLogicalSessionKey(clientID: client.id, mcpSessionID: sessionID)
        return .accepted(key: key)
    }

    func registerSSEWriter(key: MCPLogicalSessionKey, writer: MCPSSEWriting) {
        notificationHub?.registerWriter(key: key, writer: writer)
    }

    func unregisterSSEWriter(key: MCPLogicalSessionKey, writer: MCPSSEWriting? = nil) {
        notificationHub?.unregisterWriter(key: key, writer: writer, removeSubscriptions: true)
    }

    private func beginInFlight(clientID: String) -> Bool {
        let current = inFlightByClient[clientID, default: 0]
        guard current < MCPServerLimits.concurrentInFlightRequestsPerClient else { return false }
        inFlightByClient[clientID] = current + 1
        return true
    }

    private func endInFlight(clientID: String) {
        let current = inFlightByClient[clientID, default: 0]
        inFlightByClient[clientID] = max(0, current - 1)
    }

    private func handleAuthenticatedBody(body: Data, client: MCPClientRecord, context: RequestContext) async -> MCPHTTPResponse {
        let jsonObject: Any
        do {
            jsonObject = try MCPJSONParsing.parseJSONObject(from: body)
        } catch MCPJSONParsing.Failure.depthExceeded {
            MCPLog.protocolLog.notice("Rejected request: JSON nesting exceeded the allowed depth.")
            return MCPHTTPResponse.jsonRPCError(status: 400, id: nil, code: -32600, message: "JSON nesting too deep.")
        } catch {
            MCPLog.protocolLog.notice("Rejected request: JSON parse error.")
            return MCPHTTPResponse.jsonRPCError(status: 400, id: nil, code: -32700, message: "Parse error.")
        }
        guard let message = jsonObject as? [String: Any] else {
            MCPLog.protocolLog.notice("Rejected request: body was not a JSON object.")
            return MCPHTTPResponse.jsonRPCError(status: 400, id: nil, code: -32600, message: "Invalid Request.")
        }
        let method = message["method"] as? String
        if let method, let rejection = sessionHTTPRejection(for: method, id: message["id"], client: client, context: context) {
            return rejection
        }
        if let method, message["id"] == nil {
            guard validateSession(for: method, id: nil, client: client, context: context) == nil else {
                return MCPHTTPResponse.response(
                    status: 202,
                    headers: sessionHeaders(context: context),
                    body: Data()
                )
            }
            await handleNotification(message, client: client, context: context)
            return MCPHTTPResponse.response(status: 202, headers: sessionHeaders(context: context), body: Data())
        }
        var responseObject = await buildJSONRPCResponse(message: message, client: client, context: context)
        if message["method"] as? String == "tools/call",
           let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()],
           sessions[sessionID]?.structuredResultsOnly == true {
            responseObject = structuredOnlyToolResponse(responseObject)
        }
        // A response for this id is about to be delivered (cancelled or not) — the cancellation
        // marker has done its job. Without this, a client that reuses small integer ids (common
        // with simple counters) would find every future call using the same id permanently
        // rejected with "Request cancelled" for the rest of the session.
        if context.finalPairCheck == nil, let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()],
           let requestKey = requestKey(from: message["id"]) {
            sessions[sessionID]?.cancelledRequestIDs.remove(requestKey)
        }
        var headers = sessionHeaders(context: context)
        if let method = message["method"] as? String,
           method == "initialize",
           let result = responseObject["result"] as? [String: Any],
           let sessionID = result["_sessionID"] as? String {
            headers[MCPNetworkConstants.sessionIDHeader] = sessionID
        }
        return MCPHTTPResponse.jsonResponse(status: 200, headers: headers, object: sanitizeResponse(responseObject))
    }

    private func buildJSONRPCResponse(
        message: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32600, "Invalid Request."))
        }
        let params = message["params"] as? [String: Any] ?? [:]

        if let sessionError = validateSession(for: method, id: id, client: client, context: context) {
            return sessionError
        }
        if let cancelled = cancelledResponse(id: id, context: context) {
            return cancelled
        }

        MCPLog.protocolLog.debug("Dispatching \(method, privacy: .public) for client \(client.id, privacy: .public).")
        switch method {
        case "initialize":
            return handleInitialize(id: id, params: params, client: client)
        case "tools/list":
            return handleToolsList(id: id, client: client)
        case "resources/list":
            return handleResourcesList(id: id)
        case "resources/read":
            return await handleResourcesRead(id: id, params: params, client: client)
        case "resources/subscribe":
            return handleResourcesSubscribe(id: id, params: params, client: client, context: context)
        case "resources/unsubscribe":
            return handleResourcesUnsubscribe(id: id, params: params, client: client, context: context)
        case "prompts/list":
            return handlePromptsList(id: id)
        case "prompts/get":
            return handlePromptsGet(id: id, params: params, client: client)
        case "tools/call":
            return await handleToolsCall(id: id, params: params, client: client, context: context)
        default:
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    private func handleInitialize(id: Any?, params: [String: Any], client: MCPClientRecord) -> [String: Any] {
        pruneSessions(forClientID: client.id)
        let sessionID = UUID().uuidString
        let profileRevision = policyStore.policyRevision
        // Echo the client's requested version back when it's one this server actually supports;
        // otherwise fall back to the preferred version. Never silently claim a version the client
        // never asked for when it asked for one we do support — the client is expected to check
        // this response and disconnect if it can't work with what's returned.
        let requestedVersion = params["protocolVersion"] as? String
        let negotiatedVersion = requestedVersion.flatMap { version in
            MCPNetworkConstants.supportedProtocolVersions.contains(version) ? version : nil
        } ?? MCPNetworkConstants.preferredProtocolVersion
        let clientCapabilities = params["capabilities"] as? [String: Any]
        let experimental = clientCapabilities?["experimental"] as? [String: Any]
        let joesProxyCapabilities = experimental?["joesproxy"] as? [String: Any]
        let structuredResultsOnly = joesProxyCapabilities?["structuredResultsOnly"] as? Bool == true
        sessions[sessionID] = MCPBoundSession(
            sessionID: sessionID,
            clientID: client.id,
            credentialGeneration: client.credentialGeneration,
            protocolVersion: negotiatedVersion,
            policyRevision: profileRevision,
            initialized: false,
            restricted: false,
            lastActivityAt: Date(),
            structuredResultsOnly: structuredResultsOnly
        )
        MCPLog.protocolLog.info(
            "Session initialized for client \(client.id, privacy: .public), protocolVersion \(negotiatedVersion, privacy: .public)."
        )
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .authenticationSuccess,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "initialize",
                detail: nil
            )
        )
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "protocolVersion": negotiatedVersion,
                "capabilities": [
                    "tools": ["listChanged": true],
                    "resources": ["subscribe": true, "listChanged": false],
                    "prompts": ["listChanged": false],
                    "experimental": [
                        "joesproxy": [
                            "structuredResultsOnly": true,
                            "readBatchMaximum": 8,
                            "evidenceReferences": true
                        ]
                    ]
                ],
                "serverInfo": [
                    "name": "JoesProxy MCP",
                    "version": Bundle.main.marketingVersionOrDev
                ],
                "_sessionID": sessionID
            ]
        ]
    }

    private func handleToolsList(id: Any?, client: MCPClientRecord) -> [String: Any] {
        var tools = toolDescriptors(for: client)
        #if DEBUG
        if exposeDebugTools {
            tools.append(toolDescriptor(name: "mcp_slow", description: "Debug slow tool for cancellation tests."))
        }
        #endif
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": ["tools": tools]
        ]
    }

    /// Testable serialized discovery boundary used by `tools/list`.
    func toolDescriptors(for client: MCPClientRecord) -> [[String: Any]] {
        listedProductionTools(for: client).compactMap {
            productionToolDescriptorsByName[$0.name]
        }
    }

    var cachedProductionToolDescriptorCount: Int {
        productionToolDescriptorsByName.count
    }

    private func listedProductionTools(
        for client: MCPClientRecord
    ) -> [MCPCapabilitiesManifestBuilder.ProductionTool] {
        policyAvailableProductionTools(for: client).filter {
            $0.discoveryToolsets.contains(client.effectiveToolset)
        }
    }

    private func policyAvailableProductionTools(
        for client: MCPClientRecord
    ) -> [MCPCapabilitiesManifestBuilder.ProductionTool] {
        MCPCapabilitiesManifestBuilder.productionTools.filter { tool in
            guard policyEvaluator.profileAllows(
                capability: tool.capability,
                profileID: client.assignedProfileID
            ) else {
                return false
            }
            if tool.name == "runtime_status" {
                return managedRuntimeStatusProvider != nil
            }
            if tool.name == "setup_readiness" {
                return setupReadinessProvider != nil
            }
            switch tool.capability {
            case .artifactSourceAccess, .artifactSourceRelease, .artifactCalculate, .artifactSearch, .artifactBrief, .artifactCompare:
                return artifactSources != nil
            case .httpsRulesInspect, .httpsRulesManage:
                return httpsRulesReader != nil && httpsRulesWriter != nil
            case .bookmarkInspect, .overrideInspect, .structuralDiscovery, .transformationPreview,
                 .responseDraftInspect,
                 .createDisabledBookmark, .createDisabledMapLocal, .createDisabledMapRemote,
                 .createDisabledBlock, .createDisabledRewrite, .createDisabledLiveRewrite,
                 .createDisabledCollectionMock,
                 .createResponseDraft,
                 .enableRule, .disableRule, .changeThrottle:
                return mutationService != nil
            case .executeBookmark, .activateMapRemote, .activateLiveRewrite, .activateCollectionMock,
                 .replayRequest, .liveMediaProbe:
                return openWorldService != nil
            case .scenarioLifecycle:
                return scenarioService != nil
            case .hlsFixtureInspect, .hlsFixtureLifecycle, .hlsSubstitutionLifecycle:
                return hlsFixtureService != nil
            case .openAPIMockInspect, .openAPIMockLifecycle:
                return openAPIMockPackService != nil
            case .diagnosticRunInspect, .diagnosticRunLifecycle:
                return diagnosticRunService != nil
            case .certificateStatus, .certificateIdentity, .certificateArtifactsList,
                 .certificateCompare, .certificateCleanup, .certificateExport:
                return certificateIdentityService != nil
            case .returnToNormal:
                return returnToNormalHandler != nil
            case .runtimeControl:
                return runtimeControlHandler != nil
            default:
                return true
            }
        }
    }

    private func handleResourcesList(id: Any?) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "resources": MCPCapabilitiesManifestBuilder.productionResources.map {
                    ["uri": $0.uri, "name": $0.name, "mimeType": $0.mimeType]
                }
            ]
        ]
    }

    private func handleResourcesRead(
        id: Any?,
        params: [String: Any],
        client: MCPClientRecord
    ) async -> [String: Any] {
        let uri = params["uri"] as? String ?? ""
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .resourceRead,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: uri,
                detail: nil
            )
        )
        do {
            let profile = try policyStore.resolvedProfile(for: client.assignedProfileID)
            let payload = try await resourcePayload(uri: uri, client: client, profile: profile)
            let text = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
            guard let text = String(data: text, encoding: .utf8) else {
                throw MCPStructuredError(code: .internalFailure, message: "Resource serialization failed.")
            }
            return [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": [
                    "contents": [[
                        "uri": uri,
                        "mimeType": "application/json",
                        "text": text
                    ]]
                ]
            ]
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch let error as MCPPolicyStoreError {
            return policyDeniedJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Resource read failed."))
        }
    }

    private func handlePromptsList(id: Any?) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "prompts": [
                    ["name": MCPDiagnosticPrompt.name, "description": MCPDiagnosticPrompt.description],
                    ["name": MCPSetupOnboardingPrompt.name, "description": MCPSetupOnboardingPrompt.description],
                    ["name": MCPIntegrationsPrompt.name, "description": MCPIntegrationsPrompt.description]
                ]
            ]
        ]
    }

    private func handlePromptsGet(
        id: Any?,
        params: [String: Any],
        client: MCPClientRecord
    ) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        guard name == MCPDiagnosticPrompt.name || name == MCPSetupOnboardingPrompt.name || name == MCPIntegrationsPrompt.name else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "Unknown prompt: \(name)."))
        }
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .resourceRead,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "prompt:\(name)",
                detail: nil
            )
        )
        let description: String
        let body: String
        switch name {
        case MCPDiagnosticPrompt.name:
            description = MCPDiagnosticPrompt.description
            body = MCPDiagnosticPrompt.body
        case MCPSetupOnboardingPrompt.name:
            description = MCPSetupOnboardingPrompt.description
            body = MCPSetupOnboardingPrompt.body
        case MCPIntegrationsPrompt.name:
            description = MCPIntegrationsPrompt.description
            body = MCPIntegrationsPrompt.body
        default:
            description = ""
            body = ""
        }
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "description": description,
                "messages": [
                    [
                        "role": "user",
                        "content": ["type": "text", "text": body]
                    ]
                ]
            ]
        ]
    }

    private func handleResourcesSubscribe(
        id: Any?,
        params: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) -> [String: Any] {
        let uri = params["uri"] as? String ?? ""
        guard MCPSubscriptionResource.isAllowed(uri) else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .malformedRequest, message: "Unknown subscription resource: \(uri)")
            )
        }
        do {
            _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
            _ = try resourceAccessAllowed(uri: uri)
            guard let notificationHub,
                  let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()] else {
                return structuredErrorJSONRPC(
                    id: id,
                    error: MCPStructuredError(code: .internalFailure, message: "Subscriptions are unavailable.")
                )
            }
            let key = MCPLogicalSessionKey(clientID: client.id, mcpSessionID: sessionID)
            try notificationHub.subscribe(key: key, uri: uri)
            return [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": [:] as [String: Any]
            ]
        } catch let error as MCPStructuredError {
            auditStore.record(
                MCPAuditEvent(
                    id: UUID(),
                    kind: .policyDenied,
                    timestamp: Date(),
                    clientID: client.id,
                    credentialFingerprint: nil,
                    sourceProcess: nil,
                    reasonCode: "subscribe_denied:\(uri)",
                    detail: error.message
                )
            )
            return structuredErrorJSONRPC(id: id, error: error)
        } catch let error as MCPPolicyStoreError {
            return policyDeniedJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Subscription failed."))
        }
    }

    private func handleResourcesUnsubscribe(
        id: Any?,
        params: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) -> [String: Any] {
        let uri = params["uri"] as? String ?? ""
        guard MCPSubscriptionResource.isAllowed(uri) else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .malformedRequest, message: "Unknown subscription resource: \(uri)")
            )
        }
        guard let notificationHub,
              let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()] else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "Subscriptions are unavailable.")
            )
        }
        let key = MCPLogicalSessionKey(clientID: client.id, mcpSessionID: sessionID)
        notificationHub.unsubscribe(key: key, uri: uri)
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [:] as [String: Any]
        ]
    }

    private func resourceAccessAllowed(uri: String) throws -> Bool {
        switch uri {
        case "joesproxy://server/status", "joesproxy://capture/summary", "joesproxy://capture/health",
             "joesproxy://agent/capabilities", "joesproxy://agent/guide", "joesproxy://setup/guide", "joesproxy://audit/recent", "joesproxy://docs/index":
            return true
        default:
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown resource: \(uri)")
        }
    }

    private func handleToolsCall(
        id: Any?,
        params: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        // Toolsets reduce discovery cost only. Authorization always evaluates the complete
        // policy-available catalog so a compact selection cannot remove diagnostic capability.
        let availableNames = Set(policyAvailableProductionTools(for: client).map(\.name))
        #if DEBUG
        let isAvailableDebugTool = exposeDebugTools && name == "mcp_slow"
        #else
        let isAvailableDebugTool = false
        #endif
        guard availableNames.contains(name) || isAvailableDebugTool else {
            if let capability = MCPCapabilityRouter.capability(forTool: name),
               !policyEvaluator.effectiveAllows(capability: capability, client: client) {
                auditStore.recordOperatorActionablePolicyBlock(
                    clientID: client.id,
                    capability: capability,
                    detail: "Tool unavailable under the client's disclosure profile or access policy."
                )
            }
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32601, "Unknown or unavailable tool: \(name)"))
        }
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .toolCall,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: name,
                detail: nil
            )
        )
        switch name {
        case "agent_toolset_status":
            return toolsetStatusTool(id: id, client: client, relistRequired: false)
        case "agent_toolset_select":
            return toolsetSelectTool(id: id, arguments: arguments, client: client)
        case "sessions_list":
            return await sessionsPage(id: id, arguments: arguments, client: client, queryDigest: "sessions_list", filter: nil)
        case "sessions_search":
            return await sessionsPage(
                id: id,
                arguments: arguments,
                client: client,
                queryDigest: sessionsSearchDigest(arguments: arguments),
                filter: sessionsSearchFilter(arguments: arguments)
            )
        case "capture_digest":
            return captureDigestTool(id: id, arguments: arguments)
        case "documentation_list", "documentation_search", "documentation_read":
            do {
                let query = try DocumentationCatalog.Query(operation: String(name.dropFirst("documentation_".count)), arguments: arguments)
                let page = try await DocumentationService.shared.query(query, source: "running-server", appVersion: Bundle.main.marketingVersionOrDev)
                return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: page))
            } catch let failure as DocumentationCatalog.Failure {
                return structuredErrorJSONRPC(id: id, error: MCPStructuredError(code: .malformedRequest,
                    message: failure.localizedDescription, details: ["phase": "documentation", "reason": failure.reason, "recommendedAction": failure.recovery, "documentationTopic": "agent-documentation"]))
            } catch {
                return structuredErrorJSONRPC(id: id, error: MCPStructuredError(code: .internalFailure, message: "Documentation is unavailable."))
            }
        case "audit_cache_efficiency":
            return auditCacheEfficiencyTool(id: id)
        case "investigation_snapshot":
            return investigationSnapshotTool(id: id, arguments: arguments, client: client)
        case "evidence_get":
            return evidenceGetTool(id: id, arguments: arguments, client: client)
        case "read_batch":
            return await readBatchTool(id: id, arguments: arguments, client: client, context: context)
        case "capture_marker_create":
            return captureMarkerCreateTool(id: id, arguments: arguments, client: client)
        case "capture_restore_rolling":
            return await captureRestoreRollingTool(id: id, client: client)
        case "session_summary":
            return await sessionSummaryTool(id: id, arguments: arguments, client: client, context: context)
        case "response_evidence_brief":
            let allowed: Set<String> = ["sessionID", "selectionPointer", "includeStructure", "fieldPointers", "rowLimit", "ifBriefDigest", "approval"]
            guard Set(arguments.keys).isSubset(of: allowed),
                  MCPBriefReadCache.validDigest(arguments["ifBriefDigest"]),
                  arguments["includeStructure"] == nil || (arguments["includeStructure"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true,
                  arguments["selectionPointer"] == nil || arguments["selectionPointer"] is String,
                  (try? CollectionMockCompiler.pointer(arguments["selectionPointer"] as? String ?? "")) != nil else {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "Use sessionID and an optional valid selectionPointer."))
            }
            var approvedArguments = arguments
            approvedArguments["includeBody"] = true
            return await sessionSummaryTool(id: id, arguments: approvedArguments, client: client, context: context, brief: true)
        case "capture_calculate":
            return await captureCalculateTool(id: id, arguments: arguments, client: client, context: context)
        case "artifact_compare_responses", "artifact_source_register", "artifact_source_status", "artifact_source_inspect", "artifact_source_release", "artifact_calculate", "artifact_inventory", "artifact_search", "artifact_response_brief":
            return await artifactSourceTool(id: id, name: name, arguments: arguments, client: client, context: context)
        case "investigation_compare_brief":
            return investigationCompareBriefTool(id: id, arguments: arguments, client: client, context: context)
        case "list_discovered_devices", "set_device_alias":
            return await deviceTool(id: id, name: name, arguments: arguments)
        case "sessions_export":
            return await sessionsExportTool(id: id, arguments: arguments, client: client, context: context)
        case "repro_export_package":
            return reproExportPackageTool(id: id, arguments: arguments)
        case "repro_inspect_package":
            return reproInspectPackageTool(id: id, arguments: arguments)
        case "media_summary":
            return mediaSummaryTool(id: id, arguments: arguments, client: client)
        case "media_readiness":
            return mediaReadinessTool(id: id, arguments: arguments, client: client)
        case "media_context":
            return mediaContextTool(id: id, arguments: arguments, client: client)
        case "media_manifest_structure":
            return mediaManifestStructureTool(id: id, arguments: arguments, client: client)
        case "response_context":
            return responseContextTool(id: id, arguments: arguments, client: client)
        case "response_text_search":
            return await responseTextSearchTool(id: id, arguments: arguments, client: client, context: context)
        case "response_text_read":
            return await responseTextReadTool(id: id, arguments: arguments, client: client, context: context)
        case "media_related_sessions":
            return mediaRelatedSessionsTool(id: id, arguments: arguments, client: client)
        case "media_inspection_start":
            return await mediaInspectionStartTool(id: id, arguments: arguments, client: client, context: context)
        case "operation_status":
            return operationStatusTool(id: id, arguments: arguments, client: client, context: context)
        case "operation_cancel":
            return operationCancelTool(id: id, arguments: arguments, client: client, context: context)
        case "client_cleanup_status":
            return await clientCleanupStatusTool(id: id, client: client)
        case "runtime_status":
            return await runtimeStatusTool(id: id, arguments: arguments, client: client)
        case "setup_readiness":
            return await setupReadinessTool(id: id, arguments: arguments, client: client)
        case "approval_status":
            return approvalStatusTool(id: id, arguments: arguments, client: client, context: context)
        case "approvals_list":
            return approvalsListTool(id: id, client: client)
        case "https_rules_get", "https_rules_set", "https_rules_restore":
            return httpsRulesTool(id: id, name: name, arguments: arguments, client: client, context: context)
        case "capture_status":
            guard arguments.isEmpty else {
                return structuredErrorJSONRPC(id: id, error: MCPStructuredError(code: .malformedRequest,
                    message: "capture_status accepts no arguments. Example: capture_status {}."))
            }
            guard let status = captureStatusProvider?() else {
                return structuredErrorJSONRPC(id: id, error: MCPStructuredError(
                    code: .internalFailure, message: "Live capture status is unavailable; do not infer that body capture is enabled."))
            }
            return (try? encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: status)))
                ?? structuredErrorJSONRPC(id: id, error: MCPStructuredError(code: .internalFailure, message: "Capture status encoding failed."))
        case "proxy_start", "proxy_stop", "mcp_stop", "capture_resume":
            return await runtimeControlTool(
                id: id,
                name: name,
                arguments: arguments,
                client: client,
                context: context
            )
        case "bookmarks_list", "bookmark_get", "overrides_list", "override_get",
             "capture_activity_since_marker",
             "discover_response_structure", "preview_live_rewrite", "preview_hls_codecs_edit",
             "preview_response_edit",
             "response_drafts_list", "response_draft_get",
             "propose_create_response_draft", "apply_create_response_draft",
             "propose_commit_response_edit", "apply_commit_response_edit",
             "propose_delete_response_draft", "apply_delete_response_draft",
             "propose_create_block", "apply_create_block",
             "propose_create_map_local", "apply_create_map_local",
             "propose_create_map_remote", "apply_create_map_remote",
             "propose_create_rewrite", "apply_create_rewrite",
             "propose_create_live_rewrite", "apply_create_live_rewrite",
             "preview_collection_mock", "propose_create_collection_mock", "apply_create_collection_mock",
             "propose_create_bookmark", "apply_create_bookmark",
             "propose_enable_rule", "apply_enable_rule",
             "propose_disable_rule", "apply_disable_rule",
             "propose_delete_rule", "apply_delete_rule",
             "propose_enable_rewrite", "apply_enable_rewrite",
             "propose_disable_rewrite", "apply_disable_rewrite",
             "propose_change_throttle", "apply_change_throttle":
            return await mutationTool(id: id, name: name, arguments: arguments, client: client, context: context)
        case "execute_bookmark", "replay_request", "repro_replay_request", "recapture_session_body", "activate_map_remote", "activate_live_rewrite", "activate_collection_mock", "live_media_probe_start":
            return await openWorldTool(id: id, name: name, arguments: arguments, client: client, context: context)
        case "draft_test_scenario", "validate_test_scenario", "preview_test_scenario",
             "request_test_scenario_approval", "arm_test_scenario", "activate_test_scenario",
             "get_test_observations", "evaluate_test_assertions", "stop_test_scenario",
             "cleanup_test_scenario", "get_test_report":
            return await scenarioTool(id: id, name: name, arguments: arguments, client: client, context: context)
        case "hls_fixture_capabilities", "hls_fixture_profiles_list", "hls_fixture_status",
             "hls_fixture_window_preview",
             "propose_hls_fixture_start", "apply_hls_fixture_start", "hls_fixture_stop",
             "hls_substitution_profiles_list", "propose_hls_substitution_start",
             "apply_hls_substitution_start", "hls_substitution_status", "hls_substitution_stop",
             "hls_substitution_extend":
            return await hlsFixtureTool(id: id, name: name, arguments: arguments, client: client, context: context)
        case "openapi_pack_preview", "propose_openapi_pack_start", "apply_openapi_pack_start",
             "openapi_pack_status", "openapi_pack_stop", "openapi_validate_session",
             "openapi_generate_mock", "openapi_import_spec":
            return await openAPIMockPackTool(id: id, name: name, arguments: arguments, client: client, context: context)
        case "diagnostic_run_list", "diagnostic_run_create", "diagnostic_run_start",
             "diagnostic_run_window_begin", "diagnostic_run_window_end",
             "diagnostic_run_status", "diagnostic_run_brief", "diagnostic_run_observations", "diagnostic_run_close",
             "diagnostic_run_retry_cleanup", "diagnostic_run_evidence_list", "diagnostic_run_evidence_get",
             "propose_diagnostic_run_recheck", "apply_diagnostic_run_recheck":
            return await diagnosticRunTool(id: id, name: name, arguments: arguments, client: client, context: context)
        case "certificate_status", "certificate_identity", "certificate_artifacts_list",
             "certificate_compare", "certificate_export", "propose_certificate_cleanup", "apply_certificate_cleanup":
            return await certificateIdentityTool(id: id, name: name, arguments: arguments, client: client, context: context)
        case "propose_hypothesis_dag", "step_hypothesis_graph", "get_fault_bisection_report":
            return agenticGraphTool(id: id, name: name, arguments: arguments)
        case "llm_stream_inspection", "propose_llm_stream_fault":
            return llmInspectionTool(id: id, name: name, arguments: arguments)
        case "propose_temporal_permutation_plan", "step_temporal_permutation_plan",
             "get_race_condition_fuzz_report":
            return concurrencyFuzzingTool(id: id, name: name, arguments: arguments)
        case "propose_resilience_bisection_plan", "step_resilience_bisection_plan",
             "get_resilience_matrix_report":
            return resilienceTool(id: id, name: name, arguments: arguments)
        case "diff_session_trajectories":
            return trajectoryTool(id: id, name: name, arguments: arguments)
        case "propose_semantic_mock_rule", "list_semantic_mock_rules", "test_semantic_query_match",
             "delete_semantic_mock_rule":
            return semanticMockTool(id: id, name: name, arguments: arguments)
        case "contract_diff_sessions", "contract_regression_suite":
            return contractDiffTool(id: id, name: name, arguments: arguments)
        case "trace_data_lineage", "audit_analytics_attribution", "propose_provenance_watermark":
            return await dataLineageTool(id: id, name: name, arguments: arguments)
        case "localization_mock_list_presets", "localization_mock_preview":
            return localizationMockTool(id: id, name: name, arguments: arguments)
        case "stateful_mock_list_backends", "stateful_mock_list_presets",
             "stateful_mock_install_preset", "stateful_mock_set_state",
             "stateful_mock_query_entities", "stateful_mock_reset_backend":
            return await statefulMockTool(id: id, name: name, arguments: arguments)
        case "fault_isolation_start", "fault_isolation_record_step", "fault_isolation_report",
             "fault_isolation_cancel":
            return faultIsolationTool(id: id, name: name, arguments: arguments)
        case "cmcd_telemetry_inspection", "webvtt_subtitle_inspection", "drm_handshake_inspection",
             "byte_range_efficiency_inspection", "streaming_waterfall_inspection",
             "visual_asset_inspection", "scte35_ad_break_inspection":
            return await advancedMediaInspectionTool(id: id, name: name, arguments: arguments, client: client)
        case "list_synthetic_assets", "propose_inject_synthetic_item", "list_synthetic_injection_plans",
             "remove_synthetic_injection_plan":
            return syntheticInjectionTool(id: id, name: name, arguments: arguments)
        case "instruments_list_templates", "instruments_record_trace", "instruments_analyze_trace",
             "instruments_correlated_audit":
            return await instrumentsTool(id: id, name: name, arguments: arguments)
        case "effect_bundle_prepare", "effect_bundle_list", "effect_bundle_inspect", "effect_bundle_import", "effect_bundle_retire_preparation",
             "propose_activate_effect_bundle", "apply_activate_effect_bundle",
             "effect_bundle_stop", "effect_bundle_advance", "effect_bundle_compare", "propose_discard_effect_bundle", "apply_discard_effect_bundle":
            guard let effectBundleService else {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Effect bundle service unavailable."))
            }
            do {
                if name == "effect_bundle_prepare" {
                    _ = try resolveSensitiveReadApproval(toolName: name, arguments: arguments, client: client,
                        capability: .bodyRead, mcpSessionID: context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()])
                }
                var boundArguments = arguments
                if name == "apply_activate_effect_bundle" || name == "apply_discard_effect_bundle" {
                    boundArguments["__mcpInternalSessionID"] = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
                }
                let result = try await effectBundleService.handleTool(name: name, arguments: boundArguments, client: client)
                return toolStructuredResult(id: id, payload: result["payload"] as? [String: Any] ?? result)
            } catch let error as MCPStructuredError {
                return structuredErrorJSONRPC(id: id, error: error)
            } catch {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, error.localizedDescription))
            }
        case "return_to_normal":
            return await returnToNormalTool(id: id, client: client)
        #if DEBUG
        case "mcp_slow":
            return await slowTool(id: id, arguments: arguments, context: context)
        #endif
        default:
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32601, "Unknown tool: \(name)"))
        }
    }

    private func toolsetStatusTool(
        id: Any?,
        client: MCPClientRecord,
        relistRequired: Bool
    ) -> [String: Any] {
        var status = MCPToolsetStatusDTO(
            selectedToolset: client.effectiveToolset,
            selectedToolCount: listedProductionTools(for: client).count,
            policyAvailableToolCount: policyAvailableProductionTools(for: client).count,
            availableToolsets: MCPToolset.allCases,
            discoveryOnly: true,
            relistRequired: relistRequired
        )
        let available = Set(policyAvailableProductionTools(for: client).map(\.name))
        for tool in MCPCapabilitiesManifestBuilder.productionTools {
            guard let analysis = MCPCapabilitiesManifestBuilder.analysis(for: tool.name) else { continue }
            if available.contains(tool.name) { status.analysis[tool.name] = analysis }
            else { status.unavailableAnalyses.append(tool.name) }
        }
        status.unavailableAnalyses += ["vision_ocr", "semantic_artifact_search"]
        do {
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: status))
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "agent_toolset_status failed."))
        }
    }

    private func toolsetSelectTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) -> [String: Any] {
        guard let rawToolset = arguments["toolset"] as? String,
              let toolset = MCPToolset(rawValue: rawToolset) else {
            return MCPHTTPResponse.jsonRPCObject(
                id: id,
                error: (-32602, "toolset must be one of: \(MCPToolset.allCases.map(\.rawValue).joined(separator: ", ")).")
            )
        }
        do {
            let updated = try clientRegistry.setPreferredToolset(clientID: client.id, toolset: toolset)
            notificationHub?.publishToolsListChanged(clientID: client.id)
            return toolsetStatusTool(id: id, client: updated, relistRequired: true)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "agent_toolset_select failed."))
        }
    }

    private func capacityWarning(status: MCPCaptureStatusDTO?, records: [SessionRecord],
                                 includesHistory: Bool) -> String? {
        var issues: [String] = []
        if status?.admissionPaused == true { issues.append("Capture busy") }
        if includesHistory, let status {
            if let gap = status.lastIncompleteCaptureAt,
               gap >= (snapshotService.epochMetadata.lastEpochChangeAt ?? .distantPast) {
                issues.append("Some requests were not recorded")
            }
            if records.isEmpty, let skipped = status.lastBodySkippedAt,
               skipped >= (snapshotService.epochMetadata.lastEpochChangeAt ?? .distantPast) {
                issues.append("Response bodies skipped during capture")
            }
            if status.droppedSessionCount > 0 { issues.append("Older sessions removed by retention") }
        }
        if records.contains(where: { $0.responseCaptureLimitedByPressure == true }) {
            issues.append("Response body skipped during capture")
        }
        if records.contains(where: { $0.request.recordingBodyOmissionReason == .retentionEvicted ||
                                      $0.response?.recordingBodyOmissionReason == .retentionEvicted }) ||
            (includesHistory && records.isEmpty && (status?.evictedBodyCount ?? 0) > 0) {
            issues.append("Older bodies removed by retention")
        }
        return issues.isEmpty ? nil : issues.joined(separator: ". ")
    }

    private func sessionsPage(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord,
        queryDigest: String,
        filter: MCPSessionSnapshotService.ListFilter?
    ) async -> [String: Any] {
        do {
            let profile = try policyStore.resolvedProfile(for: client.assignedProfileID)
            let requestedLimit = disclosureSerializer.normalizedPageSize(arguments["limit"] as? Int)
            let cursor = try decodeCursor(arguments["cursor"])
            let projection = try responseProjection(from: arguments)
            let sinceSequence = try normalizedUInt64(arguments["sinceSequence"], fieldName: "sinceSequence")
            let stateToken = captureStateToken()
            let capacity = captureStatusProvider?()
            let effectiveQueryDigest = "\(queryDigest):\(projection.rawValue):\(sinceSequence)"
            if cursor == nil, arguments["ifStateToken"] as? String == stateToken {
                let pageDTO = MCPSessionListPageDTO(
                    captureWarning: capacityWarning(status: capacity, records: [], includesHistory: true),
                    items: [],
                    nextCursor: nil,
                    hasMore: false,
                    captureEpoch: snapshotService.captureEpoch,
                    policyRevision: policyStore.policyRevision,
                    truncated: false,
                    projection: projection,
                    latestSequence: snapshotService.highWaterSequence,
                    stateToken: stateToken,
                    unchanged: true
                )
                return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: pageDTO))
            }
            let responseBudget = try normalizedResponseBudget(arguments["maxResponseBytes"])
            let deduplicateBy: String?
            if let rawDedup = arguments["deduplicateBy"] {
                guard let text = rawDedup as? String, text == "endpoint" else {
                    throw MCPStructuredError.malformedRequest(message: "deduplicateBy must be endpoint.")
                }
                deduplicateBy = text
            } else {
                deduplicateBy = nil
            }
            let includeAuthChain: Bool
            if let rawAuth = arguments["includeAuthChain"] {
                guard let flag = rawAuth as? Bool else {
                    throw MCPStructuredError.malformedRequest(message: "includeAuthChain must be a boolean.")
                }
                if flag {
                    guard profile.allowedFieldClasses.contains(.sanitizedHost),
                          profile.allowedFieldClasses.contains(.safeHeaders) else {
                        throw MCPStructuredError(
                            code: .policyDenied,
                            message: "Auth chain analysis requires sanitizedHost and safeHeaders disclosure."
                        )
                    }
                }
                includeAuthChain = flag
            } else {
                includeAuthChain = false
            }

            var limit = requestedLimit
            var truncatedByBudget = false
            var encodedData = Data()

            while true {
                // Cooperative cancellation checkpoint: if the per-request timeout in
                // MCPNIOHTTPTransport has already fired and cancelled this task, stop retrying
                // instead of continuing to loop on the MainActor after the client has moved on.
                try Task.checkCancellation()
                let page = try snapshotService.page(
                    request: MCPSessionSnapshotService.PageRequest(
                        limit: limit,
                        cursor: cursor,
                        queryDigest: effectiveQueryDigest,
                        orderingDigest: "sequence_asc",
                        filter: filter,
                        minimumSequenceExclusive: sinceSequence
                    ),
                    clientID: client.id,
                    policyRevision: policyStore.policyRevision
                )
                let items = try page.items.map { indexed in
                    let summary = try disclosureSerializer.sessionSummary(
                        record: indexed.record,
                        captureSequence: indexed.captureSequence,
                        profile: profile
                    )
                    return projectedSessionSummary(summary, projection: projection)
                }
                let endpointGroups = deduplicateBy == "endpoint"
                    ? MCPSessionSnapshotService.deduplicateEndpoints(items: page.items, profile: profile, disclosure: disclosureSerializer)
                    : nil
                let authChain = includeAuthChain
                    ? AuthChainBrief.analyze(records: page.items.map(\.record), disclosure: disclosureSerializer)
                    : nil
                let pageDTO = MCPSessionListPageDTO(
                    captureWarning: capacityWarning(status: capacity, records: page.items.map(\.record), includesHistory: true),
                    items: items,
                    nextCursor: try page.nextCursor.map { try encodeCursor($0) },
                    hasMore: page.nextCursor != nil,
                    captureEpoch: snapshotService.captureEpoch,
                    policyRevision: policyStore.policyRevision,
                    truncated: truncatedByBudget,
                    truncationReason: truncatedByBudget ? "response_exceeded_requested_budget" : nil,
                    projection: projection,
                    latestSequence: snapshotService.highWaterSequence,
                    stateToken: stateToken,
                    endpointGroups: endpointGroups,
                    authChain: authChain
                )
                encodedData = try encoder.encode(MCPDTOEnvelope(payload: pageDTO))

                if encodedData.count <= responseBudget || items.isEmpty {
                    break
                }
                if limit <= 1 {
                    throw MCPStructuredError(
                        code: .policyDenied,
                        message: "One session does not fit the requested response budget.",
                        details: [
                            "requestedBytes": String(responseBudget),
                            "requiredBytes": String(encodedData.count),
                            "recommendedAction": "use_minimal_projection_or_increase_budget"
                        ]
                    )
                }
                limit = max(1, limit / 2)
                truncatedByBudget = true
            }

            return toolStructuredResult(id: id, payload: try jsonObject(from: encodedData))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "sessions query failed."))
        }
    }

    private func sessionsSearchDigest(arguments: [String: Any]) -> String {
        let method = arguments["method"] as? String ?? ""
        let hostCategory = arguments["hostCategory"] as? String ?? ""
        let sessionIDPrefix = arguments["sessionIDPrefix"] as? String ?? ""
        let domain = arguments["domain"] as? String ?? ""
        let path = arguments["path"] as? String ?? ""
        let startedAfter = arguments["startedAfter"] as? String ?? ""
        let startedBefore = arguments["startedBefore"] as? String ?? ""
        let statusCode = (arguments["statusCode"] as? NSNumber)?.stringValue ?? ""
        let statusClass = arguments["statusClass"] as? String ?? ""
        let minDurationMs = (arguments["minDurationMs"] as? NSNumber)?.stringValue ?? ""
        let hasOverrideHit = (arguments["hasOverrideHit"] as? Bool).map(String.init) ?? ""
        let bodyAvailable = (arguments["bodyAvailable"] as? Bool).map(String.init) ?? ""
        return "search:\(method):\(hostCategory):\(sessionIDPrefix):\(domain):\(path):\(startedAfter):\(startedBefore):\(statusCode):\(statusClass):\(minDurationMs):\(hasOverrideHit):\(bodyAvailable)"
    }

    private func captureDigestTool(id: Any?, arguments: [String: Any]) -> [String: Any] {
        do {
            let counts = snapshotService.captureCounts
            let stateToken = captureStateToken()
            let unchanged = arguments["ifStateToken"] as? String == stateToken
            let knownLatestSequence = try normalizedUInt64(
                arguments["knownLatestSequence"],
                fieldName: "knownLatestSequence"
            )
            let recommendedAction: String
            if unchanged {
                recommendedAction = "reuse_cached_capture_state"
            } else if knownLatestSequence < snapshotService.highWaterSequence {
                recommendedAction = "read_sessions_since_known_sequence"
            } else {
                recommendedAction = "refresh_pending_or_selected_sessions"
            }
            let capacity = captureStatusProvider?()
            let digest = MCPCaptureDigestDTO(
                captureWarning: capacityWarning(status: capacity, records: [], includesHistory: true),
                stateToken: stateToken,
                unchanged: unchanged,
                sessionCount: counts.sessionCount,
                completedCount: counts.completedCount,
                pendingCount: counts.pendingCount,
                latestSequence: snapshotService.highWaterSequence,
                captureEpoch: snapshotService.captureEpoch,
                policyRevision: policyStore.policyRevision,
                recommendedAction: recommendedAction,
                lastEpochChangeAt: snapshotService.epochMetadata.lastEpochChangeAt,
                lastEpochChangeReason: snapshotService.epochMetadata.lastEpochChangeReason,
                previousCaptureEpoch: snapshotService.epochMetadata.previousCaptureEpoch,
                rollingCaptureAvailable: rollingCaptureStatusProvider?().isAvailable,
                rollingCaptureSavedAt: rollingCaptureStatusProvider?().savedAt,
                rollingCaptureSessionCount: rollingCaptureStatusProvider?().sessionCount,
                rollingCapturePersistenceError: rollingCaptureStatusProvider?().persistenceError,
                captureStatus: capacity
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: digest))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "capture_digest failed."))
        }
    }

    private func investigationSnapshotTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) -> [String: Any] {
        do {
            let requestedLimit = arguments["limit"] as? Int ?? 8
            guard (1...25).contains(requestedLimit) else {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "limit must be from 1 through 25."))
            }
            let sinceSequence = try normalizedUInt64(
                arguments["sinceSequence"],
                fieldName: "sinceSequence"
            )
            let counts = snapshotService.captureCounts
            let stateToken = captureStateToken()
            if arguments["ifStateToken"] as? String == stateToken {
                let payload = MCPInvestigationSnapshotDTO(
                    stateToken: stateToken,
                    unchanged: true,
                    captureEpoch: snapshotService.captureEpoch,
                    policyRevision: policyStore.policyRevision,
                    latestSequence: snapshotService.highWaterSequence,
                    sessionCount: counts.sessionCount,
                    completedCount: counts.completedCount,
                    pendingCount: counts.pendingCount,
                    sampledSessionCount: 0,
                    sampledStatusFamilies: [:],
                    sampledHostCategories: [:],
                    evidence: [],
                    recommendedNextTools: []
                )
                return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: payload))
            }
            let profile = try policyStore.resolvedProfile(for: client.assignedProfileID)
            let indexedSessions = snapshotService.recentSessions(
                limit: requestedLimit,
                minimumSequenceExclusive: sinceSequence
            )
            var statusFamilies: [String: Int] = [:]
            var hostCategories: [String: Int] = [:]
            let evidence = try indexedSessions.map { indexed -> MCPInvestigationEvidenceDTO in
                let disclosed = try disclosureSerializer.sessionSummary(
                    record: indexed.record,
                    captureSequence: indexed.captureSequence,
                    profile: profile
                )
                let summary = projectedSessionSummary(disclosed, projection: .minimal)
                let family = summary.statusCode.map { "\($0 / 100)xx" } ?? "pending"
                statusFamilies[family, default: 0] += 1
                let category = disclosed.hostCategory ?? "undisclosed"
                hostCategories[category, default: 0] += 1
                let reference = try evidenceReferenceStore.retain(
                    summary: summary,
                    clientID: client.id,
                    captureEpoch: snapshotService.captureEpoch,
                    policyRevision: policyStore.policyRevision
                )
                return MCPInvestigationEvidenceDTO(reference: reference, summary: summary)
            }
            var nextTools = ["sessions_search", "session_summary"]
            if evidence.contains(where: { ($0.summary.statusCode ?? 0) >= 400 }) {
                nextTools.insert("overrides_list", at: 0)
            }
            if evidence.contains(where: { $0.summary.mediaCategory != nil && $0.summary.mediaCategory != "other" }) {
                nextTools.append("media_readiness")
            }
            let payload = MCPInvestigationSnapshotDTO(
                stateToken: stateToken,
                unchanged: false,
                captureEpoch: snapshotService.captureEpoch,
                policyRevision: policyStore.policyRevision,
                latestSequence: snapshotService.highWaterSequence,
                sessionCount: counts.sessionCount,
                completedCount: counts.completedCount,
                pendingCount: counts.pendingCount,
                sampledSessionCount: evidence.count,
                sampledStatusFamilies: statusFamilies,
                sampledHostCategories: hostCategories,
                evidence: evidence,
                recommendedNextTools: Array(Set(nextTools)).sorted()
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: payload))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "investigation_snapshot failed."))
        }
    }

    private func auditCacheEfficiencyTool(id: Any?) -> [String: Any] {
        let sessions = snapshotService.sourceSessionStore.sessions
        let report = CacheEfficiencyAuditor.audit(sessions: sessions)
        guard let data = try? JSONEncoder().encode(report),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return structuredErrorJSONRPC(id: id, error: MCPStructuredError(code: .internalFailure, message: "Failed to encode cache efficiency audit report."))
        }
        return toolStructuredResult(id: id, payload: dict)
    }

    private func evidenceGetTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) -> [String: Any] {
        guard let evidenceRef = arguments["evidenceRef"] as? String, !evidenceRef.isEmpty else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "evidenceRef is required."))
        }
        do {
            let evidence = try evidenceReferenceStore.resolve(
                evidenceRef,
                clientID: client.id,
                captureEpoch: snapshotService.captureEpoch,
                policyRevision: policyStore.policyRevision
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: evidence))
        } catch MCPEvidenceReferenceError.staleCapture {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .staleCursor, message: "Evidence belongs to an earlier capture epoch.")
            )
        } catch MCPEvidenceReferenceError.stalePolicy {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .staleCursor, message: "Evidence was issued under an earlier policy revision.")
            )
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32004, "Evidence reference was not found or has expired."))
        }
    }

    private func readBatchTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        guard let requests = arguments["requests"] as? [[String: Any]], (1...8).contains(requests.count) else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "requests must contain from 1 through 8 read operations."))
        }
        let allowedNames: Set<String> = [
            "capture_digest", "sessions_list", "sessions_search", "session_summary",
            "investigation_snapshot", "evidence_get", "media_readiness", "media_summary",
            "media_context", "client_cleanup_status", "runtime_status"
        ]
        var results: [[String: Any]] = []
        results.reserveCapacity(requests.count)
        for (index, request) in requests.enumerated() {
            guard let name = request["name"] as? String, allowedNames.contains(name) else {
                return MCPHTTPResponse.jsonRPCObject(
                    id: id,
                    error: (-32602, "Batch item \(index) is not an allowlisted read-only tool.")
                )
            }
            let nestedArguments = request["arguments"] as? [String: Any] ?? [:]
            if name == "session_summary",
               !MCPCapabilityRouter.sensitiveReadCapabilities(from: nestedArguments).isEmpty {
                return MCPHTTPResponse.jsonRPCObject(
                    id: id,
                    error: (-32602, "Batch session_summary cannot request approval-gated fields.")
                )
            }
            let response = await handleToolsCall(
                id: "batch-\(index)",
                params: ["name": name, "arguments": nestedArguments],
                client: client,
                context: context
            )
            var item: [String: Any] = ["index": index, "name": name]
            if let nestedResult = response["result"] as? [String: Any],
               let structured = nestedResult["structuredContent"] as? [String: Any] {
                item["structuredContent"] = structured
            } else if let error = response["error"] as? [String: Any] {
                item["error"] = error
            } else {
                item["error"] = ["code": -32002, "message": "Nested read returned no structured result."]
            }
            results.append(item)
        }
        let payload: [String: Any] = [
            "captureEpoch": snapshotService.captureEpoch.rawValue,
            "policyRevision": policyStore.policyRevision.rawValue,
            "latestSequence": snapshotService.highWaterSequence,
            "results": results
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              data.count <= MCPResourceBudget.maxResponseBytes else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .policyDenied, message: "Batch result exceeds the response budget.")
            )
        }
        return toolStructuredResult(id: id, payload: payload)
    }

    private func captureMarkerCreateTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) -> [String: Any] {
        guard let markerService = captureMarkerService else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Capture markers are unavailable."))
        }
        guard let name = arguments["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "name is required."))
        }
        let detail = arguments["detail"] as? String
        let label = arguments["label"] as? String
        do {
            let record = try markerService.insertUserMarker(
                name: name,
                detail: detail,
                label: label,
                captureEpoch: snapshotService.captureEpoch
            )
            guard let indexed = snapshotService.indexedSession(id: record.id) else {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Marker session was not indexed."))
            }
            auditStore.record(
                MCPAuditEvent(
                    id: UUID(),
                    kind: .toolCall,
                    timestamp: Date(),
                    clientID: client.id,
                    credentialFingerprint: nil,
                    sourceProcess: nil,
                    reasonCode: "capture_marker_create",
                    detail: name
                )
            )
            let payload = MCPCaptureMarkerResultDTO(
                sessionID: record.id.uuidString,
                captureSequence: indexed.captureSequence,
                captureEpoch: snapshotService.captureEpoch,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: payload))
        } catch CaptureMarkerError.emptyName {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "name is required."))
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "capture_marker_create failed."))
        }
    }

    private func captureRestoreRollingTool(
        id: Any?,
        client: MCPClientRecord
    ) async -> [String: Any] {
        guard let rollingCaptureRestoreHandler else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Rolling capture restore is unavailable."))
        }
        do {
            let payload = try await rollingCaptureRestoreHandler()
            auditStore.record(
                MCPAuditEvent(
                    id: UUID(),
                    kind: .toolCall,
                    timestamp: Date(),
                    clientID: client.id,
                    credentialFingerprint: nil,
                    sourceProcess: nil,
                    reasonCode: "capture_restore_rolling",
                    detail: "\(payload["sessionCount"] ?? 0)"
                )
            )
            return toolStructuredResult(id: id, payload: payload)
        } catch RollingCaptureRestoreError.noSnapshot {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "No rolling capture snapshot is available."))
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "capture_restore_rolling failed."))
        }
    }

    private func captureStateToken() -> String {
        let counts = snapshotService.captureCounts
        let capture = captureStatusProvider?()
        return [
            snapshotService.captureEpoch.rawValue,
            policyStore.policyRevision.rawValue,
            String(snapshotService.highWaterSequence),
            String(counts.sessionCount),
            String(counts.pendingCount),
            String(counts.completedCount),
            String(snapshotService.stateRevision),
            capture?.futureBodyCapture ?? "unknown",
            String(capture?.perResponseByteLimit ?? -1),
            String(capture?.retainedBodyByteLimit ?? -1),
            String(capture?.rejectedCaptures ?? -1),
            String(capture?.metadataOnlyCaptures ?? -1)
        ].joined(separator: ":")
    }

    private func responseProjection(from arguments: [String: Any]) throws -> MCPResponseProjection {
        guard let rawValue = arguments["projection"] as? String else {
            return .minimal
        }
        guard let projection = MCPResponseProjection(rawValue: rawValue) else {
            throw MCPStructuredError.malformedRequest(
                message: "projection must be minimal, summary, or full."
            )
        }
        return projection
    }

    private func normalizedUInt64(_ value: Any?, fieldName: String) throws -> UInt64 {
        guard let value else { return 0 }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue <= Double(UInt64.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            throw MCPStructuredError.malformedRequest(
                message: "\(fieldName) must be a non-negative integer."
            )
        }
        return number.uint64Value
    }

    private func normalizedResponseBudget(_ value: Any?) throws -> Int {
        guard let value else {
            return MCPResourceBudget.maxResponseBytes
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.intValue >= 4_096,
              number.intValue <= MCPResourceBudget.maxResponseBytes else {
            throw MCPStructuredError.malformedRequest(
                message: "maxResponseBytes must be an integer from 4096 through \(MCPResourceBudget.maxResponseBytes)."
            )
        }
        return min(
            MCPResourceBudget.maxResponseBytes,
            number.intValue
        )
    }

    private func projectedSessionSummary(
        _ summary: MCPSessionSummaryDTO,
        projection: MCPResponseProjection
    ) -> MCPSessionSummaryDTO {
        switch projection {
        case .minimal:
            return MCPSessionSummaryDTO(
                id: summary.id,
                captureSequence: summary.captureSequence,
                method: summary.method,
                statusCode: summary.statusCode,
                mediaCategory: summary.mediaCategory,
                bodyUnavailableReason: summary.bodyUnavailableReason,
                bodyRecoveryAction: summary.bodyRecoveryAction,
                bodyAvailable: summary.bodyAvailable
            )
        case .summary:
            return MCPSessionSummaryDTO(
                id: summary.id,
                captureSequence: summary.captureSequence,
                method: summary.method,
                statusCode: summary.statusCode,
                startedAt: summary.startedAt,
                durationSeconds: summary.durationSeconds,
                mediaCategory: summary.mediaCategory,
                hostCategory: summary.hostCategory,
                sanitizedHost: summary.sanitizedHost,
                sanitizedPath: summary.sanitizedPath,
                bodyUnavailableReason: summary.bodyUnavailableReason,
                bodyRecoveryAction: summary.bodyRecoveryAction,
                bodyAvailable: summary.bodyAvailable,
                bodyTruncated: summary.bodyTruncated,
                mcpEffectKinds: summary.mcpEffectKinds,
                parserSummaries: summary.parserSummaries
            )
        case .full:
            return summary
        }
    }

    private func sessionsSearchFilter(arguments: [String: Any]) -> MCPSessionSnapshotService.ListFilter? {
        let method = (arguments["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostCategory = (arguments["hostCategory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionIDPrefix = (arguments["sessionIDPrefix"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = (arguments["domain"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startedAfter = isoDate(arguments["startedAfter"])
        let startedBefore = isoDate(arguments["startedBefore"])
        let statusCode: Int?
        if let number = arguments["statusCode"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue == Double(number.intValue),
           (100...599).contains(number.intValue) {
            statusCode = number.intValue
        } else {
            statusCode = nil
        }
        let statusClass = (arguments["statusClass"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let minDurationMs: Double?
        if let number = arguments["minDurationMs"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite,
           number.doubleValue >= 0 {
            minDurationMs = number.doubleValue
        } else {
            minDurationMs = nil
        }
        let hasOverrideHit = arguments["hasOverrideHit"] as? Bool
        let bodyAvailable = arguments["bodyAvailable"] as? Bool
        let filter = MCPSessionSnapshotService.ListFilter(
            method: method?.isEmpty == true ? nil : method,
            hostCategory: hostCategory?.isEmpty == true ? nil : hostCategory,
            sessionIDPrefix: sessionIDPrefix?.isEmpty == true ? nil : sessionIDPrefix,
            domain: domain?.isEmpty == true ? nil : domain,
            pathContains: path?.isEmpty == true ? nil : path,
            startedAfter: startedAfter,
            startedBefore: startedBefore,
            statusCode: statusCode,
            statusClass: statusClass?.isEmpty == true ? nil : statusClass,
            minDurationMs: minDurationMs,
            hasOverrideHit: hasOverrideHit,
            bodyAvailable: bodyAvailable
        )
        return filter.isEmpty ? nil : filter
    }

    private func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private func sessionSummaryTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext,
        brief: Bool = false
    ) async -> [String: Any] {
        guard let sessionID = arguments["sessionID"] as? String,
              let uuid = UUID(uuidString: sessionID) else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "sessionID is required."))
        }
        let fieldPointers: [String]
        let rowLimit: Int
        if brief {
            if let rawPointers = arguments["fieldPointers"] {
                guard let strings = rawPointers as? [String] else {
                    return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "fieldPointers must be an array of JSON Pointers."))
                }
                fieldPointers = strings
            } else {
                fieldPointers = []
            }
            if let rawLimit = arguments["rowLimit"] {
                guard let number = rawLimit as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(number.intValue) else {
                    return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "rowLimit must be an integer from 1 through 50."))
                }
                rowLimit = number.intValue
            } else {
                rowLimit = ResponseEvidenceBrief.defaultProjectionRows
            }
            if !fieldPointers.isEmpty,
               !ResponseEvidenceBrief.validateProjection(fieldPointers: fieldPointers, rowLimit: rowLimit) {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "fieldPointers must contain 1...8 valid non-root JSON Pointers and rowLimit must be 1...50."))
            }
        } else {
            fieldPointers = []
            rowLimit = ResponseEvidenceBrief.defaultProjectionRows
        }
        do {
            let sensitiveCapabilities = MCPCapabilityRouter.sensitiveReadCapabilities(from: arguments)
            let approvedCapabilities: Set<MCPCapabilityID>
            if sensitiveCapabilities.isEmpty {
                approvedCapabilities = []
            } else {
                approvedCapabilities = try resolveSensitiveReadApproval(
                    toolName: brief ? "response_evidence_brief" : "session_summary",
                    arguments: arguments,
                    client: client,
                    capability: MCPCapabilityRouter.primarySensitiveCapability(from: arguments) ?? .headerRead,
                    mcpSessionID: context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
                )
            }
            let profile = try policyStore.resolvedProfile(for: client.assignedProfileID)
            guard let indexed = snapshotService.indexedSession(id: uuid) else {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32004, "Session not found."))
            }
            let briefScope = brief ? try MCPBriefReadCache.scope(["response-v2", client.id, profile.id.rawValue,
                policyStore.policyRevision.rawValue, snapshotService.captureEpoch.rawValue,
                snapshotService.sourceRevisionScope(for: [uuid]),
                arguments["selectionPointer"] as? String ?? "",
                String(arguments["includeStructure"] as? Bool ?? false),
                fieldPointers.joined(separator: ","),
                String(rowLimit)]) : ""
            if brief, let unchanged = briefReadCache.unchanged(arguments["ifBriefDigest"] as? String,
                owner: client.id, scope: briefScope) {
                return toolStructuredResult(id: id, payload: unchanged)
            }
            var summary = try disclosureSerializer.sessionSummary(
                record: indexed.record,
                captureSequence: indexed.captureSequence,
                profile: profile,
                approvedCapabilities: approvedCapabilities,
                bodySource: MCPSessionBodySource(rawValue: arguments["bodySource"] as? String ?? "response") ?? .response,
                headerSource: MCPSessionHeaderSource(rawValue: arguments["headerSource"] as? String ?? "both") ?? .both
            )
            summary.captureWarning = capacityWarning(status: captureStatusProvider?(), records: [indexed.record], includesHistory: false)
            if summary.transportEvidence == nil, profile.allowedFieldClasses.contains(.duration),
               let evidence = transportEvidenceProvider?(uuid) {
                summary.transportEvidence = evidence
                summary.transportEvidenceSource = "recent_in_memory_256_request_limit"
                summary.transportDiagnostic = .assess(evidence)
            }
            if brief {
                let input = try disclosureSerializer.responseAnalysisInput(from: indexed.record, approvedCapabilities: approvedCapabilities)
                briefAnalysisExecutionCount += 1
                var report = ResponseEvidenceBrief.analyze(
                    text: input.text,
                    truncated: input.truncated,
                    unavailableReason: input.unavailableReason,
                    pointer: arguments["selectionPointer"] as? String ?? "",
                    includeStructure: arguments["includeStructure"] as? Bool ?? false,
                    fieldPointers: fieldPointers,
                    projectionLimit: rowLimit
                )
                while try encoder.encode(report).count > 60_000, report.structure?.isEmpty == false {
                    report.structure?.removeLast()
                    report.structureCoverage = "bounded"
                    report.structureLimits = Array(Set((report.structureLimits ?? []) + ["output_limit"])).sorted()
                }
                var payload = try jsonObject(from: encoder.encode(report))
                payload["sessionID"] = summary.id
                payload["captureSequence"] = summary.captureSequence
                payload["captureEpoch"] = snapshotService.captureEpoch.rawValue
                payload["policyRevision"] = policyStore.policyRevision.rawValue
                payload["bodyUnavailableReason"] = analysisUnavailableReason(input.unavailableReason)
                payload["bodyRecoveryAction"] = summary.bodyRecoveryAction
                payload["nextRead"] = "session_summary; includeBody requires existing approval; verify sourceSHA256 before comparing retained response bytes"
                payload["briefDigest"] = try briefReadCache.retain(payload: payload, owner: client.id, scope: briefScope)
                payload["unchanged"] = false
                payload["analysisReused"] = false
                guard try JSONSerialization.data(withJSONObject: payload).count <= MCPResourceBudget.maxDisclosedItemBytes else {
                    throw MCPStructuredError(code: .policyDenied, message: "Brief exceeds response budget; narrow the selection.")
                }
                return toolStructuredResult(id: id, payload: payload)
            }
            let encoded = try encoder.encode(summary)
            guard encoded.count <= MCPResourceBudget.maxDisclosedCallBytes else {
                return structuredErrorJSONRPC(
                    id: id,
                    error: MCPStructuredError(
                        code: .policyDenied,
                        message: "Disclosed session summary exceeds the approved byte budget."
                    )
                )
            }
            return toolStructuredResult(id: id, payload: try jsonObject(from: encoded))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "session_summary failed."))
        }
    }

    /// No suspension between snapshot lookup and projection: capture identity and source bytes
    /// belong to the same MainActor turn. Analysis is bounded to 32 sources and 1 MiB decoded text.
    private func investigationCompareBriefTool(id: Any?, arguments: [String: Any], client: MCPClientRecord,
                                               context: RequestContext) -> [String: Any] {
        let allowed: Set<String> = [
            "baselineSessionIDs", "candidateSessionIDs", "selectionPointer",
            "ifBriefDigest", "includeValueDiff", "ignorePointers", "approval"
        ]
        func identifiers(_ key: String) -> [UUID]? {
            guard let strings = arguments[key] as? [String], !strings.isEmpty,
                  strings.count <= InvestigationComparisonBrief.maximumSessionsPerSide else { return nil }
            let ids = strings.compactMap(UUID.init(uuidString:))
            return ids.count == strings.count && Set(ids).count == ids.count ? ids : nil
        }
        guard Set(arguments.keys).isSubset(of: allowed),
              MCPBriefReadCache.validDigest(arguments["ifBriefDigest"]),
              let baseline = identifiers("baselineSessionIDs"), let candidate = identifiers("candidateSessionIDs"),
              arguments["selectionPointer"] == nil || arguments["selectionPointer"] is String,
              (try? CollectionMockCompiler.pointer(arguments["selectionPointer"] as? String ?? "")) != nil,
              arguments["includeValueDiff"] == nil || arguments["includeValueDiff"] is Bool else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "Provide 1...16 distinct UUIDs per side and an optional valid selectionPointer."))
        }
        let includeValueDiff = arguments["includeValueDiff"] as? Bool ?? false
        let ignorePointers: [String]
        if let rawIgnore = arguments["ignorePointers"] {
            guard let strings = rawIgnore as? [String],
                  InvestigationComparisonBrief.validateIgnorePointers(strings) else {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "ignorePointers must contain up to 16 non-empty JSON Pointers."))
            }
            ignorePointers = strings
        } else {
            ignorePointers = []
        }
        do {
            let profile = try policyStore.resolvedProfile(for: client.assignedProfileID)
            guard profile.allowedFieldClasses.isSuperset(of: [.method, .sanitizedHost, .sanitizedPath, .statusCode]) else {
                throw MCPStructuredError(code: .policyDenied, message: "Comparison requires structural request metadata disclosure.")
            }
            var sensitive = arguments
            sensitive["includeBody"] = true
            let approved = try resolveSensitiveReadApproval(toolName: "investigation_compare_brief", arguments: sensitive,
                client: client, capability: .bodyRead,
                mcpSessionID: context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()])
            let briefScope = try MCPBriefReadCache.scope(["comparison-v2", client.id, profile.id.rawValue,
                policyStore.policyRevision.rawValue, snapshotService.captureEpoch.rawValue,
                snapshotService.sourceRevisionScope(for: baseline + candidate),
                baseline.map(\.uuidString).joined(separator: ","), candidate.map(\.uuidString).joined(separator: ","),
                arguments["selectionPointer"] as? String ?? "",
                String(includeValueDiff),
                ignorePointers.joined(separator: ",")])
            if let unchanged = briefReadCache.unchanged(arguments["ifBriefDigest"] as? String, owner: client.id, scope: briefScope) {
                return toolStructuredResult(id: id, payload: unchanged)
            }
            var remaining = InvestigationComparisonBrief.maximumAggregateInputBytes
            var inputs: [UUID: InvestigationComparisonBrief.Input] = [:]
            for uuid in baseline + candidate where inputs[uuid] == nil {
                var source = InvestigationComparisonBrief.Source(sessionID: uuid.uuidString, analysisStatus: "session_missing")
                guard let indexed = snapshotService.indexedSession(id: uuid) else {
                    inputs[uuid] = .init(source: source)
                    continue
                }
                source.captureSequence = indexed.captureSequence
                // Align only on disclosed request metadata; query/header values must not influence
                // a comparison under a body-read grant. Redaction can make alignment ambiguous.
                var alignmentRecord = indexed.record
                let request = indexed.record.request
                alignmentRecord.request = CapturedRequest(method: request.method, scheme: request.scheme,
                    host: disclosureSerializer.sanitizedHost(request.host), port: request.port,
                    path: disclosureSerializer.sanitizedPath(request.path), headers: [], bodyData: nil, bodySize: nil)
                let input = try disclosureSerializer.responseAnalysisInput(from: indexed.record, approvedCapabilities: approved)
                source.unavailableReason = analysisUnavailableReason(input.unavailableReason)
                let count = input.text?.utf8.count ?? 0
                guard count <= remaining else {
                    source.analysisStatus = "aggregate_input_limit"
                    inputs[uuid] = .init(source: source, record: alignmentRecord)
                    continue
                }
                remaining -= count
                briefAnalysisExecutionCount += 1
                let brief = ResponseEvidenceBrief.analyze(text: input.text, truncated: input.truncated,
                    unavailableReason: input.unavailableReason, pointer: arguments["selectionPointer"] as? String ?? "",
                    includeStructure: true)
                source.analysisStatus = brief.status
                source.sourceSHA256 = brief.sourceSHA256
                inputs[uuid] = .init(
                    source: source,
                    record: alignmentRecord,
                    brief: brief,
                    bodyText: includeValueDiff ? input.text : nil
                )
            }
            var report = InvestigationComparisonBrief.compare(
                baseline: baseline.compactMap { inputs[$0] },
                candidate: candidate.compactMap { inputs[$0] },
                selectionPointer: arguments["selectionPointer"] as? String ?? "",
                includeValueDiff: includeValueDiff,
                ignorePointers: ignorePointers
            )
            while try encoder.encode(report).count > 32_768 {
                if var vChanges = report.valueChanges, !vChanges.isEmpty {
                    vChanges.removeLast()
                    report.valueChanges = vChanges
                    report.omittedValueChangeCount = (report.omittedValueChangeCount ?? 0) + 1
                    report.status = "incomplete"
                } else if !report.changes.isEmpty {
                    report.changes.removeLast()
                    report.omittedChangeCount += 1
                    report.status = "incomplete"
                } else {
                    break
                }
            }
            var payload = try jsonObject(from: encoder.encode(report))
            payload["captureEpoch"] = snapshotService.captureEpoch.rawValue
            payload["policyRevision"] = policyStore.policyRevision.rawValue
            payload["selectionPointer"] = arguments["selectionPointer"] as? String ?? ""
            payload["briefDigest"] = try briefReadCache.retain(payload: payload, owner: client.id, scope: briefScope)
            payload["unchanged"] = false
            payload["analysisReused"] = false
            guard try JSONSerialization.data(withJSONObject: payload).count <= MCPResourceBudget.maxDisclosedItemBytes else {
                throw MCPStructuredError(code: .policyDenied, message: "Comparison exceeds response budget; narrow the selection.")
            }
            return toolStructuredResult(id: id, payload: payload)
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Investigation comparison failed."))
        }
    }

    private func filteredCalculation(id: Any?, arguments: [String: Any], client: MCPClientRecord,
                                     context: RequestContext) async throws -> [String: Any] {
        guard try JSONSerialization.data(withJSONObject: MCPArgumentDigest.dispatchArguments(arguments)).count <= 8192,
              Set(arguments.keys).isSubset(of: ["filter", "operation", "dataset", "selectionPointer", "approval"]),
              arguments["dataset"] as? String == "sessionMetadata", arguments["selectionPointer"] as? String == "",
              let operation = arguments["operation"] as? [String: Any],
              let scope = arguments["filter"] as? [String: String],
              Set(scope.keys).isSubset(of: ["method", "domain", "path", "startedAfter", "startedBefore"]),
              scope.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }),
              let filter = sessionsSearchFilter(arguments: scope), let start = filter.startedAfter,
              let end = filter.startedBefore, start <= end else { throw ArtifactAnalysisFailure.malformedRequest }
        let query = try ArtifactCalculation.Query(selectionPointer: "", operation: operation)
        guard query.kind == .rowCount || (query.kind == .groupCount && query.fieldPointer == "/statusCode"),
              query.predicate == nil || query.predicate?.fieldPointer == "/statusCode" else {
            throw ArtifactAnalysisFailure.malformedRequest
        }
        let profile = try policyStore.resolvedProfile(for: client.assignedProfileID)
        var fields: Set<MCPPolicyFieldClass> = [.timestamps]
        if filter.pathContains != nil { fields.insert(.sanitizedPath) }
        if filter.domain != nil { fields.insert(.sanitizedHost) }
        if filter.method != nil { fields.insert(.method) }
        if query.kind == .groupCount || query.predicate?.fieldPointer == "/statusCode" { fields.insert(.statusCode) }
        guard fields.isSubset(of: profile.allowedFieldClasses) else {
            throw MCPStructuredError(code: .policyDenied, message: "Profile does not grant the selected metadata.")
        }
        guard !artifactWorker.busy else { throw ArtifactAnalysisFailure.busy }
        var approval = arguments
        approval["includeBody"] = true
        _ = try resolveSensitiveReadApproval(toolName: "capture_calculate", arguments: approval, client: client,
            capability: .bodyRead, mcpSessionID: context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()],
            reason: "Count retained metadata in the selected capture window.")
        let revision = snapshotService.stateRevision
        let epoch = snapshotService.captureEpoch
        let policy = policyStore.policyRevision
        let records = snapshotService.sourceSessionStore.sessions
        guard records.count <= 50_000 else { throw ArtifactAnalysisFailure.inputLimit }
        let serializer = disclosureSerializer
        let needsStatus = query.kind == .groupCount || query.predicate?.fieldPointer == "/statusCode"
        let report = try await artifactWorker.perform {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            var rows: [ArtifactJSONValue] = []
            for (index, record) in records.enumerated() {
                if index.isMultiple(of: 64) { try ArtifactSnapshotReader.check(deadline) }
                guard MCPSessionSnapshotService.matchesFilter(record, filter: filter, disclosure: serializer) else { continue }
                guard rows.count < 10_000 else { throw ArtifactAnalysisFailure.inputLimit }
                if needsStatus, let status = record.response?.statusCode {
                    rows.append(.object([("statusCode", .number(String(status)))]))
                } else {
                    rows.append(.object([]))
                }
            }
            return try ArtifactCalculation.analyze(rows: rows, query: query, deadline: deadline)
        }
        guard let current = clientRegistry.client(id: client.id), current.credentialState == .active,
              current.credentialGeneration == client.credentialGeneration, current.assignedProfileID == client.assignedProfileID,
              policy == policyStore.policyRevision, policyEvaluator.effectiveAllows(capability: .bodyRead, client: current)
        else { throw ArtifactAnalysisFailure.sourceUnavailable }
        guard revision == snapshotService.stateRevision, epoch == snapshotService.captureEpoch else {
            throw ArtifactAnalysisFailure.sourceChanged
        }
        var payload = try jsonObject(from: encoder.encode(report))
        payload["filter"] = scope
        payload["captureEpoch"] = epoch.rawValue
        payload["stateRevision"] = revision
        payload["scannedRows"] = records.count
        payload["snapshotSemantics"] = "retained_sessions_at_revision"
        if let reset = snapshotService.epochMetadata.lastEpochChangeAt, start <= reset {
            payload["historyChangedSinceWindowStart"] = true
        }
        if let status = captureStatusProvider?() {
            if status.rejectedCaptures > 0, (status.lastIncompleteCaptureAt ?? .distantFuture) >= start,
               (status.firstIncompleteCaptureAt ?? .distantPast) <= end {
                payload["possibleCaptureGap"] = true
            }
        } else { payload["admissionCoverage"] = "unknown" }
        if snapshotService.droppedSessionCount > 0 { payload["historyTrimmed"] = true }
        if let groups = report.result.groups {
            let activeRows = report.filteredRows ?? report.rows
            payload["rowsInOmittedGroups"] = activeRows - groups.reduce(0) { $0 + $1.count }
        }
        guard try JSONSerialization.data(withJSONObject: payload).count <= 16_384 else { throw ArtifactAnalysisFailure.outputLimit }
        return toolStructuredResult(id: id, payload: payload)
    }

    private func captureCalculateTool(id: Any?, arguments: [String: Any], client: MCPClientRecord,
                                      context: RequestContext) async -> [String: Any] {
        do {
            if arguments["filter"] != nil { return try await filteredCalculation(id: id, arguments: arguments, client: client, context: context) }
            let allowed: Set<String> = ["sessionIDs", "dataset", "selectionPointer", "operation", "operations", "approval"]
            let hasSingle = arguments["operation"] != nil
            let hasBatch = arguments["operations"] != nil
            guard Set(arguments.keys).isSubset(of: allowed),
                  hasSingle != hasBatch,
                  let strings = arguments["sessionIDs"] as? [String], !strings.isEmpty, strings.count <= 256,
                  Set(strings).count == strings.count,
                  let dataset = arguments["dataset"] as? String,
                  dataset == "responseJSON" || dataset == "sessionMetadata",
                  dataset != "responseJSON" || strings.count == 1,
                  let pointer = arguments["selectionPointer"] as? String,
                  try JSONSerialization.data(withJSONObject: MCPArgumentDigest.dispatchArguments(arguments)).count <= 8192 else {
                throw ArtifactAnalysisFailure.malformedRequest
            }
            let ids = strings.compactMap(UUID.init(uuidString:))
            guard ids.count == strings.count, Set(ids).count == ids.count else { throw ArtifactAnalysisFailure.malformedRequest }
            let queries: [ArtifactCalculation.Query]
            if let operation = arguments["operation"] as? [String: Any] {
                queries = [try ArtifactCalculation.Query(selectionPointer: pointer, operation: operation)]
            } else if let rawOps = arguments["operations"] as? [Any], !rawOps.isEmpty, rawOps.count <= 4 {
                queries = try rawOps.map { item -> ArtifactCalculation.Query in
                    guard let op = item as? [String: Any] else { throw ArtifactAnalysisFailure.malformedRequest }
                    return try ArtifactCalculation.Query(selectionPointer: pointer, operation: op)
                }
            } else {
                throw ArtifactAnalysisFailure.malformedRequest
            }
            if dataset == "sessionMetadata" {
                for query in queries { try ArtifactSessionProjection.validateMetadata(query) }
            }
            guard !artifactWorker.busy else { throw ArtifactAnalysisFailure.busy }
            var approvalArguments = arguments
            approvalArguments["includeBody"] = true
            _ = try resolveSensitiveReadApproval(toolName: "capture_calculate", arguments: approvalArguments,
                client: client, capability: .bodyRead,
                mcpSessionID: context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()],
                reason: "Calculate selected captured traffic locally; counts, group keys and selected scalar values may be returned.")
            let epoch = snapshotService.captureEpoch
            let revisions = snapshotService.sourceRevisionScope(for: ids)
            let policyRevision = policyStore.policyRevision
            let records = try ids.map { id -> SessionRecord in
                guard let indexed = snapshotService.indexedSession(id: id) else { throw ArtifactAnalysisFailure.sourceUnavailable }
                return indexed.record
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            let evidence: (encodedReport: Data, analyzerVersion: String, sha256: String) = try await artifactWorker.perform {
                let projections = records.map { ArtifactSessionProjection(record: $0, includeBody: dataset == "responseJSON") }
                if dataset == "responseJSON" {
                    guard let bytes = projections[0].responseJSON else { throw ArtifactAnalysisFailure.incompleteSelection }
                    let sha = ArtifactSnapshotReader.hash(bytes)
                    if hasBatch {
                        let batch = try ArtifactCalculation.analyzeBatch(data: bytes, selectionPointer: pointer, queries: queries, deadline: deadline)
                        return (try JSONEncoder().encode(batch), batch.analyzerVersion, sha)
                    } else {
                        let single = try ArtifactCalculation.analyze(data: bytes, query: queries[0], deadline: deadline)
                        return (try JSONEncoder().encode(single), single.analyzerVersion, sha)
                    }
                }
                guard records.reduce(0, { $0 + $1.request.method.utf8.count }) <= 1_048_576 else {
                    throw ArtifactAnalysisFailure.inputLimit
                }
                let rows = projections.map(\.metadata)
                let bytes = try ArtifactJSONValue.array(rows).encoded(maximum: 1_048_576, deadline: deadline)
                let sha = ArtifactSnapshotReader.hash(bytes)
                if hasBatch {
                    let batch = try ArtifactCalculation.analyzeBatch(rows: rows, selectionPointer: pointer, queries: queries, deadline: deadline)
                    return (try JSONEncoder().encode(batch), batch.analyzerVersion, sha)
                } else {
                    let single = try ArtifactCalculation.analyze(rows: rows, query: queries[0], deadline: deadline)
                    return (try JSONEncoder().encode(single), single.analyzerVersion, sha)
                }
            }
            guard let currentClient = clientRegistry.client(id: client.id),
                  currentClient.credentialState == .active,
                  currentClient.credentialGeneration == client.credentialGeneration,
                  currentClient.assignedProfileID == client.assignedProfileID,
                  policyRevision == policyStore.policyRevision,
                  policyEvaluator.effectiveAllows(capability: .bodyRead, client: currentClient) else {
                throw ArtifactAnalysisFailure.sourceUnavailable
            }
            guard epoch == snapshotService.captureEpoch,
                  revisions == snapshotService.sourceRevisionScope(for: ids) else { throw ArtifactAnalysisFailure.sourceChanged }
            var payload = try jsonObject(from: evidence.encodedReport)
            payload["sourceKind"] = "live_capture"
            payload["sourceSHA256"] = evidence.sha256
            payload["queryDigest"] = try MCPBriefReadCache.scope([MCPArgumentDigest.normalized(arguments), evidence.sha256,
                evidence.analyzerVersion, revisions, epoch.rawValue, policyRevision.rawValue, client.assignedProfileID.rawValue])
            payload["sessionIDs"] = strings
            payload["sourceRevisions"] = ids.map { snapshotService.sourceRevision(for: $0) ?? 0 }
            payload["captureEpoch"] = epoch.rawValue
            payload["policyRevision"] = policyRevision.rawValue
            payload["snapshotSemantics"] = "selected_retained_sources_at_analysis; later traffic is not included"
            guard try JSONSerialization.data(withJSONObject: payload).count <= 16_384 else { throw ArtifactAnalysisFailure.outputLimit }
            return toolStructuredResult(id: id, payload: payload)
        } catch let failure as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: failure)
        } catch {
            return artifactAnalysisError(id: id, error: error)
        }
    }

    private func artifactAnalysisError(id: Any?, error: Error) -> [String: Any] {
        let reason = (error as? ArtifactAnalysisFailure)?.rawValue ?? "analysis_unavailable"
        var response = toolStructuredResult(id: id, payload: ["status": "unavailable", "reason": reason,
            "result": NSNull(), "analysisReused": false])
        var result = response["result"] as? [String: Any] ?? [:]
        result["isError"] = true
        response["result"] = result
        return response
    }

    private func artifactSourceTool(id: Any?, name: String, arguments: [String: Any],
                                    client: MCPClientRecord, context: RequestContext) async -> [String: Any] {
        do {
            guard let registry = artifactSources else { throw ArtifactAnalysisFailure.sourceUnavailable }
            let owner = ArtifactSourceRegistry.Owner(clientID: client.id, generation: client.credentialGeneration,
                policyRevision: policyStore.policyRevision, profile: client.assignedProfileID)
            if name == "artifact_compare_responses" {
                guard let session = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()] else {
                    throw ArtifactAnalysisFailure.sourceUnavailable
                }
                let query = try SavedResponsePair(arguments)
                let baseline = try registry.pairSource(query.baseline, owner: owner)
                let candidate = try registry.pairSource(query.candidate, owner: owner)
                guard let old = baseline.snapshot, let new = candidate.snapshot else { throw ArtifactAnalysisFailure.sourceUnavailable }
                let deadline = try registry.admitPair(query, owner: owner, session: session, clientName: client.displayName,
                    baseline: baseline, candidate: candidate)
                let ids = Set([baseline.id, candidate.id])
                for id in ids { registry.setInUse(id, true) }
                defer { for id in ids { registry.setInUse(id, false) } }
                let connected = context.isConnected
                var report = try await registry.worker.perform { try query.report(baseline: old, candidate: new, isConnected: connected) }
                var response = toolStructuredResult(id: id, payload: try jsonObject(from: encoder.encode(report)))
                while try JSONSerialization.data(withJSONObject: response).count > 65_536 {
                    guard !report.changes.isEmpty else { throw ArtifactAnalysisFailure.outputLimit }
                    report.changes.removeLast()
                    report.omittedChangeCount += 1
                    report.status = "incomplete"
                    response = toolStructuredResult(id: id, payload: try jsonObject(from: encoder.encode(report)))
                }
                let requestKey = requestKey(from: id)
                // Async dispatch and serialization precede this final synchronous check at the HTTP handoff.
                context.finalPairCheck = { [self] in
                    defer { if let requestKey { sessions[session]?.cancelledRequestIDs.remove(requestKey) } }
                    do {
                        _ = try registry.pairSource(query.baseline, owner: owner)
                        _ = try registry.pairSource(query.candidate, owner: owner)
                        guard let bound = sessions[session], !bound.restricted, bound.clientID == owner.clientID,
                              !terminatingSessionIDs.contains(session), Date() < deadline else { throw ArtifactAnalysisFailure.sourceUnavailable }
                        guard connected(), !Task.isCancelled, requestKey.map({ !bound.cancelledRequestIDs.contains($0) }) ?? true else {
                            throw ArtifactAnalysisFailure.cancelled
                        }
                        return nil
                    } catch {
                        let rejection = artifactAnalysisError(id: id, error: error)
                        return MCPHTTPResponse.jsonResponse(status: 200, headers: [MCPNetworkConstants.sessionIDHeader: session],
                            object: sessions[session]?.structuredResultsOnly == true ? structuredOnlyToolResponse(rejection) : rejection)
                    }
                }
                return response
            }
            if name == "artifact_source_register" {
                guard Set(arguments.keys).isSubset(of: ["requestKey", "kind", "scopes", "ttlSeconds", "approval"]),
                      let key = arguments["requestKey"] as? String,
                      let kindName = arguments["kind"] as? String, let kind = ArtifactSourceKind(rawValue: kindName),
                      let scopes = arguments["scopes"] as? [String],
                      policyEvaluator.effectiveAllows(capability: .artifactSourceAccess, client: client),
                      !scopes.contains("brief-v1") || policyEvaluator.effectiveAllows(capability: .artifactBrief, client: client),
                      !scopes.contains("search-v1") || policyEvaluator.effectiveAllows(capability: .artifactSearch, client: client),
                      !scopes.contains("calculations-v1") || policyEvaluator.effectiveAllows(capability: .artifactCalculate, client: client) else {
                    throw ArtifactAnalysisFailure.malformedRequest
                }
                let ttl: Int
                if let supplied = arguments["ttlSeconds"] {
                    guard let number = supplied as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue == Double(number.intValue) else { throw ArtifactAnalysisFailure.malformedRequest }
                    ttl = number.intValue
                } else { ttl = 1800 }
                let request = try registry.register(key: key, kind: kind, scopes: scopes, ttl: ttl, owner: owner,
                    argumentDigest: MCPArgumentDigest.normalized(arguments),
                    sessionID: context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()])
                if request.state == "ready" { return try artifactDescriptor(id: id, request: request) }
                if request.state == "approved_awaiting_retry" {
                    _ = try resolveSensitiveReadApproval(toolName: name, arguments: arguments, client: client,
                        capability: .artifactSourceAccess, mcpSessionID: context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()])
                    return try artifactDescriptor(id: id, request: registry.publish(id: request.id, owner: owner))
                }
                if ["pending_selection", "preparing", "review"].contains(request.state) {
                    throw MCPStructuredError.approvalRequired(request.approval)
                }
                throw ArtifactAnalysisFailure.sourceUnavailable
            }
            if name == "artifact_source_status" {
                guard Set(arguments.keys) == ["requestKey"], let key = arguments["requestKey"] as? String else { throw ArtifactAnalysisFailure.malformedRequest }
                let request = try registry.status(key: key, owner: owner)
                // Until approval, never expose selected filenames, dimensions, counts or parse details.
                return toolStructuredResult(id: id, payload: ["status": request.state,
                    "requestID": request.id, "deadline": MCPApprovalPolicy.iso8601String(from: request.deadline),
                    "reason": request.localFailure == nil ? NSNull() as Any : "preparation_failed" as Any])
            }
            guard let handle = arguments["handle"] as? String else { throw ArtifactAnalysisFailure.malformedRequest }
            if name == "artifact_source_release" {
                guard Set(arguments.keys) == ["handle"] else { throw ArtifactAnalysisFailure.malformedRequest }
                try registry.release(handle: handle, clientID: client.id)
                return toolStructuredResult(id: id, payload: ["status": "released"])
            }
            let request = try registry.inspect(handle: handle, owner: owner)
            if name == "artifact_source_inspect" {
                guard Set(arguments.keys) == ["handle"] else { throw ArtifactAnalysisFailure.malformedRequest }
                return try artifactDescriptor(id: id, request: request)
            }
            if name == "artifact_response_brief" {
                guard request.scopes.contains("brief-v1"), owner.profile == .shareable,
                      policyEvaluator.effectiveAllows(capability: .artifactBrief, client: client),
                      let revision = arguments["snapshotRevision"] as? String, request.revision == revision,
                      let snapshot = request.snapshot else { throw ArtifactAnalysisFailure.sourceUnavailable }
                let query = try SavedResponseBrief(arguments: arguments)
                registry.setInUse(request.id, true)
                defer { registry.setInUse(request.id, false) }
                let report = try await registry.worker.perform { try query.report(snapshot: snapshot) }
                var payload = try jsonObject(from: encoder.encode(report))
                if report.status != "complete" {
                    payload["reason"] = report.status
                    payload["status"] = "unavailable"
                }
                payload["handle"] = handle
                payload["snapshotRevision"] = revision
                payload["recordIndex"] = query.recordIndex
                payload["dataset"] = "responseJSON"
                payload["analyzerVersion"] = "artifact-response-brief-v1"
                payload["sourceWarnings"] = snapshot.warnings
                let response = toolStructuredResult(id: id, payload: payload)
                guard try JSONSerialization.data(withJSONObject: response).count <= 65_536 else { throw ArtifactAnalysisFailure.outputLimit }
                let current = try registry.inspect(handle: handle, owner: owner)
                guard current.revision == revision, current.scopes.contains("brief-v1") else { throw ArtifactAnalysisFailure.sourceUnavailable }
                try Task.checkCancellation()
                return response
            }
            if name == "artifact_inventory" || name == "artifact_search" {
                guard request.scopes.contains("search-v1"), owner.profile == .shareable,
                      policyEvaluator.effectiveAllows(capability: .artifactSearch, client: client),
                      let revision = arguments["snapshotRevision"] as? String, revision == request.revision else {
                    throw ArtifactAnalysisFailure.sourceUnavailable
                }
                let query = try ArtifactSearchQuery(inventory: name == "artifact_inventory", arguments: arguments)
                let payload = try await registry.searchSessions.run(registry: registry, request: request, query: query,
                    token: arguments["cursor"] as? String) { payload in
                    try JSONSerialization.data(withJSONObject: self.toolStructuredResult(id: id, payload: payload)).count
                }
                _ = try registry.inspect(handle: handle, owner: owner)
                try Task.checkCancellation()
                return toolStructuredResult(id: id, payload: payload)
            }
            let hasSingle = arguments["operation"] != nil
            let hasBatch = arguments["operations"] != nil
            guard Set(arguments.keys).isSubset(of: ["handle", "snapshotRevision", "dataset", "selectionPointer", "operation", "operations"]),
                  hasSingle != hasBatch,
                  let revision = arguments["snapshotRevision"] as? String, revision == request.revision,
                  request.scopes.contains("calculations-v1"),
                  policyEvaluator.effectiveAllows(capability: .artifactCalculate, client: client),
                  let snapshot = request.snapshot, let datasetObject = arguments["dataset"] as? [String: Any],
                  let pointer = arguments["selectionPointer"] as? String,
                  try JSONSerialization.data(withJSONObject: arguments).count <= 8192 else { throw ArtifactAnalysisFailure.malformedRequest }
            let queries: [ArtifactCalculation.Query]
            if let operation = arguments["operation"] as? [String: Any] {
                queries = [try ArtifactCalculation.Query(selectionPointer: pointer, operation: operation)]
            } else if let rawOps = arguments["operations"] as? [Any], !rawOps.isEmpty, rawOps.count <= 4 {
                queries = try rawOps.map { item -> ArtifactCalculation.Query in
                    guard let op = item as? [String: Any] else { throw ArtifactAnalysisFailure.malformedRequest }
                    return try ArtifactCalculation.Query(selectionPointer: pointer, operation: op)
                }
            } else {
                throw ArtifactAnalysisFailure.malformedRequest
            }
            let dataset = try ArtifactCalculationDataset(datasetObject)
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            registry.setInUse(request.id, true)
            defer { registry.setInUse(request.id, false) }
            let (encodedReport, analyzerVersion) = try await artifactWorker.perform {
                if hasBatch {
                    let batch = try snapshot.calculateBatch(dataset: dataset, selectionPointer: pointer, queries: queries, deadline: deadline)
                    return (try JSONEncoder().encode(batch), batch.analyzerVersion)
                } else {
                    let single = try snapshot.calculate(dataset: dataset, query: queries[0], deadline: deadline)
                    return (try JSONEncoder().encode(single), single.analyzerVersion)
                }
            }
            _ = try registry.inspect(handle: handle, owner: owner)
            var payload = try jsonObject(from: encodedReport)
            payload["handle"] = handle
            payload["snapshotRevision"] = revision
            payload["sourceSHA256"] = snapshot.sourceSHA256
            payload["queryDigest"] = try MCPBriefReadCache.scope([MCPArgumentDigest.normalized(arguments), snapshot.sourceSHA256,
                analyzerVersion, revision, owner.policyRevision.rawValue, owner.profile.rawValue, request.scopes.joined(separator: ",")])
            payload["sourceCoverage"] = snapshot.invalidRecordCount == 0 && !snapshot.warnings.contains("declared_count_mismatch") ? "complete" : "incomplete_source"
            payload["dataset"] = datasetObject
            payload["snapshotSemantics"] = "approved_immutable_copy; original file changes are not tracked"
            guard try JSONSerialization.data(withJSONObject: payload).count <= 16_384 else { throw ArtifactAnalysisFailure.outputLimit }
            return toolStructuredResult(id: id, payload: payload)
        } catch let failure as MCPStructuredError { return structuredErrorJSONRPC(id: id, error: failure) }
        catch { return artifactAnalysisError(id: id, error: error) }
    }

    private func artifactDescriptor(id: Any?, request: ArtifactSourceRegistry.Request) throws -> [String: Any] {
        guard let snapshot = request.snapshot, let handle = request.handle, let revision = request.revision,
              let expiry = request.expiresAt else { throw ArtifactAnalysisFailure.sourceUnavailable }
        var payload: [String: Any] = ["status": "ready", "handle": handle, "snapshotRevision": revision,
            "kind": snapshot.kind.rawValue, "scopes": request.scopes, "bytes": snapshot.byteCount,
            "expiresAt": MCPApprovalPolicy.iso8601String(from: expiry), "recordCount": snapshot.records.count,
            "invalidRecordCount": snapshot.invalidRecordCount, "warnings": snapshot.warnings,
            "snapshotSemantics": "approved_immutable_copy; original file changes are not tracked"]
        if let schema = snapshot.schemaVersion { payload["schemaVersion"] = schema }
        if let frames = snapshot.frameCount { payload["frameCount"] = frames }
        if let width = snapshot.imageWidth { payload["width"] = width }
        if let height = snapshot.imageHeight { payload["height"] = height }
        if let orientation = snapshot.imageOrientation { payload["orientation"] = orientation }
        if request.scopes.contains("calculations-v1") { payload["sourceSHA256"] = snapshot.sourceSHA256 }
        guard try JSONSerialization.data(withJSONObject: payload).count <= 4096 else { throw ArtifactAnalysisFailure.outputLimit }
        return toolStructuredResult(id: id, payload: payload)
    }

    private func analysisUnavailableReason(_ reason: String?) -> String? {
        reason?.hasPrefix("unsupported_encoding:") == true ? "unsupported_encoding" : reason
    }

    /// Bulk session export (`sessions_export`) for HAR/JSON/NDJSON, gated by the same
    /// `.bodyRead`/`.headerRead` approval model as `session_summary` — one approval covers the
    /// whole bulk call because approval keys on the exact argument set, not per-session. Records
    /// that aren't approved for body/header disclosure are exported with those fields stripped
    /// rather than failing the whole export.
    ///
    /// File delivery: `deliverFile=true` (CLI `--output` / full HAR) walks all matching sessions
    /// unless `maxSessions` is set explicitly, writes under ``sessionExportDirectory``, and returns
    /// ``MCPSessionExportResultDTO/outputPath``. Inline delivery stays within the 500-session /
    /// 1 MB budgets and auto-spills to the same directory when the MCP response would overflow.
    private func sessionsExportTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        do {
            let format = (arguments["format"] as? String)?.lowercased() ?? "json"
            guard ["json", "ndjson", "har"].contains(format) else {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "format must be json, ndjson, or har."))
            }
            let deliverFile = arguments["deliverFile"] as? Bool == true
            let sensitiveCapabilities = MCPCapabilityRouter.sensitiveReadCapabilities(from: arguments)
            let approvedCapabilities: Set<MCPCapabilityID>
            if sensitiveCapabilities.isEmpty {
                approvedCapabilities = []
            } else {
                approvedCapabilities = try resolveSensitiveReadApproval(
                    toolName: "sessions_export",
                    arguments: arguments,
                    client: client,
                    capability: MCPCapabilityRouter.primarySensitiveCapability(from: arguments) ?? .headerRead,
                    mcpSessionID: context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
                )
            }
            _ = try policyStore.resolvedProfile(for: client.assignedProfileID)

            let filter = sessionsSearchFilter(arguments: arguments)
            let maxSessions = resolvedExportMaxSessions(arguments: arguments, deliverFile: deliverFile)

            var indexed: [MCPSessionSnapshotService.IndexedSession] = []
            var cursor: MCPSessionQueryCursor?
            var hasMore = true
            while hasMore, indexed.count < maxSessions {
                let pageLimit = min(MCPResourceBudget.maxPageSize, maxSessions - indexed.count)
                let page = try snapshotService.page(
                    request: MCPSessionSnapshotService.PageRequest(
                        limit: pageLimit,
                        cursor: cursor,
                        queryDigest: "sessions_export:\(sessionsSearchDigest(arguments: arguments))",
                        orderingDigest: "sequence_asc",
                        filter: filter
                    ),
                    clientID: client.id,
                    policyRevision: policyStore.policyRevision
                )
                indexed.append(contentsOf: page.items)
                cursor = page.nextCursor
                hasMore = cursor != nil
            }
            let truncated = hasMore

            let records = indexed.map { redactedRecord($0.record, approvedCapabilities: approvedCapabilities) }
            let envelope = SessionExportEnvelope(
                exportedAt: Date(),
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                proxyPort: 0, // cosmetic only (HAR/JSON metadata) — MCPProtocolService has no proxy-port dependency.
                sessionCount: records.count,
                sessions: records
            )

            let data: Data
            switch format {
            case "har": data = try HARSessionExportService().harData(envelope)
            case "ndjson": data = try JSONSessionExportService().ndjsonData(envelope)
            default: data = try JSONSessionExportService().jsonData(envelope)
            }

            if deliverFile {
                let path = try MCPSessionExportFileStore.writeExport(
                    data: data,
                    format: format,
                    directory: sessionExportDirectory
                )
                let result = MCPSessionExportResultDTO(
                    format: format,
                    sessionCount: records.count,
                    truncated: truncated,
                    content: nil,
                    outputPath: path,
                    contentByteCount: data.count
                )
                return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: result))
            }

            guard let content = String(data: data, encoding: .utf8) else {
                throw MCPStructuredError(code: .internalFailure, message: "Export content was not valid UTF-8.")
            }
            let inlineResult = MCPSessionExportResultDTO(
                format: format,
                sessionCount: records.count,
                truncated: truncated,
                content: content,
                outputPath: nil,
                contentByteCount: data.count
            )
            let inlineEnvelope = MCPDTOEnvelope(payload: inlineResult)
            let encodedInline = try encoder.encode(inlineEnvelope)
            if encodedInline.count <= MCPResourceBudget.maxResponseBytes {
                return toolStructuredResult(id: id, payload: try jsonObject(from: encodedInline))
            }

            // Auto-spill when inline delivery would exceed the MCP response budget.
            let path = try MCPSessionExportFileStore.writeExport(
                data: data,
                format: format,
                directory: sessionExportDirectory
            )
            let spilled = MCPSessionExportResultDTO(
                format: format,
                sessionCount: records.count,
                truncated: truncated,
                content: nil,
                outputPath: path,
                contentByteCount: data.count
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: spilled))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "sessions_export failed."))
        }
    }

    private func reproExportPackageTool(id: Any?, arguments: [String: Any]) -> [String: Any] {
        do {
            let title = arguments["title"] as? String ?? "JoesProxy Reproduction"
            let notes = arguments["notes"] as? String ?? "Sanitized capture evidence and safe replay instructions."
            let requestedLimit = (arguments["maxSessions"] as? NSNumber)?.intValue
                ?? ReproPackageEngine.maximumSessionCount
            guard requestedLimit > 0, requestedLimit <= ReproPackageEngine.maximumSessionCount else {
                return MCPHTTPResponse.jsonRPCObject(
                    id: id,
                    error: (-32602, "maxSessions must be between 1 and \(ReproPackageEngine.maximumSessionCount).")
                )
            }
            let records = Array(snapshotService.sourceSessionStore.sessions.prefix(requestedLimit))
            let engine = ReproPackageEngine()
            let package = try engine.makePackage(
                title: title,
                notes: notes,
                sessions: records,
                hypothesisGraphs: HypothesisDAGEngine.shared.allGraphs(),
                appVersion: Bundle.main.marketingVersionOrDev
            )
            let data = try engine.data(for: package)
            let path = try MCPSessionExportFileStore.writeExport(
                data: data,
                format: "jproxy-repro",
                directory: sessionExportDirectory
            )
            return try encodedToolResult(
                id: id,
                payload: MCPDTOEnvelope(
                    payload: MCPReproExportResult(
                        outputPath: path,
                        contentByteCount: data.count,
                        inspection: engine.inspection(of: package)
                    )
                )
            )
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "repro_export_package failed."))
        }
    }

    private func reproInspectPackageTool(id: Any?, arguments: [String: Any]) -> [String: Any] {
        do {
            guard let encoded = arguments["packageBase64"] as? String,
                  let data = Data(base64Encoded: encoded) else {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "packageBase64 is required."))
            }
            let engine = ReproPackageEngine()
            let package = try engine.read(data: data)
            return try encodedToolResult(
                id: id,
                payload: MCPDTOEnvelope(payload: engine.inspection(of: package))
            )
        } catch let error as ReproPackageError {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, error.localizedDescription))
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "repro_inspect_package failed."))
        }
    }

    /// Resolves the session walk bound for ``sessions_export``.
    ///
    /// - Inline (`deliverFile` false): default and hard cap 500.
    /// - File delivery: uncapped unless the caller passes an explicit `maxSessions` safety valve
    ///   (up to 1_000_000).
    private func resolvedExportMaxSessions(arguments: [String: Any], deliverFile: Bool) -> Int {
        let fileDeliveryCap = 1_000_000
        if let requested = (arguments["maxSessions"] as? NSNumber)?.intValue {
            let capped = deliverFile ? fileDeliveryCap : 500
            return min(max(requested, 1), capped)
        }
        return deliverFile ? fileDeliveryCap : 500
    }

    /// Strips headers/body from a record's request and response when the corresponding capability
    /// wasn't approved for this export call — redact, don't fail the export.
    private func redactedRecord(
        _ record: SessionRecord,
        approvedCapabilities: Set<MCPCapabilityID>
    ) -> SessionRecord {
        var transformed = record
        if !approvedCapabilities.contains(.headerRead) {
            transformed.request = CapturedRequest(
                method: record.request.method,
                scheme: record.request.scheme,
                inspectionKind: record.request.inspectionKind,
                inspectionReason: record.request.inspectionReason,
                host: record.request.host,
                port: record.request.port,
                path: record.request.path,
                headers: [],
                bodyData: approvedCapabilities.contains(.bodyRead) ? record.request.bodyData : nil,
                bodySize: record.request.bodySize,
                bodyTruncated: record.request.bodyTruncated,
                recordingBodyOmissionReason: approvedCapabilities.contains(.bodyRead) ? nil : .metadataOnly
            )
        } else if !approvedCapabilities.contains(.bodyRead) {
            transformed.request = CapturedRequest(
                method: record.request.method,
                scheme: record.request.scheme,
                inspectionKind: record.request.inspectionKind,
                inspectionReason: record.request.inspectionReason,
                host: record.request.host,
                port: record.request.port,
                path: record.request.path,
                headers: record.request.headers,
                bodyData: nil,
                bodySize: record.request.bodySize,
                bodyTruncated: false,
                recordingBodyOmissionReason: .metadataOnly
            )
        }
        if let response = record.response {
            if !approvedCapabilities.contains(.headerRead) {
                transformed.response = CapturedResponse(
                    statusCode: response.statusCode,
                    headers: [],
                    bodyData: approvedCapabilities.contains(.bodyRead) ? response.bodyData : nil,
                    bodySize: response.bodySize,
                    source: response.source,
                    sourceDescription: response.sourceDescription,
                    bodyTruncated: response.bodyTruncated,
                    recordingBodyOmissionReason: approvedCapabilities.contains(.bodyRead) ? nil : .metadataOnly
                )
            } else if !approvedCapabilities.contains(.bodyRead) {
                transformed.response = CapturedResponse(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    bodyData: nil,
                    bodySize: response.bodySize,
                    source: response.source,
                    sourceDescription: response.sourceDescription,
                    bodyTruncated: false,
                    recordingBodyOmissionReason: .metadataOnly
                )
            }
        }
        return transformed
    }

    private func mediaSummaryTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) -> [String: Any] {
        do {
            _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
            let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
            let summary = try mediaInspectionService.summary(
                sessionID: sessionID,
                policyRevision: policyStore.policyRevision
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: summary))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "media_summary failed."))
        }
    }

    private func mediaReadinessTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) -> [String: Any] {
        do {
            _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
            let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
            let readiness = try mediaInspectionService.mediaReadiness(
                sessionID: sessionID,
                policyRevision: policyStore.policyRevision
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: readiness))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "media_readiness failed."))
        }
    }

    private func mediaContextTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) -> [String: Any] {
        do {
            _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
            let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
            let context = try mediaInspectionService.mediaContext(
                sessionID: sessionID,
                policyRevision: policyStore.policyRevision
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: context))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "media_context failed."))
        }
    }

    private func mediaManifestStructureTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) -> [String: Any] {
        do {
            _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
            let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
            let structure = try mediaInspectionService.manifestStructure(
                sessionID: sessionID,
                policyRevision: policyStore.policyRevision
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: structure))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "media_manifest_structure failed."))
        }
    }

    private func responseContextTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) -> [String: Any] {
        do {
            let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
            let payload = try responseEditService.responseContext(sessionID: sessionID, client: client)
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: payload))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "response_context failed."))
        }
    }

    private func responseTextSearchTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        do {
            let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
            guard let find = arguments["find"] as? String else {
                throw MCPStructuredError.malformedRequest(message: "find is required.")
            }
            let includeContext = arguments["includeContext"] as? Bool == true
            let mcpSessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
            if includeContext {
                _ = try resolveSensitiveReadApproval(
                    toolName: "response_text_search",
                    arguments: arguments,
                    client: client,
                    capability: .bodyRead,
                    mcpSessionID: mcpSessionID
                )
            }
            let payload = try responseEditService.responseTextSearch(
                sessionID: sessionID,
                find: find,
                includeContext: includeContext,
                client: client,
                mcpSessionID: mcpSessionID
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: payload))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "response_text_search failed."))
        }
    }

    private func responseTextReadTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        do {
            let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
            let mcpSessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
            _ = try resolveSensitiveReadApproval(
                toolName: "response_text_read",
                arguments: arguments,
                client: client,
                capability: .bodyRead,
                mcpSessionID: mcpSessionID
            )
            let payload = try responseEditService.responseTextRead(
                sessionID: sessionID,
                offset: arguments["byteOffset"] as? Int,
                length: arguments["byteLength"] as? Int,
                cursor: arguments["cursor"] as? String,
                client: client,
                mcpSessionID: mcpSessionID
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: payload))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "response_text_read failed."))
        }
    }

    private func mediaRelatedSessionsTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) -> [String: Any] {
        do {
            _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
            let sourceID = try requiredUUID(arguments["sessionID"], name: "sessionID")
            let limit = disclosureSerializer.normalizedPageSize(arguments["limit"] as? Int)
            let cursor = try decodeMediaRelatedCursor(arguments["cursor"])
            if let cursor {
                guard cursor.clientID == client.id,
                      cursor.sourceSessionID == sourceID.uuidString,
                      cursor.captureEpoch == snapshotService.captureEpoch,
                      cursor.policyRevision == policyStore.policyRevision else {
                    throw MCPStructuredError(
                        code: .staleCursor,
                        message: "Media relationship cursor is no longer valid."
                    )
                }
            }
            let highWater = cursor?.highWaterSequence ?? snapshotService.highWaterSequence
            let startSequence = cursor?.lastSequence ?? 0
            let relatedResult = try mediaInspectionService.relatedSessions(sessionID: sourceID)
            let related = relatedResult.items.compactMap { item -> MCPMediaRelatedSessionDTO? in
                    guard let indexed = snapshotService.indexedSession(id: item.sessionID),
                          indexed.captureSequence > startSequence,
                          indexed.captureSequence <= highWater else {
                        return nil
                    }
                    return MCPMediaRelatedSessionDTO(
                        sessionID: item.sessionID.uuidString,
                        captureSequence: indexed.captureSequence,
                        relationship: item.relationship,
                        matchStrategy: item.matchStrategy,
                        mediaType: mcpMediaTypeName(MediaDetector.mediaType(for: indexed.record))
                    )
                }
                .sorted { $0.captureSequence < $1.captureSequence }
            let pageItems = Array(related.prefix(limit))
            let nextCursor: String?
            if related.count > pageItems.count, let last = pageItems.last {
                nextCursor = try encodeMediaRelatedCursor(
                    MCPMediaRelatedCursor(
                        clientID: client.id,
                        sourceSessionID: sourceID.uuidString,
                        captureEpoch: snapshotService.captureEpoch,
                        policyRevision: policyStore.policyRevision,
                        highWaterSequence: highWater,
                        lastSequence: last.captureSequence
                    )
                )
            } else {
                nextCursor = nil
            }
            let payload = MCPMediaRelatedSessionsPageDTO(
                sourceSessionID: sourceID.uuidString,
                status: relatedResult.status,
                candidateCount: relatedResult.candidateCount,
                skippedBodyReasons: relatedResult.skippedBodyReasons,
                attemptedStrategies: relatedResult.attemptedStrategies,
                indexedThroughSequence: relatedResult.indexedThroughSequence,
                items: pageItems,
                nextCursor: nextCursor,
                disclosure: MCPMediaDisclosureContextDTO(
                    captureEpoch: snapshotService.captureEpoch,
                    policyRevision: policyStore.policyRevision,
                    generatedAt: Date(),
                    removedFields: ["rawURLs", "queryValues", "matchedReferences"],
                    partialResultReason: relatedResult.status == "partial"
                        ? "One or more candidate manifest bodies were unavailable or malformed."
                        : nil,
                    truncated: false
                )
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: payload))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "media_related_sessions failed."))
        }
    }

    private func mediaInspectionStartTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        do {
            _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
            let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
            guard let analysisValues = arguments["analyses"] as? [String],
                  !analysisValues.isEmpty else {
                throw MCPStructuredError.malformedRequest(message: "analyses is required.")
            }
            let analyses = try analysisValues.map { value -> MCPMediaAnalysisKind in
                guard let analysis = MCPMediaAnalysisKind(rawValue: value) else {
                    throw MCPStructuredError.malformedRequest(message: "Unknown media analysis: \(value)")
                }
                return analysis
            }
            guard Set(analyses).count == analyses.count else {
                throw MCPStructuredError.malformedRequest(message: "analyses must not contain duplicates.")
            }
            // JSONSerialization bridges JSON true/false to NSNumber too, so `as? NSNumber` alone
            // would silently accept `"sampleTimeSeconds": true` as 1.0 despite the schema declaring
            // a number type — exclude CFBoolean explicitly.
            let sampleTime: TimeInterval
            if let number = arguments["sampleTimeSeconds"] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID() {
                sampleTime = number.doubleValue
            } else {
                sampleTime = 1
            }
            guard let mcpSessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()] else {
                throw MCPStructuredError(code: .unauthorized, message: "Logical MCP session is required.")
            }
            let descriptor = try operationCoordinator.startMediaInspection(
                clientID: client.id,
                mcpSessionID: mcpSessionID,
                sourceSessionID: sessionID,
                analyses: analyses,
                sampleTime: sampleTime,
                argumentDigest: MCPArgumentDigest.normalized(arguments)
            ) {
                _ = try resolveSensitiveReadApproval(
                    toolName: "media_inspection_start",
                    arguments: arguments,
                    client: client,
                    capability: .mediaInspection,
                    mcpSessionID: mcpSessionID
                )
            }
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: descriptor))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "media_inspection_start failed."))
        }
    }

    private func operationStatusTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) -> [String: Any] {
        operationTool(id: id, arguments: arguments, client: client, context: context, cancel: false)
    }

    private func operationCancelTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) -> [String: Any] {
        operationTool(id: id, arguments: arguments, client: client, context: context, cancel: true)
    }

    private func operationTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext,
        cancel: Bool
    ) -> [String: Any] {
        do {
            _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
            guard let operationID = arguments["operationID"] as? String, !operationID.isEmpty else {
                throw MCPStructuredError.malformedRequest(message: "operationID is required.")
            }
            guard let mcpSessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()] else {
                throw MCPStructuredError(code: .unauthorized, message: "Logical MCP session is required.")
            }
            let descriptor = if cancel {
                try operationCoordinator.cancel(
                    operationID: operationID,
                    clientID: client.id,
                    mcpSessionID: mcpSessionID
                )
            } else {
                try operationCoordinator.descriptor(
                    operationID: operationID,
                    clientID: client.id,
                    mcpSessionID: mcpSessionID
                )
            }
            let projection = try responseProjection(from: arguments)
            let includeResult = arguments["includeResult"] as? Bool == true
            if projection == .full || includeResult {
                return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: descriptor))
            }
            let unchanged = arguments["ifStatus"] as? String == descriptor.status.rawValue
            let summary = MCPOperationStatusSummaryDTO(
                operationID: descriptor.operationID,
                status: descriptor.status,
                progress: descriptor.progress,
                currentStage: descriptor.currentStage,
                operationKind: descriptor.operationKind,
                warningCount: descriptor.warnings.count,
                failureCode: descriptor.failureCode,
                resultAvailable: descriptor.result != nil,
                retryAfterMs: operationRetryAfterMs(for: descriptor.status),
                unchanged: unchanged,
                stages: projection == .summary ? descriptor.stages : nil,
                warnings: projection == .summary ? descriptor.warnings : nil,
                result: nil
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: summary))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "operation request failed."))
        }
    }

    private func clientCleanupStatusTool(
        id: Any?,
        client: MCPClientRecord
    ) async -> [String: Any] {
        do {
            _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
            let status = await clientCleanupStatus(client: client)
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: status))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "client_cleanup_status failed."))
        }
    }

    private func clientCleanupStatus(client: MCPClientRecord) async -> MCPClientCleanupStatusDTO {
        let clientOperationCount = operationCoordinator.activeOperationCount(forClientID: client.id)
        if let recoveryService {
            return await recoveryService.clientCleanupStatus(
                clientID: client.id,
                activeOperationCount: clientOperationCount,
                policyRevision: policyStore.policyRevision
            )
        }
        let pendingApprovalCount = approvalStore.pendingRequests.filter { $0.clientID == client.id }.count
        let isClean = clientOperationCount == 0 && pendingApprovalCount == 0
        return MCPClientCleanupStatusDTO(
            isClean: isClean,
            state: isClean ? "clean" : "cleanup_required",
            reasonCodes: [
                clientOperationCount > 0 ? "active_operations" : nil,
                pendingApprovalCount > 0 ? "pending_approvals" : nil
            ].compactMap { $0 },
            recommendedAction: isClean ? "safe_to_terminate" : "terminate_session_for_automatic_cleanup",
            activeEffectCount: 0,
            cleanupConflictCount: 0,
            activeOperationCount: clientOperationCount,
            pendingApprovalCount: pendingApprovalCount,
            activeScenarioCount: 0,
            activeFixtureRunCount: 0,
            policyRevision: policyStore.policyRevision,
            recentApprovalOutcomes: approvalStore.recentStatuses(clientID: client.id)
        )
    }

    private func httpsRulesTool(id: Any?, name: String, arguments: [String: Any],
                                client: MCPClientRecord, context: RequestContext) -> [String: Any] {
        do {
            guard let httpsRulesReader, let httpsRulesWriter else {
                throw MCPStructuredError(code: .internalFailure, message: "HTTPS rules unavailable.")
            }
            let changing = name != "https_rules_get"
            let restoring = name == "https_rules_restore"
            let allowed: Set<String> = changing
                ? ["host", "mode", "expectedRevision", "scope", "approval", "recoveryID"] : ["host", "recoveryID"]
            guard Set(arguments.keys).isSubset(of: allowed) else { throw MCPHTTPSRules.invalid() }
            let host = try MCPHTTPSRules.host(arguments["host"])
            let current = httpsRulesReader()
            var recoveryID: UUID?
            if let value = arguments["recoveryID"] {
                guard let text = value as? String, let id = UUID(uuidString: text) else { throw MCPHTTPSRules.invalid() }
                recoveryID = id
            }
            var receipt = try recoveryID.flatMap { try httpsRecoveryJournal.receipt(id: $0, owner: client.id) }
            if let receipt, receipt.host != host { throw MCPHTTPSRules.invalid() }
            if !changing {
                if recoveryID != nil && receipt == nil {
                    throw MCPStructuredError(code: .staleProposal, message: "Recovery receipt unavailable or retired. Inspect current rules; do not assume a mutation succeeded.")
                }
            } else {
                guard arguments["scope"] as? String == "host_and_subdomains_all_clients",
                      arguments["expectedRevision"] is String else { throw MCPHTTPSRules.invalid() }
                let updated: TLSInterceptionRules
                if restoring {
                    guard arguments["mode"] == nil, var saved = receipt else { throw MCPHTTPSRules.invalid() }
                    if saved.phase == .abandoned || (saved.phase == .applyPrepared && current == saved.before) {
                        // No settings to undo. Close the prepared intent without pretending restore occurred.
                        saved.phase = .abandoned
                        try httpsRecoveryJournal.save(saved)
                        var payload = MCPHTTPSRules.inspection(current, host: host, globalMode: httpsRulesGlobalMode)
                        payload["recovery"] = saved.projection(current: current)
                        return toolStructuredResult(id: id, payload: payload)
                    }
                    // A repeat after a lost restore reply is inspection, never another write.
                    if saved.phase == .restored || (saved.phase == .restorePrepared && current == saved.before) {
                        saved.phase = .restored
                        try httpsRecoveryJournal.save(saved)
                        var payload = MCPHTTPSRules.inspection(current, host: host, globalMode: httpsRulesGlobalMode)
                        payload["recovery"] = saved.projection(current: current)
                        return toolStructuredResult(id: id, payload: payload)
                    }
                    guard current == saved.after, saved.before != saved.after else {
                        throw MCPStructuredError(code: .staleProposal, message: "Recovery settings conflict or no change was applied. Inspect the receipt and rules; no automatic merge or replay is permitted.")
                    }
                    updated = saved.before
                } else {
                    guard let mode = MCPHTTPSRules.Mode(rawValue: arguments["mode"] as? String ?? "") else { throw MCPHTTPSRules.invalid() }
                    if let saved = receipt {
                        guard saved.mode == mode.rawValue,
                              arguments["expectedRevision"] as? String == MCPHTTPSRules.revision(saved.before) else {
                            throw MCPStructuredError(code: .staleProposal, message: "Recovery ID already describes different arguments. Inspect it; do not reuse it for another change.")
                        }
                        var payload = MCPHTTPSRules.inspection(current, host: host, globalMode: httpsRulesGlobalMode)
                        payload["recovery"] = saved.projection(current: current)
                        return toolStructuredResult(id: id, payload: payload)
                    }
                    updated = try MCPHTTPSRules.changed(current, host: host, mode: mode)
                    if let recoveryID {
                        receipt = MCPHTTPSRecoveryJournal.Receipt(id: recoveryID, owner: client.id, host: host,
                            mode: mode.rawValue, before: current, after: updated, createdAt: Date())
                    }
                }
                guard arguments["expectedRevision"] as? String == MCPHTTPSRules.revision(current) else {
                    throw MCPStructuredError(code: .staleProposal, message: "HTTPS rules changed. Read https_rules_get and review a new change; do not retry with a substituted revision automatically.")
                }
                if updated != current {
                    let changeDescription = restoring
                        ? "restore prior custom rules (tunnel=\(updated.bypassDomains.contains { $0.lowercased() == host }), inspect=\(updated.interceptDomains.contains { $0.lowercased() == host }))"
                        : (arguments["mode"] as? String ?? "")
                    _ = try resolveSensitiveReadApproval(toolName: name, arguments: arguments, client: client,
                        capability: .httpsRulesManage,
                        mcpSessionID: context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()],
                        reason: "Persist HTTPS rule \(changeDescription) for \(host) and subdomains, ALL clients, NEW connections. Tunneling hides bodies and disables HTTP modifications; TCP only, not QUIC. Recovery does not close connections or prove playback; bundle cleanup does not undo this setting.")
                    if var saved = receipt {
                        if restoring { saved.phase = .restorePrepared }
                        try httpsRecoveryJournal.save(saved) // Durable intent precedes any settings write.
                        receipt = saved
                    }
                    httpsRulesWriter(updated)
                    guard httpsRulesReader() == updated else {
                        throw MCPStructuredError(code: .internalFailure, message: "Settings write did not verify. Inspect current rules and recovery receipt before any further mutation.")
                    }
                    if restoring, var saved = receipt {
                        saved.phase = .restored
                        try httpsRecoveryJournal.save(saved)
                        receipt = saved
                    }
                    auditStore.record(MCPAuditEvent(id: UUID(), kind: .proposalApplied, timestamp: Date(),
                        clientID: client.id, reasonCode: restoring ? "https_rules_restored" : "https_rules_changed",
                        detail: "Persistent HTTPS domain preference changed after exact approval; all clients, new connections."))
                } else if let receipt { try httpsRecoveryJournal.save(receipt) }
            }
            var payload = MCPHTTPSRules.inspection(httpsRulesReader(), host: host, globalMode: httpsRulesGlobalMode)
            if let receipt { payload["recovery"] = receipt.projection(current: httpsRulesReader()) }
            if !changing && recoveryID == nil {
                payload["recoveryHistory"] = httpsRecoveryJournal.history(host: host, owner: client.id, current: current)
            }
            return toolStructuredResult(id: id, payload: payload)
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return structuredErrorJSONRPC(id: id, error: MCPHTTPSRules.invalid())
        }
    }

    private func runtimeControlTool(
        id: Any?,
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        do {
            guard let action = MCPRuntimeControlAction(toolName: name), let runtimeControlHandler else {
                throw MCPStructuredError(code: .internalFailure, message: "Runtime control is unavailable.")
            }
            if action == .resumeCapture, !Set(arguments.keys).isSubset(of: ["approval"]) {
                throw MCPStructuredError(code: .malformedRequest,
                    message: "capture_resume accepts only optional approval. It cannot force admission or change limits. Example: capture_resume {}.")
            }
            if action == .startProxy || action == .resumeCapture, let managedRuntimeStatusProvider {
                let host = await managedRuntimeStatusProvider()
                try MCPRuntimeControlSafetyPolicy.validateRemoteAction(
                    action,
                    systemProxyManagementEnabled: host.systemProxyManagementEnabled
                )
            }
            let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
            _ = try resolveSensitiveReadApproval(
                toolName: name,
                arguments: arguments,
                client: client,
                capability: .runtimeControl,
                mcpSessionID: sessionID,
                reason: "Runtime control \(name) requires in-app approval."
            )
            if action == .stopMCP {
                let cleanup = await clientCleanupStatus(client: client)
                guard cleanup.isClean else {
                    throw MCPStructuredError(
                        code: .policyDenied,
                        message: "MCP cannot stop while this client requires cleanup: \(cleanup.reasonCodes.joined(separator: ", "))."
                    )
                }
            }
            var payload = try await runtimeControlHandler(action)
            if action == .resumeCapture {
                payload["resumeRestoresHistoricalBodies"] = false
                if let status = captureStatusProvider?() {
                    payload["captureStatus"] = try jsonObject(from: encoder.encode(status))
                } else {
                    payload["captureStatusUnavailable"] = true
                }
            }
            return toolStructuredResult(id: id, payload: payload)
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "\(name) failed."))
        }
    }

    private func runtimeStatusTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async -> [String: Any] {
        do {
            guard let managedRuntimeStatusProvider else {
                throw MCPStructuredError(code: .internalFailure, message: "Managed runtime status is unavailable.")
            }
            let host = await managedRuntimeStatusProvider()
            let cleanup = await clientCleanupStatus(client: client)
            let runtimeIdentity = MCPRuntimeIdentityBuilder.current()
            let compatibility = MCPRuntimeCompatibilityEvaluator.evaluate(
                runtime: runtimeIdentity,
                expectation: runtimeCompatibilityExpectation(from: arguments["expectedRuntime"])
            )
            let profileAllowsControl = policyEvaluator.profileAllows(
                capability: .runtimeControl,
                profileID: client.assignedProfileID
            )
            let isDenied = grantStore.isAlwaysDenied(capability: .runtimeControl, clientID: client.id)
            let grant = grantStore.activeGrant(capability: .runtimeControl, clientID: client.id)
            var checks: [MCPRuntimeReadinessCheckDTO] = [
                MCPRuntimeReadinessCheckDTO(
                    id: "credential",
                    state: client.credentialState == .active ? "pass" : "action_required",
                    detail: client.credentialState == .active ? "Credential is active." : "Credential requires rotation or reenrollment.",
                    recommendedAction: client.credentialState == .active ? nil : "Rotate the JoesProxy CLI credential in MCP Management."
                ),
                MCPRuntimeReadinessCheckDTO(
                    id: "cli_startup",
                    state: host.cliAutomationStartEnabled ? "pass" : "action_required",
                    detail: host.cliAutomationStartEnabled ? "CLI-initiated MCP startup is enabled." : "CLI-initiated MCP startup is disabled.",
                    recommendedAction: host.cliAutomationStartEnabled ? nil : "Enable Allow JoesProxy CLI to start MCP in MCP Management > Overview."
                ),
                MCPRuntimeReadinessCheckDTO(
                    id: "runtime_policy",
                    state: profileAllowsControl && !isDenied ? "pass" : "action_required",
                    detail: profileAllowsControl && !isDenied ? "The client profile permits runtime control." : "The client profile or an always-deny rule blocks runtime control.",
                    recommendedAction: profileAllowsControl && !isDenied ? nil : "Assign the Shareable profile and remove any runtime-control denial."
                ),
                MCPRuntimeReadinessCheckDTO(
                    id: "runtime_grant",
                    state: grant == nil ? "action_required" : "pass",
                    detail: grant.map { "Runtime control grant is active (\($0.mode.rawValue))." } ?? "Runtime control still requires per-call approval.",
                    recommendedAction: grant == nil ? "Approve a runtime command and choose Add To Client Policy for unattended use." : nil
                ),
                MCPRuntimeReadinessCheckDTO(
                    id: "cleanup",
                    state: cleanup.isClean ? "pass" : "action_required",
                    detail: cleanup.isClean ? "No client-owned cleanup blocks safe MCP shutdown." : "Cleanup is required: \(cleanup.reasonCodes.joined(separator: ", ")).",
                    recommendedAction: cleanup.isClean ? nil : "Run joesproxyctl cleanup status and resolve the reported state."
                )
            ]
            if host.proxyState == "failed" {
                checks.append(MCPRuntimeReadinessCheckDTO(
                    id: "proxy",
                    state: "warning",
                    detail: "The proxy is in a failed state.",
                    recommendedAction: "Resolve the proxy failure before retrying joesproxyctl proxy start."
                ))
            }
            if host.systemProxyManagementEnabled {
                checks.append(MCPRuntimeReadinessCheckDTO(
                    id: "system_proxy_management",
                    state: "action_required",
                    detail: "Mac traffic routing is armed. MCP and CLI are not permitted to start the proxy because doing so could activate Mac-wide routing.",
                    recommendedAction: "Start the proxy manually in JoesProxy, or manually turn Mac routing off before using MCP or CLI runtime control."
                ))
            }
            if let isCompatible = compatibility.compatible {
                checks.append(MCPRuntimeReadinessCheckDTO(
                    id: "runtime_compatibility",
                    state: isCompatible ? "pass" : "action_required",
                    detail: isCompatible
                        ? "The client identity is compatible with this running app."
                        : "The client identity does not match this running app's capability contract.",
                    recommendedAction: compatibility.recommendedActions.first
                ))
            }
            let ready = client.credentialState == .active
                && host.cliAutomationStartEnabled
                && profileAllowsControl
                && !isDenied
                && grant != nil
                && cleanup.isClean
                && host.proxyState != "failed"
                && !host.systemProxyManagementEnabled
                && compatibility.compatible != false
            var commands: [String] = []
            if !host.cliAutomationStartEnabled { commands.append("joesproxyctl mcp start") }
            if !profileAllowsControl || isDenied || grant == nil { commands.append("joesproxyctl proxy start --wait-for-approval") }
            if !cleanup.isClean { commands.append("joesproxyctl cleanup status") }
            if ready && host.proxyState != "running" { commands.append("joesproxyctl proxy start") }
            if ready && host.proxyState == "running" { commands.append("joesproxyctl capture digest") }
            // Report every active grant this client actually holds, not a preselected subset —
            // a capability missing from this list is real evidence "no standing grant," not just
            // evidence "we didn't check for one."
            let activeStandingGrants = grantStore.activeGrants(for: client.id).map(\.capability.rawValue)
            let payload = MCPRuntimeReadinessDTO(
                readyForUnattendedControl: ready,
                state: ready ? "ready" : "action_required",
                clientID: client.id,
                profileID: client.assignedProfileID,
                runtimeControlGrantMode: grant?.mode,
                runtimeControlGrantExpiresAt: grant?.expiresAt,
                host: host,
                cleanup: cleanup,
                checks: checks,
                recommendedNextCommands: Array(commands.prefix(3)),
                capabilitiesBundleVersion: MCPCapabilitiesRevision.bundleVersion(),
                runtimeIdentity: runtimeIdentity,
                compatibility: compatibility,
                policyRevision: policyStore.policyRevision,
                activeStandingGrants: activeStandingGrants.isEmpty ? nil : activeStandingGrants
            )
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: payload))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "runtime_status failed."))
        }
    }

    private func runtimeCompatibilityExpectation(
        from value: Any?
    ) -> MCPRuntimeCompatibilityExpectationDTO? {
        guard let object = value as? [String: Any] else { return nil }
        return MCPRuntimeCompatibilityExpectationDTO(
            appBuildFingerprint: object["appBuildFingerprint"] as? String,
            marketingVersion: object["marketingVersion"] as? String,
            buildVersion: object["buildVersion"] as? String,
            capabilitiesBundleVersion: object["capabilitiesBundleVersion"] as? String,
            capabilitiesManifestDigest: object["capabilitiesManifestDigest"] as? String,
            skillVersion: object["skillVersion"] as? String
        )
    }

    private func setupReadinessTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async -> [String: Any] {
        guard let rawTarget = arguments["target"] as? String,
              let target = MCPSetupReadinessTarget(rawValue: rawTarget) else {
            return MCPHTTPResponse.jsonRPCObject(
                id: id,
                error: (-32602, "setup_readiness requires target: macOS, iOS/iPadOS, tvOS, Simulator, or generic.")
            )
        }
        guard let setupReadinessProvider else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Setup readiness is unavailable."))
        }
        do {
            let payload = await setupReadinessProvider(target, client.credentialState)
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: payload))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "setup_readiness failed."))
        }
    }

    private func operationRetryAfterMs(for status: MCPOperationStatus) -> Int? {
        switch status {
        case .pendingApproval:
            return 1_000
        case .running, .cancelling:
            return 500
        case .completed, .partial, .failed, .cancelled, .expired:
            return nil
        }
    }

    private func encodedToolResult<Payload: Codable & Sendable>(
        id: Any?,
        payload: MCPDTOEnvelope<Payload>
    ) throws -> [String: Any] {
        let data = try encoder.encode(payload)
        guard data.count <= MCPResourceBudget.maxResponseBytes else {
            throw MCPStructuredError(code: .policyDenied, message: "MCP media result exceeds the response budget.")
        }
        return toolStructuredResult(id: id, payload: try jsonObject(from: data))
    }

    private func requiredUUID(_ value: Any?, name: String) throws -> UUID {
        guard let string = value as? String, let uuid = UUID(uuidString: string) else {
            throw MCPStructuredError.malformedRequest(message: "\(name) must be a UUID.")
        }
        return uuid
    }

    private func requiredString(_ value: Any?, name: String) throws -> String {
        guard let string = value as? String, !string.isEmpty else {
            throw MCPStructuredError.malformedRequest(message: "\(name) must be a non-empty string.")
        }
        return string
    }

    private func optionalUUID(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    private func uuidArray(_ value: Any?) -> [UUID] {
        (value as? [String] ?? []).compactMap(UUID.init(uuidString:))
    }

    private func stringArray(_ value: Any?) -> [String] {
        value as? [String] ?? []
    }

    private func decodedArray<T: Decodable>(_ value: Any?, as type: T.Type, name: String) throws -> [T] {
        guard let rawArray = value as? [[String: Any]] else {
            return []
        }
        let data = try JSONSerialization.data(withJSONObject: rawArray)
        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            throw MCPStructuredError.malformedRequest(message: "\(name) is malformed: \(error.localizedDescription)")
        }
    }

    private func encodedArrayObject<T: Encodable>(_ value: [T], key: String) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw MCPStructuredError(code: .internalFailure, message: "Response serialization failed.")
        }
        return [key: array]
    }

    // MARK: - Advanced agentic diagnostics (AG-1..AG-6) and related tool families

    private func agenticGraphTool(id: Any?, name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "propose_hypothesis_dag":
                let planName = try requiredString(arguments["name"], name: "name")
                let targetBug = try requiredString(arguments["targetBug"], name: "targetBug")
                let nodeInputs = try decodedArray(arguments["nodeInputs"], as: MCPHypothesisNodeInput.self, name: "nodeInputs")
                let dto = try agenticService.proposeHypothesisDAG(
                    name: planName, targetBug: targetBug, nodeInputs: nodeInputs,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "step_hypothesis_graph":
                let graphID = try requiredUUID(arguments["graphID"], name: "graphID")
                let matches = arguments["evidenceMatches"] as? Bool ?? false
                let summary = try requiredString(arguments["evidenceSummary"], name: "evidenceSummary")
                let dto = try agenticService.stepHypothesisGraph(
                    graphID: graphID, evidenceMatches: matches, evidenceSummary: summary,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "get_fault_bisection_report":
                let graphID = try requiredUUID(arguments["graphID"], name: "graphID")
                let dto = try agenticService.getFaultBisectionReport(graphID: graphID, policyRevision: policyStore.policyRevision)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown hypothesis-DAG tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Hypothesis-DAG operation failed."))
        }
    }

    private func llmInspectionTool(id: Any?, name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "llm_stream_inspection":
                let sessionIDs = uuidArray(arguments["sessionIDs"])
                let canaries = stringArray(arguments["configuredCanaries"])
                let reports = try llmInspectionService.llmStreamInspection(
                    sessionIDs: sessionIDs, configuredCanaries: canaries,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedArrayObject(reports, key: "reports"))
            case "propose_llm_stream_fault":
                let faultName = try requiredString(arguments["name"], name: "name")
                let urlPattern = try requiredString(arguments["urlPattern"], name: "urlPattern")
                let faultKind = try requiredString(arguments["faultKind"], name: "faultKind")
                let delayMs = arguments["delayMs"] as? Int
                let targetTokenIndex = arguments["targetTokenIndex"] as? Int
                let dto = try llmInspectionService.proposeLLMStreamFault(
                    name: faultName, urlPattern: urlPattern, faultKind: faultKind,
                    delayMs: delayMs, targetTokenIndex: targetTokenIndex,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown LLM inspection tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "LLM stream operation failed."))
        }
    }

    private func concurrencyFuzzingTool(id: Any?, name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "propose_temporal_permutation_plan":
                let planName = try requiredString(arguments["name"], name: "name")
                let targetBatch = try requiredString(arguments["targetBatch"], name: "targetBatch")
                let endpoints = try decodedArray(arguments["endpoints"], as: MCPPermutationEndpointInput.self, name: "endpoints")
                let spacingMs = arguments["spacingMs"] as? Int ?? 150
                let dto = try concurrencyFuzzingService.proposeTemporalPermutationPlan(
                    name: planName, targetBatch: targetBatch, endpoints: endpoints, spacingMs: spacingMs,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "step_temporal_permutation_plan":
                let planID = try requiredUUID(arguments["planID"], name: "planID")
                let errorDetected = arguments["errorDetected"] as? Bool ?? false
                let outcomeSummary = try requiredString(arguments["outcomeSummary"], name: "outcomeSummary")
                let dto = try concurrencyFuzzingService.stepTemporalPermutationPlan(
                    planID: planID, errorDetected: errorDetected, outcomeSummary: outcomeSummary,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "get_race_condition_fuzz_report":
                let planID = try requiredUUID(arguments["planID"], name: "planID")
                let dto = try concurrencyFuzzingService.getRaceConditionFuzzReport(planID: planID, policyRevision: policyStore.policyRevision)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown concurrency-fuzzing tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Concurrency-fuzzing operation failed."))
        }
    }

    private func resilienceTool(id: Any?, name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "propose_resilience_bisection_plan":
                let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
                let planName = (arguments["name"] as? String) ?? "Payload Resilience Bisection"
                let dto = try resilienceService.proposeResilienceBisectionPlan(
                    sessionID: sessionID, name: planName, policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "step_resilience_bisection_plan":
                let planID = try requiredUUID(arguments["planID"], name: "planID")
                let clientCrashed = arguments["clientCrashed"] as? Bool ?? false
                let observedError = arguments["observedError"] as? String
                let dto = try resilienceService.stepResilienceBisectionPlan(
                    planID: planID, clientCrashed: clientCrashed, observedError: observedError,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "get_resilience_matrix_report":
                let planID = try requiredUUID(arguments["planID"], name: "planID")
                let dto = try resilienceService.getResilienceMatrixReport(planID: planID, policyRevision: policyStore.policyRevision)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown resilience-bisection tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Resilience-bisection operation failed."))
        }
    }

    private func trajectoryTool(id: Any?, name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            let baselineIDs = uuidArray(arguments["baselineSessionIDs"])
            let candidateIDs = uuidArray(arguments["candidateSessionIDs"])
            let baselineName = (arguments["baselineName"] as? String) ?? "Baseline Run"
            let candidateName = (arguments["candidateName"] as? String) ?? "Candidate Run"
            let dto = try trajectoryService.diffSessionTrajectories(
                baselineSessionIDs: baselineIDs, candidateSessionIDs: candidateIDs,
                baselineName: baselineName, candidateName: candidateName,
                policyRevision: policyStore.policyRevision
            )
            return toolStructuredResult(id: id, payload: try encodedObject(dto))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Trajectory diff failed."))
        }
    }

    private func semanticMockTool(id: Any?, name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "propose_semantic_mock_rule":
                let ruleName = try requiredString(arguments["name"], name: "name")
                let urlPattern = try requiredString(arguments["urlPattern"], name: "urlPattern")
                let intentLabel = try requiredString(arguments["intentLabel"], name: "intentLabel")
                let exampleQueries = stringArray(arguments["exampleQueries"])
                let statusCode = arguments["mockStatusCode"] as? Int ?? 200
                let responseBody = try requiredString(arguments["mockResponseBody"], name: "mockResponseBody")
                let threshold = arguments["confidenceThreshold"] as? Double ?? 0.70
                let dto = try semanticMockService.proposeSemanticMockRule(
                    name: ruleName, urlPattern: urlPattern, intentLabel: intentLabel,
                    exampleQueries: exampleQueries, mockStatusCode: statusCode,
                    mockResponseBody: responseBody, confidenceThreshold: threshold,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "list_semantic_mock_rules":
                let dto = try semanticMockService.listSemanticMockRules(policyRevision: policyStore.policyRevision)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "test_semantic_query_match":
                let query = try requiredString(arguments["query"], name: "query")
                let targetURL = arguments["targetURL"] as? String
                let dto = try semanticMockService.testSemanticQueryMatch(
                    query: query, targetURL: targetURL, policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "delete_semantic_mock_rule":
                let ruleID = try requiredUUID(arguments["ruleID"], name: "ruleID")
                let deleted = try semanticMockService.deleteSemanticMockRule(ruleID: ruleID, policyRevision: policyStore.policyRevision)
                return toolStructuredResult(id: id, payload: ["deleted": deleted])
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown semantic-mock tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Semantic-mock operation failed."))
        }
    }

    private func contractDiffTool(id: Any?, name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "contract_diff_sessions":
                let liveID = try requiredUUID(arguments["liveSessionID"], name: "liveSessionID")
                let baselineID = try requiredUUID(arguments["baselineSessionID"], name: "baselineSessionID")
                let dto = try contractDiffService.diffSessions(liveSessionID: liveID, baselineSessionID: baselineID)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "contract_regression_suite":
                let liveIDs = uuidArray(arguments["liveSessionIDs"])
                let baselineIDs = uuidArray(arguments["baselineSessionIDs"])
                let dto = try contractDiffService.runRegressionSuite(liveSessionIDs: liveIDs, baselineSessionIDs: baselineIDs)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown contract-diff tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Contract-diff operation failed."))
        }
    }

    private func dataLineageTool(id: Any?, name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "trace_data_lineage":
                let mode = (arguments["mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let candidateIDs = uuidArray(arguments["candidateSessionIDs"])
                if mode == "authChain" {
                    let dto = try dataLineageService.traceAuthChain(
                        candidateSessionIDs: candidateIDs,
                        disclosure: disclosureSerializer,
                        policyRevision: policyStore.policyRevision
                    )
                    return toolStructuredResult(id: id, payload: try encodedObject(dto))
                }
                if let mode, !mode.isEmpty, mode != "value" {
                    throw MCPStructuredError.malformedRequest(message: "mode must be value or authChain.")
                }
                let targetValue = try requiredString(arguments["targetValue"], name: "targetValue")
                let dto = try dataLineageService.traceDataLineage(
                    targetValue: targetValue, candidateSessionIDs: candidateIDs,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "audit_analytics_attribution":
                let sinkID = try requiredUUID(arguments["sinkSessionID"], name: "sinkSessionID")
                let candidateIDs = uuidArray(arguments["candidateSourceSessionIDs"])
                let dto = try await dataLineageService.auditAnalyticsAttribution(
                    sinkSessionID: sinkID, candidateSourceSessionIDs: candidateIDs,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "propose_provenance_watermark":
                let watermarkName = try requiredString(arguments["name"], name: "name")
                let urlPattern = try requiredString(arguments["urlPattern"], name: "urlPattern")
                let keypaths = stringArray(arguments["targetKeypaths"])
                let strategy = try requiredString(arguments["strategy"], name: "strategy")
                let dto = try dataLineageService.proposeProvenanceWatermark(
                    name: watermarkName, urlPattern: urlPattern, targetKeypaths: keypaths, strategy: strategy,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown data-lineage tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Data-lineage operation failed."))
        }
    }

    private func localizationMockTool(id: Any?, name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "localization_mock_list_presets":
                let presets = localizationMockService.listPresets()
                return toolStructuredResult(id: id, payload: try encodedArrayObject(presets, key: "presets"))
            case "localization_mock_preview":
                let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
                let presetID = try requiredString(arguments["presetID"], name: "presetID")
                let preserveURLs = arguments["preserveURLs"] as? Bool ?? true
                let preserveIDs = arguments["preserveIDs"] as? Bool ?? true
                let dto = try localizationMockService.previewLocalizationTransform(
                    sessionID: sessionID, presetID: presetID, preserveURLs: preserveURLs, preserveIDs: preserveIDs
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown localization-mock tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Localization-mock operation failed."))
        }
    }

    private func statefulMockTool(id: Any?, name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "stateful_mock_list_backends":
                let backends = await statefulMockService.listBackends()
                return toolStructuredResult(id: id, payload: try encodedArrayObject(backends, key: "backends"))
            case "stateful_mock_list_presets":
                let presets = statefulMockService.listPresets()
                return toolStructuredResult(id: id, payload: try encodedArrayObject(presets, key: "presets"))
            case "stateful_mock_install_preset":
                let presetID = try requiredString(arguments["presetID"], name: "presetID")
                let customHost = arguments["customHost"] as? String
                let dto = try await statefulMockService.installPreset(presetID: presetID, customHost: customHost)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "stateful_mock_set_state":
                let backendID = try requiredString(arguments["backendID"], name: "backendID")
                let state = try requiredString(arguments["state"], name: "state")
                let dto = try await statefulMockService.setState(backendIDString: backendID, state: state)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "stateful_mock_query_entities":
                let backendID = try requiredString(arguments["backendID"], name: "backendID")
                let collection = try requiredString(arguments["collection"], name: "collection")
                let dto = try await statefulMockService.queryEntities(backendIDString: backendID, collection: collection)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "stateful_mock_reset_backend":
                let backendID = try requiredString(arguments["backendID"], name: "backendID")
                let reset = try await statefulMockService.resetBackend(backendIDString: backendID)
                return toolStructuredResult(id: id, payload: ["reset": reset])
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown stateful-mock tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Stateful-mock operation failed."))
        }
    }

    private func faultIsolationTool(id: Any?, name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "fault_isolation_start":
                let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
                let windowSeconds = (arguments["windowSeconds"] as? Double) ?? 30.0
                let dto = try faultBisectionService.startBisection(sessionID: sessionID, windowSeconds: windowSeconds)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "fault_isolation_record_step":
                let outcome = try requiredString(arguments["outcome"], name: "outcome")
                let logSnippet = arguments["logSnippet"] as? String
                let dto = try faultBisectionService.recordStep(outcome: outcome, logSnippet: logSnippet)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "fault_isolation_report":
                let dto = try faultBisectionService.getReport()
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "fault_isolation_cancel":
                let cancelled = faultBisectionService.cancelBisection()
                return toolStructuredResult(id: id, payload: ["cancelled": cancelled])
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown fault-isolation tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Fault-isolation operation failed."))
        }
    }

    private func syntheticInjectionTool(id: Any?, name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "list_synthetic_assets":
                let dto = try syntheticInjectionService.listSyntheticAssets(policyRevision: policyStore.policyRevision)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "propose_inject_synthetic_item":
                let itemName = try requiredString(arguments["name"], name: "name")
                let urlPattern = try requiredString(arguments["urlPattern"], name: "urlPattern")
                let collectionKeypath = (arguments["collectionKeypath"] as? String) ?? "$"
                let position = (arguments["position"] as? String) ?? "prepend"
                let boundAssetKind = arguments["boundAssetKind"] as? String
                let customAssetURL = arguments["customAssetURL"] as? String
                let fieldOverrides = (arguments["fieldOverrides"] as? [String: String]) ?? [:]
                let clientScope = (arguments["clientScope"] as? String) ?? "simulatorOnly"
                let dto = try syntheticInjectionService.injectSyntheticItemInCollection(
                    name: itemName, urlPattern: urlPattern, collectionKeypath: collectionKeypath,
                    position: position, boundAssetKind: boundAssetKind, customAssetURL: customAssetURL,
                    fieldOverrides: fieldOverrides, clientScope: clientScope,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "list_synthetic_injection_plans":
                let dto = syntheticInjectionService.listInjectionPlans(policyRevision: policyStore.policyRevision)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "remove_synthetic_injection_plan":
                let planID = try requiredUUID(arguments["planID"], name: "planID")
                let removed = syntheticInjectionService.removeInjectionPlan(planID: planID)
                return toolStructuredResult(id: id, payload: ["removed": removed])
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown synthetic-injection tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Synthetic-injection operation failed."))
        }
    }

    private func instrumentsTool(id: Any?, name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "instruments_list_templates":
                let templates = try await instrumentsCoordinator.listTemplates()
                let items = templates.map { ["name": $0.name, "description": $0.description] }
                return toolStructuredResult(id: id, payload: ["templates": items])
            case "instruments_record_trace":
                let templateName = (arguments["template"] as? String) ?? (arguments["templateName"] as? String) ?? "Time Profiler"
                let targetProcess = arguments["process"] as? String ?? arguments["targetProcess"] as? String
                let targetBundleID = arguments["bundleID"] as? String ?? arguments["targetBundleID"] as? String
                let targetDevice = arguments["device"] as? String ?? arguments["targetDevice"] as? String
                let duration = (arguments["duration"] as? Int) ?? (arguments["durationSeconds"] as? Int) ?? 10
                let config = InstrumentsTraceSessionConfig(
                    templateName: templateName,
                    targetProcess: targetProcess,
                    targetBundleID: targetBundleID,
                    targetDeviceIdentifier: targetDevice,
                    timeLimitSeconds: duration
                )
                let result = try await instrumentsCoordinator.recordTrace(config: config)
                return toolStructuredResult(id: id, payload: [
                    "tracePath": result.traceURL.path,
                    "durationSeconds": result.durationSeconds,
                    "fileSizeBytes": result.fileSizeBytes,
                    "exitCode": result.exitCode
                ])
            case "instruments_analyze_trace":
                let tracePath = try requiredString(arguments["tracePath"] ?? arguments["trace"], name: "tracePath")
                let traceURL = URL(fileURLWithPath: tracePath)
                let templateName = (arguments["template"] as? String) ?? "Time Profiler"
                let xmlURL = try await instrumentsCoordinator.exportTableXML(traceURL: traceURL)
                let parser = InstrumentsTraceParser()
                let summary = parser.parse(fileURL: xmlURL, templateName: templateName)
                return toolStructuredResult(id: id, payload: try encodedObject(summary))
            case "instruments_correlated_audit":
                let templateName = (arguments["template"] as? String) ?? "Hangs / Hitches"
                let targetProcess = arguments["process"] as? String ?? "TargetApp"
                let duration = (arguments["duration"] as? Int) ?? 10
                let startTime = Date()

                let tracePath: String
                if let existingTrace = arguments["tracePath"] as? String ?? arguments["trace"] as? String {
                    tracePath = existingTrace
                } else {
                    let config = InstrumentsTraceSessionConfig(
                        templateName: templateName,
                        targetProcess: targetProcess,
                        timeLimitSeconds: duration
                    )
                    let result = try await instrumentsCoordinator.recordTrace(config: config)
                    tracePath = result.traceURL.path
                }

                let xmlURL = try await instrumentsCoordinator.exportTableXML(traceURL: URL(fileURLWithPath: tracePath))
                let parser = InstrumentsTraceParser()
                let metrics = parser.parse(fileURL: xmlURL, templateName: templateName)

                let recentSessions = snapshotService.sourceSessionStore.sessions.filter {
                    $0.timing.startedAt >= startTime.addingTimeInterval(-Double(duration) - 5.0)
                }

                let report = InstrumentsCorrelatedDiagnosticEngine.analyze(
                    targetName: targetProcess,
                    durationSeconds: Double(duration),
                    tracePath: tracePath,
                    sessionStartTime: startTime,
                    capturedSessions: recentSessions,
                    traceMetrics: metrics
                )
                return toolStructuredResult(id: id, payload: try encodedObject(report))
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown instruments tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Instruments operation failed: \(error.localizedDescription)"))
        }
    }

    private func advancedMediaInspectionTool(id: Any?, name: String, arguments: [String: Any], client: MCPClientRecord) async -> [String: Any] {
        do {
            switch name {
            case "cmcd_telemetry_inspection":
                let sessionIDs = uuidArray(arguments["sessionIDs"])
                let dto = try mediaInspectionService.cmcdTelemetryInspection(sessionIDs: sessionIDs, policyRevision: policyStore.policyRevision)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "webvtt_subtitle_inspection":
                let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
                let referenceID = optionalUUID(arguments["referenceVideoSessionID"])
                let dto = try mediaInspectionService.webvttSubtitleInspection(
                    sessionID: sessionID, referenceVideoSessionID: referenceID, policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "drm_handshake_inspection":
                let manifestID = optionalUUID(arguments["manifestSessionID"])
                let licenseIDs = uuidArray(arguments["licenseSessionIDs"])
                let mediaIDs = uuidArray(arguments["mediaSessionIDs"])
                let dto = try mediaInspectionService.drmHandshakeInspection(
                    manifestSessionID: manifestID, licenseSessionIDs: licenseIDs, mediaSessionIDs: mediaIDs,
                    policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "byte_range_efficiency_inspection":
                let sessionIDs = uuidArray(arguments["sessionIDs"])
                let dto = try mediaInspectionService.byteRangeEfficiencyInspection(sessionIDs: sessionIDs, policyRevision: policyStore.policyRevision)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "streaming_waterfall_inspection":
                let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
                let dto = try mediaInspectionService.streamingWaterfall(sessionID: sessionID, policyRevision: policyStore.policyRevision)
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "visual_asset_inspection":
                let sessionID = try requiredUUID(arguments["sessionID"], name: "sessionID")
                let revision = policyStore.policyRevision
                let dto = try await mediaInspectionService.visualAssetInspection(sessionID: sessionID, policyRevision: revision)
                guard !Task.isCancelled, revision == policyStore.policyRevision,
                      let currentClient = clientRegistry.client(id: client.id),
                      currentClient.credentialState == .active,
                      policyAvailableProductionTools(for: currentClient).contains(where: { $0.name == name }) else {
                    throw MCPStructuredError(code: .policyDenied, message: "Image inspection cancelled or authority changed; result discarded.")
                }
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            case "scte35_ad_break_inspection":
                let masterID = try requiredUUID(arguments["masterManifestSessionID"], name: "masterManifestSessionID")
                let variantIDs = uuidArray(arguments["variantSessionIDs"])
                let dto = try mediaInspectionService.scte35AdBreakInspection(
                    masterManifestSessionID: masterID, variantSessionIDs: variantIDs, policyRevision: policyStore.policyRevision
                )
                return toolStructuredResult(id: id, payload: try encodedObject(dto))
            default:
                throw MCPStructuredError.malformedRequest(message: "Unknown advanced media inspection tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Advanced media inspection failed."))
        }
    }

    private func encodeMediaRelatedCursor(_ cursor: MCPMediaRelatedCursor) throws -> String {
        let token = UUID().uuidString
        mediaCursors[token] = cursor
        mediaCursorOrder.append(token)
        while mediaCursorOrder.count > 512 {
            mediaCursors.removeValue(forKey: mediaCursorOrder.removeFirst())
        }
        return token
    }

    private func decodeMediaRelatedCursor(_ value: Any?) throws -> MCPMediaRelatedCursor? {
        guard let value else { return nil }
        guard let string = value as? String,
              let cursor = mediaCursors[string] else {
            throw MCPStructuredError.malformedRequest(message: "cursor must be an opaque media cursor returned by JoesProxy.")
        }
        return cursor
    }

    private func mcpMediaTypeName(_ mediaType: MediaType) -> String {
        switch mediaType {
        case .image: return "image"
        case .hls: return "hls"
        case .hlsDiscovery: return "hls_discovery"
        case .dash: return "dash"
        case .video: return "video"
        case .adXml: return "ad_xml"
        case .none: return "none"
        }
    }

    /// Validates or mints approval for sensitive-read tool arguments.
    private func resolveSensitiveReadApproval(
        toolName: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        capability: MCPCapabilityID,
        mcpSessionID: String?,
        reason: String? = nil
    ) throws -> Set<MCPCapabilityID> {
        guard policyEvaluator.effectiveAllows(capability: capability, client: client) else {
            auditStore.recordOperatorActionablePolicyBlock(
                clientID: client.id,
                capability: capability,
                detail: "Sensitive operation denied by the client's disclosure profile or access policy."
            )
            throw MCPStructuredError(
                code: .policyDenied,
                message: "Profile or policy denies \(capability.rawValue)."
            )
        }
        let digest = MCPArgumentDigest.normalized(arguments)
        // The client-supplied `authorization` is untrusted input — it is only ever used to look up
        // the nonce. Every field actually validated against (`request`/`authorization`) comes from
        // the server-side grant record, never from what the client echoes back. Without this, a
        // client could fabricate its own MCPApprovalAuthorization and self-approve: the retry check
        // would then be comparing the forged object to itself and always pass.
        if let presentedAuthorization = MCPArgumentDigest.authorization(from: arguments) {
            if approvalStore.nonceAlreadyUsed(presentedAuthorization.nonce) {
                throw approvalValidationError(.reused)
            }
            if approvalStore.nonceExpired(presentedAuthorization.nonce) {
                throw approvalValidationError(.expired)
            }
            if let granted = approvalStore.grantedAuthorization(nonce: presentedAuthorization.nonce) {
            if let failure = MCPApprovalValidation.validateRetry(
                request: granted.request,
                authorization: granted.authorization,
                currentClientID: client.id,
                currentCapability: capability,
                normalizedArgumentDigest: digest,
                currentPolicyRevision: policyStore.policyRevision,
                currentTargetRevision: nil,
                nonceAlreadyUsed: false
            ) {
                throw approvalValidationError(failure)
            }
            approvalStore.consumeNonce(granted.authorization.nonce)
            return MCPCapabilityRouter.sensitiveReadCapabilities(
                from: MCPArgumentDigest.dispatchArguments(arguments)
            )
            }
        }
        if approvalStore.consumeApprovedRequest(
            clientID: client.id,
            mcpSessionID: mcpSessionID,
            capability: capability,
            argumentDigest: digest,
            policyRevision: policyStore.policyRevision
        ) {
            return MCPCapabilityRouter.sensitiveReadCapabilities(
                from: MCPArgumentDigest.dispatchArguments(arguments)
            )
        }
        if !capability.requiresOneUseApproval && policyEvaluator.skipsApprovalNonce(capability: capability, client: client) {
            return MCPCapabilityRouter.sensitiveReadCapabilities(
                from: MCPArgumentDigest.dispatchArguments(arguments)
            )
        }
        let request = approvalStore.createPendingRequest(
            clientID: client.id,
            capability: capability,
            argumentDigest: digest,
            policyRevision: policyStore.policyRevision,
            mcpSessionID: mcpSessionID,
            reason: reason ?? "Sensitive read of \(toolName) requires in-app approval."
        )
        throw MCPStructuredError.approvalRequired(request)
    }

    private func approvalStatusTool(
        id: Any?,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) -> [String: Any] {
        guard let requestID = arguments["requestID"] as? String else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32602, "requestID is required."))
        }
        let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
        guard let status = approvalStore.status(requestID: requestID, clientID: client.id, mcpSessionID: sessionID),
              let data = try? encoder.encode(status),
              let payload = try? jsonObject(from: data) else {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32004, "Approval request not found."))
        }
        return toolStructuredResult(id: id, payload: payload)
    }

    /// Lists every currently-pending approval request for this client (client-wide, same scope as
    /// `client_cleanup_status.pendingApprovalCount`) — added so an agent/operator can discover what's
    /// blocking a client without having to re-trigger the original call just to re-read its
    /// `approval_required` error (see `MCPAndCLIUserExperienceValidation.md`).
    private func approvalsListTool(id: Any?, client: MCPClientRecord) -> [String: Any] {
        do {
            let pending = approvalStore.pendingList(clientID: client.id)
            let payload = MCPApprovalListDTO(pending: pending, count: pending.count)
            return try encodedToolResult(id: id, payload: MCPDTOEnvelope(payload: payload))
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "approvals_list failed."))
        }
    }

    private func approvalValidationError(_ failure: MCPApprovalValidation.Failure) -> MCPStructuredError {
        switch failure {
        case .expired:
            return MCPStructuredError(code: .approvalExpired, message: "Approval authorization expired.")
        case .reused:
            return MCPStructuredError(code: .approvalReused, message: "Approval authorization was already used.")
        case .argumentMismatch:
            return MCPStructuredError(code: .malformedRequest, message: "Approval authorization does not match request arguments.")
        case .policyTightened:
            return MCPStructuredError(code: .policyDenied, message: "Policy changed; approval is no longer valid.")
        case .targetRevisionChanged:
            return MCPStructuredError(code: .staleTargetRevision, message: "Target revision changed; approval is no longer valid.")
        }
    }

    #if DEBUG
    private func slowTool(id: Any?, arguments: [String: Any], context: RequestContext) async -> [String: Any] {
        let delayMs = arguments["delayMs"] as? Int ?? 2_000
        guard (0 ... MCPNetworkConstants.maxSlowToolDelayMilliseconds).contains(delayMs) else {
            return MCPHTTPResponse.jsonRPCObject(
                id: id,
                error: (-32602, "delayMs must be between 0 and \(MCPNetworkConstants.maxSlowToolDelayMilliseconds).")
            )
        }
        guard let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()],
              let requestKey = requestKey(from: id) else {
            do {
                try await Task.sleep(for: .milliseconds(delayMs))
                return toolStructuredResult(id: id, payload: ["completed": true, "delayMs": delayMs])
            } catch is CancellationError {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32800, "Request cancelled."))
            } catch {
                return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32603, "Internal error."))
            }
        }

        let taskKey = SlowToolTaskKey(sessionID: sessionID, requestID: requestKey)
        let task = Task {
            let step = max(1, delayMs / 100)
            var elapsed = 0
            while elapsed < delayMs {
                try Task.checkCancellation()
                if isRequestCancelled(sessionID: sessionID, requestKey: requestKey) {
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(step))
                elapsed += step
            }
        }
        slowToolTasks[taskKey] = task
        defer { slowToolTasks.removeValue(forKey: taskKey) }
        do {
            try await task.value
            return toolStructuredResult(id: id, payload: ["completed": true, "delayMs": delayMs])
        } catch is CancellationError {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32800, "Request cancelled."))
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32603, "Internal error."))
        }
    }
    #endif

    private func resourcePayload(
        uri: String,
        client: MCPClientRecord,
        profile: MCPDisclosureProfileDocument
    ) async throws -> [String: Any] {
        switch uri {
        case "joesproxy://server/status":
            let availableTools = listedProductionTools(for: client)
            let runtime = await runtimeStatus()
            let status = MCPServerStatusDTO(
                isRunning: true,
                endpointURL: "http://127.0.0.1:\(boundPort)\(MCPNetworkConstants.endpointPath)",
                protocolVersion: MCPNetworkConstants.preferredProtocolVersion,
                appVersion: Bundle.main.marketingVersionOrDev,
                capabilitiesBundleVersion: MCPCapabilitiesRevision.bundleVersion(),
                toolCount: availableTools.count,
                connectedClientCount: connectedClientIDs.count,
                activeSessionCount: activeSessionCount,
                policyRevision: policyStore.policyRevision,
                captureEpoch: snapshotService.captureEpoch,
                degradedReason: policyStore.loadFailureReason ?? auditStore.persistenceFailureReason,
                runtime: runtime
            )
            return try jsonObject(from: encoder.encode(MCPDTOEnvelope(payload: status)))
        case "joesproxy://agent/capabilities":
            let manifest = MCPCapabilitiesManifestBuilder.buildManifest(tools: listedProductionTools(for: client))
            return try jsonObject(from: encoder.encode(MCPDTOEnvelope(payload: manifest)))
        case "joesproxy://docs/index":
            let page = try await DocumentationService.shared.query(.init(operation: "list"), source: "running-server", appVersion: Bundle.main.marketingVersionOrDev)
            return try jsonObject(from: encoder.encode(MCPDTOEnvelope(payload: page)))
        case "joesproxy://agent/guide":
            let manifest = MCPCapabilitiesManifestBuilder.buildManifest(tools: listedProductionTools(for: client))
            let guide = MCPAgentGuideDTO(
                bundleVersion: manifest.bundleVersion,
                appVersion: manifest.appVersion,
                generatedAt: manifest.generatedAt,
                markdownBody: MCPAgentExportService.generateGuideMarkdown(manifest: manifest)
            )
            return try jsonObject(from: encoder.encode(MCPDTOEnvelope(payload: guide)))
        case "joesproxy://setup/guide":
            let guide = MCPSetupGuideDTO(
                schemaVersion: MCPSetupGuideDTO.schemaVersion,
                appVersion: Bundle.main.marketingVersionOrDev,
                markdownBody: MCPSetupGuideContent.markdown,
                bootstrapRequired: true
            )
            return try jsonObject(from: encoder.encode(MCPDTOEnvelope(payload: guide)))
        case "joesproxy://capture/summary":
            let counts = snapshotService.captureCounts
            let summary = MCPCaptureSummaryDTO(
                sessionCount: counts.sessionCount,
                completedCount: counts.completedCount,
                pendingCount: counts.pendingCount,
                captureEpoch: snapshotService.captureEpoch,
                policyRevision: policyStore.policyRevision
            )
            return try jsonObject(from: encoder.encode(MCPDTOEnvelope(payload: summary)))
        case "joesproxy://capture/health":
            let health = MCPCaptureHealthDTO(
                retainedBodyBytes: snapshotService.retainedBodyBytes,
                droppedSessionCount: snapshotService.droppedSessionCount,
                captureEpoch: snapshotService.captureEpoch,
                policyRevision: policyStore.policyRevision,
                captureStatus: captureStatusProvider?()
            )
            return try jsonObject(from: encoder.encode(MCPDTOEnvelope(payload: health)))
        case "joesproxy://audit/recent":
            let recent = auditStore.recentEvents(forClientID: client.id)
            let summary = MCPClientAuditSummaryDTO(
                events: recent.events.map {
                    MCPClientAuditEventDTO(
                        id: $0.id.uuidString,
                        kind: $0.kind.rawValue,
                        timestamp: $0.timestamp,
                        reasonCode: $0.reasonCode
                    )
                },
                hasMore: recent.hasMore,
                policyRevision: policyStore.policyRevision
            )
            return try jsonObject(from: encoder.encode(MCPDTOEnvelope(payload: summary)))
        default:
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown resource: \(uri)")
        }
    }

    private func runtimeStatus() async -> MCPRuntimeStatusDTO {
        if let recoveryService {
            return await recoveryService.runtimeStatus(activeOperationCount: operationCoordinator.activeAnalysisCount)
        }
        return MCPRuntimeStatusDTO(
            effectState: "unknown",
            activeEffectCount: 0,
            cleanupConflictCount: 0,
            activeOperationCount: operationCoordinator.activeAnalysisCount,
            pendingApprovalCount: approvalStore.pendingCount,
            activeScenarioCount: 0
        )
    }

    private func handleNotification(_ message: [String: Any], client: MCPClientRecord, context: RequestContext) async {
        guard let method = message["method"] as? String else { return }
        if method == "notifications/initialized" || method == "initialized",
           let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()],
           var session = sessions[sessionID],
           session.clientID == client.id,
           session.credentialGeneration == client.credentialGeneration,
           session.policyRevision == policyStore.policyRevision {
            session.initialized = true
            session.lastActivityAt = Date()
            sessions[sessionID] = session
            return
        }
        if method == "notifications/cancelled",
           let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()],
           var session = sessions[sessionID],
           session.clientID == client.id {
            let params = message["params"] as? [String: Any] ?? [:]
            if let requestKey = requestKey(from: params["requestId"]) {
                if session.cancelledRequestIDs.count < MCPServerLimits.maxTrackedCancelledRequestIDsPerSession {
                    session.cancelledRequestIDs.insert(requestKey)
                    sessions[sessionID] = session
                }
                let slowKey = SlowToolTaskKey(sessionID: sessionID, requestID: requestKey)
                slowToolTasks[slowKey]?.cancel()
            }
        }
    }

    private func cancelledResponse(id: Any?, context: RequestContext) -> [String: Any]? {
        guard let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()],
              let requestKey = requestKey(from: id),
              isRequestCancelled(sessionID: sessionID, requestKey: requestKey) else {
            return nil
        }
        return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32800, "Request cancelled."))
    }

    private func isRequestCancelled(sessionID: String, requestKey: String) -> Bool {
        sessions[sessionID]?.cancelledRequestIDs.contains(requestKey) == true
    }

    /// JSON-RPC ids are always a bare scalar (string or number) per spec, never an array/object —
    /// `JSONSerialization.isValidJSONObject` only accepts a top-level array/dictionary, so it
    /// rejects every real id and previously made this always return `nil`. Type-tag the two cases
    /// directly instead so `id: 42` and `id: "42"` also don't collide on the same key.
    private func requestKey(from id: Any?) -> String? {
        switch id {
        case let string as String:
            return "s:\(string)"
        case let number as NSNumber:
            return "n:\(number.stringValue)"
        default:
            return nil
        }
    }

    private func validateSession(
        for method: String,
        id: Any?,
        client: MCPClientRecord,
        context: RequestContext
    ) -> [String: Any]? {
        if method == "initialize" { return nil }
        guard let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()],
              var session = sessions[sessionID] else {
            MCPLog.protocolLog.notice("Session rejected: missing or unknown session ID.")
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32001, "Session missing."))
        }
        guard session.clientID == client.id,
              session.credentialGeneration == client.credentialGeneration else {
            MCPLog.protocolLog.notice("Session rejected: client/credential-generation mismatch.")
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32001, "Session invalid."))
        }
        guard session.policyRevision == policyStore.policyRevision else {
            session.restricted = true
            sessions[sessionID] = session
            operationCoordinator.cancelOperations(forMCPSessionID: sessionID)
            notificationHub?.invalidateSession(
                MCPLogicalSessionKey(clientID: session.clientID, mcpSessionID: sessionID),
                reason: "policy_changed"
            )
            MCPLog.protocolLog.notice("Session restricted: policy revision changed since initialize.")
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32001, "Session policy changed."))
        }
        if session.restricted {
            operationCoordinator.cancelOperations(forMCPSessionID: sessionID)
            notificationHub?.invalidateSession(
                MCPLogicalSessionKey(clientID: session.clientID, mcpSessionID: sessionID),
                reason: "session_restricted"
            )
            MCPLog.protocolLog.notice("Session rejected: session is restricted.")
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32001, "Session restricted."))
        }
        guard Date().timeIntervalSince(session.lastActivityAt) < MCPServerLimits.sessionIdleExpiry else {
            removeSession(sessionID: sessionID, reason: "session_expired")
            MCPLog.protocolLog.notice("Session expired due to inactivity.")
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32001, "Session expired."))
        }
        if !session.initialized, method != "notifications/initialized", method != "initialized" {
            MCPLog.protocolLog.notice("Session rejected: \(method, privacy: .public) called before initialization.")
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32001, "Session not initialized."))
        }
        let protocolVersionHeaderName = MCPNetworkConstants.protocolVersionHeader.lowercased()
        if let suppliedVersion = context.headers[protocolVersionHeaderName] {
            guard suppliedVersion == session.protocolVersion else {
                MCPLog.protocolLog.notice(
                    "Session rejected: protocol version header \(suppliedVersion, privacy: .public) does not match negotiated \(session.protocolVersion, privacy: .public)."
                )
                return MCPHTTPResponse.jsonRPCObject(
                    id: id,
                    error: (-32003, "MCP protocol version does not match the negotiated session.")
                )
            }
        } else if session.protocolVersion != "2025-03-26" {
            // Only the oldest supported spec version didn't mandate this header; every session
            // negotiated at a newer version must send it on every request after initialize.
            MCPLog.protocolLog.notice("Session rejected: missing required MCP-Protocol-Version header.")
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32003, "Missing MCP protocol version header."))
        }
        session.lastActivityAt = Date()
        sessions[sessionID] = session
        return nil
    }

    private func sessionHTTPRejection(
        for method: String,
        id: Any?,
        client: MCPClientRecord,
        context: RequestContext
    ) -> MCPHTTPResponse? {
        if method == "initialize" { return nil }
        guard let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()] else {
            MCPLog.protocolLog.notice("Session rejected: required session ID header is missing.")
            return MCPHTTPResponse.jsonRPCError(
                status: 400,
                id: id,
                code: -32001,
                message: "Mcp-Session-Id is required; initialize a session first."
            )
        }
        guard let session = sessions[sessionID] else {
            MCPLog.protocolLog.notice("Session rejected: session ID is unknown or no longer retained.")
            let diagnostic = sessionTerminationDiagnostic(sessionID: sessionID, clientID: client.id)
            return MCPHTTPResponse.jsonRPCError(
                status: 404,
                id: id,
                code: -32001,
                message: "Session not found; initialize a new session.",
                data: diagnostic
            )
        }
        let expired = Date().timeIntervalSince(session.lastActivityAt) >= MCPServerLimits.sessionIdleExpiry
        let unavailable = session.clientID != client.id
            || session.credentialGeneration != client.credentialGeneration
            || session.policyRevision != policyStore.policyRevision
            || session.restricted
            || expired
        guard unavailable else { return nil }
        if session.clientID == client.id {
            removeSession(sessionID: sessionID, reason: expired ? "session_expired" : "session_invalidated")
        }
        MCPLog.protocolLog.notice("Session rejected: identity is expired, restricted, or belongs to another client.")
        return MCPHTTPResponse.jsonRPCError(
            status: 404,
            id: id,
            code: -32001,
            message: "Session not found; initialize a new session.",
            data: sessionTerminationDiagnostic(sessionID: sessionID, clientID: client.id)
        )
    }

    /// Removes idle-expired and restricted sessions, then — if still at the configured cap — evicts
    /// the least-recently-active session so `sessions` never grows without bound regardless of how
    /// many `initialize` calls a client makes over the process lifetime.
    private func pruneSessions(forClientID clientID: String) {
        let now = Date()
        let removedSessions = sessions.compactMap { sessionID, session -> (String, String)? in
            if session.restricted {
                return (sessionID, "session_invalidated")
            }
            if now.timeIntervalSince(session.lastActivityAt) >= MCPServerLimits.sessionIdleExpiry {
                return (sessionID, "session_expired")
            }
            return nil
        }
        for (sessionID, reason) in removedSessions {
            removeSession(sessionID: sessionID, reason: reason)
        }
        let clientSessions = sessions
            .filter { $0.value.clientID == clientID }
            .sorted { $0.value.lastActivityAt < $1.value.lastActivityAt }
        if clientSessions.count >= MCPServerLimits.activeMCPSessionsPerClient {
            let overflow = clientSessions.count - MCPServerLimits.activeMCPSessionsPerClient + 1
            for key in clientSessions.prefix(overflow).map(\.key) {
                removeSession(sessionID: key, reason: "client_session_evicted")
            }
        }
        guard sessions.count >= MCPServerLimits.activeMCPSessions else { return }
        let overflow = sessions.count - MCPServerLimits.activeMCPSessions + 1
        let staleKeys = sessions
            .sorted { $0.value.lastActivityAt < $1.value.lastActivityAt }
            .prefix(overflow)
            .map(\.key)
        for key in staleKeys {
            removeSession(sessionID: key, reason: "session_evicted")
        }
    }

    private func removeSession(sessionID: String, reason: String) {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        artifactSources?.invalidatePairs { $0.session == sessionID }
        retainSessionTermination(sessionID: sessionID, clientID: session.clientID, reason: reason)
        operationCoordinator.cancelOperations(forMCPSessionID: sessionID)
        notificationHub?.invalidateSession(
            MCPLogicalSessionKey(clientID: session.clientID, mcpSessionID: sessionID),
            reason: reason
        )
        if activeSessionCount(forClientID: session.clientID) == 0 {
            sessionEndHandler?(session.clientID)
        }
    }

    private func retainSessionTermination(sessionID: String, clientID: String, reason: String, now: Date = Date()) {
        pruneSessionTerminations(now: now)
        sessionTerminations[sessionID] = MCPSessionTerminationRecord(
            clientID: clientID,
            state: clientVisibleSessionState(for: reason),
            terminatedAt: now,
            expiresAt: now.addingTimeInterval(MCPServerLimits.sessionTerminationRetention)
        )
        if sessionTerminations.count > MCPServerLimits.maxRetainedSessionTerminations,
           let oldest = sessionTerminations.min(by: { $0.value.terminatedAt < $1.value.terminatedAt })?.key {
            sessionTerminations.removeValue(forKey: oldest)
        }
    }

    private func sessionTerminationDiagnostic(
        sessionID: String,
        clientID: String,
        now: Date = Date()
    ) -> [String: Any]? {
        pruneSessionTerminations(now: now)
        guard let termination = sessionTerminations[sessionID], termination.clientID == clientID else {
            return nil
        }
        return [
            "sessionState": termination.state,
            "recovery": "reinitialize"
        ]
    }

    private func pruneSessionTerminations(now: Date) {
        sessionTerminations = sessionTerminations.filter { now < $0.value.expiresAt }
    }

    private func clientVisibleSessionState(for internalReason: String) -> String {
        switch internalReason {
        case "client_session_evicted", "session_evicted":
            return "evicted_capacity"
        case "session_expired":
            return "expired_idle"
        case "client_terminated":
            return "terminated"
        default:
            return "invalidated"
        }
    }

    private func sessionHeaders(context: RequestContext) -> [String: String] {
        guard let sessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()] else { return [:] }
        return [MCPNetworkConstants.sessionIDHeader: sessionID]
    }

    /// The real MCP logical session ID for this request, bound into a service's arguments dict as
    /// `__mcpInternalSessionID` so approval records are created/consumed under the same session
    /// `approval_status` will later look them up with — see `MCPApprovalStore.status(...)`.
    private func internalSessionID(from context: RequestContext) -> String? {
        context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
    }

    private func sanitizeResponse(_ response: [String: Any]) -> [String: Any] {
        guard var result = response["result"] as? [String: Any] else { return response }
        result.removeValue(forKey: "_sessionID")
        var copy = response
        copy["result"] = result
        return copy
    }

    private func mutationTool(
        id: Any?,
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        guard let mutationService else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "Mutation tools are unavailable.")
            )
        }
        do {
            var boundArguments = arguments
            boundArguments["__mcpInternalSessionID"] = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
            let payload = try await mutationService.handleTool(name: name, arguments: boundArguments, client: client)
            return toolStructuredResult(id: id, payload: payload)
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "\(name) failed."))
        }
    }

    private func openWorldTool(
        id: Any?,
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        guard let openWorldService else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "Open-world tools are unavailable.")
            )
        }
        let mcpSessionID = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()] ?? ""
        do {
            let payload = try await openWorldService.handleTool(
                name: name,
                arguments: arguments,
                client: client,
                mcpSessionID: mcpSessionID
            )
            return toolStructuredResult(id: id, payload: payload)
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "\(name) failed."))
        }
    }

    private func hlsFixtureTool(
        id: Any?,
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        guard let hlsFixtureService else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "HLS fixture tools are unavailable.")
            )
        }
        do {
            var boundArguments = arguments
            boundArguments["__mcpInternalSessionID"] = internalSessionID(from: context)
            let payload = try await hlsFixtureService.handleTool(
                name: name,
                arguments: boundArguments,
                client: client
            )
            return toolStructuredResult(id: id, payload: payload)
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch let error as HLSFixtureRunStoreError {
            let message: String
            switch error {
            case .notLoaded:
                message = "HLS fixture-run store is not loaded."
            case .corruptPersistence:
                message = "HLS fixture-run store persistence is corrupt."
            case .runNotFound:
                message = "HLS fixture run not found."
            case .notOwner:
                message = "HLS fixture run is owned by another client."
            case .quotaExceeded(let detail):
                message = detail
            case .profileNotFound(let profileID):
                message = "HLS fixture profile not found: \(profileID)."
            case .alreadyStopped:
                message = "HLS fixture run is already stopped."
            case .registryUnavailable:
                message = "HLS fixture origin registry is unavailable."
            }
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .conflict, message: message)
            )
        } catch {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "HLS fixture tool failed.")
            )
        }
    }

    private func openAPIMockPackTool(
        id: Any?,
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        guard let openAPIMockPackService else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "OpenAPI mock-pack tools are unavailable.")
            )
        }
        do {
            var boundArguments = arguments
            boundArguments["__mcpInternalSessionID"] = internalSessionID(from: context)
            let payload = try await openAPIMockPackService.handleTool(
                name: name,
                arguments: boundArguments,
                client: client
            )
            return toolStructuredResult(id: id, payload: payload)
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "OpenAPI mock-pack tool failed.")
            )
        }
    }

    private func diagnosticRunTool(
        id: Any?,
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        guard let diagnosticRunService else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "Diagnostic-run tools are unavailable.")
            )
        }
        do {
            var boundArguments = arguments
            // Observation windows do not consume approvals. Preserve their strict public
            // argument contract; do not inject approval-only metadata or strip caller input.
            if name != "diagnostic_run_window_begin", name != "diagnostic_run_window_end", name != "diagnostic_run_brief" {
                boundArguments["__mcpInternalSessionID"] = context.headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
            }
            let payload = try await diagnosticRunService.handleTool(
                name: name,
                arguments: boundArguments,
                client: client
            )
            return toolStructuredResult(id: id, payload: payload)
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "Diagnostic-run tool failed.")
            )
        }
    }

    /// Phase C certificate identity tools — delegated to the service that owns the shared
    /// CA-instance / distribution stores and the propose→approve→apply gate for cleanup.
    private func certificateIdentityTool(
        id: Any?,
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        guard let certificateIdentityService else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "Certificate tools are unavailable.")
            )
        }
        do {
            var boundArguments = arguments
            boundArguments["__mcpInternalSessionID"] = internalSessionID(from: context)
            let payload = try await certificateIdentityService.handleTool(
                name: name,
                arguments: boundArguments,
                client: client
            )
            return toolStructuredResult(id: id, payload: payload)
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(
                    code: .internalFailure,
                    message: "Certificate tool failed: \(error.localizedDescription)"
                )
            )
        }
    }

    private func scenarioTool(
        id: Any?,
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        context: RequestContext
    ) async -> [String: Any] {
        guard let scenarioService else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "Scenario tools are unavailable.")
            )
        }
        do {
            var boundArguments = arguments
            boundArguments["__mcpInternalSessionID"] = internalSessionID(from: context)
            let payload = try await scenarioService.handleTool(
                name: name,
                arguments: boundArguments,
                client: client
            )
            return toolStructuredResult(id: id, payload: payload)
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch let error as MCPScenarioLifecycleError {
            let message: String
            switch error {
            case .scenarioNotFound:
                message = "Scenario not found."
            case .duplicateScenarioID:
                message = "Scenario ID already exists."
            case .invalidTransition(let from, let to):
                message = "Invalid scenario transition from \(from.rawValue) to \(to.rawValue)."
            case .globalScenarioSlotBusy:
                message = "Another scenario is already active."
            case .storeUnavailable:
                message = "Scenario store unavailable."
            case .validationRequired:
                message = "Scenario validation is required before approval."
            case .scenarioExpired:
                message = "Scenario expired."
            }
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .malformedRequest, message: message)
            )
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "\(name) failed."))
        }
    }

    private func returnToNormalTool(id: Any?, client: MCPClientRecord) async -> [String: Any] {
        _ = client
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .returnToNormal,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "return_to_normal",
                detail: nil
            )
        )
        guard let returnToNormalHandler else {
            return structuredErrorJSONRPC(
                id: id,
                error: MCPStructuredError(code: .internalFailure, message: "Recovery tools are unavailable.")
            )
        }
        do {
            let summary = try await returnToNormalHandler()
            let payload = try recoverySummaryPayload(summary)
            return toolStructuredResult(id: id, payload: payload)
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "return_to_normal failed."))
        }
    }

    private func recoverySummaryPayload(_ summary: MCPRecoverySummary) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object ?? [:]
    }

    private func deviceTool(id: Any?, name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "list_discovered_devices":
                return toolStructuredResult(
                    id: id,
                    payload: try encodedObject(await deviceService.listDevices())
                )
            case "set_device_alias":
                guard let rawAddress = arguments["ipAddress"] as? String else {
                    throw MCPStructuredError(code: .malformedRequest, message: "ipAddress is required.")
                }
                let ipAddress = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ipAddress.isEmpty, ipAddress.utf8.count <= 64 else {
                    throw MCPStructuredError(code: .malformedRequest, message: "ipAddress must be between 1 and 64 UTF-8 bytes.")
                }
                let alias = (arguments["alias"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (alias?.utf8.count ?? 0) <= 80 else {
                    throw MCPStructuredError(code: .malformedRequest, message: "alias must not exceed 80 UTF-8 bytes.")
                }
                let request = MCPSetDeviceAliasRequestDTO(
                    ipAddress: ipAddress,
                    alias: alias?.isEmpty == false ? alias : nil
                )
                guard let response = await deviceService.setDeviceAlias(request: request) else {
                    throw MCPStructuredError(
                        code: .malformedRequest,
                        message: "No discovered device has the supplied ipAddress. Call list_discovered_devices and retry with an exact result."
                    )
                }
                return toolStructuredResult(id: id, payload: try encodedObject(response))
            default:
                throw MCPStructuredError(code: .malformedRequest, message: "Unknown device tool.")
            }
        } catch let error as MCPStructuredError {
            return structuredErrorJSONRPC(id: id, error: error)
        } catch {
            return MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Device operation failed."))
        }
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPStructuredError(code: .internalFailure, message: "Device response serialization failed.")
        }
        return object
    }

    private func toolDescriptor(name: String, description: String) -> [String: Any] {
        let inputSchema: [String: Any]
        switch name {
        case "agent_toolset_status":
            inputSchema = ["type": "object", "additionalProperties": false]
        case "documentation_list", "documentation_search", "documentation_read":
            inputSchema = ["type": "object", "properties": [
                "query": ["type": "string", "maxLength": 512],
                "topic": ["type": "string", "maxLength": 96],
                "section": ["type": "string", "maxLength": 96],
                "category": ["type": "string", "maxLength": 96],
                "cursor": ["type": "string", "maxLength": 2048],
                "limit": ["type": "integer", "minimum": 1, "maximum": 20],
                "maxResponseBytes": ["type": "integer", "minimum": 2048, "maximum": 32768]
            ], "required": name == "documentation_search" ? ["query"] : name == "documentation_read" ? ["topic"] : [], "additionalProperties": false]
        case "agent_toolset_select":
            inputSchema = [
                "type": "object",
                "properties": [
                    "toolset": [
                        "type": "string",
                        "enum": MCPToolset.allCases.map(\.rawValue),
                        "description": "Discovery catalog only. Select all to restore the complete tools/list response."
                    ]
                ],
                "required": ["toolset"],
                "additionalProperties": false
            ]
        case "sessions_list":
            inputSchema = [
                "type": "object",
                "properties": sessionQueryProperties(),
                "additionalProperties": false
            ]
        case "sessions_search":
            var properties = sessionQueryProperties()
            properties["method"] = ["type": "string", "description": "Exact HTTP method."]
            properties["hostCategory"] = [
                "type": "string",
                "enum": MCPHostCategory.allCases.map(\.rawValue)
            ]
            properties["sessionIDPrefix"] = ["type": "string", "description": "Opaque session ID prefix."]
            properties["domain"] = ["type": "string", "description": "Case-insensitive substring match against the disclosed request host."]
            properties["path"] = ["type": "string", "description": "Case-insensitive substring match against the disclosed request path."]
            properties["startedAfter"] = ["type": "string", "format": "date-time", "description": "Inclusive lower bound (ISO 8601)."]
            properties["startedBefore"] = ["type": "string", "format": "date-time", "description": "Inclusive upper bound (ISO 8601)."]
            properties["statusCode"] = ["type": "integer", "minimum": 100, "maximum": 599, "description": "Exact HTTP status code."]
            properties["statusClass"] = ["type": "string", "enum": ["2xx", "3xx", "4xx", "5xx", "error", "non200"], "description": "Status family filter."]
            properties["minDurationMs"] = ["type": "number", "minimum": 0, "description": "Minimum total duration in milliseconds."]
            properties["hasOverrideHit"] = ["type": "boolean", "description": "Filter by whether an active rule/effect matched."]
            properties["bodyAvailable"] = ["type": "boolean", "description": "Filter by whether response body bytes are retained."]
            properties["deduplicateBy"] = ["type": "string", "enum": ["endpoint"], "description": "Optional grouping mode; endpoint collapses matched sessions into endpointGroups."]
            properties["includeAuthChain"] = ["type": "boolean", "description": "Include zero-secret auth/cookie continuity report across matched sessions."]
            inputSchema = [
                "type": "object",
                "properties": properties,
                "additionalProperties": false
            ]
        case "capture_digest":
            inputSchema = [
                "type": "object",
                "properties": [
                    "ifStateToken": [
                        "type": "string",
                        "description": "Previously returned state token; returns unchanged=true when still current."
                    ],
                    "knownLatestSequence": [
                        "type": "integer",
                        "minimum": 0,
                        "description": "Latest sequence already cached, used to distinguish new sessions from lifecycle updates."
                    ]
                ],
                "additionalProperties": false
            ]
        case "audit_cache_efficiency":
            inputSchema = [
                "type": "object",
                "properties": [:],
                "additionalProperties": false
            ]
        case "investigation_snapshot":
            inputSchema = [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "minimum": 1, "maximum": 25],
                    "sinceSequence": [
                        "type": "integer",
                        "minimum": 0,
                        "description": "Return only recent evidence newer than this known sequence."
                    ],
                    "ifStateToken": [
                        "type": "string",
                        "description": "Previously returned state token; returns unchanged=true without issuing new evidence when still current."
                    ]
                ],
                "additionalProperties": false
            ]
        case "evidence_get":
            inputSchema = [
                "type": "object",
                "properties": ["evidenceRef": ["type": "string", "minLength": 1]],
                "required": ["evidenceRef"],
                "additionalProperties": false
            ]
        case "read_batch":
            inputSchema = [
                "type": "object",
                "properties": [
                    "requests": [
                        "type": "array",
                        "minItems": 1,
                        "maxItems": 8,
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string"],
                                "arguments": ["type": "object"]
                            ],
                            "required": ["name"],
                            "additionalProperties": false
                        ]
                    ]
                ],
                "required": ["requests"],
                "additionalProperties": false
            ]
        case "capture_marker_create":
            inputSchema = [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "Required marker name used as a timeline anchor."
                    ],
                    "detail": [
                        "type": "string",
                        "description": "Optional free-form detail stored in the marker payload."
                    ],
                    "label": [
                        "type": "string",
                        "description": "Optional human label for the marker."
                    ]
                ],
                "required": ["name"],
                "additionalProperties": false
            ]
        case "capture_restore_rolling":
            inputSchema = [
                "type": "object",
                "properties": [:],
                "additionalProperties": false
            ]
        case "session_summary":
            let properties: [String: Any] = [
                "sessionID": [
                    "type": "string",
                    "format": "uuid",
                    "description": "Opaque session identifier returned by a session query."
                ],
                "includeHeaders": [
                    "type": "boolean",
                    "description": "Request full header values for the selected headerSource (requires approval)."
                ],
                "headerSource": [
                    "type": "string",
                    "enum": MCPSessionHeaderSource.allCases.map(\.rawValue),
                    "description": "Select request, response, or both header disclosure; defaults to both."
                ],
                "includeQuery": [
                    "type": "boolean",
                    "description": "Request query parameter names and values (requires approval)."
                ],
                "includeBody": [
                    "type": "boolean",
                    "description": "Request a bounded body excerpt (requires approval). Defaults to the response body."
                ],
                "bodySource": [
                    "type": "string",
                    "enum": MCPSessionBodySource.allCases.map(\.rawValue),
                    "description": "Select response or request body disclosure; defaults to response."
                ],
                "approval": [
                    "type": "object",
                    "description": "One-use authorization returned after in-app approval."
                ]
            ]
            inputSchema = [
                "type": "object",
                "properties": properties,
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "artifact_compare_responses", "capture_calculate", "artifact_calculate", "artifact_source_register", "artifact_source_status", "artifact_source_inspect", "artifact_source_release", "artifact_inventory", "artifact_search", "artifact_response_brief":
            inputSchema = ArtifactToolSchema.input(name)
        case "response_evidence_brief":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": ["type": "string", "format": "uuid"],
                    "selectionPointer": ["type": "string", "maxLength": 4096,
                        "description": "RFC 6901 pointer; empty selects root. Complete JSON response up to 262144 UTF-8 bytes. Counts and at most 32 immediate fields; no scalar values unless fieldPointers is specified. Body-read approval required."],
                    "includeStructure": ["type": "boolean", "description": "Opt-in nested path counts; depth 4, 32 nodes and 20000 visited values. Check structureCoverage and structureLimits."],
                    "fieldPointers": ["type": "array", "minItems": 1, "maxItems": 8, "items": ["type": "string", "minLength": 1, "maxLength": 128], "description": "Optional RFC 6901 pointers relative to each selected item to project into a compact tabular projection."],
                    "rowLimit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 25, "description": "Maximum projected rows when fieldPointers is supplied."],
                    "ifBriefDigest": ["type": "string", "pattern": "^[0-9a-f]{64}$"],
                    "approval": ["type": "object"]
                ],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "investigation_compare_brief":
            inputSchema = [
                "type": "object",
                "properties": [
                    "baselineSessionIDs": ["type": "array", "minItems": 1, "maxItems": 16, "uniqueItems": true, "items": ["type": "string", "format": "uuid"]],
                    "candidateSessionIDs": ["type": "array", "minItems": 1, "maxItems": 16, "uniqueItems": true, "items": ["type": "string", "format": "uuid"]],
                    "ifBriefDigest": ["type": "string", "pattern": "^[0-9a-f]{64}$"],
                    "selectionPointer": ["type": "string", "maxLength": 4096],
                    "includeValueDiff": ["type": "boolean", "description": "Opt-in bounded RFC 6902-style scalar/value diff across aligned pairs."],
                    "ignorePointers": ["type": "array", "maxItems": 16, "items": ["type": "string", "minLength": 1, "maxLength": 128], "description": "Optional JSON Pointers (relative to selectionPointer) to exclude from valueChanges."],
                    "approval": ["type": "object"]
                ],
                "required": ["baselineSessionIDs", "candidateSessionIDs"],
                "additionalProperties": false
            ]
        case "list_discovered_devices":
            inputSchema = [
                "type": "object",
                "properties": [:],
                "additionalProperties": false
            ]
        case "set_device_alias":
            inputSchema = [
                "type": "object",
                "properties": [
                    "ipAddress": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 64,
                        "description": "Exact client IP returned by list_discovered_devices."
                    ],
                    "alias": [
                        "type": ["string", "null"],
                        "maxLength": 80,
                        "description": "Local friendly name. Omit, pass null, or pass an empty string to clear it."
                    ]
                ],
                "required": ["ipAddress"],
                "additionalProperties": false
            ]
        case "sessions_export":
            var properties = sessionQueryProperties()
            properties["method"] = ["type": "string", "description": "Exact HTTP method."]
            properties["hostCategory"] = [
                "type": "string",
                "enum": MCPHostCategory.allCases.map(\.rawValue)
            ]
            properties["sessionIDPrefix"] = ["type": "string", "description": "Opaque session ID prefix."]
            properties["domain"] = ["type": "string", "description": "Case-insensitive substring match against the request host."]
            properties["path"] = ["type": "string", "description": "Case-insensitive substring match against the request path."]
            properties["startedAfter"] = ["type": "string", "format": "date-time", "description": "Inclusive lower bound (ISO 8601)."]
            properties["startedBefore"] = ["type": "string", "format": "date-time", "description": "Inclusive upper bound (ISO 8601)."]
            properties["format"] = ["type": "string", "enum": ["json", "ndjson", "har"], "description": "Export format. Defaults to json."]
            properties["includeHeaders"] = ["type": "boolean", "description": "Request full header values (requires approval)."]
            properties["includeBody"] = ["type": "boolean", "description": "Request bodies (requires approval)."]
            properties["maxSessions"] = [
                "type": "integer",
                "minimum": 1,
                "maximum": 1_000_000,
                "description": "Export size bound. Inline delivery defaults to 500 (hard cap 500). With deliverFile, omitted means full matching capture (safety valve up to 1_000_000)."
            ]
            properties["deliverFile"] = [
                "type": "boolean",
                "description": "When true, write the full export under JoesProxy MCPExports and return outputPath instead of inlining content. Used by CLI --output / full HAR export.",
                "default": false
            ]
            properties["approval"] = ["type": "object", "description": "One-use authorization returned after in-app approval."]
            inputSchema = [
                "type": "object",
                "properties": properties,
                "additionalProperties": false
            ]
        case "repro_export_package":
            inputSchema = [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "maxLength": 160],
                    "notes": ["type": "string", "maxLength": 2_000],
                    "maxSessions": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": ReproPackageEngine.maximumSessionCount
                    ]
                ],
                "additionalProperties": false
            ]
        case "repro_inspect_package":
            inputSchema = [
                "type": "object",
                "properties": [
                    "packageBase64": [
                        "type": "string",
                        "description": "Base64-encoded .jproxy-repro data within the MCP request budget."
                    ]
                ],
                "required": ["packageBase64"],
                "additionalProperties": false
            ]
        case "media_summary", "media_manifest_structure", "media_readiness", "media_context", "response_context":
            inputSchema = [
                "type": "object",
                "properties": ["sessionID": sessionIDSchema()],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "response_text_search":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": sessionIDSchema(),
                    "find": [
                        "type": "string",
                        "minLength": 3,
                        "description": "Exact UTF-8 literal to search; case-sensitive, no regex."
                    ],
                    "includeContext": [
                        "type": "boolean",
                        "description": "When true, return short untrusted context windows (requires body-read approval)."
                    ],
                    "approval": [
                        "type": "object",
                        "description": "One-use authorization returned after in-app approval for includeContext."
                    ]
                ],
                "required": ["sessionID", "find"],
                "additionalProperties": false
            ]
        case "response_text_read":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": sessionIDSchema(),
                    "byteOffset": [
                        "type": "integer",
                        "minimum": 0,
                        "description": "Byte offset into the decoded UTF-8 revision."
                    ],
                    "byteLength": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": MCPResourceBudget.maxDisclosedItemBytes,
                        "description": "Maximum bytes to return in this page."
                    ],
                    "cursor": [
                        "type": "string",
                        "description": "Opaque next-page cursor from a previous response_text_read."
                    ],
                    "approval": [
                        "type": "object",
                        "description": "One-use authorization returned after in-app approval."
                    ]
                ],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "media_related_sessions":
            var properties = paginationProperties()
            properties["sessionID"] = sessionIDSchema()
            inputSchema = [
                "type": "object",
                "properties": properties,
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "media_inspection_start":
            let captureOnlyAnalyses = MCPMediaAnalysisKind.allCases.filter { $0 != .liveMediaEngine }
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": sessionIDSchema(),
                    "analyses": [
                        "type": "array",
                        "minItems": 1,
                        "maxItems": captureOnlyAnalyses.count,
                        "uniqueItems": true,
                        "items": [
                            "type": "string",
                            "enum": captureOnlyAnalyses.map(\.rawValue)
                        ]
                    ],
                    "sampleTimeSeconds": [
                        "type": "number",
                        "minimum": 0,
                        "description": "Captured media-engine frame sample time; defaults to 1 second."
                    ],
                    "approval": [
                        "type": "object",
                        "description": "One-use authorization returned after in-app approval."
                    ]
                ],
                "required": ["sessionID", "analyses"],
                "additionalProperties": false
            ]
        case "operation_status":
            inputSchema = [
                "type": "object",
                "properties": [
                    "operationID": [
                        "type": "string",
                        "description": "Opaque operation identifier returned by an asynchronous start tool."
                    ],
                    "projection": projectionSchema(),
                    "includeResult": [
                        "type": "boolean",
                        "description": "Include the complete bounded result when available; equivalent to full projection."
                    ],
                    "ifStatus": [
                        "type": "string",
                        "description": "Previously observed status; unchanged=true indicates no state transition."
                    ]
                ],
                "required": ["operationID"],
                "additionalProperties": false
            ]
        case "operation_cancel":
            inputSchema = [
                "type": "object",
                "properties": [
                    "operationID": [
                        "type": "string",
                        "description": "Opaque operation identifier returned by an asynchronous start tool."
                    ],
                    "projection": projectionSchema()
                ],
                "required": ["operationID"],
                "additionalProperties": false
            ]
        case "client_cleanup_status", "approvals_list":
            inputSchema = ["type": "object", "additionalProperties": false]
        case "runtime_status":
            inputSchema = [
                "type": "object",
                "properties": [
                    "expectedRuntime": [
                        "type": "object",
                        "properties": [
                            "appBuildFingerprint": ["type": "string", "maxLength": 128],
                            "marketingVersion": ["type": "string", "maxLength": 64],
                            "buildVersion": ["type": "string", "maxLength": 64],
                            "capabilitiesBundleVersion": ["type": "string", "maxLength": 128],
                            "capabilitiesManifestDigest": ["type": "string", "maxLength": 128],
                            "skillVersion": ["type": "string", "maxLength": 64]
                        ],
                        "additionalProperties": false
                    ]
                ],
                "additionalProperties": false
            ]
        case "setup_readiness":
            inputSchema = [
                "type": "object",
                "properties": [
                    "target": [
                        "type": "string",
                        "enum": MCPSetupReadinessTarget.allCases.map(\.rawValue),
                        "description": "Explicit onboarding target. Remote installation and trust remain user-confirmed or not observable."
                    ]
                ],
                "required": ["target"],
                "additionalProperties": false
            ]
        case "https_rules_get", "https_rules_set", "https_rules_restore":
            var properties: [String: Any] = ["host": ["type": "string", "maxLength": 253],
                "recoveryID": ["type": "string", "format": "uuid", "description": "Owner-bound receipt ID; choose before set, reuse for inspection and approved restore."]]
            var required = ["host"]
            if name != "https_rules_get" {
                properties["mode"] = ["type": "string", "enum": MCPHTTPSRules.Mode.allCases.map(\.rawValue)]
                properties["expectedRevision"] = ["type": "string"]
                properties["scope"] = ["type": "string", "enum": ["host_and_subdomains_all_clients"]]
                properties["approval"] = ["type": "object"]
                required += ["expectedRevision", "scope"]
                if name == "https_rules_restore" {
                    properties.removeValue(forKey: "mode")
                    required.append("recoveryID")
                } else { required.append("mode") }
            }
            inputSchema = ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        case "capture_status":
            inputSchema = ["type": "object", "properties": [:], "additionalProperties": false]
        case "proxy_start", "proxy_stop", "mcp_stop", "capture_resume":
            inputSchema = [
                "type": "object",
                "properties": [
                    "approval": [
                        "type": "object",
                        "description": "Optional explicit one-use authorization; normal clients retry identical arguments after approval."
                    ]
                ],
                "additionalProperties": false
            ]
        case "bookmarks_list":
            inputSchema = [
                "type": "object",
                "properties": projectedPaginationProperties(),
                "additionalProperties": false
            ]
        case "overrides_list":
            var overrideProperties = projectedPaginationProperties()
            overrideProperties["sourceKind"] = ["type": "string"]
            inputSchema = [
                "type": "object",
                "properties": overrideProperties,
                "additionalProperties": false
            ]
        case "bookmark_get":
            inputSchema = [
                "type": "object",
                "properties": ["bookmarkID": opaqueUUIDSchema(description: "Opaque bookmark identifier.")],
                "required": ["bookmarkID"],
                "additionalProperties": false
            ]
        case "override_get":
            inputSchema = [
                "type": "object",
                "properties": ["overrideID": opaqueUUIDSchema(description: "Opaque response-override identifier.")],
                "required": ["overrideID"],
                "additionalProperties": false
            ]
        case "capture_activity_since_marker":
            inputSchema = [
                "type": "object",
                "properties": [
                    "markerSessionID": opaqueUUIDSchema(description: "sessionID returned by capture_marker_create."),
                    "sinceSequence": ["type": "integer", "minimum": 0, "description": "Alternative to markerSessionID: inspect traffic newer than this captureSequence."],
                    "overrideID": opaqueUUIDSchema(description: "Optional response-override identifier to check for hits and near-miss predicate diagnostics."),
                    "limit": ["type": "integer", "minimum": 1, "maximum": MCPResourceBudget.maxPageSize, "default": 20]
                ],
                "additionalProperties": false
            ]
        case "discover_response_structure":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionIDs": [
                        "type": "array",
                        "items": opaqueUUIDSchema(description: "Opaque captured-session identifier."),
                        "minItems": 1,
                        "maxItems": MCPResourceBudget.maxPageSize
                    ]
                ],
                "required": ["sessionIDs"],
                "additionalProperties": false
            ]
        case "preview_live_rewrite":
            inputSchema = previewLiveRewriteInputSchema()
        case "preview_hls_codecs_edit":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": opaqueUUIDSchema(description: "Opaque captured HLS master session identifier."),
                    "edits": [
                        "type": "array",
                        "minItems": 1,
                        "maxItems": 100,
                        "items": [
                            "type": "object",
                            "properties": [
                                "variantRef": ["type": "string"],
                                "codecs": ["type": "string", "maxLength": 512]
                            ],
                            "required": ["variantRef", "codecs"],
                            "additionalProperties": false
                        ]
                    ],
                    "matchMode": [
                        "type": "string",
                        "enum": ResponseOverrideMatchMode.allCases.map(\.rawValue),
                        "default": ResponseOverrideMatchMode.ignoreQuery.rawValue
                    ],
                    "path": ["type": "string"]
                ],
                "required": ["sessionID", "edits"],
                "additionalProperties": false
            ]
        case "preview_response_edit":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": opaqueUUIDSchema(description: "Opaque captured session identifier."),
                    "edits": [
                        "type": "array",
                        "minItems": 1,
                        "maxItems": 100,
                        "items": [
                            "type": "object",
                            "properties": [
                                "selector": [
                                    "type": "object",
                                    "properties": [
                                        "kind": ["type": "string", "enum": ["exactText", "matchRef"]],
                                        "find": ["type": "string"],
                                        "expectedOccurrences": ["type": "integer", "minimum": 0],
                                        "matchRef": ["type": "string"],
                                        "matchRefs": [
                                            "type": "array",
                                            "items": ["type": "string"],
                                            "minItems": 1,
                                            "maxItems": 100
                                        ]
                                    ],
                                    "required": ["kind"],
                                    "additionalProperties": false
                                ],
                                "operation": [
                                    "type": "object",
                                    "properties": [
                                        "kind": [
                                            "type": "string",
                                            "enum": ["replace", "insertBefore", "insertAfter", "delete"]
                                        ],
                                        "text": ["type": "string", "maxLength": 4096]
                                    ],
                                    "required": ["kind"],
                                    "additionalProperties": false
                                ]
                            ],
                            "required": ["selector", "operation"],
                            "additionalProperties": false
                        ]
                    ],
                    "matchMode": [
                        "type": "string",
                        "enum": ResponseOverrideMatchMode.allCases.map(\.rawValue),
                        "default": ResponseOverrideMatchMode.ignoreQuery.rawValue
                    ],
                    "path": ["type": "string"]
                ],
                "required": ["sessionID", "edits"],
                "additionalProperties": false
            ]
        case "propose_create_block", "propose_create_map_local", "propose_create_map_remote", "propose_create_bookmark":
            inputSchema = mutationMatcherInputSchema(toolName: name)
        case "propose_create_response_draft":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": opaqueUUIDSchema(description: "Opaque captured session identifier."),
                    "label": ["type": "string"],
                    "matchMode": [
                        "type": "string",
                        "enum": ResponseOverrideMatchMode.allCases.map(\.rawValue),
                        "default": ResponseOverrideMatchMode.ignoreQuery.rawValue
                    ],
                    "idempotencyKey": ["type": "string"]
                ],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "propose_commit_response_edit":
            inputSchema = [
                "type": "object",
                "properties": [
                    "draftID": opaqueUUIDSchema(description: "Opaque response-draft identifier."),
                    "responseEditPreviewDigest": ["type": "string"],
                    "previewDigest": [
                        "type": "string",
                        "description": "Alias for responseEditPreviewDigest."
                    ],
                    "idempotencyKey": ["type": "string"]
                ],
                "required": ["draftID"],
                "additionalProperties": false
            ]
        case "propose_delete_response_draft":
            inputSchema = [
                "type": "object",
                "properties": [
                    "draftID": opaqueUUIDSchema(description: "Opaque response-draft identifier."),
                    "idempotencyKey": ["type": "string"]
                ],
                "required": ["draftID"],
                "additionalProperties": false
            ]
        case "response_drafts_list":
            inputSchema = [
                "type": "object",
                "properties": [:],
                "additionalProperties": false
            ]
        case "response_draft_get":
            inputSchema = [
                "type": "object",
                "properties": [
                    "draftID": opaqueUUIDSchema(description: "Opaque response-draft identifier.")
                ],
                "required": ["draftID"],
                "additionalProperties": false
            ]
        case "apply_create_block", "apply_create_map_remote",
             "apply_create_rewrite", "apply_create_live_rewrite", "apply_create_bookmark",
             "apply_create_response_draft", "apply_commit_response_edit", "apply_delete_response_draft",
             "apply_create_collection_mock":
            inputSchema = mutationApplyInputSchema()
        case "apply_create_map_local":
            inputSchema = mapLocalApplyInputSchema()
        case "propose_create_live_rewrite":
            inputSchema = liveRewriteCreateInputSchema()
        case "preview_collection_mock":
            inputSchema = collectionMockPreviewInputSchema()
        case "propose_create_collection_mock":
            inputSchema = collectionMockCreateInputSchema()
        case "propose_create_rewrite":
            inputSchema = [
                "type": "object",
                "properties": [
                    "bookmarkID": opaqueUUIDSchema(description: "Opaque bookmark identifier."),
                    "jsonPath": ["type": "string"],
                    "operation": ["type": "string", "enum": ["set", "insert"]],
                    "overrideValue": ["type": "object"],
                    "label": ["type": "string"]
                ],
                "required": ["bookmarkID", "jsonPath", "overrideValue"],
                "additionalProperties": false
            ]
        case "propose_enable_rule":
            inputSchema = [
                "type": "object",
                "properties": [
                    "overrideID": opaqueUUIDSchema(description: "Opaque response-override identifier."),
                    "idempotencyKey": ["type": "string"],
                    "acceptConfounder": [
                        "type": "boolean",
                        "description": "Required when enabling would confound a clean measurement (overlapping enabled rules, active scenarios, or multi-match pathSuffix)."
                    ]
                ],
                "required": ["overrideID"],
                "additionalProperties": false
            ]
        case "propose_disable_rule":
            inputSchema = [
                "type": "object",
                "properties": [
                    "overrideID": opaqueUUIDSchema(description: "Opaque response-override identifier."),
                    "idempotencyKey": ["type": "string"]
                ],
                "required": ["overrideID"],
                "additionalProperties": false
            ]
        case "propose_delete_rule":
            inputSchema = [
                "type": "object",
                "properties": [
                    "overrideID": opaqueUUIDSchema(description: "Opaque response-override identifier to permanently delete (MCP-owned only)."),
                    "idempotencyKey": ["type": "string"]
                ],
                "required": ["overrideID"],
                "additionalProperties": false
            ]
        case "apply_enable_rule":
            inputSchema = [
                "type": "object",
                "properties": [
                    "proposalToken": ["type": "string"],
                    "idempotencyKey": ["type": "string"],
                    "acceptConfounder": [
                        "type": "boolean",
                        "description": "Required when enabling would still confound a clean measurement at apply time."
                    ],
                    "approval": [
                        "type": "object",
                        "description": "One-use authorization returned after in-app approval."
                    ]
                ],
                "required": ["proposalToken"],
                "additionalProperties": false
            ]
        case "apply_disable_rule":
            inputSchema = mutationApplyInputSchema()
        case "apply_delete_rule":
            inputSchema = mutationApplyInputSchema()
        case "propose_enable_rewrite", "propose_disable_rewrite":
            inputSchema = [
                "type": "object",
                "properties": [
                    "bookmarkID": opaqueUUIDSchema(description: "Opaque bookmark identifier."),
                    "rewriteID": opaqueUUIDSchema(description: "Opaque rewrite identifier within the bookmark."),
                    "idempotencyKey": ["type": "string"]
                ],
                "required": ["bookmarkID", "rewriteID"],
                "additionalProperties": false
            ]
        case "apply_enable_rewrite", "apply_disable_rewrite":
            inputSchema = mutationApplyInputSchema()
        case "propose_change_throttle":
            inputSchema = [
                "type": "object",
                "properties": [
                    "isEnabled": ["type": "boolean"],
                    "selectedPresetID": ["type": "string"],
                    "customDownstreamKbps": ["type": "integer"],
                    "customUpstreamKbps": ["type": "integer"],
                    "latencyMs": ["type": "integer"],
                    "idempotencyKey": ["type": "string"]
                ],
                "additionalProperties": false
            ]
        case "apply_change_throttle":
            inputSchema = mutationApplyInputSchema()
        case "hls_fixture_capabilities", "hls_fixture_profiles_list":
            inputSchema = [
                "type": "object",
                "properties": [:],
                "additionalProperties": false
            ]
        case "hls_fixture_status":
            inputSchema = [
                "type": "object",
                "properties": [
                    "runID": opaqueUUIDSchema(description: "Optional opaque fixture run identifier.")
                ],
                "additionalProperties": false
            ]
        case "hls_fixture_window_preview":
            inputSchema = [
                "type": "object",
                "properties": [
                    "runID": opaqueUUIDSchema(description: "Opaque active fixture run identifier."),
                    "path": [
                        "type": "string",
                        "description": "Rendition playlist relative path (e.g. audio-en/stream.m3u8)."
                    ],
                    "elapsedSeconds": [
                        "type": "number",
                        "description": "Optional simulated seconds since run start for deterministic live publication. Static VOD output remains clock-independent. Omit to use the fixture clock."
                    ]
                ],
                "required": ["runID", "path"],
                "additionalProperties": false
            ]
        case "propose_hls_fixture_start":
            inputSchema = [
                "type": "object",
                "properties": [
                    "profileID": [
                        "type": "string",
                        "description": "Bundled profile directory name (e.g. baseline-aligned-codecs)."
                    ],
                    "playbackConfiguration": [
                        "type": "object",
                        "properties": [
                            "presentationMode": ["type": "string", "enum": ["vodStatic", "liveLoop"]],
                            "timeShiftMode": ["type": "string", "enum": ["off", "warmDVR", "coldDVR"]],
                            "intent": ["type": "string", "enum": ["conformant", "deliberateFault"]],
                            "windowSegmentCount": ["type": "integer", "minimum": 2, "maximum": 30],
                            "loopBoundaryTreatment": [
                                "type": "string",
                                "enum": ["declareDiscontinuity", "omitDiscontinuity"]
                            ],
                            "segmentURIIdentity": [
                                "type": "string",
                                "enum": ["uniquePerMediaSequence", "reuseAssetURI"]
                            ],
                            "targetDurationTreatment": [
                                "type": "string",
                                "enum": ["source", "underreportByOneSecond"]
                            ],
                            "programDateTimeTreatment": ["type": "string", "enum": ["include", "omit"]],
                            "playlistCachePolicy": ["type": "string", "enum": ["noCache", "noStore", "maxAge"]],
                            "playlistMaxAgeSeconds": ["type": "integer", "minimum": 0, "maximum": 60]
                        ],
                        "additionalProperties": false
                    ],
                    "idempotencyKey": ["type": "string"]
                ],
                "required": ["profileID"],
                "additionalProperties": false
            ]
        case "apply_hls_fixture_start":
            inputSchema = mutationApplyInputSchema()
        case "hls_fixture_stop":
            inputSchema = [
                "type": "object",
                "properties": [
                    "runID": opaqueUUIDSchema(description: "Opaque fixture run identifier to stop.")
                ],
                "required": ["runID"],
                "additionalProperties": false
            ]
        case "hls_substitution_profiles_list":
            inputSchema = ["type": "object", "properties": [:], "additionalProperties": false]
        case "propose_hls_substitution_start":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": opaqueUUIDSchema(description: "Optional captured HLS session used to derive origin and playlist path."),
                    "profileID": ["type": "string"],
                    "sourceClientAddress": ["type": "string", "minLength": 1, "maxLength": 256,
                        "description": "Explicit device client for scoped lab routes; requires selectedPlaylist and exact canonical entry query. Omission retains legacy all-client scope."],
                    "missingTextTrackID": ["type": "string", "minLength": 1, "maxLength": 64,
                        "description": "Reviewed local 404 fault for one profile text track; requires sourceClientAddress."],
                    "scope": ["type": "string", "enum": ["selectedPlaylist", "host"]],
                    "conflictStrategy": ["type": "string", "enum": ["cancel", "replaceExisting"]],
                    "scheme": ["type": "string", "enum": ["http", "https"]],
                    "host": ["type": "string"],
                    "port": ["type": "integer", "minimum": 1, "maximum": 65_535],
                    "path": ["type": "string"],
                    "playbackConfiguration": [
                        "type": "object",
                        "properties": [
                            "presentationMode": ["type": "string", "enum": ["vodStatic", "liveLoop"]],
                            "timeShiftMode": ["type": "string", "enum": ["off", "warmDVR", "coldDVR"]],
                            "intent": ["type": "string", "enum": ["conformant", "deliberateFault"]],
                            "windowSegmentCount": ["type": "integer", "minimum": 2, "maximum": 30],
                            "loopBoundaryTreatment": [
                                "type": "string",
                                "enum": ["declareDiscontinuity", "omitDiscontinuity"]
                            ],
                            "segmentURIIdentity": [
                                "type": "string",
                                "enum": ["uniquePerMediaSequence", "reuseAssetURI"]
                            ],
                            "targetDurationTreatment": [
                                "type": "string",
                                "enum": ["source", "underreportByOneSecond"]
                            ],
                            "programDateTimeTreatment": ["type": "string", "enum": ["include", "omit"]],
                            "playlistCachePolicy": ["type": "string", "enum": ["noCache", "noStore", "maxAge"]],
                            "playlistMaxAgeSeconds": ["type": "integer", "minimum": 0, "maximum": 60]
                        ],
                        "additionalProperties": false
                    ],
                    "ttlSeconds": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": Int(HLSSubstitutionTTLPolicy.maxTTL),
                        "description": "How long the substitution stays active before it fails open to the real upstream automatically. Defaults to \(Int(HLSSubstitutionTTLPolicy.defaultTTL)) seconds (30 minutes) when omitted — today's original, only-ever duration. Use a longer value to avoid re-preparing/re-approving every 30 minutes during active debugging; hls_substitution_extend can also push an already-running substitution's expiry out further without restarting it."
                    ],
                    "idempotencyKey": ["type": "string"]
                ],
                "required": ["profileID", "scope", "conflictStrategy"],
                "additionalProperties": false
            ]
        case "apply_hls_substitution_start":
            inputSchema = mutationApplyInputSchema()
        case "hls_substitution_status":
            inputSchema = [
                "type": "object",
                "properties": [
                    "experimentID": opaqueUUIDSchema(description: "Optional owned HLS substitution experiment identifier.")
                ],
                "additionalProperties": false
            ]
        case "hls_substitution_stop":
            inputSchema = [
                "type": "object",
                "properties": [
                    "experimentID": opaqueUUIDSchema(description: "Owned HLS substitution experiment identifier to stop.")
                ],
                "required": ["experimentID"],
                "additionalProperties": false
            ]
        case "hls_substitution_extend":
            inputSchema = [
                "type": "object",
                "properties": [
                    "experimentID": opaqueUUIDSchema(description: "Owned, currently active HLS substitution experiment identifier to extend."),
                    "ttlSeconds": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": Int(HLSSubstitutionTTLPolicy.maxTTL),
                        "description": "New expiry, measured from now (not additive on top of whatever time was left). Defaults to \(Int(HLSSubstitutionTTLPolicy.defaultTTL)) seconds when omitted. No propose/apply/approval step — this only changes how long an already-approved substitution keeps running, not what it serves."
                    ]
                ],
                "required": ["experimentID"],
                "additionalProperties": false
            ]
        case "openapi_pack_preview", "propose_openapi_pack_start":
            inputSchema = [
                "type": "object",
                "properties": [
                    "openapiDocumentBookmarkRef": [
                        "type": "string",
                        "description": "Opaque base64 bookmark for a local OpenAPI 3.0 JSON file. Never a filesystem path."
                    ],
                    "scheme": ["type": "string", "enum": ["http", "https"]],
                    "host": ["type": "string"],
                    "port": ["type": "integer", "minimum": 1, "maximum": 65_535],
                    "ttlSeconds": ["type": "integer", "minimum": 1, "maximum": 86_400],
                    "conflictStrategy": ["type": "string", "enum": ["refuse", "replaceConflicts"]],
                    "idempotencyKey": ["type": "string"]
                ],
                "required": ["openapiDocumentBookmarkRef"],
                "additionalProperties": false
            ]
        case "apply_openapi_pack_start":
            inputSchema = mutationApplyInputSchema()
        case "openapi_pack_status":
            inputSchema = [
                "type": "object",
                "properties": [
                    "packID": opaqueUUIDSchema(description: "Optional owned OpenAPI mock-pack identifier.")
                ],
                "additionalProperties": false
            ]
        case "openapi_pack_stop":
            inputSchema = [
                "type": "object",
                "properties": [
                    "packID": opaqueUUIDSchema(description: "Owned OpenAPI mock-pack identifier to stop.")
                ],
                "required": ["packID"],
                "additionalProperties": false
            ]
        case "openapi_validate_session":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": opaqueUUIDSchema(description: "UUID of the captured session to validate against OpenAPI schema.")
                ],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "openapi_generate_mock":
            inputSchema = [
                "type": "object",
                "properties": [
                    "pathTemplate": ["type": "string", "description": "OpenAPI path template (e.g. /users/{id})."],
                    "method": ["type": "string", "description": "HTTP method (e.g. GET)."],
                    "statusCode": ["type": "string", "description": "HTTP status code (e.g. 200)."],
                    "mode": ["type": "string", "enum": ["validDefault", "boundaryEdge", "nullFields", "emptyCollections"], "description": "Mock synthesis mode."]
                ],
                "required": ["pathTemplate"],
                "additionalProperties": false
            ]
        case "openapi_import_spec":
            inputSchema = [
                "type": "object",
                "properties": [
                    "specJSON": ["type": "string", "description": "Raw OpenAPI JSON specification string."],
                    "specBase64": ["type": "string", "description": "Base64-encoded OpenAPI JSON specification bytes."],
                    "openapiDocumentBookmarkRef": ["type": "string", "description": "Bookmark ref to local OpenAPI JSON document."]
                ],
                "additionalProperties": false
            ]
        case "diagnostic_run_list", "diagnostic_run_evidence_list":
            inputSchema = [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50],
                    "offset": ["type": "integer", "minimum": 0]
                ],
                "additionalProperties": false
            ]
        case "diagnostic_run_create":
            inputSchema = [
                "type": "object",
                "properties": [
                    "hypothesisSummary": ["type": "string", "description": "Owner-authored hypothesis. Never paste untrusted captured bodies."],
                    "expectedObservation": ["type": "string"],
                    "lifetimeSeconds": ["type": "number", "minimum": 60, "maximum": 86_400],
                    "scopes": [
                        "type": "array",
                        "items": ["type": "object"],
                        "description": "Explicit http, capturedSession, or effect scopes."
                    ]
                ],
                "required": ["hypothesisSummary", "expectedObservation"],
                "additionalProperties": false
            ]
        case "diagnostic_run_brief":
            inputSchema = [
                "type": "object",
                "properties": [
                    "runID": opaqueUUIDSchema(description: "Owned diagnostic run identifier."),
                    "baselineWindowID": opaqueUUIDSchema(description: "Closed baseline window in this run."),
                    "modifiedWindowID": opaqueUUIDSchema(description: "Closed modified window in this run."),
                    "ifBriefDigest": ["type": "string", "pattern": "^[0-9a-f]{64}$"]
                ],
                "required": ["runID", "baselineWindowID", "modifiedWindowID"],
                "additionalProperties": false
            ]
        case "diagnostic_run_start", "diagnostic_run_status", "diagnostic_run_retry_cleanup":
            inputSchema = [
                "type": "object",
                "properties": [
                    "runID": opaqueUUIDSchema(description: "Owned diagnostic run identifier.")
                ],
                "required": ["runID"],
                "additionalProperties": false
            ]
        case "diagnostic_run_observations":
            inputSchema = [
                "type": "object",
                "properties": [
                    "runID": opaqueUUIDSchema(description: "Owned diagnostic run identifier."),
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                    "afterMarker": opaqueUUIDSchema(description: "Optional marker lower bound."),
                    "beforeMarker": opaqueUUIDSchema(description: "Optional marker upper bound.")
                ],
                "required": ["runID"],
                "additionalProperties": false
            ]
        case "diagnostic_run_close":
            inputSchema = [
                "type": "object",
                "properties": [
                    "runID": opaqueUUIDSchema(description: "Owned diagnostic run identifier."),
                    "requestedTerminal": [
                        "type": "string",
                        "enum": ["passed", "failed", "inconclusive", "expired"]
                    ],
                    "conclusionOutcome": [
                        "type": "string",
                        "enum": ["passed", "failed", "inconclusive"]
                    ],
                    "conclusionReasonCode": ["type": "string"],
                    "conclusionSummary": ["type": "string"],
                    "conclusionConfidence": [
                        "type": "string",
                        "enum": ["high", "medium", "low", "unassessed"]
                    ],
                    "evidenceDigest": ["type": "string"]
                ],
                "required": ["runID", "requestedTerminal"],
                "additionalProperties": false
            ]
        case "diagnostic_run_evidence_get":
            inputSchema = [
                "type": "object",
                "properties": [
                    "evidenceID": opaqueUUIDSchema(description: "Owned evidence record identifier.")
                ],
                "required": ["evidenceID"],
                "additionalProperties": false
            ]
        case "propose_diagnostic_run_recheck":
            inputSchema = [
                "type": "object",
                "properties": [
                    "evidenceID": opaqueUUIDSchema(description: "Saved evidence record to re-check.")
                ],
                "required": ["evidenceID"],
                "additionalProperties": false
            ]
        case "apply_diagnostic_run_recheck":
            inputSchema = [
                "type": "object",
                "properties": [
                    "proposalToken": ["type": "string"],
                    "freshObservation": [
                        "type": "object",
                        "description": "Optional bounded observation summary captured after driving traffic."
                    ],
                    "idempotencyKey": ["type": "string"],
                    "approval": ["type": "object"]
                ],
                "required": ["proposalToken"],
                "additionalProperties": false
            ]
        case "execute_bookmark":
            inputSchema = [
                "type": "object",
                "properties": [
                    "bookmarkID": opaqueUUIDSchema(description: "Opaque bookmark identifier."),
                    "includeCredentials": ["type": "boolean"],
                    "idempotencyKey": ["type": "string"],
                    "approval": ["type": "object"]
                ],
                "required": ["bookmarkID"],
                "additionalProperties": false
            ]
        case "replay_request":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": sessionIDSchema(),
                    "includeCredentials": ["type": "boolean"],
                    "idempotencyKey": ["type": "string"],
                    "approval": ["type": "object"]
                ],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "recapture_session_body":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": opaqueUUIDSchema(description: "Owned captured session whose response body should be recaptured — must already have a response."),
                    "includeCredentials": [
                        "type": "boolean",
                        "description": "Defaults to false, same as replay_request. Forwarding a stripped request may get a different (e.g. 401) response than the original."
                    ],
                    "idempotencyKey": ["type": "string"],
                    "approval": ["type": "object"]
                ],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "repro_replay_request":
            inputSchema = [
                "type": "object",
                "properties": [
                    "packageSessionID": ["type": "string"],
                    "method": ["type": "string", "enum": ["GET", "HEAD", "OPTIONS"]],
                    "scheme": ["type": "string", "enum": ["http", "https"]],
                    "host": ["type": "string"],
                    "port": ["type": "integer", "minimum": 1, "maximum": 65_535],
                    "path": ["type": "string"],
                    "expectedStatusCode": ["type": "integer", "minimum": 100, "maximum": 599],
                    "idempotencyKey": ["type": "string"],
                    "approval": ["type": "object"]
                ],
                "required": ["packageSessionID", "method", "scheme", "host", "path"],
                "additionalProperties": false
            ]
        case "activate_map_remote", "activate_live_rewrite", "activate_collection_mock":
            inputSchema = [
                "type": "object",
                "properties": [
                    "overrideID": opaqueUUIDSchema(description: "Opaque response-override identifier."),
                    "idempotencyKey": ["type": "string"],
                    "approval": ["type": "object"]
                ],
                "required": ["overrideID"],
                "additionalProperties": false
            ]
        case "live_media_probe_start":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": sessionIDSchema(),
                    "analyses": [
                        "type": "array",
                        "items": ["type": "string", "enum": [MCPMediaAnalysisKind.liveMediaEngine.rawValue]]
                    ],
                    "sampleTimeSeconds": ["type": "number"],
                    "approval": ["type": "object"]
                ],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "approval_status":
            inputSchema = [
                "type": "object",
                "properties": ["requestID": ["type": "string"]],
                "required": ["requestID"],
                "additionalProperties": false
            ]
        case "return_to_normal":
            inputSchema = ["type": "object", "additionalProperties": false]
        case "draft_test_scenario", "preview_test_scenario":
            inputSchema = [
                "type": "object",
                "properties": [
                    "draft": [
                        "type": "object",
                        "description": "Structured scenario draft.",
                        "properties": [
                            "id": [
                                "type": "object",
                                "properties": ["rawValue": ["type": "string"]],
                                "required": ["rawValue"],
                                "additionalProperties": false
                            ],
                            "schemaVersion": ["type": "integer", "minimum": 1],
                            "name": ["type": "string"],
                            "purpose": ["type": "string"],
                            "target": ["type": "object"],
                            "preconditions": ["type": "array", "items": ["type": "object"]],
                            "captureScope": ["type": "object"],
                            "disclosureProfileID": [
                                "type": "string",
                                "enum": MCPDisclosureProfileID.allCases.map(\.rawValue)
                            ],
                            "faults": ["type": "array", "items": ["type": "object"]],
                            "duration": ["type": "number", "minimum": 0],
                            "expiresAt": ["type": "string", "format": "date-time"],
                            "observationWindow": ["type": "object"],
                            "assertions": ["type": "array", "items": ["type": "object"]],
                            "assertionSeverity": ["type": "string"],
                            "evidenceRetentionSpec": ["type": "object"],
                            "cleanupActions": ["type": "array", "items": ["type": "object"]]
                        ],
                        "required": [
                            "id", "schemaVersion", "name", "purpose", "target", "preconditions",
                            "captureScope", "disclosureProfileID", "faults", "observationWindow",
                            "assertions", "assertionSeverity", "evidenceRetentionSpec", "cleanupActions"
                        ]
                    ],
                    "draftJSON": [
                        "type": "string",
                        "description": "Same MCPScenarioDraftInput shape as `draft`, pre-serialized as a JSON string."
                    ]
                ],
                "oneOf": [
                    ["required": ["draft"]],
                    ["required": ["draftJSON"]]
                ],
                "additionalProperties": false
            ]
        case "validate_test_scenario", "get_test_observations", "evaluate_test_assertions", "get_test_report":
            inputSchema = [
                "type": "object",
                "properties": ["scenarioID": ["type": "string", "description": "Scenario identifier returned by draft_test_scenario."]],
                "required": ["scenarioID"],
                "additionalProperties": false
            ]
        case "request_test_scenario_approval", "arm_test_scenario", "activate_test_scenario":
            inputSchema = [
                "type": "object",
                "properties": [
                    "scenarioID": ["type": "string", "description": "Scenario identifier returned by draft_test_scenario."],
                    "approval": [
                        "type": "object",
                        "description": "One-use authorization returned after in-app approval."
                    ]
                ],
                "required": ["scenarioID"],
                "additionalProperties": false
            ]
        case "stop_test_scenario", "cleanup_test_scenario":
            inputSchema = [
                "type": "object",
                "properties": [
                    "scenarioID": ["type": "string", "description": "Scenario identifier returned by draft_test_scenario."],
                    "outcome": [
                        "type": "string",
                        "enum": ["completed", "failed", "inconclusive", "canceled"],
                        "description": "Explicit terminal outcome; defaults to canceled for cleanup_test_scenario."
                    ]
                ],
                "required": ["scenarioID"],
                "additionalProperties": false
            ]
        case "certificate_status", "certificate_identity", "certificate_export":
            inputSchema = [
                "type": "object",
                "properties": [:],
                "additionalProperties": false
            ]
        case "certificate_artifacts_list":
            inputSchema = [
                "type": "object",
                "properties": [
                    "fingerprint": [
                        "type": "string",
                        "description": "Optional SHA-256 CA fingerprint filter; defaults to the active root."
                    ]
                ],
                "additionalProperties": false
            ]
        case "certificate_compare":
            inputSchema = [
                "type": "object",
                "properties": [
                    "fingerprint": ["type": "string", "description": "First SHA-256 CA fingerprint."],
                    "otherFingerprint": ["type": "string", "description": "Second SHA-256 CA fingerprint."]
                ],
                "required": ["fingerprint", "otherFingerprint"],
                "additionalProperties": false
            ]
        case "propose_certificate_cleanup":
            inputSchema = [
                "type": "object",
                "properties": [
                    "fingerprint": [
                        "type": "string",
                        "description": "SHA-256 fingerprint of the retired CA identity to clean up."
                    ],
                    "allowCurrentRoot": [
                        "type": "boolean",
                        "description": "Guard override required to target the active root identity.",
                        "default": false
                    ]
                ],
                "required": ["fingerprint"],
                "additionalProperties": false
            ]
        case "apply_certificate_cleanup":
            inputSchema = [
                "type": "object",
                "properties": [
                    "proposalToken": [
                        "type": "string",
                        "description": "Token issued by propose_certificate_cleanup; carries the target fingerprint."
                    ],
                    "idempotencyKey": ["type": "string"],
                    "approval": ["type": "object"]
                ],
                "required": ["proposalToken"],
                "additionalProperties": false
            ]
        case "propose_hypothesis_dag":
            inputSchema = [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "targetBug": ["type": "string", "description": "Short description of the bug being isolated."],
                    "nodeInputs": [
                        "type": "array",
                        "description": "Candidate root-cause hypotheses.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "title": ["type": "string"],
                                "explanation": ["type": "string"],
                                "parentID": ["type": "string"],
                                "mutationType": ["type": "string", "enum": ["jsonRewrite", "statusCodeFault", "latencyInjection", "headerMutation", "dropConnection"]],
                                "mutationTarget": ["type": "string", "description": "URL pattern the mutation would apply to."],
                                "mutationValue": ["type": "string", "description": "JSON path, status code, or header value, depending on mutationType."],
                                "expectedOutcome": ["type": "string", "description": "What a client SHOULD do if this hypothesis is correct."]
                            ],
                            "required": ["id", "title", "explanation", "mutationType", "mutationTarget", "expectedOutcome"]
                        ]
                    ]
                ],
                "required": ["name", "targetBug", "nodeInputs"],
                "additionalProperties": false
            ]
        case "step_hypothesis_graph":
            inputSchema = [
                "type": "object",
                "properties": [
                    "graphID": ["type": "string", "format": "uuid"],
                    "evidenceMatches": ["type": "boolean"],
                    "evidenceSummary": ["type": "string"]
                ],
                "required": ["graphID", "evidenceMatches", "evidenceSummary"],
                "additionalProperties": false
            ]
        case "get_fault_bisection_report":
            inputSchema = [
                "type": "object",
                "properties": ["graphID": ["type": "string", "format": "uuid"]],
                "required": ["graphID"],
                "additionalProperties": false
            ]
        case "llm_stream_inspection":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionIDs": ["type": "array", "items": ["type": "string", "format": "uuid"]],
                    "configuredCanaries": ["type": "array", "items": ["type": "string"], "description": "Known canary strings to check for leakage in streamed content."]
                ],
                "additionalProperties": false
            ]
        case "propose_llm_stream_fault":
            inputSchema = [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "urlPattern": ["type": "string"],
                    "faultKind": ["type": "string", "description": "e.g. delay, truncate, malform."],
                    "delayMs": ["type": "integer"],
                    "targetTokenIndex": ["type": "integer"]
                ],
                "required": ["name", "urlPattern", "faultKind"],
                "additionalProperties": false
            ]
        case "propose_temporal_permutation_plan":
            inputSchema = [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "targetBatch": ["type": "string"],
                    "endpoints": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "name": ["type": "string"],
                                "urlPattern": ["type": "string"],
                                "method": ["type": "string"]
                            ],
                            "required": ["id", "name", "urlPattern"]
                        ]
                    ],
                    "spacingMs": ["type": "integer", "description": "Default 150."]
                ],
                "required": ["name", "targetBatch", "endpoints"],
                "additionalProperties": false
            ]
        case "step_temporal_permutation_plan":
            inputSchema = [
                "type": "object",
                "properties": [
                    "planID": ["type": "string", "format": "uuid"],
                    "errorDetected": ["type": "boolean"],
                    "outcomeSummary": ["type": "string"]
                ],
                "required": ["planID", "errorDetected", "outcomeSummary"],
                "additionalProperties": false
            ]
        case "get_race_condition_fuzz_report":
            inputSchema = [
                "type": "object",
                "properties": ["planID": ["type": "string", "format": "uuid"]],
                "required": ["planID"],
                "additionalProperties": false
            ]
        case "propose_resilience_bisection_plan":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": ["type": "string", "format": "uuid"],
                    "name": ["type": "string", "description": "Default 'Payload Resilience Bisection'."]
                ],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "step_resilience_bisection_plan":
            inputSchema = [
                "type": "object",
                "properties": [
                    "planID": ["type": "string", "format": "uuid"],
                    "clientCrashed": ["type": "boolean"],
                    "observedError": ["type": "string"]
                ],
                "required": ["planID", "clientCrashed"],
                "additionalProperties": false
            ]
        case "get_resilience_matrix_report":
            inputSchema = [
                "type": "object",
                "properties": ["planID": ["type": "string", "format": "uuid"]],
                "required": ["planID"],
                "additionalProperties": false
            ]
        case "diff_session_trajectories":
            inputSchema = [
                "type": "object",
                "properties": [
                    "baselineSessionIDs": ["type": "array", "items": ["type": "string", "format": "uuid"]],
                    "candidateSessionIDs": ["type": "array", "items": ["type": "string", "format": "uuid"]],
                    "baselineName": ["type": "string"],
                    "candidateName": ["type": "string"]
                ],
                "required": ["baselineSessionIDs", "candidateSessionIDs"],
                "additionalProperties": false
            ]
        case "propose_semantic_mock_rule":
            inputSchema = [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "urlPattern": ["type": "string"],
                    "intentLabel": ["type": "string"],
                    "exampleQueries": ["type": "array", "items": ["type": "string"]],
                    "mockStatusCode": ["type": "integer", "description": "Default 200."],
                    "mockResponseBody": ["type": "string"],
                    "confidenceThreshold": ["type": "number", "description": "Default 0.70."]
                ],
                "required": ["name", "urlPattern", "intentLabel", "exampleQueries", "mockResponseBody"],
                "additionalProperties": false
            ]
        case "list_semantic_mock_rules", "stateful_mock_list_backends", "stateful_mock_list_presets",
             "localization_mock_list_presets":
            inputSchema = ["type": "object", "additionalProperties": false]
        case "test_semantic_query_match":
            inputSchema = [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "targetURL": ["type": "string"]
                ],
                "required": ["query"],
                "additionalProperties": false
            ]
        case "delete_semantic_mock_rule":
            inputSchema = [
                "type": "object",
                "properties": ["ruleID": ["type": "string", "format": "uuid"]],
                "required": ["ruleID"],
                "additionalProperties": false
            ]
        case "contract_diff_sessions":
            inputSchema = [
                "type": "object",
                "properties": [
                    "liveSessionID": ["type": "string", "format": "uuid"],
                    "baselineSessionID": ["type": "string", "format": "uuid"]
                ],
                "required": ["liveSessionID", "baselineSessionID"],
                "additionalProperties": false
            ]
        case "contract_regression_suite":
            inputSchema = [
                "type": "object",
                "properties": [
                    "liveSessionIDs": ["type": "array", "items": ["type": "string", "format": "uuid"]],
                    "baselineSessionIDs": ["type": "array", "items": ["type": "string", "format": "uuid"]]
                ],
                "required": ["liveSessionIDs", "baselineSessionIDs"],
                "additionalProperties": false
            ]
        case "trace_data_lineage":
            inputSchema = [
                "type": "object",
                "properties": [
                    "targetValue": ["type": "string", "description": "The value to trace provenance for, e.g. a token or account identifier (required unless mode is authChain)."],
                    "mode": ["type": "string", "enum": ["value", "authChain"], "description": "Lineage mode; authChain produces a zero-secret HMAC credential/cookie continuity report."],
                    "candidateSessionIDs": ["type": "array", "items": ["type": "string", "format": "uuid"]]
                ],
                "additionalProperties": false
            ]
        case "audit_analytics_attribution":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sinkSessionID": ["type": "string", "format": "uuid"],
                    "candidateSourceSessionIDs": ["type": "array", "items": ["type": "string", "format": "uuid"]]
                ],
                "required": ["sinkSessionID"],
                "additionalProperties": false
            ]
        case "propose_provenance_watermark":
            inputSchema = [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "urlPattern": ["type": "string"],
                    "targetKeypaths": ["type": "array", "items": ["type": "string"]],
                    "strategy": ["type": "string", "description": "e.g. prefix, suffix, property, auto."]
                ],
                "required": ["name", "urlPattern", "strategy"],
                "additionalProperties": false
            ]
        case "localization_mock_preview":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": ["type": "string", "format": "uuid"],
                    "presetID": ["type": "string"],
                    "preserveURLs": ["type": "boolean", "description": "Default true."],
                    "preserveIDs": ["type": "boolean", "description": "Default true."]
                ],
                "required": ["sessionID", "presetID"],
                "additionalProperties": false
            ]
        case "stateful_mock_install_preset":
            inputSchema = [
                "type": "object",
                "properties": [
                    "presetID": ["type": "string"],
                    "customHost": ["type": "string"]
                ],
                "required": ["presetID"],
                "additionalProperties": false
            ]
        case "stateful_mock_set_state":
            inputSchema = [
                "type": "object",
                "properties": [
                    "backendID": ["type": "string", "format": "uuid"],
                    "state": ["type": "string"]
                ],
                "required": ["backendID", "state"],
                "additionalProperties": false
            ]
        case "stateful_mock_query_entities":
            inputSchema = [
                "type": "object",
                "properties": [
                    "backendID": ["type": "string", "format": "uuid"],
                    "collection": ["type": "string"]
                ],
                "required": ["backendID", "collection"],
                "additionalProperties": false
            ]
        case "stateful_mock_reset_backend":
            inputSchema = [
                "type": "object",
                "properties": ["backendID": ["type": "string", "format": "uuid"]],
                "required": ["backendID"],
                "additionalProperties": false
            ]
        case "fault_isolation_start":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": ["type": "string", "format": "uuid"],
                    "windowSeconds": ["type": "number", "description": "Default 30."]
                ],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "fault_isolation_record_step":
            inputSchema = [
                "type": "object",
                "properties": [
                    "outcome": ["type": "string", "enum": ["crashed", "failed_assertion", "succeeded", "empty", "unknown"]],
                    "logSnippet": ["type": "string"]
                ],
                "required": ["outcome"],
                "additionalProperties": false
            ]
        case "fault_isolation_report", "fault_isolation_cancel":
            inputSchema = ["type": "object", "additionalProperties": false]
        case "cmcd_telemetry_inspection", "byte_range_efficiency_inspection":
            inputSchema = [
                "type": "object",
                "properties": ["sessionIDs": ["type": "array", "items": ["type": "string", "format": "uuid"]]],
                "required": ["sessionIDs"],
                "additionalProperties": false
            ]
        case "webvtt_subtitle_inspection":
            inputSchema = [
                "type": "object",
                "properties": [
                    "sessionID": ["type": "string", "format": "uuid"],
                    "referenceVideoSessionID": ["type": "string", "format": "uuid"]
                ],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "drm_handshake_inspection":
            inputSchema = [
                "type": "object",
                "properties": [
                    "manifestSessionID": ["type": "string", "format": "uuid"],
                    "licenseSessionIDs": ["type": "array", "items": ["type": "string", "format": "uuid"]],
                    "mediaSessionIDs": ["type": "array", "items": ["type": "string", "format": "uuid"]]
                ],
                "additionalProperties": false
            ]
        case "streaming_waterfall_inspection", "visual_asset_inspection":
            inputSchema = [
                "type": "object",
                "properties": ["sessionID": ["type": "string", "format": "uuid"]],
                "required": ["sessionID"],
                "additionalProperties": false
            ]
        case "scte35_ad_break_inspection":
            inputSchema = [
                "type": "object",
                "properties": [
                    "masterManifestSessionID": ["type": "string", "format": "uuid"],
                    "variantSessionIDs": ["type": "array", "items": ["type": "string", "format": "uuid"]]
                ],
                "required": ["masterManifestSessionID"],
                "additionalProperties": false
            ]
        case "list_synthetic_assets":
            inputSchema = ["type": "object", "additionalProperties": false]
        case "propose_inject_synthetic_item":
            inputSchema = [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "urlPattern": ["type": "string"],
                    "collectionKeypath": ["type": "string", "description": "JSON keypath to the target collection. Default '$' (root)."],
                    "position": ["type": "string", "enum": ["prepend", "append", "replace"], "description": "Default prepend."],
                    "boundAssetKind": ["type": "string", "enum": ["clearLiveHLS", "clearVODHLS", "testPatternImage", "syntheticVASTAd"], "description": "Default clearLiveHLS."],
                    "customAssetURL": ["type": "string", "description": "Overrides boundAssetKind with an explicit asset URL."],
                    "fieldOverrides": ["type": "object", "additionalProperties": ["type": "string"]],
                    "clientScope": ["type": "string", "enum": ["simulatorOnly", "allClients"], "description": "Default simulatorOnly."]
                ],
                "required": ["name", "urlPattern"],
                "additionalProperties": false
            ]
        case "list_synthetic_injection_plans":
            inputSchema = ["type": "object", "additionalProperties": false]
        case "remove_synthetic_injection_plan":
            inputSchema = [
                "type": "object",
                "properties": ["planID": ["type": "string", "format": "uuid"]],
                "required": ["planID"],
                "additionalProperties": false
            ]
        case "effect_bundle_prepare":
            inputSchema = ["type": "object", "properties": [
                "relatedResponsesJSON": ["type": "string", "maxLength": 65536,
                    "description": "JSON array of at most 8 distinct captured GET sources. Each entry: sessionID (complete source body), optional targetSessionID (observed GET destination; defaults to source) OR targetPath (unobserved root-relative path on source origin, maximum 4096 UTF-8 bytes, exact query matching; incompatible with targetSessionID and ignoredQueryNames), edits [{pointer,value}] using typed JSON, images [{pointer,assetID}] referencing image-N IDs in images array order, identityLinks [{pointer,primaryPointer}] linking to prepared primary JSON. At least one identity link per resource. Optional ignoredQueryNames lists 1–16 reviewed rotating names; all other query items must match. Exact captured destination/query is the default; no refetch or fabricated capture identity. Example: [{\"sessionID\":\"<source UUID>\",\"targetSessionID\":\"<target UUID>\",\"edits\":[{\"pointer\":\"/title\",\"value\":\"JoesProxy\"}],\"identityLinks\":[{\"pointer\":\"/id\",\"primaryPointer\":\"/items/0/id\"}]}]"],
                "sessionID": ["type": "string", "format": "uuid"],
                "name": ["type": "string", "minLength": 1],
                "idempotencyKey": ["type": "string", "minLength": 1, "maxLength": 256],
                "clientAddress": ["type": "string", "minLength": 1],
                "draftJSON": ["type": "string", "maxLength": CollectionMockDraftDecoder.maximumInputBytes,
                    "description": "Collection draft with identityPointers. For a frozen batch, supply templateIndex and expansionItems: 1–100 objects with edits [{pointer,value}] and optional images [{pointer,assetID}] referencing supplied image-N assets. Supply unique identities for every copy. Shared edits and primary image bindings apply to all copies; overlapping pointers reject. Batch order is preserved for append and prepend. Only declared countPointers change. Whole preparation fails on any invalid item; no partial publication. identityPresence accepts required (default) or wherePresent for heterogeneous objects; present null/type mismatches still fail. Optional ignoredQueryNames lists 1–16 reviewed query names; other query items must match. 64 KiB input, 5 MiB output. Activation remains separate."],
                "images": ["type": "array", "maxItems": 16, "items": [
                    "type": "object", "properties": [
                        "itemPointer": ["type": "string", "description": "Shared primary item JSON Pointer. Omit for per-item batch or related-only artwork; expansionItems or a related response must explicitly bind this image-N asset ID (zero-based images array order)."],
                        "localFileBookmarkRef": ["type": "string", "maxLength": 65536,
                            "description": "Opaque local file bookmark minted by CLI or UI; never send image bytes or a raw path."],
                        "originalURL": ["type": "string", "description": "Optional HTTP(S) URL to retain; client-cache warning applies."],
                        "deliveryURL": ["type": "string", "description": "Explicit absolute HTTP(S) image request URL, paired with imageReference; incompatible with originalURL. No client URL transformation is inferred."],
                        "imageReference": ["type": "string", "description": "Relative value written into JSON, paired with deliveryURL. Verify the client requests that delivery URL."]
                    ], "required": ["localFileBookmarkRef"], "additionalProperties": false
                ]]
            ], "required": ["sessionID", "name", "idempotencyKey", "clientAddress", "draftJSON"], "additionalProperties": false]
        case "effect_bundle_retire_preparation":
            inputSchema = ["type": "object", "properties": [
                "revisionID": ["type": "string", "format": "uuid",
                    "description": "Owned prepared handle to retire. Identical retries are safe. Imported bundles and in-progress imports are unaffected."]
            ], "required": ["revisionID"], "additionalProperties": false]
        case "effect_bundle_inspect":
            inputSchema = ["type": "object", "properties": [
                "afterMarker": ["type": "string", "description": "Unsigned decimal observation marker for retained bundle delivery evidence; pass 0 initially."],
                "revisionID": ["type": "string", "format": "uuid"],
                "bundleID": ["type": "string", "format": "uuid"],
                "packagePath": ["type": "string", "minLength": 1]
            ], "oneOf": [["required": ["revisionID"]], ["required": ["bundleID"]],
                          ["required": ["packagePath"]]], "additionalProperties": false]
        case "diagnostic_run_window_begin":
            inputSchema = ["type": "object", "properties": [
                "runID": ["type": "string", "format": "uuid"], "bundleID": ["type": "string", "format": "uuid"],
                "mode": ["type": "string", "enum": ["baseline", "modified"]]
            ], "required": ["runID", "bundleID", "mode"], "additionalProperties": false]
        case "diagnostic_run_window_end":
            inputSchema = ["type": "object", "properties": [
                "windowID": ["type": "string", "format": "uuid"],
                "targetOutcome": ["type": "string", "enum": ["confirmed", "rejected", "unknown"]],
                "outcomeSource": ["type": "string", "minLength": 1, "maxLength": 256]
            ], "required": ["windowID"], "additionalProperties": false]
        case "effect_bundle_compare":
            inputSchema = ["type": "object", "properties": [
                "baselineWindowID": ["type": "string", "format": "uuid"],
                "modifiedWindowID": ["type": "string", "format": "uuid"]
            ], "required": ["baselineWindowID", "modifiedWindowID"], "additionalProperties": false]
        case "effect_bundle_advance":
            inputSchema = ["type": "object", "properties": [
                "bundleID": ["type": "string", "format": "uuid"],
                "activationID": ["type": "string", "format": "uuid"],
                "expectedPhaseID": ["type": "string", "format": "uuid"]
            ], "required": ["bundleID", "activationID", "expectedPhaseID"], "additionalProperties": false]
        case "effect_bundle_import":
            inputSchema = [
                "type": "object",
                "properties": [
                    "packagePath": ["type": "string", "minLength": 1],
                    "revisionID": ["type": "string", "format": "uuid"]
                ],
                "oneOf": [["required": ["packagePath"]], ["required": ["revisionID"]]],
                "additionalProperties": false
            ]
        default:
            inputSchema = ["type": "object", "additionalProperties": false]
        }
        var descriptor: [String: Any] = ["name": name, "description": description,
            "inputSchema": inputSchema, "outputSchema": ["type": "object"]]
        if let analysis = MCPCapabilitiesManifestBuilder.analysis(for: name),
           let data = try? JSONEncoder().encode(analysis), let object = try? JSONSerialization.jsonObject(with: data) {
            descriptor["_meta"] = ["joesproxy.analysis": object]
        }
        return descriptor
    }

    private func paginationProperties() -> [String: Any] {
        [
            "limit": [
                "type": "integer",
                "minimum": 1,
                "maximum": MCPResourceBudget.maxPageSize
            ],
            "cursor": [
                "type": "string",
                "description": "Opaque cursor returned by the previous page."
            ]
        ]
    }

    private func sessionQueryProperties() -> [String: Any] {
        var properties = paginationProperties()
        properties["projection"] = projectionSchema()
        properties["sinceSequence"] = [
            "type": "integer",
            "minimum": 0,
            "description": "Return only sessions captured after this sequence."
        ]
        properties["ifStateToken"] = [
            "type": "string",
            "description": "Previously returned capture state token; returns unchanged=true when still current."
        ]
        properties["maxResponseBytes"] = [
            "type": "integer",
            "minimum": 4_096,
            "maximum": MCPResourceBudget.maxResponseBytes,
            "description": "Requested encoded payload budget; the server may return fewer items."
        ]
        return properties
    }

    private func projectedPaginationProperties() -> [String: Any] {
        var properties = paginationProperties()
        properties["projection"] = projectionSchema()
        return properties
    }

    private func projectionSchema() -> [String: Any] {
        [
            "type": "string",
            "enum": MCPResponseProjection.allCases.map(\.rawValue),
            "default": MCPResponseProjection.minimal.rawValue,
            "description": "minimal is decision-oriented; summary adds bounded context; full preserves all policy-allowed fields."
        ]
    }

    private func sessionIDSchema() -> [String: Any] {
        opaqueUUIDSchema(description: "Opaque captured-session identifier.")
    }

    private func opaqueUUIDSchema(description: String) -> [String: Any] {
        [
            "type": "string",
            "format": "uuid",
            "description": description
        ]
    }

    private func mutationMatcherInputSchema(toolName: String) -> [String: Any] {
        var properties: [String: Any] = [
            "method": ["type": "string"],
            "scheme": ["type": "string", "enum": ["http", "https"]],
            "host": ["type": "string"],
            "path": ["type": "string"],
            "matchMode": [
                "type": "string",
                "enum": ResponseOverrideMatchMode.allCases.map(\.rawValue)
            ],
            "port": ["type": "integer"],
            "label": ["type": "string"],
            "idempotencyKey": ["type": "string"],
            "sourceClientAddress": [
                "type": "string",
                "maxLength": 64,
                "description": "Optional exact client IP from list_discovered_devices. When set, the rule affects only requests from that proxy client."
            ],
            "hlsPreviewDigest": [
                "type": "string",
                "description": "Compatibility alias for responseEditPreviewDigest from preview_hls_codecs_edit."
            ],
            "responseEditPreviewDigest": [
                "type": "string",
                "description": "Server-retained response-edit preview digest. When present, the preview body, status, content type, and matcher are authoritative."
            ],
            "responseRevisionID": [
                "type": "string",
                "format": "uuid",
                "description": "Owned draft revision to serve via Map Local without re-previewing."
            ]
        ]
        switch toolName {
        case "propose_create_block":
            properties["statusCode"] = ["type": "integer", "minimum": 100, "maximum": 599]
            properties["dropConnection"] = [
                "type": "boolean",
                "description": "When true, close the connection with no HTTP response instead of serving statusCode — simulates a real dropped connection/timeout rather than a clean error. Defaults to false."
            ]
            properties["graphqlOperationName"] = [
                "type": "string",
                "description": "Optional GraphQL operation-name predicate: only match a POST whose JSON body's top-level operationName equals this value. Omit to match every operation on this path."
            ]
            properties["matchQueryKey"] = [
                "type": "string",
                "description": "Optional query-parameter predicate: only match a request whose query string contains this exact key=value pair (paired with matchQueryValue). Both must be supplied together. Mocks one item on a query-multiplexed endpoint (e.g. ?contentId=1234) without affecting other values of the same key on the same path."
            ]
            properties["matchQueryValue"] = ["type": "string"]
        case "propose_create_map_local":
            properties["statusCode"] = ["type": "integer", "minimum": 100, "maximum": 599]
            properties["bodyText"] = ["type": "string"]
            properties["contentType"] = ["type": "string"]
            properties["allowDuplicateScope"] = [
                "type": "boolean",
                "description": "An existing Map Local rule already covering the exact same method/host/scheme/path/matchMode is rejected by default (use `rule enable <id>` on the existing rule instead). Set true to explicitly create a duplicate anyway. Defaults to false."
            ]
            properties["fixtureRunID"] = [
                "type": "string",
                "format": "uuid",
                "description": "Delegate to a running HLS fixture run (from hls_fixture_start) instead of a static body — the fixture computes each response live (sliding playlist window, Range-aware segments). Requires matchMode: pathPrefix. Mutually exclusive with bodyText/statusCode/contentType, responseEditPreviewDigest/hlsPreviewDigest, responseRevisionID, and localDirectoryBookmarkRef. The run must be owned by the calling client and still active."
            ]
            properties["localDirectoryBookmarkRef"] = [
                "type": "string",
                "description": "Opaque base64 bookmark for a local directory (minted by joesproxyctl response map-local prepare --directory, or the app UI). Requires matchMode: pathPrefix. Mutually exclusive with bodyText/statusCode/contentType, fixtureRunID, preview digests, responseRevisionID, and localFileBookmarkRef. Never pass a raw filesystem path over MCP."
            ]
            properties["localFileBookmarkRef"] = [
                "type": "string",
                "description": "Opaque base64 bookmark for one local file (minted by joesproxyctl response map-local prepare --file, or the app UI) — the first-class replacement for the one-file-directory workaround. Unlike localDirectoryBookmarkRef, does NOT require matchMode: pathPrefix; a single file naturally wants exactPath/pathSuffix/filename. contentType is inferred from the file's extension when omitted; statusCode defaults to 200. Mutually exclusive with bodyText, fixtureRunID, preview digests, responseRevisionID, and localDirectoryBookmarkRef. Never pass a raw filesystem path over MCP."
            ]
            properties["notFoundRelativePath"] = [
                "type": "string",
                "description": "Optional relative path inside the mapped directory served as the HTTP 404 body when a requested file is missing. Only valid with localDirectoryBookmarkRef."
            ]
            properties["missingFilePolicy"] = [
                "type": "string",
                "enum": LocalDirectoryMissingFilePolicy.allCases.map(\.rawValue),
                "description": "Only valid with localDirectoryBookmarkRef. How a request under this rule's prefix with no matching local file is served: strictLocal (default) always 404s locally (today's original behavior); overlayFailOpen forwards to the real upstream server instead — every unedited sibling behaves as if no rule existed; configuredFallback serves notFoundRelativePath's bytes under a forced 404 (requires notFoundRelativePath to be set)."
            ]
            properties["forceNoCache"] = [
                "type": "boolean",
                "description": "When true, apply no-store / strip caching headers on every locally served response for this rule. Defaults to false."
            ]
            properties["graphqlOperationName"] = [
                "type": "string",
                "description": "Optional GraphQL operation-name predicate: only match a POST whose JSON body's top-level operationName equals this value. Omit to match every operation on this path. Cannot be combined with responseEditPreviewDigest/hlsPreviewDigest/responseRevisionID."
            ]
            properties["matchQueryKey"] = [
                "type": "string",
                "description": "Optional query-parameter predicate: only match a request whose query string contains this exact key=value pair (paired with matchQueryValue). Both must be supplied together. Cannot be combined with responseEditPreviewDigest/hlsPreviewDigest/responseRevisionID."
            ]
            properties["matchQueryValue"] = ["type": "string"]
        case "propose_create_map_remote":
            properties["remoteHost"] = ["type": "string"]
            properties["remotePort"] = ["type": "integer", "minimum": 1, "maximum": 65_535]
            properties["remoteScheme"] = ["type": "string", "enum": ["http", "https"]]
            properties["remotePath"] = [
                "type": "string",
                "maxLength": 2048,
                "description": "Optional destination request-target override (origin-form, must start with '/'). Omit to keep the original request's path."
            ]
            properties["remoteQueryPolicy"] = [
                "type": "string",
                "enum": MapRemoteQueryPolicy.allCases.map(\.rawValue),
                "description": "How remotePath combines with the original query: preserve (default), replace (use remoteQuery), or drop."
            ]
            properties["remoteQuery"] = [
                "type": "string",
                "maxLength": 2048,
                "description": "Replacement query string (no leading '?'), used only when remoteQueryPolicy is replace."
            ]
            properties["allowLoopbackDestination"] = [
                "type": "boolean",
                "description": "Explicit per-rule opt-in allowing loopback destinations on this Mac (requires Settings > Proxy > Local-Server Routing enabled and destination port authorized)."
            ]
            properties["preserveHostHeader"] = [
                "type": "boolean",
                "description": "When true, preserves the validated original incoming HTTP Host authority instead of rewriting Host to remoteHost (TLS SNI and cert validation stay pinned to remoteHost)."
            ]
            properties["graphqlOperationName"] = [
                "type": "string",
                "description": "Optional GraphQL operation-name predicate: only match a POST whose JSON body's top-level operationName equals this value. Omit to match every operation on this path."
            ]
            properties["matchQueryKey"] = [
                "type": "string",
                "description": "Optional query-parameter predicate: only match a request whose query string contains this exact key=value pair (paired with matchQueryValue). Both must be supplied together."
            ]
            properties["matchQueryValue"] = ["type": "string"]
        case "propose_create_bookmark":
            properties["name"] = ["type": "string"]
        default:
            break
        }
        var required = ["method", "host", "path"]
        if toolName == "propose_create_map_remote" {
            required.append("remoteHost")
        } else if toolName == "propose_create_bookmark" {
            required.append("name")
        }
        return [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    }

    private func previewLiveRewriteInputSchema() -> [String: Any] {
        let properties: [String: Any] = [
            "method": ["type": "string"],
            "scheme": ["type": "string", "enum": ["http", "https"]],
            "host": ["type": "string"],
            "path": ["type": "string"],
            "matchMode": [
                "type": "string",
                "enum": ResponseOverrideMatchMode.allCases.map(\.rawValue)
            ],
            "port": ["type": "integer"],
            "jsonPath": ["type": "string"],
            "operation": [
                "type": "string",
                "enum": [
                    "set", "insert", "insertArrayElement", "appendString", "prependString",
                    "removeProperty", "removeIndex", "move"
                ]
            ],
            "overrideValue": ["type": "object"],
            "repeatPolicy": ["type": "string", "enum": ["always", "ifMissingSuffix"]],
            "sessionIDs": [
                "type": "array",
                "items": opaqueUUIDSchema(description: "Opaque captured-session identifier to preview against."),
                "minItems": 1,
                "maxItems": MCPResourceBudget.maxPageSize
            ],
            "graphqlOperationName": [
                "type": "string",
                "description": "Optional GraphQL operation-name predicate: only match a POST whose JSON body's top-level operationName equals this value. Must match the value later passed to propose_create_live_rewrite, or the preview digest binding will be considered stale."
            ],
            "matchQueryKey": [
                "type": "string",
                "description": "Optional query-parameter predicate (paired with matchQueryValue): only match a request whose query string contains this exact key=value pair. Must match the values later passed to propose_create_live_rewrite, or the preview digest binding will be considered stale."
            ],
            "matchQueryValue": ["type": "string"]
        ]
        return [
            "type": "object",
            "properties": properties,
            "required": ["method", "host", "path", "jsonPath", "sessionIDs"],
            "additionalProperties": false
        ]
    }

    private func liveRewriteCreateInputSchema() -> [String: Any] {
        let properties: [String: Any] = [
            "method": ["type": "string"],
            "scheme": ["type": "string", "enum": ["http", "https"]],
            "host": ["type": "string"],
            "path": ["type": "string"],
            "matchMode": [
                "type": "string",
                "enum": ResponseOverrideMatchMode.allCases.map(\.rawValue)
            ],
            "port": ["type": "integer"],
            "label": ["type": "string"],
            "idempotencyKey": ["type": "string"],
            "previewDigest": [
                "type": "string",
                "description": "Current digest returned by preview_live_rewrite for this exact rule and capture sample."
            ],
            "jsonPath": ["type": "string"],
            "operation": [
                "type": "string",
                "enum": [
                    "set", "insert", "insertArrayElement", "appendString", "prependString",
                    "removeProperty", "removeIndex", "move"
                ]
            ],
            // Not universally required: `removeProperty`/`removeIndex` take no overrideValue and
            // reject one if supplied; `move` requires it as a whole-number destination index, not
            // arbitrary content (see `MCPMutationValidator`'s per-operation argument validation).
            "overrideValue": ["type": "object"],
            "repeatPolicy": ["type": "string", "enum": ["always", "ifMissingSuffix"]],
            "graphqlOperationName": [
                "type": "string",
                "description": "Optional GraphQL operation-name predicate: only match a POST whose JSON body's top-level operationName equals this value. Must match the value passed to the preceding preview_live_rewrite call, or the preview digest binding will be considered stale."
            ],
            "matchQueryKey": [
                "type": "string",
                "description": "Optional query-parameter predicate (paired with matchQueryValue): only match a request whose query string contains this exact key=value pair. Must match the values passed to the preceding preview_live_rewrite call, or the preview digest binding will be considered stale."
            ],
            "matchQueryValue": ["type": "string"]
        ]
        return [
            "type": "object",
            "properties": properties,
            "required": ["method", "host", "path", "jsonPath", "previewDigest"],
            "additionalProperties": false
        ]
    }

    private func collectionMockPreviewInputSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "sessionID": opaqueUUIDSchema(description: "Captured session whose retained response body is compiled against."),
                "draftJSON": [
                    "type": "string",
                    "description": "JSON text of a CollectionMockDraft object: collectionPointer, item (or templateIndex), identityPointers, countPointers, position (append/prepend). At most \(CollectionMockDraftDecoder.maximumInputBytes) UTF-8 bytes."
                ]
            ],
            "required": ["sessionID", "draftJSON"],
            "additionalProperties": false
        ]
    }

    private func collectionMockCreateInputSchema() -> [String: Any] {
        let properties: [String: Any] = [
            "method": ["type": "string"],
            "scheme": ["type": "string", "enum": ["http", "https"]],
            "host": ["type": "string"],
            "path": ["type": "string"],
            "matchMode": [
                "type": "string",
                "enum": ResponseOverrideMatchMode.allCases.map(\.rawValue)
            ],
            "port": ["type": "integer"],
            "label": ["type": "string"],
            "idempotencyKey": ["type": "string"],
            "revisionID": [
                "type": "string",
                "description": "Revision ID returned by preview_collection_mock for this exact compiled plan."
            ],
            "graphqlOperationName": ["type": "string"],
            "matchQueryKey": ["type": "string"],
            "matchQueryValue": ["type": "string"]
        ]
        return [
            "type": "object",
            "properties": properties,
            "required": ["method", "host", "path", "revisionID"],
            "additionalProperties": false
        ]
    }

    private func mutationApplyInputSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "proposalToken": ["type": "string"],
                "idempotencyKey": ["type": "string"],
                "approval": [
                    "type": "object",
                    "description": "One-use authorization returned after in-app approval."
                ]
            ],
            "required": ["proposalToken"],
            "additionalProperties": false
        ]
    }

    /// Apply schema for `apply_create_map_local`, including optional create+enable bundling.
    private func mapLocalApplyInputSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "proposalToken": ["type": "string"],
                "idempotencyKey": ["type": "string"],
                "enableAfterApply": [
                    "type": "boolean",
                    "description": "When true, create the rule and enable it under one `.enableRule` approval. Fail-closed if enable is denied."
                ],
                "acceptConfounder": [
                    "type": "boolean",
                    "description": "Required with enableAfterApply when enabling would confound a clean measurement."
                ],
                "approval": [
                    "type": "object",
                    "description": "One-use authorization returned after in-app approval."
                ]
            ],
            "required": ["proposalToken"],
            "additionalProperties": false
        ]
    }

    private func toolStructuredResult(id: Any?, payload: [String: Any]) -> [String: Any] {
        let textData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let text: String
        if let textData, textData.count <= 768 {
            text = String(data: textData, encoding: .utf8) ?? "{}"
        } else {
            let summary = compactToolTextSummary(payload)
            let summaryData = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            text = summaryData.flatMap { String(data: $0, encoding: .utf8) } ?? """
            {"structuredContentAvailable":true}
            """
        }
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "structuredContent": payload,
                "content": [[
                    "type": "text",
                    "text": text
                ]]
            ]
        ]
    }

    private func structuredOnlyToolResponse(_ response: [String: Any]) -> [String: Any] {
        guard var result = response["result"] as? [String: Any],
              result["structuredContent"] != nil else {
            return response
        }
        // MCP CallToolResult requires `content`; negotiated clients receive a conforming empty
        // array instead of duplicated textual JSON while `structuredContent` remains authoritative.
        result["content"] = [] as [[String: Any]]
        var compact = response
        compact["result"] = result
        return compact
    }

    private func compactToolTextSummary(_ payload: [String: Any]) -> [String: Any] {
        var summary: [String: Any] = ["structuredContentAvailable": true]
        for key in [
            "status", "state", "operationID", "scenarioID", "proposalToken",
            "captureEpoch", "policyRevision", "hasMore", "truncated", "unchanged",
            "isClean", "recommendedAction", "resultAvailable", "retryAfterMs",
            "latestSequence", "projection", "stateToken"
        ] {
            if let value = payload[key], value is String || value is NSNumber {
                summary[key] = value
            }
        }
        if let items = payload["items"] as? [[String: Any]] {
            summary["itemCount"] = items.count
            summary["itemIDs"] = Array(items.compactMap { ($0["id"] ?? $0["sessionID"]) as? String }.prefix(20))
        }
        if let payloadEnvelope = payload["payload"] as? [String: Any] {
            summary["payload"] = compactToolTextSummary(payloadEnvelope)
        }
        return summary
    }

    /// Rejects requests whose `Origin` doesn't match this loopback endpoint. A missing Origin is
    /// allowed (non-browser clients rarely send one); a present-but-wrong Origin is rejected.
    private func validateOrigin(_ headers: [String: String]) -> MCPHTTPResponse? {
        guard let origin = headers["origin"], !origin.isEmpty else {
            return nil
        }
        guard let components = URLComponents(string: origin),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              ["127.0.0.1", "localhost"].contains(host),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.port == Int(boundPort) else {
            return MCPHTTPResponse.response(status: 403, headers: [:], body: Data("Forbidden".utf8))
        }
        return nil
    }

    /// Rejects requests whose `Host` header doesn't match this loopback endpoint — the primary
    /// DNS-rebinding protection: a public domain that resolves to 127.0.0.1 still sends its own
    /// Host value, which this check catches even though the underlying connection is local.
    private func validateHost(_ headers: [String: String]) -> MCPHTTPResponse? {
        guard let hostHeader = headers["host"],
              let components = URLComponents(string: "http://\(hostHeader)"),
              let host = components.host?.lowercased(),
              ["127.0.0.1", "localhost"].contains(host),
              components.port == Int(boundPort) else {
            return MCPHTTPResponse.response(status: 403, headers: [:], body: Data("Forbidden".utf8))
        }
        return nil
    }

    private func encodeCursor(_ cursor: MCPSessionQueryCursor) throws -> String {
        let token = cursor.token
        sessionCursors[token] = cursor
        sessionCursorOrder.removeAll { $0 == token }
        sessionCursorOrder.append(token)
        while sessionCursorOrder.count > 512 {
            sessionCursors.removeValue(forKey: sessionCursorOrder.removeFirst())
        }
        return token
    }

    private func decodeCursor(_ value: Any?) throws -> MCPSessionQueryCursor? {
        guard let value else { return nil }
        guard let token = value as? String,
              let cursor = sessionCursors[token] else {
            throw MCPStructuredError.malformedRequest(message: "cursor must be an opaque cursor returned by JoesProxy.")
        }
        return cursor
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPPolicyStoreError.corruptPersistence
        }
        return object
    }

    private func recordAuthFailure(fingerprint: String?, reason: String) {
        MCPLog.auth.notice("Authentication failed: \(reason, privacy: .public).")
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .authenticationFailure,
                timestamp: Date(),
                clientID: nil,
                credentialFingerprint: fingerprint,
                sourceProcess: nil,
                reasonCode: reason,
                detail: nil
            )
        )
    }

    private func unauthorizedResponse() -> MCPHTTPResponse {
        MCPHTTPResponse.response(status: 401, headers: [:], body: Data("Unauthorized".utf8))
    }

    private func rateLimitedResponse() -> MCPHTTPResponse {
        MCPHTTPResponse.response(status: 429, headers: [:], body: Data("Rate limited".utf8))
    }

    private func busyResponse() -> MCPHTTPResponse {
        MCPHTTPResponse.response(
            status: 429,
            headers: ["Content-Type": "application/json"],
            body: (try? JSONEncoder().encode(MCPStructuredError(code: .busy, message: "Too many in-flight MCP requests for this client."))) ?? Data("Busy".utf8)
        )
    }

    private func policyDeniedResponse(message: String) -> MCPHTTPResponse {
        MCPHTTPResponse.response(
            status: 403,
            headers: ["Content-Type": "application/json"],
            body: (try? JSONEncoder().encode(MCPStructuredError(code: .policyDenied, message: message))) ?? Data()
        )
    }

    private func policyDeniedJSONRPC(id: Any?, error: MCPPolicyStoreError) -> [String: Any] {
        MCPHTTPResponse.jsonRPCObject(id: id, error: (-32002, "Policy denied: \(error)"))
    }

    private func structuredErrorJSONRPC(id: Any?, error: MCPStructuredError) -> [String: Any] {
        var data: [String: Any] = [
            "mcpCode": error.code.rawValue,
            "message": error.message
        ]
        if let details = error.details {
            data["details"] = details
        }
        if let policyRevision = error.policyRevision {
            data["policyRevision"] = policyRevision.rawValue
        }
        if let targetRevision = error.targetRevision {
            data["targetRevision"] = targetRevision.rawValue
        }
        if error.code == .approvalRequired, let requestID = error.details?["requestID"] {
            data["requestID"] = requestID
        }
        return MCPHTTPResponse.jsonRPCObject(
            id: id,
            error: (-32002, error.message),
            data: data
        )
    }
}
