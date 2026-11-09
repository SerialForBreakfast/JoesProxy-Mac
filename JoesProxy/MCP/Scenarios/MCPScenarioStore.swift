import Foundation

/// Durable scenario record — one per scenario, tracking its lifecycle phase and outcome (AI-1).
struct MCPScenarioRecord: Equatable, Sendable, Codable, Identifiable {
    var id: MCPScenarioID
    var definition: MCPScenarioDefinition
    var phase: MCPScenarioPhase
    /// Populated after a successful `validate` transition — drives approval UI and future
    /// `validate_test_scenario` responses without recompiling (AI-1).
    var validationResult: MCPScenarioValidationResultDTO?
    /// Populated after successful activation — drives cleanup of the exact inventory rows created
    /// during `activate` (AI-2).
    var appliedFaultReceipts: [MCPScenarioAppliedFaultReceipt]
    /// Bounded proxy observations collected during the observation window (AI-3).
    var observationEvidence: [MCPScenarioEvidenceRecord]
    /// Populated after `evaluateScenario` runs (AI-3).
    var assertionResults: [MCPScenarioAssertionResult]
    var evaluationReport: MCPScenarioReportDTO?
    /// Terminal phase `cleanup` should land in when `drainPendingCleanups` succeeds.
    var cleanupResolvedOutcome: MCPScenarioPhase?
    var approvedAt: Date?
    var armedAt: Date?
    var activatedAt: Date?
    var cleanupCompletedAt: Date?
    var lastError: String?
    /// Capped per-scenario conflict list accumulated across cleanup retries (invariant 7 — see
    /// `MCPScenarioStore.maxConflictsPerScenario`).
    var conflicts: [MCPEffectConflictItem]
    var createdAt: Date
    /// Set when the scenario was created on an isolated self-validation lane (AI-5).
    var validationRunID: MCPValidationRunID?
}

enum MCPScenarioStoreError: Error, Equatable, Sendable {
    case corruptPersistence
    case scenarioNotFound
}

/// JSON-backed durable repository for scenario records — mirrors `MCPEffectJournalStore`'s
/// persistence/retention shape exactly (@MainActor, schema-versioned, fail-closed on mismatch).
///
/// Concurrency: `@MainActor` because it is wired from `AppCoordinator` alongside the other MCP
/// recovery/journal stores.
@MainActor
final class MCPScenarioStore {
    static let persistenceFileName = "mcp-scenario-store.json"
    static let persistenceSchemaVersion = 1
    /// Bounds for terminal (`.completed`/`.failed`/`.inconclusive`/`.canceled`) records — the first
    /// limit reached wins. Smaller than `MCPEffectJournalStore`'s 1000 because a scenario record
    /// embeds a full fault list + conflict list and is heavier per-entry than a journal entry.
    /// `.cleanupRequired` is never pruned by this — it represents unresolved state a human must
    /// still resolve, mirroring the journal's `.conflict` exemption.
    static let terminalScenarioRetention: TimeInterval = 30 * 24 * 60 * 60
    static let maxTerminalScenarios = 200
    /// Invariant 7 — caps the per-scenario conflict list accumulated across repeated
    /// cleanupRequired -> cleaningUp retries. A scenario stuck past this many retries without
    /// resolution is itself a signal something is structurally wrong.
    static let maxConflictsPerScenario = 50

    struct PersistedState: Equatable, Sendable, Codable {
        var schemaVersion: Int
        var scenarios: [MCPScenarioRecord]
    }

    private(set) var scenarios: [MCPScenarioRecord] = []
    private(set) var isLoaded = false
    private(set) var loadFailureReason: String?

    private let persistenceURL: URL
    private let fileManager: FileManager

    init(
        persistenceURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
    }

    func load() {
        do {
            if fileManager.fileExists(atPath: persistenceURL.path) {
                let data = try Data(contentsOf: persistenceURL)
                let persisted = try JSONDecoder().decode(PersistedState.self, from: data)
                guard persisted.schemaVersion == Self.persistenceSchemaVersion else {
                    failClosed(reason: "Unsupported scenario store schema version.")
                    return
                }
                scenarios = persisted.scenarios
            } else {
                scenarios = []
            }
            pruneTerminalScenarios()
            isLoaded = true
            loadFailureReason = nil
        } catch {
            failClosed(reason: "Scenario store failed to load.")
        }
    }

    func persist() throws {
        let state = PersistedState(schemaVersion: Self.persistenceSchemaVersion, scenarios: scenarios)
        let data = try JSONEncoder().encode(state)
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: .atomic)
    }

    @discardableResult
    func createScenario(
        _ definition: MCPScenarioDefinition,
        validationRunID: MCPValidationRunID? = nil,
        now: Date = Date()
    ) throws -> MCPScenarioRecord {
        let record = MCPScenarioRecord(
            id: definition.id,
            definition: definition,
            phase: .draft,
            validationResult: nil,
            appliedFaultReceipts: [],
            observationEvidence: [],
            assertionResults: [],
            evaluationReport: nil,
            cleanupResolvedOutcome: nil,
            approvedAt: nil,
            armedAt: nil,
            activatedAt: nil,
            cleanupCompletedAt: nil,
            lastError: nil,
            conflicts: [],
            createdAt: now,
            validationRunID: validationRunID
        )
        scenarios.append(record)
        try persist()
        return record
    }

    func scenario(id: MCPScenarioID) -> MCPScenarioRecord? {
        scenarios.first { $0.id == id }
    }

    func updateScenario(_ record: MCPScenarioRecord) throws {
        guard let index = scenarios.firstIndex(where: { $0.id == record.id }) else {
            throw MCPScenarioStoreError.scenarioNotFound
        }
        var updated = record
        if updated.conflicts.count > Self.maxConflictsPerScenario {
            updated.conflicts = Array(updated.conflicts.suffix(Self.maxConflictsPerScenario))
        }
        scenarios[index] = updated
        pruneTerminalScenarios()
        try persist()
    }

    /// Non-terminal scenarios (everything except completed/failed/inconclusive/canceled) — used at
    /// launch to reconcile scenarios that were mid-flight when the process last exited.
    func unresolvedScenarios(now: Date = Date()) -> [MCPScenarioRecord] {
        scenarios.filter { !$0.phase.isPrunableTerminal }
    }

    private func pruneTerminalScenarios(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.terminalScenarioRetention)
        scenarios.removeAll { record in
            guard record.phase.isPrunableTerminal else { return false }
            return record.createdAt < cutoff
        }
        let terminalCount = scenarios.count { $0.phase.isPrunableTerminal }
        guard terminalCount > Self.maxTerminalScenarios else { return }
        let overflow = terminalCount - Self.maxTerminalScenarios
        let staleIDs = scenarios
            .filter { $0.phase.isPrunableTerminal }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(overflow)
            .map(\.id)
        scenarios.removeAll { staleIDs.contains($0.id) }
    }

    /// Clears scenario records for an isolated self-validation lane (AI-5).
    func resetForSelfValidation() {
        scenarios.removeAll()
        isLoaded = true
        loadFailureReason = nil
    }

    private func failClosed(reason: String) {
        scenarios = []
        isLoaded = false
        loadFailureReason = reason
    }

    private static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent(persistenceFileName)
    }
}
