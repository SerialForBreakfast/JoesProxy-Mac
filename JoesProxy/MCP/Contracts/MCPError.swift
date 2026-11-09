import Foundation

/// Stable MCP error codes shared by transport, policy, approval, and mutation layers.
enum MCPErrorCode: String, Equatable, Sendable, Codable, CaseIterable {
    case unsupportedProtocolVersion = "unsupported_protocol_version"
    case malformedRequest = "malformed_request"
    case unauthorized = "unauthorized"
    case rateLimited = "rate_limited"
    case policyDenied = "policy_denied"
    case approvalRequired = "approval_required"
    case approvalExpired = "approval_expired"
    case approvalReused = "approval_reused"
    case staleCursor = "stale_cursor"
    case staleTargetRevision = "stale_target_revision"
    case staleProposal = "stale_proposal"
    case conflict = "conflict"
    case busy = "busy"
    case cancelled = "cancelled"
    case timeout = "timeout"
    case internalFailure = "internal_failure"
}

/// Structured error payload returned to MCP clients and projected into UI diagnostics.
struct MCPStructuredError: Equatable, Sendable, Codable, Error {
    var code: MCPErrorCode
    var message: String
    var details: [String: String]?
    var policyRevision: MCPPolicyRevision?
    var targetRevision: MCPTargetRevision?

    init(
        code: MCPErrorCode,
        message: String,
        details: [String: String]? = nil,
        policyRevision: MCPPolicyRevision? = nil,
        targetRevision: MCPTargetRevision? = nil
    ) {
        self.code = code
        self.message = message
        self.details = details
        self.policyRevision = policyRevision
        self.targetRevision = targetRevision
    }
}

extension MCPStructuredError {
    static func unauthorized(message: String = "Authentication required.") -> MCPStructuredError {
        MCPStructuredError(code: .unauthorized, message: message)
    }

    static func malformedRequest(message: String) -> MCPStructuredError {
        MCPStructuredError(code: .malformedRequest, message: message)
    }

    static func invalidEnumValue(field: String, provided: String?, validValues: [String]) -> MCPStructuredError {
        let validList = validValues.joined(separator: ", ")
        return MCPStructuredError(
            code: .malformedRequest,
            message: "\(field) must be one of: \(validList).",
            details: [
                "field": field,
                "provided": provided ?? "<missing>",
                "validValues": validList
            ]
        )
    }

    static func unsupportedProtocolVersion(requested: String, supported: String) -> MCPStructuredError {
        MCPStructuredError(
            code: .unsupportedProtocolVersion,
            message: "Unsupported MCP protocol version.",
            details: [
                "requested": requested,
                "supported": supported
            ]
        )
    }

    static func staleCursor(expected: MCPCaptureRevision, actual: MCPCaptureRevision) -> MCPStructuredError {
        MCPStructuredError(
            code: .staleCursor,
            message: "Capture revision changed; cursor is no longer valid.",
            details: [
                "expectedRevision": expected.rawValue,
                "actualRevision": actual.rawValue
            ]
        )
    }

    static func approvalRequired(_ request: MCPApprovalRequest) -> MCPStructuredError {
        MCPStructuredError(
            code: .approvalRequired,
            message: request.reason,
            details: [
                "requestID": request.requestID,
                "argumentDigest": request.argumentDigest,
                "expiresAt": MCPApprovalPolicy.iso8601String(from: request.expiresAt),
                "statusTool": "approval_status",
                "retryInstruction": "Approve in JoesProxy, then retry the identical tool call. Do not poll by repeating the gated call."
            ],
            policyRevision: request.policyRevision
        )
    }
}
