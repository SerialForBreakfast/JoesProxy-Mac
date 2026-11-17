# Edge efficiency tranche acceptance plan

Build 28 source reconciliation: both endpoint and auth-chain search aggregates receive the
full filtered input at the cursor watermark, independent of page size. A 50,000-input guard
remains. The endpoint status distribution and first/latest locators already exist. Compare
new example selection with that one-call baseline when measuring efficiency.

The first candidate slice adds opt-in slowest/first/latest endpoint examples, bounded
keyword discovery, filtered metadata counts without the retained-input count guard, CLI
retry intervals, and body-approved exact image grouping. The example fixture retains 300
matches behind a one-row page; the count fixture exercises 50,001 retained sessions. The
image fixture uses one PPM under two URLs and one partial response. Token savings, live soak
cost, and independent fixed-build paired receipts for these new paths remain unmeasured.

On the candidate test host the 300-failure, single-endpoint fixture returned the correct
slowest session at index 149 in both workflows. Two build-28-compatible reads used 460
request bytes and 2,990 response bytes in 12.15 ms. One candidate read used 261 and 1,628
bytes respectively in 9.56 ms. This is one local matched execution without model inference.
A standalone synthetic label was recognized with OCR and boxes, without sending pixels.
Its first focused test took 65 seconds on this Mac; cold interactive latency is unresolved.

The candidate catalog fixture measured 36,144 bytes for core and 73,331 for all. Task
catalogs measured 47,060 for capture, 47,068 for mocking, 42,832 for media, 37,183 for
reproduction and 45,755 for advanced. The fixture uses one authenticated client with fixed
grants and available services. These figures describe RPC response bytes, not model tokens.

2026-11-10 review. The five capabilities have implementations in the working tree. Accept each on a user question with an independent expected answer, a disclosure test and a paired workflow receipt. Ship independently if one fails.

## Evidence available today

The latest inspected Policy result contains 3,066 cases: 3,051 passed, 15 skipped, zero failures. An earlier full run failed the generated-reference parity test. A subsequent 13-test run and the final full run passed. These receipts describe a local checkout. A commit-bound hosted receipt is pending.

The filtered calculation fixture is the reference measurement. Its frozen window contains 299 recorded 502 responses and one missing status. The authenticated RPC transcript yields the following UTF-8 byte counts, excluding transport headers and initialization:

| Question | Workflow | Calls | Request bytes | Response bytes |
| --- | --- | ---: | ---: | ---: |
| Count by status | Search and calculate by ID | 8 | 13,698 | 91,799 |
| Count by status | Filter and calculate | 1 | 333 | 1,610 |
| Count and open one example | Search and calculate by ID | 9 | 13,846 | 94,115 |
| Count and open one example | Filter and calculate | 3 | 697 | 5,234 |

Reproduce from the filtered-capture-300-rpc-bodies test attachment. For the aggregate-only comparison remove the final baseline message and the final two candidate messages. Measure actual provider tokens separately. This fixture covers the earlier filtered-calculation slice.

## Acceptance changes before release

