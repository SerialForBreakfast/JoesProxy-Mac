//
//  AppDelegate.swift
//  JoesProxy
//
//  AppKit application delegate that intercepts the quit lifecycle to warn the user
//  when captured sessions would be lost. Wired into SwiftUI via @NSApplicationDelegateAdaptor.
//

import AppKit

/// AppKit delegate for quit-confirmation and other lifecycle events.
///
/// `applicationShouldTerminate(_:)` runs on the main thread. The `hasUnsavedSessions`
/// closure is set by `JoesProxyApp` immediately after coordinator initialisation and
/// is also safe to call from the main thread.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    enum QuitPreservationDecision {
        case saveRecording
        case quitWithoutSaving
        case cancel
    }

    struct QuitPreservationAlertResult {
        let decision: QuitPreservationDecision
        let suppressFutureWarnings: Bool
    }

    // MARK: - Configuration

    /// Injected by `JoesProxyApp`. Returns `true` when the session store is non-empty.
    var hasUnsavedSessions: (() -> Bool)?
    /// Injected by `JoesProxyApp`. Returns `true` when quit should warn before losing sessions.
    var shouldWarnBeforeQuit: (() -> Bool)?
    /// Injected by `JoesProxyApp`. Persists the user's quit-warning preference.
    var setShouldWarnBeforeQuit: ((Bool) -> Void)?
    /// Injected by `JoesProxyApp`. Presents the recording save flow and returns whether save succeeded.
    var saveRecordingBeforeQuit: (() -> Bool)?
    /// Test seam for unit tests; production uses `presentQuitPreservationAlert()`.
    var presentQuitPreservationAlertForTesting: (() -> QuitPreservationAlertResult)?
    /// Injected by `JoesProxyApp`. Synchronously restores the macOS system proxy before the app
    /// exits so a managed proxy is never left pointing at JoesProxy after a graceful quit.
    var cleanUpSystemProxyOnQuit: (() -> Void)?
    /// Injected by `JoesProxyApp`. Synchronously writes a clean shutdown marker for previous-run diagnostics.
    var recordCleanShutdownOnQuit: (() -> Void)?

    // MARK: - NSApplicationDelegate

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shouldWarnBeforeQuit?() == true,
              hasUnsavedSessions?() == true else {
            return .terminateNow
        }

        let result = presentQuitPreservationAlertForTesting?() ?? presentQuitPreservationAlert()
        if result.suppressFutureWarnings {
            setShouldWarnBeforeQuit?(false)
        }

        switch result.decision {
        case .saveRecording:
            return saveRecordingBeforeQuit?() == true ? .terminateNow : .terminateCancel
        case .quitWithoutSaving:
            return .terminateNow
        case .cancel:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Runs on every graceful quit after termination is approved. Restore the system proxy
        // synchronously so it is never left pointing at JoesProxy.
        cleanUpSystemProxyOnQuit?()
        recordCleanShutdownOnQuit?()
    }

    /// Dock click / reopen: front the existing singleton main window instead of creating another.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        _ = MainWindowDeduper.closeDuplicateMainWindows()
        if let main = MainWindowLookup.firstMainWindow() {
            MenuBarOnlyActivation.ensureRegularActivationPolicy()
            main.makeKeyAndOrderFront(nil)
            return true
        }
        MainWindowActivation.requestOpenMainWindow()
        return true
    }

    // MARK: - Private helpers

    private func presentQuitPreservationAlert() -> QuitPreservationAlertResult {
        let alert = NSAlert()
        alert.messageText = "Quit JoesProxy?"
        alert.informativeText = "Captured sessions are stored in memory until you save a recording. Save before quitting if you want to preserve them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save Recording...")
        alert.addButton(withTitle: "Quit Without Saving")
        alert.addButton(withTitle: "Cancel")

        let checkbox = NSButton(checkboxWithTitle: "Don't show this again", target: nil, action: nil)
        checkbox.state = .off
        alert.accessoryView = checkbox

        let response = alert.runModal()

        let decision: QuitPreservationDecision
        switch response {
        case .alertFirstButtonReturn:
            decision = .saveRecording
        case .alertSecondButtonReturn:
            decision = .quitWithoutSaving
        default:
            decision = .cancel
        }

        return QuitPreservationAlertResult(
            decision: decision,
            suppressFutureWarnings: checkbox.state == .on
        )
    }
}
