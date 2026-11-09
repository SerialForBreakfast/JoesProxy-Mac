import CryptoKit
import Foundation

/// Normalized digest binding a `preview_live_rewrite` result to whatever specific candidate rule
/// (matcher + selector + operation + literal + limits) produced it — a later approval binds this
/// digest, and any change to any of those inputs must invalidate it.
///
/// A new sibling type next to `MCPTargetRevisionFingerprint`, not a method on it: that type
/// fingerprints a *persisted* rule/bookmark/throttle target for staleness checks; this fingerprints
/// a *candidate, possibly never-persisted* rewrite specification. Same SHA256-over-`.sortedKeys`-
/// JSON → prefixed-token pattern.
enum MCPTransformationPreviewDigest {
    private struct Payload: Codable {
        var method: String
        var scheme: String
        var host: String
        var port: Int?
        var path: String
        var matchMode: String
        var jsonPath: String
        var operation: String
        var overrideValueDescription: String
        var repeatPolicy: String
        var graphQLOperationName: String?
        var matchQueryKey: String?
        var matchQueryValue: String?
    }

    static func compute(
        matcher: MCPMutationMatcher,
        jsonPath: String,
        operation: JSONMutationOperation,
        overrideValue: BookmarkJSONValue,
        repeatPolicy: JSONMutationRepeatPolicy
    ) -> String {
        let payload = Payload(
            method: matcher.method,
            scheme: matcher.scheme.rawValue,
            host: matcher.host,
            port: matcher.port,
            path: matcher.path,
            matchMode: matcher.matchMode.rawValue,
            jsonPath: jsonPath,
            operation: operation.rawValue,
            overrideValueDescription: overrideValue.disclosureDescriptor,
            repeatPolicy: repeatPolicy.rawValue,
            graphQLOperationName: matcher.graphQLOperationName,
            matchQueryKey: matcher.matchQueryKey,
            matchQueryValue: matcher.matchQueryValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else {
            return "preview-digest-unavailable"
        }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "preview-\(hex.prefix(16))"
    }
}
