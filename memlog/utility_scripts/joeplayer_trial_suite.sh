#!/usr/bin/env bash
# Fault-tolerant JoePlayer HLS rendition-switch trial orchestrator.
#
# Usage:
#   ./memlog/utility_scripts/joeplayer_trial_suite.sh \
#     --scenarios memlog/utility_scripts/joeplayer_suite/scenarios/default_drift_matrix.json \
#     --simulator "iPhone 17 Pro" --trials-per-cell 1 --continue-on-error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$SCRIPT_DIR/joeplayer_suite"
# shellcheck source=memlog/utility_scripts/joeplayer_suite/lib.sh
. "$SUITE_DIR/lib.sh"

SCENARIO_FILE="$SUITE_DIR/scenarios/default_drift_matrix.json"
SIMULATOR_NAME="iPhone 17 Pro"
SIMULATOR_UDID_OVERRIDE=""
TRIALS_PER_CELL=""
CONTINUE_ON_ERROR=0
RESUME_RUN_ID=""
WAIT_FLAG=()
DRY_RUN=0

usage() {
  cat <<EOF
Usage:
  joeplayer_trial_suite.sh [options]

Options:
  --scenarios <json>       Scenario matrix file (default: default_drift_matrix.json)
  --simulator <name>       Simulator device name (default: iPhone 17 Pro)
  --udid <udid>            Pin a specific simulator UDID (overrides --simulator)
  --trials-per-cell <n>    Override scenario trialsPerCell
  --continue-on-error      Record failures and continue
  --resume <suite_run_id>  Skip cells that already have manifest.json
  --wait-for-approval      Pass through to joesproxyctl fixture/fault apply
  --dry-run                Print planned cells without executing
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenarios) SCENARIO_FILE="${2:?}"; shift 2 ;;
    --simulator) SIMULATOR_NAME="${2:?}"; shift 2 ;;
    --udid) SIMULATOR_UDID_OVERRIDE="${2:?}"; shift 2 ;;
    --trials-per-cell|--n) TRIALS_PER_CELL="${2:?}"; shift 2 ;;
    --continue-on-error) CONTINUE_ON_ERROR=1; shift ;;
    --resume) RESUME_RUN_ID="${2:?}"; shift 2 ;;
    --wait-for-approval) WAIT_FLAG=(--wait-for-approval); shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -f "$SCENARIO_FILE" ]] || die "Scenario file not found: $SCENARIO_FILE"

suite_preflight

PROFILES=()
OFFSETS=()
FAULTS=()
AUDIO_TARGET="$(jq -r '.audioTarget // "ad"' "$SCENARIO_FILE")"
PLAY_AT="$(jq -r '.playAtSeconds // 0.1' "$SCENARIO_FILE")"
TRIAL_DURATION="$(jq -r '.trialDurationSeconds // 20' "$SCENARIO_FILE")"
CELL_TRIALS="$(jq -r '.trialsPerCell // 1' "$SCENARIO_FILE")"
[[ -n "$TRIALS_PER_CELL" ]] && CELL_TRIALS="$TRIALS_PER_CELL"

while IFS= read -r line; do PROFILES+=("$line"); done < <(jq -r '.profiles[]' "$SCENARIO_FILE")
while IFS= read -r line; do OFFSETS+=("$line"); done < <(jq -r '.offsetsSeconds[]' "$SCENARIO_FILE")
while IFS= read -r line; do [[ -n "$line" ]] && FAULTS+=("$line"); done < <(jq -r '.faults[]? // empty' "$SCENARIO_FILE")
[[ "${#FAULTS[@]}" -eq 0 ]] && FAULTS=("none")

if [[ -n "$RESUME_RUN_ID" ]]; then
  SUITE_RUN_ID="$RESUME_RUN_ID"
else
  SUITE_RUN_ID="joeplayer-$(date +%Y%m%d-%H%M%S)-$$"
fi

SUITE_DIR_OUT="$ROOT_DIR/memlog/joeplayer-trials/$SUITE_RUN_ID"
mkdir -p "$SUITE_DIR_OUT"
RESULTS_NDJSON="$SUITE_DIR_OUT/results.ndjson"
touch "$RESULTS_NDJSON"

log "Suite run: $SUITE_RUN_ID"
log "Scenario: $SCENARIO_FILE"
log "Output: $SUITE_DIR_OUT"

