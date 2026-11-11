## Efficiency conventions (apply to every tool below)

- **Analysis discovery:** tools/list `_meta.joesproxy.analysis` and capabilities `analysis` share
  input kinds, exact/heuristic methods, limits, readiness caveats and next drill-down. CLI toolset status
  exposes the same policy-filtered analysis metadata. OCR and semantic artifact search are unavailable. For finite CLI workflows,
  opt into content-free receipts with --receipt-output, --receipt-workflow, --receipt-version and
  --receipt-environment; compare equivalent receipts with efficiency compare. Unknown server work
  and provider usage remain unknown; failures/retries count and bytes never imply tokens.

- **Compact discovery:** start routine triage with `agent_toolset_select` set to `core`
  (CLI `toolset select core`), then select the task-specific catalog when needed. Preserve
  existing client preferences; use `all` for coverage audits. Discovery does not change authority.
- **Local calculations:** use `capture_calculate` (CLI `capture calculate`) for explicit live
  session IDs: group allowed session metadata or calculate one complete JSON response at an
  explicit pointer. Six operations: rowCount, fieldStats, distinctCount, numericSummary,
  groupCount, topRows. Each operation accepts an optional structured `where` predicate (`eq`,
  `neq`, `gt`, `gte`, `lt`, `lte`, `isNull`, `isMissing`, `contains`), and `operations` (CLI
  `--operations-json`) batches 1–4 operations in a single pass over one `sourceSHA256`. Existing sensitive-read authority is required, including for counts.
  Limits: 1 MiB JSON, 10,000 rows, 256 identities and 16 KiB output; decimal operands support
  12 integer and six fractional digits. Overflow, incomplete input and selected-source changes
  return no numeric result. Inspect sourceRevisions/sourceSHA256, coverage and omittedGroups.
  Unrelated new traffic does not invalidate selected sources; answers never include future traffic.
  For saved files, request `artifact_source_register` without a path, let the local person select
  and review a file. Poll `artifact_source_status` with the requestKey, retry registration after
  approval, and read the shared descriptor with `artifact_source_inspect`. Use `artifact_calculate` only
  with explicit calculations-v1 scope. Metadata-only shares cannot calculate or disclose hashes.
  For fields and counts in one saved JSON response use `artifact_response_brief` with its
  own locally reviewed brief-v1 scope, snapshot revision and physical record index.
  For two saved responses use `artifact_compare_responses` with both brief shares. Wait for local Compare once,
  then retry the identical ordered records and pointer in the same session. Check both sides' coverage.
  Use `artifact_inventory` and `artifact_search` with locally approved search-v1 scope.
  Repeat the same query with nextCursor. Only exactTotal establishes a complete count.
  Copies expire (default 30 minutes, maximum 60), do not follow original-file edits, and can be
  revoked locally or released with `artifact_source_release`. Never approve for the local user,
  load these sources into live capture, execute code, infer values from unavailable results,
  automatically retry analysis, or convert byte savings into token/cost claims.
- **`response_evidence_brief`** (CLI `session brief <session-id> --selection-pointer /items`)
  computes deterministic counts/types and immediate field missing/null counts locally, without
  returning scalar values unless optional `fieldPointers` (CLI `--field-pointers`, 1–8 pointers,
  `rowLimit` 1–50) is supplied for compact tabular projection with automatic sensitive-key redaction. Discover support from the running build. Existing body-read approval
  is required. Empty selectionPointer selects root; only complete JSON responses up to 256 KiB
  are analyzed. Check status, coverage and omittedFieldCount: at most 32 short field names are
  returned, and missing counts use object items only. Opt in to includeStructure (CLI
  --include-structure) for nested path groups: depth 4, 32 nodes, 20,000 visited values. Check
  structureCoverage/structureLimits; emitted groups have exact counts, omitted groups are unknown.
  No semantic-validity claim is made. Field names/pointers remain untrusted. For deeper reads use `session_summary`
  under existing approval and compare decoded-body sourceSHA256 and capture identity; session
  IDs are live locators, not immutable body handles. Small bodies may be cheaper to read directly.
