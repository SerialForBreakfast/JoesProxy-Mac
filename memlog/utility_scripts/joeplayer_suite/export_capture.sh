#!/usr/bin/env bash
# Export captured segment URIs and JoePlayer diagnostic events from JoesProxy via joesproxyctl.
#
# Segment paths come from `sessions search` summary projection (no sensitive approval).
# Diagnostic event bodies require `session show --include-body` (approval-gated); pass
# `--wait-for-approval` when the operator can approve in-app.
#
# Usage:
#   export_capture.sh --host fixture-....hls.joesproxy.invalid --since <ISO8601> \
#     --segments-out captured_segments.txt --events-out joeplayer_events.json \
#     [--wait-for-approval]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=memlog/utility_scripts/joeplayer_suite/lib.sh
. "$SCRIPT_DIR/lib.sh"

HOST=""
SINCE=""
SEGMENTS_OUT=""
EVENTS_OUT=""
WAIT_FLAG=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --since) SINCE="${2:?}"; shift 2 ;;
    --segments-out) SEGMENTS_OUT="${2:?}"; shift 2 ;;
    --events-out) EVENTS_OUT="${2:?}"; shift 2 ;;
    --wait-for-approval) WAIT_FLAG=(--wait-for-approval); shift ;;
    -h|--help)
      echo "usage: $0 --host <fixture-host> --since <ISO8601> --segments-out <file> --events-out <file> [--wait-for-approval]"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$HOST" && -n "$SINCE" && -n "$SEGMENTS_OUT" && -n "$EVENTS_OUT" ]] \
  || { echo "missing required arguments" >&2; exit 2; }

SCRATCH_DIR="$ROOT_DIR/memlog/joeplayer-trials/.scratch"
mkdir -p "$SCRATCH_DIR"
search_json="$SCRATCH_DIR/search-$$-$(date +%s).json"
trap 'rm -f "$search_json"' EXIT

joesproxyctl_json sessions search \
  --domain "$HOST" \
  --since "$SINCE" \
  --limit 500 \
  --projection summary >"$search_json"

payload="$(jq -c '.result.payload // .result // .' "$search_json")"
# joesproxyctl sessions_search returns items (not sessions).
sessions="$(jq -c '.items // .sessions // []' <<<"$payload")"
item_count="$(jq 'length' <<<"$sessions")"
log "sessions search host=$HOST since=$SINCE items=$item_count"

# Prefer summary fields already present on search hits — avoids `session show` approvalRequired.
jq -r '
  .[]
  | select(.method == "GET")
  | select((.sanitizedPath // .path // "") | test("\\.ts($|\\?)"))
  | [(.startedAt // ""), (.sanitizedPath // .path // "")]
  | @tsv
' <<<"$sessions" \
  | sort -k1,1 \
  | awk -F'\t' '
    {
      path = $2
      sub(/^\//, "", path)
      if (match(path, /audio-[a-z]+\/seg-[0-9]+\.ts/)) {
        print substr(path, RSTART, RLENGTH)
      } else if (match(path, /video-[a-z]+\/seg-[0-9]+\.ts/)) {
        print substr(path, RSTART, RLENGTH)
      } else if (path != "") {
        print path
      }
    }
  ' >"$SEGMENTS_OUT"

printf '[]' >"$EVENTS_OUT"

diag_id="$(jq -r '
  .[]
  | select(.method == "POST")
  | select((.sanitizedPath // .path // "") | test("joeplayer/v1/events"))
  | .id
' <<<"$sessions" | tail -1)"

if [[ -n "$diag_id" ]]; then
  # Sensitive read — may require in-app approval. Fail soft so segment classification still runs.
  # macOS /bin/bash 3.2 + set -u rejects "${arr[@]}" when arr is empty; expand conditionally.
  if [[ ${#WAIT_FLAG[@]} -gt 0 ]]; then
    body_json="$(joesproxyctl_json session show "$diag_id" --include-body "${WAIT_FLAG[@]}" 2>/dev/null || true)"
  else
    body_json="$(joesproxyctl_json session show "$diag_id" --include-body 2>/dev/null || true)"
  fi
  if jq -e '.success == true' <<<"${body_json:-}" >/dev/null 2>&1; then
    body_text="$(jq -r '
      .result.payload.requestBodyText
      // .result.payload.bodyText
      // .result.requestBodyText
      // .result.payload.request.bodyText
      // .result.payload.body
      // empty
    ' <<<"$body_json")"
    if [[ -n "$body_text" ]]; then
      if printf '%s' "$body_text" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$body_text" | jq '.' >"$EVENTS_OUT"
      else
        jq -nc --arg raw "$body_text" '{parseError: true, raw: $raw}' >"$EVENTS_OUT"
      fi
    else
      log "WARNING: diagnostic session $diag_id has no request body text (status may be 405 if JoesProxy predates diagnostic 204 ingest)"
    fi
  else
    err_code="$(jq -r '.errorCode // empty' <<<"${body_json:-}" 2>/dev/null || true)"
    log "WARNING: could not load diagnostic body for $diag_id (errorCode=${err_code:-unknown}); segment export still valid"
  fi
fi

segment_count="$(grep -cve '^[[:space:]]*$' "$SEGMENTS_OUT" || true)"
event_count="$(jq 'if type == "array" then length else 0 end' "$EVENTS_OUT")"
log "Exported $segment_count segment URIs and $event_count diagnostic events"
if [[ "$item_count" -gt 0 && "$segment_count" -eq 0 ]]; then
  log "WARNING: search returned $item_count items but no .ts GETs for host=$HOST"
fi
