import Foundation

/// Read-only interpretation of bounded evidence. Recommendations never execute recovery.
struct TransportRecoveryAssessment: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case unavailable = "transport_evidence_unavailable"
        case incomplete = "upstream_response_incomplete"
        case framing = "upstream_chunk_framing_invalid"
        case headers = "upstream_headers_invalid"
        case connect = "upstream_connect_failed"
        case failed = "transport_failed"
        case downstream = "downstream_write_failed"
        case pending = "downstream_delivery_pending"
        case captureDisabled = "body_capture_disabled_for_request"
        case gap = "upstream_read_gap_observed"
        case observed = "transport_observed"
    }
    struct Action: Codable, Equatable, Sendable {
        let tool: String
        let authority: String
        let purpose: String
        let verification: String
    }
    let reason: Reason
    let impact: String
    let explanation: String
    let actions: [Action]
    let limitations: String

    static func assess(_ evidence: RequestTransportEvidence?) -> Self {
        let reason: Reason
        let impact: String
        let explanation: String
        if let failure = evidence?.failureReason {
            reason = Reason(rawValue: failure) ?? .failed
            impact = "transport_failure"
            explanation = "Transport reported a failure. Completed socket writes may represent only a response prefix. The underlying cause is not established."
        } else if (evidence?.failedWrites ?? 0) > 0 {
            reason = .downstream; impact = "delivery_failure"
            explanation = "A downstream write failed. This does not establish whether the client intentionally disconnected."
        } else if (evidence?.pendingWrites ?? 0) > 0 {
            reason = .pending; impact = "pending"
            explanation = "Delivery has outstanding writes. Pending work alone is not a deadlock or timeout."
        } else if evidence?.captureEnabled == false {
            reason = .captureDisabled; impact = "capture_evidence_only"
            explanation = "This request did not collect a body. Enabling capture affects future requests only and cannot recover these bytes."
        } else if (evidence?.maximumUpstreamReadGapSeconds ?? 0) >= 1 {
            reason = .gap; impact = "cause_unknown"
            explanation = "An upstream read gap of at least one second was observed. Local backpressure can contribute; this is not an origin-latency measurement."
        } else if evidence != nil {
            reason = .observed; impact = "observed_only"
            explanation = "Inspect delivery state and coverage before drawing conclusions. Socket writes do not establish playback."
        } else {
            reason = .unavailable; impact = "unknown"
            explanation = "Transport evidence is unavailable or evicted. Do not infer successful delivery or a device configuration problem."
        }
        return Self(reason: reason, impact: impact, explanation: explanation, actions: [
            Action(tool: "session_summary", authority: "read_only_existing_disclosure_policy",
                purpose: "Inspect this session ID and its current transport evidence.",
                verification: "Compare pending writes, failure reason and evidence source; unavailable history remains unknown."),
            Action(tool: "capture_status", authority: "read_only_existing_disclosure_policy",
                purpose: "Check current capture admission and future body availability separately from transport.",
                verification: "Confirm current pause/recovery state and retained gap totals; do not reinstall a device profile based on missing bodies."),
            Action(tool: "https_rules_get", authority: "read_only_existing_disclosure_policy",
                purpose: "Inspect HTTPS routing before proposing an exception through governed discovery.",
                verification: "A rule change needs existing local approval and affects new connections. Inspect state after an uncertain mutation reply before retrying.")
        ], limitations: "No automatic replay, bypass, limit increase or security change. A recovery proposal is not approval. Target outcome requires separate observation; preserve unrelated successful requests.")
    }
}
