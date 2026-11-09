#!/bin/bash
# Offline-only authoring for the nominal-six-second SDR AVC/AAC positive control.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Fixtures/HLS/_lib.sh
. "$ROOT/_lib.sh"

PROFILE_ID="sdr-six-second-positive-v1"
PROFILE="$ROOT/$PROFILE_ID"
STAGING="$ROOT/.${PROFILE_ID}-staging.$$"
DURATION=90
AUDIO_DURATION=89.978667
SEGMENT_DURATION=6
BUNDLE_BUDGET_BYTES=25165824

require_ffmpeg
require_cmd ffprobe "validating authored codec, geometry, keyframe, and timestamp facts"
require_cmd jq "writing governed profile metadata"

if [ -e "$PROFILE" ]; then
  echo "$PROFILE_ID already exists; remove it manually only when intentionally regenerating it." >&2
  exit 1
fi
if [ -e "$STAGING" ]; then
  echo "Refusing to reuse unexpected staging path: $STAGING" >&2
  exit 1
fi

cleanup() {
  if [ -d "$STAGING" ]; then
    rm -rf "$STAGING"
  fi
}
trap cleanup EXIT
mkdir -p "$STAGING"

generate_video() {
  local directory="$1" size="$2" crf="$3" level="$4"
  local destination="$STAGING/$directory"
  mkdir -p "$destination"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc=size=${size}:rate=30:duration=${DURATION}:decimals=2,drawgrid=width=iw/10:height=ih/10:thickness=2:color=white@0.45,drawbox=x=8:y=8:w=iw-16:h=ih-16:color=white@0.85:t=4" \
    -an \
    -c:v libx264 -preset veryfast -crf "$crf" -profile:v high -level:v "$level" -pix_fmt yuv420p \
    -g 180 -keyint_min 180 -sc_threshold 0 \
    -f hls -hls_time "$SEGMENT_DURATION" -hls_playlist_type vod \
    -hls_segment_filename "$destination/seg-%03d.ts" \
    "$destination/stream.m3u8"
}

generate_audio() {
  local destination="$STAGING/audio-en"
  mkdir -p "$destination"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "sine=frequency=440:duration=${AUDIO_DURATION}:sample_rate=48000,volume=0.08" \
    -vn -c:a aac -b:a 96000 -ac 2 \
    -f hls -hls_time "$SEGMENT_DURATION" -hls_playlist_type vod \
    -hls_segment_filename "$destination/seg-%03d.ts" \
    "$destination/stream.m3u8"
}

measure_playlist() {
  local directory="$1"
  awk -v base="$directory" '
    /^#EXTINF:/ {
      duration = $0
      sub(/^#EXTINF:/, "", duration)
      sub(/,.*/, "", duration)
      next
    }
    /^[^#]/ && duration > 0 {
      command = "wc -c < \"" base "/" $0 "\""
      command | getline bytes
      close(command)
      rate = bytes * 8 / duration
      if (rate > peak) peak = rate
      totalBytes += bytes
      totalDuration += duration
      count += 1
      duration = 0
    }
    END {
      average = totalDuration > 0 ? totalBytes * 8 / totalDuration : 0
      printf "%.0f %.0f %.6f %d\n", peak + 0.499, average + 0.499, totalDuration, count
    }
  ' "$directory/stream.m3u8"
}

verify_video_segments_start_with_keyframes() {
  local directory="$1" segment first_keyframe
  for segment in "$directory"/seg-*.ts; do
    first_keyframe="$(ffprobe -v error -select_streams v:0 -read_intervals '%+#1' -show_frames \
      -show_entries frame=key_frame -of json "$segment" | jq -r '.frames[0].key_frame // 0')"
    if [ "$first_keyframe" != "1" ]; then
      echo "Video segment does not begin with a keyframe: $segment" >&2
      exit 1
    fi
  done
}

generate_video "video-360" "640x360" "29" "3.1"
generate_video "video-720" "1280x720" "30" "4.0"
generate_video "video-1080" "1920x1080" "31" "4.1"
generate_audio

verify_video_segments_start_with_keyframes "$STAGING/video-360"
verify_video_segments_start_with_keyframes "$STAGING/video-720"
verify_video_segments_start_with_keyframes "$STAGING/video-1080"

VIDEO_360_METRICS=( $(measure_playlist "$STAGING/video-360") )
VIDEO_720_METRICS=( $(measure_playlist "$STAGING/video-720") )
VIDEO_1080_METRICS=( $(measure_playlist "$STAGING/video-1080") )
AUDIO_METRICS=( $(measure_playlist "$STAGING/audio-en") )

for metrics in VIDEO_360_METRICS VIDEO_720_METRICS VIDEO_1080_METRICS AUDIO_METRICS; do
  eval "count=\${${metrics}[3]}"
  if [ "$count" -ne 15 ]; then
    echo "Expected 15 authored segments for $metrics, found $count." >&2
    exit 1
  fi
done

VIDEO_360_BANDWIDTH=$((VIDEO_360_METRICS[0] + AUDIO_METRICS[0]))
VIDEO_360_AVERAGE=$((VIDEO_360_METRICS[1] + AUDIO_METRICS[1]))
VIDEO_720_BANDWIDTH=$((VIDEO_720_METRICS[0] + AUDIO_METRICS[0]))
VIDEO_720_AVERAGE=$((VIDEO_720_METRICS[1] + AUDIO_METRICS[1]))
VIDEO_1080_BANDWIDTH=$((VIDEO_1080_METRICS[0] + AUDIO_METRICS[0]))
VIDEO_1080_AVERAGE=$((VIDEO_1080_METRICS[1] + AUDIO_METRICS[1]))

