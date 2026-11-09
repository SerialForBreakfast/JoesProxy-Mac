//
//  CaptureWorkspaceObservationTests.swift
//  JoesProxyTests
//
//  Pins the @Observable migration semantics of CaptureWorkspaceViewModel:
//  - capture-state mutations must invalidate observers (views re-render),
//  - memoization-cache writes inside computed getters must NOT (they run during
//    view-body evaluation and would loop),
//  - cache-hit reads must still register a tracked dependency so later mutations
//    are observed.
//

import Observation
import Synchronization
import XCTest
@testable import JoesProxy

private actor ExplorerBuildGate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

@MainActor
final class CaptureWorkspaceObservationTests: XCTestCase {
    func testDepartureIgnoresQueuedDeliveryAndReentrySnapshotsLatestCanonicalState() async throws {
        let store = InMemorySessionStore()
        let first = Self.makeSession(path: "/before-switch")
        store.append(first)
        let old = CaptureWorkspaceViewModel(store: store)
        let queued = Self.makeSession(path: "/queued-at-switch")
        store.append(queued)
        old.stopPresentation()
        store.clear()
        let current = Self.makeSession(path: "/after-clear")
        store.append(current)
        let replacement = CaptureWorkspaceViewModel(store: store)
        let next = Self.makeSession(path: "/after-subscription")
        store.append(next)
        try await waitUntil("new subscription receives next record") {
            replacement.filteredSessionIDs == [current.id, next.id]
        }
        XCTAssertEqual(old.filteredSessionIDs, [first.id], "Queued delivery must not revive a retired graph")
        XCTAssertEqual(Set(replacement.filteredSessionIDs).count, 2)
        XCTAssertEqual(replacement.sessionSummaries.map(\.id), [current.id, next.id])
        replacement.stopPresentation()
    }

