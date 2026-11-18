# ADR: Edge-compute roadmap after 1.9.1

Status: accepted 2026-11-17. Owner: maintainer. Findings and measurements go in the
[gap ledger](Edge-Efficiency-Tranche-Acceptance.md).

## Decision

JoesProxy answers agent questions on the Mac and returns the smallest correct answer, or the
smallest useful view: a count, a table, a cropped image. Work is ordered by how many sessions it
affects and how exactly the answer can be computed.

## Rules

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
| A1 | Discovery diet: shorter descriptions, schema detail moved to `documentation_read`, a `tool_find` keyword lookup, per-toolset byte budget | exact | In progress: budget test pins the 2026-11-17 sizes (core 36,817 bytes, default 74,268; ceilings 37,500 and 75,500); reduction planned |
| A2 | Aggregates over all matches, not one page (`aggregateScope: allMatches`) | exact | Shipped in 1.9.1 (28) for endpoint groups; status mix and duration percentiles per endpoint planned |
| A3 | Filtered counts without a row limit; result tagged with its revision | exact | Shipped in 1.9.1 (28). The 50,000 retained-session input limit remains |
| A4 | `groupCount` by time bucket; `numericSummary` on duration and size per endpoint | exact | Planned |
| A6 | Structured 429 with `retryAfterSeconds` and a `Retry-After` header | exact | Implemented and tested 2026-11-17, uncommitted. CLI still ignores the interval and sleeps a fixed 2 seconds |

### Tranche 2 — image essentials (needs its own ADR first: image content over MCP, size and privacy limits, hash choice)

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| B1 | Duplicate and repeat-fetch analytics: exact by SHA-256 of decoded bytes, near-duplicate by perceptual hash then Vision feature print; wasted bytes, cacheability, same image at several sizes. Extends `audit_cache_efficiency` | exact, near-duplicate heuristic | Planned |
| B2 | `image_view`: downscaled and cropped image block via ImageIO thumbnailing; maximum edge, crop rectangle, grayscale, quality | exact | Planned |
| B4 | OCR with Vision: text, optional boxes | heuristic | Planned |

### Tranche 3 — redundancy analytics

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| C1 | Duplicate requests by method, URL and body hash: counts, wasted bytes, identical-response rate | exact | Planned |
| C2 | Patterns: N+1 sequences, polling loops with interval, retry storms, redirect chains | exact rules | Planned |
| C3 | Response clustering by body hash and JSON shape | exact | Planned |
| C4 | Error clusters by status and normalized error body | exact | Planned |

### Tranche 4 — LLM and agent-app traffic

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| D1 | Provider-reported token usage, model, stop reason and latency, totalled by endpoint, model and time bucket. Builds on `llm_stream_inspection` | exact | Planned |
| D2 | Prompt-cache hit rate and longest shared prefix across misses | exact | Planned |
| D3 | Repeated system prompts and tool definitions by hash; images sent to a model with dimensions | exact | Planned |

### Tranche 5 — waiting and handles

| ID | Task | Class | Status |
| --- | --- | --- | --- |
| A5 | `capture_wait`: return when N matching requests arrive or a timeout passes | exact | Planned |
| A7 | Optional columnar or TSV rows for list results | exact | Planned |
| A8 | Result handles: refine, page or re-aggregate a stored query result | exact | Planned |
| A9 | `sinceSequence` and digest conditions on the remaining read tools | exact | Planned |

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

Bytes are not tokens; token claims come only from fixed-model trials. Model output can be wrong and
is labelled. Foundation Models and some Vision requests are unavailable on some Macs, so each
heuristic tool reports `unavailable` cleanly. Apple framework APIs are checked against current
documentation when each tranche starts.
