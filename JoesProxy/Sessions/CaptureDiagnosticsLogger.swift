//
//  CaptureDiagnosticsLogger.swift
//  JoesProxy
//
//  Builds redacted, bounded long-capture summaries for shareable diagnostics.
//

import Foundation

/// Logical collection counts only; shared value storage prevents interpreting these as heap bytes.
struct WorkspaceRetentionCounts: Equatable, Sendable {
    let summaries: Int
    let filteredIDs: Int
    let tableRows: Int
    let searchTexts: Int
    let explorerFolders: Int
    let explorerSummaries: Int
    let retentionPresentationSkips: Int
    var activeFilterSnapshots: Int = 0
    var activeFilterSnapshotRecords: Int = 0

    var logMessage: String {
        "workspaceSummaries=\(summaries) workspaceFilteredIDs=\(filteredIDs) workspaceTableRows=\(tableRows) "
            + "workspaceSearchTexts=\(searchTexts) workspaceExplorerFolders=\(explorerFolders) "
            + "workspaceExplorerSummaries=\(explorerSummaries) retentionPresentationSkips=\(retentionPresentationSkips)"
            + " activeFilterSnapshots=\(activeFilterSnapshots) activeFilterSnapshotRecords=\(activeFilterSnapshotRecords)"
    }
}

struct CaptureDiagnosticsSummary: Equatable, Sendable {
    let sessionCount: Int
    let retainedBodyBytes: Int
    let droppedSessionCount: Int
    let truncatedBodyCount: Int
    let strippedBodyCount: Int
    let processMetrics: AppProcessMetrics
    let captureDuration: TimeInterval?
    let transport: CaptureTransportDiagnosticsSnapshot
    let topHosts: [RankedValue]
    let topPathCategories: [RankedValue]
    let stateCounts: [String: Int]
    let statusFamilies: [String: Int]
    let workspaceRetention: WorkspaceRetentionCounts?
    let retainedHeaderFieldCount: Int?

    struct RankedValue: Equatable, Sendable {
        let value: String
        let count: Int
    }

    static func make(
        metrics: CaptureHealthMetrics,
        sessions: [SessionRecord],
        transport: CaptureTransportDiagnosticsSnapshot = .empty,
        topLimit: Int = 5,
        workspaceRetention: WorkspaceRetentionCounts? = nil,
        retainedHeaderFieldCount: Int? = nil
    ) -> CaptureDiagnosticsSummary {
        CaptureDiagnosticsSummary(
            sessionCount: metrics.sessionCount,
            retainedBodyBytes: metrics.retainedBodyBytes,
            droppedSessionCount: metrics.droppedSessionCount,
            truncatedBodyCount: countTruncatedBodies(in: sessions),
            strippedBodyCount: countStrippedBodies(in: sessions),
            processMetrics: metrics.processMetrics,
            captureDuration: metrics.captureDuration,
            transport: transport,
            topHosts: rank(sessions.map(\.request.host), limit: topLimit),
            topPathCategories: rank(
                sessions.map { CaptureDiagnosticsRedaction.pathCategory(for: $0.request.path) },
                limit: topLimit
            ),
            stateCounts: countByKey(sessions.map { $0.state.rawValue }),
            statusFamilies: countByKey(sessions.compactMap { statusFamily(for: $0.response?.statusCode) }),
            workspaceRetention: workspaceRetention,
            retainedHeaderFieldCount: retainedHeaderFieldCount
        )
    }

