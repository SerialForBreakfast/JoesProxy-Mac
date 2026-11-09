import Foundation

/// Single source of truth for production MCP tools, resources, workflows, and export manifests.
///
/// Concurrency: `Sendable` and stateless; callers on any actor may read catalog metadata.
enum MCPCapabilitiesManifestBuilder {
    static func analysis(for name: String) -> MCPAnalysisDescriptor? {
        switch name {
        case "artifact_inventory", "artifact_search":
            return .init(inputKind: "approved_saved_snapshot", method: name == "artifact_inventory" ? "typed_metadata_inventory" : "exact_nonoverlapping_utf8",
                limits: ["literalBytes": 4096, "scanBytesPerPage": 1_048_576, "recordsPerPage": 256, "itemsPerPage": 50, "outputBytes": 8192],
                coverage: "Exact total requires exhausted pages and complete selected input. Search-v1 local consent is required.",
                nextAction: "Follow nextCursor with unchanged query arguments and check coverage omissions.")
        case "capture_calculate", "artifact_calculate":
            return .init(inputKind: "explicit_live_or_approved_saved_selection", method: "deterministic_exact_decimal_calculations",
                limits: ["inputBytes": 1_048_576, "rows": 10_000, "groups": 256, "outputBytes": 16_384, "fractionalDigits": 6],
                coverage: "Complete selected domain only; group output omissions explicit. Live reads require body authority; saved sources require calculations-v1 consent.",
                nextAction: "Review counts and source identity before requesting selected source detail. No automatic retry or cache.")
        case "artifact_compare_responses":
            return .init(inputKind: "two_approved_saved_responses", method: "explicit_ordered_structure_diff",
                limits: ["responses": 2, "bytesPerResponse": 262144, "changes": 32, "outputBytes": 65536],
                coverage: "Both current brief shares and one local Compare once approval required. Partial evidence qualifies changes.",
                nextAction: "Inspect coverage before interpreting an omitted path.")
        case "artifact_response_brief":
            return .init(inputKind: "approved_recording_or_HAR_JSON_response", method: "deterministic_counts",
                limits: ["inputBytes": ResponseEvidenceBrief.maximumInputBytes, "fields": ResponseEvidenceBrief.maximumFields,
                         "structureNodes": 32, "outputBytes": 65536],
                coverage: "Selected response only. Check field omissions, structure coverage and source warnings. Requires local brief-v1 consent.",
                nextAction: "Narrow the selectionPointer to inspect a specific JSON subtree.")
        case "response_evidence_brief":
            return .init(inputKind: "retained_complete_JSON_response", method: "deterministic_counts",
                limits: ["inputBytes": ResponseEvidenceBrief.maximumInputBytes, "fields": ResponseEvidenceBrief.maximumFields, "structureNodes": 32, "depth": 4, "visitedValues": 20000],
                coverage: "Check status, omitted fields and structureCoverage; requires body-read authority.", nextAction: "Narrow selection or explicitly request approved source detail.")
        case "investigation_compare_brief":
            return .init(inputKind: "explicit_baseline_candidate_sessions", method: "deterministic_structure_with_qualified_alignment",
                limits: ["sessionsPerSide": InvestigationComparisonBrief.maximumSessionsPerSide, "aggregateInputBytes": InvestigationComparisonBrief.maximumAggregateInputBytes, "changes": InvestigationComparisonBrief.maximumChanges],
                coverage: "Missing sources and bounded traversal remain incomplete; alignment is not causality.", nextAction: "Inspect selected source briefs under existing disclosure.")
        case "diagnostic_run_brief":
            return .init(inputKind: "two_closed_owned_run_windows", method: "deterministic_observed_counts",
                limits: ["resources": 16, "qualifications": 32], coverage: "Delivery is not target acceptance; cleanup proof is historical.", nextAction: "Inspect current cleanup and source window evidence separately.")
        case "visual_asset_inspection":
            return .init(inputKind: "retained_image_response", method: "exact_metadata_and_sampled_pixel_heuristics",
                limits: ["encodedBytes": ImageInspectionPreflight.maximumEncodedBytes, "pixels": ImageInspectionPreflight.maximumPixels,
                    "frames": ImageInspectionPreflight.maximumFrames, "decodedBytes": ImageInspectionPreflight.maximumDecodedBytes, "inspectedFrames": 1],
                coverage: "Frame zero only; palette/blank-image findings are sampled heuristics. No OCR or semantic recognition.", nextAction: "Review source metadata and qualified image evidence.")
        default: return nil
        }
    }
    struct ProductionTool: Sendable, Equatable {
        var name: String
        var description: String
        var capability: MCPCapabilityID
        var discoveryToolsets: Set<MCPToolset>

        init(name: String, description: String, capability: MCPCapabilityID) {
            self.name = name
            self.description = description
            self.capability = capability
            discoveryToolsets = MCPToolset.memberships(for: name)
        }
    }

