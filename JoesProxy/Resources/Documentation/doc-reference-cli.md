# CLI command reference

## Scope {#safety}

Generated from CLIApplication.help. These are parameterized syntax examples, not permission to execute. Replace placeholders with explicitly reviewed values. Offline docs require no credentials; live commands retain authentication, disclosure and approval boundaries.

### Local calculations and saved sources

Local calculations and saved sources arrived in capabilities revision 26. Inventory and exact
search require revision 27 and a locally reviewed search grant. Check the running app before use.

```text
joesproxyctl capture calculate --session-ids <id,id> --dataset sessionMetadata --operation groupCount --field-pointer /statusCode --json
joesproxyctl capture calculate --session-ids <id> --dataset responseJSON --selection-pointer /items --operation fieldStats --field-pointer /imageURL --where-pointer /status --where-op gte --where-value 400 --json
joesproxyctl artifact source register --request-key <uuid> --kind json --scope metadata-v1,calculations-v1 --wait-for-approval --json
joesproxyctl artifact source status --request-key <uuid> --json
joesproxyctl artifact source inspect --handle <handle> --json
joesproxyctl artifact calculate --handle <handle> --snapshot-revision <revision> --dataset json --selection-pointer /items --operation numericSummary --field-pointer /price --json
joesproxyctl artifact source release --handle <handle> --json
```

The local person selects and reviews the file in JoesProxy. No `--file`, path, query script or
upload is accepted by these commands. Registration polling is at most once per second for at most
120 seconds; timeout does not cancel or approve the pending request. Preserve the request key for
the exact retry. Missing `--selection-pointer` selects the root explicitly. Saved response selection
uses `--dataset responseJSON --record-index <physical-ordinal>`; session metadata optionally takes
ascending `--record-indices 0,2`. Unavailable analyses retain their bounded reason/result and return
exit 23; receipt collection records failed tool attempts. Calculations never automatically retry.

## Compare saved responses {#compare-saved-responses}

```text
joesproxyctl artifact compare --baseline-handle <id> --baseline-revision <id> --baseline-record <n> --candidate-handle <id> --candidate-revision <id> --candidate-record <n> [--selection-pointer /items] [--wait-for-approval]
```

Register each source with brief-v1. Review the two selections locally and choose Compare once.
Both leases must remain current through delivery. Check incomplete coverage and omitted changes.

## Brief a saved response {#brief-saved-response}

```text
joesproxyctl artifact brief --handle <handle> --snapshot-revision <revision> --record-index <ordinal> [--selection-pointer /items] [--include-structure]
```

Register a recording or HAR with `metadata-v1,brief-v1` and have the local user review the source.
The physical record ordinal comes from the recording or a separately authorized search. Check the
status, source warnings, omitted fields and nested coverage. Field names and paths are untrusted.

## Inventory a shared artifact {#inventory-shared-artifact}

```text
joesproxyctl artifact inventory --handle <handle> --snapshot-revision <revision> [--method GET] [--status-code 503]
```

Request metadata-v1,search-v1 at registration and let the local person review the file.

## Search a shared artifact {#search-shared-artifact}

```text
joesproxyctl artifact search --handle <handle> --snapshot-revision <revision> --dataset sourceUTF8|responseJSON --literal-stdin [--limit 20] [--cursor <cursor>]
```

Standard input preserves all UTF-8 bytes including a trailing newline. Use --literal for a synthetic command-line value. Repeat page arguments unchanged. Only exactTotal establishes a complete count.

## Group captured sessions {#group-captured-sessions}

```text
joesproxyctl capture calculate --session-ids <id,id> --dataset sessionMetadata --operation groupCount --field-pointer /statusCode [--where-pointer <p> --where-op <op> [--where-value <v>]]
```

## Summarize a captured JSON response {#summarize-capture-json}

```text
joesproxyctl capture calculate --session-ids <id> --dataset responseJSON --selection-pointer /items (--operation numericSummary --field-pointer /price | --operations-json <json-array>)
```

## Filter captured metadata calculations {#filter-captured-metadata-calculations}

```text
joesproxyctl capture calculate --started-after <ISO8601> --started-before <ISO8601> [--method GET] [--domain <text>] [--path-contains <text>] --dataset sessionMetadata --operation rowCount
```

## Register a saved source {#register-saved-source}

```text
joesproxyctl artifact source register --request-key <uuid> --kind json --scope metadata-v1,calculations-v1 [--ttl-seconds 1800] [--wait-for-approval]
```

