#!/bin/bash
# Offline authoring for JIT and fine-grid hybrid audio profiles (HF-5):
# 1. audio-hybrid-inband-program-ad-fine-grid (6.0s A/V grid + 3.0s AD grid)
# 2. audio-hybrid-inband-program-ad-jit (hybrid A/V + scheduled JIT AD publication)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Fixtures/HLS/_lib.sh
. "$ROOT/_lib.sh"

DURATION=90
AUDIO_DURATION=89.978667
SEGMENT_DURATION=6
FINE_AD_SEGMENT_DURATION=3
BUNDLE_BUDGET_BYTES=26214400

require_ffmpeg
require_cmd ffprobe "validating authored codec, geometry, keyframe, and timestamp facts"
require_cmd jq "writing governed profile metadata"
require_cmd shasum "emitting expected hashes"

EMIT="$ROOT/emit-expected-hashes.sh"

gen_muxed_video() {
  local staging="$1" directory="$2" size="$3" crf="$4" level="$5"
  local destination="$staging/$directory"
  mkdir -p "$destination"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc=size=${size}:rate=30:duration=${DURATION}:decimals=2,drawgrid=width=iw/10:height=ih/10:thickness=2:color=white@0.45,drawbox=x=8:y=8:w=iw-16:h=ih-16:color=white@0.85:t=4" \
    -f lavfi -i "sine=frequency=440:duration=${AUDIO_DURATION}:sample_rate=48000,volume=0.08" \
    -c:v libx264 -preset veryfast -crf "$crf" -profile:v high -level:v "$level" -pix_fmt yuv420p \
    -g 180 -keyint_min 180 -sc_threshold 0 \
    -c:a aac -b:a 96000 -ac 2 \
    -f hls -hls_time "$SEGMENT_DURATION" -hls_playlist_type vod \
    -hls_segment_filename "$destination/seg-%03d.ts" \
    "$destination/stream.m3u8"
}

gen_audio_rendition_fine() {
  local staging="$1" directory="$2" freq="$3" seg_time="$4"
  local destination="$staging/$directory"
  mkdir -p "$destination"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "sine=frequency=${freq}:duration=${AUDIO_DURATION}:sample_rate=48000,volume=0.08" \
    -vn -c:a aac -b:a 96000 -ac 2 \
    -f hls -hls_time "$seg_time" -hls_playlist_type vod \
    -hls_segment_filename "$destination/seg-%03d.ts" \
    "$destination/stream.m3u8"
}

measure_variant() {
  local staging="$1" directory="$2" seg_dur="$3"
  local sum=0 peak=0 count=0
  for f in "$staging/$directory"/seg-*.ts; do
    local bytes duration bps
    bytes="$(stat -f '%z' "$f")"
    duration="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f")"
    bps="$(awk -v b="$bytes" -v d="$duration" 'BEGIN { printf "%d", (b * 8) / d }')"
    sum=$((sum + bytes))
    count=$((count + 1))
    if [ "$bps" -gt "$peak" ]; then peak="$bps"; fi
  done
  local total_duration avg
  total_duration="$(awk -v c="$count" -v d="$seg_dur" 'BEGIN { printf "%.6f", c * d }')"
  avg="$(awk -v s="$sum" -v d="$total_duration" 'BEGIN { printf "%d", (s * 8) / d }')"
  echo "$peak $avg"
}