    /// Production MCP tools mirrored by ``MCPProtocolService/handleToolsList``.
    static let productionTools: [ProductionTool] = [
        ProductionTool(name: "capture_calculate", description: "Count, group or summarize explicit captured session metadata or one complete JSON response using exact bounded decimal arithmetic. Requires sensitive-read approval. Source changes discard results; no refetch or raw body output.", capability: .bodyRead),
        ProductionTool(name: "artifact_source_register", description: "Request local file selection and review of one immutable temporary source. No remote path input. The local user selects and shares; retry the same request key after approval.", capability: .artifactSourceAccess),
        ProductionTool(name: "artifact_source_status", description: "Owner-only pending source state; no selected-file metadata before approval.", capability: .artifactSourceAccess),
        ProductionTool(name: "artifact_source_inspect", description: "Inspect an owned unexpired source descriptor. No raw content or local filenames.", capability: .artifactSourceAccess),
        ProductionTool(name: "artifact_source_release", description: "Release an owned source copy without editing its original. Cleanup remains available after profile downgrade.", capability: .artifactSourceRelease),
        ProductionTool(name: "artifact_inventory", description: "List bounded metadata and physical record ordinals in one reviewed snapshot with search-v1 consent.", capability: .artifactSearch),
        ProductionTool(name: "artifact_search", description: "Find exact UTF-8 byte ranges in one reviewed snapshot with search-v1 consent. Returns references, coverage and a cursor.", capability: .artifactSearch),
        ProductionTool(name: "artifact_compare_responses", description: "Compare two explicitly selected saved responses after local Compare once approval.", capability: .artifactCompare),
        ProductionTool(name: "artifact_response_brief", description: "Describe fields, counts and optional nested structure for one locally approved saved JSON response.", capability: .artifactBrief),
        ProductionTool(name: "artifact_calculate", description: "Run six typed calculations over one approved saved source. Requires calculations-v1 consent and current shareable policy. Complete-domain exact results, bounded group output; no arbitrary code, approximate counts or file writes.", capability: .artifactCalculate),
        ProductionTool(name: "documentation_list", description: "List bundled documentation topics with bounded pagination. Read-only; no runtime readiness claim.", capability: .agentResource),
        ProductionTool(name: "documentation_search", description: "Search bundled Help and workflows before requesting detailed sections. No traffic access.", capability: .agentResource),
        ProductionTool(name: "documentation_read", description: "Read a documentation topic or section. Follow continuation before treating instructions as complete.", capability: .agentResource),
        ProductionTool(name: "agent_toolset_status", description: "Report the current discovery toolset and full policy-available tool count.", capability: .agentResource),
        ProductionTool(name: "agent_toolset_select", description: "Select a compact tools/list catalog. Discovery only; policy-permitted tools remain callable.", capability: .agentResource),
        ProductionTool(name: "sessions_list", description: "Projected, paginated capture sessions; minimal by default.", capability: .sessionList),
        ProductionTool(name: "sessions_search", description: "Projected capture search by method/host category; minimal by default.", capability: .sessionSearch),
        ProductionTool(name: "capture_digest", description: "Compact capture state for conditional follow-up reads.", capability: .captureResource),
        ProductionTool(name: "audit_cache_efficiency", description: "Audits captured sessions for caching inefficiencies, duplicate un-cached requests, conflicting headers, and bandwidth waste.", capability: .captureResource),
        ProductionTool(name: "investigation_snapshot", description: "Bounded recent traffic decision surface with client-scoped evidence references.", capability: .captureResource),
        ProductionTool(name: "evidence_get", description: "Resolve one unexpired client-scoped evidence reference without expanding its original disclosure.", capability: .sessionSummary),
        ProductionTool(name: "read_batch", description: "Run up to eight bounded read-only tools and return structured results in one response.", capability: .captureResource),
        ProductionTool(name: "capture_marker_create", description: "Insert a named timeline marker into the capture stream without upstream traffic.", capability: .captureResource),
        ProductionTool(name: "capture_restore_rolling", description: "Restore the latest rolling auto-save snapshot into the live capture store.", capability: .captureResource),
        ProductionTool(name: "session_summary", description: "Summary for one session ID, including body availability and bounded transportDiagnostic reasons, read-only recovery checks and verification under existing disclosure policy. Missing bodies do not establish device profile or trust failure. Guidance never authorizes replay or routing changes.", capability: .sessionSummary),
        ProductionTool(name: "list_discovered_devices", description: "List locally discovered proxy clients with aliases and capture counts.", capability: .deviceInspect),
        ProductionTool(name: "set_device_alias", description: "Set or clear a local friendly alias for a discovered client IP address.", capability: .deviceAliasManage),
        ProductionTool(name: "response_evidence_brief", description: "Deterministic counts and immediate field types/null/missing counts for one complete retained JSON response or explicit pointer. Requires body-read approval. No scalar values, inference or automatic refetch. Coverage and source digest accompany results.", capability: .sessionSummary),
        ProductionTool(name: "investigation_compare_brief", description: "Compare explicit baseline and candidate session selections with bounded request alignment and observed JSON structure changes. Requires structural metadata and body-read approval. Missing sources and analysis limits remain incomplete; no target-outcome or cleanup claim.", capability: .sessionSummary),
        ProductionTool(name: "sessions_export", description: "Bulk session export as JSON, NDJSON, or HAR. Use deliverFile for full-capture file delivery (CLI --output / GUI Export All parity). Headers/bodies require the same approval as session_summary.", capability: .sessionSummary),
        ProductionTool(name: "repro_export_package", description: "Export a privacy-sanitized reproduction package to a managed local file.", capability: .sessionSummary),
        ProductionTool(name: "repro_inspect_package", description: "Inspect a bounded base64-encoded reproduction package without replaying it.", capability: .sessionSummary),
        ProductionTool(name: "repro_replay_request", description: "Replay one sanitized read request from a reproduction package after exact in-app approval.", capability: .replayRequest),
        ProductionTool(name: "media_readiness", description: "Deterministic media capability and recommended workflow for one session.", capability: .mediaSummary),
        ProductionTool(name: "media_context", description: "Context labels and sanitized discovery metadata for one media session.", capability: .mediaSummary),
        ProductionTool(name: "media_summary", description: "Capture-only media classification and bounded aggregate facts.", capability: .mediaSummary),
        ProductionTool(name: "media_manifest_structure", description: "Sanitized captured HLS or DASH structure.", capability: .mediaSummary),
        ProductionTool(name: "media_related_sessions", description: "Paginated capture-only media relationships.", capability: .mediaSummary),
        ProductionTool(name: "media_inspection_start", description: "Start approved capture-only media analysis.", capability: .mediaInspection),
        ProductionTool(name: "operation_status", description: "Compact operation progress; request the full result only when ready.", capability: .mediaInspection),
        ProductionTool(name: "operation_cancel", description: "Cancel an operation owned by this client and logical MCP session.", capability: .mediaInspection),
        ProductionTool(name: "client_cleanup_status", description: "Compact client-owned state and safe-termination decision.", capability: .serverResource),
        ProductionTool(name: "approval_status", description: "Read one client-owned approval state without creating another approval.", capability: .serverResource),
        ProductionTool(name: "approvals_list", description: "List every currently-pending approval request for this client, with capability and reason, without creating another approval.", capability: .serverResource),
        ProductionTool(name: "runtime_status", description: "Compact authenticated readiness for CLI startup, proxy control, grants, and safe cleanup.", capability: .serverResource),
        ProductionTool(name: "setup_readiness", description: "Read-only, target-specific onboarding evidence with explicit user-action and observability boundaries.", capability: .setupReadiness),
        ProductionTool(name: "https_rules_get", description: "Inspect one HTTPS host's effective rule and revision; optional recoveryID returns owner-bound reconciliation evidence without applying anything. Rules cover subdomains/all clients; global TLS mode may override.", capability: .httpsRulesInspect),
        ProductionTool(name: "https_rules_restore", description: "Restore an owner-bound HTTPS recovery receipt after separate exact local approval. Requires host, recoveryID, current expectedRevision and all-client scope. Conflicting settings block restore; never retries requests or changes existing connections.", capability: .httpsRulesManage),
        ProductionTool(name: "https_rules_set", description: "Change a persistent HTTPS domain rule after exact one-use local approval and revision check. Modes tunnel/inspect/remove; optional caller-chosen recoveryID records durable before/after settings for inspection and separately approved restore. Repeating an ID never reapplies. All clients, new connections only; TCP is not QUIC and bundle cleanup does not undo settings.", capability: .httpsRulesManage),
        ProductionTool(name: "proxy_start", description: "Start the local proxy after exact in-app approval.", capability: .runtimeControl),
        ProductionTool(name: "capture_status", description: "Read current body capture limits, admission pressure, and safe next actions without reading bodies or changing settings.", capability: .captureResource),
        ProductionTool(name: "capture_resume", description: "Resume a stopped proxy for future bounded capture after runtime approval. Does not force admission, alter retention/TLS/routing, recover old bodies, or grant body-read access. Read capture_status afterward.", capability: .runtimeControl),
        ProductionTool(name: "proxy_stop", description: "Stop the local proxy after exact in-app approval.", capability: .runtimeControl),
        ProductionTool(name: "mcp_stop", description: "Stop MCP after approval and verified client cleanup; the response is sent before shutdown.", capability: .runtimeControl),
        ProductionTool(name: "bookmarks_list", description: "Projected bookmark decisions; minimal by default.", capability: .bookmarkInspect),
        ProductionTool(name: "bookmark_get", description: "One bookmark summary by ID.", capability: .bookmarkInspect),
        ProductionTool(name: "overrides_list", description: "Projected override decisions; minimal by default.", capability: .overrideInspect),
        ProductionTool(name: "override_get", description: "One override summary by ID.", capability: .overrideInspect),
        ProductionTool(name: "capture_activity_since_marker", description: "Ceremony-free evidence: new request count/summaries since a marker, and whether a given override rule has been hit since then — without the full diagnostic-run lifecycle.", capability: .overrideInspect),
        ProductionTool(name: "discover_response_structure", description: "Deterministic, policy-gated structural profile (property names/types/cardinality, never values) of one or more captured JSON response bodies.", capability: .structuralDiscovery),
        ProductionTool(name: "preview_live_rewrite", description: "Capture-only preview of a candidate live-response rewrite against already-captured sessions; no live effect, nothing persisted.", capability: .transformationPreview),
        ProductionTool(name: "preview_collection_mock", description: "Capture-only preview of a candidate collection-shape mutation (insert/replace items) against one captured session's response; no live effect, nothing persisted beyond a bounded owner-scoped cache.", capability: .transformationPreview),
        ProductionTool(name: "preview_hls_codecs_edit", description: "Capture-only preview of a bounded HLS master CODECS edit; retains the patched body server-side for Map Local binding.", capability: .transformationPreview),
        ProductionTool(name: "preview_response_edit", description: "Capture-only preview of bounded exactText/matchRef response edits; retains patched bytes server-side for Map Local binding.", capability: .transformationPreview),
        ProductionTool(name: "response_context", description: "Metadata-only captured response body availability, completeness, hashes, and recommended next edit action; never returns body content.", capability: .responseContext),
        ProductionTool(name: "response_text_search", description: "Exact literal UTF-8 search over a captured response with opaque matchRef values. Context windows require body-read approval.", capability: .responseTextSearch),
        ProductionTool(name: "response_text_read", description: "Bounded byte-window read of a captured response revision after body-read approval. Returned text is labeled untrusted.", capability: .bodyRead),
        ProductionTool(name: "response_drafts_list", description: "List JoesProxy-managed response drafts owned by this client (metadata only).", capability: .responseDraftInspect),
        ProductionTool(name: "response_draft_get", description: "Inspect one owned response draft, including revision metadata and Map Local reference status.", capability: .responseDraftInspect),
        ProductionTool(name: "propose_create_response_draft", description: "Propose creating a persistent response draft from a captured session.", capability: .createResponseDraft),
        ProductionTool(name: "apply_create_response_draft", description: "Apply a proposed response-draft create after in-app approval.", capability: .createResponseDraft),
        ProductionTool(name: "propose_commit_response_edit", description: "Propose committing a consumed response-edit preview into a new draft revision.", capability: .createResponseDraft),
        ProductionTool(name: "apply_commit_response_edit", description: "Apply a proposed draft commit after in-app approval.", capability: .createResponseDraft),
        ProductionTool(name: "propose_delete_response_draft", description: "Propose deleting an owned response draft that is not referenced by Map Local.", capability: .createResponseDraft),
        ProductionTool(name: "apply_delete_response_draft", description: "Apply a proposed response-draft delete after in-app approval.", capability: .createResponseDraft),
        ProductionTool(name: "propose_create_block", description: "Propose a create-disabled block rule.", capability: .createDisabledBlock),
        ProductionTool(name: "apply_create_block", description: "Apply a proposed create-disabled block rule.", capability: .createDisabledBlock),
        ProductionTool(name: "propose_create_map_local", description: "Propose a create-disabled map-local rule.", capability: .createDisabledMapLocal),
        ProductionTool(name: "apply_create_map_local", description: "Apply a proposed map-local rule (created disabled by default; pass enableAfterApply to create and enable under one enableRule approval).", capability: .createDisabledMapLocal),
        ProductionTool(name: "propose_create_map_remote", description: "Propose a create-disabled map-remote rule.", capability: .createDisabledMapRemote),
        ProductionTool(name: "apply_create_map_remote", description: "Apply a proposed create-disabled map-remote rule.", capability: .createDisabledMapRemote),
        ProductionTool(name: "propose_create_rewrite", description: "Propose a create-disabled bookmark JSON rewrite.", capability: .createDisabledRewrite),
        ProductionTool(name: "apply_create_rewrite", description: "Apply a proposed create-disabled bookmark JSON rewrite.", capability: .createDisabledRewrite),
        ProductionTool(name: "propose_create_live_rewrite", description: "Propose a create-disabled live response JSON rewrite.", capability: .createDisabledLiveRewrite),
        ProductionTool(name: "apply_create_live_rewrite", description: "Apply a proposed create-disabled live response JSON rewrite.", capability: .createDisabledLiveRewrite),
        ProductionTool(name: "propose_create_collection_mock", description: "Propose a create-disabled collection mock rule from a previewed revision.", capability: .createDisabledCollectionMock),
        ProductionTool(name: "apply_create_collection_mock", description: "Apply a proposed create-disabled collection mock rule.", capability: .createDisabledCollectionMock),
        ProductionTool(name: "propose_create_bookmark", description: "Propose a create-disabled bookmark.", capability: .createDisabledBookmark),
        ProductionTool(name: "apply_create_bookmark", description: "Apply a proposed create-disabled bookmark.", capability: .createDisabledBookmark),
        ProductionTool(name: "propose_enable_rule", description: "Propose enabling an MCP-created override rule.", capability: .enableRule),
        ProductionTool(name: "apply_enable_rule", description: "Apply a proposed enable override rule.", capability: .enableRule),
        ProductionTool(name: "propose_disable_rule", description: "Propose disabling an MCP-created override rule.", capability: .disableRule),
        ProductionTool(name: "apply_disable_rule", description: "Apply a proposed disable override rule.", capability: .disableRule),
        ProductionTool(name: "propose_delete_rule", description: "Propose permanently deleting an MCP-created override rule.", capability: .deleteRule),
        ProductionTool(name: "apply_delete_rule", description: "Apply a proposed override delete after in-app approval.", capability: .deleteRule),
        ProductionTool(name: "propose_enable_rewrite", description: "Propose enabling an MCP bookmark JSON rewrite.", capability: .enableRule),
        ProductionTool(name: "apply_enable_rewrite", description: "Apply a proposed enable bookmark rewrite.", capability: .enableRule),
        ProductionTool(name: "propose_disable_rewrite", description: "Propose disabling an MCP bookmark JSON rewrite.", capability: .disableRule),
        ProductionTool(name: "apply_disable_rewrite", description: "Apply a proposed disable bookmark rewrite.", capability: .disableRule),
        ProductionTool(name: "propose_change_throttle", description: "Propose changing MCP network throttle settings.", capability: .changeThrottle),
        ProductionTool(name: "apply_change_throttle", description: "Apply a proposed throttle configuration change.", capability: .changeThrottle),
        ProductionTool(name: "execute_bookmark", description: "Execute a bookmark through the live proxy (open-world).", capability: .executeBookmark),
        ProductionTool(name: "replay_request", description: "Replay a captured session request through the live proxy (open-world).", capability: .replayRequest),
        ProductionTool(name: "recapture_session_body", description: "Fetch a session's request directly from the real origin (bypassing the local proxy's 1MB capture cap) and backfill its stored response body (open-world).", capability: .replayRequest),
        ProductionTool(name: "activate_map_remote", description: "Enable an MCP Map Remote rule with destination disclosure (open-world).", capability: .activateMapRemote),
        ProductionTool(name: "activate_live_rewrite", description: "Enable an MCP live response rewrite with upstream and JSON-patch disclosure (open-world).", capability: .activateLiveRewrite),
        ProductionTool(name: "activate_collection_mock", description: "Enable an MCP collection mock rule with upstream and plan disclosure (open-world).", capability: .activateCollectionMock),
        ProductionTool(name: "live_media_probe_start", description: "Start a live AVFoundation probe of a session media URL (open-world).", capability: .liveMediaProbe),
        ProductionTool(name: "hls_fixture_capabilities", description: "Report HLS fixture routing mode, quotas, and whether bundled profiles are available.", capability: .hlsFixtureInspect),
        ProductionTool(name: "hls_fixture_profiles_list", description: "List bundled HLS fixture profile IDs and versions.", capability: .hlsFixtureInspect),
        ProductionTool(name: "hls_fixture_status", description: "List owned HLS fixture runs or inspect one run by runID.", capability: .hlsFixtureInspect),
        ProductionTool(name: "hls_fixture_window_preview", description: "Inspect exact VOD or live publication evidence, including bounded live-time-shifting window, program-time, live-edge, and retention boundaries — no HTTP client required.", capability: .hlsFixtureInspect),
        ProductionTool(name: "propose_hls_fixture_start", description: "Propose starting a reserved-origin HLS fixture run for a bundled profile.", capability: .hlsFixtureLifecycle),
        ProductionTool(name: "apply_hls_fixture_start", description: "Apply a proposed HLS fixture start after in-app approval.", capability: .hlsFixtureLifecycle),
        ProductionTool(name: "hls_fixture_stop", description: "Stop an owned active HLS fixture run and unregister its reserved origin.", capability: .hlsFixtureLifecycle),
        ProductionTool(name: "hls_substitution_profiles_list", description: "List HLS test-stream profiles, media characteristics, controlled faults, and bounded playback-configuration capabilities.", capability: .hlsFixtureInspect),
        ProductionTool(name: "propose_hls_substitution_start", description: "Propose an atomic same-origin HLS substitution with conformant or explicit deliberate-fault playback configuration.", capability: .hlsSubstitutionLifecycle),
        ProductionTool(name: "apply_hls_substitution_start", description: "Apply an approved HLS test-stream substitution as one transaction.", capability: .hlsSubstitutionLifecycle),
        ProductionTool(name: "hls_substitution_status", description: "Inspect owned HLS test-stream experiments and bounded hit metrics.", capability: .hlsFixtureInspect),
        ProductionTool(name: "hls_substitution_stop", description: "Stop an owned HLS test-stream substitution and restore upstream traffic.", capability: .hlsSubstitutionLifecycle),
        ProductionTool(name: "hls_substitution_extend", description: "Push an owned, active HLS test-stream substitution's expiry out further without restarting it — no propose/apply/approval step.", capability: .hlsSubstitutionLifecycle),
        ProductionTool(name: "openapi_pack_preview", description: "Compile a local OpenAPI 3.0 JSON bookmark into a coverage report without activating intercept.", capability: .openAPIMockInspect),
        ProductionTool(name: "propose_openapi_pack_start", description: "Propose activating one compiled OpenAPI mock pack as a single owned effect.", capability: .openAPIMockLifecycle),
        ProductionTool(name: "apply_openapi_pack_start", description: "Apply an approved OpenAPI mock-pack activation as one transaction.", capability: .openAPIMockLifecycle),
        ProductionTool(name: "openapi_pack_status", description: "Inspect owned OpenAPI mock packs and bounded hit/miss metrics.", capability: .openAPIMockInspect),
        ProductionTool(name: "openapi_pack_stop", description: "Stop an owned OpenAPI mock pack and drop live intercept.", capability: .openAPIMockLifecycle),
        ProductionTool(name: "openapi_validate_session", description: "Validate captured session JSON response payload against imported OpenAPI schema.", capability: .openAPIMockInspect),
        ProductionTool(name: "openapi_generate_mock", description: "Generate a synthetic JSON mock response payload from an OpenAPI operation response schema.", capability: .openAPIMockInspect),
        ProductionTool(name: "openapi_import_spec", description: "Import an OpenAPI 3.0/3.1 JSON specification into the active schema store.", capability: .openAPIMockInspect),
        ProductionTool(name: "mocker_export_suite", description: "Generate ready-to-run Swift test suite code (Mocker/URLProtocol) from captured sessions.", capability: .openAPIMockInspect),
        ProductionTool(name: "mocker_validate_fixture", description: "Validate a local Mocker JSON fixture against a captured session for contract drift.", capability: .openAPIMockInspect),
        ProductionTool(name: "diagnostic_run_list", description: "List owned diagnostic runs with bounded status fields.", capability: .diagnosticRunInspect),
        ProductionTool(name: "diagnostic_run_create", description: "Create a Draft diagnostic run from owner-authored hypothesis and explicit scopes.", capability: .diagnosticRunLifecycle),
        ProductionTool(name: "diagnostic_run_start", description: "Start Watching for an owned Draft diagnostic run (installs observation watches only).", capability: .diagnosticRunLifecycle),
        ProductionTool(name: "diagnostic_run_status", description: "Inspect one owned diagnostic run.", capability: .diagnosticRunInspect),
        ProductionTool(name: "diagnostic_run_brief", description: "Summarize two closed windows in one owned run with current bundle lifecycle, qualified delivery counts and historical cleanup proof. Target acceptance is never inferred.", capability: .diagnosticRunInspect),
        ProductionTool(name: "diagnostic_run_observations", description: "Read scoped observations for one owned diagnostic run.", capability: .diagnosticRunInspect),
        ProductionTool(name: "diagnostic_run_close", description: "Close an owned diagnostic run with a tri-state conclusion and verified cleanup.", capability: .diagnosticRunLifecycle),
        ProductionTool(name: "diagnostic_run_window_begin", description: "Begin an explicit baseline or modified observation window for an owned run and reviewed bundle. Baseline requires inactivity; modified requires activation. Freezes matchers and client scope. Does not change effects.", capability: .diagnosticRunLifecycle),
        ProductionTool(name: "diagnostic_run_window_end", description: "Freeze an owned explicit window. Pending observations remain pending; optional external target outcome needs its source. Does not stop effects.", capability: .diagnosticRunLifecycle),
        ProductionTool(name: "effect_bundle_compare", description: "Compare explicit closed baseline and modified windows for the same owner, scope and revision. Bounded metadata and coverage qualifications, not body diffing, causal inference or playback proof.", capability: .overrideInspect),
        ProductionTool(name: "diagnostic_run_retry_cleanup", description: "Retry cleanup for a Cleanup Required diagnostic run.", capability: .diagnosticRunLifecycle),
        ProductionTool(name: "diagnostic_run_evidence_list", description: "List owned immutable diagnostic evidence records (metadata projection).", capability: .diagnosticRunInspect),
        ProductionTool(name: "diagnostic_run_evidence_get", description: "Get one owned diagnostic evidence record; Metadata Only returns disclosure projection.", capability: .diagnosticRunInspect),
        ProductionTool(name: "propose_diagnostic_run_recheck", description: "Propose a regression re-check from saved evidence and disclose recreation/cleanup plan.", capability: .diagnosticRunLifecycle),
        ProductionTool(name: "apply_diagnostic_run_recheck", description: "Apply an approved diagnostic re-check that may recreate reviewed effects (one approval).", capability: .diagnosticRunLifecycle),
        ProductionTool(name: "certificate_status", description: "Read-only local CA fingerprint, validity, trust install state, and identity health.", capability: .certificateStatus),
        ProductionTool(name: "certificate_identity", description: "Read-only CA instance identity card (short code, nickname, storage state).", capability: .certificateIdentity),
        ProductionTool(name: "certificate_artifacts_list", description: "List generated profile distribution artifacts for known CA fingerprints.", capability: .certificateArtifactsList),
        ProductionTool(name: "certificate_export", description: "Export the plain public root CA certificate (DER, base64-encoded) for use outside Apple platform trust profiles — e.g. a Docker container's trust store.", capability: .certificateExport),
        ProductionTool(name: "certificate_compare", description: "Compare two certificate fingerprints without mutating trust.", capability: .certificateCompare),
        ProductionTool(name: "propose_certificate_cleanup", description: "Propose fingerprint-targeted cleanup of retired/legacy CA trust material.", capability: .certificateCleanup),
        ProductionTool(name: "apply_certificate_cleanup", description: "Apply fingerprint-targeted certificate cleanup after in-app approval.", capability: .certificateCleanup),
        ProductionTool(name: "return_to_normal", description: "Stop MCP, clear grants, and restore or disable MCP-created proxy effects.", capability: .returnToNormal),
        ProductionTool(name: "draft_test_scenario", description: "Create a scenario draft owned by the calling client; validation is a separate step.", capability: .scenarioLifecycle),
        ProductionTool(name: "validate_test_scenario", description: "Compile and validate a draft scenario, moving it to awaiting approval.", capability: .scenarioLifecycle),
        ProductionTool(name: "preview_test_scenario", description: "Compile and validate a scenario draft without persisting it.", capability: .scenarioLifecycle),
        ProductionTool(name: "request_test_scenario_approval", description: "Request in-app approval to arm a validated scenario.", capability: .scenarioLifecycle),
        ProductionTool(name: "arm_test_scenario", description: "Arm a validated scenario after in-app approval (does not activate traffic yet).", capability: .scenarioLifecycle),
        ProductionTool(name: "activate_test_scenario", description: "Activate an armed scenario's composed faults after approval.", capability: .scenarioLifecycle),
        ProductionTool(name: "get_test_observations", description: "Read bounded observation evidence for a scenario.", capability: .scenarioLifecycle),
        ProductionTool(name: "evaluate_test_assertions", description: "Evaluate scenario assertions and build a disclosure-gated report.", capability: .scenarioLifecycle),
        ProductionTool(name: "stop_test_scenario", description: "Evaluate (if needed), stop observation, and clean up a scenario.", capability: .scenarioLifecycle),
        ProductionTool(name: "cleanup_test_scenario", description: "Force scenario cleanup without an additional approval gate.", capability: .scenarioLifecycle),
        ProductionTool(name: "get_test_report", description: "Fetch the privacy-filtered scenario evaluation report.", capability: .scenarioLifecycle),

        // MARK: - Advanced agentic diagnostics (AG-1..AG-6)
        ProductionTool(name: "propose_hypothesis_dag", description: "Create a local hypothesis-DAG fault-bisection plan from candidate root causes. No live-traffic effect.", capability: .agenticGraphLifecycle),
        ProductionTool(name: "step_hypothesis_graph", description: "Advance a hypothesis-DAG plan with one evidence observation, pruning disproven branches.", capability: .agenticGraphLifecycle),
        ProductionTool(name: "get_fault_bisection_report", description: "Read a hypothesis-DAG plan's current root-cause isolation report.", capability: .agenticGraphInspect),
        ProductionTool(name: "llm_stream_inspection", description: "Analyze captured LLM (SSE) streams for shape, timing (TTFT, tokens/sec, jitter), and canary-prompt leakage.", capability: .llmStreamInspect),
        ProductionTool(name: "propose_llm_stream_fault", description: "Register a live LLM-stream fault-injection rule (delay/truncate/malform) affecting matching in-flight SSE traffic.", capability: .llmStreamFaultInject),
        ProductionTool(name: "propose_temporal_permutation_plan", description: "Create a local temporal-permutation plan for probing async race conditions across a batch of endpoints.", capability: .concurrencyFuzzingLifecycle),
        ProductionTool(name: "step_temporal_permutation_plan", description: "Advance a temporal-permutation plan with one caller-observed outcome.", capability: .concurrencyFuzzingLifecycle),
        ProductionTool(name: "get_race_condition_fuzz_report", description: "Read a temporal-permutation plan's current race-condition fuzzing report.", capability: .concurrencyFuzzingInspect),
        ProductionTool(name: "propose_resilience_bisection_plan", description: "Create a local counterfactual-resilience plan from one captured session's response payload.", capability: .resilienceBisectionLifecycle),
        ProductionTool(name: "step_resilience_bisection_plan", description: "Advance a resilience-bisection plan with one caller-observed client outcome.", capability: .resilienceBisectionLifecycle),
        ProductionTool(name: "get_resilience_matrix_report", description: "Read a resilience-bisection plan's current client resilience matrix report.", capability: .resilienceBisectionInspect),
        ProductionTool(name: "diff_session_trajectories", description: "Diff behavioral trajectories between a baseline and a candidate set of captured sessions.", capability: .trajectoryDiffInspect),
        ProductionTool(name: "propose_semantic_mock_rule", description: "Register a live similarity-matched semantic wire-mocking rule after approval.", capability: .semanticMockLifecycle),
        ProductionTool(name: "list_semantic_mock_rules", description: "List currently registered semantic mock rules.", capability: .semanticMockInspect),
        ProductionTool(name: "test_semantic_query_match", description: "Dry-run a query against registered semantic mock rules without executing live traffic.", capability: .semanticMockInspect),
        ProductionTool(name: "delete_semantic_mock_rule", description: "Permanently remove an MCP-owned semantic mock rule.", capability: .semanticMockDelete),
        ProductionTool(name: "contract_diff_sessions", description: "Diff a live captured session's endpoint contract against a baseline session (breaking-schema-change detection).", capability: .contractDiffInspect),
        ProductionTool(name: "contract_regression_suite", description: "Run a batch contract-diff regression summary across live vs. baseline session sets.", capability: .contractDiffInspect),
        ProductionTool(name: "trace_data_lineage", description: "Search captured sessions for a target value's provenance across otherwise-unrelated traffic.", capability: .dataLineageTrace),
        ProductionTool(name: "audit_analytics_attribution", description: "Correlate an analytics sink session against candidate source sessions to audit attribution.", capability: .dataLineageTrace),
        ProductionTool(name: "propose_provenance_watermark", description: "Preview a candidate provenance-watermarking rule against target key paths. Preview only — nothing is registered or persisted.", capability: .provenanceWatermarkPreview),
        ProductionTool(name: "localization_mock_list_presets", description: "List available localization/pseudo-localization presets.", capability: .localizationMockPreview),
        ProductionTool(name: "localization_mock_preview", description: "Preview a localization transform applied to one captured session's response body. Preview only — no live rule is installed.", capability: .localizationMockPreview),
        ProductionTool(name: "stateful_mock_list_backends", description: "List installed stateful-mock virtual backends.", capability: .statefulMockInspect),
        ProductionTool(name: "stateful_mock_list_presets", description: "List available stateful-mock backend presets.", capability: .statefulMockInspect),
        ProductionTool(name: "stateful_mock_install_preset", description: "Install a new live stateful-mock virtual backend from a preset after approval.", capability: .statefulMockLifecycle),
        ProductionTool(name: "stateful_mock_set_state", description: "Force a live stateful-mock backend into a named state after approval.", capability: .statefulMockLifecycle),
        ProductionTool(name: "stateful_mock_query_entities", description: "Query a stateful-mock backend's current entity collection.", capability: .statefulMockInspect),
        ProductionTool(name: "stateful_mock_reset_backend", description: "Reset a live stateful-mock backend's entities and state after approval.", capability: .statefulMockLifecycle),
        ProductionTool(name: "fault_isolation_start", description: "Start a local fault-isolation session scoped to one captured session and time window.", capability: .faultIsolationLifecycle),
        ProductionTool(name: "fault_isolation_record_step", description: "Record one observed outcome in the active fault-isolation session.", capability: .faultIsolationLifecycle),
        ProductionTool(name: "fault_isolation_report", description: "Read the active fault-isolation session's current report.", capability: .faultIsolationInspect),
        ProductionTool(name: "fault_isolation_cancel", description: "Cancel the active fault-isolation session.", capability: .faultIsolationLifecycle),
        ProductionTool(name: "cmcd_telemetry_inspection", description: "Capture-only CMCD/CMSD quality-of-experience telemetry validation across captured sessions.", capability: .mediaAdvancedInspection),
        ProductionTool(name: "webvtt_subtitle_inspection", description: "Capture-only WebVTT subtitle/closed-caption sync drift analysis for one session.", capability: .mediaAdvancedInspection),
        ProductionTool(name: "drm_handshake_inspection", description: "Capture-only DRM license exchange and key handshake audit (FairPlay/Widevine) across related sessions.", capability: .mediaAdvancedInspection),
        ProductionTool(name: "byte_range_efficiency_inspection", description: "Capture-only byte-range/CDN 206 partial-content efficiency audit across captured sessions.", capability: .mediaAdvancedInspection),
        ProductionTool(name: "streaming_waterfall_inspection", description: "Capture-only streaming quality waterfall for one session.", capability: .mediaAdvancedInspection),
        ProductionTool(name: "visual_asset_inspection", description: "Capture-only visual asset inspection for one session.", capability: .mediaAdvancedInspection),
        ProductionTool(name: "scte35_ad_break_inspection", description: "Capture-only SCTE-35 ad-break and multi-rendition discontinuity alignment analysis.", capability: .mediaAdvancedInspection),
        ProductionTool(name: "list_synthetic_assets", description: "List bundled synthetic assets (test-pattern image, clear live/VOD HLS, synthetic VAST ad) available for collection injection.", capability: .syntheticAssetInspect),
        ProductionTool(name: "propose_inject_synthetic_item", description: "Register a live schema-inferred collection-injection plan that inserts a synthetic item into a matching JSON collection response for a scoped client set.", capability: .syntheticInjectionLifecycle),
        ProductionTool(name: "list_synthetic_injection_plans", description: "List currently armed synthetic collection-injection plans. In-memory only — cleared automatically on app quit or restart.", capability: .syntheticInjectionInspect),
        ProductionTool(name: "remove_synthetic_injection_plan", description: "Permanently remove one armed synthetic collection-injection plan.", capability: .syntheticInjectionDelete),

        // MARK: - Xcode Instruments & Trace Automation (IT-1..IT-3)
        ProductionTool(name: "instruments_list_templates", description: "List available Xcode Instruments templates and target runtimes for headless profiling.", capability: .diagnosticRunInspect),
        ProductionTool(name: "instruments_record_trace", description: "Start a bounded headless Xcode Instruments trace session on a simulator or macOS host.", capability: .diagnosticRunLifecycle),
        ProductionTool(name: "instruments_analyze_trace", description: "Extract structured performance metrics (CPU hotspots, main-thread hangs, memory deltas) from a .trace file.", capability: .diagnosticRunInspect),
        ProductionTool(name: "instruments_correlated_audit", description: "Run an integrated performance audit correlating captured network requests with host runtime stalls and CPU hotspots.", capability: .diagnosticRunLifecycle),

        // MARK: - Named Effect Bundles (.jproxy-effects)
        ProductionTool(name: "effect_bundle_prepare", description: "Prepare an inactive immutable GET JSON fixture with optional image file bookmarks, scoped to an explicit client address. Body-read approval required; no upstream fetch or activation. Image URLs are versioned by default.", capability: .bodyRead),
        ProductionTool(name: "effect_bundle_list", description: "List retained portable effect bundles owned by this client.", capability: .overrideInspect),
        ProductionTool(name: "effect_bundle_retire_preparation", description: "Retire an owned process-local prepared handle and release its cached bytes. Idempotent; prevents old-key resurrection. Does not delete or stop imported bundles, cancel an import already in progress, or grant activation authority.", capability: .overrideInspect),
        ProductionTool(name: "effect_bundle_inspect", description: "Inspect an owned revision or retained bundle with bounded joinedEvidence: historical preflight, reviewed asset metadata, one delivery page and capture-wide coverage. No body or asset-file reads for these subjects; file-backed inspection remains separate package validation. Delivery is not rendering confirmation.", capability: .overrideInspect),
        ProductionTool(name: "effect_bundle_import", description: "Import a validated .jproxy-effects package into managed storage as inactive.", capability: .overrideInspect),
        ProductionTool(name: "propose_activate_effect_bundle", description: "Propose atomic activation of a retained effect bundle with conflict checking and bounded TTL.", capability: .enableRule),
        ProductionTool(name: "apply_activate_effect_bundle", description: "Apply a proposed effect bundle activation after in-app approval.", capability: .enableRule),
        ProductionTool(name: "effect_bundle_stop", description: "Stop and deactivate an active effect bundle immediately.", capability: .disableRule),
        ProductionTool(name: "effect_bundle_advance", description: "Advance the next reviewed phase using activationID and expectedPhaseID from owned inspection. Stale retries fail; expiry never extends. Admitted live collections retain their original phase; Stop invalidates unfinished mutations. Schema-6 HLS supports compatible prepared-media switching and explicit ENDLIST completion with retained segments. Inspect mediaPlan and supervision for limits and scope: HLS is not restricted by JSON client filters. Publication is not playback proof. Final-phase Advance stops the bundle. ISO-8601 UTC bindings retain the activation anchor; legacy live field rewrites remain unsupported in phases.", capability: .enableRule),
        ProductionTool(name: "propose_discard_effect_bundle", description: "Propose permanently deleting a retained effect bundle.", capability: .deleteRule),
        ProductionTool(name: "apply_discard_effect_bundle", description: "Apply a proposed effect bundle deletion after in-app approval.", capability: .deleteRule)
    ]