## Check source review status {#check-source-review}

```text
joesproxyctl artifact source status --request-key <uuid>
```

## Inspect a shared source {#inspect-shared-source}

```text
joesproxyctl artifact source inspect --handle <handle>
```

## Release a shared source {#release-shared-source}

```text
joesproxyctl artifact source release --handle <handle>
```

## Calculate on a saved source {#calculate-saved-source}

```text
joesproxyctl artifact calculate --handle <handle> --snapshot-revision <revision> --dataset json --selection-pointer /items (--operation rowCount | --operations-json <json-array>)
```


## Command 1 {#command-6fa8bab16154b034}

```text
joesproxyctl docs list --format markdown|json
```

## Command 2 {#command-310d88f5e4b5952a}

```text
joesproxyctl docs search --query "missing body" --format markdown|json
```

## Offline workflow report {#efficiency-report}

```text
joesproxyctl efficiency report --file <workflow.json> [--json]
```

Local-only receipt arithmetic: no credentials, app launch, network, price lookup or file output.
Reads one regular local JSON file, at most 1 MiB. Schema version 1 has `baseline` and `candidate`.
Each contains `context` (fixture, version, environment, measurementLayer strings), and 1–1000
`attempts`: id, operation, outcome (success/failure), responseBytes, analysisExecutions, optional
retryOf (an earlier attempt ID), optional latencyMilliseconds. IDs are unique per workflow.
All attempts count, including failures/retries. Context strings and IDs are bounded to 128 UTF-8 bytes.
Metrics are nonnegative; byte/token/cost integers are bounded to 10^12, analyses to 1000 per attempt,
latency to one day. Context mismatch or any failed attempt suppresses comparative deltas.

Optional `providerUsage` is a list of up to 1000 supplied receipts: receiptID, model, inputTokens,
outputTokens, optional reportedCostMicros and currency (three uppercase letters, required together).
Omitted/null usage means unknown; an explicit empty list declares no provider calls. Missing costs
or mixed currencies produce null total cost. Costs are supplied actual receipts, never estimates.
Tokens are never derived from bytes. Latency total requires every sample; p50/p95 use nearest rank
over supplied samples and are trend-only. Input SHA-256 and declared contexts accompany the report.
Provider deltas require matching model sets; cost deltas additionally require complete matching
currencies. Otherwise those comparisons remain null. Output totals cannot establish that omitted
attempts did
not exist or that workflows are semantically equivalent. Review receipt provenance separately.

## Compare exported receipts {#efficiency-compare}

```text
joesproxyctl efficiency compare --baseline-receipt <file> --candidate-receipt <file> [--json]
```

Finite network commands can opt into a new local file with `--receipt-output <file>` plus
`--receipt-workflow <synthetic-label> --receipt-version <version> --receipt-environment <label>`.
Choose content-free labels (1–128 UTF-8 bytes); no automatic collection or extra MCP calls occurs.
The destination must not exist; parent folders must already exist. Export failure emits a warning
without retrying or changing the original operation's exit status. Streaming watch is unsupported.
Receipt schema 2 records HTTP response-body bytes (not headers or wire framing), elapsed time,
transport/RPC success/failure and explicit stale-session/approved retries including handshake and
approval-poll attempts. This does not verify the business outcome. Transport failures
with unavailable bytes retain null; server analysis counts remain unknown except explicit reuse (zero).
Available reuse signals are retained. Arguments, endpoints, bodies, credentials and prompts are never
retained. Provider usage remains unknown. Up to 1000 attempts fit; omitted attempts are counted and
such receipts are rejected for comparison. An interrupted process cannot guarantee file delivery.
This offline comparison feeds both exported workflows into the same `efficiency report` arithmetic.
Schema 2 report inputs permit unknown response bytes/analysis counts; their totals and deltas remain
null. Schema 1 remains strict. Context and failure qualifications still apply. One CLI invocation
is one workflow receipt; choose equivalent finite investigations, not unrelated operations.

## Command 3 {#command-94429786ea8b3d7e}

```text
joesproxyctl docs read --topic requestInspector --section context --format markdown|json
```

## Command 4 {#command-00477db421c3596c}

```text
joesproxyctl auth login|status|logout
```

## Command 5 {#command-5e7b80b2471b3c46}

```text
joesproxyctl doctor [--json]
```

## Command 6 {#command-db573271ec62b75f}

