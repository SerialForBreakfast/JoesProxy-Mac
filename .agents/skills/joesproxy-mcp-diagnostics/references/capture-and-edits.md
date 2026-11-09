## Feature catalog

*Reference material — look up a specific tool's arguments here. If you haven't yet, read
"Start here: task router and the real-device mutation loop" above first; it's the sequence that
actually resolves most real-device jobs, not this catalog.*

### Session & capture inspection (read-only)
- Playback investigation sequence: first verify the running build's capabilities, then read
  `capture_status`, the affected session summary and its `transportDiagnostic`. Keep
  `body_capture_disabled_for_request` and `transport_evidence_unavailable` separate from
  `upstream_response_incomplete` and `downstream_write_failed`. Missing bodies do not prove
  interrupted forwarding. `downstream_delivery_pending` is unfinished evidence, not success.
  Record a bounded observation window and the user's visible playback outcome separately.
  Only propose a host-rule comparison when its all-client/subdomain scope is acceptable;
  preserve a recovery ID, obtain local approval, observe NEW connections, then separately
  approve restore and verify the receipt. Never clear a target cache or force reconnection
  merely to make an experiment match. If no safe comparison is available, report the gap.
  HTTP/3 is not implemented; an opaque TCP tunnel cannot restore native QUIC behavior.
  Local scripted validation of framing, connection reuse, delayed siblings and queue drain
  does not establish remote throughput, player rendering, or a fix for a specific device stall.
- Playback transport triage: `session_summary` (CLI `session show <sessionID>`) includes
  bounded `transportEvidence` when recorded and permitted by the duration disclosure field.
  TLS readiness, upstream read gaps, pending/failed downstream writes and relay-outstanding
  time are different observations. Read gaps include local backpressure; socket write success
  is not player delivery. Missing evidence in old/tunneled/failed captures is unknown, not zero.
  `transportEvidenceSource` identifies recorded evidence or the bounded recent-request lookup
  (256 requests, including pending delivery); unavailable/evicted is never interpreted as zero.
  `transportDiagnostic` adds a stable reason, impact, read-only next actions and verification.
  Incomplete upstream framing, failed downstream writes, pending delivery and missing capture
  evidence are distinct. Inspect before proposing recovery; never replay a request, reinstall
  a device profile, increase limits or bypass inspection automatically. A successful prefix write
  does not make an incomplete response successful. Local approval remains required for HTTPS
  rule changes; preserve previous settings and inspect state after an uncertain mutation reply.
- For reversible HTTPS recovery, choose a UUID before the change and pass it as
  `recoveryID` to `https_rules_set` (CLI `--recovery-id`). Keep that ID; host inspection
  without an ID lists only your retained receipts for that host. Inspect using
  `https_rules_get` with host and recoveryID after any uncertain reply; repeating the ID
  returns evidence and never reapplies. `https_rules_restore` (CLI `https rules restore`)
  requires host, recoveryID, current expectedRevision, scope=host_and_subdomains_all_clients
  and a separate exact local approval. Conflicting settings block restore; never substitute
  a newer revision automatically or overwrite another edit. Receipts are owner-bound,
  survive restart, and are bounded to 32 (completed receipts may retire). Corrupt/full or
  unwritable storage fails closed. These persistent settings have no TTL or automatic
  cleanup; bundle Stop does not restore them. A restored receipt proves a settings operation,
  not playback or replacement of existing connections. No automatic request replay, certificate
  changes, global bypass or QUIC claim. Legacy set without a receipt remains supported.
  For capture recovery, inspect `capture_status`, use the existing approved `capture_resume`
  only when indicated, then inspect again; never raise budgets or reinstall trust to recover
  an admission gap. Keep before/run observation windows explicit and report missing evidence.
- `https_rules_get` (CLI `https rules get --host media.example.test`) returns the effective
  domain rule and revision. `https_rules_set` / CLI `https rules set` requires host, mode
  (`tunnel`, `inspect`, `remove`), expectedRevision (`--expected-revision`) and explicit scope
  `host_and_subdomains_all_clients` (`--scope`). Every actual change needs exact one-use local
  approval; agents never approve. The setting persists, covers subdomains and ALL clients,
  affects NEW connections only, and is not undone by bundle Stop/expiry. Preserve the prior
  setting; removing a custom rule is not necessarily equivalent to forcing inspection.
  Broader/built-in bypasses cannot be overridden by an inspect rule. Global HTTPS mode may
  override the domain decision. Tunneling is opaque TCP/TLS, not QUIC or HTTP/3 passthrough;
  bodies and HTTP modifications are unavailable. After an uncertain reply inspect before
  retrying, and never substitute a fresh revision without renewed review. Do not reinstall a
  device profile or change routing merely to obtain missing bodies.
