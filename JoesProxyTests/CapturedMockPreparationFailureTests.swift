import XCTest
@testable import JoesProxy

final class CapturedMockPreparationFailureTests: XCTestCase {
    func testUnknownFieldDoesNotEchoUserInputAndUnknownErrorsRemainUnclassified() throws {
        let failure = try XCTUnwrap(CapturedMockPreparationFailure.describe(
            CollectionMockDraftDecoder.ValidationError(field: "synthetic-secret", reason: "unknownField", allowedValues: ["item"])))
        XCTAssertEqual(failure.field, "draftJSON")
        XCTAssertFalse(failure.message.contains("synthetic-secret"))
        XCTAssertNil(CapturedMockPreparationFailure.describe(CancellationError()))
        XCTAssertNil(CapturedMockPreparationFailure.describe(NSError(domain: "synthetic-secret", code: 1)))
    }

    func testImageBookmarkFailureIdentifiesInputWithoutExposingReference() async throws {
        let body = Data(#"{"items":[]}"#.utf8)
        let response = CapturedResponse(statusCode: 200, headers: [], bodyData: body, bodySize: body.count)
        let draft = Data(#"{"collectionPointer":"/items","item":{"id":"new","image":""},"identityPointers":["/id"]}"#.utf8)
        do {
            _ = try await CollectionMockAuthoringService().prepareCapturedResponse(ownerID: "owner",
                idempotencyKey: "request", name: "Synthetic", response: response, draftJSON: draft,
                scope: .init(host: "example.test", scheme: .https, port: 443, path: "/items", clients: .address("192.0.2.1")),
                appVersion: "test", imageFiles: [.init(itemPointer: "/image", bookmarkRef: "synthetic-secret", originalURL: nil)])
            XCTFail("Invalid bookmark must not prepare a package")
        } catch let failure as CapturedMockPreparationFailure {
            XCTAssertEqual(failure.field, "images[0].localFileBookmarkRef")
            XCTAssertEqual(failure.details["nextTool"], "effect_bundle_prepare")
            XCTAssertTrue(failure.message.contains("Nothing was activated"))
            XCTAssertFalse(failure.message.contains("synthetic-secret"))
        }
    }
}
