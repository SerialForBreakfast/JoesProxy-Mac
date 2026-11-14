import Foundation
import os
import UniformTypeIdentifiers

private let overrideLogger = Logger(subsystem: "com.JoesProxyApp.Capture", category: "Overrides")

/// Describes the origin of a captured response.
enum CapturedResponseSource: String, Codable, Equatable, Sendable {
    /// Response came from the real upstream server.
    case upstream
    /// Response was served from a Map Local override (captured draft, inline text, or local file).
    case localOverride
    /// Request was dropped and a synthetic error response was returned by a Block rule.
    case blocked
    /// Request was forwarded to a different upstream host by a Map Remote rule.
    case mapRemote
    /// Request was replaced with a saved bookmark request before contacting upstream.
    case bookmarkRewrite
    /// Response was served from a bookmark saved snapshot with configured field overrides.
    case bookmarkResponseRewrite
    /// Response came from the real upstream server with in-flight JSON field overrides applied.
    case liveResponseRewrite
}

enum ResponseOverrideSourceKind: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
    case capturedResponse
    case inlineText
    case localFile
    /// Drops matching requests and returns a synthetic error response without contacting upstream.
    case block
    /// Forwards matching requests to a different upstream host instead of the original destination.
    case mapRemote
    /// Replaces matching requests with the full request saved in a bookmark.
    case bookmarkRewrite
    /// Forwards matching requests to the real backend and may patch JSON in the returned response.
    case liveResponseRewrite
    /// Forwards matching requests to the real backend and may apply a reviewed collection-shape
    /// mutation (add/remove/duplicate items) to the returned JSON response. Created only through
    /// the dedicated collection-mock authoring/activation path, never from
    /// `creatableFromCapturedSession`.
    case collectionMock
    /// Delegates to a running HLS fixture run's live server instead of a static body — the
    /// fixture computes the response per request (sliding playlist window, Range-aware segment
    /// bytes) rather than JoesProxy resolving one fixed body at rule-creation time. Requires
    /// `matchMode == .pathPrefix` (a fixture run serves a whole directory tree, not one URL) and
    /// is created only through the dedicated fixture-redirect Map Local MCP/CLI path, never from
    /// `creatableFromCapturedSession`.
    case fixtureRun
    /// Serves files from a user-chosen directory under a path-prefix matcher (AS). Requires
    /// `matchMode == .pathPrefix`. Body is resolved per request via `LocalDirectoryServer`
    /// (same fail-open / traversal discipline as `.fixtureRun`).
    case localDirectory

    var id: String { rawValue }

    static var creatableFromCapturedSession: [ResponseOverrideSourceKind] {
        [.capturedResponse, .inlineText, .localFile, .localDirectory, .block, .mapRemote]
    }

    var title: String {
        switch self {
        case .capturedResponse:
            return "Captured Response"
        case .inlineText:
            return "Inline Text"
        case .localFile:
            return "Local File"
        case .localDirectory:
            return "Local Directory"
        case .block:
            return "Block Request"
        case .mapRemote:
            return "Map Remote"
        case .bookmarkRewrite:
            return "Bookmark Rewrite"
        case .liveResponseRewrite:
            return "Live Response Rewrite"
        case .collectionMock:
            return "Collection Mock"
        case .fixtureRun:
            return "Fixture Redirect"
        }
    }

    var sourceDescription: String {
        switch self {
        case .capturedResponse:
            return "Captured response draft"
        case .inlineText:
            return "Inline text override"
        case .localFile:
            return "Local file override"
        case .localDirectory:
            return "Local directory override"
        case .block:
            return "Blocked by JoesProxy"
        case .mapRemote:
            return "Remapped to remote host"
        case .bookmarkRewrite:
            return "Rewritten from bookmark"
        case .liveResponseRewrite:
            return "Live response rewrite"
        case .collectionMock:
            return "Live collection mock"
        case .fixtureRun:
            return "HLS fixture run redirect"
        }
    }

    /// Rule kinds that cannot share the same matcher with another enabled rule in v1.
    static var exclusiveSourceKinds: Set<ResponseOverrideSourceKind> {
        [.block, .mapRemote, .bookmarkRewrite, .liveResponseRewrite, .collectionMock, .capturedResponse, .inlineText, .localFile, .fixtureRun, .localDirectory]
    }
}

/// The outcome of evaluating proxy rules against an incoming request.
/// Returned by ``ResponseOverrideStore/ruleDecision(for:)`` and consumed by the connection handler.
enum ProxyRuleDecision: Sendable {
    /// No enabled rule matched. Proceed to the upstream server normally.
    case noMatch
    /// Serve a locally generated response; do not contact the upstream server.
    case mapLocal(ResolvedResponseOverride)
    /// Return a synthetic error response; do not contact the upstream server.
    /// `dropConnection` selects between two observably different failure modes a real dependency
    /// can produce: `false` (the default) serves a well-formed HTTP error the client reads as "the
    /// server answered no"; `true` closes the connection with no response at all, which a client
    /// sees as a timeout/reset — "nothing answered." Recovery logic frequently branches on which
    /// of these happened, so JoesProxy needs to be able to reproduce either one deliberately.
    case block(ruleID: UUID, statusCode: Int, sourceDescription: String, dropConnection: Bool)
    /// Forward the request to a different upstream host and port using the specified scheme.
    /// `requestTarget` is the resolved path(+query) to send upstream — `nil` means "reuse the
    /// original request's path/query verbatim," the only behavior that existed before
    /// `mapRemotePath` did; a non-nil value is the fully resolved override, already combined with
    /// the query per the rule's `MapRemoteQueryPolicy`.
    case mapRemote(
        ruleID: UUID,
        host: String,
        port: Int,
        scheme: SessionScheme,
        requestTarget: String?,
        allowLoopbackDestination: Bool,
        preserveHostHeader: Bool
    )
    /// Matching Map Remote rule was denied by local-server or address policy (fail-closed: never
    /// fall through to `.noMatch` / original upstream).
    case deniedMapRemote(ruleID: UUID, reason: MapRemoteDenialReason, detail: String)
    /// Replace the upstream request with a saved bookmark request.
    case bookmarkRewrite(ruleID: UUID, request: CapturedRequest, sourceDescription: String)
    /// Forward the original request upstream and apply JSON mutations to the real response body.
    case liveResponseRewrite(
        ruleID: UUID,
        rewrites: [BookmarkResponseFieldRewrite],
        sourceDescription: String,
        expectedSchemaFingerprint: JSONSchemaShapeFingerprint?
    )
    /// Forward the original request upstream and apply a reviewed collection-shape mutation to
    /// the real response body.
    case liveCollectionMock(
        ruleID: UUID,
        plan: CompiledCollectionMock,
        sourceDescription: String,
        revision: LiveCollectionTransformationExecutor.Revision?
    )
    /// Delegate to a running HLS fixture run's server for this specific request instead of a
    /// pre-resolved body. `relativePath` has already had the matcher's `path` prefix stripped, so
    /// the caller can pass it directly to `HLSFixtureServer.response(forPath:method:rangeHeader:)`
    /// — the identical call already used for reserved-host fixture dispatch. Callers must fail
    /// open (behave as `.noMatch`) if the referenced run is no longer active; this case only
    /// represents a matched rule, not a guarantee the run still exists.
    case fixtureRedirect(ruleID: UUID, runID: UUID, relativePath: String)
    /// Delegate to a user-chosen directory for this request. `relativePath` has the matcher
    /// `path` prefix stripped. Callers resolve the rule's directory bookmark and must fail open
    /// when the bookmark is stale/unreadable — same safety contract as `.fixtureRedirect`.
    case localDirectoryRedirect(ruleID: UUID, relativePath: String)
}

/// Runtime context for applying live-response JSON mutations after upstream returns.
struct LiveResponseRewriteContext: Sendable {
    let ruleID: UUID
    let rewrites: [BookmarkResponseFieldRewrite]
    let sourceDescription: String
    let expectedSchemaFingerprint: JSONSchemaShapeFingerprint?
}

/// Runtime context for applying a reviewed collection-shape mutation after upstream returns.
/// Mirrors `LiveResponseRewriteContext`; at most one of the two is ever set per request, since
/// both are derived from the same single matched rule's `sourceKind`.
struct LiveCollectionMockContext: Sendable {
    let ruleID: UUID
    let plan: CompiledCollectionMock
    let sourceDescription: String
    let revision: LiveCollectionTransformationExecutor.Revision?

    init(
        ruleID: UUID,
        plan: CompiledCollectionMock,
        sourceDescription: String,
        revision: LiveCollectionTransformationExecutor.Revision? = nil
    ) {
        self.ruleID = ruleID
        self.plan = plan
        self.sourceDescription = sourceDescription
        self.revision = revision
    }
}

/// Formats live-response rewrite descriptions for rules and capture attribution.
enum LiveResponseRewriteDescriptions {
    static func ruleSourceDescription(rewrites: [BookmarkResponseFieldRewrite]) -> String {
        let enabledPaths = rewrites.filter(\.isRuleEnabled).map(\.jsonPath)
        guard !enabledPaths.isEmpty else {
            return ResponseOverrideSourceKind.liveResponseRewrite.sourceDescription
        }
        return "\(ResponseOverrideSourceKind.liveResponseRewrite.sourceDescription): \(enabledPaths.joined(separator: ", "))"
    }

    static func captureSourceDescription(
        baseDescription: String,
        result: LiveResponseTransformationResult
    ) -> String {
        var parts = [baseDescription]
        if result.wasTransformed {
            parts.append("applied: \(result.appliedMutationIDs.count)")
            if !result.skippedMutationIDs.isEmpty {
                parts.append("skipped: \(result.skippedMutationIDs.count)")
            }
        } else if result.matchedButNotApplied {
            parts.append("matched, not applied")
        }
        return parts.joined(separator: " · ")
    }
}

/// Formats live collection-mock outcomes for capture attribution — the "skip receipt": every
/// `LiveCollectionTransformationResult.Outcome` case is surfaced by name so a skipped transform is
/// distinguishable from an applied one in the capture record, without inventing a separate receipt type.
enum LiveCollectionMockDescriptions {
    static func captureSourceDescription(
        baseDescription: String,
        outcome: LiveCollectionTransformationResult.Outcome
    ) -> String {
        switch outcome {
        case .applied(let beforeCount, let afterCount):
            return "\(baseDescription) · applied: \(beforeCount) → \(afterCount) items"
        case .alreadyPresent:
            return "\(baseDescription) · skipped: already present"
        case .ineligibleResponse:
            return "\(baseDescription) · skipped: ineligible response"
        case .unsupportedEncoding:
            return "\(baseDescription) · skipped: unsupported encoding"
        case .sizeLimit:
            return "\(baseDescription) · skipped: size limit"
        case .decodeFailed:
            return "\(baseDescription) · skipped: decode failed"
        case .contractMismatch(let error):
            return "\(baseDescription) · skipped: contract mismatch (\(error))"
        case .encodingFailed:
            return "\(baseDescription) · skipped: re-encoding failed"
        case .capacityLimited:
            return "\(baseDescription) · skipped: capacity limited"
        case .inactiveRevision:
            return "\(baseDescription) · skipped: inactive revision"
        case .cancelled:
            return "\(baseDescription) · skipped: cancelled"
        }
    }
}

enum ResponseOverrideBodySource: Equatable, Sendable {
    case inline(Data?)
    case file(URL)
    /// Root directory for `.localDirectory` rules (security-scoped URL at runtime).
    case directory(URL)
}

enum ResponseOverrideConflictStrategy: String, CaseIterable, Identifiable, Equatable, Sendable {
    case keepBoth
    case replaceExisting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepBoth:
            return "Keep Both"
        case .replaceExisting:
            return "Replace Existing"
        }
    }
}

enum ResponseOverrideMatchMode: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
    case exactPath
    case ignoreQuery
    case pathPrefix
    /// Matches when the request path ends with the rule's path, ignoring query string
    /// differences. Unlike `.pathPrefix`, this distinguishes endpoints that share a dynamic
    /// path segment but diverge only in their trailing suffix (e.g. `/v1/sessions/{id}/heartbeat`
    /// vs `/v1/sessions/{id}/status`, which share the `/v1/sessions/` prefix through an
    /// unpredictable id) — `.pathPrefix` cannot separate those two without also matching every
    /// other sibling under the same prefix.
    case pathSuffix
    /// Matches on the request path's last path component alone, regardless of which directory
    /// it's nested under — e.g. a rule for `poster.png` matches `/v1/thumbs/poster.png` and
    /// `/v2/catalog/1234/poster.png` alike. Distinct from `.pathSuffix`, which anchors to the
    /// rule's entire captured path (so a differently-nested request never matches); this was
    /// previously only reachable as a manual workaround (a `.pathSuffix` rule whose path had been
    /// hand-edited down to just the filename).
    case filename

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exactPath:
            return "Exact Path"
        case .ignoreQuery:
            return "Ignore Query"
        case .pathPrefix:
            return "Path Prefix"
        case .pathSuffix:
            return "Path Suffix"
        case .filename:
            return "Filename"
        }
    }

    var description: String {
        switch self {
        case .exactPath:
            return "Match the full request path including query."
        case .ignoreQuery:
            return "Match the path and ignore query string differences."
        case .pathPrefix:
            return "Match this path and anything below it, ignoring query string differences."
        case .pathSuffix:
            return "Match any path ending with this value, ignoring query string differences."
        case .filename:
            return "Match any request whose last path component equals this filename, regardless of nesting."
        }
    }
}

/// How a `.mapRemote` rule's overridden `mapRemotePath` combines with the original request's
/// query string. Only meaningful when `mapRemotePath` is set — a rule with no path override
/// reuses the original request-target verbatim, unchanged, exactly as before this field existed.
enum MapRemoteQueryPolicy: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
    /// Keep the original request's query string, appended to the overridden path.
    case preserve
    /// Replace the query string with `mapRemoteQuery` (empty query if that's nil).
    case replace
    /// Drop any query string; the overridden path is used with no query.
    case drop

    var id: String { rawValue }
}