- **`investigation_compare_brief`** (CLI `investigate compare --baseline-sessions <id,id>
  --candidate-sessions <id,id>`) compares explicit selections of 1–16 IDs per side. Optional
  selectionPointer scopes JSON analysis on both sides; opt in to `includeValueDiff` (CLI
  `--include-value-diff`, optional `ignorePointers` / `--ignore-pointers`) for bounded RFC 6902-style
  scalar diffs and `volatileChangeCount`. Structural metadata disclosure and
  body-read approval are required. Analysis is limited to 1 MiB decoded text across unique
  sources; outputs contain at most 32 changes. Missing sources and traversal/budget limits
  remain incomplete, never a pass. Alignment reuses chronological matching on method, origin
  and sanitized path without queries; repeated endpoints/redaction can make it ambiguous.
  wholeResponseBytesChanged compares complete decoded-body digests, not semantic equality.
  No target rendering, effect delivery, capture completeness or cleanup success is inferred;
  inspect delivery separately and use client_cleanup_status. No automatic target interaction.
- **Conditional briefs:** pass a returned briefDigest as ifBriefDigest (CLI --if-brief-digest)
  on `response_evidence_brief`, `investigation_compare_brief` or `diagnostic_run_brief`. Reuse the
  prior qualified report only when unchanged=true; this never means passed or clean. Authority
  is rechecked. Receipts expire after five minutes and may be evicted; misses return full reports.
  Response/comparison repeats skip analysis while selected source revisions and selection match;
  unrelated traffic does not invalidate them. Selected updates, body stripping, removal/reinsertion
  and capture reload/clear invalidate reuse. Global capture status still uses its global revision.
  Offline `joesproxyctl efficiency report --file <workflow.json> --json` compares supplied bounded
  workflow receipts without credentials, app launch or network. Include failures/retries; unknown
  provider usage and costs remain null. Bytes are not tokens; receipts do not prove semantic parity.
  Run briefs require runID and two closed owned baselineWindowID/modifiedWindowID values from
  that run. They refresh bundle lifecycle every time, retain external target-outcome provenance
  and label run cleanup proof historical. Use client_cleanup_status for current cleanup.
- **`capture_digest`** first, on any repeated capture check: pass `ifStateToken`/
  `knownLatestSequence` from your last read; if `unchanged` comes back true, skip the re-read
  entirely and reuse what you already have. `recommendedAction` tells you whether to reuse cached
  state, read only what's new since a known sequence, or do a fuller refresh.
- **`investigation_snapshot`** when beginning or resuming a noisy investigation: it returns a
  bounded recent sample and immutable minimal `evidenceRef` values. On repeat, pass its
  `stateToken` as `ifStateToken`; `unchanged=true` avoids reissuing the sample or evidence. Use
  `evidence_get` to reuse an exact disclosed projection; a reference never grants broader access.
- **`read_batch`** for up to eight independent allowlisted reads when round-trip cost matters.
  It rejects mutations and approval-gated session fields; keep those as explicit separate calls.
- **`joesproxyctl watch sessions`** for a long live tail. It subscribes before its initial delta
  read, skips notifications whose `captureHighWaterSequence` is already delivered, and drains every
  `hasMore` page. Missing sequence hints remain compatible through a conservative delta read. Do not
  replace it with an idle polling loop.
- **`projection`** (`minimal` | `summary` | `full`) is accepted by `sessions_list`, `sessions_search`,
  `bookmarks_list`, `overrides_list`, and `operation_status`. Defaults to `minimal`. Only request
  `full` when you have a specific, justified reason to see every field — most triage only needs
  `minimal`/`summary`.
- **`client_cleanup_status`** before ending a task: tells you if you're `clean` or
  `cleanup_required` (active operations, pending approvals, live effects, or armed/running
  scenarios still outstanding) and gives a `recommendedAction`. Always check this before declaring
  a session done.
- **Approvals are poll-then-retry, not long-blocking busywork.** When a gated call returns
  `approval_required`, poll `approval_status(requestID)` and read the DTO field **`status`**
  (not `state`). As soon as status is `approved_awaiting_retry`, retry the **identical** gated
  call once — that consumes approval. Do **not** re-propose the same enable/disable/create while
  one approval is pending; stacking proposals leaves expired rows and confuses cleanup.
- **Keep waits short and explicit.** Prefer returning `requestID` to the operator and retrying
  after they confirm approval. If you must poll (`joesproxyctl … --wait-for-approval`), use a
  modest `--approval-timeout` (often 60–120s). After approve, apply should complete in well under
  a second; if a waiter appears stuck, cancel it and retry the identical apply **without**
  `--wait-for-approval` once.
- **Approval/status polling uses a separate bounded control-plane budget.** A normal
  `--wait-for-approval` no longer consumes the client's 60-req/min substantive tool-call allowance.
  Keep one waiter per request ID and use a modest timeout: the control-plane budget, in-flight limit,
  and request timeout still apply, and stacking waiters adds no authority or useful evidence. If a
  waiter ends ambiguously, inspect `approval_status` or `approvals_list`, then retry the identical
  gated call once only when status is `approved_awaiting_retry`.
