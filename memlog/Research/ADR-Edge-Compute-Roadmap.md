# ADR: Edge-compute roadmap after 1.9.1

Status: accepted 2026-11-17. Owner: maintainer. Findings and measurements go in the
[gap ledger](Edge-Efficiency-Tranche-Acceptance.md).

## Decision

JoesProxy answers agent questions on the Mac and returns the smallest correct answer, or the
smallest useful view: a count, a table, a cropped image. Work is ordered by how many sessions it
affects and how exactly the answer can be computed.

## Rules

Implementation order after reconciliation with build 28:

1. Discovery and structured throttling, revision-consistent filtered counts, time buckets,
   percentiles and representative failures. Preserve the one-call build-28 baseline for
   first/latest examples. Benchmark slowest selection separately.
2. [Image essentials](ADR-Image-Evidence-Over-MCP.md): exact representation identity, explicit
   crops, then OCR. Use read-only disclosure and independent oracle images.
3. Request repetition, failure clusters, field drift, schema and two-window regression reports.
4. Reported model usage, cache accounting, prompt redundancy and tool timelines.
5. Wait/deltas, retention intervals, tables, result handles and post-approval rule verification.
   Pull bounded wait and interval coverage forward before the next live soak.
6. Visual similarity, contact sheets, region differences, classifications and transfer hygiene.
7. Optional local model summaries, semantic retrieval, cluster labels and language identification.
8. Specialized decoders, stream exception reports and representative video frames.

For every task compare the cheapest correct build-28 route with the candidate through both
public interfaces. Keep all-attempt correctness, paired calls, request/response bytes, elapsed
time and coverage. Record model token counts only when supplied by the evaluation worker.

1. Compute on the Mac when the answer is exact. Anything a model produced is labelled `heuristic`
   with its method and source digest, and never shares a field with exact results.
2. Extend an existing tool before adding one. New tools go in a task toolset, never `core`.
3. Aggregates by default, detail on request, pixels only when asked and at the smallest useful size.
4. Every capability ships with a paired old-versus-new receipt and a synthetic fixture.
5. Image and model work is on-device, bounded by `MediaInspectionWorkBudget` or
   `ArtifactAnalysisWorker`, cancellable, off the proxy's network path and behind body-read approval.
6. Tool discovery has a byte budget enforced by
   `MCPResponseDisclosureIntegrationTests.testToolCatalogsStayWithinDiscoveryByteBudgets`.

## Who this is for

| Developer | Typical question | Where an agent spends context today |
| --- | --- | --- |
| Mobile, TV and web app | Why did checkout fail? What changed since yesterday? | Paging sessions, whole JSON bodies, re-reading unchanged capture |
| Streaming and media QA | Which rendition stalled? Is this artwork the right size? | Manifests and segment lists; images it cannot see |
| LLM and agent app | How many tokens did my app send? Is the prompt cache hitting? | Multi-megabyte prompt and stream bodies |
| Performance | What is fetched twice? What is oversized? | Listing every request to find repeats |
| QA and regression | Did this response shape change? | Diffing full bodies |
| Every session | Tool discovery | 36 KB (`core`) to 74 KB (default) of `tools/list` |

## Tasks

Class is `exact` or `heuristic`. Status is `shipped`, `in progress` or `planned`.

### Tranche 1 — discovery and aggregation

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| A1 | Compact discovery, detailed reference, keyword lookup, one byte budget per toolset | exact | Tested on candidate. Core 36,817 → 36,144 bytes; default 74,268 → 73,331. Published-build autonomous routing comparison pending. |
| A2 | Whole-query endpoint and credential-chain aggregates | exact | Both shipped in build 28. Candidate endpoint grouping counts 50,001 matches across 34 signatures, returns the first 32 with an exact omitted-signature count, and supports representative IDs and p95. Auth-chain requests retain their separate 50,000-match limit. |
| A3 | Filtered counts without a row limit; result tagged with its revision | exact | Build 28 shipped revision tagging. Candidate removes the retained-input count ceiling for filtered calculations; deadline and cancellation still apply. Fixture: 50,001 retained rows. |
| A4 | Time buckets and per-endpoint duration/size statistics | exact | Candidate implements minute/hour UTC counts, nearest-rank p95, and observed sample counts through MCP and CLI. |
| A6 | Structured 429 with `retryAfterSeconds` and a `Retry-After` header | exact | Candidate returns the interval to CLI users and uses it in the bounded MCP readiness wait. |

