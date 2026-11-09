#!/usr/bin/env bash
# Emit expected post-switch audio segment URI paths for a JoePlayer trial.
#
# Preferred path (observed join + fixture cycle order):
#   After the harness sees the first real post-switch target segment GET, emit the next
#   N URIs by walking the fixture's authored segment list as a cycle starting at that URI.
#   This does **not** map switchTimeSeconds → index from 0 (the timing bug). It only uses
#   static files for URI succession topology — the same cycle `HLSSlidingPlaylistComputer`
#   uses when rendering windows.
#
# Live playlist snapshot (optional companion artifact from the trial suite) records
# MEDIA-SEQUENCE forensics; classification anchors on the observed first GET.
#
# Usage:
#   emit_expected_segments.sh --anchor-uri audio-ad/seg-007.ts --profile <id> \
#     --audio-target ad [--window 4]
#   emit_expected_segments.sh --live-playlist <m3u8> --audio-target ad [--window 4] \
#     [--align-uri audio-ad/seg-003.ts]
#   emit_expected_segments.sh --profile <id> --audio-target ad --offset-seconds -0.5 [--window 4]
#     (legacy static timing walk — trial suite no longer uses this)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=memlog/utility_scripts/joeplayer_suite/lib.sh
. "$SCRIPT_DIR/lib.sh"

PROFILE=""
AUDIO_TARGET="ad"
OFFSET_SECONDS="0"
WINDOW_COUNT="4"
LIVE_PLAYLIST=""
ALIGN_URI=""
ANCHOR_URI=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --audio-target) AUDIO_TARGET="${2:?}"; shift 2 ;;
    --offset-seconds) OFFSET_SECONDS="${2:?}"; shift 2 ;;
    --window) WINDOW_COUNT="${2:?}"; shift 2 ;;
    --live-playlist) LIVE_PLAYLIST="${2:?}"; shift 2 ;;
    --align-uri) ALIGN_URI="${2:?}"; shift 2 ;;
    --anchor-uri) ANCHOR_URI="${2:?}"; shift 2 ;;
    -h|--help)
      echo "usage: $0 --anchor-uri <path> --profile <id> --audio-target <target> [--window 4]"
      echo "   or: $0 --live-playlist <m3u8> --audio-target <target> [--window 4] [--align-uri <path>]"
      echo "   or: $0 --profile <id> --audio-target <target> [--offset-seconds <s>] [--window 4]"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

rendition="audio-${AUDIO_TARGET}"

emit_from_live_playlist() {
  local playlist="$1"
  local align_leaf=""
  if [[ -n "$ALIGN_URI" ]]; then
    align_leaf="${ALIGN_URI##*/}"
  fi

  awk -v window="$WINDOW_COUNT" -v rendition="$rendition" -v align_leaf="$align_leaf" '
    BEGIN {
      count = 0
      media_sequence = -1
    }
    /^#EXT-X-MEDIA-SEQUENCE:/ {
      split($0, parts, ":")
      media_sequence = parts[2] + 0
      next
    }
    /^[^#].+\.ts$/ {
      uris[count++] = $0
      next
    }
    END {
      start = 0
      if (align_leaf != "") {
        for (i = 0; i < count; i++) {
          leaf = uris[i]
          sub(/.*\//, "", leaf)
          if (leaf == align_leaf || uris[i] == align_leaf) {
            start = i
            break
          }
        }
      }
      emitted = 0
      for (i = start; i < count && emitted < window; i++) {
        uri = uris[i]
        if (uri ~ /^audio-[a-z]+\//) {
          print uri
        } else {
          printf "%s/%s\n", rendition, uri
        }
        emitted++
      }
      if (emitted == 0) {
        exit 1
      }
    }
  ' "$playlist"
}

