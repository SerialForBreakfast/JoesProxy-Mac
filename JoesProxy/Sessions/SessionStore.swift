import Combine
import Foundation

// MARK: - SessionStore protocol

protocol SessionStore: AnyObject {
    var liveCaptureEpoch: LiveCaptureEpoch { get }
    var sessions: [SessionRecord] { get }
    var sessionChangesPublisher: AnyPublisher<SessionStoreChange, Never> { get }
    var retentionPolicy: CaptureRetentionPolicy { get set }

    /// Number of sessions dropped by the active retention policy since the last
    /// `clear()` or `load()` call. Returns `0` for stores that do not enforce a policy.
    var droppedSessionCount: Int { get }
    var evictedBodyCount: Int { get }
    var lastHistoryResetAt: Date? { get }

    /// Total bytes of inline body data (`request.bodyData` + `response?.bodyData`)
    /// currently retained across all sessions. Updated incrementally on each mutation.
    var retainedBodyBytes: Int { get }
    /// Logical header fields retained in canonical records, not allocated string bytes.
    var retainedHeaderFieldCount: Int { get }

    /// O(1) lookup of a single record. The store is the sole long-lived owner of full
    /// records; consumers fetch by ID on demand instead of retaining their own copies.
    func record(for id: SessionRecord.ID) -> SessionRecord?

    func append(_ session: SessionRecord)
    func update(_ session: SessionRecord)
    /// Upserts multiple sessions. Implementations enforce retention before publishing canonical records.
    func update(_ sessions: [SessionRecord])
    func remove(ids: Set<SessionRecord.ID>)
    func clear()
    /// Atomically replaces all current sessions with `sessions` in a single publish.
    /// Prefer this over `clear()` + repeated `append()` to avoid intermediate state emissions.
    /// - Parameter epochChangeReason: Machine-readable reason surfaced to MCP (`capture_loaded`, `capture_restored`).
    func load(sessions: [SessionRecord], epochChangeReason: String)
}

enum SessionStoreChange: Equatable, Sendable {
    case appended(SessionRecord, droppedIDs: Set<SessionRecord.ID>)
    case updated(SessionRecord, inserted: Bool)
    case updatedBatch([SessionRecord], insertedIDs: Set<SessionRecord.ID>)
    /// Retention stripped `bodyData` from these sessions in place. Downstream copies and
    /// body-derived caches must adopt the stripped records or the freed memory stays pinned.
    case bodiesStripped([SessionRecord])
    case removed(ids: Set<SessionRecord.ID>)
    case cleared
    case loaded(sessions: [SessionRecord], reason: String)
}

extension SessionStore {
    /// Convenience overload that uses the default `capture_loaded` epoch-change reason.
    func load(sessions: [SessionRecord]) {
        load(sessions: sessions, epochChangeReason: "capture_loaded")
    }
}

// MARK: - InMemorySessionStore

/// In-memory session store with optional retention-policy enforcement.
///
/// **Retention policy** is set via `retentionPolicy` at construction time or mutated at
/// runtime. The default is `.unlimited`. When `.keepLastSessions(n)` is active, sessions
/// exceeding the limit are dropped from the front after insertions, updates, loads, and policy changes.
///
/// **Body bytes** are tracked incrementally to avoid O(n) summation on every UI update.
///
/// **Thread safety**: all mutations must occur on the `@MainActor` because the store feeds
/// directly into `ProxyViewModel`, which is `@MainActor`-isolated.
final class InMemorySessionStore: SessionStore {
    let liveCaptureEpoch = LiveCaptureEpoch()
    private struct RetiredStorage: Sendable {
        let sessions: [SessionRecord]
        let indexByID: [SessionRecord.ID: Int]
    }

    // MARK: SessionStore conformance

    var sessions: [SessionRecord] {
        storedSessions
    }

    var sessionChangesPublisher: AnyPublisher<SessionStoreChange, Never> {
        sessionChangesSubject.eraseToAnyPublisher()
    }

    private(set) var droppedSessionCount: Int = 0
    private(set) var lastHistoryResetAt: Date?
    private(set) var evictedBodyCount = 0
    private(set) var retainedBodyBytes: Int = 0
    private(set) var retainedHeaderFieldCount = 0
    /// Ordered logical indices of records with inline bodies, including late body updates.
    private var bodyBearingIndices = IndexSet()
    /// Number of sessions dropped from the front of `storedSessions` since the last reset.
    /// `sessionIndexByID` stores logical (monotonic) indices; physical = logical - indexOffset.
    /// Using an offset lets `keepLastSessions` drops skip a full O(n) index rebuild.
    private var indexOffset: Int = 0

    // MARK: Retention policy

    var retentionPolicy: CaptureRetentionPolicy {
        didSet { publishRetention(enforceRetention()) }
    }

    // MARK: Private state

    private var storedSessions: [SessionRecord] = []
    private var sessionIndexByID: [SessionRecord.ID: Int] = [:]
    private let sessionChangesSubject = PassthroughSubject<SessionStoreChange, Never>()

    // MARK: Init

