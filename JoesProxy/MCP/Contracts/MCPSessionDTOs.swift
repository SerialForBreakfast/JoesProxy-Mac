import Foundation

enum MCPResponseProjection: String, Equatable, Sendable, Codable, CaseIterable {
    case minimal
    case summary
    case full
}

enum MCPSessionBodySource: String, Equatable, Sendable, Codable, CaseIterable {
    case response
    case request
}

/// Selects which HTTP message headers are disclosed by ``session_summary``.
enum MCPSessionHeaderSource: String, Equatable, Sendable, Codable, CaseIterable {
    case request
    case response
    case both
}

/// Production session summary exposed through MCP list/search tools.
///
/// Field presence is governed by ``MCPDisclosureProfile``; absent fields are omitted from JSON
/// rather than included as empty placeholders.
struct MCPSessionSummaryDTO: Equatable, Sendable, Codable, Identifiable {
    var captureWarning: String? = nil
    /// Opaque session identifier (UUID string).
    var id: String
    /// Immutable monotonic capture sequence used for keyset pagination.
    var captureSequence: UInt64
    var method: String?
    var statusCode: Int?
    var startedAt: Date?
    var durationSeconds: Double?
    var transportEvidence: RequestTransportEvidence?
    var transportEvidenceSource: String?
    var transportDiagnostic: TransportRecoveryAssessment?
    var mediaCategory: String?
    /// Host category for Metadata Only (e.g. `cdn`, `api`, `local`); not a raw hostname.
    var hostCategory: String?
    /// Sanitized hostname when Shareable profile allows structural host disclosure.
    var sanitizedHost: String?
    /// Sanitized path when Shareable profile allows structural path disclosure.
    var sanitizedPath: String?
    /// Redacted safe request headers (name + redacted value) for Shareable profile only.
    var safeHeaders: [MCPDisclosedHeaderField]?
    /// Redacted safe response headers for Shareable profile only.
    var safeResponseHeaders: [MCPDisclosedHeaderField]?
    /// Full request header values disclosed after explicit approval (`headerRead` capability).
    var approvedHeaders: [MCPDisclosedHeaderField]?
    /// Full response header values disclosed after explicit approval (`headerRead` capability).
    var approvedResponseHeaders: [MCPDisclosedHeaderField]?
    /// Query parameter names and values disclosed after explicit approval (`queryRead` capability).
    var queryParameters: [MCPDisclosedQueryParameter]?
    /// Bounded text body excerpt disclosed after explicit approval (`bodyRead` capability).
    var bodyExcerpt: String?
    var bodyExcerptTruncated: Bool?
    var bodyExcerptSource: String?
    var bodyDecodeStatus: String?
    var bodyUnavailableReason: String?
    /// Content-free recovery guidance; does not grant permission to read body bytes.
    var bodyRecoveryAction: String?
    /// Whether MCP can return a non-empty body excerpt for the selected `bodySource` after approval.
    var bodyExcerptAvailable: Bool?
    /// Legacy aggregate flag; mirrors `bodyExcerptAvailable` for the selected body source.
    var bodyAvailable: Bool?
    var requestBodyAvailable: Bool?
    var responseBodyAvailable: Bool?
    var bodyTruncated: Bool?
    var provenance: MCPProvenance?
    /// Sanitized statement of what happened to this response under an active MCP effect (e.g.
    /// "block", "mapRemote") — so an MCP client reading sessions can tell a rewritten/blocked
    /// response apart from real upstream traffic without a separate live-fetch/compare feature.
    /// Gated identically to `provenance` since both come from the same capture-time attribution.
    var mcpEffectKinds: [MCPEffectKind]?
    /// One-line parser outcomes (e.g. `hls_master`, `dash`) when Shareable profile allows parser summaries.
    var parserSummaries: [String]?
}

/// Redacted header field suitable for Shareable disclosure tier.
struct MCPDisclosedHeaderField: Equatable, Sendable, Codable {
    var name: String
    var redactedValue: String
}

/// Query parameter disclosed after post-approval sensitive read.
struct MCPDisclosedQueryParameter: Equatable, Sendable, Codable {
    var name: String
    var value: String
}

/// Paginated MCP session list payload with schema version 1 envelope.
struct MCPSessionListPageDTO: Equatable, Sendable, Codable {
    var captureWarning: String? = nil
    var items: [MCPSessionSummaryDTO]
    /// Opaque bounded server-side cursor token returned unchanged on the next request.
    var nextCursor: String?
    /// True when another page is available. This is independent of response-budget truncation.
    var hasMore: Bool
    var captureEpoch: MCPCaptureEpoch
    var policyRevision: MCPPolicyRevision
    /// Retained for schema compatibility. Means the requested page size was reduced to fit the
    /// response budget, not that another page exists.
    var truncated: Bool
    var truncationReason: String?
    var projection: MCPResponseProjection = .minimal
    var latestSequence: UInt64 = 0
    var stateToken: String = ""
    var unchanged: Bool = false
}

