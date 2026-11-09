import Foundation

/// JSON-backed durable repository for diagnostic runs and immutable evidence (AN-2 / AN-4).
///
/// Concurrency: `@MainActor` — bookkeeping only; never used on the proxy request hot path.
@MainActor
final class DiagnosticRunStore {
    static let persistenceFileName = "mcp-diagnostic-runs.json"
    static let persistenceSchemaVersion = DiagnosticRunSchemaVersion.current

    struct PersistedState: Equatable, Sendable, Codable {
        var schemaVersion: Int
        var runs: [DiagnosticRun]
        var evidenceRecords: [DiagnosticEvidenceRecord]
        var experimentWindows: [DiagnosticExperimentWindow]? = nil
    }

    /// AN-2 placeholder envelope accepted for migration only.
    private struct LegacyPersistedStateV1: Codable {
        var schemaVersion: Int
        var runs: [DiagnosticRun]
        var evidenceRecords: [LegacyEvidencePlaceholder]
    }

    private struct LegacyEvidencePlaceholder: Codable {
        var id: UUID
        var runID: DiagnosticRunID
        var createdAt: Date
    }

    private(set) var runs: [DiagnosticRun] = []
    private(set) var evidenceRecords: [DiagnosticEvidenceRecord] = []
    private(set) var experimentWindows: [DiagnosticExperimentWindow] = []
    private(set) var isLoaded = false
    private(set) var loadFailureReason: String?

    private let persistenceURL: URL
    private let fileManager: FileManager
    private let clock: () -> Date

    init(
        persistenceURL: URL? = nil,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.clock = clock
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
    }

