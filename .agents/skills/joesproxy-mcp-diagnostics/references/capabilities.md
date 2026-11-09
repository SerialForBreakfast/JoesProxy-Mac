## Capability coverage and release scope

Documentation review: 2026-10-29 (source guidance after the 1.8.2 candidate; re-export from the installed build).
The installed app and its exported manifest are authoritative;
repository changes are not proof that the running build contains them. Re-export the skill after
upgrading. Keep metadata.version tied to the app version, not the documentation review date.

- `agent_toolset_status` / `agent_toolset_select` select a smaller discovery catalog:
  core, capture, mocking, media, reproduction, advanced, or all. This reduces discovery tokens,
  not authorization; omitted policy-permitted tools remain callable. Read returned schemas
  and enums instead of guessing arguments from this playbook.
- For exhaustive names and descriptions read `joesproxy://agent/capabilities` or the generated
  All tools section of `joesproxy://agent/guide`. This self-contained exported skill needs no
  repository-only reference file to perform discovery.
- Prepare/import, active serving, an observed request, an applied mutation, downstream delivery,
  and a human/external target observation are separate facts. Report only the stage evidenced.
- Replacement-recovery and independent Traffic Modifications UI have build/Policy coverage;
  final host acceptance remains open. Use Tools > Traffic Modifications or Compact's Manage
  Modifications entry point in builds containing the independent window. Identify a retained
  bundle by its visible ID and revision, not its name alone; duplicates can share a name.
  Review client scope, expiry and evidence before activation. Window access grants no authority.
- Prepared coordinated live append uses the bounded executor described below; discover support
  and limits in the running build before proposing it. Full-body unlimited response capture
  remains unavailable; capture limits and retention can leave incomplete evidence.

### Coordinated bundle lifecycle and recovery

`effect_bundle_prepare`, `effect_bundle_list`, `effect_bundle_inspect`,
`effect_bundle_import`, `effect_bundle_retire_preparation`, `propose_activate_effect_bundle`, `apply_activate_effect_bundle`,
`effect_bundle_stop`, `effect_bundle_advance`, `propose_discard_effect_bundle`, `apply_discard_effect_bundle`
share the existing ownership, approval and TTL machinery. Preparation requires body-read access;
a read grant is not activation approval. An atomic activation gate is not an atomic transaction
across the target's multiple requests.

For reviewed static or live collection phases, inspect `supervision` and the retained bundle's `phase` snapshot before
`effect_bundle_advance`; pass its activationID and phaseID as expectedPhaseID. A stale command
fails instead of advancing twice. Final-phase Advance ends the run; no Advance extends expiry.
Sleep ends timed runs and wake never resumes them. Reviewed timestamp bindings replace existing
JSON strings with ISO-8601 UTC milliseconds from activation start plus explicit offsets; Advance
never rebases them. Evidence retains the template hash and a separate materialized hash.
Live collection phases use the bounded executor and preserve changing upstream data. Admitted
responses may finish under their original activation/phase; Stop and replacement invalidate
unfinished mutations. Typed delivery observations carry these live outcomes separately from
the authored-asset receipt projection; dynamic responses have no invented hash.
Existing transformation quotas still apply. Schema-6 HLS phases can preserve a
first-phase live fixture, switch reviewed compatible media, and explicitly complete it with
ENDLIST while retaining segments until Stop/expiry. Inspect mediaPlan and supervision.media;
publication state is not delivery or playback proof. Schema-7 HLS requestPolicy carries explicit
client scope and exact entry-query matching; legacy definitions remain all-client/query-insensitive.
JSON client filters do not restrict media. New lab work requires scoped media; inspect labReadiness
and the exact proposal approval separately. Prepared switching requires identical master bytes,
uniform matching segment timing and local unencrypted files; unsupported layouts fail activation.
Legacy live rewrites remain unavailable in phases. Readiness is not asset validation or approval;
do not flatten phases. Use docs read workflow-mocking for the detailed lifecycle contract.

Before/after reporting requires explicit windows, never an inferred recent-traffic baseline.
Create an owned diagnostic run with explicit scopes and start it with `diagnostic_run_start`
so it can be closed after cleanup. Then call `diagnostic_run_window_begin` with its runID, the
reviewed bundleID and mode=baseline while the bundle is inactive. Perform the baseline actions
and close it with `diagnostic_run_window_end`. Separately review/activate through existing
approval policy. Begin mode=modified, perform the target actions and explicitly end that window.
Call `effect_bundle_compare` with baselineWindowID and modifiedWindowID, then perform owned cleanup.
Window operations only observe; they never activate, advance, stop, approve or refetch traffic.
Keep the returned window IDs. Different owners, revisions, scopes or overlapping windows cannot
be compared. Read qualifications, pending writes and admission gaps before drawing conclusions.
Missing requests mean not observed, not cache confirmed. Timing is descriptive, not causal.
Record targetOutcome and outcomeSource on window end only with external or human evidence;
downstream write success does not establish rendering or playback. HLS baseline entry coverage
does not infer upstream child URLs. Use joesproxyctl run window begin/end and effect bundle compare
for equivalent CLI access; discover required arguments before issuing commands.

