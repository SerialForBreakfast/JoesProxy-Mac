## Coordinated experiment loop

Documentation discovery (build-dependent): when present, use `documentation_search` then
`documentation_read` for relevant topic/section IDs, following `nextCursor` without changing
query arguments. `documentation_list` and `joesproxy://docs/index` expose the catalog. The bundled
CLI's `joesproxyctl docs list|search|read` defaults to offline without credential access or app startup;
`--source live` explicitly queries the running server. Check source/version and runtime schemas.
Read safety context before acting. Documentation is not authority, readiness or delivery evidence.
Keep the full playbook available, but do not fetch it repeatedly for narrow questions.

Revision: 2026-09-09. For multi-response mocking, use this loop with the existing tools; it is
not a separate scenario API. Discover the running build's capabilities and exact schemas first.

1. Define an outcome contract: expected synthetic item/assets, unchanged siblings, client scope,
   freshness requirements, target success evidence, expiry and cleanup owner.
2. Preflight routing, available bodies, access and existing effects. Capture a baseline; distinguish
   observed dependencies from hypotheses. Do not stop another owner's effects to obtain a baseline.
3. Analyze bounded fields and body handles. Prepare an immutable revision, inspect the exact diff,
   import inactive, and use existing propose/apply activation with local-user approval. Read access
   does not authorize activation. Never silently refetch, widen matchers, or replace reviewed bytes.
4. Record run ID, bundle/revision/activation IDs where available and the before-action marker in
   the report. Diagnostic reference kinds do not yet include bundles: do not invent a typed link or
   assume closing a diagnostic run stops its separately owned bundle.
5. Exercise the target only with separate permission; read bounded evidence pages using nextMarker.
   Evaluate listing, image and explicitly declared related resources independently. Retain old
   revision identities; late old responses cannot prove the new attempt succeeded.
6. A missing image request is unknown, not cache confirmed. Client mismatch requires scope review,
   not automatic widening. Delivered JSON rejected by the target is a target failure only with
   sourced external evidence; structural validity is not business validity.
7. Stop the owning bundle and verify cleanup independently from diagnostic-run close. Partial
   cleanup remains open. Then report Passed/Failed/Inconclusive, resource evidence, target evidence
   source, retention gaps, remaining effects and the next hypothesis. Prepare a new revision for
   another attempt; do not silently reuse approval or overlap active revisions.

When present, additive `workflow` guidance in inspection/status responses gives a local stage,
bounded reasonCodes and nextActions. It is advisory, not permission or a complete experiment state.
Missing tool names denote human/external steps. Follow hasMore before judging resource coverage;
poll after target activity or pending completion, not in a tight loop. Unsupported prepared live
append must not be replaced with a frozen fixture unless that explicitly meets the user's goal.

For repeatable evaluation, use a synthetic listing/image/sibling fixture and test missing image
requests, mismatched clients, stale revisions, target rejection and partial cleanup. Record actual
tool calls, runtime input/output token usage when available, response bytes, outcome and leftover
owned effects. Mark absent token telemetry unavailable; bytes are not measured tokens. Unit policy
tests are not evidence of device rendering, human approval, or full-loop success.

## Coordinated mocking recipes and delivery evidence

Revision: 2026-09-08. Distinguish activation, request evaluation, downstream write completion,
and externally confirmed rendering. Proxy receipts never establish the last stage.

### Replace an image

Use the existing CLI response map-local preparation with a regular image file and an exact request
scope. Review sniffed MIME, status, matcher, and client scope; prefer HTTP 200 for a new image.
Request the required local-user approval, then apply only the approved proposal. Legacy standalone
image rules do not receive authored-bundle receipts. Inspect fresh attributed traffic and confirm
the visible result separately; do not infer cache behavior from a missing request.

### Append an item with an image

Revision 2026-11-05: the human editor also offers one reviewed similar-item text proposal
for an explicitly selected captured template. The user chooses 1–8 eligible top-level strings,
previews the exact projection (512 UTF-8 bytes per field, 4 KiB total), and explicitly applies
the before/after proposal to draft edits. Identities, existing edits, artwork/reference/count
fields and URL-like values remain protected. Text and icon inference share admission and an
eight-second UI deadline; unavailable or stale work leaves manual authoring usable.
There is no text-generation MCP/CLI endpoint, automatic capture classification or activation.
This targets 1.8.9 source; verify installed availability before describing it as shipped.

