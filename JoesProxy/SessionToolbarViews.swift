//
//  SessionToolbarViews.swift
//  JoesProxy
//
//  Toolbar-strip components embedded in the main window's toolbar: explorer
//  grouping menus, session-table sort/follow controls, and the clear/export
//  management menus. Also contains PersistentHSplitViewObserver (NSViewRepresentable
//  that tracks and restores the leading-panel split fraction) and ExportScope /
//  ExportAlertContext helpers used by the export flow.
//

import AppKit
import SwiftUI

struct ExplorerToolbarMenusView: View {
    @Binding var grouping: SessionExplorerGrouping
    @Binding var hostGrouping: SessionExplorerHostGrouping

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Group By", selection: $grouping) {
                    ForEach(SessionExplorerGrouping.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } label: {
                Label(grouping.title, systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .help("Choose how the explorer groups captured sessions.")
            .accessibilityLabel("Explorer grouping")
            .accessibilityValue(grouping.title)
            .accessibilityIdentifier("explorerGroupingMenu")

            if grouping == .byHost {
                Menu {
                    Picker("Host Grouping", selection: $hostGrouping) {
                        ForEach(SessionExplorerHostGrouping.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Label(hostGrouping.title, systemImage: "globe")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .help("Choose whether the explorer groups by exact hosts or domain families.")
                .accessibilityLabel("Explorer host grouping")
                .accessibilityValue(hostGrouping.title)
                .accessibilityIdentifier("explorerHostGroupingMenu")
            }
        }
    }
}

struct SessionTableToolbarControlsView: View {
    @Binding var sortField: ProxyViewModel.SessionSortField
    @Binding var isAscending: Bool
    var iconOnly = false

    var body: some View {
        Menu {
            Picker("Sort By", selection: $sortField) {
                ForEach(ProxyViewModel.SessionSortField.allCases, id: \.self) { field in
                    Text(field.title).tag(field)
                }
            }

            Divider()

            Toggle(isOn: $isAscending) {
                Text("Ascending")
            }
        } label: {
            toolbarControlLabel(sortMenuTitle, systemImage: sortMenuIconName)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help("Sort captured sessions by \(sortMenuTitle.lowercased()).")
        .accessibilityLabel("Session sort menu")
        .accessibilityValue(sortMenuTitle)
        .accessibilityIdentifier("sessionSortMenu")
    }

    private var sortMenuTitle: String {
        switch sortField {
        case .startedAt:
            return isAscending ? "Oldest" : "Newest"
        default:
            return "Sort: \(sortField.title)"
        }
    }

    private var sortMenuIconName: String {
        isAscending ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill"
    }

    @ViewBuilder
    private func toolbarControlLabel(_ title: String, systemImage: String) -> some View {
        if iconOnly {
            Image(systemName: systemImage)
        } else {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct SessionFollowToolbarControlsView: View {
    let followState: ProxyViewModel.SessionFollowState
    let hasSessions: Bool
    let setFollowLiveEnabled: (Bool) -> Void
    let jumpToLatest: () -> Void
    var iconOnly = false

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: followLiveBinding) {
                toolbarControlLabel("Follow Live", systemImage: followIconName)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(!hasSessions)
            .help(followHelpText)
            .accessibilityLabel(followState == .followingLive ? "Disable Follow Live" : "Enable Follow Live")
            .accessibilityValue(followState.title)
            .accessibilityIdentifier("followLiveToggle")

            if followState != .followingLive, hasSessions {
                Button {
                    jumpToLatest()
                } label: {
                    toolbarControlLabel("Jump to Latest", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Select the newest visible captured session and resume Follow Live.")
                .accessibilityLabel("Jump to latest session")
                .accessibilityIdentifier("jumpToLatestSessionButton")
            }
        }
    }

    private var followLiveBinding: Binding<Bool> {
        Binding {
            followState == .followingLive
        } set: { isEnabled in
            setFollowLiveEnabled(isEnabled)
        }
    }

    private var followIconName: String {
        switch followState {
        case .staticInspection:
            return "pause.circle"
        case .followingLive:
            return "arrow.down.to.line"
        case .paused:
            return "pause.circle.fill"
        }
    }

    private var followHelpText: String {
        switch followState {
        case .staticInspection:
            return "Follow the newest visible captured session while new traffic arrives."
        case .followingLive:
            return "Following live traffic. Manual inspection pauses Follow Live."
        case .paused:
            return "Follow Live is paused because you started inspecting traffic."
        }
    }

    @ViewBuilder
    private func toolbarControlLabel(_ title: String, systemImage: String) -> some View {
        if iconOnly {
            Image(systemName: systemImage)
        } else {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct SessionManagementMenusView: View {
    let sessionCount: Int
    let hasSelectedSessions: Bool
    let hasSessions: Bool
    let clearSelected: () -> Void
    let clearAll: () -> Void
    let exportSelectedJSON: () -> Void
    let exportAllJSON: () -> Void
    let exportSelectedHAR: () -> Void
    let exportAllHAR: () -> Void
    let exportVisualization: () -> Void
    var iconOnly = false
    @State private var isClearAllConfirmationPresented = false

    var body: some View {
        Group {
            Menu {
                Button("Clear Selected", role: .destructive, action: clearSelected)
                    .disabled(!hasSelectedSessions)

                Button("Clear All", role: .destructive) { isClearAllConfirmationPresented = true }
                    .disabled(!hasSessions)
            } label: {
                toolbarControlLabel("Clear", systemImage: "trash")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .help("Clear selected or all captured sessions.")
            .accessibilityLabel("Clear sessions")
            .accessibilityIdentifier("clearSessionsMenu")
            .confirmationDialog(
                "Clear all captured sessions?",
                isPresented: $isClearAllConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Clear \(sessionCount) Sessions", role: .destructive, action: clearAll)
                Button("Cancel", role: .cancel) {}
            }

            Menu {
                Button("Export Selected as JSON", action: exportSelectedJSON)
                    .disabled(!hasSelectedSessions)

                Button("Export All as JSON", action: exportAllJSON)
                    .disabled(!hasSessions)

                Divider()

                Button("Export Selected as HAR", action: exportSelectedHAR)
                    .disabled(!hasSelectedSessions)

                Button("Export All as HAR", action: exportAllHAR)
                    .disabled(!hasSessions)

                Divider()

                Button("Export Visualization...", action: exportVisualization)
                    .disabled(!hasSessions)
                    .accessibilityIdentifier("exportVisualizationMenuItem")
            } label: {
                toolbarControlLabel("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .help("Exported files may include sensitive headers such as Authorization and Cookie. HAR format works with browser DevTools and other HTTP inspection tools.")
            .accessibilityLabel("Export sessions")
            .accessibilityIdentifier("exportSessionsMenu")
        }
    }

    @ViewBuilder
    private func toolbarControlLabel(_ title: String, systemImage: String) -> some View {
        if iconOnly {
            Image(systemName: systemImage)
        } else {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct ExportAlertContext: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Distinguishes a window/container resize from a genuine user divider drag. See
/// `PersistentHSplitViewObserver.Coordinator.classifyResize`.
enum SplitViewResizeKind: Equatable {
    case containerResize
    case dividerDrag
}

struct PersistentHSplitViewObserver: NSViewRepresentable {
    @Binding var splitFraction: Double
    let minLeadingWidth: CGFloat
    let minTrailingWidth: CGFloat
    let isCaptureSuppressed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            splitFraction: $splitFraction,
            minLeadingWidth: minLeadingWidth,
            minTrailingWidth: minTrailingWidth
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = SplitAttachmentView(frame: .zero)
        view.didAttach = { [weak coordinator = context.coordinator] view in
            coordinator?.attachIfNeeded(to: view)
            coordinator?.applyStoredSplitFractionIfNeeded()
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.splitFraction = $splitFraction
        context.coordinator.minLeadingWidth = minLeadingWidth
        context.coordinator.minTrailingWidth = minTrailingWidth
        context.coordinator.isCaptureSuppressed = isCaptureSuppressed
        context.coordinator.attachIfNeeded(to: nsView)
        context.coordinator.applyStoredSplitFractionIfNeeded()
        context.coordinator.updateAccessibility()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        (nsView as? SplitAttachmentView)?.didAttach = nil
        coordinator.detach()
    }

    final class SplitAttachmentView: NSView {
        var didAttach: ((NSView) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.didAttach?(self)
            }
        }
    }

    final class Coordinator {
        var splitFraction: Binding<Double>
        var minLeadingWidth: CGFloat
        var minTrailingWidth: CGFloat
        var isCaptureSuppressed = false

        private weak var splitView: NSSplitView?
        private var notificationObservers: [NSObjectProtocol] = []
        private var isApplyingStoredFraction = false
        private var pendingFractionCapture: DispatchWorkItem?
        /// Total width (leading + divider + trailing) last observed. `didResizeSubviewsNotification`
        /// fires for every window/container resize as well as genuine divider drags. A change in
        /// total width means AppKit's own (non-proportional, no holding priority is set) resize
        /// logic moved the divider — not the user — so that case reapplies the stored ratio instead
        /// of capturing the resulting pixel split as a new preference. Only a divider move with
        /// total width unchanged is treated as a deliberate user drag worth persisting.
        private var lastKnownTotalWidth: CGFloat?

        init(splitFraction: Binding<Double>, minLeadingWidth: CGFloat, minTrailingWidth: CGFloat) {
            self.splitFraction = splitFraction
            self.minLeadingWidth = minLeadingWidth
            self.minTrailingWidth = minTrailingWidth
        }

        deinit {
            detach()
        }

        func attachIfNeeded(to view: NSView) {
            guard let resolvedSplitView = findEnclosingSplitView(startingAt: view) else {
                return
            }

            guard splitView !== resolvedSplitView else {
                return
            }

            detach()
            splitView = resolvedSplitView
            updateAccessibility()

            let center = NotificationCenter.default
            notificationObservers = [
                center.addObserver(
                    forName: NSSplitView.didResizeSubviewsNotification,
                    object: resolvedSplitView,
                    queue: .main
                ) { [weak self] _ in
                    self?.captureCurrentSplitFraction()
                }
            ]
        }

        func detach() {
            pendingFractionCapture?.cancel()
            pendingFractionCapture = nil
            let center = NotificationCenter.default
            notificationObservers.forEach(center.removeObserver)
            notificationObservers.removeAll()
            splitView = nil
            lastKnownTotalWidth = nil
        }

        func updateAccessibility() {
            // HSplitView is native; expose metadata on NSSplitView rather than only its SwiftUI wrapper.
            splitView?.setAccessibilityElement(true)
            splitView?.setAccessibilityIdentifier("workspaceInvestigationSplit")
            splitView?.setAccessibilityLabel("Investigation panes; browser width proportion")
            splitView?.setAccessibilityValue(String(format: "%.3f", splitFraction.wrappedValue))
        }

        func applyStoredSplitFractionIfNeeded() {
            guard let splitView,
                  splitView.subviews.count >= 2 else {
                return
            }

            let totalWidth = splitView.bounds.width - splitView.dividerThickness
            guard totalWidth > 0 else {
                return
            }

            guard let requestedPosition = WorkspaceSplitGeometry.dividerPosition(
                totalWidth: totalWidth,
                storedFraction: splitFraction.wrappedValue,
                minimumLeadingWidth: minLeadingWidth,
                minimumTrailingWidth: minTrailingWidth
            ) else { return }
            let currentPosition = splitView.subviews[0].frame.width

            guard abs(currentPosition - requestedPosition) > 1 else {
                return
            }

            isApplyingStoredFraction = true
            splitView.setPosition(requestedPosition, ofDividerAt: 0)
            isApplyingStoredFraction = false
        }

        private func captureCurrentSplitFraction() {
            guard !isApplyingStoredFraction,
                  !isCaptureSuppressed,
                  let splitView,
                  splitView.subviews.count >= 2 else {
                return
            }

            let totalWidth = splitView.bounds.width - splitView.dividerThickness
            guard totalWidth > 0 else {
                return
            }

            // Window/container resize (not a divider drag): AppKit just repositioned the
            // divider on its own to fit the new size. Re-lock it to the stored ratio rather
            // than treating wherever it happened to land as the user's new preference —
            // this is what stops the split from drifting/truncating across window resizes.
            let kind = Self.classifyResize(previousTotalWidth: lastKnownTotalWidth, currentTotalWidth: totalWidth)
            lastKnownTotalWidth = totalWidth
            if kind == .containerResize {
                pendingFractionCapture?.cancel()
                pendingFractionCapture = nil
                applyStoredSplitFractionIfNeeded()
                return
            }

            let currentFraction = Double(
                clamp(
                    splitView.subviews[0].frame.width / totalWidth,
                    lowerBound: 0.2,
                    upperBound: 0.8
                )
            )

            guard abs(splitFraction.wrappedValue - currentFraction) > 0.001 else {
                return
            }

            pendingFractionCapture?.cancel()
            let capture = DispatchWorkItem { [weak self] in
                guard let self,
                      !self.isCaptureSuppressed,
                      abs(self.splitFraction.wrappedValue - currentFraction) > 0.001 else {
                    return
                }
                self.splitFraction.wrappedValue = currentFraction
                self.updateAccessibility()
                WorkspaceLayoutDiagnostics.preferenceCommit()
                self.pendingFractionCapture = nil
            }
            pendingFractionCapture = capture
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: capture)
        }

        /// Whether a resize notification represents the window/container changing size
        /// (AppKit repositioned the divider on its own) or the user dragging the divider
        /// itself (total width unchanged, only the split point moved). Pure and
        /// AppKit-independent so the classification rule is unit-testable directly.
        static func classifyResize(
            previousTotalWidth: CGFloat?,
            currentTotalWidth: CGFloat,
            tolerance: CGFloat = 0.5
        ) -> SplitViewResizeKind {
            guard let previousTotalWidth, abs(previousTotalWidth - currentTotalWidth) > tolerance else {
                return .dividerDrag
            }
            return .containerResize
        }

        private func findEnclosingSplitView(startingAt view: NSView) -> NSSplitView? {
            var currentView: NSView? = view
            while let candidate = currentView {
                if let splitView = candidate as? NSSplitView {
                    return splitView
                }
                currentView = candidate.superview
            }
            return nil
        }

        private func clamp<T: Comparable>(_ value: T, lowerBound: T, upperBound: T) -> T {
            min(max(value, lowerBound), upperBound)
        }
    }
}

enum ExportScope {
    case all
    case selected
}
