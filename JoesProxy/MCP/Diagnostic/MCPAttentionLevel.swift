import Foundation

/// UI attention levels for MCP data-egress awareness (AJ-5). Distinct from capability risk tiers.
enum MCPAttentionLevel: String, Equatable, Sendable {
    case ambient
    case noticed
    case interruptive

    /// Maps parent ADR capability risk tiers to presentation attention.
    static func attentionLevel(for riskTier: MCPCapabilityRiskTier) -> MCPAttentionLevel {
        switch riskTier {
        case .passiveResource:
            return .ambient
        case .sensitiveReadTool:
            return .noticed
        case .readOnlyTool, .expensiveInspection:
            return .ambient
        case .mutatingTool, .openWorldTool, .destructiveTool:
            return .interruptive
        }
    }

    /// Clients cannot request a lower attention level than their capability tier allows.
    static func validatesClientCannotLowerAttention(
        requestedLevel: MCPAttentionLevel,
        capability: MCPCapabilityID
    ) -> Bool {
        let minimum = attentionLevel(for: capability.riskTier)
        return requestedLevel.severityRank >= minimum.severityRank
    }

    private var severityRank: Int {
        switch self {
        case .ambient: return 0
        case .noticed: return 1
        case .interruptive: return 2
        }
    }
}

/// Bounded toast payload for noticed-tier sensitive reads.
struct MCPAttentionToastMessage: Equatable, Identifiable, Sendable {
    let id = UUID()
    let message: String
    let clientLabel: String
    let fieldClass: String
}

/// Tracks noticed-tier activity for status projection (AJ-5).
///
/// Concurrency: `@MainActor` — updated from audit recording on the main actor.
@MainActor
final class MCPAttentionCoordinator: ObservableObject {
    @Published private(set) var noticedReadCount = 0
    @Published var pendingToast: MCPAttentionToastMessage?

    func recordSensitiveRead(clientID: String, capability: MCPCapabilityID, fieldClass: String) {
        noticedReadCount += 1
        let sanitizedClient = sanitizedClientLabel(clientID)
        pendingToast = MCPAttentionToastMessage(
            message: "Sensitive read: \(fieldClass)",
            clientLabel: sanitizedClient,
            fieldClass: fieldClass
        )
    }

    func clearToast() {
        pendingToast = nil
    }

    private func sanitizedClientLabel(_ clientID: String) -> String {
        if clientID.count <= 12 {
            return clientID
        }
        return String(clientID.prefix(8)) + "…"
    }
}
