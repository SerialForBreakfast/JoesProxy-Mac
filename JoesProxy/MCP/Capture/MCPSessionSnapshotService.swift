import Combine
import Foundation

/// Snapshot index over ``SessionStore`` with capture epoch and keyset pagination semantics.
///
/// Concurrency: `@MainActor` because it observes ``SessionStore`` mutations on the main actor.
@MainActor
final class MCPSessionSnapshotService {
    struct IndexedSession: Equatable, Sendable {
        var record: SessionRecord
        var captureSequence: UInt64
    }

    struct CaptureCounts: Equatable, Sendable {
        var sessionCount: Int
        var completedCount: Int
        var pendingCount: Int
    }

    private struct IndexEntry: Equatable, Sendable {
        var id: SessionRecord.ID
        var captureSequence: UInt64
    }

    /// Optional filters for ``sessions_search``; all supplied predicates must match.
    struct ListFilter: Equatable, Sendable {
        var method: String?
        var hostCategory: String?
        var sessionIDPrefix: String?
        /// Case-insensitive substring match against the request host.
        var domain: String?
        /// Case-insensitive substring match against the request path.
        var pathContains: String?
        /// Inclusive lower bound on `SessionTiming.startedAt`.
        var startedAfter: Date?
        /// Inclusive upper bound on `SessionTiming.startedAt`.
        var startedBefore: Date?

        var isEmpty: Bool {
            method == nil && hostCategory == nil && sessionIDPrefix == nil
                && domain == nil && pathContains == nil
                && startedAfter == nil && startedBefore == nil
        }
    }

    struct PageRequest: Equatable, Sendable {
        var limit: Int
        var cursor: MCPSessionQueryCursor?
        var queryDigest: String
        var orderingDigest: String
        var filter: ListFilter?
        var minimumSequenceExclusive: UInt64 = 0
    }

    struct PageResult: Equatable, Sendable {
        var items: [IndexedSession]
        var nextCursor: MCPSessionQueryCursor?
        var highWaterSequence: UInt64
    }

    private(set) var captureEpoch: MCPCaptureEpoch = .initial
    private(set) var epochMetadata = CaptureEpochMetadata()
    private weak var markerService: CaptureMarkerService?
    private var indexEntries: [IndexEntry] = []
    private var indexEntriesByMethod: [String: [IndexEntry]] = [:]
    private var indexEntriesByHostCategory: [String: [IndexEntry]] = [:]
    private var indexEntriesByMethodAndHostCategory: [String: [IndexEntry]] = [:]
    private var sequenceByID: [SessionRecord.ID: UInt64] = [:]
    private var revisionByID: [SessionRecord.ID: UInt64] = [:]
    private var nextSourceRevision: UInt64 = 1

    /// Main-actor mutation identity, independent of capture ordering. Removed IDs retain no tombstone.
    /// The allocator is not reset on reload, so removing/reinserting a UUID cannot reuse its receipt.
    func sourceRevision(for id: UUID) -> UInt64? { revisionByID[id] }
    var retainedSourceRevisionCount: Int { revisionByID.count }

    func sourceRevisionScope(for ids: [UUID]) -> String {
        ids.map { "\($0.uuidString):\(revisionByID[$0].map(String.init) ?? "missing")" }.joined(separator: ",")
    }

    private func reviseSource(_ id: UUID) {
        revisionByID[id] = nextSourceRevision
        nextSourceRevision += 1
    }
    private var methodByID: [SessionRecord.ID: String] = [:]
    private var hostCategoryByID: [SessionRecord.ID: String] = [:]
    private var stateByID: [SessionRecord.ID: SessionLifecycleState] = [:]
    private var removedEntryCount = 0
    private var completedCount = 0
    private var pendingCount = 0
    private var nextSequence: UInt64 = 1
    /// Advances for every published store mutation, including same-sequence response/body updates.
    /// Global capture reads use this value; selected briefs use source revisions instead.
    private(set) var stateRevision: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []
    private let sessionStore: any SessionStore
    var sourceSessionStore: any SessionStore { sessionStore }

