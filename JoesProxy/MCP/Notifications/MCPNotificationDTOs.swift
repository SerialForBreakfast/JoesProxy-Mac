import Foundation

/// Logical MCP session identity used for subscription and SSE writer routing.
struct MCPLogicalSessionKey: Hashable, Sendable, Equatable {
    var clientID: String
    var mcpSessionID: String
}

/// URIs clients may subscribe to for live capture/status notifications.
enum MCPSubscriptionResource {
    static let allowedURIs: Set<String> = [
        "joesproxy://server/status",
        "joesproxy://capture/summary",
        "joesproxy://capture/health"
    ]

    static func isAllowed(_ uri: String) -> Bool {
        allowedURIs.contains(uri)
    }
}

/// Priority ordering for bounded notification queues (higher wins on enqueue pressure).
enum MCPNotificationPriority: Int, Comparable, Sendable {
    case captureUpdate = 0
    case operationProgress = 1
    case operationTerminal = 2
    case invalidation = 3

    static func < (lhs: MCPNotificationPriority, rhs: MCPNotificationPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Hub-internal notification event before SSE framing.
enum MCPNotificationEvent: Sendable {
    case toolsListChanged
    case resourceUpdated(uri: String, droppedEventCount: Int)
    case operationUpdated(operationID: String, descriptor: MCPOperationDescriptorDTO, isTerminal: Bool)
    case resourceInvalidated(
        uri: String?,
        reason: String,
        captureEpoch: MCPCaptureEpoch,
        policyRevision: MCPPolicyRevision,
        droppedEventCount: Int
    )

    var priority: MCPNotificationPriority {
        switch self {
        case .toolsListChanged:
            return .invalidation
        case .resourceUpdated:
            return .captureUpdate
        case .operationUpdated(_, _, let isTerminal):
            return isTerminal ? .operationTerminal : .operationProgress
        case .resourceInvalidated:
            return .invalidation
        }
    }

    var operationID: String? {
        if case .operationUpdated(let operationID, _, _) = self {
            return operationID
        }
        return nil
    }

    var coalescingURI: String? {
        switch self {
        case .resourceUpdated(let uri, _):
            return uri
        case .toolsListChanged:
            return "tools/list"
        default:
            return nil
        }
    }
}

/// Sanitized operation notification payload (progress omits heavy result bodies).
struct MCPOperationNotificationDTO: Equatable, Sendable, Codable {
    var operationID: String
    var status: MCPOperationStatus
    var progress: Double
    var currentStage: String?
    var requestedAnalyses: [MCPMediaAnalysisKind]
    var stages: [MCPOperationStageDTO]
    var warnings: [String]
    var failureCode: MCPErrorCode?
    var result: MCPMediaInspectionResultDTO?
    var createdAt: Date
    var expiresAt: Date
    var droppedEventCount: Int

    init(descriptor: MCPOperationDescriptorDTO, includeResult: Bool, droppedEventCount: Int = 0) {
        operationID = descriptor.operationID
        status = descriptor.status
        progress = descriptor.progress
        currentStage = descriptor.currentStage
        requestedAnalyses = descriptor.requestedAnalyses
        stages = descriptor.stages
        warnings = descriptor.warnings
        failureCode = descriptor.failureCode
        result = includeResult ? descriptor.result : nil
        createdAt = descriptor.createdAt
        expiresAt = descriptor.expiresAt
        self.droppedEventCount = droppedEventCount
    }
}

/// Invalidation envelope surfaced to subscribed clients after clear, retention, or policy change.
struct MCPResourceInvalidationDTO: Equatable, Sendable, Codable {
    var uri: String?
    var reason: String
    var captureEpoch: MCPCaptureEpoch
    var policyRevision: MCPPolicyRevision
    var droppedEventCount: Int
}