### Tranche 2 — image essentials

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| B1 | Duplicate and repeat-fetch analytics in the cache audit | exact; similarity heuristic | Cross-URL SHA-256 grouping tested with complete bodies and range exclusion. Cache opportunity estimates and near-duplicate groups remain planned. |
| B2 | ImageIO thumbnail, normalized crop, grayscale and JPEG quality via existing visual inspection | exact transform | Loopback CLI command exported a 120 × 50 JPEG from half of a 480 × 100 source. Decoding and collision preservation passed. Installed release acceptance belongs to the upgrade test. |
| B4 | OCR with Vision: text, optional boxes | heuristic | First OCR command in an isolated test process returned the synthetic label and box in 0.400 seconds with the default CLI timeout. System model caches were left in place. |

### Tranche 3 — redundancy analytics

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| C1 | Duplicate requests by method, URL and body hash | exact | Candidate revision 36 adds approved request identity groups to the cache audit and CLI. Reports repeated request bytes, comparable response counts and repeated status/body bytes. Avoidability requires separate cache-policy evidence. |
| C2 | Patterns: N+1 sequences, polling loops with interval, retry storms, redirect chains | exact rules | Planned |
| C3 | Response clustering by body hash and JSON shape | exact | Candidate revision 37 adds endpoint-scoped byte and shape counts, representative sessions, HTTP error priority and explicit coverage to the cache audit and CLI. |
| C4 | Error clusters by status and normalized error body | exact | Implemented for retained HTTP failures, with byte fallback and explicit coverage. |

### Tranche 4 — LLM and agent-app traffic

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| D1 | Provider-reported token usage, model, stop reason and latency, totalled by endpoint, model and time bucket. Builds on `llm_stream_inspection` | exact | Planned |
| D2 | Prompt-cache hit rate and longest shared prefix across misses | exact | Planned |
| D3 | Repeated system prompts and tool definitions by hash; images sent to a model with dimensions | exact | Planned |

### Tranche 5 — waiting and handles

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| A5 | `capture_wait`: return when N matching requests arrive or a timeout passes | exact | Implemented for future admissions, distinct IDs, cancellation and capture reset; live soak pending |
| A7 | Optional tabular rows for list results | exact | Implemented for endpoint variants and minimal search pages. Wider projections remain planned. |
| A8 | Result handles: refine, page or re-aggregate a stored query result | exact | Planned |
| A9 | Interval reports and delta reads | exact | Candidate revision 35 adds rolling failure, retention and admission intervals to `capture_digest` and the CLI. Rehearsal assertions reconcile the report with the store before clear and at periodic checkpoints. Generalizing delta reads to other tools remains planned. |

### Tranche 6 — image depth

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| B3 | Contact sheet: one labelled grid image for many assets | exact | Planned |
| B5 | Smart crop from Vision saliency and text regions (`focus: salient, text, region`) | heuristic | Planned |
| B6 | Image diff: changed-region boxes, percent changed, crop of the change | exact | Planned |
| B7 | Classification labels, barcode and QR payloads, presence flags | heuristic | Planned |
| B8 | Optimization audit: oversized assets, estimated re-encoding savings | exact, estimates labelled | Planned |

### Tranche 7 — on-device language models (opt-in)

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| E1 | Bounded summary of a large HTML, text or log body with Foundation Models | heuristic | Planned |
| E2 | Semantic search with NaturalLanguage embeddings; returns session IDs and exact snippets | heuristic ranking, exact snippets | Planned |
| E3 | Short labels for error clusters from C4 | heuristic | Planned |
| E4 | Language identification for localization checks | heuristic | Planned |