```text
joesproxyctl setup guide --format markdown|json
```

## Command 7 {#command-9d15028fd11d6a72}

```text
joesproxyctl integrations list [--json]
```

## Command 8 {#command-90f953dd2ecbaafe}

```text
joesproxyctl integrations show tvtestrig|viewlens|instruments
```

## Command 9 {#command-db0622b964b731fd}

```text
joesproxyctl integrations recipe truncation-audit [--target-url <url>] [--field <name>]
```

## Command 10 {#command-517ef6d1726fd1d2}

```text
joesproxyctl app launch [-- <app launch arguments>]
```

## Command 11 {#command-644fc8c79d17f78f}

```text
joesproxyctl mcp start [-- <app launch arguments>] | wait | stop
```

## Command 12 {#command-11335a88ac366163}

```text
joesproxyctl proxy start|stop
```

## Command 13 {#command-87542fcbb56caf24}

```text
joesproxyctl status
```

## Command 14 {#command-ce48113f46b1ac4e}

```text
joesproxyctl toolset status
```

## Command 15 {#command-96cf56283f03e050}

```text
joesproxyctl toolset select --name core|capture|mocking|media|reproduction|advanced|all
```

## Command 16 {#command-12448048014aa6a4}

```text
joesproxyctl capture digest
```

## Command 17 {#command-7a1396581bcfc3e0}

```text
joesproxyctl capture status
```

## Command 18 {#command-6be1bce72886cc72}

```text
joesproxyctl https rules get --host media.example.test [--recovery-id <uuid>]
```

## Command 19 {#command-e538cdc9766b170e}

```text
joesproxyctl https rules set --host media.example.test --mode tunnel|inspect|remove --expected-revision <revision> --scope host_and_subdomains_all_clients [--recovery-id <uuid>] [--wait-for-approval]
```

## Command 20 {#command-1b76fdf7f5f30df0}

```text
joesproxyctl https rules restore --host media.example.test --recovery-id <uuid> --expected-revision <revision> --scope host_and_subdomains_all_clients [--wait-for-approval]
```

## Command 21 {#command-f3ad265719b85eb6}

```text
joesproxyctl capture resume [--wait-for-approval]
```

## Command 22 {#command-7611a081785f62f5}

```text
joesproxyctl cache audit
```

## Command 23 {#command-2ea08d0f9f1813d5}

```text
joesproxyctl investigate snapshot [--limit <1...25>] [--since-sequence <n>] [--if-state-token <token>]
```

## Command 24 {#command-c5b28716a332873d}

```text
joesproxyctl evidence get <evidence-ref>
```

## Command 25 {#command-98274ec5cb850592}

```text
joesproxyctl read batch --file <requests.json>
```

## Command 26 {#command-2180e48755dc13ef}

```text
joesproxyctl capture rolling-status
```

## Command 27 {#command-919c872bd3b0a508}

```text
joesproxyctl capture restore-rolling
```

## Command 28 {#command-eecad8c6ade693f9}

```text
joesproxyctl capture marker --name <marker-name> [--detail <text>] [--label <text>]
```

## Command 29 {#command-3f35b82ad87b90f8}

```text
joesproxyctl capture activity (--since-marker <session-id> | --since-sequence <n>) [--rule <override-id>] [--limit <n>]
```

## Command 30 {#command-b47b63e47b882fc7}

```text
joesproxyctl sessions list|search [filters] [--status-code <n>] [--status-class 2xx|3xx|4xx|5xx|error|non200] [--min-duration-ms <ms>] [--has-override-hit|--no-override-hit] [--body-available|--no-body-available] [--deduplicate-by endpoint] [--include-auth-chain]
```

## Command 31 {#command-1d391102ffe95d92}

```text
joesproxyctl device list
```

## Command 32 {#command-50bd8bc59fb4a14c}

```text
joesproxyctl device alias <ip-address> (--name <friendly-name> | --clear)
```

## Command 33 {#command-297aea8d6f7e5b0e}

```text
joesproxyctl session show <session-id>
```

## Response evidence brief {#response-evidence-brief}

Revision 2026-11-05: next-development command. Discover support from the running build.

```text
joesproxyctl session brief <session-id> [--selection-pointer /items] [--include-structure] [--field-pointers /p1,/p2] [--row-limit <1...50>]
```

