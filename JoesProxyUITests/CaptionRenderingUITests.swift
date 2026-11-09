import XCTest

/// Requires separately scoped native-player visual acceptance through the serial host wrapper.
final class CaptionRenderingUITests: XCTestCase {
    @MainActor
    func testNativeCaptionRenderingMatrixAndCleanup() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JOESPROXY_CAPTION_PLAYER_ACCEPTANCE"] == "1",
                          "Native rendering review requires the explicit player acceptance opt-in.")
        continueAfterFailure = false
        executionTimeAllowance = 180
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=caption-player", "--ui-test-primary-screen"]
        app.launchEnvironment["JOESPROXY_CAPTION_PLAYER_ACCEPTANCE"] = "1"
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let status = app.staticTexts["captionPlayerStatus"]
        waitFor("Ready: 7 tracks; no visual acceptance recorded", in: status)
        let window = app.windows.containing(.button, identifier: "captionPlayerStop").firstMatch
        XCTAssertTrue(window.exists)
        for id in ["en", "es", "fr", "en-sdh", "en-forced", "ar", "ja", "off"] {
            let selection = app.buttons["captionSelect-\(id)"]
            XCTAssertTrue(selection.isHittable)
            selection.click()
            waitFor("Ready for visual review: \(id)", in: status)
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "native-caption-\(id)-requires-visual-review"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.buttons["captionPlayerStop"].click()
        waitFor("Stopped: player released; fixture listener stopped", in: status)
        XCTAssertFalse(app.buttons["captionSelect-en"].isEnabled)
        let receipt = XCTAttachment(string: "Eight native-player images require visual inspection. Decoder/selection readiness passed; no automatic-selection, VoiceOver, or target-device claim. Explicit Stop completed before termination.")
        receipt.name = "native-caption-cleanup-and-review-boundary"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    @MainActor
    private func waitFor(_ text: String, in element: XCUIElement) {
        let ready = NSPredicate { _, _ in
            element.exists && (element.label + (element.value as? String ?? "")).contains(text)
        }
        XCTAssertTrue(ready.evaluate(with: element) || XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: ready, object: element)], timeout: 25) == .completed,
            "Expected \(text); actual \(element.exists ? element.label : "missing status")")
    }
}
