import Foundation

/// Identifies the MCP client and operation that created or modified an object.
struct MCPProvenance: Equatable, Sendable, Codable, Hashable {
    var clientID: String
    var operationID: String
    var capability: MCPCapabilityID
    var createdAt: Date
}

/// Immutable attribution snapshot stored on captured responses at capture time.
struct MCPCaptureAttribution: Equatable, Sendable, Codable {
    var provenance: MCPProvenance
    var effectKinds: [MCPEffectKind]
    var scenarioID: String?
    /// Present when the capture occurred on an isolated self-validation proxy lane (AI-5).
    var validationRunID: String?
    var measurementContext: MCPMeasurementContext?
    /// Serving OpenAPI mock pack, when this response was produced by AW-3 intercept.
    var openAPIMockPackID: String? = nil
    /// Compiled route id (`GET /v1/items/{itemId}`), never a concrete URL with query values.
    var openAPIMockOperation: String? = nil
    /// Compiled variant id. Disclosure must not include body bytes.
    var openAPIMockVariantID: String? = nil
}

/// Labels sessions captured while diagnostic interlock suspended relevant effects.
enum MCPMeasurementContext: String, Equatable, Sendable, Codable {
    case effectsSuspended
}

/// Origin of a persisted object for provenance and recovery flows.
enum MCPObjectOrigin: String, Equatable, Sendable, Codable {
    case user
    case mcp
    case `import`
    case system
}
