//
//  CaptureWorkspaceSelectionPinningTests.swift
//  JoesProxyTests
//
//  Static/Paused must keep the table genuinely live — new rows keep appending as capture
//  continues — while guaranteeing the selected session is never evicted from the visible slice.
//  A prior fix (`freezeWindow()`/`frozenTotalCount`, since removed) solved the eviction problem
//  by freezing the entire displayed array, which also stopped new rows from ever appearing —
//  this file replaces `CaptureWorkspaceWindowFreezeTests.swift`, whose two tests directly
//  asserted that now-wrong "must not grow" contract. The correct fix is selection-pinning: the
//  live arrays are never truncated, and only the one selected session is pinned back into the
//  windowed display if it would otherwise fall outside the visible slice.
//

import XCTest
@testable import JoesProxy

@MainActor
final class CaptureWorkspaceSelectionPinningTests: XCTestCase {
    func testRemovingSelectedFilteredSessionInvalidatesDisplayedSummaryCache() async throws {
        let store = InMemorySessionStore()
        let selected = Self.makeSession(path: "/selected-item")
        let sibling = Self.makeSession(path: "/sibling-item")
        store.append(selected)
        store.append(sibling)
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.searchText = "selected-item"
        try await waitUntil("filter settles") { workspace.displayedSummaries.map(\.id) == [selected.id] }
        workspace.selectedSessionID = selected.id
        _ = workspace.displayedSummaries
        store.remove(ids: [selected.id])
        try await waitUntil("removed selection leaves filtered view") {
            workspace.displayedSummaries.isEmpty && workspace.filteredSessions.isEmpty
        }
        workspace.searchText = ""
        try await waitUntil("sibling remains") { workspace.displayedSummaries.map(\.id) == [sibling.id] }
    }

    func testStaticInspectionKeepsTableGrowingWithNewSessions() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        for i in 0..<5 {
            store.append(Self.makeSession(path: "/before-\(i)"))
        }
        try await waitUntil("initial recompute settles") {
            !workspace.isRecomputing && workspace.displayedSummaries.count == 5
        }

        // Select a session — the "static inspection, no explicit Follow Live toggle" case.
        workspace.selectedSessionID = workspace.filteredSessionIDs.first

        for i in 0..<5 {
            store.append(Self.makeSession(path: "/after-selection-\(i)"))
        }
        try await waitUntil("recompute processes the appended sessions") {
            !workspace.isRecomputing
                && workspace.filteredSessions.count == 10
                && workspace.sessionSummaries.count == 10
        }

