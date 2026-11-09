import AppKit
import XCTest

/// Proves first-run path choice and rolling-capture restore never stack (BA-2 / BA-3).
final class LaunchArbitrationUITests: XCTestCase {
    @MainActor
    func testCompactRestoreOutranksFirstRunThenOffersPathChoice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--compact-mode", "--ui-test-browser-mode=table",
                               "--ui-test-guided-setup-mode=first-run", "--ui-test-rolling-restore=offered"]
        app.launchJoesProxyForTesting()
        XCTAssertTrue(app.identifiedElement("rollingCaptureRestoreSheet").waitForExistence(timeout: 8))
        XCTAssertFalse(app.identifiedElement("firstRunPathChoiceView").exists)
        app.buttons["rollingCaptureStartFreshButton"].click()
        XCTAssertTrue(app.identifiedElement("firstRunPathChoiceView").waitForExistence(timeout: 8))
    }

    @MainActor
    func testPendingRestoreSurvivesModeSwitch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--compact-mode", "--ui-test-browser-mode=table", "--ui-test-rolling-restore=offered"]
        app.launchJoesProxyForTesting()
        let sheet = app.identifiedElement("rollingCaptureRestoreSheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 8))
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 8))
        XCTAssertTrue(sheet.exists)
        app.buttons["rollingCaptureStartFreshButton"].click()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: sheet
        )], timeout: 5) == .completed)
    }

    @MainActor
    func testCompactRestoreFailureThenStartFresh() throws {
        try verifyRecoveryFlow(compact: true)
    }

    @MainActor
    func testFullRestoreFailureThenStartFresh() throws {
        try verifyRecoveryFlow(compact: false)
    }

    @MainActor
    private func verifyRecoveryFlow(compact: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-browser-mode=table", "--ui-test-rolling-restore=offered"]
        if compact { app.launchArguments.append("--compact-mode") }
        app.launchJoesProxyForTesting()
        let sheet = app.identifiedElement("rollingCaptureRestoreSheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 8))
        let suppression = app.checkBoxes["rollingCaptureSuppressPromptToggle"]
        XCTAssertTrue(suppression.exists)
        XCTAssertEqual(checkboxValue(suppression), false)
        suppression.click()
        XCTAssertEqual(checkboxValue(suppression), true)
        XCTAssertTrue(sheet.exists, "Preference changes must not resolve the offer.")
        XCTAssertTrue(app.identifiedElement("rollingCaptureExportMenu").exists)
        if compact { XCTAssertFalse(app.identifiedElement("sessionTable").exists) }
        app.buttons["rollingCaptureRestoreResumeButton"].click()
        XCTAssertTrue(app.identifiedElement("rollingCaptureRestoreError").waitForExistence(timeout: 8))
        XCTAssertTrue(sheet.exists, "Failed restore must retain the decision surface.")
        app.buttons["rollingCaptureStartFreshButton"].click()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: sheet
        )], timeout: 5) == .completed)
        app.typeKey("0", modifierFlags: .command)
        let destination = compact ? "sessionTable" : "compactMonitorRoot"
        XCTAssertTrue(app.identifiedElement(destination).waitForExistence(timeout: 8))
        XCTAssertFalse(sheet.exists, "Switching modes must not reinstall a dismissed startup offer.")
    }

    @MainActor
    func testRecoverySettingsLinkPreservesOfferAndSharesPreference() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-browser-mode=table", "--ui-test-rolling-restore=offered"]
        app.launchJoesProxyForTesting()
        let sheet = app.identifiedElement("rollingCaptureRestoreSheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 8))
        app.checkBoxes["rollingCaptureSuppressPromptToggle"].click()
        let settingsLink = app.identifiedElement("rollingCaptureOpenSettingsButton")
        XCTAssertTrue(settingsLink.waitForExistence(timeout: 5))
        settingsLink.click()
        let prompt = app.identifiedElement("settingsRollingCaptureRestorePromptToggle")
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        XCTAssertEqual(checkboxValue(prompt), false)
        let settingsWindow = app.windows.containing(.any, identifier: "settingsRollingCaptureRestorePromptToggle").firstMatch
        XCTAssertTrue(settingsWindow.exists)
        let before = XCTAttachment(screenshot: settingsWindow.screenshot())
        before.name = "Recovery Settings before toggle"
        before.lifetime = .deleteOnSuccess
        add(before)
        prompt.click()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR value == %@", NSNumber(value: true), "1"),
            object: prompt
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed,
                       "Settings must enable launch prompting after one click. \(prompt.debugDescription)")
        XCTAssertTrue(sheet.exists)
        XCTAssertEqual(checkboxValue(app.checkBoxes["rollingCaptureSuppressPromptToggle"]), false)
    }

    @MainActor
    func testRecoveryExportMenuAndKeyboardRestore() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--compact-mode", "--ui-test-browser-mode=table", "--ui-test-rolling-restore=offered"]
        app.launchJoesProxyForTesting()
        XCTAssertTrue(app.identifiedElement("rollingCaptureRestoreSheet").waitForExistence(timeout: 8))
        app.identifiedElement("rollingCaptureExportMenu").click()
        XCTAssertTrue(app.menuItems["Save .jproxy File…"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Export .har File…"].exists)
        app.menuItems["Save .jproxy File…"].click()
        let cancel = app.dialogs["save-panel"].buttons["CancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(app.identifiedElement("rollingCaptureRestoreSheet").exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.identifiedElement("rollingCaptureRestoreError").waitForExistence(timeout: 8))
    }

    /// One-click copy of the synthetic in-memory report in both layouts; canceling Save is not an error.
    @MainActor
    func testRestoreSheetCopiesPreviousRunDiagnosticsAndCancelsSave() throws {
        try verifyDiagnosticsCopyAndCancel(textSize: "standard")
    }

    @MainActor
    func testRestoreSheetDiagnosticsWithAccessibilityText() throws {
        try verifyDiagnosticsCopyAndCancel(textSize: "accessibility")
    }

    @MainActor
    private func verifyDiagnosticsCopyAndCancel(textSize: String) throws {
        for compact in [true, false] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-browser-mode=table", "--ui-test-rolling-restore=offered",
                                   "--ui-test-text-size=\(textSize)", "--ui-test-primary-screen"]
            if compact { app.launchArguments.append("--compact-mode") }
            app.launchJoesProxyForTesting()
            defer { app.terminate() }
            XCTAssertTrue(app.identifiedElement("rollingCaptureRestoreSheet").waitForExistence(timeout: 8))

            NSPasteboard.general.clearContents()
            let copy = app.buttons["rollingCaptureCopyDiagnosticsButton"]
            XCTAssertTrue(copy.waitForExistence(timeout: 5))
            XCTAssertTrue(copy.isHittable, "Copy glyph must not be clipped")
            XCTAssertEqual(copy.label, "Copy previous-run diagnostics")
            let window = app.windows.containing(.any, identifier: "rollingCaptureCopyDiagnosticsButton").firstMatch
            XCTAssertTrue(window.exists, "Capture the window owning the recovery control")
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
            XCTAssertTrue(copy.isHittable, "Recovery must remain reachable after activation")
            let screenshot = XCTAttachment(screenshot: window.screenshot())
            screenshot.name = "Previous-run diagnostics \(compact ? "Compact" : "Full") \(textSize)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            copy.click()
            let copiedFeedback = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", "Diagnostics copied"), object: copy)
            XCTAssertEqual(XCTWaiter.wait(for: [copiedFeedback], timeout: 3), .completed)
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            XCTAssertTrue(copied.hasPrefix("JoesProxy previous-run diagnostics"))
            XCTAssertTrue(copied.contains("Nothing was uploaded"))

            app.identifiedElement("rollingCaptureExportMenu").click()
            XCTAssertTrue(app.menuItems["Save Diagnostics…"].waitForExistence(timeout: 3))
            app.menuItems["Save Diagnostics…"].click()
            let cancel = app.dialogs["save-panel"].buttons["CancelButton"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.click()
            XCTAssertTrue(app.identifiedElement("rollingCaptureRestoreSheet").exists)
            XCTAssertFalse(app.identifiedElement("rollingCaptureDiagnosticsSaveMessage").exists)
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func checkboxValue(_ element: XCUIElement) -> Bool? {
        if let number = element.value as? NSNumber { return number.boolValue }
        if let value = element.value as? String, let number = Int(value) { return number != 0 }
        return nil
    }

    /// Injects first-run path choice and an in-memory restore offer; restore must win (BA-2).
    @MainActor
    func testFirstRunAndRollingRestoreDoNotStack() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-browser-mode=table",
            "--ui-test-guided-setup-mode=first-run",
            "--ui-test-rolling-restore=offered"
        ]
        app.launchJoesProxyForTesting()

        let restoreSheet = app.identifiedElement("rollingCaptureRestoreSheet")
        XCTAssertTrue(
            restoreSheet.waitForExistence(timeout: 8),
            "Rolling-capture restore should be the single primary launch surface."
        )
        XCTAssertTrue(
            app.identifiedElement("rollingCaptureRestoreResumeButton").waitForExistence(timeout: 2),
            "Restore sheet must expose a resume affordance."
        )
        XCTAssertFalse(
            app.identifiedElement("guidedSetupRepairView").exists,
            "First-run Guided Setup must not stack on top of the restore offer."
        )
        XCTAssertFalse(
            app.identifiedElement("firstRunPathChoiceView").exists,
            "First-run path choice must not stack on top of the restore offer."
        )
    }
}
