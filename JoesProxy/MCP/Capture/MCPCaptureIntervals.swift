import Foundation

/// Checkpoints carry no session records. All reads and store notifications are serialized
/// on the snapshot service's main actor.
@MainActor
final class MCPCaptureIntervals {
    struct Sample {
        var sequence: UInt64
        var failureTransitions: UInt64
        var removedBodies: Int
        var removedSessions: Int
        var retainedBytes: Int
        var retainedSessions: Int
    }

    struct Scope: Equatable {
        var epoch: MCPCaptureEpoch
        var policy: MCPPolicyRevision
        var generation: Int
        var profile: MCPDisclosureProfileID
    }

    struct Report: Codable {
        var status: String
        var checkpoint: String?
        var newSessions: UInt64?
        var failureTransitions: UInt64?
        var removedBodies: Int?
        var removedSessions: Int?
        var peakRetainedBodyBytes: Int?
        var peakRetainedSessions: Int?
        var unrecordedRequests: Int?
        var skippedBodies: Int?
    }

    private struct Window {
        var token: String
        var expiry: ContinuousClock.Instant
        var scope: Scope
        var baseline: Sample
        var rejected: Int?
        var skipped: Int?
        var peakBytes: Int
        var peakSessions: Int
        var previousToken: String?
        var previousReport: Report?

        mutating func observe(bytes: Int, sessions: Int) {
            peakBytes = max(peakBytes, bytes)
            peakSessions = max(peakSessions, sessions)
        }
    }

    private var windows: [String: Window] = [:]
    private var nextExpiry: ContinuousClock.Instant?

    private func expire(at now: ContinuousClock.Instant) {
        guard let nextExpiry, now >= nextExpiry else { return }
        windows = windows.filter { $0.value.expiry > now }
        self.nextExpiry = windows.values.map(\.expiry).min()
    }

    func observe(bytes: Int, sessions: Int) {
        guard !windows.isEmpty else { return }
        // At most 32 integer pairs per store publication. No body inspection or session scan.
        expire(at: .now)
        for index in windows.indices { windows.values[index].observe(bytes: bytes, sessions: sessions) }
    }

    func report(clientID: String, token: String, scope: Scope, sample: Sample,
                capacity: MCPCaptureStatusDTO?, now: ContinuousClock.Instant = .now) throws -> Report {
        expire(at: now)
        let next = UUID().uuidString
        var report = Report(status: "started", checkpoint: next)
        if token != "start" {
            guard UUID(uuidString: token) != nil else {
                throw MCPStructuredError.malformedRequest(message: "Use start or the checkpoint from the previous interval report.")
            }
            guard let window = windows[clientID], window.scope == scope else { return Report(status: "restart_required") }
            if token == window.previousToken, let replay = window.previousReport { return replay }
            guard token == window.token else { return Report(status: "restart_required") }
            report.status = "complete"
            report.newSessions = sample.sequence - window.baseline.sequence
            report.failureTransitions = sample.failureTransitions - window.baseline.failureTransitions
            report.removedBodies = sample.removedBodies - window.baseline.removedBodies
            report.removedSessions = sample.removedSessions - window.baseline.removedSessions
            report.peakRetainedBodyBytes = max(window.peakBytes, sample.retainedBytes)
            report.peakRetainedSessions = max(window.peakSessions, sample.retainedSessions)
            if let current = capacity?.rejectedCaptures, let previous = window.rejected, current >= previous {
                report.unrecordedRequests = current - previous
            }
            if let current = capacity?.metadataOnlyCaptures, let previous = window.skipped, current >= previous {
                report.skippedBodies = current - previous
            }
        }
        guard windows[clientID] != nil || windows.count < 32 else {
            throw MCPStructuredError(code: .busy, message: "Capture interval checkpoint capacity reached. Retry later.")
        }
        windows[clientID] = Window(token: next, expiry: now.advanced(by: .seconds(3600)), scope: scope,
            baseline: sample, rejected: capacity?.rejectedCaptures, skipped: capacity?.metadataOnlyCaptures,
            peakBytes: sample.retainedBytes, peakSessions: sample.retainedSessions,
            previousToken: token == "start" ? nil : token, previousReport: token == "start" ? nil : report)
        nextExpiry = windows.values.map(\.expiry).min()
        return report
    }
}
