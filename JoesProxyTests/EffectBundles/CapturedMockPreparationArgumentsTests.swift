import XCTest
@testable import JoesProxy

final class CapturedMockPreparationArgumentsTests: XCTestCase {
    private var arguments: [String: Any] {
        ["sessionID": UUID().uuidString, "name": "Synthetic", "clientAddress": "192.0.2.1",
         "idempotencyKey": "request", "draftJSON": "{}"]
    }
    func testPrimaryArgumentFailuresAreFieldSpecificAndPrivate() throws {
        for field in ["sessionID", "name", "clientAddress", "idempotencyKey", "draftJSON"] {
            var input = arguments
            input[field] = ["synthetic-secret"]
            XCTAssertThrowsError(try CapturedMockPreparationArguments(input)) { error in
                let failure = error as? CapturedMockPreparationFailure
                XCTAssertEqual(failure?.field, field)
                XCTAssertEqual(failure?.details["nextTool"], "effect_bundle_prepare")
                XCTAssertFalse(failure?.message.contains("synthetic-secret") ?? true)
            }
        }
        var oversized = arguments
        oversized["draftJSON"] = String(repeating: "x", count: 65_537)
        XCTAssertThrowsError(try CapturedMockPreparationArguments(oversized))
        oversized = arguments
        oversized["idempotencyKey"] = String(repeating: "x", count: 257)
        XCTAssertThrowsError(try CapturedMockPreparationArguments(oversized))
    }
    func testSourceAvailabilityAndMethodRemainDistinct() {
        let request = CapturedRequest(method: "GET", scheme: .https, host: "example.test", port: 443,
            path: "/items", headers: [], bodyData: nil, bodySize: nil)
        let responses: [(CapturedResponse, String)] = [
            (.init(statusCode: 200, headers: [], bodyData: nil, bodySize: 100, bodyDeferred: true), "bodyDeferred"),
            (.init(statusCode: 200, headers: [], bodyData: Data(), bodySize: 100, bodyTruncated: true), "bodyTruncated"),
            (.init(statusCode: 200, headers: [], bodyData: nil, bodySize: 100), "bodyUnavailable")
        ]
        for (response, reason) in responses {
            let record = SessionRecord(request: request, response: response, timing: .init(startedAt: Date()))
            XCTAssertThrowsError(try CapturedMockPreparationArguments.response(from: record)) { error in
                XCTAssertEqual((error as? CapturedMockPreparationFailure)?.reason, reason)
            }
        }
        XCTAssertThrowsError(try CapturedMockPreparationArguments.response(from: nil)) { error in
            XCTAssertEqual((error as? CapturedMockPreparationFailure)?.reason, "sourceUnavailable")
        }
    }
}
