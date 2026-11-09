import XCTest
@testable import JoesProxy

@MainActor
final class InspectorBodyCacheTests: XCTestCase {
    func testUnrelatedPublicationPreservesLoadedSourceIdentity() {
        let record = makeSession(body: Data("{\"id\":1}".utf8))
        var cache = InspectorBodyCache()
        cache.update(session: record, revision: 1)
        let sourceID = cache.responseSource?.loadedID
        for _ in 0..<100 { cache.update(session: record, revision: 1) }
        XCTAssertNotNil(sourceID)
        XCTAssertEqual(cache.responseSource?.loadedID, sourceID)
    }

    func testSameIDSameSizedReplacementRefreshesDecodedAndJSONContent() {
        let id = UUID()
        var cache = InspectorBodyCache()
        cache.update(session: makeSession(id: id, body: Data("{\"id\":1}".utf8)), revision: 1)
        let firstSourceID = cache.responseSource?.loadedID
        cache.update(session: makeSession(id: id, body: Data("{\"id\":2}".utf8)), revision: 2)
        XCTAssertEqual(cache.responseDecode?.analysisData, Data("{\"id\":2}".utf8))
        XCTAssertNotEqual(cache.responseSource?.loadedID, firstSourceID)
    }

    func testRetentionStrippingDropsDecodedAndSourceReferences() {
        let id = UUID()
        var cache = InspectorBodyCache()
        cache.update(session: makeSession(id: id, body: Data("{\"id\":1}".utf8)), revision: 1)
        cache.update(session: makeSession(id: id, body: nil), revision: 2)
        XCTAssertNil(cache.responseDecode)
        XCTAssertNil(cache.responseSource)
        XCTAssertEqual(cache.sessionID, id)
    }

    func testClearAndDisappearanceReleaseAllCachedSources() {
        var cache = InspectorBodyCache()
        let record = makeSession(body: Data("{\"id\":1}".utf8))
        cache.update(session: record, revision: 1)
        cache.update(session: nil, revision: 2)
        XCTAssertNil(cache.sessionID)
        XCTAssertNil(cache.requestSource)
        XCTAssertNil(cache.responseSource)
        XCTAssertNil(cache.responseDecode)
        cache.update(session: record, revision: 1)
        XCTAssertNotNil(cache.responseSource)
        cache.clear()
        XCTAssertNil(cache.sessionID)
        XCTAssertNil(cache.responseDecode)
    }

    func testLateBodyCompletionInvalidatesSameSession() {
        let id = UUID()
        var cache = InspectorBodyCache()
        cache.update(session: makeSession(id: id, body: nil), revision: 1)
        XCTAssertNil(cache.responseSource)
        cache.update(session: makeSession(id: id, body: Data("{\"ready\":true}".utf8)), revision: 2)
        XCTAssertNotNil(cache.responseSource)
    }

    func testRevisionPolicyOnlyIncludesEventsAffectingSelectedRecord() {
        let selected = makeSession(body: nil)
        let other = makeSession(body: nil)
        XCTAssertFalse(SessionStoreChange.appended(other, droppedIDs: []).affectsInspection(of: selected.id))
        XCTAssertFalse(SessionStoreChange.updated(other, inserted: false).affectsInspection(of: selected.id))
        XCTAssertTrue(SessionStoreChange.updated(selected, inserted: false).affectsInspection(of: selected.id))
        XCTAssertTrue(SessionStoreChange.updatedBatch([other, selected], insertedIDs: []).affectsInspection(of: selected.id))
        XCTAssertTrue(SessionStoreChange.bodiesStripped([selected]).affectsInspection(of: selected.id))
        XCTAssertTrue(SessionStoreChange.appended(other, droppedIDs: [selected.id]).affectsInspection(of: selected.id))
        XCTAssertTrue(SessionStoreChange.removed(ids: [selected.id]).affectsInspection(of: selected.id))
        XCTAssertTrue(SessionStoreChange.cleared.affectsInspection(of: selected.id))
        XCTAssertTrue(SessionStoreChange.loaded(sessions: [other], reason: "test").affectsInspection(of: selected.id))
    }

    private func makeSession(id: UUID = UUID(), body: Data?) -> SessionRecord {
        SessionRecord(
            id: id,
            request: CapturedRequest(method: "GET", scheme: .http, host: "example.test", port: 80,
                path: "/payload", headers: [], bodyData: nil, bodySize: nil),
            response: CapturedResponse(statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: body, bodySize: body?.count),
            state: .completed, timing: SessionTiming(startedAt: Date())
        )
    }
}
