// These tests run on the host macOS environment without simulator isolation — spurious
// failures can occur due to system notifications, focus loss, or background CPU pressure.
// Re-run on a quiet machine before treating a failure as a code regression.
// See JoesProxyUITests.swift for the full explanation.
import XCTest

final class SessionPerformanceUITests: XCTestCase {
    private static let uiTestFixtureLaunchArgument = "--ui-test-fixture=demo-sessions"
    private static let uiTestSessionCountLaunchArgument = "--ui-test-session-count=1500"
    private static let uiTestProxyPortLaunchArgument = "--ui-test-proxy-port=19091"
    private static let uiTestBrowserModePrefix = "--ui-test-browser-mode="

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchPerformanceWithLargeDemoSessions() throws {
        if #available(macOS 10.15, *) {
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                let app = XCUIApplication()
                app.launchArguments = [
                    Self.uiTestFixtureLaunchArgument,
                    Self.uiTestSessionCountLaunchArgument,
                    Self.uiTestProxyPortLaunchArgument,
                    "\(Self.uiTestBrowserModePrefix)table"
                ]
                app.launchJoesProxyForTesting()
            }
        }
    }

    @MainActor
    func testTableExplorerSwitchPerformanceWithLargeDemoSessions() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            Self.uiTestFixtureLaunchArgument,
            Self.uiTestSessionCountLaunchArgument,
            Self.uiTestProxyPortLaunchArgument,
            "\(Self.uiTestBrowserModePrefix)table"
        ]
        app.launchJoesProxyForTesting()

        XCTAssertTrue(identifiedElement("sessionTable", in: app).waitForExistence(timeout: 5))


        measure(metrics: [XCTClockMetric()]) {
            // Measure the transition, not an application-wide search through 1,500 rows.
            app.menuBars.firstMatch.typeKey("4", modifierFlags: [.command])
            XCTAssertTrue(identifiedElement("sessionExplorerView", in: app).waitForExistence(timeout: 15))
            app.menuBars.firstMatch.typeKey("3", modifierFlags: [.command])
            XCTAssertTrue(identifiedElement("sessionTable", in: app).waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testTableExplorerSwitchPreservesInspectorSplitFraction() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            Self.uiTestFixtureLaunchArgument,
            Self.uiTestProxyPortLaunchArgument,
            "\(Self.uiTestBrowserModePrefix)table"
        ]
        app.launchJoesProxyForTesting()

        XCTAssertTrue(identifiedElement("sessionTable", in: app).waitForExistence(timeout: 5))


        let splitValueElement = identifiedElement("workspaceInvestigationSplit", in: app)
        XCTAssertTrue(splitValueElement.waitForExistence(timeout: 5),
                      "Expected two-pane workspace; main window frame: \(app.windows.firstMatch.frame)")

        let initialFraction = try XCTUnwrap(splitFraction(from: splitValueElement))
        let adjustedFractionTarget = min(max(initialFraction - 0.12, 0.35), 0.7)
        dragInspectorSplit(in: app, from: initialFraction, to: adjustedFractionTarget)

        let adjustedFraction = try XCTUnwrap(
            waitForSplitFraction(
                in: splitValueElement,
                matching: adjustedFractionTarget,
                tolerance: 0.05
            )
        )

        app.selectSessionBrowser("Explorer")
        XCTAssertTrue(identifiedElement("sessionExplorerView", in: app).waitForExistence(timeout: 15))
        app.selectSessionBrowser("Table")
        XCTAssertTrue(identifiedElement("sessionTable", in: app).waitForExistence(timeout: 2))

        let restoredFraction = try XCTUnwrap(
            waitForSplitFraction(
                in: splitValueElement,
                matching: adjustedFraction,
                tolerance: 0.02
            )
        )

        XCTAssertEqual(restoredFraction, adjustedFraction, accuracy: 0.02)
    }

    private func sessionBrowserButton(titled title: String, in container: XCUIElement) -> XCUIElement {
        container.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    private func identifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func splitFraction(from element: XCUIElement) -> Double? {
        let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty, let fraction = Double(label) {
            return fraction
        }

        if let value = element.value as? String {
            return Double(value)
        }

        if let value = element.value as? NSNumber {
            return value.doubleValue
        }

        return nil
    }

    private func waitForSplitFraction(
        in element: XCUIElement,
        matching expected: Double,
        tolerance: Double
    ) -> Double? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let fraction = splitFraction(from: element),
               abs(fraction - expected) <= tolerance {
                return fraction
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        // A settled but incorrect fraction is a failure, not a successful wait.
        return nil
    }

    private func dragInspectorSplit(in app: XCUIApplication, from startFraction: Double, to endFraction: Double) {
        let window = identifiedElement("workspaceInvestigationSplit", in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 2))

        let start = window.coordinate(
            withNormalizedOffset: CGVector(dx: startFraction, dy: 0.5)
        )
        let end = window.coordinate(
            withNormalizedOffset: CGVector(dx: endFraction, dy: 0.5)
        )

        start.press(forDuration: 0.1, thenDragTo: end)
    }
}
