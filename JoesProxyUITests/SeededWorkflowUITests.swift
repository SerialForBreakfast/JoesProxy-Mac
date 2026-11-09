import XCTest

final class SeededWorkflowUITests: XCTestCase {
    private static let uiTestFixturePrefix = "--ui-test-fixture="
    private static let uiTestBrowserModePrefix = "--ui-test-browser-mode="
    private static let uiTestTextSizePrefix = "--ui-test-text-size="
    private static let uiTestProxyPortPrefix = "--ui-test-proxy-port="

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testClearAllCancellationPreservesCount() throws {
        let app = launchDemoApp()
        defer { app.terminate() }
        let menu = identifiedElement("clearSessionsMenu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        app.menuItems["Clear All"].click()
        let confirmation = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Clear ' AND label ENDSWITH ' Sessions'"
        )).firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        let originalLabel = confirmation.label
        app.windows.buttons["Cancel"].click()
        XCTAssertTrue(waitForNonExistence(confirmation, timeout: 3))
        menu.click()
        app.menuItems["Clear All"].click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertEqual(confirmation.label, originalLabel)
        app.windows.buttons["Cancel"].click()
    }

    @MainActor
    func testSeededTableWorkflows() throws {
        let app = launchDemoApp()

        let sessionTable = identifiedElement("sessionTable", in: app)
        XCTAssertTrue(sessionTable.waitForExistence(timeout: 5))
        XCTAssertTrue(sessionTable.staticTexts["api.github.com"].waitForExistence(timeout: 2))
        XCTAssertTrue(sessionTable.staticTexts["httpbin.org"].waitForExistence(timeout: 2))

        let searchField = app.textFields["sessionSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        replaceText(in: searchField, with: "github")

        XCTAssertTrue(sessionTable.staticTexts["api.github.com"].waitForExistence(timeout: 2))
        XCTAssertFalse(sessionTable.staticTexts["httpbin.org"].exists)

        let domainField = app.textFields["domainFilterField"]
        app.buttons["sessionFilterPopoverButton"].click()
        XCTAssertTrue(domainField.waitForExistence(timeout: 2))
        replaceText(in: domainField, with: "does-not-match")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        let noMatchesAfterClearSelected = app.staticTexts["No Matching Sessions"]
        XCTAssertTrue(noMatchesAfterClearSelected.waitForExistence(timeout: 2))

        let clearFiltersAfterClearSelected = app.buttons["Clear Filters"]
        XCTAssertTrue(clearFiltersAfterClearSelected.waitForExistence(timeout: 2))
        clearFiltersAfterClearSelected.click()

        XCTAssertTrue(sessionTable.waitForExistence(timeout: 2))
        XCTAssertTrue(sessionTable.staticTexts["api.github.com"].waitForExistence(timeout: 2))
        XCTAssertTrue(sessionTable.staticTexts["httpbin.org"].waitForExistence(timeout: 2))

        replaceText(in: searchField, with: "github")

        let githubCell = sessionTable.staticTexts["api.github.com"]
        XCTAssertTrue(githubCell.waitForExistence(timeout: 2))
        // Verify selection through Clear Selected's enabled state and exact removal below;
        // AppKit's outline-row flag and shortened AX summary can disagree with SwiftUI selection.
        githubCell.click()
        // In a focused workspace, inspection replaces the browser until Back is selected.
        let back = app.buttons["focusedBackButton"]
        if back.exists { back.click() }

        let clearMenu = identifiedElement("clearSessionsMenu", in: app)
        XCTAssertTrue(clearMenu.waitForExistence(timeout: 2))
        clearMenu.click()

        let clearSelected = app.menuItems["Clear Selected"]
        XCTAssertTrue(clearSelected.waitForExistence(timeout: 2))
        let selectionReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: clearSelected
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selectionReady], timeout: 3), .completed)
        clearSelected.click()

        XCTAssertTrue(waitForNonExistence(sessionTable.staticTexts["api.github.com"], timeout: 5))
        replaceText(in: searchField, with: "")

        XCTAssertTrue(sessionTable.waitForExistence(timeout: 2))
        XCTAssertFalse(sessionTable.staticTexts["api.github.com"].exists)
        XCTAssertTrue(sessionTable.staticTexts["httpbin.org"].waitForExistence(timeout: 2))

        clearMenu.click()

        let clearAll = app.menuItems["Clear All"]
        XCTAssertTrue(clearAll.waitForExistence(timeout: 2))
        clearAll.click()
        let confirmClear = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Clear ' AND label ENDSWITH ' Sessions'")).firstMatch
        XCTAssertTrue(confirmClear.waitForExistence(timeout: 3))
        confirmClear.click()

        XCTAssertTrue(waitForNonExistence(sessionTable.staticTexts["httpbin.org"], timeout: 5))
        XCTAssertTrue(waitForNonExistence(sessionTable.staticTexts["example.com"], timeout: 5))
    }

    @MainActor
    func testExplorerGroupingAndAccessibilitySizedControls() throws {
        let app = launchDemoApp(browserMode: "table", textSize: "accessibility")

        XCTAssertTrue(identifiedElement("sessionTable", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["sessionSearchField"].waitForExistence(timeout: 2))
        app.buttons["sessionFilterPopoverButton"].click()
        XCTAssertTrue(app.textFields["domainFilterField"].waitForExistence(timeout: 2))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(identifiedElement("sessionSortMenu", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(identifiedElement("clearSessionsMenu", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(identifiedElement("exportSessionsMenu", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(identifiedElement("proxyToggleButton", in: app).waitForExistence(timeout: 2))

        app.selectSessionBrowser("Explorer")

        let explorerView = identifiedElement("sessionExplorerView", in: app)
        XCTAssertTrue(explorerView.waitForExistence(timeout: 2))

        let groupingMenu = identifiedElement("explorerGroupingMenu", in: app)
        XCTAssertTrue(groupingMenu.waitForExistence(timeout: 2))
        XCTAssertTrue(identifiedElement("explorerHostGroupingMenu", in: app).waitForExistence(timeout: 2))

        groupingMenu.click()
        let byEndpoint = app.menuItems["By Endpoint"]
        XCTAssertTrue(byEndpoint.waitForExistence(timeout: 2))
        byEndpoint.click()

        XCTAssertFalse(identifiedElement("explorerHostGroupingMenu", in: app).exists)

        groupingMenu.click()
        let byHost = app.menuItems["By Host"]
        XCTAssertTrue(byHost.waitForExistence(timeout: 2))
        byHost.click()

        XCTAssertTrue(identifiedElement("explorerHostGroupingMenu", in: app).waitForExistence(timeout: 2))
    }

    @MainActor
    func testNetworkThrottlingToolbarControlsAreReachable() throws {
        let app = launchDemoApp()

        XCTAssertTrue(identifiedElement("sessionTable", in: app).waitForExistence(timeout: 5))

        // Modify belongs to the inspector. Enter it explicitly on focused layouts.
        let inspect = app.buttons["focusedInspectButton"]
        if inspect.exists { inspect.click() }
        let modifyMenu = identifiedElement("modifyHubMenu", in: app)
        XCTAssertTrue(modifyMenu.waitForExistence(timeout: 2))
        modifyMenu.click()

        let throttleToggle = identifiedElement("networkThrottlingToggle", in: app)
        XCTAssertTrue(throttleToggle.waitForExistence(timeout: 2))

        let throttlePresetMenu = identifiedElement("networkThrottlingPresetMenu", in: app)
        XCTAssertTrue(throttlePresetMenu.waitForExistence(timeout: 2))
        throttlePresetMenu.click()

        XCTAssertTrue(app.menuItems["Mobile 3G"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["56k Modem"].waitForExistence(timeout: 2))
    }

    @MainActor
    private func launchDemoApp(browserMode: String = "table", textSize: String = "standard") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "\(Self.uiTestFixturePrefix)demo-sessions",
            "\(Self.uiTestBrowserModePrefix)\(browserMode)",
            "\(Self.uiTestTextSizePrefix)\(textSize)",
            "\(Self.uiTestProxyPortPrefix)19090"
        ]
        app.launchJoesProxyForTesting()
        return app
    }

    private func identifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func sessionBrowserButton(titled title: String, in container: XCUIElement) -> XCUIElement {
        container.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    private func replaceText(in element: XCUIElement, with text: String) {
        element.click()
        element.typeKey("a", modifierFlags: [.command])
        element.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        element.typeText(text)
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return !element.exists
    }
}