1. **Search and endpoint groups.** Decide whether a group describes a page or a whole bounded window. The current response returns summaries for every item plus page-local groups. Add an explicit groups-only response and a detail lookup. Exercise one endpoint spanning three pages, missing paths, restricted profiles and two different filters against the same state token. Validate arguments and disclosure before conditional reuse. Bind conditional answers and cursors to the normalized query and output options. Measure cold discovery, first read and warm repeat independently.
2. **Predicates and batch calculations.** The current batch parses once and loops over queries. Either implement shared traversal or document and measure up to four bounded passes. Cover explicit IDs, saved artifacts and a filtered live window separately. The filtered dispatcher accepts a single operation. Reject unsupported combinations explicitly and validate every predicate field against its dataset and disclosure scope. Compare results to independent exact-decimal answers for missing, null, mixed types and boundary values. Record parse count, row visits, elapsed time and RPC bytes for one to four operations.
3. **Projection and value differences.** Test sensitive ancestors as well as leaves, embedded credentials in ordinary text, multibyte preview limits and distinguishable missing versus JSON null. Require explicit incomplete coverage at depth or visit exhaustion. Generate more than 32 volatile changes before one functional change and require the functional change to survive the display limit. Compare the compact answer and one detail read against the authorized raw-body workflow.
4. **Rule delivery.** Report current predicate matches, observed application provenance and historical hit counters as separate evidence. A rule enabled or edited after capture can match a historical request without having delivered that response. Test this case, a disabled rule, two competing rules, a sequence-only window, pagination and actual observed hits. Mark coverage and identify which rule revision was evaluated.
5. **Credential continuity.** Scope labels to the report and indicate partial capture/page coverage. Treat an absent cookie or an HTTP error as an observation until causal evidence exists. Exercise same-host cookies with different Path attributes, concurrent clients, two raw hosts with the same sanitized display label, and a rotation across page boundaries. Verify that generated summaries contain no fixture credentials. Evaluate the actual approval and disclosure path for both search and lineage calls.

For each case preserve the fixture version, source commit, expected versus observed answer, paired RPC transcripts and elapsed time. Count detail reads, retries and approvals. Track discovery bytes separately because additional tool schemas increase first-turn cost. Report provider token use only from a fixed-model trial with usage receipts, otherwise label tokenizer estimates. Keep source presence, passing functional tests and measured efficiency as distinct checklist items.

## Branch handoff

Review the local validation commit before pushing: it also includes the Apple HLS ADR that was previously excluded from this branch. Keep generated build products and local test bundles outside the change set. Run the hosted filtered fixture against the agreed branch SHA before opening a PR.

## Gap ledger

Planned work that follows from these findings is in the
[edge-compute roadmap](ADR-Edge-Compute-Roadmap.md).

Started 2026-11-12 from a logging audit of the files this branch changed. The capture soak
(`ProxyServerTests/testCaptureSoakWithAgentWorkflows`) adds measured entries. Each finding has one
class: product defect, evidence gap, skill gap or capability gap.

Rules for adding capability without adding token cost: compute on the Mac when the answer is exact;
extend an existing tool before adding one; put new tools in a task toolset, never `core`; return
aggregates by default and detail on request; ship each capability with a paired old-versus-new
receipt; track `core` discovery bytes so they cannot rise unnoticed.

