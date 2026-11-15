// These tests run on the host macOS environment without simulator isolation — spurious
// failures can occur due to system notifications, focus loss, or background CPU pressure.
// Re-run on a quiet machine before treating a failure as a code regression.
// See JoesProxyUITests.swift for the full explanation.
import XCTest

final class SetupRecoveryUITests: XCTestCase {
    private static let uiTestFixturePrefix = "--ui-test-fixture="
    private static let uiTestCertificateStatePrefix = "--ui-test-certificate-state="
    private static let uiTestGuidedSetupSectionPrefix = "--ui-test-guided-setup-section="
    private static let uiTestGuidedSetupModePrefix = "--ui-test-guided-setup-mode="
    private static let uiTestGuidedSetupBlockingStatePrefix = "--ui-test-guided-setup-blocking-state="

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGuidedSetupReopensFromHelpKeyboardShortcut() throws {
        let app = XCUIApplication()
        app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions"]
        app.launchJoesProxyForTesting()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        app.typeKey("g", modifierFlags: [.command, .shift])

        let guidedSetup = identifiedElement("guidedSetupRepairView", in: app)
        XCTAssertTrue(guidedSetup.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Guided Setup & Repair"].waitForExistence(timeout: 2))
        XCTAssertTrue(identifiedElement("certificateApprovalChecklist", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.buttons["guidedSetupClose"].waitForExistence(timeout: 2),
            "Guided Setup sheet must remain dismissible after resizable configuration"
        )
    }

    @MainActor
    func testInstalledCertificateStillNeedsSeparateMacOSTrustApproval() {
        let app = XCUIApplication()
        app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions",
                               "\(Self.uiTestCertificateStatePrefix)installedTrustRequired",
                               "\(Self.uiTestGuidedSetupSectionPrefix)certificate",
                               "\(Self.uiTestGuidedSetupModePrefix)replay"]
        app.launchJoesProxyForTesting()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.buttons["Trust Root CA"].waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.buttons["openKeychainAccess"].exists)
        XCTAssertTrue(sheet.buttons["Check Again"].exists)
        XCTAssertFalse(sheet.buttons["Create Root CA"].exists)
        XCTAssertFalse(sheet.buttons["Unlock Certificate Authority"].exists)
    }

