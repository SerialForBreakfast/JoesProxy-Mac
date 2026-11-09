import Combine
import Foundation
import os

struct JournalCompactionPolicy {
    private static let minimumInterval: TimeInterval = 15 * 60
    private static let minimumGrowthBytes = 64 * 1_048_576
    private(set) var attemptedAt: TimeInterval?
    private(set) var baselineBytes = 0
    private(set) var retainedCount = 0

    func shouldCompact(bytes: Int, count: Int, now: TimeInterval) -> Bool {
        guard bytes >= Self.minimumGrowthBytes else { return false }
        guard let attemptedAt else { return true }
        guard now - attemptedAt >= Self.minimumInterval else { return false }
        return count < retainedCount || bytes - baselineBytes >= max(Self.minimumGrowthBytes, baselineBytes / 4)
    }

    mutating func begin(bytes: Int, count: Int, now: TimeInterval) {
        attemptedAt = now
        baselineBytes = bytes
        retainedCount = count
    }

    mutating func completed(bytes: Int) { baselineBytes = bytes }
}

/// Snapshot metadata exposed through ``capture_digest`` for rolling auto-save state.
struct RollingCaptureStatus: Equatable, Sendable {
    var isEnabled: Bool
    var isAvailable: Bool
    var savedAt: Date?
    var sessionCount: Int
    var fileURL: URL?
    var persistenceError: String? = nil
}

private struct RollingCaptureCheckpointMetadata: Codable, Sendable {
    let version: Int
    let savedAt: Date
    let sessionCount: Int
}

/// Incremental rolling-capture recovery checkpoints under Application Support.
///
/// Concurrency: `@MainActor` schedules FIFO journal commands; `SessionJournalIO` owns blocking
/// journal I/O. Explicit recording exports run on a background utility task after a journal barrier.
@MainActor
final class RollingCapturePersistenceCoordinator {
    nonisolated static let directoryName = "RollingCaptures"
    nonisolated static let latestFileName = "latest.jproxy"
    nonisolated static let dismissedRestoreKey = "rollingCaptureRestoreDismissedAt"
    nonisolated static let journalFileName = "journal.jsonl"
    nonisolated static let checkpointMetadataFileName = "checkpoint.json"
    nonisolated static let staleStagingFileAge: TimeInterval = 60 * 60

    private let sessionStore: any SessionStore
    private let configuration: any AppConfiguration
    private let exportService: JSONSessionExportService
    private let fileManager: FileManager
    private let proxyPortProvider: () -> UInt16
    private let storageDirectoryOverride: URL?
    private var cancellables = Set<AnyCancellable>()
    private var pendingSaveTask: Task<Void, Never>?
    /// Appends observed since the last save was *requested*. Exposed for regression tests that
    /// assert the reset happens at request time rather than at write completion.
    private(set) var sessionsSinceLastSave = 0
    /// The persistence write currently in flight. Every write chains onto this so journal
    /// checkpoints and explicit recording exports never overlap.
    private var activeFlush: Task<Void, Never>?
    /// Identifies the current `activeFlush` generation. `Task` has no identity comparison, so a
    /// completion callback uses this (rather than `activeFlush === originalTask`) to tell whether
    /// it is still the most recent write before clearing `activeFlush`.
    private var activeFlushGeneration = 0
    /// Set when an auto-save is requested while one is already writing, so exactly one follow-up
    /// write runs afterwards instead of one per session change.
    private var hasQueuedAutoSave = false
    private var activeSnapshotWrites = 0
    private var compactionPolicy = JournalCompactionPolicy()
    private let now: () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var dirtyRevision: UInt64 = 0
    private var savedRevision: UInt64 = 0
    private var captureGeneration: UInt64 = 0
    private var timerGeneration: UInt64 = 0
    private var retryAfter: TimeInterval?
    private let logger = Logger(subsystem: "com.JoesProxyApp", category: "RollingRecovery")
    /// Composition-time isolation; unlike the checkpoint preference, this disables all disk access.
    private let storageAccessEnabled: Bool
    var onPersistenceError: ((String?) -> Void)?