Runs `response_evidence_brief` with existing body-read approval. No scalar values are returned
unless `--field-pointers` is specified for compact tabular projection with sensitive-key redaction.
Inspect status, coverage and omittedFieldCount before using counts; missing fields are relative
to object items only. Complete JSON input is bounded to 256 KiB; partial bodies are not analyzed.
Nested structure is opt-in and has separate coverage/limit reporting. Ordinary raw excerpts
retain their 64 KiB bound.
For routine investigations select `joesproxyctl toolset select core` first, then a task-specific
toolset as needed. Existing discovery defaults and permissions are unchanged.

## Investigation comparison brief {#investigation-compare-brief}

```text
joesproxyctl investigate compare --baseline-sessions <id,id> --candidate-sessions <id,id> [--selection-pointer /items] [--include-value-diff] [--ignore-pointers /p1,/p2]
```

Revision 2026-11-05: compares explicit retained selections with existing structural metadata and
body-read authority. Requires 1–16 distinct IDs per side. Check status, source analysisStatus,
structureComparison and omittedChangeCount. Limits and missing sources remain incomplete.
No raw scalar values, target-outcome inference or cleanup assertion. Use discovered schemas
and the existing approval workflow; agents cannot approve their own analysis requests.

## Command 34 {#command-02fd4240a3970b2f}

```text
joesproxyctl media readiness|summary|manifest|related <session-id>
```

## Command 35 {#command-cb21514bd2a93032}

```text
joesproxyctl response context|search|read <session-id>
```

## Command 36 {#command-7f0eb2a6cfc62da8}

```text
joesproxyctl response edit preview <session-id> --edits <json-file>
```

## Command 37 {#command-6f79b4c1c3e76dea}

```text
joesproxyctl response draft save <session-id> [--label <label>]
```

## Command 38 {#command-549b735c6b463ed4}

```text
joesproxyctl response draft apply-save <proposal-token>
```

## Command 39 {#command-48902b7159402760}

```text
joesproxyctl response draft list|get <draft-id>
```

## Command 40 {#command-4350fe6f4cc71205}

```text
joesproxyctl response edit commit --draft <draft-id> --preview-digest <digest>
```

## Command 41 {#command-d104b9d1b5873d09}

```text
joesproxyctl response edit apply-commit <proposal-token>
```

## Command 42 {#command-26586c884feee005}

```text
joesproxyctl response map-local prepare (--preview-digest <digest> | --revision <revision-id> |
```

## Command 43 {#command-89e2953ea19efb84}

```text
joesproxyctl response map-local apply <proposal-token> [--enable-after] [--wait-for-approval]
```

## Command 44 {#command-7dde644effaca3e8}

```text
joesproxyctl rule list [--limit <n>] [--cursor <token>] [--projection minimal|summary|full] [--source-kind <kind>]
```

## Command 45 {#command-226bd4780f02ea4d}

```text
joesproxyctl rule get <override-id>
```

## Command 46 {#command-555952162b1e5c12}

```text
joesproxyctl rule enable|disable|delete <override-id>
```

## Command 47 {#command-17eb57f5800a22eb}

```text
joesproxyctl rule apply-enable|apply-disable|apply-delete <proposal-token>
```

## Command 48 {#command-7ff7b95f943bef87}

```text
joesproxyctl hls codecs context|preview <session-id>
```

## Command 49 {#command-1b4301eced498219}

```text
joesproxyctl hls codecs prepare-map-local --preview-digest <digest> [--idempotency-key <key>]
```

## Command 50 {#command-846cfcf1d58f3ed4}

```text
joesproxyctl hls codecs apply-map-local <proposal-token> [--wait-for-approval] [--idempotency-key <key>]
```

## Command 51 {#command-8f3e317006ca5285}

```text
joesproxyctl hls fixture capabilities|profiles|status
```

## Command 52 {#command-ef3fccf6bb66265f}

```text
joesproxyctl hls fixture window-preview --run-id <uuid> --path <rendition/stream.m3u8> [--at <seconds>]
```

## Command 53 {#command-f87d6e6b844f4c80}

```text
joesproxyctl hls fixture prepare-start --profile-id <id> [--presentation-mode vodStatic|liveLoop]
```

## Command 54 {#command-f8061c0444a4716d}

```text
joesproxyctl hls fixture apply-start <proposal-token> [--wait-for-approval]
```

## Command 55 {#command-32488c43aabf57f0}

```text
joesproxyctl hls fixture stop <run-id> | --run-id <uuid>
```

## Command 56 {#command-08b40d7d399e756f}

