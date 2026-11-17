# BigDog evaluation guidance

For future JoesProxy accuracy, routing and token-efficiency comparisons, use AGY.
The maintainer selected AGY after the November 17 compact-row return. Keep the
installed client version, requested model, response alias, effort and completion
settings in each receipt. Use normal completion settings and retain all first
attempts, provider usage and failed answers. Agree on strict JSON versus
fence-tolerant grading before the next trial and preserve both grades if reported.

The compact-row Qwen run spent its entire 512-token output allowance on thinking
in all 16 attempts and produced no final JSON. That run did not establish reading
accuracy. The AGY follow-up recovered correct content in every case but returned
Markdown fences. See the acceptance ledger for its separate strict and content
grades. The existing Ollama configurations below and the hashed revision-39 packet
document the original trials. Prepare the next worker request for AGY.

## Original 1.9.1 (24) routing handoff

**Execution owner:** BigDog coordinator. Run the supplied cases on the existing Qwen model.
If available, delegate the same packet to maxmini for Gemma. Return separate results per model.
The edge candidate adds a seventh question about counts and representative failures; score the
original six separately to preserve historical comparisons.

Run a second evaluation with `evals/skill-routing/edge-arguments.cjs` and a separate output
file. It checks the tool and required arguments for failed endpoints, identical artwork, OCR,
an explicit quarter-image crop, bounded wait and starting a retention interval. Score the
original five separately from the checkpoint, repeated-request and endpoint response-variant questions.
Score the compact response-variant case separately as well. It requires the endpoint anchor and
`compactVariants: true` in the same call.
Track minimal search table routing and capture-wide HTTP error clustering as two additional
cases. Keep their grades separate from the original cohorts. Routing grades do not measure
whether the model correctly interprets returned rows or how many tokens it uses to answer.
This offline trial exercises model routing only. It does not grant body access or call the proxy.

Extract the packet into a fresh directory. From its root, verify the inputs with `shasum -a 256 -c SHA256SUMS`. On the execution worker, set OLLAMA_BASE_URL to the worker's model server and JOESPROXY_EVAL_MODEL to its exact installed tag. The config reads the enclosed candidate efficiency reference by default. For a subsequent installed-app export trial, set JOESPROXY_SKILL_DIR to that exported directory and record its reference hash.

Use the worker’s existing Promptfoo CLI:

    mkdir -p results
    PROMPTFOO_DISABLE_TELEMETRY=1 promptfoo eval -c evals/skill-routing/promptfooconfig.cjs --no-cache --max-concurrency 1 -o results/routing.json

If the worker uses a different inference API, record the provider adapter and retain the same prompts, questions, decoding settings and exact-match assertions. Report any unavailable prerequisites to the coordinator.

Return the model tag and digest if available, runtime and Promptfoo versions, input hashes, per-case expected and actual tool names, accuracy and denominator per arm, latency and provider-reported input/output tokens when available. Include failures and missing usage. Compare the unaided arm against the efficiency-reference arm on the same model. Preserve the raw JSON receipt. A higher routing score measures tool selection. Savings claims require a separate paired end-to-end execution with equivalent answers and usage receipts.
