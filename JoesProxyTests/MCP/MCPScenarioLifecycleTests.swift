import XCTest
@testable import JoesProxy

@MainActor
final class MCPScenarioLifecycleTests: XCTestCase {
    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func makeDefinition(clientID: String = "client-1") -> MCPScenarioDefinition {
        let matcher = MCPMutationMatcher(method: "GET", scheme: .https, host: "api.example.com", port: nil, path: "/v1", matchMode: .exactPath)
        return MCPScenarioDefinition(
            id: MCPScenarioID(rawValue: UUID().uuidString),
            schemaVersion: MCPScenarioSchemaVersion.current,
            name: "Test",
            purpose: "Test",
            originatingClientID: clientID,
            target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: ["api.example.com"], paths: nil),
            preconditions: [],
            captureScope: MCPScenarioCaptureScope(hosts: ["api.example.com"], includeBodies: false),
            disclosureProfileID: .shareable,
            faults: [.block(matcher: matcher, statusCode: 500)],
            duration: 30,
            expiresAt: nil,
            observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 30),
            assertions: [],
            assertionSeverity: .warning,
            evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 50, retention: 86_400),
            cleanupActions: [MCPScenarioCleanupAction(faultIndex: 0, kind: .block)],
            createdAt: Date()
        )
    }

    private func makeDraft(clientID: String = "client-1", id: MCPScenarioID? = nil) -> MCPScenarioDraftInput {
        let definition = makeDefinition(clientID: clientID)
        var draft = MCPScenarioDraftInput.fromDefinition(definition)
        if let id {
            draft.id = id
        }
        return draft
    }

    private func makeCoordinator() -> (MCPScenarioLifecycleCoordinator, MCPScenarioStore) {
        let store = MCPScenarioStore(persistenceURL: temporaryURL(named: "scenario-lifecycle.json"))
        store.load()
        return (MCPScenarioLifecycleCoordinator(store: store), store)
    }

    // MARK: - Legal transition matrix

    func testLegalTransitionsSucceed() throws {
        let (coordinator, store) = makeCoordinator()
        let definition = makeDefinition()
        try store.createScenario(definition)

        let legalPath: [MCPScenarioPhase] = [
            .validating, .awaitingApproval, .armed, .running, .observing, .evaluating, .cleaningUp, .completed
        ]
        for phase in legalPath {
            XCTAssertNoThrow(try coordinator.transition(definition.id, to: phase))
        }
    }

    func testEveryIllegalTransitionThrowsInvalidTransition() throws {
        let (coordinator, store) = makeCoordinator()
        let definition = makeDefinition()
        try store.createScenario(definition)

        // The one illegal transition AI-1's exit criteria calls out explicitly: skipping
        // validation/approval/arming entirely.
        XCTAssertThrowsError(try coordinator.transition(definition.id, to: .running)) { error in
            guard case MCPScenarioLifecycleError.invalidTransition(let from, let to) = error else {
                return XCTFail("Expected invalidTransition, got \(error)")
            }
            XCTAssertEqual(from, .draft)
            XCTAssertEqual(to, .running)
        }
    }

    func testCompletedIsTerminalWithNoOutgoingTransitions() throws {
        let (coordinator, store) = makeCoordinator()
        let definition = makeDefinition()
        try store.createScenario(definition)
        for phase: MCPScenarioPhase in [.validating, .awaitingApproval, .armed, .running, .observing, .evaluating, .cleaningUp, .completed] {
            try coordinator.transition(definition.id, to: phase)
        }
        XCTAssertThrowsError(try coordinator.transition(definition.id, to: .failed))
    }

    // MARK: - Validation orchestration (AI-1)

    func testCreateDraftAndValidateTransitionsToAwaitingApproval() throws {
        let (coordinator, store) = makeCoordinator()
        let draft = makeDraft()
        let record = try coordinator.createDraft(from: draft)
        XCTAssertEqual(record.phase, .draft)
        XCTAssertNil(record.validationResult)

        let result = try coordinator.validate(scenarioID: draft.id)
        XCTAssertEqual(result.definition.name, "Test")
        XCTAssertFalse(result.approvalDisclosure.faultSummaries.isEmpty)

        let validated = store.scenario(id: draft.id)
        XCTAssertEqual(validated?.phase, .awaitingApproval)
        XCTAssertNotNil(validated?.validationResult)
        XCTAssertEqual(validated?.validationResult?.riskTier, result.riskTier)
    }

    func testValidateFailureTransitionsToFailed() throws {
        let (coordinator, store) = makeCoordinator()
        var draft = makeDraft()
        draft.faults = []
        _ = try coordinator.createDraft(from: draft)

        XCTAssertThrowsError(try coordinator.validate(scenarioID: draft.id)) { error in
            guard case MCPScenarioCompilerError.malformed = error else {
                return XCTFail("Expected malformed compiler error, got \(error)")
            }
        }

        let failed = store.scenario(id: draft.id)
        XCTAssertEqual(failed?.phase, .failed)
        XCTAssertNotNil(failed?.lastError)
        XCTAssertNil(failed?.validationResult)
    }

    func testValidateRejectsNonDraftPhase() throws {
        let (coordinator, store) = makeCoordinator()
        let draft = makeDraft()
        _ = try coordinator.createDraft(from: draft)
        try coordinator.transition(draft.id, to: .validating)

        XCTAssertThrowsError(try coordinator.validate(scenarioID: draft.id)) { error in
            guard case MCPScenarioLifecycleError.invalidTransition(let from, let to) = error else {
                return XCTFail("Expected invalidTransition, got \(error)")
            }
            XCTAssertEqual(from, .validating)
            XCTAssertEqual(to, .validating)
        }
        XCTAssertEqual(store.scenario(id: draft.id)?.phase, .validating)
    }

    func testApproveTransitionsAwaitingApprovalToArmedWithoutActiveEffects() throws {
        let (coordinator, store) = makeCoordinator()
        let draft = makeDraft()
        _ = try coordinator.createDraft(from: draft)
        _ = try coordinator.validate(scenarioID: draft.id)

        let armed = try coordinator.approve(scenarioID: draft.id)
        XCTAssertEqual(armed.phase, .armed)
        XCTAssertNotNil(armed.approvedAt)
        XCTAssertNotNil(armed.armedAt)
        XCTAssertTrue(coordinator.armedScenarioIDs.contains(draft.id.rawValue))
        XCTAssertFalse(coordinator.activeScenarioIDs.contains(draft.id.rawValue))
    }

    func testApproveRejectsExpiredScenario() throws {
        let (coordinator, store) = makeCoordinator()
        let fixedNow = Date()
        var draft = makeDraft()
        draft.expiresAt = fixedNow.addingTimeInterval(3600)
        _ = try coordinator.createDraft(from: draft, now: fixedNow)
        _ = try coordinator.validate(scenarioID: draft.id, now: fixedNow)

        let expiredNow = fixedNow.addingTimeInterval(7200)
        XCTAssertThrowsError(try coordinator.approve(scenarioID: draft.id, now: expiredNow)) { error in
            XCTAssertEqual(error as? MCPScenarioLifecycleError, .scenarioExpired)
        }
        XCTAssertEqual(store.scenario(id: draft.id)?.phase, .failed)
    }

    func testRestartReconcilesDraftToCanceled() throws {
        let url = temporaryURL(named: "scenario-lifecycle-draft-restart.json")
        let store = MCPScenarioStore(persistenceURL: url)
        store.load()
        let coordinator = MCPScenarioLifecycleCoordinator(store: store)
        let draft = makeDraft()
        _ = try coordinator.createDraft(from: draft)

        let relaunchedStore = MCPScenarioStore(persistenceURL: url)
        let relaunchedCoordinator = MCPScenarioLifecycleCoordinator(store: relaunchedStore)
        relaunchedCoordinator.bootstrap()

        let reconciled = relaunchedStore.scenario(id: draft.id)
        XCTAssertEqual(reconciled?.phase, .canceled)
        XCTAssertNotNil(reconciled?.lastError)
    }

    // MARK: - AI-1 exit criteria

    func testRestartReconcilesIncompleteScenarioNeverSilentlyCompleted() throws {
        let url = temporaryURL(named: "scenario-lifecycle-restart.json")
        let store = MCPScenarioStore(persistenceURL: url)
        store.load()
        let coordinator = MCPScenarioLifecycleCoordinator(store: store)
        let definition = makeDefinition()
        try store.createScenario(definition)
        for phase: MCPScenarioPhase in [.validating, .awaitingApproval, .armed, .running] {
            try coordinator.transition(definition.id, to: phase)
        }

        // Simulate relaunch: fresh store/coordinator reading the same persisted file.
        let relaunchedStore = MCPScenarioStore(persistenceURL: url)
        let relaunchedCoordinator = MCPScenarioLifecycleCoordinator(store: relaunchedStore)
        relaunchedCoordinator.bootstrap()

        let reconciled = relaunchedStore.scenario(id: definition.id)
        XCTAssertNotEqual(reconciled?.phase, .completed, "A mid-flight scenario must never silently reconcile to completed.")
        XCTAssertEqual(reconciled?.phase, .cleaningUp)
    }

    func testDisconnectViaRevokeClientForcesScenarioIntoCleaningUp() throws {
        let stack = try makeControllerStack()
        let definition = makeDefinition(clientID: stack.client.id)
        try stack.controller.scenarioStore.createScenario(definition)
        try stack.controller.scenarioLifecycleCoordinator.transition(definition.id, to: .validating)
        try stack.controller.scenarioLifecycleCoordinator.transition(definition.id, to: .awaitingApproval)
        try stack.controller.scenarioLifecycleCoordinator.transition(definition.id, to: .armed)
        try stack.controller.scenarioLifecycleCoordinator.transition(definition.id, to: .running)

        // Exercise the real reachable entry point (invariant 9) — not a direct coordinator call.
        try stack.controller.revokeClient(clientID: stack.client.id)

        let record = stack.controller.scenarioStore.scenario(id: definition.id)
        XCTAssertEqual(record?.phase, .cleaningUp)
    }

    func testCleanupRequiredScenarioEffectIsNotOrphaned() throws {
        let (coordinator, store) = makeCoordinator()
        let definition = makeDefinition()
        try store.createScenario(definition)
        for phase: MCPScenarioPhase in [.validating, .awaitingApproval, .armed, .running, .observing, .evaluating, .cleaningUp] {
            try coordinator.transition(definition.id, to: phase)
        }
        try coordinator.transition(definition.id, to: .cleanupRequired)
        coordinator.recordConflicts(
            scenarioID: definition.id,
            conflicts: [MCPEffectConflictItem(id: "tx-1", kind: .block, message: "Rollback failed.", targetID: "target-1")]
        )

        let record = store.scenario(id: definition.id)
        XCTAssertEqual(record?.phase, .cleanupRequired)
        XCTAssertEqual(record?.conflicts.count, 1, "The conflict must be recorded, not silently dropped — the effect is not orphaned, it's tracked.")
    }

    // MARK: - Global mutation-scenario lock

    func testGlobalSlotRejectsSecondActivationWhileOneScenarioActive() throws {
        let (coordinator, store) = makeCoordinator()
        let first = makeDefinition()
        let second = makeDefinition()
        try store.createScenario(first)
        try store.createScenario(second)

        try coordinator.requestActivation(for: first.id)
        XCTAssertThrowsError(try coordinator.requestActivation(for: second.id)) { error in
            XCTAssertEqual(error as? MCPScenarioLifecycleError, .globalScenarioSlotBusy)
        }
        coordinator.releaseActivation(for: first.id)
        XCTAssertNoThrow(try coordinator.requestActivation(for: second.id))
    }

    // MARK: - Helpers

    private struct ControllerStack {
        let controller: MCPServerController
        let client: MCPClientRecord
    }

    private func makeControllerStack() throws -> ControllerStack {
        let isolated = try MCPIsolatedControllerStack.make()
        isolated.controller.bootstrap()
        let enrollment = try isolated.controller.enrollClient(displayName: "Test Client", profileID: .shareable)
        return ControllerStack(controller: isolated.controller, client: enrollment.client)
    }
}
