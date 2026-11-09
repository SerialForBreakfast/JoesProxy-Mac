import XCTest
@testable import JoesProxy

@MainActor
final class MCPScenarioStoreTests: XCTestCase {
    private func makeDefinition(phase: MCPScenarioPhase = .draft) -> MCPScenarioDefinition {
        let matcher = MCPMutationMatcher(method: "GET", scheme: .https, host: "api.example.com", port: nil, path: "/v1", matchMode: .exactPath)
        return MCPScenarioDefinition(
            id: MCPScenarioID(rawValue: UUID().uuidString),
            schemaVersion: MCPScenarioSchemaVersion.current,
            name: "Test",
            purpose: "Test",
            originatingClientID: "client-1",
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

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    func testCreateAndPersistRoundTrip() throws {
        let url = temporaryURL(named: "scenario-store.json")
        let store = MCPScenarioStore(persistenceURL: url)
        store.load()
        let definition = makeDefinition()
        try store.createScenario(definition)

        let reloaded = MCPScenarioStore(persistenceURL: url)
        reloaded.load()
        XCTAssertTrue(reloaded.isLoaded)
        XCTAssertEqual(reloaded.scenarios.first?.id, definition.id)
        XCTAssertEqual(reloaded.scenarios.first?.phase, .draft)
    }

    func testFailClosedOnSchemaVersionMismatch() throws {
        let url = temporaryURL(named: "scenario-store-bad-version.json")
        let badState = MCPScenarioStore.PersistedState(schemaVersion: 999, scenarios: [])
        let data = try JSONEncoder().encode(badState)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let store = MCPScenarioStore(persistenceURL: url)
        store.load()
        XCTAssertFalse(store.isLoaded)
        XCTAssertNotNil(store.loadFailureReason)
    }

    func testPruneRetiresOldestTerminalScenariosPastCap() throws {
        let url = temporaryURL(named: "scenario-store-retention.json")
        let store = MCPScenarioStore(persistenceURL: url)
        store.load()

        for _ in 0..<(MCPScenarioStore.maxTerminalScenarios + 10) {
            let definition = makeDefinition()
            var record = try store.createScenario(definition)
            record.phase = .completed
            try store.updateScenario(record)
        }

        XCTAssertLessThanOrEqual(store.scenarios.count, MCPScenarioStore.maxTerminalScenarios)
    }

    func testCleanupRequiredScenariosAreNeverPruned() throws {
        let url = temporaryURL(named: "scenario-store-cleanup-required.json")
        let store = MCPScenarioStore(persistenceURL: url)
        store.load()

        let stuckDefinition = makeDefinition()
        var stuckRecord = try store.createScenario(stuckDefinition)
        stuckRecord.phase = .cleanupRequired
        stuckRecord.createdAt = Date().addingTimeInterval(-MCPScenarioStore.terminalScenarioRetention - 1)
        try store.updateScenario(stuckRecord)

        // Push well past the terminal cap with completed records to force pruning to run.
        for _ in 0..<(MCPScenarioStore.maxTerminalScenarios + 10) {
            let definition = makeDefinition()
            var record = try store.createScenario(definition)
            record.phase = .completed
            try store.updateScenario(record)
        }

        XCTAssertTrue(store.scenarios.contains { $0.id == stuckDefinition.id && $0.phase == .cleanupRequired })
    }

    func testUnresolvedScenariosExcludesTerminalPhases() throws {
        let url = temporaryURL(named: "scenario-store-unresolved.json")
        let store = MCPScenarioStore(persistenceURL: url)
        store.load()

        var running = try store.createScenario(makeDefinition())
        running.phase = .running
        try store.updateScenario(running)

        var completed = try store.createScenario(makeDefinition())
        completed.phase = .completed
        try store.updateScenario(completed)

        let unresolved = store.unresolvedScenarios()
        XCTAssertEqual(unresolved.count, 1)
        XCTAssertEqual(unresolved.first?.id, running.id)
    }

    func testConflictListCappedPerScenario() throws {
        let url = temporaryURL(named: "scenario-store-conflicts.json")
        let store = MCPScenarioStore(persistenceURL: url)
        store.load()

        var record = try store.createScenario(makeDefinition())
        record.conflicts = (0..<(MCPScenarioStore.maxConflictsPerScenario + 20)).map { index in
            MCPEffectConflictItem(id: "\(index)", kind: .block, message: "conflict \(index)", targetID: nil)
        }
        try store.updateScenario(record)

        let stored = store.scenario(id: record.id)
        XCTAssertEqual(stored?.conflicts.count, MCPScenarioStore.maxConflictsPerScenario)
    }
}