/// Small, cache-friendly capture state used to decide whether a broader read is justified.
struct MCPCaptureDigestDTO: Equatable, Sendable, Codable {
    var captureWarning: String? = nil
    var stateToken: String
    var unchanged: Bool
    var sessionCount: Int
    var completedCount: Int
    var pendingCount: Int
    var latestSequence: UInt64
    var captureEpoch: MCPCaptureEpoch
    var policyRevision: MCPPolicyRevision
    var recommendedAction: String
    /// When the capture epoch last changed (clear, load, or restore).
    var lastEpochChangeAt: Date?
    /// Machine-readable reason for the most recent epoch change.
    var lastEpochChangeReason: String?
    var previousCaptureEpoch: MCPCaptureEpoch?
    /// Whether a rolling auto-save artifact exists on disk.
    var rollingCaptureAvailable: Bool?
    var rollingCaptureSavedAt: Date?
    var rollingCaptureSessionCount: Int?
    var rollingCapturePersistenceError: String? = nil
    var captureStatus: MCPCaptureStatusDTO? = nil
}

/// Bulk export result for `sessions_export`.
///
/// Inline delivery puts the full export text in ``content``. File delivery (explicit
/// `deliverFile`, or auto-spill when the MCP response budget would be exceeded) leaves
/// ``content`` nil and sets ``outputPath`` to a JoesProxy-managed Application Support file.
/// Bodies/headers are present only when the caller both requested and was approved for them;
/// otherwise they're simply absent, not an error.
struct MCPSessionExportResultDTO: Equatable, Sendable, Codable {
    var format: String
    var sessionCount: Int
    var truncated: Bool
    /// Full export text when delivered inline; nil when written to ``outputPath``.
    var content: String?
    /// Absolute path under JoesProxy `MCPExports/` when the payload was written to disk.
    var outputPath: String?
    /// Byte length of the encoded export payload (inline or on disk).
    var contentByteCount: Int
}

/// Server status resource payload served at `joesproxy://server/status`.
struct MCPServerStatusDTO: Equatable, Sendable, Codable {
    var isRunning: Bool
    var endpointURL: String?
    var protocolVersion: String
    var appVersion: String
    var capabilitiesBundleVersion: String
    var toolCount: Int
    var connectedClientCount: Int
    var activeSessionCount: Int
    var policyRevision: MCPPolicyRevision
    var captureEpoch: MCPCaptureEpoch
    var degradedReason: String?
    var runtime: MCPRuntimeStatusDTO
}

/// Bounded cleanup and activity state needed by an agent to verify a safe baseline.
struct MCPRuntimeStatusDTO: Equatable, Sendable, Codable {
    var effectState: String
    var activeEffectCount: Int
    var cleanupConflictCount: Int
    var activeOperationCount: Int
    var pendingApprovalCount: Int
    var activeScenarioCount: Int
}

/// Client-scoped cleanup decision that avoids reading multiple status and audit surfaces.
struct MCPClientCleanupStatusDTO: Equatable, Sendable, Codable {
    var isClean: Bool
    var state: String
    var reasonCodes: [String]
    var recommendedAction: String
    var activeEffectCount: Int
    var cleanupConflictCount: Int
    var activeOperationCount: Int
    var pendingApprovalCount: Int
    var activeScenarioCount: Int
    var activeFixtureRunCount: Int
    var policyRevision: MCPPolicyRevision
    var recentApprovalOutcomes: [MCPApprovalStatusDTO] = []
}

struct MCPClientAuditEventDTO: Equatable, Sendable, Codable {
    var id: String
    var kind: String
    var timestamp: Date
    var reasonCode: String
}

struct MCPClientAuditSummaryDTO: Equatable, Sendable, Codable {
    var events: [MCPClientAuditEventDTO]
    var hasMore: Bool
    var policyRevision: MCPPolicyRevision
}

/// Capture summary resource payload served at `joesproxy://capture/summary`.
struct MCPCaptureSummaryDTO: Equatable, Sendable, Codable {
    var sessionCount: Int
    var completedCount: Int
    var pendingCount: Int
    var captureEpoch: MCPCaptureEpoch
    var policyRevision: MCPPolicyRevision
}

/// Capture health resource payload served at `joesproxy://capture/health`.
struct MCPCaptureHealthDTO: Equatable, Sendable, Codable {
    var retainedBodyBytes: Int
    var droppedSessionCount: Int
    var captureEpoch: MCPCaptureEpoch
    var policyRevision: MCPPolicyRevision
    var captureStatus: MCPCaptureStatusDTO? = nil
}
