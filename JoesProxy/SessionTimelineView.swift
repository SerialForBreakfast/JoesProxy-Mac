import Foundation
import SwiftUI

/// Layout constants for the timeline that need testing or scale-awareness.
enum TimelineLayoutMetrics {
    /// Width of the event-row HTTP-method column. The old fixed 42pt truncated the
    /// widest verb ("CONNECT", 7 monospaced chars) to "CONNEC T"; this fits it and
    /// scales with the accessibility text size.
    static func methodColumnWidth(scale: CGFloat) -> CGFloat {
        62 * max(1, scale)
    }

    /// CALayer/Metal backing stores have a real maximum texture size (commonly ~16,384pt on the
    /// hardware this ships on); a wider content width isn't clipped, it's silently dropped by
    /// AppKit ("Ignoring bogus layer size"), leaving the pane blank at that zoom level.
    static let maxRenderableTimelineContentWidth: CGFloat = 16_000

    /// Pixel width of the timeline's scrollable content for a given viewport and zoom level.
    ///
    /// Unclamped, `viewportWidth * zoomScale` reaches 400,000pt at the 50x zoom ceiling, and even
    /// an ordinary ~1,200pt window already exceeds the safe render limit well before max zoom
    /// (1,200 × 50 = 60,000pt) — reachable by zooming all the way in on any normal window, not an
    /// edge case. The clamp keeps every zoom level actually renderable; the zoom label can read
    /// higher than what's visually changing once it's active — an intentional trade of "the
    /// slider does slightly less at the very top of its range" for "the timeline never silently
    /// goes blank."
    static func contentWidth(viewportWidth: CGFloat, zoomScale: CGFloat) -> CGFloat {
        min(max(viewportWidth, viewportWidth * zoomScale), maxRenderableTimelineContentWidth)
    }
}

struct SessionTimelineView: View {
    let analysis: TimelineAnalysisResult
    @Binding var filter: TimelineFilterState
    @Binding var selectedSessionID: SessionRecord.ID?
    let isAnalyzing: Bool
    let pinCount: Int
    let hasSelectedPin: Bool
    let textScale: Double
    let onToggleSelectedPin: () -> Void
    let onPinVisibleRange: () -> Void
    let onClearPins: () -> Void
    let onClearFilters: () -> Void
    var diagnosticInterlockCoordinator: MCPDiagnosticInterlockCoordinator? = nil

    @State private var zoomScale: CGFloat = 1.0
    @State private var baseZoomScale: CGFloat = 1.0
    @State private var interlockEvaluation: MCPDiagnosticInterlockEvaluation?
    @State private var cachedRulerTicks: [Double] = []
    @State private var cachedRulerKey: String = ""
    @State private var barCanvasWidth: CGFloat = 0
    @State private var controlsWidth: CGFloat = 800

