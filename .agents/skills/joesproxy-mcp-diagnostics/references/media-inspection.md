### Media discovery & inspection
- `media_readiness` — start here for any media session: deterministic capability check plus
  `recommendedWorkflowID`/`recommendedNextTools`.
- `media_context` — UI-equivalent context labels before opening a manifest.
- `media_summary` / `media_manifest_structure` / `media_related_sessions` — capture-only
  classification, sanitized HLS/DASH structure, and related-session relationships.
- `media_inspection_start` — start an approved, capture-only deeper analysis; poll with
  `operation_status` (compact by default; request `includeResult` only once `resultAvailable` is
  true), cancel with `operation_cancel`.
- `live_media_probe_start` (open-world) — a live AVFoundation probe of a real media URL, not just
  captured data; requires approval and real network access.
- CLI: `joesproxyctl media readiness|summary|manifest|related|inspect`, `operation status|cancel`.

### HLS CODECS Map Local experiment

Use this bounded workflow when testing whether accurate `CODECS` attributes change playback
behavior. The tooling edits only a captured HLS master; child playlists and segments continue to
come from their original upstream URLs and may expire independently.

**Hard limits:** tooling stops at “validated edit delivered and served.” Never claim a playback
hypothesis is confirmed from delivery evidence alone. Never relaunch or kill the user’s app unless
separately authorized for that run.

#### CLI command sequence

1. Create a capture marker, capture a complete master, and run
   `joesproxyctl hls codecs context <session-id>`.
2. Select only the returned opaque `variantRef` values and derive codec values from trusted media
   evidence. Never copy a manifest body into an agent prompt or edits file.
3. Run `joesproxyctl hls codecs preview <session-id> --edits <json-file>`. The JSON file may contain
   only `[{"variantRef":"...","codecs":"..."}]`; the server validates UTF-8, master structure,
   stale locators, and non-CODECS invariants. The response contains a digest, compact diff,
   source freshness, lexical signed-URL indicators, and historical matcher cardinality, but never
   the original or patched body.
4. Run `joesproxyctl hls codecs prepare-map-local --preview-digest <digest>`, review the proposal,
   approve the apply in JoesProxy, then
   `joesproxyctl hls codecs apply-map-local <proposal-token> [--wait-for-approval]`. The created
   rule starts disabled.
5. Review the exact matcher and scope. Enable with
   `joesproxyctl rule enable <override-id> [--accept-confounder]` then
   `joesproxyctl rule apply-enable <proposal-token> [--wait-for-approval]`. Use
   `--accept-confounder` only when the enable gate reports overlapping enabled matchers and you
   intentionally accept that confounder.
6. Drive the client request and verify an attributed Map Local hit plus subsequent child-playlist
   traffic. Then `joesproxyctl rule disable <override-id>` /
   `joesproxyctl rule apply-disable <proposal-token>` and confirm `joesproxyctl cleanup status`.
   Do not use `return_to_normal` for this experiment — it stops the whole MCP server and can
   disrupt other clients. A disabled inert MCP rule may remain; cleanup treats only **enabled**
   effects as active.

#### Experiment matrix

Run repeated, **counterbalanced** conditions (order A→B and B→A across runs):

- **Control** — unmodified master (no CODECS Map Local, or rule disabled).
- **CODECS-only** — validated CODECS Map Local on the master (this slice).
- **AD-metadata-only** — **future**; same Map Local mechanism targeting `EXT-X-MEDIA` / ad-related
  tags, not implemented in this playbook’s tooling yet.
- **Both together** — **future**; CODECS + AD-metadata combined.
- **Switch near discontinuity** — ABR / variant switch close to an `EXT-X-DISCONTINUITY` (or
  equivalent) boundary.
- **Switch away from discontinuity** — same player path with the switch far from discontinuity.

#### Outcome classification (before player interpretation)

Classify delivery/fixture state first; only then interpret player behavior:

| Class | Meaning |
| --- | --- |
| `delivered` | Attributed Map Local hit; transformed master served as intended. |
| `not_delivered` | Rule enabled but request missed the matcher / wrong target. |
| `cache_no_hit` | Legacy outcome label: no attributed hit; cause unknown, not cache confirmation. |
| `stale_expired` | Preview/proposal/digest consumed or expired before apply/enable. |
| `expired_fixture` | Child 401/403 or missing child traffic from expired signed URLs — not CODECS evidence. |
| `inconclusive` | Incomplete capture, truncation, confounders, or insufficient evidence fields. |

#### Per-run evidence template

Copy into the run note. Record IDs, hashes, and counts only — **never** full manifests, signed
URLs, query values, credentials, or DRM material.

- Marker / capture interval:
- Source revision / sequence:
- Preview digest:
- Proposal token / rule (override) ID:
- Enable timestamp / disable timestamp:
- Attributed Map Local hit count:
- Transformed-body hash:
- Parsed CODECS (post-edit, from disclosure — not raw manifest paste):
- Matcher cardinality / confounder accepted? (`acceptConfounder` yes/no):
- Downstream-request summary (child playlist / segment status classes only):
- Player observation (symptoms only; not a confirmed causal claim):
- Completeness / truncation notes:
- Outcome class: `delivered` | `not_delivered` | `cache_no_hit` | `stale_expired` | `expired_fixture` | `inconclusive`
- Cleanup result (`isClean` / `activeEffectCount`):

### M3U8 playlist rewrite (generic path)

M3U8 master/media playlists are plain UTF-8 text — the generic G2/G3 response-edit pipeline below
(`response_context` / `response_text_search` / `preview_response_edit` / Map Local) handles them
unchanged; there is no separate "m3u8 edit" tool family beyond the CODECS-specific workflow above.
Use the same search-preview-map-local-enable sequence for a captured master.

- **Watch for `Content-Type: audio/mpegurl`.** RFC 8216 does not mandate one canonical MIME type,
  and real CDNs frequently label M3U8 playlists with an `audio/`-prefixed Content-Type even though
  the bytes are plain text, not binary audio. `response_context`'s `isUTF8TextEditable` correctly
  reports `true` for `audio/mpegurl` / `audio/x-mpegurl` (and the `application/`-prefixed variants) —
  if you ever see it reported `false`/`unsupportedEncoding` for a playlist, that is a decoder bug,
  not a real limitation of the format.
- **A patched playlist must remain structurally valid M3U8.** `preview_response_edit`'s diff/patch
  step operates on raw text and has no playlist-aware validation — it is your responsibility to
  target a value (e.g. a `BANDWIDTH`/`RESOLUTION`/`CODECS` attribute, or a URI line) whose length
  change cannot shift a tag boundary into invalid syntax. When in doubt, prefer the CODECS-specific
  workflow above for CODECS values specifically, since it validates master structure server-side.
- Everything else — search-first with exact literals, review `matchScope` before approving,
  create-disabled unless `enableAfterApply`, disable + verify on cleanup — is identical to the
  generic G2/G3 workflow immediately below.

