import AppKit
import Combine
import SwiftUI

/// Owns the "compact mode" toggle for the main JoesProxy window. This is the compact-mode host the
/// ADR's content/host separation (§2) anticipated: it reuses `MinimalMonitoringViewModel`/
/// `MinimalMonitoringView` completely unmodified, just hosted differently — as a temporary swap of
/// the main window's own content instead of a second window.
///
/// While compact, the main `WindowGroup`'s content branch renders only `MinimalMonitoringView` —
/// `ContentView` (session table, timeline, explorer, etc.) is not constructed at all, so none of
/// its heavier view models or windowing machinery run until the user switches back.
@MainActor
final class CompactModeController: ObservableObject {
    @Published private(set) var isCompactModeActive: Bool
    /// True for a brief moment while exiting compact mode, before `ContentView` is remounted —
    /// lets the caller show a spinner instead of a blank/frozen window while the heavier view
    /// hierarchy builds back up.
    @Published private(set) var isRestoringFullView = false
    /// Independent of compact/full mode — whether the window floats above other apps' windows.
    /// This is the "stays visible while working elsewhere" behavior from the original standalone-
    /// panel design, now an explicit opt-in toggle that applies regardless of which content the
    /// window currently shows.
    @Published private(set) var isPinnedToForeground = false

    let monitoringViewModel: MinimalMonitoringViewModel
    private let configuration: AppConfiguration

    private weak var mainWindow: NSWindow?
    private var priorFrame: NSRect?
    private var priorMinSize: NSSize?
    private var priorMaxSize: NSSize?
    private var measuredCompactContentSize: NSSize?
    private var hasPendingMeasuredResize = false
    /// Observe actual window resizing, never telemetry refreshes. Corrections are deferred out
    /// of AppKit's layout notification and coalesced with content measurement changes.
    private var frameReassertionCancellable: AnyCancellable?

    /// Used only until the real content size is measured via `recordMeasuredContentSize`, on the
    /// very first compact-mode entry in a session. Deliberately close to the tile grid's actual
    /// rendered size (2 columns of fixed 130pt tiles + spacing/padding + the controls row) rather
    /// than a round-number guess — the closer this is, the smaller (and less noticeable) any
    /// later correction has to be.
    private static let fallbackCompactContentSize = NSSize(width: 294, height: 320)

    private let onInspectorPresentationChanged: (Bool) -> Void

    init(
        monitoringViewModel: MinimalMonitoringViewModel,
        configuration: AppConfiguration,
        onInspectorPresentationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.monitoringViewModel = monitoringViewModel
        self.configuration = configuration
        self.onInspectorPresentationChanged = onInspectorPresentationChanged
        // `--compact-mode` forces this launch to start compact regardless of the persisted
        // preference — deliberately not persisted itself, so an agent/automated launch never
        // silently changes what a human's own next normal launch shows.
        let startsCompact = RuntimeDebugFlag.isAgentWorkspaceForced ||
            configuration.launchWorkspacePreference == .agent ||
            RuntimeDebugFlag.isCompactModeForced ||
            configuration.preferredWorkingView == .compact
        self.isCompactModeActive = startsCompact
        // The relay records this state until an Inspector is explicitly constructed, so a cold
        // compact or Agent launch cannot briefly reactivate Inspector-owned work.
        onInspectorPresentationChanged(!startsCompact)
    }

    /// Records the main window so later toggles can resize it. Safe to call more than once —
    /// only the first call takes effect, since the same `NSWindow` backs every content swap.
    func attach(window: NSWindow) {
        guard mainWindow == nil else { return }
        mainWindow = window
        frameReassertionCancellable = NotificationCenter.default.publisher(
            for: NSWindow.didResizeNotification
        ).sink { [weak self] notification in
            guard let self, let resizedWindow = notification.object as? NSWindow,
                  resizedWindow === self.mainWindow else { return }
            self.scheduleCompactFrameCorrection()
        }
        if isCompactModeActive {
            priorFrame = window.frame
            priorMinSize = window.minSize
            priorMaxSize = window.maxSize
            applyCompactFrame(animated: false)
        }
    }

    /// Records the HUD's actual measured content size (reported by `MinimalMonitoringView`'s size
    /// callback) so the window can be sized to fit it exactly rather than an approximate guess.
    func recordMeasuredContentSize(_ size: CGSize) {
        guard let newSize = CompactWindowSizing.acceptedContentSize(
            size, previous: measuredCompactContentSize,
            backingScale: mainWindow?.backingScaleFactor ?? 1
        ) else { return }
        let sizeChanged = measuredCompactContentSize != newSize
        measuredCompactContentSize = newSize
        guard sizeChanged else { return }
        scheduleCompactFrameCorrection()
    }

