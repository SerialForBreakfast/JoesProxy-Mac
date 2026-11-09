#!/usr/bin/env bash
# Summarize JoePlayer trial suite NDJSON into distribution tables.
#
# Usage:
#   summarize_results.sh memlog/joeplayer-trials/<suite_run_id>/results.ndjson [--markdown-out file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=memlog/utility_scripts/joeplayer_suite/lib.sh
. "$SCRIPT_DIR/lib.sh"

NDJSON="${1:?usage: $0 <results.ndjson> [--markdown-out file]}"
MARKDOWN_OUT=""

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --markdown-out) MARKDOWN_OUT="${2:?}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -f "$NDJSON" ]] || die "Missing results file: $NDJSON"

require_cmd jq

render_table() {
  local title="$1"
  local field="$2"
  printf '## %s\n\n' "$title"
  printf '| Profile | Offset | Fault | Count | Distribution |\n'
  printf '|---------|--------|-------|-------|--------------|\n'
  jq -s -r --arg field "$field" '
    group_by(.profileId + "|" + (.offsetSeconds | tostring) + "|" + .fault)[]
    | {
        profile: .[0].profileId,
        offset: (.[0].offsetSeconds | tostring),
        fault: .[0].fault,
        count: length,
        dist: (map(.[ $field ])
               | group_by(.)
               | map({key: .[0], n: length})
               | sort_by(-.n)
               | map("\(.key)=\(.n)")
               | join(", "))
      }
    | "| \(.profile) | \(.offset) | \(.fault) | \(.count) | \(.dist) |"
  ' "$NDJSON"
}

trial_lines="$(jq -s -r '.[] | "- \(.trialId): \(.classification) (\(.profileId) offset=\(.offsetSeconds) fault=\(.fault))"' "$NDJSON")"
total_trials="$(wc -l <"$NDJSON" | tr -d ' ')"

output="# JoePlayer Trial Summary

Source: \`$NDJSON\`
Generated: $(iso8601_now)

Total trials: $total_trials

$(render_table "Segment classifications" "classification")

$(render_table "PCM classifications" "pcmClassification")

## Raw trial IDs

$trial_lines
"

if [[ -n "$MARKDOWN_OUT" ]]; then
  printf '%s\n' "$output" >"$MARKDOWN_OUT"
  log "Wrote $MARKDOWN_OUT"
else
  printf '%s\n' "$output"
fi
