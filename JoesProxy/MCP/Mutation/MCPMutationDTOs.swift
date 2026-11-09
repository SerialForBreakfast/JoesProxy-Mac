import Foundation

/// Sanitized bookmark summary for MCP inspect tools (no auth headers or secrets).
struct MCPBookmarkSummaryDTO: Equatable, Sendable, Codable {
    var id: String
    var name: String
    var method: String
    var host: String
    var path: String
    var matchMode: String
    var rewriteMode: String
    var enabledRewriteCount: Int
    var hasSavedResponse: Bool
    var mcpOrigin: String?
    var mcpClientID: String?
    var mcpTargetRevision: String?
    var createdAt: Date
}

/// Sanitized response-override summary for MCP inspect tools.
///
/// Kind-specific fields are optional and omit Map Local / fixture body bytes and auth headers.
struct MCPOverrideSummaryDTO: Equatable, Sendable, Codable {
    var id: String
    var label: String?
    var method: String
    var host: String
    var path: String
    var matchMode: String
    var sourceKind: String
    var isEnabled: Bool
    var statusCode: Int
    var mcpOrigin: String?
    var mcpClientID: String?
    var mcpTargetRevision: String?
    var createdAt: Date
    /// Matcher scheme (`http` / `https`).
    var scheme: String?
    /// Explicit matcher port when set.
    var port: Int?
    var sourceDescription: String?
    var hitCount: Int
    var lastMatchedAt: Date?
    var dropConnection: Bool?
    var mapRemoteHost: String?
    var mapRemotePort: Int?
    var mapRemoteScheme: String?
    var mapRemotePath: String?
    var mapRemoteQueryPolicy: String?
    var mapRemoteQuery: String?
    var bookmarkRewriteMethod: String?
    var bookmarkRewriteHost: String?
    var bookmarkRewritePath: String?
    /// Enabled live-rewrite JSON paths only (no override values).
    var liveRewritePaths: [String]?
    var fixtureRunID: String?
    /// `.localDirectory` only: last path component of the chosen folder (never a full path).
    var localDirectoryName: String?
    /// `.localFile` only: last path component of the chosen file (never a full path).
    var localFileName: String?
    /// `.localDirectory` only: how a request under this prefix with no matching local file is
    /// served — see `LocalDirectoryMissingFilePolicy`. `nil` for every other source kind.
    var missingFilePolicy: String?
    var forceNoCache: Bool?
    var graphqlOperationName: String?
    var matchQueryKey: String?
    var matchQueryValue: String?
    var sourceClientAddress: String? = nil
}

struct MCPBookmarkDecisionDTO: Equatable, Sendable, Codable {
    var id: String
    var name: String
    var method: String
    var enabledRewriteCount: Int
    var hasSavedResponse: Bool
}

struct MCPBookmarkContextDTO: Equatable, Sendable, Codable {
    var id: String
    var name: String
    var method: String
    var host: String
    var path: String
    var matchMode: String
    var rewriteMode: String
    var enabledRewriteCount: Int
    var hasSavedResponse: Bool
}

struct MCPOverrideDecisionDTO: Equatable, Sendable, Codable {
    var id: String
    var label: String?
    var sourceKind: String
    var isEnabled: Bool
    var statusCode: Int
    var hitCount: Int
}

struct MCPOverrideContextDTO: Equatable, Sendable, Codable {
    var id: String
    var label: String?
    var method: String
    var host: String
    var path: String
    var matchMode: String
    var sourceKind: String
    var isEnabled: Bool
    var statusCode: Int
    var scheme: String?
    var port: Int?
    var sourceDescription: String?
    var hitCount: Int
    var lastMatchedAt: Date?
    var dropConnection: Bool?
    var mapRemoteHost: String?
    var mapRemotePort: Int?
    var mapRemoteScheme: String?
    var mapRemotePath: String?
    var mapRemoteQueryPolicy: String?
    var liveRewritePaths: [String]?
    var fixtureRunID: String?
    /// `.localDirectory` only: last path component of the chosen folder (never a full path).
    var localDirectoryName: String?
    /// `.localFile` only: last path component of the chosen file (never a full path).
    var localFileName: String?
    /// `.localDirectory` only: how a request under this prefix with no matching local file is
    /// served — see `LocalDirectoryMissingFilePolicy`. `nil` for every other source kind.
    var missingFilePolicy: String?
    var forceNoCache: Bool?
    var graphqlOperationName: String?
    var matchQueryKey: String?
    var matchQueryValue: String?
    var sourceClientAddress: String? = nil
}

/// Paginated list envelope for inspect tools.
struct MCPMutationListPageDTO<T: Equatable & Sendable & Codable>: Equatable, Sendable, Codable {
    var items: [T]
    var nextCursor: String?
    var policyRevision: MCPPolicyRevision
    var projection: MCPResponseProjection = .minimal
}

