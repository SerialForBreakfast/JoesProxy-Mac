//
//  CaptureWorkspaceViewModel.swift
//  JoesProxy
//
//  Manages session display state for the Capture workspace (table + explorer).
//
//  Architecture:
//  - Subscribes to SessionStore and maintains an incremental summary cache.
//  - All heavy computation (filter, sort, explorer tree build) runs on a detached
//    Task so the MainActor stays free during live-capture bursts.
//  - Rapid store changes share a fixed 75ms deadline before snapshot collection;
//    changes during analysis cancel stale work and schedule the next window.
//  - WorkspaceSessionContext packages a Sendable value snapshot for each pass,
//    satisfying the compiler's actor-isolation requirements without manual locks.
//

import Combine
import Foundation
import Observation
import os

/// `@Observable`: SwiftUI tracks per-property access, so during live capture only views
/// that actually read capture state re-evaluate — the old `objectWillChange` rebroadcast
/// into ProxyViewModel (which invalidated the whole ContentView tree ~13×/sec) is gone.
/// The `ObservableObject` conformance remains only to satisfy `WorkspaceViewModelProtocol`;
/// with no `@Published` properties its publisher never fires.
@MainActor
@Observable
final class CaptureWorkspaceViewModel: ObservableObject {
    private struct RetiredPresentationState: Sendable {
        let filteredSessionIDs: [SessionRecord.ID]
        let sessionSummaries: [SessionSummary]
        let explorerTree: SessionExplorerTree
        let explorerVisibleRows: [SessionExplorerVisibleRow]
        let timelineAnalysisResult: TimelineAnalysisResult
        let displayedSessionIDsCache: [SessionRecord.ID]
        let displayedSummariesCache: [SessionSummary]
        let searchTextCacheByID: [SessionRecord.ID: String]
        let sessionSummaryCacheByID: [SessionRecord.ID: SessionSummary]
        let filteredIndexByID: [SessionRecord.ID: Int]
        let explorerSessionSummariesByNodeID: [String: [SessionSummary]]
        let timelineAnalysisCache: TimelineAnalysisCache
        let timelineDirtyIDs: Set<SessionRecord.ID>
        let classifiedTimelineEvents: [TimelineEvent]
        let cachedMediaSummary: MediaTimelineSummary?
    }

    // MARK: - FilterableWorkspace inputs

    var filterCriteria: SessionFilterCriteria = SessionFilterCriteria() {
        didSet {
            guard oldValue != filterCriteria else { return }
            canExtendFilteredSessionsIncrementally = false
            scheduleRecompute()
        }
    }

    var searchText: String = "" {
        didSet {
            trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            canExtendFilteredSessionsIncrementally = false
            scheduleRecompute()
        }
    }

    private var trimmedSearchText: String = ""

    var sortField: WorkspaceSortField = .startedAt {
        didSet {
            guard oldValue != sortField else { return }
            canExtendFilteredSessionsIncrementally = false
            scheduleRecompute()
        }
    }

    var isSortAscending: Bool = false {
        didSet {
            guard oldValue != isSortAscending else { return }
            scheduleRecompute()
        }
    }

    // MARK: - Explorer inputs

    /// Only expensive Inspector presentation is suspended. Shared summaries and capture stay live.
    private(set) var isInspectorPresentationActive = true

    func setInspectorPresentationActive(_ active: Bool) {
        guard active != isInspectorPresentationActive else { return }
        isInspectorPresentationActive = active
        if active {
            scheduleDownstreamWorkAfterRecompute()
        } else {
            explorerWorkGeneration &+= 1
            explorerRebuildTask?.cancel()
            explorerNeedsRebuild = true
            explorerRebuildPending = false
            invalidateTimelineWork()
        }
    }

    var browserMode: SessionBrowserMode = .table {
        didSet {
            guard oldValue != browserMode else { return }
            if oldValue == .timeline { invalidateTimelineWork() }
            if oldValue == .explorer {
                explorerWorkGeneration &+= 1
                explorerRebuildTask?.cancel()
                explorerNeedsRebuild = true
                explorerRebuildPending = false
            }
            if browserMode == .explorer, explorerNeedsRebuild {
                scheduleExplorerRebuild()
            }
            if browserMode == .timeline, timelineNeedsAnalysis {
                scheduleTimelineAnalysis()
            }
        }
    }

    var explorerGrouping: SessionExplorerGrouping = .byHost {
        didSet {
            guard oldValue != explorerGrouping else { return }
            scheduleExplorerRebuildIfActive()
        }
    }

    var explorerHostGrouping: SessionExplorerHostGrouping = .exactHosts {
        didSet {
            guard oldValue != explorerHostGrouping else { return }
            scheduleExplorerRebuildIfActive()
        }
    }

    var explorerExpandedNodeIDs: Set<String> = [] {
        didSet { rebuildExplorerVisibleRows() }
    }

    private(set) var selectedSessionContentRevision: UInt64 = 0

    var selectedSessionID: SessionRecord.ID? {
        didSet {
            guard oldValue != selectedSessionID else { return }
            selectedSessionContentRevision &+= 1
            if timelineFilterState.aroundSelection != .off {
                applyTimelineFilterIfActive()
            }
        }
    }

    var timelineFilterState: TimelineFilterState = .empty {
        didSet {
            guard oldValue != timelineFilterState else { return }
            applyTimelineFilterIfActive()
        }
    }

    var timelinePins: [TimelinePin] = [] {
        didSet {
            guard oldValue != timelinePins else { return }
            scheduleTimelineAnalysisIfActive() // pins change isPinned on events; needs re-classify
        }
    }

    // MARK: - Published outputs

