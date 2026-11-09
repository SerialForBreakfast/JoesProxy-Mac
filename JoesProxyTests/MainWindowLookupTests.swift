import AppKit
import XCTest
@testable import JoesProxy

/// Business policy for main-window selection: only the stamped ``JoesProxyMainWindowID`` window is
/// ever treated as the main host. Callers close, hide, resize (Compact) and front the result, so an
/// auxiliary window must never qualify — including when the main window is closed.
@MainActor
final class MainWindowLookupTests: XCTestCase {
    func testOnlyStampedWindowIsMain() {
        let stamped = makeWindow(title: "JoesProxy", identifier: JoesProxyMainWindowID.rawValue)
        let untitledCopy = makeWindow(title: "JoesProxy", identifier: nil)

        XCTAssertTrue(MainWindowLookup.isMainWindow(stamped))
        XCTAssertFalse(MainWindowLookup.isMainWindow(untitledCopy), "A matching title is not positive identification")
    }

    func testExcludesNSPanelFromMainLookup() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "JoesProxy"
        panel.identifier = JoesProxyMainWindowID.userInterfaceItemIdentifier
        XCTAssertFalse(MainWindowLookup.isMainWindow(panel))
    }

    func testStampedMainWinsOverEveryAuxiliaryScene() {
        let auxiliaries = auxiliaryWindows()
        let main = makeWindow(title: "JoesProxy", identifier: JoesProxyMainWindowID.rawValue)

        XCTAssertTrue(MainWindowLookup.firstMainWindow(in: auxiliaries + [main]) === main)
        XCTAssertEqual(
            MainWindowLookup.allMainWindows(in: auxiliaries + [main]).map(ObjectIdentifier.init),
            [ObjectIdentifier(main)]
        )
    }

    /// Dock reopen, main-window activation and Compact sizing all consult this lookup. With the main
    /// window closed, none of them may pick a utility or supervision window in its place.
    func testNoWindowQualifiesWhenMainIsClosedAndAuxiliariesRemainOpen() {
        let auxiliaries = auxiliaryWindows()
        XCTAssertNil(MainWindowLookup.firstMainWindow(in: auxiliaries))
        XCTAssertTrue(MainWindowLookup.allMainWindows(in: auxiliaries).isEmpty)
    }

    /// MCP Management titles its window with the selected section, so title matching cannot identify it.
    func testManagementIsNeverMainWhateverItsCurrentSectionTitle() {
        let management = makeWindow(title: "Overview", identifier: UtilityWindowKind.mcpManagement.rawValue)
        XCTAssertFalse(MainWindowLookup.isMainWindow(management))
        management.title = "Clients"
        XCTAssertFalse(MainWindowLookup.isMainWindow(management))
        management.identifier = nil
        XCTAssertFalse(MainWindowLookup.isMainWindow(management), "Unstamped windows never qualify")
    }

    func testWindowConfigurationReceivesAttachmentWithoutAnotherSwiftUIUpdate() {
        let window = makeWindow(title: "JoesProxy", identifier: nil)
        let attachment = MainWindowConfigurator.WindowAttachmentView()
        var attachedWindow: NSWindow?
        attachment.didAttach = { attachedWindow = $0 }
        XCTAssertNil(attachment.window)
        window.contentView = attachment
        XCTAssertTrue(attachedWindow === window)
        window.contentView = nil
    }

    /// Representative auxiliary scenes as AppKit sees them: scene identifiers and their titles.
    private func auxiliaryWindows() -> [NSWindow] {
        [
            makeWindow(title: "About JoesProxy", identifier: UtilityWindowKind.about.rawValue),
            makeWindow(title: "Overview", identifier: UtilityWindowKind.mcpManagement.rawValue),
            makeWindow(title: "MCP Approvals", identifier: UtilityWindowKind.approvals.rawValue),
            makeWindow(title: "Traffic Modifications", identifier: TrafficModificationsWindowView.windowID),
            makeWindow(title: "Current Screen Help", identifier: "contextual-help"),
            makeWindow(title: "Media Info", identifier: "media-info"),
            makeWindow(title: "Agent Approvals", identifier: "agent-approvals"),
            makeWindow(title: "response.json", identifier: nil)
        ]
    }

    private func makeWindow(title: String, identifier: String?) -> NSWindow {
        let window = MainEligibleTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        window.isReleasedWhenClosed = false
        return window
    }
}

/// Tests eligibility policy without ordering real windows onto the user's desktop.
private final class MainEligibleTestWindow: NSWindow {
    override var canBecomeMain: Bool { true }
}
