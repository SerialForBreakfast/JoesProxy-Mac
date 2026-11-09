import XCTest

@MainActor
final class UploadStorageNoticeUITests: XCTestCase {
    func testMainShowsPersistentStorageRecovery() {
        verifyNotice(compact: false)
    }

    func testCompactShowsPersistentStorageRecovery() {
        verifyNotice(compact: true)
    }

    func testCompactExtraLargeNoticeRemainsReachable() {
        verifyNotice(compact: true, textSize: "extraLarge")
    }

    func testCompactAccessibilityNoticeSurvivesModeTransitions() {
        verifyNotice(compact: true, textSize: "accessibility", transitions: true)
    }

    func testCompactNoticeHonorsTextScale() {
        let standardHeight = verifyNotice(compact: true)
        let accessibilityHeight = verifyNotice(compact: true, textSize: "accessibility")
        XCTAssertGreaterThan(accessibilityHeight, standardHeight,
                             "The accessibility setting must enlarge recovery text, not just relaunch unchanged copy")
    }

    @discardableResult
    private func verifyNotice(compact: Bool, textSize: String = "standard", transitions: Bool = false) -> Double {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--ui-test-fixture=demo-sessions", "--ui-test-upload-storage-failure"]
        app.launchArguments.append("--ui-test-text-size=\(textSize)")
        if compact { app.launchArguments.append("--compact-mode") }
        app.launchJoesProxyForTesting()
        app.activate()
        let notice = app.staticTexts["uploadStorageRecoveryNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8))
        let accessibility = XCTAttachment(string: "label=\(notice.label)\nvalue=\(String(describing: notice.value))\nframe=\(notice.frame)")
        accessibility.name = compact ? "Compact warning accessibility" : "Main warning accessibility"
        accessibility.lifetime = .keepAlways
        add(accessibility)
        XCTAssertTrue(notice.isHittable, "Recovery information must be visible, not merely in the accessibility tree")
        // macOS static text exposes its spoken content as AXValue, not AXLabel.
        let warningText = notice.value as? String ?? ""
        XCTAssertTrue(warningText.contains("Upload storage needs attention"), "Actual static-text value: \(warningText)")
        XCTAssertTrue(warningText.contains("restart capture"))
        XCTAssertTrue(warningText.contains("Affected uploads fail explicitly"))
        if compact {
            XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)
            XCTAssertFalse(app.identifiedElement("sessionTable").exists)
            XCTAssertTrue(app.identifiedElement("compactManageModifications").isHittable)
        }
        if transitions {
            for _ in 0..<3 {
                app.typeKey("0", modifierFlags: .command)
                XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 10))
                XCTAssertTrue(notice.isHittable, "Recovery information must survive entry to the full workspace")
                app.typeKey("0", modifierFlags: .command)
                XCTAssertTrue(app.identifiedElement("compactMonitorRoot").waitForExistence(timeout: 10))
                XCTAssertTrue(notice.isHittable, "Recovery information must survive return to Compact")
                XCTAssertTrue(app.identifiedElement("compactManageModifications").isHittable)
            }
        }
        let window = app.windows.containing(.any, identifier: "uploadStorageRecoveryNotice").firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("The warning must belong to an identifiable app window before screenshot capture")
            return 0
        }
        XCTAssertGreaterThanOrEqual(notice.frame.minY, window.frame.minY)
        XCTAssertLessThanOrEqual(notice.frame.maxY, window.frame.maxY,
                                 "Recovery copy must fit inside the window")
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Upload recovery — \(compact ? "Compact" : "Main") — \(textSize)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return Double(notice.frame.height)
    }
}
