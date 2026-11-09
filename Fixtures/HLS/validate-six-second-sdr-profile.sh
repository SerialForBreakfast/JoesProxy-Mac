#!/bin/bash
# Read-only offline validation for the nominal-six-second SDR positive control.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Fixtures/HLS/_lib.sh
. "$ROOT/_lib.sh"

PROFILE="${1:-$ROOT/sdr-six-second-positive-v1}"
PROFILE="$(cd "$PROFILE" && pwd)"
case "$PROFILE" in
  "$ROOT"/*) ;;
  *) echo "Profile must be inside $ROOT" >&2; exit 1 ;;
esac

require_cmd ffprobe "inspecting authored HLS fixture bitstreams"
require_cmd jq "reading bounded ffprobe output"

validate_playlist_shape() {
  local playlist="$1" count target end_list total_duration
  count="$(awk '/^[^#].*\.ts([?].*)?$/ {count += 1} END {print count + 0}' "$playlist")"
  target="$(awk -F: '/^#EXT-X-TARGETDURATION:/ {print $2}' "$playlist")"
  end_list="$(awk '/^#EXT-X-ENDLIST$/ {found = 1} END {print found + 0}' "$playlist")"
  total_duration="$(awk -F'[:,]' '/^#EXTINF:/ {total += $2} END {printf "%.6f", total}' "$playlist")"
  if [ "$count" -ne 15 ] || [ "$target" -ne 6 ] || [ "$end_list" -ne 1 ]; then
    echo "Invalid six-second playlist shape: $playlist" >&2
    exit 1
  fi
  awk -v duration="$total_duration" 'BEGIN {exit !(duration >= 89.95 && duration <= 90.05)}' || {
    echo "Playlist duration is not approximately 90 seconds: $playlist ($total_duration)" >&2
    exit 1
  }
}

first_packet_pts() {
  local selector="$1" segment="$2"
  ffprobe -v error -select_streams "$selector" -read_intervals '%+#1' -show_packets \
    -show_entries packet=pts_time -of json "$segment" | jq -r '.packets[0].pts_time // empty'
}

validate_segment_timeline() {
  local directory="$1" selector="$2" expect_keyframe="$3"
  local segment pts previous=""
  for segment in "$directory"/seg-*.ts; do
    pts="$(first_packet_pts "$selector" "$segment")"
    if [ -z "$pts" ]; then
      echo "Missing first packet timestamp: $segment" >&2
      exit 1
    fi
    if [ -n "$previous" ]; then
      awk -v current="$pts" -v prior="$previous" \
        'BEGIN {delta = current - prior; exit !(delta >= 5.95 && delta <= 6.05)}' || {
        echo "Segment timestamp step is not approximately six seconds: $segment" >&2
        exit 1
      }
    fi
    previous="$pts"

    if [ "$expect_keyframe" = "1" ]; then
      local keyframe
      keyframe="$(ffprobe -v error -select_streams "$selector" -read_intervals '%+#1' \
        -show_frames -show_entries frame=key_frame -of json "$segment" \
        | jq -r '.frames[0].key_frame // 0')"
      if [ "$keyframe" -ne 1 ]; then
        echo "Video segment does not begin with a keyframe: $segment" >&2
        exit 1
      fi
    fi
  done
}

validate_video_stream() {
  local segment="$1" width="$2" height="$3" level="$4"
  ffprobe -v error -select_streams v:0 -show_entries \
    stream=codec_name,profile,level,width,height,pix_fmt,r_frame_rate -of json "$segment" \
    | jq -e --argjson width "$width" --argjson height "$height" --argjson level "$level" '
        .streams[0]
        | .codec_name == "h264"
          and .profile == "High"
          and .level == $level
          and .width == $width
          and .height == $height
          and .pix_fmt == "yuv420p"
          and .r_frame_rate == "30/1"
      ' >/dev/null
}

validate_audio_stream() {
  ffprobe -v error -select_streams a:0 -show_entries \
    stream=codec_name,profile,sample_rate,channels -of json "$1" \
    | jq -e '
        .streams[0]
        | .codec_name == "aac"
          and .profile == "LC"
          and .sample_rate == "48000"
          and .channels == 2
      ' >/dev/null
}

for rendition in video-360 video-720 video-1080 audio-en; do
  validate_playlist_shape "$PROFILE/$rendition/stream.m3u8"
done

validate_video_stream "$PROFILE/video-360/seg-000.ts" 640 360 31
validate_video_stream "$PROFILE/video-720/seg-000.ts" 1280 720 40
validate_video_stream "$PROFILE/video-1080/seg-000.ts" 1920 1080 41
validate_audio_stream "$PROFILE/audio-en/seg-000.ts"
validate_segment_timeline "$PROFILE/video-360" v:0 1
validate_segment_timeline "$PROFILE/video-720" v:0 1
validate_segment_timeline "$PROFILE/video-1080" v:0 1
validate_segment_timeline "$PROFILE/audio-en" a:0 0

echo "Six-second SDR bounded bitstream validation passed: $PROFILE"
