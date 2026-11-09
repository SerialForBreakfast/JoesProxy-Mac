//
//  WindowConfiguration.swift
//  JoesProxy
//
//  Configures app windows so the first launch starts at a usable size while later
//  launches honor the user's previously autosaved frame.
//

import AppKit
import SwiftUI

#if !AGW4_AGENT_TARGET
private let defaultWindowConfigurationIsTestLaunch = UITestLaunchConfiguration.current != nil || ScreenshotDemoSessions.isEnabled
#else
private let defaultWindowConfigurationIsTestLaunch = false
#endif

private enum WindowConfigKeys {
    static let frameAutosaveName = "JoesProxyMainWindow"
    static let mediaInfoFrameAutosaveName = "JoesProxyMediaInfoWindow"
}

/// Explicit screenshot-fixture placement avoids cross-display coordinate ambiguity in XCTest.
/// Never restores or persists a frame; normal launches and other UI fixtures are unchanged.
struct UITestPrimaryScreenWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = MainWindowConfigurator.WindowAttachmentView()
        if defaultWindowConfigurationIsTestLaunch,
           ProcessInfo.processInfo.arguments.contains("--ui-test-primary-screen") {
            view.didAttach = { window in
                DispatchQueue.main.async {
                    guard let screen = NSScreen.screens.first else { return }
                    let visible = screen.visibleFrame
                    let size = window.frame.size
                    window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                                  y: visible.midY - size.height / 2))
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Zero-size view that configures its enclosing NSWindow on appear.
/// - Note: Applies frame autosave for UserDefaults persistence. On the first launch only,
///   the window is expanded to a large centered size based on the current screen. Once
///   autosave exists, the user's chosen frame wins on later launches.
struct MainWindowConfigurator: NSViewRepresentable {
    let compactModeController: CompactModeController
    private let isTestLaunch: Bool

    init(
        compactModeController: CompactModeController,
        isTestLaunch: Bool = defaultWindowConfigurationIsTestLaunch
    ) {
        self.compactModeController = compactModeController
        self.isTestLaunch = isTestLaunch
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachmentView()
        view.didAttach = { [weak coordinator = context.coordinator] window in
            guard let coordinator else { return }
            scheduleConfiguration(window, coordinator: coordinator)
        }
        view.widthAnchor.constraint(equalToConstant: 0).isActive = true
        view.heightAnchor.constraint(equalToConstant: 0).isActive = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        scheduleConfiguration(window, coordinator: context.coordinator)
    }

    private func scheduleConfiguration(_ window: NSWindow, coordinator: Coordinator) {
        guard !coordinator.hasScheduledInitialConfiguration else { return }
        coordinator.hasScheduledInitialConfiguration = true
        DispatchQueue.main.async {
            configureWindow(window, coordinator: coordinator)
        }
    }

    final class WindowAttachmentView: NSView {
        var didAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { didAttach?(window) }
        }
    }

    func configureWindow(_ window: NSWindow, coordinator: Coordinator) {
        guard !coordinator.hasConfiguredInitialFrame else { return }
        // One owner establishes the workspace frame before Compact takes ownership. Separate
        // representables race at attachment and can enlarge the HUD after its first sizing pass.
        defer { compactModeController.attach(window: window) }
        window.identifier = JoesProxyMainWindowID.userInterfaceItemIdentifier
        if isTestLaunch {
            guard !coordinator.hasConfiguredInitialFrame else { return }
            coordinator.hasConfiguredInitialFrame = true
            // App-owned autosave is independent of system window restoration. Seeded tests
            // must neither restore nor overwrite the user's compact/full-workspace frame.
            // A screen-relative 1200pt frame falls into Focused mode at accessibility text
            // sizes. Baseline seeded workflows require a deterministic two-pane composition.
            // CompactModeController still owns the HUD's independent size constraints.
            window.setContentSize(NSSize(width: 1440, height: 900))
            window.center()
            return
        }
        window.setFrameAutosaveName(WindowConfigKeys.frameAutosaveName)
        _ = MainWindowDeduper.closeDuplicateMainWindows()

        guard !coordinator.hasConfiguredInitialFrame else { return }
        coordinator.hasConfiguredInitialFrame = true

        // Respect an autosaved frame once the user has manually resized or repositioned the window.
        guard UserDefaults.standard.string(forKey: "NSWindow Frame " + WindowConfigKeys.frameAutosaveName).map({ !$0.isEmpty }) != true else {
            return
        }

        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let desiredFrame = desiredInitialFrame(in: visibleFrame)
        window.setFrame(desiredFrame, display: true)
        window.center()
    }

    final class Coordinator {
        var hasScheduledInitialConfiguration = false
        var hasConfiguredInitialFrame = false
    }

    private func desiredInitialFrame(in visibleFrame: NSRect?) -> NSRect {
        guard let visibleFrame else {
            return NSRect(x: 0, y: 0, width: 1440, height: 900)
        }

        let width = min(max(visibleFrame.width * 0.84, 1200), 1600)
        let height = min(max(visibleFrame.height * 0.84, 760), 1100)
        let originX = visibleFrame.origin.x + (visibleFrame.width - width) / 2
        let originY = visibleFrame.origin.y + (visibleFrame.height - height) / 2
        return NSRect(x: originX, y: originY, width: width, height: height)
    }
}

