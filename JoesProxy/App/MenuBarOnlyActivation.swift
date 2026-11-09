//
//  MenuBarOnlyActivation.swift
//  JoesProxy
//
/// Applies ``NSApplication.ActivationPolicy`` for the “Run in menu bar only” preference (AO Axis 1).
///
/// When enabled, JoesProxy runs as ``.accessory`` (no Dock icon). ``Open JoesProxy`` and approval
/// flows call ``ensureRegularActivationPolicy()`` so a main window can appear.
///

import AppKit

/// Main-actor helpers for menu-bar-only (accessory) vs normal (regular) activation policy.
@MainActor
enum MenuBarOnlyActivation {
    /// Switches between Dock-hidden accessory mode and a normal app presence.
    ///
    /// Concurrency: call from the main actor only (`NSApp` AppKit API).
    static func applyPreferredPolicy(isMenuBarOnly: Bool) {
        let policy: NSApplication.ActivationPolicy = isMenuBarOnly ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    /// Restores a Dock-visible app so sheets and the main window can receive key focus.
    static func ensureRegularActivationPolicy() {
        applyPreferredPolicy(isMenuBarOnly: false)
    }

    /// Hides main session windows after an accessory launch (MenuBarExtra remains available).
    static func hideMainWindowsForAccessoryLaunch() {
        for window in NSApp.windows where MainWindowLookup.isMainWindow(window) {
            window.orderOut(nil)
        }
    }
}
