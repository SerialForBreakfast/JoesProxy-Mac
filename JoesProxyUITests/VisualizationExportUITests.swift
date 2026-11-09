import XCTest

/// UI coverage for the shared visualization export shell (Workstream AF-3).
final class VisualizationExportUITests: XCTestCase {
    private static let uiTestFixturePrefix = "--ui-test-fixture="
    private static let uiTestBrowserModePrefix = "--ui-test-browser-mode="
    private static let uiTestTextSizePrefix = "--ui-test-text-size="
    private static let uiTestProxyPortPrefix = "--ui-test-proxy-port="
    private static let uiTestExportDestinationPathPrefix = "--ui-test-export-destination-path="

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testVisualizationExportShellFlow() throws {
        let app = launchDemoApp()

        XCTAssertTrue(identifiedElement("sessionTable", in: app).waitForExistence(timeout: 5))

        openVisualizationExportSheet(in: app)

        let exportSheet = identifiedElement("visualizationExportSheet", in: app)
        XCTAssertTrue(exportSheet.waitForExistence(timeout: 2))

        let sessionTimelineType = identifiedElement("visualizationExportType-sessionTimeline", in: app)
        XCTAssertTrue(sessionTimelineType.waitForExistence(timeout: 2))

        let hostHealthType = identifiedElement("visualizationExportType-hostHealthSummary", in: app)
        XCTAssertTrue(hostHealthType.waitForExistence(timeout: 2))
        // Default type depends on whether Follow Live selected a session. Test explicit choice.
        hostHealthType.click()
        XCTAssertEqual(hostHealthType.value as? String, "Selected")
        XCTAssertEqual(sessionTimelineType.value as? String, "Not selected")

        let requestWaterfallType = identifiedElement("visualizationExportType-requestWaterfall", in: app)
        XCTAssertTrue(requestWaterfallType.waitForExistence(timeout: 2))
        requestWaterfallType.click()
        XCTAssertEqual(requestWaterfallType.value as? String, "Selected")
        XCTAssertTrue(exportSheet.staticTexts["Request Waterfall"].waitForExistence(timeout: 2))

        sessionTimelineType.click()
        XCTAssertEqual(sessionTimelineType.value as? String, "Selected")

        selectPickerOption(identifier: "visualizationExportResolutionPicker", option: "QHD", in: app)
        let dimensionsLabel = identifiedElement("visualizationExportPixelDimensionsLabel", in: app)
        XCTAssertTrue(dimensionsLabel.waitForExistence(timeout: 2))
        XCTAssertEqual(
            identifiedElement("visualizationExportResolutionPicker", in: app).value as? String,
            "QHD"
        )

        selectPickerOption(identifier: "visualizationExportThemePicker", option: "Presentation", in: app)
        XCTAssertEqual(
            identifiedElement("visualizationExportThemePicker", in: app).value as? String,
            "Presentation"
        )

        let allowRawValuesToggle = identifiedElement("visualizationExportAllowRawValuesToggle", in: app)
        XCTAssertTrue(allowRawValuesToggle.waitForExistence(timeout: 2))
        allowRawValuesToggle.click()

        let redactAuthToggle = identifiedElement("visualizationExportRedactAuthToggle", in: app)
        XCTAssertTrue(redactAuthToggle.waitForExistence(timeout: 2))
        redactAuthToggle.click()

        let cancelButton = identifiedElement("visualizationExportCancelButton", in: app)
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
        cancelButton.click()

        XCTAssertTrue(waitForNonExistence(exportSheet, timeout: 5))
    }

    @MainActor
    func testVisualizationExportPNGHappyPathWritesFileWithoutSavePanel() throws {
        let artifactPath = try XCTUnwrap(ProcessInfo.processInfo.environment["JOESPROXY_UI_ARTIFACT_DIRECTORY"],
            "Run through host_ui_test.sh so the host prepares and independently verifies export artifacts.")
        let artifactDirectory = URL(fileURLWithPath: artifactPath, isDirectory: true)
        let destinationURL = artifactDirectory.appendingPathComponent("VisualizationExportUITest-\(UUID().uuidString).png")

        let app = launchDemoApp(exportDestinationPath: destinationURL.path)
        defer { app.terminate() }

        XCTAssertTrue(identifiedElement("sessionTable", in: app).waitForExistence(timeout: 5))

        openVisualizationExportSheet(in: app)

        let exportSheet = identifiedElement("visualizationExportSheet", in: app)
        XCTAssertTrue(exportSheet.waitForExistence(timeout: 2))

        let exportButton = identifiedElement("visualizationExportPNGButton", in: app)
        if exportButton.waitForExistence(timeout: 2) {
            exportButton.click()
        } else {
            app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        }

        XCTAssertTrue(waitForNonExistence(exportSheet, timeout: 5))
        // This is a UI-completion receipt, not proof of file delivery. The host verifies the
        // exact file independently; the sandboxed runner never reads or writes the repository.
        let receipt = XCTAttachment(string: destinationURL.lastPathComponent)
        receipt.name = "visualization-export-output"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    @MainActor
    private func launchDemoApp(exportDestinationPath: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = [
            "\(Self.uiTestFixturePrefix)demo-sessions",
            "\(Self.uiTestBrowserModePrefix)table",
            "\(Self.uiTestTextSizePrefix)standard",
            "\(Self.uiTestProxyPortPrefix)19090"
        ]
        if let exportDestinationPath {
            arguments.append("\(Self.uiTestExportDestinationPathPrefix)\(exportDestinationPath)")
        }
        app.launchArguments = arguments
        app.launchJoesProxyForTesting()
        return app
    }

    @MainActor
    private func openVisualizationExportSheet(in app: XCUIApplication) {
        let exportMenu = identifiedElement("exportSessionsMenu", in: app)
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 2))
        exportMenu.click()

        let exportVisualizationItem = app.menuItems["exportVisualizationMenuItem"].firstMatch
        let exportVisualizationTitle = app.menuItems["Export Visualization..."].firstMatch
        if exportVisualizationItem.waitForExistence(timeout: 1) {
            exportVisualizationItem.click()
        } else {
            XCTAssertTrue(exportVisualizationTitle.waitForExistence(timeout: 2))
            exportVisualizationTitle.click()
        }
    }

    @MainActor
    private func selectPickerOption(identifier: String, option: String, in app: XCUIApplication) {
        let picker = identifiedElement(identifier, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 2))
        picker.click()

        let menuItem = app.menuItems[option].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2))
        menuItem.click()
    }

    private func identifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return !element.exists
    }
}
