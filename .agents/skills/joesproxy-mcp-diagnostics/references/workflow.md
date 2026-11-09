## Start here: task router and the real-device mutation loop

A real-device field session running an earlier version of this Skill spent hours on matcher
semantics, client cache, and identity cloning — not on missing tools. The `Feature catalog` and
`Advanced agentic diagnostics` sections below are *reference
material*: consult them for one tool's exact arguments, don't read them start-to-finish before
acting. This section is the actual sequence that resolves the dominant job.

**Route the task first:**

```text
Need to understand traffic only (no mutation)?
    -> doctor -> capture_marker -> bounded session search -> inspect/export -> evidence summary
       (this read-only path is JoesProxy's strongest capability — prefer it whenever the question
       is "what actually happened," not "make it behave differently")

Need to change one readable (JSON/text) response?
    -> capture -> preview_response_edit -> propose_create_map_local -> approve
       -> require a new attributed request -> cleanup

Need to replace one binary asset (image, font, small media file)?
    -> discover support for `localFileBookmarkRef` -> CLI `response map-local prepare --file`
       mints the opaque file reference -> preview the exact matcher and asset metadata
       -> approve/apply through the existing policy -> verify the resulting rule serves status 2xx
       (the create-from-a-captured-session flow now defaults to 200 and warns on non-2xx, but
       always double-check if a non-2xx value is intentional) -> require a new attributed request

Need to append an item with coordinated images?
    -> use the coordinated mocking recipes above; prepare/review/import a captured revision
       -> local-user approval -> activate -> inspect per-resource delivery evidence -> cleanup

Need a directory-backed site rather than a coordinated collection revision?
    -> prepare files locally -> Local Directory Map Local at the narrowest prefix that
       covers only files you own -> before enabling, check the proposal's own `matcherScope`
       disclosure (observedCaptureCardinality, conflicting rule IDs) so you know what else that
       scope would touch -> approve -> verify each critical path individually -> cleanup

Need to substitute streaming media?
    -> hls substitute profiles (read the enums it returns) -> start from the recommended profile
       -> hls substitute status for entry/child/segment progression -> once delivery is proven,
       stop mutating and treat further failure as a client/player question, not a proxy question
```

**The real-device mutation playbook** (the sequence behind the second/third/fourth branches above):

1. Run `doctor`; confirm the target is actually routed through JoesProxy.
2. Place a marker immediately before the action you're about to drive on the target.
3. Find and inspect only post-marker traffic — don't reason from older captures.
4. Choose the least powerful adequate source: an inline text edit before a directory, a directory
   before a broad prefix, a narrow matcher before a broad one.
5. Before approving, read back the matcher (method/host/path/matchMode) and, for Map Local
   proposals, the `matcherScope` disclosure — `observedCaptureCardinality` tells you how many
   already-captured sessions this scope would touch, and `conflictingEnabledRuleIDs` tells you what
   else is already live at an overlapping scope. A directory prefix additionally shadows *any*
   sibling request under it. Explicitly choose strict-local versus overlay behavior using the
   discovered missing-file policy; inspect sibling-path consequences before approval. Do not
   assume a missing file will be forwarded upstream.
6. Apply and let the human approve.
7. Drive one target action.
8. Require a **new, attributed** request before judging anything — `rule get`'s hit count, not
   "I created the rule," is what tells you it actually fired. `capture_activity_since_marker`
   (marker's sessionID + the rule's overrideID) answers this in one call instead of manually
   diffing two separate lookups. No new request does not prove caching or navigation behavior.
   If a fresh request was observed but did not match, inspect its actual scope before changing
   anything. For authored bundles, prefer the per-resource receipts described above.
9. If the wire-level result is correct (right bytes, right status, attributed hit) but the target
   still doesn't show/play the intended thing, **stop mutating proxy state**. Possible client-side explanations include: the target has its own object/identity cache and made no new request at all for a
   changed asset, or the target resolved a *different* object than the one you edited because it
   reused another item's identity key (content id, event id, etc.) — cloning a captured catalog
   object and giving it a shared identity is a common way to hit this. For streaming specifically,
   proven delivery (playlists served, hit counts climbing) with segment requests never progressing
   is a real, distinct signature — treat it as a player/buffer question and move to client logs, not
   as evidence your substitution is wrong.
