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
        /// Exact HTTP response status code match (100...599).
        var statusCode: Int?
        /// Status code family match: "2xx", "3xx", "4xx", "5xx", "error" (>=400 or failed), or "non200".
        var statusClass: String?
        /// Inclusive lower bound on request duration in milliseconds.
        var minDurationMs: Double?
        /// Matches sessions where an override/rewrite/MCP effect applied (true) or upstream only (false).
        var hasOverrideHit: Bool?
        /// Matches sessions with a retained non-empty response body (true) or missing/empty body (false).
        var bodyAvailable: Bool?

        var isEmpty: Bool {
            method == nil && hostCategory == nil && sessionIDPrefix == nil
                && domain == nil && pathContains == nil
                && startedAfter == nil && startedBefore == nil
                && statusCode == nil && statusClass == nil
                && minDurationMs == nil && hasOverrideHit == nil
                && bodyAvailable == nil
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
        Self.matchesFilter(record, filter: filter, disclosure: nil)
    }

    nonisolated static func matchesFilter(_ record: SessionRecord, filter: ListFilter?, disclosure: MCPDisclosureSerializer?) -> Bool {
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
           !(disclosure?.sanitizedHost(record.request.host) ?? record.request.host).localizedCaseInsensitiveContains(domain) {
            return false
        }
        if let path = filter.pathContains,
           !(disclosure?.sanitizedPath(record.request.path) ?? record.request.path).localizedCaseInsensitiveContains(path) {
            return false
        }
        if let startedAfter = filter.startedAfter, record.timing.startedAt < startedAfter {
            return false
        }
        if let startedBefore = filter.startedBefore, record.timing.startedAt > startedBefore {
            return false
        }
        if let expectedStatus = filter.statusCode {
            guard record.response?.statusCode == expectedStatus else { return false }
        }
        if let statusClass = filter.statusClass?.lowercased() {
            let status = record.response?.statusCode
            switch statusClass {
            case "2xx":
                guard let status, (200...299).contains(status) else { return false }
            case "3xx":
                guard let status, (300...399).contains(status) else { return false }
            case "4xx":
                guard let status, (400...499).contains(status) else { return false }
            case "5xx":
                guard let status, (500...599).contains(status) else { return false }
            case "error":
                let isFailed = record.state == .failed || (status ?? 0) >= 400
                guard isFailed else { return false }
            case "non200":
                guard let status, status != 200 else { return false }
            default:
                return false
            }
        }
        if let minDurationMs = filter.minDurationMs {
            guard let durationSeconds = record.timing.duration,
                  durationSeconds * 1000.0 >= minDurationMs else {
                return false
            }
        }
        if let hasOverrideHit = filter.hasOverrideHit {
            let isHit = (record.response?.source != nil && record.response?.source != .upstream)
                || !(record.response?.mcpAttribution?.effectKinds.isEmpty ?? true)
            guard isHit == hasOverrideHit else { return false }
        }
        if let bodyAvailable = filter.bodyAvailable {
            let hasBody = !(record.response?.bodyData?.isEmpty ?? true)
                && record.response?.bodyDeferred != true
            guard hasBody == bodyAvailable else { return false }
        }
        return true
    }

    /// Collapses repetitive polling/segment traffic into bounded endpoint groups while preserving
    /// status distributions, duration maxima, override hit counts, and first/last session locators.
    nonisolated static func deduplicateEndpoints(
        items: [IndexedSession],
        profile: MCPDisclosureProfileDocument,
        disclosure: MCPDisclosureSerializer
    ) -> [MCPEndpointGroupDTO] {
        struct Builder {
            var signature: String
            var method: String?
            var sanitizedHost: String?
            var normalizedPath: String?
            var count: Int = 0
            var firstSessionID: String
            var lastSessionID: String
            var firstSequence: UInt64
            var lastSequence: UInt64
            var statusCounts: [String: Int] = [:]
            var maxDurationSeconds: Double?
            var overrideHitCount: Int = 0
        }

        let allowMethod = profile.allowedFieldClasses.contains(.method)
        let allowHost = profile.allowedFieldClasses.contains(.sanitizedHost)
        let allowPath = profile.allowedFieldClasses.contains(.sanitizedPath)
        let allowStatus = profile.allowedFieldClasses.contains(.statusCode)
        let allowDuration = profile.allowedFieldClasses.contains(.duration)
        let allowProvenance = profile.allowedFieldClasses.contains(.provenance)

        var groupsBySignature: [String: Builder] = [:]
        var orderedSignatures: [String] = []

        for indexed in items {
            let record = indexed.record
            let method = allowMethod ? record.request.method : nil
            let host = allowHost ? disclosure.sanitizedHost(record.request.host) : (
                profile.allowedFieldClasses.contains(.hostCategory)
                    ? MCPHostCategory.classify(host: record.request.host).rawValue
                    : nil
            )
            let normPath = allowPath ? normalizeEndpointPath(disclosure.sanitizedPath(record.request.path)) : nil
            let signature = [method ?? "*", host ?? "*", normPath ?? "*"].joined(separator: " ")

            let statusKey: String
            if allowStatus {
                statusKey = record.response.map { String($0.statusCode) } ?? record.state.rawValue
            } else {
                statusKey = "undisclosed"
            }
            let isHit = allowProvenance && (
                (record.response?.source != nil && record.response?.source != .upstream)
                || !(record.response?.mcpAttribution?.effectKinds.isEmpty ?? true)
            )

            if var existing = groupsBySignature[signature] {
                existing.count += 1
                existing.lastSessionID = record.id.uuidString
                existing.lastSequence = indexed.captureSequence
                existing.statusCounts[statusKey, default: 0] += 1
                if allowDuration, let duration = record.timing.duration {
                    existing.maxDurationSeconds = max(existing.maxDurationSeconds ?? duration, duration)
                }
                if isHit { existing.overrideHitCount += 1 }
                groupsBySignature[signature] = existing
            } else {
                let builder = Builder(
                    signature: signature,
                    method: method,
                    sanitizedHost: host,
                    normalizedPath: normPath,
                    count: 1,
                    firstSessionID: record.id.uuidString,
                    lastSessionID: record.id.uuidString,
                    firstSequence: indexed.captureSequence,
                    lastSequence: indexed.captureSequence,
                    statusCounts: [statusKey: 1],
                    maxDurationSeconds: allowDuration ? record.timing.duration : nil,
                    overrideHitCount: isHit ? 1 : 0
                )
                groupsBySignature[signature] = builder
                orderedSignatures.append(signature)
            }
        }

        return orderedSignatures.prefix(32).compactMap { sig in
            guard let b = groupsBySignature[sig] else { return nil }
            return MCPEndpointGroupDTO(
                signature: b.signature,
                method: b.method,
                sanitizedHost: b.sanitizedHost,
                normalizedPath: b.normalizedPath,
                count: b.count,
                firstSessionID: b.firstSessionID,
                lastSessionID: b.lastSessionID,
                firstSequence: b.firstSequence,
                lastSequence: b.lastSequence,
                statusCounts: b.statusCounts,
                maxDurationSeconds: b.maxDurationSeconds,
                overrideHitCount: b.overrideHitCount
            )
        }
    }

    nonisolated static func normalizeEndpointPath(_ sanitizedPath: String) -> String {
        let segments = sanitizedPath.split(separator: "/", omittingEmptySubsequences: false)
        let normalized = segments.map { segment -> String in
            let text = String(segment)
            guard !text.isEmpty else { return text }
            if text.allSatisfy(\.isNumber) { return ":id" }
            if UUID(uuidString: text) != nil { return ":uuid" }
            let lower = text.lowercased()
            for ext in [".ts", ".m4s", ".cmfv", ".cmfa", ".aac", ".vtt", ".webvtt", ".mp4"] {
                if lower.hasSuffix(ext), lower.dropLast(ext.count).contains(where: \.isNumber) {
                    return ":segment\(ext)"
                }
            }
            return text
        }
        return normalized.joined(separator: "/")
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