    /// - Parameter retentionPolicy: Initial policy. Defaults to `.unlimited`.
    init(retentionPolicy: CaptureRetentionPolicy = .unlimited) {
        self.retentionPolicy = retentionPolicy
    }

    func record(for id: SessionRecord.ID) -> SessionRecord? {
        guard let logicalIndex = sessionIndexByID[id] else { return nil }
        let index = logicalIndex - indexOffset
        guard storedSessions.indices.contains(index) else { return nil }
        return storedSessions[index]
    }

    // MARK: Mutations

    func append(_ session: SessionRecord) {
        if record(for: session.id) != nil {
            update(session)
            return
        }
        insertOrReplace(session)
        let changes = enforceRetention()
        if let canonical = record(for: session.id) {
            sessionChangesSubject.send(.appended(canonical, droppedIDs: changes.dropped))
        } else if !changes.dropped.isEmpty {
            sessionChangesSubject.send(.removed(ids: changes.dropped))
        }
        publishStripped(changes.stripped)
    }

    func update(_ session: SessionRecord) {
        let inserted = record(for: session.id) == nil
        insertOrReplace(session)
        let changes = enforceRetention()
        if let canonical = record(for: session.id) {
            sessionChangesSubject.send(.updated(canonical, inserted: inserted))
        }
        publishRetention(changes)
    }

    func update(_ sessions: [SessionRecord]) {
        guard !sessions.isEmpty else { return }
        var insertedIDs: Set<UUID> = []
        var changedIDs: [UUID] = []
        var seen: Set<UUID> = []
        for session in sessions {
            if record(for: session.id) == nil { insertedIDs.insert(session.id) }
            insertOrReplace(session)
            if seen.insert(session.id).inserted { changedIDs.append(session.id) }
        }
        let changes = enforceRetention()
        let canonical = changedIDs.compactMap { record(for: $0) }
        if !canonical.isEmpty {
            sessionChangesSubject.send(.updatedBatch(canonical,
                insertedIDs: insertedIDs.subtracting(changes.dropped)))
        }
        publishRetention(changes)
    }

    private func insertOrReplace(_ session: SessionRecord) {
        let logicalIndex: Int
        if let existing = sessionIndexByID[session.id] {
            logicalIndex = existing
            retainedBodyBytes -= bodyByteCount(storedSessions[existing - indexOffset])
            retainedHeaderFieldCount -= headerFieldCount(storedSessions[existing - indexOffset])
            storedSessions[existing - indexOffset] = session
        } else {
            logicalIndex = indexOffset + storedSessions.count
            sessionIndexByID[session.id] = logicalIndex
            storedSessions.append(session)
        }
        let bytes = bodyByteCount(session)
        retainedBodyBytes += bytes
        retainedHeaderFieldCount += headerFieldCount(session)
        if bytes > 0 { bodyBearingIndices.insert(logicalIndex) }
        else { bodyBearingIndices.remove(logicalIndex) }
    }

    private func enforceRetention() -> (dropped: Set<UUID>, stripped: [SessionRecord]) {
        var droppedIDs: Set<UUID> = []
        var stripped: [SessionRecord] = []
        if let maximum = retentionPolicy.sessionLimit, storedSessions.count > maximum {
            let excess = storedSessions.count - maximum
            let dropped = Array(storedSessions.prefix(excess))
            for record in dropped {
                droppedIDs.insert(record.id)
                retainedBodyBytes -= bodyByteCount(record)
                retainedHeaderFieldCount -= headerFieldCount(record)
                if let index = sessionIndexByID.removeValue(forKey: record.id) {
                    bodyBearingIndices.remove(index)
                }
            }
            storedSessions.removeFirst(excess)
            indexOffset += excess
            droppedSessionCount += excess
            DeferredRelease.schedule(dropped)
        }
        if let maximum = retentionPolicy.bodyByteLimit {
            // Only body-bearing logical indices participate; late updates reinsert their index.
            while retainedBodyBytes > max(0, maximum), let logical = bodyBearingIndices.first {
                bodyBearingIndices.remove(logical)
                let index = logical - indexOffset
                var record = storedSessions[index]
                retainedBodyBytes -= bodyByteCount(record)
                if let bytes = record.request.bodyData, !bytes.isEmpty {
                    record.request = record.request.strippingBodyData()
                    evictedBodyCount += 1
                }
                if let response = record.response, let bytes = response.bodyData, !bytes.isEmpty {
                    record.response = response.strippingBodyData()
                    evictedBodyCount += 1
                }
                storedSessions[index] = record
                stripped.append(record)
            }
        }
        return (droppedIDs, stripped)
    }

    private func publishStripped(_ records: [SessionRecord]) {
        if !records.isEmpty { sessionChangesSubject.send(.bodiesStripped(records)) }
    }

    private func publishRetention(_ changes: (dropped: Set<UUID>, stripped: [SessionRecord])) {
        if !changes.dropped.isEmpty { sessionChangesSubject.send(.removed(ids: changes.dropped)) }
        publishStripped(changes.stripped)
    }

