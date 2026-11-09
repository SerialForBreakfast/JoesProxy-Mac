import Combine
import XCTest
@testable import JoesProxy

@MainActor
final class MCPScenarioExecutorTests: XCTestCase {
    private final class ActivationContext {
        var scenarioID: MCPScenarioID?
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func makeRuntimeStack(persistenceURL: URL? = nil) -> (
        MCPScenarioRuntimeService,
        MCPScenarioStore,
        MCPScenarioLifecycleCoordinator,
        ResponseOverrideStore
    ) {
        let store = MCPScenarioStore(persistenceURL: persistenceURL ?? temporaryURL(named: "scenario-executor.json"))
        store.load()
        let lifecycle = MCPScenarioLifecycleCoordinator(store: store)
        let journalStore = MCPEffectJournalStore()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let responseOverrideStore = ResponseOverrideStore()
        let bookmarkStore = InMemoryBookmarkStore()
        var configuration = ScenarioExecutorTestConfiguration()
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
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let policyStore = MCPPolicyStore()
        policyStore.load()
        let runtime = MCPScenarioRuntimeService(
            lifecycleCoordinator: lifecycle,
            scenarioStore: store,
            recoveryCoordinator: recoveryCoordinator,
            faultApplicator: applicator,
            observationService: MCPScenarioObservationService(
                sessionStore: sessionStore,
                snapshotService: snapshotService,
                policyStore: policyStore,
                scenarioStore: store,
                lifecycleCoordinator: lifecycle
            )
        )
        return (runtime, store, lifecycle, responseOverrideStore)
    }

