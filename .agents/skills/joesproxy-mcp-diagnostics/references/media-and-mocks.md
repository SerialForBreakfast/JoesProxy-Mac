### HLS fixtures
Reserved-origin synthetic HLS for recovery experiments (bundled profiles):
- `hls_fixture_capabilities` / `hls_fixture_profiles_list` / `hls_fixture_status` /
  `hls_fixture_window_preview` — inspect the exact VOD or live publication, optionally at
  `--at` / `elapsedSeconds`. Live time shifting uses `off`, `warmDVR`, or `coldDVR`; it is
  distinct from Low-Latency HLS (LL-HLS). Preview evidence includes advertised/published
  sequence bounds, program/live-edge times, duration, and recently evicted retention.
- `propose_hls_fixture_start` / `apply_hls_fixture_start` / `hls_fixture_stop` — lifecycle
  (approval on start).
CLI: `joesproxyctl hls fixture capabilities|profiles|status|window-preview|prepare-start|apply-start|stop`.

By default a fixture run is only reachable at its own reserved synthetic host
(`<uuid>.hls.joesproxy.invalid`) — a real app requesting a real external host never reaches it, and
Map Remote cannot legally repoint traffic there either (loopback destinations are rejected
unconditionally, see the safety checklist below). Use the streaming source redirect workflow next
when the goal is to substitute fixture content for a *real* external host+path.

### Local directory Map Local

Use this when the operator needs an entire static folder (HTML/CSS/JS/images) served under a real
host path prefix — the folder-picker / CLI equivalent of "point Map Local at a directory."

1. Prefer CLI on the same Mac as the app: `joesproxyctl response map-local prepare --directory
   <absolute-or-relative-folder> --method GET --host <host> --path <prefix> [--not-found
   <relative>] [--force-no-cache]`. The CLI mints a security-scoped bookmark and passes opaque
   `localDirectoryBookmarkRef` (base64) to MCP — **never** send a raw filesystem path over MCP.
2. Or call `propose_create_map_local` with `localDirectoryBookmarkRef` directly (same mutual
   exclusion as `fixtureRunID`: no `bodyText` / preview digests / `responseRevisionID` /
   `fixtureRunID`). **Requires `matchMode: "pathPrefix"`.** Optional `notFoundRelativePath` serves
   that relative file as HTTP 404 when a requested path is missing.
3. `apply_create_map_local` (optionally `enableAfterApply: true`). Subtree URLs strip the matcher
   prefix and resolve under the folder (`/site/a.css` → `a.css`); empty / trailing `/` serves
   `index.html` when present. Path traversal (`..`) is rejected.
4. Inspect via `override_get` / `rule get`: `sourceKind` is `localDirectory` and
   `localDirectoryName` is the folder's last path component only — full paths are never disclosed.
5. **Fail-open:** if the bookmark cannot be resolved or the folder is gone, traffic falls through to
   the real upstream (same safety posture as an inactive fixture run).
6. Disable/delete with ordinary rule workflows when done.

**Single file / binary (image, font, wasm):** MCP `bodyText` is text-only. Use
`propose_create_map_local` with `localFileBookmarkRef`, minted by CLI
`response map-local prepare --file <path> --method GET --host <host> --path <request-path>`.
Use discovery to confirm support in the running build. The default matcher is `exactPath`;
inspect the proposed status, content type, scope, and conflicts before approval. A one-file
directory is only a compatibility fallback for older builds. Require a fresh attributed request
and verify delivered bytes; no observed request does not establish a client-cache diagnosis.

### OpenAPI mock pack

For a bounded local OpenAPI 3.0 JSON contract, prefer one owned mock pack over a bag of Map Local
rows. CLI mints an opaque bookmark from `--file`; MCP never receives a filesystem path.

1. Preview with `openapi_pack_preview` (CLI: `joesproxyctl openapi pack import --file <path>`).
   Review supported operations, unsupported features, and conflict counts. Schema-valid fixtures do
   not reproduce real authorization or business behavior.
2. Propose with `propose_openapi_pack_start` (CLI: `openapi pack prepare --file <path> --host
   <host>`). One approval covers the whole pack. Use `conflictStrategy: replaceConflicts` only when
   overlapping Map Local/Block/Map Remote rows should be disabled.