    /// Wires marker insertion for capture lifecycle events after initialization.
    func configureMarkerService(_ markerService: CaptureMarkerService) {
        self.markerService = markerService
    }

    /// Metadata about the most recent capture-epoch transition.
    struct CaptureEpochMetadata: Equatable, Sendable {
        var lastEpochChangeAt: Date?
        var lastEpochChangeReason: String?
        var previousCaptureEpoch: MCPCaptureEpoch?
    }

    /// Live retained-body-byte total from the underlying store, for `joesproxy://capture/health`.
    var retainedBodyBytes: Int { sessionStore.retainedBodyBytes }
    /// Live retention-policy drop count from the underlying store, for `joesproxy://capture/health`.
    var droppedSessionCount: Int { sessionStore.droppedSessionCount }
    var captureCounts: CaptureCounts {
        CaptureCounts(
            sessionCount: sequenceByID.count,
            completedCount: completedCount,
            pendingCount: pendingCount
        )
    }
    var highWaterSequence: UInt64 { nextSequence - 1 }
    /// Retained acceleration entries, including bounded tombstones awaiting compaction.
    /// Exposed internally so stress tests can enforce the storage bound without timing assertions.
    var retainedIndexEntryCount: Int { indexEntries.count }

    /// Newest retained sessions at one immutable high-water sequence. This is intentionally
    /// independent of paginated ascending reads: investigation snapshots need a small recent
    /// decision surface without walking the complete capture.
    func recentSessions(limit: Int, minimumSequenceExclusive: UInt64 = 0) -> [IndexedSession] {
        let boundedLimit = min(max(1, limit), MCPResourceBudget.maxPageSize)
        var result: [IndexedSession] = []
        result.reserveCapacity(boundedLimit)
        for entry in indexEntries.reversed() {
            guard entry.captureSequence > minimumSequenceExclusive else { break }
            guard let record = sessionStore.record(for: entry.id) else { continue }
            result.append(IndexedSession(record: record, captureSequence: entry.captureSequence))
            if result.count == boundedLimit { break }
        }
        return result
    }

    init(sessionStore: any SessionStore) {
        self.sessionStore = sessionStore
        rebuild(from: sessionStore.sessions)
        sessionStore.sessionChangesPublisher
            .sink { [weak self] change in
                self?.apply(change)
            }
            .store(in: &cancellables)
    }

    func page(
        request: PageRequest,
        clientID: String,
        policyRevision: MCPPolicyRevision
    ) throws -> PageResult {
        if let cursor = request.cursor {
            if let error = MCPCursorValidation.validate(
                cursor: cursor,
                clientID: clientID,
                currentPolicyRevision: policyRevision,
                currentEpoch: captureEpoch,
                queryDigest: request.queryDigest,
                orderingDigest: request.orderingDigest
            ) {
                throw error
            }
        }

        let limit = min(max(1, request.limit), MCPResourceBudget.maxPageSize)
        // `indexEntries` is append-ordered, so it is already ascending by capture sequence.
        let startSequence = max(request.cursor?.lastSequence ?? 0, request.minimumSequenceExclusive)
        let highWater = request.cursor?.highWaterSequence ?? (nextSequence - 1)
        var pageItems: [IndexedSession] = []
        pageItems.reserveCapacity(limit)
        var hasMore = false

        for entry in candidateEntries(for: request.filter) {
            guard entry.captureSequence > startSequence else { continue }
            guard entry.captureSequence <= highWater else { break }
            guard let record = sessionStore.record(for: entry.id),
                  matchesFilter(record, filter: request.filter) else {
                continue
            }
            if pageItems.count == limit {
                hasMore = true
                break
            }
            pageItems.append(
                IndexedSession(record: record, captureSequence: entry.captureSequence)
            )
        }

        let nextCursor: MCPSessionQueryCursor?
        if hasMore, let last = pageItems.last {
            nextCursor = MCPSessionQueryCursor(
                token: UUID().uuidString,
                clientID: clientID,
                policyRevision: policyRevision,
                captureEpoch: captureEpoch,
                queryDigest: request.queryDigest,
                orderingDigest: request.orderingDigest,
                highWaterSequence: highWater,
                lastSequence: last.captureSequence
            )
        } else {
            nextCursor = nil
        }

        return PageResult(items: pageItems, nextCursor: nextCursor, highWaterSequence: highWater)
    }

