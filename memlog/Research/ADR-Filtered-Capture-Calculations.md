# ADR — Filter and calculate capture statistics on the Mac

**Proposed · 2026-11-10.** Initial decision and paired measurement plan. The first slice covers live session metadata in MCP and joesproxyctl.

## Context and decision

A developer asks, “During this checkout test, how many POST requests to this path returned each HTTP status?” Today an agent searches the capture, pages through matching sessions, copies their identifiers into one or more calculations, and combines results. The Mac already has the records, filter predicate and arithmetic. Moving selection into the calculation removes the identifier round trip and the opportunity to miss a page. The current capture calculation accepts up to 256 explicit IDs. [Tool schema](../../JoesProxy/Analysis/ArtifactToolSchema.swift) · [Search predicate](../../JoesProxy/MCP/Capture/MCPSessionSnapshotService.swift) · [CLI](../../JoesProxyCLI/CLIApplication.swift)

Extend the existing capture_calculate tool and capture calculate CLI command. Keep explicit IDs as the existing input. Add a mutually exclusive filter input for sessionMetadata with rowCount and groupCount. Start with grouping by status code. Reuse session search’s method, domain, path and inclusive start-time boundaries with the same matching semantics. The CLI sends the same structured tool call as MCP. Document it in tool discovery and CLI help. The following illustrates the proposed CLI syntax:

    joesproxyctl capture calculate --method POST --path-contains /checkout \
      --started-after 2026-11-10T12:00:00Z --started-before 2026-11-10T12:05:00Z \
      --dataset sessionMetadata --operation groupCount --field-pointer /statusCode

Require both time bounds for the filtered form. Evaluate all authorized matching rows at one capture revision. Reuse the calculation engine’s field semantics and the search service’s predicate. If capture state changes during evaluation, retry against a consistent revision within the work budget or return an explicit retry result. Enforce scan and execution budgets independently of displayed group limits. If a budget prevents a complete count, return a qualified incomplete result. Never present the first page as the population.

Return the applied scope, revision, matched row count, groups, missing-status count and relevant capture-gap qualification. Keep valid zero matches distinct from unavailable history. A display limit may hide groups only if the response accounts for the omitted population. An agent can use the existing search path for supporting records. Do not include session IDs or bodies in the default aggregate. Apply the caller’s disclosure policy before filtering or grouping, including on fields that could reveal protected data through counts. Body-derived calculations retain their existing approval path.

## Alternatives and consequences

Batching existing calls reduces transport overhead but still requires discovery of the IDs before calculating. Increasing page sizes sends more session data to the agent. A local language model could explain results later, but grouping and counting have exact answers and need no model. A single deterministic operation works for scripts and agents alike. Its cost is additional work on the Mac, especially for broad time windows. Measure local latency and scanned rows alongside context savings.

## Paired evaluation

Run the current and proposed workflows against identical, frozen synthetic captures, with the same client profile, filters, output limits and starting context. For the baseline, follow every search cursor, calculate over every eligible ID in supported batches, and combine groups before applying the final display limit. Record an empty search as a valid baseline completion. For the candidate, issue one filtered calculation. Exercise both the authenticated MCP route and the CLI JSON route. Count CLI invocations and underlying MCP calls separately.

| Question or case | Accuracy check |
| --- | --- |
| Count and group a busy checkout window spanning several pages and more than 256 matches | Compare every count to an independently authored fixture manifest with exact expected record membership and status totals. Include an out-of-window error. |
| Sparse window, empty window, boundary timestamps and mixed-case filters | Match existing search semantics, including records exactly on either time boundary. |
| Pending responses, ties and more groups than the display limit | Reconcile matched rows with displayed, omitted and missing-status counts. Use deterministic tie ordering. |
| Capture loss, cleared history, denied fields or exhausted scan budget | Verify the exact qualification or error. Unknown traffic cannot become a measured zero. |
| Sessions complete during a live query | Return one coherent revision or an explicit retry. Run this separately from the frozen cost comparison. |
| User asks to see an example after the aggregate | Include the follow-up search and retrieval costs in both totals. Verify that the example belongs to the reported group and window. |

For each case, retain paired receipts with fixture and revision, expected and actual result, correctness verdict, externally visible calls including retries, request bytes, response bytes, and elapsed time. Count bytes of the serialized messages in both directions at the same boundary. Report setup and tool discovery separately, then include their incremental cost in a cold-session total. For agent trials, fix the model, tokenizer/version, tool catalog and question. Record total input and output tokens across turns, with cached input reported separately where available. Without provider usage, report bytes and any named-tokenizer estimate separately. Compute savings as (baseline minus candidate) divided by baseline, with absolute differences for a zero baseline.

**Adoption gate.** Every deterministic fixture must match its independent oracle, and both interfaces must agree on coverage and errors. A normal filtered calculation must complete in one MCP call. Require lower end-to-end serialized bytes on each multi-page fixture and report sparse-case overhead separately. Claim token savings only at the measurement layer actually tested. Repeat runs and report median and worst latency before choosing default work budgets. An existing repeat-read fixture recorded 12,474 versus 6,266 response bytes across nine calls in each arm, with no provider token counts. It illustrates the distinction and supplies no performance estimate for this proposal. [Existing workflow receipt](Agent-Efficiency-Workflow-v1.json)

## Follow-up decisions

If the first slice passes, reuse its selection and revision semantics to compare two capture windows locally, returning changed groups and supporting references. Evaluate incremental saved queries next for repeated polling, including late session completions and permission changes. For streaming investigations, evaluate correlating advertised HLS resources with observed requests and delivery failures. Each extension needs its own accuracy oracle and paired workflow receipt before promotion.
