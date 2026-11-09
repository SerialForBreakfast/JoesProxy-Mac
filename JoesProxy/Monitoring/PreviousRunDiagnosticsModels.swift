//
//  PreviousRunDiagnosticsModels.swift
//  JoesProxy
//
//  Content-free previous-run diagnostic schema, assessment and plain-text report
//  (ADR-Startup-Recovery-Diagnostics-Copy-And-Export).
//

import Foundation

/// One persisted health sample. Aggregate process and admission values only.
struct PreviousRunHealthSample: Codable, Equatable, Sendable {
    let at: Date
    let physicalFootprintBytes: UInt64?
    let cpuPercent: Double?
    let admissionPaused: Bool?
}

/// Whether the rolling-capture checkpoint was observed being written by this run.
enum PreviousRunCheckpointAssociation: String, Codable, Sendable {
    case savedDuringRun = "saved during this run"
    case predatesRun = "predates this run"
    case unavailable
}

/// How the latest responsiveness incident relates to a run. Only `correlated` incidents are
/// attributed; nothing is matched by timestamp proximity.
enum PreviousRunIncidentAssociation: String, Codable, Sendable {
    case correlated
    case uncorrelatedLegacy = "present without run identity; not attributed"
    case otherRun = "belongs to another run; not attributed"
    case none = "none recorded"
    case unreadable
}

/// Last-known facts owned by the main actor, pushed on change with their observation time so the
/// background writer never waits on the main thread.
struct PreviousRunOperatingContext: Codable, Equatable, Sendable {
    var observedAt: Date
    var workspace: String?
    var retainedRequestCount: Int?
    var mcpRunning: Bool?
    var pendingApprovalCount: Int?
    var checkpointSavedAt: Date?
    var checkpointSessionCount: Int?
    /// Sanitized code only. Checkpoint error messages can contain file names and are never stored.
    var checkpointErrorCode: String?
}

/// Allowlisted envelope persisted during a run and finalized at the next launch.
///
/// Excludes by schema: request/response content, headers, hosts, URLs, paths, file names, client
/// identities, rule contents, raw error text and log lines. Missing measurements stay `nil`.
struct PreviousRunDiagnosticEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    static let maximumRecentSamples = 60

    struct Admission: Codable, Equatable, Sendable {
        var paused: Bool
        var lastRejectionReasonCode: String?
        var reservedBytes: Int
        var peakReservedBytes: Int
        var reservedLimitBytes: Int?
        var collectingCount: Int
        var storeDeliveryCount: Int
        var oldestPendingAgeSeconds: Double?
        var rejectedCaptures: Int
        var gapCount: Int
        var lastStoreDeliveryAt: Date?
        var metadataOnlyCaptures: Int?
    }

    struct Incident: Codable, Equatable, Sendable {
        var detectedAt: Date
        var recoveredAt: Date?
        var maximumAcknowledgementDelaySeconds: Double?
    }

    var schemaVersion = Self.currentSchemaVersion
    var runID: String
    var producerVersion: String
    var producerBuild: String
    var osVersion: String
    var architecture: String
    var physicalMemoryBytes: UInt64
    var startedAt: Date
    var lastSavedHealthAt: Date
    /// `ProcessInfo.systemUptime` values: monotonic and excluding sleep, unlike the wall dates.
    var startUptime: Double
    var lastSampleUptime: Double
    var healthCadenceSeconds: Double
    var cleanShutdownRecorded = false
    /// Diagnostic writes that failed during the run (for example, a full disk).
    var failedWriteCount = 0
    var lastPhysicalFootprintBytes: UInt64?
    var sampledPeakPhysicalFootprintBytes: UInt64?
    var processPeakResidentBytes: UInt64?
    var lastCPUPercent: Double?
    var completedResponsesCumulative: UInt64?
    var failedResponsesCumulative: UInt64?
    var activeProxyChannels: Int?
    var admission: Admission?
    var context: PreviousRunOperatingContext?
    var incident: Incident?
    /// `nil` until the next launch finalizes this run.
    var incidentAssociation: PreviousRunIncidentAssociation?
    var recentSamples: [PreviousRunHealthSample] = []
    var omittedSampleCount = 0

    var checkpointAssociation: PreviousRunCheckpointAssociation {
        guard let savedAt = context?.checkpointSavedAt else { return .unavailable }
        return savedAt >= startedAt ? .savedDuringRun : .predatesRun
    }
}

/// A frozen report for one finalized run. Copy, save and share all use `text`.
struct PreviousRunReport: Equatable, Sendable {
    let reportID: String
    let envelope: PreviousRunDiagnosticEnvelope
    let readerVersion: String
    let readerBuild: String
    let text: String

    init(envelope: PreviousRunDiagnosticEnvelope, readerVersion: String, readerBuild: String,
         reportID: String = UUID().uuidString) {
        self.reportID = reportID
        self.envelope = envelope
        self.readerVersion = readerVersion
        self.readerBuild = readerBuild
        self.text = PreviousRunDiagnosticsFormatter.text(
            envelope: envelope, reportID: reportID, readerVersion: readerVersion, readerBuild: readerBuild)
    }
}