    /// Number of completed persistence checkpoints. Explicit snapshots and incremental journal
    /// checkpoints both count; diagnostic only.
    private(set) var snapshotWriteCount = 0
    /// Highest number of persistence operations ever in flight simultaneously. Must stay at one.
    private(set) var peakConcurrentSnapshotWrites = 0

    /// True while a recovery checkpoint or explicit recording export is in flight.
    var isWritingSnapshot: Bool { activeFlush != nil }
    var acceptsExplicitSnapshots: Bool { storageAccessEnabled && configuration.rollingCaptureAutoSaveEnabled }

    private(set) var lastStatus = RollingCaptureStatus(
        isEnabled: true,
        isAvailable: false,
        savedAt: nil,
        sessionCount: 0,
        fileURL: nil
    )

    init(
        sessionStore: any SessionStore,
        configuration: any AppConfiguration,
        exportService: JSONSessionExportService = JSONSessionExportService(),
        fileManager: FileManager = .default,
        proxyPortProvider: @escaping () -> UInt16,
        storageDirectoryOverride: URL? = nil,
        storageAccessEnabled: Bool = true,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.sessionStore = sessionStore
        self.configuration = configuration
        self.exportService = exportService
        self.fileManager = fileManager
        self.proxyPortProvider = proxyPortProvider
        self.storageDirectoryOverride = storageDirectoryOverride
        self.storageAccessEnabled = storageAccessEnabled
        self.now = now
        self.sleep = sleep
        guard storageAccessEnabled else {
            lastStatus.isEnabled = false
            return
        }
        prepareStorageDirectory()
        refreshStatusFromDisk()
        subscribeToSessionChanges()
    }