/// How a `.localDirectory` rule serves a request whose relative path has no matching file in the
/// bookmarked folder. Directory Map Local is an all-or-nothing overlay by default — a rule meant to
/// edit three files also shadows every other real sibling under the same path prefix, turning them
/// into local 404s instead of reaching the real upstream. This makes that behavior an explicit,
/// named choice instead of the only option.
enum LocalDirectoryMissingFilePolicy: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
    /// Today's original behavior: a miss is always a local 404 (or, if `notFoundRelativePath` is
    /// set, that file's bytes served under a forced 404 status). Nothing reaches upstream.
    case strictLocal
    /// A miss forwards to the real upstream server instead of 404ing — only files that actually
    /// exist locally are served from disk; every unedited sibling behaves as if no rule existed.
    case overlayFailOpen
    /// A miss serves `notFoundRelativePath`'s bytes under a forced 404 status, identical to today's
    /// `notFoundRelativePath` behavior under `.strictLocal` — kept as its own named case so a rule
    /// can require this explicitly (validated at creation time to actually have the field set).
    case configuredFallback

    var id: String { rawValue }
}

private enum PersistedResponseOverrideBodySource: Codable, Equatable {
    case inline(Data?)
    case file(bookmarkData: Data)
    case directory(bookmarkData: Data)

    private enum CodingKeys: String, CodingKey {
        case kind
        case inlineData
        case bookmarkData
    }

    private enum Kind: String, Codable {
        case inline
        case file
        case directory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .inline:
            self = .inline(try container.decodeIfPresent(Data.self, forKey: .inlineData))
        case .file:
            self = .file(bookmarkData: try container.decode(Data.self, forKey: .bookmarkData))
        case .directory:
            self = .directory(bookmarkData: try container.decode(Data.self, forKey: .bookmarkData))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inline(let data):
            try container.encode(Kind.inline, forKey: .kind)
            try container.encodeIfPresent(data, forKey: .inlineData)
        case .file(let bookmarkData):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(bookmarkData, forKey: .bookmarkData)
        case .directory(let bookmarkData):
            try container.encode(Kind.directory, forKey: .kind)
            try container.encode(bookmarkData, forKey: .bookmarkData)
        }
    }
}

private struct PersistedResponseOverrideRule: Equatable {
    let id: UUID
    let label: String?
    let requestMethod: String
    let requestScheme: SessionScheme
    let host: String
    let port: Int?
    let path: String
    let matchMode: ResponseOverrideMatchMode
    let sourceKind: ResponseOverrideSourceKind
    let sourceDescription: String
    let statusCode: Int
    let headers: [HTTPHeaderField]
    let bodySource: PersistedResponseOverrideBodySource
    let createdAt: Date
    let isEnabled: Bool
    let hitCount: Int
    let lastMatchedAt: Date?
    // Present only for .mapRemote rules; nil for all other source kinds.
    let mapRemoteHost: String?
    let mapRemotePort: Int?
    let mapRemoteScheme: SessionScheme?
    /// Optional destination request-target override for `.mapRemote` rules. `nil` means "reuse
    /// the original request's path/query," the only behavior that existed before this field.
    let mapRemotePath: String?
    /// How `mapRemotePath` combines with the original request's query. Meaningless when
    /// `mapRemotePath` is nil. Defaults to `.preserve` on decode for rules persisted before this
    /// field existed, matching their only actual prior behavior (query always preserved).
    let mapRemoteQueryPolicy: MapRemoteQueryPolicy
    /// Replacement query string for `mapRemoteQueryPolicy == .replace`. Ignored otherwise.
    let mapRemoteQuery: String?
    /// Explicit per-rule intent allowing `.mapRemote` to target local Mac loopback endpoints.
    let allowLoopbackDestination: Bool
    /// When `true` on `.mapRemote`, forwards the validated original incoming `Host` authority
    /// instead of synthesizing the destination `host[:port]`.
    let preserveHostHeader: Bool
    // Present only for .bookmarkRewrite rules; nil for all other source kinds.
    let bookmarkRewriteRequest: CapturedRequest?
    /// JSON field overrides for `.liveResponseRewrite` rules; empty for all other source kinds.
    let liveResponseRewrites: [BookmarkResponseFieldRewrite]
    /// Optional required response shape for `.liveResponseRewrite` rules — when set, a live
    /// response whose structure has drifted from this fingerprint fails open (schema drift)
    /// rather than applying selectors to an unreviewed structure. `nil` means no requirement
    /// (matches the only behavior that existed before this field).
    let expectedSchemaFingerprint: JSONSchemaShapeFingerprint?
    /// Reviewed collection-shape mutation for `.collectionMock` rules; nil for all other source kinds.
    let collectionMockPlan: CompiledCollectionMock?
    let mcpOrigin: MCPObjectOrigin?
    let mcpProvenance: MCPProvenance?
    let mcpTargetRevision: MCPTargetRevision?
    /// Owning portable bundle. Bundle rules are restored disabled and become effective only while
    /// the corresponding activation gate is open.
    let effectBundleID: UUID?
    let dropConnection: Bool
    /// Present only for .fixtureRun rules; nil for all other source kinds.
    let fixtureRunID: UUID?
    let forceNoCache: Bool
    /// `.localDirectory` only: optional relative path served as a 404 body when the requested
    /// file is missing. `nil` means a generic empty 404 (same as fixture static miss).
    let notFoundRelativePath: String?
    /// `.localDirectory` only: how a request under the rule's prefix with no matching local file is
    /// served. Defaults to `.strictLocal` (today's original, only-ever behavior) for old persisted
    /// rules and every other source kind.
    let missingFilePolicy: LocalDirectoryMissingFilePolicy
    /// Optional GraphQL operation-name predicate: when set, this rule only matches a request whose
    /// JSON body's top-level `operationName` field equals this value. `nil` means "match every
    /// operation," the only behavior that existed before this field.
    let graphQLOperationName: String?
    /// Optional query-parameter predicate: when both are set, this rule only matches a request
    /// whose query string contains this exact key=value pair. `nil` (either field) means "match
    /// regardless of query," the only behavior that existed before this field — mocks one item on
    /// a query-multiplexed endpoint (e.g. `?contentId=1234`) without affecting other values of the
    /// same parameter on the same path.
    let matchQueryKey: String?
    let matchQueryValue: String?
    /// Optional header predicate: when both are set, this rule only matches a request
    /// containing this exact HTTP header name and value.
    let matchHeaderName: String?
    let matchHeaderValue: String?
    /// Optional client IP address filter: when set, this rule only matches requests originating from
    /// this specific device/client address (DL-4). `nil` means match requests from any client address.
    let sourceClientAddress: String?
    var ignoredQueryNames: [String]? = nil
}

extension PersistedResponseOverrideRule: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, label, requestMethod, requestScheme, host, port, path
        case matchMode, sourceKind, sourceDescription, statusCode, headers
        case bodySource, createdAt, isEnabled, hitCount, lastMatchedAt
        case mapRemoteHost, mapRemotePort, mapRemoteScheme
        case mapRemotePath, mapRemoteQueryPolicy, mapRemoteQuery
        case allowLoopbackDestination, preserveHostHeader
        case bookmarkRewriteRequest
        case liveResponseRewrites
        case expectedSchemaFingerprint
        case collectionMockPlan
        case mcpOrigin, mcpProvenance, mcpTargetRevision
        case effectBundleID
        case dropConnection
        case fixtureRunID
        case forceNoCache
        case notFoundRelativePath
        case missingFilePolicy
        case graphQLOperationName
        case matchQueryKey
        case matchQueryValue
        case matchHeaderName
        case matchHeaderValue
        case sourceClientAddress
        case ignoredQueryNames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        requestMethod = try c.decode(String.self, forKey: .requestMethod)
        requestScheme = try c.decode(SessionScheme.self, forKey: .requestScheme)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        path = try c.decode(String.self, forKey: .path)
        matchMode = try c.decode(ResponseOverrideMatchMode.self, forKey: .matchMode)
        sourceKind = try c.decode(ResponseOverrideSourceKind.self, forKey: .sourceKind)
        sourceDescription = try c.decode(String.self, forKey: .sourceDescription)
        statusCode = try c.decode(Int.self, forKey: .statusCode)
        headers = try c.decode([HTTPHeaderField].self, forKey: .headers)
        bodySource = try c.decode(PersistedResponseOverrideBodySource.self, forKey: .bodySource)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        hitCount = try c.decode(Int.self, forKey: .hitCount)
        lastMatchedAt = try c.decodeIfPresent(Date.self, forKey: .lastMatchedAt)
        mapRemoteHost = try c.decodeIfPresent(String.self, forKey: .mapRemoteHost)
        mapRemotePort = try c.decodeIfPresent(Int.self, forKey: .mapRemotePort)
        mapRemoteScheme = try c.decodeIfPresent(SessionScheme.self, forKey: .mapRemoteScheme)
        mapRemotePath = try c.decodeIfPresent(String.self, forKey: .mapRemotePath)
        mapRemoteQueryPolicy = try c.decodeIfPresent(MapRemoteQueryPolicy.self, forKey: .mapRemoteQueryPolicy) ?? .preserve
        mapRemoteQuery = try c.decodeIfPresent(String.self, forKey: .mapRemoteQuery)
        allowLoopbackDestination = try c.decodeIfPresent(Bool.self, forKey: .allowLoopbackDestination) ?? false
        preserveHostHeader = try c.decodeIfPresent(Bool.self, forKey: .preserveHostHeader) ?? false
        bookmarkRewriteRequest = try c.decodeIfPresent(CapturedRequest.self, forKey: .bookmarkRewriteRequest)
        liveResponseRewrites = try c.decodeIfPresent([BookmarkResponseFieldRewrite].self, forKey: .liveResponseRewrites) ?? []
        expectedSchemaFingerprint = try c.decodeIfPresent(JSONSchemaShapeFingerprint.self, forKey: .expectedSchemaFingerprint)
        collectionMockPlan = try c.decodeIfPresent(CompiledCollectionMock.self, forKey: .collectionMockPlan)
        mcpOrigin = try c.decodeIfPresent(MCPObjectOrigin.self, forKey: .mcpOrigin)
        mcpProvenance = try c.decodeIfPresent(MCPProvenance.self, forKey: .mcpProvenance)
        mcpTargetRevision = try c.decodeIfPresent(MCPTargetRevision.self, forKey: .mcpTargetRevision)
        effectBundleID = try c.decodeIfPresent(UUID.self, forKey: .effectBundleID)
        dropConnection = try c.decodeIfPresent(Bool.self, forKey: .dropConnection) ?? false
        fixtureRunID = try c.decodeIfPresent(UUID.self, forKey: .fixtureRunID)
        forceNoCache = try c.decodeIfPresent(Bool.self, forKey: .forceNoCache) ?? false
        notFoundRelativePath = try c.decodeIfPresent(String.self, forKey: .notFoundRelativePath)
        missingFilePolicy = try c.decodeIfPresent(LocalDirectoryMissingFilePolicy.self, forKey: .missingFilePolicy) ?? .strictLocal
        graphQLOperationName = try c.decodeIfPresent(String.self, forKey: .graphQLOperationName)
        matchQueryKey = try c.decodeIfPresent(String.self, forKey: .matchQueryKey)
        matchQueryValue = try c.decodeIfPresent(String.self, forKey: .matchQueryValue)
        matchHeaderName = try c.decodeIfPresent(String.self, forKey: .matchHeaderName)
        matchHeaderValue = try c.decodeIfPresent(String.self, forKey: .matchHeaderValue)
        sourceClientAddress = try c.decodeIfPresent(String.self, forKey: .sourceClientAddress)
        ignoredQueryNames = try c.decodeIfPresent([String].self, forKey: .ignoredQueryNames)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(requestMethod, forKey: .requestMethod)
        try c.encode(requestScheme, forKey: .requestScheme)
        try c.encode(host, forKey: .host)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encode(path, forKey: .path)
        try c.encode(matchMode, forKey: .matchMode)
        try c.encode(sourceKind, forKey: .sourceKind)
        try c.encode(sourceDescription, forKey: .sourceDescription)
        try c.encode(statusCode, forKey: .statusCode)
        try c.encode(headers, forKey: .headers)
        try c.encode(bodySource, forKey: .bodySource)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(hitCount, forKey: .hitCount)
        try c.encodeIfPresent(lastMatchedAt, forKey: .lastMatchedAt)
        try c.encodeIfPresent(mapRemoteHost, forKey: .mapRemoteHost)
        try c.encodeIfPresent(mapRemotePort, forKey: .mapRemotePort)
        try c.encodeIfPresent(mapRemoteScheme, forKey: .mapRemoteScheme)
        try c.encodeIfPresent(mapRemotePath, forKey: .mapRemotePath)
        try c.encode(mapRemoteQueryPolicy, forKey: .mapRemoteQueryPolicy)
        try c.encodeIfPresent(mapRemoteQuery, forKey: .mapRemoteQuery)
        try c.encode(allowLoopbackDestination, forKey: .allowLoopbackDestination)
        try c.encode(preserveHostHeader, forKey: .preserveHostHeader)
        try c.encodeIfPresent(bookmarkRewriteRequest, forKey: .bookmarkRewriteRequest)
        try c.encode(liveResponseRewrites, forKey: .liveResponseRewrites)
        try c.encodeIfPresent(expectedSchemaFingerprint, forKey: .expectedSchemaFingerprint)
        try c.encodeIfPresent(collectionMockPlan, forKey: .collectionMockPlan)
        try c.encodeIfPresent(mcpOrigin, forKey: .mcpOrigin)
        try c.encodeIfPresent(mcpProvenance, forKey: .mcpProvenance)
        try c.encodeIfPresent(mcpTargetRevision, forKey: .mcpTargetRevision)
        try c.encodeIfPresent(effectBundleID, forKey: .effectBundleID)
        try c.encode(dropConnection, forKey: .dropConnection)
        try c.encodeIfPresent(fixtureRunID, forKey: .fixtureRunID)
        try c.encode(forceNoCache, forKey: .forceNoCache)
        try c.encodeIfPresent(notFoundRelativePath, forKey: .notFoundRelativePath)
        try c.encode(missingFilePolicy, forKey: .missingFilePolicy)
        try c.encodeIfPresent(graphQLOperationName, forKey: .graphQLOperationName)
        try c.encodeIfPresent(matchQueryKey, forKey: .matchQueryKey)
        try c.encodeIfPresent(matchQueryValue, forKey: .matchQueryValue)
        try c.encodeIfPresent(matchHeaderName, forKey: .matchHeaderName)
        try c.encodeIfPresent(matchHeaderValue, forKey: .matchHeaderValue)
        try c.encodeIfPresent(sourceClientAddress, forKey: .sourceClientAddress)
        try c.encodeIfPresent(ignoredQueryNames, forKey: .ignoredQueryNames)
    }
}