10. Disable/remove the effect and confirm return to normal. Remember that MCP-origin rules,
    bookmarks, throttle overrides, and scenarios are all intentionally purged on the next app
    launch — nothing you create through this Skill survives a relaunch by default, so don't treat a
    later "the rule is gone" as evidence something broke.

## Prefer diagnostic runs (AN-6)

When investigating a hypothesis against live traffic, prefer a **diagnostic run** over a loose
sequence of mutation tools:

1. Gate on doctor/`runtime_status` compatibility first (`capabilitiesBundleVersion` must match the
   running app; read the current manifest rather than hardcoding a revision).
2. `diagnostic_run_create` with owner-authored hypothesis/expected-observation text and explicit
   scopes (`http`, `capturedSession`, or `effect`). Never paste untrusted bodies into hypothesis fields.
3. `diagnostic_run_start` installs observation watches only — it does **not** activate effects or Mac
   system-proxy routing.
4. Drive traffic; read `diagnostic_run_observations` (scoped; absence is first-class).
5. `diagnostic_run_close` with Passed/Failed/Inconclusive + reason code; cleanup must verify before a
   completed conclusion. Cleanup Required is not success.
6. Re-check later via `propose_diagnostic_run_recheck` → one approval → `apply_diagnostic_run_recheck`
   (CLI: `joesproxyctl run recheck prepare|apply --wait-for-approval`). **Order matters**: call
   `recheck prepare` first, *then* drive the fresh traffic you want checked, *then* call
   `recheck apply`. `apply` gathers its own fresh observation by re-scanning already-captured
   sessions since `prepare`'s timestamp — it never waits for new traffic and never accepts one from
   the caller — so traffic driven before `prepare` falls outside the window and the result comes
   back `inconclusive(no_request)` even though real traffic happened. Confirmed live 2026-08-12.

Create/start/close of observation-only runs do not mint approvals. One approval is required only when
a composite action recreates reviewed effects (re-check apply).

**`joesproxyctl run` command reference** (confirmed live 2026-08-12; the run ID/evidence ID/proposal
token are positional arguments, not flags, except where noted):

```
joesproxyctl run list [--limit <n>]
joesproxyctl run create --hypothesis <text> --expected <text>
  [--host <host> --path <path> [--method GET] [--scheme https] [--port <n>] [--path-match exact|prefix|suffix]]
  [--session-id <uuid> [--fingerprint <token>] [--capture-epoch <id>]] [--lifetime <seconds>]
joesproxyctl run start <run-id>
joesproxyctl run status <run-id>
joesproxyctl run observations <run-id> [--limit <n>]
joesproxyctl run close <run-id> --terminal passed|failed|inconclusive|expired
  [--outcome <outcome> --reason <code> --summary <text> [--confidence <level>]]
joesproxyctl run retry-cleanup <run-id>
joesproxyctl run evidence list
joesproxyctl run evidence get <evidence-id>
joesproxyctl run recheck prepare --evidence-id <uuid>
joesproxyctl run recheck apply <proposal-token> [--wait-for-approval]
```

`--outcome`/`--reason`/`--summary` are required on `run close` unless `--terminal expired`.

## Native MCP prompts

Beyond this file/skill, JoesProxy also exposes itself as a native MCP `prompts` capability — useful
when a client surfaces MCP prompts directly instead of (or in addition to) a file-based skill.
`prompts/list` returns exactly two: `joesproxy_diagnose` (this same diagnostic playbook, fetched via
`prompts/get` with that `name`) and `joesproxy_setup_onboarding` — a much shorter prompt, available
only after authenticated MCP connection, purpose-built for "help me get connected and verified" rather
than active diagnosis: `runtime_status` → `setup_readiness` (one target) → generate real traffic →
verify the resulting capture → `client_cleanup_status`. Prefer fetching that prompt over re-deriving
the cold-start sequence by hand when onboarding is the actual ask.

