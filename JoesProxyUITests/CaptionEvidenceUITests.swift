import XCTest

final class CaptionEvidenceUITests: XCTestCase {
    @MainActor
    func testCaptionEvidenceStandard() { exercise(textSize: "standard") }

    @MainActor
    func testCaptionEvidenceAccessibility() { exercise(textSize: "accessibility") }

    @MainActor
    private func exercise(textSize: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=caption-evidence", "--ui-test-text-size=\(textSize)",
                               "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let disclosure = app.buttons["effectBundleEvidenceToggle"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
        disclosure.click()
        let refresh = app.buttons["effectBundleRefreshEvidence"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 3))
        refresh.click()
        XCTAssertTrue(app.staticTexts["Caption segment · Delivery pending"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Caption segment · Delivery failed"].exists)
        XCTAssertTrue(app.staticTexts["Transformation skipped (capacityLimited); the unchanged upstream response was delivered. Target outcome is unconfirmed."].exists)
        let observe = app.buttons["effectBundleObserveNextRequest"]
        observe.click()
        XCTAssertTrue(app.staticTexts["This bundle is not serving. Existing receipt history remains available."].exists)
        let window = app.windows.containing(.button, identifier: "effectBundleRefreshEvidence").firstMatch
        let next = app.buttons["effectBundleNextEvidencePage"]
        window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -10_000)
        XCTAssertTrue(next.isHittable)
        next.click()
        window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 10_000)
        let details = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                                                       "effectBundleObservation-", "-details")).firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 3))
        details.click()
        let technical = app.identifiedElement(details.identifier.replacingOccurrences(of: "-details", with: "-technicalText"))
        XCTAssertTrue(technical.waitForExistence(timeout: 3))
        let text = technical.label + (technical.value as? String ?? "")
        XCTAssertTrue(text.contains("Segment: 32"))
        XCTAssertTrue(text.contains("Text source revision: synthetic-text-v1"))
        XCTAssertTrue(text.contains("downstreamWriteSucceeded"))
        XCTAssertFalse(text.contains("SHA256"))
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "caption-evidence-\(textSize)-page-two"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse(next.exists)
    }
}
