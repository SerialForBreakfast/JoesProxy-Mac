//
//  ScreenshotUITests.swift
//  JoesProxyUITests
//
//  UI tests that capture deterministic screenshots of JoesProxy with pre-populated
//  demo sessions. Launches with screenshot-specific arguments so the app starts in
//  a known browser mode and does not depend on persisted user defaults.
//

import XCTest
import AppKit
import ScreenCaptureKit

final class ScreenshotUITests: XCTestCase {
    @MainActor
    func testControlledClientRendersJourneyAndStopRestoresBaseline() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=mock-journey", "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["mockJourneyComplete"].waitForExistence(timeout: 25),
                      app.staticTexts["mockJourneyStatus"].debugDescription)
        let title = app.staticTexts["mockJourneyTitle"]
        let detail = app.staticTexts["mockJourneyDetail"]
        XCTAssertEqual(title.value as? String ?? title.label, "Mock item")
        XCTAssertEqual(detail.value as? String ?? detail.label, "Mock detail")
        XCTAssertTrue(app.images["mockJourneyArtwork"].exists)
        let status = app.staticTexts["mockJourneyStatus"]
        XCTAssertTrue((status.value as? String ?? status.label).contains("baseline restored"))
        let window = app.windows.containing(.staticText, identifier: "mockJourneyComplete").firstMatch
        try await captureAssetWindow(app: app, window: window, name: "mock-client-rendered-journey-and-restoration")
    }

    private static let screenshotDemoLaunchArgument = "--screenshot-demo"
    private static let screenshotBrowserModePrefix = "--screenshot-browser-mode="
    private static let screenshotTextSizePrefix = "--screenshot-text-size="

    private enum BrowserMode: String {
        case table
        case explorer
        case timeline

        var launchArgument: String {
            "\(ScreenshotUITests.screenshotBrowserModePrefix)\(rawValue)"
        }

        var attachmentName: String {
            switch self {
            case .table:
                return "JoesProxy Table Mode"
            case .explorer:
                return "JoesProxy Explorer Mode"
            case .timeline:
                return "JoesProxy Timeline Mode"
            }
        }

        var requiredElementIdentifier: String {
            switch self {
            case .table:
                return "Table"
            case .explorer:
                return "Explorer"
            case .timeline:
                return "sessionTimelineView"
            }
        }
    }

    private enum ScreenshotTextSize: String {
        case standard
        case accessibility

        var launchArgument: String {
            "\(ScreenshotUITests.screenshotTextSizePrefix)\(rawValue)"
        }

        var attachmentSuffix: String {
            switch self {
            case .standard:
                return ""
            case .accessibility:
                return " Accessibility Text"
            }
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCapturePreparedMockScreenshot() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=guided-mock-authoring", "--ui-test-browser-mode=table",
                               "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        XCTAssertTrue(app.identifiedElement("sessionTable").waitForExistence(timeout: 10))
        app.menuBars.firstMatch.typeKey("l", modifierFlags: [.command, .option])
        let window = app.windows["Traffic Modifications"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let prepare = window.buttons["mockAuthoringPrepare"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        for _ in 0..<8 where !prepare.isHittable {
            window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -150)
        }
        XCTAssertTrue(prepare.isHittable)
        prepare.click()
        XCTAssertTrue(window.groups["mockRelatedPreview-related-0"].disclosureTriangles.firstMatch.waitForExistence(timeout: 10))
        // Preparation only: never save, approve or activate the fixture.
        try recordCaptureDiagnostics(app: app, window: window)
        let attachment = try await ownedWindowAttachment(window: window)
        attachment.name = "JoesProxy Prepared Mock Synthetic"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCaptureDeliveryEvidenceScreenshot() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=authored-evidence", "--ui-test-text-size=standard",
                               "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let disclosure = app.buttons["effectBundleEvidenceToggle"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
        disclosure.click()
        let refresh = app.buttons["effectBundleRefreshEvidence"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.click()
        XCTAssertTrue(app.staticTexts["Asset: fixture-0"].waitForExistence(timeout: 5))
        let window = app.windows.containing(.button, identifier: "effectBundleRefreshEvidence").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        try recordCaptureDiagnostics(app: app, window: window)
        let attachment = try await ownedWindowAttachment(window: window)
        attachment.name = "JoesProxy Delivery Evidence Synthetic"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCaptureTableScreenshotWithDemoSessions() async throws {
        try await captureScreenshot(for: .table)
    }

    @MainActor
    func testCaptureCompactScreenshotWithDemoSessions() async throws {
        let app = XCUIApplication()
        app.launchArguments = [Self.screenshotDemoLaunchArgument, "--compact-mode"]
        app.launchJoesProxyForTesting()
        let root = app.identifiedElement("compactMonitorRoot")
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let window = app.windows.containing(.any, identifier: "compactMonitorRoot").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        XCTAssertTrue(root.isHittable)
        try recordCaptureDiagnostics(app: app, window: window)
        let attachment = try await ownedWindowAttachment(window: window)
        attachment.name = "JoesProxy Compact Synthetic"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCaptureExplorerScreenshotWithDemoSessions() async throws {
        try await captureScreenshot(for: .explorer)
    }

    @MainActor
    func testCaptureTimelineScreenshotWithDemoSessions() async throws {
        try await captureScreenshot(for: .timeline)
    }

    @MainActor
    func testCaptureTableScreenshotWithAccessibilityTextSize() async throws {
        try await captureScreenshot(for: .table, textSize: .accessibility)
    }

    @MainActor
    func testCaptureExplorerScreenshotWithAccessibilityTextSize() async throws {
        try await captureScreenshot(for: .explorer, textSize: .accessibility)
    }

    @MainActor
    func testCaptureTimelineScreenshotWithAccessibilityTextSize() async throws {
        try await captureScreenshot(for: .timeline, textSize: .accessibility)
    }

    /// Captures the MCP Management panel's Approvals tab — the human-review gate an AI agent's
    /// proposed mutations wait on. Uses the same `--ui-test-fixture=`/`--ui-test-mcp-status=`
    /// launch arguments as `MCPStatusUITests` (a pending-approval state, not the demo-sessions
    /// browser fixture the other screenshot tests use).
    @MainActor
    func testCaptureMCPManagementApprovalsScreenshot() async throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-test-fixture=demo-sessions",
            "--ui-test-mcp-status=approvals", "--ui-test-primary-screen"
        ])
        app.launchJoesProxyForTesting()
        defer { app.terminate() }

        let pill = app.buttons["mcpStatusPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        pill.click()

        let approvalsDetail = app.descendants(matching: .any)["mcpManagementDetail-approvals"]
        XCTAssertTrue(approvalsDetail.waitForExistence(timeout: 5))
        let window = app.windows.containing(.any, identifier: "mcpManagementDetail-approvals").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "App window should exist")
        try recordCaptureDiagnostics(app: app, window: window)
        let attachment = try await ownedWindowAttachment(window: window)
        attachment.name = "JoesProxy MCP Management Approvals"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Captures the BA-3 first-run path-choice screen.
    @MainActor
    func testCaptureGuidedSetupFirstRunScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-test-guided-setup-mode=first-run"
        ])
        app.launchJoesProxyForTesting()

        let pathChoice = app.descendants(matching: .any)["firstRunPathChoiceView"]
        XCTAssertTrue(pathChoice.waitForExistence(timeout: 5), "firstRunPathChoiceView should exist")
        sleep(1)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "App window should exist")

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "JoesProxy Guided Setup First Run"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Captures the actual setup instructions; no device verification or QR action is performed.
    @MainActor
    func testCaptureGuidedDeviceSetupScreenshot() async throws {
        try await captureReservedDeviceSetup(textSize: "standard")
    }

    @MainActor
    func testCaptureReservedDeviceSetupAccessibility() async throws {
        try await captureReservedDeviceSetup(textSize: "accessibility")
    }

    @MainActor
    private func captureReservedDeviceSetup(textSize: String) async throws {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--ui-test-fixture=demo-sessions",
            "--ui-test-text-size=\(textSize)",
            "--ui-test-open-ios-setup", "--ui-test-primary-screen"
        ])
        app.launchJoesProxyForTesting()
        defer { app.terminate() }

        let step1 = app.staticTexts["Profile Downloaded"]
        XCTAssertTrue(step1.waitForExistence(timeout: 5), "iOS Setup guide should be presented")
        let window = app.windows.containing(.staticText, identifier: "Profile Downloaded").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "App window should exist")
        XCTAssertTrue(window.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
            "192.0.2.10", "192.0.2.10")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(window.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "macbook.local")).firstMatch.exists)
        try recordCaptureDiagnostics(app: app, window: window)
        let attachment = try await ownedWindowAttachment(window: window)
        attachment.name = "JP-08 Reserved Device Setup \(textSize)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCaptureLoopbackTransportEvidence() async throws {
        try await captureTransportEvidence(textSize: "standard")
    }

    @MainActor
    func testCaptureLoopbackTransportEvidenceAccessibility() async throws {
        try await captureTransportEvidence(textSize: "accessibility")
    }

    @MainActor
    private func captureTransportEvidence(textSize: String) async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=transport-assets", "--ui-test-text-size=\(textSize)",
                               "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        waitForAssetScenario(app)
        app.buttons["effectBundleEvidenceToggle"].click()
        app.buttons["effectBundleRefreshEvidence"].click()
        XCTAssertTrue(app.staticTexts["Downstream write completed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Asset could not be read"].exists)
        let window = app.windows.containing(.button, identifier: "effectBundleRefreshEvidence").firstMatch
        try await captureAssetWindow(app: app, window: window, name: "JP-03 Transport Success \(textSize)")
        let details = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "effectBundleReceipt-", "-details"))
        XCTAssertEqual(details.count, 2)
        let failureDetails = details.element(boundBy: 1)
        for _ in 0..<6 where !failureDetails.isHittable { window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180) }
        failureDetails.click()
        window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -240)
        try await captureAssetWindow(app: app, window: window, name: "JP-03 Unavailable Asset \(textSize)")
    }

    @MainActor
    func testCaptureLoopbackHLSManifestAndFaultTimeline() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture=streaming-assets", "--ui-test-browser-mode=table",
                               "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        waitForAssetScenario(app)
        let search = app.textFields["sessionSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("playlist.m3u8")
        let table = app.identifiedElement("sessionTable")
        let rows = table.descendants(matching: .outlineRow)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: rows)], timeout: 5), .completed)
        rows.firstMatch.staticTexts.firstMatch.click()
        let media = app.buttons["openMediaInfoButton"]
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        media.click()
        let manifestWindow = app.windows.containing(.button, identifier: "mediaInfoCloseButton").firstMatch
        XCTAssertTrue(manifestWindow.staticTexts["Media Playlist"].waitForExistence(timeout: 5))
        XCTAssertTrue(manifestWindow.staticTexts["Segments"].exists)
        try await captureAssetWindow(app: app, window: manifestWindow, name: "JP-05 HLS Manifest Loopback")
        manifestWindow.buttons["mediaInfoCloseButton"].click()
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText(XCUIKeyboardKey.delete.rawValue)
        app.selectSessionBrowser("Timeline")
        let timeline = app.identifiedElement("sessionTimelineView")
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let failedSegment = timeline.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
            "segment-1.ts", "status 503")).firstMatch
        XCTAssertTrue(failedSegment.waitForExistence(timeout: 5))
        failedSegment.click()
        let window = app.windows.containing(.any, identifier: "sessionTimelineView").firstMatch
        try await captureAssetWindow(app: app, window: window, name: "JP-05 Controlled Segment Fault Timeline")
    }

    @MainActor
    private func waitForAssetScenario(_ app: XCUIApplication) {
        let status = app.staticTexts["transportAssetScenarioStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
            "listener stopped", "listener stopped"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 20), .completed, status.debugDescription)
    }

    @MainActor
    private func captureAssetWindow(app: XCUIApplication, window: XCUIElement, name: String) async throws {
        try recordCaptureDiagnostics(app: app, window: window)
        let attachment = try await ownedWindowAttachment(window: window)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func captureScreenshot(
        for browserMode: BrowserMode,
        textSize: ScreenshotTextSize = .standard
    ) async throws {
        let app = XCUIApplication()
        app.launchArguments.append(Self.screenshotDemoLaunchArgument)
        app.launchArguments.append(browserMode.launchArgument)
        app.launchArguments.append(textSize.launchArgument)
        app.launchJoesProxyForTesting()

        let proxyButton = app.buttons["proxyToggleButton"]
        XCTAssertTrue(proxyButton.waitForExistence(timeout: 5))

        let requiredElement = app.descendants(matching: .any)[browserMode.requiredElementIdentifier]
        XCTAssertTrue(
            requiredElement.waitForExistence(timeout: 5),
            "\(browserMode.requiredElementIdentifier) should exist before capturing \(browserMode.rawValue)"
        )

        // Screenshot demo mode pre-seeds sessions; no proxy start needed.
        // Wait for the selected browser surface to settle before capturing.
        sleep(1)

        let window = app.windows.containing(.any, identifier: "proxyToggleButton").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Browser window should exist")
        app.activate()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        XCTAssertTrue(proxyButton.isHittable)

        try recordCaptureDiagnostics(app: app, window: window)

        let attachment = try await ownedWindowAttachment(window: window)
        attachment.name = browserMode.attachmentName + textSize.attachmentSuffix
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Check the runner's access without requesting permission or capturing other applications.
    @MainActor
    private func recordCaptureDiagnostics(app: XCUIApplication, window: XCUIElement) throws {
        let allowed = CGPreflightScreenCaptureAccess()
        let targets = NSRunningApplication.runningApplications(withBundleIdentifier: "com.ShowBlender.JoesProxy")
        guard targets.count == 1, let target = targets.first else {
            XCTFail("Expected exactly one running JoesProxy for screenshot attribution")
            throw CaptureFailure.ambiguousTarget
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.processIdentifier
        }
        let details = owned.map {
            "id=\($0[kCGWindowNumber as String] ?? "unknown") bounds=\($0[kCGWindowBounds as String] ?? "unknown") layer=\($0[kCGWindowLayer as String] ?? "unknown")"
        }.joined(separator: "\n")
        let receipt = XCTAttachment(string: "runner=\(Bundle.main.bundleIdentifier ?? "unknown")\nscreenCaptureAccess=\(allowed)\nappState=\(app.state.rawValue)\nAXFrame=\(window.frame)\nownedWindows:\n\(details)")
        receipt.name = "Screenshot capture access and owned geometry"
        receipt.lifetime = .keepAlways
        add(receipt)
        guard allowed else {
            XCTFail("Screenshot runner lacks screen capture access. Inspect the capture-access attachment for its identity; do not treat UI assertions as screenshot delivery.")
            throw CaptureFailure.accessUnavailable
        }
        XCTAssertFalse(owned.isEmpty, "The target app must have an on-screen window before capture")
    }

    /// Capture the identified window itself, not a desktop crop that may contain another app.
    @MainActor
    private func ownedWindowAttachment(window: XCUIElement) async throws -> XCTAttachment {
        let targets = NSRunningApplication.runningApplications(withBundleIdentifier: "com.ShowBlender.JoesProxy")
        guard targets.count == 1, let target = targets.first else { throw CaptureFailure.ambiguousTarget }
        let frame = window.frame
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let matches = content.windows.filter {
            $0.owningApplication?.processID == target.processIdentifier &&
            abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.minY - frame.minY) < 2 &&
            abs($0.frame.width - frame.width) < 2 && abs($0.frame.height - frame.height) < 2
        }
        guard matches.count == 1, let selected = matches.first else { throw CaptureFailure.ambiguousTarget }
        let filter = SCContentFilter(desktopIndependentWindow: selected)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(frame.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(frame.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CaptureFailure.encodingFailed
        }
        return XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    }

    private enum CaptureFailure: Error { case accessUnavailable, ambiguousTarget, encodingFailed }
}