    private(set) var filteredSessionIDs: [SessionRecord.ID] = []
    private(set) var sessionSummaries: [SessionSummary] = []
    private(set) var explorerTree: SessionExplorerTree = .empty
    private(set) var explorerVisibleRows: [SessionExplorerVisibleRow] = []
    private(set) var explorerRevision: UInt64 = 0
    private(set) var timelineAnalysisResult: TimelineAnalysisResult = .empty
    private(set) var isAnalyzingTimeline: Bool = false
    private(set) var isRecomputing: Bool = false
    private(set) var visibleLimit: Int = SessionTablePresentation.liveCaptureInitialVisibleSessionCount
    /// Set by `ProxyViewModel` from live proxy runtime state. The 500-row live-capture window
    /// only applies while capture is actively running; once stopped, `displayedSessions`/
    /// `displayedSummaries` show every retained session so nothing is hidden during review.
    var isCaptureActive: Bool = false

    // MARK: - Computed outputs

    var filteredSessions: [SessionRecord] {
        filteredSessionIDs.compactMap { store.record(for: $0) }
    }

    var displayedRowIdentities: [SessionTableRowPresentation] {
        _ = filteredSessionIDs.count
        let key = DisplayedSessionsKey(
            revision: filteredSessionsRevision,
            ascending: isSortAscending,
            visibleLimit: visibleLimit,
            windowing: isWindowingActive,
            selectedSessionID: selectedSessionID
        )
        if key == displayedRowIdentitiesCacheKey { return displayedRowIdentitiesCache }
        let ids: [SessionRecord.ID]
        if isWindowingActive {
            ids = SessionTablePresentation.displayedSessionsPinningSelection(
                from: filteredSessionIDs, visibleLimit: visibleLimit,
                newestFirst: !isSortAscending, selectedIndex: selectedSessionIndex)
        } else {
            ids = isSortAscending ? filteredSessionIDs : Array(filteredSessionIDs.reversed())
        }
        var nextRows: [SessionRecord.ID: SessionTableRowPresentation] = [:]
        nextRows.reserveCapacity(ids.count)
        displayedRowIdentitiesCache = ids.compactMap { id in
            guard let summary = sessionSummaryCacheByID[id] else { return nil }
            let row = tableRowPresentationsByID[id] ?? SessionTableRowPresentation(summary: summary)
            nextRows[id] = row
            return row
        }
        tableRowPresentationsByID = nextRows
        displayedRowIdentitiesCacheKey = key
        return displayedRowIdentitiesCache
    }

    var displayedSessions: [SessionRecord] {
        _ = filteredSessionIDs.count
        // Memoized: SwiftUI reads this from view bodies on every render pulse, and the
        // reversed-copy allocation is O(n). The key covers every input the computation
        // reads; revision ints avoid whole-array comparisons.
        let key = DisplayedSessionsKey(
            revision: filteredSessionsRevision,
            ascending: isSortAscending,
            visibleLimit: visibleLimit,
            windowing: isWindowingActive,
            selectedSessionID: selectedSessionID
        )
        if key == displayedSessionIDsCacheKey {
            return displayedSessionIDsCache.compactMap { store.record(for: $0) }
        }

        let newestFirst = !isSortAscending
        let computedIDs: [SessionRecord.ID]
        if isWindowingActive {
            computedIDs = SessionTablePresentation.displayedSessionsPinningSelection(
                from: filteredSessionIDs,
                visibleLimit: visibleLimit,
                newestFirst: newestFirst,
                selectedIndex: selectedSessionIndex
            )
        } else {
            computedIDs = newestFirst ? Array(filteredSessionIDs.reversed()) : filteredSessionIDs
        }
        displayedSessionIDsCache = computedIDs
        displayedSessionIDsCacheKey = key
        return computedIDs.compactMap { store.record(for: $0) }
    }

    /// Summary counterpart to `displayedSessions` — same windowing/reversal applied to
    /// `sessionSummaries` (assigned in the same recompute, so the same key is valid).
    /// The session table renders from this so rows never hold full records.
    var displayedSummaries: [SessionSummary] {
        _ = sessionSummaries.count
        let key = DisplayedSessionsKey(
            revision: filteredSessionsRevision,
            ascending: isSortAscending,
            visibleLimit: visibleLimit,
            windowing: isWindowingActive,
            selectedSessionID: selectedSessionID
        )
        if key == displayedSummariesCacheKey {
            return displayedSummariesCache
        }

        let newestFirst = !isSortAscending
        let computed: [SessionSummary]
        if isWindowingActive {
            computed = SessionTablePresentation.displayedSessionsPinningSelection(
                from: sessionSummaries,
                visibleLimit: visibleLimit,
                newestFirst: newestFirst,
                selectedIndex: selectedSessionIndex
            )
        } else {
            computed = newestFirst ? Array(sessionSummaries.reversed()) : sessionSummaries
        }
        displayedSummariesCache = computed
        displayedSummariesCacheKey = key
        return computed
    }

    /// Position of the current selection within `filteredSessionIDs`/`sessionSummaries` (the
    /// two are always index-parallel — see `runRecompute()`/`applyIncrementalAppend`), or nil
    /// if there is no selection or it isn't currently in the filtered set (filtered out, or
    /// dropped by retention eviction). Either way, nil correctly means "never pin this."
    private var selectedSessionIndex: Int? {
        guard let selectedSessionID else { return nil }
        return filteredIndexByID[selectedSessionID]
    }

    private struct DisplayedSessionsKey: Equatable {
        let revision: UInt64
        let ascending: Bool
        let visibleLimit: Int
        let windowing: Bool
        let selectedSessionID: SessionRecord.ID?
    }

