import XCTest

@MainActor
final class MCPStatusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testMCPStatusPillVisibleWhenOffCleanIdle() throws {
        app.launchArguments = ["\(LaunchArgument.uiTestFixturePrefix)demo-sessions"]
        app.launchJoesProxyForTesting()

        let pill = app.buttons["mcpStatusPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue(pill.label.localizedCaseInsensitiveContains("MCP off"))

        pill.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["mcpManagementDetail-overview"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.buttons["mcpManagementCloseButton"].waitForExistence(timeout: 3),
            "MCP Management sheet must remain dismissible after resizable configuration"
        )
    }

    func testCompactOpensIndependentManagementAndApprovalsWithoutLeavingHUD() throws {
        app.launchArguments = ["--ui-test-fixture=demo-sessions", "--compact-mode"]
        app.launchJoesProxyForTesting()
        XCTAssertTrue(app.identifiedElement("compactMonitorRoot").waitForExistence(timeout: 5))
        for _ in 0..<3 {
            app.menuBars.menuBarItems["MCP"].click()
            app.menuBars.menuItems["Open MCP Management…"].click()
            let management = app.windows["mcp-management"]
            XCTAssertTrue(management.waitForExistence(timeout: 5))
            XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)
            management.buttons["mcpManagementCloseButton"].click()
            XCTAssertTrue(management.waitForNonExistence(timeout: 5))
            // Exactly one click must both reactivate Compact and open the utility window.
            app.buttons["compactApprovalsButton"].click()
            let approvals = app.windows["mcp-approvals"]
            XCTAssertTrue(approvals.waitForExistence(timeout: 5))
            XCTAssertEqual(app.windows.matching(identifier: "mcp-approvals").count, 1)
            XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)
            XCTAssertFalse(app.identifiedElement("sessionTable").exists)
            let done = approvals.buttons["mcpCompactApprovalsDone"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            XCTAssertTrue(approvals.staticTexts["mcpCompactApprovalsEmpty"].exists)
            done.click()
            XCTAssertTrue(approvals.waitForNonExistence(timeout: 5))
        }
    }

    func testCompactAboutReusesOneWindowAndKeepsHUD() throws {
        app.launchArguments = ["--ui-test-fixture=demo-sessions", "--compact-mode"]
        app.launchJoesProxyForTesting()
        XCTAssertTrue(app.identifiedElement("compactMonitorRoot").waitForExistence(timeout: 5))
        for _ in 0..<2 {
            app.menuBars.menuBarItems["JoesProxy"].click()
            app.menuBars.menuBarItems["JoesProxy"].menus.menuItems["About JoesProxy"].click()
            XCTAssertTrue(app.windows["about-joesproxy"].waitForExistence(timeout: 5))
        }
        XCTAssertEqual(app.windows.matching(identifier: "about-joesproxy").count, 1)
        XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)
        XCTAssertFalse(app.identifiedElement("sessionTable").exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.identifiedElement("compactMonitorRoot").exists)
    }

    func testMCPStatusPillVisibleWhenRunningClean() throws {
        app.launchArguments = [
            "\(LaunchArgument.uiTestFixturePrefix)demo-sessions",
            "\(LaunchArgument.uiTestMCPStatusPrefix)running-clean"
        ]
        app.launchJoesProxyForTesting()

        let pill = app.buttons["mcpStatusPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue(pill.label.localizedCaseInsensitiveContains("MCP running")
            || pill.label.localizedCaseInsensitiveContains("MCP connected"))
    }

    func testMCPStatusPillShowsOffActiveEffects() throws {
        app.launchArguments = [
            "\(LaunchArgument.uiTestFixturePrefix)demo-sessions",
            "\(LaunchArgument.uiTestMCPStatusPrefix)off-active"
        ]
        app.launchJoesProxyForTesting()

        let pill = app.buttons["mcpStatusPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue(pill.label.localizedCaseInsensitiveContains("effects active"))
    }

    func testMCPStatusPillShowsPendingApprovals() throws {
        app.launchArguments = [
            "\(LaunchArgument.uiTestFixturePrefix)demo-sessions",
            "\(LaunchArgument.uiTestMCPStatusPrefix)approvals"
        ]
        app.launchJoesProxyForTesting()

        let pill = app.buttons["mcpStatusPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue(pill.label.localizedCaseInsensitiveContains("approval"))

        pill.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["mcpManagementDetail-approvals"]
                .waitForExistence(timeout: 3)
        )
    }

    /// 182-2: the Inspector's menu path to Approvals, with controls that name their request.
    /// Closes with Done only — resolving a request in a seeded test is not human approval.
    func testInspectorMenuOpensApprovalsWithRequestSpecificLabels() throws {
        try openApprovalsFromInspectorMenu(textSize: "standard")
    }

    func testInspectorMenuOpensApprovalsAtAccessibilityTextSize() throws {
        try openApprovalsFromInspectorMenu(textSize: "accessibility")
    }

    private func openApprovalsFromInspectorMenu(textSize: String) throws {
        app.launchArguments = [
            "\(LaunchArgument.uiTestFixturePrefix)demo-sessions",
            "\(LaunchArgument.uiTestMCPStatusPrefix)approvals",
            "--ui-test-text-size=\(textSize)"
        ]
        app.launchJoesProxyForTesting()
        XCTAssertTrue(app.buttons["mcpStatusPill"].waitForExistence(timeout: 5))

        app.menuBars.menuBarItems["MCP"].click()
        app.menuBars.menuItems["Pending Approvals…"].click()
        let approvals = app.windows["mcp-approvals"]
        XCTAssertTrue(approvals.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.matching(identifier: "mcp-approvals").count, 1)

        let allow = approvals.buttons["mcpCompactApproveOnce"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        XCTAssertTrue(allow.label.contains("UI test pending approval"), "Label: \(allow.label)")
        let deny = approvals.buttons["mcpCompactDenyOnce"]
        XCTAssertTrue(deny.label.contains("UI test pending approval"), "Label: \(deny.label)")
        XCTAssertNotEqual(allow.label, deny.label)
        // Enlarged text must wrap the controls, not clip them outside the window.
        XCTAssertTrue(allow.isHittable)
        XCTAssertTrue(deny.isHittable)
        XCTAssertTrue(approvals.frame.contains(deny.frame), "Deny frame \(deny.frame) outside \(approvals.frame)")
        let screenshot = XCTAttachment(screenshot: approvals.screenshot())
        screenshot.name = "mcp-approvals-\(textSize)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        approvals.buttons["mcpCompactApprovalsDone"].click()
        XCTAssertTrue(approvals.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.identifiedElement("sessionTable").exists, "The Inspector must remain mounted")
    }

    func testMCPRecoveryPillOpensEffectsAndRecovery() throws {
        app.launchArguments = [
            "\(LaunchArgument.uiTestFixturePrefix)demo-sessions",
            "\(LaunchArgument.uiTestMCPStatusPrefix)conflict"
        ]
        app.launchJoesProxyForTesting()

        let pill = app.buttons["mcpStatusPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue(pill.label.localizedCaseInsensitiveContains("recovery needed"))

        pill.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["mcpManagementDetail-effects"]
                .waitForExistence(timeout: 3)
        )
    }
}

private enum LaunchArgument {
    static let uiTestFixturePrefix = "--ui-test-fixture="
    static let uiTestMCPStatusPrefix = "--ui-test-mcp-status="
}
