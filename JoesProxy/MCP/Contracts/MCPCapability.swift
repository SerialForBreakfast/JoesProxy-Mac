import Foundation

/// Capability risk tiers used for policy, approval, and UI attention levels.
enum MCPCapabilityRiskTier: String, Equatable, Sendable, Codable, CaseIterable {
    case passiveResource
    case readOnlyTool
    case sensitiveReadTool
    case mutatingTool
    case openWorldTool
    case destructiveTool
    case expensiveInspection

    /// Explicit severity ordering (AI-0) so "highest risk across composed faults" is well-defined
    /// and doesn't silently depend on `CaseIterable` declaration order.
    var severityRank: Int {
        switch self {
        case .passiveResource: return 0
        case .readOnlyTool: return 1
        case .sensitiveReadTool: return 2
        case .expensiveInspection: return 3
        case .mutatingTool: return 4
        case .openWorldTool: return 5
        case .destructiveTool: return 6
        }
    }
}

/// Stable capability identifiers referenced by policy, audit, and tool routing.
enum MCPCapabilityID: String, Equatable, Sendable, Codable, CaseIterable {
    var requiresOneUseApproval: Bool { self == .httpsRulesManage || self == .artifactSourceAccess || self == .artifactCompare }

    case artifactSourceAccess
    case artifactSourceRelease
    case artifactCalculate
    case artifactSearch
    case artifactBrief
    case artifactCompare

    case serverResource
    case captureResource
    case healthResource
    case agentResource
    case sessionList
    case sessionSearch
    case sessionSummary
    case deviceInspect
    case deviceAliasManage
    case disclosurePreview
    case headerRead
    case queryRead
    case bodyRead
    case mediaSummary
    case mediaInspection
    case bookmarkInspect
    case overrideInspect
    case createDisabledBookmark
    case createDisabledMapLocal
    case createDisabledMapRemote
    case createDisabledBlock
    case createDisabledRewrite
    case createDisabledLiveRewrite
    /// Create-disabled reviewed collection-shape mutation (`.collectionMock` rule).
    case createDisabledCollectionMock
    case enableRule
    case disableRule
    /// Permanently delete an MCP-owned response override rule.
    case deleteRule
    case changeThrottle
    case executeBookmark
    case activateMapRemote
    case activateLiveRewrite
    /// Enable an MCP-created `.collectionMock` rule with destination/plan disclosure.
    case activateCollectionMock
    case replayRequest
    case liveMediaProbe
    case returnToNormal
    case runtimeControl
    case httpsRulesInspect
    case httpsRulesManage
    case scenarioLifecycle
    /// Deterministic structural profile of captured JSON response bodies — no mutation, no
    /// network, never discloses raw values.
    case structuralDiscovery
    /// Capture-only preview of a candidate live-rewrite rule against already-captured sessions —
    /// no live-traffic effect, nothing persisted.
    case transformationPreview
    /// Metadata-only response body availability and editability for generic response editing.
    case responseContext
    /// Exact-literal search over a captured response revision; context windows use ``bodyRead``.
    case responseTextSearch
    /// List/get metadata for JoesProxy-managed response drafts (no body bytes).
    case responseDraftInspect
    /// Propose/apply create, commit, rename, or delete of a response draft.
    case createResponseDraft
    /// Read-only HLS fixture capabilities, profiles, and run status.
    case hlsFixtureInspect
    /// Propose/apply start and owned stop of an HLS fixture reserved-origin run.
    case hlsFixtureLifecycle
    /// Atomic fixture + same-origin routing lifecycle for first-class HLS test-stream substitution.
    case hlsSubstitutionLifecycle
    /// Read-only OpenAPI mock-pack preview and status.
    case openAPIMockInspect
    /// Propose/apply start and owner-scoped stop of one OpenAPI mock pack.
    case openAPIMockLifecycle
    /// Read-only diagnostic-run list/status/observations/evidence.
    case diagnosticRunInspect
    /// Create/start/close diagnostic runs and approve regression re-checks that recreate effects.
    case diagnosticRunLifecycle
    /// Read-only local CA status (fingerprint, validity, trust install state).
    case certificateStatus
    /// Read-only CA instance identity card fields.
    case certificateIdentity
    /// List generated profile distribution artifacts for known CA fingerprints.
    case certificateArtifactsList
    /// Compare two certificate fingerprints without mutating trust.
    case certificateCompare
    /// Export the plain public root CA certificate bytes — no private key material, safe to
    /// disclose freely (a CA certificate is meant to be publicly trusted/distributed).
    case certificateExport
    /// Fingerprint-targeted cleanup of retired/legacy trust material (destructive).
    case certificateCleanup
    /// Read-only, target-specific onboarding evidence with explicit observability boundaries.
    case setupReadiness

    // MARK: - Advanced agentic diagnostics (AG-1..AG-6)

