//
//  CaptureRetentionPolicy.swift
//  JoesProxy
//
//  Defines how the session store bounds its in-memory footprint during a long capture
//  session, and the health metrics surfaced to the UI for monitoring.
//

import Foundation

// MARK: - CaptureRetentionPolicy

/// Controls how `InMemorySessionStore` limits its retained session data.
///
/// The default is `.unlimited`, which preserves all captured sessions for the lifetime
/// of the proxy run. Other cases allow the store to trim or externalize data automatically
/// so the app can run for extended periods without unbounded memory growth.
enum CaptureRetentionPolicy: Equatable, Codable, Sendable {
    /// No automatic trimming. All sessions and bodies are retained until the user
    /// explicitly clears them or the app quits. This is the default.
    case unlimited

    /// Keep only the most recent `n` sessions. When a new session is appended and the
    /// count exceeds `n`, the oldest sessions are dropped from the front. Session metadata
    /// and body data for dropped sessions are released.
    case keepLastSessions(Int)

    /// Retain all session metadata but strip inline body data from the oldest sessions
    /// once the total retained body bytes exceed `maxBytes`. Headers, status codes, timing,
    /// and all other metadata remain accessible; only `bodyData` is set to `nil`.
    case keepLastBodyBytes(Int)

    /// Bound both session population and retained inline bodies. Old sessions are removed first.
    case bounded(maxSessions: Int, maxBodyBytes: Int)

    var sessionLimit: Int? {
        switch self {
        case .keepLastSessions(let count): return count > 0 ? count : nil
        case .bounded(let count, _): return max(0, count)
        default: return nil
        }
    }

    var bodyByteLimit: Int? {
        switch self {
        case .keepLastBodyBytes(let bytes), .bounded(_, let bytes): return max(0, bytes)
        default: return nil
        }
    }
}

// MARK: - CaptureHealthThresholds

struct CaptureHealthThresholds: Equatable, Sendable {
    var captureDuration: TimeInterval = 2 * 60 * 60
    var sessionCount = 5_000
    var retainedBodyBytes = 200 * 1024 * 1024
    var residentMemoryBytes = 1_000 * 1024 * 1024
    var cpuPercent = 90.0

    static let standard = CaptureHealthThresholds()
}

// MARK: - CaptureHealthMetrics

/// A snapshot of the session store's current memory footprint and capture duration.
///
/// Emitted by `ProxyViewModel` via `captureHealth` whenever the session list changes
/// or the proxy runtime state transitions. The UI uses this to decide whether to
/// show the long-capture warning banner.
struct CaptureHealthMetrics: Equatable, Sendable {
    /// Total number of sessions currently retained in the store.
    let sessionCount: Int

    /// Sum of all `request.bodyData` and `response.bodyData` sizes in bytes across
    /// all currently retained sessions.
    let retainedBodyBytes: Int

    /// Number of sessions that have been dropped due to the active retention policy
    /// since the last `clear()` or `load()` call.
    let droppedSessionCount: Int

    /// The `Date` at which the proxy runtime most recently transitioned to `.running`.
    /// `nil` if the proxy has never started or has been stopped.
    let captureStartedAt: Date?

    /// Current process-level CPU / memory metrics for the JoesProxy app.
    let processMetrics: AppProcessMetrics

    /// Elapsed capture duration, or `nil` if the proxy is not running.
    var captureDuration: TimeInterval? {
        captureStartedAt.map { Date().timeIntervalSince($0) }
    }

    /// Current retained-session throughput since the proxy entered `.running`, expressed as
    /// sessions per minute. Returns `nil` until capture has been running long enough to measure.
    var sessionThroughputPerMinute: Double? {
        guard let captureDuration, captureDuration > 0 else {
            return nil
        }
        return (Double(sessionCount) / captureDuration) * 60
    }

    /// Whether the session store reflects an active capture workload.
    ///
    /// Process-level CPU and memory thresholds are only evaluated when this is `true` so
    /// startup spikes or idle app state do not trigger the long-capture banner.
    var hasCaptureSessionFootprint: Bool {
        sessionCount > 0 || retainedBodyBytes > 0 || droppedSessionCount > 0
    }

    /// Returns `true` when one or more long-capture thresholds are exceeded.
    func exceedsLongCaptureThresholds(using thresholds: CaptureHealthThresholds = .standard) -> Bool {
        guard hasCaptureSessionFootprint else {
            return false
        }

        let durationExceeded = captureDuration.map { $0 >= thresholds.captureDuration } ?? false
        return durationExceeded
            || sessionCount >= thresholds.sessionCount
            || retainedBodyBytes >= thresholds.retainedBodyBytes
            || processMetrics.residentMemoryBytes >= thresholds.residentMemoryBytes
            || (processMetrics.cpuPercent ?? 0) >= thresholds.cpuPercent
    }

    static let empty = CaptureHealthMetrics(
        sessionCount: 0,
        retainedBodyBytes: 0,
        droppedSessionCount: 0,
        captureStartedAt: nil,
        processMetrics: .empty
    )
}