3. Apply once with `apply_openapi_pack_start` (CLI: `openapi pack apply <token> --wait-for-approval`).
   The result is one pack ID.
4. Inspect bounded hit/miss metrics with `openapi_pack_status`. Do not request bodies or query URLs.
   Unmatched traffic fails open. Named error variants use header `X-JoesProxy-OpenAPI-Variant`.
5. Stop with `openapi_pack_stop` (CLI: `openapi pack stop <pack-id>`). Stop is owner-scoped and
   non-interactive; it also invalidates leftover activation approvals for that pack. Relaunch
   restores definitions as stopped — never auto-serving.

Keep low-level Map Local APIs for one-off rules. Do not restage OpenAPI operations as independent
exactPath rows.

### First-class HLS test-stream substitution

Caption-switch recipe (2026-09-21): discover `multilingual-text-vod-v1` and inspect
`textRenditions` rather than assuming a language inventory. Omitted configuration starts VOD;
request explicit conformant `liveLoop` with warmDVR/coldDVR for live-boundary tests. JIT text,
incompatible segment grids and embedded CEA captions are not supported by this profile. Read
`glossary-hls-fixture` for the shared-clock and cue contract. Ask the authorized player operator
to switch Off → English → Spanish → French → Off, then test SDH/forced and RTL/CJK separately.
For live, repeat near a segment/loop boundary and after seeking. Record visible cue/language/time
with an external evidence source; text delivery or absence of a new request proves neither
selection nor a cache hit. To isolate a text fault, propose an exact observed text-resource matcher
scoped to the device, review sibling media consequences and obtain normal approval. Never block
the entire fixture host merely to fail one text track. Stop the owned fault and fixture/bundle and
verify cleanup. Player control remains separately authorized.

For player QA against a real captured `.m3u8`, prefer the composite substitution workflow over
manually coordinating a fixture run and Map Local rule:

1. List profiles with `hls_substitution_profiles_list` (CLI:
   `joesproxyctl hls substitute profiles`). `player-qa-widescreen-v1` is the recommended 16:9
   H.264/AAC profile with a test pattern, running time reference, and four distinct audio choices:
   English program, English audio description, Spanish, and German. Read `audioRenditions` from
   profile discovery instead of assuming a fixed inventory; the audible signatures identify
   selections but are synthetic QA tones, not spoken-language samples.
   Discovery also returns `playbackConfiguration` capabilities and profile-level
   `controlledFaults`. Use a different bundled profile when the experiment changes media bytes
   (codec/container, channel layout, or physical segment boundaries). Use runtime playback
   configuration only for playlist/server behavior.
2. Propose with `propose_hls_substitution_start`, using either `sessionID` or an explicit
   `scheme`/`host`/`port` and `path`. Set `scope` to `selectedPlaylist` (default choice) or `host`,
   and always provide the explicit `conflictStrategy` `cancel` or `replaceExisting`. CLI:
   `joesproxyctl hls substitute prepare --session-id <id> --profile-id
   player-qa-widescreen-v1 --scope selected`.
   The default playback configuration is conformant. For a controlled recommendation violation,
   add `playbackConfiguration` with `intent: "deliberateFault"` and change one dimension at a time:
   `windowSegmentCount`, `loopBoundaryTreatment`, `segmentURIIdentity`,
   `targetDurationTreatment`, `programDateTimeTreatment`, or `playlistCachePolicy`. The CLI exposes
   matching `--intent`, `--window-segments`, `--loop-boundary`, `--segment-uri-identity`,
   `--target-duration`, `--program-date-time`, `--playlist-cache`, and `--playlist-max-age`
   options. A configuration containing a known violation is rejected unless deliberate-fault
   intent is explicit. Optional `ttlSeconds` (CLI `--ttl <seconds>`) sets how long the substitution
   stays active before failing open automatically — defaults to 1800 (30 minutes) when omitted,
   same as before this field existed; max 86400. Use a longer value up front for a long debugging
   session instead of re-preparing/re-approving every 30 minutes, or extend an already-running one
   later (see step 6).