/// Why a previous run could not be reported in full.
enum PreviousRunUnreadableReason: String, Error, Sendable {
    case malformed = "unreadable"
    case oversized = "larger than the supported size"
    case unsupportedSchema = "from an unsupported diagnostic schema"
}

/// Deterministic, evidence-qualified observations. Never a root-cause claim.
enum PreviousRunAssessmentEngine {
    static let maximumObservations = 3

    static func observations(for envelope: PreviousRunDiagnosticEnvelope) -> [String] {
        var items: [String] = []
        if let admission = envelope.admission, admission.paused {
            items.append("Capture admission was paused at the last saved sample; \(admission.storeDeliveryCount) captures were queued for store delivery. Next: include this report if capture stopped updating.")
        }
        if envelope.incidentAssociation == .correlated, let incident = envelope.incident {
            if incident.recoveredAt == nil {
                items.append("A main-thread acknowledgement delay was recorded for this run; recovery was not recorded. Next: include this report with any description of the unresponsive period.")
            } else {
                items.append("A main-thread acknowledgement delay was recorded for this run and later recovered.")
            }
        }
        if envelope.context?.checkpointErrorCode != nil {
            items.append("Checkpoint writes reported a storage error; the saved capture may be older than the last run. Next: choose whether to restore it; nothing was restored automatically.")
        }
        if !envelope.cleanShutdownRecorded {
            items.append("Clean shutdown was not recorded; the cause is unknown (crash, force quit, power loss, OS termination or failed persistence).")
        }
        if items.isEmpty {
            items.append("No admission pause, storage error or correlated main-thread delay appears in the saved evidence. This does not rule out an unrecorded problem.")
        }
        return Array(items.prefix(maximumObservations))
    }
}

/// Bounded plain-text rendering (ADR §9). Provenance, shutdown state and qualifications come
/// first so truncation never removes them.
enum PreviousRunDiagnosticsFormatter {
    static let maximumBytes = 32 * 1024
    static let unavailable = "unavailable"

    static func text(envelope: PreviousRunDiagnosticEnvelope, reportID: String,
                     readerVersion: String, readerBuild: String) -> String {
        let e = envelope
        var lines = [
            "JoesProxy previous-run diagnostics — schema \(e.schemaVersion)",
            "Report: \(reportID); run: \(e.runID)",
            "Producer: \(e.producerVersion) (\(e.producerBuild)); reader: \(readerVersion) (\(readerBuild))",
            "Environment: macOS \(e.osVersion), \(e.architecture), \(bytes(e.physicalMemoryBytes)) RAM",
            "Started: \(iso(e.startedAt)); last saved health: \(iso(e.lastSavedHealthAt)); sample cadence \(Int(e.healthCadenceSeconds))s",
            "Shutdown: " + (e.cleanShutdownRecorded ? "clean shutdown recorded" : "clean shutdown was not recorded; cause unknown"),
            "Process age at last sample: wall \(duration(e.lastSavedHealthAt.timeIntervalSince(e.startedAt))), awake \(duration(e.lastSampleUptime - e.startUptime)) (a difference indicates sleep or a clock change; not capture duration)",
            "Memory: physical footprint last \(bytes(e.lastPhysicalFootprintBytes)), sampled peak \(bytes(e.sampledPeakPhysicalFootprintBytes)); process peak RSS \(bytes(e.processPeakResidentBytes))",
            "CPU at last sample: \(e.lastCPUPercent.map { String(format: "%.0f%%", $0) } ?? unavailable) (100% = one core)",
            "Capture: retained requests \(number(e.context?.retainedRequestCount)); completed responses \(number(e.completedResponsesCumulative)), failed \(number(e.failedResponsesCumulative)) (cumulative); active proxy channels \(number(e.activeProxyChannels))",
        ]
        if let a = e.admission {
            lines.append("Admission: \(a.paused ? "paused" : "not paused"); last rejection reason \(a.lastRejectionReasonCode ?? "none"); reserved \(bytes(a.reservedBytes))/\(bytes(a.reservedLimitBytes)), sampled peak \(bytes(a.peakReservedBytes))")
            lines.append("Pending: collecting \(a.collectingCount), store delivery \(a.storeDeliveryCount); oldest \(a.oldestPendingAgeSeconds.map { String(format: "%.1fs", $0) } ?? "none"); last store delivery \(a.lastStoreDeliveryAt.map(iso) ?? unavailable)")
            lines.append("Capture gaps: \(a.gapCount); rejected captures \(a.rejectedCaptures)")
            if let count = a.metadataOnlyCaptures {
                lines.append("Response body capture omitted under pressure: \(count); request metadata retained")
            }
        } else {
            lines.append("Admission: \(unavailable)")
        }
        let context = e.context
        lines.append("Recovery checkpoint: saved \(context?.checkpointSavedAt.map(iso) ?? unavailable) (\(e.checkpointAssociation.rawValue)); \(number(context?.checkpointSessionCount)) sessions; storage error \(context?.checkpointErrorCode ?? "none recorded")")
        lines.append("Operating context: workspace \(context?.workspace ?? unavailable); MCP \(context?.mcpRunning.map { $0 ? "running" : "stopped" } ?? unavailable); pending approvals \(number(context?.pendingApprovalCount)); observed \(context.map { iso($0.observedAt) } ?? unavailable)")
        lines.append("Responsiveness: " + responsiveness(e))
        lines.append("Evidence limits: " + qualifications(e).joined(separator: "; "))
        lines.append("Assessment: " + PreviousRunAssessmentEngine.observations(for: e).joined(separator: " "))
        lines.append("Next action — User: share this report with the maintainer if desired. Nothing was uploaded.")
        lines.append("Excluded: traffic content, headers, hosts, URLs, paths, file names, credentials, client identities and capture files.")
        if !e.recentSamples.isEmpty {
            lines.append("Recent health samples (UTC, footprint, CPU, admission):")
            for sample in e.recentSamples.reversed() {
                lines.append("  \(iso(sample.at)) \(bytes(sample.physicalFootprintBytes)) \(sample.cpuPercent.map { String(format: "%.0f%%", $0) } ?? unavailable) \(sample.admissionPaused.map { $0 ? "paused" : "open" } ?? unavailable)")
            }
        }
        return bounded(lines)
    }

