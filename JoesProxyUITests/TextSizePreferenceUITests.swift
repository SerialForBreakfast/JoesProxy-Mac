import XCTest

final class TextSizePreferenceUITests: XCTestCase {
    @MainActor
    func testInspectorRespondsToSettingsTextSizeWithoutRelaunch() {
        checkLiveSizing(compact: false, identifier: "capturePipelinePill")
    }

    @MainActor
    func testCompactRespondsToSettingsTextSizeWithoutRelaunch() {
        checkLiveSizing(compact: true, identifier: "monitoringTileLabel-sessions")
    }

    @MainActor
    private func checkLiveSizing(compact: Bool, identifier: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=demo-sessions", "--ui-test-browser-mode=table", "--ui-test-text-size=standard"]
        if compact { app.launchArguments.append("--compact-mode") }
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let sample = app.identifiedElement(identifier)
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        let originalHeight = sample.frame.height
        let originalWidth = sample.frame.width
        XCTAssertGreaterThan(originalHeight, 0)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.identifiedElement("settingsTextSizePicker").waitForExistence(timeout: 5))
        app.radioButtons["Accessibility"].firstMatch.click()
        let enlarged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            sample.frame.height > originalHeight + 2 && (!compact || sample.frame.width > originalWidth + 2)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enlarged], timeout: 5), .completed,
                       "Changing Settings must enlarge visible text in the existing window.")
        if compact {
            let hud = app.identifiedElement("compactMonitorRoot")
            let window = app.windows.containing(.any, identifier: "compactMonitorRoot").firstMatch
            XCTAssertTrue(window.frame.insetBy(dx: -2, dy: -2).contains(hud.frame),
                          "The Compact window must resize to contain the larger HUD.")
            for id in ["proxy", "sessions", "throughput", "connections", "errors", "dropped", "duration", "approvals"] {
                XCTAssertTrue(hud.frame.contains(app.identifiedElement("monitoringTileLabel-\(id)").frame))
            }
            XCTAssertTrue(hud.frame.contains(app.identifiedElement("compactApprovalsButton").frame))
        }
        let largeHeight = sample.frame.height
        app.radioButtons["Small"].firstMatch.click()
        let reduced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            sample.frame.height < largeHeight - 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reduced], timeout: 5), .completed,
                       "Reducing text size must shrink the same visible text without relaunch.")
        if compact { XCTAssertFalse(app.identifiedElement("sessionTable").exists) }
    }
}
