### Bookmarks & overrides (inspect first)
- `bookmarks_list` / `bookmark_get` — saved requests, with any saved response snapshot and rewrite
  rules. CLI: `joesproxyctl bookmark list` / `bookmark get <id>`.
- `overrides_list` / `override_get` — every Block/Map Local/Map Remote/live-rewrite/throttle-style
  rule with enough detail to diagnose without body bytes: enabled state, matcher, `hitCount` /
  `lastMatchedAt`, Map Remote destination, live-rewrite JSON paths, bookmark rewrite request,
  `dropConnection`, `fixtureRunID`, `forceNoCache` when present. Prefer this (or CLI
  `joesproxyctl rule list` / `rule get <id>`) before create/enable when traffic looks mutated.
  After a JoesProxy relaunch, this list is authoritative for rules: in-memory rules are gone until
  recreated. `durablePolicy` grants persist to disk and survive relaunch — check `doctor` before
  assuming a standing approval was lost.
- **Delete (MCP-owned only)** — `propose_delete_rule` / `apply_delete_rule` remove a rule this MCP
  client created (approval-gated `.destructiveTool`; Always-Deny for automation-only recipes). CLI:
  `joesproxyctl rule delete` / `rule apply-delete`. Prefer disable when you may re-enable; delete
  when cleanup should remove the rule entirely. UI-created rules are out of scope for MCP delete.

### Create-disabled mutations (propose → apply; start disabled unless enableAfterApply)
Every create tool is a `propose_*`/`apply_*` pair: `propose_*` returns a `proposalToken` plus a
disclosure (`matchScope`, `effectSummary`, `riskTier`) — read it before calling `apply_*`. Create
tools leave the rule **disabled** unless `apply_create_map_local` is called with
`enableAfterApply: true` (create+enable under one `enableRule` approval). Otherwise the rule has
zero effect on traffic until separately enabled (below).

