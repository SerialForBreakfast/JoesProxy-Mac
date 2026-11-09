#!/usr/bin/env bash
# Apply network fault injections for JoePlayer trials via joesproxyctl MCP wrappers.
#
# Usage:
#   apply_faults.sh --host <fixture-host> --fault throttle --preset-id mobile-3g [--wait-for-approval]
#   apply_faults.sh --host <fixture-host> --fault block-segment --rendition audio-ad --segment seg-003.ts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=memlog/utility_scripts/joeplayer_suite/lib.sh
. "$SCRIPT_DIR/lib.sh"

HOST=""
FAULT=""
PRESET_ID="mobile-3g"
RENDITION="audio-ad"
SEGMENT="seg-003.ts"
WAIT_FLAG=()
MANIFEST_OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --fault) FAULT="${2:?}"; shift 2 ;;
    --preset-id) PRESET_ID="${2:?}"; shift 2 ;;
    --rendition) RENDITION="${2:?}"; shift 2 ;;
    --segment) SEGMENT="${2:?}"; shift 2 ;;
    --manifest-out) MANIFEST_OUT="${2:?}"; shift 2 ;;
    --wait-for-approval) WAIT_FLAG=(--wait-for-approval); shift ;;
    -h|--help)
      echo "usage: $0 --host <host> --fault throttle|block-segment|slow-and-drop [options]"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$HOST" && -n "$FAULT" ]] || { echo "missing --host or --fault" >&2; exit 2; }

ctl="$(resolve_joesproxyctl)"
applied=()

apply_throttle() {
  local prepare_json apply_token result_json
  prepare_json="$("$ctl" throttle prepare --preset-id "$PRESET_ID" --json ${WAIT_FLAG[@]+"${WAIT_FLAG[@]}"})"
  apply_token="$(jq -r '.result.proposal.proposalToken // .result.payload.proposalToken // empty' <<<"$prepare_json")"
  [[ -n "$apply_token" ]] || die "throttle prepare did not return proposalToken"
  result_json="$("$ctl" throttle apply "$apply_token" --json ${WAIT_FLAG[@]+"${WAIT_FLAG[@]}"})"
  applied+=("$(jq -nc --arg type throttle --arg token "$apply_token" --arg preset "$PRESET_ID" \
    '{type: $type, proposalToken: $token, presetId: $preset}')")
  log "Applied throttle preset=$PRESET_ID"
}

apply_block_segment() {
  local path="/${RENDITION}/${SEGMENT}"
  local prepare_json apply_token
  prepare_json="$("$ctl" block prepare \
    --method GET \
    --host "$HOST" \
    --path "$path" \
    --match-mode pathSuffix \
    --json ${WAIT_FLAG[@]+"${WAIT_FLAG[@]}"})"
  apply_token="$(jq -r '.result.proposal.proposalToken // .result.payload.proposalToken // empty' <<<"$prepare_json")"
  [[ -n "$apply_token" ]] || die "block prepare did not return proposalToken"
  "$ctl" block apply "$apply_token" --enable-after --json ${WAIT_FLAG[@]+"${WAIT_FLAG[@]}"} >/dev/null
  applied+=("$(jq -nc --arg type block --arg token "$apply_token" --arg path "$path" \
    '{type: $type, proposalToken: $token, path: $path}')")
  log "Applied block for $path"
}

case "$FAULT" in
  throttle)
    apply_throttle
    ;;
  block-segment)
    apply_block_segment
    ;;
  slow-and-drop)
    apply_throttle
    apply_block_segment
    ;;
  none|"")
    log "No faults requested"
    ;;
  *)
    die "Unknown fault: $FAULT"
    ;;
esac

if [[ -n "$MANIFEST_OUT" ]]; then
  jq -nc --argjson faults "$(printf '%s\n' "${applied[@]:-}" | jq -s '.')" '{faults: $faults}' >"$MANIFEST_OUT"
fi

printf '%s\n' "${applied[@]:-}"