    var logMessage: String {
        [
            "capture_summary",
            "requestProgress=" + CaptureRequestProgressStage.allCases.map { stage in
                let progress = transport.requestProgress[stage, default: CaptureRequestProgress()]
                let timestamp = progress.lastObservedAt.map { String($0.timeIntervalSince1970) } ?? "none"
                return "\(stage.rawValue):\(progress.count)@\(timestamp)"
            }.joined(separator: ","),
            workspaceRetention?.logMessage ?? "workspaceRetention=unavailable",
            "retainedHeaderFields=\(retainedHeaderFieldCount.map(String.init) ?? "unavailable")",
            "sessions=\(sessionCount)",
            "duration=\(formatDuration(captureDuration))",
            "retainedBodyBytes=\(retainedBodyBytes)",
            "captureReservedBytes=\(transport.captureAdmission?.reservedBytes ?? 0)",
            "capturePeakReservedBytes=\(transport.captureAdmission?.peakReservedBytes ?? 0)",
            "capturePending=\(transport.captureAdmission?.pendingCaptures ?? 0)",
            "captureAdmissionRejected=\(transport.captureAdmission?.rejectedCaptures ?? 0)",
            "captureAdmissionMetadataOnly=\(transport.captureAdmission?.metadataOnlyCaptures ?? 0)",
            "captureAdmissionPaused=\(transport.captureAdmission?.paused ?? false)",
            "captureCollecting=\(transport.captureAdmission?.collectingCount ?? 0)",
            "captureStoreDelivery=\(transport.captureAdmission?.storeDeliveryCount ?? 0)",
            "captureRejectionReason=\(transport.captureAdmission?.lastRejectionReason?.rawValue ?? "none")",
            "captureOldestReservationSeconds=\(Int(transport.captureAdmission?.oldestReservationAge ?? 0))",
            "captureLastStoreDelivery=\(transport.captureAdmission?.lastStoreDeliveryAt?.timeIntervalSince1970 ?? 0)",
            "uploadActiveSpools=\(transport.uploadActiveSpools)",
            "uploadPeakSpools=\(transport.uploadPeakSpools)",
            "uploadStorageNeedsRecovery=\(transport.uploadStorageNeedsRecovery)",
            "transportQueuedBytes=\(RelayBacklogBudget.shared.snapshot.bytes)",
            "transportPeakQueuedBytes=\(RelayBacklogBudget.shared.snapshot.peakBytes)",
            "transportPendingWrites=\(RelayBacklogBudget.shared.snapshot.operations)",
            "mutationBufferReservations=\(MutationBufferBudget.shared.activeCount)",
            "mutationBufferCapacitySkips=\(MutationBufferBudget.shared.rejectedCount)",
            "droppedSessions=\(droppedSessionCount)",
            "upstreamResponseBytes=\(transport.upstreamResponseBytesForwarded)",
            "activeChannels=\(transport.activeProxyChannels)",
            "truncatedBodies=\(truncatedBodyCount)",
            "strippedBodies=\(strippedBodyCount)",
            "expectedDisconnects=\(transport.expectedClientDisconnectCount)",
            "unexpectedErrors=\(transport.unexpectedChannelErrorCount)",
            "expectedWriteFailures=\(transport.expectedClientWriteFailureCount)",
            "unexpectedWriteFailures=\(transport.unexpectedClientWriteFailureCount)",
            "leafCertCacheHits=\(transport.leafCertCacheHits)/\(transport.leafCertCacheHits + transport.leafCertCacheMisses)",
            "residentMemoryBytes=\(processMetrics.residentMemoryBytes)",
            "cpuPercent=\(formatCPU(processMetrics.cpuPercent))",
            "states=\(formatDictionary(stateCounts))",
            "statusFamilies=\(formatDictionary(statusFamilies))",
            "topHosts=\(formatRanked(topHosts))",
            "topPaths=\(formatRanked(topPathCategories))"
        ].joined(separator: " ")
    }

    private static func countTruncatedBodies(in sessions: [SessionRecord]) -> Int {
        sessions.filter { session in
            session.request.bodyTruncated || session.response?.bodyTruncated == true
        }.count
    }

    private static func countStrippedBodies(in sessions: [SessionRecord]) -> Int {
        sessions.filter { session in
            session.request.bodyDeferred
                || session.response?.bodyDeferred == true
                || session.request.recordingBodyOmissionReason != nil
                || session.response?.recordingBodyOmissionReason != nil
        }.count
    }

    private static func rank(_ values: [String], limit: Int) -> [RankedValue] {
        countByKey(values)
            .map { RankedValue(value: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.value < $1.value
                }
                return $0.count > $1.count
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func countByKey(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { counts, value in
            counts[value, default: 0] += 1
        }
    }

    private static func statusFamily(for statusCode: Int?) -> String? {
        guard let statusCode else { return nil }
        return "\(statusCode / 100)xx"
    }

    private func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "n/a" }
        return "\(Int(duration.rounded()))s"
    }

    private func formatCPU(_ cpuPercent: Double?) -> String {
        guard let cpuPercent else { return "n/a" }
        return String(format: "%.1f", cpuPercent)
    }

    private func formatDictionary(_ values: [String: Int]) -> String {
        guard !values.isEmpty else { return "none" }
        return values
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }

    private func formatRanked(_ values: [RankedValue]) -> String {
        guard !values.isEmpty else { return "none" }
        return values
            .map { "\($0.value):\($0.count)" }
            .joined(separator: ",")
    }
}

struct CaptureDiagnosticsLogCadence: Equatable, Sendable {
    var interval: TimeInterval
    private(set) var lastEmitDate: Date?

    init(interval: TimeInterval = 60, lastEmitDate: Date? = nil) {
        self.interval = interval
        self.lastEmitDate = lastEmitDate
    }

    mutating func shouldEmit(now: Date, isEnabled: Bool, sessionCount: Int) -> Bool {
        guard isEnabled, sessionCount > 0 else {
            return false
        }

        if let lastEmitDate, now.timeIntervalSince(lastEmitDate) < interval {
            return false
        }

        lastEmitDate = now
        return true
    }

    mutating func reset() {
        lastEmitDate = nil
    }
}
