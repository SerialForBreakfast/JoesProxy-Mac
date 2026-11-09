import XCTest
@testable import JoesProxy

final class CollectionMockDraftDecoderTests: XCTestCase {
    func testIdentityPresenceDiscoveryValuesAndLegacyDefault() throws {
        let json = #"{"collectionPointer":"/items","item":{"id":1},"identityPointers":["/id"]}"#
        let legacy = try CollectionMockDraftDecoder.decode(Data(json.utf8))
        XCTAssertNil(legacy.identityPresence)
        let encoded = try JSONEncoder().encode(legacy)
        XCTAssertNil(try JSONDecoder().decode(CollectionMockDraft.self, from: encoded).identityPresence)
        let mixed = String(json.dropLast()) + #", "identityPresence":"wherePresent"}"#
        XCTAssertEqual(try CollectionMockDraftDecoder.decode(Data(mixed.utf8)).identityPresence, .wherePresent)
        let invalid = String(json.dropLast()) + #", "identityPresence":"ignoreErrors"}"#
        XCTAssertThrowsError(try CollectionMockDraftDecoder.decode(Data(invalid.utf8))) {
            XCTAssertEqual(($0 as? CollectionMockDraftDecoder.ValidationError)?.allowedValues, ["required", "wherePresent"])
        }
    }
    func testNaturalJSONPreservesTypesThroughCompilation() throws {
        let draft = try CollectionMockDraftDecoder.decode(Data(#"{"collectionPointer":"/items","item":{"id":"new","nested":{"enabled":false,"values":[null,2,"2"]}},"identityPointers":["/id"]}"#.utf8))
        let source = Data(#"{"items":[]}"#.utf8)
        let plan = try CollectionMockCompiler.prepare(source: source, draft: draft)
        guard case .applied(let bytes, _, _) = try CollectionMockCompiler.apply(source: source, plan: plan) else {
            return XCTFail("Expected prepared item")
        }
        XCTAssertEqual(try CollectionMockCompiler.parse(bytes), try CollectionMockCompiler.parse(Data(#"{"items":[{"id":"new","nested":{"enabled":false,"values":[null,2,"2"]}}]}"#.utf8)))
    }

    func testNullEditIsDifferentFromMissingValue() throws {
        let prefix = #"{"collectionPointer":"/items","templateIndex":0,"identityPointers":["/id"],"edits": ["#
        let draft = try CollectionMockDraftDecoder.decode(Data((prefix + #"{"pointer":"/image","value":null}]}"#).utf8))
        XCTAssertEqual(draft.edits.first?.value, .null)
        XCTAssertThrowsError(try CollectionMockDraftDecoder.decode(Data((prefix + #"{"pointer":"/image"}]}"#).utf8)))
    }

    func testInvalidArgumentsFailClosedWithStableReasons() {
        for extra in [#", "templateIndex":true"#, #", "templateIndex":-1"#, #", "templateIndex":0.5"#,
                      #", "item":null"#, #", "item":{},"templateIndex":0"#, #", "templateIndex":0,"postion":"append""#,
                      #", "templateIndex":0,"position":"after""#] {
            let json = #"{"collectionPointer":"/items","identityPointers":["/id"]"# + extra + "}"
            XCTAssertThrowsError(try CollectionMockDraftDecoder.decode(Data(json.utf8))) {
                XCTAssertNotNil($0 as? CollectionMockDraftDecoder.ValidationError)
            }
        }
    }

    func testInputBudgetAndPointerValidation() {
        XCTAssertThrowsError(try CollectionMockDraftDecoder.decode(Data(repeating: 32, count: CollectionMockDraftDecoder.maximumInputBytes + 1))) {
            XCTAssertEqual($0 as? CollectionMockError, .sizeLimit)
        }
        XCTAssertThrowsError(try CollectionMockDraftDecoder.decode(Data(#"{"collectionPointer":"$.items","item":{},"identityPointers":["/id"]}"#.utf8)))
    }
}
