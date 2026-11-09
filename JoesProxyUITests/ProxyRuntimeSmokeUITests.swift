import Foundation
import XCTest

final class ProxyRuntimeSmokeUITests: XCTestCase {
    private static let proxyPort: UInt16 = 19091

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Starts the proxy, waits until runtime is `running`, then captures one HTTP GET via curl.
    ///
    /// HTTP only (`http://example.com/`). Concurrency: `@MainActor` XCTest; curl is a blocking
    /// helper run after the app reports running.
    @MainActor
    func testStartProxyAndCaptureSessionFromCurl() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-browser-mode=table",
            "--ui-test-proxy-port=\(Self.proxyPort)"
        ]
        app.launchJoesProxyForTesting()

        XCTAssertFalse(
            app.identifiedElement("compactMonitorRoot").exists,
            "HTTP capture smoke must run in Full Inspector, not Compact Mode."
        )

        let proxyToggleButton = app.identifiedElement("proxyToggleButton")
        XCTAssertTrue(
            proxyToggleButton.waitForExistence(timeout: 8),
            "Full Inspector proxy toggle should exist before starting capture."
        )
        proxyToggleButton.click()
        app.waitUntilProxyRuntimeIsRunning()

        let curlResult = try ProxyHTTPCaptureHelper.curlGET(
            url: "http://example.com/",
            proxyPort: Self.proxyPort
        )
        XCTAssertEqual(
            curlResult.exitCode,
            0,
            "curl failed with output: \(curlResult.output)"
        )

        XCTAssertTrue(
            app.textFields["sessionSearchField"].waitForExistence(timeout: 5),
            "Full Inspector session search field should exist (session table chrome)."
        )

        let hostLabel = app.staticTexts["example.com"]
        XCTAssertTrue(
            hostLabel.waitForExistence(timeout: 20),
            "Captured HTTP host should appear after curl through the proxy."
        )
    }
}