    static let productionResources: [MCPResourceCapabilityEntry] = [
        MCPResourceCapabilityEntry(
            uri: "joesproxy://server/status",
            name: "Server Status",
            mimeType: "application/json",
            capabilityID: MCPCapabilityID.serverResource.rawValue
        ),
        MCPResourceCapabilityEntry(
            uri: "joesproxy://capture/summary",
            name: "Capture Summary",
            mimeType: "application/json",
            capabilityID: MCPCapabilityID.captureResource.rawValue
        ),
        MCPResourceCapabilityEntry(
            uri: "joesproxy://capture/health",
            name: "Capture Health",
            mimeType: "application/json",
            capabilityID: MCPCapabilityID.healthResource.rawValue
        ),
        MCPResourceCapabilityEntry(
            uri: "joesproxy://agent/capabilities",
            name: "Agent Capabilities",
            mimeType: "application/json",
            capabilityID: MCPCapabilityID.agentResource.rawValue
        ),
        MCPResourceCapabilityEntry(
            uri: "joesproxy://docs/index", name: "Documentation Discovery", mimeType: "application/json",
            capabilityID: MCPCapabilityID.agentResource.rawValue
        ),
        MCPResourceCapabilityEntry(
            uri: "joesproxy://agent/guide",
            name: "Agent Guide",
            mimeType: "application/json",
            capabilityID: MCPCapabilityID.agentResource.rawValue
        ),
        MCPResourceCapabilityEntry(
            uri: "joesproxy://setup/guide",
            name: "Portable Setup Guide",
            mimeType: "application/json",
            capabilityID: MCPCapabilityID.agentResource.rawValue
        ),
        MCPResourceCapabilityEntry(
            uri: "joesproxy://audit/recent",
            name: "Recent Client Audit",
            mimeType: "application/json",
            capabilityID: MCPCapabilityID.serverResource.rawValue
        )
    ]