### Tranche 8 — decoders, schema and video

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| C5 | Field-level change over time for one endpoint; volatile fields | exact | Planned |
| C6 | Inferred JSON schema and schema diff between captures | exact | Planned |
| C7 | Header and payload hygiene: compression, cookie bloat, cacheability | exact | Planned |
| C8 | Decoders: JWT claims, GraphQL operations, protobuf and gRPC field maps | exact | Planned |
| B9 | Representative downscaled frame or sprite sheet per HLS segment | exact | Planned |
| D4 | Compact tool-call timeline for a captured agent session | exact | Planned |

### Every tranche

- F1. Route the capability in `efficient-reads.md`; rerun `evals/skill-routing`.
- F2. Extend the capture soak with the tranche's calls.
- F3. One benchmark question in `evals/edge-release`, published with the release notes.
- Mirror tool changes in the CLI, `doc-reference-tools.md` and the skill references, and raise the
  capability revision in both `MCPCapabilitiesRevision.swift` and `JoesProxyCLI/CLIModels.swift`.

## Limits

### Engineering queue and fixture ownership

Use build 28 as the baseline. Each row owns one paired receipt per question; run the same
question with equal disclosure and score against the same oracle. Include failed attempts,
retries and truncated coverage. Publish the measured outcome only after release approval.

| Tasks | Toolset and reuse | Dependencies | Oracle fixture and receipt question |
| --- | --- | --- | --- |
| A1, A6 | Task discovery, existing catalog and rate buckets | Existing enrolled profile | Cold and warm catalog, expired slot, denied tool. How many bytes and calls before the first correct read? |
| A2–A4, endpoint examples | Capture, filtered calculation and session index | Snapshot revision and disclosure | Mixed failed and pending sessions around bucket edges; 1, 300 and 50,001 rows. Do count, p95 and example IDs match the independent table? |
| B1 exact, B2, B4 | Media and cache audit, ImageIO preflight and existing workers | Body authority and derivative contract | Duplicate artwork across URLs, partial range, rotated corner label. Can an agent count repeats then read the label via OCR or one crop? |
| C1–C4 | Capture, cache and comparison briefs | Snapshot group identities | Duplicate method/URL/body, retry burst, redirect plus isolated failure. Are all distinct errors represented? |
| C5–C6 and regression windows | Capture and artifacts, structure discovery and contract diff | Typed values and two source revisions | Null, missing, Boolean/string change and noise-only control. Which endpoint regressed and when? |
| D1–D4 | Media and advanced analysis, stream inspector | Provider-specific usage adapter | Cumulative usage with duplicate chunks, missing stream tail, cache hits and tool calls. What usage is attributable exactly? |
| A5, A9 and capacity intervals | Capture, existing cursor and retention counters | Implement before long soak | Quiet interval, late completion, eviction, clear and restart. Can one bounded wait replace repeated polling? |
| A7–A8 and rule verification | Capture and mocking, page cursors and effect receipts | Filter identity, revision and approval | Refine a previous window, expire a handle, verify a rule with and without fresh traffic. Are repeat reads smaller and correctly scoped? |
| B1 similarity, B3, B5–B8, C7 | Media and cache audits, visual inspection | Exact B1/B2 and bounded decoding | Look-alike prices, contact sheet, oversized artwork, cache headers. Report false merges separately from measured transfer bytes. |
| E1–E4 | Advanced analysis, local model availability and typed summaries | C4 plus per-source evidence | Unsupported Mac, conflicting claims, missing evidence and known-language text. Grade exact quotes, unsupported claims and retrieval recall. |
| C8, B9 and stream exceptions | Capture and media, waterfall and bounded visual work | Settled HLS fixtures and B2 | Schema-known and unknown binary payloads; ambiguous ladder and selected frame. Check source references, incomplete coverage and returned dimensions. |

F1 uses exported-skill routing with a frozen first-call rubric. F2 measures capture pressure,
peak memory and local CPU during the synthetic soak. F3 records both sides' calls, request
bytes, response bytes and elapsed time. Keep transfer savings separate from model-reported
tokens and from estimates of avoidable client network traffic.

Bytes are not tokens; token claims come only from fixed-model trials. Model output can be wrong and
is labelled. Foundation Models and some Vision requests are unavailable on some Macs, so each
heuristic tool reports `unavailable` cleanly. Apple framework APIs are checked against current
documentation when each tranche starts.
