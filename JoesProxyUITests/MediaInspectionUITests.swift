import XCTest

@MainActor
final class MediaInspectionUITests: XCTestCase {
    func testCapturedMediaFailureRetryAndSourceChange() {
        exerciseCapturedInspection(textSize: "standard")
    }

    func testCapturedMediaControlsWithAccessibilityText() {
        exerciseCapturedInspection(textSize: "accessibility")
    }

    private func exerciseCapturedInspection(textSize: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        // Existing synthetic demo media deliberately has malformed bytes: this exercises
        // real failure/report/retry UI without external requests or a live probe.
        app.launchArguments = ["--ui-test-fixture=demo-sessions", "--ui-test-session-count=8",
            "--ui-test-browser-mode=table", "--ui-test-text-size=\(textSize)"]
        app.launchJoesProxyForTesting()
        let search = app.textFields["sessionSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.click()
        search.typeText("segment-3.m4s")
        let table = app.identifiedElement("sessionTable")
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        let rows = table.descendants(matching: .outlineRow)
        let filtered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [filtered], timeout: 5), .completed,
            "The exact synthetic media search must resolve to one row before selection")
        // Native table cells expose width-dependent truncated values, not full path labels.
        let cell = rows.firstMatch.staticTexts.firstMatch
        XCTAssertTrue(cell.isHittable)
        cell.click()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "segment-3.m4s"), object: table)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
            "Selecting the filtered video row must update the inspected session before opening Media Info")
        let open = app.buttons["openMediaInfoButton"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        let window = app.windows.containing(.button, identifier: "mediaInfoCloseButton").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let run = window.buttons["mediaInfoRunInspectionButton"]
        reveal(run, in: window)
        XCTAssertTrue(run.isEnabled)
        XCTAssertFalse(window.descendants(matching: .any).matching(identifier: "mediaInfoInspectionReport").firstMatch.exists)
        run.click()
        let report = window.descendants(matching: .any).matching(identifier: "mediaInfoInspectionReport").firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        XCTAssertTrue(window.staticTexts["Inspection completed with partial results."].exists)
        reveal(run, in: window)
        XCTAssertEqual(run.label, "Retry Inspection")
        run.click()
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        let picker = window.descendants(matching: .any).matching(identifier: "mediaInfoInspectionSourcePicker").firstMatch
        reveal(picker, in: window)
        picker.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Live URL")).firstMatch.click()
        XCTAssertFalse(report.exists)
        XCTAssertFalse(window.descendants(matching: .any).matching(identifier: "mediaInfoInspectionProgress").firstMatch.exists)
        // Selecting a source is not permission to start a live request; never press Run here.
        window.buttons["mediaInfoCloseButton"].click()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, in window: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<8 where !element.isHittable {
            let delta = element.frame.midY < window.frame.midY ? 250.0 : -250.0
            window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(element.isHittable)
    }
}