    // Memoization storage is written from inside computed getters during view-body
    // evaluation — it must be @ObservationIgnored or those writes would invalidate the
    // observing views mid-evaluation and loop. The getters' outputs are still tracked
    // through the tracked inputs they read (filteredSessions, visibleLimit, …).
    @ObservationIgnored private var displayedSessionIDsCache: [SessionRecord.ID] = []
    @ObservationIgnored private var displayedSessionIDsCacheKey: DisplayedSessionsKey?
    @ObservationIgnored private var displayedSummariesCache: [SessionSummary] = []
    @ObservationIgnored private var displayedSummariesCacheKey: DisplayedSessionsKey?
    @ObservationIgnored private var displayedRowIdentitiesCache: [SessionTableRowPresentation] = []
    @ObservationIgnored private var displayedRowIdentitiesCacheKey: DisplayedSessionsKey?
    @ObservationIgnored private var tableRowPresentationsByID: [SessionRecord.ID: SessionTableRowPresentation] = [:]
    /// Bumped on every filtered-session ID assignment; stands in for array identity.
    @ObservationIgnored private var filteredSessionsRevision: UInt64 = 0
    /// True once a recompute has established that `filteredSessionIDs` is an exact,
    /// in-order ID prefix of `allSessions` (capture order, no filter/search/sort active).
    /// While true, a later recompute that's still fast-path-eligible can extend
    /// `filteredSessionIDs`/`filteredIndexByID`/`sessionSummaries` with just the sessions
    /// appended since then (O(appended)) instead of rebuilding both O(n) structures from
    /// scratch on every 75ms pulse. Any drop, update, or filter/search/sort change breaks
    /// the prefix guarantee and must reset this to false.
    private var canExtendFilteredSessionsIncrementally = false

    /// Lowercased searchable blobs (fields + joined headers) built lazily by search-active
    /// filter passes, one per session lifetime. Evicted when a session's record changes.
    private var searchTextCacheByID: [SessionRecord.ID: String] = [:]
    /// Bumped on every eviction so an in-flight recompute can't merge back stale blobs.
    private var searchTextCacheEpoch: UInt64 = 0

    private func evictSearchTextEntries<IDs: Sequence>(ids: IDs) where IDs.Element == SessionRecord.ID {
        var evictedAny = false
        for id in ids where searchTextCacheByID.removeValue(forKey: id) != nil {
            evictedAny = true
        }
        if evictedAny {
            searchTextCacheEpoch &+= 1
        }
    }

    var hiddenSessionCount: Int {
        guard isWindowingActive else { return 0 }
        let total = filteredSessionIDs.count
        let baseHidden = SessionTablePresentation.hiddenSessionCount(totalCount: total, visibleLimit: visibleLimit)
        // A pinned selection is displayed even though it's outside the natural window, so it
        // must not also be counted as hidden. Computed independently of the memoized displayed
        // arrays (rather than `total - displayedSessionIDsCache.count`) so this doesn't depend
        // on the memoized getter having already run this cycle.
        guard baseHidden > 0,
              let index = selectedSessionIndex,
              !SessionTablePresentation.isIndexWithinWindow(
                index: index,
                totalCount: total,
                visibleLimit: visibleLimit,
                newestFirst: !isSortAscending
              )
        else {
            return baseHidden
        }
        return baseHidden - 1
    }

    var filteredOutCount: Int {
        max(0, allSessions.count - filteredSessionIDs.count)
    }

    var hasVisibleSessions: Bool { !filteredSessionIDs.isEmpty }
    var hasSessions: Bool { !allSessions.isEmpty }
    var filteredSessionCount: Int { filteredSessionIDs.count }

    // MARK: - Public session accessors (read by ProxyViewModel for Find, export, health metrics)

    /// Passthrough to the store's array — a CoW reference, not a copy. The store is the
    /// sole long-lived owner of full records; this workspace keeps only summaries/IDs.
    var allSessions: [SessionRecord] { store.sessions }
    var totalCount: Int { store.sessions.count }

    func visibleSession(for id: SessionRecord.ID) -> SessionRecord? {
        guard filteredIndexByID[id] != nil else { return nil }
        return store.record(for: id)
    }

    func sessionRecord(for id: SessionRecord.ID) -> SessionRecord? {
        store.record(for: id)
    }

    func visibleSessions(for ids: [SessionRecord.ID]) -> [SessionRecord] {
        ids.compactMap { id in
            guard filteredIndexByID[id] != nil else { return nil }
            return store.record(for: id)
        }
           .sorted { $0.timing.startedAt > $1.timing.startedAt }
    }

    func visibleSessionSummaries(for ids: [SessionRecord.ID]) -> [SessionSummary] {
        ids.compactMap { sessionSummaryCacheByID[$0] }
           .sorted { $0.startedAt > $1.startedAt }
    }

    func newestVisibleSessionID() -> SessionRecord.ID? {
        if canUseFastPath {
            return filteredSessionIDs.last
        }

        return sessionSummaries.max { $0.startedAt < $1.startedAt }?.id
    }

    func explorerSessionSummaries(for nodeID: String) -> [SessionSummary] {
        // Read tracked inputs even on cache hits; memoization itself must not invalidate views.
        guard let node = explorerTree.node(id: nodeID), node.isFolder else { return [] }
        let summaries = sessionSummaryCacheByID
        if let cached = explorerSessionSummariesByNodeID[nodeID] { return cached }
        let result = node.sessionIDs.compactMap { summaries[$0] }
            .sorted { $0.startedAt > $1.startedAt }
        explorerSessionSummariesByNodeID = [nodeID: result]
        return result
    }

    func isSessionVisible(_ id: SessionRecord.ID) -> Bool {
        filteredIndexByID[id] != nil
    }

    // MARK: - Explorer rebuild callback

    /// Called on MainActor after each explorer tree rebuild completes.
    /// ProxyViewModel uses this to close its mode-switch performance interval.
    @ObservationIgnored var onExplorerRebuildComplete: (() -> Void)?

    /// Called on MainActor after every recompute publishes a new `filteredSessions`.
    /// Replaces the former `$filteredSessions` Combine sink (gone with @Observable);
    /// ProxyViewModel uses this to reconcile the selection against the visible set.
    @ObservationIgnored var onFilteredSessionsChanged: (() -> Void)?

    // MARK: - Private session state

