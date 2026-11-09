//
//  JoesProxyUITests.swift
//  JoesProxyUITests
//
//  Created by Joseph McCraw on 11/5/24.
//
// NOTE — macOS UI test isolation
// Unlike iOS/tvOS tests that run inside a fresh simulator process, macOS XCUITest drives
// the real app on the host machine with no sandbox isolation from the rest of the OS.
// This means individual tests can fail spuriously for reasons that have nothing to do
// with the code under test:
//
//   • System notifications, permission dialogs, Spotlight, or other apps stealing window
//     focus mid-test can cause waitForExistence timeouts or missed element interactions.
//   • Background OS activity (iCloud sync, Spotlight indexing, Time Machine, software
//     updates) can add enough CPU/disk pressure to trip timing-sensitive assertions.
//   • Keychain access prompts or security alerts (Touch ID, password dialog) block the
//     app's event loop entirely while the prompt is on screen.
//   • Screen-saver or display-sleep activation interrupts accessibility element queries.
//   • If another window overlaps the app, click coordinates may land on the wrong target.
//
// Before concluding that a UI test failure is caused by a code regression, re-run the
// suite on a quiet machine (notifications silenced, Do Not Disturb on, no other heavy
// processes running). If a test passes on the second run without code changes, treat the
// first failure as environmental noise, not a real bug.
//
// Performance tests (XCTClockMetric / XCTApplicationLaunchMetric) are especially
// sensitive — a single background process spike can double measured wall-clock time.

import XCTest

final class JoesProxyUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        throw XCTSkip("Xcode template placeholder; excluded from JoesProxy-UI and JoesProxy-Smoke.")
    }

    @MainActor
    func testLaunchPerformance() throws {
        throw XCTSkip("Xcode template launch-performance placeholder; excluded from JoesProxy-UI and JoesProxy-Smoke.")
    }
}