    static let mediaWorkflows: [MCPMediaWorkflowEntry] = [
        MCPMediaWorkflowEntry(
            id: "classify_session",
            title: "Classify Session Media",
            steps: ["session_summary", "media_readiness"],
            requiredProfile: MCPDisclosureProfileID.metadataOnly.rawValue,
            requiresApproval: false
        ),
        MCPMediaWorkflowEntry(
            id: "hls_manifest_analysis",
            title: "HLS Manifest Analysis",
            steps: ["media_readiness", "media_summary", "media_manifest_structure", "media_related_sessions"],
            requiredProfile: MCPDisclosureProfileID.metadataOnly.rawValue,
            requiresApproval: false
        ),
        MCPMediaWorkflowEntry(
            id: "dash_manifest_analysis",
            title: "DASH Manifest Analysis",
            steps: ["media_readiness", "media_summary", "media_manifest_structure", "media_related_sessions"],
            requiredProfile: MCPDisclosureProfileID.metadataOnly.rawValue,
            requiresApproval: false
        ),
        MCPMediaWorkflowEntry(
            id: "deep_capture_inspection",
            title: "Deep Capture Inspection",
            steps: ["media_readiness", "media_summary", "media_inspection_start", "operation_status"],
            requiredProfile: MCPDisclosureProfileID.shareable.rawValue,
            requiresApproval: true
        ),
        MCPMediaWorkflowEntry(
            id: "live_url_probe",
            title: "Live URL Probe",
            steps: ["media_readiness", "live_media_probe_start", "operation_status"],
            requiredProfile: MCPDisclosureProfileID.shareable.rawValue,
            requiresApproval: true
        )
    ]

