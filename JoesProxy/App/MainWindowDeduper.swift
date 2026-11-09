import AppKit
import Foundation

/// Pure policy for keeping at most one main content window (single-main-window enforcement).
///
/// Concurrency: classification is synchronous and side-effect free. Callers close returned windows
/// on the main actor via AppKit.
enum MainWindowDeduper {
    /// Result of evaluating a window list for duplicate main hosts.
    struct Decision: Equatable, Sendable {
        /// First stamped main window to keep, if any.
        var keepIdentifier: ObjectIdentifier?
        /// Additional stamped main windows — callers should close these.
        var closeIdentifiers: [ObjectIdentifier]
    }

    /// Classifies `windows` without mutating AppKit state (unit-test friendly).
    static func decision(for windows: [NSWindow]) -> Decision {
        let mains = MainWindowLookup.allMainWindows(in: windows)
        guard let keep = mains.first else {
            return Decision(keepIdentifier: nil, closeIdentifiers: [])
        }
        let close = mains.dropFirst().map(ObjectIdentifier.init)
        return Decision(keepIdentifier: ObjectIdentifier(keep), closeIdentifiers: Array(close))
    }

    /// Closes every stamped main window except the first.
    ///
    /// Safe when only one main exists (including `orderOut` menu-bar-only hosts). Never closes an
    /// unstamped window, so utility, supervision, Help, Media Info and editor windows keep their state.
    @MainActor
    @discardableResult
    static func closeDuplicateMainWindows(in windows: [NSWindow] = NSApp.windows) -> Int {
        let mains = MainWindowLookup.allMainWindows(in: windows)
        guard mains.count > 1 else { return 0 }
        var closed = 0
        for window in mains.dropFirst() {
            window.close()
            closed += 1
        }
        return closed
    }
}

/// Main-actor seam so AppKit activation can request the singleton SwiftUI `Window(id:)` when none exists.
@MainActor
enum MainWindowActivation {
    /// Wired from `JoesProxyApp` via `@Environment(\.openWindow)`.
    static var openMainWindowHandler: (() -> Void)?

    /// Opens the singleton main window scene if the handler is installed.
    static func requestOpenMainWindow() {
        openMainWindowHandler?()
    }

    /// Brings JoesProxy forward, dedupes stray main windows, and opens the singleton if needed.
    static func activateMainWindow() {
        MenuBarOnlyActivation.ensureRegularActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        _ = MainWindowDeduper.closeDuplicateMainWindows()
        if let main = MainWindowLookup.firstMainWindow() {
            main.makeKeyAndOrderFront(nil)
            return
        }
        requestOpenMainWindow()
        DispatchQueue.main.async {
            MainWindowLookup.firstMainWindow()?.makeKeyAndOrderFront(nil)
        }
    }
}
