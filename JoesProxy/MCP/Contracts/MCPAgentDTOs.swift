import Foundation

/// Machine-readable MCP surface served at `joesproxy://agent/capabilities` and exported in agent bundles.
struct MCPCapabilitiesManifest: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var bundleVersion: String
    var appVersion: String
    var mcpProtocolVersion: String
    var generatedAt: Date
    var tools: [MCPToolCapabilityEntry]
    var resources: [MCPResourceCapabilityEntry]
    var mediaWorkflows: [MCPMediaWorkflowEntry]
    var policyProfiles: [MCPPolicyProfileSummary]
}

struct MCPToolCapabilityEntry: Codable, Sendable, Equatable {
    var name: String
    var description: String
    var capabilityID: String
    var riskTier: String
    var analysis: MCPAnalysisDescriptor? = nil
}

struct MCPAnalysisDescriptor: Codable, Sendable, Equatable {
    var inputKind: String
    var method: String
    var limits: [String: Int]
    var availability: String = "Catalog support only; source readiness and authorization are checked per call."
    var coverage: String
    var nextAction: String
}

struct MCPResourceCapabilityEntry: Codable, Sendable, Equatable {
    var uri: String
    var name: String
    var mimeType: String
    var capabilityID: String
}

struct MCPMediaWorkflowEntry: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var steps: [String]
    var requiredProfile: String
    var requiresApproval: Bool
}

struct MCPPolicyProfileSummary: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var summary: String
}

/// Body availability for capture-only media tools.
enum MCPMediaBodyEligibility: String, Codable, Sendable, Equatable {
    case available
    case deferred
    case truncated
    case omitted
    case empty
}

struct MCPMediaAnalysisEligibilityDTO: Codable, Sendable, Equatable {
    var kind: String
    var eligible: Bool
    var reason: String?
    var coverage: MCPMediaCoverageDTO? = nil
}

/// One-call answer for what MCP can tell an agent about a session's media.
struct MCPMediaReadinessDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var mediaType: String
    var bodyEligibility: MCPMediaBodyEligibility
    var supportedTools: [String]
    var supportedAnalyses: [MCPMediaAnalysisEligibilityDTO]
    var recommendedWorkflowID: String?
    var recommendedNextTools: [String]
    var requiresShareableProfile: Bool
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPMediaContextLabelDTO: Codable, Sendable, Equatable {
    var title: String
    var summary: String
}

/// Sanitized HLS discovery metadata without signed URLs or query tokens.
struct MCPHLSDiscoverySummaryDTO: Codable, Sendable, Equatable {
    var manifestHostCategory: String
    var manifestPathCategory: String
    var kind: String
    var manifestFormat: String?
    var hasContentID: Bool
    var hasDRMLicenseURL: Bool
}

struct MCPMediaDeliveryHeaderDTO: Codable, Sendable, Equatable {
    var name: String
    var value: String
}

/// UI-equivalent media context labels and lightweight discovery metadata for agents.
struct MCPMediaContextDTO: Codable, Sendable, Equatable {
    var sessionID: String
    var contextLabels: [MCPMediaContextLabelDTO]
    var hlsDiscovery: MCPHLSDiscoverySummaryDTO?
    var deliveryHeaders: [MCPMediaDeliveryHeaderDTO]
    var mimeCategory: String?
    var containerKind: String?
    var disclosure: MCPMediaDisclosureContextDTO
}

/// Condensed agent guide body served at `joesproxy://agent/guide`.
struct MCPAgentGuideDTO: Codable, Sendable, Equatable {
    var bundleVersion: String
    var appVersion: String
    var generatedAt: Date
    var markdownBody: String
}

struct MCPSetupGuideDTO: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var appVersion: String
    var markdownBody: String
    var bootstrapRequired: Bool
}
