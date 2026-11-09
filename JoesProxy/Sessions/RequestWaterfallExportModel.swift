//
//  RequestWaterfallExportModel.swift
//  JoesProxy
//
//  Builds aligned waterfall rows for request sequencing export PNGs.
//

import Foundation

extension VisualizationExportChartConfiguration {
    /// Highlights the slowest requests in the waterfall export.
    var waterfallHighlightSlowestRequests: Bool {
        optionFlags["waterfallHighlightSlowestRequests"] ?? true
    }

    /// Limits the waterfall to bootstrap/setup categories when classification is available.
    var waterfallSetupPathOnly: Bool {
        optionFlags["waterfallSetupPathOnly"] ?? false
    }

    mutating func setWaterfallHighlightSlowestRequests(_ enabled: Bool) {
        optionFlags["waterfallHighlightSlowestRequests"] = enabled
    }

    mutating func setWaterfallSetupPathOnly(_ enabled: Bool) {
        optionFlags["waterfallSetupPathOnly"] = enabled
    }
}

struct RequestWaterfallExportModel: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let id: SessionRecord.ID
        let method: String
        let host: String
        let pathSummary: String
        let statusLabel: String
        let categoryTitle: String
        let categoryLane: TimelineLane
        let startedAt: Date
        let startOffset: TimeInterval
        let duration: TimeInterval
        let isFailure: Bool
        let isSlowestHighlight: Bool
        /// Immutable MCP effect attribution captured at response time (AJ-2); never re-derived
        /// from the live rule store, so it survives rule edits, disable, delete, and detach.
        let mcpEffectAnnotation: MCPCaptureAttribution?
    }

    let request: VisualizationExportRequest
    let rows: [Row]
    let captureStart: Date
    let captureEnd: Date
    let totalDuration: TimeInterval
    let highlightSlowestRequests: Bool
    let setupPathOnly: Bool
    let warnings: [String]
    let dataSummary: VisualizationExportDataSummary

    init(request: VisualizationExportRequest, sessions: [SessionRecord]) {
        self.request = request
        self.highlightSlowestRequests = request.chartConfiguration.waterfallHighlightSlowestRequests
        self.setupPathOnly = request.chartConfiguration.waterfallSetupPathOnly

        let captureBaseStart = sessions.map(\.timing.startedAt).min() ?? Date()
        let scopedSessions = Self.scopedSessions(sessions, for: request)
        let classifiedSessions = Self.classifiedSessions(
            scopedSessions,
            setupPathOnly: setupPathOnly
        )
        let orderedSessions = Self.orderedSessions(
            classifiedSessions,
            configuration: request.chartConfiguration
        )
        let filteredSessions = request.chartConfiguration.showFailedOnly
            ? orderedSessions.filter(Self.isFailure)
            : orderedSessions
        let start = filteredSessions.map(\.timing.startedAt).min() ?? captureBaseStart
        let end = filteredSessions.map { session in
            session.timing.completedAt
                ?? session.timing.startedAt.addingTimeInterval(max(session.timing.duration ?? 0.05, 0.05))
        }.max() ?? start
        let offsetBase = Self.offsetBase(
            request: request,
            captureBaseStart: captureBaseStart,
            visibleStart: start
        )
        self.captureStart = start
        self.captureEnd = end
        self.totalDuration = max(end.timeIntervalSince(start), 0.05)

        let builtRows = Self.buildRows(
            sessions: filteredSessions,
            request: request,
            offsetBase: offsetBase,
            highlightSlowestRequests: highlightSlowestRequests
        )
        self.rows = builtRows
        let resolvedWarnings = Self.warnings(
            rows: builtRows,
            request: request,
            dimensions: request.dimensions,
            scopedSessionCount: scopedSessions.count,
            setupPathOnly: setupPathOnly
        )
        self.warnings = resolvedWarnings
        self.dataSummary = Self.dataSummary(rows: builtRows, warnings: resolvedWarnings)
    }

    private static let classifier = TimelineClassificationService()
    private static let setupPathLanes: Set<TimelineLane> = [.authConfig, .api, .manifest, .drmLicense]

    private static func scopedSessions(
        _ sessions: [SessionRecord],
        for request: VisualizationExportRequest
    ) -> [SessionRecord] {
        sessions.filter { session in
            switch request.sourceScope {
            case .selectedSession, .selectedSessions, .filteredResults, .manifestAssets, .playbackFlow:
                return true
            case .host(let host):
                return session.request.host.caseInsensitiveCompare(host) == .orderedSame
            case .hostGroup(let pattern):
                let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalizedPattern.isEmpty else { return true }
                return session.request.host.lowercased().contains(normalizedPattern)
            case .timeRange(let range):
                let completedAt = session.timing.completedAt
                    ?? session.timing.startedAt.addingTimeInterval(max(session.timing.duration ?? 0.05, 0.05))
                return session.timing.startedAt <= range.end && completedAt >= range.start
            }
        }
    }

    private static func classifiedSessions(
        _ sessions: [SessionRecord],
        setupPathOnly: Bool
    ) -> [SessionRecord] {
        guard setupPathOnly else { return sessions }
        return sessions.filter { session in
            setupPathLanes.contains(classifier.classify(session).lane)
        }
    }

    private static func orderedSessions(
        _ sessions: [SessionRecord],
        configuration: VisualizationExportChartConfiguration
    ) -> [SessionRecord] {
        sessions.sorted { lhs, rhs in
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

    private static func buildRows(
        sessions: [SessionRecord],
        request: VisualizationExportRequest,
        offsetBase: Date,
        highlightSlowestRequests: Bool
    ) -> [Row] {
        let slowestHighlightIDs = slowestHighlightIDs(
            for: sessions,
            enabled: highlightSlowestRequests
        )
        return sessions.map { session in
            let classification = classifier.classify(session)
            let duration = max(session.timing.duration ?? 0.05, 0.05)
            return Row(
                id: session.id,
                method: session.request.method,
                host: session.request.host,
                pathSummary: pathSummary(
                    session.request.path,
                    redactionPolicy: request.redactionPolicy
                ),
                statusLabel: statusLabel(for: session),
                categoryTitle: classification.lane.title,
                categoryLane: classification.lane,
                startedAt: session.timing.startedAt,
                startOffset: max(0, session.timing.startedAt.timeIntervalSince(offsetBase)),
                duration: duration,
                isFailure: isFailure(session),
                isSlowestHighlight: slowestHighlightIDs.contains(session.id),
                mcpEffectAnnotation: session.response?.mcpAttribution
            )
        }
    }

    private static func slowestHighlightIDs(
        for sessions: [SessionRecord],
        enabled: Bool
    ) -> Set<SessionRecord.ID> {
        guard enabled, !sessions.isEmpty else { return [] }

        let ranked = sessions.sorted { lhs, rhs in
            let lhsDuration = lhs.timing.duration ?? 0
            let rhsDuration = rhs.timing.duration ?? 0
            if lhsDuration == rhsDuration {
                return lhs.timing.startedAt < rhs.timing.startedAt
            }
            return lhsDuration > rhsDuration
        }
        let highlightCount = min(3, ranked.count)
        return Set(ranked.prefix(highlightCount).map(\.id))
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
        guard let statusCode else { return false }
        return statusCode >= 400
    }

    private static func isFailure(_ session: SessionRecord) -> Bool {
        session.state == .failed
            || session.failure != nil
            || isErrorStatus(session.response?.statusCode)
    }

    private static func warnings(
        rows: [Row],
        request: VisualizationExportRequest,
        dimensions: VisualizationExportDimensions,
        scopedSessionCount: Int,
        setupPathOnly: Bool
    ) -> [String] {
        var warnings: [String] = []
        if rows.isEmpty {
            if setupPathOnly && scopedSessionCount > 0 {
                warnings.append("No setup-path requests matched the current scope and filters.")
            } else {
                warnings.append("No requests matched the selected waterfall scope.")
            }
        }
        if case .selectedSessions = request.sourceScope, Set(rows.map(\.host)).count > 1 {
            warnings.append("Logical flow grouping is not inferred yet; rows are ordered by start time within the selection.")
        }
        if case .hostGroup = request.sourceScope {
            warnings.append("Host-group waterfalls use scope order rather than inferred playback flow.")
        }
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
        if rows.contains(where: { $0.duration < 0.08 }) {
            warnings.append("Very short requests are shown with minimum-width bars.")
        }
        if highlightSlowestRequests(in: request) && rows.filter(\.isSlowestHighlight).count > max(3, rows.count / 4) {
            warnings.append("Multiple requests share similar durations; slowest highlighting may include ties.")
        }
        return warnings
    }

    private static func highlightSlowestRequests(in request: VisualizationExportRequest) -> Bool {
        request.chartConfiguration.waterfallHighlightSlowestRequests
    }

    private static func dataSummary(
        rows: [Row],
        warnings: [String]
    ) -> VisualizationExportDataSummary {
        VisualizationExportDataSummary(
            sessionCount: rows.count,
            hostCount: Set(rows.map(\.host)).count,
            warningCount: warnings.count,
            errorCount: rows.filter(\.isFailure).count,
            notes: warnings
        )
    }
}
