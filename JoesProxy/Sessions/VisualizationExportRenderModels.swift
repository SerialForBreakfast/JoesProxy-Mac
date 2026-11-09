import Foundation

enum VisualizationExportRenderModel: Equatable, Sendable {
    case sessionTimeline(SessionTimelineExportModel)
    case hostHealthSummary(HostHealthSummaryExportModel)
    case requestWaterfall(RequestWaterfallExportModel)

    var request: VisualizationExportRequest {
        switch self {
        case .sessionTimeline(let model):
            return model.request
        case .hostHealthSummary(let model):
            return model.request
        case .requestWaterfall(let model):
            return model.request
        }
    }

    var warnings: [String] {
        switch self {
        case .sessionTimeline(let model):
            return model.warnings
        case .hostHealthSummary(let model):
            return model.warnings
        case .requestWaterfall(let model):
            return model.warnings
        }
    }

    var dataSummary: VisualizationExportDataSummary {
        switch self {
        case .sessionTimeline(let model):
            return model.dataSummary
        case .hostHealthSummary(let model):
            return model.dataSummary
        case .requestWaterfall(let model):
            return model.dataSummary
        }
    }
}

enum VisualizationExportRenderModelBuilder {
    static func makeRenderModel(
        request: VisualizationExportRequest,
        sessions: [SessionRecord]
    ) -> VisualizationExportRenderModel? {
        guard request.validationIssues().isEmpty else {
            return nil
        }

        switch request.exportType {
        case .sessionTimeline:
            guard !sessions.isEmpty else { return nil }
            return .sessionTimeline(SessionTimelineExportModel(request: request, sessions: sessions))
        case .hostHealthSummary:
            let model = HostHealthSummaryExportModel(request: request, sessions: sessions)
            guard !model.hosts.isEmpty, model.dataSummary.sessionCount > 0 else {
                return nil
            }
            return .hostHealthSummary(model)
        case .requestWaterfall:
            let model = RequestWaterfallExportModel(request: request, sessions: sessions)
            guard !model.rows.isEmpty else {
                return nil
            }
            return .requestWaterfall(model)
        case .latencyDistribution, .errorHeatmap, .hlsPlaybackFlow,
             .mediaAssetDeliveryTimeline, .adAndCompanionAssetTimeline, .variantSwitchTimeline,
             .timedMetadataTimeline, .contractViolationSummary:
            return nil
        }
    }
}

