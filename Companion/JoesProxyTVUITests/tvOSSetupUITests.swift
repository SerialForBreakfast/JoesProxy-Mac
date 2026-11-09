import XCTest

final class TVOSSetupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFirstLaunchShowsWelcomeAndSetupControls() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.otherElements["tvOSSetupRootView"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Make proxy setup less painful."].exists)
        XCTAssertTrue(app.buttons["Start Setup"].exists)
        XCTAssertTrue(app.buttons["Troubleshooting"].exists)
    }

    func testSetupNavigationShowsManualHostEntry() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Start Setup"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(app.textFields["tvOSManualMacHostField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Check Connection"].exists)
    }
}