/// Normalized HTTP matcher shared by create-disabled propose tools.
struct MCPMutationMatcher: Equatable, Sendable, Codable {
    var method: String
    var scheme: SessionScheme
    var host: String
    var port: Int?
    var path: String
    var matchMode: ResponseOverrideMatchMode
    var graphQLOperationName: String? = nil
    var matchQueryKey: String? = nil
    var matchQueryValue: String? = nil
    var sourceClientAddress: String? = nil
}

/// Disclosure payload returned by propose_* tools before in-app apply approval.
struct MCPMutationProposalPayload: Equatable, Sendable, Codable {
    var proposalToken: String
    var expiresAt: Date
    var targetLockKey: String
    var effectSummary: String
    var matchScope: MCPMutationMatchScopeDTO
    var conflicts: [String]
    var riskTier: String
    var defaultEnabled: Bool
    var targetRevision: String?
    var priorEnabledState: Bool?
    var proposedTargetID: String
}

/// Sanitized matcher scope included in proposal disclosure.
struct MCPMutationMatchScopeDTO: Equatable, Sendable, Codable {
    var method: String
    var host: String
    var path: String
    var matchMode: String
    /// Wire scheme for the matcher (`http` / `https`). Omitted only for non-HTTP scopes such as
    /// bookmark rewrites. Agents must reload with this scheme — HTTPS will miss an `http` rule.
    var scheme: String?
    /// Explicit matcher port when present; when nil, the canonical port for `scheme` applies.
    var port: Int?
    var graphqlOperationName: String?
    var matchQueryKey: String?
    var matchQueryValue: String?
    var sourceClientAddress: String? = nil
}

/// Result returned after a successful apply_* call.
struct MCPMutationApplyResultDTO: Equatable, Sendable, Codable {
    var transactionID: String
    var appliedAt: Date
    var targetID: String
    var isEnabled: Bool
}

/// Pending mutation plan stored between propose and apply for one capability family.
struct MCPMutationPlan: Equatable, Sendable {
    var capability: MCPCapabilityID
    var activeTarget: MCPActiveMutationTarget = .createNew
    var matcher: MCPMutationMatcher?
    var proposedTargetID: UUID
    var effectKind: MCPEffectKind
    var effectSummary: String
    var priorEnabledState: Bool?
    var targetRevision: MCPTargetRevision?
    var blockStatusCode: Int?
    /// When true, this block rule closes the connection with no HTTP response instead of serving
    /// `blockStatusCode` — see `ResponseOverrideRule.dropConnection`. Ignored for non-block plans.
    var blockDropConnection: Bool = false
    var mapRemoteHost: String?
    var mapRemotePort: Int?
    var mapRemoteScheme: SessionScheme?
    var mapRemotePath: String?
    var mapRemoteQueryPolicy: MapRemoteQueryPolicy = .preserve
    var mapRemoteQuery: String?
    /// Exact Map Local body bytes. Preview-derived plans store server-retained `Data`; manually
    /// authored `bodyText` is UTF-8-encoded into this field at propose time so persistence never
    /// re-decodes through `String`.
    var inlineBodyData: Data?
    var inlineContentType: String?
    var inlineStatusCode: Int?
    var bookmarkName: String?
    var bookmarkRequest: CapturedRequest?
    var bookmarkID: UUID?
    var rewriteID: UUID?
    var rewriteJSONPath: String?
    var rewriteOverrideValue: BookmarkJSONValue?
    var rewriteOperation: JSONMutationOperation = .set
    var rewriteRepeatPolicy: JSONMutationRepeatPolicy = .always
    var rewriteLabel: String?
    /// Reviewed collection-shape mutation for a `.collectionMock` plan — the compiled plan itself,
    /// not a reference back to `CollectionMockAuthoringService`'s cache, so apply never depends on
    /// a revision the authoring service may have since evicted.
    var collectionMockPlan: CompiledCollectionMock?
    var collectionMockLabel: String?
    var throttleConfiguration: NetworkThrottleConfiguration?
    /// Session used when creating a response draft from a capture.
    var draftSourceSessionID: UUID?
    /// Optional human label for a response draft create/rename.
    var draftLabel: String?
    /// Existing draft that receives a committed preview revision.
    var draftID: UUID?
    /// Consumed response-edit preview digest for draft commit or Map Local.
    var draftPreviewDigest: String?
    /// Draft revision to serve via Map Local without re-previewing.
    var responseRevisionID: UUID?
    /// `.fixtureRun` Map Local plans only: the `HLSFixtureRunRecord.id` this rule delegates to.
    /// `nil` for every other plan shape (mutually exclusive with `inlineBodyData`/
    /// `draftPreviewDigest`/`responseRevisionID`-backed bodies).
    var fixtureRunID: UUID?
    /// `.localDirectory` Map Local plans only: security-scoped bookmark bytes for the chosen
    /// directory (never a raw path). Mutually exclusive with body/fixture/preview/revision sources.
    var localDirectoryBookmarkData: Data?
    /// `.localFile` Map Local plans only: plain (not security-scoped) bookmark bytes for the chosen
    /// file (never a raw path). Mutually exclusive with body/fixture/preview/revision/directory
    /// sources. Content-Type is resolved once at propose time and carried in `inlineContentType`;
    /// status code in `inlineStatusCode` — both reused rather than adding single-file-only twins.
    var localFileBookmarkData: Data?
    /// Optional not-found relative path for `.localDirectory` plans.
    var notFoundRelativePath: String?
    /// `.localDirectory` Map Local plans only: how a miss is served — see
    /// `LocalDirectoryMissingFilePolicy`. Defaults to `.strictLocal`, the only behavior that
    /// existed before this field.
    var missingFilePolicy: LocalDirectoryMissingFilePolicy = .strictLocal
    /// Map Local plans only: when true, the served response strips caching headers and forces
    /// `Cache-Control: no-store` — see `ResponseOverrideRule.forceNoCache`. Ignored for other
    /// effect kinds. Defaults to `false`, the only behavior that existed before this field.
    var forceNoCache: Bool = false
}

