import XCTest

final class LocalOverridesMenuUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testViewMenuOpensLocalOverrides() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-demo"]
        app.launchJoesProxyForTesting()

        let viewMenu = app.menuBars.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()

        let localOverridesItem = app.menuItems["Traffic Modifications…"].firstMatch
        XCTAssertTrue(localOverridesItem.waitForExistence(timeout: 2))
        localOverridesItem.click()

        let localOverridesSheet = app.descendants(matching: .any)["localOverridesSheet"]
        XCTAssertTrue(localOverridesSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows["Traffic Modifications"].waitForExistence(timeout: 2))
        let newPackButton = app.buttons["New OpenAPI Mock"].firstMatch
        XCTAssertTrue(newPackButton.waitForExistence(timeout: 2))
        XCTAssertEqual(newPackButton.identifier, "newOpenAPIMockPackButton")
    }

    @MainActor
    func testViewMenuNewOpenAPIMockOpensSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-demo"]
        app.launchJoesProxyForTesting()

        let viewMenu = app.menuBars.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()
        let newPackItem = app.menuItems["New OpenAPI Mock…"].firstMatch
        XCTAssertTrue(newPackItem.waitForExistence(timeout: 2))
        newPackItem.click()

        let sheet = app.descendants(matching: .any)["openAPIMockPackSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["New OpenAPI Mock"].waitForExistence(timeout: 2))
        let activateButton = app.buttons["Activate OpenAPI mock pack"].firstMatch
        XCTAssertTrue(activateButton.waitForExistence(timeout: 2))
        XCTAssertEqual(activateButton.identifier, "activateOpenAPIMockPackButton")
    }
}