    /// Short truthful report when the saved run cannot be decoded. Nothing is inferred from capture files.
    static func unreadableText(reason: PreviousRunUnreadableReason, reportID: String,
                               readerVersion: String, readerBuild: String) -> String {
        [
            "JoesProxy previous-run diagnostics",
            "Report: \(reportID); run: \(unavailable)",
            "Reader: \(readerVersion) (\(readerBuild))",
            "Evidence limits: the saved previous-run diagnostics were \(reason.rawValue); no other source was used to fill in missing facts.",
            "Excluded: traffic content, headers, hosts, URLs, paths, file names, credentials, client identities and capture files.",
        ].joined(separator: "\n") + "\n"
    }

    static func qualifications(_ e: PreviousRunDiagnosticEnvelope) -> [String] {
        var items: [String] = []
        if !e.cleanShutdownRecorded {
            items.append("evidence after the last saved health sample is unavailable")
        }
        if let context = e.context {
            let lag = e.lastSavedHealthAt.timeIntervalSince(context.observedAt)
            if lag > 2 * e.healthCadenceSeconds {
                items.append("operating context was last observed \(duration(lag)) before the final sample; the main thread may have been busy")
            }
        } else {
            items.append("operating context unavailable")
        }
        if e.admission == nil { items.append("capture admission unavailable") }
        switch e.incidentAssociation {
        case .uncorrelatedLegacy?, .otherRun?:
            items.append("latest responsiveness incident \(e.incidentAssociation!.rawValue)")
        case .unreadable?:
            items.append("responsiveness incident unreadable")
        case nil:
            items.append("responsiveness incident not examined")
        default:
            break
        }
        if e.omittedSampleCount > 0 {
            items.append("\(e.omittedSampleCount) older health samples not retained")
        }
        if e.failedWriteCount > 0 {
            items.append("\(e.failedWriteCount) diagnostic writes failed; saved evidence may be older than the run")
        }
        items.append("sampled peaks are not lifetime peaks; the absence of an incident does not prove no stall occurred")
        return items
    }

    private static func responsiveness(_ e: PreviousRunDiagnosticEnvelope) -> String {
        guard e.incidentAssociation == .correlated, let incident = e.incident else {
            return "no correlated incident (\(e.incidentAssociation?.rawValue ?? "not examined"))"
        }
        let delay = incident.maximumAcknowledgementDelaySeconds.map { String(format: "%.1fs", $0) } ?? unavailable
        let recovery = incident.recoveredAt.map { "recovered \(iso($0))" } ?? "recovery not recorded"
        return "delay detected \(iso(incident.detectedAt)); sampled acknowledgement delay \(delay); \(recovery)"
    }

    private static func bounded(_ lines: [String]) -> String {
        var result = lines.joined(separator: "\n") + "\n"
        guard result.utf8.count > maximumBytes else { return result }
        let notice = "[Notice: report truncated to the 32 KiB limit; older health samples omitted]\n"
        var kept: [String] = []
        var used = notice.utf8.count
        for line in lines {
            let size = line.utf8.count + 1
            guard used + size <= maximumBytes else { break }
            kept.append(line)
            used += size
        }
        result = kept.joined(separator: "\n") + "\n" + notice
        return result
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func bytes(_ value: UInt64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? unavailable
    }

    private static func bytes(_ value: Int?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64(max(0, $0)), countStyle: .memory) } ?? unavailable
    }

    private static func number<T: BinaryInteger>(_ value: T?) -> String {
        value.map { "\($0)" } ?? unavailable
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return String(format: "%dh %02dm %02ds", hours, minutes, secs) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, secs) }
        return "\(secs)s"
    }
}