    static let policyProfiles: [MCPPolicyProfileSummary] = [
        MCPPolicyProfileSummary(
            id: MCPDisclosureProfileID.metadataOnly.rawValue,
            title: "Metadata Only",
            summary: "Session metadata, host categories, and capture-only media tools without structural host/path disclosure."
        ),
        MCPPolicyProfileSummary(
            id: MCPDisclosureProfileID.shareable.rawValue,
            title: "Shareable",
            summary: "Adds sanitized host/path, safe headers, parser summaries, and richer media context for agent workflows."
        )
    ]

    static var productionToolCount: Int { productionTools.count }

    static var productionToolNames: Set<String> {
        Set(productionTools.map(\.name))
    }

    private static let productionToolsByName: [String: ProductionTool] =
        Dictionary(uniqueKeysWithValues: productionTools.map { ($0.name, $0) })

    static func productionTool(named name: String) -> ProductionTool? {
        productionToolsByName[name]
    }

    static func buildManifest(
        appVersion: String = Bundle.main.marketingVersionOrDev,
        generatedAt: Date = Date(),
        mcpProtocolVersion: String = MCPNetworkConstants.preferredProtocolVersion,
        tools: [ProductionTool] = productionTools
    ) -> MCPCapabilitiesManifest {
        let availableToolNames = Set(tools.map(\.name))
        return MCPCapabilitiesManifest(
            schemaVersion: 1,
            bundleVersion: MCPCapabilitiesRevision.bundleVersion(appVersion: appVersion),
            appVersion: appVersion,
            mcpProtocolVersion: mcpProtocolVersion,
            generatedAt: generatedAt,
            tools: tools.map {
                MCPToolCapabilityEntry(
                    name: $0.name,
                    description: $0.description,
                    capabilityID: $0.capability.rawValue,
                    riskTier: $0.capability.riskTier.rawValue,
                    analysis: analysis(for: $0.name)
                )
            },
            resources: productionResources,
            mediaWorkflows: mediaWorkflows.filter { workflow in
                workflow.steps.allSatisfy(availableToolNames.contains)
            },
            policyProfiles: policyProfiles
        )
    }
}