if [[ "$DRY_RUN" -eq 1 ]]; then
  for profile in "${PROFILES[@]}"; do
    for offset in "${OFFSETS[@]}"; do
      for fault in "${FAULTS[@]}"; do
        for ((trial_index = 1; trial_index <= CELL_TRIALS; trial_index++)); do
          printf 'cell profile=%s offset=%s fault=%s trial=%s\n' "$profile" "$offset" "$fault" "$trial_index"
        done
      done
    done
  done
  exit 0
fi

DOCTOR_JSON="$SUITE_DIR_OUT/doctor_preflight.json"
joesproxyctl_json doctor >"$DOCTOR_JSON" || true
ready="$(jq -r '.result.ready // false' "$DOCTOR_JSON")"
if [[ "$ready" != "true" ]]; then
  die "joesproxyctl doctor not ready — inspect $DOCTOR_JSON and approve grants if needed"
fi

SIM_UDID="${SIMULATOR_UDID_OVERRIDE:-$(resolve_simulator_udid "$SIMULATOR_NAME")}"
[[ -n "$SIM_UDID" ]] || die "Simulator not found: $SIMULATOR_NAME"
log "Using simulator $SIMULATOR_NAME udid=$SIM_UDID"
boot_simulator_if_needed "$SIM_UDID"
ensure_joeplayer_installed "$SIM_UDID"
IOS_VERSION="$(simulator_runtime_version "$SIM_UDID")"
JP_VERSION="$(marketing_version)"
CTL="$(resolve_joesproxyctl)"
PROXY_PORT="$(proxy_port_from_status)"
enable_macos_proxy_for_simulator "$PROXY_PORT" || log "WARNING: could not enable macOS system proxy"
install_joesproxy_ca_on_simulator "$SIM_UDID"
probe_proxy_routing "$PROXY_PORT" || true

ACTIVE_RUN_ID=""
ACTIVE_FAULT_MANIFEST=""
CLEANUP_FAULTS=()

cleanup_suite() {
  set +e
  if [[ -n "$ACTIVE_RUN_ID" ]]; then
    log "Stopping fixture run $ACTIVE_RUN_ID"
    "$CTL" hls fixture stop --run-id "$ACTIVE_RUN_ID" --json >/dev/null 2>&1 || true
  fi
  if [[ -n "${CLEANUP_FAULTS[*]:-}" ]]; then
    for token in "${CLEANUP_FAULTS[@]}"; do
      [[ -z "$token" ]] && continue
      "$CTL" rule disable "$token" --json >/dev/null 2>&1 || true
      "$CTL" rule apply-disable "$token" --json >/dev/null 2>&1 || true
    done
  fi
  if [[ -n "$ACTIVE_FAULT_MANIFEST" && -f "$ACTIVE_FAULT_MANIFEST" ]]; then
    while IFS= read -r token; do
      [[ -z "$token" ]] && continue
      "$CTL" rule disable "$token" --json >/dev/null 2>&1 || true
      "$CTL" rule apply-disable "$token" --json >/dev/null 2>&1 || true
    done < <(jq -r '.faults[]?.proposalToken // empty' "$ACTIVE_FAULT_MANIFEST")
    "$CTL" throttle disable --json >/dev/null 2>&1 || true
  fi
  xcrun simctl terminate "$SIM_UDID" "$JOEPLAYER_BUNDLE_ID" >/dev/null 2>&1 || true
  restore_macos_proxy || true
}
trap cleanup_suite EXIT

