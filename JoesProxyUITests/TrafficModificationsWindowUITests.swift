import XCTest

final class TrafficModificationsWindowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCompactManagementOpensSeparateWindowWithoutConstructingInspector() {
        let app = XCUIApplication()
        app.launchArguments = ["--compact-mode", "--ui-test-browser-mode=table"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let hud = app.identifiedElement("compactMonitorRoot")
        XCTAssertTrue(hud.waitForExistence(timeout: 8))
        let originalFrame = hud.frame
        app.buttons["compactManageModifications"].click()
        let management = app.windows["Traffic Modifications"]
        XCTAssertTrue(management.waitForExistence(timeout: 5))
        XCTAssertTrue(hud.exists)
        XCTAssertEqual(hud.frame.size, originalFrame.size)
        XCTAssertFalse(app.identifiedElement("sessionTable").exists)
        XCTAssertTrue(management.buttons["newHLSTestStreamButton"].exists)
        management.buttons["trafficModificationsClose"].click()
        XCTAssertTrue(hud.exists)
        app.buttons["compactManageModifications"].click()
        XCTAssertTrue(management.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.matching(identifier: "Traffic Modifications").count, 1)
    }

    @MainActor
    func testMainMenuOpensIndependentManagementWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-browser-mode=table"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 8))
        app.typeKey("l", modifierFlags: [.command, .option])
        XCTAssertTrue(app.windows["Traffic Modifications"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.identifiedElement("sessionTable").exists)
    }
}
