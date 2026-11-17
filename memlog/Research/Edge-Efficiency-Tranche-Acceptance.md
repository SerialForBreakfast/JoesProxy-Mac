# Edge efficiency tranche acceptance plan

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
| A session whose response the proxy synthesized as a 502 is recorded with no status code, so `groupCount` on `/statusCode` reports it under `missing`, not `502` or a failure bucket; the agent sees a count but no reason | Evidence gap | Open. Seen in all five overnight windows where a 502 landed inside the measured window |
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
