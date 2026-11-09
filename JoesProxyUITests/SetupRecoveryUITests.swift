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
        XCTAssertTrue(app.staticTexts["Setup Checklist"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.buttons["Done"].waitForExistence(timeout: 2),
            "Guided Setup sheet must remain dismissible after resizable configuration"
        )
    }

    @MainActor
    func testGuidedSetupDeepLinkOpensExploreTrafficSection() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "\(Self.uiTestFixturePrefix)demo-sessions",
            "\(Self.uiTestGuidedSetupSectionPrefix)exploreTraffic",
            "\(Self.uiTestGuidedSetupModePrefix)replay"
        ]
        app.launchJoesProxyForTesting()

        let guidedSetup = identifiedElement("guidedSetupRepairView", in: app)
        XCTAssertTrue(guidedSetup.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Explore Traffic"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testRepairGuidedSetupNeedsCleanupBlockingState() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "\(Self.uiTestFixturePrefix)demo-sessions",
            "\(Self.uiTestGuidedSetupSectionPrefix)httpsAndTrust",
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
            "\(Self.uiTestGuidedSetupSectionPrefix)httpsAndTrust",
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
            "\(Self.uiTestGuidedSetupSectionPrefix)httpsAndTrust",
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
