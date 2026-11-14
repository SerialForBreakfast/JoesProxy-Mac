# Usage: jq -Rs -f memlog/utility_scripts/soak_summary.jq <run directory>/metrics.jsonl
# Summarizes one capture soak. Bytes are serialized RPC bytes, not provider tokens.
def percentile($p): sort | if length == 0 then null else .[((length - 1) * $p | floor)] end;
def stats: {median: percentile(0.5), p95: percentile(0.95), max: (max // null)};
split("\n") | map(select(length > 0) | fromjson) as $all
| ($all | map(select(.kind == "workflow"))) as $workflows
| ($all | map(select(.kind == "checkpoint")) | sort_by(.cycle)) as $checkpoints
| ($all | map(select(.kind == "live_query"))) as $live
| {
    run: ($all | map(select(.kind == "summary")) | first // {status: "no summary line: run aborted or still active"}),
    aborted: ($all | map(select(.kind == "aborted" or .kind == "safety_stop"))),
    disturbedWindows: ($all | map(select(.kind == "disturbed_window")) | length),
    discoveryBytes: ($all | map(select(.kind == "discovery") | {(.toolset): .bytes}) | add),
    statusCountWorkflow: {
      cycles: ($workflows | length),
      filteredCorrect: ($workflows | map(select(.candidateCorrect)) | length),
      pagedCorrect: ($workflows | map(select(.baselineCorrect)) | length),
      filteredCalls: ($workflows | map(.candidateCalls) | stats),
      pagedCalls: ($workflows | map(.baselineCalls) | stats),
      filteredBytes: ($workflows | map(.candidateBytes) | stats),
      pagedBytes: ($workflows | map(.baselineBytes) | stats),
      filteredMilliseconds: ($workflows | map(.candidateMs) | stats),
      pagedMilliseconds: ($workflows | map(.baselineMs) | stats)
    },
    filteredUnderLiveTraffic: ($live | map(.outcomes | to_entries[]) | group_by(.key)
      | map({(.[0].key): (map(.value) | add)}) | add),
    ruleChanges: ($all | map(select(.kind == "rule_change")) | {count: length,
      fullyBlocked: (map(select(.blocked == 4)) | length), exactHits: (map(select(.hits == 4)) | length)}),
    capturePauses: ($all | map(select(.kind == "capture_pause")) | {count: length,
      qualified: (map(select(.qualified)) | length), recordedRows: (map(.recordedRows) | stats)}),
    userClears: ($all | map(select(.kind == "user_clear")) | {count: length, qualified: (map(select(.qualified)) | length)}),
    resources: (if ($checkpoints | length) == 0 then null else {
      checkpoints: ($checkpoints | length),
      hours: ($checkpoints[-1].elapsedSeconds / 3600),
      configuration: $checkpoints[0].configuration,
      footprintFirstMiB: ($checkpoints[0].physicalFootprint / 1048576),
      footprintLastMiB: ($checkpoints[-1].physicalFootprint / 1048576),
      footprintMiB: ($checkpoints | map(.physicalFootprint / 1048576) | stats),
      footprintGrowthMiBPerHour: (if $checkpoints[-1].elapsedSeconds > $checkpoints[0].elapsedSeconds then
        (($checkpoints[-1].physicalFootprint - $checkpoints[0].physicalFootprint) / 1048576)
          / (($checkpoints[-1].elapsedSeconds - $checkpoints[0].elapsedSeconds) / 3600) else null end),
      # History is cleared every tenth cycle, so only those checkpoints hold an equal population.
      footprintGrowthAfterClearMiBPerHour: (($checkpoints | map(select(.cycle % 10 == 0))) as $c
        | if ($c | length) >= 2 and $c[-1].elapsedSeconds > $c[0].elapsedSeconds then
            (($c[-1].physicalFootprint - $c[0].physicalFootprint) / 1048576)
              / (($c[-1].elapsedSeconds - $c[0].elapsedSeconds) / 3600) else null end),
      footprintAfterClearMiB: ($checkpoints | map(select(.cycle % 10 == 0) | .physicalFootprint / 1048576) | stats),
      rateWaitSeconds: ($checkpoints[-1].rateWaitSeconds // null),
      undrainedCheckpoints: ($checkpoints | map(select(.relayBytes != 0 or .captureReserved != 0)) | length),
      retainedSessions: ($checkpoints | map(.retainedSessions) | stats),
      maxTransferSeconds: ($checkpoints | map(.maxTransferSeconds) | stats),
      slowTransferCycles: ($checkpoints | map(select(.maxTransferSeconds >= 0.25)) | length),
      rejectedCaptures: $checkpoints[-1].rejectedCaptures,
      originRequests: $checkpoints[-1].originRequests
    } end),
    invariantFailures: ($all | map(select(.kind == "invariant_failure")) | group_by(.invariant)
      | map({invariant: .[0].invariant, count: length, firstCycle: (map(.cycle) | min), example: .[0].detail}))
  }
