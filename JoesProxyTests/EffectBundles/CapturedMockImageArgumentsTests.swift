import XCTest
@testable import JoesProxy

final class CapturedMockImageArgumentsTests: XCTestCase {
    func testPreservesExplicitDeliveryPairAndRelatedOnlyBindingWithoutFileAccess() throws {
        let images = try CapturedMockImageArguments.decode([
            ["localFileBookmarkRef": "opaque-reference", "deliveryURL": "https://images.example.test/mock.png",
             "imageReference": "files/mock.png"]
        ])
        let image = try XCTUnwrap(images.first)
        XCTAssertNil(image.itemPointer)
        XCTAssertNil(image.originalURL)
        XCTAssertEqual(image.deliveryURL?.absoluteString, "https://images.example.test/mock.png")
        XCTAssertEqual(image.imageReference, "files/mock.png")
        XCTAssertEqual(image.bookmarkRef, "opaque-reference")
        XCTAssertTrue(try CapturedMockImageArguments.decode(nil).isEmpty)
    }

    func testErrorsIdentifySecondImageWithoutEchoingPrivateValues() throws {
        let valid: [String: Any] = ["localFileBookmarkRef": "opaque"]
        let cases: [([String: Any], String, String)] = [
            (["localFileBookmarkRef": "synthetic-secret", "synthetic-secret": true], "images[1]", "unknownField"),
            (["localFileBookmarkRef": ""], "images[1].localFileBookmarkRef", "invalidReference"),
            (["localFileBookmarkRef": "opaque", "itemPointer": 4], "images[1].itemPointer", "incompatibleType"),
            (["localFileBookmarkRef": "opaque", "originalURL": "file:///synthetic-secret"], "images[1].originalURL", "invalidURL"),
            (["localFileBookmarkRef": "opaque", "imageReference": "synthetic-secret"], "images[1]", "invalidDeliveryPair"),
            (["localFileBookmarkRef": "opaque", "deliveryURL": "https://images.example.test/mock.png",
              "imageReference": ""], "images[1]", "invalidDeliveryPair"),
            (["localFileBookmarkRef": "opaque", "originalURL": "https://images.example.test/original.png",
              "deliveryURL": "https://images.example.test/mock.png", "imageReference": "files/mock.png"], "images[1]", "invalidDeliveryPair")
        ]
        for (invalid, field, reason) in cases {
            XCTAssertThrowsError(try CapturedMockImageArguments.decode([valid, invalid])) { error in
                guard let failure = error as? CapturedMockPreparationFailure else {
                    return XCTFail("Expected structured preparation failure")
                }
                XCTAssertEqual(failure.field, field)
                XCTAssertEqual(failure.reason, reason)
                XCTAssertEqual(failure.details["nextTool"], "effect_bundle_prepare")
                XCTAssertFalse(failure.message.contains("synthetic-secret"))
                XCTAssertTrue(failure.message.contains("Nothing was activated"))
            }
        }
    }

    func testRejectsNonArrayAndOversizedInputs() {
        let inputs: [Any] = ["synthetic-secret", Array(repeating: ["localFileBookmarkRef": "opaque"], count: 17)]
        for input in inputs {
            XCTAssertThrowsError(try CapturedMockImageArguments.decode(input)) { error in
                XCTAssertEqual((error as? CapturedMockPreparationFailure)?.field, "images")
                XCTAssertEqual((error as? CapturedMockPreparationFailure)?.reason, "invalidCount")
            }
        }
    }
}
