import AppKit
import XCTest
@testable import JoesProxy

/// Single-main-window dedupe policy: keep one main host, never close auxiliaries.
@MainActor
final class MainWindowDeduperTests: XCTestCase {
    func testDecisionKeepsFirstMainAndClosesExtras() {
        let keep = makeWindow(title: "JoesProxy", identifier: JoesProxyMainWindowID.rawValue)
        let duplicate = makeWindow(title: "JoesProxy", identifier: JoesProxyMainWindowID.rawValue)
        let help = makeWindow(title: "Current Screen Help", identifier: "contextual-help")
        let media = makeWindow(title: "Media Info", identifier: "media-info")

        let decision = MainWindowDeduper.decision(for: [help, keep, media, duplicate])
        XCTAssertEqual(decision.keepIdentifier, ObjectIdentifier(keep))
        XCTAssertEqual(decision.closeIdentifiers, [ObjectIdentifier(duplicate)])
    }

    func testDecisionDoesNotCloseAuxiliariesAlone() {
        let help = makeWindow(title: "Current Screen Help", identifier: "contextual-help")
        let media = makeWindow(title: "Media Info", identifier: "media-info")
        let decision = MainWindowDeduper.decision(for: [help, media])
        XCTAssertNil(decision.keepIdentifier)
        XCTAssertTrue(decision.closeIdentifiers.isEmpty)
    }

    func testCloseDuplicateMainWindowsLeavesSingleStampedMain() {
        let keep = makeWindow(title: "JoesProxy", identifier: JoesProxyMainWindowID.rawValue)
        let duplicate = makeWindow(title: "JoesProxy", identifier: JoesProxyMainWindowID.rawValue)
        keep.isReleasedWhenClosed = false
        duplicate.isReleasedWhenClosed = false
        let closed = MainWindowDeduper.closeDuplicateMainWindows(in: [keep, duplicate])
        XCTAssertEqual(closed, 1)
        XCTAssertTrue(MainWindowLookup.firstMainWindow(in: [keep]) === keep)
    }

    /// Dock reopen with the main window closed previously treated Management and Approvals as
    /// duplicate "mains", closing Approvals and fronting Management instead of reopening the main.
    func testNeverClosesUtilityWindowsWhenMainIsClosed() {
        let management = makeWindow(title: "Overview", identifier: UtilityWindowKind.mcpManagement.rawValue)
        let approvals = makeWindow(title: "MCP Approvals", identifier: UtilityWindowKind.approvals.rawValue)

        XCTAssertNil(MainWindowDeduper.decision(for: [management, approvals]).keepIdentifier)
        XCTAssertEqual(MainWindowDeduper.closeDuplicateMainWindows(in: [management, approvals]), 0)
    }

    func testDoesNotCloseUnstampedWindowBesideStampedMain() {
        let main = makeWindow(title: "JoesProxy", identifier: JoesProxyMainWindowID.rawValue)
        let viewer = makeWindow(title: "JoesProxy", identifier: "json-viewer")

        let decision = MainWindowDeduper.decision(for: [main, viewer])
        XCTAssertEqual(decision.keepIdentifier, ObjectIdentifier(main))
        XCTAssertTrue(decision.closeIdentifiers.isEmpty)
    }

    func testSingleMainDoesNotClose() {
        let only = makeWindow(title: "JoesProxy", identifier: JoesProxyMainWindowID.rawValue)
        let closed = MainWindowDeduper.closeDuplicateMainWindows(in: [only])
        XCTAssertEqual(closed, 0)
    }

    private func makeWindow(title: String, identifier: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        return window
    }
}
