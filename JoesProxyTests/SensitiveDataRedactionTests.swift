import XCTest
@testable import JoesProxy

final class SensitiveDataRedactionTests: XCTestCase {
    func testDetectsExplicitSensitiveHeaders() {
        XCTAssertTrue(SensitiveDataRedaction.isSensitiveHeaderName("Authorization"))
        XCTAssertTrue(SensitiveDataRedaction.isSensitiveHeaderName("X-API-Key"))
        XCTAssertTrue(SensitiveDataRedaction.isSensitiveHeaderName("x-csrf-token"))
        XCTAssertFalse(SensitiveDataRedaction.isSensitiveHeaderName("Accept"))
    }

    func testDetectsTokenLikeKeys() {
        XCTAssertTrue(SensitiveDataRedaction.isSensitiveKey("sessionToken"))
        XCTAssertTrue(SensitiveDataRedaction.isSensitiveKey("api-key"))
        XCTAssertFalse(SensitiveDataRedaction.isSensitiveKey("quality"))
    }

    func testDetectsUserIdentifierKeys() {
        XCTAssertTrue(SensitiveDataRedaction.isUserIdentifierKey("user_id"))
        XCTAssertTrue(SensitiveDataRedaction.isUserIdentifierKey("subscriberID"))
        XCTAssertFalse(SensitiveDataRedaction.isUserIdentifierKey("bitrate"))
    }

    func testRedactsQueryParametersInURLString() {
        XCTAssertEqual(
            SensitiveDataRedaction.redactedQueryURLString("https://example.com/path?token=abc&asset=video"),
            "https://example.com/path?token=%3Credacted%3E&asset=%3Credacted%3E"
        )
    }
}
