import XCTest

@MainActor
final class ArtifactSourceReviewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws { app?.terminate(); app = nil }

    private func launch(textSize: String = "standard", compact: Bool = false, pair: Bool = false) -> XCUIElement {
        app.launchArguments = ["--ui-test-fixture=demo-sessions", "--ui-test-mcp-status=approvals",
            "--ui-artifact-review", "--ui-test-text-size=\(textSize)"]
        if compact { app.launchArguments.append("--compact-mode") }
        if pair { app.launchArguments.append("--ui-artifact-pair") }
        app.launchJoesProxyForTesting()
        if compact { XCTAssertTrue(app.identifiedElement("compactMonitorRoot").waitForExistence(timeout: 5)) }
        else { XCTAssertTrue(app.buttons["mcpStatusPill"].waitForExistence(timeout: 5)) }
        app.menuBars.menuBarItems["MCP"].click()
        app.menuBars.menuItems["Pending Approvals…"].click()
        let window = app.windows["mcp-approvals"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        return window
    }

    func testOrderedPairReviewCanDenyAndCompareOnce() throws {
        for action in ["artifactPairDeny", "artifactPairApprove"] {
            let window = launch(pair: true)
            let baseline = window.staticTexts["artifactPairBaseline"]
            XCTAssertTrue(baseline.waitForExistence(timeout: 5))
            XCTAssertTrue(baseline.label.contains("record 0") || String(describing: baseline.value).contains("record 0"))
            let candidate = window.staticTexts["artifactPairCandidate"]
            XCTAssertTrue(candidate.label.contains("record 1") || String(describing: candidate.value).contains("record 1"))
            let pointer = window.staticTexts["artifactPairPointer"]
            XCTAssertTrue(pointer.label.contains("/items") || String(describing: pointer.value).contains("/items"))
            XCTAssertFalse(window.buttons["mcpApproveButton"].exists)
            window.buttons[action].click()
            XCTAssertTrue(baseline.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    func testExplicitShareAndRevokeReviewedSyntheticBytes() throws {
        let window = launch()
        XCTAssertTrue(window.staticTexts["artifactSourceBriefConsent"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["artifactSourceSearchConsent"].waitForExistence(timeout: 5))
        let share = window.buttons["artifactSourceShare"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertFalse(share.isEnabled)
        window.buttons["artifactSourceSelect"].click()
        XCTAssertTrue(window.staticTexts["artifactSourcePreview"].waitForExistence(timeout: 5))
        XCTAssertTrue(share.isEnabled)
        XCTAssertFalse(window.buttons["artifactSourceRevoke"].exists)
        share.click()
        let revoke = window.buttons["artifactSourceRevoke"]
        XCTAssertTrue(revoke.waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["artifactSourceRevokeAll"].exists)
        revoke.click()
        XCTAssertTrue(revoke.waitForNonExistence(timeout: 5))
        XCTAssertFalse(window.buttons["artifactSourceRevokeAll"].exists)
    }

    func testCancelDoesNotCreateShareAndLargeTextControlsRemainReachable() throws {
        let window = launch(textSize: "accessibility")
        let select = window.buttons["artifactSourceSelect"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.click()
        XCTAssertTrue(window.staticTexts["artifactSourcePreview"].waitForExistence(timeout: 5))
        let cancel = window.buttons["artifactSourceCancel"]
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(window.frame.contains(cancel.frame))
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertFalse(window.buttons["artifactSourceRevoke"].exists)
    }

    func testKeyboardEscapeCancelsWithoutImplicitShare() throws {
        let window = launch()
        let select = window.buttons["artifactSourceSelect"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.click()
        XCTAssertTrue(window.staticTexts["artifactSourcePreview"].waitForExistence(timeout: 5))
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(window.buttons["artifactSourceShare"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(window.buttons["artifactSourceRevoke"].exists)
    }

    func testCompactReviewKeepsHUDAndDismissalDiscardsUnsharedCopy() throws {
        let window = launch(compact: true)
        window.buttons["artifactSourceSelect"].click()
        XCTAssertTrue(window.staticTexts["artifactSourcePreview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)
        window.buttons["mcpCompactApprovalsDone"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        app.menuBars.menuBarItems["MCP"].click()
        app.menuBars.menuItems["Pending Approvals…"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertFalse(window.buttons["artifactSourceShare"].exists)
        XCTAssertFalse(window.buttons["artifactSourceRevoke"].exists)
    }
}
