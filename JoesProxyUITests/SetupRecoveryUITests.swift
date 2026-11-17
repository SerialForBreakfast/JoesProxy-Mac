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
    func testSetupHidesSDKControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions", "--ui-test-primary-screen", "\(Self.uiTestGuidedSetupSectionPrefix)proxy",
                               "\(Self.uiTestGuidedSetupModePrefix)replay"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let sheet = app.sheets.firstMatch
        let advanced = sheet.disclosureTriangles["Advanced capture settings"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 28, dy: 0)).click()
        XCTAssertTrue(sheet.checkBoxes["Allow Map Remote rules to reach local Mac servers"].waitForExistence(timeout: 3))
        XCTAssertFalse(sheet.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'SDK'")).firstMatch.exists)
    }

    @MainActor
    func testAppleTVGuideHidesSDKControls() {
        let app = XCUIApplication()
        app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions", "--ui-test-primary-screen",
                               "\(Self.uiTestGuidedSetupSectionPrefix)devices", "\(Self.uiTestGuidedSetupModePrefix)replay"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let sheet = app.sheets.firstMatch
        sheet.radioButtons["Apple TV"].click()
        sheet.buttons["Apple TV Setup Guide"].click()
        XCTAssertTrue(app.staticTexts["Set Up JoesProxy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'SDK'")).firstMatch.exists)
    }

    @MainActor
    func testProxySettingsHideSDKControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "settingsTextSizePicker").firstMatch
        if !app.identifiedElement("settingsProxyPortField").exists {
            settings.descendants(matching: .any)["Proxy"].firstMatch.click()
        }
        XCTAssertTrue(app.identifiedElement("settingsProxyPortField").waitForExistence(timeout: 5))
        let pane = app.windows.containing(.any, identifier: "settingsProxyPortField").firstMatch
        XCTAssertFalse(pane.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'SDK' OR identifier BEGINSWITH 'settingsSDK'")).firstMatch.exists)
    }

    @MainActor
    func testSetupMenusOpenUnifiedCertificatePage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions"]
        app.launchJoesProxyForTesting()

        for title in ["JoesProxy", "Certificate", "Help"] {
            let menu = app.menuBars.menuBarItems[title]
            menu.click()
            menu.menuItems["Setup & Repair…"].click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.staticTexts["Set up HTTPS on this Mac"].waitForExistence(timeout: 5), title)
            sheet.buttons["guidedSetupClose"].click()
        }
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
        let sheet = app.sheets.firstMatch
        if let display = NSScreen.main?.visibleFrame, display.width >= 1024 {
            XCTAssertGreaterThanOrEqual(sheet.frame.width, 900)
        }
        XCTAssertTrue(sheet.frame.contains(sheet.buttons["guidedSetupClose"].frame))
        XCTAssertTrue(identifiedElement("certificateApprovalChecklist", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.buttons["guidedSetupClose"].waitForExistence(timeout: 2),
            "Guided Setup sheet must remain dismissible after resizable configuration"
        )
    }

    @MainActor
    func testInstalledCertificateStillNeedsSeparateMacOSTrustApproval() async throws {
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
        try await attachSetupExample(sheet, named: "Installed-awaiting-macOS-trust")
    }

    @MainActor
    func testNewIdentityShowsApprovalPrerequisites() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions",
                               "\(Self.uiTestCertificateStatePrefix)notSetUp",
                               "\(Self.uiTestGuidedSetupSectionPrefix)certificate",
                               "\(Self.uiTestGuidedSetupModePrefix)replay"]
        app.launchJoesProxyForTesting()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.buttons["Create Root CA"].waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.buttons["Create Root CA"].isEnabled)
        for title in ["Unlock Certificate Authority", "Install in Login Keychain", "Trust Root CA"] {
            XCTAssertTrue(sheet.buttons[title].exists, title)
            XCTAssertFalse(sheet.buttons[title].isEnabled, title)
        }
        try await attachSetupExample(sheet, named: "New-identity-approval-prerequisites")
    }

    @MainActor
    func testLockedIdentityShowsExplicitApprovalAndRetry() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions",
                               "\(Self.uiTestCertificateStatePrefix)keychainLocked",
                               "\(Self.uiTestGuidedSetupSectionPrefix)certificate",
                               "\(Self.uiTestGuidedSetupModePrefix)replay"]
        app.launchJoesProxyForTesting()
        let sheet = app.sheets.firstMatch
        let unlock = sheet.buttons["Unlock Certificate Authority"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        XCTAssertTrue(unlock.isEnabled)
        XCTAssertFalse(sheet.buttons["Create Root CA"].exists)
        unlock.click()
        XCTAssertTrue(sheet.staticTexts["Access was not granted. You can leave setup or choose Unlock Certificate Authority to retry."].waitForExistence(timeout: 5))
        XCTAssertTrue(unlock.isEnabled)
        try await attachSetupExample(sheet, named: "Protected-CA-awaiting-Keychain-approval")
    }

    @MainActor
    func testCertificateGuideIllustrations() async throws {
        let cases = [
            ("installedTrustRequired", ["Show where to find the certificate", "Show where to change trust"]),
            ("keychainLocked", ["Preview the macOS password prompt"])
        ]
        for (state, titles) in cases {
            let app = XCUIApplication()
            app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions", "--ui-test-primary-screen",
                                   "\(Self.uiTestCertificateStatePrefix)\(state)",
                                   "\(Self.uiTestGuidedSetupSectionPrefix)certificate",
                                   "\(Self.uiTestGuidedSetupModePrefix)replay"]
            app.launchJoesProxyForTesting()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            // Require an attributable app window before using coordinates on a multi-display Mac.
            try await attachSetupExample(sheet, named: "\(state)-before-expansion")
            for title in titles {
                let toggle = sheet.disclosureTriangles[title]
                XCTAssertTrue(toggle.waitForExistence(timeout: 5), title)
                let arrow = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                    .withOffset(CGVector(dx: 28, dy: 0))
                arrow.click()
                let caption = sheet.staticTexts["Illustration · macOS appearance may vary"]
                let expanded = caption.waitForExistence(timeout: 3)
                if !expanded {
                    try await attachSetupExample(sheet, named: "\(title)-after-click")
                }
                XCTAssertTrue(expanded, title)
                if !caption.isHittable {
                    sheet.scroll(byDeltaX: 0, deltaY: -220)
                }
                try await attachSetupExample(sheet, named: title)
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                    .withOffset(CGVector(dx: 28, dy: 0)).click()
            }
            app.terminate()
        }
    }

    @MainActor
    private func attachSetupExample(_ sheet: XCUIElement, named name: String) async throws {
        let image = try await ownedWindowAttachment(window: sheet)
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor
    func testCaptureGuidedSetupPages() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions", "--ui-test-primary-screen", "--ui-test-capture-setup-pages",
                               "\(Self.uiTestCertificateStatePrefix)ready", "--ui-test-verification-state=inspected",
                               "\(Self.uiTestGuidedSetupSectionPrefix)certificate", "\(Self.uiTestGuidedSetupModePrefix)replay"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        for (title, heading, name) in [
            ("Certificate", "Set up HTTPS on this Mac", "certificate"),
            ("Proxy", "Start the proxy", "proxy"),
            ("Verify Capture", "Verify a live request", "verifyCapture"),
            ("Devices", "Connect a device (optional)", "devices"),
            ("MCP/CLI", "Connect a command-line client (optional)", "mcpCLI")
        ] {
            if name == "mcpCLI" {
                // macOS fits the sheet when it opens. Give the longer client checklist its own opening size.
                app.terminate()
                app.launchArguments.removeAll { $0.hasPrefix(Self.uiTestGuidedSetupSectionPrefix) }
                app.launchArguments.append("\(Self.uiTestGuidedSetupSectionPrefix)mcpCLI")
                app.launchArguments.append("--ui-test-mcp-status=running-clean")
                app.launch()
            } else if title != "Certificate" {
                let menu = sheet.popUpButtons["guidedSetupSectionPicker"]
                if menu.exists {
                    menu.click()
                    app.menuItems[title].click()
                } else {
                    sheet.radioButtons[title].click()
                }
            }
            XCTAssertTrue(sheet.staticTexts[heading].waitForExistence(timeout: 3))
            XCTAssertTrue(sheet.buttons["guidedSetupClose"].isHittable)
            let receipt = identifiedElement("setupScreenshotReceipt-\(name)", in: app)
            XCTAssertTrue(receipt.waitForExistence(timeout: 5), "Screenshot \(name)")
        }
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
        for (title, heading) in [("Certificate", "Set up HTTPS on this Mac"), ("Proxy", "Start the proxy"),
                                 ("Verify Capture", "Verify a live request"), ("Devices", "Connect a device (optional)"),
                                 ("MCP/CLI", "Connect a command-line client (optional)")] {
            if title != "Certificate" {
                let menu = sheet.popUpButtons["guidedSetupSectionPicker"]
                if menu.exists {
                    menu.click()
                    app.menuItems[title].click()
                } else {
                    sheet.radioButtons[title].click()
                }
            }
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
        XCTAssertTrue(app.staticTexts["Verify a live request"].exists)
        let finish = app.buttons["guidedSetupFinish"]
        XCTAssertTrue(finish.isHittable)
        finish.click()
        XCTAssertTrue(guidedSetup.waitForNonExistence(timeout: 2))
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
        let guides = ["macOS Setup Guide", "iOS Setup Guide", "Apple TV Setup Guide"]
        let sheet = app.sheets.firstMatch
        for guide in guides { XCTAssertFalse(sheet.buttons[guide].exists, guide) }
        sheet.radioButtons["Devices"].click()
        for platform in ["iOS", "macOS", "Apple TV"] {
            sheet.radioButtons[platform].click()
            XCTAssertTrue(sheet.buttons["\(platform) Setup Guide"].waitForExistence(timeout: 2))
        }
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
    func testCertificateShortcutExposesAdvancedManagementInGuidedSetup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["\(Self.uiTestFixturePrefix)demo-sessions", "--ui-test-primary-screen",
                               "\(Self.uiTestCertificateStatePrefix)ready", "--ui-test-open-certificate-setup"]
        app.launchJoesProxyForTesting()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.staticTexts["Set up HTTPS on this Mac"].waitForExistence(timeout: 5))
        let advanced = sheet.disclosureTriangles["Advanced certificate settings"]
        XCTAssertTrue(advanced.exists)
        XCTAssertFalse(sheet.buttons["certificatePrepareRenewalButton"].exists)
        advanced.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 28, dy: 0)).click()
        XCTAssertTrue(sheet.buttons["certificatePrepareRenewalButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.buttons["Export Shared Root…"].exists)
        XCTAssertTrue(sheet.buttons["Import Shared Root…"].exists)
        XCTAssertTrue(sheet.buttons["Remove Installed Certificate"].exists)
    }

    @MainActor
    func testFirstRunPathChoiceThenStartFirstCaptureShowsInspectorCompanion() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-primary-screen",
            "--ui-test-certificate-state=notSetUp",
            "--ui-test-verification-state=noTrafficObserved",
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

        let setupSheet = app.sheets.firstMatch
        XCTAssertTrue(setupSheet.staticTexts["Start the proxy"].waitForExistence(timeout: 5))
        setupSheet.buttons["guidedSetupNext"].click()
        XCTAssertTrue(setupSheet.staticTexts["Verify a live request"].waitForExistence(timeout: 3))
        XCTAssertEqual(setupSheet.buttons["guidedSetupRunLiveChecks"].label, "Run HTTP check")
        setupSheet.buttons["guidedSetupFinish"].click()

        XCTAssertTrue(app.textFields["sessionSearchField"].waitForExistence(timeout: 5))
        let setupSummary = app.buttons["workspaceSetupSummary"]
        let openedSetupSummary = setupSummary.exists
        if openedSetupSummary { setupSummary.click() }
        XCTAssertTrue(identifiedElement("inspectorSetupCompanion", in: app).waitForExistence(timeout: 5))
        if openedSetupSummary { app.sheets.buttons["Done"].firstMatch.click() }
        XCTAssertFalse(identifiedElement("guidedSetupRepairView", in: app).exists)
        XCTAssertTrue(identifiedElement("firstRunSetupChip", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(identifiedElement("proxyToggleButton", in: app).exists)
        for _ in 0..<2 {
            identifiedElement("firstRunSetupChip", in: app).click()
            let setup = identifiedElement("guidedSetupRepairView", in: app)
            XCTAssertTrue(setup.waitForExistence(timeout: 5))
            identifiedElement("guidedSetupClose", in: app).click()
        }
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