```text
joesproxyctl hls substitute profiles
```

## Command 57 {#command-2031f2d3690979da}

```text
joesproxyctl hls substitute prepare --profile-id <id> --scope selected|host
```

## Command 58 {#command-6397742c8cc76470}

```text
joesproxyctl hls substitute apply <proposal-token> [--wait-for-approval]
```

## Command 59 {#command-8324d303c93242d2}

```text
joesproxyctl hls substitute status [<experiment-id> | --experiment-id <uuid>]
```

## Command 60 {#command-5eb00bf993575949}

```text
joesproxyctl hls substitute stop <experiment-id>
```

## Command 61 {#command-2d5bab1520494611}

```text
joesproxyctl hls substitute extend <experiment-id> [--ttl <seconds>]
```

## Command 62 {#command-190da831636af177}

```text
joesproxyctl openapi pack import --file <path> [--host <host>] [--scheme http|https] [--port <n>] [--ttl <seconds>]
```

## Command 63 {#command-3b6e57113bd2c080}

```text
joesproxyctl openapi pack prepare --file <path> --host <host> [--scheme http|https] [--port <n>] [--ttl <seconds>] [--replace-conflicts]
```

## Command 64 {#command-aae12fe71c0901f1}

```text
joesproxyctl openapi pack apply <proposal-token> [--wait-for-approval]
```

## Command 65 {#command-00258eb9fdd6a012}

```text
joesproxyctl openapi pack status [<pack-id> | --pack-id <uuid>]
```

## Command 66 {#command-43a180115d0c562e}

```text
joesproxyctl openapi pack stop <pack-id>
```

## Command 67 {#command-e9915dee6fd4c897}

```text
joesproxyctl openapi import --file <path>
```

## Command 68 {#command-d19ab993a63679c1}

```text
joesproxyctl openapi validate <session-id>
```

## Command 69 {#command-fb4bcaac391141c3}

```text
joesproxyctl openapi mock --path <template> [--method <GET|POST>] [--status <code>] [--mode validDefault|boundaryEdge|nullFields|emptyCollections]
```

## Command 70 {#command-85c57308c11496ef}

```text
joesproxyctl run list [--limit <n>]
```

## Command 71 {#command-f51ccf25acd20dc2}

```text
joesproxyctl run create --hypothesis <text> --expected <text>
```

## Command 72 {#command-da58cd53dba0e279}

```text
joesproxyctl run start <run-id>
```

## Command 73 {#command-c244310e14f0c548}

```text
joesproxyctl run status <run-id>
```

## Run brief {#run-brief}

```text
joesproxyctl run brief <run-id> --baseline-window-id <UUID> --modified-window-id <UUID> [--if-brief-digest <digest>]
```

## Command 74 {#command-2fd2cd4cf5098f4b}

```text
joesproxyctl run observations <run-id> [--limit <n>]
```

## Command 75 {#command-4f0f5ee75f8b0c90}

```text
joesproxyctl run close <run-id> --terminal passed|failed|inconclusive|expired
```

## Command 76 {#command-6e2977561c410726}

```text
joesproxyctl run retry-cleanup <run-id>
```

## Command 77 {#command-5810589e2991c6fb}

```text
joesproxyctl run evidence list
```

## Command 78 {#command-c3805c8eee5febbd}

```text
joesproxyctl run evidence get <evidence-id>
```

## Command 79 {#command-31727ed931b5e62a}

```text
joesproxyctl run recheck prepare --evidence-id <uuid>
```

## Command 80 {#command-e1fc2c0e3a917120}

```text
joesproxyctl run recheck apply <proposal-token> [--wait-for-approval]
```

## Command 81 {#command-dc9625e3cf45f83e}

```text
joesproxyctl block prepare --method <verb> --host <host> --path <path>
```

## Command 82 {#command-6ed97986245b5f00}

```text
joesproxyctl block apply <proposal-token> [--enable-after] [--wait-for-approval]
```

## Command 83 {#command-17e644f7549492d8}

```text
joesproxyctl bookmark create --method <verb> --host <host> --path <path> --name <name>
```

## Command 84 {#command-7eddb5e8de011d01}

```text
joesproxyctl bookmark apply <proposal-token> [--wait-for-approval]
```

## Command 85 {#command-372bb95a46013a22}

```text
joesproxyctl bookmark list [--limit <n>] [--cursor <token>] [--projection minimal|summary|full]
```

## Command 86 {#command-cece46add557a8b0}