cat > "$STAGING/master.m3u8" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Program",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio-en/stream.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=${VIDEO_360_BANDWIDTH},AVERAGE-BANDWIDTH=${VIDEO_360_AVERAGE},RESOLUTION=640x360,FRAME-RATE=30.000,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"
video-360/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=${VIDEO_720_BANDWIDTH},AVERAGE-BANDWIDTH=${VIDEO_720_AVERAGE},RESOLUTION=1280x720,FRAME-RATE=30.000,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud"
video-720/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=${VIDEO_1080_BANDWIDTH},AVERAGE-BANDWIDTH=${VIDEO_1080_AVERAGE},RESOLUTION=1920x1080,FRAME-RATE=30.000,CODECS="avc1.640029,mp4a.40.2",AUDIO="aud"
video-1080/stream.m3u8
EOF

FFMPEG_VERSION="$(ffmpeg_version_line)"
FFPROBE_VERSION="$(ffprobe -version 2>/dev/null | sed -n '1p')"
cat > "$STAGING/profile.json" <<EOF
{
  "id": "$PROFILE_ID",
  "version": "1",
  "displayName": "Six-Second SDR Positive Control",
  "purpose": "Nominal-six-second SDR AVC/AAC positive control with a continuous 90-second synthetic timeline.",
  "featureTags": ["positive-control", "sdr", "avc", "aac", "abr", "six-second-grid", "live-loop", "live-time-shifting-ready", "synthetic-media"],
  "renditions": [
    {"width": 640, "height": 360, "bandwidth": $VIDEO_360_BANDWIDTH, "codecs": "avc1.64001f,mp4a.40.2"},
    {"width": 1280, "height": 720, "bandwidth": $VIDEO_720_BANDWIDTH, "codecs": "avc1.640028,mp4a.40.2"},
    {"width": 1920, "height": 1080, "bandwidth": $VIDEO_1080_BANDWIDTH, "codecs": "avc1.640029,mp4a.40.2"}
  ],
  "audioRenditions": [
    {"name": "English Program", "language": "en", "associatedLanguage": null, "channels": "2", "isDefault": true, "isAutoSelect": true, "characteristics": [], "audibleSignature": "440 Hz synthetic tone"}
  ],
  "audioDescription": "One aligned stereo AAC-LC 48 kHz synthetic program-audio rendition; no speech or third-party media.",
  "bundleSizeBudgetBytes": $BUNDLE_BUDGET_BYTES,
  "isRecommended": true,
  "conformanceClass": "conformantControl",
  "controlledFaults": [],
  "expectedClientBehavior": "Stable VOD, conventional live-loop, ABR, and bounded live-time-shifting playback.",
  "sourceProvenance": {
    "kind": "project-authored synthetic lavfi sources",
    "video": "testsrc with deterministic grid and border overlays",
    "audio": "440 Hz sine tone",
    "durationSeconds": 90,
    "authoringCommand": "Fixtures/HLS/author-hls.sh sdr-six-second",
    "ffmpegVersion": $(jq -Rn --arg value "$FFMPEG_VERSION" '$value'),
    "ffprobeVersion": $(jq -Rn --arg value "$FFPROBE_VERSION" '$value')
  },
  "mediaFacts": {
    "container": "MPEG-2 transport stream",
    "videoCodec": "H.264/AVC High, yuv420p, 30 fps",
    "audioCodec": "AAC-LC, 48 kHz, stereo",
    "segmentDurationSeconds": 6,
    "segmentCountPerRendition": 15,
    "continuousTimelineSeconds": 90,
    "videoSegmentStarts": "IDR/keyframe verified by ffprobe",
    "measuredVariantBandwidthBitsPerSecond": [$VIDEO_360_BANDWIDTH, $VIDEO_720_BANDWIDTH, $VIDEO_1080_BANDWIDTH],
    "measuredVariantAverageBandwidthBitsPerSecond": [$VIDEO_360_AVERAGE, $VIDEO_720_AVERAGE, $VIDEO_1080_AVERAGE]
  },
  "validationStatus": {
    "boundedBitstreamInspection": "passed during offline authoring",
    "repositoryHashValidation": "governed by expected-hashes.json and HLSFixtureProfileMatrixTests",
    "httpOriginValidation": "governed by HLSFixtureServerTests",
    "officialHLSValidator": "not run: mediastreamvalidator was unavailable on the authoring host"
  }
}
EOF

TOTAL_BYTES="$(find "$STAGING" -type f -exec stat -f '%z' {} \; | awk '{total += $1} END {print total + 0}')"
if [ "$TOTAL_BYTES" -gt "$BUNDLE_BUDGET_BYTES" ]; then
  echo "Authored profile is $TOTAL_BYTES bytes, exceeding budget $BUNDLE_BUDGET_BYTES." >&2
  exit 1
fi

mv "$STAGING" "$PROFILE"
trap - EXIT
echo "Six-second SDR profile authored at $PROFILE ($TOTAL_BYTES bytes before hash inventory)."
