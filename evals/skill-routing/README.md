# BigDog request — JoesProxy 1.9.1 (24) skill routing

**Execution owner:** BigDog coordinator. Run the supplied cases on the existing Qwen model.
If available, delegate the same packet to maxmini for Gemma. Return separate results per model.
The edge candidate adds a seventh question about counts and representative failures; score the
original six separately to preserve historical comparisons.

Run a second evaluation with `evals/skill-routing/edge-arguments.cjs` and a separate output
file. It checks the tool and required arguments for failed endpoints, identical artwork, OCR,
an explicit quarter-image crop and bounded wait. Score these five questions separately.
This offline trial exercises model routing only. It does not grant body access or call the proxy.

Extract the packet into a fresh directory. From its root, verify the inputs with `shasum -a 256 -c SHA256SUMS`. On the execution worker, set OLLAMA_BASE_URL to the worker's model server and JOESPROXY_EVAL_MODEL to its exact installed tag. The config reads the enclosed candidate efficiency reference by default. For a subsequent installed-app export trial, set JOESPROXY_SKILL_DIR to that exported directory and record its reference hash.

Use the worker’s existing Promptfoo CLI:

    mkdir -p results
    PROMPTFOO_DISABLE_TELEMETRY=1 promptfoo eval -c evals/skill-routing/promptfooconfig.cjs --no-cache --max-concurrency 1 -o results/routing.json

If the worker uses a different inference API, record the provider adapter and retain the same prompts, questions, decoding settings and exact-match assertions. Report any unavailable prerequisites to the coordinator.

Return the model tag and digest if available, runtime and Promptfoo versions, input hashes, per-case expected and actual tool names, accuracy and denominator per arm, latency and provider-reported input/output tokens when available. Include failures and missing usage. Compare the unaided arm against the efficiency-reference arm on the same model. Preserve the raw JSON receipt. A higher routing score measures tool selection. Savings claims require a separate paired end-to-end execution with equivalent answers and usage receipts.
