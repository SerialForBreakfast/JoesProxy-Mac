// These tests run on the host macOS environment without simulator isolation — spurious
// failures can occur due to system notifications, focus loss, or background CPU pressure.
// Re-run on a quiet machine before treating a failure as a code regression.
// See JoesProxyUITests.swift for the full explanation.
import XCTest

final class SetupVerificationUITests: XCTestCase {
    private static let uiTestFixturePrefix = "--ui-test-fixture="
    private static let uiTestCertificateStatePrefix = "--ui-test-certificate-state="
    private static let uiTestVerificationStatePrefix = "--ui-test-verification-state="
    private static let uiTestOpenCertificateSetup = "--ui-test-open-certificate-setup"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testInjectedInspectedVerificationStateShowsSuccessCard() throws {
        let app = launchVerificationApp(verificationState: "inspected")

        XCTAssertTrue(identifiedElement("certificateSetupSheet", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Verify Capture"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["HTTPS traffic was inspected successfully"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["JoesProxy has observed at least one inspected HTTPS session, so certificate trust and routing are working together."].waitForExistence(timeout: 2))
    }

    @MainActor
    func testInjectedTunneledVerificationStateShowsPartialSuccessCard() throws {
        let app = launchVerificationApp(verificationState: "tunneled")

        XCTAssertTrue(identifiedElement("certificateSetupSheet", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Traffic is routing through JoesProxy, but HTTPS is still tunneled"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Traffic is reaching JoesProxy, but HTTPS decryption is still unavailable or intentionally bypassed for the observed host."].waitForExistence(timeout: 2))
    }

    @MainActor
    func testInjectedTunneledVerificationStateTrafficHelpLinkOpensFocusedHelpHub() throws {
        let app = launchVerificationApp(verificationState: "tunneled")

        XCTAssertTrue(identifiedElement("certificateSetupSheet", in: app).waitForExistence(timeout: 5))

        let helpButton = identifiedElement("setupVerificationTrafficHelpButton", in: app)
        XCTAssertTrue(helpButton.waitForExistence(timeout: 2))
        helpButton.click()

        let helpHub = identifiedElement("helpHubView", in: app)
        XCTAssertTrue(helpHub.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recommended For This Step"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Traffic States"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testInjectedNoTrafficObservedVerificationStateShowsRoutingGuidance() throws {
        let app = launchVerificationApp(verificationState: "noTrafficObserved")

        XCTAssertTrue(identifiedElement("certificateSetupSheet", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No test traffic was observed yet"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["No routed session observed yet. Verify proxy host, port, browser or device proxy settings, and network reachability."].waitForExistence(timeout: 2))
        XCTAssertTrue(identifiedElement("setupDiagnosticCommands", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Copy HTTP routing diagnostic command"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Copy HTTPS inspection diagnostic command"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testInjectedProxyStoppedVerificationStateShowsStartProxyGuidance() throws {
        let app = launchVerificationApp(verificationState: "proxyStopped")

        XCTAssertTrue(identifiedElement("certificateSetupSheet", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Start the proxy before running the test"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["The proxy listener is not running. Start it, then retry the verification flow."].waitForExistence(timeout: 2))
        XCTAssertTrue(identifiedElement("setupVerificationStartProxyButton", in: app).waitForExistence(timeout: 2))
    }

    @MainActor
    private func launchVerificationApp(verificationState: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "\(Self.uiTestFixturePrefix)demo-sessions",
            "\(Self.uiTestCertificateStatePrefix)ready",
            "\(Self.uiTestVerificationStatePrefix)\(verificationState)",
            Self.uiTestOpenCertificateSetup
        ]
        app.launchJoesProxyForTesting()
        return app
    }

    private func identifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