    @MainActor
    func testCompactSetupKeepsCloseReachableOnEveryPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions", "--ui-test-compact-setup-sheet",
                               "\(Self.uiTestGuidedSetupSectionPrefix)certificate", "\(Self.uiTestGuidedSetupModePrefix)replay"]
        app.launchJoesProxyForTesting()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let close = sheet.buttons["Close"]
        for title in ["Certificate", "Proxy", "Verify Capture", "Devices", "MCP/CLI"] {
            if title != "Certificate" {
                let menu = sheet.popUpButtons["guidedSetupSectionPicker"]
                if menu.exists {
                    menu.click()
                    app.menuItems[title].click()
                } else {
                    sheet.radioButtons[title].click()
                }
            }
            let heading = title == "Devices" || title == "MCP/CLI" ? "\(title) (optional)" : title
            XCTAssertTrue(sheet.staticTexts[heading].waitForExistence(timeout: 2))
            XCTAssertLessThanOrEqual(sheet.frame.width, 430)
            XCTAssertLessThanOrEqual(sheet.frame.height, 355)
            XCTAssertTrue(sheet.frame.contains(close.frame), title)
            XCTAssertTrue(close.isHittable, title)
        }
        close.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testGuidedSetupDeepLinkOpensVerifyCaptureSection() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "\(Self.uiTestFixturePrefix)demo-sessions",
            "\(Self.uiTestGuidedSetupSectionPrefix)verifyCapture",
            "\(Self.uiTestGuidedSetupModePrefix)replay"
        ]
        app.launchJoesProxyForTesting()

        let guidedSetup = identifiedElement("guidedSetupRepairView", in: app)
        XCTAssertTrue(guidedSetup.waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement("setupChecklistVerificationRow", in: app).waitForExistence(timeout: 2))
    }

    @MainActor
    func testRepairGuidedSetupNeedsCleanupBlockingState() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "\(Self.uiTestFixturePrefix)demo-sessions",
            "\(Self.uiTestGuidedSetupSectionPrefix)certificate",
            "\(Self.uiTestGuidedSetupModePrefix)repair",
            "\(Self.uiTestGuidedSetupBlockingStatePrefix)needsCleanup"
        ]
        app.launchJoesProxyForTesting()

        let guidedSetup = identifiedElement("guidedSetupRepairView", in: app)
        XCTAssertTrue(guidedSetup.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Repair HTTPS Setup"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts["The certificate state needs cleanup before HTTPS inspection can continue"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["Reset Certificate State…"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testRepairGuidedSetupLaunchesDirectlyIntoInjectedBlockingState() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "\(Self.uiTestFixturePrefix)demo-sessions",
            "\(Self.uiTestGuidedSetupSectionPrefix)certificate",
            "\(Self.uiTestGuidedSetupModePrefix)repair",
            "\(Self.uiTestGuidedSetupBlockingStatePrefix)installedTrustRequired"
        ]
        app.launchJoesProxyForTesting()

        let guidedSetup = identifiedElement("guidedSetupRepairView", in: app)
        XCTAssertTrue(guidedSetup.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Repair HTTPS Setup"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["The certificate is installed, but trust is still required"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Retry Status Check"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["iOS Setup Guide"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testRepairGuidedSetupCertificateHelpLinkOpensFocusedHelpHub() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "\(Self.uiTestFixturePrefix)demo-sessions",
            "\(Self.uiTestGuidedSetupSectionPrefix)certificate",
            "\(Self.uiTestGuidedSetupModePrefix)repair",
            "\(Self.uiTestGuidedSetupBlockingStatePrefix)installedTrustRequired"
        ]
        app.launchJoesProxyForTesting()

        let guidedSetup = identifiedElement("guidedSetupRepairView", in: app)
        XCTAssertTrue(guidedSetup.waitForExistence(timeout: 5))

        let helpButton = identifiedElement("guidedSetupRepairTrustHelpButton", in: app)
        XCTAssertTrue(helpButton.waitForExistence(timeout: 2))
        helpButton.click()

        let helpHub = identifiedElement("helpHubView", in: app)
        XCTAssertTrue(helpHub.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recommended For This Step"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Certificate And HTTPS Setup"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testFirstRunPathChoiceThenStartFirstCaptureShowsInspectorCompanion() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "\(Self.uiTestFixturePrefix)demo-sessions",
            "\(Self.uiTestGuidedSetupModePrefix)first-run"
        ]
        app.launchJoesProxyForTesting()

        let pathChoice = identifiedElement("firstRunPathChoiceView", in: app)
        XCTAssertTrue(pathChoice.waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement("startFirstCaptureButton", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(identifiedElement("connectAnAgentButton", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(identifiedElement("openInspectorButton", in: app).waitForExistence(timeout: 2))
        XCTAssertFalse(identifiedElement("guidedSetupRepairView", in: app).exists)

        identifiedElement("startFirstCaptureButton", in: app).click()

        XCTAssertTrue(app.textFields["sessionSearchField"].waitForExistence(timeout: 5))
        let setupSummary = app.buttons["workspaceSetupSummary"]
        let openedSetupSummary = setupSummary.exists
        if openedSetupSummary { setupSummary.click() }
        XCTAssertTrue(identifiedElement("inspectorSetupCompanion", in: app).waitForExistence(timeout: 5))
        if openedSetupSummary { app.sheets.buttons["Done"].firstMatch.click() }
        XCTAssertFalse(identifiedElement("guidedSetupRepairView", in: app).exists)
        XCTAssertTrue(identifiedElement("firstRunSetupChip", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(identifiedElement("proxyToggleButton", in: app).exists)
    }

    @MainActor
    func testInjectedNeedsCleanupCertificateStateShowsRecoveryBanner() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "\(Self.uiTestFixturePrefix)demo-sessions",
            "\(Self.uiTestCertificateStatePrefix)needsCleanup"
        ]
        app.launchJoesProxyForTesting()

        let details = app.buttons["workspaceNoticeDetails"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.click()
        XCTAssertTrue(app.staticTexts["Certificate Cleanup Required"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open HTTPS Setup"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Reset Certificate State"].waitForExistence(timeout: 2))
    }

    private func identifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
