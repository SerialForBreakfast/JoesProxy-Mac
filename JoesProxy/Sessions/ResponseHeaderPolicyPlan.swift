import Foundation

/// Explicit response metadata plan bound to a response-edit preview before Map Local persistence.
///
/// Serve-time still recomputes `Content-Length` and `Connection`. This plan records which headers
/// are preserved on the rule, which are stripped because they are hop-by-hop or invalidated by the
/// edited body, and which remain off by default (`Set-Cookie`).
struct ResponseHeaderPolicyPlan: Equatable, Sendable {
    let statusCode: Int
    let contentType: String
    let preservedHeaderNames: [String]
    let removedHeaderNames: [String]
    let recomputedHeaderNames: [String]
    let omittedByDefaultHeaderNames: [String]

    /// Builds the default ADR §7 plan for an edited decoded-identity body.
    static func planForEditedDecodedBody(
        statusCode: Int,
        contentType: String?,
        capturedHeaders: [HTTPHeaderField]
    ) -> ResponseHeaderPolicyPlan {
        let normalizedContentType = normalizedContentType(contentType, from: capturedHeaders)
        let hopByHop: Set<String> = [
            "connection", "proxy-connection", "transfer-encoding", "keep-alive", "upgrade"
        ]
        let invalidated: Set<String> = [
            "content-encoding", "content-range", "accept-ranges",
            "etag", "content-md5", "digest", "content-length"
        ]
        let omittedByDefault: Set<String> = [
            "set-cookie", "set-cookie2"
        ]
        var preserved: [String] = ["Content-Type"]
        var removed: [String] = []
        var omitted: [String] = []
        var seen = Set<String>(["content-type"])

        for header in capturedHeaders {
            let lower = header.name.lowercased()
            guard seen.insert(lower).inserted else { continue }
            if hopByHop.contains(lower) || invalidated.contains(lower) {
                removed.append(header.name)
            } else if omittedByDefault.contains(lower) {
                omitted.append(header.name)
            } else if lower != "content-type" {
                // v1 persists only Content-Type for edited Map Local bodies; other semantic
                // headers are reported as removed so preview disclosure stays accurate.
                removed.append(header.name)
            }
        }
        return ResponseHeaderPolicyPlan(
            statusCode: statusCode,
            contentType: normalizedContentType,
            preservedHeaderNames: preserved.sorted(),
            removedHeaderNames: Array(Set(removed)).sorted(),
            recomputedHeaderNames: ["Content-Length", "Connection"],
            omittedByDefaultHeaderNames: Array(Set(omitted)).sorted()
        )
    }

    /// Headers stored on the Map Local rule. Framing length/connection stay serve-time only.
    var persistenceHeaders: [HTTPHeaderField] {
        [HTTPHeaderField(name: "Content-Type", value: contentType)]
    }

    /// Compact disclosure without header values.
    var disclosure: [String: Any] {
        [
            "statusCode": statusCode,
            "contentType": contentType,
            "preservedHeaderNames": preservedHeaderNames,
            "removedHeaderNames": removedHeaderNames,
            "recomputedHeaderNames": recomputedHeaderNames,
            "omittedByDefaultHeaderNames": omittedByDefaultHeaderNames
        ]
    }

    private static func normalizedContentType(
        _ contentType: String?,
        from headers: [HTTPHeaderField]
    ) -> String {
        let raw = contentType
            ?? headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value
            ?? "text/plain; charset=utf-8"
        let mediaType = raw.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "text/plain"
        if raw.lowercased().contains("charset=") {
            return raw
        }
        return "\(mediaType); charset=utf-8"
    }
}
