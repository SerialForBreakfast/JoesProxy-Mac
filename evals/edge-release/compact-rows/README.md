# BigDog request — compact search rows

Measure whether the same installed Qwen model answers accurately from ordinary and
compact JoesProxy search results, and how many provider-reported tokens it spends per
correct answer. This is a fixed-evidence interpretation trial. No live proxy, browsing,
tool selection, credentials, dependency installation or training is required. Use a
worker with Node 20+ and the existing Ollama server. Use Gemma only as a separate run.

## Inputs and controls

`pages.json` contains four paired synthetic pages exported by the revision 39 MCP
dispatcher. Two are empty/single-row fallback controls. The other two are the first
50 and last four rows of one paginated search. A missing status, rare HTTP failures
and body-retention warnings test column alignment and evidence preservation. Inputs
are the decoded, structured page payloads a client would pass to a model. Network
framing, CLI formatting, discovery and a duplicate MCP text fallback are excluded.
The runner sends only the page and a fixed question. The expected answer stays in the
local grader. The trial does not estimate end-to-end agent cost.

Run each pair twice in fresh conversations. Arm order alternates and reverses in the
second round. This gives 16 serial calls per model. Use one installed model digest
and the supplied settings for the whole run. Keep all answers, including malformed
JSON, wrong IDs, wrong order, extra keys and incomplete generations. No automatic
retries or replacement attempts. Provider errors stop the run and retain the receipt.

## Worker commands

Extract the packet into an empty directory. Set `OLLAMA_BASE_URL` to the worker's
existing server and `JOESPROXY_EVAL_MODEL` to its exact installed tag.

```sh
shasum -a 256 -c SHA256SUMS
node trial.cjs verify pages.json
node trial.cjs run pages.json attempts.jsonl > summary.json
```

The runner refuses to overwrite an attempts file. If interrupted, keep it and score
the partial run with `node trial.cjs score pages.json attempts.jsonl > partial.json`.
Return the original attempts, summary (or partial summary), packet hash, worker model
digest, Ollama version and any context or provider errors. Never combine models.

## Reading the result

Report exact answers over **all** attempts for each arm. Tokens per correct answer
is the sum of input and generation tokens on all attempts in that arm divided by its
exact answer count. Zero successes or missing usage yields an unavailable metric.
Report raw input/output counts and paired reductions separately for pairs where both
arms were exact. Inspect the 50-row and four-row results separately from the fallback
controls. Two rounds per case give a diagnostic result, not a population estimate.

The source fixture lives in `MCPEdgeWorkflowTests.swift`, test
`testExportCompactRowModelTrial`. For a new build the maintainer runs that focused
Policy test with `TEST_RUNNER_JOESPROXY_EXPORT_COMPACT_TRIAL=1` and uses its
`build/compact-row-pages.json` as the packet's `pages.json`.