run_trial() {
  local profile="$1"
  local offset="$2"
  local fault="$3"
  local trial_index="$4"
  local trial_id="${profile//[^a-zA-Z0-9_-]/_}_off${offset//[^0-9.-]/}_fault${fault}_n${trial_index}"
  local trial_dir="$SUITE_DIR_OUT/$trial_id"

  if [[ -f "$trial_dir/manifest.json" ]]; then
    log "Skipping completed trial $trial_id"
    return 0
  fi

  mkdir -p "$trial_dir"
  local stderr_log="$trial_dir/stderr.log"
  exec 3>&1
  exec 1>"$trial_dir/stdout.log"
  exec 2>"$stderr_log"

  local status="failed"
  local classification="error"
  local pcm_classification="omitted"
  local run_id=""
  local host=""
  local switch_time=""
  local trigger_arg=""
  local boundary=""
  local fault_manifest="$trial_dir/faults.json"

  boundary="$(jq -r --arg profile "$profile" --arg target "$AUDIO_TARGET" \
    '.[$profile].discontinuityBoundarySeconds[$target] // empty' \
    "$SUITE_DIR/profile_metadata.json")"
  switch_time="$(awk -v b="$boundary" -v o="$offset" 'BEGIN { printf "%.6f", b + o }')"
  trigger_arg="$("$SUITE_DIR/build_trigger_plan.sh" \
    --switch-time "$switch_time" \
    --audio-target "$AUDIO_TARGET" \
    --play-at "$PLAY_AT" 2>"$trial_dir/trigger_plan.json")"

  log "Trial $trial_id profile=$profile offset=$offset fault=$fault"

  prepare_json="$("$CTL" hls fixture prepare-start --profile-id "$profile" --json 2>>"$stderr_log")"
  proposal_token="$(jq -r '.result.proposal.proposalToken // .result.payload.proposalToken // empty' <<<"$prepare_json")"
  [[ -n "$proposal_token" ]] || die "fixture prepare-start missing proposalToken"

  apply_json="$("$CTL" hls fixture apply-start "$proposal_token" --json ${WAIT_FLAG[@]+"${WAIT_FLAG[@]}"} 2>>"$stderr_log")"
  run_id="$(jq -r '.result.runID // .result.payload.runID // .result.payload.id // empty' <<<"$apply_json")"
  [[ -n "$run_id" ]] || run_id="$(jq -r '.result.payload.run.id // empty' <<<"$apply_json")"
  [[ -n "$run_id" ]] || die "fixture apply-start missing runID"
  ACTIVE_RUN_ID="$run_id"
  host="$(fixture_host "$run_id")"
  stream_url="$(fixture_stream_url "$run_id")"

  since_marker="$(iso8601_now)"
  "$CTL" capture marker --name "trial_${trial_id}_start" --detail "profile=$profile offset=$offset" --json >"$trial_dir/markers_start.json" 2>>"$stderr_log" || true

  if [[ "$fault" != "none" ]]; then
    ACTIVE_FAULT_MANIFEST="$fault_manifest"
    "$SUITE_DIR/apply_faults.sh" \
      --host "$host" \
      --fault "$fault" \
      --manifest-out "$fault_manifest" \
      ${WAIT_FLAG[@]+"${WAIT_FLAG[@]}"} >>"$trial_dir/stdout.log" 2>>"$stderr_log" || true
  else
    printf '{"faults":[]}\n' >"$fault_manifest"
  fi

  xcrun simctl terminate "$SIM_UDID" "$JOEPLAYER_BUNDLE_ID" >/dev/null 2>&1 || true
  if ! xcrun simctl launch "$SIM_UDID" "$JOEPLAYER_BUNDLE_ID" \
    --joeplayer-stream-url="$stream_url" \
    "$trigger_arg" >>"$trial_dir/simctl_launch.log" 2>>"$stderr_log"; then
    log "ERROR: simctl launch failed — see $trial_dir/simctl_launch.log and $stderr_log"
    classification="launch_failed"
    status="failed"
    printf '%s\n' "$classification" >"$trial_dir/classification.txt"
  else
    # Bound the wait for the first real post-switch target-rendition segment GET.
    # Cap is a multiple of TRIAL_DURATION so zero-capture trials fail cleanly instead of hanging.
    trial_started_at=$SECONDS
    poll_timeout=$((TRIAL_DURATION * 3))
    [[ "$poll_timeout" -lt 60 ]] && poll_timeout=60
    first_seg=""
    ca_pem="$ROOT_DIR/memlog/joeplayer-trials/.scratch/joesproxy-root-ca.pem"

    set +e
    first_seg="$("$SUITE_DIR/wait_for_target_segment.sh" \
      --host "$host" \
      --since "$since_marker" \
      --audio-target "$AUDIO_TARGET" \
      --timeout-seconds "$poll_timeout" \
      --first-out "$trial_dir/first_target_segment.txt" 2>>"$stderr_log")"
    wait_rc=$?
    set -e

    if [[ "$wait_rc" -ne 0 || -z "$first_seg" ]]; then
      classification="length_mismatch expected>0 captured_audio=0"
      status="failed"
      printf '%s\n' "$classification" >"$trial_dir/classification.txt"
      log "HINT: no audio-${AUDIO_TARGET} segment GETs within ${poll_timeout}s — check trigger plan selectAudio + proxy/CA"
    else
      # Live fixture-served playlist is ground truth (MEDIA-SEQUENCE + segment list).
      if [[ ! -s "$ca_pem" ]]; then
        install_joesproxy_ca_on_simulator "$SIM_UDID" || true
      fi
      set +e
      "$SUITE_DIR/fetch_live_audio_playlist.sh" \
        --host "$host" \
        --audio-target "$AUDIO_TARGET" \
        --proxy-port "$PROXY_PORT" \
        --cacert "$ca_pem" \
        --out "$trial_dir/live_audio_playlist.m3u8" >>"$trial_dir/stdout.log" 2>>"$stderr_log"
      fetch_rc=$?
      set -e

      set +e
      "$SUITE_DIR/fetch_live_audio_playlist.sh" \
        --host "$host" \
        --audio-target "$AUDIO_TARGET" \
        --proxy-port "$PROXY_PORT" \
        --cacert "$ca_pem" \
        --out "$trial_dir/live_audio_playlist.m3u8" >>"$trial_dir/stdout.log" 2>>"$stderr_log"
      fetch_rc=$?
      set -e

      if [[ "$fetch_rc" -ne 0 || ! -s "$trial_dir/live_audio_playlist.m3u8" ]]; then
        log "WARNING: live playlist fetch failed (forensics only) — continuing with anchor-uri expected"
      fi

      # Classification expected URIs: first observed target GET + fixture segment cycle.
      # Live playlist file (when present) is MEDIA-SEQUENCE forensics, not the timing oracle.
      "$SUITE_DIR/emit_expected_segments.sh" \
        --anchor-uri "$first_seg" \
        --profile "$profile" \
        --audio-target "$AUDIO_TARGET" \
        >"$trial_dir/expected_segments.txt" 2>>"$stderr_log" || true

      # Collect enough post-switch media for a full window even if TRIAL_DURATION was mostly
      # spent waiting for the first target GET.
      elapsed=$((SECONDS - trial_started_at))
      remaining=$((TRIAL_DURATION - elapsed))
      post_switch_floor=16
      if [[ "$remaining" -lt "$post_switch_floor" ]]; then
        remaining=$post_switch_floor
      fi
      sleep "$remaining"

      "$SUITE_DIR/export_capture.sh" \
        --host "$host" \
        --since "$since_marker" \
        --segments-out "$trial_dir/captured_segments.txt" \
        --events-out "$trial_dir/joeplayer_events.json" \
        ${WAIT_FLAG[@]+"${WAIT_FLAG[@]}"} >>"$trial_dir/stdout.log" 2>>"$stderr_log" || \
        log "export_capture failed (see $stderr_log)"

      if [[ -s "$trial_dir/expected_segments.txt" && -s "$trial_dir/captured_segments.txt" ]]; then
        captured_audio="$trial_dir/captured_audio_segments.txt"
        grep -E "^audio-${AUDIO_TARGET}/" "$trial_dir/captured_segments.txt" >"$captured_audio" || true
        expected_count="$(grep -cve '^[[:space:]]*$' "$trial_dir/expected_segments.txt" || true)"
        if [[ "$expected_count" -gt 0 && -s "$captured_audio" ]]; then
          # Drop leading captures before the observed first target GET (pre-anchor noise).
          awk -v anchor="$first_seg" '
            $0 == anchor { seen = 1 }
            seen { print }
          ' "$captured_audio" >"${captured_audio}.from_anchor" || true
          if [[ -s "${captured_audio}.from_anchor" ]]; then
            mv "${captured_audio}.from_anchor" "$captured_audio"
          fi
            head -n "$expected_count" "$captured_audio" >"${captured_audio}.window"
            mv "${captured_audio}.window" "$captured_audio"
          fi
          if [[ -s "$captured_audio" ]]; then
          set +e
          classification_line="$("$SCRIPT_DIR/joeplayer_compare_segment_sequences.sh" \
            "$trial_dir/expected_segments.txt" "$captured_audio" 2>>"$stderr_log")"
          set -e
          classification="$classification_line"
          status="completed"
          printf '%s\n' "$classification" >"$trial_dir/classification.txt"
        else
          classification="length_mismatch expected>0 captured_audio=0"
          printf '%s\n' "$classification" >"$trial_dir/classification.txt"
          log "HINT: no audio-${AUDIO_TARGET} segment GETs — check trigger plan selectAudio + proxy/CA"
        fi
      else
        classification="export_failed"
        printf '%s\n' "$classification" >"$trial_dir/classification.txt"
        log "HINT: empty capture — Simulator must inherit macOS HTTP/HTTPS proxy to 127.0.0.1:$PROXY_PORT"
      fi
    fi
  fi

  if [[ -f "$trial_dir/joeplayer_events.json" ]] && jq -e '.[] | select(.kind == "pcmAttachError")' "$trial_dir/joeplayer_events.json" >/dev/null 2>&1; then
    pcm_classification="pcm_attach_error"
  elif [[ -f "$trial_dir/joeplayer_events.json" ]] && jq -e '.[] | select(.kind == "pcmMute")' "$trial_dir/joeplayer_events.json" >/dev/null 2>&1; then
    pcm_classification="pcm_mute"
  elif [[ -f "$trial_dir/joeplayer_events.json" ]] && jq -e '.[] | select(.kind == "pcmGlitch")' "$trial_dir/joeplayer_events.json" >/dev/null 2>&1; then
    pcm_classification="pcm_glitch"
  elif [[ -f "$trial_dir/joeplayer_events.json" ]] && jq -e '.[] | select(.kind == "pcmOk")' "$trial_dir/joeplayer_events.json" >/dev/null 2>&1; then
    pcm_classification="pcm_ok"
  fi

  "$CTL" capture marker --name "trial_${trial_id}_end" --json >"$trial_dir/markers_end.json" 2>>"$stderr_log" || true
  "$CTL" hls fixture stop --run-id "$run_id" --json >"$trial_dir/fixture_stop.json" 2>>"$stderr_log" || true
  ACTIVE_RUN_ID=""
  ACTIVE_FAULT_MANIFEST=""

  jq -nc \
    --arg trial_id "$trial_id" \
    --arg suite_run_id "$SUITE_RUN_ID" \
    --arg profile_id "$profile" \
    --arg offset "$offset" \
    --arg fault "$fault" \
    --argjson trial_index "$trial_index" \
    --arg run_id "$run_id" \
    --arg host "$host" \
    --arg stream_url "$stream_url" \
    --arg switch_time "$switch_time" \
    --arg trigger_plan "$(cat "$trial_dir/trigger_plan.json" 2>/dev/null || echo "")" \
    --arg classification "$classification" \
    --arg pcm_classification "$pcm_classification" \
    --arg status "$status" \
    --arg ios_version "$IOS_VERSION" \
    --arg simulator_udid "$SIM_UDID" \
    --arg joesproxy_version "$JP_VERSION" \
    --arg finished_at "$(iso8601_now)" \
    '{
      trialId: $trial_id,
      suiteRunId: $suite_run_id,
      profileId: $profile_id,
      offsetSeconds: ($offset | tonumber? // $offset),
      fault: $fault,
      trialIndex: $trial_index,
      fixtureRunId: $run_id,
      reservedHost: $host,
      streamURL: $stream_url,
      switchTimeSeconds: ($switch_time | tonumber? // $switch_time),
      triggerPlanJSON: $trigger_plan,
      classification: $classification,
      pcmClassification: $pcm_classification,
      status: $status,
      iosVersion: $ios_version,
      simulatorUDID: $simulator_udid,
      joesproxyVersion: $joesproxy_version,
      finishedAt: $finished_at
    }' >"$trial_dir/manifest.json"

  append_ndjson_line "$RESULTS_NDJSON" "$(cat "$trial_dir/manifest.json")"

  exec 1>&3 3>&-
  log "Trial $trial_id -> $classification ($status)"

  if [[ "$status" != "completed" && "$CONTINUE_ON_ERROR" -eq 0 ]]; then
    return 1
  fi
  return 0
}

for profile in "${PROFILES[@]}"; do
  for offset in "${OFFSETS[@]}"; do
    for fault in "${FAULTS[@]}"; do
      for ((trial_index = 1; trial_index <= CELL_TRIALS; trial_index++)); do
        if ! run_trial "$profile" "$offset" "$fault" "$trial_index"; then
          [[ "$CONTINUE_ON_ERROR" -eq 1 ]] || exit 1
        fi
      done
    done
  done
done

log "Suite complete: $RESULTS_NDJSON"
