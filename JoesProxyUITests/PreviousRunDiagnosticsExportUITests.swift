import AppKit
import XCTest

/// The app writes through its real save panel; only the host verifies repository file bytes.
final class PreviousRunDiagnosticsExportUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSettingsExportMatchesCopiedReport() throws {
        try verifyExport(agent: false, textSize: "standard")
    }

    @MainActor
    func testSettingsExportWithAccessibilityText() throws {
        try verifyExport(agent: false, textSize: "accessibility")
    }

    @MainActor
    func testAgentExportPreservesReportAcrossWorkspaceSwitch() throws {
        try verifyExport(agent: true, textSize: "accessibility")
    }

    @MainActor
    private func verifyExport(agent: Bool, textSize: String) throws {
        let artifactPath = try XCTUnwrap(ProcessInfo.processInfo.environment["JOESPROXY_UI_ARTIFACT_DIRECTORY"])
        let outputName = "PreviousRunDiagnostics-\(UUID().uuidString).txt"
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-browser-mode=table", "--ui-test-rolling-restore=offered",
                               "--ui-test-text-size=\(textSize)", "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let startupCopy = app.buttons["rollingCaptureCopyDiagnosticsButton"]
        XCTAssertTrue(startupCopy.waitForExistence(timeout: 8))
        startupCopy.click()
        let expectedText = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertTrue(expectedText.hasPrefix("JoesProxy previous-run diagnostics"))
        XCTAssertTrue(expectedText.contains("Nothing was uploaded"))

        let copyID: String
        let saveID: String
        let feedbackID: String
        if agent {
            app.buttons["rollingCaptureStartFreshButton"].click()
            app.menuBars.menuBarItems["Tools"].click()
            app.menuItems["Return to Agent Workspace"].click()
            XCTAssertTrue(app.identifiedElement("compactMonitorRoot").waitForExistence(timeout: 8))
            app.menuBars.menuBarItems["Agent Workspace"].click()
            app.menuItems["Capture Recovery"].click()
            copyID = "agentCaptureRecoveryCopyDiagnosticsButton"
            saveID = "agentCaptureRecoverySaveDiagnosticsButton"
            feedbackID = "agentCaptureRecoveryDiagnosticsSaveMessage"
        } else {
            app.buttons["rollingCaptureOpenSettingsButton"].click()
            copyID = "settingsCopyDiagnosticsButton"
            saveID = "settingsSaveDiagnosticsButton"
            feedbackID = "settingsDiagnosticsSaveMessage"
        }

        let window = app.windows.containing(.any, identifier: copyID).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        let copy = window.buttons[copyID]
        // Recovery Settings may need scrolling at accessibility text size.
        for _ in 0..<8 {
            if copy.isHittable { break }
            window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -150)
        }
        XCTAssertTrue(copy.isHittable)
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), expectedText,
                       "All recovery surfaces must offer the same frozen report")
        let save = window.buttons[saveID]
        XCTAssertTrue(save.isHittable)
        save.click()
        let panel = app.dialogs["save-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let locationSheet = panel.sheets.firstMatch
        XCTAssertTrue(locationSheet.waitForExistence(timeout: 5))
        let location = locationSheet.comboBoxes.firstMatch.exists
            ? locationSheet.comboBoxes.firstMatch : locationSheet.textFields.firstMatch
        XCTAssertTrue(location.exists)
        location.click()
        location.typeKey("a", modifierFlags: .command)
        location.typeText(artifactPath)
        location.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: locationSheet
        )], timeout: 5), .completed)
        let name = panel.textFields["saveAsNameTextField"]
        XCTAssertTrue(name.exists)
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText(outputName)
        panel.buttons["SaveButton"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: panel
        )], timeout: 5), .completed)
        let feedback = window.descendants(matching: .any).matching(identifier: feedbackID).firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertTrue(feedback.label == "Diagnostics saved." || feedback.value as? String == "Diagnostics saved.")

        let receiptData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "outputName": outputName, "expectedText": expectedText
        ], options: [.sortedKeys])
        let receipt = XCTAttachment(data: receiptData, uniformTypeIdentifier: "public.json")
        receipt.name = "previous-run-diagnostics-output"
        receipt.lifetime = .keepAlways
        add(receipt)
    }
}