```text
joesproxyctl bookmark get <bookmark-id>
```

## Command 87 {#command-eb02b691ed3de3ec}

```text
joesproxyctl throttle prepare [--preset-id mobile-3g|56k-modem|isdn|t1|mobile-lte|custom]
```

## Command 88 {#command-28f4847dcc95a3ee}

```text
joesproxyctl throttle apply <proposal-token> [--wait-for-approval]
```

## Command 89 {#command-0080b8c0a163e430}

```text
joesproxyctl throttle disable [--wait-for-approval]
```

## Command 90 {#command-a998f829c3370d2d}

```text
joesproxyctl media inspect <session-id> --analysis <kind[,kind]>
```

## Command 91 {#command-6685f085b0595d2c}

```text
joesproxyctl operation status|cancel <operation-id>
```

## Command 92 {#command-ef6e2cbffa96b40e}

```text
joesproxyctl rewrite preview|prepare <session-id> [rewrite options]
```

## Command 93 {#command-7cec5af1afb6ec57}

```text
joesproxyctl rewrite apply|activate <proposal-token-or-override-id>
```

## Command 94 {#command-e6e933f66d97350c}

```text
joesproxyctl rewrite disable prepare <override-id>
```

## Command 95 {#command-651afd91260347ef}

```text
joesproxyctl rewrite disable apply <proposal-token>
```

## Command 96 {#command-40f1c7ec18381485}

```text
joesproxyctl collection-mock preview|prepare <session-id> [collection-mock options]
```

## Command 97 {#command-bec9d4363017f08a}

```text
joesproxyctl collection-mock apply|activate <proposal-token-or-override-id>
```

## Command 98 {#command-19c7e89d5ed63a25}

```text
joesproxyctl scenario preview|draft --input <json-file>
```

## Command 99 {#command-6bfb7c7a05416ae6}

```text
joesproxyctl scenario validate|approve|arm|activate <scenario-id>
```

## Command 100 {#command-36e36625508c1cf2}

```text
joesproxyctl scenario observe|assert|report <scenario-id>
```

## Command 101 {#command-b770ccf96666735f}

```text
joesproxyctl scenario stop|cleanup <scenario-id> [--outcome <phase>]
```

## Command 102 {#command-20b7d5b1d844e783}

```text
joesproxyctl certificate status|identity
```

## Command 103 {#command-edfa860e1ba32bba}

```text
joesproxyctl certificate export --output <path>
```

## Command 104 {#command-b9a56adf1d099358}

```text
joesproxyctl certificate artifacts list [--fingerprint <sha256>]
```

## Command 105 {#command-7c1e00cda90c85b0}

```text
joesproxyctl certificate compare --fingerprint <sha256> --other-fingerprint <sha256>
```

## Command 106 {#command-3eaaf23502c27066}

```text
joesproxyctl certificate cleanup prepare --fingerprint <sha256> [--allow-current-root]
```

## Command 107 {#command-7395151fa2e6b2c9}

```text
joesproxyctl certificate cleanup apply --proposal-token <token>
```

## Command 108 {#command-d8770269d474fff5}

```text
joesproxyctl watch capture
```

## Command 109 {#command-e49cd86c01280623}

```text
joesproxyctl watch sessions [--since-sequence <n>] [--ndjson]
```

## Command 110 {#command-b4a1d7036d0db877}

```text
joesproxyctl wait capture|session|operation [id]
```

## Command 111 {#command-0e9b675eda89aae7}

```text
joesproxyctl sessions export --format json|ndjson|har [--output path]
```

## Command 112 {#command-4ef671754bb7ae15}

```text
joesproxyctl repro export --output <package.jproxy-repro> [--name <title>] [--detail <notes>]
```

## Command 113 {#command-f3abdfc79f00f3cd}

```text
joesproxyctl repro inspect --file <package.jproxy-repro>
```

## Command 114 {#command-48f4c078cc7c87d2}

```text
joesproxyctl repro replay --file <package.jproxy-repro> [--session-id <package-session-id>]
```

## Command 115 {#command-f3073b8aecc38ca9}

```text
joesproxyctl cleanup status
```

## Command 116 {#command-9779311914e0b302}

```text
joesproxyctl approvals list
```

## Command 117 {#command-73ece925468b632e}

```text
joesproxyctl session end
```

## Command 118 {#command-50ccd457f7a26ec4}

```text
joesproxyctl hypothesis propose --name <text> --target-bug <text> --nodes <json-file>
```

