import XCTest

/// Seeded host acceptance only; run through the serial host wrapper after local-user approval.
final class AgentWorkspaceLifecycleUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAgentInspectorRoundTripKeepsSearchAndIndependentRecoveryWindow() throws {
        try verifyRoundTrip(accessibilityText: false)
    }

    @MainActor
    func testAgentInspectorRoundTripWithAccessibilityText() throws {
        try verifyRoundTrip(accessibilityText: true)
    }

    @MainActor
    private func verifyRoundTrip(accessibilityText: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--agent-workspace", "--ui-test-browser-mode=table",
                               "--ui-test-fixture=demo-sessions"]
        if accessibilityText { app.launchArguments.append("--ui-test-text-size=accessibility") }
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        XCTAssertTrue(app.identifiedElement("compactMonitorRoot").waitForExistence(timeout: 8))
        XCTAssertFalse(app.identifiedElement("sessionTable").exists)
        app.menuBars.menuBarItems["Agent Workspace"].click()
        app.menuItems["Capture Recovery"].click()
        let recovery = app.identifiedElement("agentCaptureRecovery")
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Agent Workspace"].click()
        app.menuItems["Capture Recovery"].click()
        XCTAssertEqual(app.windows.containing(.any, identifier: "agentCaptureRecovery").count, 1)
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 8))
        XCTAssertTrue(recovery.exists, "Shared supervision must survive Inspector entry")
        let search = app.textFields["sessionSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("agw-no-matching-record")
        XCTAssertTrue(app.staticTexts["No Matching Sessions"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Tools"].click()
        app.menuItems["Return to Agent Workspace"].click()
        XCTAssertTrue(app.identifiedElement("compactMonitorRoot").waitForExistence(timeout: 8))
        XCTAssertTrue(recovery.exists, "Workspace departure must not close shared recovery")
        XCTAssertFalse(app.identifiedElement("sessionTable").exists)
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 8))
        XCTAssertEqual(app.textFields["sessionSearchField"].value as? String, "agw-no-matching-record")
        XCTAssertTrue(app.staticTexts["No Matching Sessions"].waitForExistence(timeout: 5))
    }
}
