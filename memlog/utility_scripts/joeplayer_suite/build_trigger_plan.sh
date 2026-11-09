#!/usr/bin/env bash
# Build a base64 JoePlayer trigger-plan launch argument.
#
# Usage:
#   build_trigger_plan.sh --switch-time 8.5 --audio-target ad [--play-at 0.1]
set -euo pipefail

SWITCH_TIME=""
AUDIO_TARGET="ad"
PLAY_AT="0.1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --switch-time) SWITCH_TIME="${2:?}"; shift 2 ;;
    --audio-target) AUDIO_TARGET="${2:?}"; shift 2 ;;
    --play-at) PLAY_AT="${2:?}"; shift 2 ;;
    -h|--help)
      echo "usage: $0 --switch-time <seconds> [--audio-target ad|en|es] [--play-at 0.1]"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SWITCH_TIME" ]] || { echo "missing --switch-time" >&2; exit 2; }

plan_json=$(jq -nc \
  --argjson playAt "$PLAY_AT" \
  --argjson switchTime "$SWITCH_TIME" \
  --arg target "$AUDIO_TARGET" \
  '{
    actions: [
      {atPlayerTimeSeconds: $playAt, action: "play", target: null},
      {atPlayerTimeSeconds: $switchTime, action: "selectAudio", target: $target}
    ]
  }')

encoded="$(printf '%s' "$plan_json" | base64 | tr -d '\n')"
printf '%s\n' "--joeplayer-trigger-plan=$encoded"
printf '%s\n' "$plan_json" >&2