    private var sessionSummaryCacheByID: [SessionRecord.ID: SessionSummary] = [:]
    private var filteredIndexByID: [SessionRecord.ID: Int] = [:]
    @ObservationIgnored private var explorerSessionSummariesByNodeID: [String: [SessionSummary]] = [:]
    /// Logical entries, not allocated bytes: summaries may share underlying string storage.
    var cachedExplorerFolderCount: Int { explorerSessionSummariesByNodeID.count }
    var cachedExplorerSummaryCount: Int { explorerSessionSummariesByNodeID.values.reduce(0) { $0 + $1.count } }
    @ObservationIgnored private(set) var retentionPresentationSkipCount = 0
    @ObservationIgnored private var activeFilterSnapshots = 0
    @ObservationIgnored private var activeFilterSnapshotRecords = 0
    var retentionCounts: WorkspaceRetentionCounts {
        WorkspaceRetentionCounts(summaries: sessionSummaryCacheByID.count,
            filteredIDs: filteredSessionIDs.count, tableRows: tableRowPresentationsByID.count,
            searchTexts: searchTextCacheByID.count, explorerFolders: cachedExplorerFolderCount,
            explorerSummaries: cachedExplorerSummaryCount,
            retentionPresentationSkips: retentionPresentationSkipCount,
            activeFilterSnapshots: activeFilterSnapshots,
            activeFilterSnapshotRecords: activeFilterSnapshotRecords)
    }

    // MARK: - Recompute coalescing

    private var pendingRecompute: Task<Void, Never>?
    private var recomputeGeneration: UInt64 = 0
    @ObservationIgnored private var isRecomputeWaitingForDeadline = false
    @ObservationIgnored var recomputeCheckpoint: @Sendable () throws -> Void = {}

    // MARK: - Explorer rebuild state

    private var explorerRebuildTask: Task<Void, Never>?
    private var explorerNeedsRebuild: Bool = true
    private var explorerRebuildPending: Bool = false
    private var explorerWorkGeneration: UInt64 = 0
    @ObservationIgnored var explorerBuildCheckpoint: @Sendable () async -> Void = {}
    @ObservationIgnored private(set) var explorerBuildCount = 0
    private(set) var isRebuildingExplorer: Bool = false

