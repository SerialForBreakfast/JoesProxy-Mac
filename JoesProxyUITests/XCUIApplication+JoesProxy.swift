import Darwin
import Foundation
import XCTest

final class HostUITestLease {
    static let shared = HostUITestLease()

    let failureMessage: String?
    private var descriptor: Int32 = -1

    init(
        leaseURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.joesproxy.host-ui-test.lock", isDirectory: false)
    ) {
        let openedDescriptor = open(leaseURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard openedDescriptor >= 0 else {
            failureMessage = "Host UI test infrastructure could not open its per-login-session lease."
            return
        }
        guard flock(openedDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            failureMessage = "Host UI test infrastructure contention: another UI runner owns this Mac login session."
            close(openedDescriptor)
            return
        }
        descriptor = openedDescriptor
        failureMessage = nil
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}

extension XCUIApplication {
    /// Launches without inheriting the developer machine's saved macOS window state or recovery
    /// prompts. macOS UI tests run against the host account, so both otherwise leak across runs.
    ///
    /// - Parameter suppressLaunchRecovery: When `true` (default), injects
    ///   `--ui-test-suppress-launch-recovery` so real Application Support snapshots cannot appear.
    ///   BA-2 injects an in-memory restore fixture instead of turning this off.
    func launchJoesProxyForTesting(
        suppressLaunchRecovery: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let failureMessage = HostUITestLease.shared.failureMessage {
            XCTFail(failureMessage, file: file, line: line)
            return
        }
        guard let artifactRoot = ProcessInfo.processInfo.environment["JOESPROXY_UI_ARTIFACT_DIRECTORY"] else {
            XCTFail("UI tests require the serial host wrapper's artifact directory; user storage is not a fallback.", file: file, line: line)
            return
        }
        launchEnvironment["JOESPROXY_UI_ARTIFACT_DIRECTORY"] = artifactRoot
        var isolationArguments = [
            "-ApplePersistenceIgnoreState",
            "YES"
        ]
        if suppressLaunchRecovery {
            isolationArguments.append("--ui-test-suppress-launch-recovery")
        }
        launchArguments.insert(contentsOf: isolationArguments, at: 0)
        launch()
    }

    /// First descendant matching the accessibility identifier, including non-button containers.
    func identifiedElement(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Responsive browser navigation can be a segmented picker or a labeled menu.
    func selectSessionBrowser(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let header = identifiedElement("browserPaneHeader")
        guard header.waitForExistence(timeout: 3) else {
            XCTFail("Browser navigation header unavailable", file: file, line: line)
            return
        }
        let menu = header.descendants(matching: .any).matching(identifier: "sessionBrowserMenuCompact").firstMatch
        if menu.exists && menu.isHittable {
            menu.click()
            let item = menuItems[title]
            guard item.waitForExistence(timeout: 3) else {
                XCTFail("Browser menu option \(title) unavailable", file: file, line: line)
                return
            }
            item.click()
        } else {
            let picker = header.descendants(matching: .any).matching(identifier: "sessionBrowserPicker").firstMatch
            let option = picker.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", title)).firstMatch
            guard option.waitForExistence(timeout: 3) else {
                XCTFail("Browser picker option \(title) unavailable", file: file, line: line)
                return
            }
            option.click()
        }
    }

    /// Waits until the proxy toggle reports runtime value `running` (or Stop-proxy copy as fallback).
    ///
    /// Concurrency: XCTest waiter on the test's MainActor; the app under test publishes the value
    /// from its own MainActor runtime.
    func waitUntilProxyRuntimeIsRunning(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = identifiedElement("proxyToggleButton")
        let predicate = NSPredicate(
            format: "value == %@ OR label == %@",
            "running",
            "Stop proxy"
        )
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: button)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Proxy did not reach running state within \(timeout)s",
            file: file,
            line: line
        )
    }
}