Revision 2026-09-23: inspect retained bundles by bundleID for lifecycle-aware `workflow` guidance.
Inactive means review/baseline before activation; stopped/expired means verify cleanup, not drive
more traffic. Retry owned Stop for cleanupRequired; never stop unrelated effects or silently
activate a replacement. Reinspect lifecycleChangedDuringRead. Guidance grants no authority.
Use typed deliveryEvidence.observations for live JSON/HLS; an empty legacy receipts array does
not mean no traffic. Pending work is not a skip, and upstream delivery after a skipped transform
is not mutation success. After stopping owned effects, close the started diagnostic run with an
evidence-qualified conclusion. Name the next actor: Agent for authorized tool work; Local user
for required approval or target interaction. Request physical presence only for an observed
condition requiring a specific local action. See docs read workflow-mocking for recovery detail.

After a failed receipt, inspect the exact retained revision/resource and expected/served digest.
An unavailable or changed asset must not silently become new reviewed bytes. Retained-package
verification does not establish runtime-file availability or delivery to a device.

In builds containing receipt recovery UI: Review → choose an explicit retained JSON GET capture
(from the bounded chooser, selected capture, or UUID) → open replacement draft → choose an image
→ prepare → review → save inactive → separately request activation. The source/draft is not
reconstructed from an image receipt: persisted metadata retains a source digest, not the original
JSON/draft pair. The editor preserves typed edits through Back/Resume and preparation/save failure
within the Overrides window; closing the window does not promise draft persistence. Source changes
invalidate preview/review. Checks and the chooser have no new MCP/CLI commands; do not invent them.
Use existing prepare/inspect/import for agent authoring. Never silently refetch an unavailable body.
If considering `recapture_session_body`, disclose that it is a new upstream request, not recovery
of the historical bytes, and obtain the required authorization.

### Devices, capture audits, and portable reproduction

- `list_discovered_devices` reports observed proxy clients and aliases; `set_device_alias`
  changes local naming, not device routing or trust. Observed IP identity is not durable device
  identity. Keep client scope explicit and recheck it after network changes.
- `audit_cache_efficiency` audits captured cache headers and duplicate traffic. It cannot inspect
  a target's private cache or establish why an unobserved request was not made.
- `repro_export_package` / `repro_inspect_package` create and inspect sanitized
  `.jproxy-repro` artifacts. `repro_replay_request` makes a real authorized request;
  inspection does not. CLI: `joesproxyctl repro export|inspect|replay`.
  Review privacy omissions and completeness. A package or HAR is not a snapshot of client cache,
  authentication, routing, backend state, or a fully reproducible network environment. Do not
  imply HAR import automatically installs mocks or replays traffic.

### Schema and generated-test workflows

- `openapi_import_spec` imports a specification; `openapi_validate_session` checks a captured
  JSON response; `openapi_generate_mock` generates schema-based JSON. Generated validity does
  not prove business semantics, authorization behavior or coverage. This differs from activating
  an OpenAPI mock pack; discover each surface's supported specification versions separately.
- `mocker_export_suite` generates test fixtures/code; `mocker_validate_fixture` checks
  drift against a capture. CLI: `joesproxyctl mocker export|validate`.
  Review generated code and sensitive content before saving/sharing/executing. Generation is not
  test execution or permission to install dependencies.
- `apply_create_live_rewrite` completes the existing preview/propose create-disabled flow;
  activation still uses `activate_live_rewrite`. It is not prepared coordinated live append.
- `apply_create_collection_mock` completes the preview/propose create-disabled collection-mock
  flow; activation still uses `activate_collection_mock`.

### Diagnostic evidence and host profiling

- `diagnostic_run_list` / `diagnostic_run_status` inspect owned runs;
  `diagnostic_run_evidence_list` / `diagnostic_run_evidence_get` retrieve retained evidence;
  `diagnostic_run_retry_cleanup` retries incomplete cleanup. Retained evidence does not establish
  a new target outcome. These complement create/start/observe/close/recheck above.
- `instruments_list_templates` discovers installed profiling support;
  `instruments_record_trace` creates a bounded host trace;
  `instruments_analyze_trace` reads trace metrics;
  `instruments_correlated_audit` relates host and wire observations.
  CLI: `joesproxyctl instruments templates|record|analyze|audit`.
  Profiling is not ordinary capture-only inspection: obtain explicit authority for the target
  process/device and recording duration. Discover available templates; never install tooling,
  launch/kill another app, or operate the desktop as an inferred prerequisite. Trace files may
  contain sensitive data. Align actual capture windows and describe temporal correlation as
  correlation, not proof of causation. An incomplete trace cannot stand in for an entire long run.

### Storage and HLS feature boundaries

Recordings support legacy JSON plus JPXR LZFSE/gzip containers through governed load/save paths.
Compression is lossless for retained data; it cannot restore bodies omitted or truncated during
capture. Read completeness/omission evidence before mocking or exporting. Large-file load and
rolling recovery do not imply a validated 24-hour memory ceiling.

HLS discovery exposes profile-specific audio topology, publication configuration, live time
shifting and ID3 facts. Use returned profiles and playbackConfiguration schemas: muxed-only,
demuxed and hybrid in-band/URI-backed audio differ; publication delay simulation is not on-demand
audio encoding. Synthetic language-labeled tones are not spoken translations. Live time shifting
is not LL-HLS. ID3 carrier declarations and validator results are not proof a target emitted the
expected player event. Correlate rendition, segment/discontinuity grid and external player evidence.
Do not infer support for arbitrary HDR, codecs, DRM or ID3 carriers from a catalog enum alone.