author_fine_grid() {
  local profile_id="audio-hybrid-inband-program-ad-fine-grid"
  local dest="$ROOT/$profile_id"
  local staging="$ROOT/.${profile_id}-staging.$$"
  rm -rf "$dest" "$staging"
  mkdir -p "$staging"

  echo "Authoring $profile_id..."
  gen_muxed_video "$staging" "video-360" "640x360" "24" "3.1"
  gen_muxed_video "$staging" "video-720" "1280x720" "22" "4.0"
  gen_muxed_video "$staging" "video-1080" "1920x1080" "20" "4.1"
  gen_audio_rendition_fine "$staging" "audio-ad" "880" "$FINE_AD_SEGMENT_DURATION"

  local v360_p v360_a v720_p v720_a v1080_p v1080_a
  v360_p="$(measure_variant "$staging" "video-360" "$SEGMENT_DURATION" | awk '{print $1}')"
  v360_a="$(measure_variant "$staging" "video-360" "$SEGMENT_DURATION" | awk '{print $2}')"
  v720_p="$(measure_variant "$staging" "video-720" "$SEGMENT_DURATION" | awk '{print $1}')"
  v720_a="$(measure_variant "$staging" "video-720" "$SEGMENT_DURATION" | awk '{print $2}')"
  v1080_p="$(measure_variant "$staging" "video-1080" "$SEGMENT_DURATION" | awk '{print $1}')"
  v1080_a="$(measure_variant "$staging" "video-1080" "$SEGMENT_DURATION" | awk '{print $2}')"

  cat > "$staging/master.m3u8" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Program",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Audio Description",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",CHARACTERISTICS="public.accessibility.describes-video",URI="audio-ad/stream.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=${v360_p},AVERAGE-BANDWIDTH=${v360_a},RESOLUTION=640x360,FRAME-RATE=30.000,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"
video-360/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=${v720_p},AVERAGE-BANDWIDTH=${v720_a},RESOLUTION=1280x720,FRAME-RATE=30.000,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud"
video-720/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=${v1080_p},AVERAGE-BANDWIDTH=${v1080_a},RESOLUTION=1920x1080,FRAME-RATE=30.000,CODECS="avc1.640029,mp4a.40.2",AUDIO="aud"
video-1080/stream.m3u8
EOF

  cat > "$staging/profile.json" <<EOF
{
  "id": "$profile_id",
  "version": "1",
  "displayName": "Hybrid In-Band Program + Fine-Grid AD",
  "purpose": "Positive control where default audio is carried in-band and AD is delivered on a shorter 3-second physical grid.",
  "featureTags": ["positive-control", "audio-topology", "hybrid", "fine-grid", "alternate-audio", "audio-description", "aligned", "sdr", "avc", "aac", "abr"],
  "renditions": [
    {"width": 640, "height": 360, "bandwidth": $v360_p, "codecs": "avc1.64001f,mp4a.40.2"},
    {"width": 1280, "height": 720, "bandwidth": $v720_p, "codecs": "avc1.640028,mp4a.40.2"},
    {"width": 1920, "height": 1080, "bandwidth": $v1080_p, "codecs": "avc1.640029,mp4a.40.2"}
  ],
  "audioRenditions": [
    {
      "name": "English Program",
      "language": "en",
      "associatedLanguage": null,
      "channels": "2",
      "isDefault": true,
      "isAutoSelect": true,
      "characteristics": [],
      "audibleSignature": "440 Hz synthetic tone",
      "deliveryKind": "inBand",
      "variantsCarryingInBand": ["video-360", "video-720", "video-1080"],
      "publicationSchedule": "static",
      "segmentGridDuration": 6.0,
      "hasDiscontinuities": false
    },
    {
      "name": "English Audio Description",
      "language": "en",
      "associatedLanguage": "en",
      "channels": "2",
      "isDefault": false,
      "isAutoSelect": true,
      "characteristics": ["public.accessibility.describes-video"],
      "audibleSignature": "880 Hz synthetic AD tone",
      "deliveryKind": "uriBacked",
      "variantsCarryingInBand": [],
      "publicationSchedule": "static",
      "segmentGridDuration": 3.0,
      "hasDiscontinuities": false
    }
  ],
  "audioTopology": "hybridInBandProgramAD",
  "audioDescription": "Hybrid audio delivery with in-band 6s program audio and fine-grid 3s URI-backed AD.",
  "bundleSizeBudgetBytes": $BUNDLE_BUDGET_BYTES,
  "isRecommended": false,
  "conformanceClass": "conformantControl",
  "controlledFaults": [],
  "expectedClientBehavior": "Seamless switching between 6s in-band program audio and 3s fine-grid AD without timeline drift."
}
EOF

  mv "$staging" "$dest"
  "$EMIT" "$dest" --purpose "Hybrid in-band program + fine-grid AD audio topology positive control" --version "1"
}