emit_from_anchor_cycle() {
  local playlist="$1"
  local anchor_leaf="${ANCHOR_URI##*/}"

  awk -v window="$WINDOW_COUNT" -v rendition="$rendition" -v anchor_leaf="$anchor_leaf" '
    BEGIN { count = 0 }
    /^[^#].+\.ts$/ {
      leaf = $0
      sub(/.*\//, "", leaf)
      uris[count++] = leaf
      next
    }
    END {
      if (count == 0) exit 1
      start = -1
      for (i = 0; i < count; i++) {
        if (uris[i] == anchor_leaf) {
          start = i
          break
        }
      }
      if (start < 0) exit 1
      for (emitted = 0; emitted < window; emitted++) {
        idx = (start + emitted) % count
        printf "%s/%s\n", rendition, uris[idx]
      }
    }
  ' "$playlist"
}

if [[ -n "$LIVE_PLAYLIST" ]]; then
  [[ -f "$LIVE_PLAYLIST" ]] || die "Missing live playlist: $LIVE_PLAYLIST"
  emit_from_live_playlist "$LIVE_PLAYLIST"
  exit 0
fi

if [[ -n "$ANCHOR_URI" ]]; then
  [[ -n "$PROFILE" ]] || die "--anchor-uri requires --profile"
  metadata_file="$SCRIPT_DIR/profile_metadata.json"
  profile_dir="$FIXTURES_HLS/$PROFILE"
  mapped="$(jq -r --arg profile "$PROFILE" --arg target "$AUDIO_TARGET" \
    '.[$profile].audioRenditionForTarget[$target] // empty' "$metadata_file")"
  [[ -n "$mapped" ]] || die "No audio rendition mapping for profile=$PROFILE target=$AUDIO_TARGET"
  rendition="$mapped"
  playlist="$profile_dir/$rendition/stream.m3u8"
  [[ -f "$playlist" ]] || die "Missing playlist: $playlist"
  emit_from_anchor_cycle "$playlist"
  exit 0
fi

[[ -n "$PROFILE" ]] || { echo "missing --profile, --anchor-uri, or --live-playlist" >&2; exit 2; }

log "WARNING: static playlist timing walk is legacy; prefer --anchor-uri for trial classification"

metadata_file="$SCRIPT_DIR/profile_metadata.json"
profile_dir="$FIXTURES_HLS/$PROFILE"

mapped="$(jq -r --arg profile "$PROFILE" --arg target "$AUDIO_TARGET" \
  '.[$profile].audioRenditionForTarget[$target] // empty' "$metadata_file")"
[[ -n "$mapped" ]] || die "No audio rendition mapping for profile=$PROFILE target=$AUDIO_TARGET"
rendition="$mapped"

playlist="$profile_dir/$rendition/stream.m3u8"
[[ -f "$playlist" ]] || die "Missing playlist: $playlist"

boundary="$(jq -r --arg profile "$PROFILE" --arg target "$AUDIO_TARGET" \
  '.[$profile].discontinuityBoundarySeconds[$target] // empty' "$metadata_file")"
[[ -n "$boundary" ]] || die "No discontinuity boundary for profile=$PROFILE target=$AUDIO_TARGET"

switch_time="$(awk -v b="$boundary" -v o="$OFFSET_SECONDS" 'BEGIN { printf "%.6f", b + o }')"

awk -v switch_time="$switch_time" -v window="$WINDOW_COUNT" -v rendition="$rendition" '
  BEGIN {
    seg_index = 0
    cumulative = 0
    start_index = -1
    pending_duration = 0
  }
  /^#EXTINF:/ {
    split($0, parts, ":")
    gsub(/,.*/, "", parts[2])
    pending_duration = parts[2] + 0
    if (start_index < 0 && cumulative + pending_duration >= switch_time) {
      start_index = seg_index
    }
    cumulative += pending_duration
    next
  }
  /^[^#].+\.ts$/ {
    uris[seg_index] = $0
    seg_index++
    next
  }
  END {
    if (start_index < 0) {
      start_index = 0
    }
    emitted = 0
    for (i = start_index; i < seg_index && emitted < window; i++) {
      printf "%s/%s\n", rendition, uris[i]
      emitted++
    }
  }
' "$playlist"
