import Foundation

/// Durable MCP effect transaction journal entry.
struct MCPEffectJournalEntry: Equatable, Sendable, Codable, Identifiable {
    enum Phase: String, Equatable, Sendable, Codable {
        case intent
        case committed
        case rolledBack
        case conflict
    }

    var id: UUID
    var transactionID: String
    var clientID: String
    var targetKind: MCPEffectKind
    var targetID: String
    var baselineRevision: MCPTargetRevision?
    var intendedChangeDigest: String
    var rollbackSnapshot: Data?
    var expiresAt: Date
    var phase: Phase
    var createdAt: Date
    var conflictMessage: String?
}

enum MCPEffectJournalStoreError: Error, Equatable, Sendable {
    case corruptPersistence
    case entryNotFound
    case invalidPhaseTransition
    case unresolvedEntriesRemain
}

/// JSON-backed durable journal for MCP mutation intent/commit lifecycle.
///
/// Concurrency: `@MainActor` because it is wired from ``AppCoordinator`` and ``MCPRecoveryCoordinator``.
@MainActor
final class MCPEffectJournalStore {
    static let persistenceFileName = "mcp-effect-journal.json"
    static let persistenceSchemaVersion = 1
    /// Bounds for terminal (`.committed`/`.rolledBack`) entries — the first limit reached wins.
    /// `.intent`/`.conflict` entries are never pruned by this; they stay until reconciled.
    static let terminalEntryRetention: TimeInterval = 30 * 24 * 60 * 60
    static let maxTerminalEntries = 1000

    struct PersistedState: Equatable, Sendable, Codable {
        var schemaVersion: Int
        var entries: [MCPEffectJournalEntry]
    }

    private(set) var entries: [MCPEffectJournalEntry] = []
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
                    failClosed(reason: "Unsupported effect journal schema version.")
                    return
                }
                entries = persisted.entries
            } else {
                entries = []
            }
            pruneTerminalEntries()
            isLoaded = true
            loadFailureReason = nil
        } catch {
            failClosed(reason: "Effect journal failed to load.")
        }
    }

    func persist() throws {
        let state = PersistedState(schemaVersion: Self.persistenceSchemaVersion, entries: entries)
        let data = try JSONEncoder().encode(state)
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: .atomic)
    }

    func appendIntent(_ entry: MCPEffectJournalEntry) throws {
        entries.append(entry)
        try persist()
    }

    /// - Parameter resultingRevision: when committing, the target's revision immediately after the
    ///   mutation actually wrote it. Overwrites `baselineRevision` (which held the PRE-mutation
    ///   value, only relevant for a not-yet-committed rollback) so that a later restore's drift
    ///   check compares against the correct anchor: "did anything touch this target after MY
    ///   mutation completed," not "does it still match the state from before I even ran" — the
    ///   latter is always false for a successful mutation, since applying it is what changed the
    ///   revision in the first place. See `MCPRecoveryRestorer.restore` for the consuming check.
    func updatePhase(
        transactionID: String,
        phase: MCPEffectJournalEntry.Phase,
        conflictMessage: String? = nil,
        resultingRevision: MCPTargetRevision? = nil
    ) throws {
        guard let index = entries.firstIndex(where: { $0.transactionID == transactionID }) else {
            throw MCPEffectJournalStoreError.entryNotFound
        }
        entries[index].phase = phase
        entries[index].conflictMessage = conflictMessage
        if phase == .committed, let resultingRevision {
            entries[index].baselineRevision = resultingRevision
        }
        pruneTerminalEntries()
        try persist()
    }

    func entry(transactionID: String) -> MCPEffectJournalEntry? {
        entries.first { $0.transactionID == transactionID }
    }

    /// Removes journal history for a deleted target. Refuses when unresolved intent/conflict remains.
    func removeEntries(forTargetID targetID: String) throws {
        let hasUnresolved = entries.contains { entry in
            entry.targetID == targetID && (entry.phase == .intent || entry.phase == .conflict)
        }
        if hasUnresolved {
            throw MCPEffectJournalStoreError.unresolvedEntriesRemain
        }
        let before = entries.count
        entries.removeAll { $0.targetID == targetID }
        guard entries.count != before else { return }
        try persist()
    }

    func unresolvedEntries(now: Date = Date()) -> [MCPEffectJournalEntry] {
        // `expiresAt` bounds how long a proposal token stays valid for a client to act on — it is
        // not a reason to stop reconciling an incomplete journal entry. An `.intent` entry whose
        // deadline already passed still represents an ambiguous "did this mutation happen"
        // record and must be resolved at launch like any other, or it sits in `.intent` phase
        // forever: never rolled back, never removed, permanently unaccounted for.
        entries.filter { entry in
            switch entry.phase {
            case .intent:
                return true
            case .conflict:
                return true
            case .committed, .rolledBack:
                return false
            }
        }
    }

    /// Bounds the journal so it doesn't grow forever — every mutation attempt (approved or not,
    /// once AH-3 wires real callers in) appends an entry, and nothing previously removed one.
    /// `.intent`/`.conflict` entries are exempt: they represent unresolved state that reconciliation
    /// owns, not routine history.
    private func pruneTerminalEntries(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.terminalEntryRetention)
        entries.removeAll { entry in
            guard entry.phase == .committed || entry.phase == .rolledBack else { return false }
            return entry.createdAt < cutoff
        }
        let terminalCount = entries.count { $0.phase == .committed || $0.phase == .rolledBack }
        guard terminalCount > Self.maxTerminalEntries else { return }
        let overflow = terminalCount - Self.maxTerminalEntries
        let staleIDs = entries
            .filter { $0.phase == .committed || $0.phase == .rolledBack }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(overflow)
            .map(\.id)
        entries.removeAll { staleIDs.contains($0.id) }
    }

    /// Clears journal entries for an isolated self-validation lane (AI-5).
    func resetForSelfValidation() {
        entries.removeAll()
        isLoaded = true
        loadFailureReason = nil
    }

    /// Unconditionally clears every journal entry, including `.intent`/`.conflict` phases that
    /// `removeEntries(forTargetID:)` deliberately refuses to touch. Used only by the launch-time
    /// fresh-state reset (`MCPRecoveryService.enforceFreshLaunchState()`) — at launch there is no
    /// live client session whose evidence needs protecting, and a stale `.conflict` entry from a
    /// prior crash must never resurface the "MCP recovery needed" banner in a new session.
    func clearAllForFreshLaunch() {
        entries.removeAll()
        try? persist()
    }

    private func failClosed(reason: String) {
        entries = []
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
