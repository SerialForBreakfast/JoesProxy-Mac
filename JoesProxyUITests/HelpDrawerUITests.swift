import XCTest

final class HelpDrawerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHelpToolbarButtonReflectsSuggestedTopic() throws {
        let app = launchApp()

        let helpToggle = app.buttons["mainHelpDrawerToggle"]
        XCTAssertTrue(helpToggle.waitForExistence(timeout: 5))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Captured Sessions"), object: helpToggle)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
    }

    @MainActor
    func testHelpMenuOpensHelpHub() throws {
        let app = launchApp()

        let helpMenu = app.menuBars.menuBarItems["Help"]
        XCTAssertTrue(helpMenu.waitForExistence(timeout: 5))

        helpMenu.click()

        let helpMenuItem = app.menuItems["Help Topics & Glossary"].firstMatch
        XCTAssertTrue(helpMenuItem.waitForExistence(timeout: 2))

        helpMenuItem.click()

        let helpHub = app.scrollViews["helpHubView"]
        XCTAssertTrue(helpHub.waitForExistence(timeout: 5))

        let searchField = app.textFields["helpHubSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))

        let doneButton = app.buttons["helpHubDoneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 2))
        XCTAssertTrue(doneButton.isHittable, "Help Hub Done must stay hittable after resizable configuration")
    }

    @MainActor
    func testSimulatorSetupGuideLaunchesFromUITestArgument() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-open-simulator-setup"]
        app.launchJoesProxyForTesting()

        let simulatorSetupGuide = app.staticTexts["Simulator Setup"]
        XCTAssertTrue(simulatorSetupGuide.waitForExistence(timeout: 5))

        let setupContent = app.scrollViews["simulatorSetupGuide"]
        XCTAssertTrue(setupContent.waitForExistence(timeout: 2))
    }

    @MainActor
    func testSharedCatalogRecipeSearchAndReading() throws {
        try exerciseSharedCatalog(textSize: "standard")
    }

    @MainActor
    func testSharedCatalogRecipeWithAccessibilityText() throws {
        try exerciseSharedCatalog(textSize: "accessibility")
    }

    @MainActor
    private func exerciseSharedCatalog(textSize: String) throws {
        let app = launchApp(textSize: textSize)
        let helpMenu = app.menuBars.menuBarItems["Help"]
        XCTAssertTrue(helpMenu.waitForExistence(timeout: 5))
        helpMenu.click()
        app.menuItems["Help Topics & Glossary"].firstMatch.click()
        let search = app.textFields["helpHubSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("Replace an image")
        let result = app.buttons["helpCatalogResult-workflow-image"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.click()
        XCTAssertTrue(app.popUpButtons["helpCatalogTopicPicker"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["helpCatalogReadTopic"].firstMatch.exists)
        XCTAssertTrue(app.buttons["helpHubDoneButton"].isHittable)
    }

    @MainActor
    private func launchApp(textSize: String = "standard") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--screenshot-demo")
        app.launchArguments.append("--screenshot-text-size=\(textSize)")
        app.launchJoesProxyForTesting()
        return app
    }
}