Approval never executes the requested read or mutation. When a gated call returns
`approval_required`, poll `approval_status(requestID)` and read **`status`** (values include
`pending`, `approved_awaiting_retry`, `consumed`, `denied`, `expired`, `invalidated`). After
`approved_awaiting_retry`, retry the original call with byte-identical arguments; that retry
consumes approval once. Repeated identical requests while pending are deduplicated — do not mint
a second propose for the same enable/disable while waiting.
- **Block** — `propose_create_block` / `apply_create_block`: `method`, `host`, `path`, `matchMode`,
  `statusCode`, optional `scheme`/`port`/`dropConnection`/`graphqlOperationName`. `matchMode`
  includes `pathSuffix` —
  matches any path *ending* with `path`, ignoring query — the only mode that can isolate two
  endpoints sharing a dynamic path segment (e.g. `/v1/sessions/{id}/heartbeat` vs.
  `/v1/sessions/{id}/status`) without also matching every sibling under that prefix; `pathPrefix`
  cannot make that distinction. `matchMode: "filename"` matches on the request's last path
  component alone, regardless of which directory it's nested under — set `path` to just the
  filename (e.g. `poster.png`), not a full path. Use this instead of hand-crafting a `pathSuffix`
  rule whose `path` you've trimmed down to a bare filename (the previous workaround for the same
  job); prefer `filename` whenever the exact directory nesting is unknown, variable, or irrelevant
  to the job — reach for `pathSuffix` only when the match should stay anchored to a longer, known
  path tail. `graphqlOperationName` (optional string) additionally requires the
  request body to be JSON whose top-level `operationName` field equals this value — use it to scope
  a rule to one specific query/mutation on a GraphQL endpoint that serves every operation from the
  same path (e.g. `/graphql`); omit it to match every operation on that path, same as before this
  field existed. `matchQueryKey`/`matchQueryValue` (both optional, must be supplied together)
  additionally require the request's query string to contain this exact key=value pair — use it to
  mock one item on a query-multiplexed endpoint (e.g. `?contentId=1234`) without affecting other
  values of the same parameter on the same path; pair with `matchMode: "ignoreQuery"` (not
  `"exactPath"`, which would require the *entire* query string to match byte-for-byte, defeating the
  point). `dropConnection: true` closes the connection with no HTTP response
  at all instead of serving `statusCode` — simulates a real timeout/reset rather than a clean error;
  a client's recovery logic frequently branches on which of the two actually happened, so use
  whichever matches the failure mode you're trying to reproduce. Same fields are available on a
  scenario's `block` fault (below). CLI: `joesproxyctl block prepare|apply` (`--graphql-operation-name
  <name>`, `--match-query-key <key> --match-query-value <value>`).
- **Map Local** — `propose_create_map_local` / `apply_create_map_local`: same matcher (including
  `graphqlOperationName`/`matchQueryKey`/`matchQueryValue`, except on the
  `responseEditPreviewDigest`/`hlsPreviewDigest`/
  `responseRevisionID` sub-paths — see below), plus
  `bodyText`/`contentType` for the inline response served instead of the real backend. Alternatively
  pass `fixtureRunID` (requires `matchMode: "pathPrefix"`) to delegate to a running HLS fixture run
  instead of a static body — see "Streaming source redirect" below. Or pass opaque
  `localDirectoryBookmarkRef` (base64 bookmark from CLI `response map-local prepare
  --directory <path> …`, never a raw filesystem path over MCP; requires `pathPrefix`) to serve a
  whole folder under that prefix — see "Local directory Map Local" below. This is the supported way
  to serve local substitute content through the proxy; do not start an external static file server
  for the same job. Optional `forceNoCache: true` forces `no-store` / strips validators on the served
  Map Local response (HTTP-cache clients only — see Efficiency conventions). Optional
  `notFoundRelativePath` (directory source only) serves a relative failure page as HTTP 404.
  Optional `missingFilePolicy` (directory source only; `strictLocal`/`overlayFailOpen`/
  `configuredFallback`, defaults to `strictLocal`) controls what happens when a request under this
  prefix has no matching file in the folder — `strictLocal` (default) always 404s locally, exactly
  today's original behavior; `overlayFailOpen` forwards that request to the real upstream instead,
  so unedited sibling paths under the same prefix behave as if no rule existed at all; use this when
  a directory rule is meant to edit a few files, not shadow everything else under that path.
  `configuredFallback` serves `notFoundRelativePath`'s bytes under a forced 404 and requires
  `notFoundRelativePath` to actually be set. `propose_create_map_local` also returns a
  `capturedSiblingsNotOnDisk` disclosure (count + relative paths) when captured sessions exist
  under this prefix with no matching local file — check it before approving, especially under the
  default `strictLocal` policy. Or pass opaque `localFileBookmarkRef` (base64 bookmark from CLI
  `response map-local prepare --file <path> …`, never a raw filesystem path over MCP) to serve one
  local binary file directly — the first-class replacement for the one-file-directory workaround.
  Unlike `localDirectoryBookmarkRef`, this does **not** require `matchMode: pathPrefix`; a single
  file naturally wants `exactPath`/`pathSuffix`/`filename` instead. `contentType` is inferred from
  the file's extension when omitted; `statusCode` defaults to 200. `graphqlOperationName` is rejected outright (not silently ignored) if passed alongside
  `responseEditPreviewDigest`/`hlsPreviewDigest`/`responseRevisionID` — those sub-paths inherit their
  matcher from an earlier preview/draft call and cannot pick up a fresh scope at create time.
- **Map Remote** — `propose_create_map_remote` / `apply_create_map_remote`: same matcher, plus
  `remoteHost`/`remotePort`/`remoteScheme` — the destination cannot be any loopback address (checked
  against the full `127.0.0.0/8` range, not just `127.0.0.1`). Supports `graphqlOperationName` like
  the others. No `joesproxyctl` CLI command exists for Map Remote — MCP tool only.
- **Rewrite** — `propose_create_rewrite` / `apply_create_rewrite`: `bookmarkID`, `jsonPath` (e.g.
  `$.data.id`), `overrideValue` (`{"type":"number","value":"2"}`-shaped) — patches one field of a
  bookmark's saved JSON response.
- **Live Response Rewrite** — call `preview_live_rewrite` first against exact captured session IDs,
  then pass its `previewDigest` to `propose_create_live_rewrite`; the proposal fails if capture,
  policy, logical session, sampled sessions, or rule arguments drift. Apply creates a disabled rule
  that forwards matching traffic to the real upstream and patches JSON in the live response. Also
  supports `graphqlOperationName` — pass the same value to both `preview_live_rewrite` and
  `propose_create_live_rewrite` (it's bound into the preview digest, so a mismatch between the two
  calls fails as a stale proposal, same as changing any other matcher field between preview and
  create). CLI: `joesproxyctl rewrite preview|prepare` (`--graphql-operation-name <name>`).
- **Collection Mock** — call `preview_collection_mock` first against one exact captured session ID
  with a `draftJSON` (`collectionPointer`, `item`, `identityPointers`, `countPointers`, `position`),
  then pass its `revisionID` to `propose_create_collection_mock`; the proposal fails if the
  revision no longer exists (evicted, wrong owner, or never previewed). Apply creates a disabled
  rule that forwards matching traffic to the real upstream and applies the reviewed collection-shape
  mutation (insert/replace items) to the live JSON response. Unlike live response rewrite, propose
  never re-accepts the draft — only the `revisionID` reference — so there is no digest-recomputation
  staleness class to worry about. CLI: `joesproxyctl collection-mock preview|prepare`.
- **Bookmark** — `propose_create_bookmark` / `apply_create_bookmark`: `method`, `host`, `path`,
  `name` — creates a reusable saved request. CLI: `joesproxyctl bookmark create|apply` (see also
  `bookmark list`/`bookmark get` above).

### Enable/disable & throttle mutations
- `propose_enable_rule` / `apply_enable_rule` — toggle a Block/Map Local rule live (interactive
  approval or standing `enableRule` grant). **Not** valid for Map Remote, live response rewrite, or
  collection mock (see Open-world below). Prefer `apply_create_map_local` with `enableAfterApply`
  when create and enable are one intent.
- `propose_disable_rule` / `apply_disable_rule` — disable a Block/Map Local rule. Propose is
  unchanged; **apply does not require interactive approval** (still policy-gated and fully audited).
- `propose_enable_rewrite` / `apply_enable_rewrite` — enable one bookmark JSON rewrite (approval-gated).
- `propose_disable_rewrite` / `apply_disable_rewrite` — disable one bookmark JSON rewrite (no
  interactive approval on apply; policy + audit remain).
- `propose_change_throttle` / `apply_change_throttle` — `isEnabled` + `selectedPresetID` (or custom
  bandwidth/latency); affects all traffic while enabled. CLI: `joesproxyctl throttle
  prepare|apply|disable`.

### Open-world tools (real network actions, extra disclosure, mutating-tier approval)
- `execute_bookmark` — replays a saved bookmark through the real proxy; `includeCredentials`
  defaults to stripped.
- `replay_request` — replays one previously-captured session's request through the real proxy.
- `recapture_session_body` — when a session's response reports `bodyAvailable: false` (truncated
  past the 1MB live-capture cap, or evicted later by the retention policy), fetches that request
  **directly from the real origin** (deliberately bypassing the proxy, so the same 1MB cap doesn't
  re-apply) and backfills the session's stored body in place — up to a 20MB ceiling
  (`SessionBodyRecaptureBudget.maxBodyBytes`), truncated at that ceiling rather than unbounded.
  Same risk tier and `includeCredentials` default (stripped) as `replay_request` — it re-hits a
  live endpoint right now, with no guarantee the response matches what was originally captured.
  Only the body is replaced; the session's original status code and headers are left untouched.
- `activate_map_remote` — the **only** way to enable a Map Remote rule (discloses the real
  destination as part of approval); `propose_enable_rule`/`apply_enable_rule` reject it.
- `activate_live_rewrite` — the **only** way to enable a live response rewrite rule (discloses the
  real upstream and JSON patch summary); `propose_enable_rule`/`apply_enable_rule` reject it.
- `activate_collection_mock` — the **only** way to enable a collection mock rule (discloses the
  real upstream and a rendering of the compiled plan); `propose_enable_rule`/`apply_enable_rule`
  reject it.
- `live_media_probe_start` — see Media discovery above.

### Scenario testing system (compose multiple faults into one supervised test)
For testing more than one fault together, or needing a bounded observation window with
assertions, rather than hand-driving individual propose/apply calls:
`draft_test_scenario` → `validate_test_scenario` (or `preview_test_scenario` to validate without
persisting) → `request_test_scenario_approval` → `arm_test_scenario` → `activate_test_scenario` →
(drive real traffic) → `get_test_observations` → `evaluate_test_assertions` → `stop_test_scenario`
(evaluates if needed, stops, cleans up) or `cleanup_test_scenario` (force cleanup, no extra
approval). `get_test_report` fetches the final privacy-filtered report. A scenario composes the
*same* fault shapes as the standalone mutation tools above (block/mapLocal/mapRemote/
bookmarkRewrite/jsonRewrite/throttle/bookmark-replay) — it cannot expand scope beyond what the
standalone tool would already allow. **`jsonRewrite` (live response rewrite) is not yet supported
in scenario composition** — `validate_test_scenario` rejects it immediately with a clear
"unsupported" error, because rule composition has no staged pipeline yet (the proxy applies only
the first matching enabled rule, so a scenario cannot safely promise both a rewrite and another
fault on the same target). Use standalone `activate_live_rewrite` outside of scenarios for live
response rewriting; **`bookmarkRewrite`** (patches a saved bookmark snapshot, not live traffic) is
unaffected and works normally inside scenarios. Scenario approval covers open-world disclosure for
`mapRemote`/`replay`; standalone `activate_live_rewrite` is not required when the fault is composed
inside an approved scenario.

### Certificate identity
Read-only tools work on Metadata Only / Shareable (inspect-tool gate). Cleanup is Shareable +
propose/approve/apply (destructive):
- `certificate_status` / `certificate_identity` / `certificate_artifacts_list` /
  `certificate_compare` — fingerprint, short code, trust install state, distribution artifacts,
  and compare two fingerprints (`fingerprint` + `otherFingerprint`).
- `certificate_export` — read-only, no arguments: exports the plain public root CA certificate
  (DER, base64-encoded in `certificateDataBase64`) — never the private key. For trust stores outside
  the platform profile flows (iOS/tvOS mobileconfig, Simulator `simctl`), e.g. a
  container's trust store. CLI: `joesproxyctl certificate export --output <path>` writes the
  decoded bytes directly to a file.
- `propose_certificate_cleanup` / `apply_certificate_cleanup` — fingerprint-targeted cleanup;
  apply takes only `proposalToken` (never a bare fingerprint). Prefer Shareable; require
  `allowCurrentRoot` to target the active root.
CLI: `joesproxyctl certificate status|identity|export|artifacts list|compare|cleanup prepare|apply`.

