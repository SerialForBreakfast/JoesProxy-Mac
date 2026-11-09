import XCTest

final class EffectBundleEvidenceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    @MainActor
    func testEvidencePagingWithAccessibilityText() throws {
        try checkPaging(textSize: "accessibility")
    }

    @MainActor
    func testEvidencePagingWithStandardText() throws {
        try checkPaging(textSize: "standard")
    }

    @MainActor
    private func checkPaging(textSize: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=authored-evidence", "--ui-test-text-size=\(textSize)",
            "--ui-test-suppress-launch-recovery", "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let disclosure = app.buttons["effectBundleEvidenceToggle"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
        disclosure.click()
        let refresh = app.buttons["effectBundleRefreshEvidence"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 3))
        XCTAssertTrue(refresh.isHittable)
        refresh.click()
        XCTAssertTrue(app.staticTexts["Asset: fixture-0"].waitForExistence(timeout: 3))
        let next = app.buttons["effectBundleNextEvidencePage"]
        XCTAssertTrue(next.isHittable)
        next.click()
        let receipt = app.staticTexts["Asset: fixture-32"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 3))
        let inspect = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "-checkAsset")).firstMatch
        XCTAssertTrue(inspect.exists)
        XCTAssertFalse(inspect.isEnabled, "The fixture has no retained resource; asset checks must explain unavailability.")
        let details = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "effectBundleReceipt-", "-details")).firstMatch
        XCTAssertTrue(details.exists)
        details.click()
        let technical = app.identifiedElement(details.identifier.replacingOccurrences(of: "-details", with: "-technicalText"))
        XCTAssertTrue(technical.waitForExistence(timeout: 3))
        let technicalText = (technical.value as? String ?? "") + technical.label
        XCTAssertTrue(technicalText.contains("assetReadFailed"))
        XCTAssertTrue(technicalText.contains("not served"))
        XCTAssertTrue(technicalText.contains("notApplied"))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3))
        let evidenceWindow = app.windows.containing(.button, identifier: "effectBundleRefreshEvidence").firstMatch
        XCTAssertTrue(evidenceWindow.waitForExistence(timeout: 3))
        for _ in 0..<8 {
            if technical.isHittable { break }
            evidenceWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -150)
        }
        XCTAssertTrue(technical.isHittable)
        let screenshot = XCTAttachment(screenshot: evidenceWindow.screenshot())
        screenshot.name = "authored-evidence-\(textSize)-page-two"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse(next.exists)
        refresh.click()
        XCTAssertTrue(next.waitForExistence(timeout: 3))
    }
}
