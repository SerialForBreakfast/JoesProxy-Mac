import Combine
import XCTest
@testable import JoesProxy

final class MCPDiagnosticRelevanceMatrixTests: XCTestCase {
    func testWaterfallRelevanceIncludesThrottleAndResponseOverride() {
        XCTAssertTrue(MCPDiagnosticRelevanceMatrix.isRelevant(effectKind: .throttle, to: .waterfallLatencyTimeline))
        XCTAssertTrue(MCPDiagnosticRelevanceMatrix.isRelevant(effectKind: .responseOverride, to: .waterfallLatencyTimeline))
        XCTAssertFalse(MCPDiagnosticRelevanceMatrix.isRelevant(effectKind: .block, to: .waterfallLatencyTimeline))
    }

    func testHostHealthRelevanceIncludesBlockAndMapRemote() {
        XCTAssertTrue(MCPDiagnosticRelevanceMatrix.isRelevant(effectKind: .block, to: .hostHealthErrorSummary))
        XCTAssertTrue(MCPDiagnosticRelevanceMatrix.isRelevant(effectKind: .mapRemote, to: .hostHealthErrorSummary))
    }

    func testResponseComparisonRelevanceIncludesRewriteKinds() {
        XCTAssertTrue(MCPDiagnosticRelevanceMatrix.isRelevant(effectKind: .mapLocal, to: .responseComparison))
        XCTAssertTrue(MCPDiagnosticRelevanceMatrix.isRelevant(effectKind: .bookmarkRewrite, to: .responseComparison))
    }

    func testExportTypeMapsToDiagnosticKind() {
        XCTAssertEqual(
            MCPDiagnosticRelevanceMatrix.diagnosticKind(for: .requestWaterfall),
            .waterfallLatencyTimeline
        )
        XCTAssertEqual(
            MCPDiagnosticRelevanceMatrix.diagnosticKind(for: .hostHealthSummary),
            .hostHealthErrorSummary
        )
    }
}

@MainActor
final class MCPDiagnosticInterlockTests: XCTestCase {
    func testBeginCleanMeasurementSuspendsThrottleAndRestores() async throws {
        let configuration = InterlockTestConfiguration()
        let responseOverrideStore = ResponseOverrideStore()
        let bookmarkStore = InMemoryBookmarkStore()
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "interlock-journal.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let restorer = MCPRecoveryRestorer(
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            throttleConfigurationReader: { configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { configuration.networkThrottleConfiguration = $0 }
        )
        var throttle = NetworkThrottleConfiguration.defaults
        throttle.isEnabled = true
        throttle.mcpOrigin = .mcp
        throttle.mcpProvenance = MCPProvenance(
            clientID: "client-1",
            operationID: "op-1",
            capability: .changeThrottle,
            createdAt: Date()
        )
        configuration.networkThrottleConfiguration = throttle

        let recoveryService = MCPRecoveryService(
            recoveryCoordinator: recoveryCoordinator,
            journalStore: journalStore,
            restorer: restorer,
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            throttleConfigurationReader: { configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { configuration.networkThrottleConfiguration = $0 },
            approvalStore: MCPApprovalStore(),
            proposalCoordinator: MCPProposalCoordinator(
                recoveryCoordinator: recoveryCoordinator,
                policyRevisionProvider: { .initial }
            ),
            auditStore: MCPAuditStore()
        )
        let scenarioStore = MCPScenarioStore(persistenceURL: temporaryURL(named: "interlock-scenarios.json"))
        let lifecycle = MCPScenarioLifecycleCoordinator(store: scenarioStore)
        lifecycle.bootstrap()
        let coordinator = MCPDiagnosticInterlockCoordinator(
            recoveryService: recoveryService,
            restorer: restorer,
            scenarioLifecycleCoordinator: lifecycle,
            finishScenario: { _, _ in }
        )

        let evaluation = await coordinator.evaluate(diagnostic: MCPDiagnosticKind.waterfallLatencyTimeline)
        XCTAssertTrue(evaluation.requiresWarning)

        let begin = await coordinator.beginCleanMeasurement(for: MCPDiagnosticKind.waterfallLatencyTimeline)
        XCTAssertEqual(begin, MCPDiagnosticMeasurementBeginResult.started)
        XCTAssertTrue(MCPMeasurementSuspensionGate.isActive)
        XCTAssertFalse(configuration.networkThrottleConfiguration.isEnabled)

        await coordinator.endCleanMeasurement()
        XCTAssertFalse(MCPMeasurementSuspensionGate.isActive)
        XCTAssertTrue(configuration.networkThrottleConfiguration.isEnabled)
    }

    func testMeasurementSuspensionStampsAttributionOnResponses() {
        MCPMeasurementSuspensionGate.deactivate()
        defer { MCPMeasurementSuspensionGate.deactivate() }

        let response = CapturedResponse(
            statusCode: 200,
            headers: [],
            bodyData: Data(),
            bodySize: 0
        )
        MCPMeasurementSuspensionGate.activate(diagnosticLabel: "test")
        let stamped = MCPSessionAttributionService.measurementSuspensionAttributionIfNeeded(on: response)
        XCTAssertEqual(stamped.mcpAttribution?.measurementContext, .effectsSuspended)
    }

    func testAttributionSurvivesRecordingRoundTrip() throws {
        MCPMeasurementSuspensionGate.activate(diagnosticLabel: "test")
        defer { MCPMeasurementSuspensionGate.deactivate() }

        let response = CapturedResponse(
            statusCode: 200,
            headers: [],
            bodyData: Data("ok".utf8),
            bodySize: 3
        )
        let stamped = MCPSessionAttributionService.measurementSuspensionAttributionIfNeeded(on: response)
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .http,
                host: "127.0.0.1",
                port: 80,
                path: "/",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: stamped,
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
        let payload = try MCPRecordingAttributionSupport.wrappedRecordingPayload([session])
        let unwrapped = try MCPRecordingAttributionSupport.unwrappedRecordingPayload(payload)
        let decoded = try MCPRecordingAttributionSupport.decodeSessions(from: unwrapped)
        XCTAssertEqual(decoded.first?.response?.mcpAttribution?.measurementContext, .effectsSuspended)
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }
}

@MainActor
private final class InterlockTestConfiguration: AppConfiguration {
    var proxyPort: UInt16 = NetworkConstants.defaultPort { didSet { didChangeSubject.send(()) } }
    var logLevel: AppLogLevel = .info { didSet { didChangeSubject.send(()) } }
    var verboseHTTPSLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var isFindDebugLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var appTextSizeRawValue = AppTextSize.standard.rawValue { didSet { didChangeSubject.send(()) } }
    var isInspectorCopyRedactionEnabled = true { didSet { didChangeSubject.send(()) } }
    var sessionSortFieldRawValue = ProxyViewModel.SessionSortField.startedAt.rawValue { didSet { didChangeSubject.send(()) } }
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
    let certificateLabel = "test"
    private let didChangeSubject = PassthroughSubject<Void, Never>()
    var didChangePublisher: AnyPublisher<Void, Never> { didChangeSubject.eraseToAnyPublisher() }
    func resetToDefaults() {}
}
