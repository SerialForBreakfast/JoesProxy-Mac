import Foundation

/// Disclosure payload bound into open-world approval digests.
///
/// Never includes raw credential values — only whether credentials will be forwarded.
struct MCPOpenWorldDisclosureDTO: Equatable, Sendable, Codable {
    var destinationHost: String
    var destinationPort: Int?
    var destinationScheme: String?
    var method: String
    var includesCredentials: Bool
    var expectedSideEffect: String
    var riskTier: String
    var targetID: String
}

/// Result of `execute_bookmark` / `replay_request`.
struct MCPOpenWorldExecutionResultDTO: Equatable, Sendable, Codable {
    var status: String
    var matchedSessionID: String?
    var startedAt: Date
    var includesCredentials: Bool
    var destinationHost: String
    var method: String
}

/// Result of `activate_map_remote`.
struct MCPOpenWorldActivateMapRemoteResultDTO: Equatable, Sendable, Codable {
    var overrideID: String
    var isEnabled: Bool
    var remoteHost: String
    var remotePort: Int
    var remoteScheme: String
    var transactionID: String
}

/// Result of `activate_live_rewrite`.
struct MCPOpenWorldActivateLiveRewriteResultDTO: Equatable, Sendable, Codable {
    var overrideID: String
    var isEnabled: Bool
    var rewriteSummary: String
    var transactionID: String
}

struct MCPOpenWorldActivateCollectionMockResultDTO: Equatable, Sendable, Codable {
    var overrideID: String
    var isEnabled: Bool
    var summary: String
    var transactionID: String
}

/// Result of `recapture_session_body`. Deliberately never carries the recaptured bytes themselves
/// (that would defeat the point of a bounded disclosure budget) — only enough to tell the caller
/// whether it worked and how much landed, so a follow-up `session_summary`/`bodyExcerpt` call is
/// how the actual content gets inspected, exactly like any other session's body.
struct MCPOpenWorldRecaptureResultDTO: Equatable, Sendable, Codable {
    var sessionID: String
    var statusCode: Int?
    var recapturedBodyBytes: Int
    /// `true` when the real response was larger than `maxBodyBytes` and got truncated at the
    /// recapture ceiling — distinct from `bodyTruncated` on ordinary live capture (1MB cap).
    var truncatedAtCeiling: Bool
    var includesCredentials: Bool
}

/// Sanitized live-probe start acknowledgement (full results via `operation_status`).
struct MCPOpenWorldLiveProbeStartDTO: Equatable, Sendable, Codable {
    var operationID: String
    var status: String
    var destinationHost: String
    var destinationScheme: String?
}
