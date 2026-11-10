import Foundation

/// Aggregate live capture state, distinct from per-session storage and disclosure permission.
struct MCPCaptureStatusDTO: Codable, Equatable, Sendable {
    var proxyState: String
    var admissionPaused: Bool
    var futureBodyCapture: String
    var perResponseByteLimit: Int
    var retainedBodyByteLimit: Int?
    var reservedBytes: Int
    var pendingCaptures: Int
    var rejectedCaptures: Int
    var metadataOnlyCaptures: Int
    var inFlightByteLimit: Int
    var inFlightCountLimit: Int
    var retainedBodyBytes: Int
    var retainedSessionCount: Int
    var retainedSessionLimit: Int?
    var evictedBodyCount: Int
    var droppedSessionCount: Int
    var lossCounterScope = "Admission counts since launch; retention removals since clear or load."
    var userActions: [String] = []
    var lastIncompleteCaptureAt: Date?
    var lastBodySkippedAt: Date?
    var admissionDetail: String
    var recommendedAction: String
    var resumeRestoresHistoricalBodies = false
    var capturePolicy = "playback_first"
    var pressureFallback = "response_metadata_when_capacity_allows; otherwise_request_not_recorded; forwarding_does_not_wait_for_capture_capacity"
    var notice = "Applies to future admitted, inspectable traffic only. Does not recover missing bodies, bypass TLS policy, grant body-read access, or replay requests."

    init(proxyState: String, admission: CaptureAdmissionBudget.Snapshot,
         perResponseByteLimit: Int, retainedBodyByteLimit: Int?, retainedBodyBytes: Int = 0,
         retainedSessionCount: Int = 0, retainedSessionLimit: Int? = nil,
         evictedBodyCount: Int = 0, droppedSessionCount: Int = 0) {
        lastIncompleteCaptureAt = admission.lastRejectedAt
        lastBodySkippedAt = admission.lastBodySkippedAt
        inFlightByteLimit = admission.byteLimit
        inFlightCountLimit = admission.countLimit
        self.retainedBodyBytes = retainedBodyBytes
        self.retainedSessionCount = retainedSessionCount
        self.retainedSessionLimit = retainedSessionLimit
        self.evictedBodyCount = evictedBodyCount
        self.droppedSessionCount = droppedSessionCount
        if admission.paused {
            userActions.append("Wait for recovery. If pressure recurs, lower Per-Response Body Cap or reduce concurrent traffic.")
        }
        if evictedBodyCount > 0 { userActions.append("Save earlier or increase the retained body budget for future captures.") }
        if droppedSessionCount > 0 { userActions.append("Save earlier or increase the retained session limit.") }
        self.proxyState = proxyState
        admissionPaused = admission.paused
        self.perResponseByteLimit = perResponseByteLimit
        self.retainedBodyByteLimit = retainedBodyByteLimit
        reservedBytes = admission.reservedBytes
        pendingCaptures = admission.pendingCaptures
        rejectedCaptures = admission.rejectedCaptures
        metadataOnlyCaptures = admission.metadataOnlyCaptures
        admissionDetail = admission.statusText
        if proxyState == "stopped" || proxyState == "failed" {
            futureBodyCapture = "proxy_not_running"
            recommendedAction = "capture_resume_after_runtime_approval"
        } else if proxyState != "running" {
            futureBodyCapture = "runtime_transition_or_unavailable"
            recommendedAction = "wait_then_capture_status; do_not_retry_mutations_blindly"
        } else if admission.paused {
            futureBodyCapture = "admission_paused"
            recommendedAction = "wait_for_capture_drain_then_capture_status; do_not_restart_or_raise_limits"
        } else if perResponseByteLimit <= 0 || retainedBodyByteLimit == 0 {
            futureBodyCapture = "body_retention_disabled"
            recommendedAction = "ask_local_user_to_review_capture_storage_settings"
        } else {
            futureBodyCapture = "bounded_capture_available"
            recommendedAction = "generate_new_authorized_traffic_then_session_summary; body_read_requires_separate_approval"
        }
    }
}