- Missing bodies: read `bodyUnavailableReason` and `bodyRecoveryAction` before requesting body
  approval. These content-free fields also accompany minimal/summary session projections.
  `capture_status` (CLI `capture status`) reports current bounded capture/admission state;
  `capture_digest` and capture health include it too. A stored original byte count is not proof
  that bytes remain available. Deferred load, omitted recording, TLS pass-through, pending
  response and missing bytes require different recovery; never automatically refetch.
  Missing bodies alone never justify reinstalling a device proxy/certificate profile. Even a
  TLS tunnel may reflect deliberate bypass policy, not broken trust. Use target-specific
  `setup_readiness` and actual TLS evidence before recommending any setup repair; preserve
  a working device configuration. An unavailable observation is not a failed trust check.
  For a stopped proxy, `capture_resume` (CLI `capture resume --wait-for-approval`) requests
  runtime control through existing local approval/grants. Read its returned capture status.
  Resume does not restore historical bodies, force pressure-paused admission, raise limits,
  change TLS/routing, or grant bodyRead. Pressure recovery is automatic after drain; zero
  retention requires local settings review. Generate new traffic only with task authorization.
- `sessions_list` / `sessions_search` — paginated/filterable capture sessions (search by `domain`,
  `path`, `method`, `hostCategory`, `sessionIDPrefix`, `startedAfter`, `startedBefore`).
- `session_summary` — full detail for one session ID; `bodySource` defaults to `response` and may be
  set to `request`. `headerSource` defaults to `both` and exposes `safeResponseHeaders` /
  `approvedResponseHeaders` for response-side evidence. `bodyAvailable` /
  `bodyExcerptAvailable` mean MCP can return a non-empty excerpt after approval — not merely that
  bytes exist in the store. `bodyRead` covers request or response body per `bodySource`;
  `headerRead` covers request and/or response headers per `headerSource`.
  `includeHeaders`/`includeQuery`/`includeBody` require in-app approval (or a standing grant).
- `investigation_snapshot` — bounded newest-session sample, aggregate sample counts, and immutable
  minimal evidence references for efficient investigation startup or resume.
- `evidence_get` — resolve one unexpired evidence reference for the same client, capture epoch, and
  policy revision without expanding the retained disclosure.
- `read_batch` — execute up to eight allowlisted read-only tools; mutations and approval-gated
  session fields are rejected.
- `capture_digest` — see Efficiency conventions above. Also reports `lastEpochChangeReason`,
  `rollingCaptureAvailable`, and related rolling-save metadata.
- `capture_marker_create` — insert a named timeline marker (`MARKER` session) without upstream
  traffic; filter later with `hostCategory=capture_marker` or `method=MARKER`.
- `capture_activity_since_marker` (CLI: `capture activity --since-marker <session-id> [--rule
  <override-id>]`) — the ceremony-free evidence check named in "Start here" above: pass a marker's
  `sessionID` to get the count and compact summaries (method/status/sequence only, never host/path)
  of every request observed after it; add `overrideID` to also learn whether that specific rule's
  `lastMatchedAt` falls after the marker. No create/start/observe/close lifecycle — one call.
- `capture_restore_rolling` — restore the latest Application Support rolling `.jproxy` snapshot.
- `sessions_export` — bulk export as `json` / `ndjson` / `har`. Args: `format`, optional filters
  (`method`/`hostCategory`/`domain`/`path`/`startedAfter`/`startedBefore`), `includeHeaders` /
  `includeBody` (approval-gated like `session_summary`), `maxSessions`, `deliverFile`.
  **Inline** (`deliverFile` false): default/hard cap 500 sessions; if the encoded MCP response
  would exceed 1 MB, JoesProxy auto-spills to Application Support `MCPExports/` and returns
  `outputPath` + `contentByteCount` with `content` nil. **File delivery** (`deliverFile` true):
  walks the full matching capture unless `maxSessions` is set; always returns `outputPath`
  (posix `0600`). Prefer CLI `sessions export --format har --output <path>` for GUI Export All
  parity. Full tool name list: resource `joesproxy://agent/guide` (All tools section).
- CLI: `joesproxyctl sessions list|search`, `session show <session-id>` (equivalent to
  `session_summary`), `capture digest|marker|restore-rolling|rolling-status`.