    /// Loads the store or fails closed without overwriting a corrupt/unsupported file.
    /// Migrates schema v1 (empty evidence placeholders) to v2 on read.
    func load() {
        experimentWindows = []
        do {
            if fileManager.fileExists(atPath: persistenceURL.path) {
                let data = try Data(contentsOf: persistenceURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let header = try decoder.decode(SchemaHeader.self, from: data)
                switch header.schemaVersion {
                case Self.persistenceSchemaVersion:
                    let persisted = try decoder.decode(PersistedState.self, from: data)
                    runs = persisted.runs
                    evidenceRecords = persisted.evidenceRecords
                    experimentWindows = persisted.experimentWindows ?? []
                case 1:
                    let legacy = try decoder.decode(LegacyPersistedStateV1.self, from: data)
                    runs = legacy.runs
                    evidenceRecords = []
                    try persist()
                default:
                    failClosed(reason: "Unsupported diagnostic-run store schema version.")
                    return
                }
            } else {
                runs = []
                evidenceRecords = []
            }
            pruneTerminalRuns(now: clock())
            isLoaded = true
            loadFailureReason = nil
        } catch {
            failClosed(reason: "Diagnostic-run store failed to load.")
        }
    }

    /// Atomically replaces the on-disk envelope.
    func persist() throws {
        let state = PersistedState(
            schemaVersion: Self.persistenceSchemaVersion,
            runs: runs,
            evidenceRecords: evidenceRecords,
            experimentWindows: experimentWindows
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: .atomic)
    }

    func saveExperimentWindow(_ window: DiagnosticExperimentWindow) throws {
        let previous = experimentWindows
        experimentWindows.removeAll { $0.id == window.id }
        if experimentWindows.count >= 32 {
            guard let index = experimentWindows.firstIndex(where: { $0.endedAt != nil }) else {
                experimentWindows = previous
                throw EffectBundleError.retainedBundleLimitReached
            }
            experimentWindows.remove(at: index)
        }
        experimentWindows.append(window)
        do { try persist() } catch { experimentWindows = previous; throw error }
    }

    func run(id: DiagnosticRunID) -> DiagnosticRun? {
        runs.first(where: { $0.id == id })
    }

    func upsert(_ run: DiagnosticRun) throws {
        replaceInMemory(run)
        pruneTerminalRuns(now: clock())
        try persist()
    }

    /// Updates the in-memory run without filesystem I/O. Used for observation-summary ticks
    /// so capture ingest never writes on the hot path (AN-3).
    func replaceInMemory(_ run: DiagnosticRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
    }

    func evidenceRecord(id: UUID) -> DiagnosticEvidenceRecord? {
        evidenceRecords.first(where: { $0.id == id })
    }

    func evidenceRecord(forRunID runID: DiagnosticRunID) -> DiagnosticEvidenceRecord? {
        evidenceRecords.first(where: { $0.runID == runID })
    }

    /// Owner-scoped paginated evidence list, newest first.
    func listEvidence(
        ownerID: String,
        limit: Int = DiagnosticRunBudget.listPageDefault,
        offset: Int = 0
    ) -> DiagnosticEvidenceListPage {
        let boundedLimit = min(max(limit, 1), DiagnosticRunBudget.listPageMax)
        let owned = evidenceRecords
            .filter { $0.ownerID == ownerID }
            .sorted { $0.createdAt > $1.createdAt }
        let slice = owned.dropFirst(max(offset, 0)).prefix(boundedLimit)
        return DiagnosticEvidenceListPage(
            records: Array(slice),
            totalCount: owned.count,
            hasMore: max(offset, 0) + slice.count < owned.count
        )
    }

    /// Appends one immutable evidence record after verified terminal close (AN-4).
    func appendEvidence(_ record: DiagnosticEvidenceRecord) throws {
        if evidenceRecords.contains(where: { $0.runID == record.runID }) {
            return
        }
        let perRunCount = evidenceRecords.filter { $0.runID == record.runID }.count
        guard perRunCount < DiagnosticRunBudget.maxImmutableEvidenceRecordsPerRun else {
            throw DiagnosticRunError.evidenceQuotaExceeded(
                "A run may have at most \(DiagnosticRunBudget.maxImmutableEvidenceRecordsPerRun) evidence records."
            )
        }
        let existingBytes = evidenceRecords
            .filter { $0.runID == record.runID }
            .reduce(0) { partial, existing in
                partial + ((try? DiagnosticRunEvidenceMaterializer.encodedByteCount(existing)) ?? 0)
            }
        let newBytes = try DiagnosticRunEvidenceMaterializer.encodedByteCount(record)
        guard existingBytes + newBytes <= DiagnosticRunBudget.maxEncodedEvidenceBytesPerRun else {
            throw DiagnosticRunError.evidenceQuotaExceeded(
                "Encoded evidence for this run exceeds \(DiagnosticRunBudget.maxEncodedEvidenceBytesPerRun) bytes."
            )
        }
        evidenceRecords.append(record)
        try persist()
    }

    /// Updates editable notes without mutating immutable provenance or digests.
    func updateEditableNotes(
        recordID: UUID,
        ownerID: String,
        notes: String?
    ) throws -> DiagnosticEvidenceRecord {
        guard let index = evidenceRecords.firstIndex(where: { $0.id == recordID }) else {
            throw DiagnosticRunError.evidenceNotFound
        }
        guard evidenceRecords[index].ownerID == ownerID else {
            throw DiagnosticRunError.notOwner
        }
        let normalized: String?
        if let notes {
            normalized = try DiagnosticRunValidation.validatedEditableNotes(notes)
        } else {
            normalized = nil
        }
        evidenceRecords[index].editableNotes = normalized
        evidenceRecords[index].notesUpdatedAt = clock()
        try persist()
        return evidenceRecords[index]
    }

    /// Nonterminal runs that still require relaunch reconciliation or close work.
    func unresolvedRuns(now: Date? = nil) -> [DiagnosticRun] {
        let instant = now ?? clock()
        return runs.filter { run in
            run.status.isNonterminal || run.expiresAt <= instant && !run.status.isPrunableTerminal
        }
    }

    private struct SchemaHeader: Codable {
        var schemaVersion: Int
    }

    private func pruneTerminalRuns(now: Date) {
        var kept: [DiagnosticRun] = []
        var terminalsByOwner: [String: [DiagnosticRun]] = [:]
        var globalTerminals: [DiagnosticRun] = []

        for run in runs {
            if run.status.isPrunableTerminal, let terminalAt = run.terminalAt {
                if now.timeIntervalSince(terminalAt) > DiagnosticRunBudget.terminalRetention {
                    continue
                }
                globalTerminals.append(run)
                terminalsByOwner[run.owner.ownerID, default: []].append(run)
            } else {
                kept.append(run)
            }
        }

        globalTerminals.sort { ($0.terminalAt ?? .distantPast) < ($1.terminalAt ?? .distantPast) }
        if globalTerminals.count > DiagnosticRunBudget.maxTerminalRunsGlobal {
            globalTerminals = Array(globalTerminals.suffix(DiagnosticRunBudget.maxTerminalRunsGlobal))
        }

        var retainedIDs = Set(globalTerminals.map(\.id))
        for (_, ownerRuns) in terminalsByOwner {
            let sorted = ownerRuns.sorted { ($0.terminalAt ?? .distantPast) < ($1.terminalAt ?? .distantPast) }
            let capped = sorted.suffix(DiagnosticRunBudget.maxTerminalRunsPerOwner)
            let allowed = Set(capped.map(\.id)).intersection(retainedIDs)
            retainedIDs = retainedIDs.subtracting(Set(sorted.map(\.id)).subtracting(allowed))
                .union(allowed)
        }

        let prunedRunIDs = Set(runs.map(\.id)).subtracting(Set(kept.map(\.id)).union(retainedIDs))
        if !prunedRunIDs.isEmpty {
            evidenceRecords.removeAll { prunedRunIDs.contains($0.runID) }
        }

        let terminalKept = globalTerminals.filter { retainedIDs.contains($0.id) }
        runs = kept + terminalKept
    }

    private func failClosed(reason: String) {
        runs = []
        evidenceRecords = []
        experimentWindows = []
        isLoaded = false
        loadFailureReason = reason
    }

    static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent(persistenceFileName)
    }
}