| Finding | Class | Status |
| --- | --- | --- |
| No log line recorded a completed MCP request, so duration and request/response bytes per tool were invisible outside tests | Evidence gap | Fixed: one content-free `Completed` line per request in the MCP `Protocol` category |
| Capture admission paused and resumed silently | Evidence gap | Fixed: transition lines in `com.JoesProxyApp.Capture` / `Admission` |
| Rule creation, enable, disable and removal were silent in the override store | Evidence gap | Fixed: identifier and kind only, category `Overrides` |
| A Map Remote denial at request time was logged only when verbose HTTPS logging was on | Evidence gap | Fixed: reason code always logged |
| A filtered calculation that loses a race with new traffic returns `sourceChanged` with no retry; the ADR calls for a retry within budget or an explicit retry result | Product defect, confirmed | Open. Two 10-minute pilots: 57 of 304 and 53 of 304 filtered calculations (about 18%) failed this way while 8 requests arrived; every completed answer was correct. Overnight (8 h, 14,248 attempts): 492 (3.5%) |
| Filtered calculation rejects a capture above 50,000 retained sessions with a generic input limit | Capability gap, unconfirmed | Not exercised by the soak's retained population |
| Loopback policy denials at proposal and activation time have no log line | Evidence gap | Open |
| Credential-continuity, comparison and response briefs log nothing when a budget or coverage limit truncates them | Evidence gap | Open |
| The session recorder logs nothing when a capture is skipped or reduced to metadata | Evidence gap | Open |
| A client over the 60-per-minute request limit gets status 429 with the plain-text body `Rate limited`: no JSON error, no reason code and no retry interval, so an agent cannot tell how long to wait. Seen in the first soak pilot, which hit the limit in 25 seconds | Evidence gap | Open; the soak now paces itself under the limit and records the wait |
| A proxied exchange occasionally reaches the client cut short (`incompleteResponse`): once in the first rehearsal (cycle 374) and once overnight (cycle 2054, `media` fixture, normal receiver) | Product defect, unconfirmed | Open. About 1 in 90,000 overnight; the log cannot say which side closed first |
| The proxy occasionally answers with its own `502 Bad Gateway` (152-byte plain-text body) for a request the loopback origin serves normally: once in the rehearsal (cycle 188) and six times overnight (cycles 187, 560, 1308, 1495, 2428, 3177; fixtures `gzip`, `api`, `redirect`, `empty`), about 1 in 15,000 requests, never two in one cycle | Mostly a test-environment artifact; product hardening open | Cause found 2026-11-13. The failure path logged only with verbose HTTPS logging; it now always logs `Proxy failure response` with status, bucket and error type. A third 60-minute run hit it again at cycle 183 and logged `errorType=ChannelError detail=I/O on closed channel`. In all seven overnight and rehearsal incidents, the client's ephemeral source ports had wrapped around and were 2 to 16 below the proxy's listening port, and the loopback origin listens on the adjacent ephemeral port. The spacing between overnight incidents (373, 748, 187, 933, 749 cycles) is a multiple of the roughly 187 cycles one pass through the ephemeral range takes. This fits an upstream connect whose source port collides with the origin's own port (TCP self-connect); not yet proven by an upstream local-port log. Only an origin listening inside the ephemeral range (49152–65535) can trigger it. Next: bind the soak origin below that range, log upstream local and remote endpoints on failure, and consider having the proxy refuse a self-connected upstream (local endpoint equals remote) with a clear reason |
| `ChannelError` on the upstream connection is classified as bucket `unknown` and the client gets the generic text "could not complete this connection" | Evidence gap | Open |
| A session whose response the proxy synthesized as a 502 appeared under missing status in the historical overnight run | Recorded-status evidence | Candidate fixture verifies a refused upstream connection through wire status, stored proxy error, and filtered status count. The original soak's failure cause remains unconfirmed. |
| The proxy logs `Proxy channel inactive` with no close reason, bytes relayed or matching capture ID, so the truncated exchange above could not be traced from the log | Evidence gap | Open |
| The paged workflow spends one request per 50 sessions plus one per 192 identifiers against the same 60-per-minute limit, so on a busy capture the limit, not bytes, is what stops it first | Capability gap, measured at small scale | Pilot, 16 to 21 sessions per window: filtered 1 call and 1,312 bytes median, paged 2 calls and 8,829 bytes; the harness spent 434 of 612 seconds waiting on the limit. Overnight, 3,562 windows: filtered 1 call, 1,318 bytes, 10 ms median (p95 17 ms); paged 2 calls, 8,857 bytes, 32 ms median (p95 40 ms); 20,644 of 28,802 seconds spent waiting on the limit |
| Overnight resources: footprint 64 to 148 MiB, no growth after clears (-1.6 MiB/hour across 356 clears), every checkpoint drained, no rejected captures; 890 rule changes, 593 pauses and 356 clears all behaved correctly | — | Evidence for the branch, not a gap |

Soak version 1 covers status counts through both workflows, the same question under live traffic,
a block rule added and disabled while recording, a capture pause and a history clear. It does not
yet cover loopback Map Remote, admission saturation, save and reopen, projections, value
differences, rule near misses or credential continuity, and it changes rules through the override
store directly, not through MCP proposals and approvals.
## November 13, 2026 — optimized 60-minute rehearsal

