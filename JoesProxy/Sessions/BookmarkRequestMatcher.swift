import Foundation

/// Shared request-matching rules for bookmark response intercept and traffic-hint analysis.
enum BookmarkRequestMatcher {
    /// Returns whether `request` matches the bookmark rule request using `matchMode`.
    static func matches(
        ruleRequest: CapturedRequest,
        matchMode: ResponseOverrideMatchMode,
        request: CapturedRequest
    ) -> Bool {
        let normalizedRulePath = normalizedPathForMatch(ruleRequest.path, mode: matchMode)
        let normalizedRequestPath = normalizedPathForMatch(normalizedPath(request.path), mode: matchMode)

        return ruleRequest.method.caseInsensitiveCompare(request.method) == .orderedSame &&
            ruleRequest.scheme == request.scheme &&
            normalizeHost(ruleRequest.host).caseInsensitiveCompare(normalizeHost(request.host)) == .orderedSame &&
            canonicalPort(ruleRequest.port, scheme: ruleRequest.scheme) == canonicalPort(request.port, scheme: request.scheme) &&
            pathMatches(rulePath: normalizedRulePath, requestPath: normalizedRequestPath, mode: matchMode)
    }

    /// Formats applied/skipped rewrite paths for session source descriptions.
    static func sourceDescription(
        bookmarkName: String,
        rewrites: [BookmarkResponseFieldRewrite],
        rewriteResult: BookmarkJSONRewriteResult,
        maxListedPaths: Int = 5
    ) -> String {
        let rewriteByID = Dictionary(uniqueKeysWithValues: rewrites.map { ($0.id, $0) })
        let appliedPaths = rewriteResult.appliedRuleIDs.compactMap { rewriteByID[$0]?.jsonPath }
        let skippedPaths = rewriteResult.skippedRuleIDs.compactMap { rewriteByID[$0]?.jsonPath }

        var parts: [String] = ["Bookmark response rewrite: \(bookmarkName)"]
        if !appliedPaths.isEmpty {
            parts.append("applied: \(listPaths(appliedPaths, max: maxListedPaths))")
        }
        if !skippedPaths.isEmpty {
            parts.append("skipped: \(listPaths(skippedPaths, max: maxListedPaths))")
        }
        if appliedPaths.isEmpty && skippedPaths.isEmpty {
            parts.append("(0 fields)")
        }
        return parts.joined(separator: " · ")
    }

    static func normalizeHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedPath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return "/"
        }
        return trimmedPath
    }

    static func normalizedPathForMatch(_ path: String, mode: ResponseOverrideMatchMode) -> String {
        switch mode {
        case .exactPath:
            return path
        case .ignoreQuery, .pathPrefix, .pathSuffix, .filename:
            return String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/")
        }
    }

    static func pathMatches(rulePath: String, requestPath: String, mode: ResponseOverrideMatchMode) -> Bool {
        switch mode {
        case .exactPath, .ignoreQuery:
            return rulePath == requestPath
        case .pathPrefix:
            if rulePath == "/" {
                return true
            }
            return requestPath == rulePath || requestPath.hasPrefix(rulePath.hasSuffix("/") ? rulePath : "\(rulePath)/")
        case .pathSuffix:
            return requestPath.hasSuffix(rulePath)
        case .filename:
            return lastPathComponent(of: rulePath) == lastPathComponent(of: requestPath)
        }
    }

    static func lastPathComponent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    static func canonicalPort(_ port: Int?, scheme: SessionScheme) -> Int {
        if let port {
            return port
        }

        switch scheme {
        case .http:
            return 80
        case .https:
            return 443
        }
    }

    private static func listPaths(_ paths: [String], max: Int) -> String {
        guard paths.count > max else {
            return paths.joined(separator: ", ")
        }
        let listed = paths.prefix(max).joined(separator: ", ")
        return "\(listed), +\(paths.count - max) more"
    }
}