    var body: some View {
        VStack(spacing: 0) {
            if let coordinator = diagnosticInterlockCoordinator,
               let evaluation = interlockEvaluation {
                MCPDiagnosticInterlockBanner(
                    coordinator: coordinator,
                    diagnostic: .waterfallLatencyTimeline,
                    evaluation: evaluation,
                    textScale: CGFloat(textScale),
                    onAcknowledge: {}
                )
                .padding(8)
            }
            controls
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if isAnalyzing && analysis.events.isEmpty {
                timelineAnalyzingState
            } else if analysis.events.isEmpty {
                timelineEmptyState
            } else {
                HSplitView {
                    timelineLanes
                        .frame(minWidth: 480)
                    findingsPanel
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessionTimelineView")
        .task {
            guard let coordinator = diagnosticInterlockCoordinator else {
                interlockEvaluation = nil
                return
            }
            interlockEvaluation = await coordinator.evaluate(diagnostic: .waterfallLatencyTimeline)
        }
    }

    private var isTimelineIconOnly: Bool {
        controlsWidth < CompactLayout.timelineIconOnlyWidth
    }

    private var isTimelineCompact: Bool {
        controlsWidth < CompactLayout.compactToolbarWidth
    }

    private var activeSecondaryFilterCount: Int {
        var count = 0
        if !filter.hostOrPathContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            count += 1
        }
        if filter.statusFilter != .all {
            count += 1
        }
        if filter.minimumDuration != nil {
            count += 1
        }
        if filter.aroundSelection != .off {
            count += 1
        }
        if filter.pinnedOnly {
            count += 1
        }
        return count
    }

    private var controls: some View {
        HStack(spacing: 8) {
            laneFilterMenu

            if isTimelineCompact {
                collapsedFiltersMenu
            } else {
                expandedTimelineFilters
            }

            Divider()
                .frame(height: 16)

            zoomControls

            Spacer(minLength: 8)

            if isAnalyzing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Analyzing timeline")
            }

            pinControls

            if !filter.isEmpty {
                Button("Clear") {
                    onClearFilters()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Clear Timeline filters.")
            }
        }
        .reportViewWidth { controlsWidth = $0 }
    }

    private var laneFilterMenu: some View {
        Menu {
            Button("All Lanes") { updateLane(nil) }
            Divider()
            ForEach(TimelineLane.allCases) { lane in
                Button(lane.title) { updateLane(lane) }
            }
        } label: {
            timelineControlLabel(
                title: filter.lane?.title ?? "All Lanes",
                systemImage: "rectangle.3.group"
            )
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .accessibilityLabel("Timeline lane filter")
    }

    @ViewBuilder
    private var expandedTimelineFilters: some View {
        TextField(
            "Host or path",
            text: Binding(
                get: { filter.hostOrPathContains },
                set: { filter.hostOrPathContains = $0 }
            )
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: isTimelineIconOnly ? 120 : 170)
        .appFont(.caption, scale: textScale)
        .accessibilityLabel("Timeline host or path filter")

        statusFilterMenu
        durationFilterMenu
        aroundSelectionMenu
        pinnedOnlyToggle
    }

    private var collapsedFiltersMenu: some View {
        Menu {
            Section("Host or Path") {
                TextField(
                    "Host or path",
                    text: Binding(
                        get: { filter.hostOrPathContains },
                        set: { filter.hostOrPathContains = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }

            Divider()

            Menu("Status") {
                ForEach(TimelineStatusFilter.allCases) { status in
                    Button(status.title) { filter.statusFilter = status }
                }
            }

            Menu("Duration") {
                Button("Any Duration") { filter.minimumDuration = nil }
                Button("Over 500ms") { filter.minimumDuration = 0.5 }
                Button("Over 1s") { filter.minimumDuration = 1 }
                Button("Over 2s") { filter.minimumDuration = 2 }
                Button("Over 5s") { filter.minimumDuration = 5 }
            }

            Menu("Around Selection") {
                ForEach(TimelineAroundSelectionWindow.allCases) { option in
                    Button(option.title) { filter.aroundSelection = option }
                }
            }
            .disabled(selectedSessionID == nil && filter.aroundSelection == .off)

            Toggle(isOn: Binding(get: { filter.pinnedOnly }, set: { filter.pinnedOnly = $0 })) {
                Text("Pinned Only")
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                timelineControlLabel(title: "Filters", systemImage: "line.3.horizontal.decrease.circle")
                if activeSecondaryFilterCount > 0 {
                    Text(verbatim: "\(activeSecondaryFilterCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(Color.white)
                        .offset(x: 8, y: -6)
                        .accessibilityHidden(true)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .accessibilityLabel("Timeline filters")
        .accessibilityValue(activeSecondaryFilterCount > 0 ? "\(activeSecondaryFilterCount) active" : "None active")
    }

    private var statusFilterMenu: some View {
        Menu {
            ForEach(TimelineStatusFilter.allCases) { status in
                Button(status.title) { filter.statusFilter = status }
            }
        } label: {
            timelineControlLabel(title: filter.statusFilter.title, systemImage: "number.circle")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    private var durationFilterMenu: some View {
        Menu {
            Button("Any Duration") { filter.minimumDuration = nil }
            Button("Over 500ms") { filter.minimumDuration = 0.5 }
            Button("Over 1s") { filter.minimumDuration = 1 }
            Button("Over 2s") { filter.minimumDuration = 2 }
            Button("Over 5s") { filter.minimumDuration = 5 }
        } label: {
            timelineControlLabel(title: durationFilterTitle, systemImage: "timer")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    private var aroundSelectionMenu: some View {
        Menu {
            ForEach(TimelineAroundSelectionWindow.allCases) { option in
                Button(option.title) { filter.aroundSelection = option }
            }
        } label: {
            timelineControlLabel(title: filter.aroundSelection.title, systemImage: "scope")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .disabled(selectedSessionID == nil && filter.aroundSelection == .off)
    }

    private var pinnedOnlyToggle: some View {
        Toggle(isOn: Binding(get: { filter.pinnedOnly }, set: { filter.pinnedOnly = $0 })) {
            timelineControlLabel(title: "Pinned", systemImage: "pin")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help("Show only pinned timeline events.")
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            if !isTimelineIconOnly {
                Label("Zoom", systemImage: "magnifyingglass")
                    .labelStyle(.titleAndIcon)
                    .appFont(.caption, scale: textScale, weight: .semibold)
                    .foregroundStyle(.secondary)
            }

            Button { zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(zoomScale <= 1.01)
                .help("Zoom out horizontally.")
                .accessibilityLabel("Zoom timeline out")

            Slider(value: zoomBinding, in: 1.0...50.0)
                .frame(width: isTimelineIconOnly ? 72 : 96)
                .controlSize(.small)
                .accessibilityLabel("Timeline horizontal zoom")
                .accessibilityValue(zoomDisplayText)
                .accessibilityIdentifier("timelineZoomSlider")

            if !isTimelineIconOnly {
                Text(verbatim: zoomDisplayText)
                    .appFont(.caption, scale: textScale, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            Button { zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(zoomScale >= 50.0)
                .help("Zoom in horizontally.")
                .accessibilityLabel("Zoom timeline in")

            if !isTimelineIconOnly {
                Button("1:1") { resetZoom() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption.monospacedDigit())
                    .disabled(zoomScale <= 1.01)
                    .help("Reset timeline zoom.")
            }
        }
        .help("Zoom timeline horizontally. Pinch trackpad to zoom.")
    }

    private var pinControls: some View {
        Group {
            Button {
                onToggleSelectedPin()
            } label: {
                timelineControlLabel(
                    title: hasSelectedPin ? "Unpin" : "Pin",
                    systemImage: hasSelectedPin ? "pin.slash" : "pin"
                )
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(selectedSessionID == nil)
            .help(hasSelectedPin ? "Unpin the selected request." : "Pin the selected request.")

            Button {
                onPinVisibleRange()
            } label: {
                timelineControlLabel(title: "Range", systemImage: "timeline.selection")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(analysis.visibleEvents.isEmpty)
            .help("Pin the currently visible timeline range.")

            if pinCount > 0 {
                Button {
                    onClearPins()
                } label: {
                    timelineControlLabel(title: "Clear Pins", systemImage: "pin.slash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func timelineControlLabel(title: String, systemImage: String) -> some View {
        Group {
            if isTimelineIconOnly {
                Image(systemName: systemImage)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        // Keep control labels on one line and let them claim their intrinsic width so a
        // narrow toolbar shrinks other elements first instead of wrapping "Range" to "Ran\nge".
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var timelineLanes: some View {
        GeometryReader { geo in
            // Guard against transiently large geometry proposals (window resize, split drag).
            let viewportWidth = geo.size.width.isNormal ? min(geo.size.width, 8_000) : 800
            // See `TimelineLayoutMetrics.contentWidth` for why this is clamped rather than left as
            // the raw `viewportWidth * zoomScale` product.
            let contentWidth = TimelineLayoutMetrics.contentWidth(
                viewportWidth: viewportWidth,
                zoomScale: zoomScale
            )
            // Outer horizontal scroll keeps ruler and event rows in sync.
            // Inner vertical-only scroll lets LazyVStack be truly lazy (single-axis parent).
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    timeRuler(contentWidth: contentWidth)
                        .frame(width: contentWidth)
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            timelineHeader

                            if analysis.renderedEvents.isEmpty {
                                ContentUnavailableView {
                                    Label("No Timeline Matches", systemImage: "timeline.selection")
                                } description: {
                                    Text("Adjust Timeline filters or clear pinned-only mode.")
                                }
                                .frame(maxWidth: .infinity, minHeight: 260)
                            } else {
                                ForEach(lanesWithEvents, id: \.lane) { group in
                                    laneSection(lane: group.lane, events: group.events)
                                }
                            }
                        }
                        .padding(12)
                        .frame(width: contentWidth, alignment: .leading)
                    }
                }
                .frame(width: contentWidth)
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        zoomScale = min(max(baseZoomScale * value, 1.0), 50.0)
                    }
                    .onEnded { value in
                        baseZoomScale = min(max(baseZoomScale * value, 1.0), 50.0)
                        zoomScale = baseZoomScale
                    }
            )
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
    }

    private func timeRuler(contentWidth: CGFloat) -> some View {
        Group {
            if let start = analysis.captureStart, let end = analysis.captureEnd, end > start {
                rulerContent(contentWidth: contentWidth, captureStart: start, captureEnd: end)
            }
        }
    }

    @ViewBuilder
    private func rulerContent(contentWidth: CGFloat, captureStart: Date, captureEnd: Date) -> some View {
        let span = captureEnd.timeIntervalSince(captureStart)
        let interval = niceTickInterval(span: span, contentWidth: contentWidth)
        let key = "\(span),\(contentWidth),\(interval)"
        let ticks = cachedRulerKey == key ? cachedRulerTicks : Array(stride(from: 0.0, through: span, by: interval))
        ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { t in
                VStack(alignment: .leading, spacing: 1) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 1, height: 5)
                    Text(t.formattedAsSeconds())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .offset(x: CGFloat(t / span) * contentWidth)
            }
        }
        .frame(width: contentWidth, height: 24, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            cachedRulerKey = key
            cachedRulerTicks = ticks
        }
        .onChange(of: key) { _, newKey in
            // `key` (and so this closure) fires on every pixel of a live pinch-zoom drag, since it
            // derives from `contentWidth`, which derives from `zoomScale`, which the magnification
            // gesture updates continuously via `.onChanged`. Writing `@State` synchronously here
            // is a state mutation reacting to another state mutation from *inside* that gesture's
            // still-active view-update transaction — deferring one run-loop turn (values are
            // captured now, by value, so this still writes the correct ticks for this exact
            // `newKey`) is what actually produced "Publishing changes from within view updates" in
            // Instruments captures, matching the fix already used for the same class of issue in
            // `MainWindowConfigurator.updateNSView`.
            let recalculatedTicks = Array(stride(from: 0.0, through: span, by: interval))
            DispatchQueue.main.async {
                cachedRulerKey = newKey
                cachedRulerTicks = recalculatedTicks
            }
        }
    }

    private func niceTickInterval(span: TimeInterval, contentWidth: CGFloat) -> TimeInterval {
        let pixelsPerSecond = Double(contentWidth) / span
        let idealSeconds = 80.0 / pixelsPerSecond
        let nice: [TimeInterval] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 300]
        return nice.first { $0 >= idealSeconds } ?? 300
    }

    private func zoomIn() {
        let next = min(zoomScale * 2, 50.0)
        baseZoomScale = next
        zoomScale = next
    }

    private func zoomOut() {
        let next = max(zoomScale / 2, 1.0)
        baseZoomScale = next
        zoomScale = next
    }

    private func resetZoom() {
        baseZoomScale = 1.0
        zoomScale = 1.0
    }

    private var zoomBinding: Binding<Double> {
        Binding(
            get: { Double(zoomScale) },
            set: { newValue in
                let clamped = min(max(newValue, 1.0), 50.0)
                let next = CGFloat(clamped)
                baseZoomScale = next
                zoomScale = next
            }
        )
    }

    private var zoomDisplayText: String {
        if zoomScale < 10 {
            return String(format: "%.1fx", Double(zoomScale))
        }

        return "\(Int(zoomScale.rounded()))x"
    }

    private var timelineHeader: some View {
        HStack(spacing: 12) {
            Label("Timeline", systemImage: "waveform.path.ecg")
                .appFont(.headline, scale: textScale, weight: .semibold)

            Text(verbatim: timelineCountText)
                .appFont(.caption, scale: textScale, design: .monospaced)
                .foregroundStyle(.secondary)

            if let start = analysis.captureStart, let end = analysis.captureEnd {
                Text(verbatim: formatSeconds(end.timeIntervalSince(start)))
                    .appFont(.caption, scale: textScale, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Capture span \(formatSeconds(end.timeIntervalSince(start)))")
            }

            Spacer()
        }
    }

    private func laneSection(lane: TimelineLane, events: [TimelineEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(laneColor(lane))
                    .frame(width: 8, height: 8)
                Text(lane.title)
                    .appFont(.subheadline, scale: textScale, weight: .semibold)
                Text(verbatim: "\(events.count)")
                    .appFont(.caption, scale: textScale, design: .monospaced)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                ForEach(events) { event in
                    timelineEventRow(event)
                }
                ForEach(gaps(for: lane)) { gap in
                    gapRow(gap)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func timelineEventRow(_ event: TimelineEvent) -> some View {
        #if DEBUG
        CapturePerformanceSignposts.signposter.emitEvent("timeline-row-eval")
        #endif
        return Button {
            selectedSessionID = event.sessionID
        } label: {
            HStack(spacing: 8) {
                Text(relativeStartText(for: event))
                    .appFont(.caption, scale: textScale, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)

                // Background GR measures actual canvas width without affecting layout.
                // barCanvasWidth is shared state — all rows have the same canvas width.
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 8)
                    Capsule(style: .continuous)
                        .fill(laneColor(event.lane))
                        .frame(width: barWidth(for: event, totalWidth: barCanvasWidth), height: 8)
                        .offset(x: barOffset(for: event, totalWidth: barCanvasWidth))
                }
                .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { barCanvasWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, w in barCanvasWidth = w }
                    }
                )

                Text(event.method)
                    .appFont(.caption, scale: textScale, weight: .semibold, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: TimelineLayoutMetrics.methodColumnWidth(scale: textScale), alignment: .leading)

                Text(event.host)
                    .appFont(.caption, scale: textScale)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 100, idealWidth: 150, alignment: .leading)

                Text(event.pathSummary)
                    .appFont(.caption, scale: textScale, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(statusText(event.statusCode))
                    .appFont(.caption, scale: textScale, weight: .semibold, design: .monospaced)
                    .foregroundStyle(statusColor(event.statusCode))
                    .frame(width: 44, alignment: .trailing)

                if event.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Pinned")
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selectedSessionID == event.sessionID ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: event))
        .accessibilityIdentifier("timelineEvent-\(event.sessionID.uuidString)")
    }

    private func gapRow(_ gap: TimelineGap) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(gap.severity == .high ? .red : .orange)
            Text(gap.reason.title)
                .appFont(.caption, scale: textScale, weight: .semibold)
            Text(verbatim: formatSeconds(gap.duration))
                .appFont(.caption, scale: textScale, design: .monospaced)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .accessibilityLabel("\(gap.reason.title), \(formatSeconds(gap.duration))")
    }

    private var findingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Findings", systemImage: "lightbulb")
                    .appFont(.headline, scale: textScale, weight: .semibold)
                Spacer()
                Text(verbatim: "\(analysis.findings.count)")
                    .appFont(.caption, scale: textScale, design: .monospaced)
                    .foregroundStyle(.secondary)
            }

            if let mediaSummary = analysis.mediaSummary {
                mediaSummaryView(mediaSummary)
            }

            if analysis.findings.isEmpty {
                Text("No timeline findings for the current filters.")
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(analysis.findings) { finding in
                            findingRow(finding)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("timelineFindingsPanel")
    }

    private func mediaSummaryView(_ summary: MediaTimelineSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Media")
                .appFont(.subheadline, scale: textScale, weight: .semibold)
            timelineMetric("Manifests", "\(summary.manifestSessionIDs.count)")
            timelineMetric("Licenses", "\(summary.licenseSessionIDs.count)")
            timelineMetric("Segments", "\(summary.mediaSegmentSessionIDs.count)")
            if let delay = summary.firstSegmentDelay {
                timelineMetric("First Segment", formatSeconds(delay))
            }
            if let longestGap = summary.cadence?.longestSegmentGap {
                timelineMetric("Longest Gap", formatSeconds(longestGap))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.10))
        )
    }

    private func timelineMetric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(verbatim: value)
                .appFont(.caption, scale: textScale, weight: .semibold, design: .monospaced)
                // The value is the payload ("9.9s") — give it priority and its intrinsic
                // width so a narrow Findings panel truncates the label, never the number.
                .lineLimit(1)
                .layoutPriority(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func findingRow(_ finding: TimelineFinding) -> some View {
        Button {
            if let id = finding.evidenceSessionIDs.first {
                selectedSessionID = id
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(finding.title)
                        .appFont(.caption, scale: textScale, weight: .semibold)
                        .lineLimit(2)
                    Spacer()
                    Text(finding.confidence.rawValue.capitalized)
                        .appFont(.caption2, scale: textScale, design: .monospaced)
                        .foregroundStyle(.secondary)
                }
                Text(finding.detail)
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(findingColor(finding.severity).opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(finding.title). \(finding.detail)")
    }

    private var timelineAnalyzingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text("Analyzing Timeline…")
                .appFont(.headline, scale: CGFloat(textScale), weight: .semibold)
            Text("Correlating requests, streaming events, and timing findings.")
                .appFont(.subheadline, scale: CGFloat(textScale))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analyzing captured timeline. Correlating requests, streaming events, and timing findings.")
    }

    private var timelineEmptyState: some View {
        ContentUnavailableView {
            if activeSecondaryFilterCount > 0 || filter.lane != nil || filter.aroundSelection != .off {
                Label("No Matching Timeline Events", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                Label("No Timeline Yet", systemImage: "timeline.selection")
            }
        } description: {
            if activeSecondaryFilterCount > 0 || filter.lane != nil || filter.aroundSelection != .off {
                Text("No captured requests match the active timeline filters.")
            } else {
                Text("Captured traffic will appear here as a time-based investigation view.")
            }
        } actions: {
            if activeSecondaryFilterCount > 0 || filter.lane != nil || filter.aroundSelection != .off {
                Button("Clear Timeline Filters") {
                    onClearFilters()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lanesWithEvents: [(lane: TimelineLane, events: [TimelineEvent])] {
        TimelineLane.allCases.compactMap { lane in
            guard lane != .pinned, let events = analysis.eventsByLane[lane], !events.isEmpty else { return nil }
            return (lane, events)
        }
    }

    private var timelineCountText: String {
        if analysis.filteredEventCount == analysis.renderedEventCount {
            return "\(analysis.renderedEventCount) of \(analysis.events.count) shown"
        }

        return "\(analysis.renderedEventCount) of \(analysis.filteredEventCount) matching shown"
    }

    private var durationFilterTitle: String {
        guard let minimumDuration = filter.minimumDuration else {
            return "Any Duration"
        }
        return "Over \(formatSeconds(minimumDuration))"
    }

    private func updateLane(_ lane: TimelineLane?) {
        filter.lane = lane
    }

    private func gaps(for lane: TimelineLane) -> [TimelineGap] {
        analysis.gapsByLane[lane] ?? []
    }

    private func relativeStartText(for event: TimelineEvent) -> String {
        guard let start = analysis.captureStart else { return "0.0s" }
        return formatSeconds(event.startedAt.timeIntervalSince(start))
    }

    private func barOffset(for event: TimelineEvent, totalWidth: CGFloat) -> CGFloat {
        max(0, totalWidth * event.normalizedStart)
    }

    private func barWidth(for event: TimelineEvent, totalWidth: CGFloat) -> CGFloat {
        max(5, totalWidth * event.normalizedDuration)
    }

    private func accessibilityLabel(for event: TimelineEvent) -> String {
        let status = event.statusCode.map(String.init) ?? "no status"
        return "\(event.lane.title), \(event.method), \(event.host), \(event.pathSummary), status \(status), duration \(formatSeconds(event.duration))"
    }

    private func statusText(_ statusCode: Int?) -> String {
        statusCode.map(String.init) ?? "-"
    }

    private func statusColor(_ statusCode: Int?) -> Color {
        guard let statusCode else { return .orange }
        switch statusCode {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<600: return .red
        default: return .secondary
        }
    }

    private func laneColor(_ lane: TimelineLane) -> Color {
        switch lane {
        case .api: return .blue
        case .authConfig: return .purple
        case .manifest: return .teal
        case .drmLicense: return .yellow
        case .mediaSegments: return .green
        case .imagesAssets: return .indigo
        case .adsAnalytics: return .pink
        case .errorsRetries: return .red
        case .pinned: return .orange
        }
    }

    private func findingColor(_ severity: TimelineSeverity) -> Color {
        switch severity {
        case .info: return .blue
        case .attention: return .orange
        case .high: return .red
        }
    }

    private func formatSeconds(_ value: TimeInterval) -> String { value.formattedAsSeconds() }
}
