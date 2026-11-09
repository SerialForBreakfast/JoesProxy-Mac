import CryptoKit
import Foundation

/// Computes canonical target revisions from semantic fields only.
///
/// Cosmetic edits (display names, hit counts, execution timestamps) must not change the revision.
enum MCPTargetRevisionFingerprint {
    /// Builds a stable revision token from normalized semantic payload bytes.
    static func revision(forSemanticPayload payload: Data) -> MCPTargetRevision {
        let digest = SHA256.hash(data: payload)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return MCPTargetRevision(rawValue: "target-\(hex.prefix(16))")
    }

    /// Semantic fingerprint for bookmark matcher and response rewrite behavior.
    static func semanticPayload(for bookmark: Bookmark) -> Data {
        let payload = SemanticBookmarkPayload(
            requestMethod: bookmark.request.method,
            requestScheme: bookmark.request.scheme.rawValue,
            requestHost: bookmark.request.host,
            requestPort: bookmark.request.port ?? 0,
            requestPath: bookmark.request.path,
            requestHeaders: bookmark.request.headers.map { SemanticHeader(name: $0.name, value: $0.value) },
            requestBodyData: bookmark.request.bodyData?.base64EncodedString(),
            savedResponseStatusCode: bookmark.savedResponse?.statusCode,
            savedResponseHeaders: bookmark.savedResponse?.headers.map { SemanticHeader(name: $0.name, value: $0.value) },
            savedResponseBodyData: bookmark.savedResponse?.bodyData?.base64EncodedString(),
            responseRewrites: bookmark.responseRewrites.map {
                SemanticRewrite(
                    jsonPath: $0.jsonPath,
                    operation: $0.operation.rawValue,
                    overrideValue: String(describing: $0.overrideValue),
                    isRuleEnabled: $0.isRuleEnabled,
                    repeatPolicy: $0.repeatPolicy?.rawValue
                )
            },
            responseRewriteMode: bookmark.responseRewriteMode.rawValue,
            responseMatchMode: bookmark.responseMatchMode.rawValue
        )
        return encode(payload)
    }

    /// Semantic fingerprint for response override matching and served content.
    static func semanticPayload(for rule: ResponseOverrideRule) -> Data {
        let bodyFingerprint: String
        switch rule.bodySource {
        case .inline(let data):
            bodyFingerprint = "inline:\(data?.base64EncodedString() ?? "nil")"
        case .file(let url):
            bodyFingerprint = "file:\(url.path)"
        case .directory(let url):
            bodyFingerprint = "directory:\(url.path)"
        }

        let payload = SemanticResponseOverridePayload(
            requestMethod: rule.requestMethod,
            requestScheme: rule.requestScheme.rawValue,
            host: rule.host,
            port: rule.port,
            path: rule.path,
            matchMode: rule.matchMode.rawValue,
            sourceKind: rule.sourceKind.rawValue,
            sourceDescription: rule.sourceDescription,
            statusCode: rule.statusCode,
            headers: rule.headers.map { SemanticHeader(name: $0.name, value: $0.value) },
            bodyFingerprint: bodyFingerprint,
            isEnabled: rule.isEnabled,
            mapRemoteHost: rule.mapRemoteHost,
            mapRemotePort: rule.mapRemotePort,
            mapRemoteScheme: rule.mapRemoteScheme?.rawValue,
            mapRemotePath: rule.mapRemotePath,
            mapRemoteQueryPolicy: rule.mapRemoteQueryPolicy.rawValue,
            mapRemoteQuery: rule.mapRemoteQuery,
            bookmarkRewriteRequest: rule.bookmarkRewriteRequest.map { semanticPayload(for: $0) },
            liveResponseRewrites: rule.liveResponseRewrites.map {
                SemanticRewrite(
                    jsonPath: $0.jsonPath,
                    operation: $0.operation.rawValue,
                    overrideValue: String(describing: $0.overrideValue),
                    isRuleEnabled: $0.isRuleEnabled,
                    repeatPolicy: $0.repeatPolicy?.rawValue
                )
            },
            expectedSchemaFingerprint: rule.expectedSchemaFingerprint?.rawValue,
            graphQLOperationName: rule.graphQLOperationName,
            matchQueryKey: rule.matchQueryKey,
            matchQueryValue: rule.matchQueryValue,
            sourceClientAddress: rule.sourceClientAddress
        )
        return encode(payload)
    }

    /// Semantic fingerprint for throttle behavior (preset rates and enablement).
    static func semanticPayload(for configuration: NetworkThrottleConfiguration) -> Data {
        let payload = SemanticThrottlePayload(
            isEnabled: configuration.isEnabled,
            selectedPresetID: configuration.selectedPresetID,
            presets: configuration.presets.map {
                SemanticThrottlePreset(
                    id: $0.id,
                    downstreamKbps: $0.downstreamKbps,
                    upstreamKbps: $0.upstreamKbps,
                    latencyMs: $0.latencyMs
                )
            }
        )
        return encode(payload)
    }

