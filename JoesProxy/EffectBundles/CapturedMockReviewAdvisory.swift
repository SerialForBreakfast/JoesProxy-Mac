import Darwin
import Foundation

/// Static review guidance, not a connectivity probe or delivery receipt. No DNS, traffic, or I/O.
struct CapturedMockReviewAdvisory: Equatable, Sendable, Identifiable {
    enum Code: String, Sendable {
        case nonPortableImageDestination
        case retainedImageCacheRisk
        case routingNotVerified
        case visibleOutcomeNotVerified
        case syntheticResponseNotUpstreamEvidence
        case relativeImageMappingUnverified
        case unobservedRelatedDestination
    }

    let code: Code
    let message: String
    let recovery: String
    let assetIDs: [String]
    var id: String { code.rawValue }

    var payload: [String: Any] {
        ["code": code.rawValue, "message": message, "recovery": recovery, "assetIDs": assetIDs]
    }

    static func evaluate(images: [CapturedMockImagePreview]) -> [Self] {
        var result: [Self] = []
        let relative = images.filter { $0.imageReference != nil }.map(\.assetID)
        if !relative.isEmpty {
            result.append(Self(code: .relativeImageMappingUnverified,
                message: "A relative image reference is not the final request URL. The client may add a size path or query parameters; the prepared image matcher requires the exact delivery path and query.",
                recovery: "Compare the captured image request's scheme, host, port, path, query and client with the prepared matcher. On mismatch, review a new revision using the observed delivery URL; do not automatically ignore queries or widen scope. Verify delivery and asset hash separately from rendering. No observed request does not establish a cache hit.",
                assetIDs: relative))
        }
        let localAssets = images.filter { image in
            guard let host = URLComponents(string: image.url)?.host else { return false }
            return isNonPortableHost(host)
        }.map(\.assetID)
        if !localAssets.isEmpty {
            result.append(Self(code: .nonPortableImageDestination,
                message: "An image uses a loopback or unspecified host. A physical device may interpret it locally or bypass the proxy; it is not a portable address for this Mac.",
                recovery: "Prefer the generated versioned virtual-host URL. If retaining this URL intentionally, verify an attributed image response from the intended client before claiming delivery.",
                assetIDs: localAssets))
        }
        let retained = images.filter(\.retainsOriginalURL).map(\.assetID)
        if !retained.isEmpty {
            result.append(Self(code: .retainedImageCacheRisk,
                message: "A retained image URL may reuse client-cached content. No request observed does not confirm a cache hit.",
                recovery: "Prefer a versioned URL, or inspect the intended client's request and served asset hash. Do not automatically clear application caches.",
                assetIDs: retained))
        }
        if !images.isEmpty {
            result.append(Self(code: .routingNotVerified,
                message: "Prepared assets and virtual-host availability do not prove device routing, HTTPS trust, or image delivery.",
                recovery: "Check the chosen client's routing and trust prerequisites, then correlate each image request with the prepared revision and asset hash.",
                assetIDs: images.map(\.assetID)))
        }
        result.append(Self(code: .visibleOutcomeNotVerified,
            message: "A changed response does not prove the target renders the changed field. Visible labels may come from artwork or a different response.",
            recovery: "Choose a field the target actually displays and an explicit diagnostic marker. Confirm the visible result separately; do not infer it from an enabled rule or request count.",
            assetIDs: []))
        result.append(Self(code: .syntheticResponseNotUpstreamEvidence,
            message: "A synthetic failure demonstrates the target's reaction to the injected response, not what the real upstream returned.",
            recovery: "Keep mock observations separate from an unmodified baseline. Verify the relevant request path and record untested alternatives as unknown.",
            assetIDs: []))
        return result
    }

    private static func isNonPortableHost(_ value: String) -> Bool {
        var host = value.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            return bytes[0] == 127 || bytes.allSatisfy { $0 == 0 }
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] <= 1 { return true }
        return bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
            && (bytes[12] == 127 || bytes.suffix(4).allSatisfy { $0 == 0 })
    }
}

extension PreparedCapturedMockPackage {
    var reviewAdvisories: [CapturedMockReviewAdvisory] {
        var result = CapturedMockReviewAdvisory.evaluate(images: images)
        let unobserved = (manifest.authoring?.relatedResponses ?? []).filter { $0.targetSessionID == nil }.map(\.assetID)
        if !unobserved.isEmpty {
            result.append(.init(code: .unobservedRelatedDestination,
                message: "Related destinations are authored without linked target captures. The client may never request them or may reject this frozen API contract.",
                recovery: "Review exact paths and identity links. After approved activation, compare fresh request and resource receipts; investigate client rejection separately. For API drift, select a complete current capture and prepare a new reviewed revision. Never silently refetch, widen scope or alter active bytes.",
                assetIDs: unobserved))
        }
        return result
    }
}
