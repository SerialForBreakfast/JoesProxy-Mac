import Foundation
import XCTest

/// Public first-run acceptance through the app's ordinary toolbar and inspector.
/// Uses the UI lane, with a one-shot loopback origin matching GETTING-STARTED.
final class PublicPreviewWalkthroughUITests: XCTestCase {
    @MainActor
    func testSyntheticHTTPStartInspectAndStop() throws {
        continueAfterFailure = false
        let body = #"{"items":[{"state":"ready"}]}"#
        let origin = Process()
        let input = Pipe()
        origin.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        origin.arguments = ["-l", "127.0.0.1", "28088"]
        origin.standardInput = input
        origin.standardOutput = FileHandle.nullDevice
        origin.standardError = FileHandle.nullDevice
        try origin.run()
        defer {
            if origin.isRunning { origin.terminate() }
            origin.waitUntilExit()
        }
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        try input.fileHandleForWriting.write(contentsOf: Data(response.utf8))
        try input.fileHandleForWriting.close()

        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-browser-mode=table", "--ui-test-proxy-port=19091", "--ui-test-primary-screen"]
        app.launchJoesProxyForTesting()
        defer { app.terminate() }
        let toggle = app.identifiedElement("proxyToggleButton")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(origin.isRunning, "Synthetic origin could not listen on port 28088.")
        toggle.click()
        app.waitUntilProxyRuntimeIsRunning()

        let result = try ProxyHTTPCaptureHelper.curlGET(url: "http://127.0.0.1:28088/items",
            proxyPort: 19091, includeBody: true)
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(result.output, body)
        let row = app.staticTexts["/items"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The real loopback request must appear in the capture table.")
        XCTAssertTrue(app.staticTexts["200"].firstMatch.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(app.staticTexts["Response Body"].firstMatch.waitForExistence(timeout: 5))
        let raw = app.radioButtons["Raw"].firstMatch
        if raw.exists { raw.click() } else { app.buttons["Raw"].firstMatch.click() }
        let capturedBody = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", #""state":"ready""#, #""state":"ready""#)
        ).firstMatch
        XCTAssertTrue(capturedBody.waitForExistence(timeout: 5), "The inspector must expose the captured JSON body.")
        toggle.click()
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", "Start proxy", "stopped"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed)
        let receipt = XCTAttachment(string: "Synthetic loopback HTTP: Start, captured /items with status 200, inspected exact JSON body, Stop. Body: \(body)")
        receipt.name = "Public preview synthetic HTTP acceptance"
        receipt.lifetime = .keepAlways
        add(receipt)
    }
}