3. Review the disclosed exact origin/path, conflicts, expiry (`maxRunDurationSeconds`) and
   fail-open behavior, playback configuration, and enumerated recommendation violations. Then apply
   once with `apply_hls_substitution_start` (CLI: `hls substitute apply <token>`).
   The result is one experiment ID; fixture start, same-origin route mount, and enablement are one
   transaction and use one approval.
4. Inspect only bounded evidence with `hls_substitution_status` (CLI: `hls substitute status`):
   entry-playlist, child-playlist, and segment hit counts plus last hit, plus a `stallClass`
   interpretation (`matcherMiss` — zero hits, check the matcher, not the player; `workingNormally`;
   or `likelyClientRejectOrStall` — hits are flowing but the player keeps re-polling the playlist
   without downloading segments, a player-side rejection or buffer stall, not a matcher problem —
   stop re-tuning the rule and pivot to player-side logs). `stallClassBasis: "sinceStart"` means
   this is computed over the experiment's whole lifetime, not a recent window. Do not request or
   expose manifest bodies, signed URLs, or query values.
   If selected-playlist scope remains at zero entry hits while a newly captured HLS master appears
   on the same exact origin, the opaque path may rotate between playback starts. Do not silently
   widen scope: explain the evidence, obtain explicit operator confirmation, then create a new
   `host`-scope proposal with `replaceExisting`. Exact-host scope affects every GET/HEAD `.m3u8`
   on that origin, so this is a meaningful escalation.
5. Verify multilingual behavior with both bounded hit evidence and direct client observation. Mark
   each selection and record the friendly rendition, request time, audible change time, stall time,
   and recovery time. Aggregate substitution metrics prove delivery but do not identify which
   audio rendition was selected; correlate with app-owned player logs when switch latency matters.
6. Still actively debugging as expiry approaches? Call `hls_substitution_extend` (CLI: `hls
   substitute extend <experiment-id> --ttl <seconds>`) instead of re-preparing/re-approving from
   scratch — it pushes the same running experiment's expiry out further (measured from now, not
   additive on top of remaining time; defaults to 1800s when `ttlSeconds` is omitted). Like Stop,
   Extend is owner-scoped and non-interactive: it only changes *how long* an already-approved
   substitution runs, not *what* it serves, so it doesn't need a fresh proposal/approval. It does
   not weaken fail-open: relaunch still purges every persisted-active experiment unconditionally
   regardless of how far out its expiry reaches.
7. Stop with `hls_substitution_stop` (CLI: `hls substitute stop <experiment-id>`). Stop is
   owner-scoped and non-interactive because it reduces risk. The route is disabled before the
   fixture run is stopped; expiry and relaunch also fail open to the real upstream. An already-
   playing client may retain synthetic child URLs and need a playback reload before it requests the
   real entry playlist again, so verify restoration rather than assuming Stop healed the session.

For comparative diagnosis, first establish a conformant positive control, then run one deliberate
fault per experiment against the same scope and profile. Record time to first frame, stall/recovery
time, rendition changes, client error, and bounded hit counts. Stop and restore the positive control
between cases; do not combine faults until each isolated result is understood.

Use the lower-level fixture-backed Map Local workflow below only for compatibility or specialized
path-prefix experiments that the bounded selected-playlist/exact-host workflow cannot express.

### Streaming source redirect (fixture-backed Map Local)

Use this bounded workflow to make a real app's requests to a real external HLS host+path prefix
serve content from a running local fixture run instead — e.g. substituting a live, looping local
stream for a real one to test client recovery behavior, without the app ever knowing the traffic
was redirected. Verify sliding-window progression, Range responses, scope isolation and fail-open on expiry
against the chosen target; historical validation does not establish this run's outcome.

1. Start a bundled fixture run first (`hls fixture prepare-start --profile-id <id>` /
   `apply-start`, above) and keep its `runID`.