    func testCompactPresentationCancelsExplorerWithoutFreezingSharedCapture() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/first"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        let gate = ExplorerBuildGate()
        defer { Task { await gate.release() } }
        workspace.explorerBuildCheckpoint = { await gate.wait() }
        workspace.browserMode = .explorer
        try await waitUntil("Explorer entered worker") { workspace.explorerBuildCount == 1 }
        workspace.setInspectorPresentationActive(false)
        let next = Self.makeSession(path: "/during-compact")
        store.append(next)
        try await waitUntil("shared queries see Compact arrival") {
            workspace.filteredSessions.contains { $0.id == next.id }
                && workspace.sessionSummaries.contains { $0.id == next.id }
        }
        await gate.release()
        try await waitUntil("cancelled Explorer exits") { !workspace.isRebuildingExplorer }
        XCTAssertEqual(workspace.explorerBuildCount, 1)
        XCTAssertTrue(workspace.explorerTree.isEmpty)
        XCTAssertEqual(workspace.browserMode, .explorer)
        workspace.setInspectorPresentationActive(true)
        try await waitUntil("Inspector rebuild includes latest capture") {
            workspace.explorerTree.leafNodeID(for: next.id) != nil && !workspace.isRebuildingExplorer
        }
        XCTAssertEqual(workspace.explorerBuildCount, 2)
    }

    func testCompactTimelineDefersAnalysisAndRebuildsAfterClear() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.setInspectorPresentationActive(false)
        workspace.browserMode = .timeline
        store.append(Self.makeSession(path: "/discarded"))
        try await waitUntil("first capture received") { workspace.filteredSessionCount == 1 }
        store.clear()
        let latest = Self.makeSession(path: "/latest")
        store.append(latest)
        try await waitUntil("shared state reflects clear and append") { workspace.filteredSessionIDs == [latest.id] }
        XCTAssertEqual(workspace.timelineSnapshotCount, 0)
        XCTAssertFalse(workspace.isAnalyzingTimeline)
        workspace.setInspectorPresentationActive(true)
        try await waitUntil("timeline analyzes on return") { workspace.timelineSnapshotCount > 0 && !workspace.isAnalyzingTimeline }
    }

    func testBodyRetentionPreservesBrowserProjectionAndRefreshesSelection() async throws {
        let store = InMemorySessionStore()
        var session = Self.makeSession(path: "/retained")
        session.response = CapturedResponse(statusCode: 200, headers: [],
            bodyData: Data(repeating: 42, count: 1024), bodySize: 1024)
        store.append(session)
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.selectedSessionID = session.id
        let revision = workspace.selectedSessionContentRevision
        let summaries = workspace.sessionSummaries
        var publications = 0
        workspace.onFilteredSessionsChanged = { publications += 1 }

        store.retentionPolicy = .keepLastBodyBytes(1)
        try await waitUntil("retention notification consumed") {
            workspace.retentionPresentationSkipCount == 1
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(publications, 0, "Body eviction must not rebuild browser projections")
        XCTAssertEqual(workspace.retentionCounts.retentionPresentationSkips, 1)
        XCTAssertEqual(workspace.sessionSummaries, summaries)
        XCTAssertGreaterThan(workspace.selectedSessionContentRevision, revision)
        XCTAssertNil(workspace.filteredSessions.first?.response?.bodyData)

        let next = Self.makeSession(path: "/next")
        store.append(next)
        try await waitUntil("incremental append remains usable") {
            workspace.filteredSessionIDs == [session.id, next.id]
        }
        XCTAssertEqual(publications, 1)
    }

    func testExplorerCachesOnlyRequestedFolderAndClearsOnHistoryReset() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/one/nested/item"))
        store.append(Self.makeSession(path: "/two/nested/item"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.browserMode = .explorer
        try await waitUntil("Explorer ready") { !workspace.explorerTree.isEmpty && !workspace.isRebuildingExplorer }
        XCTAssertEqual(workspace.cachedExplorerFolderCount, 0)
        let folders = workspace.explorerTree.roots.flatMap { [$0] + $0.children }.filter(\.isFolder)
        XCTAssertGreaterThan(folders.count, 1)
        for folder in folders {
            let expected = workspace.visibleSessionSummaries(for: folder.sessionIDs)
            XCTAssertEqual(workspace.explorerSessionSummaries(for: folder.id), expected)
            XCTAssertEqual(workspace.cachedExplorerFolderCount, 1)
            XCTAssertEqual(workspace.cachedExplorerSummaryCount, expected.count)
        }
        store.clear()
        try await waitUntil("Clear releases folder summaries") {
            workspace.cachedExplorerFolderCount == 0 && workspace.filteredSessionCount == 0
        }
        XCTAssertEqual(workspace.retentionCounts.summaries, 0)
        XCTAssertEqual(workspace.retentionCounts.explorerSummaries, 0)
        XCTAssertEqual(workspace.retentionCounts.tableRows, 0)
        for folder in folders { XCTAssertTrue(workspace.explorerSessionSummaries(for: folder.id).isEmpty) }
    }

    func testExplorerStopsQueuedWorkWhenHiddenAndRefreshesOnReturn() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/first"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        let gate = ExplorerBuildGate()
        defer { Task { await gate.release() } }
        workspace.explorerBuildCheckpoint = { await gate.wait() }
        workspace.browserMode = .explorer
        try await waitUntil("Explorer build starts") { workspace.explorerBuildCount == 1 }
        workspace.browserMode = .timeline
        let next = Self.makeSession(path: "/second")
        store.append(next)
        try await waitUntil("hidden Explorer input updates") { workspace.filteredSessionCount == 2 }
        await gate.release()
        try await waitUntil("hidden worker exits") { !workspace.isRebuildingExplorer }
        XCTAssertEqual(workspace.explorerBuildCount, 1)
        XCTAssertTrue(workspace.explorerTree.isEmpty)
        workspace.browserMode = .explorer
        try await waitUntil("return rebuilds latest Explorer") {
            workspace.explorerBuildCount == 2 && !workspace.isRebuildingExplorer
        }
        XCTAssertFalse(workspace.explorerTree.isEmpty)
        XCTAssertNotNil(workspace.explorerTree.leafNodeID(for: next.id))
    }

    func testExplorerClearKeepsOneWorkerUntilCancelledBuildExits() async throws {
        let store = InMemorySessionStore()
        let old = Self.makeSession(path: "/old")
        store.append(old)
        let workspace = CaptureWorkspaceViewModel(store: store)
        let gate = ExplorerBuildGate()
        defer { Task { await gate.release() } }
        workspace.explorerBuildCheckpoint = { await gate.wait() }
        workspace.browserMode = .explorer
        try await waitUntil("old Explorer build starts") { workspace.explorerBuildCount == 1 }
        store.clear()
        let replacement = Self.makeSession(path: "/replacement")
        store.append(replacement)
        try await waitUntil("replacement input settles") {
            workspace.filteredSessionIDs == [replacement.id] && !workspace.isRecomputing
        }
        XCTAssertEqual(workspace.explorerBuildCount, 1, "Clear must not release an occupied worker slot")
        XCTAssertTrue(workspace.explorerTree.isEmpty)
        await gate.release()
        try await waitUntil("replacement tree publishes") {
            workspace.explorerTree.leafNodeID(for: replacement.id) != nil
        }
        XCTAssertNil(workspace.explorerTree.leafNodeID(for: old.id))
        XCTAssertEqual(workspace.explorerBuildCount, 2)
    }

    func testHiddenExplorerBecomesDirtyWhileTimelineIsActive() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/initial"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.browserMode = .explorer
        try await waitUntil("initial tree settles") { !workspace.explorerTree.isEmpty }
        workspace.browserMode = .timeline
        let next = Self.makeSession(path: "/new")
        store.append(next)
        try await waitUntil("timeline input settles") { workspace.filteredSessionCount == 2 }
        workspace.browserMode = .explorer
        try await waitUntil("Explorer contains hidden arrival") {
            workspace.explorerTree.leafNodeID(for: next.id) != nil
        }
    }

    func testExplorerReloadAndGroupingChangeDiscardOldGeneration() async throws {
        let store = InMemorySessionStore()
        let old = Self.makeSession(path: "/old-recording")
        store.append(old)
        let workspace = CaptureWorkspaceViewModel(store: store)
        let gate = ExplorerBuildGate()
        defer { Task { await gate.release() } }
        workspace.explorerBuildCheckpoint = { await gate.wait() }
        workspace.browserMode = .explorer
        try await waitUntil("old recording build starts") { workspace.explorerBuildCount == 1 }
        let replacement = Self.makeSession(path: "/new-recording")
        store.load(sessions: [replacement])
        workspace.explorerGrouping = .byEndpoint
        try await waitUntil("loaded recording settles") {
            workspace.filteredSessionIDs == [replacement.id] && !workspace.isRecomputing
        }
        XCTAssertEqual(workspace.explorerBuildCount, 1)
        await gate.release()
        try await waitUntil("new recording and grouping publish") {
            workspace.explorerTree.grouping == .byEndpoint &&
            workspace.explorerTree.leafNodeID(for: replacement.id) != nil
        }
        XCTAssertNil(workspace.explorerTree.leafNodeID(for: old.id))
        XCTAssertEqual(workspace.explorerBuildCount, 2)
    }

    func testExplorerCoalescesCaptureArrivalsIntoOneFollowup() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/initial"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        let gate = ExplorerBuildGate()
        defer { Task { await gate.release() } }
        workspace.explorerBuildCheckpoint = { await gate.wait() }
        workspace.browserMode = .explorer
        try await waitUntil("first build starts") { workspace.explorerBuildCount == 1 }
        let arrivals = (0..<30).map { Self.makeSession(path: "/arrival/\($0)") }
        for record in arrivals { store.append(record) }
        try await waitUntil("burst settles") { workspace.filteredSessionCount == 31 }
        XCTAssertEqual(workspace.explorerBuildCount, 1)
        await gate.release()
        try await waitUntil("coalesced tree catches up") {
            arrivals.allSatisfy { workspace.explorerTree.leafNodeID(for: $0.id) != nil }
        }
        XCTAssertEqual(workspace.explorerBuildCount, 2)
    }

    func testExplorerBuilderDiscardsCancelledPartialTrees() {
        let summaries = (0..<50).map { SessionSummary(record: Self.makeSession(path: "/item/\($0)")) }
        for grouping in [SessionExplorerGrouping.byHost, .byEndpoint, .bySource] {
            for hosts in [SessionExplorerHostGrouping.exactHosts, .domainFamilies] {
                var checkpoints = 0
                let tree = SessionExplorerBuilder.build(from: summaries, grouping: grouping,
                    hostGrouping: hosts, isCancelled: {
                        checkpoints += 1
                        return checkpoints > 5
                    })
                XCTAssertTrue(tree.isEmpty)
                XCTAssertLessThan(checkpoints, summaries.count)
            }
        }
    }

    func testIdentityProjectionPreservesWindowSelectionAndClear() async throws {
        let store = InMemorySessionStore()
        let records = (0..<600).map { Self.makeSession(path: "/row/\($0)") }
        store.load(sessions: records)
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.isCaptureActive = true
        workspace.isSortAscending = false
        workspace.selectedSessionID = records[0].id
        let identities = workspace.displayedRowIdentities
        XCTAssertEqual(identities.map(\.id), workspace.displayedSummaries.map(\.id))
        XCTAssertEqual(identities.count, 501)
        XCTAssertEqual(identities.last?.id, records[0].id)

        workspace.showMoreSessions()
        XCTAssertEqual(workspace.displayedRowIdentities.count, 600)
        store.clear()
        try await waitUntil("identity projection clears") { workspace.displayedRowIdentities.isEmpty }
        XCTAssertNil(workspace.summaryLookup(for: identities[0].id),
            "Retaining a row identity must not retain its removed summary in the workspace")
    }

    func testIdentityProjectionResolvesSameIDUpdatesAndLatestFilter() async throws {
        let store = InMemorySessionStore()
        var record = Self.makeSession(path: "/keep")
        store.append(record)
        store.append(Self.makeSession(path: "/other"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        let identity = try XCTUnwrap(workspace.displayedRowIdentities.first { $0.id == record.id })
        record.response = CapturedResponse(statusCode: 503, headers: [], bodyData: nil, bodySize: 0)
        store.update(record)
        try await waitUntil("identity resolves current metadata") {
            identity.summary == SessionSummary(record: record)
        }
        workspace.searchText = "keep"
        try await waitUntil("identity projection applies filter") {
            workspace.displayedRowIdentities == [identity]
        }
        XCTAssertEqual(workspace.displayedRowIdentities.map(\.id), workspace.displayedSummaries.map(\.id))
    }

    func testIdentityCellLookupObservesSameIDMetadataChanges() async throws {
        let store = InMemorySessionStore()
        var record = Self.makeSession(path: "/metadata")
        store.append(record)
        let workspace = CaptureWorkspaceViewModel(store: store)
        let identity = try XCTUnwrap(workspace.displayedRowIdentities.first)
        let invalidated = Mutex(false)
        withObservationTracking {
            _ = identity.summary
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        record.response = CapturedResponse(statusCode: 201, headers: [], bodyData: nil, bodySize: 0)
        store.update(record)
        try await waitUntil("cell metadata dependency invalidates") { invalidated.withLock { $0 } }
        XCTAssertEqual(identity.summary.statusCode, 201)
        XCTAssertTrue(workspace.displayedRowIdentities.first === identity)
    }

    func testRowObservationIgnoresUnrelatedArrivalsAndUnchangedMetadata() async throws {
        let store = InMemorySessionStore()
        let record = Self.makeSession(path: "/stable")
        store.append(record)
        let workspace = CaptureWorkspaceViewModel(store: store)
        let row = try XCTUnwrap(workspace.displayedRowIdentities.first)
        let invalidated = Mutex(false)
        withObservationTracking {
            _ = row.summary
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        var other = Self.makeSession(path: "/unrelated")
        store.append(other)
        store.update(record)
        other.response = CapturedResponse(statusCode: 204, headers: [], bodyData: nil, bodySize: 0)
        store.update(other)
        try await waitUntil("unrelated traffic reaches workspace") {
            workspace.summaryLookup(for: other.id)?.statusCode == 204
        }
        XCTAssertFalse(invalidated.withLock { $0 }, "Unrelated captures must not invalidate this row")
        XCTAssertTrue(workspace.displayedRowIdentities.first { $0.id == record.id } === row)
    }

    func testRowPresentationRefreshesLoadedMetadataAndReleasesRemovedRows() async throws {
        let store = InMemorySessionStore()
        var record = Self.makeSession(path: "/reload")
        store.append(record)
        let workspace = CaptureWorkspaceViewModel(store: store)
        weak var oldRow = workspace.displayedRowIdentities.first
        record.response = CapturedResponse(statusCode: 202, headers: [], bodyData: nil, bodySize: 0)
        store.load(sessions: [record])
        try await waitUntil("retained row gets replacement metadata") { oldRow?.summary.statusCode == 202 }
        store.clear()
        try await waitUntil("workspace releases row ownership") {
            workspace.displayedRowIdentities.isEmpty && oldRow == nil
        }
    }

    func testBatchUpdatesPreserveRowsAndRemovalReleasesOnlyRemovedPresentation() async throws {
        let store = InMemorySessionStore()
        var first = Self.makeSession(path: "/first")
        var second = Self.makeSession(path: "/second")
        store.load(sessions: [first, second])
        let workspace = CaptureWorkspaceViewModel(store: store)
        weak var firstRow = workspace.displayedRowIdentities.first { $0.id == first.id }
        let secondRow = try XCTUnwrap(workspace.displayedRowIdentities.first { $0.id == second.id })
        first.response = CapturedResponse(statusCode: 201, headers: [], bodyData: nil, bodySize: 0)
        second.response = CapturedResponse(statusCode: 202, headers: [], bodyData: nil, bodySize: 0)
        store.update([first, second])
        try await waitUntil("batch updates the existing row objects") {
            firstRow?.summary.statusCode == 201 && secondRow.summary.statusCode == 202
        }
        store.remove(ids: [first.id])
        try await waitUntil("removed row is released") {
            workspace.displayedRowIdentities == [secondRow] && firstRow == nil
        }
    }

    func testContinuousArrivalsPublishBeforeTrafficBecomesQuiet() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        var publicationsDuringTraffic = 0
        workspace.onFilteredSessionsChanged = { publicationsDuringTraffic += 1 }
        for index in 0..<40 {
            store.append(Self.makeSession(path: "/stream/\(index)"))
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(publicationsDuringTraffic, 0,
            "Continuous arrivals must not restart the presentation deadline indefinitely")
        try await waitUntil("latest arrivals become visible") {
            workspace.filteredSessionIDs.count == 40
        }
    }

    func testCoalescingWindowUsesLatestCriteriaAndClearStartsFreshDeadline() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        store.append(Self.makeSession(path: "/discard"))
        workspace.searchText = "discard"
        store.clear()
        let replacement = Self.makeSession(path: "/keep")
        store.append(replacement)
        workspace.searchText = "keep"
        try await waitUntil("new capture uses latest criteria") {
            workspace.filteredSessionIDs == [replacement.id]
        }
        XCTAssertFalse(workspace.isRecomputing)
    }

    func testFallbackInspectionWithoutSelectionRefreshesSameIDBodies() async throws {
        let store = InMemorySessionStore()
        var record = Self.makeSession(path: "/fallback")
        store.append(record)
        let workspace = CaptureWorkspaceViewModel(store: store)
        XCTAssertNil(workspace.selectedSessionID)
        XCTAssertEqual(workspace.newestVisibleSessionID(), record.id)
        var cache = InspectorBodyCache()
        cache.update(session: record, revision: workspace.selectedSessionContentRevision)
        XCTAssertNil(cache.responseSource)

        for value in ["{\"id\":1}", "{\"id\":2}"] {
            let priorRevision = workspace.selectedSessionContentRevision
            record.response = CapturedResponse(statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: Data(value.utf8), bodySize: value.utf8.count)
            store.update(record)
            try await waitUntil("fallback same-ID body update invalidates inspector") {
                workspace.selectedSessionContentRevision > priorRevision
            }
            cache.update(session: store.record(for: record.id), revision: workspace.selectedSessionContentRevision)
            XCTAssertEqual(cache.responseDecode?.analysisData, Data(value.utf8))
            XCTAssertNotNil(cache.responseSource)
            XCTAssertNil(workspace.selectedSessionID)
        }
    }

    func testSelectedInspectionRevisionIgnoresUnrelatedTrafficButTracksUpdateAndClear() async throws {
        let store = InMemorySessionStore()
        let selected = Self.makeSession(path: "/selected")
        store.append(selected)
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.selectedSessionID = selected.id
        let originalRevision = workspace.selectedSessionContentRevision
        let other = Self.makeSession(path: "/unrelated")
        store.append(other)
        try await waitUntil("unrelated append applied") { workspace.summaryLookup(for: other.id) != nil }
        XCTAssertEqual(workspace.selectedSessionContentRevision, originalRevision)
        var updated = selected
        updated.state = .failed
        store.update(updated)
        try await waitUntil("selected update invalidates inspector") {
            workspace.selectedSessionContentRevision > originalRevision
        }
        let updatedRevision = workspace.selectedSessionContentRevision
        store.clear()
        try await waitUntil("clear invalidates inspector") {
            workspace.selectedSessionContentRevision > updatedRevision
        }
    }

    func testClearCancelsDetachedFilteringWithoutRetiringNewCaptureState() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/old-body"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        let gate = PausedFilterCheckpoint()
        defer { gate.release() }
        workspace.recomputeCheckpoint = { try gate.check() }
        workspace.searchText = "body"
        try await waitUntil("old filter starts") { gate.callCount == 1 }
        XCTAssertEqual(workspace.retentionCounts.activeFilterSnapshots, 1)
        XCTAssertEqual(workspace.retentionCounts.activeFilterSnapshotRecords, 1)

        store.clear()
        let replacement = Self.makeSession(path: "/new-body")
        store.append(replacement)
        try await waitUntil("replacement filter completes") {
            workspace.filteredSessionIDs == [replacement.id]
        }
        gate.release()
        try await waitUntil("old detached task sees cancellation") { gate.cancelledCount == 1 }
        try await waitUntil("retired snapshots release accounting") {
            workspace.retentionCounts.activeFilterSnapshots == 0
        }
        XCTAssertEqual(workspace.retentionCounts.activeFilterSnapshotRecords, 0)
        XCTAssertEqual(workspace.filteredSessionIDs, [replacement.id])
        XCTAssertFalse(workspace.isRecomputing)
    }

    func testTimelineKeepsSameIDUpdateDuringAnalysisAndUsesCurrentFilter() async throws {
        let store = InMemorySessionStore()
        let original = Self.makeSession(path: "/in-flight")
        store.append(original)
        let workspace = CaptureWorkspaceViewModel(store: store)
        let classifier = PausedTimelineClassifier()
        defer { classifier.release() }
        workspace.timelineAnalyzer = TimelineAnalyzer(classifier: classifier)
        workspace.timelineSleep = { _ in }
        workspace.browserMode = .timeline
        try await waitUntil("classification starts") { classifier.callCount == 1 }
        var updated = original
        updated.state = .failed
        store.update(updated)
        workspace.timelineFilterState.lane = .errorsRetries
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(workspace.timelineSnapshotCount, 1, "No overlapping analysis")
        classifier.release()
        try await waitUntil("in-flight update is reclassified") {
            workspace.timelineAnalysisResult.visibleEvents.first?.lane == .errorsRetries
        }
        XCTAssertEqual(workspace.timelineAnalysisResult.events.count, 1)
        XCTAssertEqual(classifier.callCount, 2)
    }

    func testClearCancelsDetachedClassificationAndRejectsOldResults() async throws {
        let store = InMemorySessionStore()
        for index in 0..<20 { store.append(Self.makeSession(path: "/retired/\(index)")) }
        let workspace = CaptureWorkspaceViewModel(store: store)
        let classifier = PausedTimelineClassifier()
        defer { classifier.release() }
        workspace.timelineAnalyzer = TimelineAnalyzer(classifier: classifier)
        workspace.timelineSleep = { _ in }
        workspace.browserMode = .timeline
        try await waitUntil("classification starts") { classifier.callCount == 1 }
        store.clear()
        try await waitUntil("clear publishes") { workspace.filteredSessions.isEmpty }
        classifier.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(classifier.callCount, 1, "Cancellation stops the remaining classification loop")
        XCTAssertTrue(workspace.timelineAnalysisResult.events.isEmpty)
        XCTAssertFalse(workspace.isAnalyzingTimeline)
        store.append(Self.makeSession(path: "/new-capture"))
        try await waitUntil("new capture publishes independently") {
            workspace.timelineAnalysisResult.events.count == 1
        }
    }

    func testReloadPublishesNewGenerationWhileOldAnalysisIsRetiring() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/old-recording"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        let classifier = PausedTimelineClassifier()
        defer { classifier.release() }
        workspace.timelineAnalyzer = TimelineAnalyzer(classifier: classifier)
        workspace.timelineSleep = { _ in }
        workspace.browserMode = .timeline
        try await waitUntil("old classification starts") { classifier.callCount == 1 }
        let replacement = Self.makeSession(path: "/replacement")
        store.load(sessions: [replacement])
        try await waitUntil("replacement publishes") {
            workspace.timelineAnalysisResult.events.first?.sessionID == replacement.id
        }
        classifier.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(workspace.timelineAnalysisResult.events.map(\.sessionID), [replacement.id])
        XCTAssertFalse(workspace.isAnalyzingTimeline)
    }
    func testTimelineCollectsOneSnapshotAfterFixedDeadline() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        let gate = TimelineDeadlineGate()
        workspace.timelineSleep = { _ in await gate.wait() }
        workspace.browserMode = .timeline
        for index in 0..<5 {
            store.append(Self.makeSession(path: "/deadline/\(index)"))
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(workspace.timelineSnapshotCount, 0, "No full snapshot before the deadline")
        let waits = await gate.count
        XCTAssertEqual(waits, 1, "Capture changes must not replace the timer")
        await gate.release()
        try await waitUntil("timeline publishes latest snapshot") {
            workspace.timelineAnalysisResult.events.count == 5
        }
        XCTAssertEqual(workspace.timelineSnapshotCount, 1)
        workspace.browserMode = .table
        await gate.release()
    }

    func testTimelinePublishesWhileCaptureContinues() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        workspace.browserMode = .timeline
        var publishedDuringCapture = false
        for index in 0..<30 {
            store.append(Self.makeSession(path: "/continuous/\(index)"))
            try await Task.sleep(for: .milliseconds(30))
            publishedDuringCapture = publishedDuringCapture || !workspace.timelineAnalysisResult.events.isEmpty
        }
        XCTAssertTrue(publishedDuringCapture)
        try await waitUntil("timeline catches final update") {
            workspace.timelineAnalysisResult.events.count == 30
        }
    }

    func testLeavingTimelineInvalidatesDeadlineAndReentryRefreshes() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/before"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        let gate = TimelineDeadlineGate()
        workspace.timelineSleep = { _ in await gate.wait() }
        workspace.browserMode = .timeline
        try await Task.sleep(for: .milliseconds(30))
        workspace.browserMode = .table
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(workspace.timelineSnapshotCount, 0)
        XCTAssertFalse(workspace.isAnalyzingTimeline)
        workspace.timelineSleep = { _ in }
        workspace.browserMode = .timeline
        try await waitUntil("reentry refreshes") { workspace.timelineAnalysisResult.events.count == 1 }
    }

    func testClearInvalidatesPendingTimelinePublication() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/old"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        let gate = TimelineDeadlineGate()
        workspace.timelineSleep = { _ in await gate.wait() }
        workspace.browserMode = .timeline
        try await Task.sleep(for: .milliseconds(30))
        store.clear()
        try await Task.sleep(for: .milliseconds(30))
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(workspace.timelineAnalysisResult.events.isEmpty)
        XCTAssertFalse(workspace.isAnalyzingTimeline)
        XCTAssertEqual(workspace.timelineSnapshotCount, 0)
    }

    func testFilteredSessionsMutationTriggersObservation() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        try await waitUntil("initial recompute settles") { !workspace.isRecomputing }

        var changed = false
        withObservationTracking {
            _ = workspace.filteredSessions
        } onChange: {
            changed = true
        }

        store.append(Self.makeSession(path: "/observed"))
        try await waitUntil("recompute publishes filteredSessions") { changed }
    }

    func testDisplayedSessionsReadDoesNotSelfInvalidate() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/a"))
        store.append(Self.makeSession(path: "/b"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        try await waitUntil("recompute settles") {
            !workspace.isRecomputing && workspace.filteredSessions.count == 2
        }

        var changed = false
        withObservationTracking {
            // Cold read writes the memo cache during evaluation; warm read hits it.
            // If the cache storage were tracked, the write would fire onChange here —
            // exactly the re-render loop @ObservationIgnored exists to prevent.
            _ = workspace.displayedSessions
            _ = workspace.displayedSessions
            _ = workspace.displayedSummaries
            _ = workspace.displayedSummaries
        } onChange: {
            changed = true
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(changed, "Memoization writes must not invalidate observers")
    }

    func testDisplayedSessionsCacheHitStillTracksLaterMutations() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/a"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        try await waitUntil("recompute settles") {
            !workspace.isRecomputing && workspace.filteredSessions.count == 1
        }

        // Warm the memo cache outside tracking, then read inside tracking (cache hit).
        _ = workspace.displayedSessions

        var changed = false
        withObservationTracking {
            _ = workspace.displayedSessions
        } onChange: {
            changed = true
        }

        store.append(Self.makeSession(path: "/b"))
        try await waitUntil("append invalidates cached-path observers") { changed }
    }

    func testOnFilteredSessionsChangedFiresPerRecompute() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        var fireCount = 0
        workspace.onFilteredSessionsChanged = { fireCount += 1 }

        store.append(Self.makeSession(path: "/one"))
        try await waitUntil("first recompute fires callback") { fireCount >= 1 }

        let countAfterFirst = fireCount
        store.append(Self.makeSession(path: "/two"))
        try await waitUntil("second recompute fires callback again") { fireCount > countAfterFirst }
    }

    func testIncrementalAppendMatchesFullRebuildAfterManyAppends() async throws {
        // Regression test for the append-only fast path in runRecompute(): once
        // canExtendFilteredSessionsIncrementally is established, subsequent appends must
        // extend filteredSessionIDs/sessionSummaries identically to what a full rebuild
        // would have produced — same order, same summaries, no dropped or duplicated IDs.
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        let first = Self.makeSession(path: "/seed")
        store.append(first)
        try await waitUntil("initial full-rebuild recompute settles") {
            !workspace.isRecomputing && workspace.filteredSessions.count == 1
        }

        // These appends must all be absorbed by the incremental path (no filter/sort
        // change in between to force a full rebuild).
        var appended = [first]
        for i in 0..<25 {
            let session = Self.makeSession(path: "/item-\(i)")
            appended.append(session)
            store.append(session)
        }

        try await waitUntil("all appends land") { workspace.filteredSessions.count == appended.count }

        XCTAssertEqual(workspace.filteredSessions.map(\.id), appended.map(\.id))
        XCTAssertEqual(workspace.sessionSummaries.map(\.id), appended.map(\.id))

        // Every appended session must be individually resolvable at its filtered index —
        // proves filteredIndexByID was extended, not left stale.
        for session in appended {
            XCTAssertNotNil(workspace.visibleSession(for: session.id), "missing from filteredIndexByID: \(session.id)")
        }
    }

    func testFilterChangeForcesFullRebuildAfterIncrementalAppends() async throws {
        // A filter/sort change must invalidate the incremental-append invariant so the
        // next recompute does a correct full rebuild instead of extending stale state.
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        let matching = Self.makeSession(path: "/keep")
        let nonMatching = Self.makeSession(path: "/drop")
        store.append(matching)
        store.append(nonMatching)
        try await waitUntil("initial recompute settles") {
            !workspace.isRecomputing && workspace.filteredSessions.count == 2
        }

        workspace.searchText = "keep"
        try await waitUntil("filtered recompute settles") {
            !workspace.isRecomputing && workspace.filteredSessions.map(\.id) == [matching.id]
        }

        XCTAssertEqual(workspace.filteredSessions.map(\.id), [matching.id])
    }

    func testClearPublishesEmptyStateWithoutRecomputeDelay() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/a"))
        store.append(Self.makeSession(path: "/b"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        try await waitUntil("initial recompute settles") {
            !workspace.isRecomputing && workspace.filteredSessionCount == 2
        }

        store.clear()
        await Task.yield()

        XCTAssertFalse(workspace.hasSessions)
        XCTAssertFalse(workspace.hasVisibleSessions)
        XCTAssertEqual(workspace.filteredSessionCount, 0)
        XCTAssertTrue(workspace.sessionSummaries.isEmpty)
        XCTAssertFalse(workspace.isRecomputing)
    }

    func testAppendAfterClearRepopulatesWorkspace() async throws {
        let store = InMemorySessionStore()
        store.append(Self.makeSession(path: "/before-clear"))
        let workspace = CaptureWorkspaceViewModel(store: store)
        try await waitUntil("initial recompute settles") {
            workspace.filteredSessionCount == 1
        }

        store.clear()
        await Task.yield()
        let replacement = Self.makeSession(path: "/after-clear")
        store.append(replacement)

        try await waitUntil("post-clear session appears") {
            workspace.filteredSessions.map(\.id) == [replacement.id]
        }
    }

    func testSessionUpdateInPlaceMaintainsFastPathAndOrder() async throws {
        let store = InMemorySessionStore()
        let workspace = CaptureWorkspaceViewModel(store: store)
        var sessions: [SessionRecord] = []
        for i in 0..<10 {
            let s = Self.makeSession(path: "/item-\(i)")
            sessions.append(s)
            store.append(s)
        }

        try await waitUntil("initial appends settle") {
            workspace.filteredSessionCount == 10
        }

        // Now simulate response completions (updates) on all 10 sessions.
        for i in 0..<10 {
            var updated = sessions[i]
            updated.response = CapturedResponse(statusCode: 204, headers: [], bodyData: nil, bodySize: nil)
            store.update(updated)
        }

        // Verify all 10 summaries reflect the updated status code in O(1) without dropping or reordering.
        try await waitUntil("updates reflected in summaries") {
            workspace.sessionSummaries.allSatisfy { $0.statusCode == 204 }
        }

        XCTAssertEqual(workspace.filteredSessions.map(\.id), sessions.map(\.id))
        XCTAssertEqual(workspace.sessionSummaries.map(\.id), sessions.map(\.id))

        // Append one more to prove fast-path append still works immediately after updates.
        let tail = Self.makeSession(path: "/tail")
        store.append(tail)

        try await waitUntil("tail append lands") {
            workspace.filteredSessionCount == 11
        }
        XCTAssertEqual(workspace.filteredSessionIDs.last, tail.id)
    }

    // MARK: - Helpers

    private func waitUntil(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async throws {
        for _ in 0..<40 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }

    private static func makeSession(path: String) -> SessionRecord {
        SessionRecord(
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

private actor TimelineDeadlineGate {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0
    func wait() async {
        count += 1
        await withCheckedContinuation { pending.append($0) }
    }
    func release() {
        let continuations = pending
        pending = []
        continuations.forEach { $0.resume() }
    }
}

private final class PausedFilterCheckpoint: Sendable {
    private let calls = Mutex(0)
    private let cancelled = Mutex(0)
    private let resume = DispatchSemaphore(value: 0)
    var callCount: Int { calls.withLock { $0 } }
    var cancelledCount: Int { cancelled.withLock { $0 } }
    func release() { resume.signal() }
    func check() throws {
        let count = calls.withLock { $0 += 1; return $0 }
        if count == 1 { resume.wait() }
        if Task.isCancelled {
            cancelled.withLock { $0 += 1 }
            throw CancellationError()
        }
    }
}

/// Blocks only the first synchronous classifier call on its detached worker.
private final class PausedTimelineClassifier: TimelineClassifying {
    private let calls = Mutex(0)
    private let resume = DispatchSemaphore(value: 0)
    var callCount: Int { calls.withLock { $0 } }
    func release() { resume.signal() }
    func classify(_ session: SessionRecord) -> TimelineClassification {
        let count = calls.withLock { value in
            value += 1
            return value
        }
        if count == 1 { resume.wait() }
        return TimelineClassificationService().classify(session)
    }
}