JoesProxy completed 441 cycles in 3,603.6 seconds. The synthetic origin received 11,278 requests. The origin used port 41000 and the proxy used port 41100. The run recorded zero invariant failures, zero 502 responses and zero upstream self-connect notices. Both status-count workflows returned the correct answer in all 441 paired comparisons. The low-port result supports the port-collision hypothesis. The cause of the earlier intermittent 502s remains unconfirmed.

| Status-count workflow on this Mac | Median RPC bytes | Median workflow latency |
|---|---:|---:|
| Page through search results and calculate by ID | 8,834 | 37.3 ms |
| Filter and calculate locally | 1,315 | 11.7 ms |

The local calculation used 85.1% fewer median RPC bytes for this question. In the separate concurrent live-query exercise, 1,574 attempts succeeded and 190 returned `source_changed` as capture advanced. Those outcomes need to be counted when measuring end-to-end agent usage.

These measurements describe the optimized development checkout used for the rehearsal. Provider-token measurements and a new eight-hour soak are pending.

## Build 28 follow-up — endpoint evidence and image inspection

The endpoint-failure fixture contains 300 failures and one uniquely slowest request. Both workflows returned the expected count and example ID. The control uses the build-28 API on the candidate dispatcher. A separate run against the tagged binary and fixed-model token trials remain pending.

| Workflow | Calls | Request bytes | Response bytes | Elapsed in this run |
|---|---:|---:|---:|---:|
| Search and resolve the example separately | 2 | 460 | 2,990 | 12.15 ms |
| Group endpoints with the slowest example | 1 | 261 | 1,628 | 9.56 ms |

Authenticated discovery measured 36,144 bytes for core and 73,331 bytes for the default catalog. Their comparison baselines were 36,817 and 74,268 bytes respectively. The timing figures above are single observations.

The synthetic image fixtures verified exact repeat grouping, JPEG crop delivery and recognition of the expected label with a normalized bounding box. The first OCR fixture took 65 seconds including setup. Cold success through the 60-second transport deadline remains unverified. The serial Policy run passed 3,108 tests with 17 skipped. The extended rehearsal, installed CLI file acceptance and autonomous model trials remain open.

### November 16, 2026 — pre-soak verification on the candidate

Endpoint-only grouping scanned an immutable capture with 50,001 matches, a one-row page and 34 distinct normalized endpoints. It returned 32 groups, reported two omitted signatures and counted 1,471 requests in the first group. The separate auth-chain input ceiling still applies when requested. A loopback refused connection produced HTTP 502 at the client and status 502 in the store. A filtered `capture_calculate` on that path returned exactly one 502.

Adding the omission count changed the earlier endpoint receipt. On this revision the two-call control used 460 request bytes and 3,020 response bytes. The single call used 261 and 1,658 respectively. Both found the same count and slowest example on the candidate dispatcher.

The first OCR command in a fresh test process returned `CLOSED` with a normalized bounding box in 0.400 seconds using the default CLI timeout. Timing includes CLI negotiation and the loopback request, and excludes creation of the synthetic PNG and listener. System-level model caches were left intact. This is one first-use observation on this Mac.

The production CLI command received an MCP image block over loopback, cropped the left half of a 480 × 100 source and wrote a decodable 120 × 50 JPEG. A second write to the same destination failed and the original bytes were preserved. These tests use isolated credentials and run the CLI entry point in process. The installed executable and Keychain workflow remain part of release acceptance.

Serial Policy passed 3,111 tests with 17 skipped and zero failures. The Debug app build succeeded. This verification precedes the soak.

### Revision 35 — periodic capture intervals

The synthetic interval starts with one successful retained response. A late update marks
that session failed twice, a second request arrives, body retention strips bytes, and
count retention removes one session. One admission is rejected. The interval reports one
failure transition, one new session, one whole-session removal, the store's body-removal
count, one unrecorded request and the peak observed between reads. A quiet interval reports
zero transitions. A retried checkpoint returns its prior report, and a clear invalidates it.

For the shared question “How many whole sessions were lost between these two checkpoints?”,
both workflows returned one. These dispatcher measurements include both checkpoint calls
and use the same capture and disclosure settings.

