import CryptoKit
import Foundation

/// Deterministic content digest for `preview_hls_codecs_edit` retained bodies.
///
/// Call-scoped binding (client / MCP session / capture epoch / policy revision / expiry) lives on
/// ``MCPMutationService.ResponseEditPreviewRecord`` and is re-validated at propose time. This type
/// fingerprints only the *content* of the preview so re-encoding is stable (``JSONEncoder``
/// `.sortedKeys`) and any change to edits, matcher, hashes, or transformer version invalidates the
/// token.
///
/// Pattern mirrors ``MCPTransformationPreviewDigest`` for live-rewrite previews.
enum MCPHLSCodecsPreviewDigest {
    private struct EditPayload: Codable {
        var variantRef: String
        var codecs: String
    }

    private struct Payload: Codable {
        var sessionID: String
        var captureSequence: UInt64
        var originalBodyHash: String
        var patchedBodyHash: String
        var edits: [EditPayload]
        var method: String
        var scheme: String
        var host: String
        var port: Int?
        var path: String
        var matchMode: String
        var sourceStatus: Int
        var contentType: String
        var transformerVersion: Int
    }

    /// Builds an `hls-codecs-preview-<hex>` token from the validated preview content.
    static func compute(
        sessionID: SessionRecord.ID,
        captureSequence: UInt64,
        originalBodyHash: String,
        patchedBodyHash: String,
        edits: [(variantRef: String, codecs: String)],
        matcher: MCPMutationMatcher,
        sourceStatus: Int,
        contentType: String,
        transformerVersion: Int
    ) -> String {
        let payload = Payload(
            sessionID: sessionID.uuidString,
            captureSequence: captureSequence,
            originalBodyHash: originalBodyHash,
            patchedBodyHash: patchedBodyHash,
            edits: edits.map { EditPayload(variantRef: $0.variantRef, codecs: $0.codecs) },
            method: matcher.method,
            scheme: matcher.scheme.rawValue,
            host: matcher.host,
            port: matcher.port,
            path: matcher.path,
            matchMode: matcher.matchMode.rawValue,
            sourceStatus: sourceStatus,
            contentType: contentType,
            transformerVersion: transformerVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else {
            return "hls-codecs-preview-unavailable"
        }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "hls-codecs-preview-\(hex.prefix(20))"
    }
}
