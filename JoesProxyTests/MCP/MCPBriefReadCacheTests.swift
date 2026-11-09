import XCTest
@testable import JoesProxy

@MainActor
final class MCPBriefReadCacheTests: XCTestCase {
    func testExpiredReceiptsAndMixedOwnersUnderCapacityPressure() throws {
        let cache = MCPBriefReadCache(), start = Date(timeIntervalSince1970: 500)
        let active = try cache.retain(payload: ["status": "complete"], owner: "a", scope: "ab", now: start)
        let missing = try cache.retain(payload: ["status": "incomplete"], owner: "b", scope: "bc-missing", now: start)
        XCTAssertNil(cache.unchanged(missing, owner: "b", scope: "bc-arrived", now: start))
        for index in 0..<63 {
            _ = try cache.retain(payload: [:], owner: index.isMultiple(of: 2) ? "a" : "b", scope: String(index), now: start.addingTimeInterval(Double(index + 1)))
        }
        XCTAssertNil(cache.unchanged(active, owner: "a", scope: "ab", now: start.addingTimeInterval(64)))
        XCTAssertNotNil(cache.unchanged(missing, owner: "b", scope: "bc-missing", now: start.addingTimeInterval(64)))
        XCTAssertNil(cache.unchanged(missing, owner: "a", scope: "bc-missing", now: start.addingTimeInterval(64)))
        XCTAssertNil(cache.unchanged(missing, owner: "b", scope: "bc-missing", now: start.addingTimeInterval(300)))
        let refreshed = try cache.retain(payload: ["status": "complete"], owner: "b", scope: "bc-arrived", now: start.addingTimeInterval(301))
        XCTAssertNotNil(cache.unchanged(refreshed, owner: "b", scope: "bc-arrived", now: start.addingTimeInterval(301)))
    }
    func testReceiptRequiresOwnerScopeAndUnexpiredIssuance() throws {
        let cache = MCPBriefReadCache(), now = Date(timeIntervalSince1970: 100)
        let token = try cache.retain(payload: ["status": "incomplete"], owner: "a", scope: "revision1", now: now)
        XCTAssertEqual(cache.unchanged(token, owner: "a", scope: "revision1", now: now)?["status"] as? String, "incomplete")
        XCTAssertNil(cache.unchanged(token, owner: "b", scope: "revision1", now: now))
        XCTAssertNil(cache.unchanged(token, owner: "a", scope: "revision2", now: now))
        XCTAssertNil(cache.unchanged(token, owner: "a", scope: "revision1", now: now.addingTimeInterval(300)))
        XCTAssertTrue(MCPBriefReadCache.validDigest(token))
        XCTAssertFalse(MCPBriefReadCache.validDigest(token.uppercased()))
        XCTAssertFalse(MCPBriefReadCache.validDigest(123))
    }

    func testCapacityAndOwnerInvalidation() throws {
        let cache = MCPBriefReadCache()
        let first = try cache.retain(payload: [:], owner: "a", scope: "0")
        for index in 1...64 { _ = try cache.retain(payload: [:], owner: "a", scope: String(index)) }
        XCTAssertNil(cache.unchanged(first, owner: "a", scope: "0"))
        let last = try cache.retain(payload: [:], owner: "b", scope: "last")
        cache.removeAll(owner: "a")
        XCTAssertNotNil(cache.unchanged(last, owner: "b", scope: "last"))
        cache.removeAll()
        XCTAssertNil(cache.unchanged(last, owner: "b", scope: "last"))
    }
}
