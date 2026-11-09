import Foundation

/// Approval lifetime per ADR Resolved Implementation Contracts.
enum MCPApprovalPolicy {
    static let defaultLifetime: TimeInterval = 10 * 60
    static let proposalLifetime: TimeInterval = 30 * 60
    static let terminalRetention: TimeInterval = 10 * 60
    static let maxTerminalRecordsPerClient = 128

    static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func expiration(from issuedAt: Date = Date(), lifetime: TimeInterval = defaultLifetime) -> Date {
        issuedAt.addingTimeInterval(lifetime)
    }

    /// Policy tightening invalidates pending approvals even when arguments are unchanged.
    static func isInvalidated(
        request: MCPApprovalRequest,
        currentPolicyRevision: MCPPolicyRevision,
        now: Date = Date()
    ) -> Bool {
        if request.policyRevision != currentPolicyRevision {
            return true
        }
        if now >= request.expiresAt {
            return true
        }
        return false
    }
}

enum MCPApprovalStatus: String, Equatable, Sendable, Codable {
    case pending
    case approvedAwaitingRetry = "approved_awaiting_retry"
    case consumed
    case denied
    case expired
    case invalidated
}

struct MCPApprovalStatusDTO: Equatable, Sendable, Codable {
    var requestID: String
    var status: MCPApprovalStatus
    var capability: MCPCapabilityID
    var expiresAt: Date
    var updatedAt: Date
    var retryInstruction: String?
}

/// One entry in `approvals_list` — unlike `MCPApprovalStatusDTO`, this always describes a request
/// that is still `pending` (the list tool never returns terminal-state entries), so `status` is
/// omitted, and `reason` is included since a list's whole purpose is letting an operator see
/// *which* capability/target is blocking without already knowing a `requestID` to query.
struct MCPApprovalPendingItemDTO: Equatable, Sendable, Codable {
    var requestID: String
    var capability: MCPCapabilityID
    var reason: String
    var expiresAt: Date
}

/// `approvals_list` tool payload. Added so an agent (or the human approving in-app) can see
/// everything currently blocking a client in one call, instead of only ever learning about one
/// `requestID` at a time from whichever specific tool call happened to trigger it
/// (`memlog/Research/MCPAndCLIUserExperienceValidation.md`, "No CLI command surfaces the list of
/// currently-pending approval requests").
struct MCPApprovalListDTO: Equatable, Sendable, Codable {
    var pending: [MCPApprovalPendingItemDTO]
    var count: Int
}

/// Structured `approval_required` payload returned instead of blocking the transport request.
struct MCPApprovalRequest: Equatable, Sendable, Codable {
    var requestID: String
    var clientID: String
    var argumentDigest: String
    var policyRevision: MCPPolicyRevision
    var targetRevision: MCPTargetRevision?
    var expiresAt: Date
    var reason: String
    var capability: MCPCapabilityID
}

/// One-use authorization supplied on an exact-argument retry after in-app approval.
struct MCPApprovalAuthorization: Equatable, Sendable, Codable {
    var requestID: String
    var clientID: String
    var capability: MCPCapabilityID
    var argumentDigest: String
    var policyRevision: MCPPolicyRevision
    var targetRevision: MCPTargetRevision?
    var nonce: String
    var expiresAt: Date
}

enum MCPApprovalValidation {
    enum Failure: Equatable, Sendable {
        case expired
        case reused
        case argumentMismatch
        case policyTightened
        case targetRevisionChanged
    }

    /// Validates a retry authorization against the original request and current revisions.
    static func validateRetry(
        request: MCPApprovalRequest,
        authorization: MCPApprovalAuthorization,
        currentClientID: String,
        currentCapability: MCPCapabilityID,
        normalizedArgumentDigest: String,
        currentPolicyRevision: MCPPolicyRevision,
        currentTargetRevision: MCPTargetRevision?,
        now: Date = Date(),
        nonceAlreadyUsed: Bool
    ) -> Failure? {
        if nonceAlreadyUsed {
            return .reused
        }
        if authorization.requestID != request.requestID
            || authorization.clientID != request.clientID
            || authorization.clientID != currentClientID
            || authorization.capability != request.capability
            || authorization.capability != currentCapability {
            return .argumentMismatch
        }
        if request.argumentDigest != normalizedArgumentDigest
            || authorization.argumentDigest != normalizedArgumentDigest {
            return .argumentMismatch
        }
        if request.policyRevision != currentPolicyRevision
            || authorization.policyRevision != request.policyRevision {
            return .policyTightened
        }
        if now >= request.expiresAt || now >= authorization.expiresAt {
            return .expired
        }
        if request.targetRevision != currentTargetRevision
            || authorization.targetRevision != currentTargetRevision {
            return .targetRevisionChanged
        }
        return nil
    }
}