    private func scheduleCompactFrameCorrection() {
        guard isCompactModeActive, !hasPendingMeasuredResize else { return }
        hasPendingMeasuredResize = true
        // Geometry callbacks run inside SwiftUI layout. Defer and coalesce corrections;
        // animated AppKit resizing here enters a nested run loop during that layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingMeasuredResize = false
            guard self.isCompactModeActive else { return }
            self.applyCompactFrame(animated: false)
        }
    }

    func toggle() {
        if isCompactModeActive {
            exitCompactMode(persistsPreference: true)
        } else {
            enterCompactMode(persistsPreference: true)
        }
    }

    /// Enters Compact and persists it as the preferred working view (BA-3 Connect an Agent).
    func enterCompactWorkingView() {
        enterCompactMode(persistsPreference: true)
    }

    func enterAgentPresentation() {
        enterCompactMode(persistsPreference: false)
    }

    func toggleForegroundPin() {
        isPinnedToForeground.toggle()
        resolvedWindow()?.level = isPinnedToForeground ? .floating : .normal
    }

    /// Runs `action` immediately if the full UI is already showing. Otherwise exits compact mode
    /// first and defers `action` until `ContentView` has actually remounted.
    ///
    /// This matters for two different reasons depending on what `action` does: a
    /// `WorkspaceCommandCenter.post(...)` is a fire-and-forget `NotificationCenter` broadcast — if
    /// nothing is subscribed yet (because `ContentView` isn't mounted), it is simply lost, not
    /// queued. A `presentationState.presentX()` call is durable `@Published` state that
    /// `ContentView`'s sheets would pick up correctly on next mount regardless of timing — but
    /// deferring it the same way costs nothing and keeps every menu command that depends on the
    /// full UI going through one uniform, easy-to-audit path.
    func performRequiringFullView(_ action: @escaping () -> Void) {
        guard isCompactModeActive else {
            action()
            return
        }
        exitCompactMode(persistsPreference: false, then: action)
    }

    private func resolvedWindow() -> NSWindow? {
        if let mainWindow { return mainWindow }
        // Only the stamped main window qualifies: `attach` accepts one window for the session, so
        // latching onto an auxiliary window here would resize it instead of the HUD host.
        // A later `MainWindowConfigurator` attach still applies the Compact frame.
        let fallback = MainWindowLookup.firstMainWindow()
        if let fallback { attach(window: fallback) }
        return fallback
    }

    private func enterCompactMode(persistsPreference: Bool) {
        guard !isCompactModeActive else { return }
        if let window = resolvedWindow() {
            priorFrame = window.frame
            priorMinSize = window.minSize
            priorMaxSize = window.maxSize
        }
        isCompactModeActive = true
        onInspectorPresentationChanged(false)
        if persistsPreference {
            configuration.preferredWorkingView = .compact
        }
        monitoringViewModel.start()
        // Content measurement and resize notifications can arrive during a transition. Do not
        // animate an AppKit frame while those corrections are converging.
        applyCompactFrame(animated: false)
    }

    private func applyCompactFrame(animated: Bool) {
        guard let window = resolvedWindow() else { return }
        let contentSize = measuredCompactContentSize ?? Self.fallbackCompactContentSize
        let targetSize = CompactWindowSizing.frameSize(for: contentSize, in: window)
        // Locking minSize == maxSize == targetSize (not just calling setFrame) is what actually
        // makes this stick: a bare setFrame can be silently overridden by a later layout pass,
        // but the OS itself won't let the window exceed a hard min/max constraint.
        // AppKit constraint setters can themselves cause layout and frame persistence.
        // A refresh with unchanged geometry must not touch either setter.
        if window.minSize != targetSize { window.minSize = targetSize }
        if window.maxSize != targetSize { window.maxSize = targetSize }
        let old = window.frame
        // Anchor the window's top-left corner so it visibly collapses in place rather than
        // jumping to a new position.
        let newOrigin = NSPoint(x: old.origin.x, y: old.maxY - targetSize.height)
        let newFrame = NSRect(origin: newOrigin, size: targetSize)
        guard newFrame != old else { return }
        window.setFrame(newFrame, display: true, animate: animated)
    }

    private func exitCompactMode(
        persistsPreference: Bool,
        then completion: (() -> Void)? = nil
    ) {
        guard isCompactModeActive else {
            completion?()
            return
        }
        monitoringViewModel.stop()
        isCompactModeActive = false
        onInspectorPresentationChanged(true)
        if persistsPreference {
            configuration.preferredWorkingView = .inspector
        }
        isRestoringFullView = true
        if let window = resolvedWindow() {
            // Release the compact-mode size lock before restoring the larger frame — otherwise
            // the still-clamped maxSize would immediately shrink it right back down.
            window.minSize = priorMinSize ?? NSSize(width: 200, height: 200)
            window.maxSize = priorMaxSize ?? NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            if let priorFrame {
                window.setFrame(priorFrame, display: true, animate: true)
            }
        }
        Task { @MainActor [weak self] in
            // One tick is enough for the spinner to actually paint before ContentView's heavier
            // view hierarchy starts building — without this, the swap happens synchronously in
            // the same render pass and the spinner never has a chance to appear.
            try? await Task.sleep(for: .milliseconds(60))
            self?.isRestoringFullView = false
            completion?()
        }
    }
}

/// Main-actor callers retain the accepted size; subpixel layout noise must not resize the HUD.
enum CompactWindowSizing {
    @MainActor
    static func frameSize(for contentSize: CGSize, in window: NSWindow) -> CGSize {
        // Full-size content windows include the titlebar in contentRect, but SwiftUI lays the
        // HUD below it. Reserve the actual unobscured layout insets to avoid competing resizes.
        let layout = window.contentLayoutRect.size
        return CGSize(
            width: contentSize.width + max(0, window.frame.width - layout.width),
            height: contentSize.height + max(0, window.frame.height - layout.height)
        )
    }

    static func acceptedContentSize(
        _ proposed: CGSize, previous: CGSize?, backingScale: CGFloat
    ) -> CGSize? {
        guard proposed.width.isFinite, proposed.height.isFinite,
              proposed.width > 0, proposed.height > 0 else { return nil }
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let pixel = 1 / scale
        func dimension(_ value: CGFloat, previous: CGFloat?) -> CGFloat {
            // Retain a pixel of slack to avoid oscillation around rounding boundaries.
            if let previous, abs(value - previous) < pixel { return previous }
            return (value * scale).rounded(.up) / scale
        }
        return CGSize(
            width: dimension(proposed.width, previous: previous?.width),
            height: dimension(proposed.height, previous: previous?.height)
        )
    }
}
