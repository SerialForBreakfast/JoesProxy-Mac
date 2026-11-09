
# JoesProxy MCP Diagnostics

JoesProxy is a local SSL-intercepting proxy with a full MCP server: it captures traffic routed through it, subject to protocol, inspection, and retention limits,
and lets you inspect, replay, and selectively mutate that traffic
(block, redirect, rewrite, throttle) to isolate root cause — all under an approval/audit/cleanup
model that mirrors what a human in the app would do by hand. This file is both a **diagnostic
playbook** (what to do, in what order) and a **feature-oriented reference** (use discovery for exact schemas and policy-visible availability).
Disclosure profiles control visible fields: **Metadata Only** limits structural detail;
**Shareable** adds sanitized host/path, safe headers and parser summaries.
**Developer Inspection (Automation)** currently uses Shareable field disclosure; grants and
approval policy remain separate. Discover selectable profiles rather than treating every profile
enum as available or assuming that an automation label authorizes broader data access.

## Start here: connect, discover, route

Documentation revision: 2026-10-29. JoesProxy is a native HTTP/HTTPS debugging proxy with
streaming-media testing; AI control is optional. This opening router is the entry point.
Read detailed sections only for the current task, not the entire feature reference on every turn.

1. Human: start MCP in JoesProxy's MCP Management, enroll this client, choose disclosure,
   and copy/export the connection configuration and Skill from the installed build.
   Agent: use that configuration without printing credentials. Do not invent a token or grant.
2. Agent: verify the running identity and connection. If CLI execution is restricted, use the
   configured MCP connector; it has the same authentication, disclosure and approval boundaries.
   Offline CLI documentation remains available without starting the app or reading credentials.
3. Agent: inspect `agent_toolset_status`. Select the relevant discovered toolset with
   `agent_toolset_select`; use `all` when auditing coverage or a feature appears missing.
   Read `joesproxy://agent/capabilities` for the full runtime catalog. A reduced toolset
   changes discovery size, not grants. An unexposed UI-only operation remains a human step.
4. Agent: use `documentation_search`, then `documentation_read` for the returned topic/section.
   Retrieve only needed pages; preserve query arguments with continuation cursors.
   The topic map below is a starting point, not a static inventory of every operation.
5. Agent: inspect prerequisites, perform only authorized actions, collect delivery evidence,
   obtain separate target-outcome evidence and stop/verify cleanup of owned effects.

| Goal | Start with documentation topics | Discovery route |
| --- | --- | --- |
| Connect, route traffic, trust and recover setup | `mcpAndCLI`, `setup`, `agent-documentation` | core, capture |
| Inspect bodies, filter, record, replay and explain missing evidence | `capturedSessions`, `requestInspector`, `workflow-evidence`, `bookmarksReplay` | capture |
| JSON/image mocks, rewrites, mappings, OpenAPI and conditions | `workflow-mocking`, `workflow-image`, `localOverrides`, `networkThrottling` | mocking |
| HLS, local fixtures, subtitles, ranges, telemetry and media faults | `mediaInfo`, `hub-mediaInfo`, `reference-tools` | media |
| Repeatable runs, comparisons, lifecycle and cleanup | `workflow-evidence`, `workflow-mocking`, `reference-tools` | reproduction |
| Specialized analysis and remaining registered capabilities | `reference-tools`, `reference-cli` | advanced, then all |

For exact schemas, allowed values and current availability, use runtime discovery. Do not claim
every desktop action is remotely exposed or every documented feature is enabled. Missing bodies
require their reported recovery path, not speculative device-profile reinstallation.
Agents never approve their own live requests. Target navigation, visible playback/captions,
host profiling and filesystem access retain their separate authority boundaries.