/// Zero-size view that configures the media info window for a larger, resizable inspector experience.
struct MediaInfoWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: 0).isActive = true
        view.heightAnchor.constraint(equalToConstant: 0).isActive = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        configureWindow(window, coordinator: context.coordinator)
    }

    private func configureWindow(_ window: NSWindow, coordinator: Coordinator) {
        window.setFrameAutosaveName(WindowConfigKeys.mediaInfoFrameAutosaveName)
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 760, height: 560)

        guard !coordinator.hasConfiguredInitialSize else { return }
        coordinator.hasConfiguredInitialSize = true

        let desiredSize = NSSize(width: 980, height: 720)
        if window.frame.size.width < desiredSize.width || window.frame.size.height < desiredSize.height {
            window.setContentSize(desiredSize)
        }
    }

    final class Coordinator {
        var hasConfiguredInitialSize = false
    }
}

/// Policy for making a presented workspace sheet's host `NSWindow` user-resizable.
///
/// - Important: Preserves the caller's minimum content size and does not alter fullscreen or
///   window-collection behavior. Compact alerts and one-purpose dialogs should not use this policy.
enum ResizableSheetWindowPolicy {
    /// Resolved AppKit knobs for a resizable workspace sheet.
    struct Configuration: Equatable {
        /// Style mask after inserting `.resizable`.
        let styleMask: NSWindow.StyleMask
        /// Content-derived minimum size the sheet must retain.
        let minSize: NSSize
    }

    /// Computes the style mask and minimum size without mutating a live window.
    ///
    /// - Parameters:
    ///   - existingStyleMask: The sheet host's current style mask.
    ///   - minSize: Content-derived minimum size that AppKit must honor while resizing.
    /// - Returns: Configuration values for ``configure(_:minSize:)`` to apply.
    static func configuration(
        from existingStyleMask: NSWindow.StyleMask,
        minSize: NSSize
    ) -> Configuration {
        var styleMask = existingStyleMask
        styleMask.insert(.resizable)
        return Configuration(styleMask: styleMask, minSize: minSize)
    }

    /// Inserts `.resizable` and applies `minSize` on `window` without changing collection behavior.
    ///
    /// - Parameters:
    ///   - window: The sheet or panel hosting SwiftUI content.
    ///   - minSize: Content-derived minimum size that AppKit must honor while resizing.
    static func configure(_ window: NSWindow, minSize: NSSize) {
        let resolved = configuration(from: window.styleMask, minSize: minSize)
        window.styleMask = resolved.styleMask
        window.minSize = resolved.minSize
    }
}

/// Zero-size view that makes its enclosing sheet window resizable while preserving a minimum size.
///
/// Attach via ``View/joesProxyResizableWorkspaceSheet(minWidth:minHeight:)`` on major workspace
/// sheets (MCP Management, Guided Setup, Help Hub, Find, overrides, and similar). Configuration
/// may run asynchronously on the main queue because the sheet's `NSWindow` is often unavailable
/// on the first `updateNSView` pass.
struct ResizableSheetWindowConfigurator: NSViewRepresentable {
    /// Minimum width the sheet must retain while the user resizes.
    let minWidth: CGFloat
    /// Minimum height the sheet must retain while the user resizes.
    let minHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: 0).isActive = true
        view.heightAnchor.constraint(equalToConstant: 0).isActive = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            ResizableSheetWindowPolicy.configure(
                window,
                minSize: NSSize(width: minWidth, height: minHeight)
            )
            return
        }

        guard !context.coordinator.hasScheduledConfiguration else { return }
        context.coordinator.hasScheduledConfiguration = true
        DispatchQueue.main.async {
            guard let window = nsView.window else {
                context.coordinator.hasScheduledConfiguration = false
                return
            }
            ResizableSheetWindowPolicy.configure(
                window,
                minSize: NSSize(width: minWidth, height: minHeight)
            )
        }
    }

    final class Coordinator {
        /// Tracks whether an async configuration pass has already been scheduled.
        var hasScheduledConfiguration = false
    }
}

extension View {
    /// Makes a major workspace sheet's host window resizable while keeping the existing minimum size.
    ///
    /// - Parameters:
    ///   - minWidth: Minimum width already declared by the sheet's SwiftUI frame.
    ///   - minHeight: Minimum height already declared by the sheet's SwiftUI frame.
    /// - Returns: The view with an AppKit-backed sheet window configurator in the background.
    ///
    /// Concurrency: configuration hops to the main queue when the sheet window is not yet attached;
    /// callers remain `@MainActor` SwiftUI views.
    func joesProxyResizableWorkspaceSheet(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        background(
            ResizableSheetWindowConfigurator(minWidth: minWidth, minHeight: minHeight)
        )
    }
}