| Workflow | Calls | Request bytes | Response bytes | Total RPC bytes |
|---|---:|---:|---:|---:|
| Read the ordinary digest twice and difference retention counters | 2 | 194 | 3,810 | 4,004 |
| Start an interval and read its checkpoint | 2 | 261 | 980 | 1,241 |

The peaks measure retained store state at published changes. Network in-flight peaks and
physical process memory need separate instrumentation. The reference workflow uses the
existing API on the candidate dispatcher. Model tokens and live-run savings remain unmeasured.

Serial Policy passed 3,113 tests with 17 skipped and zero failures. The Debug app built
successfully. The rehearsal now records rolling interval receipts and reconciles retention
and admissions with the store across clears. Its opt-in timed run remains pending.

### Revision 36 — request identity audit

The candidate adds a request identity mode to the existing cache audit. The mixed fixture
contains repeated POSTs with the same entity, a different entity at the same URL, a different
query, a different port, and an unknown legacy body. The expected group has four requests,
three comparable responses, two distinct status/body combinations, and one repeated response.
The lone 503 has its own session reference. One incomplete response contributes to request
occurrences while being excluded from response comparisons.

The paired receipt uses 128 identical, empty GETs with uncached responses. Both audit
modes can answer the occurrence count for this controlled fixture. The ordinary cache
audit cannot establish POST body identity in the mixed fixture. Both calls use an
initialized client on the candidate dispatcher. The body grant is already in place.

| Audit for the shared 128-GET question | Calls | Request bytes | Response bytes | Elapsed in one focused run |
|---|---:|---:|---:|---:|
| Ordinary URL cache audit | 1 | 105 | 5,391 | 2.56 ms |
| Exact request identity | 1 | 134 | 920 | 7.69 ms |

Both returned 128 occurrences. The identity audit returned one representative, 127
repeated response bodies and 127 repeated body bytes. It used 80.8% fewer total RPC
bytes and took longer locally on this fixture. No model-token measurement was made.
The 47 focused tests passed, including capture replacement, grant revocation, unknown
request bodies, output limits and retention of the example 503.

The full serial Policy run passed 3,117 tests with 17 skipped and zero failures.
The Debug app build succeeded.

### Revision 37 — endpoint response variants

Five synthetic responses from one endpoint contain four distinct captured bodies and
three status/JSON-shape combinations. The control reads one approved response brief per
known session and groups the source digests. The candidate takes one representative
session ID. Both recovered the same four byte variants and representative IDs. Only the
candidate returned the shape groups in this comparison. The fixture uses JSON served
without content encoding and a single 503 with a unique body.

| Workflow | Calls | Request bytes | Response bytes | Elapsed in the focused run |
|---|---:|---:|---:|---:|
| Per-session briefs | 5 | 890 | 6,891 | 5.17 ms |
| Endpoint response variants | 1 | 174 | 1,107 | 1.50 ms |

Total RPC bytes fell from 7,781 to 1,281 (83.5%). Both arms used the candidate dispatcher,
an initialized client and an existing body grant. Model tokens and live-capture latency
remain unmeasured. Additional fixtures verified gzip shape equivalence, partial and
malformed input coverage, explicit output limits, and retention of the rare HTTP error
in a report with more variants than display slots. All 41 focused tests passed.

Full serial Policy passed 3,119 tests with 17 skipped and zero failures. The Debug build succeeded.

### Revision 38 — compact response variants

The revision 37 five-response fixture also compares the ordinary and compact variants
of the same approved MCP call. Expanding both tables by their shared column names
reproduced the entire ordinary report, including all seven ordered example rows,
the rare 503, and the coverage fields. An empty report with a skipped body retained
the smaller ordinary encoding.

| Initialized MCP workflow | Calls | Request bytes | Response bytes | Total bytes | Focused-run elapsed |
|---|---:|---:|---:|---:|---:|
| Endpoint variants | 1 | 174 | 1,107 | 1,281 | 1.01 ms |
| Endpoint variants with compact rows | 1 | 197 | 793 | 990 | 0.66 ms |

