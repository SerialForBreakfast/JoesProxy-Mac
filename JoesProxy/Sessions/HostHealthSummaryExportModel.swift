//
//  HostHealthSummaryExportModel.swift
//  JoesProxy
//
//  Aggregates host-level health metrics for visualization export PNGs.
//

import Foundation

enum VisualizationExportHostHealthBucketSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case thirtySeconds
    case oneMinute
    case fiveMinutes
    case fifteenMinutes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thirtySeconds: return "30 seconds"
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        }
    }
}

extension VisualizationExportChartConfiguration {
    /// When enabled, the export renders one health summary per host instead of a single aggregate.
    var hostHealthComparisonEnabled: Bool {
        groupingMode == .host || (optionFlags["hostHealthComparisonMode"] ?? false)
    }

    var hostHealthBucketSize: VisualizationExportHostHealthBucketSize {
        guard let rawValue = optionValues["hostHealthBucketSize"],
              let size = VisualizationExportHostHealthBucketSize(rawValue: rawValue) else {
            return .oneMinute
        }
        return size
    }

    mutating func setHostHealthBucketSize(_ size: VisualizationExportHostHealthBucketSize) {
        optionValues["hostHealthBucketSize"] = size.rawValue
    }

    mutating func setHostHealthComparisonMode(_ enabled: Bool) {
        optionFlags["hostHealthComparisonMode"] = enabled
        if enabled {
            groupingMode = .host
        } else if groupingMode == .host {
            groupingMode = .none
        }
    }
}

struct HostHealthSummaryExportModel: Equatable, Sendable {
    struct TimeBucket: Equatable, Sendable, Identifiable {
        let id: Int
        let startOffset: TimeInterval
        let endOffset: TimeInterval
        let requestCount: Int
        let errorCount: Int
        let medianLatencyMs: Double?
        /// Count of requests in this bucket captured under an active MCP effect (AJ-2) — e.g.
        /// "N of these M requests were under an active throttle." Never re-derived from the live
        /// rule store; sourced from each session's immutable capture-time attribution snapshot.
        let mcpAttributedRequestCount: Int
    }

    struct PeakErrorWindow: Equatable, Sendable {
        let startOffset: TimeInterval
        let endOffset: TimeInterval
        let errorCount: Int
    }

    struct HostSummary: Equatable, Sendable, Identifiable {
        let id: String
        let host: String
        let requestCount: Int
        let successCount: Int
        let errorCount: Int
        let clientErrorCount: Int
        let serverErrorCount: Int
        let timeoutCount: Int
        let p50LatencyMs: Double?
        let p95LatencyMs: Double?
        let buckets: [TimeBucket]
        let peakErrorWindow: PeakErrorWindow?
        /// Count of this host's requests captured under an active MCP effect (AJ-2).
        let mcpAttributedRequestCount: Int
    }

    let request: VisualizationExportRequest
    let comparisonMode: Bool
    let bucketSize: VisualizationExportHostHealthBucketSize
    let hosts: [HostSummary]
    let captureStart: Date
    let captureEnd: Date
    let totalDuration: TimeInterval
    let warnings: [String]
    let dataSummary: VisualizationExportDataSummary

    init(request: VisualizationExportRequest, sessions: [SessionRecord]) {
        self.request = request
        self.comparisonMode = request.chartConfiguration.hostHealthComparisonEnabled
        self.bucketSize = request.chartConfiguration.hostHealthBucketSize

        let scopedSessions = Self.scopedSessions(sessions, for: request)
        let captureStart = scopedSessions.map(\.timing.startedAt).min() ?? Date()
        let captureEnd = scopedSessions.map { session in
            session.timing.completedAt
                ?? session.timing.startedAt.addingTimeInterval(max(session.timing.duration ?? 0.05, 0.05))
        }.max() ?? captureStart
        self.captureStart = captureStart
        self.captureEnd = captureEnd
        self.totalDuration = max(captureEnd.timeIntervalSince(captureStart), bucketSize.duration)

        let groupedSessions = Self.groupedSessions(
            scopedSessions,
            comparisonMode: comparisonMode
        )
        let allHosts = Self.buildHostSummaries(
            groupedSessions: groupedSessions,
            captureStart: captureStart,
            totalDuration: totalDuration,
            bucketSize: bucketSize.duration
        )
        let totalHostCount = allHosts.count
        let resolvedHosts = Array(allHosts.prefix(comparisonMode ? 8 : 1))
        let resolvedWarnings = Self.warnings(
            hosts: resolvedHosts,
            totalHostCount: totalHostCount,
            request: request,
            dimensions: request.dimensions
        )
        let resolvedDataSummary = Self.dataSummary(
            hosts: resolvedHosts,
            warnings: resolvedWarnings
        )
        self.hosts = resolvedHosts
        self.warnings = resolvedWarnings
        self.dataSummary = resolvedDataSummary
    }