    /// Create/advance a local hypothesis-DAG fault-bisection plan — no live-traffic effect.
    case agenticGraphLifecycle
    /// Read-only hypothesis-DAG bisection report.
    case agenticGraphInspect
    /// Read captured session traffic for LLM (SSE) stream shape, timing, and canary-leak analysis.
    /// Sensitive-read tier: LLM prompt/completion content can carry the same kind of secrets as
    /// any other response body.
    case llmStreamInspect
    /// Register a live LLM-stream fault-injection rule affecting real in-flight SSE traffic.
    case llmStreamFaultInject
    /// Create/advance a local temporal-permutation (race-condition) fuzzing plan.
    case concurrencyFuzzingLifecycle
    /// Read-only race-condition fuzzing report.
    case concurrencyFuzzingInspect
    /// Create/advance a local counterfactual-resilience bisection plan.
    case resilienceBisectionLifecycle
    /// Read-only client-resilience matrix report.
    case resilienceBisectionInspect
    /// Read-only behavioral trajectory diff between two sets of captured sessions.
    case trajectoryDiffInspect
    /// Register a live semantic (similarity-matched) wire-mocking rule.
    case semanticMockLifecycle
    /// Read-only semantic mock rule listing and dry-run query matching (no live traffic effect).
    case semanticMockInspect
    /// Permanently remove an MCP-owned semantic mock rule.
    case semanticMockDelete
    /// Read-only endpoint contract diff / breaking-schema-change regression summary.
    case contractDiffInspect
    /// Read-only search correlating a target value's provenance across captured sessions.
    /// Sensitive-read tier: the whole point is finding where a value (often a token or
    /// account identifier) flows across otherwise-unrelated traffic.
    case dataLineageTrace
    /// Capture-only preview of a candidate provenance-watermarking rule — no live effect, nothing
    /// persisted (there is no corresponding activation tool yet).
    case provenanceWatermarkPreview
    /// Read-only localization/pseudo-localization presets and a preview transform — no live rule
    /// is installed.
    case localizationMockPreview
    /// Read-only stateful-mock virtual backend listing, preset listing, and entity queries.
    case statefulMockInspect
    /// Install, set state on, or reset a live stateful-mock virtual backend.
    case statefulMockLifecycle
    /// Start, advance, or cancel a local fault-isolation session (distinct from the hypothesis-DAG
    /// bisection above — a simpler, single active-session state machine).
    case faultIsolationLifecycle
    /// Read-only fault-isolation session report.
    case faultIsolationInspect
    /// Read-only advanced media inspection: CMCD/CMSD telemetry, WebVTT sync drift, DRM handshake
    /// audit, byte-range/CDN efficiency, streaming quality waterfall, visual asset inspection,
    /// SCTE-35 ad-break alignment. Same risk profile as ``mediaSummary`` — capture-only, bounded
    /// aggregate facts, no raw-value disclosure beyond what ``mediaSummary`` already allows.
    case mediaAdvancedInspection
    /// Read-only catalog of bundled synthetic assets (test-pattern image, clear live/VOD HLS,
    /// synthetic VAST ad) available for collection injection.
    case syntheticAssetInspect
    /// Register a live schema-inferred collection-injection plan — inserts a synthetic item into
    /// a matching JSON collection response for a scoped client set (simulator-only by default).
    case syntheticInjectionLifecycle
    /// Read-only listing of currently armed synthetic-injection plans.
    case syntheticInjectionInspect
    /// Permanently remove one armed synthetic-injection plan.
    case syntheticInjectionDelete
}

extension MCPCapabilityID {
    /// Maps each capability to its ADR risk tier.
    var riskTier: MCPCapabilityRiskTier {
        switch self {
        case .serverResource, .captureResource, .healthResource, .agentResource:
            return .passiveResource
        case .sessionList, .sessionSearch, .sessionSummary, .deviceInspect, .disclosurePreview,
             .bookmarkInspect, .overrideInspect, .structuralDiscovery, .transformationPreview,
             .responseContext, .responseTextSearch, .responseDraftInspect, .hlsFixtureInspect,
             .openAPIMockInspect, .diagnosticRunInspect,
             .certificateStatus, .certificateIdentity, .certificateArtifactsList, .certificateCompare,
             .certificateExport:
            return .readOnlyTool
        case .setupReadiness, .httpsRulesInspect:
            return .readOnlyTool
        case .artifactSourceAccess, .artifactCalculate, .artifactSearch, .artifactBrief, .artifactCompare, .headerRead, .queryRead, .bodyRead:
            return .sensitiveReadTool
        case .artifactSourceRelease:
            return .readOnlyTool
        case .mediaSummary:
            return .readOnlyTool
        case .mediaInspection:
            return .expensiveInspection
        case .deviceAliasManage,
             .createDisabledBookmark, .createDisabledMapLocal, .createDisabledMapRemote,
             .createDisabledBlock, .createDisabledRewrite, .createDisabledLiveRewrite,
             .createDisabledCollectionMock,
             .createResponseDraft,
             .enableRule, .disableRule, .changeThrottle:
            return .mutatingTool
        case .executeBookmark, .activateMapRemote, .activateLiveRewrite, .activateCollectionMock,
             .replayRequest, .liveMediaProbe:
            return .openWorldTool
        case .returnToNormal, .runtimeControl, .httpsRulesManage:
            return .mutatingTool
        case .scenarioLifecycle, .hlsFixtureLifecycle, .hlsSubstitutionLifecycle, .openAPIMockLifecycle,
             .diagnosticRunLifecycle:
            return .mutatingTool
        case .deleteRule, .certificateCleanup, .semanticMockDelete:
            return .destructiveTool
        case .agenticGraphInspect, .concurrencyFuzzingInspect, .resilienceBisectionInspect,
             .trajectoryDiffInspect, .semanticMockInspect, .contractDiffInspect,
             .provenanceWatermarkPreview, .localizationMockPreview, .statefulMockInspect,
             .faultIsolationInspect, .mediaAdvancedInspection, .syntheticAssetInspect,
             .syntheticInjectionInspect:
            return .readOnlyTool
        case .llmStreamInspect, .dataLineageTrace:
            return .sensitiveReadTool
        case .agenticGraphLifecycle, .llmStreamFaultInject, .concurrencyFuzzingLifecycle,
             .resilienceBisectionLifecycle, .semanticMockLifecycle, .statefulMockLifecycle,
             .faultIsolationLifecycle, .syntheticInjectionLifecycle:
            return .mutatingTool
        case .syntheticInjectionDelete:
            return .destructiveTool
        }
    }
}
