import Foundation

/// Runtime configuration for a bookmark response intercept rule.
struct BookmarkResponseInterceptConfig: Equatable, Sendable {
    let bookmarkID: UUID
    let bookmarkName: String
    let request: CapturedRequest
    let savedResponse: BookmarkSavedResponse
    let responseRewrites: [BookmarkResponseFieldRewrite]
    let matchMode: ResponseOverrideMatchMode
    let createdAt: Date
    let mcpOrigin: MCPObjectOrigin?
    let mcpProvenance: MCPProvenance?
}

/// Session-scoped bookmark response intercept evaluation.
///
/// Holds bookmark rewrite definitions synced from ``ProxyViewModel`` and applies them only
/// when their bookmark IDs are present in the session-enabled set. This store is never
/// persisted to UserDefaults.
actor BookmarkResponseInterceptStore {
    private var configsByID: [UUID: BookmarkResponseInterceptConfig] = [:]
    private var enabledBookmarkIDs: Set<UUID> = []

    /// Replaces the in-memory bookmark intercept catalog.
    func syncBookmarks(_ bookmarks: [Bookmark]) {
        configsByID = Dictionary(
            uniqueKeysWithValues: bookmarks.compactMap { bookmark in
                guard let savedResponse = bookmark.savedResponse else {
                    return nil
                }

                return (
                    bookmark.id,
                    BookmarkResponseInterceptConfig(
                        bookmarkID: bookmark.id,
                        bookmarkName: bookmark.name,
                        request: bookmark.request,
                        savedResponse: savedResponse,
                        responseRewrites: bookmark.responseRewrites,
                        matchMode: bookmark.responseMatchMode,
                        createdAt: bookmark.createdAt,
                        mcpOrigin: bookmark.mcpOrigin,
                        mcpProvenance: bookmark.mcpProvenance
                    )
                )
            }
        )

        enabledBookmarkIDs = enabledBookmarkIDs.intersection(Set(configsByID.keys))
    }

    /// Updates which bookmark response rewrites are active for the current proxy session.
    func setEnabledBookmarkIDs(_ ids: Set<UUID>) {
        enabledBookmarkIDs = ids.intersection(Set(configsByID.keys))
    }

    func enabledBookmarkIDsSnapshot() -> Set<UUID> {
        enabledBookmarkIDs
    }

    /// Returns capture attribution when the bookmark intercept is MCP-owned.
    func mcpAttribution(forBookmarkID bookmarkID: UUID) -> MCPCaptureAttribution? {
        guard let config = configsByID[bookmarkID],
              config.mcpOrigin == .mcp,
              config.responseRewrites.contains(where: \.isRuleEnabled),
              let provenance = config.mcpProvenance else {
            return nil
        }
        return MCPActiveEffectAttributionResolver.attribution(
            for: Bookmark(
                id: config.bookmarkID,
                name: config.bookmarkName,
                request: config.request,
                responseRewrites: config.responseRewrites,
                mcpOrigin: config.mcpOrigin,
                mcpProvenance: config.mcpProvenance
            )
        )
    }

    /// Evaluates session-enabled bookmark response rewrites against an incoming request.
    ///
    /// Returns a local override decision when a bookmark matches and has at least one enabled
    /// rewrite rule. Bookmarks are considered in creation order (newest first).
    func ruleDecision(for request: CapturedRequest) throws -> ProxyRuleDecision? {
        let orderedConfigs = configsByID.values
            .filter { enabledBookmarkIDs.contains($0.bookmarkID) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.bookmarkID.uuidString > rhs.bookmarkID.uuidString
                }
                return lhs.createdAt > rhs.createdAt
            }

        guard let config = orderedConfigs.first(where: { matches(config: $0, request: request) }) else {
            return nil
        }

        guard config.responseRewrites.contains(where: \.isRuleEnabled) else {
            return nil
        }

        let rewriteResult = try BookmarkJSONRewriteEngine.apply(
            bodyData: config.savedResponse.bodyData,
            rewrites: config.responseRewrites
        )

        var headers = sanitizedHeaders(config.savedResponse.headers)
        headers = upsertingHeader(
            named: "Content-Type",
            value: inferredJSONContentType(from: headers),
            in: headers
        )

        let sourceDescription = BookmarkRequestMatcher.sourceDescription(
            bookmarkName: config.bookmarkName,
            rewrites: config.responseRewrites,
            rewriteResult: rewriteResult
        )

        return .mapLocal(
            ResolvedResponseOverride(
                ruleID: config.bookmarkID,
                statusCode: config.savedResponse.statusCode,
                headers: headers,
                bodyData: rewriteResult.patchedData,
                sourceKind: .inlineText,
                sourceDescription: sourceDescription,
                capturedResponseSource: .bookmarkResponseRewrite
            )
        )
    }

    private func matches(config: BookmarkResponseInterceptConfig, request: CapturedRequest) -> Bool {
        BookmarkRequestMatcher.matches(
            ruleRequest: config.request,
            matchMode: config.matchMode,
            request: request
        )
    }

    private func sanitizedHeaders(_ headers: [HTTPHeaderField]) -> [HTTPHeaderField] {
        headers.filter { header in
            let lowercasedName = header.name.lowercased()
            return lowercasedName != "content-length" &&
                lowercasedName != "connection" &&
                lowercasedName != "transfer-encoding" &&
                lowercasedName != "proxy-connection" &&
                lowercasedName != "content-encoding"
        }
    }

    private func upsertingHeader(named name: String, value: String, in headers: [HTTPHeaderField]) -> [HTTPHeaderField] {
        let filteredHeaders = headers.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        return filteredHeaders + [HTTPHeaderField(name: name, value: value)]
    }

    private func inferredJSONContentType(from headers: [HTTPHeaderField]) -> String {
        if let contentType = headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines), !contentType.isEmpty {
            return contentType
        }

        return "application/json; charset=utf-8"
    }
}