    private func makeDraft(clientID: String = "client-1") -> MCPScenarioDraftInput {
        let matcher = MCPMutationMatcher(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: nil,
            path: "/blocked",
            matchMode: .exactPath
        )
        return MCPScenarioDraftInput(
            id: MCPScenarioID(rawValue: UUID().uuidString),
            schemaVersion: MCPScenarioSchemaVersion.current,
            name: "Block scenario",
            purpose: "Verify executor wiring.",
            originatingClientID: clientID,
            target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: ["api.example.com"], paths: nil),
            preconditions: [],
            captureScope: MCPScenarioCaptureScope(hosts: ["api.example.com"], includeBodies: false),
            disclosureProfileID: .shareable,
            faults: [.block(matcher: matcher, statusCode: 503)],
            duration: 30,
            expiresAt: nil,
            observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 30),
            assertions: [],
            assertionSeverity: .warning,
            evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 50, retention: 86_400),
            cleanupActions: [MCPScenarioCleanupAction(faultIndex: 0, kind: .block)]
        )
    }

    func testActivateScenarioCreatesEnabledBlockRule() async throws {
        let (runtime, store, lifecycle, responseOverrideStore) = makeRuntimeStack()
        let draft = makeDraft()
        _ = try lifecycle.createDraft(from: draft)
        _ = try lifecycle.validate(scenarioID: draft.id)
        _ = try lifecycle.approve(scenarioID: draft.id)

        try await runtime.activateScenario(draft.id)

        let record = store.scenario(id: draft.id)
        XCTAssertEqual(record?.phase, .observing)
        XCTAssertEqual(record?.appliedFaultReceipts.count, 1)

        let rules = await responseOverrideStore.rules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertTrue(rules[0].isEnabled)
        XCTAssertEqual(rules[0].sourceKind, .block)
    }

    // T3: proves a scenario's block fault carries `dropConnection` all the way through
    // MCPScenarioCompiler → MCPScenarioAppliedFaultReceipt into the real ResponseOverrideRule that
    // ConnectionHandler evaluates — the scenario JSON path for the reference-scenario capability.
    func testActivateScenarioWithDropConnectionCreatesRuleWithDropConnectionFlag() async throws {
        let (runtime, store, lifecycle, responseOverrideStore) = makeRuntimeStack()
        var draft = makeDraft()
        let matcher = MCPMutationMatcher(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: nil,
            path: "/blocked",
            matchMode: .exactPath
        )
        draft.faults = [.block(matcher: matcher, statusCode: 503, dropConnection: true)]
        _ = try lifecycle.createDraft(from: draft)
        _ = try lifecycle.validate(scenarioID: draft.id)
        _ = try lifecycle.approve(scenarioID: draft.id)

        try await runtime.activateScenario(draft.id)

        let record = store.scenario(id: draft.id)
        XCTAssertEqual(record?.phase, .observing)

        let rules = await responseOverrideStore.rules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertTrue(rules[0].isEnabled)
        XCTAssertEqual(rules[0].sourceKind, .block)
        XCTAssertTrue(rules[0].dropConnection)
    }

    /// Regression test for a confirmed HIGH data-loss bug: `activate()` used to transition the
    /// scenario to `.observing` (a durable, persisted write) and only THEN return receipts for the
    /// caller to persist in a second, later write. A crash between those two writes left the
    /// on-disk record showing `.observing` (faults live) with `appliedFaultReceipts == []` — on
    /// restart, cleanup would find no receipts to revert and silently orphan the real applied
    /// effect forever. Proves receipts are durable (visible to a freshly-loaded store reading the
    /// same file) by the time `activateScenario` returns — not just held in the in-memory record
    /// this test process happens to still have open.
    func testAppliedFaultReceiptsAreDurableBeforeActivateReturns() async throws {
        let sharedURL = temporaryURL(named: "scenario-executor-durability.json")
        let (runtime, _, lifecycle, _) = makeRuntimeStack(persistenceURL: sharedURL)
        let draft = makeDraft()
        _ = try lifecycle.createDraft(from: draft)
        _ = try lifecycle.validate(scenarioID: draft.id)
        _ = try lifecycle.approve(scenarioID: draft.id)

        try await runtime.activateScenario(draft.id)

        // A brand-new store instance reading the SAME file — simulates what a relaunch after a
        // crash would see, independent of this process's in-memory state.
        let reloadedStore = MCPScenarioStore(persistenceURL: sharedURL)
        reloadedStore.load()
        let reloadedRecord = reloadedStore.scenario(id: draft.id)
        XCTAssertEqual(reloadedRecord?.phase, .observing)
        XCTAssertEqual(
            reloadedRecord?.appliedFaultReceipts.count,
            1,
            "Applied-fault receipts must already be on disk by the time activation returns, not written in a later, separate step."
        )
    }

    func testFinishScenarioRemovesAppliedBlockRule() async throws {
        let (runtime, store, lifecycle, responseOverrideStore) = makeRuntimeStack()
        let draft = makeDraft()
        _ = try lifecycle.createDraft(from: draft)
        _ = try lifecycle.validate(scenarioID: draft.id)
        _ = try lifecycle.approve(scenarioID: draft.id)
        try await runtime.activateScenario(draft.id)

        await runtime.finishScenario(draft.id, outcome: .completed)

        let record = store.scenario(id: draft.id)
        XCTAssertEqual(record?.phase, .completed)
        let rules = await responseOverrideStore.rules()
        XCTAssertTrue(rules.isEmpty)
    }

    func testValidateRejectsJsonRewriteFaultAsUnsupportedInScenarioComposition() async throws {
        let (_, _, lifecycle, _) = makeRuntimeStack()
        let matcher = MCPMutationMatcher(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: nil,
            path: "/live",
            matchMode: .exactPath
        )
        let draft = MCPScenarioDraftInput(
            id: MCPScenarioID(rawValue: UUID().uuidString),
            schemaVersion: MCPScenarioSchemaVersion.current,
            name: "Live rewrite scenario",
            purpose: "Verify jsonRewrite faults are rejected at validation time.",
            originatingClientID: "client-1",
            target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: ["api.example.com"], paths: nil),
            preconditions: [],
            captureScope: MCPScenarioCaptureScope(hosts: ["api.example.com"], includeBodies: false),
            disclosureProfileID: .shareable,
            faults: [
                .jsonRewrite(
                    matcher: matcher,
                    jsonPath: "$.flag",
                    overrideValue: .bool(true),
                    operation: .set
                )
            ],
            duration: 30,
            expiresAt: nil,
            observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 30),
            assertions: [],
            assertionSeverity: .warning,
            evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 50, retention: 86_400),
            cleanupActions: [MCPScenarioCleanupAction(faultIndex: 0, kind: .liveResponseRewrite)]
        )
        _ = try lifecycle.createDraft(from: draft)

        XCTAssertThrowsError(try lifecycle.validate(scenarioID: draft.id)) { error in
            guard case MCPScenarioCompilerError.unsupportedFaultCombination = error else {
                return XCTFail("Expected unsupportedFaultCombination, got \(error)")
            }
        }
    }

    func testFaultApplicatorApplyJsonRewriteCreatesEnabledLiveResponseRewriteRule() async throws {
        let responseOverrideStore = ResponseOverrideStore()
        let bookmarkStore = InMemoryBookmarkStore()
        var configuration = ScenarioExecutorTestConfiguration()
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
        let matcher = MCPMutationMatcher(
            method: "GET",
            scheme: .http,
            host: "127.0.0.1",
            port: 8080,
            path: "/live-rewrite-target",
            matchMode: .exactPath
        )
        do {
            _ = try await applicator.apply(
                fault: .jsonRewrite(
                    matcher: matcher,
                    jsonPath: "$.flag",
                    overrideValue: .bool(true),
                    operation: .set
                ),
                faultIndex: 0,
                clientID: "client-1",
                scenarioID: MCPScenarioID(rawValue: UUID().uuidString)
            )
            XCTFail("Expected jsonRewrite fault application to be rejected as unsupported.")
        } catch MCPScenarioFaultApplicatorError.unsupportedFault {
            // Expected: jsonRewrite scenario composition is deferred until a staged rule pipeline exists.
        }
        let rules = await responseOverrideStore.rules()
        XCTAssertTrue(rules.isEmpty)
    }

    func testActivationFailureRollsBackPartialFaultSet() async throws {
        let store = MCPScenarioStore(persistenceURL: temporaryURL(named: "scenario-executor-rollback.json"))
        store.load()
        let lifecycle = MCPScenarioLifecycleCoordinator(store: store)
        let journalStore = MCPEffectJournalStore()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let responseOverrideStore = ResponseOverrideStore()
        let bookmarkStore = InMemoryBookmarkStore()
        var configuration = ScenarioExecutorTestConfiguration()
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
        let context = ActivationContext()
        let executor = MCPScenarioExecutor(
            recoveryCoordinator: recoveryCoordinator,
            lifecycleCoordinator: lifecycle,
            applyFault: { fault, index, clientID in
                guard index == 0 else {
                    throw MCPStructuredError(code: .conflict, message: "Second fault forced failure.")
                }
                guard let scenarioID = context.scenarioID else {
                    throw MCPStructuredError(code: .internalFailure, message: "Missing scenario context.")
                }
                return try await applicator.apply(
                    fault: fault,
                    faultIndex: index,
                    clientID: clientID,
                    scenarioID: scenarioID
                )
            },
            rollbackFault: { fault, receipt in
                try await applicator.rollback(fault: fault, receipt: receipt)
            }
        )

        var draft = makeDraft()
        let matcherOne = MCPMutationMatcher(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: nil,
            path: "/one",
            matchMode: .exactPath
        )
        let matcherTwo = MCPMutationMatcher(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: nil,
            path: "/two",
            matchMode: .exactPath
        )
        draft.faults = [
            .block(matcher: matcherOne, statusCode: 500),
            .block(matcher: matcherTwo, statusCode: 501)
        ]
        draft.cleanupActions = [
            MCPScenarioCleanupAction(faultIndex: 0, kind: .block),
            MCPScenarioCleanupAction(faultIndex: 1, kind: .block)
        ]
        let definition = try MCPScenarioCompiler.compile(draft: draft)
        _ = try store.createScenario(definition)
        for phase: MCPScenarioPhase in [.validating, .awaitingApproval, .armed] {
            try lifecycle.transition(draft.id, to: phase)
        }

        context.scenarioID = draft.id
        do {
            _ = try await executor.activate(
                scenarioID: draft.id,
                definition: definition,
                clientID: draft.originatingClientID
            )
            XCTFail("Expected activation failure.")
        } catch {
            // expected
        }

        let record = store.scenario(id: draft.id)
        XCTAssertEqual(record?.phase, .failed)
        let rules = await responseOverrideStore.rules()
        XCTAssertTrue(rules.isEmpty, "Partial activation must roll back applied faults.")
    }
}

@MainActor
private final class ScenarioExecutorTestConfiguration: AppConfiguration {
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
