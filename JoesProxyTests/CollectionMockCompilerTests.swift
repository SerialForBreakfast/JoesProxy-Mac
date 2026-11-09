import XCTest
@testable import JoesProxy

final class CollectionMockCompilerTests: XCTestCase {
    func testCollisionDoesNotHideLaterIdentityOrCountDrift() throws {
        let plan = try CollectionMockCompiler.prepare(source: source, draft: draft())
        for fresh in [
            #"{"items":[{"id":"synthetic"},{"id":null}],"total":2}"#,
            #"{"items":[{"id":"synthetic"}],"total":"1"}"#,
            #"{"items":[{"id":"synthetic"}],"total":-1}"#
        ] {
            XCTAssertThrowsError(try CollectionMockCompiler.apply(source: Data(fresh.utf8), plan: plan))
        }
    }

    func testCountsCannotChangeExistingCollectionMembers() throws {
        let body = Data(#"{"items":[{"id":"original","count":1}]}"#.utf8)
        XCTAssertThrowsError(try CollectionMockCompiler.prepare(source: body,
            draft: draft(counts: ["/items/0/count"]))) {
            XCTAssertEqual($0 as? CollectionMockError, .invalidCount)
        }
    }

    func testDecodedPlanStillValidatesIdentityWithEmptyCollection() throws {
        let body = Data(#"{"items":[]}"#.utf8)
        for identity in [BookmarkJSONValue.null, .bool(true), .string("")] {
            let plan = CompiledCollectionMock(collectionPointer: "/items", item: .object(["id": identity]),
                identityPointers: ["/id"], countPointers: [], position: .append)
            XCTAssertThrowsError(try CollectionMockCompiler.apply(source: body, plan: plan)) {
                XCTAssertEqual($0 as? CollectionMockError, .missingIdentity)
            }
        }
    }

    func testMixedIdentityPresenceIsExplicitAndRetainsCollisionChecks() throws {
        let source = Data(#"{"items":[{"movieId":1},{"showId":2}]}"#.utf8)
        var draft = CollectionMockDraft(collectionPointer: "/items", item: .object(["showId": .number("3")]),
            templateIndex: nil, edits: [], identityPointers: ["/showId"], countPointers: [], position: .prepend)
        XCTAssertThrowsError(try CollectionMockCompiler.prepare(source: source, draft: draft))
        draft.identityPresence = .wherePresent
        let plan = try CollectionMockCompiler.prepare(source: source, draft: draft)
        guard case .applied(let body, _, let count) = try CollectionMockCompiler.apply(source: source, plan: plan) else {
            return XCTFail("Expected mixed collection prepend")
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(try CollectionMockCompiler.parse(body),
            try CollectionMockCompiler.parse(Data(#"{"items":[{"showId":3},{"movieId":1},{"showId":2}]}"#.utf8)))
        XCTAssertEqual(try CollectionMockCompiler.apply(source: body, plan: plan), .alreadyPresent)
        for malformed in [#"{"items":[{"showId":null}]}"#, #"{"items":[{"showId":"3"}]}"#, #"{"items":[null]}"#] {
            XCTAssertThrowsError(try CollectionMockCompiler.apply(source: Data(malformed.utf8), plan: plan))
        }
        let decoded = try JSONDecoder().decode(CompiledCollectionMock.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded.identityPresence, .wherePresent)
    }

    private let source = Data(#"{"items":[{"id":"original","details":{"title":"Original","enabled":true,"image":"old"}}],"total":1,"untouched":false}"#.utf8)

    private func draft(edits: [CollectionMockEdit] = [], counts: [String] = ["/total"]) -> CollectionMockDraft {
        CollectionMockDraft(collectionPointer: "/items", item: nil, templateIndex: 0,
            edits: [.init(pointer: "/id", value: .string("synthetic"))] + edits,
            identityPointers: ["/id"], countPointers: counts, position: .append)
    }

    func testNestedTypedEditsAndExplicitCounts() throws {
        let plan = try CollectionMockCompiler.prepare(source: source, draft: draft(edits: [
            .init(pointer: "/details/title", value: .string("Synthetic")),
            .init(pointer: "/details/enabled", value: .bool(false)),
            .init(pointer: "/details/image", value: .null)
        ]))
        guard case .applied(let data, let before, let after) = try CollectionMockCompiler.apply(source: source, plan: plan) else {
            return XCTFail("Expected append")
        }
        XCTAssertEqual(before, 1)
        XCTAssertEqual(after, 2)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["total"] as? Int, 2)
        XCTAssertEqual(object["untouched"] as? Bool, false)
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        let details = try XCTUnwrap(items[1]["details"] as? [String: Any])
        XCTAssertEqual(details["enabled"] as? Bool, false)
        XCTAssertTrue(details["image"] is NSNull)
        XCTAssertEqual(try CollectionMockCompiler.apply(source: data, plan: plan), .alreadyPresent)
    }

    func testPreparationRejectsDuplicateIdentity() throws {
        let duplicate = CollectionMockDraft(collectionPointer: "/items", item: nil, templateIndex: 0,
            edits: [], identityPointers: ["/id"], countPointers: [], position: .append)
        XCTAssertThrowsError(try CollectionMockCompiler.prepare(source: source, draft: duplicate)) {
            XCTAssertEqual($0 as? CollectionMockError, .duplicateIdentity)
        }
    }

    func testTypeMismatchDoesNotCoerceStringsToBooleans() {
        XCTAssertThrowsError(try CollectionMockCompiler.prepare(source: source, draft: draft(edits: [
            .init(pointer: "/details/enabled", value: .string("false"))
        ]))) { XCTAssertEqual($0 as? CollectionMockError, .incompatibleType) }
    }

    func testPointerEscapingAndStrictArrayIndices() throws {
        XCTAssertEqual(try CollectionMockCompiler.pointer("/a~1b/~0/"), ["a/b", "~", ""])
        XCTAssertThrowsError(try CollectionMockCompiler.pointer("/bad~2"))
        XCTAssertThrowsError(try CollectionMockCompiler.pointer("$.items"))
        XCTAssertThrowsError(try CollectionMockCompiler.prepare(source: source, draft: draft(edits: [
            .init(pointer: "/missing", value: .null)
        ])))
    }

    func testLiveResponsePreservesFreshUpstreamItems() throws {
        let plan = try CollectionMockCompiler.prepare(source: source, draft: draft(counts: []))
        let fresh = Data(#"{"items":[{"id":"fresh"}],"total":100}"#.utf8)
        guard case .applied(let data, _, let count) = try CollectionMockCompiler.apply(source: fresh, plan: plan) else {
            return XCTFail("Expected append to fresh source")
        }
        XCTAssertEqual(count, 2)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["total"] as? Int, 100)
    }

    func testLimitsAndInvalidCount() {
        XCTAssertThrowsError(try CollectionMockCompiler.prepare(
            source: Data(repeating: 32, count: CollectionMockCompiler.maximumBodyBytes + 1), draft: draft())) {
            XCTAssertEqual($0 as? CollectionMockError, .sizeLimit)
        }
        XCTAssertThrowsError(try CollectionMockCompiler.prepare(source: source, draft: draft(counts: ["/untouched"]))) {
            XCTAssertEqual($0 as? CollectionMockError, .invalidCount)
        }
    }

    func testLargeIntegerAndBooleanRemainDistinct() throws {
        let body = Data(#"{"items":[{"id":18446744073709551615}],"flag":true}"#.utf8)
        let draft = CollectionMockDraft(collectionPointer: "/items", item: .object(["id": .number("2")]),
            templateIndex: nil, edits: [], identityPointers: ["/id"], countPointers: [], position: .append)
        let plan = try CollectionMockCompiler.prepare(source: body, draft: draft)
        guard case .applied(let data, _, _) = try CollectionMockCompiler.apply(source: body, plan: plan) else {
            return XCTFail("Expected append")
        }
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("18446744073709551615"))
        XCTAssertTrue(text.contains("\"flag\":true"))
    }

    func testNumericIdentityUsesValueNotLiteralSpelling() {
        let draft = CollectionMockDraft(collectionPointer: "/items", item: .object(["id": .number("1.0")]),
            templateIndex: nil, edits: [], identityPointers: ["/id"], countPointers: [], position: .append)
        XCTAssertThrowsError(try CollectionMockCompiler.prepare(source: Data(#"{"items":[{"id":1}]}"#.utf8), draft: draft)) {
            XCTAssertEqual($0 as? CollectionMockError, .duplicateIdentity)
        }
    }
}
