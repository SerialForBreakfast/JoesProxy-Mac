import Foundation

struct VisualizationExportPresentationContext: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceScope: VisualizationExportScope
    let sourceSummary: String
    let sessionCount: Int
    let filteredSessionCount: Int
    let totalSessionCount: Int
    let hasActiveFilters: Bool
    let provenance: VisualizationExportProvenance
    let sourceSessions: [SessionRecord]

    init(
        id: UUID = UUID(),
        sourceScope: VisualizationExportScope,
        sourceSummary: String,
        sessionCount: Int,
        filteredSessionCount: Int,
        totalSessionCount: Int,
        hasActiveFilters: Bool,
        provenance: VisualizationExportProvenance = .proxyOnlyComplete,
        sourceSessions: [SessionRecord] = []
    ) {
        self.id = id
        self.sourceScope = sourceScope
        self.sourceSummary = sourceSummary
        self.sessionCount = sessionCount
        self.filteredSessionCount = filteredSessionCount
        self.totalSessionCount = totalSessionCount
        self.hasActiveFilters = hasActiveFilters
        self.provenance = provenance
        self.sourceSessions = sourceSessions
    }
}

enum VisualizationExportPreviewFitMode: Equatable, Sendable {
    case fitAll
    case fitWidth
    case fitHeight
}

struct VisualizationExportPreviewState: Equatable, Sendable {
    private(set) var zoomFactor: Double
    private(set) var fitMode: VisualizationExportPreviewFitMode
    private(set) var panOffset: CGSize

    var zoomPercentText: String {
        "\(Int((zoomFactor * 100).rounded()))%"
    }

    init(
        zoomFactor: Double = 1,
        fitMode: VisualizationExportPreviewFitMode = .fitAll,
        panOffset: CGSize = .zero
    ) {
        self.zoomFactor = min(1.5, max(0.15, zoomFactor))
        self.fitMode = fitMode
        self.panOffset = panOffset
    }

    mutating func zoomIn() {
        zoomFactor = min(1.5, zoomFactor + 0.1)
    }

    mutating func zoomOut() {
        zoomFactor = max(0.15, zoomFactor - 0.1)
    }

    mutating func fitWidth() {
        fitMode = .fitWidth
    }

    mutating func fitHeight() {
        fitMode = .fitHeight
    }

    mutating func pan(by translation: CGSize) {
        panOffset.width += translation.width
        panOffset.height += translation.height
    }

    mutating func reset() {
        zoomFactor = 1
        fitMode = .fitAll
        panOffset = .zero
    }
}

/// Layout math for the export preview pane, extracted for testing. Sibling to
/// `TimelineLayoutMetrics.contentWidth` (`SessionTimelineView.swift`) — same CALayer/Metal
/// hardware backing-store limit, found via the same Instruments capture
/// (`memlog/Instruments-Results/JoesProxyNotRendering`).
enum VisualizationExportPreviewMetrics {
    /// CALayer/Metal backing stores have a real maximum texture size (commonly ~16,384pt on the
    /// hardware this ships on); a wider/taller rendered size isn't clipped, it's silently dropped
    /// by AppKit ("Ignoring bogus layer size"), leaving the preview blank.
    static let maxRenderableDimension: CGFloat = 16_000

    /// The "fit to container" scale for the given mode, before zoom is applied.
    static func fitScale(
        containerSize: CGSize,
        dimensions: VisualizationExportDimensions,
        fitMode: VisualizationExportPreviewFitMode
    ) -> CGFloat {
        let widthScale = containerSize.width / CGFloat(dimensions.width)
        let heightScale = containerSize.height / CGFloat(dimensions.height)
        switch fitMode {
        case .fitAll:
            return min(widthScale, heightScale)
        case .fitWidth:
            return widthScale
        case .fitHeight:
            return heightScale
        }
    }

