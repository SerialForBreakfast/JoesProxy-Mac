import XCTest
@testable import JoesProxy

final class SimilarItemProposalValidatorTests: XCTestCase {
    private let source = Data(#"{"items":[{"id":"original","title":"Template","protected":true}]}"#.utf8)

    private func template(identity: String = "synthetic") -> CollectionMockDraft {
        CollectionMockDraft(collectionPointer: "/items", item: nil, templateIndex: 0,
            edits: [.init(pointer: "/id", value: .string(identity))],
            identityPointers: ["/id"], countPointers: [], position: .prepend)
    }

    func testGeneratedTextCompilesWithExplicitIdentityAndPreservesTemplateFields() throws {
        let draft = try SimilarItemProposalValidator.validate(source: source, template: template(),
            allowedTextPointers: ["/title"], generated: [.init(pointer: "/title", value: .string("JoeData"))])
        let compiled = try CollectionMockCompiler.prepare(source: source, draft: draft)
        XCTAssertEqual(compiled.item, .object(["id": .string("synthetic"),
            "title": .string("JoeData"), "protected": .bool(true)]))
    }

    func testGeneratedIdentityAndProtectedFieldEditsAreRejected() {
        for pointer in ["/id", "/protected"] {
            XCTAssertThrowsError(try SimilarItemProposalValidator.validate(source: source,
                template: template(), allowedTextPointers: ["/title"],
                generated: [.init(pointer: pointer, value: .string("replacement"))]))
        }
        XCTAssertThrowsError(try SimilarItemProposalValidator.validate(source: source,
            template: template(), allowedTextPointers: ["/id"], generated: []))
    }

    func testCollisionAndNonTextAndOversizedOutputAreRejected() {
        XCTAssertThrowsError(try SimilarItemProposalValidator.validate(source: source,
            template: template(identity: "original"), allowedTextPointers: ["/title"], generated: []))
        for value: BookmarkJSONValue in [.null, .string(String(repeating: "x", count: 8_193))] {
            XCTAssertThrowsError(try SimilarItemProposalValidator.validate(source: source,
                template: template(), allowedTextPointers: ["/title"],
                generated: [.init(pointer: "/title", value: value)]))
        }
    }
}