    private static func buildHostSummaries(
        groupedSessions: [String: [SessionRecord]],
        captureStart: Date,
        totalDuration: TimeInterval,
        bucketSize: TimeInterval
    ) -> [HostSummary] {
        groupedSessions.map { hostLabel, hostSessions in
            makeHostSummary(
                host: hostLabel,
                sessions: hostSessions,
                captureStart: captureStart,
                totalDuration: totalDuration,
                bucketSize: bucketSize
            )
        }
        .sorted { lhs, rhs in
            if lhs.requestCount == rhs.requestCount {
                return lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending
            }
            return lhs.requestCount > rhs.requestCount
        }
    }

    private static func scopedSessions(
        _ sessions: [SessionRecord],
        for request: VisualizationExportRequest
    ) -> [SessionRecord] {
        sessions.filter { session in
            switch request.sourceScope {
            case .filteredResults, .selectedSession, .selectedSessions, .manifestAssets, .playbackFlow:
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

    private static func groupedSessions(
        _ sessions: [SessionRecord],
        comparisonMode: Bool
    ) -> [String: [SessionRecord]] {
        if comparisonMode {
            var grouped: [String: [SessionRecord]] = [:]
            for session in sessions {
                grouped[session.request.host, default: []].append(session)
            }
            return grouped
        }
        return ["All Hosts": sessions]
    }

    private static func makeHostSummary(
        host: String,
        sessions: [SessionRecord],
        captureStart: Date,
        totalDuration: TimeInterval,
        bucketSize: TimeInterval
    ) -> HostSummary {
        let metrics = sessions.map { sessionMetrics(for: $0) }
        let latencies = metrics.compactMap(\.latencyMs)
        let buckets = makeBuckets(
            metrics: metrics,
            captureStart: captureStart,
            totalDuration: totalDuration,
            bucketSize: bucketSize
        )
        let peakErrorWindow = buckets
            .filter { $0.errorCount > 0 }
            .max(by: { $0.errorCount < $1.errorCount })
            .map {
                PeakErrorWindow(
                    startOffset: $0.startOffset,
                    endOffset: $0.endOffset,
                    errorCount: $0.errorCount
                )
            }

        return HostSummary(
            id: host.lowercased(),
            host: host,
            requestCount: metrics.count,
            successCount: metrics.filter { !$0.isFailure }.count,
            errorCount: metrics.filter(\.isFailure).count,
            clientErrorCount: metrics.filter(\.isClientError).count,
            serverErrorCount: metrics.filter(\.isServerError).count,
            timeoutCount: metrics.filter(\.isTimeout).count,
            p50LatencyMs: percentile(latencies, quantile: 0.50),
            p95LatencyMs: percentile(latencies, quantile: 0.95),
            buckets: buckets,
            peakErrorWindow: peakErrorWindow,
            mcpAttributedRequestCount: metrics.filter(\.hasMCPAttribution).count
        )
    }

    private struct SessionMetrics {
        let startedAt: Date
        let latencyMs: Double?
        let isFailure: Bool
        let isClientError: Bool
        let isServerError: Bool
        let isTimeout: Bool
        let hasMCPAttribution: Bool
    }

    private static func sessionMetrics(for session: SessionRecord) -> SessionMetrics {
        let statusCode = session.response?.statusCode
        let isFailure = isFailure(session)
        return SessionMetrics(
            startedAt: session.timing.startedAt,
            latencyMs: session.timing.duration.map { max($0, 0) * 1_000 },
            isFailure: isFailure,
            isClientError: isClientError(statusCode),
            isServerError: isServerError(statusCode),
            isTimeout: isTimeout(session),
            hasMCPAttribution: session.response?.mcpAttribution != nil
        )
    }

    private static func makeBuckets(
        metrics: [SessionMetrics],
        captureStart: Date,
        totalDuration: TimeInterval,
        bucketSize: TimeInterval
    ) -> [TimeBucket] {
        let bucketCount = max(1, Int(ceil(totalDuration / bucketSize)))
        return (0..<bucketCount).map { index in
            let startOffset = TimeInterval(index) * bucketSize
            let endOffset = min(TimeInterval(index + 1) * bucketSize, totalDuration)
            let bucketMetrics = metrics.filter { metric in
                let offset = metric.startedAt.timeIntervalSince(captureStart)
                return offset >= startOffset && offset < endOffset
            }
            let latencies = bucketMetrics.compactMap(\.latencyMs)
            return TimeBucket(
                id: index,
                startOffset: startOffset,
                endOffset: endOffset,
                requestCount: bucketMetrics.count,
                errorCount: bucketMetrics.filter(\.isFailure).count,
                medianLatencyMs: percentile(latencies, quantile: 0.50),
                mcpAttributedRequestCount: bucketMetrics.filter(\.hasMCPAttribution).count
            )
        }
    }

    private static func percentile(_ values: [Double], quantile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clampedQuantile = min(max(quantile, 0), 1)
        let index = Int(ceil(clampedQuantile * Double(sorted.count))) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    private static func isFailure(_ session: SessionRecord) -> Bool {
        session.state == .failed
            || session.failure != nil
            || isErrorStatus(session.response?.statusCode)
    }

    private static func isErrorStatus(_ statusCode: Int?) -> Bool {
        guard let statusCode else { return false }
        return statusCode >= 400
    }

    private static func isClientError(_ statusCode: Int?) -> Bool {
        guard let statusCode else { return false }
        return (400..<500).contains(statusCode)
    }

    private static func isServerError(_ statusCode: Int?) -> Bool {
        guard let statusCode else { return false }
        return statusCode >= 500
    }

    private static func isTimeout(_ session: SessionRecord) -> Bool {
        session.failure?.bucket == NetworkFailureBucket.timeout.rawValue
    }

    private static func warnings(
        hosts: [HostSummary],
        totalHostCount: Int,
        request: VisualizationExportRequest,
        dimensions: VisualizationExportDimensions
    ) -> [String] {
        var warnings: [String] = []
        let totalRequests = hosts.reduce(0) { $0 + $1.requestCount }
        if totalRequests == 0 {
            warnings.append("No requests matched the selected host health scope.")
        }
        if request.comparisonMode && totalHostCount > 8 {
            warnings.append("Host comparison is limited to the top 8 hosts by request count.")
        }
        if hosts.contains(where: { $0.p50LatencyMs == nil }) {
            warnings.append("Some requests are missing timing data; latency percentiles may be partial.")
        }
        if totalRequests > 250 {
            warnings.append("Large capture sets are summarized by time buckets to keep the export readable.")
        }
        if request.comparisonMode && hosts.count > max(3, dimensions.width / 420) {
            warnings.append("Many hosts may crowd comparison cards at this resolution.")
        }
        return warnings
    }

    private static func dataSummary(
        hosts: [HostSummary],
        warnings: [String]
    ) -> VisualizationExportDataSummary {
        let totalRequests = hosts.reduce(0) { $0 + $1.requestCount }
        return VisualizationExportDataSummary(
            sessionCount: totalRequests,
            hostCount: hosts.count,
            warningCount: warnings.count,
            errorCount: hosts.reduce(0) { $0 + $1.errorCount },
            notes: warnings
        )
    }
}

private extension VisualizationExportRequest {
    var comparisonMode: Bool {
        chartConfiguration.hostHealthComparisonEnabled
    }
}