/// Identifies the target of an active (enable/disable/throttle) mutation.
enum MCPActiveMutationTarget: Equatable, Sendable {
    case createNew
    case responseOverride(UUID)
    case bookmarkRewrite(bookmarkID: UUID, rewriteID: UUID)
    case throttle
}

/// Rollback snapshot for response override enable/disable.
struct MCPRuleRollbackSnapshot: Equatable, Sendable, Codable {
    var isEnabled: Bool
    var mcpTargetRevision: String?
}

/// Rollback snapshot for permanent MCP rule delete — restores the prior persisted rule blob.
struct MCPDeletedRuleRollbackSnapshot: Equatable, Sendable, Codable {
    /// JSON for one ``PersistedResponseOverrideRule`` as produced by ``ResponseOverrideStore``.
    var persistedRuleJSON: Data
}

/// Rollback snapshot for bookmark rewrite enable/disable.
struct MCPBookmarkRewriteRollbackSnapshot: Equatable, Sendable, Codable {
    var isRuleEnabled: Bool
    var bookmarkMcpTargetRevision: String?
}

/// Rollback snapshot for throttle configuration changes.
struct MCPThrottleRollbackSnapshot: Equatable, Sendable, Codable {
    var configuration: NetworkThrottleConfiguration
}

/// Extended proposal payload for active mutations that bind an existing target revision.
struct MCPActiveMutationProposalPayload: Equatable, Sendable, Codable {
    var proposalToken: String
    var expiresAt: Date
    var targetLockKey: String
    var effectSummary: String
    var targetRevision: String
    var priorEnabledState: Bool?
    var riskTier: String
    var proposedTargetID: String
}

/// Result of `discover_response_structure` — a deterministic, policy-gated structural summary of
/// one or a bounded set of captured JSON response bodies. `shapeDescription` is a compact
/// canonical description (property names/types/array shape, property names with sensitive-key
/// names redacted) — deliberately never includes actual values. `nil` when `status != "complete"`.
struct MCPStructuralProfileDTO: Equatable, Sendable, Codable {
    var status: String
    var shapeDescription: String?
    var sampleCount: Int
    var schemaFingerprint: String?
}

/// Result of `preview_live_rewrite` — applies a fully-specified candidate rewrite against a
/// bounded set of already-captured sessions, with no live-traffic effect and nothing persisted.
struct MCPTransformationPreviewResultDTO: Equatable, Sendable, Codable {
    struct SelectorResult: Equatable, Sendable, Codable {
        var selector: String
        var matchedCount: Int
        var changedCount: Int
        var skippedCount: Int
        var failureCount: Int
    }

    var eligibleCount: Int
    var ineligibleCount: Int
    var transformedCount: Int
    var zeroMatches: Bool
    var schemaFingerprint: String?
    /// Sanitized (never raw-value) example of one transformation, when policy and availability allow.
    var sanitizedExample: String?
    var selectorResults: [SelectorResult]
    var originalBytes: Int
    var transformedBytes: Int
    var byteGrowth: Int
    var warnings: [String]
    var captureEpoch: MCPCaptureEpoch
    var policyRevision: MCPPolicyRevision
    var sampledHighWaterSequence: UInt64
    var expiresAt: Date
    /// Binds this specific preview to a later approval — invalidated by any change to matcher,
    /// selector, operation, literal, or limits.
    var previewDigest: String
}

/// Result of `preview_collection_mock` — capture-only, nothing persisted beyond the bounded,
/// owner-scoped `CollectionMockAuthoringService` cache. `revisionID` is the binding
/// `propose_create_collection_mock` consumes; it carries no digest-recomputation requirement since
/// propose never re-accepts the draft, only this reference to an already-compiled plan.
struct MCPCollectionMockPreviewResultDTO: Equatable, Sendable, Codable {
    var revisionID: String
    var beforeCount: Int
    var afterCount: Int
    /// Human-readable rendering of the compiled plan — the same renderer `activate_collection_mock`
    /// uses for its disclosure, so preview and activation always describe the plan identically.
    var summary: String
}
