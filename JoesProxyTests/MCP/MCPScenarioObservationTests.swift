import Combine
import XCTest
@testable import JoesProxy

@MainActor
final class MCPScenarioObservationTests: XCTestCase {
    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func makeStack(
        policyStore: MCPPolicyStore? = nil
    ) -> (
        MCPScenarioRuntimeService,
        MCPScenarioStore,
        MCPScenarioLifecycleCoordinator,
        InMemorySessionStore,
        MCPSessionSnapshotService,
        MCPPolicyStore
    ) {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let resolvedPolicyStore = policyStore ?? {
            let store = MCPPolicyStore()
            store.load()
            return store
        }()
        let scenarioStore = MCPScenarioStore(persistenceURL: temporaryURL(named: "scenario-observation.json"))
        scenarioStore.load()
        let lifecycle = MCPScenarioLifecycleCoordinator(store: scenarioStore)
        let journalStore = MCPEffectJournalStore()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let responseOverrideStore = ResponseOverrideStore()
        let bookmarkStore = InMemoryBookmarkStore()
        var configuration = ScenarioObservationTestConfiguration()
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
            restorer: restorer,
            throttleConfigurationReader: { configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                configuration.networkThrottleConfiguration = updated
            }
        )
        let observationService = MCPScenarioObservationService(
            sessionStore: sessionStore,
            snapshotService: snapshotService,
            policyStore: resolvedPolicyStore,
            scenarioStore: scenarioStore,
            lifecycleCoordinator: lifecycle
        )
        let runtime = MCPScenarioRuntimeService(
            lifecycleCoordinator: lifecycle,
            scenarioStore: scenarioStore,
            recoveryCoordinator: recoveryCoordinator,
            faultApplicator: applicator,
            observationService: observationService
        )
        return (runtime, scenarioStore, lifecycle, sessionStore, snapshotService, resolvedPolicyStore)
    }

    private func makeDraft(
        id: MCPScenarioID = MCPScenarioID(rawValue: UUID().uuidString),
        assertions: [MCPScenarioAssertion],
        assertionSeverity: MCPScenarioAssertionSeverity = .blocking,
        disclosureProfileID: MCPDisclosureProfileID = .shareable
    ) -> MCPScenarioDraftInput {
        let matcher = MCPMutationMatcher(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: nil,
            path: "/blocked",
            matchMode: .exactPath
        )
        return MCPScenarioDraftInput(
            id: id,
            schemaVersion: MCPScenarioSchemaVersion.current,
            name: "Observation scenario",
            purpose: "Verify AI-3 evaluation.",
            originatingClientID: "client-1",
            target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: ["api.example.com"], paths: nil),
            preconditions: [],
            captureScope: MCPScenarioCaptureScope(hosts: ["api.example.com"], includeBodies: false),
            disclosureProfileID: disclosureProfileID,
            faults: [.block(matcher: matcher, statusCode: 503)],
            duration: 30,
            expiresAt: nil,
            observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 300),
            assertions: assertions,
            assertionSeverity: assertionSeverity,
            evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 50, retention: 86_400),
            cleanupActions: [MCPScenarioCleanupAction(faultIndex: 0, kind: .block)]
        )
    }

    private func makeSession(
        host: String = "api.example.com",
        path: String = "/blocked",
        method: String = "GET",
        statusCode: Int = 503,
        startedAt: Date = Date()
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: method,
                scheme: .https,
                host: host,
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: statusCode,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            state: .completed,
            timing: SessionTiming(startedAt: startedAt, completedAt: startedAt.addingTimeInterval(0.2))
        )
    }

    func testEvaluateScenarioRequestOccurredPassesWhenMatchingTrafficExists() async throws {
        let (runtime, store, lifecycle, sessionStore, _, _) = makeStack()
        let assertion = MCPScenarioAssertion(
            kind: .requestOccurred,
            matcher: MCPMutationMatcher(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: nil,
                path: "/blocked",
                matchMode: .exactPath
            ),
            host: nil,
            path: nil,
            statusCode: nil,
            thresholdSeconds: nil,
            expectedCount: nil,
            markerName: nil,
            detail: nil,
            evidenceSource: .captured,
            notes: nil
        )
        let draft = makeDraft(assertions: [assertion])
        _ = try lifecycle.createDraft(from: draft)
        _ = try lifecycle.validate(scenarioID: draft.id)
        _ = try lifecycle.approve(scenarioID: draft.id)
        try await runtime.activateScenario(draft.id)

        sessionStore.append(makeSession())

        let evaluation = try runtime.evaluateScenario(draft.id)
        XCTAssertEqual(evaluation.assertionResults.count, 1)
        XCTAssertEqual(evaluation.assertionResults[0].outcome, .passed)
        XCTAssertEqual(evaluation.resolvedOutcome, .completed)
        XCTAssertEqual(store.scenario(id: draft.id)?.phase, .evaluating)
        XCTAssertEqual(store.scenario(id: draft.id)?.observationEvidence.count, 1)
    }

    func testEvaluateScenarioRequestOccurredFailsWhenTrafficMissing() async throws {
        let (runtime, _, lifecycle, _, _, _) = makeStack()
        let assertion = MCPScenarioAssertion(
            kind: .requestOccurred,
            matcher: MCPMutationMatcher(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: nil,
                path: "/blocked",
                matchMode: .exactPath
            ),
            host: nil,
            path: nil,
            statusCode: nil,
            thresholdSeconds: nil,
            expectedCount: nil,
            markerName: nil,
            detail: nil,
            evidenceSource: .captured,
            notes: nil
        )
        let draft = makeDraft(assertions: [assertion], assertionSeverity: .blocking)
        _ = try lifecycle.createDraft(from: draft)
        _ = try lifecycle.validate(scenarioID: draft.id)
        _ = try lifecycle.approve(scenarioID: draft.id)
        try await runtime.activateScenario(draft.id)

        let evaluation = try runtime.evaluateScenario(draft.id)
        XCTAssertEqual(evaluation.assertionResults[0].outcome, .failed)
        XCTAssertEqual(evaluation.resolvedOutcome, .failed)
    }

    func testSDKAssertionEvaluatesAsInconclusive() async throws {
        let (runtime, _, lifecycle, _, _, _) = makeStack()
        let assertion = MCPScenarioAssertion(
            kind: .sdkPlaybackState,
            matcher: nil,
            host: nil,
            path: nil,
            statusCode: nil,
            thresholdSeconds: nil,
            expectedCount: nil,
            markerName: nil,
            detail: "Expect buffering",
            evidenceSource: .sdkReported,
            notes: nil
        )
        let draft = makeDraft(assertions: [assertion], assertionSeverity: .blocking)
        _ = try lifecycle.createDraft(from: draft)
        _ = try lifecycle.validate(scenarioID: draft.id)
        _ = try lifecycle.approve(scenarioID: draft.id)
        try await runtime.activateScenario(draft.id)

        let evaluation = try runtime.evaluateScenario(draft.id)
        XCTAssertEqual(evaluation.assertionResults[0].outcome, .inconclusive)
        XCTAssertEqual(evaluation.resolvedOutcome, .inconclusive)
    }

    func testFinishScenarioDerivesFailedOutcomeFromBlockingAssertion() async throws {
        let (runtime, store, lifecycle, _, _, _) = makeStack()
        let assertion = MCPScenarioAssertion(
            kind: .requestOccurred,
            matcher: MCPMutationMatcher(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: nil,
                path: "/blocked",
                matchMode: .exactPath
            ),
            host: nil,
            path: nil,
            statusCode: nil,
            thresholdSeconds: nil,
            expectedCount: nil,
            markerName: nil,
            detail: nil,
            evidenceSource: .captured,
            notes: nil
        )
        let draft = makeDraft(assertions: [assertion], assertionSeverity: .blocking)
        _ = try lifecycle.createDraft(from: draft)
        _ = try lifecycle.validate(scenarioID: draft.id)
        _ = try lifecycle.approve(scenarioID: draft.id)
        try await runtime.activateScenario(draft.id)

        await runtime.finishScenario(draft.id)

        XCTAssertEqual(store.scenario(id: draft.id)?.phase, .failed)
        XCTAssertEqual(store.scenario(id: draft.id)?.assertionResults.first?.outcome, .failed)
    }

    func testReportRedactsScenarioFieldsForMetadataOnlyProfile() async throws {
        let (runtime, _, lifecycle, sessionStore, _, _) = makeStack()
        let assertion = MCPScenarioAssertion(
            kind: .requestOccurred,
            matcher: MCPMutationMatcher(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: nil,
                path: "/blocked",
                matchMode: .exactPath
            ),
            host: nil,
            path: nil,
            statusCode: nil,
            thresholdSeconds: nil,
            expectedCount: nil,
            markerName: nil,
            detail: nil,
            evidenceSource: .captured,
            notes: nil
        )
        let draft = makeDraft(
            assertions: [assertion],
            disclosureProfileID: .metadataOnly
        )
        _ = try lifecycle.createDraft(from: draft)
        _ = try lifecycle.validate(scenarioID: draft.id)
        _ = try lifecycle.approve(scenarioID: draft.id)
        try await runtime.activateScenario(draft.id)
        sessionStore.append(makeSession())

        let evaluation = try runtime.evaluateScenario(draft.id)
        XCTAssertTrue(evaluation.report.redactionSummary.contains("scenarioEvidence"))
        XCTAssertTrue(evaluation.report.redactionSummary.contains("scenarioAssertionResults"))
        XCTAssertNil(evaluation.report.sessionSummaries)
        XCTAssertTrue(evaluation.report.assertionResults.isEmpty)
    }

    /// Regression test for a confirmed HIGH bug: assertion evaluation matched against the entire
    /// live session store with no time-window bound at all — only the separate evidence collector
    /// applied the observation window. A `requestOccurred` assertion would pass on traffic that hit
    /// the target host at any point before the scenario was even activated, violating the ADR's
    /// "deterministic time windows" requirement.
    func testEvaluateScenarioIgnoresTrafficBeforeActivation() async throws {
        let (runtime, _, lifecycle, sessionStore, _, _) = makeStack()
        let assertion = MCPScenarioAssertion(
            kind: .requestOccurred,
            matcher: MCPMutationMatcher(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: nil,
                path: "/blocked",
                matchMode: .exactPath
            ),
            host: nil,
            path: nil,
            statusCode: nil,
            thresholdSeconds: nil,
            expectedCount: nil,
            markerName: nil,
            detail: nil,
            evidenceSource: .captured,
            notes: nil
        )
        let draft = makeDraft(assertions: [assertion])

        // Matching traffic that occurred well before the scenario is ever activated — this must
        // NOT count toward "requestOccurred" once the scenario evaluates.
        sessionStore.append(makeSession(startedAt: Date().addingTimeInterval(-3_600)))

        _ = try lifecycle.createDraft(from: draft)
        _ = try lifecycle.validate(scenarioID: draft.id)
        _ = try lifecycle.approve(scenarioID: draft.id)
        try await runtime.activateScenario(draft.id)

        let evaluation = try runtime.evaluateScenario(draft.id)
        XCTAssertEqual(
            evaluation.assertionResults.first?.outcome,
            .failed,
            "A session from before scenario activation must not satisfy requestOccurred."
        )
    }

    /// Regression test for a confirmed MEDIUM bug: the collector capped evidence only against the
    /// global `MCPScenarioResourceBudget.maxEvidenceRecords` ceiling, ignoring the scenario's own
    /// declared `evidenceRetentionSpec.maxRecords` — a scenario that requested a tighter cap got up
    /// to the global maximum anyway.
    func testEvidenceCappedAtScenariosOwnRetentionSpecNotGlobalCeiling() async throws {
        let (runtime, _, lifecycle, sessionStore, _, _) = makeStack()
        let matcher = MCPMutationMatcher(
            method: "GET", scheme: .https, host: "api.example.com", port: nil, path: "/blocked", matchMode: .exactPath
        )
        let assertion = MCPScenarioAssertion(
            kind: .requestOccurred, matcher: matcher, host: nil, path: nil, statusCode: nil,
            thresholdSeconds: nil, expectedCount: nil, markerName: nil, detail: nil,
            evidenceSource: .captured, notes: nil
        )
        var draft = makeDraft(assertions: [assertion])
        draft.evidenceRetentionSpec = MCPScenarioEvidenceRetentionSpec(maxRecords: 3, retention: 86_400)

        _ = try lifecycle.createDraft(from: draft)
        _ = try lifecycle.validate(scenarioID: draft.id)
        _ = try lifecycle.approve(scenarioID: draft.id)
        try await runtime.activateScenario(draft.id)

        for _ in 0..<10 {
            sessionStore.append(makeSession())
        }

        let evaluation = try runtime.evaluateScenario(draft.id)
        XCTAssertEqual(evaluation.evidence.count, 3, "Evidence must respect the scenario's own tighter maxRecords, not the global ceiling.")
    }
}

private final class ScenarioObservationTestConfiguration: AppConfiguration {
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

    var didChangePublisher: AnyPublisher<Void, Never> {
        didChangeSubject.eraseToAnyPublisher()
    }

    func resetToDefaults() {}
}
