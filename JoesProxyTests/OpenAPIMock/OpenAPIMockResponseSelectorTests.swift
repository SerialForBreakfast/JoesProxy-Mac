import XCTest
@testable import JoesProxy

/// AW-1 response-selection order and stable seed material.
final class OpenAPIMockResponseSelectorTests: XCTestCase {
    func testDeclaredExampleBeatsSchemaFallback() {
        let result = OpenAPIMockResponseSelector.select(candidates: [
            variant(id: "enum", kind: .schemaEnum, name: "archived"),
            variant(id: "example", kind: .declaredExample, name: "available"),
            variant(id: "default", kind: .schemaDefault, name: nil)
        ])
        XCTAssertEqual(selectedID(result), "example")
    }

    func testSchemaExampleThenDefaultThenEnum() {
        XCTAssertEqual(
            selectedID(OpenAPIMockResponseSelector.select(candidates: [
                variant(id: "enum", kind: .schemaEnum, name: "archived"),
                variant(id: "default", kind: .schemaDefault, name: nil)
            ])),
            "default"
        )
        XCTAssertEqual(
            selectedID(OpenAPIMockResponseSelector.select(candidates: [
                variant(id: "enum-b", kind: .schemaEnum, name: "b"),
                variant(id: "enum-a", kind: .schemaEnum, name: "a")
            ])),
            "enum-a"
        )
        XCTAssertEqual(
            selectedID(OpenAPIMockResponseSelector.select(candidates: [
                variant(id: "schema-ex", kind: .schemaExample, name: nil),
                variant(id: "default", kind: .schemaDefault, name: nil)
            ])),
            "schema-ex"
        )
    }

    func testSyntheticWhenNoDeclaredOrSchemaCandidate() {
        let result = OpenAPIMockResponseSelector.select(candidates: [
            variant(id: "synth", kind: .synthetic, name: nil),
            variant(id: "err", kind: .namedError, name: "not_found", status: 404)
        ])
        XCTAssertEqual(selectedID(result), "synth")
    }

    func testNamedErrorOnlyWhenRequested() {
        let candidates = [
            variant(id: "ok", kind: .declaredExample, name: "available"),
            variant(id: "err", kind: .namedError, name: "not_found", status: 404)
        ]
        XCTAssertEqual(selectedID(OpenAPIMockResponseSelector.select(candidates: candidates)), "ok")
        XCTAssertEqual(
            selectedID(OpenAPIMockResponseSelector.select(
                candidates: candidates,
                requestedVariant: "not_found"
            )),
            "err"
        )
    }

    func testNamedErrorAloneWithoutRequestIsUnsupported() {
        let result = OpenAPIMockResponseSelector.select(candidates: [
            variant(id: "err", kind: .namedError, name: "not_found", status: 404)
        ])
        XCTAssertEqual(result, .unsupported)
    }

    func testEmptyCandidatesAreUnsupported() {
        XCTAssertEqual(OpenAPIMockResponseSelector.select(candidates: []), .unsupported)
    }

    func testSeedMaterialIsStableAndOrderSensitive() {
        let packID = OpenAPIMockPackID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let first = OpenAPIMockResponseSelector.seedMaterial(
            packID: packID,
            method: "get",
            template: "/v1/catalog/items/{itemId}",
            status: 200,
            contentType: "Application/JSON",
            variantName: "available"
        )
        let second = OpenAPIMockResponseSelector.seedMaterial(
            packID: packID,
            method: "GET",
            template: "/v1/catalog/items/{itemId}",
            status: 200,
            contentType: "application/json",
            variantName: "available"
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first,
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|GET|/v1/catalog/items/{itemId}|200|application/json|available"
        )

        let other = OpenAPIMockResponseSelector.seedMaterial(
            packID: packID,
            method: "GET",
            template: "/v1/catalog/items/{itemId}",
            status: 404,
            contentType: "application/json",
            variantName: "not_found"
        )
        XCTAssertNotEqual(first, other)
    }

    private func variant(
        id: String,
        kind: OpenAPIMockResponseSourceKind,
        name: String?,
        status: Int = 200
    ) -> OpenAPIMockResponseVariant {
        OpenAPIMockResponseVariant(
            id: id,
            status: status,
            contentType: "application/json",
            sourceKind: kind,
            name: name,
            bodyDigest: nil
        )
    }

    private func selectedID(_ result: OpenAPIMockSelectionResult) -> String? {
        if case .selected(let variant) = result { return variant.id }
        return nil
    }
}
