import Foundation

/// Revision token for MCP data-access policy; tightening invalidates in-flight approvals and cursors.
struct MCPPolicyRevision: Equatable, Sendable, Codable, Hashable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let initial = MCPPolicyRevision(rawValue: "policy-v1")
}

/// Revision token for a mutable MCP target such as a rule or bookmark.
struct MCPTargetRevision: Equatable, Sendable, Codable, Hashable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Monotonic capture epoch bumped on clear, reload, replacement, or destructive retention.
///
/// Ordinary session appends do **not** bump the epoch so live-capture pagination stays stable.
struct MCPCaptureEpoch: Equatable, Sendable, Codable, Hashable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let initial = MCPCaptureEpoch(rawValue: "capture-epoch-0")
}

/// Legacy alias retained for older contract tests and approval metadata.
typealias MCPCaptureRevision = MCPCaptureEpoch

/// Opaque pagination cursor bound to client, policy, query, epoch, and high-water sequence.
struct MCPSessionQueryCursor: Equatable, Sendable, Codable {
    var token: String
    var clientID: String
    var policyRevision: MCPPolicyRevision
    var captureEpoch: MCPCaptureEpoch
    var queryDigest: String
    var orderingDigest: String
    /// Stable upper bound for the whole paginated query, fixed at the first page and carried
    /// forward unchanged on every subsequent cursor so live-capture appends mid-pagination don't
    /// shift later pages.
    var highWaterSequence: UInt64
    /// Sequence number of the last item returned on the page that produced this cursor. The next
    /// page resumes strictly after this value. `0` before any page has been returned.
    var lastSequence: UInt64
}

/// Legacy cursor shape retained for decode tolerance in older fixtures.
struct MCPCursor: Equatable, Sendable, Codable {
    var token: String
    var captureRevision: MCPCaptureEpoch
}

/// Idempotency key for proposal/apply and other retried MCP mutations.
struct MCPIdempotencyKey: Equatable, Sendable, Codable, Hashable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

enum MCPCursorValidation {
    /// Validates a production cursor against the authenticated client, policy, and capture epoch.
    static func validate(
        cursor: MCPSessionQueryCursor,
        clientID: String,
        currentPolicyRevision: MCPPolicyRevision,
        currentEpoch: MCPCaptureEpoch,
        queryDigest: String,
        orderingDigest: String
    ) -> MCPStructuredError? {
        if cursor.clientID != clientID {
            return staleCursor(expected: cursor.captureEpoch, actual: currentEpoch, reason: "client_mismatch")
        }
        if cursor.policyRevision != currentPolicyRevision {
            return staleCursor(
                expected: cursor.captureEpoch,
                actual: currentEpoch,
                reason: "policy_revision_changed"
            )
        }
        if cursor.captureEpoch != currentEpoch {
            return staleCursor(expected: cursor.captureEpoch, actual: currentEpoch, reason: "capture_epoch_changed")
        }
        if cursor.queryDigest != queryDigest || cursor.orderingDigest != orderingDigest {
            return staleCursor(expected: cursor.captureEpoch, actual: currentEpoch, reason: "query_changed")
        }
        return nil
    }

    private static func staleCursor(
        expected: MCPCaptureEpoch,
        actual: MCPCaptureEpoch,
        reason: String
    ) -> MCPStructuredError {
        MCPStructuredError(
            code: .staleCursor,
            message: "Cursor is no longer valid.",
            details: [
                "expectedEpoch": expected.rawValue,
                "actualEpoch": actual.rawValue,
                "reason": reason
            ]
        )
    }
}
