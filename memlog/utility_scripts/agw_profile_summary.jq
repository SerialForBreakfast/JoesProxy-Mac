# Usage: jq -Rs -f memlog/utility_scripts/agw_profile_summary.jq <exported AGW JSONL files>
def percentile($p): sort | if length == 0 then null else .[((length - 1) * $p | floor)] end;
split("\n") | map(select(length > 0) | fromjson)
| group_by([.candidate, .repetition, .agentProfile.phase])
| map(. as $all | unique_by(.sampleUptime) | sort_by(.sampleUptime) as $samples
    | $samples[0] as $first | $samples[-1] as $last
    | ($last.sampleUptime - $first.sampleUptime) as $duration
    | {candidate: $first.candidate, repetition: $first.repetition, phase: $first.agentProfile.phase,
       workloadDigest: $first.workloadDigest, samples: ($samples | length), seconds: $duration,
       footprintMedianMiB: ([$samples[].physicalFootprintBytes / 1048576] | percentile(0.5)),
       footprintP95MiB: ([$samples[].physicalFootprintBytes / 1048576] | percentile(0.95)),
       cpuPercentOneCore: (if $duration > 0 and all($samples[]; .cpuTimeUnit == "nanoseconds") then
         (($last.userCPUTimeNanoseconds + $last.systemCPUTimeNanoseconds - $first.userCPUTimeNanoseconds - $first.systemCPUTimeNanoseconds) / 1000000000 / $duration * 100) else null end),
       interruptWakeupsPerSecond: (if $duration > 0 then ($last.interruptWakeups - $first.interruptWakeups) / $duration else null end),
       idleWakeupsPerSecond: (if $duration > 0 then ($last.idleWakeups - $first.idleWakeups) / $duration else null end),
       forwardingP95Milliseconds: ([$all[] | select(.forwardingSeconds != null) | .forwardingSeconds * 1000] | percentile(0.95)),
       queryP95Milliseconds: ([$samples[] | select(.agentProfile.phase == "traffic-query" and .agentProfile.queryCount > 0)] | unique_by(.agentProfile.queryCount) | map(.agentProfile.lastQueryNanoseconds / 1000000) | percentile(0.95)),
       completedRequests: $last.completedRequests, finalState: $last.agentProfile})
