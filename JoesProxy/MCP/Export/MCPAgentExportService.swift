import Foundation

/// Generates versioned MCP agent export bundles for Claude, Codex, and Cursor.
///
/// Concurrency: `@MainActor` because export reads live controller state from the management panel.
@MainActor
enum MCPAgentExportService {
    static let lastExportedBundleVersionKey = "mcpLastExportedBundleVersion"

    struct ExportRequest: Sendable {
        var destinationDirectory: URL
        var endpointURL: URL
        var bearerToken: String?
        var clientLabel: String
        var manifest: MCPCapabilitiesManifest
    }

    /// Writes the agent bundle into `destinationDirectory` and returns the directory URL.
    static func exportBundle(_ request: ExportRequest) throws -> URL {
        let fileManager = FileManager.default
        let bundleDirectory = request.destinationDirectory.appendingPathComponent(
            "JoesProxy-MCP-Agent-\(request.manifest.bundleVersion)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

        let token = request.bearerToken ?? MCPClientConfigSnippetBuilder.enrollmentTokenPlaceholder
        let versionHeader = bundleVersionHeader(manifest: request.manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let manifestData = try encoder.encode(request.manifest)
        try manifestData.write(to: bundleDirectory.appendingPathComponent("manifest.json"))

        let guideMarkdown = generateGuideMarkdown(manifest: request.manifest)
        try (versionHeader + "\n\n" + guideMarkdown).write(
            to: bundleDirectory.appendingPathComponent("JOESPROXY_MCP_AGENT.md"),
            atomically: true,
            encoding: .utf8
        )

        let cursorJSON = versionHeader + "\n" + MCPClientConfigSnippetBuilder.cursorMCPJSON(
            endpointURL: request.endpointURL,
            bearerToken: token,
            clientLabel: request.clientLabel
        )
        try cursorJSON.write(
            to: bundleDirectory.appendingPathComponent("cursor.mcp.json"),
            atomically: true,
            encoding: .utf8
        )

        let claudeJSON = versionHeader + "\n" + MCPClientConfigSnippetBuilder.claudeMCPJSON(
            endpointURL: request.endpointURL,
            bearerToken: token,
            clientLabel: request.clientLabel
        )
        try claudeJSON.write(
            to: bundleDirectory.appendingPathComponent("claude.mcp.json"),
            atomically: true,
            encoding: .utf8
        )

        let claudeCodeCommand = versionHeader + "\n" + MCPClientConfigSnippetBuilder.claudeCodeCommand(
            endpointURL: request.endpointURL,
            bearerToken: token,
            clientLabel: request.clientLabel
        )
        try claudeCodeCommand.write(
            to: bundleDirectory.appendingPathComponent("claude-code.command.txt"),
            atomically: true,
            encoding: .utf8
        )

        let codexTOML = MCPClientConfigSnippetBuilder.codexConfig(
            endpointURL: request.endpointURL,
            bearerToken: token
        )
        try codexTOML.write(
            to: bundleDirectory.appendingPathComponent("codex.config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let readme = """
        \(versionHeader)

        Setup
        -----
        1. Start JoesProxy and enable the MCP server in MCP Management.
        2. Enroll your client under Clients and copy the one-time bearer token.
        3. Claude Code (CLI): run the command in claude-code.command.txt — no file to place.
           Claude Desktop and Cursor: paste the token into their respective config snippet.
           Codex CLI and the Codex desktop app use the same file: add codex.config.toml to
           <project-root>/.codex/config.toml. Project scope is the supported default.
        4. Keep the server running, then restart the MCP client or open a new task so it discovers the connector.
        5. For the bundled CLI, run `joesproxyctl doctor`; other clients can verify connectivity by reading `joesproxy://server/status`.

        Existing Codex tasks do not reliably hot-load newly added or changed MCP connectors. After
        changing a URL or bearer token, restart Codex or open a new task only after JoesProxy is listening.
        The same is true for Claude Code sessions and Claude Desktop — a session/app started before the
        config is finalized on disk can show "failed to connect" indefinitely even when the server is healthy.

        Files
        -----
        - manifest.json — machine-readable tool/resource catalog
        - JOESPROXY_MCP_AGENT.md — human/agent guide
        - \(portableSetupGuideFileName) — credential-free setup guide safe to share before enrollment
        - \(MCPDiagnosticSkill.directoryName)/ — recommended skill folder: concise SKILL.md and all routed references.
          Install this entire folder in your agent's skills directory; do not copy only SKILL.md.
        - \(skillFileName) — complete standalone fallback for clients accepting only one file.
        - claude-code.command.txt — one-line `claude mcp add` install for Claude Code CLI (no file to place)
        - claude.mcp.json — Claude Desktop config template (paste into claude_desktop_config.json)
        - cursor.mcp.json — project or global Cursor MCP config template
        - codex.config.toml — shared Codex CLI/desktop project config (save as .codex/config.toml)

        Security
        --------
        Never commit enrolled bearer tokens. Re-export after app upgrades if bundle versions diverge.
        """
        try readme.write(
            to: bundleDirectory.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )

        _ = try writeSkillFile(to: bundleDirectory)
        _ = try writeSkillPackage(to: bundleDirectory)
        _ = try writePortableSetupGuide(to: bundleDirectory)

        UserDefaults.standard.set(request.manifest.bundleVersion, forKey: lastExportedBundleVersionKey)
        return bundleDirectory
    }

    static let skillFileName = "joesproxy-mcp-diagnostics.SKILL.md"
    static let portableSetupGuideFileName = "JOESPROXY_SETUP_GUIDE.md"

    /// Writes the credential-free, endpoint-free onboarding guide to a user-selected directory.
    @discardableResult
    static func writePortableSetupGuide(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(portableSetupGuideFileName)
        try MCPSetupGuideContent.markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Writes the same guide to a user-selected file URL (used by save panels).
    @discardableResult
    static func writePortableSetupGuideFile(to fileURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MCPSetupGuideContent.markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Portable entry point. References are exported by `writeSkillPackage`.
    static var skillMarkdown: String {
        skillMarkdown(body: MCPDiagnosticSkill.entryBody)
    }

    /// Copy/share/save-file paths cannot carry sibling references, so retain the complete playbook.
    static var standaloneSkillMarkdown: String {
        skillMarkdown(body: MCPDiagnosticPrompt.body)
    }

    /// Frontmatter mirrors the checked-in Skill; exported bodies/references have parity tests.
    ///
    /// `metadata.version` tracks the app's own `MARKETING_VERSION` (via `Bundle.main
    /// .marketingVersionOrDev`, the same helper every other version-surfacing export uses) instead
    /// of a hand-maintained semver — the running app's copy can no longer drift from "is this
    /// current." The checked-in repo file can't read `Bundle.main` at authoring time, so its copy of
    /// this same line is kept in sync by `bump_version.sh` instead.
    private static func skillMarkdown(body: String) -> String {
        """
        ---
        name: joesproxy-mcp-diagnostics
        description: >
          Use when debugging a network, API, TLS, or media-delivery problem in an app or service that can
          be routed through JoesProxy's local proxy. Enrolls an MCP client, drives JoesProxy's propose/apply
          mutation tools (block, map local, map remote, rewrite, throttle), and interprets captured traffic
          to isolate root cause — without guessing at transport/session mechanics or leaving live effects
          behind.
        compatibility: [claude-code, codex, cursor]
        metadata:
          version: \(Bundle.main.marketingVersionOrDev)
          source: JoesProxy built-in diagnostic prompt (joesproxy_diagnose)
        ---

        \(body)
        """
    }

    /// Legacy single-file export remains self-contained.
    @discardableResult
    static func writeSkillFile(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(skillFileName)
        try standaloneSkillMarkdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Writes a portable skill folder; returned only after every reference and the entry point exist.
    @discardableResult
    static func writeSkillPackage(to directory: URL) throws -> URL {
        let package = directory.appendingPathComponent(MCPDiagnosticSkill.directoryName, isDirectory: true)
        let references = package.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        for reference in MCPDiagnosticSkill.references {
            try reference.markdown.write(
                to: references.appendingPathComponent(reference.fileName), atomically: true, encoding: .utf8
            )
        }
        try skillMarkdown.write(to: package.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return package
    }

    static func generateGuideMarkdown(manifest: MCPCapabilitiesManifest) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let generatedAt = formatter.string(from: manifest.generatedAt)

        var sections: [String] = []
        sections.append("# JoesProxy MCP Agent Guide")
        sections.append("")
        sections.append("## Compatibility")
        sections.append("- Bundle version: `\(manifest.bundleVersion)`")
        sections.append("- App version: `\(manifest.appVersion)`")
        sections.append("- MCP protocol: `\(manifest.mcpProtocolVersion)`")
        sections.append("- Generated: \(generatedAt)")
        sections.append("- Re-export this bundle after app upgrades when bundle versions differ.")
        sections.append("- Complete the ordinary app-only path first; see `JOESPROXY_SETUP_GUIDE.md` for the credential-free setup guide.")
        sections.append("")
        sections.append("## Setup")
        sections.append("1. Start JoesProxy and the loopback MCP server.")
        sections.append("2. Enroll your client and paste the bearer token into the exported config.")
        sections.append("3. For Cursor, use `.cursor/mcp.json` in the project or `~/.cursor/mcp.json` globally.")
        sections.append("4. For Codex CLI and the Codex desktop app, use `<project-root>/.codex/config.toml`; both surfaces share this project-scoped configuration.")
        sections.append("5. Keep the server running, then restart the MCP client or open a new task.")
        sections.append("6. Verify with resource `joesproxy://server/status`.")
        sections.append("   The bundled CLI should run `joesproxyctl doctor` for compact startup, grant, proxy, and cleanup readiness.")
        sections.append("7. On HTTP 404 for a session-bound call, initialize a new logical session and resend `notifications/initialized`.")
        sections.append("")
        sections.append("> Existing Codex tasks do not reliably hot-load new or changed MCP connectors. Start the server before opening the validating task, and restart Codex after changing the URL or bearer token.")
        sections.append("")
        sections.append("## Efficient Reads")
        sections.append("- Agent workspace changes presentation, not authority. Read `documentation_read` topic `agent-documentation`, section `workspace` for human supervision, switching and recovery. Closing a window or switching workspace does not stop owned effects or prove cleanup; agents must not resolve their own live approvals.")
        sections.append("- Use `documentation_search` then `documentation_read` for focused Help; follow returned cursors and safety context. `documentation_list` discovers topic IDs. Offline CLI: `joesproxyctl docs list`; choose `--source live` explicitly for running-server documentation. Documentation grants no execution authority.")
        sections.append("- Start capture checks with `capture_digest`; reuse cached state when `unchanged` is true.")
        sections.append("- Use `investigation_snapshot` for a bounded recent decision surface; pass its `stateToken` back as `ifStateToken` on repeat and reuse `evidenceRef` values with `evidence_get`.")
        sections.append("- Use `read_batch` only for independent allowlisted reads (maximum eight); approval-gated fields and mutations remain separate.")
        sections.append("- Use `joesproxyctl watch sessions` for a long live tail; it subscribes before the initial delta read and uses capture high-water hints to suppress redundant reads.")
        sections.append("- List tools default to `minimal`. Request `summary` for bounded context and `full` only for a justified detail read.")
        sections.append("- Use `sinceSequence` and `maxResponseBytes` on session queries instead of repeating broad capture reads.")
        sections.append("- Poll `operation_status` in minimal mode using `retryAfterMs`; request `includeResult` only after `resultAvailable` is true.")
        sections.append("- Poll `approval_status(requestID)` while waiting. Approval never executes the action; retry the identical call once status is `approved_awaiting_retry`.")
        sections.append("- Call `client_cleanup_status` before ending a task and follow its `recommendedAction`.")
        sections.append("")
        sections.append("## Tool Catalog")
        appendToolGroup(&sections, title: "Session & capture reads", tools: manifest.tools, names: [
            "artifact_compare_responses", "artifact_response_brief", "artifact_inventory", "artifact_search", "capture_calculate", "artifact_calculate", "artifact_source_register", "artifact_source_status", "artifact_source_inspect", "artifact_source_release",
            "capture_digest", "investigation_snapshot", "evidence_get", "read_batch",
            "sessions_list", "sessions_search", "session_summary", "response_evidence_brief", "investigation_compare_brief", "diagnostic_run_brief", "sessions_export",
            "capture_marker_create", "capture_restore_rolling", "approval_status",
            "response_context", "response_text_search", "response_text_read",
            "response_drafts_list", "response_draft_get",
            "preview_response_edit", "preview_live_rewrite", "preview_hls_codecs_edit",
            "discover_response_structure"
        ])
        appendToolGroup(&sections, title: "Media discovery & inspection", tools: manifest.tools, names: [
            "media_readiness", "media_context", "media_summary", "media_manifest_structure",
            "media_related_sessions", "media_inspection_start", "operation_status", "operation_cancel",
            "live_media_probe_start"
        ])
        appendToolGroup(&sections, title: "Bookmarks & overrides", tools: manifest.tools, names: [
            "bookmarks_list", "bookmark_get", "overrides_list", "override_get"
        ])
        appendToolGroup(&sections, title: "Certificate identity", tools: manifest.tools, names: [
            "certificate_status", "certificate_identity", "certificate_artifacts_list",
            "certificate_compare", "propose_certificate_cleanup", "apply_certificate_cleanup"
        ])
        appendToolGroup(&sections, title: "HLS fixtures", tools: manifest.tools, names: [
            "hls_fixture_capabilities", "hls_fixture_profiles_list", "hls_fixture_status",
            "hls_fixture_window_preview",
            "propose_hls_fixture_start", "apply_hls_fixture_start", "hls_fixture_stop"
        ])
        appendToolGroup(&sections, title: "OpenAPI mock packs", tools: manifest.tools, names: [
            "openapi_pack_preview", "propose_openapi_pack_start", "apply_openapi_pack_start",
            "openapi_pack_status", "openapi_pack_stop"
        ])
        appendToolGroup(&sections, title: "Mutations", tools: manifest.tools, names: manifest.tools.map(\.name).filter {
            $0.hasPrefix("propose_") || $0.hasPrefix("apply_")
        }.sorted())
        appendToolGroup(&sections, title: "Scenarios", tools: manifest.tools, names: [
            "draft_test_scenario", "validate_test_scenario", "preview_test_scenario",
            "request_test_scenario_approval", "arm_test_scenario", "activate_test_scenario",
            "get_test_observations", "evaluate_test_assertions", "stop_test_scenario",
            "cleanup_test_scenario", "get_test_report"
        ])
        appendToolGroup(&sections, title: "Open-world", tools: manifest.tools, names: [
            "execute_bookmark", "replay_request", "recapture_session_body", "activate_map_remote",
            "activate_live_rewrite", "activate_collection_mock", "live_media_probe_start"
        ])
        appendToolGroup(&sections, title: "Recovery & runtime", tools: manifest.tools, names: [
            "runtime_status", "setup_readiness", "client_cleanup_status", "return_to_normal",
            "proxy_start", "proxy_stop", "mcp_stop"
        ])
        sections.append("### All tools")
        sections.append("Complete list from the live capabilities manifest (never omit a tool):")
        sections.append("")
        for tool in manifest.tools.sorted(by: { $0.name < $1.name }) {
            sections.append("- `\(tool.name)` — \(tool.description)")
        }
        sections.append("")
        sections.append("## CLI companion")
        sections.append("Analysis budgets are shared with tools/list `_meta.joesproxy.analysis` and manifest `analysis`. Missing descriptors do not imply unsupported tools; consult their exact schemas. OCR and semantic artifact retrieval are unavailable.")
        for tool in manifest.tools.sorted(by: { $0.name < $1.name }) {
            guard let analysis = tool.analysis else { continue }
            let limits = analysis.limits.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            sections.append("- `\(tool.name)`: \(analysis.inputKind); \(analysis.method); \(limits). \(analysis.availability) \(analysis.coverage) Next: \(analysis.nextAction)")
        }
        sections.append("The bundled CLI (`JoesProxy.app/Contents/MacOS/joesproxyctl`) speaks the same MCP surface.")
        sections.append("Run `joesproxyctl help` for the full command list.")
        sections.append("- Full-capture HAR (GUI Export All parity): `joesproxyctl sessions export --format har --output <path.har>`")
        sections.append("  sets MCP `deliverFile` — not limited by the 1 MB inline MCP budget or the default 500-session inline cap")
        sections.append("  (omit `--max-sessions` for the entire matching capture; files land under Application Support `MCPExports/` then copy to `--output`).")
        sections.append("- Certificate: `joesproxyctl certificate status|identity|artifacts list|compare|cleanup prepare|apply`")
        sections.append("- HLS fixtures: `joesproxyctl hls fixture capabilities|profiles|status|window-preview|prepare-start|apply-start|stop`")
        sections.append("- OpenAPI mock packs: `joesproxyctl openapi pack import|prepare|apply|status|stop`")
        sections.append("- Observation: `joesproxyctl watch capture|sessions`, `wait capture|session|operation`, `capture rolling-status`, `session end`")
        sections.append("- Runtime: `joesproxyctl doctor`, `app launch`, `mcp start|stop`, `proxy start|stop`")
        sections.append("")
        sections.append("## Media Playbook")
        sections.append("Start every media investigation with `media_readiness` for the session ID.")
        sections.append("Use `recommendedWorkflowID` and `recommendedNextTools` from the response.")
        sections.append("Call `media_context` when you need UI-equivalent labels before opening manifests.")
        sections.append("")
        sections.append("### Workflows")
        for workflow in manifest.mediaWorkflows {
            sections.append("- **\(workflow.title)** (`\(workflow.id)`): \(workflow.steps.joined(separator: " → "))")
        }
        sections.append("")
        sections.append("## Approvals & Profiles")
        for profile in manifest.policyProfiles {
            sections.append("- **\(profile.title)** (`\(profile.id)`): \(profile.summary)")
        }
        sections.append("- `media_inspection_start` and `live_media_probe_start` require in-app approval.")
        sections.append("- `session_summary` defaults `bodySource` to `response`; request `request` explicitly when needed.")
        sections.append("- `session_summary` defaults `headerSource` to `both` and exposes `safeResponseHeaders` / `approvedResponseHeaders` for response-side evidence.")
        sections.append("- `bodyRead` discloses a bounded request or response body excerpt for the selected `bodySource`; `headerRead` discloses request and/or response headers for the selected `headerSource`.")
        sections.append("- `bodyAvailable` / `bodyExcerptAvailable` mean MCP can return a non-empty excerpt after approval — not merely that bytes exist in the store.")
        sections.append("- Missing bodies: read `bodyUnavailableReason` and `bodyRecoveryAction`, then `capture_status` / CLI `capture status`. Deferred, omitted, tunneled, pending and missing bodies are distinct; an original size is not proof of retained bytes. Never automatically refetch.")
        sections.append("- Missing bodies alone never justify reinstalling a device proxy/certificate profile. TLS tunneling can be intentional bypass, not broken trust. Check target-specific `setup_readiness` and actual TLS evidence before recommending repair; preserve working device configuration. Unavailable evidence is not a failed trust check.")
        sections.append("- For a stopped proxy, `capture_resume` / CLI `capture resume --wait-for-approval` uses existing runtime approval/grants and returns current capture status. It does not restore old bytes, force admission, raise memory limits, change TLS/routing, or grant bodyRead. Pressure resumes automatically after drain; zero retention needs local settings review. Generate new traffic only when authorized.")
        sections.append("- Use `capture_marker_create` before/after repro; check `capture_digest.rollingCaptureAvailable` before declaring evidence lost after an epoch change.")
        sections.append("")
        sections.append("## Resources")
        for resource in manifest.resources {
            sections.append("- `\(resource.uri)` — \(resource.name)")
        }
        sections.append("")
        sections.append("## Privacy")
        sections.append("Media tools inspect captured proxy data only unless an open-world tool explicitly states otherwise.")
        sections.append("URLs, query tokens, raw bodies, and signed values are redacted or omitted from MCP payloads.")
        return sections.joined(separator: "\n")
    }

    private static func appendToolGroup(
        _ sections: inout [String],
        title: String,
        tools: [MCPToolCapabilityEntry],
        names: [String]
    ) {
        sections.append("### \(title)")
        let lookup = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        for name in names {
            guard let tool = lookup[name] else { continue }
            sections.append("- `\(tool.name)` — \(tool.description)")
        }
        sections.append("")
    }

    private static func bundleVersionHeader(manifest: MCPCapabilitiesManifest) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return """
        # JoesProxy MCP Agent Bundle v\(manifest.bundleVersion)
        # Generated: \(formatter.string(from: manifest.generatedAt)) — verify compatibility after app updates
        """
    }
}