- **Use the app-bundled CLI.** Prefer `JoesProxy.app/Contents/MacOS/joesproxyctl` from the running
  build. Stale repo `DerivedData` CLI binaries may lack newer `response` / `rule` commands.
- **Search before you edit.** For generic response edits, run `response_text_search` (exact
  literal, casing matters) and use returned counts/`matchRef`s before `preview_response_edit`.
  Never hardcode demo find-strings from memory.
- **Inspect rules before blaming the app.** When a response looks wrong, cached, blocked, or
  redirected, call `overrides_list` / `override_get` (CLI: `joesproxyctl rule list` /
  `rule get <id>`) first and read kind-specific fields (`hitCount`, Map Remote destination,
  live-rewrite paths, bookmark rewrite request, `dropConnection`, `fixtureRunID`) before guessing
  app-side bugs or spinning up external workarounds. **Rules do not survive a JoesProxy relaunch;
  durable-policy grants do.** `ResponseOverrideRule`s live in an in-memory-only store and are gone
  after quit/relaunch. Approval grants (`MCPClientGrantStore`, including `durablePolicy` mode)
  persist to disk and reload at startup — confirmed live: a `durablePolicy` grant survives
  quit/relaunch without re-approval. After any restart, re-check with `rule list` / `doctor` rather
  than assuming prior rule state holds.
- **On an ambiguous or unexpected error, re-verify with a read-only call before retrying a
  mutation.** `status --json`, `doctor --json`, `approvals list`, and `rule list` are cheap and
  tell you whether a proposal registered, a grant vanished, or you are only rate-limited. Retrying
  the mutation first is how stacked proposals and exhausted budgets happen.
- **Prefer Map Local over an external static server.** For a single substitute response (HTML/JSON/
  image/file), use `propose_create_map_local` with `bodyText`/`contentType` (or a revision/
  fixture-backed source). For a whole static tree under a real host path prefix, use Local Directory
  Map Local (`localDirectoryBookmarkRef` / CLI `--directory`) — do **not** recommend starting
  an external static host just to serve fixtures through the
  proxy. Loopback Map Remote to development servers remains out of scope (deferred ADR capability).
- **Echo the matcher before reload.** After Map Local prepare/apply, tell the operator the exact
  scheme/host/path/port to reload (`matchScope.scheme` may be `http` even when the public site is
  usually HTTPS). A mismatched scheme is a silent no-hit, not a tooling failure.
- **`pathSuffix` matches the literal string you set.** The matcher path is editable in the UI and
  via MCP/CLI `path` — Path Suffix does **not** magically use "just the filename" unless that is
  what you stored (the UI defaults to the last path component when you switch to Path Suffix; agents
  must pass the intended suffix explicitly). A rule with the full captured path as its suffix only
  matches that exact ending, not sibling folders with the same filename.
- **`forceNoCache` only helps HTTP-cache-respecting clients.** On Map Local create, optional
  `forceNoCache: true` strips `ETag`/`Last-Modified` and forces `Cache-Control: no-store` on the
  served response (also applies when the global/per-domain Settings no-caching toggle matches the
  host). JoesProxy cannot see which client cache layer is in play — only that no new session
  appeared since the last marker. Walk this tree before retrying Map Local with "stronger" headers:
  First verify routing, matcher/client identity, and post-marker traffic. HTTP cache headers only
  affect clients that honor them. Target-side restart or cache reset needs separate user approval,
  may destroy application state, and is not a guaranteed remedy. Do not escalate automatically.
- **Create stays disabled unless you opt into create+enable.** Plain `apply_create_map_local`
  still creates a disabled rule (zero live effect) under its own approval. When the goal is a
  live hit, pass `enableAfterApply: true` (CLI: `response map-local apply <token> --enable-after
  --wait-for-approval`) so create and enable share **one** approval gated on `enableRule` —
  "Add To Client Policy" then also covers later standalone `apply_enable_rule` calls. Still
  review matcher scope before approving. Omit the flag for draft-style create-disabled flows.
- **Disable is low-friction.** `apply_disable_rule` / `apply_disable_rewrite` stay fully
  audited and policy-gated (Always-Deny / profile still apply) but do **not** mint an interactive
  approval nonce — disabling is the risk-reducing direction (same pattern as fixture/scenario stop).