The compact request added 23 bytes and saved 314 response bytes, reducing total RPC
bytes by 22.7%. The initial table implementation crossed the 768-byte text fallback
threshold and returned a second copy of the table. The regression test compares the
complete RPC bodies so it detects that duplication. A table now uses a short text
summary and retains the evidence in structured content. Latency is a single local
sample. Provider token usage and model interpretation remain unmeasured.

All 25 focused checks passed, including CLI argument mapping and discovery byte budgets.
Full serial Policy reported 3,120 passed, 17 skipped and zero failures. The Debug build succeeded.

### Revision 39 — search pages, wait rehearsal and HTTP error clusters

Paired local, initialized MCP dispatcher calls. Sizes count serialized JSON-RPC
request/response bodies. Timings below are individual Debug samples. No provider ran.

| Workflow | Control calls | Candidate calls | Control request / response bytes | Candidate request / response bytes |
|---|---:|---:|---:|---:|
| Empty minimal search | 1 | 1 | 108 / 718 | 127 / 718 |
| One retained row | 1 | 1 | 108 / 1,422 | 127 / 1,422 |
| First 50 rows of 54 | 1 | 1 | 108 / 15,856 | 127 / 9,056 |
| Remaining 4 rows via cursor | 1 | 1 | 156 / 2,055 | 175 / 1,506 |
| Poll or wait, with start and end interval reads | 6 | 3 | 769 / 4,230 | 387 / 1,166 |
| Distinct HTTP errors and one example per group | 4 | 1 | 620 / 8,622 | 125 / 904 |

**Search.** Each arm followed its own opaque cursor. Expanding columns and dropping
absent cells reproduced the ordinary rows, ordered IDs, metadata and retention warning
on both pages. The 50-row pair took 4.43 / 4.64 ms. A client asking for compact rows
pays 19 extra request bytes on an empty or one-row result.

**Wait.** Both observers saw the same published 503 and used the same two checkpoint
boundaries. The fixture took three quiet polls and one positive poll, compared with
one subscribed wait. There were zero retries. With the fixture's 20 ms polling cadence,
detection after publication took 22.38 / 0.35 ms. The shared interval reported one
failure transition, two removed bodies and one removed session. These numbers depend
on the event schedule. The rehearsal also emits this isolated fixture as
`synthetic_wait_vs_poll`, separately from the long capture's own interval reports.

**Errors.** One search and three approved body excerpts provided the control. Independent
JSON decoding identified two 503 groups with counts two and one, identical to the
single audit's counts and examples. The common body varied in JSON formatting and
key order. The rare body differed in a string value. The pair took 4.03 / 1.21 ms.
An additional 18-group fixture retained the only singleton within the 16-example limit
and reported two omitted groups. Separate cases cover invalid JSON, text, a truncated
body and equal raw bodies with different status codes.

The six focused workflow, CLI and catalog checks passed. After reconciling CLI help
with the governed reference, full serial Policy passed with 3,124 passed, 17 skipped
and zero failures. The Debug app build succeeded. The short polling comparison ran
locally. The 60-minute rehearsal and provider-token evaluation remain pending.

### Revision 39 rehearsal — November 17, 2026

The optimized, uninstrumented synthetic loopback rehearsal completed from approximately
09:06 to 10:06 Pacific, with 3,605.22 seconds in the timed loop and 415 cycles.
XCTest passed with zero failures and zero runtime warnings.

The rehearsal now registers a wait before every fourth cycle's block-rule traffic.
All 103 registered waits returned `matched`, observing one new HTTP failure during
each four-response burst. The origin independently confirmed 412 delivered 503s.
All 415 baseline/candidate status-count comparisons were correct.

