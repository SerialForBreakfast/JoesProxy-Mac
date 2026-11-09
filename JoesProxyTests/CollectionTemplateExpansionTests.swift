import XCTest
@testable import JoesProxy

final class CollectionTemplateExpansionTests: XCTestCase {
    private let source = Data(#"{"count":2,"items":[{"id":"a","title":"Original","nested":{"value":null}},{"other":true}]}"#.utf8)

    private func template(_ position: CollectionMockDraft.Position = .prepend) -> CollectionMockDraft {
        CollectionMockDraft(collectionPointer: "/items", item: nil, templateIndex: 0, edits: [],
            identityPointers: ["/id"], countPointers: ["/count"], position: position,
            identityPresence: .wherePresent)
    }

    private func edits(_ id: String) -> [CollectionMockEdit] {
        [.init(pointer: "/id", value: .string(id)), .init(pointer: "/title", value: .string(id))]
    }

    func testPrependPreservesRequestedOrderTemplateAndMixedSibling() throws {
        let result = try CollectionTemplateExpansion.prepare(source: source, template: template(),
            itemEdits: [edits("first"), edits("second")])
        let root = try CollectionMockCompiler.parse(result)
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["count"], in: root), .number("4"))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "0", "id"], in: root), .string("first"))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "1", "id"], in: root), .string("second"))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "1", "nested", "value"], in: root), .null)
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "3"], in: root), .object(["other": .bool(true)]))
    }

    func testAppendPreservesOrderAndRejectsBatchAndSourceCollisions() throws {
        let result = try CollectionTemplateExpansion.prepare(source: source, template: template(.append),
            itemEdits: [edits("first"), edits("second")])
        let root = try CollectionMockCompiler.parse(result)
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "2", "id"], in: root), .string("first"))
        for batch in [[edits("duplicate"), edits("duplicate")], [edits("a")]] {
            XCTAssertThrowsError(try CollectionTemplateExpansion.prepare(source: source,
                template: template(), itemEdits: batch))
        }
    }

    func testRejectsEmptyAndOversizedBatches() {
        for batch in [[], Array(repeating: edits("x"), count: 101)] {
            XCTAssertThrowsError(try CollectionTemplateExpansion.prepare(source: source,
                template: template(), itemEdits: batch))
        }
    }

    func testMaximumBatchAndConflictingOrMistypedEdits() throws {
        let batch = (0..<100).map { edits("new-\($0)") }
        let result = try CollectionTemplateExpansion.prepare(source: source, template: template(), itemEdits: batch)
        let root = try CollectionMockCompiler.parse(result)
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["count"], in: root), .number("102"))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "99", "id"], in: root), .string("new-99"))
        for extra in [CollectionMockEdit(pointer: "/id", value: .string("duplicate-edit")),
                      .init(pointer: "/nested", value: .number("1"))] {
            XCTAssertThrowsError(try CollectionTemplateExpansion.prepare(source: source, template: template(),
                itemEdits: [edits("first") + [extra]]))
        }
        XCTAssertThrowsError(try CollectionTemplateExpansion.prepare(source: source, template: template(),
            itemEdits: [edits("first") + [.init(pointer: "/nested", value: .object(["value": .null])),
                                         .init(pointer: "/nested/value", value: .null)]]))
    }

    func testExpansionRejectsAggregateOutputBeyondBodyBudget() throws {
        let largeSource = Data(("{\"items\":[{\"id\":\"original\",\"payload\":\""
            + String(repeating: "x", count: 60_000) + "\"}]}").utf8)
        let input = CollectionMockDraft(collectionPointer: "/items", item: nil, templateIndex: 0,
            edits: [], identityPointers: ["/id"], countPointers: [], position: .append)
        let batch = (0..<100).map { [CollectionMockEdit(pointer: "/id", value: .string("new-\($0)"))] }
        XCTAssertThrowsError(try CollectionTemplateExpansion.prepare(source: largeSource, template: input, itemEdits: batch)) {
            XCTAssertEqual($0 as? CollectionMockError, .sizeLimit)
        }
    }
}
