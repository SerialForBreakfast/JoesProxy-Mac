#!/bin/bash
# Unified offline HLS fixture authoring entry point (P2-optional).
#
# Developer-only. Never invoked by HLSFixtureServer, MCP, CLI agents, or unit tests.
# Install ffmpeg yourself when needed — this script never auto-installs anything.
#
# Usage:
#   author-hls.sh preflight [--skip-ffmpeg]
#   author-hls.sh baseline
#   author-hls.sh player-qa
#   author-hls.sh sdr-six-second
#   author-hls.sh validate-sdr-six-second
#   author-hls.sh matrix [--skip-ffmpeg] [--only <profile-id>]
#   author-hls.sh hashes <profile-dir> --purpose <text> [--differs <text>] [--version <v>]
#   author-hls.sh regenerate-all
#
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Fixtures/HLS/_lib.sh
. "$ROOT/_lib.sh"

GEN="$ROOT/generate-profile.sh"
MAT="$ROOT/materialize-matrix.sh"
EMIT="$ROOT/emit-expected-hashes.sh"
PARAM="$ROOT/author-param-profile.sh"
PLAYER_QA="$ROOT/generate-player-qa-profile.sh"
SIX_SECOND_SDR="$ROOT/generate-six-second-sdr-profile.sh"
AUDIO_TOPOLOGIES="$ROOT/generate-audio-topology-profiles.sh"
JIT_PROFILES="$ROOT/generate-jit-and-fine-grid-profiles.sh"
ID3_PROFILES="$ROOT/generate-id3-profiles.sh"
VALIDATE_SIX_SECOND_SDR="$ROOT/validate-six-second-sdr-profile.sh"
BASELINE="$ROOT/baseline-aligned-codecs"

usage() {
  cat <<EOF
Usage:
  author-hls.sh preflight [--skip-ffmpeg]
  author-hls.sh baseline
  author-hls.sh player-qa
  author-hls.sh sdr-six-second
  author-hls.sh audio-topologies
  author-hls.sh jit-profiles
  author-hls.sh id3-profiles
  author-hls.sh validate-sdr-six-second
  author-hls.sh matrix [--skip-ffmpeg] [--only <profile-id>]
  author-hls.sh hashes <profile-dir> --purpose <text> [emit-expected-hashes flags...]
  author-hls.sh regenerate-all
  author-hls.sh param [--only <profile-id>]

Offline developer tooling only. CI and HLSFixtureServer never run these scripts.
EOF
}

ensure_executable() {
  local f
  for f in "$GEN" "$MAT" "$EMIT" "$PARAM" "$PLAYER_QA" "$SIX_SECOND_SDR" "$AUDIO_TOPOLOGIES" "$JIT_PROFILES" "$ID3_PROFILES" "$VALIDATE_SIX_SECOND_SDR"; do
    if [ ! -x "$f" ]; then
      chmod +x "$f"
    fi
  done
}

cmd_six_second_sdr() {
  require_cmd jq "writing profile metadata and expected-hashes.json"
  require_cmd shasum "emitting expected-hashes.json"
  require_cmd ffprobe "validating authored codec, geometry, keyframe, and timestamp facts"
  require_ffmpeg
  ensure_executable
  "$SIX_SECOND_SDR"
  "$VALIDATE_SIX_SECOND_SDR" "$ROOT/sdr-six-second-positive-v1"
  local ffver
  ffver="$(ffmpeg_version_line)"
  "$EMIT" "$ROOT/sdr-six-second-positive-v1" \
    --purpose "Nominal-six-second SDR AVC/AAC positive control with a continuous 90-second synthetic timeline." \
    --version "1" \
    --generated-with "Fixtures/HLS/author-hls.sh sdr-six-second" \
    --ffmpeg-version "$ffver"
}

cmd_player_qa() {
  require_cmd jq "emitting expected-hashes.json"
  require_cmd shasum "emitting expected-hashes.json"
  require_ffmpeg
  ensure_executable
  "$PLAYER_QA"
  local ffver
  ffver="$(ffmpeg_version_line)"
  "$EMIT" "$ROOT/player-qa-widescreen-v1" \
    --purpose "Widescreen player QA: deterministic 16:9 ABR with English, English AD, Spanish, and German audio switching." \
    --version "2" \
    --generated-with "Fixtures/HLS/author-hls.sh player-qa" \
    --ffmpeg-version "$ffver"
}

