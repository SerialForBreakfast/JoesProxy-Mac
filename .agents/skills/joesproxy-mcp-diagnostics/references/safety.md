## Symptom → tool sequence

Start with the symptom in the table. Inspect request metadata first. If it answers the
question, stop there. Ask for more sensitive evidence or propose a traffic change only
when you can explain what the next step would distinguish.

| Symptom | Sequence |
|---|---|
| Target request "missing" amid noise | `capture_marker_create` first, then `sessions_search` after the marker — filter out common ambient families (operating-system services, MDM, ad SDKs, first-party telemetry) before concluding the target never fired |
| TLS/handshake failure | `sessions_search` (filter by host) → `session_summary` on the failing session → check `statusCode`/`hostCategory` before assuming a code-level bug |
| 401/403 loop | `session_summary` (with `includeHeaders` if approved) on one failing request → confirm it's actually reaching the target, not being blocked by an existing rule → `overrides_list` / `rule list` (then `override_get` / `rule get`) for stale block/map rules |
| Redirect loop or unexpected destination | `overrides_list`/`bookmarks_list` (CLI `rule list` / `bookmark list`) first — an enabled Map Remote or bookmark rewrite is a common, easily-missed cause before assuming app code is wrong |
| Slow/hanging request | Check `propose_change_throttle`'s current state before touching app code — an active throttle (yours or someone else's) explains this instantly |
| Unexpected response body | `overrides_list` / `rule list` → `override_get` / `rule get` on suspects → `session_summary` attribution (`mcpEffectKinds`) — a Map Local or bookmark rewrite may be serving a substitute response, not the real backend. Prefer Map Local (inline, file, **local directory**, or fixture-backed) for a local substitute; do not spin up an external static server |
| Need a whole static site/folder under a real path prefix | Local directory Map Local (`--directory` / `localDirectoryBookmarkRef`, `pathPrefix`) — not an external `http.server` |
| Client still shows old asset after Map Local | Confirm a **new** proxied request appears after the last marker. If none: report no observation; investigate routing, identity, scope and client behavior without declaring caching proven. If a request hits but body is still old: check matcher (`pathSuffix` literal) and `hitCount` via `rule get` |
| Reproducing a specific failure to test a fix | `propose_create_block`/`propose_create_rewrite`/etc. → approve → apply → drive **real** traffic through the proxy and check the actual response, not just the tool's own success message |
| Testing multiple faults together / need an observation window | Use the scenario testing system above instead of hand-chaining several standalone mutations |
| Media startup/playback failure | `media_readiness` → follow its `recommendedNextTools` |
| Need to substitute a live/looping local stream for a real one | Prefer the first-class HLS test-stream substitution workflow; use fixture-backed Map Local only for specialized path-prefix experiments — never Map Remote, which rejects loopback destinations |

## Mutation safety checklist

These are confirmed, previously-live gotchas — not hypothetical:

- **`scheme` silently defaults to `https`** if you omit it when proposing a block/map/rewrite rule.
  If your target is plain HTTP, say `"scheme": "http"` explicitly or the rule will never match.
- **`port` must match the real target port.** A matcher with no `port` matches the *canonical*
  port for its scheme (80 for http, 443 for https) — not "any port." If the target runs on a
  non-default port, set `port` explicitly or the rule silently never fires.
- **Read the disclosure before approving.** Every `propose_*` result includes `matchScope`/
  `effectSummary`/`riskTier` — confirm it names the target you actually intended before approving
  the apply. Approval is a real, single-use decision, not a formality.
- **Map Remote requires `activate_map_remote`, not `enable_rule`.** It's an open-world tool because
  it discloses a real destination; the generic enable/disable tools reject it.
- **Live response rewrite requires `activate_live_rewrite`, not `enable_rule`.** It's open-world
  because matching traffic reaches the real upstream and the response JSON may be patched.
- **Map Remote to local Mac servers is opt-in and port-scoped; HLS fixtures belong in Map Local.**
  Loopback destinations (`127.0.0.0/8`, `::1`, `localhost` — always meaning the Mac running
  JoesProxy, never the client device) are blocked by default unless **Settings → Proxy →
  Local-Server Routing** is enabled, the exact destination port is authorized (JoesProxy's own
  listener ports remain reserved), and the rule passes `allowLoopbackDestination: true`. To
  substitute JoesProxy-managed HLS fixture content for a real external host, still use
  fixture-backed Map Local (`fixtureRunID` on `propose_create_map_local`), not Map Remote.
- **A fixture-backed Map Local rule fails open, silently, if its fixture run stops.** Confirm the
  fixture run is still active (`hls_fixture_status`) before concluding a redirect "isn't working" —
  a 404/real-upstream response after a redirect was previously confirmed working usually means the
  fixture run expired or was stopped, not that the rule broke.
- **An approved `apply_hls_fixture_start`/`apply_*` retry can still hit a fresh `approval_required`.**
  Confirmed live: approving one `requestID` in-app does not guarantee the next identical `apply_*`
  retry reuses it — a second, different request can be minted if enough time passes between
  approval and retry. If a retry unexpectedly asks for approval again, treat it as a new request,
  not a bug, and have the operator approve the new one.
- **`pathSuffix` is literal.** Confirm the stored `path` with `override_get` / `rule get` before
  concluding a Path Suffix rule "should have matched" a differently foldered URL — only the suffix
  string you set matters.
- **`forceNoCache` is not an app-cache flusher.** If the client never re-requests, stripping response
  cache headers changes nothing; say so instead of retrying Map Local with stronger header claims.
  Discuss separately authorized target-side checks; never infer permission to force-quit,
  clear application data, or reinstall from permission to modify proxy traffic.
- **Rules do not survive a JoesProxy relaunch; `durablePolicy` grants do.**
  `ResponseOverrideRule`s are in-memory only. Approval grants set to `durablePolicy` persist to disk
  and reload at startup. After quit/relaunch, run `rule list` before assuming a prior Map Local
  still exists — but don't assume a standing `durablePolicy` approval was lost without checking
  `doctor` first.
- **Always clean up within ownership.** Stop the owning bundle/run or explicitly disable the rule, or (for MCP-owned rules
  you no longer need) `propose_delete_rule` / `rule delete` when you're done testing, and confirm
  with one real traffic request that the effect is actually gone — don't just trust the tool's own
  response.

