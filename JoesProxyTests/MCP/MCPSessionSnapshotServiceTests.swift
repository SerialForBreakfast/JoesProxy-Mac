import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class MCPSessionSnapshotServiceTests: XCTestCase {
    func testSourceRevisionsTrackUpdatesReloadsAndReinsertionsWithoutTombstones() throws {
        let store = InMemorySessionStore()
        let service = MCPSessionSnapshotService(sessionStore: store)
        let selected = Self.makeSession(), noise = Self.makeSession()
        store.append(selected)
        let original = try XCTUnwrap(service.sourceRevision(for: selected.id))
        store.append(noise)
        store.update(noise)
        store.remove(ids: [noise.id])
        XCTAssertEqual(service.sourceRevision(for: selected.id), original)
        store.update([selected])
        let updated = try XCTUnwrap(service.sourceRevision(for: selected.id))
        XCTAssertGreaterThan(updated, original)
        store.remove(ids: [selected.id])
        XCTAssertNil(service.sourceRevision(for: selected.id))
        XCTAssertEqual(service.retainedSourceRevisionCount, 0)
        store.append(selected)
        XCTAssertGreaterThan(try XCTUnwrap(service.sourceRevision(for: selected.id)), updated)
        let reinserted = service.sourceRevision(for: selected.id)
        store.load(sessions: [selected], epochChangeReason: "test_reload")
        XCTAssertNotEqual(service.sourceRevision(for: selected.id), reinserted)
        store.clear()
        XCTAssertEqual(service.retainedSourceRevisionCount, 0)
    }
    func testAppendDoesNotBumpEpoch() {
        let sessionStore = InMemorySessionStore()
        let service = MCPSessionSnapshotService(sessionStore: sessionStore)
        let epoch = service.captureEpoch
        sessionStore.append(Self.makeSession())
        XCTAssertEqual(service.captureEpoch, epoch)
        XCTAssertEqual(service.indexedSession(id: sessionStore.sessions[0].id)?.captureSequence, 1)
    }

    func testClearBumpsEpochAndInvalidatesCursor() {
        let sessionStore = InMemorySessionStore()
        let service = MCPSessionSnapshotService(sessionStore: sessionStore)
        sessionStore.append(Self.makeSession())
        let cursor = MCPSessionQueryCursor(
            token: "t",
            clientID: "client",
            policyRevision: .initial,
            captureEpoch: service.captureEpoch,
            queryDigest: "sessions_list",
            orderingDigest: "sequence_asc",
            highWaterSequence: 1,
            lastSequence: 0
        )
        sessionStore.clear()
        XCTAssertThrowsError(
            try service.page(
                request: .init(limit: 10, cursor: cursor, queryDigest: "sessions_list", orderingDigest: "sequence_asc"),
                clientID: "client",
                policyRevision: .initial
            )
        )
    }

    func testPaginationAdvancesAcrossMultiplePages() throws {
        let sessionStore = InMemorySessionStore()
        let service = MCPSessionSnapshotService(sessionStore: sessionStore)
        for _ in 0..<5 {
            sessionStore.append(Self.makeSession())
        }

        var seenIDs: [SessionRecord.ID] = []
        var cursor: MCPSessionQueryCursor?
        repeat {
            let page = try service.page(
                request: .init(limit: 2, cursor: cursor, queryDigest: "sessions_list", orderingDigest: "sequence_asc"),
                clientID: "client",
                policyRevision: .initial
            )
            XCTAssertFalse(page.items.isEmpty, "page must not be empty while a cursor is being followed")
            seenIDs.append(contentsOf: page.items.map(\.record.id))
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(seenIDs.count, 5, "every session must be returned exactly once across pages")
        XCTAssertEqual(Set(seenIDs).count, 5, "no session should be returned twice")
        XCTAssertEqual(seenIDs, sessionStore.sessions.map(\.id), "pages must preserve capture order")
    }

    func testSessionsSearchFiltersByMethodAndHostCategory() throws {
        let sessionStore = InMemorySessionStore()
        let service = MCPSessionSnapshotService(sessionStore: sessionStore)
        sessionStore.append(Self.makeSession(method: "GET", host: "localhost"))
        sessionStore.append(Self.makeSession(method: "POST", host: "api.example.com"))
        sessionStore.append(Self.makeSession(method: "GET", host: "cdn.cloudfront.net"))

        let page = try service.page(
            request: .init(
                limit: 10,
                cursor: nil,
                queryDigest: "search:POST:api:",
                orderingDigest: "sequence_asc",
                filter: .init(method: "POST", hostCategory: "api", sessionIDPrefix: nil)
            ),
            clientID: "client",
            policyRevision: .initial
        )
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.record.request.method, "POST")
    }

    func testIncrementalExactIndexesPreserveOrderAcrossAppendAndRemoval() throws {
        let sessionStore = InMemorySessionStore()
        let service = MCPSessionSnapshotService(sessionStore: sessionStore)
        let first = Self.makeSession(method: "POST", host: "api.example.com", path: "/first")
        let unrelated = Self.makeSession(method: "GET", host: "localhost", path: "/unrelated")
        let second = Self.makeSession(method: "post", host: "api.example.com", path: "/second")
        sessionStore.append(first)
        sessionStore.append(unrelated)
        sessionStore.append(second)

        func indexedPage() throws -> MCPSessionSnapshotService.PageResult {
            try service.page(
                request: .init(
                    limit: 10,
                    cursor: nil,
                    queryDigest: "indexed-post-api",
                    orderingDigest: "sequence_asc",
                    filter: .init(method: "POST", hostCategory: "API", sessionIDPrefix: nil)
                ),
                clientID: "client",
                policyRevision: .initial
            )
        }

        XCTAssertEqual(try indexedPage().items.map(\.record.id), [first.id, second.id])
        sessionStore.remove(ids: [first.id])
        XCTAssertEqual(try indexedPage().items.map(\.record.id), [second.id])
    }

    func testRollingRetentionKeepsIndexesCorrectAndStorageBounded() throws {
        let retainedSessionCount = 32
        let sessionStore = InMemorySessionStore(
            retentionPolicy: .keepLastSessions(retainedSessionCount)
        )
        let service = MCPSessionSnapshotService(sessionStore: sessionStore)

        for index in 0..<2_000 {
            sessionStore.append(Self.makeSession(
                method: index.isMultiple(of: 2) ? "GET" : "POST",
                host: index.isMultiple(of: 3) ? "api.example.com" : "localhost",
                path: "/item/\(index)"
            ))
        }

        XCTAssertEqual(service.captureCounts.sessionCount, retainedSessionCount)
        XCTAssertEqual(service.retainedSourceRevisionCount, retainedSessionCount)
        XCTAssertEqual(service.captureCounts.sessionCount, sessionStore.sessions.count)
        for record in sessionStore.sessions {
            let indexed = try XCTUnwrap(service.indexedSession(id: record.id))
            XCTAssertEqual(indexed.record, record)
            XCTAssertGreaterThan(indexed.captureSequence, 1_968)
        }
        XCTAssertLessThanOrEqual(
            service.retainedIndexEntryCount,
            retainedSessionCount + 63,
            "tombstones must stay within one compaction interval"
        )

        let all = try service.page(
            request: .init(
                limit: 100,
                cursor: nil,
                queryDigest: "rolling-all",
                orderingDigest: "sequence_asc"
            ),
            clientID: "client",
            policyRevision: .initial
        )
        XCTAssertEqual(all.items.map(\.record.id), sessionStore.sessions.map(\.id))

        let indexed = try service.page(
            request: .init(
                limit: 100,
                cursor: nil,
                queryDigest: "rolling-post-api",
                orderingDigest: "sequence_asc",
                filter: .init(method: "POST", hostCategory: "api", sessionIDPrefix: nil)
            ),
            clientID: "client",
            policyRevision: .initial
        )
        let expectedIDs = sessionStore.sessions.filter {
            $0.request.method == "POST"
                && MCPHostCategory.classify(host: $0.request.host).rawValue == "api"
        }.map(\.id)
        XCTAssertEqual(indexed.items.map(\.record.id), expectedIDs)
        XCTAssertEqual(service.recentSessions(limit: 8).map(\.record.id), sessionStore.sessions.suffix(8).reversed().map(\.id))
    }

    func testRecentSessionsReturnsNewestBoundedDelta() {
        let sessionStore = InMemorySessionStore()
        let service = MCPSessionSnapshotService(sessionStore: sessionStore)
        for index in 0..<6 {
            sessionStore.append(Self.makeSession(path: "/\(index)"))
        }

        let recent = service.recentSessions(limit: 2, minimumSequenceExclusive: 3)
        XCTAssertEqual(recent.map(\.captureSequence), [6, 5])
        XCTAssertEqual(recent.map(\.record.request.path), ["/5", "/4"])
    }

    func testSessionsSearchFiltersByDomainPathAndTimeRange() throws {
        let sessionStore = InMemorySessionStore()
        let service = MCPSessionSnapshotService(sessionStore: sessionStore)
        let early = Date(timeIntervalSince1970: 1_000)
        let middle = Date(timeIntervalSince1970: 2_000)
        let late = Date(timeIntervalSince1970: 3_000)
        sessionStore.append(Self.makeSession(host: "api.example.com", path: "/v1/login", startedAt: early))
        sessionStore.append(Self.makeSession(host: "cdn.example.com", path: "/v1/assets/logo.png", startedAt: middle))
        sessionStore.append(Self.makeSession(host: "api.example.com", path: "/v1/logout", startedAt: late))

        // domain substring match
        var page = try service.page(
            request: .init(
                limit: 10, cursor: nil, queryDigest: "search:domain",
                orderingDigest: "sequence_asc",
                filter: .init(domain: "api.example")
            ),
            clientID: "client", policyRevision: .initial
        )
        XCTAssertEqual(page.items.count, 2)
        XCTAssertTrue(page.items.allSatisfy { $0.record.request.host == "api.example.com" })

        // path substring match
        page = try service.page(
            request: .init(
                limit: 10, cursor: nil, queryDigest: "search:path",
                orderingDigest: "sequence_asc",
                filter: .init(pathContains: "login")
            ),
            clientID: "client", policyRevision: .initial
        )
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.record.request.path, "/v1/login")

        // time-range (inclusive bounds)
        page = try service.page(
            request: .init(
                limit: 10, cursor: nil, queryDigest: "search:time",
                orderingDigest: "sequence_asc",
                filter: .init(startedAfter: middle, startedBefore: late)
            ),
            clientID: "client", policyRevision: .initial
        )
        XCTAssertEqual(page.items.count, 2)
        XCTAssertTrue(page.items.allSatisfy { $0.record.timing.startedAt >= middle })
    }

    func testBodyStrippingIsObservedWithoutRetainingOriginalRecord() {
        let sessionStore = InMemorySessionStore(retentionPolicy: .keepLastBodyBytes(0))
        let service = MCPSessionSnapshotService(sessionStore: sessionStore)
        let session = SessionRecord(
            request: CapturedRequest(
                method: "POST",
                scheme: .http,
                host: "localhost",
                port: 9090,
                path: "/upload",
                headers: [],
                bodyData: Data(repeating: 0x41, count: 64),
                bodySize: 64
            ),
            timing: SessionTiming(startedAt: Date())
        )

        sessionStore.append(session)

        let indexed = service.indexedSession(id: session.id)
        XCTAssertNil(indexed?.record.request.bodyData)
        XCTAssertEqual(indexed?.record.request.bodySize, 64)
        XCTAssertEqual(service.retainedBodyBytes, 0)
    }

    func testCaptureCountsAreNotLimitedToOnePage() {
        let sessionStore = InMemorySessionStore()
        let service = MCPSessionSnapshotService(sessionStore: sessionStore)
        for index in 0..<150 {
            var session = Self.makeSession()
            session.state = index < 120 ? .completed : .pending
            sessionStore.append(session)
        }

        XCTAssertEqual(service.captureCounts.sessionCount, 150)
        XCTAssertEqual(service.captureCounts.completedCount, 120)
        XCTAssertEqual(service.captureCounts.pendingCount, 30)
    }

    private static func makeSession(
        method: String = "GET",
        host: String = "localhost",
        path: String = "/",
        startedAt: Date = Date()
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: method,
                scheme: .http,
                host: host,
                port: 9090,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            timing: SessionTiming(startedAt: startedAt)
        )
    }
}