cmd_preflight() {
  local skip_ffmpeg=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --skip-ffmpeg) skip_ffmpeg=1; shift ;;
      *) echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  echo "Offline HLS authoring preflight ($ROOT)"
  local missing=0
  report_cmd jq || missing=1
  report_cmd rsync || missing=1
  report_cmd shasum || missing=1
  if [ "$skip_ffmpeg" = "1" ]; then
    if command -v ffmpeg >/dev/null 2>&1; then
      printf '  %-10s OK (optional; --skip-ffmpeg set)\n' ffmpeg
    else
      printf '  %-10s MISSING (optional; --skip-ffmpeg set)\n' ffmpeg
    fi
  else
    report_cmd ffmpeg || missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    echo "preflight FAILED: install missing tools yourself (repo never auto-installs)." >&2
    exit 1
  fi
  echo "preflight OK"
}

cmd_baseline() {
  require_cmd jq "emitting expected-hashes.json"
  require_cmd shasum "emitting expected-hashes.json"
  require_ffmpeg
  ensure_executable

  echo "=== author-hls baseline → baseline-aligned-codecs ==="
  "$GEN" "$BASELINE"

  local ffver
  ffver="$(ffmpeg_version_line)"
  local emit_args=(
    "$BASELINE"
    --purpose "Positive control: correct CODECS on every variant, genuine AD, aligned splices."
    --version "1"
    --generated-with "Fixtures/HLS/author-hls.sh baseline"
  )
  if [ -n "$ffver" ]; then
    emit_args+=(--ffmpeg-version "$ffver")
  fi
  "$EMIT" "${emit_args[@]}"
  echo "Baseline authored at $BASELINE"
}

cmd_matrix() {
  require_cmd jq "emitting expected-hashes.json"
  require_cmd rsync "copying baseline media into matrix profiles"
  require_cmd shasum "emitting expected-hashes.json"
  ensure_executable
  "$MAT" "$@"
}

cmd_hashes() {
  require_cmd jq "emitting expected-hashes.json"
  require_cmd shasum "emitting expected-hashes.json"
  ensure_executable
  if [ $# -lt 1 ]; then
    echo "usage: author-hls.sh hashes <profile-dir> --purpose <text> [...]" >&2
    exit 1
  fi
  "$EMIT" "$@"
}

cmd_param() {
  ensure_executable
  if [ ! -x "$PARAM" ]; then
    chmod +x "$PARAM"
  fi
  "$PARAM" "$@"
}

cmd_regenerate_all() {
  require_cmd jq "emitting expected-hashes.json"
  require_cmd rsync "copying baseline media into matrix profiles"
  require_cmd shasum "emitting expected-hashes.json"
  require_ffmpeg
  ensure_executable
  cmd_baseline
  echo "=== author-hls matrix (full, ffmpeg required) ==="
  "$MAT"
  echo "regenerate-all complete."
}

if [ $# -lt 1 ]; then
  usage >&2
  exit 1
fi

CMD="$1"
shift || true

case "$CMD" in
  preflight) cmd_preflight "$@" ;;
  baseline) cmd_baseline "$@" ;;
  player-qa) cmd_player_qa "$@" ;;
  sdr-six-second) cmd_six_second_sdr "$@" ;;
  audio-topologies) ensure_executable; "$AUDIO_TOPOLOGIES" "$@" ;;
  jit-profiles) ensure_executable; "$JIT_PROFILES" "$@" ;;
  id3-profiles) ensure_executable; "$ID3_PROFILES" "$@" ;;
  validate-sdr-six-second) ensure_executable; "$VALIDATE_SIX_SECOND_SDR" "$@" ;;
  matrix) cmd_matrix "$@" ;;
  param) cmd_param "$@" ;;
  hashes) cmd_hashes "$@" ;;
  regenerate-all) cmd_regenerate_all "$@" ;;
  -h|--help|help) usage ;;
  *)
    echo "unknown subcommand: $CMD" >&2
    usage >&2
    exit 1
    ;;
esac