    /// The scale actually applied to the rendered preview content. Combines the fit-to-container
    /// scale with the user's zoom factor, then clamps so `dimensions.width * scale` and
    /// `dimensions.height * scale` both stay under `maxRenderableDimension`.
    ///
    /// Unclamped, this reaches unsafe sizes on ordinary inputs: export dimensions are
    /// independently steppable 640...8,192 per axis with no aspect-ratio tie
    /// (`VisualizationExportDimensions.isValid` only floors each axis), so an extreme custom
    /// aspect ratio (e.g. 8192×360) combined with Fit Height mode and a modest zoom-in reaches a
    /// scale that pushes the *width* past the limit — and the symmetric case (e.g. 640×8192 with
    /// Fit Width) pushes the *height* past it. Clamping by both axes' limits, not just the one the
    /// active fit mode targets, handles every fit mode/aspect-ratio combination uniformly.
    static func clampedScale(
        containerSize: CGSize,
        dimensions: VisualizationExportDimensions,
        fitMode: VisualizationExportPreviewFitMode,
        zoomFactor: Double
    ) -> CGFloat {
        let requested = max(
            0.1,
            fitScale(containerSize: containerSize, dimensions: dimensions, fitMode: fitMode)
                * CGFloat(zoomFactor)
        )
        let widthLimit = maxRenderableDimension / CGFloat(max(dimensions.width, 1))
        let heightLimit = maxRenderableDimension / CGFloat(max(dimensions.height, 1))
        return min(requested, widthLimit, heightLimit)
    }
}

@MainActor
final class VisualizationExportViewModel: ObservableObject {
    static let enabledExportTypes: [VisualizationExportType] = [
        .sessionTimeline,
        .requestWaterfall,
        .hostHealthSummary
    ]

    let context: VisualizationExportPresentationContext
    @Published var selectedExportType: VisualizationExportType
    @Published var title: String
    @Published var subtitle: String
    @Published var dimensions: VisualizationExportDimensions
    @Published var theme: VisualizationExportTheme
    @Published var redactionPolicy: VisualizationExportRedactionPolicy
    @Published var annotations: VisualizationExportAnnotationOptions
    @Published var includedMetadata: VisualizationExportIncludedMetadata
    @Published var chartConfiguration: VisualizationExportChartConfiguration
    @Published var usesCustomTimeRange: Bool
    @Published var timeRangeStart: Date
    @Published var timeRangeEnd: Date

    private var cachedRenderModelKey: String?
    private var cachedRenderModel: VisualizationExportRenderModel?

    init(context: VisualizationExportPresentationContext) {
        self.context = context
        let defaultType = Self.defaultExportType(for: context.sourceScope)
        let defaultTimeRange = Self.defaultTimeRange(for: context.sourceSessions)
        self.selectedExportType = defaultType
        self.title = defaultType.title
        self.subtitle = context.sourceSummary
        self.dimensions = .hd
        self.theme = .dark
        self.redactionPolicy = .shareableDefault
        self.annotations = .defaults
        self.includedMetadata = .defaults
        self.chartConfiguration = .defaults
        self.usesCustomTimeRange = false
        self.timeRangeStart = defaultTimeRange.start
        self.timeRangeEnd = defaultTimeRange.end
    }

    var request: VisualizationExportRequest {
        VisualizationExportRequest(
            exportType: selectedExportType,
            sourceScope: sourceScope,
            redactionPolicy: redactionPolicy,
            theme: theme,
            dimensions: dimensions,
            chartConfiguration: chartConfiguration,
            title: title,
            subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : subtitle,
            annotations: annotations,
            includedMetadata: includedMetadata,
            provenance: context.provenance
        )
    }

    var sourceScope: VisualizationExportScope {
        if usesCustomTimeRange {
            return .timeRange(VisualizationExportTimeRange(start: timeRangeStart, end: timeRangeEnd))
        }
        return context.sourceScope
    }

    var validationIssues: [VisualizationExportValidationIssue] {
        request.validationIssues()
    }