## Command 119 {#command-aa509d6163ba49f6}

```text
joesproxyctl hypothesis step --graph-id <uuid> [--evidence-matches] --evidence-summary <text>
```

## Command 120 {#command-84faf8787f32b385}

```text
joesproxyctl hypothesis report --graph-id <uuid>
```

## Command 121 {#command-d75993eeebca4585}

```text
joesproxyctl llm stream inspect [--session-ids <id,id,...>] [--canaries <s1,s2,...>]
```

## Command 122 {#command-320271c761a65997}

```text
joesproxyctl llm stream fault propose --name <text> --url-pattern <pattern> --fault-kind <kind>
```

## Command 123 {#command-3f6d4641c7ebf727}

```text
joesproxyctl fuzz permutation propose --name <text> --target-batch <text> --endpoints <json-file>
```

## Command 124 {#command-ef8df26b6c8bf5d0}

```text
joesproxyctl fuzz permutation step --plan-id <uuid> [--error-detected] --outcome-summary <text>
```

## Command 125 {#command-f7ba9b348991ec58}

```text
joesproxyctl fuzz permutation report --plan-id <uuid>
```

## Command 126 {#command-52c964d7d82a7ada}

```text
joesproxyctl resilience propose --session-id <uuid> [--name <text>]
```

## Command 127 {#command-1958a1e7bb0cc081}

```text
joesproxyctl resilience step --plan-id <uuid> [--client-crashed] [--observed-error <text>]
```

## Command 128 {#command-2326e03e0aa4ecd6}

```text
joesproxyctl resilience report --plan-id <uuid>
```

## Command 129 {#command-92c872e179d321f3}

```text
joesproxyctl trajectory diff --baseline-sessions <id,id> --candidate-sessions <id,id>
```

## Command 130 {#command-34be2617fd9e13e5}

```text
joesproxyctl semantic mock propose --name <text> --url-pattern <pattern> --intent-label <text>
```

## Command 131 {#command-37a319bb7e548a7a}

```text
joesproxyctl semantic mock list|test|delete
```

## Command 132 {#command-1b809a7befb4dc6e}

```text
joesproxyctl contract diff --live-session <uuid> --baseline-session <uuid>
```

## Command 133 {#command-ab831c126ad686bc}

```text
joesproxyctl contract regression --live-sessions <id,id> --baseline-sessions <id,id>
```

## Command 134 {#command-2f357ea87d7b3935}

```text
joesproxyctl lineage trace (--target-value <text> | --auth-chain) [--candidate-sessions <id,id>]
```

## Command 135 {#command-a8fc5c2a81776f14}

```text
joesproxyctl lineage attribution --sink-session <uuid> [--candidate-sessions <id,id>]
```

## Command 136 {#command-e974c9753527bf77}

```text
joesproxyctl lineage watermark propose --name <text> --url-pattern <pattern> --strategy <text>
```

## Command 137 {#command-bd6be76eb9d67dee}

```text
joesproxyctl localization presets
```

## Command 138 {#command-978ea123b381f46a}

```text
joesproxyctl localization preview --session-id <uuid> --preset-id <id>
```

## Command 139 {#command-99586db1d349c5bd}

```text
joesproxyctl stateful backends|presets
```

## Command 140 {#command-f5c3f1bac0739948}

```text
joesproxyctl stateful install --preset-id <id> [--custom-host <host>]
```

## Command 141 {#command-0a1f872303b22e4c}

```text
joesproxyctl stateful set-state --backend-id <uuid> --state <name>
```

## Command 142 {#command-889d508d48554005}

```text
joesproxyctl stateful entities --backend-id <uuid> --collection <name>
```

## Command 143 {#command-59707e618e9bfcff}

```text
joesproxyctl stateful reset --backend-id <uuid>
```

## Command 144 {#command-f2872f279123482f}

```text
joesproxyctl isolate start --session-id <uuid> [--window-seconds <n>]
```

## Command 145 {#command-77ffa2024e7aebeb}

```text
joesproxyctl isolate step --outcome crashed|failed_assertion|succeeded|empty|unknown
```

## Command 146 {#command-4d0fb8717a7f6423}

```text
joesproxyctl isolate report|cancel
```

## Command 147 {#command-dc198832dc1667ca}

```text
joesproxyctl media cmcd --session-ids <id,id,...>
```

## Command 148 {#command-a23e30f370799b55}

