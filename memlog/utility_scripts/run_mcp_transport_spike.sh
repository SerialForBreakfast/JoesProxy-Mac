#!/usr/bin/env bash
# Starts the AG-0 MCP transport spike for manual Claude/Codex validation.
# Prints the one-time bearer credential and example client configuration snippets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="${MCP_SPIKE_PORT:-9091}"

echo "Building the JoesProxy debug app..."
cd "$ROOT"
xcodebuild build -scheme JoesProxy -destination "platform=macOS" -configuration Debug -quiet

DERIVED="$(xcodebuild -scheme JoesProxy -destination "platform=macOS" -showBuildSettings 2>/dev/null | awk -F' = ' '/BUILD_DIR/ {print $2; exit}')"
APP_EXECUTABLE="$DERIVED/Debug/JoesProxy.app/Contents/MacOS/JoesProxy"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "Could not locate the JoesProxy debug executable." >&2
  exit 1
fi

CREDENTIAL="$(openssl rand -hex 32)"

echo ""
echo "Starting MCP transport spike on http://127.0.0.1:${PORT}/mcp"
echo "Press Ctrl+C to stop."
echo "Sanitized connection events will appear as JOESPROXY_MCP_SPIKE_EVENT lines."
echo "Credentials, headers, payloads, and MCP session identifiers are not logged."
echo ""
echo "Temporary Codex configuration (copy this exact generated block):"
echo "The credential changes every time this script starts."
echo ""
cat <<EOF
[mcp_servers.joesproxy_spike]
url = "http://127.0.0.1:${PORT}/mcp"
http_headers = { Authorization = "Bearer ${CREDENTIAL}" }
startup_timeout_sec = 10
tool_timeout_sec = 45
enabled = true
required = false
EOF

echo ""
echo "Add this temporary block to Codex MCP settings, restart Codex, and call mcp_ping."
echo "Do not use a placeholder such as TEMPORARY_CREDENTIAL."
echo "Remove the block after testing. The disposable credential is valid only for this process."
echo ""
echo "----------------------------------------------------------------------"
echo ""
echo "Temporary Claude Code configuration."
echo ""
echo "Two different surfaces are involved below — do not mix them up:"
echo "  SHELL   = the ordinary terminal you are reading this in right now."
echo "  SESSION = a Claude Code chat session (run 'claude' to start one), where you"
echo "            type natural-language requests, not shell commands."
echo ""
echo "Setup (SHELL) — choose Option 1 or Option 2, both run in your ordinary terminal:"
echo ""
echo "OPTION 1 (recommended — no file to place, run this exact command in SHELL):"
echo "Verify flags against 'claude mcp add --help' first if this errors — CLI flag"
echo "names can drift between Claude Code versions."
echo ""
echo "  claude mcp add --transport http joesproxy-spike http://127.0.0.1:${PORT}/mcp \\"
echo "    --header \"Authorization: Bearer ${CREDENTIAL}\""
echo ""
echo "To remove later, run in SHELL: claude mcp remove joesproxy-spike"
echo ""
echo "OPTION 2 (project-scoped file — copy the whole block below and paste it into"
echo "SHELL, then press Enter; do not retype it by hand):"
echo ""
cat <<CMDEOF
cat > "${ROOT}/.mcp.json" <<'JSONEOF'
{
  "mcpServers": {
    "joesproxy-spike": {
      "type": "http",
      "url": "http://127.0.0.1:${PORT}/mcp",
      "headers": {
        "Authorization": "Bearer ${CREDENTIAL}"
      }
    }
  }
}
JSONEOF
CMDEOF
echo ""
echo "  File created at: ${ROOT}/.mcp.json"
echo "  Required filename: .mcp.json exactly (Claude Code will not discover any other"
echo "  name; joesproxy.mcp.json.example in the repo is a reference template only)."
echo "  Not committed: already gitignored."
echo "  To remove later, run in SHELL: rm \"${ROOT}/.mcp.json\""
echo ""
echo "After EITHER option, start a NEW Claude Code SESSION (run 'claude' — an already"
echo "running session cannot pick up a server added after it started)."
echo ""
echo "Validation (SESSION) — type this as a chat message inside that new session, not"
echo "a shell command:"
echo ""
echo "  List your available MCP tools, then call joesproxy-spike's mcp_ping tool and"
echo "  show me the full result."
echo ""
echo "Each option's credential is valid only for this process — do not reuse it later."
echo ""

JOESPROXY_MCP_SPIKE_CREDENTIAL="$CREDENTIAL" \
  "$APP_EXECUTABLE" \
  --mcp-transport-spike \
  "--mcp-spike-port=${PORT}"