Every tenth cycle strips bodies, then removes whole sessions, reads an interval
checkpoint and clears history. All 41 exercises preserved session count during
body stripping and subsequently removed sessions. Across 42 interval reports the
ledger reconciled 412 failure transitions, 5,726 body removals and 10,310 whole-session
removals. Clear All invalidated the old checkpoint in every exercised cycle.
There were zero invariant failures. The final cycle finished beyond the nominal
hour so its measurements and final interval were retained.

Checkpoint physical footprint peaked at 96.63 MiB. The origin served 10,615 requests.
Rate-limit pacing accumulated 2,602.44 seconds, about 72.2% of the timed run.
Traffic arrived in repeated concurrent bursts with pacing between investigations.
This validates repeated waits and retention accounting under that workload; a
continuous unpaced forwarding load and a literal 15-minute untouched interval
remain separate cases. Clear/retention exercises close intervals more frequently.

Local evidence is `build/Soak/2026-11-17T170633Z/metrics.jsonl`,
`build/WaitRetentionRehearsal.log` and `build/WaitRetentionRehearsal.xcresult`.
The independent ledger check is
`node evals/edge-release/check-rehearsal.cjs build/Soak/2026-11-17T170633Z/metrics.jsonl`.
The reused build tree is 4.7 GiB and the result bundle 5.3 MiB. Free disk space after
the run was approximately 98 GiB.

The focused dispatcher export `testExportCompactRowModelTrial` passed. BigDog's
packet is `build/BigDog-compact-rows-r39.tar.gz`, SHA-256
`28fdf4c0ea857a43e71848c0dd8b0b522e9a2f5916e52e85bb88b3f26840109f`.
Versioned inputs and commands are in `evals/edge-release/compact-rows/`.
Offline verification passed all four paired page oracles and the grading controls,
including an intentionally wrong answer and missing usage. The worker trial compares
ordinary and compact structured pages in 16 serial calls per model. It measures
interpretation accuracy and provider tokens per exact answer, including incorrect
attempts in total token cost. Real-model execution remains assigned to BigDog.

### BigDog return and future provider choice — November 17, 2026

The maintainer selected AGY for future model evaluations.
BigDog's Qwen run completed all 16 first attempts with zero exact answers.
Every attempt consumed the configured 512 output tokens in thinking without
producing final JSON. Token cost per exact answer is unavailable. This establishes
a completion-budget failure for that configuration; reading accuracy remains
unmeasured in that run.

BigDog subsequently completed an owner-approved AGY Flash Low follow-up using
the same pages, question and alternating order with normal completion settings.
The return archive SHA-256 was verified as
`1298395d7ec70e960a07d3d1df2c85929764df13b8280182aa3102dd77d95c12`.

| Format | Original strict JSON grade | Content grade after outer fence removal | Input tokens | Output tokens | Total tokens | Tokens per content-exact answer |
|---|---:|---:|---:|---:|---:|---:|
| Ordinary | 0/8 | 8/8 | 28,677 | 740 | 29,417 | 3,677.125 |
| Compact | 0/8 | 8/8 | 26,298 | 1,551 | 27,849 | 3,481.125 |

Content grading is a separate post-run analysis. Strict grades remain frozen and
strict tokens per exact answer remain unavailable. Total tokens fell 5.3% over all
content-exact answers. Each 50-row pair fell from 7,685 to 6,560 tokens (14.6%).
Small-page results varied, including increases. These are reported AGY harness
tokens, including session context and reported reasoning. They do not establish a
general saving for every page size.

The worker reported client 1.5.5, requested alias `gemini-3.8-flash-low` and
response alias `gemini-3.8-flash-n`. No immutable backend revision was claimed.
Reports and original evidence reside under the local SharedStatusFile directory
in `joe-big-dog/joesproxy-compact-rows-r39-agy-results.md` and
`joe-big-dog/joesproxy-compact-rows-r39-agy-return.zip`.
Before the next AGY trial, specify whether the intended consumer accepts fenced
JSON and freeze that rubric. Retain original outputs and all attempts.