struct ResponseOverrideRule: Identifiable, Equatable, Sendable {
    /// Activation-scoped, never persisted; stays pinned while a selected file is being read.
    var authoredResource: EffectBundleResourceIdentity? = nil
    let id: UUID
    var label: String?
    let requestMethod: String
    let requestScheme: SessionScheme
    let host: String
    let port: Int?
    var path: String
    var matchMode: ResponseOverrideMatchMode
    let sourceKind: ResponseOverrideSourceKind
    var sourceDescription: String
    var statusCode: Int
    var headers: [HTTPHeaderField]
    var bodySource: ResponseOverrideBodySource
    let createdAt: Date
    var isEnabled: Bool
    var hitCount: Int
    var lastMatchedAt: Date?
    /// Target host for `.mapRemote` rules. `nil` for all other source kinds.
    var mapRemoteHost: String?
    /// Target port for `.mapRemote` rules. `nil` means derive from `mapRemoteScheme`.
    var mapRemotePort: Int?
    /// Target scheme for `.mapRemote` rules. `nil` for all other source kinds.
    var mapRemoteScheme: SessionScheme?
    /// Optional destination request-target override for `.mapRemote` rules. `nil` means "reuse
    /// the original request's path/query," the only behavior that existed before this field.
    var mapRemotePath: String?
    /// How `mapRemotePath` combines with the original request's query. Meaningless when
    /// `mapRemotePath` is nil.
    var mapRemoteQueryPolicy: MapRemoteQueryPolicy
    /// Replacement query string for `mapRemoteQueryPolicy == .replace`. Ignored otherwise.
    var mapRemoteQuery: String?
    /// Explicit per-rule intent allowing `.mapRemote` to target local Mac loopback endpoints.
    var allowLoopbackDestination: Bool
    /// When `true` on `.mapRemote`, preserves the validated incoming `Host` authority.
    var preserveHostHeader: Bool
    /// Full upstream replacement request for `.bookmarkRewrite` rules. `nil` for all other source kinds.
    var bookmarkRewriteRequest: CapturedRequest?
    /// JSON field overrides for `.liveResponseRewrite` rules.
    var liveResponseRewrites: [BookmarkResponseFieldRewrite]
    /// Optional required response shape for `.liveResponseRewrite` rules — see
    /// `PersistedResponseOverrideRule.expectedSchemaFingerprint`.
    var expectedSchemaFingerprint: JSONSchemaShapeFingerprint?
    /// Reviewed collection-shape mutation for `.collectionMock` rules; nil for all other source kinds.
    var collectionMockPlan: CompiledCollectionMock?
    var mcpOrigin: MCPObjectOrigin?
    var mcpProvenance: MCPProvenance?
    var mcpTargetRevision: MCPTargetRevision?
    var effectBundleID: UUID?
    /// `.block` rules only: when true, the connection is closed with no HTTP response at all
    /// (simulating a dropped connection/timeout) instead of serving `statusCode`. Ignored for all
    /// other source kinds. Defaults to `false`, the only behavior that existed before this field.
    var dropConnection: Bool
    /// `.fixtureRun` rules only: the `HLSFixtureRunRecord.id` this rule delegates to. `nil` for
    /// all other source kinds. Looked up in `HLSFixtureOriginRegistry.activeEntry(forRunID:)` at
    /// dispatch time — never resolved to a static body at rule-creation time, since the fixture
    /// computes different content per request (sliding playlist window, Range-aware segments).
    var fixtureRunID: UUID?
    /// When `true`, the serving path strips `ETag`/`Last-Modified` and forces `Cache-Control:
    /// no-store` on this rule's response regardless of the global/per-domain no-caching Settings
    /// toggle. Only meaningful for rules that actually serve a response (not `.mapRemote`/
    /// `.bookmarkRewrite`/`.liveResponseRewrite`, which go through the real upstream no-caching
    /// path already). Defaults to `false`, the only behavior that existed before this field.
    var forceNoCache: Bool
    /// `.localDirectory` only: optional relative not-found file inside the chosen directory.
    var notFoundRelativePath: String?
    /// `.localDirectory` only: how a miss (no matching local file) is served. Defaults to
    /// `.strictLocal`, the only behavior that existed before this field.
    var missingFilePolicy: LocalDirectoryMissingFilePolicy
    /// Optional GraphQL operation-name predicate: when set, this rule only matches a request whose
    /// JSON body's top-level `operationName` field equals this value. `nil` means "match every
    /// operation," the only behavior that existed before this field.
    var graphQLOperationName: String?
    /// Optional query-parameter predicate — see `PersistedResponseOverrideRule`'s doc comment.
    var matchQueryKey: String?
    var matchQueryValue: String?
    /// Optional header predicate: when both are set, this rule only matches a request
    /// containing this exact HTTP header name and value.
    var matchHeaderName: String?
    var matchHeaderValue: String?
    /// Optional client IP address filter: when set, this rule only matches requests originating from
    /// this specific device/client address (DL-4). `nil` means match requests from any client address.
    var sourceClientAddress: String?
    var ignoredQueryNames: [String]?

    init(
        id: UUID = UUID(),
        label: String? = nil,
        requestMethod: String,
        requestScheme: SessionScheme,
        host: String,
        port: Int?,
        path: String,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        sourceKind: ResponseOverrideSourceKind,
        sourceDescription: String,
        statusCode: Int,
        headers: [HTTPHeaderField],
        bodySource: ResponseOverrideBodySource,
        createdAt: Date = Date(),
        isEnabled: Bool = true,
        hitCount: Int = 0,
        lastMatchedAt: Date? = nil,
        mapRemoteHost: String? = nil,
        mapRemotePort: Int? = nil,
        mapRemoteScheme: SessionScheme? = nil,
        mapRemotePath: String? = nil,
        mapRemoteQueryPolicy: MapRemoteQueryPolicy = .preserve,
        mapRemoteQuery: String? = nil,
        allowLoopbackDestination: Bool = false,
        preserveHostHeader: Bool = false,
        bookmarkRewriteRequest: CapturedRequest? = nil,
        liveResponseRewrites: [BookmarkResponseFieldRewrite] = [],
        expectedSchemaFingerprint: JSONSchemaShapeFingerprint? = nil,
        collectionMockPlan: CompiledCollectionMock? = nil,
        mcpOrigin: MCPObjectOrigin? = nil,
        mcpProvenance: MCPProvenance? = nil,
        mcpTargetRevision: MCPTargetRevision? = nil,
        effectBundleID: UUID? = nil,
        dropConnection: Bool = false,
        fixtureRunID: UUID? = nil,
        forceNoCache: Bool = false,
        notFoundRelativePath: String? = nil,
        missingFilePolicy: LocalDirectoryMissingFilePolicy = .strictLocal,
        graphQLOperationName: String? = nil,
        matchQueryKey: String? = nil,
        matchQueryValue: String? = nil,
        matchHeaderName: String? = nil,
        matchHeaderValue: String? = nil,
        sourceClientAddress: String? = nil,
        ignoredQueryNames: [String]? = nil
    ) {
        self.id = id
        self.label = label
        self.requestMethod = requestMethod
        self.requestScheme = requestScheme
        self.host = host
        self.port = port
        self.path = path
        self.matchMode = matchMode
        self.sourceKind = sourceKind
        self.sourceDescription = sourceDescription
        self.statusCode = statusCode
        self.headers = headers
        self.bodySource = bodySource
        self.createdAt = createdAt
        self.isEnabled = isEnabled
        self.hitCount = hitCount
        self.lastMatchedAt = lastMatchedAt
        self.mapRemoteHost = mapRemoteHost
        self.mapRemotePort = mapRemotePort
        self.mapRemoteScheme = mapRemoteScheme
        self.mapRemotePath = mapRemotePath
        self.mapRemoteQueryPolicy = mapRemoteQueryPolicy
        self.mapRemoteQuery = mapRemoteQuery
        self.allowLoopbackDestination = allowLoopbackDestination
        self.preserveHostHeader = preserveHostHeader
        self.bookmarkRewriteRequest = bookmarkRewriteRequest
        self.liveResponseRewrites = liveResponseRewrites
        self.expectedSchemaFingerprint = expectedSchemaFingerprint
        self.collectionMockPlan = collectionMockPlan
        self.mcpOrigin = mcpOrigin
        self.mcpProvenance = mcpProvenance
        self.mcpTargetRevision = mcpTargetRevision
        self.effectBundleID = effectBundleID
        self.dropConnection = dropConnection
        self.fixtureRunID = fixtureRunID
        self.forceNoCache = forceNoCache
        self.notFoundRelativePath = notFoundRelativePath
        self.missingFilePolicy = missingFilePolicy
        self.graphQLOperationName = graphQLOperationName
        self.matchQueryKey = matchQueryKey
        self.matchQueryValue = matchQueryValue
        self.matchHeaderName = matchHeaderName
        self.matchHeaderValue = matchHeaderValue
        self.sourceClientAddress = sourceClientAddress
        self.ignoredQueryNames = ignoredQueryNames
    }

    var title: String {
        "\(requestMethod) \(host)\(path)"
    }

    var displayTitle: String {
        guard let label, !label.isEmpty else {
            return title
        }
        return label
    }
}

struct ResolvedResponseOverride: Sendable {
    var authoredResource: EffectBundleResourceIdentity? = nil
    let ruleID: UUID
    let statusCode: Int
    let headers: [HTTPHeaderField]
    let bodyData: Data?
    let sourceKind: ResponseOverrideSourceKind
    let sourceDescription: String
    /// When set, overrides the default response source derived from ``sourceKind``.
    let capturedResponseSource: CapturedResponseSource?
    /// When `true`, the serving path strips caching headers and forces `no-store` regardless of
    /// the global/per-domain no-caching Settings toggle — see `ResponseOverrideRule.forceNoCache`.
    let forceNoCache: Bool
    let mcpAttribution: MCPCaptureAttribution?

    init(
        ruleID: UUID,
        statusCode: Int,
        headers: [HTTPHeaderField],
        bodyData: Data?,
        sourceKind: ResponseOverrideSourceKind,
        sourceDescription: String,
        capturedResponseSource: CapturedResponseSource? = nil,
        forceNoCache: Bool = false,
        mcpAttribution: MCPCaptureAttribution? = nil
    ) {
        self.ruleID = ruleID
        self.statusCode = statusCode
        self.headers = headers
        self.bodyData = bodyData
        self.sourceKind = sourceKind
        self.sourceDescription = sourceDescription
        self.capturedResponseSource = capturedResponseSource
        self.forceNoCache = forceNoCache
        self.mcpAttribution = mcpAttribution
    }
}

enum ResponseOverrideError: LocalizedError, Equatable {
    case unsupportedSourceSession
    case fileReadFailed(String)
    case fileBookmarkCreationFailed(String)
    case persistedOverrideLoadFailed(String)
    case exclusiveRuleConflict(existingKind: ResponseOverrideSourceKind, newKind: ResponseOverrideSourceKind)
    case missingEnabledLiveResponseRewrite
    case liveCollectionCapacityExceeded
    case liveCollectionExecutorUnavailable
    case ruleNotFound

    var errorDescription: String? {
        switch self {
        case .unsupportedSourceSession:
            return "Map Local needs a completed captured response before it can create an override."
        case .fileReadFailed(let message):
            return "JoesProxy could not read the selected local file. \(message)"
        case .fileBookmarkCreationFailed(let message):
            return "JoesProxy could not persist the selected local file. \(message)"
        case .persistedOverrideLoadFailed(let message):
            return "JoesProxy could not restore a saved local override. \(message)"
        case .exclusiveRuleConflict(let existingKind, let newKind):
            return "An enabled \(existingKind.title) rule already matches this request. Disable or remove it before adding a \(newKind.title) rule."
        case .missingEnabledLiveResponseRewrite:
            return "Live response rewrite rules need at least one enabled JSON field override."
        case .liveCollectionCapacityExceeded:
            return "The live collection plan budget is full. Stop an owned live collection effect and review activation again."
        case .liveCollectionExecutorUnavailable:
            return "The bounded live collection executor is unavailable. Leave this bundle inactive and use a build with live collection support."
        case .ruleNotFound:
            return "The override rule was not found."
        }
    }
}

