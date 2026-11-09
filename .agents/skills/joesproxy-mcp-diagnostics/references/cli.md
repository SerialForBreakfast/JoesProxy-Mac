## Bundled JoesProxy CLI

`joesproxyctl` is bundled at `JoesProxy.app/Contents/MacOS/joesproxyctl` for deterministic shell
automation and compact machine-readable evidence. Enroll it as a separate **JoesProxy CLI** client
in MCP Management, run `joesproxyctl auth login`, and paste the one-time credential at the hidden
prompt. The credential is stored in Keychain, never in command arguments or a project config file.
`auth status` reports whether a credential is currently stored for the target endpoint (no network
call); `auth logout` deletes the stored credential and any cached session — use it before enrolling
a freshly-minted credential to rule out a stale one. `mcp wait` polls for MCP readiness without also
requesting a start (use after `app launch`, which already requests start itself). `setup guide
[--format markdown|json]` fetches the same portable onboarding content as the
`joesproxy://setup/guide` resource, without requiring an established MCP session first.

The CLI uses the same loopback MCP transport, disclosure profile, approvals, audit trail, response
budgets, and cleanup rules as an agent client. It provides capture/session/media reads, operation
status/cancellation, waits, capture notifications, cleanup status, explicit logical-session
termination, `doctor` (non-mutating readiness diagnosis), and — as of workstream AK-5 — real
mutation commands: `app launch`/`mcp start|stop`/`proxy start|stop` (runtime control, gated behind
a stored credential and an opt-in "Allow JoesProxy CLI to start MCP" toggle in MCP Management),
`rewrite preview|prepare|apply|activate|disable` (live response rewriting), and a full
`scenario draft|validate|arm|activate|observe|assert|report|stop|cleanup` lifecycle. These go
through the same propose/approve/apply model and non-idempotent-retry-safe handling as any other
mutation in this catalog — the CLI does not bypass policy.

`sessions export --format json|ndjson|har` supports filtering by `--method`/`--host-category`/
`--session-id-prefix`/`--domain`/`--path`/`--since`/`--until`. Plain `json`/`ndjson` without
`--include-headers`/`--include-body` stays metadata-only and needs no approval, exactly as before.
Requesting `--format har`, or either `--include-*` flag, routes through a single bulk,
approval-gated `sessions_export` MCP tool call (one approval covers the whole export — it does not
prompt per session). With `--output` (and for HAR generally), the CLI sets `deliverFile` so JoesProxy
writes the full matching capture under Application Support `MCPExports/` and the CLI copies it to
`--output` — same completeness as GUI Export All HAR, not limited by the 1 MB inline MCP budget or
the default 500-session inline cap (pass `--max-sessions` only as an optional safety valve). Inline
MCP tool results without file delivery remain bounded (500 / 1 MB) and auto-spill to a managed file
when oversized. This does *not* bypass disclosure policy — a record whose header/body wasn't
approved is exported with those fields simply absent, same redact-don't-error behavior as
`session_summary`.

Use `joesproxyctl help` for the exact command surface and `--json` for stable result envelopes.

### Deterministic session filtering and CLI JSON output

When searching, filtering, or extracting captured network traffic via the CLI, **always pass `--json`** to receive the structured `CLIResultEnvelope` (`{"command": ..., "success": true, "result": {"sessions": [...]}}`), and parse output directly with `jq`.

**Supported `joesproxyctl sessions search` filter options:**
- `--domain <domain>` — Filter by host/domain name (e.g. `--domain api.example.com`).
- `--path <path>` — Filter by request path or path prefix (e.g. `--path /v1/auth` or `--path .m3u8`).
- `--method <method>` — Filter by HTTP method (e.g. `--method POST`, `--method GET`).
- `--host-category <category>` — Filter by classified category (`direct_origin`, `synthetic_asset`, `capture_marker`, `ad_telemetry`, etc.).
- `--since <iso-timestamp>` / `--until <iso-timestamp>` — Filter by start timestamp range.
- `--session-id-prefix <prefix>` — Filter by the starting hex/UUID characters of the session ID.
- `--limit <n>` — Maximum number of sessions to return (default: 50).
- `--projection minimal|summary|full` — Information depth (`minimal` is fastest and avoids large payloads).
- `--json` — Format output as standardized JSON.

**Common CLI recipes with `jq`:**
```bash
# Find all POST requests to a specific domain and extract IDs and status codes
joesproxyctl sessions search --domain api.example.com --method POST --json | jq '.result.sessions[] | {id: .sessionID, path: .path, status: .statusCode}'

# Find media playlist requests
joesproxyctl sessions search --path .m3u8 --json | jq '.result.sessions[] | {id: .sessionID, path: .path}'

# List newest 10 sessions in minimal projection
joesproxyctl sessions list --limit 10 --projection minimal --json | jq '.result.sessions'

# Inspect one session's summary (status, headers, timing)
joesproxyctl session show <session-id> --include-headers --json | jq '.result'
```

**MCP equivalent (`sessions_search` tool):**
Pass structured arguments:
`{"domain": "api.example.com", "path": "/v1/data", "method": "POST", "limit": 20, "projection": "minimal"}`