## Connect quick-check

Before calling any tool, confirm all of these — a missing one produces a confusing, generic error
rather than a clear one:

1. `Authorization: Bearer <token>` — the one-time token from JoesProxy's Clients tab.
2. `Accept: application/json, text/event-stream` on every request (both media types, not just
   `application/json` — a server that only sends one type returns 406).
3. `MCP-Protocol-Version: <version>` header on every call **after** `initialize` (the version
   `initialize` negotiated back to you). Omitting it is the single most common reason a first tool
   call after a clean `initialize` fails with a session error.
4. Send `notifications/initialized` after `initialize` and before any other call — some clients
   skip this and get "Session not initialized."
5. Reuse the `Mcp-Session-Id` header returned by `initialize` on every subsequent call in that
   session.
6. Treat HTTP 404 for a session-bound request as a reinitialization signal. Create a new logical
   session and resend `notifications/initialized`; do not keep retrying the expired session ID.

For direct `curl` diagnostics, use `--data-binary` for JSON-RPC request bodies. `-d` may reinterpret
payload bytes. JoesProxy permits bounded concurrent logical sessions for one credential, so a
secondary `mcp list/get` health check must not terminate the session doing real work.

## When CLI sandboxing blocks the investigation

Revision: 2026-09-09. Recommend a connected native MCP client when the CLI cannot launch, cannot
read its Keychain credential, cannot reach loopback from its execution sandbox, or lacks a command
supported by the running server. Explain the benefit before requesting broader shell permissions.
Do not call an inaccessible Keychain credential "missing" or ask the user to rotate it without
evidence that the server rejected it.

Native MCP sends structured tool calls through the agent host's configured connection. It can
avoid shell execution, PATH/quoting problems, CLI-specific credential access, and a stale CLI parser.
The CLI already uses MCP underneath: shared server tools retain the same validation, disclosure,
approval, and evidence behavior. A native connection can have different network permissions from
the shell, but connectivity is not guaranteed—especially when the agent host is remote and its
localhost is not the Mac running JoesProxy.

- **Discover first:** check whether JoesProxy tools/resources are actually connected. If not,
  explain that the user must configure/enroll a native connection using their agent host's supported
  setup. Do not claim tools are available, install a connector, alter credentials, expose the server
  publicly, or start/restart the app without the relevant authorization.
- **Verify equivalence:** read runtime_status and the running capability manifest, then discover
  the required tool's schema. Start with a bounded capture_digest. Native MCP can avoid an outdated
  CLI command surface; it cannot add an unimplemented server feature. CLI-local conveniences such
  as creating file bookmarks, copying exports, or launching the app may have no native equivalent.
- **Assets remain permission-bound:** prefer available opaque body/asset references and
  server-retained revisions. A raw local path is not a portable upload or a security-scoped
  bookmark. If no supported native import path exists, ask the user to select/import the file in
  JoesProxy or use an authorized local helper. Never encode image bytes as text to evade the
  limitation, and never promise MCP will fix an app or test runner's filesystem permissions.
- **Preserve the experiment:** carry over capture IDs/epoch, intended client scope, reviewed
  revision/digest, observation marker, and outstanding effect/approval IDs as context only. Verify
  their availability and ownership with the new client; references may be client/session scoped.
  A new MCP identity does not inherit CLI grants, pending approvals, proposals, or effect ownership.
  Inspect before retrying any mutation. If the new client cannot manage the old effects, have the
  original client or local user resolve cleanup before creating replacements.
- **Stop at policy boundaries:** native MCP is an alternative supported transport, not a sandbox,
  privacy, approval, or device-control bypass. If the connection is unavailable or the required
  operation is denied, report the exact blocker and the smallest user action needed. Do not probe
  alternative transports to circumvent an explicit denial.

Suggested explanation: "A native JoesProxy MCP connection may let us inspect and prepare mocks
without launching the CLI or accessing its Keychain entry from this shell. JoesProxy still enforces
its approvals and file access. I'll verify the connection and supported tools first; any local
image import or ownership handoff may still need your help."

