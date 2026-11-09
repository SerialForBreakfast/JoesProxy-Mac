import XCTest
@testable import JoesProxy

final class CaptureDiagnosticsRedactionTests: XCTestCase {
    func testPathCategoryStripsQueryAndFragment() {
        XCTAssertEqual(
            CaptureDiagnosticsRedaction.pathCategory(for: "/v1/profile?at=secret-token#section"),
            "/v1/profile"
        )
    }

    func testPathCategoryCapsToFirstTwoSegments() {
        XCTAssertEqual(
            CaptureDiagnosticsRedaction.pathCategory(for: "/api/v2/users/123/orders"),
            "/api/v2"
        )
    }

    func testPathCategoryNormalizesNumericAndUUIDSegments() {
        XCTAssertEqual(
            CaptureDiagnosticsRedaction.pathCategory(for: "/users/12345/profile"),
            "/users/:id"
        )
        XCTAssertEqual(
            CaptureDiagnosticsRedaction.pathCategory(for: "/sessions/550E8400-E29B-41D4-A716-446655440000"),
            "/sessions/:id"
        )
    }
}