actor ResponseOverrideStore {
    private var rulesByID: [ResponseOverrideRule.ID: ResponseOverrideRule] = [:]
    private let effectBundleGate: EffectBundleActivationGate
    private let liveCollectionTransformationExecutor: LiveCollectionTransformationExecutor?

    /// Fires once after any add/update/enable/disable/remove, regardless of caller — `ProxyViewModel`
    /// (UI-driven mutations) and `MCPMutationService` (agent-driven mutations) both funnel through
    /// `store(_:)`/`removeRule(id:)`/`removeRulesMatching(_:)` below, so hooking those three covers
    /// every trigger. Confirmed live 2026-08-10: rules created/enabled over MCP had zero effect on
    /// the app's own "Local Overrides" UI, because nothing told `ProxyViewModel` to re-read the store
    /// outside of its own UI-driven mutation methods, which each separately called
    /// `refreshResponseOverrides()` after mutating — MCP mutations never went through those methods.
    nonisolated let changes: AsyncStream<Void>
    private let changeContinuation: AsyncStream<Void>.Continuation

    init(
        effectBundleGate: EffectBundleActivationGate = .shared,
        liveCollectionTransformationExecutor: LiveCollectionTransformationExecutor? = nil
    ) {
        self.effectBundleGate = effectBundleGate
        self.liveCollectionTransformationExecutor = liveCollectionTransformationExecutor
        var continuation: AsyncStream<Void>.Continuation!
        self.changes = AsyncStream { continuation = $0 }
        self.changeContinuation = continuation
    }

    private func notifyChanged() {
        changeContinuation.yield(())
    }

    /// The single write path into `rulesByID` — every add/update method must go through this
    /// (not assign `rulesByID[...]` directly) so `mcpTargetRevision` always reflects the rule's
    /// current semantic content. Without this, a legacy (non-MCP) edit would leave the stored
    /// revision frozen at whatever it was before the edit, silently defeating the MCP proposal
    /// system's staleness check for this rule.
    @discardableResult
    private func store(_ rule: ResponseOverrideRule, skipExclusiveValidation: Bool = false) throws -> ResponseOverrideRule {
        if !skipExclusiveValidation {
            try assertNoExclusiveConflict(for: rule)
        }
        // Creation and enabled-state transitions only. Identifier and kind, never matcher or body.
        let previousEnabled = rulesByID[rule.id]?.isEnabled
        if previousEnabled != rule.isEnabled {
            overrideLogger.notice("""
                Rule \(previousEnabled == nil ? "created" : "changed", privacy: .public) \
                id=\(rule.id.uuidString, privacy: .public) kind=\(String(describing: rule.sourceKind), privacy: .public) \
                enabled=\(rule.isEnabled, privacy: .public)
                """)
        }
        if rule.sourceKind == .collectionMock, rule.isEnabled, let plan = rule.collectionMockPlan {
            if let executor = liveCollectionTransformationExecutor {
                guard executor.begin(effectID: rule.id, plan: plan, bundleGate: effectBundleGate) != nil else {
                    throw ResponseOverrideError.liveCollectionCapacityExceeded
                }
            } else if rule.effectBundleID != nil {
                throw ResponseOverrideError.liveCollectionExecutorUnavailable
            }
        }
        // `LiveTransformationActivationTracker` needs to know the exact moment a live-rewrite or
        // live collection-mock rule's enabled state transitions, from every trigger (explicit
        // activate/disable, scenario stop, hit-limit, expiration, revocation, server stop, Return
        // To Normal, startup reconciliation) — this single write path is the one place all of them
        // funnel through, so hooking it here covers every trigger without chasing each call site.
        // The tracker is keyed only by ruleID and has no notion of rewrite-vs-mock semantics, so
        // both live-mutation rule kinds share the same activation lifetime/budget bookkeeping.
        if rule.sourceKind == .liveResponseRewrite || rule.sourceKind == .collectionMock {
            let wasEnabled = rulesByID[rule.id]?.isEnabled ?? false
            if rule.isEnabled, !wasEnabled {
                LiveTransformationActivationTracker.shared.recordActivationStart(ruleID: rule.id)
            } else if !rule.isEnabled, wasEnabled {
                LiveTransformationActivationTracker.shared.clear(ruleID: rule.id)
            }
        }
        if rule.sourceKind == .collectionMock {
            if !rule.isEnabled {
                liveCollectionTransformationExecutor?.stop(effectID: rule.id)
            }
        } else if rulesByID[rule.id]?.sourceKind == .collectionMock {
            liveCollectionTransformationExecutor?.stop(effectID: rule.id)
        }
        let revised = MCPTargetRevisionFingerprint.ruleByApplyingRevision(rule)
        rulesByID[rule.id] = revised
        notifyChanged()
        return revised
    }

    func rules() -> [ResponseOverrideRule] {
        rulesByID.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func effectBundleConflictIDs(for proposedRules: [ResponseOverrideRule]) -> [UUID] {
        let enabledExisting = rulesByID.values.filter { existing in
            existing.isEnabled &&
                effectBundleGate.allows(responseRuleID: existing.id) &&
                (existing.effectBundleID.map { effectBundleGate.allows(bundleID: $0) } ?? true)
        }
        return Array(Set(enabledExisting.compactMap { existing in
            proposedRules.contains(where: { rulesShareMatcher(existing, $0) }) ? existing.id : nil
        })).sorted { $0.uuidString < $1.uuidString }
    }

    /// Phase publication checks the current store without treating its own staged rules as
    /// external conflicts. The caller rechecks its activation identity after this actor hop.
    func effectBundlePhaseConflicts(bundleID: UUID, ruleIDs: Set<UUID>,
                                   expectedRevisions: [UUID: MCPTargetRevision]? = nil) -> [UUID] {
        let proposed = ruleIDs.compactMap { rulesByID[$0] }
        guard proposed.count == ruleIDs.count,
              proposed.allSatisfy({ $0.isEnabled && $0.effectBundleID == bundleID }) else { return Array(ruleIDs) }
        if let expectedRevisions {
            let changed = expectedRevisions.keys.filter { id in
                guard let rule = rulesByID[id] else { return true }
                return !rule.isEnabled || rule.effectBundleID != bundleID
                    || rule.mcpTargetRevision != expectedRevisions[id]
            }
            if !changed.isEmpty { return changed }
        }
        return rulesByID.values.filter { existing in
            existing.effectBundleID != bundleID && existing.isEnabled
                && effectBundleGate.allows(responseRuleID: existing.id)
                && proposed.contains { phaseMatchersMayOverlap($0, existing) }
        }.map(\.id)
    }

    func effectBundlePhaseRevisions(bundleID: UUID, ruleIDs: Set<UUID>) throws -> [UUID: MCPTargetRevision] {
        var revisions: [UUID: MCPTargetRevision] = [:]
        for id in ruleIDs {
            guard let rule = rulesByID[id], rule.isEnabled, rule.effectBundleID == bundleID,
                  let revision = rule.mcpTargetRevision else { throw EffectBundleError.activationConflict }
            revisions[id] = revision
        }
        return revisions
    }

    private func phaseMatchersMayOverlap(_ lhs: ResponseOverrideRule, _ rhs: ResponseOverrideRule) -> Bool {
        guard lhs.requestMethod.caseInsensitiveCompare(rhs.requestMethod) == .orderedSame,
              lhs.requestScheme == rhs.requestScheme,
              lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame,
              canonicalPort(lhs.port, scheme: lhs.requestScheme) == canonicalPort(rhs.port, scheme: rhs.requestScheme),
              clientAddressesOverlap(lhs.sourceClientAddress, rhs.sourceClientAddress) else { return false }
        let left = normalizedPathForMatch(lhs.path, mode: .ignoreQuery)
        let right = normalizedPathForMatch(rhs.path, mode: .ignoreQuery)
        switch (lhs.matchMode, rhs.matchMode) {
        case (.exactPath, .exactPath), (.exactPath, .ignoreQuery), (.ignoreQuery, .exactPath), (.ignoreQuery, .ignoreQuery):
            return left == right
        case (.pathPrefix, .exactPath), (.pathPrefix, .ignoreQuery): return right.hasPrefix(left)
        case (.exactPath, .pathPrefix), (.ignoreQuery, .pathPrefix): return left.hasPrefix(right)
        case (.pathPrefix, .pathPrefix): return left.hasPrefix(right) || right.hasPrefix(left)
        case (.pathSuffix, .exactPath), (.pathSuffix, .ignoreQuery): return right.hasSuffix(left)
        case (.exactPath, .pathSuffix), (.ignoreQuery, .pathSuffix): return left.hasSuffix(right)
        case (.filename, .exactPath), (.filename, .ignoreQuery), (.exactPath, .filename), (.ignoreQuery, .filename), (.filename, .filename):
            return lastPathComponent(of: left) == lastPathComponent(of: right)
        default: return true // Mixed broad matchers require explicit review, not a false safety claim.
        }
    }

    func removeRules(effectBundleID: UUID) {
        let ids = rulesByID.values
            .filter { $0.effectBundleID == effectBundleID }
            .map(\.id)
        for id in ids {
            removeRule(id: id)
        }
    }

    /// Returns enabled response rules whose matcher overlaps an HLS substitution entry scope.
    /// Host scope is intentionally conservative for prefix matchers because any matching prefix
    /// can contain a descendant playlist.
    func hlsSubstitutionConflictIDs(
        origin: HLSSubstitutionOrigin,
        scope: HLSSubstitutionScope
    ) -> [UUID] {
        rules().compactMap { rule in
            let isSupportedMethod = rule.requestMethod.caseInsensitiveCompare("GET") == .orderedSame ||
                rule.requestMethod.caseInsensitiveCompare("HEAD") == .orderedSame
            guard rule.isEnabled,
                  effectBundleGate.allows(responseRuleID: rule.id),
                  isSupportedMethod,
                  rule.requestScheme == origin.scheme,
                  rule.host.caseInsensitiveCompare(origin.host) == .orderedSame,
                  canonicalPort(rule.port, scheme: rule.requestScheme) == origin.port else {
                return nil
            }

            let overlaps: Bool
            switch scope {
            case .selectedPlaylist(let path):
                let request = CapturedRequest(
                    method: rule.requestMethod,
                    scheme: origin.scheme,
                    host: origin.host,
                    port: origin.port,
                    path: path,
                    headers: [],
                    bodyData: nil,
                    bodySize: nil
                )
                overlaps = matches(rule: rule, request: request)
            case .host:
                switch rule.matchMode {
                case .pathPrefix:
                    overlaps = true
                case .exactPath, .ignoreQuery:
                    overlaps = normalizedPathForMatch(rule.path, mode: .ignoreQuery)
                        .lowercased().hasSuffix(".m3u8")
                case .pathSuffix:
                    let suffix = normalizedPathForMatch(rule.path, mode: .pathSuffix).lowercased()
                    overlaps = ".m3u8".hasSuffix(suffix) || suffix.hasSuffix(".m3u8")
                case .filename:
                    overlaps = lastPathComponent(of: normalizedPathForMatch(rule.path, mode: .filename))
                        .lowercased().hasSuffix(".m3u8")
                }
            }
            return overlaps ? rule.id : nil
        }
    }

    /// Enabled override/block/map-remote rules whose matcher would hit a compiled mock-pack probe path.
    func openAPIMockConflictIDs(
        origin: OpenAPIMockOrigin,
        routes: [OpenAPIMockRoute]
    ) -> [OpenAPIMockOverlappingRule] {
        rules().compactMap { rule in
            guard rule.isEnabled,
                  effectBundleGate.allows(responseRuleID: rule.id),
                  rule.requestScheme == origin.scheme,
                  rule.host.caseInsensitiveCompare(origin.host) == .orderedSame,
                  canonicalPort(rule.port, scheme: rule.requestScheme) == origin.port else {
                return nil
            }
            for route in routes where route.method.caseInsensitiveCompare(rule.requestMethod) == .orderedSame {
                var path = route.pathTemplate.probePath
                let required = route.queryConstraints.filter(\.isRequired)
                if !required.isEmpty {
                    let query = required.map { "\($0.name)=\($0.allowedValues?.first ?? "1")" }.joined(separator: "&")
                    path += "?\(query)"
                }
                let probe = CapturedRequest(
                    method: route.method,
                    scheme: origin.scheme,
                    host: origin.host,
                    port: origin.port,
                    path: path,
                    headers: route.requestContentType.map { [HTTPHeaderField(name: "Content-Type", value: $0)] } ?? [],
                    bodyData: nil,
                    bodySize: nil
                )
                if matches(rule: rule, request: probe) {
                    return OpenAPIMockOverlappingRule(
                        ruleID: rule.id,
                        method: rule.requestMethod,
                        pathDescription: rule.path
                    )
                }
            }
            return nil
        }
    }

    func disableRules(ids: Set<UUID>) throws {
        for id in ids {
            guard var rule = rulesByID[id], rule.isEnabled else { continue }
            rule.isEnabled = false
            _ = try store(rule, skipExclusiveValidation: true)
        }
    }

    func enableRules(ids: Set<UUID>) throws {
        for id in ids {
            guard var rule = rulesByID[id], !rule.isEnabled else { continue }
            rule.isEnabled = true
            _ = try store(rule, skipExclusiveValidation: true)
        }
    }

    @discardableResult
    func addCapturedResponseOverride(
        from session: SessionRecord,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        conflictStrategy: ResponseOverrideConflictStrategy = .keepBoth,
        forceNoCache: Bool = false
    ) throws -> ResponseOverrideRule {
        guard let response = session.response else {
            throw ResponseOverrideError.unsupportedSourceSession
        }

        if conflictStrategy == .replaceExisting {
            removeRulesMatching(session.request)
        }

        let rule = ResponseOverrideRule(
            label: nil,
            requestMethod: session.request.method,
            requestScheme: session.request.scheme,
            host: normalizeHost(session.request.host),
            port: session.request.port,
            path: normalizePath(matchPath ?? session.request.path),
            matchMode: matchMode,
            sourceKind: .capturedResponse,
            sourceDescription: ResponseOverrideSourceKind.capturedResponse.sourceDescription,
            statusCode: response.statusCode,
            headers: sanitizedHeaders(response.headers),
            bodySource: .inline(response.bodyData),
            forceNoCache: forceNoCache
        )
        return try store(rule)
    }

    @discardableResult
    func addInlineTextOverride(
        from session: SessionRecord,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        conflictStrategy: ResponseOverrideConflictStrategy = .keepBoth,
        statusCode: Int,
        contentType: String?,
        bodyText: String,
        forceNoCache: Bool = false
    ) throws -> ResponseOverrideRule {
        guard session.response != nil else {
            throw ResponseOverrideError.unsupportedSourceSession
        }

        if conflictStrategy == .replaceExisting {
            removeRulesMatching(session.request)
        }

        let bodyData = bodyText.data(using: .utf8)
        var headers = sanitizedHeaders(session.response?.headers ?? [])
        headers = upsertingHeader(named: "Content-Type", value: normalizedContentType(contentType, fallback: "text/plain; charset=utf-8"), in: headers)

        let rule = ResponseOverrideRule(
            label: normalizedLabel(label),
            requestMethod: session.request.method,
            requestScheme: session.request.scheme,
            host: normalizeHost(session.request.host),
            port: session.request.port,
            path: normalizePath(matchPath ?? session.request.path),
            matchMode: matchMode,
            sourceKind: .inlineText,
            sourceDescription: ResponseOverrideSourceKind.inlineText.sourceDescription,
            statusCode: statusCode,
            headers: headers,
            bodySource: .inline(bodyData),
            forceNoCache: forceNoCache
        )
        return try store(rule)
    }

    @discardableResult
    func addFileBackedOverride(
        from session: SessionRecord,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        conflictStrategy: ResponseOverrideConflictStrategy = .keepBoth,
        statusCode: Int,
        contentType: String?,
        fileURL: URL,
        forceNoCache: Bool = false
    ) throws -> ResponseOverrideRule {
        guard session.response != nil else {
            throw ResponseOverrideError.unsupportedSourceSession
        }

        if conflictStrategy == .replaceExisting {
            removeRulesMatching(session.request)
        }

        var headers = sanitizedHeaders(session.response?.headers ?? [])
        let resolvedContentType = normalizedContentType(
            contentType,
            fallback: inferredContentType(for: fileURL) ?? "application/octet-stream"
        )
        headers = upsertingHeader(named: "Content-Type", value: resolvedContentType, in: headers)

        let rule = ResponseOverrideRule(
            label: normalizedLabel(label),
            requestMethod: session.request.method,
            requestScheme: session.request.scheme,
            host: normalizeHost(session.request.host),
            port: session.request.port,
            path: normalizePath(matchPath ?? session.request.path),
            matchMode: matchMode,
            sourceKind: .localFile,
            sourceDescription: "\(ResponseOverrideSourceKind.localFile.sourceDescription): \(fileURL.lastPathComponent)",
            statusCode: statusCode,
            headers: headers,
            bodySource: .file(fileURL),
            forceNoCache: forceNoCache
        )
        return try store(rule)
    }

    /// Creates a Map Local rule that serves files from `directoryURL` under a path-prefix matcher.
    ///
    /// - Parameters:
    ///   - matchMode: Must be `.pathPrefix` (enforced). Other modes cannot map a URL subtree onto a folder.
    ///   - notFoundRelativePath: Optional relative file inside the directory served as HTTP 404 body.
    ///   - extraHeaders: Applied on every served file after Content-Type (CORS, etc.).
    @discardableResult
    func addDirectoryBackedOverride(
        from session: SessionRecord,
        label: String?,
        matchPath: String? = nil,
        conflictStrategy: ResponseOverrideConflictStrategy = .keepBoth,
        directoryURL: URL,
        notFoundRelativePath: String? = nil,
        extraHeaders: [HTTPHeaderField] = [],
        forceNoCache: Bool = false,
        missingFilePolicy: LocalDirectoryMissingFilePolicy = .strictLocal
    ) throws -> ResponseOverrideRule {
        guard session.response != nil else {
            throw ResponseOverrideError.unsupportedSourceSession
        }

        if conflictStrategy == .replaceExisting {
            removeRulesMatching(session.request)
        }

        let trimmedNotFound = notFoundRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = ResponseOverrideRule(
            label: normalizedLabel(label),
            requestMethod: session.request.method,
            requestScheme: session.request.scheme,
            host: normalizeHost(session.request.host),
            port: session.request.port,
            path: normalizePath(matchPath ?? session.request.path),
            matchMode: .pathPrefix,
            sourceKind: .localDirectory,
            sourceDescription: "\(ResponseOverrideSourceKind.localDirectory.sourceDescription): \(directoryURL.lastPathComponent)",
            statusCode: 200,
            headers: sanitizedHeaders(extraHeaders),
            bodySource: .directory(directoryURL),
            forceNoCache: forceNoCache,
            notFoundRelativePath: (trimmedNotFound?.isEmpty == false) ? trimmedNotFound : nil,
            missingFilePolicy: missingFilePolicy
        )
        return try store(rule)
    }

    /// Creates a directory Map Local rule from an explicit matcher (MCP/CLI), without a captured session.
    @discardableResult
    func addDirectoryBackedOverride(
        method: String,
        scheme: SessionScheme,
        host: String,
        port: Int?,
        path: String,
        label: String?,
        directoryURL: URL,
        notFoundRelativePath: String? = nil,
        extraHeaders: [HTTPHeaderField] = [],
        forceNoCache: Bool = false,
        missingFilePolicy: LocalDirectoryMissingFilePolicy = .strictLocal,
        isEnabled: Bool = true,
        mcpOrigin: MCPObjectOrigin? = nil,
        mcpProvenance: MCPProvenance? = nil
    ) throws -> ResponseOverrideRule {
        let trimmedNotFound = notFoundRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = ResponseOverrideRule(
            label: normalizedLabel(label),
            requestMethod: method,
            requestScheme: scheme,
            host: normalizeHost(host),
            port: port,
            path: normalizePath(path),
            matchMode: .pathPrefix,
            sourceKind: .localDirectory,
            sourceDescription: "\(ResponseOverrideSourceKind.localDirectory.sourceDescription): \(directoryURL.lastPathComponent)",
            statusCode: 200,
            headers: sanitizedHeaders(extraHeaders),
            bodySource: .directory(directoryURL),
            isEnabled: isEnabled,
            mcpOrigin: mcpOrigin,
            mcpProvenance: mcpProvenance,
            forceNoCache: forceNoCache,
            notFoundRelativePath: (trimmedNotFound?.isEmpty == false) ? trimmedNotFound : nil,
            missingFilePolicy: missingFilePolicy
        )
        return try store(rule)
    }

    /// Inserts a fully-formed rule directly. Used for import and testing.
    func addRule(_ rule: ResponseOverrideRule) throws {
        _ = try store(rule)
    }

    /// Looks up one rule by id — used by ConnectionHandler when resolving `.localDirectoryRedirect`.
    func rule(id: ResponseOverrideRule.ID) -> ResponseOverrideRule? {
        rulesByID[id]
    }

    func setEnabled(_ isEnabled: Bool, for id: ResponseOverrideRule.ID) throws {
        guard var rule = rulesByID[id] else {
            return
        }

        rule.isEnabled = isEnabled
        _ = try store(rule)
    }

    func setLabel(_ label: String?, for id: ResponseOverrideRule.ID) throws {
        guard var rule = rulesByID[id] else {
            return
        }

        rule.label = normalizedLabel(label)
        _ = try store(rule)
    }

    func updateCapturedResponseOverride(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        statusCode: Int,
        contentType: String?,
        forceNoCache: Bool? = nil
    ) throws {
        guard var rule = rulesByID[id] else {
            return
        }

        rule.label = normalizedLabel(label)
        rule.matchMode = matchMode
        rule.path = normalizePath(matchPath ?? rule.path)
        rule.headers = upsertingHeader(
            named: "Content-Type",
            value: normalizedContentType(contentType, fallback: "application/octet-stream"),
            in: sanitizedHeaders(rule.headers)
        )
        rule.statusCode = statusCode
        if let forceNoCache { rule.forceNoCache = forceNoCache }
        _ = try store(rule)
    }

    func updateInlineTextOverride(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        statusCode: Int,
        contentType: String?,
        bodyText: String,
        forceNoCache: Bool? = nil
    ) throws {
        guard var rule = rulesByID[id] else {
            return
        }

        rule.label = normalizedLabel(label)
        rule.matchMode = matchMode
        rule.path = normalizePath(matchPath ?? rule.path)
        rule.statusCode = statusCode
        rule.headers = upsertingHeader(
            named: "Content-Type",
            value: normalizedContentType(contentType, fallback: "text/plain; charset=utf-8"),
            in: sanitizedHeaders(rule.headers)
        )
        rule.bodySource = .inline(bodyText.data(using: .utf8))
        rule.sourceDescription = ResponseOverrideSourceKind.inlineText.sourceDescription
        if let forceNoCache { rule.forceNoCache = forceNoCache }
        _ = try store(rule)
    }

    func updateFileBackedOverride(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        statusCode: Int,
        contentType: String?,
        fileURL: URL,
        forceNoCache: Bool? = nil
    ) throws {
        guard var rule = rulesByID[id] else {
            return
        }

        rule.label = normalizedLabel(label)
        rule.matchMode = matchMode
        rule.path = normalizePath(matchPath ?? rule.path)
        rule.statusCode = statusCode
        let resolvedContentType = normalizedContentType(
            contentType,
            fallback: inferredContentType(for: fileURL) ?? "application/octet-stream"
        )
        rule.headers = upsertingHeader(
            named: "Content-Type",
            value: resolvedContentType,
            in: sanitizedHeaders(rule.headers)
        )
        rule.bodySource = .file(fileURL)
        rule.sourceDescription = "\(ResponseOverrideSourceKind.localFile.sourceDescription): \(fileURL.lastPathComponent)"
        if let forceNoCache { rule.forceNoCache = forceNoCache }
        _ = try store(rule)
    }

    /// Updates a `.localDirectory` rule's folder, path prefix, forceNoCache flag, and
    /// missingFilePolicy.
    func updateDirectoryBackedOverride(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchPath: String? = nil,
        directoryURL: URL,
        forceNoCache: Bool? = nil,
        notFoundRelativePath: String?? = nil,
        missingFilePolicy: LocalDirectoryMissingFilePolicy? = nil
    ) throws {
        guard var rule = rulesByID[id], rule.sourceKind == .localDirectory else {
            return
        }

        rule.label = normalizedLabel(label)
        rule.matchMode = .pathPrefix
        rule.path = normalizePath(matchPath ?? rule.path)
        rule.bodySource = .directory(directoryURL)
        rule.sourceDescription = "\(ResponseOverrideSourceKind.localDirectory.sourceDescription): \(directoryURL.lastPathComponent)"
        if let forceNoCache { rule.forceNoCache = forceNoCache }
        if let notFoundRelativePath {
            let trimmed = notFoundRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.notFoundRelativePath = (trimmed?.isEmpty == false) ? trimmed : nil
        }
        if let missingFilePolicy { rule.missingFilePolicy = missingFilePolicy }
        _ = try store(rule)
    }

    func updateBlockRule(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        statusCode: Int,
        dropConnection: Bool? = nil
    ) throws {
        guard var rule = rulesByID[id], rule.sourceKind == .block else {
            return
        }

        rule.label = normalizedLabel(label)
        rule.matchMode = matchMode
        rule.path = normalizePath(matchPath ?? rule.path)
        rule.statusCode = statusCode
        rule.sourceDescription = ResponseOverrideSourceKind.block.sourceDescription
        if let dropConnection {
            rule.dropConnection = dropConnection
        }
        _ = try store(rule)
    }

    func updateMapRemoteRule(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        remoteHost: String,
        remotePort: Int?,
        remoteScheme: SessionScheme,
        remotePath: String? = nil,
        remoteQueryPolicy: MapRemoteQueryPolicy = .preserve,
        remoteQuery: String? = nil,
        allowLoopbackDestination: Bool? = nil,
        preserveHostHeader: Bool? = nil
    ) throws {
        guard var rule = rulesByID[id], rule.sourceKind == .mapRemote else {
            return
        }

        let resolvedPort = remotePort ?? canonicalPort(nil, scheme: remoteScheme)
        rule.label = normalizedLabel(label)
        rule.matchMode = matchMode
        rule.path = normalizePath(matchPath ?? rule.path)
        rule.mapRemoteHost = LoopbackAddressInspector.stripBracketsAndTrailingDot(remoteHost).host
        rule.mapRemotePort = resolvedPort
        rule.mapRemoteScheme = remoteScheme
        rule.mapRemotePath = remotePath
        rule.mapRemoteQueryPolicy = remoteQueryPolicy
        rule.mapRemoteQuery = remoteQuery
        if let allowLoopbackDestination {
            rule.allowLoopbackDestination = allowLoopbackDestination
        }
        if let preserveHostHeader {
            rule.preserveHostHeader = preserveHostHeader
        }
        rule.sourceDescription = "\(ResponseOverrideSourceKind.mapRemote.sourceDescription): \(remoteScheme.rawValue)://\(rule.mapRemoteHost ?? remoteHost):\(resolvedPort)\(remotePath ?? "")"
        _ = try store(rule)
    }

    func updateBookmarkRewriteRule(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        rewriteRequest: CapturedRequest
    ) throws {
        guard var rule = rulesByID[id], rule.sourceKind == .bookmarkRewrite else {
            return
        }

        rule.label = normalizedLabel(label)
        rule.matchMode = matchMode
        rule.bookmarkRewriteRequest = normalizedRewriteRequest(rewriteRequest)
        rule.sourceDescription = "\(ResponseOverrideSourceKind.bookmarkRewrite.sourceDescription): \(rewriteRequest.method) \(rewriteRequest.host)\(normalizePath(rewriteRequest.path))"
        _ = try store(rule)
    }

    func removeRule(id: ResponseOverrideRule.ID) {
        if let removedKind = rulesByID[id]?.sourceKind,
           removedKind == .liveResponseRewrite || removedKind == .collectionMock {
            LiveTransformationActivationTracker.shared.clear(ruleID: id)
        }
        liveCollectionTransformationExecutor?.stop(effectID: id)
        if rulesByID.removeValue(forKey: id) != nil {
            overrideLogger.notice("Rule removed id=\(id.uuidString, privacy: .public)")
        }
        notifyChanged()
    }

    /// Encodes one rule for MCP delete rollback using the same persist format as on-disk storage.
    ///
    /// Concurrency: actor-isolated; call from async contexts that await this store.
    func mcpDeleteRollbackData(for id: ResponseOverrideRule.ID) throws -> Data {
        guard let rule = rulesByID[id] else {
            throw ResponseOverrideError.ruleNotFound
        }
        let persisted = try makePersistedRule(from: rule)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(persisted)
    }

    /// Restores a rule previously encoded by ``mcpDeleteRollbackData(for:)``.
    func restoreFromMCPDeleteRollbackData(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(PersistedResponseOverrideRule.self, from: data)
        let runtimeRule = MCPTargetRevisionFingerprint.ruleByApplyingRevision(try makeRuntimeRule(from: persisted))
        _ = try store(runtimeRule)
    }

    func clearAll() {
        for rule in rulesByID.values where rule.sourceKind == .collectionMock {
            liveCollectionTransformationExecutor?.stop(effectID: rule.id)
        }
        rulesByID.removeAll()
    }

    func persistedData() throws -> Data {
        let persistedRules = try rules().map(makePersistedRule(from:))
        return try JSONEncoder().encode(persistedRules)
    }

    func loadPersistedData(_ data: Data?, loopbackPolicy: LoopbackDestinationPolicy? = nil) throws {
        guard let data, !data.isEmpty else {
            rulesByID.removeAll()
            return
        }

        let persistedRules = try JSONDecoder().decode([PersistedResponseOverrideRule].self, from: data)
        var restoredRulesByID: [ResponseOverrideRule.ID: ResponseOverrideRule] = [:]
        var disabledUnauthorizedLoopback = false
        for persistedRule in persistedRules {
            // Recompute rather than trust whatever was on disk — a file written before this fix
            // (or by any future code path that forgets to call `store(_:)`) could carry a stale or
            // missing revision.
            var runtimeRule = MCPTargetRevisionFingerprint.ruleByApplyingRevision(try makeRuntimeRule(from: persistedRule))
            if let loopbackPolicy, runtimeRule.sourceKind == .mapRemote, runtimeRule.isEnabled {
                let remoteHost = runtimeRule.mapRemoteHost ?? runtimeRule.host
                let remoteScheme = runtimeRule.mapRemoteScheme ?? runtimeRule.requestScheme
                let remotePort = runtimeRule.mapRemotePort ?? canonicalPort(nil, scheme: remoteScheme)
                if runtimeRule.allowLoopbackDestination || Self.targetsStaticLoopback(host: remoteHost) {
                    if (try? LoopbackAddressInspector.validateStaticDestination(
                        host: remoteHost,
                        port: remotePort,
                        scheme: remoteScheme,
                        allowLoopbackDestination: runtimeRule.allowLoopbackDestination,
                        policy: loopbackPolicy
                    )) == nil {
                        runtimeRule.isEnabled = false
                        runtimeRule = MCPTargetRevisionFingerprint.ruleByApplyingRevision(runtimeRule)
                        disabledUnauthorizedLoopback = true
                    }
                }
            }
            restoredRulesByID[runtimeRule.id] = runtimeRule
        }
        rulesByID = restoredRulesByID
        if disabledUnauthorizedLoopback {
            notifyChanged()
        }
    }

    /// Immediately disables all enabled loopback Map Remote rules (or only those targeting
    /// `removedPorts` when non-nil) so revoking permission blocks subsequent traffic AND prevents
    /// persisted rules from silently resuming when permission is later restored.
    @discardableResult
    func disableLoopbackMapRemoteRules(forRemovedPorts removedPorts: Set<Int>? = nil) -> Bool {
        var didChange = false
        for (id, var rule) in rulesByID {
            guard rule.sourceKind == .mapRemote, rule.isEnabled else { continue }
            let host = rule.mapRemoteHost ?? rule.host
            let scheme = rule.mapRemoteScheme ?? rule.requestScheme
            let port = rule.mapRemotePort ?? canonicalPort(nil, scheme: scheme)
            guard rule.allowLoopbackDestination || Self.targetsStaticLoopback(host: host) else { continue }
            if let removedPorts, !removedPorts.contains(port) {
                continue
            }
            rule.isEnabled = false
            rulesByID[id] = MCPTargetRevisionFingerprint.ruleByApplyingRevision(rule)
            didChange = true
        }
        if didChange {
            notifyChanged()
        }
        return didChange
    }

    private static func targetsStaticLoopback(host rawHost: String) -> Bool {
        let stripped = LoopbackAddressInspector.stripBracketsAndTrailingDot(rawHost)
        guard !stripped.malformed else { return false }
        if let literal = LoopbackAddressInspector.parseLiteralIP(rawHost) {
            return LoopbackAddressInspector.classify(literal) == .loopback
        }
        return LoopbackAddressInspector.isLocalhostName(stripped.host)
    }

    /// Evaluates all enabled rules against `request` in creation order (newest first) and returns
    /// the first matching decision. Returns `.noMatch` when no rule applies.
    ///
    /// - Concurrency: Must be called from an async context; the actor serialises access.
    func ruleDecision(for request: CapturedRequest,
                      loopbackPolicy: LoopbackDestinationPolicy = .disabled,
                      reservedRegistry: ReservedListenerRegistry = .shared,
                      observationSessionIDTask: Task<UUID?, Never>? = nil) throws -> ProxyRuleDecision {
        var failedObservations: [UUID] = []
        let candidateRules = rules()
        defer {
            if !failedObservations.isEmpty, let observationSessionIDTask {
                let ids = failedObservations, gate = effectBundleGate
                Task {
                    let sessionID = await observationSessionIDTask.value
                    for id in ids { gate.completeReceipt(id: id, sessionID: sessionID) }
                }
            }
        }
        for rule in candidateRules where rule.isEnabled && rule.authoredResource != nil
            && rule.host.caseInsensitiveCompare(normalizeHost(request.host)) == .orderedSame
            && effectBundleGate.allows(responseRuleID: rule.id)
            && (rule.effectBundleID.map { effectBundleGate.allows(bundleID: $0) } ?? true) {
            guard !matches(rule: rule, request: request), let resource = rule.authoredResource else { continue }
            let reason: EffectBundleDeliveryReceipt.Evaluation = matches(rule: rule, request: request, ignoringClientScope: true)
                ? .clientScopeMismatch : .matcherMismatch
            failedObservations.append(effectBundleGate.observe(resource: resource, servedSHA256: nil, evaluation: reason))
        }
        guard let matchedRule = candidateRules.first(where: { matches(rule: $0, request: request) }) else {
            return .noMatch
        }

        var updatedRule = matchedRule
        updatedRule.hitCount += 1
        updatedRule.lastMatchedAt = Date()
        rulesByID[updatedRule.id] = updatedRule

        switch updatedRule.sourceKind {
        case .block:
            return .block(
                ruleID: updatedRule.id,
                statusCode: updatedRule.statusCode,
                sourceDescription: updatedRule.sourceDescription,
                dropConnection: updatedRule.dropConnection
            )

        case .mapRemote:
            let remoteHost = updatedRule.mapRemoteHost ?? updatedRule.host
            let remoteScheme = updatedRule.mapRemoteScheme ?? updatedRule.requestScheme
            let remotePort = updatedRule.mapRemotePort ?? canonicalPort(nil, scheme: remoteScheme)
            let normalizedHost: String
            do {
                let result = try LoopbackAddressInspector.validateStaticDestination(
                    host: remoteHost,
                    port: remotePort,
                    scheme: remoteScheme,
                    allowLoopbackDestination: updatedRule.allowLoopbackDestination,
                    policy: loopbackPolicy,
                    reservedRegistry: reservedRegistry
                )
                normalizedHost = result.normalizedHost
            } catch MapRemoteValidationError.policyDenied(let reason, let detail) {
                return .deniedMapRemote(ruleID: updatedRule.id, reason: reason, detail: detail)
            } catch MapRemoteValidationError.malformedRequest(let detail) {
                return .deniedMapRemote(ruleID: updatedRule.id, reason: .malformedDestination, detail: detail)
            }
            let requestTarget = resolvedMapRemoteRequestTarget(rule: updatedRule, originalRequestTarget: request.path)
            return .mapRemote(
                ruleID: updatedRule.id,
                host: normalizedHost,
                port: remotePort,
                scheme: remoteScheme,
                requestTarget: requestTarget,
                allowLoopbackDestination: updatedRule.allowLoopbackDestination,
                preserveHostHeader: updatedRule.preserveHostHeader
            )

        case .bookmarkRewrite:
            guard let rewriteRequest = updatedRule.bookmarkRewriteRequest else {
                return .noMatch
            }
            return .bookmarkRewrite(
                ruleID: updatedRule.id,
                request: rewriteRequest,
                sourceDescription: updatedRule.sourceDescription
            )

        case .liveResponseRewrite:
            guard updatedRule.liveResponseRewrites.contains(where: \.isRuleEnabled) else {
                return .noMatch
            }
            return .liveResponseRewrite(
                ruleID: updatedRule.id,
                rewrites: updatedRule.liveResponseRewrites,
                sourceDescription: updatedRule.sourceDescription,
                expectedSchemaFingerprint: updatedRule.expectedSchemaFingerprint
            )

        case .collectionMock:
            guard let plan = updatedRule.collectionMockPlan else {
                return .noMatch
            }
            let revision = liveCollectionTransformationExecutor?.currentRevision(effectID: updatedRule.id)
            let phaseDescription = revision?.phase.map {
                " · bundle \($0.bundleID.uuidString) · activation \($0.activationID.uuidString) · phase \($0.phaseID.uuidString)"
            } ?? ""
            return .liveCollectionMock(
                ruleID: updatedRule.id,
                plan: plan,
                sourceDescription: updatedRule.sourceDescription + phaseDescription,
                revision: revision
            )

        case .fixtureRun:
            // Validated at rule-creation time (`MCPMutationValidator`), but re-checked here since
            // a persisted rule could in principle predate that validation. A missing run ID or
            // wrong match mode means this rule can never dispatch correctly — treat as no match
            // rather than crash or serve garbage.
            guard let fixtureRunID = updatedRule.fixtureRunID, updatedRule.matchMode == .pathPrefix else {
                return .noMatch
            }
            return .fixtureRedirect(
                ruleID: updatedRule.id,
                runID: fixtureRunID,
                relativePath: fixtureRelativePath(rule: updatedRule, requestPath: request.path)
            )

        case .localDirectory:
            guard updatedRule.matchMode == .pathPrefix,
                  case .directory = updatedRule.bodySource else {
                return .noMatch
            }
            return .localDirectoryRedirect(
                ruleID: updatedRule.id,
                relativePath: fixtureRelativePath(rule: updatedRule, requestPath: request.path)
            )

        case .capturedResponse, .inlineText, .localFile:
            let bodyData: Data?
            switch updatedRule.bodySource {
            case .inline(let inlineData):
                bodyData = inlineData
            case .file(let fileURL):
                do {
                    let didAccessSecurityScopedResource = fileURL.startAccessingSecurityScopedResource()
                    defer {
                        if didAccessSecurityScopedResource {
                            fileURL.stopAccessingSecurityScopedResource()
                        }
                    }
                    bodyData = try Data(contentsOf: fileURL)
                } catch {
                    if let resource = updatedRule.authoredResource {
                        failedObservations.append(effectBundleGate.observe(resource: resource,
                            servedSHA256: nil, evaluation: .assetReadFailed))
                    }
                    throw ResponseOverrideError.fileReadFailed(error.localizedDescription)
                }
            case .directory:
                return .noMatch
            }

            var resolved = ResolvedResponseOverride(
                ruleID: updatedRule.id,
                statusCode: updatedRule.statusCode,
                headers: updatedRule.headers,
                bodyData: bodyData,
                sourceKind: updatedRule.sourceKind,
                sourceDescription: updatedRule.sourceDescription,
                forceNoCache: updatedRule.forceNoCache
            )
            resolved.authoredResource = updatedRule.authoredResource
            return .mapLocal(resolved)
        }
    }

    /// Adds a block rule that drops matching requests with a synthetic error response.
    @discardableResult
    func addBlockRule(
        from request: CapturedRequest,
        statusCode: Int,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        dropConnection: Bool = false,
        graphQLOperationName: String? = nil,
        matchQueryKey: String? = nil,
        matchQueryValue: String? = nil
    ) throws -> ResponseOverrideRule {
        let rule = ResponseOverrideRule(
            label: normalizedLabel(label),
            requestMethod: request.method,
            requestScheme: request.scheme,
            host: normalizeHost(request.host),
            port: request.port,
            path: normalizePath(matchPath ?? request.path),
            matchMode: matchMode,
            sourceKind: .block,
            sourceDescription: ResponseOverrideSourceKind.block.sourceDescription,
            statusCode: statusCode,
            headers: [],
            bodySource: .inline(nil),
            dropConnection: dropConnection,
            graphQLOperationName: graphQLOperationName,
            matchQueryKey: matchQueryKey,
            matchQueryValue: matchQueryValue
        )
        return try store(rule)
    }

    /// Adds a map-remote rule that forwards matching requests to a different upstream host.
    @discardableResult
    func addMapRemoteRule(
        from request: CapturedRequest,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        remoteHost: String,
        remotePort: Int?,
        remoteScheme: SessionScheme,
        remotePath: String? = nil,
        remoteQueryPolicy: MapRemoteQueryPolicy = .preserve,
        remoteQuery: String? = nil,
        allowLoopbackDestination: Bool = false,
        preserveHostHeader: Bool = false
    ) throws -> ResponseOverrideRule {
        let resolvedPort = remotePort ?? canonicalPort(nil, scheme: remoteScheme)
        let normalizedRemoteHost = LoopbackAddressInspector.stripBracketsAndTrailingDot(remoteHost).host
        let effectiveRemoteHost = normalizedRemoteHost.isEmpty
            ? remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : normalizedRemoteHost
        let description = "\(ResponseOverrideSourceKind.mapRemote.sourceDescription): \(remoteScheme.rawValue)://\(effectiveRemoteHost):\(resolvedPort)\(remotePath ?? "")"
        let rule = ResponseOverrideRule(
            label: normalizedLabel(label),
            requestMethod: request.method,
            requestScheme: request.scheme,
            host: normalizeHost(request.host),
            port: request.port,
            path: normalizePath(matchPath ?? request.path),
            matchMode: matchMode,
            sourceKind: .mapRemote,
            sourceDescription: description,
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            mapRemoteHost: effectiveRemoteHost,
            mapRemotePort: resolvedPort,
            mapRemoteScheme: remoteScheme,
            mapRemotePath: remotePath,
            mapRemoteQueryPolicy: remoteQueryPolicy,
            mapRemoteQuery: remoteQuery,
            allowLoopbackDestination: allowLoopbackDestination,
            preserveHostHeader: preserveHostHeader
        )
        return try store(rule)
    }

    /// Adds a bookmark rewrite rule that replaces matching requests with the full saved bookmark request.
    @discardableResult
    func addBookmarkRewriteRule(
        from bookmark: Bookmark,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath
    ) throws -> ResponseOverrideRule {
        let rewriteRequest = normalizedRewriteRequest(bookmark.request)
        let description = "\(ResponseOverrideSourceKind.bookmarkRewrite.sourceDescription): \(rewriteRequest.method) \(rewriteRequest.host)\(rewriteRequest.path)"
        let rule = ResponseOverrideRule(
            label: normalizedLabel(label) ?? bookmark.name,
            requestMethod: rewriteRequest.method,
            requestScheme: rewriteRequest.scheme,
            host: normalizeHost(rewriteRequest.host),
            port: rewriteRequest.port,
            path: normalizePath(rewriteRequest.path),
            matchMode: matchMode,
            sourceKind: .bookmarkRewrite,
            sourceDescription: description,
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            bookmarkRewriteRequest: rewriteRequest
        )
        return try store(rule)
    }

    /// Adds a live-response rewrite rule that forwards matching requests upstream and patches JSON in the response.
    @discardableResult
    func addLiveResponseRewriteRule(
        from request: CapturedRequest,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        rewrites: [BookmarkResponseFieldRewrite]
    ) throws -> ResponseOverrideRule {
        guard rewrites.contains(where: \.isRuleEnabled) else {
            throw ResponseOverrideError.missingEnabledLiveResponseRewrite
        }

        let rule = ResponseOverrideRule(
            label: normalizedLabel(label),
            requestMethod: request.method,
            requestScheme: request.scheme,
            host: normalizeHost(request.host),
            port: request.port,
            path: normalizePath(matchPath ?? request.path),
            matchMode: matchMode,
            sourceKind: .liveResponseRewrite,
            sourceDescription: LiveResponseRewriteDescriptions.ruleSourceDescription(rewrites: rewrites),
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            liveResponseRewrites: rewrites
        )
        return try store(rule)
    }

    /// Internal building block for a `.collectionMock` rule from an already-compiled, already
    /// reviewed plan. Not yet exposed via MCP/CLI/UI — no authoring/activation tool calls this
    /// today; it exists so the live-pipeline wiring is testable without new production-facing
    /// authoring surface. A future MCP/CLI activation increment is expected to call this.
    func addCollectionMockRule(
        from request: CapturedRequest,
        label: String?,
        matchMode: ResponseOverrideMatchMode = .exactPath,
        matchPath: String? = nil,
        plan: CompiledCollectionMock
    ) throws -> ResponseOverrideRule {
        let rule = ResponseOverrideRule(
            label: normalizedLabel(label),
            requestMethod: request.method,
            requestScheme: request.scheme,
            host: normalizeHost(request.host),
            port: request.port,
            path: normalizePath(matchPath ?? request.path),
            matchMode: matchMode,
            sourceKind: .collectionMock,
            sourceDescription: ResponseOverrideSourceKind.collectionMock.sourceDescription,
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            collectionMockPlan: plan
        )
        return try store(rule)
    }

    func updateLiveResponseRewriteRule(
        id: ResponseOverrideRule.ID,
        label: String?,
        matchMode: ResponseOverrideMatchMode,
        matchPath: String? = nil,
        rewrites: [BookmarkResponseFieldRewrite]
    ) throws {
        guard var rule = rulesByID[id], rule.sourceKind == .liveResponseRewrite else {
            return
        }

        rule.label = normalizedLabel(label)
        rule.matchMode = matchMode
        rule.path = normalizePath(matchPath ?? rule.path)
        rule.liveResponseRewrites = rewrites
        rule.sourceDescription = LiveResponseRewriteDescriptions.ruleSourceDescription(rewrites: rewrites)
        _ = try store(rule)
    }

    /// Extracts the JSON body's top-level `operationName` string field, if present. Used only to
    /// evaluate a rule's optional `graphQLOperationName` predicate — fails closed (returns nil) on
    /// any ambiguity (non-JSON, missing/wrong-typed key, truncated body) so a malformed or partial
    /// body never causes a false match.
    nonisolated private func requestGraphQLOperationName(from request: CapturedRequest) -> String? {
        guard let bodyData = request.bodyData, !bodyData.isEmpty, !request.bodyTruncated else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }
        guard let name = object["operationName"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return name
    }

    /// Two `graphQLOperationName` values "overlap" (would both match the same live request) when
    /// they're equal, or when either is nil (nil matches every operation, including whatever the
    /// other one requires).
    private func graphQLOperationNamesOverlap(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    /// Extracts one named query-parameter's value from a request path, if present. Used only to
    /// evaluate a rule's optional query-parameter predicate (`matchQueryKey`/`matchQueryValue`).
    nonisolated private func requestQueryValue(for key: String, from request: CapturedRequest) -> String? {
        guard let components = URLComponents(string: normalizePath(request.path)) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == key })?.value
    }

    /// Two query-parameter predicates "overlap" (could both be satisfied by the same live request)
    /// when either is unset (nil overlaps everything, same as `graphQLOperationNamesOverlap`), when
    /// they name different keys (one request's query string can satisfy two different keys at
    /// once, e.g. `?a=1&b=2`), or when they name the same key with the same required value. Two
    /// predicates on the *same* key with *different* required values cannot both be satisfied by
    /// one request, so those do not overlap.
    private func queryPredicatesOverlap(
        lhsKey: String?, lhsValue: String?,
        rhsKey: String?, rhsValue: String?
    ) -> Bool {
        guard let lhsKey, let lhsValue, let rhsKey, let rhsValue else { return true }
        guard lhsKey == rhsKey else { return true }
        return lhsValue == rhsValue
    }

    private func clientAddressesOverlap(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines), !lhs.isEmpty,
              let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines), !rhs.isEmpty else {
            return true
        }
        return lhs == rhs
    }

    nonisolated private func requestHeaderValue(for name: String, from request: CapturedRequest) -> String? {
        request.headers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private func headerPredicatesOverlap(
        lhsName: String?, lhsValue: String?,
        rhsName: String?, rhsValue: String?
    ) -> Bool {
        guard let lhsName, let lhsValue, let rhsName, let rhsValue else { return true }
        guard lhsName.caseInsensitiveCompare(rhsName) == .orderedSame else { return true }
        return lhsValue == rhsValue
    }

    private func matches(rule: ResponseOverrideRule, request: CapturedRequest, ignoringClientScope: Bool = false) -> Bool {
        guard rule.isEnabled, effectBundleGate.allows(responseRuleID: rule.id) else {
            return false
        }
        if let bundleID = rule.effectBundleID, !effectBundleGate.allows(bundleID: bundleID) {
            return false
        }

        return matchesConfiguration(rule: rule, request: request, ignoringClientScope: ignoringClientScope)
    }

    /// Configuration matching is shared with read-only preparation preflight; activation gates stay above.
    nonisolated func matchesConfiguration(rule: ResponseOverrideRule, request: CapturedRequest, ignoringClientScope: Bool = false) -> Bool {
        if !ignoringClientScope, let requiredClientAddress = rule.sourceClientAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !requiredClientAddress.isEmpty {
            guard let clientAddress = request.clientAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
                  clientAddress == requiredClientAddress else {
                return false
            }
        }

        let normalizedRulePath = normalizedPathForMatch(rule.path, mode: rule.matchMode)
        if let names = rule.ignoredQueryNames {
            guard rule.matchMode == .ignoreQuery, rule.sourceClientAddress?.isEmpty == false,
                  CapturedQueryMatcher.matches(request.path, baseline: rule.path, ignoring: names) else { return false }
        }
        let normalizedRequestPath = normalizedPathForMatch(normalizePath(request.path), mode: rule.matchMode)

        guard rule.requestMethod.caseInsensitiveCompare(request.method) == .orderedSame &&
            rule.requestScheme == request.scheme &&
            rule.host.caseInsensitiveCompare(normalizeHost(request.host)) == .orderedSame &&
            canonicalPort(rule.port, scheme: rule.requestScheme) == canonicalPort(request.port, scheme: request.scheme) &&
            pathMatches(rulePath: normalizedRulePath, requestPath: normalizedRequestPath, mode: rule.matchMode)
        else {
            return false
        }

        if let requiredOperationName = rule.graphQLOperationName {
            guard requestGraphQLOperationName(from: request) == requiredOperationName else { return false }
        }
        if let requiredQueryKey = rule.matchQueryKey, let requiredQueryValue = rule.matchQueryValue {
            guard requestQueryValue(for: requiredQueryKey, from: request) == requiredQueryValue else { return false }
        }
        if let requiredHeaderName = rule.matchHeaderName, let requiredHeaderValue = rule.matchHeaderValue {
            guard requestHeaderValue(for: requiredHeaderName, from: request) == requiredHeaderValue else { return false }
        }
        return true
    }

    struct MatchDiagnostic: Sendable, Equatable {
        let matched: Bool
        let failedReasons: [String]
        let isNearMiss: Bool
    }

    /// Evaluates why a captured request did or did not match a rule's configuration and enabled state.
    nonisolated func diagnoseMatch(rule: ResponseOverrideRule, request: CapturedRequest) -> MatchDiagnostic {
        var reasons: [String] = []
        if !rule.isEnabled {
            reasons.append("rule_disabled")
        }
        if let requiredClientAddress = rule.sourceClientAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requiredClientAddress.isEmpty {
            let clientAddress = request.clientAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
            if clientAddress != requiredClientAddress {
                reasons.append("client_scope_mismatch")
            }
        }
        let hostMatched = rule.host.caseInsensitiveCompare(normalizeHost(request.host)) == .orderedSame
        if !hostMatched {
            reasons.append("host_mismatch")
        }
        if rule.requestScheme != request.scheme {
            reasons.append("scheme_mismatch")
        }
        if rule.requestMethod.caseInsensitiveCompare(request.method) != .orderedSame {
            reasons.append("method_mismatch")
        }
        if canonicalPort(rule.port, scheme: rule.requestScheme) != canonicalPort(request.port, scheme: request.scheme) {
            reasons.append("port_mismatch")
        }
        let normalizedRulePath = normalizedPathForMatch(rule.path, mode: rule.matchMode)
        let normalizedRequestPath = normalizedPathForMatch(normalizePath(request.path), mode: rule.matchMode)
        let basePathMatched = pathMatches(rulePath: normalizedRulePath, requestPath: normalizedRequestPath, mode: rule.matchMode)
        if !basePathMatched {
            reasons.append("path_mismatch")
        } else if let names = rule.ignoredQueryNames {
            let queryMatched = rule.matchMode == .ignoreQuery &&
                rule.sourceClientAddress?.isEmpty == false &&
                CapturedQueryMatcher.matches(request.path, baseline: rule.path, ignoring: names)
            if !queryMatched {
                reasons.append("query_predicate_mismatch")
            }
        }
        if let requiredOperationName = rule.graphQLOperationName,
           requestGraphQLOperationName(from: request) != requiredOperationName {
            reasons.append("graphql_operation_mismatch")
        }
        if let requiredQueryKey = rule.matchQueryKey, let requiredQueryValue = rule.matchQueryValue,
           requestQueryValue(for: requiredQueryKey, from: request) != requiredQueryValue {
            if !reasons.contains("query_predicate_mismatch") {
                reasons.append("query_predicate_mismatch")
            }
        }
        if let requiredHeaderName = rule.matchHeaderName, let requiredHeaderValue = rule.matchHeaderValue,
           requestHeaderValue(for: requiredHeaderName, from: request) != requiredHeaderValue {
            reasons.append("header_predicate_mismatch")
        }
        let matched = reasons.isEmpty
        let ruleLeaf = lastPathComponent(of: normalizedRulePath)
        let reqLeaf = lastPathComponent(of: normalizedRequestPath)
        let pathRelated = basePathMatched || (!ruleLeaf.isEmpty && ruleLeaf != "/" && ruleLeaf == reqLeaf)
        let isNearMiss = !matched && (hostMatched || pathRelated)
        return MatchDiagnostic(matched: matched, failedReasons: reasons, isNearMiss: isNearMiss)
    }

    private func rulesShareMatcher(_ lhs: ResponseOverrideRule, _ rhs: ResponseOverrideRule) -> Bool {
        lhs.requestMethod.caseInsensitiveCompare(rhs.requestMethod) == .orderedSame &&
            lhs.requestScheme == rhs.requestScheme &&
            lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame &&
            canonicalPort(lhs.port, scheme: lhs.requestScheme) == canonicalPort(rhs.port, scheme: rhs.requestScheme) &&
            lhs.path == rhs.path &&
            lhs.matchMode == rhs.matchMode &&
            graphQLOperationNamesOverlap(lhs.graphQLOperationName, rhs.graphQLOperationName) &&
            queryPredicatesOverlap(
                lhsKey: lhs.matchQueryKey, lhsValue: lhs.matchQueryValue,
                rhsKey: rhs.matchQueryKey, rhsValue: rhs.matchQueryValue
            ) &&
            headerPredicatesOverlap(
                lhsName: lhs.matchHeaderName, lhsValue: lhs.matchHeaderValue,
                rhsName: rhs.matchHeaderName, rhsValue: rhs.matchHeaderValue
            ) &&
            clientAddressesOverlap(lhs.sourceClientAddress, rhs.sourceClientAddress)
    }

    private func assertNoExclusiveConflict(for rule: ResponseOverrideRule) throws {
        guard rule.isEnabled, ResponseOverrideSourceKind.exclusiveSourceKinds.contains(rule.sourceKind) else {
            return
        }

        for existing in rulesByID.values where existing.id != rule.id && existing.isEnabled {
            guard ResponseOverrideSourceKind.exclusiveSourceKinds.contains(existing.sourceKind) else {
                continue
            }
            if rulesShareMatcher(rule, existing) {
                throw ResponseOverrideError.exclusiveRuleConflict(
                    existingKind: existing.sourceKind,
                    newKind: rule.sourceKind
                )
            }
        }
    }

    private func removeRulesMatching(_ request: CapturedRequest) {
        let matchingRuleIDs = rulesByID.values.compactMap { rule in
            matches(rule: rule, request: request) ? rule.id : nil
        }

        for ruleID in matchingRuleIDs {
            liveCollectionTransformationExecutor?.stop(effectID: ruleID)
            rulesByID.removeValue(forKey: ruleID)
        }
        if !matchingRuleIDs.isEmpty {
            notifyChanged()
        }
    }

    nonisolated private func normalizeHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let unbracketed = (trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.count > 2)
            ? String(trimmed.dropFirst().dropLast())
            : trimmed
        if LoopbackAddressInspector.isIPv6Literal(unbracketed),
           let ip = LoopbackAddressInspector.parseLiteralIP(unbracketed) {
            return ip.canonicalIPString
        }
        return trimmed
    }

    nonisolated private func normalizePath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return "/"
        }
        return trimmedPath
    }

    nonisolated private func normalizedPathForMatch(_ path: String, mode: ResponseOverrideMatchMode) -> String {
        switch mode {
        case .exactPath:
            return path
        case .ignoreQuery, .pathPrefix, .pathSuffix, .filename:
            return String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/")
        }
    }

    nonisolated private func pathMatches(rulePath: String, requestPath: String, mode: ResponseOverrideMatchMode) -> Bool {
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

    /// Last path component, ignoring nesting — the primitive `.filename` matching is built on.
    nonisolated private func lastPathComponent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    /// Strips a `.fixtureRun` rule's matcher path prefix from the real request path, producing the
    /// relative path `HLSFixtureServer.response(forPath:method:rangeHeader:)` expects (the same
    /// shape it already receives for reserved-host dispatch). Only meaningful for `matchMode ==
    /// .pathPrefix`, the only mode this source kind supports — validated at rule-creation time.
    private func fixtureRelativePath(rule: ResponseOverrideRule, requestPath: String) -> String {
        let pathOnly = normalizedPathForMatch(normalizePath(requestPath), mode: .pathPrefix)
        let rulePath = normalizedPathForMatch(normalizePath(rule.path), mode: .pathPrefix)
        guard rulePath != "/", pathOnly.hasPrefix(rulePath) else {
            return pathOnly.hasPrefix("/") ? String(pathOnly.dropFirst()) : pathOnly
        }
        var remainder = String(pathOnly.dropFirst(rulePath.count))
        if remainder.hasPrefix("/") {
            remainder = String(remainder.dropFirst())
        }
        return remainder
    }

    /// Resolves a `.mapRemote` rule's final upstream request-target. Returns `nil` when the rule
    /// has no `mapRemotePath` override, meaning the caller should reuse the original request's
    /// path/query verbatim — the only behavior that existed before this field.
    private func resolvedMapRemoteRequestTarget(rule: ResponseOverrideRule, originalRequestTarget: String) -> String? {
        guard let overridePath = rule.mapRemotePath else {
            return nil
        }
        let query: String?
        switch rule.mapRemoteQueryPolicy {
        case .preserve:
            let parts = originalRequestTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            query = parts.count > 1 ? String(parts[1]) : nil
        case .replace:
            query = rule.mapRemoteQuery
        case .drop:
            query = nil
        }
        guard let query, !query.isEmpty else {
            return overridePath
        }
        return "\(overridePath)?\(query)"
    }

    nonisolated private func canonicalPort(_ port: Int?, scheme: SessionScheme) -> Int {
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

    private func sanitizedHeaders(_ headers: [HTTPHeaderField]) -> [HTTPHeaderField] {
        headers.filter { header in
            let lowercasedName = header.name.lowercased()
            return lowercasedName != "content-length" &&
                lowercasedName != "connection" &&
                lowercasedName != "transfer-encoding" &&
                lowercasedName != "proxy-connection"
        }
    }

    private func upsertingHeader(named name: String, value: String, in headers: [HTTPHeaderField]) -> [HTTPHeaderField] {
        let filteredHeaders = headers.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        return filteredHeaders + [HTTPHeaderField(name: name, value: value)]
    }

    private func normalizedContentType(_ contentType: String?, fallback: String) -> String {
        let trimmed = contentType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func normalizedLabel(_ label: String?) -> String? {
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedLabel.isEmpty ? nil : trimmedLabel
    }

    private func inferredContentType(for fileURL: URL) -> String? {
        guard let type = UTType(filenameExtension: fileURL.pathExtension) else {
            return nil
        }
        return type.preferredMIMEType
    }

    private func makePersistedRule(from rule: ResponseOverrideRule) throws -> PersistedResponseOverrideRule {
        let persistedBodySource: PersistedResponseOverrideBodySource
        switch rule.bodySource {
        case .inline(let data):
            persistedBodySource = .inline(data)
        case .file(let fileURL):
            do {
                let bookmarkData = try fileURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                persistedBodySource = .file(bookmarkData: bookmarkData)
            } catch {
                throw ResponseOverrideError.fileBookmarkCreationFailed(error.localizedDescription)
            }
        case .directory(let directoryURL):
            do {
                let bookmarkData = try directoryURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                persistedBodySource = .directory(bookmarkData: bookmarkData)
            } catch {
                throw ResponseOverrideError.fileBookmarkCreationFailed(error.localizedDescription)
            }
        }

        return PersistedResponseOverrideRule(
            id: rule.id,
            label: rule.label,
            requestMethod: rule.requestMethod,
            requestScheme: rule.requestScheme,
            host: rule.host,
            port: rule.port,
            path: rule.path,
            matchMode: rule.matchMode,
            sourceKind: rule.sourceKind,
            sourceDescription: rule.sourceDescription,
            statusCode: rule.statusCode,
            headers: rule.headers,
            bodySource: persistedBodySource,
            createdAt: rule.createdAt,
            isEnabled: rule.isEnabled,
            hitCount: rule.hitCount,
            lastMatchedAt: rule.lastMatchedAt,
            mapRemoteHost: rule.mapRemoteHost,
            mapRemotePort: rule.mapRemotePort,
            mapRemoteScheme: rule.mapRemoteScheme,
            mapRemotePath: rule.mapRemotePath,
            mapRemoteQueryPolicy: rule.mapRemoteQueryPolicy,
            mapRemoteQuery: rule.mapRemoteQuery,
            allowLoopbackDestination: rule.allowLoopbackDestination,
            preserveHostHeader: rule.preserveHostHeader,
            bookmarkRewriteRequest: rule.bookmarkRewriteRequest,
            liveResponseRewrites: rule.liveResponseRewrites,
            expectedSchemaFingerprint: rule.expectedSchemaFingerprint,
            collectionMockPlan: rule.collectionMockPlan,
            mcpOrigin: rule.mcpOrigin,
            mcpProvenance: rule.mcpProvenance,
            mcpTargetRevision: rule.mcpTargetRevision,
            effectBundleID: rule.effectBundleID,
            dropConnection: rule.dropConnection,
            fixtureRunID: rule.fixtureRunID,
            forceNoCache: rule.forceNoCache,
            notFoundRelativePath: rule.notFoundRelativePath,
            missingFilePolicy: rule.missingFilePolicy,
            graphQLOperationName: rule.graphQLOperationName,
            matchQueryKey: rule.matchQueryKey,
            matchQueryValue: rule.matchQueryValue,
            matchHeaderName: rule.matchHeaderName,
            matchHeaderValue: rule.matchHeaderValue,
            sourceClientAddress: rule.sourceClientAddress,
            ignoredQueryNames: rule.ignoredQueryNames
        )
    }

    private func makeRuntimeRule(from persistedRule: PersistedResponseOverrideRule) throws -> ResponseOverrideRule {
        let bodySource: ResponseOverrideBodySource
        switch persistedRule.bodySource {
        case .inline(let data):
            bodySource = .inline(data)
        case .file(let bookmarkData):
            var isStale = false
            do {
                let fileURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                bodySource = .file(fileURL)
            } catch {
                throw ResponseOverrideError.persistedOverrideLoadFailed(error.localizedDescription)
            }
        case .directory(let bookmarkData):
            var isStale = false
            do {
                let directoryURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                bodySource = .directory(directoryURL)
            } catch {
                throw ResponseOverrideError.persistedOverrideLoadFailed(error.localizedDescription)
            }
        }

        return ResponseOverrideRule(
            id: persistedRule.id,
            label: persistedRule.label,
            requestMethod: persistedRule.requestMethod,
            requestScheme: persistedRule.requestScheme,
            host: persistedRule.host,
            port: persistedRule.port,
            path: persistedRule.path,
            matchMode: persistedRule.matchMode,
            sourceKind: persistedRule.sourceKind,
            sourceDescription: persistedRule.sourceDescription,
            statusCode: persistedRule.statusCode,
            headers: persistedRule.headers,
            bodySource: bodySource,
            createdAt: persistedRule.createdAt,
            isEnabled: persistedRule.effectBundleID == nil ? persistedRule.isEnabled : false,
            hitCount: persistedRule.hitCount,
            lastMatchedAt: persistedRule.lastMatchedAt,
            mapRemoteHost: persistedRule.mapRemoteHost,
            mapRemotePort: persistedRule.mapRemotePort,
            mapRemoteScheme: persistedRule.mapRemoteScheme,
            mapRemotePath: persistedRule.mapRemotePath,
            mapRemoteQueryPolicy: persistedRule.mapRemoteQueryPolicy,
            mapRemoteQuery: persistedRule.mapRemoteQuery,
            allowLoopbackDestination: persistedRule.allowLoopbackDestination,
            preserveHostHeader: persistedRule.preserveHostHeader,
            bookmarkRewriteRequest: persistedRule.bookmarkRewriteRequest,
            liveResponseRewrites: persistedRule.liveResponseRewrites,
            expectedSchemaFingerprint: persistedRule.expectedSchemaFingerprint,
            collectionMockPlan: persistedRule.collectionMockPlan,
            mcpOrigin: persistedRule.mcpOrigin,
            mcpProvenance: persistedRule.mcpProvenance,
            mcpTargetRevision: persistedRule.mcpTargetRevision,
            effectBundleID: persistedRule.effectBundleID,
            dropConnection: persistedRule.dropConnection,
            fixtureRunID: persistedRule.fixtureRunID,
            forceNoCache: persistedRule.forceNoCache,
            notFoundRelativePath: persistedRule.notFoundRelativePath,
            missingFilePolicy: persistedRule.missingFilePolicy,
            graphQLOperationName: persistedRule.graphQLOperationName,
            matchQueryKey: persistedRule.matchQueryKey,
            matchQueryValue: persistedRule.matchQueryValue,
            matchHeaderName: persistedRule.matchHeaderName,
            matchHeaderValue: persistedRule.matchHeaderValue,
            sourceClientAddress: persistedRule.sourceClientAddress,
            ignoredQueryNames: persistedRule.ignoredQueryNames
        )
    }

    private func normalizedRewriteRequest(_ request: CapturedRequest) -> CapturedRequest {
        CapturedRequest(
            method: request.method,
            scheme: request.scheme,
            inspectionKind: request.inspectionKind,
            inspectionReason: request.inspectionReason,
            host: normalizeHost(request.host),
            port: request.port,
            path: normalizePath(request.path),
            headers: sanitizedRewriteHeaders(request.headers),
            bodyData: request.bodyData?.isEmpty == true ? nil : request.bodyData,
            bodySize: request.bodyData?.isEmpty == true ? nil : request.bodyData?.count
        )
    }

    private func sanitizedRewriteHeaders(_ headers: [HTTPHeaderField]) -> [HTTPHeaderField] {
        headers.filter { header in
            let lowercasedName = header.name.lowercased()
            return lowercasedName != "host" &&
                lowercasedName != "content-length" &&
                lowercasedName != "connection" &&
                lowercasedName != "transfer-encoding" &&
                lowercasedName != "proxy-connection"
        }
    }
}