        // Content must never freeze — this is the whole point of the fix.
        XCTAssertEqual(workspace.displayedSummaries.count, 10, "new sessions must keep appearing while a selection is held")
        XCTAssertEqual(workspace.displayedSessions.count, 10, "new sessions must keep appearing while a selection is held")
    }

    func testSelectedOlderSessionStaysVisibleViaPinningAcrossManyNewArrivals() async throws {
        // Construct against an empty store, then append — `CaptureWorkspaceViewModel.init` seeds
        // `visibleLimit` from whatever's already in the store at construction time
        // (`SessionTablePresentation.initialVisibleLimit(for: store.sessions.count)`), so
        // constructing with sessions already present would seed a small limit instead of the
        // real 500-row default and produce a false pass/fail on the windowing math below.
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.isCaptureActive = true
        let watchedSession = Self.makeSession(path: "/watched")
        store.append(watchedSession)
        for i in 0..<50 {
            store.append(Self.makeSession(path: "/filler-\(i)"))
        }
        try await waitUntil("initial recompute settles") {
            !workspace.isRecomputing && workspace.filteredSessions.count == 51
        }
        workspace.selectedSessionID = watchedSession.id

        // Flood in far more than the table's live-capture windowing limit (500).
        for i in 0..<600 {
            store.append(Self.makeSession(path: "/flood-\(i)"))
        }
        try await waitUntil("recompute processes the flood", timeout: 5) {
            !workspace.isRecomputing && workspace.filteredSessions.count == 651
        }

        XCTAssertTrue(
            workspace.displayedSessions.contains { $0.id == watchedSession.id },
            "windowing must not evict a selected session just because more traffic arrived"
        )
        XCTAssertEqual(
            workspace.displayedSessions.count, 501,
            "the window itself must still show 500 rows plus exactly one pinned row — not stay frozen at the original snapshot"
        )
        XCTAssertEqual(workspace.filteredSessions.count, 651, "sanity: underlying data is never truncated")
    }

    func testPinDoesNotDuplicateWhenSelectionNaturallyInWindow() async throws {
        // Construct against an empty store first — see the comment in
        // `testSelectedOlderSessionStaysVisibleViaPinningAcrossManyNewArrivals`.
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.isCaptureActive = true
        for i in 0..<600 {
            store.append(Self.makeSession(path: "/item-\(i)"))
        }
        try await waitUntil("initial recompute settles") {
            !workspace.isRecomputing && workspace.filteredSessions.count == 600
        }

        // Select the newest session — already naturally inside the visible window.
        workspace.selectedSessionID = workspace.filteredSessionIDs.last

        XCTAssertEqual(workspace.displayedSessions.count, 500, "selection already in-window must not add a pinned row")
        XCTAssertEqual(
            workspace.displayedSessions.filter { $0.id == workspace.selectedSessionID }.count, 1,
            "selection must appear exactly once"
        )
    }

    func testHiddenSessionCountExcludesPinnedRow() async throws {
        // Construct against an empty store first — see the comment in
        // `testSelectedOlderSessionStaysVisibleViaPinningAcrossManyNewArrivals`.
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.isCaptureActive = true
        let watchedSession = Self.makeSession(path: "/watched")
        store.append(watchedSession)
        for i in 0..<650 {
            store.append(Self.makeSession(path: "/item-\(i)"))
        }
        try await waitUntil("initial recompute settles", timeout: 5) {
            !workspace.isRecomputing && workspace.filteredSessions.count == 651
        }
        workspace.selectedSessionID = watchedSession.id

        // 651 total, 500 visible naturally, 1 pinned back in — 150 genuinely hidden, not 151.
        XCTAssertEqual(workspace.hiddenSessionCount, 150)
    }

    func testSelectionDroppedFromStoreIsNeverPinned() async throws {
        // See the comment in `testSelectedOlderSessionStaysVisibleViaPinningAcrossManyNewArrivals`
        // — construct against an empty store so `visibleLimit` seeds to the real 500 default.
        let store = InMemorySessionStore(
            retentionPolicy: .keepLastSessions(600)
        )
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.isCaptureActive = true
        let watchedSession = Self.makeSession(path: "/watched")
        store.append(watchedSession)
        try await waitUntil("initial recompute settles") {
            !workspace.isRecomputing && workspace.filteredSessions.count == 1
        }
        workspace.selectedSessionID = watchedSession.id

        // Push well past the retention cap so the watched session is evicted from the store,
        // not just windowed out of the display.
        for i in 0..<650 {
            store.append(Self.makeSession(path: "/item-\(i)"))
        }
        try await waitUntil("retention evicts the watched session", timeout: 5) {
            !workspace.isRecomputing && !workspace.filteredSessionIDs.contains(watchedSession.id)
        }

        // No phantom pinned row: exactly the windowed count, nothing extra, no crash.
        XCTAssertEqual(workspace.displayedSessions.count, 500)
        XCTAssertEqual(workspace.hiddenSessionCount, 100)
    }

    func testCaptureStopRevealsAllSessions() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.isCaptureActive = true
        for i in 0..<600 {
            store.append(Self.makeSession(path: "/item-\(i)"))
        }
        try await waitUntil("initial recompute settles") {
            !workspace.isRecomputing && workspace.filteredSessions.count == 600
        }

        XCTAssertGreaterThan(workspace.hiddenSessionCount, 0)
        XCTAssertEqual(workspace.displayedSessions.count, 500)

        workspace.isCaptureActive = false

        XCTAssertEqual(workspace.hiddenSessionCount, 0)
        XCTAssertEqual(workspace.displayedSessions.count, 600, "stopping capture must reveal every retained session")
    }

    func testHighThroughputBurstMaintainsStrictIDUniquenessAcrossAllLayers() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.isCaptureActive = true

        let burstCount = 200
        var generatedSessions: [SessionRecord] = []
        for i in 0..<burstCount {
            let session = Self.makeSession(path: "/api/burst/\(i % 10)/segment-\(i)")
            generatedSessions.append(session)
            store.append(session)
        }

        try await waitUntil("store settles after burst") {
            !workspace.isRecomputing && workspace.sessionSummaries.count == burstCount
        }

        // 1. Assert SessionStore uniqueness
        let storeSessions = store.sessions
        XCTAssertEqual(storeSessions.count, burstCount)
        XCTAssertEqual(Set(storeSessions.map(\.id)).count, burstCount, "SessionStore must have 100% unique IDs")

        // 2. Assert Workspace Filtered IDs uniqueness
        let filteredIDs = workspace.filteredSessionIDs
        XCTAssertEqual(filteredIDs.count, burstCount)
        XCTAssertEqual(Set(filteredIDs).count, burstCount, "filteredSessionIDs must have 100% unique IDs")

        // 3. Assert Workspace SessionSummaries uniqueness
        let summaries = workspace.sessionSummaries
        XCTAssertEqual(summaries.count, burstCount)
        XCTAssertEqual(Set(summaries.map(\.id)).count, burstCount, "sessionSummaries must have 100% unique IDs")

        // 4. Assert Displayed Summaries uniqueness (Windowed + Pinned)
        // 4. Assert Displayed Summaries and Sessions uniqueness (Windowed + Pinned)
        workspace.selectedSessionID = filteredIDs.first
        let displayedSummaries = workspace.displayedSummaries
        XCTAssertEqual(Set(displayedSummaries.map(\.id)).count, displayedSummaries.count, "displayedSummaries must never contain duplicate IDs")

        let displayedSessions = workspace.displayedSessions
        XCTAssertEqual(Set(displayedSessions.map(\.id)).count, displayedSessions.count, "displayedSessions must never contain duplicate IDs")

        // 5. Assert Explorer Tree leaf uniqueness
        let tree = SessionExplorerBuilder.build(from: summaries, grouping: .byHost, hostGrouping: .exactHosts)
        let visibleRows = tree.visibleRows(expandedNodeIDs: Set(tree.roots.map(\.id)))
        let leafIDs = visibleRows.filter { $0.node.children.isEmpty }.map(\.node.id)
        XCTAssertEqual(Set(leafIDs).count, leafIDs.count, "Explorer tree leaves must have 100% unique IDs")

        // 6. Assert Timeline Analyzer event uniqueness
        let analyzer = TimelineAnalyzer()
        let events = storeSessions.map { analyzer.event(for: $0) }
        let eventIDs = events.map(\.sessionID)
        XCTAssertEqual(Set(eventIDs).count, eventIDs.count, "Timeline events must have 100% unique session IDs")
    }

    func testRapidIncrementalAppendsAndUpdatesDoNotIntroduceDuplicates() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.isCaptureActive = true

        // Initial batch
        for i in 0..<50 {
            store.append(Self.makeSession(path: "/initial/\(i)"))
        }
        try await waitUntil("initial batch settles") {
            !workspace.isRecomputing && workspace.sessionSummaries.count == 50
        }

        // Rapid interleaved appends and updates
        for i in 0..<50 {
            let session = Self.makeSession(path: "/interleaved/\(i)")
            store.append(session)
            // Immediately mutate state
            var updated = session
            updated.state = .completed
            store.update(updated)
        }

        try await waitUntil("interleaved batch settles") {
            !workspace.isRecomputing && workspace.sessionSummaries.count == 100
        }

        let displayed = workspace.displayedSummaries
        XCTAssertEqual(Set(displayed.map(\.id)).count, displayed.count, "displayedSummaries must have strictly unique IDs after interleaved appends and updates")
    }

    func testBodyPackStoreWriteAndReadWithCRCVerification() throws {
        let spoolDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BodyPackTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: spoolDir) }

        let store = BodyPackStore(spoolDirectory: spoolDir)
        let sessionID1 = UUID()
        let payload1 = Data("first video segment payload data".utf8)
        let ref1 = try store.write(sessionID: sessionID1, kind: 0x02, payload: payload1)

        let sessionID2 = UUID()
        let payload2 = Data("second audio segment payload data with higher length".utf8)
        let ref2 = try store.write(sessionID: sessionID2, kind: 0x02, payload: payload2)

        XCTAssertEqual(ref1.packIndex, 1)
        XCTAssertEqual(ref2.packIndex, 1)
        XCTAssertEqual(ref1.length, UInt32(payload1.count))
        XCTAssertEqual(ref2.length, UInt32(payload2.count))

        let read1 = try store.read(reference: ref1)
        let read2 = try store.read(reference: ref2)

        XCTAssertEqual(read1, payload1)
        XCTAssertEqual(read2, payload2)
    }

    func testSessionJournalWriterAndReaderSequentialRoundtrip() throws {
        let journalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalTest-\(UUID().uuidString)", isDirectory: true)
        let journalURL = journalDir.appendingPathComponent("journal.jsonl")
        defer { try? FileManager.default.removeItem(at: journalDir) }

        let writer = SessionJournalWriter(journalURL: journalURL)
        var originalSessions: [SessionRecord] = []
        for i in 0..<25 {
            let session = Self.makeSession(path: "/journal/item-\(i)")
            originalSessions.append(session)
            try writer.append(session: session)
        }

        XCTAssertEqual(writer.entryCount, 25)

        let readSessions = SessionJournalReader.readSessions(from: journalURL)
        XCTAssertEqual(readSessions.count, 25)
        for i in 0..<25 {
            XCTAssertEqual(readSessions[i].id, originalSessions[i].id)
            XCTAssertEqual(readSessions[i].request.path, originalSessions[i].request.path)
        }

        writer.reset()
        XCTAssertEqual(writer.entryCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testBodySpoolCoordinatorTier3LRUCachingAndThresholding() throws {
        let spoolDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpoolCoordTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: spoolDir) }

        let coordinator = BodySpoolCoordinator(spoolDirectory: spoolDir)

        // 1. Small non-media payload remains inline
        let smallData = Data("{\"status\":\"ok\"}".utf8)
        let (inline1, ref1) = coordinator.spoolIfNeeded(
            bodyData: smallData,
            sessionID: UUID(),
            kind: 0x02,
            contentType: "application/json"
        )
        XCTAssertNotNil(inline1)
        XCTAssertNil(ref1)

        // 2. Large or streaming media payload spools to disk
        let mediaData = Data(repeating: 0x47, count: 500) // MPEG-TS packet sync pattern
        let sessionID2 = UUID()
        let (inline2, ref2) = coordinator.spoolIfNeeded(
            bodyData: mediaData,
            sessionID: sessionID2,
            kind: 0x02,
            contentType: "video/mp2t"
        )
        XCTAssertNil(inline2)
        XCTAssertNotNil(ref2)

        if let ref2 {
            let hydrated = try coordinator.loadBody(for: sessionID2, reference: ref2)
            XCTAssertEqual(hydrated, mediaData)
        }
    }

    func testGate1HighThroughputBurstWithEphemeralSpoolingAndFlatMemory() async throws {
        let spoolDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gate1Test-\(UUID().uuidString)", isDirectory: true)
        let journalURL = spoolDir.appendingPathComponent("journal.jsonl")
        defer { try? FileManager.default.removeItem(at: spoolDir) }

        let spoolCoordinator = BodySpoolCoordinator(spoolDirectory: spoolDir)
        let journalWriter = SessionJournalWriter(journalURL: journalURL)
        let sampler = CurrentProcessMetricsSampler()

        let baselineMemory = sampler.sample().physicalFootprintBytes
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.isCaptureActive = true

        let totalSessions = 500
        var spooledRefs: [(UUID, BodySpoolReference)] = []

        for i in 0..<totalSessions {
            let isMedia = (i % 2 == 0)
            let sessionID = UUID()
            let rawData = isMedia ? Data(repeating: 0x47, count: 260 * 1024) : Data("{\"item\":\(i)}".utf8)
            let contentType = isMedia ? "video/mp2t" : "application/json"

            let (inlineData, spoolRef) = spoolCoordinator.spoolIfNeeded(
                bodyData: rawData,
                sessionID: sessionID,
                kind: 0x02,
                contentType: contentType
            )

            if let spoolRef {
                spooledRefs.append((sessionID, spoolRef))
            }

            var session = Self.makeSession(id: sessionID, path: "/stream/segment-\(i)")
            session.response = CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: contentType)],
                bodyData: inlineData,
                bodySize: rawData.count
            )

            store.append(session)
            try journalWriter.append(session: session)
        }

        try await waitUntil("all sessions process in workspace") {
            !workspace.isRecomputing && workspace.sessionSummaries.count == totalSessions
        }

        XCTAssertEqual(workspace.sessionSummaries.count, totalSessions)
        XCTAssertEqual(journalWriter.entryCount, totalSessions)
        XCTAssertGreaterThan(spooledRefs.count, 200, "Media segments must be offloaded to spool")

        // Verify random hydration sample from spooled packfiles
        for (sid, ref) in spooledRefs.prefix(10) {
            let hydrated = try spoolCoordinator.loadBody(for: sid, reference: ref)
            XCTAssertEqual(hydrated.count, 260 * 1024)
        }

        let endMemory = sampler.sample().physicalFootprintBytes
        XCTAssertGreaterThan(endMemory, 0)
        XCTAssertGreaterThan(baselineMemory, 0)
    }

    func testGate2ContinuousStreamingSimulationStability() async throws {
        let spoolDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gate2Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: spoolDir) }

        let spoolCoordinator = BodySpoolCoordinator(spoolDirectory: spoolDir)
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.isCaptureActive = true

        let bitrates = ["video_1080p", "video_720p", "video_480p", "audio_stereo"]
        var loadedRefs: [(UUID, BodySpoolReference)] = []

        for i in 0..<300 {
            let bitrate = bitrates[i % bitrates.count]
            let sessionID = UUID()
            let segmentData = Data(repeating: UInt8(i % 255), count: 128 * 1024)

            let (inlineData, spoolRef) = spoolCoordinator.spoolIfNeeded(
                bodyData: segmentData,
                sessionID: sessionID,
                kind: 0x02,
                contentType: "video/mp4"
            )

            var session = Self.makeSession(id: sessionID, path: "/hls/\(bitrate)/segment_\(i).m4s")
            session.response = CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")],
                bodyData: inlineData,
                bodySize: segmentData.count
            )

            store.append(session)
            if let spoolRef {
                loadedRefs.append((sessionID, spoolRef))
            }
        }

        try await waitUntil("streaming batch recomputation finishes") {
            !workspace.isRecomputing && workspace.sessionSummaries.count == 300
        }

        XCTAssertEqual(workspace.sessionSummaries.count, 300)
        XCTAssertEqual(loadedRefs.count, 300, "All video segments should be spooled to disk")

        // Verify random hydration correctness
        for (sid, ref) in loadedRefs.suffix(20) {
            let body = try spoolCoordinator.loadBody(for: sid, reference: ref)
            XCTAssertEqual(body.count, 128 * 1024)
        }
    }

    // MARK: - Helpers

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async throws {
        let attempts = Int(timeout / 0.05)
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }

    private static func makeSession(id: UUID = UUID(), path: String) -> SessionRecord {
        SessionRecord(
            id: id,
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "api.example.com",
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}