    func remove(ids: Set<SessionRecord.ID>) {
        guard !ids.isEmpty else { return }
        let signpost = CapturePerformanceSignposts.signposter.beginInterval("SessionStore.remove")
        defer { CapturePerformanceSignposts.signposter.endInterval("SessionStore.remove", signpost) }

        var removedSessions: [SessionRecord] = []
        storedSessions = storedSessions.filter { session in
            let removing = ids.contains(session.id)
            if removing {
                retainedBodyBytes -= bodyByteCount(session)
                retainedHeaderFieldCount -= headerFieldCount(session)
                removedSessions.append(session)
            }
            return !removing
        }
        rebuildSessionIndex()
        if !removedSessions.isEmpty {
            DeferredRelease.schedule(removedSessions)
        }
        sessionChangesSubject.send(.removed(ids: ids))
    }

    func clear() {
        liveCaptureEpoch.advance()
        let signpost = CapturePerformanceSignposts.signposter.beginInterval("SessionStore.clear")
        defer { CapturePerformanceSignposts.signposter.endInterval("SessionStore.clear", signpost) }

        let retiredStorage = RetiredStorage(
            sessions: storedSessions,
            indexByID: sessionIndexByID
        )
        storedSessions = []
        sessionIndexByID = [:]
        retainedBodyBytes = 0
        retainedHeaderFieldCount = 0
        droppedSessionCount = 0
        evictedBodyCount = 0
        lastHistoryResetAt = Date()
        bodyBearingIndices = []
        indexOffset = 0
        DeferredRelease.schedule(retiredStorage)
        sessionChangesSubject.send(.cleared)
    }

    func load(sessions: [SessionRecord], epochChangeReason: String) {
        liveCaptureEpoch.advance()
        let signpost = CapturePerformanceSignposts.signposter.beginInterval("SessionStore.load")
        defer { CapturePerformanceSignposts.signposter.endInterval("SessionStore.load", signpost) }

        storedSessions = sessions
        indexOffset = 0
        rebuildSessionIndex()
        retainedBodyBytes = sessions.reduce(0) { $0 + bodyByteCount($1) }
        retainedHeaderFieldCount = sessions.reduce(0) { $0 + headerFieldCount($1) }
        droppedSessionCount = 0
        evictedBodyCount = 0
        lastHistoryResetAt = Date()
        _ = enforceRetention()
        sessionChangesSubject.send(.loaded(sessions: storedSessions, reason: epochChangeReason))
    }

    // MARK: Private helpers

    private func headerFieldCount(_ session: SessionRecord) -> Int {
        session.request.headers.count + (session.response?.headers.count ?? 0)
    }

    private func bodyByteCount(_ session: SessionRecord) -> Int {
        (session.request.bodyData?.count ?? 0) + (session.response?.bodyData?.count ?? 0)
    }

    private func rebuildSessionIndex() {
        let count = storedSessions.count
        let sp = CapturePerformanceSignposts.signposter.beginInterval(
            "SessionStore.rebuildSessionIndex",
            "\(count) sessions"
        )
        defer { CapturePerformanceSignposts.signposter.endInterval("SessionStore.rebuildSessionIndex", sp) }

        sessionIndexByID = [:]
        bodyBearingIndices = []
        for (physicalIndex, session) in storedSessions.enumerated() {
            sessionIndexByID[session.id] = indexOffset + physicalIndex
            if bodyByteCount(session) > 0 { bodyBearingIndices.insert(indexOffset + physicalIndex) }
        }
    }
}

// MARK: - Body-stripping helpers

extension CapturedRequest {
    /// Returns a copy of this request with `bodyData` set to `nil`. `bodySize` is
    /// preserved so the UI can still report how large the original body was.
    func strippingBodyData() -> CapturedRequest {
        CapturedRequest(
            method: method,
            scheme: scheme,
            inspectionKind: inspectionKind,
            inspectionReason: inspectionReason,
            host: host,
            port: port,
            path: path,
            headers: headers,
            bodyData: nil,
            bodySize: bodySize,
            bodyTruncated: bodyTruncated,
            recordingBodyOmissionReason: .retentionEvicted,
            bodyDeferred: false,
            clientAddress: clientAddress,
            localCACertificateSHA256Fingerprint: localCACertificateSHA256Fingerprint,
            remoteTrustState: remoteTrustState
        )
    }
}

extension CapturedResponse {
    /// Returns a copy of this response with `bodyData` set to `nil`. `bodySize` is
    /// preserved so the UI can still report how large the original body was.
    func strippingBodyData() -> CapturedResponse {
        CapturedResponse(
            statusCode: statusCode,
            headers: headers,
            bodyData: nil,
            bodySize: bodySize,
            source: source,
            sourceDescription: sourceDescription,
            bodyTruncated: bodyTruncated,
            recordingBodyOmissionReason: .retentionEvicted,
            bodyDeferred: false,
            mcpAttribution: mcpAttribution,
            localCACertificateSHA256Fingerprint: localCACertificateSHA256Fingerprint
        )
    }
}