    func indexedSession(id: SessionRecord.ID) -> IndexedSession? {
        guard let sequence = sequenceByID[id],
              let record = sessionStore.record(for: id) else {
            return nil
        }
        return IndexedSession(record: record, captureSequence: sequence)
    }

    /// All indexed sessions in capture order for management-panel preview pickers.
    var allIndexedSessions: [IndexedSession] {
        indexEntries.compactMap { entry in
            sessionStore.record(for: entry.id).map {
                IndexedSession(record: $0, captureSequence: entry.captureSequence)
            }
        }
    }

    private func matchesFilter(_ record: SessionRecord, filter: ListFilter?) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        if let method = filter.method,
           record.request.method.caseInsensitiveCompare(method) != .orderedSame {
            return false
        }
        if let hostCategory = filter.hostCategory {
            let category: String
            if CaptureMarkerConstants.isMarkerRecord(record) {
                category = CaptureMarkerConstants.hostCategory
            } else {
                category = MCPHostCategory.classify(host: record.request.host).rawValue
            }
            if category.caseInsensitiveCompare(hostCategory) != .orderedSame {
                return false
            }
        }
        if let prefix = filter.sessionIDPrefix {
            let idString = record.id.uuidString.lowercased()
            if !idString.hasPrefix(prefix.lowercased()) {
                return false
            }
        }
        if let domain = filter.domain,
           !record.request.host.localizedCaseInsensitiveContains(domain) {
            return false
        }
        if let path = filter.pathContains,
           !record.request.path.localizedCaseInsensitiveContains(path) {
            return false
        }
        if let startedAfter = filter.startedAfter, record.timing.startedAt < startedAfter {
            return false
        }
        if let startedBefore = filter.startedBefore, record.timing.startedAt > startedBefore {
            return false
        }
        return true
    }

    private func candidateEntries(for filter: ListFilter?) -> [IndexEntry] {
        guard let filter else { return indexEntries }
        let method = filter.method?.lowercased()
        let hostCategory = filter.hostCategory?.lowercased()
        if let method, let hostCategory {
            return indexEntriesByMethodAndHostCategory["\(method)|\(hostCategory)"] ?? []
        }
        if let method {
            return indexEntriesByMethod[method] ?? []
        }
        if let hostCategory {
            return indexEntriesByHostCategory[hostCategory] ?? []
        }
        return indexEntries
    }

    private func rebuild(from sessions: [SessionRecord]) {
        indexEntries = []
        indexEntriesByMethod = [:]
        indexEntriesByHostCategory = [:]
        indexEntriesByMethodAndHostCategory = [:]
        sequenceByID = [:]
        revisionByID = [:]
        methodByID = [:]
        hostCategoryByID = [:]
        stateByID = [:]
        removedEntryCount = 0
        completedCount = 0
        pendingCount = 0
        nextSequence = 1
        for session in sessions {
            appendSession(session)
        }
    }

    private func apply(_ change: SessionStoreChange) {
        defer { stateRevision &+= 1 }
        switch change {
        case .appended(let session, droppedIDs: let droppedIDs):
            appendSession(session)
            if !droppedIDs.isEmpty {
                removeSessions(droppedIDs)
            }
        case .updated(let session, inserted: let inserted):
            if inserted {
                appendSession(session)
            } else {
                replaceSession(session)
            }
        case .updatedBatch(let sessions, insertedIDs: let insertedIDs):
            for session in sessions where insertedIDs.contains(session.id) {
                appendSession(session)
            }
            for session in sessions where !insertedIDs.contains(session.id) {
                replaceSession(session)
            }
        case .bodiesStripped(let sessions):
            // Full records are never retained here; the next disclosure fetches the stripped
            // record directly from SessionStore.
            for session in sessions where sequenceByID[session.id] != nil { reviseSource(session.id) }
        case .removed(ids: let ids):
            removeSessions(ids)
        case .cleared:
            let priorEpoch = captureEpoch
            bumpEpochAndRebuild(from: [], reason: "capture_cleared", priorEpoch: priorEpoch)
            insertSystemMarker(
                name: "capture_cleared",
                reason: "capture_cleared",
                detail: "Capture was cleared; prior epoch \(priorEpoch.rawValue).",
                captureEpoch: captureEpoch,
                priorCaptureEpoch: priorEpoch
            )
        case .loaded(let sessions, let reason):
            let priorEpoch = captureEpoch
            bumpEpochAndRebuild(from: sessions, reason: reason, priorEpoch: priorEpoch)
            insertSystemMarker(
                name: reason,
                reason: reason,
                detail: "Loaded \(sessions.count) sessions; prior epoch \(priorEpoch.rawValue).",
                captureEpoch: captureEpoch,
                priorCaptureEpoch: priorEpoch,
                loadedSessionCount: sessions.count
            )
        }
    }

    private func bumpEpochAndRebuild(
        from sessions: [SessionRecord],
        reason: String,
        priorEpoch: MCPCaptureEpoch? = nil
    ) {
        let previous = priorEpoch ?? captureEpoch
        captureEpoch = MCPCaptureEpoch(rawValue: "capture-epoch-\(Self.epochCounter(from: captureEpoch) + 1)")
        epochMetadata = CaptureEpochMetadata(
            lastEpochChangeAt: Date(),
            lastEpochChangeReason: reason,
            previousCaptureEpoch: previous
        )
        rebuild(from: sessions)
    }

    private func insertSystemMarker(
        name: String,
        reason: String,
        detail: String?,
        captureEpoch: MCPCaptureEpoch,
        priorCaptureEpoch: MCPCaptureEpoch?,
        loadedSessionCount: Int? = nil
    ) {
        try? markerService?.insertSystemMarker(
            name: name,
            reason: reason,
            detail: detail,
            captureEpoch: captureEpoch,
            priorCaptureEpoch: priorCaptureEpoch,
            loadedSessionCount: loadedSessionCount
        )
    }

    private func appendSession(_ session: SessionRecord) {
        guard sequenceByID[session.id] == nil else { return }
        let sequence = nextSequence
        nextSequence += 1
        sequenceByID[session.id] = sequence
        reviseSource(session.id)
        updateLifecycleState(session.state, for: session.id)
        let entry = IndexEntry(id: session.id, captureSequence: sequence)
        indexEntries.append(entry)
        let method = session.request.method.lowercased()
        let hostCategory = Self.hostCategory(for: session).lowercased()
        methodByID[session.id] = method
        hostCategoryByID[session.id] = hostCategory
        indexEntriesByMethod[method, default: []].append(entry)
        indexEntriesByHostCategory[hostCategory, default: []].append(entry)
        indexEntriesByMethodAndHostCategory["\(method)|\(hostCategory)", default: []].append(entry)
    }

    private func replaceSession(_ session: SessionRecord) {
        guard let sequence = sequenceByID[session.id] else { return }
        reviseSource(session.id)
        let newMethod = session.request.method.lowercased()
        let newHostCategory = Self.hostCategory(for: session).lowercased()
        let oldMethod = methodByID[session.id]
        let oldHostCategory = hostCategoryByID[session.id]
        if oldMethod != newMethod || oldHostCategory != newHostCategory {
            let id = session.id
            indexEntriesByMethod = indexEntriesByMethod.mapValues { $0.filter { $0.id != id } }
                .filter { !$0.value.isEmpty }
            indexEntriesByHostCategory = indexEntriesByHostCategory.mapValues { $0.filter { $0.id != id } }
                .filter { !$0.value.isEmpty }
            indexEntriesByMethodAndHostCategory = indexEntriesByMethodAndHostCategory
                .mapValues { $0.filter { $0.id != id } }
                .filter { !$0.value.isEmpty }
            let entry = IndexEntry(id: id, captureSequence: sequence)
            indexEntriesByMethod[newMethod, default: []].append(entry)
            indexEntriesByHostCategory[newHostCategory, default: []].append(entry)
            indexEntriesByMethodAndHostCategory["\(newMethod)|\(newHostCategory)", default: []].append(entry)
            indexEntriesByMethod[newMethod]?.sort { $0.captureSequence < $1.captureSequence }
            indexEntriesByHostCategory[newHostCategory]?.sort { $0.captureSequence < $1.captureSequence }
            indexEntriesByMethodAndHostCategory["\(newMethod)|\(newHostCategory)"]?.sort {
                $0.captureSequence < $1.captureSequence
            }
            methodByID[id] = newMethod
            hostCategoryByID[id] = newHostCategory
        }
        updateLifecycleState(session.state, for: session.id)
    }

    private func removeSessions(_ ids: Set<SessionRecord.ID>) {
        var removedCount = 0
        for id in ids {
            guard sequenceByID.removeValue(forKey: id) != nil else { continue }
            revisionByID.removeValue(forKey: id)
            removedCount += 1
            if let state = stateByID[id] {
                decrementCount(for: state)
            }
            methodByID.removeValue(forKey: id)
            hostCategoryByID.removeValue(forKey: id)
            stateByID.removeValue(forKey: id)
        }

        // Retention commonly drops one oldest session for every append. Removing that ID from the
        // master array and every secondary array on each event makes the steady-state hot path O(n).
        // Keep stale acceleration entries as tombstones; all reads still resolve against SessionStore
        // and therefore skip them. Periodic compaction bounds memory and amortizes the rebuild cost.
        removedEntryCount += removedCount
        let compactionThreshold = max(64, sequenceByID.count / 4)
        if removedEntryCount >= compactionThreshold {
            compactIndexes()
        }
    }

    private func compactIndexes() {
        indexEntries.removeAll { sequenceByID[$0.id] == nil }
        indexEntriesByMethod = compacted(indexEntriesByMethod)
        indexEntriesByHostCategory = compacted(indexEntriesByHostCategory)
        indexEntriesByMethodAndHostCategory = compacted(indexEntriesByMethodAndHostCategory)
        removedEntryCount = 0
    }

    private func compacted(_ index: [String: [IndexEntry]]) -> [String: [IndexEntry]] {
        index.mapValues { entries in
            entries.filter { sequenceByID[$0.id] != nil }
        }.filter { !$0.value.isEmpty }
    }

    private func updateLifecycleState(_ state: SessionLifecycleState, for id: SessionRecord.ID) {
        if let previous = stateByID[id] {
            guard previous != state else { return }
            decrementCount(for: previous)
        }
        stateByID[id] = state
        switch state {
        case .completed:
            completedCount += 1
        case .pending:
            pendingCount += 1
        case .failed, .cancelled:
            break
        }
    }

    private func decrementCount(for state: SessionLifecycleState) {
        switch state {
        case .completed:
            completedCount = max(0, completedCount - 1)
        case .pending:
            pendingCount = max(0, pendingCount - 1)
        case .failed, .cancelled:
            break
        }
    }

    private static func epochCounter(from epoch: MCPCaptureEpoch) -> Int {
        Int(epoch.rawValue.replacingOccurrences(of: "capture-epoch-", with: "")) ?? 0
    }

    private static func hostCategory(for session: SessionRecord) -> String {
        CaptureMarkerConstants.isMarkerRecord(session)
            ? CaptureMarkerConstants.hostCategory
            : MCPHostCategory.classify(host: session.request.host).rawValue
    }
}
