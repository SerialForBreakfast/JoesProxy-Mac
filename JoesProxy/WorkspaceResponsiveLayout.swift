import SwiftUI
import os

enum WorkspaceHeightMode: Equatable { case normal, constrained }
enum WorkspacePaneKind { case browser, inspector }

struct WorkspaceLayoutState: Equatable {
    var tier: WorkspaceWindowTier = .expanded
    var height: WorkspaceHeightMode = .normal
}

enum WorkspaceResponsivePolicy {
    static func index(value: CGFloat, thresholds: [CGFloat], previous: Int?) -> Int {
        let natural = thresholds.filter { value >= $0 }.count
        guard let previous, natural > previous else { return natural }
        var result = previous
        while result < thresholds.count, value >= thresholds[result] + 16 { result += 1 }
        return result
    }

    static func window(size: CGSize, textScale: CGFloat, previous: WorkspaceLayoutState?) -> WorkspaceLayoutState {
        let tiers: [WorkspaceWindowTier] = [.focused, .grouped, .expanded]
        let scale = min(max(textScale, 1), 1.25)
        let index = index(value: size.width / scale, thresholds: [960, 1_380],
                          previous: previous.flatMap { tiers.firstIndex(of: $0.tier) })
        let fitsPanes = size.width >= WorkspaceLayoutMetrics.browserMinimumWidth
            + WorkspaceLayoutMetrics.inspectorMinimumWidth + 1
        let height = Self.index(value: size.height, thresholds: [640],
                                previous: previous.map { $0.height == .normal ? 1 : 0 })
        return WorkspaceLayoutState(tier: fitsPanes ? tiers[index] : .focused,
                                    height: height == 0 ? .constrained : .normal)
    }

    static func pane(width: CGFloat, textScale: CGFloat, kind: WorkspacePaneKind, previous: PaneLayoutMode?) -> PaneLayoutMode {
        let modes: [PaneLayoutMode] = kind == .browser ? [.narrow, .compact, .roomy] : [.compact, .roomy]
        let thresholds: [CGFloat] = kind == .browser ? [450, 650] : [520]
        return modes[index(value: max(0, width - 16) / max(1, textScale), thresholds: thresholds,
                           previous: previous.flatMap { modes.firstIndex(of: $0) })]
    }

    static func columnWidthBucket(_ width: CGFloat, textScale: CGFloat) -> CGFloat {
        let width = width / max(1, textScale)
        return [0, 520, 560, 600, 640, 680, 720].last { CGFloat($0) <= width }.map(CGFloat.init) ?? 0
    }
}

/// Aggregate presentation events only; no sessions or traffic content are logged.
enum WorkspaceLayoutDiagnostics {
    private static let logger = Logger(subsystem: "com.JoesProxyApp.UI", category: "WorkspaceLayout")
    static func transition() { logger.debug("Workspace layout mode changed") }
    static func preferenceCommit() { logger.debug("Workspace resize preference committed") }
}

private struct WorkspaceModeReporter<Value: Equatable>: ViewModifier {
    let textScale: CGFloat
    let resolve: (CGSize, CGFloat, Value?) -> Value
    let report: (Value) -> Void
    @State private var previous: Value?

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { update(geometry.size) }
                    .onChange(of: geometry.size) { _, size in update(size) }
                    .onChange(of: textScale) { _, _ in update(geometry.size) }
            }
        }
    }
    private func update(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let value = resolve(size, textScale, previous)
        guard value != previous else { return }
        previous = value
        WorkspaceLayoutDiagnostics.transition()
        report(value)
    }
}

extension View {
    func reportWorkspaceLayout(textScale: CGFloat, report: @escaping (WorkspaceLayoutState) -> Void) -> some View {
        modifier(WorkspaceModeReporter(textScale: textScale, resolve: WorkspaceResponsivePolicy.window, report: report))
    }
    func reportWorkspacePane(kind: WorkspacePaneKind, textScale: CGFloat, report: @escaping (PaneLayoutMode) -> Void) -> some View {
        modifier(WorkspaceModeReporter(textScale: textScale, resolve: { size, scale, previous in
            WorkspaceResponsivePolicy.pane(width: size.width, textScale: scale, kind: kind, previous: previous)
        }, report: report))
    }
    func reportWorkspaceColumns(textScale: CGFloat, report: @escaping (CGFloat) -> Void) -> some View {
        modifier(WorkspaceModeReporter(textScale: textScale, resolve: { size, scale, _ in
            WorkspaceResponsivePolicy.columnWidthBucket(size.width, textScale: scale)
        }, report: report))
    }
}

/// A pane's geometry belongs here; the owner receives discrete composition changes only.
struct WorkspacePaneContainer<Header: View, Content: View, Footer: View>: View {
    let kind: WorkspacePaneKind
    let textScale: CGFloat
    let modeChanged: (PaneLayoutMode) -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header().layoutPriority(1)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            footer().layoutPriority(1)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .reportWorkspacePane(kind: kind, textScale: textScale, report: modeChanged)
        .accessibilityElement(children: .contain)
    }
}