    var storageDirectory: URL {
        if let storageDirectoryOverride {
            return storageDirectoryOverride
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    var latestFileURL: URL {
        storageDirectory.appendingPathComponent(Self.latestFileName, isDirectory: false)
    }

    var journalURL: URL {
        storageDirectory.appendingPathComponent(Self.journalFileName, isDirectory: false)
    }

    var checkpointMetadataURL: URL {
        storageDirectory.appendingPathComponent(Self.checkpointMetadataFileName, isDirectory: false)
    }

    private lazy var journalIO: SessionJournalIO = SessionJournalIO(journalURL: journalURL, metadataURL: checkpointMetadataURL, fileManager: fileManager) { [weak self] epoch, error in
        Task { @MainActor [weak self] in
            guard let self, self.captureGeneration == epoch else { return }
            self.logger.error("Rolling journal paused: \(error.message, privacy: .public)")
            self.reportPersistenceError(error.message)
        }
    }

    /// Persists an explicit session snapshot before destructive capture operations.
    ///
    /// Explicit snapshots must land, so this waits out any in-flight auto-save and then writes its
    /// own copy rather than coalescing onto it.
    func flushSnapshot(sessions: [SessionRecord]) async {
        guard storageAccessEnabled else { return }
        guard configuration.rollingCaptureAutoSaveEnabled else { return }
        guard !sessions.isEmpty else { return }
        // Looped rather than a single await: each `await existing.value` is a suspension point, and
        // another auto-save can start while we're suspended. Re-checking after every wait means we
        // only take over once `activeFlush` is genuinely nil with no other MainActor code able to
        // run in between — otherwise we could clobber a write that just started, leaving it running
        // unserialized alongside ours.
        while let existing = activeFlush {
            await existing.value
        }
        activeFlushGeneration += 1
        let generation = activeFlushGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            // Drain accepted appends before the explicit snapshot/export boundary.
            let _: Result<Int, Error> = await withCheckedContinuation { continuation in
                self.journalIO.checkpoint(sessions: [], compact: false, commitMetadata: {}, completion: {
                    continuation.resume(returning: $0)
                })
            }
            await self.writeSnapshot(sessions: sessions)
        }
        activeFlush = task
        defer {
            if activeFlushGeneration == generation {
                activeFlush = nil
                if hasQueuedAutoSave { requestAutoSave() }
            }
        }
        await task.value
    }

    /// Persists the current capture immediately when enabled.
    func flushNow() async {
        await flushSnapshot(sessions: sessionStore.sessions)
    }

    /// Auto-save entry point: at most one journal checkpoint in flight and one queued behind it.
    ///
    /// Periodic recovery uses the existing append-only journal. A checkpoint synchronizes those
    /// bytes and only compacts when the journal has grown materially. It does not create a full
    /// `.jproxy`, duplicate `latest`, or rotate another whole-capture file.
    private func requestAutoSave() {
        guard storageAccessEnabled else { return }
        guard configuration.rollingCaptureAutoSaveEnabled else { return }
        guard dirtyRevision != savedRevision else { return }
        if let retryAfter, now() < retryAfter {
            scheduleCheckpointDeadline()
            return
        }
        guard activeFlush == nil else {
            hasQueuedAutoSave = true
            return
        }
        activeFlushGeneration += 1
        let generation = activeFlushGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.hasQueuedAutoSave = false
                guard self.configuration.rollingCaptureAutoSaveEnabled,
                      self.dirtyRevision != self.savedRevision else { return }
                let sessions = self.sessionStore.sessions
                guard !sessions.isEmpty else { return }
                self.cancelPendingSave()
                let revision = self.dirtyRevision
                let epoch = self.captureGeneration
                let succeeded = await self.writeJournalCheckpoint(sessions: sessions)
                guard epoch == self.captureGeneration else { return }
                if succeeded {
                    self.savedRevision = revision
                    self.retryAfter = nil
                } else {
                    self.retryAfter = self.now() + Double(max(5, self.configuration.rollingCaptureSaveIntervalSeconds))
                    self.hasQueuedAutoSave = false
                    self.cancelPendingSave()
                }
                if self.dirtyRevision != self.savedRevision { self.scheduleCheckpointDeadline() }
                if !succeeded { return }
            } while self.hasQueuedAutoSave
        }
        activeFlush = task
        Task { [weak self] in
            await task.value
            guard let self, self.activeFlushGeneration == generation else { return }
            self.activeFlush = nil
            if self.hasQueuedAutoSave { self.requestAutoSave() }
        }
    }

    private func writeJournalCheckpoint(sessions: [SessionRecord]) async -> Bool {
        sessionsSinceLastSave = 0
        let journalBytes = Self.fileSize(at: journalURL, fileManager: fileManager)
        let epoch = captureGeneration
        let shouldCompact = compactionPolicy.shouldCompact(bytes: journalBytes, count: sessions.count, now: now())
        if shouldCompact { compactionPolicy.begin(bytes: journalBytes, count: sessions.count, now: now()) }

        activeSnapshotWrites += 1
        peakConcurrentSnapshotWrites = Swift.max(peakConcurrentSnapshotWrites, activeSnapshotWrites)
        defer { activeSnapshotWrites -= 1 }

        let writer = journalIO
        let checkpointMetadataURL = checkpointMetadataURL
        let outcome: Result<Int, Error> = await withCheckedContinuation { continuation in
            writer.checkpoint(sessions: sessions, compact: shouldCompact, commitMetadata: {
                try Self.writeCheckpointMetadata(sessionCount: sessions.count, to: checkpointMetadataURL)
            }, completion: { continuation.resume(returning: $0) })
        }
        guard epoch == captureGeneration else { return false }
        guard case .success(let compactedBytes) = outcome else {
            logger.error("Recovery checkpoint failed; retry deferred.")
            if case .failure(let error) = outcome {
                reportPersistenceError((error as? SessionJournalIOError)?.message
                    ?? "Recovery checkpoint failed. The last checkpoint remains unchanged; retry is pending. Check disk space and permissions.")
            }
            return false
        }
        // A later append can fail before this earlier barrier resumes on MainActor.
        reportPersistenceError(writer.failure?.message)
        if shouldCompact { compactionPolicy.completed(bytes: compactedBytes) }
        if shouldCompact {
            logger.info("Journal compacted: before=\(journalBytes) after=\(compactedBytes) sessions=\(sessions.count)")
        }
        snapshotWriteCount += 1
        refreshStatusFromDisk(sessionCount: sessions.count)
        return true
    }

    /// Performs exactly one full-store export. Callers must serialize through ``activeFlush``.
    private func writeSnapshot(sessions: [SessionRecord]) async {
        let epoch = captureGeneration
        // Reset as the data is captured, not when the write finishes: changes arriving during a
        // multi-second export belong to the *next* save, and leaving the counter above the
        // threshold for the duration of the write is what produced the original stampede.
        sessionsSinceLastSave = 0
        let envelope = makeEnvelope(sessions: sessions)
        let destination = latestFileURL
        let retentionCount = configuration.rollingCaptureRetentionCount
        let maxDiskBytes = configuration.rollingCaptureMaxDiskMB * 1_048_576

        activeSnapshotWrites += 1
        peakConcurrentSnapshotWrites = Swift.max(peakConcurrentSnapshotWrites, activeSnapshotWrites)
        defer { activeSnapshotWrites -= 1 }

        let succeeded = await Task.detached(priority: .utility) { [exportService, fileManager] in
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let archivedLatest = try Self.archiveCurrentLatest(
                    in: destination.deletingLastPathComponent(),
                    latestURL: destination,
                    fileManager: fileManager
                )
                do {
                    try exportService.exportAsRecording(envelope, to: destination, fidelity: .fullRecording)
                } catch {
                    Self.restoreArchivedLatestIfNeeded(
                        archivedLatest,
                        latestURL: destination,
                        fileManager: fileManager
                    )
                    throw error
                }
                try Self.pruneSnapshots(
                    in: destination.deletingLastPathComponent(),
                    retentionCount: retentionCount,
                    maxDiskBytes: maxDiskBytes,
                    fileManager: fileManager
                )
                return true
            } catch {
                return false
            }
        }.value
        guard succeeded, epoch == captureGeneration else { return }
        snapshotWriteCount += 1
        refreshStatusFromDisk(sessionCount: sessions.count)
    }

    /// Loads the latest rolling snapshot when present.
    func restoreLatestSnapshot() throws -> [SessionRecord] {
        guard storageAccessEnabled else { throw RollingCaptureRestoreError.noSnapshot }
        return try Self.readRecoverySnapshot(at: latestFileURL, journalURL: journalURL, fileManager: fileManager)
    }

    /// The UI awaits decoding without blocking MainActor. Only immutable paths cross to the
    /// utility task; it owns its FileManager. Cancellation prevents publication, not disk reads.
    func restoreLatestSnapshotInBackground() async throws -> [SessionRecord] {
        guard storageAccessEnabled else { throw RollingCaptureRestoreError.noSnapshot }
        let url = latestFileURL
        let journal = journalURL
        return try await restoreSnapshot {
            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let sessions = try Self.readRecoverySnapshot(at: url, journalURL: journal, fileManager: FileManager())
                try Task.checkCancellation()
                return sessions
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    /// MainActor transaction guard; the injected loader suspends while I/O runs off actor.
    func restoreSnapshot(using loader: @MainActor () async throws -> [SessionRecord]) async throws -> [SessionRecord] {
        let revision = dirtyRevision
        let generation = captureGeneration
        let sessions = try await loader()
        try Task.checkCancellation()
        guard revision == dirtyRevision, generation == captureGeneration else {
            throw RollingCaptureRestoreError.captureChanged
        }
        return sessions
    }

    nonisolated private static func readRecoverySnapshot(
        at url: URL, journalURL: URL, fileManager: FileManager
    ) throws -> [SessionRecord] {
        var baseSessions: [SessionRecord] = []
        if fileManager.fileExists(atPath: url.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if try RecordingContainer.format(at: url) == RecordingContainer.gzipFormat {
                baseSessions = try JSONSessionRecordingImportService.openStreamingGzip(
                    from: url,
                    bestEffort: true,
                    decoder: decoder,
                    deferBodiesWhenLarge: false
                ).envelope.sessions
            } else {
                let jsonData = try RecordingContainer.unwrapFile(at: url)
                baseSessions = try decoder.decode(SessionExportEnvelope.self, from: jsonData).sessions
            }
        }
        let journalSessions = SessionJournalReader.readSessions(from: journalURL, fileManager: fileManager)
        if baseSessions.isEmpty && journalSessions.isEmpty {
            throw RollingCaptureRestoreError.noSnapshot
        }
        return Self.mergeRecovery(base: baseSessions, journal: journalSessions)
    }

    nonisolated static func mergeRecovery(base: [SessionRecord], journal: [SessionRecord]) -> [SessionRecord] {
        var merged = base
        var indices: [SessionRecord.ID: Int] = [:]
        for (index, session) in base.enumerated() where indices[session.id] == nil {
            indices[session.id] = index
        }
        for session in journal {
            if let index = indices[session.id] {
                merged[index] = session
            } else {
                indices[session.id] = merged.count
                merged.append(session)
            }
        }
        return merged
    }

    /// Directly copies the on-disk snapshot container to a destination file URL without in-memory decoding.
    func copyLatestSnapshot(to destinationURL: URL) throws {
        guard storageAccessEnabled else { throw RollingCaptureRestoreError.noSnapshot }
        let hasLatest = fileManager.fileExists(atPath: latestFileURL.path)
        let hasJournal = Self.fileSize(at: journalURL, fileManager: fileManager) > 0
        guard hasLatest || hasJournal else {
            throw RollingCaptureRestoreError.noSnapshot
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        if hasJournal {
            let sessions = try restoreLatestSnapshot()
            try exportService.exportAsRecording(
                makeEnvelope(sessions: sessions),
                to: destinationURL,
                fidelity: .fullRecording
            )
        } else {
            try fileManager.copyItem(at: latestFileURL, to: destinationURL)
        }
    }

    /// Exports the on-disk snapshot as a .har file to the specified destination URL.
    func exportLatestSnapshotAsHAR(to destinationURL: URL, harExportService: any ExportService) throws {
        let sessions = try restoreLatestSnapshot()
        let envelope = makeEnvelope(sessions: sessions)
        try harExportService.export(envelope, to: destinationURL)
    }

    /// Only immutable paths and metadata cross the utility-task boundary. Exporters are task-local.
    func exportSnapshotInBackground(to destinationURL: URL, format: RollingCaptureExportFormat) async throws {
        guard storageAccessEnabled else { throw RollingCaptureRestoreError.noSnapshot }
        let source = latestFileURL
        let journal = journalURL
        let resolvedDestination = destinationURL.resolvingSymlinksInPath().standardizedFileURL
        guard ![source, journal].contains(where: {
            $0.resolvingSymlinksInPath().standardizedFileURL == resolvedDestination
        }) else { throw CocoaError(.fileWriteInvalidFileName) }
        let port = proxyPortProvider()
        let version = Bundle.main.marketingVersionOrDev
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let fileManager = FileManager()
            if format == .recording, Self.fileSize(at: journal, fileManager: fileManager) == 0 {
                guard fileManager.isReadableFile(atPath: source.path) else {
                    throw RollingCaptureRestoreError.noSnapshot
                }
                let staging = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString).recovery-copy")
                defer { try? fileManager.removeItem(at: staging) }
                try fileManager.copyItem(at: source, to: staging)
                try Task.checkCancellation()
                if fileManager.fileExists(atPath: destinationURL.path) {
                    _ = try fileManager.replaceItemAt(destinationURL, withItemAt: staging)
                } else {
                    try fileManager.moveItem(at: staging, to: destinationURL)
                }
                return
            }
            let sessions = try Self.readRecoverySnapshot(at: source, journalURL: journal, fileManager: FileManager())
            let envelope = SessionExportEnvelope(
                exportedAt: Date(), appVersion: version, proxyPort: port,
                recordingFidelity: .fullRecording, sessionCount: sessions.count, sessions: sessions
            )
            try Task.checkCancellation()
            switch format {
            case .recording:
                try JSONSessionExportService().exportAsRecording(envelope, to: destinationURL, fidelity: .fullRecording)
            case .har:
                try HARSessionExportService().export(envelope, to: destinationURL)
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Offers restore only when the live store is empty and the latest snapshot actually contains sessions.
    ///
    /// - Parameter sessionCount: Count of sessions currently loaded in the live store (not the snapshot).
    func shouldOfferRestoreOnLaunch(sessionCount: Int) -> RollingCaptureRestoreOffer? {
        guard sessionCount == 0 else { return nil }
        guard configuration.rollingCaptureAutoSaveEnabled else { return nil }
        guard configuration.rollingCaptureRestorePromptEnabled else { return nil }
        guard let offer = availableRestoreOffer() else { return nil }
        let dismissedAt = UserDefaults.standard.object(forKey: Self.dismissedRestoreKey) as? Date
        if let dismissedAt, dismissedAt >= offer.savedAt { return nil }
        return offer
    }

    /// Manual review ignores prompting and dismissal preferences, not snapshot availability.
    func availableRestoreOffer() -> RollingCaptureRestoreOffer? {
        guard storageAccessEnabled else { return nil }
        // Skip empty on-disk snapshots — restoring 0 sessions is a no-op and should not prompt.
        guard lastStatus.isAvailable,
              lastStatus.sessionCount > 0,
              let savedAt = lastStatus.savedAt else { return nil }
        guard fileManager.isReadableFile(atPath: latestFileURL.path)
            || fileManager.isReadableFile(atPath: journalURL.path) else { return nil }
        let fileSize = Self.fileSize(at: latestFileURL, fileManager: fileManager)
            + Self.fileSize(at: journalURL, fileManager: fileManager)
        return RollingCaptureRestoreOffer(
            savedAt: savedAt,
            sessionCount: lastStatus.sessionCount,
            fileURL: latestFileURL,
            fileSizeBytes: fileSize > 0 ? fileSize : nil
        )
    }

    func markRestoreDismissed() {
        guard storageAccessEnabled else { return }
        UserDefaults.standard.set(Date(), forKey: Self.dismissedRestoreKey)
    }

    private func subscribeToSessionChanges() {
        sessionStore.sessionChangesPublisher
            .sink { [weak self] change in
                guard let self else { return }
                switch change {
                case .appended(let session, _):
                    self.dirtyRevision &+= 1
                    self.sessionsSinceLastSave += 1
                    self.journalIO.append(session)
                    self.scheduleCheckpointDeadline()
                    if self.sessionsSinceLastSave >= self.configuration.rollingCaptureSaveSessionThreshold {
                        // Reset when the checkpoint is requested, not when it completes, so every
                        // subsequent append does not independently re-cross the threshold.
                        self.sessionsSinceLastSave = 0
                        self.requestAutoSave()
                    }
                case .updated(let session, _):
                    self.dirtyRevision &+= 1
                    // Updates share the first dirty change's deadline; continuous traffic must
                    // not postpone recovery indefinitely.
                    self.journalIO.append(session)
                    self.scheduleCheckpointDeadline()
                case .updatedBatch(let sessions, _):
                    self.dirtyRevision &+= 1
                    for session in sessions {
                        self.journalIO.append(session)
                    }
                    self.scheduleCheckpointDeadline()
                case .cleared:
                    self.captureGeneration &+= 1
                    self.dirtyRevision = 0
                    self.savedRevision = 0
                    self.retryAfter = nil
                    self.hasQueuedAutoSave = false
                    self.sessionsSinceLastSave = 0
                    self.cancelPendingSave()
                    self.journalIO.reset()
                    self.reportPersistenceError(nil)
                    self.lastStatus = RollingCaptureStatus(
                        isEnabled: self.configuration.rollingCaptureAutoSaveEnabled,
                        isAvailable: false, savedAt: nil, sessionCount: 0, fileURL: nil
                    )
                case .loaded:
                    self.captureGeneration &+= 1
                    self.refreshStatusFromDisk(sessionCount: self.sessionStore.sessions.count)
                case .removed, .bodiesStripped:
                    self.dirtyRevision &+= 1
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleCheckpointDeadline() {
        guard pendingSaveTask == nil, configuration.rollingCaptureAutoSaveEnabled else { return }
        let generation = timerGeneration
        let interval = max(Double(max(5, configuration.rollingCaptureSaveIntervalSeconds)), (retryAfter ?? now()) - now())
        let sleep = sleep
        pendingSaveTask = Task { [weak self] in
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled, let self, self.timerGeneration == generation else { return }
            self.pendingSaveTask = nil
            self.requestAutoSave()
        }
    }

    private func reportPersistenceError(_ message: String?) {
        guard lastStatus.persistenceError != message else { return }
        lastStatus.persistenceError = message
        onPersistenceError?(message)
    }

    private func cancelPendingSave() {
        timerGeneration &+= 1
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
    }

    private func makeEnvelope(sessions: [SessionRecord]) -> SessionExportEnvelope {
        SessionExportEnvelope(
            exportedAt: Date(),
            appVersion: Bundle.main.marketingVersionOrDev,
            proxyPort: proxyPortProvider(),
            recordingFidelity: .fullRecording,
            sessionCount: sessions.count,
            sessions: sessions
        )
    }

    private func refreshStatusFromDisk(sessionCount: Int? = nil) {
        let latestAttributes = try? fileManager.attributesOfItem(atPath: latestFileURL.path)
        let journalAttributes = try? fileManager.attributesOfItem(atPath: journalURL.path)
        let latestModified = latestAttributes?[.modificationDate] as? Date
        let journalModified = journalAttributes?[.modificationDate] as? Date
        let savedAt = [latestModified, journalModified].compactMap { $0 }.max()
        guard let savedAt else {
            lastStatus = RollingCaptureStatus(
                isEnabled: configuration.rollingCaptureAutoSaveEnabled,
                isAvailable: false,
                savedAt: nil,
                sessionCount: sessionCount ?? 0,
                fileURL: nil,
                persistenceError: lastStatus.persistenceError
            )
            return
        }
        // Prefer an explicit count from the caller; otherwise read the on-disk envelope header so
        // launch restore offers don't claim "0 sessions" when the file still holds captures.
        let resolvedCount = sessionCount
            ?? Self.readCheckpointMetadata(from: checkpointMetadataURL)?.sessionCount
            ?? Self.sessionCountInSnapshot(at: latestFileURL, fileManager: fileManager)
            ?? lastStatus.sessionCount
        lastStatus = RollingCaptureStatus(
            isEnabled: configuration.rollingCaptureAutoSaveEnabled,
            isAvailable: true,
            savedAt: savedAt,
            sessionCount: resolvedCount,
            fileURL: latestModified != nil ? latestFileURL : journalURL,
            persistenceError: lastStatus.persistenceError
        )
    }

    private func prepareStorageDirectory() {
        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        Self.removeStaleStagingFiles(
            in: storageDirectory,
            olderThan: Date().addingTimeInterval(-Self.staleStagingFileAge),
            fileManager: fileManager
        )
        Self.recoverLatestFromNewestCaptureIfNeeded(in: storageDirectory, fileManager: fileManager)
    }

    /// Reads `sessionCount` from a rolling `.jproxy` without loading session bodies.
    nonisolated private static func sessionCountInSnapshot(at url: URL, fileManager: FileManager) -> Int? {
        do {
            let root: [String: Any]
            if try RecordingContainer.format(at: url) == RecordingContainer.gzipFormat {
                root = try JSONSessionRecordingImportService.streamingHeaderRoot(from: url)
            } else {
                let jsonData = try RecordingContainer.unwrapFile(at: url)
                guard let legacyRoot = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    return nil
                }
                root = legacyRoot
            }
            return root["sessionCount"] as? Int
        } catch {
            return nil
        }
    }

    nonisolated private static func archiveCurrentLatest(
        in directory: URL,
        latestURL: URL,
        fileManager: FileManager
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: latestURL.path) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let attributes = try? fileManager.attributesOfItem(atPath: latestURL.path)
        let modifiedAt = attributes?[.modificationDate] as? Date ?? Date()
        let rotatedName = "capture-\(formatter.string(from: modifiedAt)).jproxy"
        let rotatedURL = directory.appendingPathComponent(rotatedName)
        if fileManager.fileExists(atPath: rotatedURL.path) {
            try fileManager.removeItem(at: rotatedURL)
        }
        try fileManager.moveItem(at: latestURL, to: rotatedURL)
        return rotatedURL
    }

    nonisolated private static func restoreArchivedLatestIfNeeded(
        _ archivedLatest: URL?,
        latestURL: URL,
        fileManager: FileManager
    ) {
        guard let archivedLatest,
              !fileManager.fileExists(atPath: latestURL.path),
              fileManager.fileExists(atPath: archivedLatest.path) else { return }
        try? fileManager.moveItem(at: archivedLatest, to: latestURL)
    }

    nonisolated private static func pruneSnapshots(
        in directory: URL,
        retentionCount: Int,
        maxDiskBytes: Int,
        fileManager: FileManager
    ) throws {
        let captures = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]))?
            .filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "jproxy" }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate > rDate
            } ?? []
        var retainedCaptures = captures
        if captures.count > retentionCount {
            for url in captures.dropFirst(retentionCount) {
                try? fileManager.removeItem(at: url)
            }
            retainedCaptures = Array(captures.prefix(retentionCount))
        }
        var totalSize = 0
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            totalSize += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        while totalSize > maxDiskBytes, let oldest = retainedCaptures.popLast() {
            totalSize -= (try? oldest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? fileManager.removeItem(at: oldest)
        }
    }

    nonisolated private static func recoverLatestFromNewestCaptureIfNeeded(
        in directory: URL,
        fileManager: FileManager
    ) {
        let latestURL = directory.appendingPathComponent(Self.latestFileName)
        guard !fileManager.fileExists(atPath: latestURL.path) else { return }
        let newestCapture = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ))?
            .filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "jproxy" }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }
        guard let newestCapture else { return }
        try? fileManager.moveItem(at: newestCapture, to: latestURL)
    }

    nonisolated private static func removeStaleStagingFiles(
        in directory: URL,
        olderThan cutoff: Date,
        fileManager: FileManager
    ) {
        let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        )
        for url in files ?? [] {
            let name = url.lastPathComponent
            guard name.hasSuffix(".recording-stage") || name.hasSuffix(SessionJournalWriter.stagingSuffix) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    nonisolated private static func writeCheckpointMetadata(sessionCount: Int, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadata = RollingCaptureCheckpointMetadata(
            version: 1,
            savedAt: Date(),
            sessionCount: sessionCount
        )
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    nonisolated private static func readCheckpointMetadata(
        from url: URL
    ) -> RollingCaptureCheckpointMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RollingCaptureCheckpointMetadata.self, from: data)
    }

    nonisolated private static func fileSize(at url: URL, fileManager: FileManager) -> Int {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}

struct RollingCaptureRestoreOffer: Equatable, Identifiable, Sendable {
    let id = UUID()
    var savedAt: Date
    var sessionCount: Int
    var fileURL: URL
    var fileSizeBytes: Int? = nil
}

enum RollingCaptureExportFormat: Equatable, Sendable {
    case recording
    case har
}

enum RollingCaptureRestoreError: Error, LocalizedError, Equatable, Sendable {
    case noSnapshot
    case alreadyRestoring
    case captureChanged

    var errorDescription: String? {
        switch self {
        case .noSnapshot: return "No readable saved capture is available."
        case .alreadyRestoring: return "A restore is already in progress."
        case .captureChanged: return "Capture changed during restore. Pause capture and retry; newer traffic was not replaced."
        }
    }
}