```text
joesproxyctl media webvtt --session-id <uuid> [--reference-session <uuid>]
```

## Command 149 {#command-20ced646a56d66af}

```text
joesproxyctl media drm [--manifest-session <uuid>] [--license-sessions <id,id>]
```

## Command 150 {#command-f739579c116e2b14}

```text
joesproxyctl media byte-range [--session-ids <id,id,...>]
```

## Command 151 {#command-d81642dce432c4ad}

```text
joesproxyctl media waterfall --session-id <uuid>
```

## Command 152 {#command-9926ff1583f68c23}

```text
joesproxyctl media visual --session-id <uuid>
```

## Command 153 {#command-509f32c08b5ce56b}

```text
joesproxyctl media scte35 --master-session <uuid> [--variant-sessions <id,id>]
```

## Command 154 {#command-580206d0400629bb}

```text
joesproxyctl synthetic assets
```

## Command 155 {#command-7e422f4ee922a2fd}

```text
joesproxyctl synthetic inject --name <text> --url-pattern <pattern>
```

## Command 156 {#command-f3dbc28e0d8d8ef7}

```text
joesproxyctl synthetic plans
```

## Command 157 {#command-d96aa1c8db95e3b0}

```text
joesproxyctl synthetic remove --plan-id <uuid>
```

## Command 158 {#command-8a96aea8ec793ed5}

```text
joesproxyctl instruments templates
```

## Command 159 {#command-dc531113352a88df}

```text
joesproxyctl instruments record [--template <name>] [--process <target>] [--duration <sec>]
```

## Command 160 {#command-2df1b278d073ff1f}

```text
joesproxyctl instruments analyze --trace <path> [--template <name>]
```

## Command 161 {#command-94177ee505bf3c11}

```text
joesproxyctl instruments audit [--process <target>] [--template <name>] [--duration <sec>] [--trace <path>]
```

## Command 162 {#command-18c43b22b4db8201}

```text
joesproxyctl effect bundle list
```

## Command 163 {#command-71102501906590d2}

```text
joesproxyctl effect bundle inspect (--file <path> | --bundle-id <uuid>)
```

## Command 164 {#command-267a115925ad87b2}

```text
joesproxyctl effect bundle inspect --revision-id <prepared-revision-uuid>
```

## Command 165 {#command-dd3a29cc825a36cd}

```text
joesproxyctl effect bundle inspect <bundle-id> [--after-marker <observation-marker>]
```

## Command 166 {#command-375f9247b867a151}

```text
joesproxyctl effect bundle import --file <path>
```

## Command 167 {#command-efa77065c7a0a3e9}

```text
joesproxyctl effect bundle prepare --session-id <UUID> --name <name> --idempotency-key <key> --client-address <address> --draft <JSON>
```

## Command 168 {#command-d1ae030d3deb468e}

```text
joesproxyctl effect bundle retire-preparation --revision-id <UUID>
```

## Command 169 {#command-364ee9f2074656ae}

```text
joesproxyctl effect bundle import --revision-id <prepared-revision-uuid>
```

## Command 170 {#command-bf82f4b7c72bdaab}

```text
joesproxyctl effect bundle activate prepare <bundle-id> [--ttl <sec>] [--replace-conflicts]
```

## Command 171 {#command-0ed17f36cc8d4ea4}

```text
joesproxyctl effect bundle activate apply <token>
```

## Command 172 {#command-de1a546b8284cda7}

```text
joesproxyctl effect bundle stop <bundle-id>
```

## Command 173 {#command-b1e1e8aa15a819a0}

```text
joesproxyctl effect bundle advance <bundle-id> --activation-id <UUID> --expected-phase-id <UUID>
```

## Command 174 {#command-1ec3085d89b3b22d}

```text
joesproxyctl run window begin <run-id> --bundle-id <UUID> --mode baseline|modified
```

## Command 175 {#command-af9ed3003763ef46}

```text
joesproxyctl run window end <window-id> [--target-outcome confirmed|rejected|unknown --outcome-source <source>]
```

## Command 176 {#command-a5b8f368e77d8b23}

```text
joesproxyctl effect bundle compare --baseline-window-id <UUID> --modified-window-id <UUID>
```

## Command 177 {#command-280c86fd78d24345}

```text
joesproxyctl effect bundle discard prepare <bundle-id>
```

## Command 178 {#command-e091301e7b354370}

```text
joesproxyctl effect bundle discard apply <token>
```
