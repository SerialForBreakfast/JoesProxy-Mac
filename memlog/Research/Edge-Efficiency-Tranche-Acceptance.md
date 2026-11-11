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
