import Foundation

/// One client's real connection mechanism — a terminal command for clients with a CLI installer,
/// or a config file to edit for everything else. See `MCPClientConfigSnippetBuilder.setupInstructions`.
struct MCPClientSetupInstructions: Equatable {
    enum Mechanism: Equatable {
        /// Run this exact command in a terminal — no file to place.
        case command(String)
        /// Add `content` to the config file at `path`.
        case fileEdit(path: String, content: String)
    }

    let kind: MCPClientKind
    let mechanism: Mechanism
    let restartNote: String
    let caveat: String?
}

/// Builds copy-paste client configuration snippets for enrolled MCP clients.
///
/// Concurrency: `Sendable` and stateless; callers supply endpoint URL and one-time bearer on the main actor.
enum MCPClientConfigSnippetBuilder {
    static let enrollmentTokenPlaceholder = "<PASTE_ENROLLED_TOKEN>"

    static func joesProxyCLICommand(
        endpointURL: URL,
        appBundleURL: URL = Bundle.main.bundleURL
    ) -> String {
        let executableURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("joesproxyctl", isDirectory: false)
        let quotedPath = "'\(executableURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        let quotedEndpoint = "'\(endpointURL.absoluteString.replacingOccurrences(of: "'", with: "'\\''"))'"
        return "\(quotedPath) auth login --endpoint \(quotedEndpoint)"
    }

    static func codexConfig(
        endpointURL: URL,
        bearerToken: String = enrollmentTokenPlaceholder
    ) -> String {
        let hostPort = endpointURL.host ?? "127.0.0.1"
        let portSuffix = endpointURL.port.map { ":\($0)" } ?? ""
        let path = endpointURL.path.isEmpty ? MCPNetworkConstants.endpointPath : endpointURL.path
        return """
        # JoesProxy MCP Agent Bundle v\(MCPCapabilitiesRevision.bundleVersion())
        # Save in <project-root>/.codex/config.toml for Codex CLI and the Codex desktop app.
        # Keep this project-scoped file out of source control because it contains a real credential.
        [mcp_servers.joesproxy]
        url = "http://\(hostPort)\(portSuffix)\(path)"
        http_headers = { Authorization = "Bearer \(bearerToken)" }
        startup_timeout_sec = 10
        tool_timeout_sec = 45
        enabled = true
        required = false
        """
    }