    static func revision(for bookmark: Bookmark) -> MCPTargetRevision {
        revision(forSemanticPayload: semanticPayload(for: bookmark))
    }

    static func revision(for rule: ResponseOverrideRule) -> MCPTargetRevision {
        revision(forSemanticPayload: semanticPayload(for: rule))
    }

    static func revision(for configuration: NetworkThrottleConfiguration) -> MCPTargetRevision {
        revision(forSemanticPayload: semanticPayload(for: configuration))
    }

    /// Returns an updated bookmark whose revision reflects semantic content.
    static func bookmarkByApplyingRevision(_ bookmark: Bookmark) -> Bookmark {
        var updated = bookmark
        updated.mcpTargetRevision = revision(for: bookmark)
        return updated
    }

    /// Returns an updated rule whose revision reflects semantic content.
    static func ruleByApplyingRevision(_ rule: ResponseOverrideRule) -> ResponseOverrideRule {
        var updated = rule
        updated.mcpTargetRevision = revision(for: rule)
        return updated
    }

    /// Returns updated throttle configuration with a semantic revision token.
    static func throttleByApplyingRevision(_ configuration: NetworkThrottleConfiguration) -> NetworkThrottleConfiguration {
        var updated = configuration
        updated.mcpTargetRevision = revision(for: configuration)
        return updated
    }

    private static func semanticPayload(for request: CapturedRequest) -> SemanticCapturedRequestPayload {
        SemanticCapturedRequestPayload(
            method: request.method,
            scheme: request.scheme.rawValue,
            host: request.host,
            port: request.port ?? 0,
            path: request.path,
            headers: request.headers.map { SemanticHeader(name: $0.name, value: $0.value) },
            bodyData: request.bodyData?.base64EncodedString()
        )
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        // `.sortedKeys` is load-bearing, not cosmetic: this payload is hashed to produce the
        // revision token, and `JSONEncoder`'s default (unsorted) key order is not guaranteed
        // stable across encode calls — it depends on the process's randomized hash seed for the
        // internal keyed-container storage. Without this, two encodes of byte-for-byte identical
        // semantic content could hash to different revisions, spuriously failing the staleness
        // check that the whole proposal system depends on.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }
}

private struct SemanticHeader: Codable {
    var name: String
    var value: String
}

private struct SemanticRewrite: Codable {
    var jsonPath: String
    var operation: String
    var overrideValue: String
    var isRuleEnabled: Bool
    var repeatPolicy: String?
}

private struct SemanticBookmarkPayload: Codable {
    var requestMethod: String
    var requestScheme: String
    var requestHost: String
    var requestPort: Int
    var requestPath: String
    var requestHeaders: [SemanticHeader]
    var requestBodyData: String?
    var savedResponseStatusCode: Int?
    var savedResponseHeaders: [SemanticHeader]?
    var savedResponseBodyData: String?
    var responseRewrites: [SemanticRewrite]
    var responseRewriteMode: String
    var responseMatchMode: String
}

private struct SemanticCapturedRequestPayload: Codable {
    var method: String
    var scheme: String
    var host: String
    var port: Int
    var path: String
    var headers: [SemanticHeader]
    var bodyData: String?
}

private struct SemanticResponseOverridePayload: Codable {
    var requestMethod: String
    var requestScheme: String
    var host: String
    var port: Int?
    var path: String
    var matchMode: String
    var sourceKind: String
    var sourceDescription: String
    var statusCode: Int
    var headers: [SemanticHeader]
    var bodyFingerprint: String
    var isEnabled: Bool
    var mapRemoteHost: String?
    var mapRemotePort: Int?
    var mapRemoteScheme: String?
    var mapRemotePath: String?
    var mapRemoteQueryPolicy: String?
    var mapRemoteQuery: String?
    var bookmarkRewriteRequest: SemanticCapturedRequestPayload?
    var liveResponseRewrites: [SemanticRewrite]
    var expectedSchemaFingerprint: String?
    var graphQLOperationName: String?
    var matchQueryKey: String?
    var matchQueryValue: String?
    var sourceClientAddress: String?
}

private struct SemanticThrottlePreset: Codable {
    var id: String
    var downstreamKbps: Int
    var upstreamKbps: Int
    var latencyMs: Int
}

private struct SemanticThrottlePayload: Codable {
    var isEnabled: Bool
    var selectedPresetID: String
    var presets: [SemanticThrottlePreset]
}