2. `propose_create_map_local` with `fixtureRunID: <runID>` instead of `bodyText`/`contentType` —
   mutually exclusive with `bodyText`, `responseEditPreviewDigest`/`hlsPreviewDigest`, and
   `responseRevisionID`. **Requires `matchMode: "pathPrefix"`** — a fixture run serves a whole
   directory tree (master + child playlists + segments), not one URL; `exactPath`/`pathSuffix` are
   rejected. CLI: `response map-local prepare --fixture-run-id <uuid> --method <verb> --host <host>
   --path <prefix> [--scheme http|https] [--match-mode pathPrefix] [--port <n>]`.
3. Read the disclosed `effectSummary` before approving — it names the exact fixture profile ID and
   reserved host of record, so you know precisely which local content will be substituted.
4. `apply_create_map_local` (optionally `enableAfterApply: true` for create+enable in one
   approval, same convention as any other Map Local rule). The request path actually sent to the
   fixture is the real request path with the matcher's `path` prefix stripped — e.g. a matcher on
   `/videos/bipbop` serving a request for `/videos/bipbop/master.m3u8` asks the fixture for
   `master.m3u8`.
5. Drive real client traffic and confirm: content matches the fixture (not the real upstream),
   a child playlist's media sequence advances across two requests a few seconds apart (proves live
   computation, not a frozen body), and a `Range` request against a segment returns `206`/
   `Content-Range` correctly.
6. **Fail-open is intentional, not a bug.** If the referenced fixture run has since stopped or hit
   its bounded max duration, the rule behaves exactly like a non-match and traffic falls through to
   the genuine real upstream — it does not serve an error or silently blackhole the request. If you
   stop a fixture run without disabling its Map Local rule, expect requests to that path prefix to
   start reaching the real upstream again automatically; that is the designed safety behavior, not
   something to work around.
7. Disable the rule with the ordinary rule-disable workflow, stop the fixture run, and confirm with
   one real request that traffic has reverted to the genuine upstream — same cleanup discipline as
   every other create-mutation.

### Structural discovery
- `discover_response_structure` — policy-gated structural profile (property names/types/
  cardinality, never values) of one or more captured JSON response bodies. Use before inventing
  JSONPath rewrites when the shape is unknown.

### Runtime control
- `runtime_status` — compact readiness (proxy/MCP/grants/cleanup) for CLI/agent startup checks.
- `proxy_start` / `proxy_stop` / `mcp_stop` — exact in-app approval; `mcp_stop` responds before
  shutdown. CLI: `joesproxyctl doctor`, `app launch`, `mcp start|stop`, `proxy start|stop`
  (MCP start also needs the "Allow JoesProxy CLI to start MCP" toggle).

### CLI observation helpers
These are CLI-first (same MCP backend where applicable):
- `joesproxyctl watch capture|sessions` — stream capture/session notifications.
- `joesproxyctl wait capture|session|operation` — block until a condition or timeout.
- `joesproxyctl capture rolling-status` — rolling auto-save availability.
- `joesproxyctl session end` — end the logical MCP session cleanly.

### Recovery & cleanup
- `client_cleanup_status` — whether this client is `clean` or `cleanup_required` before ending.
- `approvals_list` — every currently-pending approval request for this client (`capability`,
  `reason`, `expiresAt`), not just the single `requestID` whichever call triggered it returned.
  CLI: `joesproxyctl approvals list`. Read-only; does not create or resolve any approval itself.
- `return_to_normal` — stops the MCP server, clears grants/approvals, and restores or disables
  every MCP-created effect. This is server-wide recovery, not default per-task cleanup.
  Prefer owner-scoped stop/disable and `client_cleanup_status`; use server-wide recovery only
  with explicit authorization for its impact on other clients.

### Resources
- `joesproxy://server/status`, `joesproxy://capture/summary`, `joesproxy://capture/health` —
  server/capture state.
- `joesproxy://agent/capabilities` — the machine-readable manifest (this catalog, structured).
- `joesproxy://agent/guide` — the generated human/agent guide (setup + grouped catalog +
  **All tools** list + CLI companion). Prefer it when you need every tool name/description.
- `joesproxy://setup/guide` — the portable, MCP-endpoint-optional onboarding guide (same content
  family as `agent/guide`, usable before a client has even connected).
- `joesproxy://audit/recent` — recent client audit events.

