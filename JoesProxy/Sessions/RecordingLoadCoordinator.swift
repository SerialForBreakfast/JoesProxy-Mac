import Foundation

/// Orchestrates opening a `.jproxy` recording file into the session store.
///
/// ## Concurrency
/// `RecordingLoadCoordinator` is `@MainActor`-isolated. File I/O and decoding are dispatched
/// inside `SessionRecordingImportService`, so the main thread is never blocked. All state
/// mutations and `sessionStore` calls are made on the main actor after async operations complete.
///
/// ## Open lifecycle
/// 1. `load(from:mode:)` sets state to `.loading` and awaits `importService.open`.
/// 2. On `RecordingOpenError.schemaTooNew`, the coordinator sets `pendingSchemaWarning` instead
///    of failing — the UI should present a sheet offering "Load Anyway" / "Cancel".
/// 3. On success, phase-1 sessions (bodies may be stripped for large files) are applied to the
///    store immediately via `applyToStore(_:mode:)`.
/// 4. When `phase2Source` is present, a background task re-decodes sessions with full
///    bodies and applies them to the store in bounded batches, filling in bodies progressively
///    without publishing one main-actor change per session.
@MainActor
final class RecordingLoadCoordinator {

    private static let phase2BodyUpdateBatchSize = 50

    // MARK: - Nested types

    /// Controls how loaded sessions are merged with the current session store contents.
    enum LoadMode {
        /// Clears all existing sessions before loading the recording.
        case replace
        /// Appends loaded sessions to the existing session list, deduplicating by ID.
        case merge
    }

    /// Tracks the current state of an open operation.
    enum LoadState: Equatable {
        case idle
        case loading
        /// One or more sessions failed to decode individually; the rest loaded successfully.
        case loadWarning([UUID])
        /// The entire open operation failed with a localized message.
        case failed(String)

        static func == (lhs: LoadState, rhs: LoadState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading):
                return true
            case (.loadWarning(let a), .loadWarning(let b)):
                return a == b
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// Payload for the "schema too new" warning sheet. The coordinator holds this until the user
    /// either confirms (Load Anyway) or cancels.
    struct SchemaVersionWarning {
        let fileVersion: Int
        let url: URL
        let mode: LoadMode
    }

    // MARK: - Published state

    /// Current lifecycle state of the most recent open operation.
    private(set) var loadState: LoadState = .idle

    /// Advisory message surfaced when a version-0 or best-effort future-schema file was opened.
    private(set) var schemaNotice: String?

    /// Non-nil when a "schema too new" warning is awaiting user confirmation. The UI should
    /// present a sheet offering "Load Anyway" / "Cancel" while this is set.
    private(set) var pendingSchemaWarning: SchemaVersionWarning?

    // MARK: - Dependencies

    private let importService: any SessionRecordingImportService
    private let sessionStore: any SessionStore
    private var phase2BodyLoadTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - importService: Reads and decodes recording files from disk.
    ///   - sessionStore: The store to load sessions into.
    init(importService: any SessionRecordingImportService, sessionStore: any SessionStore) {
        self.importService = importService
        self.sessionStore = sessionStore
    }

    // MARK: - Load

    /// Opens the recording at `url` and loads sessions into the store in two phases.
    ///
    /// Phase 1 completes before this method returns: sessions (possibly without bodies for large
    /// files) are applied to the store immediately. Phase 2 runs asynchronously in a background
    /// task to fill in body data when the file exceeded `RecordingConstants.lazyLoadThreshold`.
    ///
    /// A `schemaTooNew` throw is intercepted and surfaced via `pendingSchemaWarning` instead of
    /// setting `loadState` to `.failed`, giving the user a "Load Anyway" escape hatch.
    ///
    /// - Parameters:
    ///   - url: Path to the `.jproxy` file.
    ///   - mode: Whether to replace or merge with the current session list.
    func load(from url: URL, mode: LoadMode) async {
        phase2BodyLoadTask?.cancel()
        phase2BodyLoadTask = nil
        loadState = .loading
        schemaNotice = nil
        pendingSchemaWarning = nil

        await performLoad(from: url, mode: mode, bestEffort: false)
    }

