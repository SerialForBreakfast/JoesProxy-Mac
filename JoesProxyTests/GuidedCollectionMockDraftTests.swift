import XCTest
@testable import JoesProxy

final class GuidedCollectionMockDraftTests: XCTestCase {
    func testTemplateAndTypedEditsPreserveUnchangedFieldsAndTypes() throws {
        var input = GuidedCollectionMockDraft()
        input.useTemplate = true
        input.templateIndex = 0
        input.itemJSON = "unused invalid draft is retained"
        input.edits = [.init(pointer: "/id", valueJSON: "\"new\""),
            .init(pointer: "/enabled", valueJSON: "true"), .init(pointer: "/count", valueJSON: "42"),
            .init(pointer: "/nested", valueJSON: #"{"items":[null,false,3]}"#)]
        let draft = try CollectionMockDraftDecoder.decode(input.encoded())
        XCTAssertNil(draft.item)
        XCTAssertEqual(draft.templateIndex, 0)
        let source = Data(#"{"items":[{"id":"old","enabled":false,"count":1,"nested":{},"untouched":"keep"}]}"#.utf8)
        let plan = try CollectionMockCompiler.prepare(source: source, draft: draft)
        guard case .applied(let body, _, _) = try CollectionMockCompiler.apply(source: source, plan: plan) else {
            return XCTFail("Expected appended template")
        }
        let root = try CollectionMockCompiler.parse(body)
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "1", "untouched"], in: root), .string("keep"))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "1", "enabled"], in: root), .bool(true))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "1", "count"], in: root), .number("42"))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "1", "nested", "items"], in: root), .array([.null, .bool(false), .number("3")]))
        input.templateIndex = 99
        XCTAssertThrowsError(try CollectionMockCompiler.prepare(source: source, draft: CollectionMockDraftDecoder.decode(input.encoded())))
    }

    func testInvalidTypedEditIdentifiesInputWithoutEchoingValue() {
        var input = GuidedCollectionMockDraft()
        input.edits = [.init(pointer: "/id", valueJSON: "synthetic-secret")]
        XCTAssertThrowsError(try input.encoded()) { error in
            XCTAssertEqual((error as? CapturedMockPreparationFailure)?.field, "draftJSON.edits[0]")
            XCTAssertFalse((error as? CapturedMockPreparationFailure)?.message.contains("synthetic-secret") ?? true)
        }
    }
    func testGuidedFieldsPreserveTypedValuesAndExplicitCounts() throws {
        var input = GuidedCollectionMockDraft()
        input.itemJSON = #"{"id":"new","enabled":false,"nested":{"value":null},"count":2}"#
        input.prepend = true
        let draft = try CollectionMockDraftDecoder.decode(input.encoded())
        XCTAssertEqual(draft.countPointers, [])
        XCTAssertEqual(draft.position, .prepend)
        guard case .object(let item) = draft.item else { return XCTFail("Expected typed item") }
        XCTAssertEqual(item["enabled"], .bool(false))
        XCTAssertEqual(item["count"], .number("2"))
        XCTAssertEqual(item["nested"], .object(["value": .null]))
        input.countPointers = " /total \n /pagination/total \n"
        XCTAssertEqual(try CollectionMockDraftDecoder.decode(input.encoded()).countPointers, ["/total", "/pagination/total"])
    }

    func testInvalidIdentityAndNonobjectItemCannotPrepare() {
        var input = GuidedCollectionMockDraft()
        input.identityPointers = ""
        XCTAssertThrowsError(try input.encoded())
        input.identityPointers = "/id\n/id"
        XCTAssertThrowsError(try input.encoded())
        input.identityPointers = "/id"
        input.itemJSON = "null"
        XCTAssertThrowsError(try input.encoded())
        input.itemJSON = "{"
        XCTAssertThrowsError(try input.encoded())
    }
}
