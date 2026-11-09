import XCTest

final class CaptionProfileUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCaptionProfileStandard() { checkProfile(textSize: "standard") }

    @MainActor
    func testCaptionProfileAccessibility() { checkProfile(textSize: "accessibility") }

    @MainActor
    private func checkProfile(textSize: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--compact-mode", "--ui-test-browser-mode=table", "--ui-test-text-size=\(textSize)",
                               "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        XCTAssertTrue(app.identifiedElement("compactMonitorRoot").waitForExistence(timeout: 10))
        app.buttons["compactManageModifications"].click()
        let management = app.windows["Traffic Modifications"]
        XCTAssertTrue(management.waitForExistence(timeout: 5))
        XCTAssertTrue(management.staticTexts["No Saved Modifications"].waitForExistence(timeout: 5),
                      "Caption fixture must not inherit saved user modifications")
        management.buttons["newHLSTestStreamButton"].click()
        let picker = app.identifiedElement("hlsTestStreamProfilePicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        let captions = app.menuItems["Multilingual Captions"]
        XCTAssertTrue(captions.waitForExistence(timeout: 3))
        captions.click()
        let mode = app.identifiedElement("hlsTextTrackMode")
        let languages = app.identifiedElement("hlsTextTrackLanguages")
        XCTAssertTrue(mode.waitForExistence(timeout: 3))
        XCTAssertTrue(languages.exists)
        XCTAssertTrue((mode.label + (mode.value as? String ?? "")).contains("7 diagnostic text tracks"))
        let languageText = languages.label + (languages.value as? String ?? "")
        for language in ["English", "Español", "Français", "العربية", "日本語"] {
            XCTAssertTrue(languageText.contains(language), "Missing accessible track: \(language)")
        }
        let window = app.windows.containing(.textField, identifier: "hlsTestStreamHostField").firstMatch
        XCTAssertTrue(window.exists)
        XCTAssertGreaterThan(window.frame.width, 600)
        let metadataScreenshot = XCTAttachment(screenshot: window.screenshot())
        metadataScreenshot.name = "caption-profile-metadata-\(textSize)"
        metadataScreenshot.lifetime = .keepAlways
        add(metadataScreenshot)
        let host = app.textFields["hlsTestStreamHostField"]
        let path = app.textFields["hlsTestStreamPlaylistPathField"]
        let configurationScroll = app.identifiedElement("hlsTestStreamConfigurationScroll")
        for _ in 0..<4 where !host.isHittable || !path.isHittable {
            configurationScroll.scroll(byDeltaX: 0, deltaY: -160)
        }
        XCTAssertTrue(host.isHittable)
        XCTAssertTrue(path.isHittable)
        host.click()
        host.typeText("media.example.test")
        path.click()
        path.typeText("/master.m3u8")
        let start = app.buttons["startHLSTestStreamButton"]
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(start.isHittable)
        // Exercise keyboard editing without starting any substitution or capture.
        path.typeKey("a", modifierFlags: .command)
        path.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertFalse(start.isEnabled)
        path.typeText("/master.m3u8")
        let replace = app.checkBoxes["Replace overlapping local overrides"]
        if textSize == "accessibility" {
            let previousMetadataY = mode.frame.minY
            configurationScroll.scroll(byDeltaX: 0, deltaY: -240)
            XCTAssertLessThan(mode.frame.minY, previousMetadataY,
                              "Large-text configuration must actually scroll, not merely expose AX elements")
        }
        for _ in 0..<4 where !replace.isHittable {
            configurationScroll.scroll(byDeltaX: 0, deltaY: -160)
        }
        XCTAssertTrue(replace.isHittable, "The lower configuration options must remain reachable")
        XCTAssertLessThan(replace.frame.maxY, start.frame.minY,
                          "The lower option must be visibly above the pinned footer")
        XCTAssertTrue(start.isHittable, "Start must remain pinned while configuration scrolls")
        app.activate()
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "caption-profile-\(textSize)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Cancel through keyboard; this test never authorizes a live effect.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(picker.waitForNonExistence(timeout: 3), "Escape must dismiss the configuration sheet")
        XCTAssertTrue(management.waitForExistence(timeout: 3))
        XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)
    }
}