    /// Confirms the pending schema-version warning and re-attempts the load with best-effort
    /// decoding. The UI should call this in response to the user tapping "Load Anyway".
    func confirmSchemaWarning() async {
        guard let warning = pendingSchemaWarning else { return }
        phase2BodyLoadTask?.cancel()
        phase2BodyLoadTask = nil
        pendingSchemaWarning = nil
        loadState = .loading
        schemaNotice = nil

        await performLoad(from: warning.url, mode: warning.mode, bestEffort: true)
    }

    /// Dismisses the pending schema warning without loading the file.
    func cancelSchemaWarning() {
        phase2BodyLoadTask?.cancel()
        phase2BodyLoadTask = nil
        pendingSchemaWarning = nil
        loadState = .idle
    }

    /// Resets coordinator state to `.idle`. Call after the UI has acknowledged warnings or errors.
    func resetState() {
        phase2BodyLoadTask?.cancel()
        phase2BodyLoadTask = nil
        loadState = .idle
        schemaNotice = nil
    }

    // MARK: - Private helpers

    private func performLoad(from url: URL, mode: LoadMode, bestEffort: Bool) async {
        let result: RecordingLoadResult
        do {
            result = try await importService.open(from: url, bestEffort: bestEffort)
        } catch RecordingOpenError.schemaTooNew(let version) {
            // Surface as a warning rather than a hard failure.
            pendingSchemaWarning = SchemaVersionWarning(fileVersion: version, url: url, mode: mode)
            loadState = .idle
            return
        } catch {
            loadState = .failed(error.localizedDescription)
            return
        }

        schemaNotice = result.schemaNotice
        applyToStore(result.envelope.sessions, mode: mode)

        loadState = result.failedSessionIDs.isEmpty
            ? .idle
            : .loadWarning(result.failedSessionIDs)

        // Phase 2: fill in deferred bodies for large files.
        if let phase2Source = result.phase2Source {
            let phase1IDs = Set(result.envelope.sessions.map(\.id))
            phase2BodyLoadTask = schedulePhase2BodyLoad(from: phase2Source, existingIDs: phase1IDs)
        }
    }

    private func applyToStore(_ sessions: [SessionRecord], mode: LoadMode) {
        switch mode {
        case .replace:
            sessionStore.load(sessions: sessions)
        case .merge:
            let existingIDs = Set(sessionStore.sessions.map(\.id))
            let newSessions = sessions.filter { !existingIDs.contains($0.id) }
            sessionStore.load(sessions: sessionStore.sessions + newSessions)
        }
    }

    /// Decodes full sessions (with body data) from an opaque phase-2 source, then updates
    /// the store in bounded batches on the main actor. Failures here are non-fatal: phase-1
    /// sessions remain visible and any bodies that successfully decode are filled in incrementally.
    @discardableResult
    private func schedulePhase2BodyLoad(
        from source: RecordingPhase2Source,
        existingIDs: Set<UUID>
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            let applySignpost = CapturePerformanceSignposts.signposter.beginInterval("RecordingLoadCoordinator.phase2ApplyBatches")
            defer { CapturePerformanceSignposts.signposter.endInterval("RecordingLoadCoordinator.phase2ApplyBatches", applySignpost) }

            let totalCount = await source.totalSessionCount()
            var startIndex = 0
            while startIndex < totalCount {
                if Task.isCancelled {
                    await source.cleanup()
                    return
                }
                let decoded = await source.decodeBatch(
                    startingAt: startIndex,
                    limit: Self.phase2BodyUpdateBatchSize
                )
                let applicable = decoded.filter { existingIDs.contains($0.id) }
                if !applicable.isEmpty {
                    self.sessionStore.update(applicable)
                }
                startIndex += Self.phase2BodyUpdateBatchSize
            }
            await source.cleanup()

            if self.phase2BodyLoadTask?.isCancelled == false {
                self.phase2BodyLoadTask = nil
            }
        }
    }

    func waitForPhase2BodyLoadForTesting() async {
        await phase2BodyLoadTask?.value
    }
}
