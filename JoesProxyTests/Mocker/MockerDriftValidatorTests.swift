import XCTest
@testable import JoesProxy

final class MockerDriftValidatorTests: XCTestCase {

    func testIdenticalPayloadsReportCompliant() {
        let json = "{\"id\": 123, \"name\": \"Alice\", \"roles\": [\"admin\"]}".data(using: .utf8)!
        let report = MockerDriftValidator.validate(fixtureData: json, wireData: json, fixtureStatusCode: 200, wireStatusCode: 200)

        XCTAssertTrue(report.isCompliant)
        XCTAssertTrue(report.violations.isEmpty)
        XCTAssertTrue(report.summary.contains("100% synchronized"))
    }

    func testMissingPropertyInMockDetected() {
        let fixtureJSON = "{\"id\": 123}".data(using: .utf8)!
        let wireJSON = "{\"id\": 123, \"email\": \"alice@example.com\"}".data(using: .utf8)!

        let report = MockerDriftValidator.validate(fixtureData: fixtureJSON, wireData: wireJSON)

        XCTAssertFalse(report.isCompliant)
        XCTAssertEqual(report.violations.count, 1)
        XCTAssertEqual(report.violations[0].kind, .missingInFixture)
        XCTAssertEqual(report.violations[0].keyPath, "$.email")
    }

    func testDeprecatedExtraPropertyInMockDetected() {
        let fixtureJSON = "{\"id\": 123, \"legacy_flag\": true}".data(using: .utf8)!
        let wireJSON = "{\"id\": 123}".data(using: .utf8)!

        let report = MockerDriftValidator.validate(fixtureData: fixtureJSON, wireData: wireJSON)

        XCTAssertFalse(report.isCompliant)
        XCTAssertEqual(report.violations.count, 1)
        XCTAssertEqual(report.violations[0].kind, .extraInFixture)
        XCTAssertEqual(report.violations[0].keyPath, "$.legacy_flag")
    }

    func testDataTypeMismatchDetected() {
        let fixtureJSON = "{\"id\": \"123\"}".data(using: .utf8)!
        let wireJSON = "{\"id\": 123}".data(using: .utf8)!

        let report = MockerDriftValidator.validate(fixtureData: fixtureJSON, wireData: wireJSON)

        XCTAssertFalse(report.isCompliant)
        XCTAssertEqual(report.violations.count, 1)
        XCTAssertEqual(report.violations[0].kind, .typeMismatch)
        XCTAssertEqual(report.violations[0].keyPath, "$.id")
    }

    func testStatusCodeMismatchDetected() {
        let json = "{}".data(using: .utf8)!
        let report = MockerDriftValidator.validate(fixtureData: json, wireData: json, fixtureStatusCode: 200, wireStatusCode: 500)

        XCTAssertFalse(report.isCompliant)
        XCTAssertEqual(report.violations.count, 1)
        XCTAssertEqual(report.violations[0].kind, .statusCodeMismatch)
        XCTAssertEqual(report.violations[0].keyPath, "$status")
    }
}
