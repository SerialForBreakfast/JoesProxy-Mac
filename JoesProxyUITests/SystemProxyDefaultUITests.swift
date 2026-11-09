import XCTest

final class SystemProxyDefaultUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStartingProxyDoesNotRouteMacWithoutExplicitConsent() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-fixture=demo-sessions",
            "--ui-test-browser-mode=table",
            "--ui-test-proxy-port=19093"
        ]
        app.launchJoesProxyForTesting()

        let routingOff = identifiedElement("systemProxyOffIndicator", in: app)
        XCTAssertTrue(routingOff.waitForExistence(timeout: 5))

        let proxyToggle = identifiedElement("proxyToggleButton", in: app)
        XCTAssertTrue(proxyToggle.waitForExistence(timeout: 2))
        proxyToggle.click()

        let running = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Stop proxy"),
            object: proxyToggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [running], timeout: 5), .completed)
        XCTAssertTrue(routingOff.exists)

        routingOff.click()
        XCTAssertTrue(
            app.staticTexts["Off. Mac and Simulator traffic is not routed through JoesProxy."]
                .waitForExistence(timeout: 2)
        )

        let routingToggle = identifiedElement("systemProxyPopoverToggle", in: app)
        XCTAssertTrue(routingToggle.waitForExistence(timeout: 2))
        routingToggle.click()

        XCTAssertTrue(app.staticTexts["Route system proxy through JoesProxy?"].waitForExistence(timeout: 2))
        let consentSheet = app.sheets.firstMatch
        XCTAssertTrue(consentSheet.buttons["Enable"].waitForExistence(timeout: 2))
        XCTAssertTrue(consentSheet.buttons["Cancel"].exists)
        consentSheet.buttons["Cancel"].click()

        XCTAssertTrue(routingOff.exists)
        proxyToggle.click()
    }

    private func identifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