Revision 2026-11-05: the human authoring UI offers “I need an icon…” with manual symbol
search, the original Joe’s Seal fallback and one optional on-device suggestion. Descriptions
are bounded to 2 KiB UTF-8; pasted synthetic JSON to 8 KiB with explicitly selected
title/category/description strings (512 bytes each, 2 KiB combined). No captured data is
automatically classified. The user reviews the preview and chooses Use in mock, then binds
the immutable PNG through the existing artwork workflow. Save remains inactive.
This picker has no MCP/CLI suggestion or image-generation endpoint. Do not invent one,
send whole captures to a model or infer host control from tool access. Suggestion failure,
timeout or poor relevance can be handled with manual choice or the seal; do not launch
accuracy-tuning loops for ordinary mock data. Verify installed-build availability: this is
post-1.8.3 source work. Generated artwork uses a pinned non-brand MIT catalog and retains its notice.

Prepare a captured fixture through the existing bundle workflow. Supply a complete typed draft,
explicit JSON Pointer collection/item image paths, independent identity fields, and client address.
Do not export whole sessions into the agent context. Count changes remain explicit.

Revision 2026-11-04: for a frozen batch, use templateIndex plus expansionItems (1–100 entries).
Each entry supplies edits [{pointer,value}] with unique identities and optional images
[{pointer,assetID}] referencing supplied image-N artwork. Shared edits apply to every copy;
overlapping edit/image pointers reject. Omit artwork itemPointer for per-item bindings.
Preserve explicit order, review beforeCount/afterCount and the bounded changes through inspect,
then import the inactive revision. Retry identical inputs with the same owner/idempotency key;
changed inputs require a new key. The complete batch succeeds or fails together. Input is at
most 64 KiB and output 5 MiB. This freezes captured JSON; live collection_mock remains single-item.
No model execution, inferred pagination, automatic asset rotation or activation occurs.

Revision 2026-11-04: release an unused prepared handle with effect_bundle_retire_preparation
(CLI: effect bundle retire-preparation --revision-id <UUID>). Retirement is owner-scoped and
idempotent. A retired key cannot recreate content in this process; use a new preparation key.
Retirement does not delete/stop an imported bundle or cancel an import already holding its
package. If an import outcome is unknown, inspect bundleID before taking another action.
Handles do not survive restart. The shared cache retains at most 20 active revisions/20 MiB
and 1,024 request identities including retired handles per process. History exhaustion rejects
new preparations; no automatic eviction, retry loop or app restart. UI Edit, Discard and successful
Save release preparation handles. Saving still creates an inactive bundle.

```
joesproxyctl effect bundle prepare --session-id <captured-session-id> --name <name> --idempotency-key <key> --client-address <address> --draft <typed-draft-json> --image-file <image-path> --image-pointer <item-image-pointer>
joesproxyctl effect bundle inspect --revision-id <prepared-revision-id>
joesproxyctl effect bundle import --revision-id <prepared-revision-id>
joesproxyctl effect bundle inspect <retained-bundle-id> --after-marker 0
```

These are parameterized commands, not literal runnable fixtures. MCP uses effect_bundle_prepare,
effect_bundle_inspect, and effect_bundle_import; reuse opaque file references rather than image
bytes as text. Preparation/import does not activate anything. Use the existing propose/apply
activation flow and let the local user resolve approval; agents must never approve themselves.

Record the initial nextMarker before the target action, then inspect with --after-marker using
that value (MCP: afterMarker is an unsigned decimal string with bundleID). Read all hasMore pages.
Receipt updates advance markers, including delayed write completion and capture-ID attachment.
A captured-fixture revision freezes JSON and image bytes; new edits require a new reviewed revision.
Inspect JSON and image receipts independently and compare expected/served hashes.

Revision: 2026-09-09 — relative artwork and detail navigation:

