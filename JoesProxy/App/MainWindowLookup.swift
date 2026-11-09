import AppKit
import Foundation

/// Stable SwiftUI scene id and AppKit identifier for the singleton main content window.
enum JoesProxyMainWindowID {
    static let rawValue = "main"

    /// AppKit identifier stamped onto the main `NSWindow` by ``MainWindowConfigurator``.
    static var userInterfaceItemIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(rawValue)
    }
}

/// Locates the primary JoesProxy content window among `NSApp.windows`.
///
/// Only a window carrying the stamped ``JoesProxyMainWindowID`` qualifies. Auxiliary scenes
/// (utility windows, agent supervision, Help, Media Info, Traffic Modifications, Settings and file
/// viewers) are ordinary titled `NSWindow`s, some change their title with content, and new ones are
/// added over time — so an exclusion list cannot stay complete. Callers close, hide, resize or front
/// the result; none of those may ever act on a window that is not positively the main host.
enum MainWindowLookup {
    /// Whether `window` carries the stamped singleton main-window identifier.
    static func hasMainWindowIdentifier(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == JoesProxyMainWindowID.rawValue
    }

    /// Whether `window` is the main content window (stamped, never a panel).
    static func isMainWindow(_ window: NSWindow) -> Bool {
        hasMainWindowIdentifier(window) && !(window is NSPanel)
    }

    /// First stamped main window, or `nil` when the main window is closed or not yet created.
    static func firstMainWindow(in windows: [NSWindow] = NSApp.windows) -> NSWindow? {
        allMainWindows(in: windows).first
    }

    /// Every stamped main window, in `windows` order (more than one only for dedupe).
    static func allMainWindows(in windows: [NSWindow] = NSApp.windows) -> [NSWindow] {
        windows.filter(isMainWindow)
    }
}
