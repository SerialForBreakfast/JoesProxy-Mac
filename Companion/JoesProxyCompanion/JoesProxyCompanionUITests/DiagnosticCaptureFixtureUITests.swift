import XCTest

final class DiagnosticCaptureFixtureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEmitsDeterministicCaptureSequence() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--diagnostic-capture-fixture"]
        app.launch()

        let status = app.staticTexts["diagnosticCaptureFixtureStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))

        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Diagnostic capture fixture complete"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed)

        let attachment = XCTAttachment(string: "runID=phase0-capture-v1 stages=3")
        attachment.name = "Diagnostic Capture Fixture Manifest"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
