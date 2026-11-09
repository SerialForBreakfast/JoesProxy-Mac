import XCTest

final class MCPEPGRewriteFixtureUITests: XCTestCase {
    @MainActor
    func testEPGTitlesRenderThroughLiveRewriteAndRestoreAfterCleanup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=epg-rewrite-client"]
        app.launchJoesProxyForTesting()

        let firstTransformedTitle = app.staticTexts["epgFixture.transformedTitle.0"]
        let completed = firstTransformedTitle.waitForExistence(timeout: 30)
        if !completed {
            let error = app.staticTexts["epgFixture.error"]
            XCTFail(error.exists ? error.label : "EPG fixture did not complete")
            return
        }
        XCTAssertEqual(app.staticTexts["epgFixture.status"].value as? String, "Passed")
        XCTAssertEqual(app.staticTexts["epgFixture.transformedTitle.0"].value as? String, "Morning News!")
        XCTAssertEqual(app.staticTexts["epgFixture.transformedTitle.1"].value as? String, "World Report!")
        XCTAssertEqual(app.staticTexts["epgFixture.transformedTitle.2"].value as? String, "Live Match!")
        XCTAssertEqual(app.staticTexts["epgFixture.restoredTitle.0"].value as? String, "Morning News")
        XCTAssertEqual(app.staticTexts["epgFixture.restoredTitle.1"].value as? String, "World Report")
        XCTAssertEqual(app.staticTexts["epgFixture.restoredTitle.2"].value as? String, "Live Match")
        XCTAssertEqual(app.staticTexts["epgFixture.unrelatedResponse"].value as? String, "Unrelated response preserved")
        XCTAssertEqual(app.staticTexts["epgFixture.attribution"].value as? String, "Attribution recorded")
    }
}
