#!/usr/bin/env bash
# Poll JoesProxy `sessions search` until the first GET for a target audio segment appears.
#
# Reuses the same summary-projection query shape as `export_capture.sh` (domain + since +
# `.ts` path extraction). Does not re-implement sliding-window math.
#
# Usage:
#   wait_for_target_segment.sh --host <fixture-host> --since <ISO8601> \
#     --audio-target ad --timeout-seconds 60 [--poll-interval 1] [--first-out path]
#
# Prints the first matching path (e.g. audio-ad/seg-003.ts) on stdout when found.
# Exits 1 on timeout with no match.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=memlog/utility_scripts/joeplayer_suite/lib.sh
. "$SCRIPT_DIR/lib.sh"

HOST=""
SINCE=""
AUDIO_TARGET="ad"
TIMEOUT_SECONDS="60"
POLL_INTERVAL="1"
FIRST_OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --since) SINCE="${2:?}"; shift 2 ;;
    --audio-target) AUDIO_TARGET="${2:?}"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:?}"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="${2:?}"; shift 2 ;;
    --first-out) FIRST_OUT="${2:?}"; shift 2 ;;
    -h|--help)
      echo "usage: $0 --host <host> --since <ISO8601> --audio-target <id> [--timeout-seconds N]"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$HOST" && -n "$SINCE" ]] || { echo "missing --host/--since" >&2; exit 2; }

SCRATCH_DIR="$ROOT_DIR/memlog/joeplayer-trials/.scratch"
mkdir -p "$SCRATCH_DIR"
search_json="$SCRATCH_DIR/wait-seg-$$-$(date +%s).json"
trap 'rm -f "$search_json"' EXIT

prefix="audio-${AUDIO_TARGET}/seg-"
deadline=$((SECONDS + TIMEOUT_SECONDS))
log "Waiting for first audio-${AUDIO_TARGET} segment GET host=$HOST timeout=${TIMEOUT_SECONDS}s"

while (( SECONDS < deadline )); do
  joesproxyctl_json sessions search \
    --domain "$HOST" \
    --since "$SINCE" \
    --limit 500 \
    --projection summary >"$search_json"

  payload="$(jq -c '.result.payload // .result // .' "$search_json")"
  sessions="$(jq -c '.items // .sessions // []' <<<"$payload")"

  first="$(jq -r '
    .[]
    | select(.method == "GET")
    | select((.sanitizedPath // .path // "") | test("\\.ts($|\\?)"))
    | [(.startedAt // ""), (.sanitizedPath // .path // "")]
    | @tsv
  ' <<<"$sessions" \
    | sort -k1,1 \
    | awk -F'\t' -v prefix="$prefix" '
      {
        path = $2
        sub(/^\//, "", path)
        if (match(path, /audio-[a-z]+\/seg-[0-9]+\.ts/)) {
          candidate = substr(path, RSTART, RLENGTH)
          if (index(candidate, prefix) == 1) {
            print candidate
            exit
          }
        }
      }
    ')"

  if [[ -n "$first" ]]; then
    log "Observed first post-switch target segment: $first"
    if [[ -n "$FIRST_OUT" ]]; then
      printf '%s\n' "$first" >"$FIRST_OUT"
    fi
    printf '%s\n' "$first"
    exit 0
  fi
  sleep "$POLL_INTERVAL"
done

log "ERROR: timed out waiting for audio-${AUDIO_TARGET}/seg-*.ts after ${TIMEOUT_SECONDS}s"
exit 1
