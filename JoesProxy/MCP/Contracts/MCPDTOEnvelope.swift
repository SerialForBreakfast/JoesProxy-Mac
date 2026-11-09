import Foundation

/// Current MCP policy revision wrapper for encode/decode helpers.
typealias MCPPolicyRevisionSnapshot = MCPPolicyRevision

/// Versioned DTO envelope for MCP-facing payloads.
///
/// Unknown fields in nested payloads should be ignored by decoders that opt into tolerant decoding.
struct MCPDTOEnvelope<Payload: Codable & Sendable>: Sendable, Codable {
    var schemaVersion: Int
    var payload: Payload
}

enum MCPDTOSchema {
    static let currentVersion = 1
}

enum MCPDTOEnvelopeError: Error, Equatable {
    case unsupportedSchemaVersion(requested: Int, supported: Int)
}

extension MCPDTOEnvelope {
    init(payload: Payload, schemaVersion: Int = MCPDTOSchema.currentVersion) {
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    /// Decodes an envelope and rejects unsupported top-level schema versions.
    static func decodeStrict(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> MCPDTOEnvelope<Payload> {
        let envelope = try decoder.decode(MCPDTOEnvelope<Payload>.self, from: data)
        guard envelope.schemaVersion == MCPDTOSchema.currentVersion else {
            throw MCPDTOEnvelopeError.unsupportedSchemaVersion(
                requested: envelope.schemaVersion,
                supported: MCPDTOSchema.currentVersion
            )
        }
        return envelope
    }
}

/// Legacy capture revision alias retained for approval and target flows.
typealias MCPCaptureRevisionSnapshot = MCPCaptureRevision
