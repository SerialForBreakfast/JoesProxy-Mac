import Foundation

/// The aggregate-only data the Minimal Monitoring HUD renders — see
/// `memlog/Research/ADR-Minimal-Monitoring-Mode.md` §2a. Deliberately contains only numbers
/// already maintained elsewhere (`CaptureHealthMetrics`, `CaptureTransportDiagnosticsSnapshot`,
/// proxy/routing status); it must never require per-session state to compute.
struct MinimalMonitoringSnapshot: Equatable, Sendable {
    var proxyStatusDescription: String
    var sessionCount: Int
    var throughputPerMinute: Double?
    var activeConnections: Int
    var errorCount: Int
    var droppedSessionCount: Int
    var captureDuration: TimeInterval?
    /// Aggregate pending MCP approval count only (AO Axis 1) — never per-request state.
    var pendingApprovalCount: Int

    static let empty = MinimalMonitoringSnapshot(
        proxyStatusDescription: "—",
        sessionCount: 0,
        throughputPerMinute: nil,
        activeConnections: 0,
        errorCount: 0,
        droppedSessionCount: 0,
        captureDuration: nil,
        pendingApprovalCount: 0
    )
}
