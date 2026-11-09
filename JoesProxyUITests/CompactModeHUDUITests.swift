import XCTest

/// Compact Mode HUD smoke: `--compact-mode` must not construct Full Inspector (`ContentView`).
final class CompactModeHUDUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches with `--compact-mode` and asserts HUD chrome without Full Inspector `ContentView`.
    @MainActor
    func testCompactHUDLaunchesWithoutInspector() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--compact-mode",
            "--ui-test-proxy-port=19092"
        ]
        app.launchJoesProxyForTesting()

        let hud = app.identifiedElement("compactMonitorRoot")
        XCTAssertTrue(hud.waitForExistence(timeout: 8), "Compact HUD root should exist.")

        let proxyToggle = app.identifiedElement("proxyToggleButton")
        XCTAssertTrue(proxyToggle.waitForExistence(timeout: 2))
        XCTAssertTrue(proxyToggle.isHittable)

        XCTAssertTrue(app.identifiedElement("compactApprovalsButton").waitForExistence(timeout: 2))
        XCTAssertFalse(
            app.identifiedElement("sessionTable").exists,
            "Compact Mode must not construct Full Inspector ContentView."
        )
    }
}
