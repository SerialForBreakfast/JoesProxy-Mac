import Foundation

/// Marks returned captured text as untrusted for MCP clients.
struct MCPUntrustedCapturedTextDTO: Codable, Sendable, Equatable {
    var captured_untrusted: String

    init(_ text: String) {
        captured_untrusted = text
    }
}

/// Metadata-only view of a captured response body suitable for deciding next edit tools.
struct MCPResponseContextDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var captureSequence: UInt64
    var statusCode: Int
    var contentType: String?
    var charset: String?
    var representation: String
    var completeness: String
    var rawBodyByteCount: Int
    var revisionBodyByteCount: Int
    /// Absent when no captured bytes are available; never synthesize a digest for missing data.
    var bodySHA256: String?
    var isUTF8TextEditable: Bool
    var recommendedNextAction: String
    /// Always `metadata_only` — this tool never returns body content.
    var contentTrust: String
    var captureEpoch: String
    var policyRevision: String
}

/// One exact-literal match bound to an opaque server-side `matchRef`.
struct MCPResponseTextMatchDTO: Codable, Sendable, Equatable {
    var matchRef: String
    var byteOffset: Int
    var byteLength: Int
    var matchedBytesSHA256: String
    /// Present only when body-read approval was granted for this call.
    var context: MCPUntrustedCapturedTextDTO?
}

/// Exact-literal search result over a captured response revision.
struct MCPResponseTextSearchDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var findByteCount: Int
    var matchCount: Int
    var matches: [MCPResponseTextMatchDTO]
    var truncated: Bool
    var contentTrust: String
    var captureEpoch: String
    var policyRevision: String
    var bodySHA256: String
    /// G6-03: only populated when `matchCount == 0`. A non-nil, non-zero value here is a signal
    /// the text is very likely present but differently cased, rather than genuinely absent — real
    /// content frequently mixes casing of the same literal (e.g. "ShowBlender LLC" vs
    /// "Showblender llc" on the same page). A count only, never the matched text itself.
    var caseInsensitiveMatchCount: Int?
}

/// Bounded page of untrusted captured response text.
struct MCPResponseTextReadDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var byteOffset: Int
    var byteLength: Int
    var nextCursor: String?
    var truncated: Bool
    var text: MCPUntrustedCapturedTextDTO
    var contentTrust: String
    var aggregateBytesDisclosed: Int
    var aggregateBudgetBytes: Int
    var captureEpoch: String
    var policyRevision: String
    var bodySHA256: String
}