    private var timelineAnalysisTask: Task<Void, Never>?
    private var timelineFilterTask: Task<Void, Never>?
    private var timelineWorkGeneration: UInt64 = 0
    private var timelineNeedsFilter = false
    private var timelineRequiresFullFingerprint = false
    @ObservationIgnored var timelineSleep: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }
    @ObservationIgnored var timelineAnalyzer = TimelineAnalyzer()
    @ObservationIgnored private(set) var timelineSnapshotCount = 0
    private var timelineNeedsAnalysis: Bool = true
    private var timelineAnalysisCache = TimelineAnalysisCache()
    /// Session IDs whose records changed since the timeline cache last updated. Lets the
    /// analysis pass reuse classified events for clean sessions without recomputing
    /// per-session fingerprints (header sorts). Drained at snapshot time so a second update
    /// to the same ID survives; invalidated passes require full fingerprint checking.
    private var timelineDirtyIDs: Set<SessionRecord.ID> = []
    private var classifiedTimelineEvents: [TimelineEvent] = []
    private var cachedMediaSummary: MediaTimelineSummary?
    private var timelineCaptureStart: Date?
    private var timelineCaptureEnd: Date?

    // MARK: - Infrastructure

    private let store: any SessionStore
    private var isPresentationStopped = false
    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "com.JoesProxyApp.UI", category: "CaptureWorkspace")

    // MARK: - Init

    init(store: any SessionStore) {
        self.store = store
        let initialSessions = store.sessions
        let initialSummaries = initialSessions.map(SessionSummary.init(record:))
        sessionSummaryCacheByID = Dictionary(
            uniqueKeysWithValues: initialSummaries.map { ($0.id, $0) }
        )
        visibleLimit = SessionTablePresentation.initialVisibleLimit(for: initialSessions.count)
        filteredSessionIDs = initialSessions.map(\.id)
        sessionSummaries = initialSummaries
        filteredIndexByID = Dictionary(
            uniqueKeysWithValues: filteredSessionIDs.enumerated().map { ($0.element, $0.offset) }
        )
        filteredSessionsRevision = 1
        canExtendFilteredSessionsIncrementally = true

        store.sessionChangesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.applyStoreChange(change)
            }
            .store(in: &cancellables)
        AgentWorkspaceDiagnostics.shared.recordInspectorSubscription()
    }

    // MARK: - Public actions

    /// Terminal teardown for a discarded Inspector. Shared capture/query owners remain alive.
    func stopPresentation() {
        isPresentationStopped = true
        setInspectorPresentationActive(false)
        pendingRecompute?.cancel()
        pendingRecompute = nil
        explorerRebuildTask?.cancel()
        explorerRebuildTask = nil
        invalidateTimelineWork()
        cancellables.removeAll()
    }

    func showMoreSessions() {
        let next = SessionTablePresentation.nextVisibleLimit(
            currentLimit: visibleLimit,
            totalCount: filteredSessionIDs.count
        )
        guard next != visibleLimit else { return }
        visibleLimit = next
    }

    func summaryLookup(for id: SessionRecord.ID) -> SessionSummary? {
        sessionSummaryCacheByID[id]
    }

    // MARK: - Store change application

    /// The store already applied the mutation before publishing, and `allSessions` is a
    /// passthrough to it — this only maintains the workspace's derived caches.
    private func applyStoreChange(_ change: SessionStoreChange) {
        // A main-queue delivery already scheduled before cancellation may still arrive.
        guard !isPresentationStopped else { return }
        explorerSessionSummariesByNodeID = [:]
        if let inspectedID = selectedSessionID ?? newestVisibleSessionID(),
           change.affectsInspection(of: inspectedID) {
            selectedSessionContentRevision &+= 1
        }
        switch change {
        case .appended(let session, let droppedIDs):
            applyDrops(droppedIDs)
            let summary = SessionSummary(record: session)
            sessionSummaryCacheByID[session.id] = summary
            tableRowPresentationsByID[session.id]?.update(summary)
            timelineDirtyIDs.insert(session.id)
            if canUseFastPath, canExtendFilteredSessionsIncrementally, droppedIDs.isEmpty {
                let idx = filteredSessionIDs.count
                filteredSessionIDs.append(session.id)
                filteredIndexByID[session.id] = idx
                sessionSummaries.append(summary)
                filteredSessionsRevision &+= 1
                onFilteredSessionsChanged?()
                scheduleDownstreamWorkAfterRecompute()
            } else {
                scheduleRecompute()
            }

        case .updated(let session, let inserted):
            let summary = SessionSummary(record: session)
            sessionSummaryCacheByID[session.id] = summary
            tableRowPresentationsByID[session.id]?.update(summary)
            evictSearchTextEntries(ids: [session.id])
            timelineDirtyIDs.insert(session.id)
            if canUseFastPath, canExtendFilteredSessionsIncrementally, !inserted, let idx = filteredIndexByID[session.id], idx < sessionSummaries.count {
                sessionSummaries[idx] = summary
                filteredSessionsRevision &+= 1
                onFilteredSessionsChanged?()
                scheduleDownstreamWorkAfterRecompute()
            } else {
                canExtendFilteredSessionsIncrementally = false
                scheduleRecompute()
            }

        case .updatedBatch(let sessions, let insertedIDs):
            for session in sessions {
                let summary = SessionSummary(record: session)
                sessionSummaryCacheByID[session.id] = summary
                tableRowPresentationsByID[session.id]?.update(summary)
            }
            evictSearchTextEntries(ids: sessions.map(\.id))
            timelineDirtyIDs.formUnion(sessions.map(\.id))
            if canUseFastPath, canExtendFilteredSessionsIncrementally, insertedIDs.isEmpty {
                var modified = false
                for session in sessions {
                    if let idx = filteredIndexByID[session.id], idx < sessionSummaries.count {
                        sessionSummaries[idx] = sessionSummaryCacheByID[session.id] ?? SessionSummary(record: session)
                        modified = true
                    }
                }
                if modified {
                    filteredSessionsRevision &+= 1
                    onFilteredSessionsChanged?()
                    scheduleDownstreamWorkAfterRecompute()
                }
            } else {
                canExtendFilteredSessionsIncrementally = false
                scheduleRecompute()
            }

        case .bodiesStripped(let sessions):
            // Retention preserves every browser filter/sort/summary input. Only body-dependent
            // analysis must refresh; full-history presentation work is unnecessary here.
            timelineDirtyIDs.formUnion(sessions.map(\.id))
            retentionPresentationSkipCount &+= 1
            scheduleTimelineAnalysisIfActive()

        case .removed(let ids):
            applyDrops(ids)
            scheduleRecompute()

        case .cleared:
            applyImmediateClear()

        case .loaded(let sessions, _):
            invalidateTimelineWork()
            explorerWorkGeneration &+= 1
            explorerRebuildTask?.cancel()
            explorerNeedsRebuild = true
            sessionSummaryCacheByID = Self.makeCache(for: sessions)
            for (id, row) in tableRowPresentationsByID {
                if let summary = sessionSummaryCacheByID[id] { row.update(summary) }
            }
            tableRowPresentationsByID = tableRowPresentationsByID.filter { sessionSummaryCacheByID[$0.key] != nil }
            searchTextCacheByID = [:]
            searchTextCacheEpoch &+= 1
            timelineAnalysisCache = TimelineAnalysisCache()
            timelineDirtyIDs = []
            canExtendFilteredSessionsIncrementally = false
            resetVisibleLimit()
            scheduleRecompute()
        }
    }

    private func applyDrops(_ ids: Set<SessionRecord.ID>) {
        guard !ids.isEmpty else { return }
        ids.forEach {
            sessionSummaryCacheByID[$0] = nil
            tableRowPresentationsByID[$0] = nil
        }
        evictSearchTextEntries(ids: ids)
        // Retention dropped sessions from the front of the store — filteredSessionIDs is
        // no longer a verbatim prefix of allSessions, so the tail-append shortcut in
        // runRecompute() can't be trusted until the next full rebuild re-establishes it.
        canExtendFilteredSessionsIncrementally = false
    }

    /// Publishes the empty workspace immediately and retires large capture-derived caches
    /// off the main actor. A normal recompute is unnecessary because the store is already
    /// empty; the next append schedules its own recompute.
    private func applyImmediateClear() {
        recomputeGeneration &+= 1
        pendingRecompute?.cancel()
        isRecomputeWaitingForDeadline = false
        explorerRebuildTask?.cancel()
        explorerWorkGeneration &+= 1
        invalidateTimelineWork()

        let retiredState = RetiredPresentationState(
            filteredSessionIDs: filteredSessionIDs,
            sessionSummaries: sessionSummaries,
            explorerTree: explorerTree,
            explorerVisibleRows: explorerVisibleRows,
            timelineAnalysisResult: timelineAnalysisResult,
            displayedSessionIDsCache: displayedSessionIDsCache,
            displayedSummariesCache: displayedSummariesCache,
            searchTextCacheByID: searchTextCacheByID,
            sessionSummaryCacheByID: sessionSummaryCacheByID,
            filteredIndexByID: filteredIndexByID,
            explorerSessionSummariesByNodeID: explorerSessionSummariesByNodeID,
            timelineAnalysisCache: timelineAnalysisCache,
            timelineDirtyIDs: timelineDirtyIDs,
            classifiedTimelineEvents: classifiedTimelineEvents,
            cachedMediaSummary: cachedMediaSummary
        )

        pendingRecompute = nil
        timelineAnalysisTask = nil
        timelineFilterTask = nil

        filteredSessionIDs = []
        sessionSummaries = []
        explorerTree = .empty
        explorerVisibleRows = []
        explorerRevision &+= 1
        timelineAnalysisResult = .empty
        isRecomputing = false
        isRebuildingExplorer = false
        explorerRebuildPending = false
        explorerNeedsRebuild = true
        isAnalyzingTimeline = false
        timelineNeedsAnalysis = true
        visibleLimit = SessionTablePresentation.liveCaptureInitialVisibleSessionCount

        displayedSessionIDsCache = []
        displayedSessionIDsCacheKey = nil
        displayedSummariesCache = []
        displayedSummariesCacheKey = nil
        displayedRowIdentitiesCache = []
        displayedRowIdentitiesCacheKey = nil
        tableRowPresentationsByID = [:]
        filteredSessionsRevision &+= 1
        canExtendFilteredSessionsIncrementally = false

        searchTextCacheByID = [:]
        searchTextCacheEpoch &+= 1
        sessionSummaryCacheByID = [:]
        filteredIndexByID = [:]
        explorerSessionSummariesByNodeID = [:]
        timelineAnalysisCache = TimelineAnalysisCache()
        timelineDirtyIDs = []
        classifiedTimelineEvents = []
        cachedMediaSummary = nil
        timelineCaptureStart = nil
        timelineCaptureEnd = nil

        DeferredRelease.schedule(retiredState)
        onFilteredSessionsChanged?()
    }

    // MARK: - Coalesced filter/sort recompute

    /// MainActor owns the deadline. Arrivals and criteria changes during the window use the
    /// latest state at snapshot time without postponing presentation indefinitely. Changes
    /// during detached analysis still cancel that stale generation before scheduling a new pass.
    private func scheduleRecompute() {
        guard !isRecomputeWaitingForDeadline else { return }
        recomputeGeneration &+= 1
        let generation = recomputeGeneration
        pendingRecompute?.cancel()
        isRecomputeWaitingForDeadline = true
        pendingRecompute = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(75))
            } catch {
                return
            }
            guard !Task.isCancelled, self.recomputeGeneration == generation else { return }
            self.isRecomputeWaitingForDeadline = false
            await self.runRecompute(generation: generation)
            if self.recomputeGeneration == generation { self.pendingRecompute = nil }
        }
    }

    private func runRecompute(generation: UInt64) async {
        let fastPath = canUseFastPath
        let currentTotal = allSessions.count

        // Append-only fast path: the previous recompute already proved filteredSessionIDs
        // is an exact ID-order prefix of allSessions. If we're still fast-path-eligible,
        // the only sessions that can have changed are ones appended after that prefix —
        // extend the filtered index/summaries with just those (O(appended)) instead of
        // paying O(n) to rebuild both every ~75ms pulse. Runs synchronously (no detached
        // Task) since it's cheap and there's nothing to filter/sort.
        if fastPath, canExtendFilteredSessionsIncrementally {
            if currentTotal > filteredSessionIDs.count {
                applyIncrementalAppend(newSessions: allSessions[filteredSessionIDs.count...])
                onFilteredSessionsChanged?()
                scheduleDownstreamWorkAfterRecompute()
            }
            // currentTotal == count: a recompute was scheduled but nothing actually
            // changed the filtered set (shouldn't normally happen — every scheduleRecompute()
            // caller either appends or invalidates the flag — but a no-op skip is safe).
            return
        }

        // Snapshot Sendable values on MainActor before leaving isolation.
        let ctx = WorkspaceSessionContext(sessions: allSessions, summaries: sessionSummaryCacheByID)
        // Keep retired generations accounted until their detached work actually returns.
        activeFilterSnapshots += 1
        activeFilterSnapshotRecords += ctx.sessions.count
        defer {
            activeFilterSnapshots -= 1
            activeFilterSnapshotRecords -= ctx.sessions.count
        }
        let criteria = filterCriteria
        let search = trimmedSearchText.lowercased()
        let field = sortField
        let ascending = isSortAscending
        let searchTextsSnapshot = searchTextCacheByID
        let searchTextEpochAtSnapshot = searchTextCacheEpoch

        isRecomputing = true

        // Cancellation is forwarded to the detached worker so retired body snapshots stop
        // filtering promptly. Only the current generation owns publication and task state.
        let checkpoint = recomputeCheckpoint
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try checkpoint()
            try Task.checkCancellation()
            let filtered: [SessionRecord]
            var searchTexts = searchTextsSnapshot
            if fastPath {
                filtered = ctx.sessions // already in capture order, no work needed
            } else {
                let engine = SessionFilterEngine()
                let f = try engine.filter(ctx.sessions, criteria: criteria, searchText: search,
                    searchTextCache: &searchTexts, cancellationCheck: { try Task.checkCancellation() })
                filtered = try Self.sort(f, by: field, ascending: ascending)
            }
            let sums = try filtered.map {
                try Task.checkCancellation()
                return ctx.summaries[$0.id] ?? SessionSummary(record: $0)
            }
            return (filtered, sums, searchTexts)
        }
        let output = try? await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }

        guard !Task.isCancelled, recomputeGeneration == generation,
              let (sorted, summaries, builtSearchTexts) = output else {
            if recomputeGeneration == generation { isRecomputing = false }
            return
        }

        // Adopt lazily built search blobs only if no invalidation raced this recompute —
        // a stale merge would resurrect blobs for sessions that changed mid-flight.
        if !search.isEmpty, searchTextCacheEpoch == searchTextEpochAtSnapshot {
            if builtSearchTexts.count > 2000 {
                searchTextCacheByID = Dictionary(uniqueKeysWithValues: Array(builtSearchTexts.suffix(2000)))
            } else {
                searchTextCacheByID = builtSearchTexts
            }
        } else if search.isEmpty, !searchTextCacheByID.isEmpty {
            searchTextCacheByID = [:]
            searchTextCacheEpoch &+= 1
        }

        let sortedIDs = sorted.map(\.id)
        filteredSessionIDs = sortedIDs
        filteredSessionsRevision &+= 1
        filteredIndexByID = Dictionary(
            uniqueKeysWithValues: sortedIDs.enumerated().map { ($0.element, $0.offset) }
        )
        sessionSummaries = summaries
        isRecomputing = false
        // Fast path re-establishes the ID-prefix invariant the incremental branch above
        // depends on; a filtered/sorted pass does not.
        canExtendFilteredSessionsIncrementally = fastPath
        onFilteredSessionsChanged?()
        scheduleDownstreamWorkAfterRecompute()
    }

    /// Extends `filteredSessionIDs`/`filteredIndexByID`/`sessionSummaries` with sessions
    /// appended since the last recompute, without touching the existing entries. Only
    /// valid when `canExtendFilteredSessionsIncrementally` holds (see its doc comment).
    private func applyIncrementalAppend(newSessions: ArraySlice<SessionRecord>) {
        var nextIndex = filteredSessionIDs.count
        filteredSessionIDs.reserveCapacity(filteredSessionIDs.count + newSessions.count)
        sessionSummaries.reserveCapacity(sessionSummaries.count + newSessions.count)
        for session in newSessions {
            filteredSessionIDs.append(session.id)
            filteredIndexByID[session.id] = nextIndex
            sessionSummaries.append(sessionSummaryCacheByID[session.id] ?? SessionSummary(record: session))
            nextIndex += 1
        }
        filteredSessionsRevision &+= 1
    }

    private func scheduleDownstreamWorkAfterRecompute() {
        scheduleExplorerRebuildIfActive()
        scheduleTimelineAnalysisIfActive()
    }

    // MARK: - Explorer rebuild

    private func scheduleExplorerRebuildIfActive() {
        if browserMode == .explorer {
            scheduleExplorerRebuild()
        } else {
            explorerNeedsRebuild = true
        }
    }

    private func scheduleExplorerRebuild() {
        explorerNeedsRebuild = true
        guard isInspectorPresentationActive, browserMode == .explorer,
              !isRecomputing, !isRecomputeWaitingForDeadline else { return }
        // If a build is already running, queue one follow-up rather than cancelling.
        // Cancelling mid-build discards work already done on the detached task.
        guard explorerRebuildTask == nil else {
            explorerRebuildPending = true
            return
        }

        let summaries = sessionSummaries
        let grouping = explorerGrouping
        let hostGrouping = explorerHostGrouping
        let generation = explorerWorkGeneration
        let checkpoint = explorerBuildCheckpoint

        isRebuildingExplorer = true
        explorerBuildCount &+= 1

        explorerRebuildTask = Task { [weak self] in
            let work = Task.detached(priority: .utility) {
                await checkpoint()
                return SessionExplorerBuilder.build(from: summaries, grouping: grouping,
                    hostGrouping: hostGrouping, isCancelled: { Task.isCancelled })
            }
            let tree = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard let self else { return }
            // Keep the worker slot occupied until detached work actually exits, including
            // across Clear and tab changes. Old generations never publish or clear new state.
            self.explorerRebuildTask = nil
            self.isRebuildingExplorer = false

            if !Task.isCancelled, self.isInspectorPresentationActive, self.explorerWorkGeneration == generation,
               self.browserMode == .explorer, self.explorerGrouping == grouping,
               self.explorerHostGrouping == hostGrouping {
                self.explorerTree = tree
                self.explorerSessionSummariesByNodeID = [:]
                self.explorerNeedsRebuild = self.explorerRebuildPending
                self.rebuildExplorerVisibleRows()
                self.explorerRevision &+= 1
                self.onExplorerRebuildComplete?()
            }

            self.explorerRebuildPending = false
            if self.browserMode == .explorer, self.explorerNeedsRebuild {
                self.scheduleExplorerRebuild()
            }
        }
    }

    private func rebuildExplorerVisibleRows() {
        explorerVisibleRows = explorerTree.visibleRows(expandedNodeIDs: explorerExpandedNodeIDs)
    }

    // MARK: - Timeline analysis

    private func scheduleTimelineAnalysisIfActive() {
        if browserMode == .timeline {
            scheduleTimelineAnalysis()
        } else {
            timelineNeedsAnalysis = true
        }
    }

    private func applyTimelineFilterIfActive() {
        if isInspectorPresentationActive, browserMode == .timeline {
            applyTimelineFilter()
        } else {
            timelineNeedsAnalysis = true
        }
    }

    /// MainActor owns scheduling and cache publication. Live changes queue one follow-up;
    /// only lifecycle invalidation cancels detached work and prevents its publication.
    private func invalidateTimelineWork() {
        timelineWorkGeneration &+= 1
        timelineAnalysisTask?.cancel()
        timelineFilterTask?.cancel()
        timelineAnalysisTask = nil
        timelineFilterTask = nil
        timelineNeedsAnalysis = true
        timelineNeedsFilter = false
        isAnalyzingTimeline = false
        // A cancelled pass may have consumed its dirty set. Recheck all fingerprints.
        timelineRequiresFullFingerprint = true
    }

    /// Fixed coalescing deadline; snapshots are collected only when the pass starts.
    private func scheduleTimelineAnalysis() {
        timelineNeedsAnalysis = true
        guard isInspectorPresentationActive, browserMode == .timeline else { return }
        guard timelineAnalysisTask == nil else { return }
        let generation = timelineWorkGeneration
        let sleep = timelineSleep
        let coalescence: Duration = classifiedTimelineEvents.isEmpty ? .milliseconds(75) : .milliseconds(250)
        isAnalyzingTimeline = true

        timelineAnalysisTask = Task { [weak self] in
            do { try await sleep(coalescence) } catch { return }
            guard let self, !Task.isCancelled,
                  self.timelineWorkGeneration == generation,
                  self.browserMode == .timeline else { return }
            let sessions = self.filteredSessions
            let pins = self.timelinePins
            let cache = self.timelineAnalysisCache
            let dirtyIDs: Set<SessionRecord.ID>? = self.timelineRequiresFullFingerprint ? nil : self.timelineDirtyIDs
            self.timelineRequiresFullFingerprint = false
            self.timelineDirtyIDs = []
            self.timelineNeedsAnalysis = false
            self.timelineSnapshotCount += 1

            let spState = CapturePerformanceSignposts.signposter.beginInterval("timeline-analysis")
            defer { CapturePerformanceSignposts.signposter.endInterval("timeline-analysis", spState) }

            let analyzer = self.timelineAnalyzer
            let captureEpoch = self.store.liveCaptureEpoch
            let snapshotEpoch = captureEpoch.current
            let work = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                var nextCache = cache
                let cached = try nextCache.update(
                    sessions: sessions, pins: pins, dirtyIDs: dirtyIDs, analyzer: analyzer,
                    checkCancellation: {
                        try Task.checkCancellation()
                        guard captureEpoch.current == snapshotEpoch else { throw CancellationError() }
                    }
                )
                let events = cached.events
                try Task.checkCancellation()
                let media = MediaTimelineCorrelator().summarize(events: events)
                try Task.checkCancellation()
                let start = events.lazy.map(\.startedAt).min()
                let end = events.lazy.map(\.completedAt).max()
                return (nextCache, events, media, start, end)
            }
            let output = try? await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, self.timelineWorkGeneration == generation,
                  let (nextCache, classified, mediaSummary, start, end) = output else { return }
            self.timelineAnalysisCache = nextCache
            self.classifiedTimelineEvents = classified
            self.cachedMediaSummary = mediaSummary
            self.timelineCaptureStart = start
            self.timelineCaptureEnd = end
            self.timelineAnalysisTask = nil
            self.applyTimelineFilter()
            if self.timelineNeedsAnalysis { self.scheduleTimelineAnalysis() }
        }
    }

    /// Phase 2: re-filter already-classified events (cheap). Called when filter or selection changes.
    private func applyTimelineFilter() {
        timelineNeedsFilter = true
        guard isInspectorPresentationActive, browserMode == .timeline else { return }
        guard timelineFilterTask == nil else { return }
        let generation = timelineWorkGeneration
        timelineFilterTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.timelineNeedsFilter = false
                let events = self.classifiedTimelineEvents
                let filter = self.timelineFilterState
                let selectedID = self.selectedSessionID
                let mediaSummary = self.cachedMediaSummary
                let start = self.timelineCaptureStart
                let end = self.timelineCaptureEnd
                let spState = CapturePerformanceSignposts.signposter.beginInterval("timeline-filter")
                defer { CapturePerformanceSignposts.signposter.endInterval("timeline-filter", spState) }
                let work = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    let result = TimelineAnalyzer().buildResult(
                        events: events,
                        filter: filter,
                        selectedSessionID: selectedID,
                        mediaSummary: mediaSummary,
                        captureStart: start,
                        captureEnd: end
                    )
                    try Task.checkCancellation()
                    return result
                }
                let result = try? await withTaskCancellationHandler {
                    try await work.value
                } onCancel: { work.cancel() }
                guard !Task.isCancelled, self.timelineWorkGeneration == generation else { return }
                // Serialized filter passes can publish useful intermediate capture results.
                // Newer events queue a follow-up, not an endless stream of discarded results.
                if filter == self.timelineFilterState,
                   (filter.aroundSelection == .off || selectedID == self.selectedSessionID),
                   let result {
                    self.timelineAnalysisResult = result
                    if self.timelineAnalysisTask == nil { self.isAnalyzingTimeline = false }
                }
            } while self.timelineNeedsFilter
            self.timelineFilterTask = nil
        }
    }

    // MARK: - Windowing

    private var isWindowingActive: Bool {
        isCaptureActive && canUseFastPath && filteredSessionIDs.count > visibleLimit
    }

    /// Fast path: capture order, no filter, no search. Skips sort+filter entirely.
    /// Internal so ProxyViewModel can read it for `selectNewestVisibleSession`.
    var canUseFastPath: Bool {
        filterCriteria.isEmpty && trimmedSearchText.isEmpty && sortField == .startedAt
    }

    private func resetVisibleLimit() {
        visibleLimit = SessionTablePresentation.initialVisibleLimit(for: allSessions.count)
    }

    // MARK: - Static helpers (nonisolated — called from detached Tasks)

    private nonisolated static func makeCache(for sessions: [SessionRecord]) -> [SessionRecord.ID: SessionSummary] {
        var cache: [SessionRecord.ID: SessionSummary] = [:]
        cache.reserveCapacity(sessions.count)
        for s in sessions { cache[s.id] = SessionSummary(record: s) }
        return cache
    }

    private nonisolated static func sort(
        _ sessions: [SessionRecord],
        by field: WorkspaceSortField,
        ascending: Bool
    ) throws -> [SessionRecord] {
        try sessions.sorted { lhs, rhs in
            try Task.checkCancellation()
            let cmp: ComparisonResult = switch field {
            case .startedAt:
                lhs.timing.startedAt.compare(rhs.timing.startedAt)
            case .host:
                lhs.request.host.localizedCaseInsensitiveCompare(rhs.request.host)
            case .method:
                lhs.request.method.localizedCaseInsensitiveCompare(rhs.request.method)
            case .statusCode:
                compareOptional(lhs.response?.statusCode, rhs.response?.statusCode)
            case .duration:
                compareOptional(lhs.timing.duration, rhs.timing.duration)
            }
            if cmp == .orderedSame {
                // Stable tie-break: most recent first
                return lhs.timing.startedAt > rhs.timing.startedAt
            }
            return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
    }

    private nonisolated static func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (l?, r?):
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
            return .orderedSame
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        }
    }
}

// MARK: - FilterableWorkspace

extension CaptureWorkspaceViewModel: FilterableWorkspace {}
