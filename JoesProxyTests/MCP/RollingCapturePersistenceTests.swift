import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class RollingCapturePersistenceTests: XCTestCase {
    func testStorageIsolationPreventsJournalingAndRecoveryAccess() async throws {
        let store = InMemorySessionStore()
        let configuration = MCPSelfValidationAppConfiguration()
        XCTAssertTrue(configuration.rollingCaptureAutoSaveEnabled)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/RecoveryIsolation-\(UUID().uuidString)")
        let coordinator = RollingCapturePersistenceCoordinator(
            sessionStore: store, configuration: configuration, proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory, storageAccessEnabled: false
        )
        let session = makeSession(index: 1)
        store.append(session)
        store.update(session)
        store.load(sessions: [session])
        await coordinator.flushNow()
        store.clear()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(coordinator.lastStatus.isEnabled)
        XCTAssertNil(coordinator.availableRestoreOffer())
        XCTAssertEqual(coordinator.snapshotWriteCount, 0)
        XCTAssertThrowsError(try coordinator.restoreLatestSnapshot()) {
            XCTAssertEqual($0 as? RollingCaptureRestoreError, .noSnapshot)
        }
        XCTAssertThrowsError(try coordinator.copyLatestSnapshot(to: directory.appendingPathComponent("export.jproxy"))) {
            XCTAssertEqual($0 as? RollingCaptureRestoreError, .noSnapshot)
        }
        do {
            _ = try await coordinator.restoreLatestSnapshotInBackground()
            XCTFail("Isolated coordinator must not read recovery storage")
        } catch {
            XCTAssertEqual(error as? RollingCaptureRestoreError, .noSnapshot)
        }
        do {
            try await coordinator.exportSnapshotInBackground(to: directory.appendingPathComponent("export.har"), format: .har)
            XCTFail("Isolated coordinator must not export recovery storage")
        } catch {
            XCTAssertEqual(error as? RollingCaptureRestoreError, .noSnapshot)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRestoreRejectsStoreChangesWhileLoaderIsSuspended() async throws {
        let store = InMemorySessionStore()
        let (coordinator, directory) = makeCoordinator(threshold: 10_000, sessionStore: store)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = makeSession(index: 0)
        for change in 0..<3 {
            do {
                _ = try await coordinator.restoreSnapshot {
                    switch change {
                    case 0: store.append(sample)
                    case 1: store.load(sessions: [sample])
                    default: store.clear()
                    }
                    return [sample]
                }
                XCTFail("Store changes must invalidate restore")
            } catch {
                XCTAssertEqual(error as? RollingCaptureRestoreError, .captureChanged)
            }
        }
    }
    func testOversizedCompactionRequiresCooldownAndMeaningfulChange() {
        var policy = JournalCompactionPolicy()
        let bytes = 2_000 * 1_048_576
        XCTAssertTrue(policy.shouldCompact(bytes: bytes, count: 100, now: 0))
        policy.begin(bytes: bytes, count: 100, now: 0)
        XCTAssertFalse(policy.shouldCompact(bytes: bytes * 2, count: 50, now: 899))
        XCTAssertFalse(policy.shouldCompact(bytes: bytes, count: 100, now: 900))
        XCTAssertTrue(policy.shouldCompact(bytes: bytes, count: 99, now: 900))
        XCTAssertTrue(policy.shouldCompact(bytes: bytes + bytes / 4, count: 100, now: 900))
        policy.completed(bytes: bytes / 2)
        XCTAssertFalse(policy.shouldCompact(bytes: bytes / 2, count: 100, now: 1800))
    }

    func testEveryCompactionFailureReleasesBufferAndPreservesJournal() throws {
        for stage in SessionJournalWriter.CompactionStage.allCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("journal.jsonl")
            let writer = SessionJournalWriter(journalURL: url, beforeCompactionStage: {
                if $0 == stage { throw CocoaError(.fileWriteUnknown) }
            })
            let first = makeSession(index: 1)
            let second = makeSession(index: 2)
            try writer.append(session: first)
            let generation = writer.beginCompaction()
            XCTAssertThrowsError(try writer.replaceContents(with: [first], generation: generation))
            XCTAssertFalse(writer.isBufferingCompaction, "\(stage)")
            try writer.append(session: second)
            XCTAssertEqual(SessionJournalReader.readSessions(from: url).map(\.id), [first.id, second.id])
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasSuffix(SessionJournalWriter.stagingSuffix) })
        }
    }

    func testStaleCompactionCannotClearNewGenerationBuffer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SessionJournalWriter(journalURL: directory.appendingPathComponent("journal.jsonl"))
        let first = makeSession(index: 1)
        let old = writer.beginCompaction()
        writer.reset()
        let current = writer.beginCompaction()
        XCTAssertThrowsError(try writer.replaceContents(with: [first], generation: old))
        XCTAssertTrue(writer.isBufferingCompaction)
        try writer.replaceContents(with: [first], generation: current)
        XCTAssertFalse(writer.isBufferingCompaction)
    }

    func testRecoveryMergePreservesOrderDuplicatesAndLatestUpdate() {
        let first = makeSession(index: 1)
        let second = makeSession(index: 2)
        var updated = first
        updated.state = .failed
        let merged = RollingCapturePersistenceCoordinator.mergeRecovery(
            base: [first, first], journal: [second, updated]
        )
        XCTAssertEqual(merged.map(\.id), [first.id, first.id, second.id])
        XCTAssertEqual(merged[0].state, .failed)
        XCTAssertEqual(merged[1].state, first.state)
    }

    func testLargeRecoveryMergePerformance() {
        let base = (0..<50_000).map { makeSession(index: $0) }
        let journal = (0..<200_000).map { base[$0 % base.count] }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let result = RollingCapturePersistenceCoordinator.mergeRecovery(base: base, journal: journal)
            XCTAssertEqual(result.count, base.count)
            XCTAssertEqual(result.last?.id, base.last?.id)
        }
    }

    func testContinuousUpdatesKeepOneCheckpointDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        configuration.rollingCaptureSaveSessionThreshold = 10_000
        let store = InMemorySessionStore()
        let gate = CheckpointSleepGate()
        let coordinator = RollingCapturePersistenceCoordinator(
            sessionStore: store, configuration: configuration, proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory, sleep: { _ in await gate.wait() }
        )
        let session = makeSession(index: 1)
        store.append(session)
        for _ in 0..<100 { store.update(session) }
        for _ in 0..<100 {
            if await gate.count > 0 { break }
            await Task.yield()
        }
        let scheduled = await gate.count
        XCTAssertEqual(scheduled, 1)
        await gate.release()
        let deadline = ContinuousClock.now + .seconds(5)
        while coordinator.snapshotWriteCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(coordinator.snapshotWriteCount, 1)
        XCTAssertEqual(try coordinator.restoreLatestSnapshot().count, 1)
    }
    func testFailedCheckpointRetainsDirtyWorkAndDefersRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        configuration.rollingCaptureSaveSessionThreshold = 1
        let store = InMemorySessionStore()
        let gate = CheckpointSleepGate()
        var time: TimeInterval = 0
        let coordinator = RollingCapturePersistenceCoordinator(
            sessionStore: store, configuration: configuration, proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory, now: { time }, sleep: { _ in await gate.wait() }
        )
        try FileManager.default.createDirectory(at: coordinator.checkpointMetadataURL, withIntermediateDirectories: true)
        store.append(makeSession(index: 1))
        try await waitUntilIdle(coordinator)
        XCTAssertEqual(coordinator.snapshotWriteCount, 0)
        store.append(makeSession(index: 2))
        XCTAssertFalse(coordinator.isWritingSnapshot, "Failed checkpoints must not retry on every append")
        try FileManager.default.removeItem(at: coordinator.checkpointMetadataURL)
        time = 10_000
        for _ in 0..<100 { await Task.yield() }
        await gate.release()
        let deadline = ContinuousClock.now + .seconds(5)
        while coordinator.snapshotWriteCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(coordinator.snapshotWriteCount, 1)
        XCTAssertEqual(try coordinator.restoreLatestSnapshot().count, 2)
    }

    func testDisablingAutoSaveBeforeDeadlineDoesNotCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        configuration.rollingCaptureSaveSessionThreshold = 10_000
        let store = InMemorySessionStore()
        let gate = CheckpointSleepGate()
        let coordinator = RollingCapturePersistenceCoordinator(
            sessionStore: store, configuration: configuration, proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory, sleep: { _ in await gate.wait() }
        )
        store.append(makeSession(index: 1))
        for _ in 0..<100 { await Task.yield() }
        configuration.rollingCaptureAutoSaveEnabled = false
        await gate.release()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(coordinator.snapshotWriteCount, 0)
        XCTAssertFalse(coordinator.isWritingSnapshot)
    }

    func testRollingSaveAndRestoreRoundTrip() async throws {
        let defaults = UserDefaults(suiteName: "RollingCapture-\(UUID().uuidString)")!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.rollingCaptureAutoSaveEnabled = true
        let sessionStore = InMemorySessionStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollingCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = RollingCapturePersistenceCoordinator(
            sessionStore: sessionStore,
            configuration: configuration,
            fileManager: .default,
            proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory
        )
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/v1/items",
                headers: [HTTPHeaderField(name: "Accept", value: "application/json")],
                bodyData: nil,
                bodySize: 0
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: Data("{\"ok\":true}".utf8),
                bodySize: 11
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
        sessionStore.append(session)
        await coordinator.flushSnapshot(sessions: [session])

        XCTAssertTrue(coordinator.lastStatus.isAvailable)
        XCTAssertEqual(coordinator.lastStatus.sessionCount, 1)

        let restored = try coordinator.restoreLatestSnapshot()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.request.path, "/v1/items")
        XCTAssertEqual(restored.first?.response?.statusCode, 200)
        try? FileManager.default.removeItem(at: directory)
    }

    func testCaptureMarkerInsertsReadableRequestBody() throws {
        let sessionStore = InMemorySessionStore()
        let markerService = CaptureMarkerService(sessionStore: sessionStore)
        let record = try markerService.insertUserMarker(
            name: "repro_start",
            detail: "before playback",
            label: "AM-3",
            captureEpoch: .initial
        )
        XCTAssertTrue(CaptureMarkerConstants.isMarkerRecord(record))
        XCTAssertEqual(record.request.method, CaptureMarkerConstants.method)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(CaptureMarkerPayload.self, from: try XCTUnwrap(record.request.bodyData))
        XCTAssertEqual(payload.name, "repro_start")
        XCTAssertEqual(payload.reason, "user_created")
        XCTAssertEqual(payload.detail, "before playback")
    }

    func testClearInsertsSystemMarkerAndBumpsEpoch() throws {
        let sessionStore = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: sessionStore)
        let markerService = CaptureMarkerService(sessionStore: sessionStore)
        snapshot.configureMarkerService(markerService)
        let priorEpoch = snapshot.captureEpoch

        sessionStore.append(
            SessionRecord(
                request: CapturedRequest(
                    method: "GET",
                    scheme: .http,
                    host: "example.com",
                    port: 80,
                    path: "/",
                    headers: [],
                    bodyData: nil,
                    bodySize: 0
                ),
                response: nil,
                state: .pending,
                timing: SessionTiming(startedAt: Date(), completedAt: nil)
            )
        )
        sessionStore.clear()

        XCTAssertNotEqual(snapshot.captureEpoch, priorEpoch)
        XCTAssertEqual(snapshot.epochMetadata.lastEpochChangeReason, "capture_cleared")
        XCTAssertEqual(snapshot.epochMetadata.previousCaptureEpoch, priorEpoch)
        XCTAssertEqual(sessionStore.sessions.count, 1)
        XCTAssertTrue(CaptureMarkerConstants.isMarkerRecord(try XCTUnwrap(sessionStore.sessions.first)))
    }

    // MARK: - Save-stampede regression coverage
    //
    // These guard the blocker bug diagnosed from a 44-minute Instruments capture
    // (memlog/Instruments-Results/JoesProxyNotRendering): the rolling auto-save reset its
    // session counter only when a write *completed*, not when it was *requested*. A full-store
    // `.jproxy` export takes seconds; every session change arriving during that window still saw
    // the counter at/above threshold and spawned its own unguarded `Task { await flushNow() }`.
    // Dozens of concurrent exports saturated the CPU and starved the proxy's NIO event loops, so
    // connections were accepted but never parsed into sessions — traffic visible in the raw
    // console log never reached the session store, let alone the UI.

    private func makeSession(index: Int, bodyBytes: Int = 0) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "burst-\(index).example.com",
                port: 443,
                path: "/\(index)",
                headers: [],
                bodyData: nil,
                bodySize: 0
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [],
                bodyData: bodyBytes > 0 ? Data(repeating: 0x41, count: bodyBytes) : nil,
                bodySize: bodyBytes
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    private func makeCoordinator(
        threshold: Int,
        sessionStore: InMemorySessionStore = InMemorySessionStore()
    ) -> (RollingCapturePersistenceCoordinator, URL) {
        let defaults = UserDefaults(suiteName: "RollingBurst-\(UUID().uuidString)")!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.rollingCaptureAutoSaveEnabled = true
        configuration.rollingCaptureSaveSessionThreshold = threshold
        // Long enough that the debounce timer never fires mid-test and adds a second, untracked
        // trigger path on top of the one under test.
        configuration.rollingCaptureSaveIntervalSeconds = 3600
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollingBurst-\(UUID().uuidString)", isDirectory: true)
        let coordinator = RollingCapturePersistenceCoordinator(
            sessionStore: sessionStore,
            configuration: configuration,
            proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory
        )
        return (coordinator, directory)
    }

    /// Rapidly crosses the auto-save threshold many times in a single synchronous burst — no
    /// `await` between appends, so nothing else can run until the burst finishes. This is the
    /// worst case the original bug hit: many session changes arriving faster than a single export
    /// can complete.
    ///
    /// Regardless of write speed, the fix's `activeFlush` guard is checked synchronously inside
    /// `requestAutoSave()`, so it is not a matter of luck that this test doesn't flake: only the
    /// very first threshold crossing in the burst can find no write in flight and start one; every
    /// later crossing in the same burst is coalesced before any write begins.
    func testRapidSessionBurstNeverOverlapsAndCoalescesIntoOneWrite() async throws {
        let sessionStore = InMemorySessionStore()
        let (coordinator, directory) = makeCoordinator(threshold: 3, sessionStore: sessionStore)
        defer { try? FileManager.default.removeItem(at: directory) }

        let totalSessions = 12
        for index in 0..<totalSessions {
            sessionStore.append(makeSession(index: index))
        }

        // Assertable *before* any write has had a chance to run: proves the counter is reset the
        // moment the threshold is crossed, not left pinned at/above threshold until a write
        // finishes (the other half of the original bug — every subsequent append while the
        // counter sat >= threshold re-triggered a save).
        XCTAssertEqual(coordinator.sessionsSinceLastSave, 0)
        XCTAssertTrue(coordinator.isWritingSnapshot, "the first threshold crossing must have started a write")

        try await waitUntilIdle(coordinator)

        XCTAssertLessThanOrEqual(
            coordinator.peakConcurrentSnapshotWrites, 1,
            "a burst of session changes must never produce overlapping full-store exports"
        )
        XCTAssertEqual(
            coordinator.snapshotWriteCount, 1,
            "every threshold crossing in the same burst must coalesce into a single export"
        )

        let restored = try coordinator.restoreLatestSnapshot()
        XCTAssertEqual(restored.count, totalSessions, "the coalesced write must reflect every session from the burst")
    }

    /// Direct, minimal check of the reset-timing fix in isolation: with `threshold == 1`, the very
    /// next append must show the counter already back at zero, synchronously, before the export
    /// has run at all. Under the pre-fix code the counter stayed at/above threshold until the
    /// write *completed*, so this would have observed `1`, not `0`.
    func testSessionCounterResetsWhenThresholdCrossesNotWhenWriteCompletes() throws {
        let sessionStore = InMemorySessionStore()
        let (coordinator, directory) = makeCoordinator(threshold: 1, sessionStore: sessionStore)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(coordinator.sessionsSinceLastSave, 0)
        sessionStore.append(makeSession(index: 0))

        XCTAssertEqual(
            coordinator.sessionsSinceLastSave, 0,
            "crossing the threshold must reset the counter immediately, not after the write finishes"
        )
        XCTAssertTrue(coordinator.isWritingSnapshot, "crossing the threshold must have started a write")
    }

    func testAutoSaveRequestedWhileBusyCoalescesIntoASingleTrailingWriteWithoutOverlap() async throws {
        let sessionStore = InMemorySessionStore()
        let (coordinator, directory) = makeCoordinator(threshold: 1, sessionStore: sessionStore)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A sizeable payload so the background export has measurable wall-clock duration, giving a
        // realistic (though not load-bearing — see below) chance of catching a write actually
        // in flight rather than merely scheduled.
        for index in 0..<200 {
            sessionStore.append(makeSession(index: index, bodyBytes: 20_000))
        }

        sessionStore.append(makeSession(index: 9000, bodyBytes: 20_000))
        XCTAssertTrue(coordinator.isWritingSnapshot)

        // Give the scheduler a turn so the in-flight write can actually start running (as opposed
        // to merely being scheduled) before the second, overlapping request arrives.
        await Task.yield()
        sessionStore.append(makeSession(index: 9001, bodyBytes: 20_000))

        try await waitUntilIdle(coordinator)

        // The hard invariant regardless of exact scheduler timing: no matter whether the second
        // request landed before the first write started (coalesced into it) or while it was
        // already running (queued as a trailing follow-up), the two writes must never overlap.
        XCTAssertLessThanOrEqual(coordinator.peakConcurrentSnapshotWrites, 1)
        XCTAssertGreaterThanOrEqual(coordinator.snapshotWriteCount, 1)
        XCTAssertLessThanOrEqual(coordinator.snapshotWriteCount, 2)

        let restored = try coordinator.restoreLatestSnapshot()
        XCTAssertEqual(
            restored.count, sessionStore.sessions.count,
            "the last journal checkpoint must reflect the full session list, not a stale count"
        )
    }

    func testAutomaticCheckpointUsesJournalWithoutCreatingFullRecordingCopies() async throws {
        let sessionStore = InMemorySessionStore()
        let (coordinator, directory) = makeCoordinator(threshold: 1, sessionStore: sessionStore)
        defer { try? FileManager.default.removeItem(at: directory) }

        sessionStore.append(makeSession(index: 1, bodyBytes: 1_024))
        try await waitUntilIdle(coordinator)

        XCTAssertTrue(FileManager.default.fileExists(atPath: coordinator.journalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.latestFileURL.path))
        let rotatedFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("capture-") }
        XCTAssertTrue(rotatedFiles.isEmpty)
        XCTAssertEqual(try coordinator.restoreLatestSnapshot().count, 1)
    }

    func testExplicitSnapshotsArchivePreviousLatestInsteadOfCopyingNewLatest() async throws {
        let sessionStore = InMemorySessionStore()
        let (coordinator, directory) = makeCoordinator(threshold: 10_000, sessionStore: sessionStore)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeSession(index: 1)
        await coordinator.flushSnapshot(sessions: [first])
        let firstLatestData = try Data(contentsOf: coordinator.latestFileURL)

        let second = makeSession(index: 2)
        await coordinator.flushSnapshot(sessions: [first, second])

        let captures = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "jproxy" }
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(captures.first)), firstLatestData)
        XCTAssertNotEqual(try Data(contentsOf: coordinator.latestFileURL), firstLatestData)
    }

    func testInitializationRemovesOnlyStaleStagingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollingStaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let staleRecording = directory.appendingPathComponent(".latest.jproxy.old.recording-stage")
        let staleJournal = directory.appendingPathComponent(".journal.jsonl.old.journal-stage")
        let recentRecording = directory.appendingPathComponent(".latest.jproxy.recent.recording-stage")
        FileManager.default.createFile(atPath: staleRecording.path, contents: Data([1]))
        FileManager.default.createFile(atPath: staleJournal.path, contents: Data([2]))
        FileManager.default.createFile(atPath: recentRecording.path, contents: Data([3]))
        let oldDate = Date().addingTimeInterval(-(RollingCapturePersistenceCoordinator.staleStagingFileAge + 60))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleRecording.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleJournal.path)

        _ = RollingCapturePersistenceCoordinator(
            sessionStore: InMemorySessionStore(),
            configuration: UserDefaultsAppConfiguration(
                userDefaults: UserDefaults(suiteName: "RollingStaging-\(UUID().uuidString)")!
            ),
            proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRecording.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleJournal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentRecording.path))
    }

    func testJournalCompactionPreservesSessionsAppendedAfterSnapshotCapture() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollingCompaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let journalURL = directory.appendingPathComponent("journal.jsonl")
        let writer = SessionJournalWriter(journalURL: journalURL)
        let retainedSession = makeSession(index: 1)
        let appendedDuringCompaction = makeSession(index: 2)
        try writer.append(session: retainedSession)

        let generation = writer.beginCompaction()
        try writer.append(session: appendedDuringCompaction)
        try writer.replaceContents(with: [retainedSession], generation: generation)

        let restored = SessionJournalReader.readSessions(from: journalURL)
        XCTAssertEqual(restored.map(\.id), [retainedSession.id, appendedDuringCompaction.id])
    }

    /// Polls `isWritingSnapshot` until it clears, rather than a fixed sleep, so the test is exact
    /// on fast machines and not flaky on slow/loaded ones.
    private func waitUntilIdle(
        _ coordinator: RollingCapturePersistenceCoordinator,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while coordinator.isWritingSnapshot {
            guard Date() < deadline else {
                XCTFail("Rolling capture snapshot write did not finish within \(timeout)s")
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testRestoreOfferRequiresEmptyStoreAndAvailableSnapshot() async throws {
        let defaults = UserDefaults(suiteName: "RollingOffer-\(UUID().uuidString)")!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.rollingCaptureAutoSaveEnabled = true
        let sessionStore = InMemorySessionStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollingOffer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = RollingCapturePersistenceCoordinator(
            sessionStore: sessionStore,
            configuration: configuration,
            proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory
        )
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "cdn.example.com",
                port: 443,
                path: "/a",
                headers: [],
                bodyData: nil,
                bodySize: 0
            ),
            response: nil,
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
        await coordinator.flushSnapshot(sessions: [session])
        XCTAssertNotNil(coordinator.shouldOfferRestoreOnLaunch(sessionCount: 0))
        XCTAssertNil(coordinator.shouldOfferRestoreOnLaunch(sessionCount: 1))
        configuration.rollingCaptureRestorePromptEnabled = false
        XCTAssertNil(coordinator.shouldOfferRestoreOnLaunch(sessionCount: 0))
        XCTAssertNotNil(coordinator.availableRestoreOffer())
        XCTAssertTrue(configuration.rollingCaptureAutoSaveEnabled)
        configuration.rollingCaptureRestorePromptEnabled = true
        coordinator.markRestoreDismissed()
        XCTAssertNil(coordinator.shouldOfferRestoreOnLaunch(sessionCount: 0))
        XCTAssertNotNil(coordinator.availableRestoreOffer(), "Manual review survives per-snapshot dismissal.")
        configuration.rollingCaptureAutoSaveEnabled = false
        XCTAssertNotNil(coordinator.availableRestoreOffer(), "Turning off future checkpoints does not hide saved data.")
    }

    /// An on-disk rolling snapshot with zero sessions must not prompt — restore would be a no-op.
    func testRestoreOfferSkippedWhenSnapshotHasZeroSessions() async throws {
        let defaults = UserDefaults(suiteName: "RollingOfferEmpty-\(UUID().uuidString)")!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.rollingCaptureAutoSaveEnabled = true
        let sessionStore = InMemorySessionStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollingOfferEmpty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // `flushSnapshot` refuses empty arrays — write a zero-session envelope directly, then
        // construct a coordinator so `refreshStatusFromDisk` loads the header count.
        let emptyEnvelope = SessionExportEnvelope(
            exportedAt: Date(),
            appVersion: "test",
            proxyPort: 9090,
            recordingFidelity: .fullRecording,
            sessionCount: 0,
            sessions: []
        )
        let latestURL = directory.appendingPathComponent(RollingCapturePersistenceCoordinator.latestFileName)
        try JSONSessionExportService().exportAsRecording(emptyEnvelope, to: latestURL, fidelity: .fullRecording)

        let coordinator = RollingCapturePersistenceCoordinator(
            sessionStore: sessionStore,
            configuration: configuration,
            proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory
        )
        XCTAssertTrue(coordinator.lastStatus.isAvailable)
        XCTAssertEqual(coordinator.lastStatus.sessionCount, 0)
        XCTAssertNil(coordinator.shouldOfferRestoreOnLaunch(sessionCount: 0))
    }

    /// Cold launch must read the on-disk header count so a non-empty snapshot still offers restore.
    func testRestoreOfferUsesOnDiskSessionCountAfterColdLaunch() async throws {
        let defaults = UserDefaults(suiteName: "RollingOfferCold-\(UUID().uuidString)")!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.rollingCaptureAutoSaveEnabled = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollingOfferCold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = RollingCapturePersistenceCoordinator(
            sessionStore: InMemorySessionStore(),
            configuration: configuration,
            proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory
        )
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "cdn.example.com",
                port: 443,
                path: "/a",
                headers: [],
                bodyData: nil,
                bodySize: 0
            ),
            response: nil,
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
        await writer.flushSnapshot(sessions: [session])

        let relaunched = RollingCapturePersistenceCoordinator(
            sessionStore: InMemorySessionStore(),
            configuration: configuration,
            proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory
        )
        XCTAssertEqual(relaunched.lastStatus.sessionCount, 1)
        let offer = try XCTUnwrap(relaunched.shouldOfferRestoreOnLaunch(sessionCount: 0))
        XCTAssertEqual(offer.sessionCount, 1)
    }
}

private actor CheckpointSleepGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0
    func wait() async {
        count += 1
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
}