    var renderModel: VisualizationExportRenderModel? {
        let cacheKey = renderModelCacheKey
        if cachedRenderModelKey == cacheKey, let cachedRenderModel {
            return cachedRenderModel
        }

        let model = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: context.sourceSessions
        )
        cachedRenderModelKey = cacheKey
        cachedRenderModel = model
        return model
    }

    var canExportPNG: Bool {
        validationIssues.isEmpty && renderModel != nil
    }

    var exportUnavailableMessage: String {
        if !validationIssues.isEmpty {
            return validationIssues.map(\.message).joined(separator: " ")
        }
        switch selectedExportType {
        case .sessionTimeline, .hostHealthSummary, .requestWaterfall:
            if context.sourceSessions.isEmpty {
                return "There are no sessions in this export scope."
            }
            if renderModel == nil {
                return "No exportable data matched the current scope and chart options."
            }
            return "Export PNG"
        case .requestWaterfall, .latencyDistribution, .errorHeatmap, .hlsPlaybackFlow,
             .mediaAssetDeliveryTimeline, .adAndCompanionAssetTimeline, .variantSwitchTimeline,
             .timedMetadataTimeline, .contractViolationSummary:
            return "\(selectedExportType.title) rendering is planned for a later export visualization slice."
        }
    }

    func resetToDefaults() {
        let defaultType = Self.defaultExportType(for: context.sourceScope)
        selectedExportType = defaultType
        title = defaultType.title
        subtitle = context.sourceSummary
        dimensions = .hd
        theme = .dark
        redactionPolicy = .shareableDefault
        annotations = .defaults
        includedMetadata = .defaults
        chartConfiguration = .defaults
        usesCustomTimeRange = false
        let defaultTimeRange = Self.defaultTimeRange(for: context.sourceSessions)
        timeRangeStart = defaultTimeRange.start
        timeRangeEnd = defaultTimeRange.end
        invalidateRenderModelCache()
    }

    private var renderModelCacheKey: String {
        let sessionIDs = context.sourceSessions.map(\.id.uuidString).sorted().joined(separator: ",")
        let optionFlagsKey = chartConfiguration.optionFlags.keys.sorted().map { key in
            "\(key)=\(chartConfiguration.optionFlags[key] ?? false)"
        }.joined(separator: ";")
        let optionValuesKey = chartConfiguration.optionValues.keys.sorted().map { key in
            "\(key)=\(chartConfiguration.optionValues[key] ?? "")"
        }.joined(separator: ";")
        return [
            selectedExportType.rawValue,
            sourceScope.summary,
            dimensions.preset.rawValue,
            "\(dimensions.width)x\(dimensions.height)",
            theme.rawValue,
            chartConfiguration.groupingMode.rawValue,
            chartConfiguration.sortMode.rawValue,
            "\(chartConfiguration.showFailedOnly)",
            "\(chartConfiguration.collapseDuplicates)",
            "\(chartConfiguration.normalizeRelativeStartTime)",
            optionFlagsKey,
            optionValuesKey,
            "\(redactionPolicy.allowsRawValues)",
            "\(usesCustomTimeRange)",
            "\(timeRangeStart.timeIntervalSince1970)",
            "\(timeRangeEnd.timeIntervalSince1970)",
            title,
            subtitle,
            sessionIDs
        ].joined(separator: "|")
    }

    private func invalidateRenderModelCache() {
        cachedRenderModelKey = nil
        cachedRenderModel = nil
    }

    func selectResolutionPreset(_ preset: VisualizationExportResolutionPreset) {
        switch preset {
        case .hd:
            dimensions = .hd
        case .qhd:
            dimensions = .qhd
        case .fourK:
            dimensions = .fourK
        case .custom:
            dimensions = VisualizationExportDimensions(
                preset: .custom,
                width: dimensions.width,
                height: dimensions.height
            )
        }
    }

    func updateCustomDimensions(width: Int? = nil, height: Int? = nil) {
        dimensions = VisualizationExportDimensions(
            preset: .custom,
            width: max(1, width ?? dimensions.width),
            height: max(1, height ?? dimensions.height)
        )
    }

    private static func defaultExportType(for scope: VisualizationExportScope) -> VisualizationExportType {
        switch scope {
        case .filteredResults, .host, .hostGroup:
            return .hostHealthSummary
        case .selectedSession, .selectedSessions, .timeRange, .manifestAssets, .playbackFlow:
            return .sessionTimeline
        }
    }

    private static func defaultTimeRange(for sessions: [SessionRecord]) -> VisualizationExportTimeRange {
        let start = sessions.map(\.timing.startedAt).min() ?? Date()
        let end = sessions.map { session in
            session.timing.completedAt ?? session.timing.startedAt.addingTimeInterval(max(session.timing.duration ?? 0.05, 0.05))
        }.max() ?? start
        return VisualizationExportTimeRange(start: start, end: end)
    }
}
