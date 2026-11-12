import CryptoKit
import Foundation

/// Production MCP adapter for bookmark/override inspection and create-disabled mutations.
///
/// Concurrency: `@MainActor` — reads policy, approval, and store state on the main actor; awaits
/// the response-override actor at persistence boundaries.
@MainActor
final class MCPMutationService {
    private struct LiveRewritePreviewRecord {
        let digest: String
        let clientID: String
        let mcpSessionID: String?
        let ruleDigest: String
        let sampledSessionIDs: [SessionRecord.ID]
        let captureEpoch: MCPCaptureEpoch
        let policyRevision: MCPPolicyRevision
        let sampledHighWaterSequence: UInt64
        let expiresAt: Date
    }

    /// Neutral capture-only preview retained for Map Local binding (HLS CODECS and generic edits).
    ///
    /// `transformedBodyHash` is always set so propose/apply disclosure can bind the retained bytes
    /// without re-hashing. CODECS-only fields (`codecValueProvenance`, `mediaVerified`,
    /// `codecsDiffSummary`) are populated by ``previewHLSCODECSEdit`` and remain `nil` for generic
    /// response-edit previews — never store body text, child URIs, or query values here.
    struct ResponseEditPreviewRecord {
        let digest: String
        let clientID: String
        let mcpSessionID: String?
        let captureEpoch: MCPCaptureEpoch
        let policyRevision: MCPPolicyRevision
        let sessionID: SessionRecord.ID
        let matcher: MCPMutationMatcher
        let patchedBody: Data
        /// SHA-256 hex of `patchedBody` for propose-time disclosure.
        let transformedBodyHash: String
        /// `"user_supplied"` for HLS CODECS previews; `nil` for generic response edits.
        let codecValueProvenance: String?
        /// Always `false` for CODECS previews (metadata-only; media was not re-encoded).
        let mediaVerified: Bool?
        /// Compact CODECS attribute diff for effect summaries (no manifest body).
        let codecsDiffSummary: String?
        let statusCode: Int
        let contentType: String
        let headerPlan: ResponseHeaderPolicyPlan
        let expiresAt: Date
        var lastAccessAt: Date
    }

    let bookmarkStore: any BookmarkStore
    let responseOverrideStore: ResponseOverrideStore
    let proposalCoordinator: MCPProposalCoordinator
    let recoveryCoordinator: MCPRecoveryCoordinator
    let approvalStore: MCPApprovalStore
    let policyStore: MCPPolicyStore
    let grantStore: MCPClientGrantStore
    let policyEvaluator: MCPPolicyEvaluator
    let auditStore: MCPAuditStore
    let throttleConfigurationReader: () -> NetworkThrottleConfiguration
    let throttleConfigurationWriter: (NetworkThrottleConfiguration) -> Void
    let loopbackPolicyReader: () -> LoopbackDestinationPolicy
    /// Read-only session/capture access for the structural-discovery and capture-only preview
    /// tools — `nil` in test stacks that don't need them (those two tools fail closed with a
    /// clear "unavailable" error rather than crashing when it's absent).
    let snapshotService: MCPSessionSnapshotService?
    /// Optional shared response-edit service for `matchRef` resolution and generic preview helpers.
    var responseEditService: MCPResponseEditService?
    /// Optional persistent response-draft store for G4 draft lifecycle tools.
    var responseDraftStore: ResponseDraftStore?
    /// Optional HLS fixture-run store, needed only to validate/disclose `.fixtureRun` Map Local
    /// rules (ownership + active-run checks against `propose_create_map_local`'s `fixtureRunID`
    /// argument). `nil` in stacks that don't wire fixture support — that source kind then fails
    /// closed with a clear "unavailable" error rather than crashing, matching the
    /// `responseDraftStore`/`snapshotService` optional-dependency pattern above.
    var hlsFixtureRunStore: HLSFixtureRunStore?
    /// Optional provider of currently active scenario IDs for P1-05 confounder disclosure/gating.
    /// Wired from ``MCPScenarioLifecycleCoordinator/activeScenarioIDs`` in production; `nil` in
    /// narrow test stacks that do not exercise scenarios (treated as empty).
    var activeScenarioIDsProvider: (() -> [String])?
    /// Optional collection-mock authoring/preview service. `nil` in stacks that don't wire it —
    /// `preview_collection_mock`/`propose_create_collection_mock` then fail closed with a clear
    /// "unavailable" error, matching the `responseDraftStore`/`snapshotService` pattern above.
    var collectionMockAuthoringService: CollectionMockAuthoringService?
    private let enforcesLiveRewritePreview: Bool
    var plansByProposalToken: [String: MCPMutationPlan] = [:]
    private var liveRewritePreviewsByDigest: [String: LiveRewritePreviewRecord] = [:]
    private var responseEditPreviewsByDigest: [String: ResponseEditPreviewRecord] = [:]
    /// Memory-only response-edit / HLS CODECS preview cache: TTL + entry count + aggregate bytes + LRU (`lastAccessAt`).
    private static let responseEditPreviewMaxEntries = 8
    private static let responseEditPreviewMaxAggregateBytes = 8 * 1024 * 1024
    /// Test seam: override entry cap for eviction tests (`nil` uses production default).
    var responseEditPreviewMaxEntriesForTesting: Int?
    /// Test seam: override TTL seconds for expiry tests (`nil` uses production default).
    var responseEditPreviewTTLForTesting: TimeInterval?
    private let encoder: JSONEncoder

    /// Capture cardinality + enabled-rule / scenario conflict snapshot for a matcher (P1-05).
    ///
    /// Concurrency: caller must be on the main actor; awaits ``ResponseOverrideStore/rules()``.
    struct MatcherScopeConflictEvaluation: Equatable, Sendable {
        var observedCaptureCardinality: Int
        var observedAt: Date
        var conflictingEnabledRuleIDs: [String]
        var activeScenarioIDs: [String]
        var cardinalityIsHistorical: Bool = true

        /// Soft preview warning when more than one captured request currently matches.
        var warning: String? {
            observedCaptureCardinality > 1
                ? "Matcher currently overlaps multiple captured requests."
                : nil
        }

        /// True when enable must not proceed without an explicit `acceptConfounder` flag.
        func hasConfounders(matchMode: ResponseOverrideMatchMode) -> Bool {
            !conflictingEnabledRuleIDs.isEmpty
                || !activeScenarioIDs.isEmpty
                || (matchMode == .pathSuffix && observedCaptureCardinality > 1)
        }
    }