    /// Claude Desktop config (`claude_desktop_config.json`) — hand-pasted, no CLI equivalent exists.
    static func claudeMCPJSON(
        endpointURL: URL,
        bearerToken: String = enrollmentTokenPlaceholder,
        clientLabel: String
    ) -> String {
        let sanitizedLabel = sanitizedConfigKey(from: clientLabel, allowed: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")))
        let serverKey = sanitizedLabel.isEmpty ? "joesproxy" : "joesproxy-\(sanitizedLabel)"
        return """
        {
          "mcpServers": {
            "\(serverKey)": {
              "type": "http",
              "url": "\(endpointURL.absoluteString)",
              "headers": {
                "Authorization": "Bearer \(bearerToken)"
              }
            }
          }
        }
        """
    }

    /// Claude Code CLI's one-line install — no file to place. Exact form validated against a real
    /// `claude mcp add` invocation (`memlog/utility_scripts/run_mcp_transport_spike.sh`,
    /// confirmed working across 3 independent runs per `AG-0-Transport-Spike-Results.md`).
    static func claudeCodeCommand(
        endpointURL: URL,
        bearerToken: String = enrollmentTokenPlaceholder,
        clientLabel: String
    ) -> String {
        let sanitizedLabel = sanitizedConfigKey(from: clientLabel, allowed: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")))
        let serverKey = sanitizedLabel.isEmpty ? "joesproxy" : "joesproxy-\(sanitizedLabel)"
        return """
        claude mcp add --transport http \(serverKey) \(endpointURL.absoluteString) \\
          --header "Authorization: Bearer \(bearerToken)"

        # Remove later with: claude mcp remove \(serverKey)
        """
    }

    /// Project-level Cursor MCP config (`.cursor/mcp.json`) or global `~/.cursor/mcp.json`.
    static func cursorMCPJSON(
        endpointURL: URL,
        bearerToken: String = enrollmentTokenPlaceholder,
        clientLabel: String
    ) -> String {
        let sanitizedLabel = sanitizedConfigKey(from: clientLabel, allowed: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")))
        let serverKey = sanitizedLabel.isEmpty ? "joesproxy" : "joesproxy-\(sanitizedLabel)"
        return """
        {
          "mcpServers": {
            "\(serverKey)": {
              "type": "http",
              "url": "\(endpointURL.absoluteString)",
              "headers": {
                "Authorization": "Bearer \(bearerToken)"
              }
            }
          }
        }
        """
    }

    /// Single source of truth for "how does this specific client actually get connected" — a
    /// command to run for Claude Code, a file to edit for everything else. Shared by the Clients
    /// enrollment panel and the Agent Setup tab so both always agree on one client's real
    /// mechanism instead of dumping all snippets regardless of which client was picked.
    static func setupInstructions(
        for kind: MCPClientKind,
        endpointURL: URL,
        bearerToken: String = enrollmentTokenPlaceholder,
        clientLabel: String
    ) -> MCPClientSetupInstructions {
        switch kind {
        case .joesProxyCLI:
            return MCPClientSetupInstructions(
                kind: kind,
                mechanism: .command(joesProxyCLICommand(endpointURL: endpointURL)),
                restartNote: "Paste the one-time credential at the hidden prompt. The CLI stores it in Keychain and can be used immediately; no client restart is needed.",
                caveat: "This enrolls only the bundled JoesProxy CLI. Enable 'Allow JoesProxy CLI to start MCP' in Overview, then run 'joesproxyctl doctor'. Proxy and shutdown controls remain approval-gated unless Runtime Control is added to this client policy."
            )
        case .claudeCode:
            return MCPClientSetupInstructions(
                kind: kind,
                mechanism: .command(claudeCodeCommand(endpointURL: endpointURL, bearerToken: bearerToken, clientLabel: clientLabel)),
                restartNote: "Start a new Claude Code session — MCP servers are discovered at session start, not hot-reloaded into one already running.",
                caveat: nil
            )
        case .claudeDesktop:
            return MCPClientSetupInstructions(
                kind: kind,
                mechanism: .fileEdit(
                    path: "~/Library/Application Support/Claude/claude_desktop_config.json",
                    content: claudeMCPJSON(endpointURL: endpointURL, bearerToken: bearerToken, clientLabel: clientLabel)
                ),
                restartNote: "Quit and reopen Claude Desktop completely (not just close the window).",
                caveat: "Exact key names may vary by Claude Desktop version — verify against Anthropic's current docs if it doesn't connect."
            )
        case .cursor:
            return MCPClientSetupInstructions(
                kind: kind,
                mechanism: .fileEdit(
                    path: "~/.cursor/mcp.json (global) or .cursor/mcp.json in your project root",
                    content: cursorMCPJSON(endpointURL: endpointURL, bearerToken: bearerToken, clientLabel: clientLabel)
                ),
                restartNote: "Toggle it off/on in Cursor Settings → MCPs, or restart Cursor.",
                caveat: nil
            )
        case .codexCLI:
            return MCPClientSetupInstructions(
                kind: kind,
                mechanism: .fileEdit(
                    path: ".codex/config.toml in your project root",
                    content: codexConfig(endpointURL: endpointURL, bearerToken: bearerToken)
                ),
                restartNote: "Open this project in a new Codex CLI session or restart the Codex desktop app. Existing tasks do not hot-load MCP changes.",
                caveat: "Codex CLI and the Codex desktop app use this same project configuration. Global installation is intentionally not the default."
            )
        case .other:
            return MCPClientSetupInstructions(
                kind: kind,
                mechanism: .fileEdit(
                    path: "your MCP client's config file — check its docs for the exact location",
                    content: claudeMCPJSON(endpointURL: endpointURL, bearerToken: bearerToken, clientLabel: clientLabel)
                ),
                restartNote: "Restart or reconnect the client after saving — most MCP clients only discover servers at startup.",
                caveat: "This is a generic `mcpServers` JSON shape; adjust key names if your client's docs differ."
            )
        }
    }

    private static func sanitizedConfigKey(from label: String, allowed: CharacterSet) -> String {
        label
            .lowercased()
            .replacingOccurrences(of: " ", with: allowed.contains("_") ? "_" : "-")
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
    }
}