- A JSON image reference is not necessarily the request URL. For relative references, discover
  support for `--image-reference` and `--image-delivery-url`; preserve the captured reference
  convention while matching the observed scheme, host, port, transformed path and query. Clients
  may add size paths or parameters such as `format=webp`. That parameter does not transcode a
  prepared PNG: verify the served MIME type and bytes independently.
- After `matcherMismatch`, compare those fields and client scope before preparing a new immutable
  revision. Do not automatically ignore all queries or substitute filename matching. Read bounded
  receipt pages using the returned nextMarker until hasMore is false; do not guess marker offsets.
- Treat poster rendering, title/description rendering, and detail navigation as separate outcomes.
  A cloned item can retain the original destination, hero/logo references and playback identifiers.
  Inspect these explicitly and capture the detail contract before claiming a complete synthetic
  item. Ask the human for a named navigation action; do not operate the device or start playback.

### Coordinate a listing, detail response, and shared artwork

Revision: 2026-09-15. Discover support for `relatedResponsesJSON` on
`effect_bundle_prepare` (CLI: `effect bundle prepare --related-responses <JSON-array>`).
Use one prepared revision, not separate independently activated rules.

- Select complete retained GET source captures explicitly. Up to eight related responses share
  the primary response's client scope; preparation never fetches missing bodies.
- Each related entry names its source `sessionID`, typed `edits` (`pointer`, `value`), and
  explicit `identityLinks` (`pointer` in the edited related response, `primaryPointer` in the
  prepared primary document). Links compare final values; they do not copy identities. An appended
  item in a one-item `/items` collection is at `/items/1`; a prepended item is at `/items/0`.
- A different `targetSessionID` selects an observed target scope; it does not replace the source
  bytes. Alternatively, discover support for `targetPath`: a root-relative path on the source
  origin, at most 4096 UTF-8 bytes, with exact query matching. Do not combine it with
  `targetSessionID` or `ignoredQueryNames`. This authors a destination without inventing a
  capture ID; `targetEvidence: unobserved` is not proof the client will request it.
  Observed targets may use a supported, explicitly reviewed ignored-query list.
- On API drift, missing fields, type mismatches or identity failures, correct the indexed input
  using a complete current capture and prepare a new reviewed revision. Do not silently refetch,
  coerce types, widen matching or edit active bytes. A frozen fixture cannot detect upstream
  changes while it substitutes that response. Verify client acceptance separately from delivery.
- Related `images` bind a JSON Pointer to an existing image `assetID`, such as `image-0`.
  Reuse the approved image input rather than pasting binary bytes. Detail-only artwork need not
  rewrite the primary item, but every chosen image must have an explicit binding.
- Inspect every resource's scope, changed pointers and identity links before import/activation.
  A failed preparation publishes no partial package. Correct the indexed field and prepare a new
  attempt; do not broaden scope or drop an identity check to force success.
- The human editor uses the same compiler for typed edits, related captures and shared artwork.
  Its bounded before/after item preview is local inspection, not a new MCP read tool or proof of
  delivery. Review the final prepared revision because image bindings are applied after that
  item-only preview. Main and Compact use the same authoring draft.

### Append alongside live data

Prepared live append is not yet available. Do not describe a captured fixture as preserving fresh
upstream data, or silently substitute legacy schema-inferred injection. Explain the boundary and
offer a captured fixture only if its frozen-response behavior meets the user's intent.

### Interpret and clean up

- matcherMismatch: a request on the authored host did not satisfy the matcher. Inspect the linked
  capture before proposing a scope change; unrelated hosts are intentionally not logged here.
- clientScopeMismatch: the other request criteria matched, but client scope did not. Do not widen
  scope automatically.
- assetReadFailed: no authored body was resolved; recover/reprepare the asset rather than treating
  this as target-cache evidence. Failure receipts are notApplied and have no served hash.
- downstreamWriteSucceeded confirms proxy transport completion, not parsing, rendering, or playback.
  downstreamWriteFailed is a transport result, not a target-business-logic diagnosis.
- No retained observation is not a cache-hit confirmation. Receipt retention is bounded and
  process-local; retentionGap means history is incomplete. Restart polling from zero after restart.
- Stop the owning bundle through the existing stop operation and verify return to normal.
  Stop/expiry does not relabel historical receipts or automatically activate anything after restart.