    init(
        bookmarkStore: any BookmarkStore,
        responseOverrideStore: ResponseOverrideStore,
        proposalCoordinator: MCPProposalCoordinator,
        recoveryCoordinator: MCPRecoveryCoordinator,
        approvalStore: MCPApprovalStore,
        policyStore: MCPPolicyStore,
        grantStore: MCPClientGrantStore? = nil,
        auditStore: MCPAuditStore,
        snapshotService: MCPSessionSnapshotService? = nil,
        responseEditService: MCPResponseEditService? = nil,
        responseDraftStore: ResponseDraftStore? = nil,
        collectionMockAuthoringService: CollectionMockAuthoringService? = nil,
        enforcesLiveRewritePreview: Bool = true,
        throttleConfigurationReader: @escaping () -> NetworkThrottleConfiguration = { .defaults },
        throttleConfigurationWriter: @escaping (NetworkThrottleConfiguration) -> Void = { _ in },
        loopbackPolicyReader: @escaping () -> LoopbackDestinationPolicy = { .disabled }
    ) {
        self.bookmarkStore = bookmarkStore
        self.responseOverrideStore = responseOverrideStore
        self.proposalCoordinator = proposalCoordinator
        self.recoveryCoordinator = recoveryCoordinator
        self.approvalStore = approvalStore
        self.policyStore = policyStore
        let resolvedGrantStore = grantStore ?? MCPClientGrantStore()
        self.grantStore = resolvedGrantStore
        self.policyEvaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: resolvedGrantStore)
        self.auditStore = auditStore
        self.snapshotService = snapshotService
        self.responseEditService = responseEditService
        self.responseDraftStore = responseDraftStore
        self.collectionMockAuthoringService = collectionMockAuthoringService
        self.enforcesLiveRewritePreview = enforcesLiveRewritePreview
        self.throttleConfigurationReader = throttleConfigurationReader
        self.throttleConfigurationWriter = throttleConfigurationWriter
        self.loopbackPolicyReader = loopbackPolicyReader
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let responseDraftStore, !responseDraftStore.isLoaded {
            responseDraftStore.load()
        }
    }

    /// Dispatches AH-3 inspect, propose, and apply MCP tools.
    func handleTool(
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        do {
            return try await dispatchTool(name: name, arguments: arguments, client: client)
        } catch let error as MCPMutationValidationError {
            throw MCPMutationValidator.structuredError(for: error)
        } catch let error as MCPProposalCoordinatorError {
            throw proposalCoordinator.structuredError(for: error)
        }
    }

    private func dispatchTool(
        name: String,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        switch name {
        case "bookmarks_list":
            return try await bookmarksList(arguments: arguments, client: client)
        case "bookmark_get":
            return try bookmarkGet(arguments: arguments, client: client)
        case "overrides_list":
            return try await overridesList(arguments: arguments, client: client)
        case "override_get":
            return try await overrideGet(arguments: arguments, client: client)
        case "capture_activity_since_marker":
            return try await captureActivitySinceMarker(arguments: arguments, client: client)
        case "discover_response_structure":
            return try discoverResponseStructure(arguments: arguments, client: client)
        case "preview_live_rewrite":
            return try previewLiveRewrite(arguments: arguments, client: client)
        case "preview_hls_codecs_edit":
            return try await previewHLSCODECSEdit(arguments: arguments, client: client)
        case "preview_response_edit":
            return try await previewResponseEdit(arguments: arguments, client: client)
        case "response_drafts_list":
            return try responseDraftsList(arguments: arguments, client: client)
        case "response_draft_get":
            return try await responseDraftGet(arguments: arguments, client: client)
        case "propose_create_response_draft":
            return try await proposeCreateResponseDraft(arguments: arguments, client: client)
        case "apply_create_response_draft":
            return try await applyCreateResponseDraft(arguments: arguments, client: client)
        case "propose_commit_response_edit":
            return try await proposeCommitResponseEdit(arguments: arguments, client: client)
        case "apply_commit_response_edit":
            return try await applyCommitResponseEdit(arguments: arguments, client: client)
        case "propose_delete_response_draft":
            return try await proposeDeleteResponseDraft(arguments: arguments, client: client)
        case "apply_delete_response_draft":
            return try await applyDeleteResponseDraft(arguments: arguments, client: client)
        case "propose_create_block":
            return try await proposeCreateBlock(arguments: arguments, client: client)
        case "apply_create_block":
            return try await applyCreateBlock(arguments: arguments, client: client)
        case "propose_create_map_local":
            return try await proposeCreateMapLocal(arguments: arguments, client: client)
        case "apply_create_map_local":
            return try await applyCreateMapLocal(arguments: arguments, client: client)
        case "propose_create_map_remote":
            return try await proposeCreateMapRemote(arguments: arguments, client: client)
        case "apply_create_map_remote":
            return try await applyCreateMapRemote(arguments: arguments, client: client)
        case "propose_create_live_rewrite":
            return try await proposeCreateLiveRewrite(arguments: arguments, client: client)
        case "apply_create_live_rewrite":
            return try await applyCreateLiveRewrite(arguments: arguments, client: client)
        case "preview_collection_mock":
            return try await previewCollectionMock(arguments: arguments, client: client)
        case "propose_create_collection_mock":
            return try await proposeCreateCollectionMock(arguments: arguments, client: client)
        case "apply_create_collection_mock":
            return try await applyCreateCollectionMock(arguments: arguments, client: client)
        case "propose_create_rewrite":
            return try await proposeCreateRewrite(arguments: arguments, client: client)
        case "apply_create_rewrite":
            return try await applyCreateRewrite(arguments: arguments, client: client)
        case "propose_create_bookmark":
            return try await proposeCreateBookmark(arguments: arguments, client: client)
        case "apply_create_bookmark":
            return try await applyCreateBookmark(arguments: arguments, client: client)
        case "propose_enable_rule":
            return try await proposeEnableRule(arguments: arguments, client: client)
        case "apply_enable_rule":
            return try await applyEnableRule(arguments: arguments, client: client)
        case "propose_disable_rule":
            return try await proposeDisableRule(arguments: arguments, client: client)
        case "apply_disable_rule":
            return try await applyDisableRule(arguments: arguments, client: client)
        case "propose_delete_rule":
            return try await proposeDeleteRule(arguments: arguments, client: client)
        case "apply_delete_rule":
            return try await applyDeleteRule(arguments: arguments, client: client)
        case "propose_enable_rewrite":
            return try await proposeEnableRewrite(arguments: arguments, client: client)
        case "apply_enable_rewrite":
            return try await applyEnableRewrite(arguments: arguments, client: client)
        case "propose_disable_rewrite":
            return try await proposeDisableRewrite(arguments: arguments, client: client)
        case "apply_disable_rewrite":
            return try await applyDisableRewrite(arguments: arguments, client: client)
        case "propose_change_throttle":
            return try await proposeChangeThrottle(arguments: arguments, client: client)
        case "apply_change_throttle":
            return try await applyChangeThrottle(arguments: arguments, client: client)
        default:
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown mutation tool: \(name).")
        }
    }

    // MARK: - Inspect

    private func bookmarksList(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .bookmarkInspect)
        let limit = min(max(1, arguments["limit"] as? Int ?? MCPResourceBudget.defaultPageSize), MCPResourceBudget.maxPageSize)
        let offset = decodeListOffset(arguments["cursor"] as? String)
        let all = bookmarkStore.loadBookmarks().map(Self.bookmarkSummary)
        let slice = Array(all.dropFirst(offset).prefix(limit))
        let nextCursor = offset + slice.count < all.count ? encodeListOffset(offset + slice.count) : nil
        switch try responseProjection(arguments) {
        case .minimal:
            return try payloadDictionary(
                MCPMutationListPageDTO(
                    items: slice.map(Self.bookmarkDecision),
                    nextCursor: nextCursor,
                    policyRevision: policyStore.policyRevision,
                    projection: .minimal
                )
            )
        case .summary:
            return try payloadDictionary(
                MCPMutationListPageDTO(
                    items: slice.map(Self.bookmarkContext),
                    nextCursor: nextCursor,
                    policyRevision: policyStore.policyRevision,
                    projection: .summary
                )
            )
        case .full:
            return try payloadDictionary(
                MCPMutationListPageDTO(
                    items: slice,
                    nextCursor: nextCursor,
                    policyRevision: policyStore.policyRevision,
                    projection: .full
                )
            )
        }
    }

    private func bookmarkGet(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .bookmarkInspect)
        guard let idString = arguments["bookmarkID"] as? String,
              let id = UUID(uuidString: idString),
              let bookmark = bookmarkStore.loadBookmarks().first(where: { $0.id == id }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "bookmarkID not found.")
        }
        return try payloadDictionary(Self.bookmarkSummary(bookmark))
    }

    private func overridesList(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .overrideInspect)
        let limit = min(max(1, arguments["limit"] as? Int ?? MCPResourceBudget.defaultPageSize), MCPResourceBudget.maxPageSize)
        let offset = decodeListOffset(arguments["cursor"] as? String)
        var rules = await responseOverrideStore.rules()
        if let sourceKindRaw = arguments["sourceKind"] as? String,
           let sourceKind = ResponseOverrideSourceKind(rawValue: sourceKindRaw) {
            rules = rules.filter { $0.sourceKind == sourceKind }
        }
        let summaries = rules.map(Self.overrideSummary)
        let slice = Array(summaries.dropFirst(offset).prefix(limit))
        let nextCursor = offset + slice.count < summaries.count ? encodeListOffset(offset + slice.count) : nil
        switch try responseProjection(arguments) {
        case .minimal:
            return try payloadDictionary(
                MCPMutationListPageDTO(
                    items: slice.map(Self.overrideDecision),
                    nextCursor: nextCursor,
                    policyRevision: policyStore.policyRevision,
                    projection: .minimal
                )
            )
        case .summary:
            return try payloadDictionary(
                MCPMutationListPageDTO(
                    items: slice.map(Self.overrideContext),
                    nextCursor: nextCursor,
                    policyRevision: policyStore.policyRevision,
                    projection: .summary
                )
            )
        case .full:
            return try payloadDictionary(
                MCPMutationListPageDTO(
                    items: slice,
                    nextCursor: nextCursor,
                    policyRevision: policyStore.policyRevision,
                    projection: .full
                )
            )
        }
    }

    private func overrideGet(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .overrideInspect)
        guard let idString = arguments["overrideID"] as? String,
              let id = UUID(uuidString: idString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "overrideID is required.")
        }
        let rules = await responseOverrideStore.rules()
        guard let rule = rules.first(where: { $0.id == id }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "overrideID not found.")
        }
        return try payloadDictionary(Self.overrideSummary(rule))
    }

    /// Ceremony-free "post-marker request observed / rule hit" evidence — composes two primitives
    /// that already exist independently (`sessions_search --since-sequence` and `override_get`'s
    /// `hitCount`/`lastMatchedAt`) into one call, instead of requiring the full diagnostic-run
    /// create/start/observe/close lifecycle just to answer "did anything change since I did the
    /// thing." Deliberately returns only method/status/sequence per new request, never host/path/
    /// body — an agent that needs full detail on a specific new session already has
    /// `session_summary`/`sessions_search` for that, profile-gated as usual.
    private func captureActivitySinceMarker(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .overrideInspect)
        guard let snapshotService else {
            throw MCPStructuredError(code: .internalFailure, message: "Session snapshot service is unavailable.")
        }
        let hasMarkerID = arguments["markerSessionID"] != nil
        let hasSinceSeq = arguments["sinceSequence"] != nil
        guard hasMarkerID != hasSinceSeq else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: hasMarkerID ? "Provide either markerSessionID or sinceSequence, not both." : "markerSessionID or sinceSequence is required."
            )
        }

        let markerSessionIDString: String?
        let markerCaptureSequence: UInt64
        let markerStartedAt: Date?
        if hasMarkerID {
            guard let idString = arguments["markerSessionID"] as? String,
                  let markerSessionID = UUID(uuidString: idString) else {
                throw MCPStructuredError(code: .malformedRequest, message: "markerSessionID must be a valid session UUID.")
            }
            guard let marker = snapshotService.indexedSession(id: markerSessionID) else {
                throw MCPStructuredError(
                    code: .malformedRequest,
                    message: "markerSessionID not found — it may predate the current capture epoch or have been cleared."
                )
            }
            markerSessionIDString = markerSessionID.uuidString
            markerCaptureSequence = marker.captureSequence
            markerStartedAt = marker.record.timing.startedAt
        } else {
            guard let number = arguments["sinceSequence"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.int64Value >= 0,
                  number.doubleValue == Double(number.int64Value) else {
                throw MCPStructuredError(code: .malformedRequest, message: "sinceSequence must be a non-negative integer.")
            }
            markerSessionIDString = nil
            markerCaptureSequence = UInt64(number.int64Value)
            markerStartedAt = nil
        }

        let limit = min(max(1, arguments["limit"] as? Int ?? 20), MCPResourceBudget.maxPageSize)
        let page = try snapshotService.page(
            request: MCPSessionSnapshotService.PageRequest(
                limit: limit,
                cursor: nil,
                queryDigest: "capture_activity_since_marker:\(markerSessionIDString ?? "seq-\(markerCaptureSequence)")",
                orderingDigest: "sequence_asc",
                filter: nil,
                minimumSequenceExclusive: markerCaptureSequence
            ),
            clientID: client.id,
            policyRevision: policyStore.policyRevision
        )

        let newRequests: [[String: Any]] = page.items.map { indexed in
            var entry: [String: Any] = [
                "sessionID": indexed.record.id.uuidString,
                "captureSequence": indexed.captureSequence,
                "method": indexed.record.request.method
            ]
            if let response = indexed.record.response {
                entry["statusCode"] = response.statusCode
            }
            return entry
        }

        var result: [String: Any] = [
            "markerSessionID": markerSessionIDString as Any,
            "markerCaptureSequence": markerCaptureSequence,
            "newRequestCount": page.items.count,
            "hasMore": page.nextCursor != nil,
            "newRequests": newRequests
        ]

        if let overrideIDString = arguments["overrideID"] as? String {
            guard let overrideID = UUID(uuidString: overrideIDString) else {
                throw MCPStructuredError(code: .malformedRequest, message: "overrideID must be a valid identifier.")
            }
            let rules = await responseOverrideStore.rules()
            if let rule = rules.first(where: { $0.id == overrideID }) {
                var matchedSessionIDs: [String] = []
                var nearMisses: [[String: Any]] = []
                for indexed in page.items {
                    let diag = responseOverrideStore.diagnoseMatch(rule: rule, request: indexed.record.request)
                    if diag.matched {
                        matchedSessionIDs.append(indexed.record.id.uuidString)
                    } else if diag.isNearMiss && nearMisses.count < 10 {
                        nearMisses.append([
                            "sessionID": indexed.record.id.uuidString,
                            "captureSequence": indexed.captureSequence,
                            "method": indexed.record.request.method,
                            "failedPredicates": diag.failedReasons
                        ])
                    }
                }
                let matchedByTimestamp = markerStartedAt.flatMap { start in rule.lastMatchedAt.map { $0 > start } } ?? false
                let matchedSinceMarker = matchedByTimestamp || !matchedSessionIDs.isEmpty
                result["rule"] = [
                    "overrideID": overrideID.uuidString,
                    "found": true,
                    "isEnabled": rule.isEnabled,
                    "hitCountTotal": rule.hitCount,
                    "lastMatchedAt": rule.lastMatchedAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                    "matchedSinceMarker": matchedSinceMarker,
                    "matchedSessionIDs": matchedSessionIDs,
                    "nearMisses": nearMisses
                ]
            } else {
                result["rule"] = ["overrideID": overrideID.uuidString, "found": false]
            }
        }

        return result
    }

    // MARK: - Structural discovery and capture-only preview

    /// Maximum captured sessions sampled by `discover_response_structure`/`preview_live_rewrite` in
    /// one call — bounded like every other list tool (`MCPResourceBudget.maxPageSize`), since both
    /// tools read whole response bodies rather than paginated summaries.
    private static let maxDiscoverySampleCount = 20
    private static let responseEditPreviewTTL: TimeInterval = 300
    private static let responseEditPreviewMaxBodyBytes = 2 * 1024 * 1024
    private static let hlsCodecsPreviewTTL = responseEditPreviewTTL
    private static let hlsCodecsPreviewMaxBodyBytes = responseEditPreviewMaxBodyBytes

    private var effectiveResponseEditPreviewMaxEntries: Int {
        responseEditPreviewMaxEntriesForTesting ?? Self.responseEditPreviewMaxEntries
    }

    private var effectiveResponseEditPreviewTTL: TimeInterval {
        responseEditPreviewTTLForTesting ?? Self.responseEditPreviewTTL
    }

    private func previewHLSCODECSEdit(
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .transformationPreview)
        guard let snapshotService,
              let sessionIDString = arguments["sessionID"] as? String,
              let sessionID = UUID(uuidString: sessionIDString),
              let indexed = snapshotService.indexedSession(id: sessionID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "A captured session is required.")
        }
        guard let response = indexed.record.response else {
            throw MCPStructuredError(code: .malformedRequest, message: "A captured response body is required.")
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw MCPStructuredError(code: .malformedRequest, message: "CODECS preview requires a successful (2xx) captured response.")
        }
        guard let rawBody = response.bodyData, !rawBody.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "The captured response body is absent or was evicted.")
        }
        guard let decoded = CapturedBodyDecoder.decode(
            bodyData: rawBody,
            headers: response.headers,
            maxDecodedBytes: Self.hlsCodecsPreviewMaxBodyBytes
        ) else {
            throw MCPStructuredError(code: .malformedRequest, message: "The captured HLS body could not be decoded.")
        }
        guard decoded.canUseAnalysisDataForInspection else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "The captured HLS body is truncated, streaming-incomplete, or unavailable for inspection."
            )
        }
        guard let utf8Text = decoded.analysisUTF8Text() else {
            throw MCPStructuredError(code: .malformedRequest, message: "The captured HLS body is not valid UTF-8 text.")
        }
        let originalBody = Data(utf8Text.utf8)
        guard originalBody.count <= Self.hlsCodecsPreviewMaxBodyBytes else {
            throw MCPStructuredError(code: .malformedRequest, message: "The captured HLS body exceeds the preview size limit.")
        }

        let locators = try HLSCODECSEditTransformer.variantLocators(in: originalBody)
        let manifest = HLSParser.parse(String(decoding: originalBody, as: UTF8.self), baseURL: nil)
        guard manifest.isMasterPlaylist else {
            throw MCPStructuredError(code: .malformedRequest, message: "CODECS edits require an HLS master playlist.")
        }
        let edits = try decodeHLSCODECSEdits(arguments["edits"])
        guard !edits.isEmpty, edits.count <= 100 else {
            throw MCPStructuredError(code: .malformedRequest, message: "edits must contain between 1 and 100 variants.")
        }
        let captureSequence = indexed.captureSequence
        let bodyDigest = sha256Hex(originalBody)
        var resolvedEdits: [HLSCODECSVariantEdit] = []
        var diff: [[String: Any]] = []
        var editedOrdinals = Set<Int>()
        for edit in edits {
            guard let locator = locators.first(where: {
                hlsVariantReference(
                    sessionID: sessionID,
                    captureSequence: captureSequence,
                    bodyDigest: bodyDigest,
                    locator: $0
                ) == edit.variantRef
            }) else {
                throw MCPStructuredError(code: .staleProposal, message: "A variantRef does not match the current captured master.")
            }
            guard let ordinal = locators.firstIndex(of: locator),
                  ordinal < manifest.variants.count else {
                throw MCPStructuredError(code: .staleProposal, message: "A variantRef resolved outside the parsed master.")
            }
            let oldCodecs = manifest.variants[ordinal].codecs
            resolvedEdits.append(HLSCODECSVariantEdit(locator: locator, codecs: edit.codecs))
            editedOrdinals.insert(ordinal)
            diff.append([
                "variantRef": edit.variantRef,
                "oldCodecs": oldCodecs as Any,
                "newCodecs": edit.codecs
            ])
        }
        let transformed: HLSCODECSEditResult
        do {
            transformed = try HLSCODECSEditTransformer.apply(
                originalBytes: originalBody,
                edits: resolvedEdits
            )
        } catch let error as HLSCODECSEditError {
            throw error
        } catch {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "CODECS edit rejected: \(error)"
            )
        }
        let patchedManifest = HLSParser.parse(String(decoding: transformed.data, as: UTF8.self), baseURL: nil)
        do {
            try HLSCODECSPreviewSemanticCheck.assertCodecsOnlyChange(
                original: manifest,
                patched: patchedManifest,
                editedOrdinals: editedOrdinals
            )
        } catch {
            throw MCPStructuredError(
                code: .internalFailure,
                message: "The CODECS edit changed non-CODECS manifest structure (\(error))."
            )
        }

        let matcher = try hlsMatcher(arguments: arguments, request: indexed.record.request)
        let scopeEvaluation = await evaluateMatcherScopeConflicts(matcher: matcher, excludingRuleID: nil)
        let freshness = hlsFreshnessDisclosure(
            manifestText: String(decoding: originalBody, as: UTF8.self),
            capturedAt: indexed.record.timing.startedAt
        )
        let contentType = response.headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value ?? "application/vnd.apple.mpegurl"
        let patchedBodyHash = sha256Hex(transformed.data)
        let previewDigest = MCPHLSCodecsPreviewDigest.compute(
            sessionID: sessionID,
            captureSequence: captureSequence,
            originalBodyHash: bodyDigest,
            patchedBodyHash: patchedBodyHash,
            edits: edits,
            matcher: matcher,
            sourceStatus: response.statusCode,
            contentType: contentType,
            transformerVersion: HLSCODECSEditTransformer.transformerVersion
        )
        let now = Date()
        let headerPlan = ResponseHeaderPolicyPlan.planForEditedDecodedBody(
            statusCode: response.statusCode,
            contentType: contentType,
            capturedHeaders: response.headers
        )
        let diffSummary = compactCODECSDiffSummary(diff)
        storeResponseEditPreview(ResponseEditPreviewRecord(
            digest: previewDigest,
            clientID: client.id,
            mcpSessionID: arguments["__mcpInternalSessionID"] as? String,
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyStore.policyRevision,
            sessionID: sessionID,
            matcher: matcher,
            patchedBody: transformed.data,
            transformedBodyHash: patchedBodyHash,
            codecValueProvenance: transformed.codecValueProvenance,
            mediaVerified: transformed.mediaVerified,
            codecsDiffSummary: diffSummary,
            statusCode: headerPlan.statusCode,
            contentType: headerPlan.contentType,
            headerPlan: headerPlan,
            expiresAt: now.addingTimeInterval(effectiveResponseEditPreviewTTL),
            lastAccessAt: now
        ))
        return [
            "previewDigest": previewDigest,
            "sessionID": sessionID.uuidString,
            "captureSequence": captureSequence,
            "matcher": [
                "method": matcher.method,
                "scheme": matcher.scheme.rawValue,
                "host": matcher.host,
                "port": matcher.port as Any,
                "path": matcher.path,
                "matchMode": matcher.matchMode.rawValue
            ],
            "diff": diff,
            "originalBodyBytes": originalBody.count,
            "patchedBodyBytes": transformed.data.count,
            "codecValueProvenance": transformed.codecValueProvenance,
            "mediaVerified": transformed.mediaVerified,
            "unsupportedVariantCount": transformed.unsupportedVariantCount,
            "transformerVersion": HLSCODECSEditTransformer.transformerVersion,
            "captureFreshness": freshness,
            "responseHeaderPlan": headerPlan.disclosure,
            "matcherScope": matcherScopeDisclosure(matcher: matcher, evaluation: scopeEvaluation),
            "expiresAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(effectiveResponseEditPreviewTTL))
        ]
    }

    /// Compact CODECS attribute-only summary for propose `effectSummary` (no manifest body or URIs).
    private func compactCODECSDiffSummary(_ diff: [[String: Any]]) -> String {
        diff.map { entry in
            let old = entry["oldCodecs"] as? String ?? "none"
            let new = entry["newCodecs"] as? String ?? ""
            return "\(old)->\(new)"
        }.joined(separator: "; ")
    }

    /// True when the retained preview was produced by ``previewHLSCODECSEdit``.
    private func isHLSCODECSPreview(_ preview: ResponseEditPreviewRecord) -> Bool {
        preview.digest.hasPrefix("hls-codecs-preview-") || preview.codecValueProvenance != nil
    }

    private func decodeHLSCODECSEdits(_ value: Any?) throws -> [(variantRef: String, codecs: String)] {
        guard let raw = value as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            throw MCPStructuredError(code: .malformedRequest, message: "edits must be an array of {variantRef, codecs} objects.")
        }
        return try objects.map { object in
            guard let variantRef = object["variantRef"], !variantRef.isEmpty,
                  let codecs = object["codecs"] else {
                throw MCPStructuredError(code: .malformedRequest, message: "Each CODECS edit requires variantRef and codecs.")
            }
            return (variantRef, codecs)
        }
    }

    private func hlsMatcher(
        arguments: [String: Any],
        request: CapturedRequest
    ) throws -> MCPMutationMatcher {
        let mode = ResponseOverrideMatchMode(rawValue: arguments["matchMode"] as? String ?? ResponseOverrideMatchMode.ignoreQuery.rawValue)
            ?? .ignoreQuery
        let requestPath = request.path
        let path: String
        if mode == .pathSuffix {
            guard let suffix = arguments["path"] as? String, !suffix.isEmpty,
                  requestPath.hasSuffix(suffix.split(separator: "?", maxSplits: 1).first.map(String.init) ?? suffix) else {
                throw MCPStructuredError(code: .malformedRequest, message: "path must be a suffix of the captured manifest path.")
            }
            path = suffix
        } else if mode == .exactPath {
            path = requestPath
        } else {
            path = requestPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestPath
        }
        return MCPMutationMatcher(
            method: request.method.uppercased(),
            scheme: request.scheme,
            host: request.host.lowercased(),
            port: request.port,
            path: path,
            matchMode: mode
        )
    }

    private func hlsVariantReference(
        sessionID: SessionRecord.ID,
        captureSequence: UInt64,
        bodyDigest: String,
        locator: HLSCODECSVariantLocator
    ) -> String {
        let source = "\(sessionID.uuidString)|\(captureSequence)|\(bodyDigest)|\(locator.ordinal)|\(locator.streamInfoLineDigest)|\(locator.followingURIlineDigest)"
        return "hls-variant-\(sha256Hex(Data(source.utf8)).prefix(20))"
    }

    private func hlsFreshnessDisclosure(manifestText: String, capturedAt: Date) -> [String: Any] {
        let uriLines = manifestText.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let absoluteCount = uriLines.filter {
            $0.trimmingCharacters(in: .whitespaces).contains("://")
        }.count
        let queryCount = uriLines.filter {
            $0.trimmingCharacters(in: .whitespaces).contains("?")
        }.count
        let keyNames = uriLines
            .flatMap { line -> [String] in
                let lower = line.lowercased()
                return ["sid", "token", "auth", "signature", "sig"].filter { lower.contains($0) }
            }
        return [
            "capturedAt": ISO8601DateFormatter().string(from: capturedAt),
            "ageSeconds": max(0, Date().timeIntervalSince(capturedAt)),
            "appearsCacheable": !manifestText.contains("#EXT-X-SESSION-DATA"),
            "absoluteChildURICount": absoluteCount,
            "queryBearingChildURICount": queryCount,
            "sessionLikeQueryKeyIndicators": Array(Set(keyNames)).sorted(),
            "disclosureOnly": true
        ]
    }

    private func matches(matcher: MCPMutationMatcher, request: CapturedRequest) -> Bool {
        guard matcher.method.caseInsensitiveCompare(request.method) == .orderedSame,
              matcher.scheme == request.scheme,
              matcher.host.caseInsensitiveCompare(request.host) == .orderedSame else {
            return false
        }
        let requestPath = request.path
        let matcherPath = matcher.path
        let pathMatches: Bool
        switch matcher.matchMode {
        case .exactPath:
            pathMatches = requestPath == matcherPath
        case .ignoreQuery:
            pathMatches = requestPath.split(separator: "?", maxSplits: 1).first.map(String.init)
                == matcherPath.split(separator: "?", maxSplits: 1).first.map(String.init)
        case .pathPrefix:
            pathMatches = requestPath.hasPrefix(matcherPath)
        case .pathSuffix:
            pathMatches = requestPath.split(separator: "?", maxSplits: 1).first.map(String.init)?.hasSuffix(matcherPath) == true
        case .filename:
            let requestPathOnly = requestPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestPath
            pathMatches = lastPathComponent(of: requestPathOnly) == lastPathComponent(of: matcherPath)
        }
        guard pathMatches else { return false }
        if let requiredOperationName = matcher.graphQLOperationName {
            guard probeGraphQLOperationName(from: request) == requiredOperationName else { return false }
        }
        if let requiredQueryKey = matcher.matchQueryKey, let requiredQueryValue = matcher.matchQueryValue {
            guard requestQueryValue(for: requiredQueryKey, from: request) == requiredQueryValue else { return false }
        }
        return true
    }

    /// Extracts one named query-parameter's value from a request path, if present. Independent
    /// per-file copy of `ResponseOverrideStore`'s own helper — matches this codebase's existing
    /// convention of independent per-file matcher helpers (see the comment on
    /// `graphQLOperationNamesOverlap` below).
    private func requestQueryValue(for key: String, from request: CapturedRequest) -> String? {
        guard let components = URLComponents(string: request.path) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == key })?.value
    }

    private func lastPathComponent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func storeResponseEditPreview(_ preview: ResponseEditPreviewRecord) {
        purgeStaleResponseEditPreviews()
        responseEditPreviewsByDigest[preview.digest] = preview
        let maxEntries = effectiveResponseEditPreviewMaxEntries
        while responseEditPreviewsByDigest.count > maxEntries
            || responseEditPreviewsByDigest.values.reduce(0, { $0 + $1.patchedBody.count }) > Self.responseEditPreviewMaxAggregateBytes {
            let candidates = responseEditPreviewsByDigest.filter { $0.key != preview.digest }
            let oldest = candidates.min(by: {
                if $0.value.lastAccessAt != $1.value.lastAccessAt {
                    return $0.value.lastAccessAt < $1.value.lastAccessAt
                }
                return $0.key < $1.key
            }) ?? responseEditPreviewsByDigest.min(by: {
                $0.value.lastAccessAt < $1.value.lastAccessAt
            })
            guard let oldest else { break }
            responseEditPreviewsByDigest.removeValue(forKey: oldest.key)
            if oldest.key == preview.digest { break }
        }
    }

    /// Drops TTL-expired previews and entries invalidated by capture epoch, policy revision, or missing source session.
    private func purgeStaleResponseEditPreviews() {
        let now = Date()
        let epoch = snapshotService?.captureEpoch
        let policy = policyStore.policyRevision
        responseEditPreviewsByDigest = responseEditPreviewsByDigest.filter { _, preview in
            guard preview.expiresAt > now else { return false }
            if let epoch, preview.captureEpoch != epoch { return false }
            if preview.policyRevision != policy { return false }
            if let snapshotService, snapshotService.indexedSession(id: preview.sessionID) == nil {
                return false
            }
            return true
        }
    }

    /// Test seam: number of retained response-edit / HLS CODECS preview digests after purge.
    func testing_responseEditPreviewCount() -> Int {
        purgeStaleResponseEditPreviews()
        return responseEditPreviewsByDigest.count
    }

    /// Test seam: whether a digest is currently retained.
    func testing_hasResponseEditPreview(digest: String) -> Bool {
        purgeStaleResponseEditPreviews()
        return responseEditPreviewsByDigest[digest] != nil
    }

    /// Removes a retained preview after draft commit or Map Local binding.
    func consumeResponseEditPreview(digest: String) {
        responseEditPreviewsByDigest.removeValue(forKey: digest)
    }

    /// Generic capture-only response edit preview (exactText / matchRef). HLS CODECS remains available
    /// via ``previewHLSCODECSEdit`` and both share ``responseEditPreviewsByDigest``.
    private func previewResponseEdit(
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .transformationPreview)
        guard let snapshotService,
              let sessionIDString = arguments["sessionID"] as? String,
              let sessionID = UUID(uuidString: sessionIDString),
              let indexed = snapshotService.indexedSession(id: sessionID),
              let response = indexed.record.response,
              let rawBody = response.bodyData else {
            throw MCPStructuredError(code: .malformedRequest, message: "A captured response body is required.")
        }
        guard let decoded = CapturedBodyDecoder.decode(
            bodyData: rawBody,
            headers: response.headers,
            maxDecodedBytes: Self.responseEditPreviewMaxBodyBytes
        ), decoded.canUseAnalysisDataForInspection,
        let originalBody = decoded.analysisUTF8Text().map({ Data($0.utf8) }),
        originalBody.count <= Self.responseEditPreviewMaxBodyBytes else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "The captured response body is unavailable, encoded with an unsupported coding, or too large."
            )
        }

        let edits = try decodeResponseEditSpecs(arguments["edits"])
        guard !edits.isEmpty, edits.count <= 100 else {
            throw MCPStructuredError(code: .malformedRequest, message: "edits must contain between 1 and 100 items.")
        }

        var patches: [ResolvedPatch] = []
        var diff: [[String: Any]] = []
        let mcpSessionID = arguments["__mcpInternalSessionID"] as? String
        for edit in edits {
            switch edit.kind {
            case .exactText(let find, let expectedOccurrences, let operation, let replacement):
                do {
                    let resolved = try ResponseEditSelectorResolver.resolveExactText(
                        originalBytes: originalBody,
                        find: Data(find.utf8),
                        expectedOccurrences: expectedOccurrences,
                        operation: operation,
                        replacement: Data(replacement.utf8)
                    )
                    patches.append(contentsOf: resolved)
                    diff.append([
                        "kind": "exactText",
                        "findByteCount": Data(find.utf8).count,
                        "expectedOccurrences": expectedOccurrences,
                        "operation": operation.rawValue,
                        "replacementByteCount": Data(replacement.utf8).count
                    ])
                } catch let error as ResponseEditSelectorResolver.SelectorError {
                    throw structuredSelectorError(error)
                }
            case .matchRef(let matchRefs, let operation, let replacement):
                guard let responseEditService else {
                    throw MCPStructuredError(
                        code: .internalFailure,
                        message: "matchRef selectors require the response-edit service."
                    )
                }
                var ranges: [Range<Int>] = []
                for ref in matchRefs {
                    let resolved = try responseEditService.resolvedMatchRef(
                        ref,
                        client: client,
                        mcpSessionID: mcpSessionID
                    )
                    guard resolved.sessionID == sessionID else {
                        throw MCPStructuredError(
                            code: .staleProposal,
                            message: "A matchRef belongs to a different captured session."
                        )
                    }
                    ranges.append(resolved.byteRange)
                }
                do {
                    let resolved = try ResponseEditSelectorResolver.resolveMatchRefs(
                        originalBytes: originalBody,
                        ranges: ranges,
                        operation: operation,
                        replacement: Data(replacement.utf8)
                    )
                    patches.append(contentsOf: resolved)
                    diff.append([
                        "kind": "matchRef",
                        "matchRefCount": matchRefs.count,
                        "operation": operation.rawValue,
                        "replacementByteCount": Data(replacement.utf8).count
                    ])
                } catch let error as ResponseEditSelectorResolver.SelectorError {
                    throw structuredSelectorError(error)
                }
            case .adapter:
                throw MCPStructuredError(
                    code: .malformedRequest,
                    message: "Adapter selectors are available via preview_hls_codecs_edit in this slice; mixed adapter batches land with G3 follow-up."
                )
            }
        }

        let patched: BoundedBytePatchEngine.Result
        do {
            patched = try BoundedBytePatchEngine.apply(originalBytes: originalBody, patches: patches)
        } catch {
            throw MCPStructuredError(code: .malformedRequest, message: "The resolved patches could not be applied.")
        }

        let matcher = try hlsMatcher(arguments: arguments, request: indexed.record.request)
        let scopeEvaluation = await evaluateMatcherScopeConflicts(matcher: matcher, excludingRuleID: nil)
        let headerPlan = ResponseHeaderPolicyPlan.planForEditedDecodedBody(
            statusCode: response.statusCode,
            contentType: response.headers.first(where: {
                $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
            })?.value,
            capturedHeaders: response.headers
        )
        let bodyDigest = sha256Hex(originalBody)
        let digest = sha256Hex(Data(
            "\(sessionID.uuidString)|\(indexed.captureSequence)|\(bodyDigest)|\(patched.patchedSHA256)|\(matcher.path)|\(matcher.matchMode.rawValue)|\(diff)"
                .utf8
        ))
        let previewDigest = "response-edit-preview-\(digest.prefix(20))"
        let now = Date()
        storeResponseEditPreview(ResponseEditPreviewRecord(
            digest: previewDigest,
            clientID: client.id,
            mcpSessionID: mcpSessionID,
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyStore.policyRevision,
            sessionID: sessionID,
            matcher: matcher,
            patchedBody: patched.data,
            transformedBodyHash: patched.patchedSHA256,
            codecValueProvenance: nil,
            mediaVerified: nil,
            codecsDiffSummary: nil,
            statusCode: headerPlan.statusCode,
            contentType: headerPlan.contentType,
            headerPlan: headerPlan,
            expiresAt: now.addingTimeInterval(effectiveResponseEditPreviewTTL),
            lastAccessAt: now
        ))
        return [
            "previewDigest": previewDigest,
            "responseEditPreviewDigest": previewDigest,
            "sessionID": sessionID.uuidString,
            "captureSequence": indexed.captureSequence,
            "diff": diff,
            "originalBodyBytes": originalBody.count,
            "patchedBodyBytes": patched.data.count,
            "originalBodySHA256": patched.originalSHA256,
            "patchedBodySHA256": patched.patchedSHA256,
            "contentTrust": "metadata_only",
            "responseHeaderPlan": headerPlan.disclosure,
            "matcherScope": matcherScopeDisclosure(matcher: matcher, evaluation: scopeEvaluation),
            "expiresAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(effectiveResponseEditPreviewTTL))
        ]
    }

    private struct ResponseEditSpec {
        enum Kind {
            case exactText(
                find: String,
                expectedOccurrences: Int,
                operation: ResponseEditSelectorResolver.OperationKind,
                replacement: String
            )
            case matchRef(
                matchRefs: [String],
                operation: ResponseEditSelectorResolver.OperationKind,
                replacement: String
            )
            case adapter
        }

        let kind: Kind
    }

    /// G6-03: shown inline in malformed-shape errors below — this is the first thing a new agent
    /// session is likely to get wrong, since a flatter, illustrative shape appears in early design
    /// docs but was never the actual accepted schema (see `Live-NOBLENDER-Audit-2026-08-05.md`).
    private static let exactTextEditExample = """
        {"selector": {"kind": "exactText", "find": "...", "expectedOccurrences": N}, \
        "operation": {"kind": "replace", "text": "..."}}
        """

    private func decodeResponseEditSpecs(_ value: Any?) throws -> [ResponseEditSpec] {
        guard let raw = value as? [[String: Any]] else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "edits must be an array of edit objects, e.g. [\(Self.exactTextEditExample)]."
            )
        }
        return try raw.map { object in
            guard let selector = object["selector"] as? [String: Any],
                  let kind = selector["kind"] as? String else {
                throw MCPStructuredError(
                    code: .malformedRequest,
                    message: "Each edit requires selector.kind. Example: \(Self.exactTextEditExample)"
                )
            }
            let operationObject = object["operation"] as? [String: Any] ?? [:]
            let operationKindRaw = operationObject["kind"] as? String ?? "replace"
            guard let operation = ResponseEditSelectorResolver.OperationKind(rawValue: operationKindRaw) else {
                throw MCPStructuredError(code: .malformedRequest, message: "Unsupported operation kind.")
            }
            let replacement = operationObject["text"] as? String ?? ""
            switch kind {
            case "exactText":
                guard let find = selector["find"] as? String,
                      let expected = selector["expectedOccurrences"] as? Int else {
                    throw MCPStructuredError(
                        code: .malformedRequest,
                        message: "exactText selectors require find and expectedOccurrences. Example: \(Self.exactTextEditExample)"
                    )
                }
                return ResponseEditSpec(
                    kind: .exactText(
                        find: find,
                        expectedOccurrences: expected,
                        operation: operation,
                        replacement: replacement
                    )
                )
            case "matchRef":
                let refs = selector["matchRefs"] as? [String]
                    ?? (selector["matchRef"] as? String).map { [$0] }
                    ?? []
                guard !refs.isEmpty else {
                    throw MCPStructuredError(code: .malformedRequest, message: "matchRef selectors require matchRefs.")
                }
                return ResponseEditSpec(
                    kind: .matchRef(matchRefs: refs, operation: operation, replacement: replacement)
                )
            case "adapter":
                return ResponseEditSpec(kind: .adapter)
            default:
                throw MCPStructuredError(code: .malformedRequest, message: "Unknown selector kind '\(kind)'.")
            }
        }
    }

    private func structuredSelectorError(_ error: ResponseEditSelectorResolver.SelectorError) -> MCPStructuredError {
        switch error {
        case .occurrenceMismatch(let expected, let actual):
            return MCPStructuredError(
                code: .malformedRequest,
                message: "exactText expectedOccurrences=\(expected) but found \(actual)."
            )
        case .findTooShort:
            return MCPStructuredError(code: .malformedRequest, message: "find must be at least 3 UTF-8 bytes.")
        case .findTooLong, .replacementTooLong:
            return MCPStructuredError(code: .malformedRequest, message: "find/replacement exceeds the 4 KiB bound.")
        case .emptyEdits, .emptyMatchRefSet:
            return MCPStructuredError(code: .malformedRequest, message: "edits must be non-empty.")
        case .excessiveEdits:
            return MCPStructuredError(code: .malformedRequest, message: "edits must contain between 1 and 100 items.")
        case .overlappingResolvedRanges:
            return MCPStructuredError(code: .malformedRequest, message: "Resolved edit ranges overlap.")
        case .unsupportedOperation(let name):
            return MCPStructuredError(code: .malformedRequest, message: "Unsupported operation '\(name)'.")
        case .missingExpectedOccurrences:
            return MCPStructuredError(code: .malformedRequest, message: "expectedOccurrences is required.")
        }
    }

    private func discoverResponseStructure(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .structuralDiscovery)
        guard let snapshotService else {
            throw MCPStructuredError(code: .internalFailure, message: "Structural discovery is unavailable in this server configuration.")
        }
        let sessionIDStrings = arguments["sessionIDs"] as? [String] ?? []
        guard !sessionIDStrings.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "sessionIDs is required and must be non-empty.")
        }
        let bodies = sessionIDStrings.prefix(Self.maxDiscoverySampleCount).compactMap { idString -> Data? in
            guard let id = UUID(uuidString: idString) else { return nil }
            return snapshotService.indexedSession(id: id)?.record.response?.bodyData
        }
        guard !bodies.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "No matching session response bodies found for sessionIDs.")
        }
        let profile = JSONStructuralProfiler.profile(bodies: bodies)
        let dto = MCPStructuralProfileDTO(
            status: String(describing: profile.status),
            shapeDescription: profile.shape.map { Self.sanitizedDescription(of: $0, profileID: client.assignedProfileID) },
            sampleCount: profile.sampleCount,
            schemaFingerprint: profile.schemaFingerprint?.rawValue
        )
        return try payloadDictionary(dto)
    }

    private func previewLiveRewrite(arguments: [String: Any], client: MCPClientRecord) throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .transformationPreview)
        guard let snapshotService else {
            throw MCPStructuredError(code: .internalFailure, message: "Capture-only preview is unavailable in this server configuration.")
        }
        let matcher = try MCPMutationValidator.parseMatcher(from: arguments)
        guard let jsonPath = arguments["jsonPath"] as? String else {
            throw MCPMutationValidationError.malformedRequest("jsonPath is required.")
        }
        let operation = try MCPMutationValidator.parseRewriteOperation(from: arguments)
        try MCPMutationValidator.validateRewriteLocator(jsonPath: jsonPath, operation: operation)
        let repeatPolicy = try MCPMutationValidator.parseRewriteRepeatPolicy(from: arguments)
        let overrideValue = try MCPMutationValidator.parseRewriteOverrideValue(operation: operation, from: arguments)

        let sessionIDStrings = arguments["sessionIDs"] as? [String] ?? []
        guard !sessionIDStrings.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "sessionIDs is required and must be non-empty.")
        }
        let sessions = sessionIDStrings.prefix(Self.maxDiscoverySampleCount).compactMap { idString -> MCPSessionSnapshotService.IndexedSession? in
            guard let id = UUID(uuidString: idString) else { return nil }
            return snapshotService.indexedSession(id: id)
        }
        guard !sessions.isEmpty else {
            throw MCPStructuredError(code: .malformedRequest, message: "No matching sessions found for sessionIDs.")
        }

        let mutation = JSONResponseMutation(
            locator: jsonPath,
            operation: operation,
            value: overrideValue,
            repeatPolicy: repeatPolicy
        )

        var eligibleCount = 0
        var ineligibleCount = 0
        var transformedCount = 0
        var firstSampledBody: Data?
        var originalBytes = 0
        var transformedBytes = 0
        var selectorMatchedCount = 0
        var selectorSkippedCount = 0
        var selectorFailureCount = 0

        for session in sessions {
            guard let response = session.record.response, let bodyData = response.bodyData else {
                ineligibleCount += 1
                continue
            }
            if firstSampledBody == nil {
                firstSampledBody = bodyData
            }
            let result = LiveResponseTransformation.transform(
                requestMethod: session.record.request.method,
                statusCode: response.statusCode,
                headers: response.headers,
                bodyData: bodyData,
                mutations: [mutation]
            )
            if result.eligibilityReason != nil {
                ineligibleCount += 1
                continue
            }
            eligibleCount += 1
            originalBytes += result.originalBodyByteCount
            transformedBytes += result.bodyData.count
            if let outcome = result.mutationOutcomes[mutation.id] {
                switch outcome {
                case .applied:
                    selectorMatchedCount += 1
                case .wildcardMatchedNothing, .parentMissing:
                    selectorSkippedCount += 1
                case .invalidLocator, .wrongContainerType, .indexOutOfRange,
                     .unsupportedResponse, .bodyTooLarge, .typeMismatch:
                    selectorFailureCount += 1
                }
            }
            if result.wasTransformed {
                transformedCount += 1
            }
        }

        let profile = firstSampledBody.map { JSONStructuralProfiler.profile(bodyData: $0) }
        let sanitizedExample: String? = transformedCount > 0
            ? "\(jsonPath) \(operation.title.lowercased()) \(overrideValue.disclosureDescriptor) — \(transformedCount) of \(eligibleCount) eligible response(s) would change."
            : nil
        let ruleDigest = MCPTransformationPreviewDigest.compute(
            matcher: matcher,
            jsonPath: jsonPath,
            operation: operation,
            overrideValue: overrideValue,
            repeatPolicy: repeatPolicy
        )
        let now = Date()
        let expiresAt = now.addingTimeInterval(MCPApprovalPolicy.defaultLifetime)
        let sampledSessionIDs = sessions.map(\.record.id)
        let mcpSessionID = arguments["__mcpInternalSessionID"] as? String
        let digestBinding: [String: Any] = [
            "ruleDigest": ruleDigest,
            "clientID": client.id,
            "mcpSessionID": mcpSessionID ?? "",
            "sessionIDs": sampledSessionIDs.map(\.uuidString),
            "captureEpoch": snapshotService.captureEpoch.rawValue,
            "policyRevision": policyStore.policyRevision.rawValue,
            "highWaterSequence": snapshotService.highWaterSequence,
            "expiresAt": ISO8601DateFormatter().string(from: expiresAt)
        ]
        let digest = "preview-\(MCPArgumentDigest.normalized(digestBinding).prefix(24))"
        liveRewritePreviewsByDigest = liveRewritePreviewsByDigest.filter { now < $0.value.expiresAt }
        liveRewritePreviewsByDigest[digest] = LiveRewritePreviewRecord(
            digest: digest,
            clientID: client.id,
            mcpSessionID: mcpSessionID,
            ruleDigest: ruleDigest,
            sampledSessionIDs: sampledSessionIDs,
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyStore.policyRevision,
            sampledHighWaterSequence: snapshotService.highWaterSequence,
            expiresAt: expiresAt
        )
        var previewWarnings: [String] = []
        if sessionIDStrings.count > Self.maxDiscoverySampleCount {
            previewWarnings.append("Preview sampled the first \(Self.maxDiscoverySampleCount) requested sessions.")
        }
        let byteGrowth = transformedBytes - originalBytes
        if byteGrowth > LiveTransformationExecutionBudget.maxOutputGrowthBytes {
            previewWarnings.append("Aggregate sampled byte growth exceeds the per-response live transformation budget.")
        }
        let dto = MCPTransformationPreviewResultDTO(
            eligibleCount: eligibleCount,
            ineligibleCount: ineligibleCount,
            transformedCount: transformedCount,
            zeroMatches: transformedCount == 0,
            schemaFingerprint: profile?.schemaFingerprint?.rawValue,
            sanitizedExample: sanitizedExample,
            selectorResults: [
                .init(
                    selector: jsonPath,
                    matchedCount: selectorMatchedCount,
                    changedCount: transformedCount,
                    skippedCount: selectorSkippedCount,
                    failureCount: selectorFailureCount
                )
            ],
            originalBytes: originalBytes,
            transformedBytes: transformedBytes,
            byteGrowth: byteGrowth,
            warnings: previewWarnings,
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyStore.policyRevision,
            sampledHighWaterSequence: snapshotService.highWaterSequence,
            expiresAt: expiresAt,
            previewDigest: digest
        )
        return try payloadDictionary(dto)
    }

    /// Renders a `JSONShape` as a compact structural summary, redacting object-key names that
    /// `SensitiveDataRedaction` classifies as sensitive/user-identifying — the profiler itself stays
    /// policy-agnostic (see `JSONStructuralProfiler`'s doc comment), so this gating happens here at
    /// the MCP serialization boundary instead. `profileID` is accepted for parity with every other
    /// disclosure-boundary function even though redaction is currently unconditional (matches the
    /// locked-in decision that discovery is `.shareable`-only — there is no lower profile tier that
    /// would see MORE than this).
    private static func sanitizedDescription(of shape: JSONShape, profileID: MCPDisclosureProfileID) -> String {
        switch shape {
        case .string:
            return "string"
        case .number:
            return "number"
        case .bool:
            return "bool"
        case .null:
            return "null"
        case .object(let properties):
            let parts = properties.keys.sorted().map { key -> String in
                let displayKey = (SensitiveDataRedaction.isSensitiveKey(key) || SensitiveDataRedaction.isUserIdentifierKey(key))
                    ? "<redacted>"
                    : key
                return "\(displayKey): \(sanitizedDescription(of: properties[key]!, profileID: profileID))"
            }
            return "{\(parts.joined(separator: ", "))}"
        case .array(let elementShape, let minCount, let maxCount):
            let elementDescription = elementShape.map { sanitizedDescription(of: $0, profileID: profileID) } ?? "empty"
            return "[\(elementDescription)] (count \(minCount)...\(maxCount))"
        case .mixed(let alternatives):
            let parts = alternatives.map { sanitizedDescription(of: $0, profileID: profileID) }
            return "mixed(\(parts.joined(separator: " | ")))"
        }
    }

    // MARK: - Block

    private func proposeCreateBlock(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledBlock)
        let matcher = try MCPMutationValidator.parseMatcher(from: arguments)
        let statusCode = arguments["statusCode"] as? Int ?? 403
        try MCPMutationValidator.validateBlockStatusCode(statusCode)
        let label = arguments["label"] as? String
        let dropConnection = arguments["dropConnection"] as? Bool ?? false
        let proposedID = UUID()
        let effectSummary = dropConnection
            ? "Create disabled block rule (drop connection) for \(matcher.method) \(matcher.host)\(matcher.path)."
            : "Create disabled block rule for \(matcher.method) \(matcher.host)\(matcher.path)."
        let plan = MCPMutationPlan(
            capability: .createDisabledBlock,
            matcher: matcher,
            proposedTargetID: proposedID,
            effectKind: .block,
            effectSummary: effectSummary,
            blockStatusCode: statusCode,
            blockDropConnection: dropConnection,
            rewriteLabel: label
        )
        return try await propose(plan: plan, client: client, arguments: arguments)
    }

    private func applyCreateBlock(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledBlock)
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .createDisabledBlock, client: client)
        try resolveMutationApproval(toolName: "apply_create_block", arguments: arguments, client: client, capability: .createDisabledBlock)
        guard let matcher = plan.matcher, let statusCode = plan.blockStatusCode else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        let provenance = makeProvenance(clientID: client.id, capability: .createDisabledBlock)
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .createDisabledBlock,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: proposal.targetRevision,
            mutationIntent: mutationIntent(for: plan, clientID: client.id, digest: proposal.argumentDigest),
            performMutation: {
                try await self.persistBlockRule(
                    id: plan.proposedTargetID,
                    matcher: matcher,
                    statusCode: statusCode,
                    label: plan.rewriteLabel,
                    provenance: provenance,
                    dropConnection: plan.blockDropConnection
                )
                // No rollback snapshot is attached for a fresh create (nothing to revert to), so
                // `MCPRecoveryRestorer.restore` never consults this target's revision — nil is correct.
                return nil
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        recordApplied(client: client, capability: .createDisabledBlock, targetID: plan.proposedTargetID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: plan.proposedTargetID.uuidString, isEnabled: false))
    }

    func finalizeApply(proposalToken: String, idempotencyKey: MCPIdempotencyKey?) {
        if idempotencyKey == nil {
            plansByProposalToken.removeValue(forKey: proposalToken)
        }
    }

    // MARK: - Map Local

    private func proposeCreateMapLocal(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledMapLocal)
        if let bookmarkRef = arguments["localDirectoryBookmarkRef"] as? String {
            guard arguments["fixtureRunID"] == nil,
                  arguments["responseEditPreviewDigest"] == nil,
                  arguments["hlsPreviewDigest"] == nil,
                  arguments["responseRevisionID"] == nil,
                  !arguments.keys.contains("bodyText") else {
                throw MCPStructuredError(
                    code: .malformedRequest,
                    message: "localDirectoryBookmarkRef cannot be combined with fixtureRunID, bodyText, preview digests, or responseRevisionID."
                )
            }
            return try await proposeCreateLocalDirectoryMapLocal(bookmarkRef: bookmarkRef, arguments: arguments, client: client)
        }
        if let bookmarkRef = arguments["localFileBookmarkRef"] as? String {
            guard arguments["fixtureRunID"] == nil,
                  arguments["responseEditPreviewDigest"] == nil,
                  arguments["hlsPreviewDigest"] == nil,
                  arguments["responseRevisionID"] == nil,
                  !arguments.keys.contains("bodyText") else {
                throw MCPStructuredError(
                    code: .malformedRequest,
                    message: "localFileBookmarkRef cannot be combined with fixtureRunID, bodyText, preview digests, or responseRevisionID."
                )
            }
            return try await proposeCreateSingleFileMapLocal(bookmarkRef: bookmarkRef, arguments: arguments, client: client)
        }
        if let fixtureRunIDString = arguments["fixtureRunID"] as? String {
            guard arguments["responseEditPreviewDigest"] == nil,
                  arguments["hlsPreviewDigest"] == nil,
                  arguments["responseRevisionID"] == nil else {
                throw MCPStructuredError(
                    code: .malformedRequest,
                    message: "fixtureRunID cannot be combined with responseEditPreviewDigest/hlsPreviewDigest/responseRevisionID."
                )
            }
            return try await proposeCreateFixtureRunMapLocal(fixtureRunIDString: fixtureRunIDString, arguments: arguments, client: client)
        }
        let preview = try resolvedResponseEditPreviewIfRequested(arguments: arguments, client: client)
        let revisionBinding = try resolvedResponseRevisionIfRequested(arguments: arguments, client: client)
        if preview != nil, revisionBinding != nil {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "Supply either responseEditPreviewDigest/hlsPreviewDigest or responseRevisionID, not both."
            )
        }
        var matcher: MCPMutationMatcher
        let bodyData: Data
        let statusCode: Int
        let contentType: String
        if let preview {
            guard !arguments.keys.contains("bodyText"),
                  !arguments.keys.contains("statusCode"),
                  !arguments.keys.contains("contentType"),
                  !arguments.keys.contains("graphqlOperationName"),
                  !arguments.keys.contains("matchQueryKey"),
                  !arguments.keys.contains("matchQueryValue") else {
                let digestKey = arguments["responseEditPreviewDigest"] != nil
                    ? "responseEditPreviewDigest"
                    : "hlsPreviewDigest"
                throw MCPStructuredError(
                    code: .malformedRequest,
                    message: "bodyText, statusCode, contentType, graphqlOperationName, and matchQueryKey/matchQueryValue cannot be supplied with \(digestKey)."
                )
            }
            matcher = preview.matcher
            // Keep the server-retained preview bytes authoritative — do not round-trip through String.
            bodyData = preview.patchedBody
            statusCode = preview.statusCode
            contentType = preview.contentType
        } else if let revisionBinding {
            guard !arguments.keys.contains("bodyText"),
                  !arguments.keys.contains("statusCode"),
                  !arguments.keys.contains("contentType"),
                  !arguments.keys.contains("graphqlOperationName"),
                  !arguments.keys.contains("matchQueryKey"),
                  !arguments.keys.contains("matchQueryValue") else {
                throw MCPStructuredError(
                    code: .malformedRequest,
                    message: "bodyText, statusCode, contentType, graphqlOperationName, and matchQueryKey/matchQueryValue cannot be supplied with responseRevisionID."
                )
            }
            matcher = revisionBinding.draft.matcher
            bodyData = revisionBinding.revision.bodyData
            statusCode = revisionBinding.revision.statusCode
            contentType = revisionBinding.revision.contentType
        } else {
            matcher = try MCPMutationValidator.parseMatcher(from: arguments)
            let bodyText = arguments["bodyText"] as? String ?? ""
            try MCPMutationValidator.validateInlineBody(bodyText)
            guard let encoded = bodyText.data(using: .utf8) else {
                throw MCPStructuredError(code: .malformedRequest, message: "bodyText must be valid UTF-8.")
            }
            bodyData = encoded
            statusCode = arguments["statusCode"] as? Int ?? 200
            contentType = arguments["contentType"] as? String ?? "text/plain; charset=utf-8"
        }
        if preview != nil || revisionBinding != nil {
            matcher.sourceClientAddress = try MCPMutationValidator.parseSourceClientAddress(from: arguments)
        }
        if arguments["allowDuplicateScope"] as? Bool != true,
           let conflict = await exactScopeMapLocalConflict(matcher: matcher, proposedBodyData: bodyData) {
            let existingID = conflict.ruleID
            let message: String
            if conflict.bodyIdentical {
                // G6-02 option 2: same scope AND same bytes — this isn't just an overlapping rule,
                // it's the literal same edit already existing. Point at it instead of making the
                // caller re-derive that on their own.
                message = "An identical Map Local rule (\(existingID)) already exists for this exact "
                    + "scope and serves the exact same content. No new rule is needed — run "
                    + "`rule enable \(existingID)` if it isn't already enabled, or pass "
                    + "allowDuplicateScope: true to create a redundant duplicate anyway."
            } else {
                message = "An existing Map Local rule (\(existingID)) already covers this exact scope "
                    + "(\(matcher.method) \(matcher.scheme.rawValue)://\(matcher.host)\(matcher.path), "
                    + "\(matcher.matchMode.rawValue)) but serves different content. Use `rule enable "
                    + "\(existingID)` if you meant to reuse it, or pass allowDuplicateScope: true to "
                    + "create a duplicate anyway."
            }
            throw MCPStructuredError(
                code: .malformedRequest,
                message: message,
                details: ["existingRuleID": existingID, "bodyIdentical": conflict.bodyIdentical ? "true" : "false"]
            )
        }
        let proposedID = UUID()
        let effectSummary: String
        if let preview {
            if isHLSCODECSPreview(preview) {
                let diffPart = preview.codecsDiffSummary.map { " \($0)" } ?? ""
                effectSummary = "Create disabled Map Local rule from validated CODECS-only edit \(preview.digest).\(diffPart)"
            } else {
                effectSummary = "Create disabled Map Local rule from validated response-edit preview \(preview.digest)."
            }
        } else if let revisionBinding {
            effectSummary = "Create disabled Map Local rule from response draft revision \(revisionBinding.revision.id.uuidString)."
        } else {
            effectSummary = "Create disabled map-local rule for \(matcher.method) \(matcher.host)\(matcher.path)."
        }
        let plan = MCPMutationPlan(
            capability: .createDisabledMapLocal,
            matcher: matcher,
            proposedTargetID: proposedID,
            effectKind: .mapLocal,
            effectSummary: effectSummary,
            inlineBodyData: bodyData,
            inlineContentType: contentType,
            inlineStatusCode: statusCode,
            rewriteLabel: arguments["label"] as? String,
            draftPreviewDigest: preview?.digest,
            responseRevisionID: revisionBinding?.revision.id,
            forceNoCache: arguments["forceNoCache"] as? Bool ?? false
        )
        // Proactive match-scope disclosure at the point the rule's own matcher (not the edit
        // preview's) is actually decided — this is where `pathSuffix`/directory-prefix scope
        // mistakes are made, not inside the earlier edit-preview step, so it belongs here even
        // though `preview_response_edit`/`preview_hls_codecs_edit` already surface their own.
        let scopeEvaluation = await evaluateMatcherScopeConflicts(matcher: matcher, excludingRuleID: nil)
        var result = try await propose(plan: plan, client: client, arguments: arguments)
        result.merge(matcherScopeDisclosure(matcher: matcher, evaluation: scopeEvaluation), uniquingKeysWith: { current, _ in current })
        if let preview {
            // Consume after successful propose so the proposal owns the bytes independently of cache TTL.
            consumeResponseEditPreview(digest: preview.digest)
            result.merge(mapLocalPreviewDisclosure(preview), uniquingKeysWith: { current, _ in current })
        }
        return result
    }

    /// Safe propose-time fields for a retained response-edit / HLS CODECS preview.
    /// Never includes patched or original body text, child URIs, or query values.
    private func mapLocalPreviewDisclosure(_ preview: ResponseEditPreviewRecord) -> [String: Any] {
        var disclosure: [String: Any] = [
            "previewDigest": preview.digest,
            "transformedBodyHash": preview.transformedBodyHash,
            "statusCode": preview.statusCode,
            "contentType": preview.contentType,
            "matcher": [
                "method": preview.matcher.method,
                "scheme": preview.matcher.scheme.rawValue,
                "host": preview.matcher.host,
                "port": preview.matcher.port as Any,
                "path": preview.matcher.path,
                "matchMode": preview.matcher.matchMode.rawValue
            ]
        ]
        if isHLSCODECSPreview(preview) {
            disclosure["codecValueProvenance"] = preview.codecValueProvenance ?? "user_supplied"
            disclosure["mediaVerified"] = preview.mediaVerified ?? false
            if let codecsDiffSummary = preview.codecsDiffSummary {
                disclosure["codecsDiffSummary"] = codecsDiffSummary
            }
        }
        return disclosure
    }

    /// Proposes a `.localDirectory` Map Local rule that serves a user-chosen folder under a
    /// path-prefix matcher (ADR-Map-Local-Directory-Mocking.md capability 1 / AS). MCP receives only
    /// an opaque `localDirectoryBookmarkRef` (base64 bookmark) — never a raw path. Plain (not
    /// security-scoped): JoesProxy is not sandboxed (no `com.apple.security.app-sandbox`
    /// entitlement), and a security-scoped bookmark minted by the separate `joesproxyctl` process
    /// failed to resolve here across that process boundary — confirmed live 2026-08-10.
    private func proposeCreateLocalDirectoryMapLocal(
        bookmarkRef: String,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        guard !arguments.keys.contains("bodyText"),
              !arguments.keys.contains("statusCode"),
              !arguments.keys.contains("contentType") else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "bodyText, statusCode, and contentType cannot be supplied with localDirectoryBookmarkRef."
            )
        }
        guard let bookmarkData = Data(base64Encoded: bookmarkRef), !bookmarkData.isEmpty else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "localDirectoryBookmarkRef must be base64-encoded bookmark data."
            )
        }
        var isStale = false
        let directoryURL: URL
        do {
            directoryURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "localDirectoryBookmarkRef could not be resolved: \(error.localizedDescription)"
            )
        }
        let didAccess = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { directoryURL.stopAccessingSecurityScopedResource() }
        }
        var isDirectory = false
        if let values = try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]) {
            isDirectory = values.isDirectory == true
        }
        guard isDirectory else {
            throw MCPStructuredError(code: .malformedRequest, message: "localDirectoryBookmarkRef must point at a directory.")
        }
        let matcher = try MCPMutationValidator.parseMatcher(from: arguments)
        guard matcher.matchMode == .pathPrefix else {
            throw MCPStructuredError(code: .malformedRequest, message: "localDirectoryBookmarkRef requires matchMode: pathPrefix.")
        }
        let notFound = (arguments["notFoundRelativePath"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let missingFilePolicy = try Self.parseMissingFilePolicy(
            arguments: arguments,
            notFoundRelativePath: (notFound?.isEmpty == false) ? notFound : nil
        )
        let proposedID = UUID()
        let folderName = directoryURL.lastPathComponent
        let plan = MCPMutationPlan(
            capability: .createDisabledMapLocal,
            matcher: matcher,
            proposedTargetID: proposedID,
            effectKind: .mapLocal,
            effectSummary: "Create disabled Map Local directory rule for \(matcher.method) \(matcher.host)\(matcher.path) → folder \(folderName).",
            rewriteLabel: arguments["label"] as? String,
            localDirectoryBookmarkData: bookmarkData,
            notFoundRelativePath: (notFound?.isEmpty == false) ? notFound : nil,
            missingFilePolicy: missingFilePolicy,
            forceNoCache: arguments["forceNoCache"] as? Bool ?? false
        )
        // See the identical comment in `proposeCreateMapLocal` — directory Map Local is exactly
        // the pathPrefix-scope case the field session hit, so this disclosure matters here too.
        let scopeEvaluation = await evaluateMatcherScopeConflicts(matcher: matcher, excludingRuleID: nil)
        var result = try await propose(plan: plan, client: client, arguments: arguments)
        result.merge(matcherScopeDisclosure(matcher: matcher, evaluation: scopeEvaluation), uniquingKeysWith: { current, _ in current })
        result.merge(
            missingLocalSiblingsDisclosure(matcher: matcher, directoryURL: directoryURL),
            uniquingKeysWith: { current, _ in current }
        )
        return result
    }

    /// Validates `missingFilePolicy` (default `.strictLocal`) and enforces that `.configuredFallback`
    /// actually has a `notFoundRelativePath` to fall back to — without it, "configured fallback"
    /// has nothing configured, which is more likely a caller mistake than an intentional bare-404.
    private static func parseMissingFilePolicy(
        arguments: [String: Any],
        notFoundRelativePath: String?
    ) throws -> LocalDirectoryMissingFilePolicy {
        guard let raw = arguments["missingFilePolicy"] as? String else {
            return .strictLocal
        }
        guard let policy = LocalDirectoryMissingFilePolicy(rawValue: raw) else {
            throw MCPStructuredError.invalidEnumValue(
                field: "missingFilePolicy",
                provided: raw,
                validValues: LocalDirectoryMissingFilePolicy.allCases.map(\.rawValue)
            )
        }
        if policy == .configuredFallback, notFoundRelativePath == nil {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "missingFilePolicy: configuredFallback requires a non-empty notFoundRelativePath."
            )
        }
        return policy
    }

    /// Pre-activation "these N captured sibling paths are not in your folder" disclosure — the
    /// preview half of the directory missing-file-policy item. Compares every captured session
    /// under this matcher's host+path prefix against what's actually on disk in `directoryURL`,
    /// so a caller can see the gap *before* approving a rule that will otherwise silently 404 (or,
    /// under `.overlayFailOpen`, silently pass through) those paths. Best-effort and capped — never
    /// blocks rule creation, since the local folder may simply not have every sibling yet by design.
    private func missingLocalSiblingsDisclosure(matcher: MCPMutationMatcher, directoryURL: URL) -> [String: Any] {
        guard let snapshotService else { return [:] }
        let normalizedPrefix = matcher.path.hasSuffix("/") ? matcher.path : "\(matcher.path)/"
        var missingRelativePaths: [String] = []
        var seenRelativePaths = Set<String>()
        for indexed in snapshotService.allIndexedSessions {
            guard indexed.record.request.host.caseInsensitiveCompare(matcher.host) == .orderedSame else { continue }
            let requestPath = indexed.record.request.path.split(separator: "?", maxSplits: 1).first.map(String.init)
                ?? indexed.record.request.path
            guard requestPath.hasPrefix(normalizedPrefix) else { continue }
            let relative = String(requestPath.dropFirst(normalizedPrefix.count))
            guard !relative.isEmpty, seenRelativePaths.insert(relative).inserted else { continue }
            let localURL = directoryURL.appendingPathComponent(relative)
            let existsLocally = (try? localURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            if !existsLocally {
                missingRelativePaths.append(relative)
            }
            if missingRelativePaths.count >= 50 { break }
        }
        guard !missingRelativePaths.isEmpty else { return [:] }
        return [
            "capturedSiblingsNotOnDisk": [
                "count": missingRelativePaths.count,
                "relativePaths": missingRelativePaths,
                "note": "Captured sessions under this path prefix with no matching file in the chosen folder. "
                    + "Under missingFilePolicy: strictLocal (default) these will 404 locally; overlayFailOpen "
                    + "forwards them to the real upstream instead."
            ]
        ]
    }

    /// Proposes a `.localFile` Map Local rule that serves one local binary file via an opaque
    /// bookmark — the first-class replacement for the "one-file directory" workaround, unblocking
    /// the single most common asset-swap shape (one PNG/WebP at one URL) without a folder. Mirrors
    /// `proposeCreateLocalDirectoryMapLocal`'s bookmark handling exactly (plain, not security-scoped
    /// — see that function's doc comment) but does NOT require `matchMode: pathPrefix`: a single
    /// file naturally wants `exactPath`/`pathSuffix`/`filename` instead.
    private func proposeCreateSingleFileMapLocal(
        bookmarkRef: String,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        guard !arguments.keys.contains("bodyText") else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "bodyText cannot be supplied with localFileBookmarkRef."
            )
        }
        guard let bookmarkData = Data(base64Encoded: bookmarkRef), !bookmarkData.isEmpty else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "localFileBookmarkRef must be base64-encoded bookmark data."
            )
        }
        var isStale = false
        let fileURL: URL
        do {
            fileURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "localFileBookmarkRef could not be resolved: \(error.localizedDescription)"
            )
        }
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            throw MCPStructuredError(code: .malformedRequest, message: "localFileBookmarkRef must point at a regular file.")
        }
        let matcher = try MCPMutationValidator.parseMatcher(from: arguments)
        let statusCode = arguments["statusCode"] as? Int ?? 200
        let contentType = (arguments["contentType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedContentType = (contentType?.isEmpty == false)
            ? contentType!
            : LocalDirectoryServer.contentType(forPathExtension: fileURL.pathExtension)
        let proposedID = UUID()
        let fileName = fileURL.lastPathComponent
        let plan = MCPMutationPlan(
            capability: .createDisabledMapLocal,
            matcher: matcher,
            proposedTargetID: proposedID,
            effectKind: .mapLocal,
            effectSummary: "Create disabled Map Local file rule for \(matcher.method) \(matcher.host)\(matcher.path) → file \(fileName).",
            inlineContentType: resolvedContentType,
            inlineStatusCode: statusCode,
            rewriteLabel: arguments["label"] as? String,
            localFileBookmarkData: bookmarkData,
            forceNoCache: arguments["forceNoCache"] as? Bool ?? false
        )
        let scopeEvaluation = await evaluateMatcherScopeConflicts(matcher: matcher, excludingRuleID: nil)
        var result = try await propose(plan: plan, client: client, arguments: arguments)
        result.merge(matcherScopeDisclosure(matcher: matcher, evaluation: scopeEvaluation), uniquingKeysWith: { current, _ in current })
        return result
    }

    /// Proposes a `.fixtureRun` Map Local rule that delegates to a running HLS fixture run's live
    /// server instead of a static body (ADR-Streaming-Source-Redirect-To-Fixture.md). Requires
    /// `matchMode: pathPrefix` — a fixture run serves a whole directory tree, not one URL — and the
    /// referenced run must belong to the calling client and still be active. No preview/inline-body
    /// arguments are meaningful here since the fixture computes each response live.
    private func proposeCreateFixtureRunMapLocal(
        fixtureRunIDString: String,
        arguments: [String: Any],
        client: MCPClientRecord
    ) async throws -> [String: Any] {
        guard !arguments.keys.contains("bodyText"),
              !arguments.keys.contains("statusCode"),
              !arguments.keys.contains("contentType") else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "bodyText, statusCode, and contentType cannot be supplied with fixtureRunID."
            )
        }
        guard let runID = UUID(uuidString: fixtureRunIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "fixtureRunID must be a UUID.")
        }
        let matcher = try MCPMutationValidator.parseMatcher(from: arguments)
        guard matcher.matchMode == .pathPrefix else {
            throw MCPStructuredError(code: .malformedRequest, message: "fixtureRunID requires matchMode: pathPrefix.")
        }
        guard let hlsFixtureRunStore, hlsFixtureRunStore.isLoaded else {
            throw MCPStructuredError(code: .internalFailure, message: "HLS fixture-run store is unavailable.")
        }
        guard let record = hlsFixtureRunStore.run(id: runID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "fixtureRunID was not found.")
        }
        guard record.clientID == client.id else {
            throw MCPStructuredError(code: .policyDenied, message: "fixtureRunID is not owned by this client.")
        }
        guard record.isActive else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "fixtureRunID does not reference an active fixture run. Start a new run with hls_fixture_start."
            )
        }
        let proposedID = UUID()
        // Names the exact profile + reserved host of record so an approver knows precisely which
        // local content will be substituted, per ADR §5.
        let effectSummary = "Create disabled Map Local rule serving HLS fixture run \(runID.uuidString) "
            + "(profile '\(record.profileID)', reserved host \(record.reservedHost)) for \(matcher.method) "
            + "\(matcher.scheme.rawValue)://\(matcher.host)\(matcher.path)*."
        let plan = MCPMutationPlan(
            capability: .createDisabledMapLocal,
            matcher: matcher,
            proposedTargetID: proposedID,
            effectKind: .mapLocal,
            effectSummary: effectSummary,
            rewriteLabel: arguments["label"] as? String,
            fixtureRunID: runID
        )
        return try await propose(plan: plan, client: client, arguments: arguments)
    }

    /// Resolves a client-owned draft revision for Map Local when `responseRevisionID` is present.
    private func resolvedResponseRevisionIfRequested(
        arguments: [String: Any],
        client: MCPClientRecord
    ) throws -> (draft: ResponseDraft, revision: ResponseDraftRevision)? {
        guard let revisionIDString = arguments["responseRevisionID"] as? String else { return nil }
        guard let revisionID = UUID(uuidString: revisionIDString) else {
            throw MCPStructuredError(code: .malformedRequest, message: "responseRevisionID must be a UUID.")
        }
        guard let store = responseDraftStore, store.isLoaded else {
            throw MCPStructuredError(code: .internalFailure, message: "Response draft store is unavailable.")
        }
        guard let bound = store.revision(id: revisionID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "responseRevisionID was not found.")
        }
        guard bound.draft.clientID == client.id else {
            throw MCPStructuredError(code: .policyDenied, message: "responseRevisionID is not owned by this client.")
        }
        return bound
    }

    /// Resolves a retained preview digest for Map Local. Accepts `responseEditPreviewDigest` and the
    /// compatibility alias `hlsPreviewDigest`.
    func resolvedResponseEditPreviewIfRequested(
        arguments: [String: Any],
        client: MCPClientRecord
    ) throws -> ResponseEditPreviewRecord? {
        let digest = (arguments["responseEditPreviewDigest"] as? String)
            ?? (arguments["hlsPreviewDigest"] as? String)
        guard let digest else { return nil }
        let isHLSAlias = arguments["hlsPreviewDigest"] != nil && arguments["responseEditPreviewDigest"] == nil
        let previewTool = isHLSAlias ? "preview_hls_codecs_edit" : "preview_response_edit"
        let recovery = "Run \(previewTool) again, review the result, then propose_create_map_local with the new digest. Reconnecting does not refresh a preview."
        let recoveryDetails = ["nextTool": previewTool, "recoveryInstruction": recovery]
        purgeStaleResponseEditPreviews()
        guard var preview = responseEditPreviewsByDigest[digest] else {
            throw MCPStructuredError(
                code: .staleProposal,
                message: (isHLSAlias
                    ? "The HLS CODECS preview is missing, consumed, or expired."
                    : "The response-edit preview is missing, consumed, or expired.") + " " + recovery,
                details: recoveryDetails
            )
        }
        guard Date() < preview.expiresAt else {
            responseEditPreviewsByDigest.removeValue(forKey: digest)
            throw MCPStructuredError(
                code: .staleProposal,
                message: (isHLSAlias
                    ? "The HLS CODECS preview expired; run it again."
                    : "The response-edit preview expired; run it again.") + " " + recovery,
                details: recoveryDetails
            )
        }
        guard let snapshotService,
              preview.clientID == client.id,
              preview.mcpSessionID == (arguments["__mcpInternalSessionID"] as? String),
              preview.captureEpoch == snapshotService.captureEpoch,
              preview.policyRevision == policyStore.policyRevision,
              snapshotService.indexedSession(id: preview.sessionID) != nil else {
            throw MCPStructuredError(
                code: .staleProposal,
                message: (isHLSAlias
                    ? "The HLS CODECS preview no longer matches the client, capture, or policy."
                    : "The response-edit preview no longer matches the client, capture, or policy.") + " " + recovery,
                details: recoveryDetails
            )
        }
        if arguments["method"] != nil || arguments["host"] != nil || arguments["path"] != nil {
            var supplied = try MCPMutationValidator.parseMatcher(from: arguments)
            // Client scope is reviewed by the proposal, independently of preview request identity.
            supplied.sourceClientAddress = preview.matcher.sourceClientAddress
            guard supplied == preview.matcher else {
                throw MCPStructuredError(
                    code: .malformedRequest,
                    message: (isHLSAlias
                        ? "The supplied matcher differs from the validated HLS CODECS preview."
                        : "The supplied matcher differs from the validated response-edit preview.")
                        + " Omit the repeated request matcher to use the preview scope, or preview the intended request again. Client restriction and cache behavior are reviewed separately.",
                    details: ["nextTool": "propose_create_map_local", "reason": "preview_matcher_mismatch"]
                )
            }
        }
        preview.lastAccessAt = Date()
        responseEditPreviewsByDigest[digest] = preview
        return preview
    }

    private func applyCreateMapLocal(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        let enableAfterApply = arguments["enableAfterApply"] as? Bool ?? false
        try requireMutatingAccess(client: client, capability: .createDisabledMapLocal)
        // Fail-closed: if enable is denied/blocked, do not create a disabled rule either.
        if enableAfterApply {
            try requireActiveMutatingAccess(client: client, capability: .enableRule)
        }
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .createDisabledMapLocal, client: client)
        // Gate the create+enable bundle on `.enableRule` (highest-severity member) so "Add To Client
        // Policy" mints a grant that also covers later standalone `apply_enable_rule` calls.
        // Proposal/applyProposal stay on `.createDisabledMapLocal` (token minted at propose time).
        try resolveMutationApproval(
            toolName: "apply_create_map_local",
            arguments: arguments,
            client: client,
            capability: enableAfterApply ? .enableRule : .createDisabledMapLocal,
            reason: enableAfterApply
                ? "Create-and-enable map-local apply_create_map_local — this rule becomes live on approval."
                : nil,
            idempotencyCapability: .createDisabledMapLocal
        )
        guard let matcher = plan.matcher else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        if enableAfterApply {
            let evaluation = await evaluateMatcherScopeConflicts(
                matcher: matcher,
                excludingRuleID: plan.proposedTargetID
            )
            try requireAcceptedConfoundersIfNeeded(
                evaluation: evaluation,
                matcher: matcher,
                arguments: arguments
            )
        }
        let provenance = makeProvenance(clientID: client.id, capability: .createDisabledMapLocal)
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .createDisabledMapLocal,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: proposal.targetRevision,
            mutationIntent: mutationIntent(for: plan, clientID: client.id, digest: proposal.argumentDigest),
            performMutation: {
                if let fixtureRunID = plan.fixtureRunID {
                    try await self.persistFixtureRunOverrideRule(
                        id: plan.proposedTargetID,
                        matcher: matcher,
                        fixtureRunID: fixtureRunID,
                        label: plan.rewriteLabel,
                        provenance: provenance
                    )
                } else if let bookmarkData = plan.localDirectoryBookmarkData {
                    try await self.persistLocalDirectoryOverrideRule(
                        id: plan.proposedTargetID,
                        matcher: matcher,
                        bookmarkData: bookmarkData,
                        notFoundRelativePath: plan.notFoundRelativePath,
                        missingFilePolicy: plan.missingFilePolicy,
                        label: plan.rewriteLabel,
                        provenance: provenance,
                        forceNoCache: plan.forceNoCache
                    )
                } else if let bookmarkData = plan.localFileBookmarkData {
                    guard let statusCode = plan.inlineStatusCode,
                          let contentType = plan.inlineContentType else {
                        throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
                    }
                    try await self.persistLocalFileOverrideRule(
                        id: plan.proposedTargetID,
                        matcher: matcher,
                        bookmarkData: bookmarkData,
                        statusCode: statusCode,
                        contentType: contentType,
                        label: plan.rewriteLabel,
                        provenance: provenance,
                        forceNoCache: plan.forceNoCache
                    )
                } else {
                    guard let bodyData = plan.inlineBodyData,
                          let statusCode = plan.inlineStatusCode,
                          let contentType = plan.inlineContentType else {
                        throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
                    }
                    try await self.persistInlineOverrideRule(
                        id: plan.proposedTargetID,
                        matcher: matcher,
                        bodyData: bodyData,
                        statusCode: statusCode,
                        contentType: contentType,
                        label: plan.rewriteLabel,
                        provenance: provenance,
                        forceNoCache: plan.forceNoCache
                    )
                    if let revisionID = plan.responseRevisionID,
                       let store = self.responseDraftStore {
                        try? store.bindOverride(ruleID: plan.proposedTargetID, toRevision: revisionID, clientID: client.id)
                    }
                }
                if enableAfterApply {
                    try await self.responseOverrideStore.setEnabled(true, for: plan.proposedTargetID)
                }
                return nil
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        recordApplied(client: client, capability: .createDisabledMapLocal, targetID: plan.proposedTargetID.uuidString, detail: plan.effectSummary)
        if enableAfterApply {
            recordApplied(
                client: client,
                capability: .enableRule,
                targetID: plan.proposedTargetID.uuidString,
                detail: "Enabled map-local rule \(plan.proposedTargetID.uuidString) as part of create+enable apply."
            )
            await refreshLiveEffectSummary()
        }
        return try payloadDictionary(applyResultDTO(result: result, targetID: plan.proposedTargetID.uuidString, isEnabled: enableAfterApply))
    }

    // MARK: - Map Remote

    private func proposeCreateMapRemote(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledMapRemote)
        let matcher = try MCPMutationValidator.parseMatcher(from: arguments)
        guard let remoteHost = arguments["remoteHost"] as? String else {
            throw MCPMutationValidator.structuredError(for: .malformedRequest("remoteHost is required."))
        }
        let remoteSchemeRaw = arguments["remoteScheme"] as? String ?? SessionScheme.https.rawValue
        guard let remoteScheme = SessionScheme(rawValue: remoteSchemeRaw.lowercased()) else {
            throw MCPMutationValidator.structuredError(for: .malformedRequest("remoteScheme must be http or https."))
        }
        let remotePort = arguments["remotePort"] as? Int
        let allowLoopbackDestination = (arguments["allowLoopbackDestination"] as? Bool) ?? false
        let preserveHostHeader = (arguments["preserveHostHeader"] as? Bool) ?? false
        try MCPMutationValidator.validateMapRemoteDestination(
            host: remoteHost,
            port: remotePort,
            scheme: remoteScheme,
            allowLoopbackDestination: allowLoopbackDestination,
            policy: loopbackPolicyReader(),
            reservedRegistry: .shared
        )
        let remotePath = arguments["remotePath"] as? String
        if let remotePath {
            try MCPMutationValidator.validateMapRemoteRequestTarget(remotePath)
        }
        let queryPolicyRaw = arguments["remoteQueryPolicy"] as? String ?? MapRemoteQueryPolicy.preserve.rawValue
        guard let queryPolicy = MapRemoteQueryPolicy(rawValue: queryPolicyRaw) else {
            throw MCPMutationValidator.structuredError(for: .malformedRequest("remoteQueryPolicy must be preserve, replace, or drop."))
        }
        let remoteQuery = arguments["remoteQuery"] as? String
        if let remoteQuery {
            try MCPMutationValidator.validateMapRemoteQuery(remoteQuery)
        }
        let normalizedRemoteHost = LoopbackAddressInspector.stripBracketsAndTrailingDot(remoteHost).host
        let hostBehaviorNote = preserveHostHeader ? "; preserve original Host" : ""
        let loopbackNote = allowLoopbackDestination ? " [local Mac loopback]" : ""
        let proposedID = UUID()
        let plan = MCPMutationPlan(
            capability: .createDisabledMapRemote,
            matcher: matcher,
            proposedTargetID: proposedID,
            effectKind: .mapRemote,
            effectSummary: "Create disabled map-remote rule\(loopbackNote) for \(matcher.method) \(matcher.host)\(matcher.path) -> \(remoteScheme.rawValue)://\(normalizedRemoteHost)\(remotePort.map { ":\($0)" } ?? "")\(remotePath ?? "")\(hostBehaviorNote).",
            mapRemoteHost: normalizedRemoteHost,
            mapRemotePort: remotePort,
            mapRemoteScheme: remoteScheme,
            mapRemotePath: remotePath,
            mapRemoteQueryPolicy: queryPolicy,
            mapRemoteQuery: remoteQuery,
            mapRemoteAllowLoopback: allowLoopbackDestination,
            mapRemotePreserveHostHeader: preserveHostHeader,
            rewriteLabel: arguments["label"] as? String
        )
        return try await propose(plan: plan, client: client, arguments: arguments)
    }

    private func applyCreateMapRemote(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledMapRemote)
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .createDisabledMapRemote, client: client)
        try resolveMutationApproval(toolName: "apply_create_map_remote", arguments: arguments, client: client, capability: .createDisabledMapRemote)
        guard let matcher = plan.matcher,
              let remoteHost = plan.mapRemoteHost,
              let remoteScheme = plan.mapRemoteScheme else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        try MCPMutationValidator.validateMapRemoteDestination(
            host: remoteHost,
            port: plan.mapRemotePort,
            scheme: remoteScheme,
            allowLoopbackDestination: plan.mapRemoteAllowLoopback,
            policy: loopbackPolicyReader(),
            reservedRegistry: .shared
        )
        let provenance = makeProvenance(clientID: client.id, capability: .createDisabledMapRemote)
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .createDisabledMapRemote,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: proposal.targetRevision,
            mutationIntent: mutationIntent(for: plan, clientID: client.id, digest: proposal.argumentDigest),
            performMutation: {
                try await self.persistMapRemoteRule(
                    id: plan.proposedTargetID,
                    matcher: matcher,
                    remoteHost: remoteHost,
                    remotePort: plan.mapRemotePort,
                    remoteScheme: remoteScheme,
                    remotePath: plan.mapRemotePath,
                    remoteQueryPolicy: plan.mapRemoteQueryPolicy,
                    remoteQuery: plan.mapRemoteQuery,
                    allowLoopbackDestination: plan.mapRemoteAllowLoopback,
                    preserveHostHeader: plan.mapRemotePreserveHostHeader,
                    label: plan.rewriteLabel,
                    provenance: provenance
                )
                return nil
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        recordApplied(client: client, capability: .createDisabledMapRemote, targetID: plan.proposedTargetID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: plan.proposedTargetID.uuidString, isEnabled: false))
    }

    // MARK: - Live Response Rewrite

    private func proposeCreateLiveRewrite(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledLiveRewrite)
        let matcher = try MCPMutationValidator.parseMatcher(from: arguments)
        let jsonPath = arguments["jsonPath"] as? String ?? ""
        let operation = try MCPMutationValidator.parseRewriteOperation(from: arguments)
        try MCPMutationValidator.validateRewriteLocator(jsonPath: jsonPath, operation: operation)
        let overrideValue = try MCPMutationValidator.parseRewriteOverrideValue(operation: operation, from: arguments)
        let repeatPolicy = try MCPMutationValidator.parseRewriteRepeatPolicy(from: arguments)
        try validateLiveRewritePreview(
            arguments: arguments,
            client: client,
            matcher: matcher,
            jsonPath: jsonPath,
            operation: operation,
            overrideValue: overrideValue,
            repeatPolicy: repeatPolicy
        )
        let proposedID = UUID()
        let scopeDescription = jsonPath.contains("[*]")
            ? "every value matched by \(jsonPath)"
            : jsonPath
        let plan = MCPMutationPlan(
            capability: .createDisabledLiveRewrite,
            matcher: matcher,
            proposedTargetID: proposedID,
            effectKind: .liveResponseRewrite,
            effectSummary: "Create disabled live response rewrite for \(matcher.method) \(matcher.host)\(matcher.path) patching \(scopeDescription) (\(operation.rawValue)).",
            rewriteJSONPath: jsonPath,
            rewriteOverrideValue: overrideValue,
            rewriteOperation: operation,
            rewriteRepeatPolicy: repeatPolicy,
            rewriteLabel: arguments["label"] as? String
        )
        return try await propose(plan: plan, client: client, arguments: arguments)
    }

    private func validateLiveRewritePreview(
        arguments: [String: Any],
        client: MCPClientRecord,
        matcher: MCPMutationMatcher,
        jsonPath: String,
        operation: JSONMutationOperation,
        overrideValue: BookmarkJSONValue,
        repeatPolicy: JSONMutationRepeatPolicy
    ) throws {
        guard enforcesLiveRewritePreview else { return }
        guard let snapshotService else {
            throw MCPStructuredError(code: .internalFailure, message: "Capture-only preview validation is unavailable.")
        }
        guard let previewDigest = arguments["previewDigest"] as? String,
              let preview = liveRewritePreviewsByDigest[previewDigest] else {
            throw MCPStructuredError(code: .staleProposal, message: "A current previewDigest from preview_live_rewrite is required.")
        }
        let now = Date()
        guard now < preview.expiresAt else {
            liveRewritePreviewsByDigest.removeValue(forKey: previewDigest)
            throw MCPStructuredError(code: .staleProposal, message: "The rewrite preview expired; run preview_live_rewrite again.")
        }
        let ruleDigest = MCPTransformationPreviewDigest.compute(
            matcher: matcher,
            jsonPath: jsonPath,
            operation: operation,
            overrideValue: overrideValue,
            repeatPolicy: repeatPolicy
        )
        let mcpSessionID = arguments["__mcpInternalSessionID"] as? String
        guard preview.clientID == client.id,
              preview.mcpSessionID == mcpSessionID,
              preview.ruleDigest == ruleDigest,
              preview.captureEpoch == snapshotService.captureEpoch,
              preview.policyRevision == policyStore.policyRevision,
              preview.sampledSessionIDs.allSatisfy({ snapshotService.indexedSession(id: $0) != nil }) else {
            throw MCPStructuredError(
                code: .staleProposal,
                message: "The rewrite preview no longer matches this client, session, capture, policy, or rule. Run preview_live_rewrite again."
            )
        }
    }

    func invalidateTransientState(clientID: String? = nil) {
        if let clientID {
            liveRewritePreviewsByDigest = liveRewritePreviewsByDigest.filter { $0.value.clientID != clientID }
            responseEditPreviewsByDigest = responseEditPreviewsByDigest.filter { $0.value.clientID != clientID }
        } else {
            liveRewritePreviewsByDigest.removeAll()
            responseEditPreviewsByDigest.removeAll()
        }
    }

    private func applyCreateLiveRewrite(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledLiveRewrite)
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .createDisabledLiveRewrite, client: client)
        try resolveMutationApproval(toolName: "apply_create_live_rewrite", arguments: arguments, client: client, capability: .createDisabledLiveRewrite)
        guard let matcher = plan.matcher,
              let jsonPath = plan.rewriteJSONPath,
              let overrideValue = plan.rewriteOverrideValue else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        let operation = plan.rewriteOperation
        let repeatPolicy = plan.rewriteRepeatPolicy
        let provenance = makeProvenance(clientID: client.id, capability: .createDisabledLiveRewrite)
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .createDisabledLiveRewrite,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: proposal.targetRevision,
            mutationIntent: mutationIntent(for: plan, clientID: client.id, digest: proposal.argumentDigest),
            performMutation: {
                try await self.persistLiveResponseRewriteRule(
                    id: plan.proposedTargetID,
                    matcher: matcher,
                    jsonPath: jsonPath,
                    overrideValue: overrideValue,
                    operation: operation,
                    repeatPolicy: repeatPolicy,
                    label: plan.rewriteLabel,
                    provenance: provenance
                )
                return nil
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        recordApplied(client: client, capability: .createDisabledLiveRewrite, targetID: plan.proposedTargetID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: plan.proposedTargetID.uuidString, isEnabled: false))
    }

    // MARK: - Collection Mock

    /// Capture-only: compiles and retains a reviewed collection-shape mutation against one
    /// selected session's response. Nothing is persisted as a rule here — `revisionID` only binds
    /// a later `propose_create_collection_mock` call to this exact compiled plan.
    private func previewCollectionMock(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireInspectAccess(client: client, capability: .transformationPreview)
        guard let collectionMockAuthoringService else {
            throw MCPStructuredError(code: .internalFailure, message: "Collection-mock preparation is unavailable in this server configuration.")
        }
        guard let snapshotService else {
            throw MCPStructuredError(code: .internalFailure, message: "Capture-only preview is unavailable in this server configuration.")
        }
        guard let sessionIDString = arguments["sessionID"] as? String, let sessionID = UUID(uuidString: sessionIDString) else {
            throw MCPMutationValidationError.malformedRequest("sessionID is required.")
        }
        guard let draftText = arguments["draftJSON"] as? String,
              draftText.utf8.count <= CollectionMockDraftDecoder.maximumInputBytes else {
            throw MCPMutationValidationError.malformedRequest(
                "draftJSON is required and must be at most \(CollectionMockDraftDecoder.maximumInputBytes) UTF-8 bytes."
            )
        }
        guard let session = snapshotService.indexedSession(id: sessionID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "sessionID not found.")
        }
        guard let response = session.record.response else {
            throw MCPStructuredError(code: .malformedRequest, message: "Selected session has no response.")
        }
        guard !response.bodyDeferred, !response.bodyTruncated, response.recordingBodyOmissionReason == nil,
              let bodyData = response.bodyData else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "Selected response body is unavailable, deferred, or truncated. No upstream refetch is performed."
            )
        }
        let draftData = Data(draftText.utf8)
        let draft: CollectionMockDraft
        do {
            draft = try CollectionMockDraftDecoder.decode(draftData)
        } catch let error as CollectionMockDraftDecoder.ValidationError {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "draftJSON.\(error.field): \(error.reason)",
                details: error.allowedValues.isEmpty ? nil : ["allowedValues": error.allowedValues.joined(separator: ", ")]
            )
        }
        guard let decoded = CapturedBodyDecoder.decode(
                bodyData: bodyData, headers: response.headers, maxDecodedBytes: CollectionMockCompiler.maximumBodyBytes
              ), decoded.canUseAnalysisDataForInspection else {
            throw MCPStructuredError(code: .malformedRequest, message: "Selected response body could not be decoded as JSON.")
        }
        let idempotencyKey = MCPArgumentDigest.normalized(["sessionID": sessionIDString, "draftJSON": draftText])
        let revision: PreparedCollectionRevision
        do {
            revision = try await collectionMockAuthoringService.prepare(
                ownerID: client.id, idempotencyKey: idempotencyKey, source: decoded.analysisData, draft: draft
            )
        } catch {
            throw Self.structuredError(forCollectionMockPreparation: error)
        }
        let dto = MCPCollectionMockPreviewResultDTO(
            revisionID: revision.id.uuidString,
            beforeCount: revision.beforeCount,
            afterCount: revision.afterCount,
            summary: revision.plan.mcpSummary
        )
        return try payloadDictionary(dto)
    }

    private func proposeCreateCollectionMock(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledCollectionMock)
        guard let collectionMockAuthoringService else {
            throw MCPStructuredError(code: .internalFailure, message: "Collection-mock preparation is unavailable in this server configuration.")
        }
        let matcher = try MCPMutationValidator.parseMatcher(from: arguments)
        guard let revisionIDString = arguments["revisionID"] as? String, let revisionID = UUID(uuidString: revisionIDString) else {
            throw MCPMutationValidationError.malformedRequest("revisionID from preview_collection_mock is required.")
        }
        let revision: PreparedCollectionRevision
        do {
            revision = try await collectionMockAuthoringService.inspect(id: revisionID, ownerID: client.id)
        } catch {
            throw MCPStructuredError(code: .staleProposal, message: "revisionID not found; run preview_collection_mock again.")
        }
        let proposedID = UUID()
        let plan = MCPMutationPlan(
            capability: .createDisabledCollectionMock,
            matcher: matcher,
            proposedTargetID: proposedID,
            effectKind: .collectionMock,
            effectSummary: "Create disabled collection mock for \(matcher.method) \(matcher.host)\(matcher.path): \(revision.plan.mcpSummary).",
            collectionMockPlan: revision.plan,
            collectionMockLabel: arguments["label"] as? String
        )
        return try await propose(plan: plan, client: client, arguments: arguments)
    }

    private func applyCreateCollectionMock(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledCollectionMock)
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .createDisabledCollectionMock, client: client)
        try resolveMutationApproval(toolName: "apply_create_collection_mock", arguments: arguments, client: client, capability: .createDisabledCollectionMock)
        guard let matcher = plan.matcher, let collectionMockPlan = plan.collectionMockPlan else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        let provenance = makeProvenance(clientID: client.id, capability: .createDisabledCollectionMock)
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .createDisabledCollectionMock,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: proposal.targetRevision,
            mutationIntent: mutationIntent(for: plan, clientID: client.id, digest: proposal.argumentDigest),
            performMutation: {
                try await self.persistCollectionMockRule(
                    id: plan.proposedTargetID,
                    matcher: matcher,
                    plan: collectionMockPlan,
                    label: plan.collectionMockLabel,
                    provenance: provenance
                )
                return nil
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        recordApplied(client: client, capability: .createDisabledCollectionMock, targetID: plan.proposedTargetID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: plan.proposedTargetID.uuidString, isEnabled: false))
    }

    private func persistCollectionMockRule(
        id: UUID,
        matcher: MCPMutationMatcher,
        plan: CompiledCollectionMock,
        label: String?,
        provenance: MCPProvenance
    ) async throws {
        let rule = ResponseOverrideRule(
            id: id,
            label: label,
            requestMethod: matcher.method,
            requestScheme: matcher.scheme,
            host: matcher.host,
            port: matcher.port,
            path: matcher.path,
            matchMode: matcher.matchMode,
            sourceKind: .collectionMock,
            sourceDescription: "\(ResponseOverrideSourceKind.collectionMock.sourceDescription): \(plan.mcpSummary)",
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            isEnabled: false,
            collectionMockPlan: plan,
            mcpOrigin: .mcp,
            mcpProvenance: provenance,
            graphQLOperationName: matcher.graphQLOperationName,
            matchQueryKey: matcher.matchQueryKey,
            matchQueryValue: matcher.matchQueryValue,
            sourceClientAddress: matcher.sourceClientAddress
        )
        try await responseOverrideStore.addRule(rule)
    }

    /// Maps `CollectionMockAuthoringService.prepare`'s thrown errors to a structured MCP error.
    /// Not a validation error the caller can fix by re-reading a schema — every case here reflects
    /// either exhausted bounded capacity or a source/draft mismatch the compiler itself detected.
    private static func structuredError(forCollectionMockPreparation error: Error) -> MCPStructuredError {
        if let error = error as? CollectionMockAuthoringError {
            switch error {
            case .invalidRequest:
                return MCPStructuredError(code: .malformedRequest, message: "Invalid collection-mock preparation request.")
            case .idempotencyConflict:
                return MCPStructuredError(code: .conflict, message: "sessionID/draftJSON changed since an earlier preview with different content; preview again.")
            case .revisionNotFound:
                return MCPStructuredError(code: .staleProposal, message: "revisionID not found; run preview_collection_mock again.")
            case .revisionRetired:
                return MCPStructuredError(code: .staleProposal, message: "revisionRetired: prepare a new revision with a new request key.")
            case .requestHistoryFull:
                return MCPStructuredError(code: .busy, message: "requestHistoryFull: preparation history is full for this app process; no automatic retry or restart.")
            case .capacityExceeded:
                return MCPStructuredError(code: .busy, message: "Collection-mock preview capacity is exhausted; retry shortly.")
            }
        }
        if let error = error as? CollectionMockError {
            return MCPStructuredError(code: .malformedRequest, message: "Collection-mock compilation failed: \(error.rawValue).")
        }
        return MCPStructuredError(code: .internalFailure, message: "Collection-mock preparation failed.")
    }

    // MARK: - Rewrite

    private func proposeCreateRewrite(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledRewrite)
        guard let bookmarkIDString = arguments["bookmarkID"] as? String,
              let bookmarkID = UUID(uuidString: bookmarkIDString),
              bookmarkStore.loadBookmarks().contains(where: { $0.id == bookmarkID }) else {
            throw MCPMutationValidator.structuredError(for: .malformedRequest("bookmarkID not found."))
        }
        let jsonPath = arguments["jsonPath"] as? String ?? ""
        let operation = try MCPMutationValidator.parseRewriteOperation(from: arguments)
        try MCPMutationValidator.validateRewriteLocator(jsonPath: jsonPath, operation: operation)
        let overrideValue = try MCPMutationValidator.parseBookmarkJSONValue(from: arguments)
        let proposedID = bookmarkID
        let plan = MCPMutationPlan(
            capability: .createDisabledRewrite,
            matcher: nil,
            proposedTargetID: proposedID,
            effectKind: .bookmarkRewrite,
            effectSummary: "Add disabled JSON rewrite \(jsonPath) (\(operation.rawValue)) to bookmark \(bookmarkIDString).",
            bookmarkID: bookmarkID,
            rewriteJSONPath: jsonPath,
            rewriteOverrideValue: overrideValue,
            rewriteOperation: operation,
            rewriteLabel: arguments["label"] as? String
        )
        return try await propose(
            plan: plan,
            client: client,
            arguments: arguments,
            targetRevision: bookmarkStore.loadBookmarks().first(where: { $0.id == bookmarkID })?.mcpTargetRevision
        )
    }

    private func applyCreateRewrite(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledRewrite)
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .createDisabledRewrite, client: client)
        try resolveMutationApproval(toolName: "apply_create_rewrite", arguments: arguments, client: client, capability: .createDisabledRewrite)
        guard let bookmarkID = plan.bookmarkID,
              let jsonPath = plan.rewriteJSONPath,
              let overrideValue = plan.rewriteOverrideValue else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        let operation = plan.rewriteOperation
        let currentRevision = bookmarkStore.loadBookmarks().first(where: { $0.id == bookmarkID })?.mcpTargetRevision
        if proposal.targetRevision != currentRevision {
            throw MCPStructuredError(code: .staleProposal, message: "Bookmark changed since proposal.")
        }
        let provenance = makeProvenance(clientID: client.id, capability: .createDisabledRewrite)
        let rollbackData = try? encoder.encode(bookmarkStore.loadBookmarks().first(where: { $0.id == bookmarkID }))
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .createDisabledRewrite,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: currentRevision,
            mutationIntent: MCPMutationIntent(
                clientID: client.id,
                targetKind: .bookmarkRewrite,
                targetID: bookmarkID.uuidString,
                baselineRevision: currentRevision,
                intendedChangeDigest: proposal.argumentDigest,
                rollbackSnapshot: rollbackData,
                expiresAt: proposal.expiresAt
            ),
            performMutation: {
                try self.persistBookmarkRewrite(
                    bookmarkID: bookmarkID,
                    jsonPath: jsonPath,
                    overrideValue: overrideValue,
                    operation: operation,
                    provenance: provenance
                )
                return self.bookmarkStore.loadBookmarks().first(where: { $0.id == bookmarkID })?.mcpTargetRevision
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        recordApplied(client: client, capability: .createDisabledRewrite, targetID: bookmarkID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: bookmarkID.uuidString, isEnabled: false))
    }

    // MARK: - Bookmark

    private func proposeCreateBookmark(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledBookmark)
        let matcher = try MCPMutationValidator.parseMatcher(from: arguments)
        guard let name = arguments["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPMutationValidator.structuredError(for: .malformedRequest("name is required."))
        }
        let request = Self.capturedRequest(from: matcher)
        let proposedID = UUID()
        let plan = MCPMutationPlan(
            capability: .createDisabledBookmark,
            matcher: matcher,
            proposedTargetID: proposedID,
            effectKind: .responseOverride,
            effectSummary: "Create bookmark \(name) for \(matcher.method) \(matcher.host)\(matcher.path).",
            bookmarkName: name,
            bookmarkRequest: request
        )
        return try await propose(plan: plan, client: client, arguments: arguments)
    }

    private func applyCreateBookmark(arguments: [String: Any], client: MCPClientRecord) async throws -> [String: Any] {
        try requireMutatingAccess(client: client, capability: .createDisabledBookmark)
        let (plan, proposal) = try resolvedPlan(arguments: arguments, capability: .createDisabledBookmark, client: client)
        try resolveMutationApproval(toolName: "apply_create_bookmark", arguments: arguments, client: client, capability: .createDisabledBookmark)
        guard let name = plan.bookmarkName, let request = plan.bookmarkRequest, let matcher = plan.matcher else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal plan is incomplete.")
        }
        let provenance = makeProvenance(clientID: client.id, capability: .createDisabledBookmark)
        let result = try await proposalCoordinator.applyProposal(
            token: proposal.token,
            clientID: client.id,
            capability: .createDisabledBookmark,
            argumentDigest: proposal.argumentDigest,
            currentTargetRevision: proposal.targetRevision,
            mutationIntent: mutationIntent(for: plan, clientID: client.id, digest: proposal.argumentDigest),
            performMutation: {
                try self.persistBookmark(
                    id: plan.proposedTargetID,
                    name: name,
                    request: request,
                    matchMode: matcher.matchMode,
                    provenance: provenance
                )
                return nil
            },
            idempotencyKey: idempotencyKey(from: arguments)
        )
        finalizeApply(proposalToken: proposal.token, idempotencyKey: idempotencyKey(from: arguments))
        recordApplied(client: client, capability: .createDisabledBookmark, targetID: plan.proposedTargetID.uuidString, detail: plan.effectSummary)
        return try payloadDictionary(applyResultDTO(result: result, targetID: plan.proposedTargetID.uuidString, isEnabled: false))
    }

    // MARK: - Shared propose / apply helpers

    func propose(
        plan: MCPMutationPlan,
        client: MCPClientRecord,
        arguments: [String: Any],
        targetRevision: MCPTargetRevision? = nil
    ) async throws -> [String: Any] {
        let digest = MCPArgumentDigest.normalized(MCPArgumentDigest.dispatchArguments(arguments))
        let lockKey = targetLockKey(for: plan)
        let proposal = try proposalCoordinator.createProposal(
            clientID: client.id,
            capability: plan.capability,
            argumentDigest: digest,
            targetRevision: targetRevision,
            targetLockKey: lockKey,
            idempotencyKey: idempotencyKey(from: arguments)
        )
        plansByProposalToken[proposal.token] = plan
        let conflicts = await conflictingTargetIDs(for: plan)
        let payload = MCPMutationProposalPayload(
            proposalToken: proposal.token,
            expiresAt: proposal.expiresAt,
            targetLockKey: lockKey,
            effectSummary: plan.effectSummary,
            matchScope: matchScope(for: plan),
            conflicts: conflicts,
            riskTier: MCPCapabilityRiskTier.mutatingTool.rawValue,
            defaultEnabled: false,
            targetRevision: targetRevision?.rawValue,
            proposedTargetID: plan.proposedTargetID.uuidString
        )
        recordProposalCreated(client: client, capability: plan.capability, detail: plan.effectSummary)
        return try payloadDictionary(payload)
    }

    func resolvedPlan(
        arguments: [String: Any],
        capability: MCPCapabilityID,
        client: MCPClientRecord
    ) throws -> (MCPMutationPlan, MCPProposalToken) {
        guard let token = arguments["proposalToken"] as? String,
              let plan = plansByProposalToken[token] else {
            if let token = arguments["proposalToken"] as? String {
                approvalStore.invalidate(proposalToken: token)
            }
            throw MCPStructuredError(code: .staleProposal, message: "Unknown or expired proposal token.")
        }
        guard plan.capability == capability else {
            throw MCPStructuredError(code: .staleProposal, message: "Proposal capability mismatch.")
        }
        guard let proposal = proposalCoordinator.proposal(forToken: token),
              proposal.clientID == client.id,
              proposal.capability == capability else {
            approvalStore.invalidate(proposalToken: token)
            plansByProposalToken.removeValue(forKey: token)
            throw MCPStructuredError(code: .staleProposal, message: "Proposal token is no longer valid.")
        }
        return (plan, proposal)
    }

    private func mutationIntent(for plan: MCPMutationPlan, clientID: String, digest: String) -> MCPMutationIntent {
        MCPMutationIntent(
            clientID: clientID,
            targetKind: plan.effectKind,
            targetID: plan.proposedTargetID.uuidString,
            baselineRevision: nil,
            intendedChangeDigest: digest,
            rollbackSnapshot: nil,
            expiresAt: MCPApprovalPolicy.expiration()
        )
    }

    /// Resolves in-app approval (or a standing grant) before a create-disabled mutation apply.
    ///
    /// - Parameters:
    ///   - capability: Capability used for pending-approval minting, nonce validation, and
    ///     ``MCPPolicyEvaluator/skipsApprovalNonce`` (may be a higher-severity member for bundled applies).
    ///   - reason: Optional pending-approval disclosure; defaults to the create-disabled wording.
    ///   - idempotencyCapability: Capability used for the apply-result cache short-circuit. Must match
    ///     the capability passed to ``MCPProposalCoordinator/applyProposal`` (proposal mint capability),
    ///     which can differ from `capability` when create+enable is gated on ``MCPCapabilityID/enableRule``.
    func resolveMutationApproval(
        toolName: String,
        arguments: [String: Any],
        client: MCPClientRecord,
        capability: MCPCapabilityID,
        reason: String? = nil,
        idempotencyCapability: MCPCapabilityID? = nil
    ) throws {
        let digest = MCPArgumentDigest.normalized(arguments)
        let mcpSessionID = arguments["__mcpInternalSessionID"] as? String
        let proposalToken = arguments["proposalToken"] as? String
        let cacheCapability = idempotencyCapability ?? capability
        if let proposalToken,
           let proposal = proposalCoordinator.proposal(forToken: proposalToken),
           let idempotencyKey = idempotencyKey(from: arguments),
           proposalCoordinator.hasCachedApplyResult(
               idempotencyKey: idempotencyKey,
               clientID: client.id,
               capability: cacheCapability,
               argumentDigest: proposal.argumentDigest
           ) {
            return
        }
        if let presentedAuthorization = MCPArgumentDigest.authorization(from: arguments) {
            if approvalStore.nonceAlreadyUsed(presentedAuthorization.nonce) {
                throw approvalValidationError(.reused)
            }
            if approvalStore.nonceExpired(presentedAuthorization.nonce) {
                throw approvalValidationError(.expired)
            }
            if let granted = approvalStore.grantedAuthorization(nonce: presentedAuthorization.nonce) {
            if let failure = MCPApprovalValidation.validateRetry(
                request: granted.request,
                authorization: granted.authorization,
                currentClientID: client.id,
                currentCapability: capability,
                normalizedArgumentDigest: digest,
                currentPolicyRevision: policyStore.policyRevision,
                currentTargetRevision: nil,
                nonceAlreadyUsed: false
            ) {
                throw approvalValidationError(failure)
            }
            approvalStore.consumeNonce(granted.authorization.nonce)
            return
            }
        }
        if approvalStore.consumeApprovedRequest(
            clientID: client.id,
            mcpSessionID: mcpSessionID,
            capability: capability,
            argumentDigest: digest,
            policyRevision: policyStore.policyRevision,
            proposalToken: proposalToken
        ) {
            return
        }
        if policyEvaluator.skipsApprovalNonce(capability: capability, client: client) {
            return
        }
        let pendingReason = reason ?? "Create-disabled mutation \(toolName) requires in-app approval."
        if let proposalToken {
            proposalCoordinator.extendProposal(
                token: proposalToken,
                through: Date().addingTimeInterval(MCPApprovalPolicy.defaultLifetime)
            )
        }
        let request = approvalStore.createPendingRequest(
            clientID: client.id,
            capability: capability,
            argumentDigest: digest,
            policyRevision: policyStore.policyRevision,
            mcpSessionID: mcpSessionID,
            proposalToken: proposalToken,
            reason: pendingReason
        )
        throw MCPStructuredError.approvalRequired(request)
    }

    func approvalValidationError(_ failure: MCPApprovalValidation.Failure) -> MCPStructuredError {
        switch failure {
        case .expired:
            return MCPStructuredError(code: .approvalExpired, message: "Approval authorization expired.")
        case .reused:
            return MCPStructuredError(code: .approvalReused, message: "Approval authorization was already used.")
        case .argumentMismatch:
            return MCPStructuredError(code: .malformedRequest, message: "Approval authorization does not match request arguments.")
        case .policyTightened:
            return MCPStructuredError(code: .policyDenied, message: "Policy changed; approval is no longer valid.")
        case .targetRevisionChanged:
            return MCPStructuredError(code: .staleTargetRevision, message: "Target revision changed; approval is no longer valid.")
        }
    }

    func requireInspectAccess(client: MCPClientRecord, capability: MCPCapabilityID) throws {
        _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
        guard policyEvaluator.effectiveAllows(capability: capability, client: client) else {
            auditStore.recordOperatorActionablePolicyBlock(
                clientID: client.id,
                capability: capability,
                detail: "Inspect tools denied for profile."
            )
            throw MCPStructuredError(code: .policyDenied, message: "Inspect tools require Shareable profile.")
        }
    }

    func requireMutatingAccess(client: MCPClientRecord, capability: MCPCapabilityID) throws {
        _ = try policyStore.resolvedProfile(for: client.assignedProfileID)
        guard policyEvaluator.effectiveAllows(capability: capability, client: client) else {
            auditStore.recordOperatorActionablePolicyBlock(
                clientID: client.id,
                capability: capability,
                detail: "Mutating tools denied for profile."
            )
            throw MCPStructuredError(code: .policyDenied, message: "Mutating tools require Shareable profile.")
        }
    }

    // MARK: - Persistence

    private func persistBlockRule(
        id: UUID,
        matcher: MCPMutationMatcher,
        statusCode: Int,
        label: String?,
        provenance: MCPProvenance,
        dropConnection: Bool = false
    ) async throws {
        let rule = ResponseOverrideRule(
            id: id,
            label: label,
            requestMethod: matcher.method,
            requestScheme: matcher.scheme,
            host: matcher.host,
            port: matcher.port,
            path: matcher.path,
            matchMode: matcher.matchMode,
            sourceKind: .block,
            sourceDescription: ResponseOverrideSourceKind.block.sourceDescription,
            statusCode: statusCode,
            headers: [],
            bodySource: .inline(nil),
            isEnabled: false,
            mcpOrigin: .mcp,
            mcpProvenance: provenance,
            dropConnection: dropConnection,
            graphQLOperationName: matcher.graphQLOperationName,
            matchQueryKey: matcher.matchQueryKey,
            matchQueryValue: matcher.matchQueryValue,
            sourceClientAddress: matcher.sourceClientAddress
        )
        try await responseOverrideStore.addRule(rule)
    }

    private func persistInlineOverrideRule(
        id: UUID,
        matcher: MCPMutationMatcher,
        bodyData: Data,
        statusCode: Int,
        contentType: String,
        label: String?,
        provenance: MCPProvenance,
        forceNoCache: Bool = false
    ) async throws {
        let headers = [HTTPHeaderField(name: "Content-Type", value: contentType)]
        let rule = ResponseOverrideRule(
            id: id,
            label: label,
            requestMethod: matcher.method,
            requestScheme: matcher.scheme,
            host: matcher.host,
            port: matcher.port,
            path: matcher.path,
            matchMode: matcher.matchMode,
            sourceKind: .inlineText,
            sourceDescription: ResponseOverrideSourceKind.inlineText.sourceDescription,
            statusCode: statusCode,
            headers: headers,
            bodySource: .inline(bodyData),
            isEnabled: false,
            mcpOrigin: .mcp,
            mcpProvenance: provenance,
            forceNoCache: forceNoCache,
            graphQLOperationName: matcher.graphQLOperationName,
            matchQueryKey: matcher.matchQueryKey,
            matchQueryValue: matcher.matchQueryValue,
            sourceClientAddress: matcher.sourceClientAddress
        )
        try await responseOverrideStore.addRule(rule)
    }

    /// Persists a `.fixtureRun` Map Local rule (ADR-Streaming-Source-Redirect-To-Fixture.md).
    /// Unlike `persistInlineOverrideRule`, no body/status/content-type is resolved here — the
    /// fixture computes those live per request at dispatch time
    /// (`ResponseOverrides.ruleDecision(for:)` → `.fixtureRedirect`).
    private func persistFixtureRunOverrideRule(
        id: UUID,
        matcher: MCPMutationMatcher,
        fixtureRunID: UUID,
        label: String?,
        provenance: MCPProvenance
    ) async throws {
        let rule = ResponseOverrideRule(
            id: id,
            label: label,
            requestMethod: matcher.method,
            requestScheme: matcher.scheme,
            host: matcher.host,
            port: matcher.port,
            path: matcher.path,
            matchMode: matcher.matchMode,
            sourceKind: .fixtureRun,
            sourceDescription: "\(ResponseOverrideSourceKind.fixtureRun.sourceDescription) \(fixtureRunID.uuidString.prefix(8))",
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            isEnabled: false,
            mcpOrigin: .mcp,
            mcpProvenance: provenance,
            fixtureRunID: fixtureRunID,
            graphQLOperationName: matcher.graphQLOperationName,
            matchQueryKey: matcher.matchQueryKey,
            matchQueryValue: matcher.matchQueryValue,
            sourceClientAddress: matcher.sourceClientAddress
        )
        try await responseOverrideStore.addRule(rule)
    }

    /// Persists a `.localDirectory` Map Local rule from opaque bookmark bytes (AS).
    ///
    /// Builds the rule with the proposal's target ID (same pattern as fixture-run Map Local) so
    /// `apply_create_map_local` / enable-after flows share a stable override id with the proposal.
    private func persistLocalDirectoryOverrideRule(
        id: UUID,
        matcher: MCPMutationMatcher,
        bookmarkData: Data,
        notFoundRelativePath: String?,
        missingFilePolicy: LocalDirectoryMissingFilePolicy = .strictLocal,
        label: String?,
        provenance: MCPProvenance,
        forceNoCache: Bool
    ) async throws {
        // Plain (not security-scoped) bookmark resolution — see propose-side comment above;
        // JoesProxy isn't sandboxed, and security-scoped bookmarks don't survive the CLI→app
        // process boundary here.
        var isStale = false
        let directoryURL: URL
        do {
            directoryURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "localDirectoryBookmarkRef could not be resolved at apply: \(error.localizedDescription)"
            )
        }
        let didAccess = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { directoryURL.stopAccessingSecurityScopedResource() }
        }
        let trimmedNotFound = notFoundRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = ResponseOverrideRule(
            id: id,
            label: label,
            requestMethod: matcher.method,
            requestScheme: matcher.scheme,
            host: matcher.host,
            port: matcher.port,
            path: matcher.path,
            matchMode: .pathPrefix,
            sourceKind: .localDirectory,
            sourceDescription: "\(ResponseOverrideSourceKind.localDirectory.sourceDescription): \(directoryURL.lastPathComponent)",
            statusCode: 200,
            headers: [],
            bodySource: .directory(directoryURL),
            isEnabled: false,
            mcpOrigin: .mcp,
            mcpProvenance: provenance,
            forceNoCache: forceNoCache,
            notFoundRelativePath: (trimmedNotFound?.isEmpty == false) ? trimmedNotFound : nil,
            missingFilePolicy: missingFilePolicy,
            graphQLOperationName: matcher.graphQLOperationName,
            matchQueryKey: matcher.matchQueryKey,
            matchQueryValue: matcher.matchQueryValue,
            sourceClientAddress: matcher.sourceClientAddress
        )
        try await responseOverrideStore.addRule(rule)
    }

    /// Applies a `.localFile` Map Local plan — re-resolves the same plain bookmark bytes the
    /// propose step already validated, then persists a static rule pointing at that one file.
    private func persistLocalFileOverrideRule(
        id: UUID,
        matcher: MCPMutationMatcher,
        bookmarkData: Data,
        statusCode: Int,
        contentType: String,
        label: String?,
        provenance: MCPProvenance,
        forceNoCache: Bool
    ) async throws {
        var isStale = false
        let fileURL: URL
        do {
            fileURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "localFileBookmarkRef could not be resolved at apply: \(error.localizedDescription)"
            )
        }
        let rule = ResponseOverrideRule(
            id: id,
            label: label,
            requestMethod: matcher.method,
            requestScheme: matcher.scheme,
            host: matcher.host,
            port: matcher.port,
            path: matcher.path,
            matchMode: matcher.matchMode,
            sourceKind: .localFile,
            sourceDescription: "\(ResponseOverrideSourceKind.localFile.sourceDescription): \(fileURL.lastPathComponent)",
            statusCode: statusCode,
            headers: [HTTPHeaderField(name: "Content-Type", value: contentType)],
            bodySource: .file(fileURL),
            isEnabled: false,
            mcpOrigin: .mcp,
            mcpProvenance: provenance,
            forceNoCache: forceNoCache,
            graphQLOperationName: matcher.graphQLOperationName,
            matchQueryKey: matcher.matchQueryKey,
            matchQueryValue: matcher.matchQueryValue,
            sourceClientAddress: matcher.sourceClientAddress
        )
        try await responseOverrideStore.addRule(rule)
    }

    private func persistMapRemoteRule(
        id: UUID,
        matcher: MCPMutationMatcher,
        remoteHost: String,
        remotePort: Int?,
        remoteScheme: SessionScheme,
        remotePath: String? = nil,
        remoteQueryPolicy: MapRemoteQueryPolicy = .preserve,
        remoteQuery: String? = nil,
        allowLoopbackDestination: Bool = false,
        preserveHostHeader: Bool = false,
        label: String?,
        provenance: MCPProvenance
    ) async throws {
        let resolvedPort = remotePort ?? Self.defaultPort(for: remoteScheme)
        let normalizedHost = LoopbackAddressInspector.stripBracketsAndTrailingDot(remoteHost).host
        let effectiveHost = normalizedHost.isEmpty ? remoteHost.lowercased() : normalizedHost
        let description = "\(ResponseOverrideSourceKind.mapRemote.sourceDescription): \(remoteScheme.rawValue)://\(effectiveHost):\(resolvedPort)\(remotePath ?? "")"
        let rule = ResponseOverrideRule(
            id: id,
            label: label,
            requestMethod: matcher.method,
            requestScheme: matcher.scheme,
            host: matcher.host,
            port: matcher.port,
            path: matcher.path,
            matchMode: matcher.matchMode,
            sourceKind: .mapRemote,
            sourceDescription: description,
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            isEnabled: false,
            mapRemoteHost: effectiveHost,
            mapRemotePort: resolvedPort,
            mapRemoteScheme: remoteScheme,
            mapRemotePath: remotePath,
            mapRemoteQueryPolicy: remoteQueryPolicy,
            mapRemoteQuery: remoteQuery,
            allowLoopbackDestination: allowLoopbackDestination,
            preserveHostHeader: preserveHostHeader,
            mcpOrigin: .mcp,
            mcpProvenance: provenance,
            graphQLOperationName: matcher.graphQLOperationName,
            matchQueryKey: matcher.matchQueryKey,
            matchQueryValue: matcher.matchQueryValue,
            sourceClientAddress: matcher.sourceClientAddress
        )
        try await responseOverrideStore.addRule(rule)
    }

    private func persistLiveResponseRewriteRule(
        id: UUID,
        matcher: MCPMutationMatcher,
        jsonPath: String,
        overrideValue: BookmarkJSONValue,
        operation: JSONMutationOperation,
        repeatPolicy: JSONMutationRepeatPolicy = .always,
        label: String?,
        provenance: MCPProvenance
    ) async throws {
        let rewrite = BookmarkResponseFieldRewrite(
            jsonPath: jsonPath,
            overrideValue: overrideValue,
            operation: operation,
            isRuleEnabled: true,
            repeatPolicy: repeatPolicy
        )
        let rule = ResponseOverrideRule(
            id: id,
            label: label,
            requestMethod: matcher.method,
            requestScheme: matcher.scheme,
            host: matcher.host,
            port: matcher.port,
            path: matcher.path,
            matchMode: matcher.matchMode,
            sourceKind: .liveResponseRewrite,
            sourceDescription: LiveResponseRewriteDescriptions.ruleSourceDescription(rewrites: [rewrite]),
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            isEnabled: false,
            liveResponseRewrites: [rewrite],
            mcpOrigin: .mcp,
            mcpProvenance: provenance,
            graphQLOperationName: matcher.graphQLOperationName,
            matchQueryKey: matcher.matchQueryKey,
            matchQueryValue: matcher.matchQueryValue,
            sourceClientAddress: matcher.sourceClientAddress
        )
        try await responseOverrideStore.addRule(rule)
    }

    private func persistBookmarkRewrite(
        bookmarkID: UUID,
        jsonPath: String,
        overrideValue: BookmarkJSONValue,
        operation: JSONMutationOperation = .set,
        provenance: MCPProvenance
    ) throws {
        var bookmarks = bookmarkStore.loadBookmarks()
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            throw MCPStructuredError(code: .conflict, message: "Bookmark not found during apply.")
        }
        var bookmark = bookmarks[index]
        let rewrite = BookmarkResponseFieldRewrite(
            jsonPath: jsonPath,
            overrideValue: overrideValue,
            operation: operation,
            isRuleEnabled: false
        )
        bookmark.responseRewrites.append(rewrite)
        bookmark.mcpOrigin = .mcp
        bookmark.mcpProvenance = provenance
        bookmarks[index] = MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(bookmark)
        try MCPBookmarkStoreSupport.saveBookmarks(bookmarks, to: bookmarkStore, applyingRevisionToUpdated: bookmarks[index], provenance: provenance, origin: .mcp)
    }

    private func persistBookmark(
        id: UUID,
        name: String,
        request: CapturedRequest,
        matchMode: ResponseOverrideMatchMode,
        provenance: MCPProvenance
    ) throws {
        let bookmark = Bookmark(
            id: id,
            name: name,
            request: request,
            responseMatchMode: matchMode,
            mcpOrigin: .mcp,
            mcpProvenance: provenance
        )
        var bookmarks = bookmarkStore.loadBookmarks()
        bookmarks.append(bookmark)
        try MCPBookmarkStoreSupport.saveBookmarks(bookmarks, to: bookmarkStore, applyingRevisionToUpdated: bookmark, provenance: provenance, origin: .mcp)
    }

    // MARK: - Conflict detection

    /// Evaluates historical capture cardinality and live confounders for a matcher (P1-05).
    ///
    /// Concurrency: `@MainActor`; awaits enabled rules from ``responseOverrideStore``.
    func evaluateMatcherScopeConflicts(
        matcher: MCPMutationMatcher,
        excludingRuleID: UUID?
    ) async -> MatcherScopeConflictEvaluation {
        let observedAt = Date()
        let cardinality: Int
        if let snapshotService {
            cardinality = snapshotService.sourceSessionStore.sessions.filter {
                matches(matcher: matcher, request: $0.request)
            }.count
        } else {
            cardinality = 0
        }
        let probe = Self.capturedRequest(from: matcher)
        let rules = await responseOverrideStore.rules()
        let conflicting = rules.compactMap { rule -> String? in
            guard rule.isEnabled else { return nil }
            if let excludingRuleID, rule.id == excludingRuleID { return nil }
            return ruleMatchesProbe(rule: rule, probe: probe, matcher: matcher) ? rule.id.uuidString : nil
        }.sorted()
        let scenarios = (activeScenarioIDsProvider?() ?? []).sorted()
        return MatcherScopeConflictEvaluation(
            observedCaptureCardinality: cardinality,
            observedAt: observedAt,
            conflictingEnabledRuleIDs: conflicting,
            activeScenarioIDs: scenarios
        )
    }

    /// Safe matcher-scope disclosure dictionary (no bodies, URIs, or query values).
    func matcherScopeDisclosure(
        matcher: MCPMutationMatcher,
        evaluation: MatcherScopeConflictEvaluation
    ) -> [String: Any] {
        [
            "method": matcher.method,
            "scheme": matcher.scheme.rawValue,
            "host": matcher.host,
            "port": matcher.port as Any,
            "path": matcher.path,
            "matchMode": matcher.matchMode.rawValue,
            "observedCaptureCardinality": evaluation.observedCaptureCardinality,
            "cardinalityIsHistorical": evaluation.cardinalityIsHistorical,
            "observedAt": ISO8601DateFormatter().string(from: evaluation.observedAt),
            "conflictingEnabledRuleIDs": evaluation.conflictingEnabledRuleIDs,
            "activeScenarioIDs": evaluation.activeScenarioIDs,
            "warning": (evaluation.warning as Any?) ?? NSNull()
        ]
    }

    /// Fail-closed enable gate when confounders exist unless `acceptConfounder` is true.
    func requireAcceptedConfoundersIfNeeded(
        evaluation: MatcherScopeConflictEvaluation,
        matcher: MCPMutationMatcher,
        arguments: [String: Any]
    ) throws {
        guard evaluation.hasConfounders(matchMode: matcher.matchMode) else { return }
        guard arguments["acceptConfounder"] as? Bool == true else {
            throw MCPStructuredError(
                code: .malformedRequest,
                message: "Enabling this rule would confound a clean measurement "
                    + "(overlapping enabled rules, active scenarios, or multi-match pathSuffix). "
                    + "Pass acceptConfounder: true to proceed anyway.",
                details: [
                    "observedCaptureCardinality": "\(evaluation.observedCaptureCardinality)",
                    "observedAt": ISO8601DateFormatter().string(from: evaluation.observedAt),
                    "conflictingEnabledRuleIDs": evaluation.conflictingEnabledRuleIDs.joined(separator: ","),
                    "activeScenarioIDs": evaluation.activeScenarioIDs.joined(separator: ","),
                    "matchMode": matcher.matchMode.rawValue
                ]
            )
        }
    }

    /// Path-aware probe: whether an enabled rule would match the synthetic request for `matcher`.
    private func ruleMatchesProbe(rule: ResponseOverrideRule, probe: CapturedRequest, matcher: MCPMutationMatcher) -> Bool {
        guard rule.requestMethod.caseInsensitiveCompare(probe.method) == .orderedSame,
              rule.requestScheme == probe.scheme,
              rule.host.caseInsensitiveCompare(probe.host) == .orderedSame else {
            return false
        }
        let rulePort = rule.port ?? Self.defaultPort(for: rule.requestScheme)
        let probePort = probe.port ?? Self.defaultPort(for: probe.scheme)
        guard rulePort == probePort else { return false }
        let rulePath = normalizedPathForMatch(rule.path, mode: rule.matchMode)
        let requestPath = normalizedPathForMatch(probe.path, mode: rule.matchMode)
        guard pathMatches(rulePath: rulePath, requestPath: requestPath, mode: rule.matchMode) else {
            return false
        }
        return Self.graphQLOperationNamesOverlap(rule.graphQLOperationName, probeGraphQLOperationName(from: probe)) &&
            Self.queryPredicatesOverlap(
                lhsKey: rule.matchQueryKey, lhsValue: rule.matchQueryValue,
                rhsKey: matcher.matchQueryKey, rhsValue: matcher.matchQueryValue
            ) &&
            Self.clientAddressesOverlap(rule.sourceClientAddress, probe.clientAddress)
    }

    /// Mirrors `ResponseOverrideStore`'s private body-parsing helper — extracts the synthesized
    /// probe body's `operationName`, if `capturedRequest(from matcher:)` set one.
    private func probeGraphQLOperationName(from probe: CapturedRequest) -> String? {
        guard let bodyData = probe.bodyData,
              let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }
        return object["operationName"] as? String
    }

    private func normalizedPathForMatch(_ path: String, mode: ResponseOverrideMatchMode) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "/" : trimmed
        switch mode {
        case .exactPath:
            return normalized
        case .ignoreQuery, .pathPrefix, .pathSuffix, .filename:
            return String(normalized.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/")
        }
    }

    private func pathMatches(rulePath: String, requestPath: String, mode: ResponseOverrideMatchMode) -> Bool {
        switch mode {
        case .exactPath, .ignoreQuery:
            return rulePath == requestPath
        case .pathPrefix:
            if rulePath == "/" { return true }
            return requestPath == rulePath || requestPath.hasPrefix(rulePath.hasSuffix("/") ? rulePath : "\(rulePath)/")
        case .pathSuffix:
            return requestPath.hasSuffix(rulePath)
        case .filename:
            return lastPathComponent(of: rulePath) == lastPathComponent(of: requestPath)
        }
    }

    private func conflictingTargetIDs(for plan: MCPMutationPlan) async -> [String] {
        guard let matcher = plan.matcher else { return [] }
        let evaluation = await evaluateMatcherScopeConflicts(matcher: matcher, excludingRuleID: nil)
        return evaluation.conflictingEnabledRuleIDs
    }

    /// Two `graphQLOperationName` values "overlap" (would both match the same live request) when
    /// they're equal, or when either is nil (nil matches every operation, including whatever the
    /// other one requires). Mirrors `ResponseOverrideStore`'s private helper of the same name —
    /// duplicated per this codebase's existing convention of independent per-file matcher helpers.
    private static func graphQLOperationNamesOverlap(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    /// Mirrors `ResponseOverrideStore`'s private helper of the same name — duplicated per this
    /// codebase's existing convention of independent per-file matcher helpers.
    private static func queryPredicatesOverlap(
        lhsKey: String?, lhsValue: String?,
        rhsKey: String?, rhsValue: String?
    ) -> Bool {
        guard let lhsKey, let lhsValue, let rhsKey, let rhsValue else { return true }
        guard lhsKey == rhsKey else { return true }
        return lhsValue == rhsValue
    }

    private static func clientAddressesOverlap(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines), !lhs.isEmpty,
              let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines), !rhs.isEmpty else {
            return true
        }
        return lhs == rhs
    }

    /// G6-02: unlike `conflictingTargetIDs` (enabled path-aware disclosure), this requires an EXACT scope match — method, host, scheme, path, and matchMode
    /// all identical — before treating an existing `.inlineText` (Map Local) rule as a real
    /// duplicate of a proposed one. A looser match would false-positive on two legitimately
    /// different Map Local rules that merely share a host.
    private func exactScopeMapLocalConflict(
        matcher: MCPMutationMatcher,
        proposedBodyData: Data
    ) async -> (ruleID: String, bodyIdentical: Bool)? {
        let rules = await responseOverrideStore.rules()
        guard let existing = rules.first(where: { rule in
            rule.sourceKind == .inlineText &&
                rule.requestMethod.caseInsensitiveCompare(matcher.method) == .orderedSame &&
                rule.host.caseInsensitiveCompare(matcher.host) == .orderedSame &&
                rule.requestScheme == matcher.scheme &&
                rule.path == matcher.path &&
                rule.matchMode == matcher.matchMode &&
                Self.graphQLOperationNamesOverlap(rule.graphQLOperationName, matcher.graphQLOperationName) &&
                Self.queryPredicatesOverlap(
                    lhsKey: rule.matchQueryKey, lhsValue: rule.matchQueryValue,
                    rhsKey: matcher.matchQueryKey, rhsValue: matcher.matchQueryValue
                ) &&
                Self.clientAddressesOverlap(rule.sourceClientAddress, matcher.sourceClientAddress)
        }) else {
            return nil
        }
        // G6-02 option 2: only `.inline` bodies (what every MCP-created Map Local rule actually
        // uses, per `persistInlineOverrideRule`) can be compared directly here. A `.file`-backed
        // rule (manually authored, not an MCP path) is conservatively never reported as identical
        // — we don't read arbitrary local files just to answer this hint.
        let bodyIdentical: Bool
        if case .inline(let existingBody) = existing.bodySource {
            bodyIdentical = existingBody == proposedBodyData
        } else {
            bodyIdentical = false
        }
        return (existing.id.uuidString, bodyIdentical)
    }

    // MARK: - Audit

    func recordProposalCreated(client: MCPClientRecord, capability: MCPCapabilityID, detail: String) {
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .proposalCreated,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: capability.rawValue,
                detail: detail
            )
        )
    }

    func recordApplied(client: MCPClientRecord, capability: MCPCapabilityID, targetID: String, detail: String) {
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .proposalApplied,
                timestamp: Date(),
                clientID: client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "\(capability.rawValue):\(targetID)",
                detail: detail
            )
        )
    }

    // MARK: - DTO helpers

    private static func bookmarkSummary(_ bookmark: Bookmark) -> MCPBookmarkSummaryDTO {
        MCPBookmarkSummaryDTO(
            id: bookmark.id.uuidString,
            name: bookmark.name,
            method: bookmark.request.method,
            host: bookmark.request.host,
            path: bookmark.request.path,
            matchMode: bookmark.responseMatchMode.rawValue,
            rewriteMode: bookmark.responseRewriteMode.rawValue,
            enabledRewriteCount: bookmark.enabledResponseRewriteCount,
            hasSavedResponse: bookmark.hasSavedResponse,
            mcpOrigin: bookmark.mcpOrigin?.rawValue,
            mcpClientID: bookmark.mcpProvenance?.clientID,
            mcpTargetRevision: bookmark.mcpTargetRevision?.rawValue,
            createdAt: bookmark.createdAt
        )
    }

    private static func bookmarkDecision(_ summary: MCPBookmarkSummaryDTO) -> MCPBookmarkDecisionDTO {
        MCPBookmarkDecisionDTO(
            id: summary.id,
            name: summary.name,
            method: summary.method,
            enabledRewriteCount: summary.enabledRewriteCount,
            hasSavedResponse: summary.hasSavedResponse
        )
    }

    private static func bookmarkContext(_ summary: MCPBookmarkSummaryDTO) -> MCPBookmarkContextDTO {
        MCPBookmarkContextDTO(
            id: summary.id,
            name: summary.name,
            method: summary.method,
            host: summary.host,
            path: summary.path,
            matchMode: summary.matchMode,
            rewriteMode: summary.rewriteMode,
            enabledRewriteCount: summary.enabledRewriteCount,
            hasSavedResponse: summary.hasSavedResponse
        )
    }

    private static func overrideSummary(_ rule: ResponseOverrideRule) -> MCPOverrideSummaryDTO {
        let livePaths = rule.liveResponseRewrites.filter(\.isRuleEnabled).map(\.jsonPath)
        let bookmark = rule.bookmarkRewriteRequest
        let directoryName: String? = {
            if case .directory(let url) = rule.bodySource {
                return url.lastPathComponent
            }
            return nil
        }()
        let fileName: String? = {
            if rule.sourceKind == .localFile, case .file(let url) = rule.bodySource {
                return url.lastPathComponent
            }
            return nil
        }()
        return MCPOverrideSummaryDTO(
            id: rule.id.uuidString,
            label: rule.label,
            method: rule.requestMethod,
            host: rule.host,
            path: rule.path,
            matchMode: rule.matchMode.rawValue,
            sourceKind: rule.sourceKind.rawValue,
            isEnabled: rule.isEnabled,
            statusCode: rule.statusCode,
            mcpOrigin: rule.mcpOrigin?.rawValue,
            mcpClientID: rule.mcpProvenance?.clientID,
            mcpTargetRevision: rule.mcpTargetRevision?.rawValue,
            createdAt: rule.createdAt,
            scheme: rule.requestScheme.rawValue,
            port: rule.port,
            sourceDescription: rule.sourceDescription,
            hitCount: rule.hitCount,
            lastMatchedAt: rule.lastMatchedAt,
            dropConnection: rule.sourceKind == .block ? rule.dropConnection : nil,
            mapRemoteHost: rule.mapRemoteHost,
            mapRemotePort: rule.mapRemotePort,
            mapRemoteScheme: rule.mapRemoteScheme?.rawValue,
            mapRemotePath: rule.mapRemotePath,
            mapRemoteQueryPolicy: rule.sourceKind == .mapRemote ? rule.mapRemoteQueryPolicy.rawValue : nil,
            mapRemoteQuery: rule.mapRemoteQuery,
            allowLoopbackDestination: rule.sourceKind == .mapRemote ? rule.allowLoopbackDestination : nil,
            preserveHostHeader: rule.sourceKind == .mapRemote ? rule.preserveHostHeader : nil,
            bookmarkRewriteMethod: bookmark?.method,
            bookmarkRewriteHost: bookmark?.host,
            bookmarkRewritePath: bookmark?.path,
            liveRewritePaths: livePaths.isEmpty ? nil : livePaths,
            fixtureRunID: rule.fixtureRunID?.uuidString,
            localDirectoryName: directoryName,
            localFileName: fileName,
            missingFilePolicy: rule.sourceKind == .localDirectory ? rule.missingFilePolicy.rawValue : nil,
            forceNoCache: rule.forceNoCache ? true : nil,
            graphqlOperationName: rule.graphQLOperationName,
            matchQueryKey: rule.matchQueryKey,
            matchQueryValue: rule.matchQueryValue,
            sourceClientAddress: rule.sourceClientAddress
        )
    }

    private static func overrideDecision(_ summary: MCPOverrideSummaryDTO) -> MCPOverrideDecisionDTO {
        MCPOverrideDecisionDTO(
            id: summary.id,
            label: summary.label,
            sourceKind: summary.sourceKind,
            isEnabled: summary.isEnabled,
            statusCode: summary.statusCode,
            hitCount: summary.hitCount
        )
    }

    private static func overrideContext(_ summary: MCPOverrideSummaryDTO) -> MCPOverrideContextDTO {
        MCPOverrideContextDTO(
            id: summary.id,
            label: summary.label,
            method: summary.method,
            host: summary.host,
            path: summary.path,
            matchMode: summary.matchMode,
            sourceKind: summary.sourceKind,
            isEnabled: summary.isEnabled,
            statusCode: summary.statusCode,
            scheme: summary.scheme,
            port: summary.port,
            sourceDescription: summary.sourceDescription,
            hitCount: summary.hitCount,
            lastMatchedAt: summary.lastMatchedAt,
            dropConnection: summary.dropConnection,
            mapRemoteHost: summary.mapRemoteHost,
            mapRemotePort: summary.mapRemotePort,
            mapRemoteScheme: summary.mapRemoteScheme,
            mapRemotePath: summary.mapRemotePath,
            mapRemoteQueryPolicy: summary.mapRemoteQueryPolicy,
            allowLoopbackDestination: summary.allowLoopbackDestination,
            preserveHostHeader: summary.preserveHostHeader,
            liveRewritePaths: summary.liveRewritePaths,
            fixtureRunID: summary.fixtureRunID,
            localDirectoryName: summary.localDirectoryName,
            localFileName: summary.localFileName,
            missingFilePolicy: summary.missingFilePolicy,
            forceNoCache: summary.forceNoCache,
            graphqlOperationName: summary.graphqlOperationName,
            matchQueryKey: summary.matchQueryKey,
            matchQueryValue: summary.matchQueryValue,
            sourceClientAddress: summary.sourceClientAddress
        )
    }

    private static func capturedRequest(from matcher: MCPMutationMatcher) -> CapturedRequest {
        // Synthesize a minimal JSON body carrying just the matcher's operationName, if any, so
        // `ruleMatchesProbe` can evaluate a GraphQL-scoped rule against this probe the same way the
        // live dispatch path would — otherwise a bodyless probe could never see an operationName
        // and would spuriously fail to detect a real overlap.
        let bodyData: Data? = matcher.graphQLOperationName.flatMap {
            try? JSONSerialization.data(withJSONObject: ["operationName": $0])
        }
        return CapturedRequest(
            method: matcher.method,
            scheme: matcher.scheme,
            inspectionKind: .plain,
            inspectionReason: nil,
            host: matcher.host,
            port: matcher.port ?? defaultPort(for: matcher.scheme),
            path: matcher.path,
            headers: [],
            bodyData: bodyData,
            bodySize: bodyData?.count,
            clientAddress: matcher.sourceClientAddress
        )
    }

    private static func defaultPort(for scheme: SessionScheme) -> Int {
        scheme == .https ? 443 : 80
    }

    func matchScope(for plan: MCPMutationPlan) -> MCPMutationMatchScopeDTO {
        if let matcher = plan.matcher {
            return MCPMutationMatchScopeDTO(
                method: matcher.method,
                host: matcher.host,
                path: matcher.path,
                matchMode: matcher.matchMode.rawValue,
                scheme: matcher.scheme == .https ? "https" : "http",
                port: matcher.port,
                graphqlOperationName: matcher.graphQLOperationName,
                matchQueryKey: matcher.matchQueryKey,
                matchQueryValue: matcher.matchQueryValue,
                sourceClientAddress: matcher.sourceClientAddress
            )
        }
        return MCPMutationMatchScopeDTO(
            method: "",
            host: "",
            path: plan.rewriteJSONPath ?? "",
            matchMode: "bookmarkRewrite",
            scheme: nil,
            port: nil,
            graphqlOperationName: nil,
            matchQueryKey: nil,
            matchQueryValue: nil,
            sourceClientAddress: nil
        )
    }

    func targetLockKey(for plan: MCPMutationPlan) -> String {
        switch plan.capability {
        case .createDisabledBookmark:
            return "bookmark:\(plan.proposedTargetID.uuidString)"
        case .createDisabledRewrite:
            return "bookmark:\(plan.proposedTargetID.uuidString)"
        case .createResponseDraft:
            return "response-draft:\(plan.proposedTargetID.uuidString)"
        default:
            return "override:\(plan.proposedTargetID.uuidString)"
        }
    }

    func makeProvenance(clientID: String, capability: MCPCapabilityID) -> MCPProvenance {
        MCPProvenance(
            clientID: clientID,
            operationID: UUID().uuidString,
            capability: capability,
            createdAt: Date()
        )
    }

    func applyResultDTO(result: MCPProposalApplyResult, targetID: String, isEnabled: Bool) -> MCPMutationApplyResultDTO {
        MCPMutationApplyResultDTO(
            transactionID: result.transactionID,
            appliedAt: result.appliedAt,
            targetID: targetID,
            isEnabled: isEnabled
        )
    }

    func idempotencyKey(from arguments: [String: Any]) -> MCPIdempotencyKey? {
        if let raw = arguments["idempotencyKey"] as? String, !raw.isEmpty {
            return MCPIdempotencyKey(rawValue: raw)
        }
        guard let proposalToken = arguments["proposalToken"] as? String, !proposalToken.isEmpty else {
            return nil
        }
        return MCPIdempotencyKey(rawValue: "proposal:\(proposalToken)")
    }

    private func responseProjection(_ arguments: [String: Any]) throws -> MCPResponseProjection {
        guard let rawValue = arguments["projection"] as? String else {
            return .minimal
        }
        guard let projection = MCPResponseProjection(rawValue: rawValue) else {
            throw MCPStructuredError.malformedRequest(
                message: "projection must be minimal, summary, or full."
            )
        }
        return projection
    }

    func payloadDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPStructuredError(code: .internalFailure, message: "Payload encoding failed.")
        }
        return object
    }

    private func encodeListOffset(_ offset: Int) -> String {
        Data("\(offset)".utf8).base64EncodedString()
    }

    private func decodeListOffset(_ cursor: String?) -> Int {
        guard let cursor,
              let data = Data(base64Encoded: cursor),
              let string = String(data: data, encoding: .utf8),
              let offset = Int(string),
              offset >= 0 else {
            return 0
        }
        return offset
    }
}
