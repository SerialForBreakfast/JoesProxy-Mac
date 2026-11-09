import SwiftUI

/// Window-level workspace policy. Pane-local controls must use ``PaneLayoutMode`` instead;
/// a wide window can still contain a narrow pane after the divider is dragged.
enum WorkspaceWindowTier: Equatable, Sendable {
    case expanded
    case grouped
    case focused

    static func resolve(width: CGFloat, textScale: CGFloat) -> Self {
        let boundedScale = min(max(textScale, 1), 1.25)
        let effectiveWidth = width / boundedScale
        if effectiveWidth < 960 { return .focused }
        if effectiveWidth < 1_380 { return .grouped }
        return .expanded
    }

    var usesTwoPanes: Bool { self != .focused }
}

enum PaneLayoutMode: Equatable, Sendable {
    case roomy
    case compact
    case narrow

    static func browser(width: CGFloat) -> Self {
        if width < 450 { return .narrow }
        if width < 650 { return .compact }
        return .roomy
    }

    static func inspector(width: CGFloat) -> Self {
        width < 520 ? .compact : .roomy
    }
}

enum WorkspacePaneFocus: Equatable, Sendable {
    case browser
    case detail

    static func afterBackgroundSelectionChange(
        current: Self,
        hasValidDetailDestination: Bool
    ) -> Self {
        current == .detail && !hasValidDetailDestination ? .browser : current
    }

    static func afterExplicitDetailEntry(
        current: Self,
        hasValidDetailDestination: Bool
    ) -> Self {
        hasValidDetailDestination ? .detail : current
    }
}

enum WorkspaceLayoutMetrics {
    static let minimumWindowWidth: CGFloat = 720
    static let minimumWindowHeight: CGFloat = 560
    static let browserMinimumWidth: CGFloat = 340
    static let inspectorMinimumWidth: CGFloat = 380
}

enum WorkspaceSplitGeometry {
    static func dividerPosition(
        totalWidth: CGFloat,
        storedFraction: Double,
        minimumLeadingWidth: CGFloat,
        minimumTrailingWidth: CGFloat
    ) -> CGFloat? {
        let minimumPosition = minimumLeadingWidth
        let maximumPosition = totalWidth - minimumTrailingWidth
        guard totalWidth > 0, maximumPosition > minimumPosition else { return nil }

        let boundedFraction = min(max(storedFraction, 0.2), 0.8)
        return min(
            max(CGFloat(boundedFraction) * totalWidth, minimumPosition),
            maximumPosition
        )
    }
}

/// Width breakpoints for toolbar and table compaction (Workstream AC-2).
enum CompactLayout {
    static let compactToolbarWidth: CGFloat = 520
    static let timelineIconOnlyWidth: CGFloat = 580
    static let sessionTableMinPaneWidth: CGFloat = 480
}

/// Session table columns that may hide as the primary pane narrows.
enum SessionTableColumnID: String, CaseIterable, Sendable {
    case time
    case method
    case domain
    case source
    case path
    case media
    case status
    case size
    case duration
}

/// Priority-ordered visibility for session table columns at narrow pane widths.
enum SessionTableColumnVisibility {
    /// Returns whether `column` should render for a session table pane of `paneWidth` points.
    static func isVisible(_ column: SessionTableColumnID, paneWidth: CGFloat) -> Bool {
        switch column {
        case .method, .domain, .path:
            return true
        case .time:
            return paneWidth >= 720
        case .size:
            return paneWidth >= 680
        case .duration:
            return paneWidth >= 640
        case .media:
            return paneWidth >= 600
        case .source:
            return paneWidth >= 560
        case .status:
            return paneWidth >= 520
        }
    }
}

extension View {
    /// Reports the rendered width of a container to `onChange` whenever layout updates.
    func reportViewWidth(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        modifier(ViewWidthReportingModifier(onChange: onChange))
    }
}

private struct ViewWidthReportingModifier: ViewModifier {
    @State private var lastReportedWidth: CGFloat?
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { reportIfMeaningful(geometry.size.width) }
                    .onChange(of: geometry.size.width) { _, width in
                        reportIfMeaningful(width)
                    }
            }
        )
    }

    private func reportIfMeaningful(_ width: CGFloat) {
        let roundedWidth = width.rounded(.toNearestOrAwayFromZero)
        guard lastReportedWidth != roundedWidth else { return }
        lastReportedWidth = roundedWidth
        onChange(roundedWidth)
    }
}