struct SessionTimelineExportModel: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let id: SessionRecord.ID
        let method: String
        let host: String
        let pathSummary: String
        let statusLabel: String
        let contentType: String?
        let inspectionKind: SessionInspectionKind
        let startedAt: Date
        let startOffset: TimeInterval
        let duration: TimeInterval
        let responseBodySize: Int?
        let isFailure: Bool
        /// Immutable MCP effect attribution captured at response time (AJ-2); never re-derived
        /// from the live rule store, so it survives rule edits, disable, delete, and detach.
        let mcpEffectAnnotation: MCPCaptureAttribution?
    }

    let request: VisualizationExportRequest
    let rows: [Row]
    let captureStart: Date
    let captureEnd: Date
    let totalDuration: TimeInterval
    let warnings: [String]
    let dataSummary: VisualizationExportDataSummary

    init(request: VisualizationExportRequest, sessions: [SessionRecord]) {
        self.request = request
        let captureBaseStart = sessions.map(\.timing.startedAt).min() ?? Date()
        let scopedSessions = Self.scopedSessions(sessions, for: request)
        let orderedSessions = Self.orderedSessions(scopedSessions, configuration: request.chartConfiguration)
        let filteredSessions = request.chartConfiguration.showFailedOnly
            ? orderedSessions.filter(Self.isFailure)
            : orderedSessions
        let visibleSessions = request.chartConfiguration.collapseDuplicates
            ? Self.collapsedDuplicateSessions(filteredSessions)
            : filteredSessions
        let start = visibleSessions.map(\.timing.startedAt).min() ?? captureBaseStart
        let end = visibleSessions.map { session in
            session.timing.completedAt ?? session.timing.startedAt.addingTimeInterval(max(session.timing.duration ?? 0.05, 0.05))
        }.max() ?? start
        let offsetBase = Self.offsetBase(
            request: request,
            captureBaseStart: captureBaseStart,
            visibleStart: start
        )
        self.captureStart = start
        self.captureEnd = end
        self.totalDuration = max(end.timeIntervalSince(start), 0.05)
        self.rows = visibleSessions.map { session in
            let duration = max(session.timing.duration ?? 0.05, 0.05)
            return Row(
                id: session.id,
                method: session.request.method,
                host: session.request.host,
                pathSummary: Self.pathSummary(
                    session.request.path,
                    redactionPolicy: request.redactionPolicy
                ),
                statusLabel: Self.statusLabel(for: session),
                contentType: Self.headerValue("Content-Type", in: session.response?.headers),
                inspectionKind: session.request.inspectionKind,
                startedAt: session.timing.startedAt,
                startOffset: max(0, session.timing.startedAt.timeIntervalSince(offsetBase)),
                duration: duration,
                responseBodySize: session.response?.bodySize ?? session.response?.bodyData?.count,
                isFailure: Self.isFailure(session),
                mcpEffectAnnotation: session.response?.mcpAttribution
            )
        }
        self.warnings = Self.warnings(
            rows: rows,
            request: request,
            dimensions: request.dimensions
        )
        self.dataSummary = Self.dataSummary(rows: rows, warnings: warnings)
    }

    private static func scopedSessions(
        _ sessions: [SessionRecord],
        for request: VisualizationExportRequest
    ) -> [SessionRecord] {
        guard case .timeRange(let range) = request.sourceScope else {
            return sessions
        }
        return sessions.filter { session in
            let completedAt = session.timing.completedAt
                ?? session.timing.startedAt.addingTimeInterval(max(session.timing.duration ?? 0.05, 0.05))
            return session.timing.startedAt <= range.end && completedAt >= range.start
        }
    }

    private static let timelineClassifier = TimelineClassificationService()

    private static func orderedSessions(
        _ sessions: [SessionRecord],
        configuration: VisualizationExportChartConfiguration
    ) -> [SessionRecord] {
        sessions.sorted { lhs, rhs in
            switch configuration.groupingMode {
            case .host:
                if lhs.request.host.localizedCaseInsensitiveCompare(rhs.request.host) != .orderedSame {
                    return lhs.request.host.localizedCaseInsensitiveCompare(rhs.request.host) == .orderedAscending
                }
            case .requestRole:
                let lhsRole = requestRoleTitle(for: lhs)
                let rhsRole = requestRoleTitle(for: rhs)
                if lhsRole != rhsRole {
                    return lhsRole < rhsRole
                }
            case .none:
                break
            }

            switch configuration.sortMode {
            case .startTime:
                if lhs.timing.startedAt == rhs.timing.startedAt {
                    return lhs.request.host.localizedCaseInsensitiveCompare(rhs.request.host) == .orderedAscending
                }
                return lhs.timing.startedAt < rhs.timing.startedAt
            case .durationDescending:
                let lhsDuration = lhs.timing.duration ?? 0
                let rhsDuration = rhs.timing.duration ?? 0
                if lhsDuration == rhsDuration {
                    return lhs.timing.startedAt < rhs.timing.startedAt
                }
                return lhsDuration > rhsDuration
            }
        }
    }

    private static func requestRoleTitle(for session: SessionRecord) -> String {
        timelineClassifier.classify(session).lane.title
    }

    private static func collapsedDuplicateSessions(_ sessions: [SessionRecord]) -> [SessionRecord] {
        var seen = Set<String>()
        return sessions.filter { session in
            let key = [
                session.request.method,
                session.request.host.lowercased(),
                session.request.path,
                statusLabel(for: session),
                headerValue("Content-Type", in: session.response?.headers) ?? ""
            ].joined(separator: "\u{1F}")
            return seen.insert(key).inserted
        }
    }

    private static func offsetBase(
        request: VisualizationExportRequest,
        captureBaseStart: Date,
        visibleStart: Date
    ) -> Date {
        if request.chartConfiguration.normalizeRelativeStartTime {
            return visibleStart
        }
        if case .timeRange(let range) = request.sourceScope {
            return range.start
        }
        return captureBaseStart
    }

    private static func pathSummary(
        _ path: String,
        redactionPolicy: VisualizationExportRedactionPolicy
    ) -> String {
        let redacted = redactionPolicy.redactedURLString(path)
        guard redacted.count > 90 else {
            return redacted
        }
        let index = redacted.index(redacted.startIndex, offsetBy: 87)
        return "\(redacted[..<index])..."
    }

    private static func statusLabel(for session: SessionRecord) -> String {
        if let statusCode = session.response?.statusCode {
            return "\(statusCode)"
        }
        if session.state == .failed {
            return "Failed"
        }
        return session.state.rawValue.capitalized
    }

    private static func isErrorStatus(_ statusCode: Int?) -> Bool {
        guard let statusCode else {
            return false
        }
        return statusCode >= 400
    }

    private static func isFailure(_ session: SessionRecord) -> Bool {
        session.state == .failed || session.failure != nil || isErrorStatus(session.response?.statusCode)
    }

    private static func headerValue(_ name: String, in headers: [HTTPHeaderField]?) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func warnings(
        rows: [Row],
        request: VisualizationExportRequest,
        dimensions: VisualizationExportDimensions
    ) -> [String] {
        var warnings: [String] = []
        if rows.count > 80 {
            warnings.append("High row count: \(rows.count) requests may be hard to read.")
        }
        let labelBudget = max(1, dimensions.width / 170)
        if rows.count > labelBudget * 12 {
            warnings.append("Dense labels: use a larger resolution or narrower scope.")
        }
        if request.annotations.showHostLabels && rows.count > max(12, dimensions.width / 220) {
            warnings.append("Host labels may overflow at this resolution.")
        }
        if request.includedMetadata.includeLegend && rows.count > max(16, dimensions.height / 28) {
            warnings.append("Legend may compete with dense timeline rows.")
        }
        let pixelArea = max(dimensions.width * dimensions.height, 1)
        let marksPerPixel = Double(rows.count) / Double(pixelArea)
        if marksPerPixel > 0.00004 {
            warnings.append("High mark density may obscure short-duration requests.")
        }
        if rows.contains(where: { $0.duration < 0.08 }) {
            warnings.append("Very short requests are shown with minimum-width bars.")
        }
        if request.annotations.showRequestNames && request.annotations.showStatusCodes && rows.count > labelBudget * 8 {
            warnings.append("Overlapping request labels and status badges are likely at this density.")
        }
        return warnings
    }

    private static func dataSummary(rows: [Row], warnings: [String]) -> VisualizationExportDataSummary {
        VisualizationExportDataSummary(
            sessionCount: rows.count,
            hostCount: Set(rows.map(\.host)).count,
            warningCount: warnings.count,
            errorCount: rows.filter(\.isFailure).count,
            notes: warnings
        )
    }
}