author_jit() {
  local profile_id="audio-hybrid-inband-program-ad-jit"
  local dest="$ROOT/$profile_id"
  local staging="$ROOT/.${profile_id}-staging.$$"
  rm -rf "$dest" "$staging"
  mkdir -p "$staging"

  echo "Authoring $profile_id..."
  gen_muxed_video "$staging" "video-360" "640x360" "24" "3.1"
  gen_muxed_video "$staging" "video-720" "1280x720" "22" "4.0"
  gen_muxed_video "$staging" "video-1080" "1920x1080" "20" "4.1"
  gen_audio_rendition_fine "$staging" "audio-ad" "880" "$SEGMENT_DURATION"

  local v360_p v360_a v720_p v720_a v1080_p v1080_a
  v360_p="$(measure_variant "$staging" "video-360" "$SEGMENT_DURATION" | awk '{print $1}')"
  v360_a="$(measure_variant "$staging" "video-360" "$SEGMENT_DURATION" | awk '{print $2}')"
  v720_p="$(measure_variant "$staging" "video-720" "$SEGMENT_DURATION" | awk '{print $1}')"
  v720_a="$(measure_variant "$staging" "video-720" "$SEGMENT_DURATION" | awk '{print $2}')"
  v1080_p="$(measure_variant "$staging" "video-1080" "$SEGMENT_DURATION" | awk '{print $1}')"
  v1080_a="$(measure_variant "$staging" "video-1080" "$SEGMENT_DURATION" | awk '{print $2}')"

  cat > "$staging/master.m3u8" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Program",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Audio Description",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",CHARACTERISTICS="public.accessibility.describes-video",URI="audio-ad/stream.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=${v360_p},AVERAGE-BANDWIDTH=${v360_a},RESOLUTION=640x360,FRAME-RATE=30.000,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"
video-360/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=${v720_p},AVERAGE-BANDWIDTH=${v720_a},RESOLUTION=1280x720,FRAME-RATE=30.000,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud"
video-720/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=${v1080_p},AVERAGE-BANDWIDTH=${v1080_a},RESOLUTION=1920x1080,FRAME-RATE=30.000,CODECS="avc1.640029,mp4a.40.2",AUDIO="aud"
video-1080/stream.m3u8
EOF

  cat > "$staging/profile.json" <<EOF
{
  "id": "$profile_id",
  "version": "1",
  "displayName": "Hybrid In-Band Program + JIT AD",
  "purpose": "Simulated JIT alternate-audio publication near the moving live edge.",
  "featureTags": ["jit-publication", "hybrid", "audio-topology", "scheduled-publication", "live-edge", "alternate-audio", "audio-description", "aligned", "sdr", "avc", "aac"],
  "renditions": [
    {"width": 640, "height": 360, "bandwidth": $v360_p, "codecs": "avc1.64001f,mp4a.40.2"},
    {"width": 1280, "height": 720, "bandwidth": $v720_p, "codecs": "avc1.640028,mp4a.40.2"},
    {"width": 1920, "height": 1080, "bandwidth": $v1080_p, "codecs": "avc1.640029,mp4a.40.2"}
  ],
  "audioRenditions": [
    {
      "name": "English Program",
      "language": "en",
      "associatedLanguage": null,
      "channels": "2",
      "isDefault": true,
      "isAutoSelect": true,
      "characteristics": [],
      "audibleSignature": "440 Hz synthetic tone",
      "deliveryKind": "inBand",
      "variantsCarryingInBand": ["video-360", "video-720", "video-1080"],
      "publicationSchedule": "static",
      "segmentGridDuration": 6.0,
      "hasDiscontinuities": false
    },
    {
      "name": "English Audio Description",
      "language": "en",
      "associatedLanguage": "en",
      "channels": "2",
      "isDefault": false,
      "isAutoSelect": true,
      "characteristics": ["public.accessibility.describes-video"],
      "audibleSignature": "880 Hz synthetic AD tone",
      "deliveryKind": "uriBacked",
      "variantsCarryingInBand": [],
      "publicationSchedule": "scheduledJIT",
      "segmentGridDuration": 6.0,
      "hasDiscontinuities": false
    }
  ],
  "audioTopology": "hybridInBandProgramAD",
  "jitPublicationState": "current",
  "audioDescription": "Hybrid audio delivery with scheduled JIT AD rendition published near the live edge.",
  "bundleSizeBudgetBytes": $BUNDLE_BUDGET_BYTES,
  "isRecommended": false,
  "conformanceClass": "stressCase",
  "controlledFaults": [],
  "expectedClientBehavior": "Rendition switching should adapt to JIT publication lag and availability."
}
EOF

  mv "$staging" "$dest"
  "$EMIT" "$dest" --purpose "Hybrid in-band program + JIT AD audio topology profile" --version "1"
}

chmod +x "$EMIT"
author_fine_grid
author_jit
echo "JIT and Fine-Grid profiles successfully generated!"
