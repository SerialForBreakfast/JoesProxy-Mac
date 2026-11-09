import Foundation

/// Client-selected discovery projection for `tools/list`.
///
/// Toolsets are not an authorization boundary. A tool omitted from the selected catalog remains
/// callable when the client's disclosure profile and policy allow its capability. This keeps
/// compact discovery from reducing diagnostic power or changing safety enforcement.
enum MCPToolset: String, Codable, Sendable, Equatable, CaseIterable {
    case core
    case capture
    case mocking
    case media
    case reproduction
    case advanced
    case all

    var title: String {
        switch self {
        case .core: return "Core Diagnostics"
        case .capture: return "Capture Investigation"
        case .mocking: return "Mocking And Traffic Control"
        case .media: return "Media Investigation"
        case .reproduction: return "Reproduction And Diagnostic Runs"
        case .advanced: return "Advanced Analysis"
        case .all: return "All Capabilities"
        }
    }

    /// Canonical discovery classification used when the tool registry is constructed.
    /// Authorization never consults this value.
    func includes(toolName: String) -> Bool {
        if self == .all || Self.coreToolNames.contains(toolName) {
            return true
        }
        let keywords: [String]
        switch self {
        case .core, .all:
            return false
        case .capture:
            keywords = ["artifact_compare_responses", "artifact_response_brief", "artifact_inventory", "artifact_search", "capture_", "sessions_", "session_", "device", "audit_cache_"]
        case .mocking:
            keywords = [
                "bookmark", "override", "rule_", "block", "map_", "rewrite", "response_",
                "throttle", "stateful_", "semantic_", "synthetic_", "openapi_", "hls_fixture",
                "hls_substitution", "effect_bundle"
            ]
        case .media:
            keywords = [
                "media_", "hls_", "dash_", "drm_", "webvtt_", "subtitle_", "byte_range_",
                "cmcd_", "scte", "vast_", "vmap_", "llm_stream_", "streaming_waterfall",
                "visual_asset_"
            ]
        case .reproduction:
            keywords = ["repro_", "diagnostic_run_", "test_scenario"]
        case .advanced:
            keywords = [
                "test_scenario", "certificate_", "hypothesis_dag", "fault_bisection",
                "fault_isolation", "temporal_permutation", "race_condition",
                "resilience_bisection", "resilience_matrix", "trajectory_diff", "contract_diff",
                "contract_regression", "data_lineage", "analytics_attribution",
                "provenance_watermark", "localization_mock", "llm_stream_"
            ]
        }
        return keywords.contains { toolName.contains($0) }
    }

    static let coreToolNames: Set<String> = [
        "capture_calculate", "artifact_calculate", "artifact_source_register", "artifact_source_status",
        "artifact_source_inspect", "artifact_source_release",
        "documentation_list", "documentation_search", "documentation_read",
        "agent_toolset_status",
        "agent_toolset_select",
        "capture_digest",
        "capture_status",
        "https_rules_get",
        "https_rules_set",
        "https_rules_restore",
        "capture_resume",
        "investigation_snapshot",
        "evidence_get",
        "read_batch",
        "sessions_list",
        "sessions_search",
        "session_summary",
        "response_evidence_brief",
        "investigation_compare_brief",
        "diagnostic_run_brief",
        "media_readiness",
        "media_summary",
        "operation_status",
        "operation_cancel",
        "approval_status",
        "approvals_list",
        "client_cleanup_status",
        "runtime_status",
        "setup_readiness",
        "return_to_normal"
    ]

    static func memberships(for toolName: String) -> Set<MCPToolset> {
        Set(allCases.filter { $0.includes(toolName: toolName) })
    }
}

struct MCPToolsetStatusDTO: Codable, Sendable, Equatable {
    var analysis: [String: MCPAnalysisDescriptor] = [:]
    var unavailableAnalyses: [String] = []
    var selectedToolset: MCPToolset
    var selectedToolCount: Int
    var policyAvailableToolCount: Int
    var availableToolsets: [MCPToolset]
    var discoveryOnly: Bool
    var relistRequired: Bool
}
