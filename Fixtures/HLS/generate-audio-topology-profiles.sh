#!/bin/bash
# Offline authoring for matched audio topology positive controls (HF-4):
# 1. audio-muxed-only-aligned (in-band program audio in all A/V variants)
# 2. audio-demuxed-all-aligned (video-only variants with separate program and AD audio playlists)
# 3. audio-hybrid-inband-program-ad-aligned (default in-band program audio + separate URI-backed AD)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Fixtures/HLS/_lib.sh
. "$ROOT/_lib.sh"

DURATION=90
AUDIO_DURATION=89.978667
SEGMENT_DURATION=6
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

gen_video_only() {
  local staging="$1" directory="$2" size="$3" crf="$4" level="$5"
  local destination="$staging/$directory"
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

gen_audio_rendition() {
  local staging="$1" directory="$2" freq="$3"
  local destination="$staging/$directory"
  mkdir -p "$destination"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "sine=frequency=${freq}:duration=${AUDIO_DURATION}:sample_rate=48000,volume=0.08" \
    -vn -c:a aac -b:a 96000 -ac 2 \
    -f hls -hls_time "$SEGMENT_DURATION" -hls_playlist_type vod \
    -hls_segment_filename "$destination/seg-%03d.ts" \
    "$destination/stream.m3u8"
}

measure_variant() {
  local staging="$1" directory="$2"
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
  total_duration="$(awk -v c="$count" -v d="$SEGMENT_DURATION" 'BEGIN { printf "%.6f", c * d }')"
  avg="$(awk -v s="$sum" -v d="$total_duration" 'BEGIN { printf "%d", (s * 8) / d }')"
  echo "$peak $avg"
}

author_muxed_only() {
  local profile_id="audio-muxed-only-aligned"
  local dest="$ROOT/$profile_id"
  local staging="$ROOT/.${profile_id}-staging.$$"
  rm -rf "$dest" "$staging"
  mkdir -p "$staging"

  echo "Authoring $profile_id..."
  gen_muxed_video "$staging" "video-360" "640x360" "24" "3.1"
  gen_muxed_video "$staging" "video-720" "1280x720" "22" "4.0"
  gen_muxed_video "$staging" "video-1080" "1920x1080" "20" "4.1"

  local v360_p v360_a v720_p v720_a v1080_p v1080_a
  v360_p="$(measure_variant "$staging" "video-360" | awk '{print $1}')"
  v360_a="$(measure_variant "$staging" "video-360" | awk '{print $2}')"
  v720_p="$(measure_variant "$staging" "video-720" | awk '{print $1}')"
  v720_a="$(measure_variant "$staging" "video-720" | awk '{print $2}')"
  v1080_p="$(measure_variant "$staging" "video-1080" | awk '{print $1}')"
  v1080_a="$(measure_variant "$staging" "video-1080" | awk '{print $2}')"

  cat > "$staging/master.m3u8" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=${v360_p},AVERAGE-BANDWIDTH=${v360_a},RESOLUTION=640x360,FRAME-RATE=30.000,CODECS="avc1.64001f,mp4a.40.2"
video-360/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=${v720_p},AVERAGE-BANDWIDTH=${v720_a},RESOLUTION=1280x720,FRAME-RATE=30.000,CODECS="avc1.640028,mp4a.40.2"
video-720/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=${v1080_p},AVERAGE-BANDWIDTH=${v1080_a},RESOLUTION=1920x1080,FRAME-RATE=30.000,CODECS="avc1.640029,mp4a.40.2"
video-1080/stream.m3u8
EOF

  cat > "$staging/profile.json" <<EOF
{
  "id": "$profile_id",
  "version": "1",
  "displayName": "Muxed-Only Aligned Audio",
  "purpose": "Positive control where all A/V variants carry in-band program audio without a separate audio group.",
  "featureTags": ["positive-control", "audio-topology", "muxed-only", "aligned", "sdr", "avc", "aac", "abr", "six-second-grid"],
  "renditions": [
    {"width": 640, "height": 360, "bandwidth": $v360_p, "codecs": "avc1.64001f,mp4a.40.2"},
    {"width": 1280, "height": 720, "bandwidth": $v720_p, "codecs": "avc1.640028,mp4a.40.2"},
    {"width": 1920, "height": 1080, "bandwidth": $v1080_p, "codecs": "avc1.640029,mp4a.40.2"}
  ],
  "audioRenditions": [
    {
      "name": "In-Band Program Audio",
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
    }
  ],
  "audioTopology": "muxedOnly",
  "audioDescription": "Multiplexed program audio carried within each A/V variant transport stream.",
  "bundleSizeBudgetBytes": $BUNDLE_BUDGET_BYTES,
  "isRecommended": false,
  "conformanceClass": "conformantControl",
  "controlledFaults": [],
  "expectedClientBehavior": "Stable playback across variant switches without independent audio playlist requests."
}
EOF

  mv "$staging" "$dest"
  "$EMIT" "$dest" --purpose "Muxed-only audio topology positive control" --version "1"
}

author_demuxed_all() {
  local profile_id="audio-demuxed-all-aligned"
  local dest="$ROOT/$profile_id"
  local staging="$ROOT/.${profile_id}-staging.$$"
  rm -rf "$dest" "$staging"
  mkdir -p "$staging"

  echo "Authoring $profile_id..."
  gen_video_only "$staging" "video-360" "640x360" "24" "3.1"
  gen_video_only "$staging" "video-720" "1280x720" "22" "4.0"
  gen_video_only "$staging" "video-1080" "1920x1080" "20" "4.1"
  gen_audio_rendition "$staging" "audio-en" "440"
  gen_audio_rendition "$staging" "audio-ad" "880"

  local v360_p v360_a v720_p v720_a v1080_p v1080_a
  v360_p="$(measure_variant "$staging" "video-360" | awk '{print $1}')"
  v360_a="$(measure_variant "$staging" "video-360" | awk '{print $2}')"
  v720_p="$(measure_variant "$staging" "video-720" | awk '{print $1}')"
  v720_a="$(measure_variant "$staging" "video-720" | awk '{print $2}')"
  v1080_p="$(measure_variant "$staging" "video-1080" | awk '{print $1}')"
  v1080_a="$(measure_variant "$staging" "video-1080" | awk '{print $2}')"

  cat > "$staging/master.m3u8" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Program",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio-en/stream.m3u8"
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
  "displayName": "Demuxed-All Aligned Audio",
  "purpose": "Positive control where video-only variants reference an audio group with separate program and AD playlists.",
  "featureTags": ["positive-control", "audio-topology", "demuxed-all", "alternate-audio", "audio-description", "aligned", "sdr", "avc", "aac", "abr", "six-second-grid"],
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
      "deliveryKind": "uriBacked",
      "variantsCarryingInBand": [],
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
      "segmentGridDuration": 6.0,
      "hasDiscontinuities": false
    }
  ],
  "audioTopology": "demuxedAll",
  "audioDescription": "Fully demuxed audio group with separate URI-backed program audio and audio description renditions.",
  "bundleSizeBudgetBytes": $BUNDLE_BUDGET_BYTES,
  "isRecommended": false,
  "conformanceClass": "conformantControl",
  "controlledFaults": [],
  "expectedClientBehavior": "Seamless switching between Program and AD renditions on the same aligned 6-second segment grid."
}
EOF

  mv "$staging" "$dest"
  "$EMIT" "$dest" --purpose "Demuxed-all audio topology positive control" --version "1"
}

author_hybrid_inband() {
  local profile_id="audio-hybrid-inband-program-ad-aligned"
  local dest="$ROOT/$profile_id"
  local staging="$ROOT/.${profile_id}-staging.$$"
  rm -rf "$dest" "$staging"
  mkdir -p "$staging"

  echo "Authoring $profile_id..."
  gen_muxed_video "$staging" "video-360" "640x360" "24" "3.1"
  gen_muxed_video "$staging" "video-720" "1280x720" "22" "4.0"
  gen_muxed_video "$staging" "video-1080" "1920x1080" "20" "4.1"
  gen_audio_rendition "$staging" "audio-ad" "880"

  local v360_p v360_a v720_p v720_a v1080_p v1080_a
  v360_p="$(measure_variant "$staging" "video-360" | awk '{print $1}')"
  v360_a="$(measure_variant "$staging" "video-360" | awk '{print $2}')"
  v720_p="$(measure_variant "$staging" "video-720" | awk '{print $1}')"
  v720_a="$(measure_variant "$staging" "video-720" | awk '{print $2}')"
  v1080_p="$(measure_variant "$staging" "video-1080" | awk '{print $1}')"
  v1080_a="$(measure_variant "$staging" "video-1080" | awk '{print $2}')"

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
  "displayName": "Hybrid In-Band Program + AD Aligned",
  "purpose": "Positive control where default audio is carried in-band and AD is delivered as a URI-backed alternate rendition.",
  "featureTags": ["positive-control", "audio-topology", "hybrid", "alternate-audio", "audio-description", "aligned", "sdr", "avc", "aac", "abr", "six-second-grid"],
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
      "segmentGridDuration": 6.0,
      "hasDiscontinuities": false
    }
  ],
  "audioTopology": "hybridInBandProgramAD",
  "audioDescription": "Hybrid audio delivery with default in-band program audio in all A/V variants and a URI-backed AD rendition.",
  "bundleSizeBudgetBytes": $BUNDLE_BUDGET_BYTES,
  "isRecommended": false,
  "conformanceClass": "conformantControl",
  "controlledFaults": [],
  "expectedClientBehavior": "Bidirectional switching between in-band program audio and URI-backed audio description."
}
EOF

  mv "$staging" "$dest"
  "$EMIT" "$dest" --purpose "Hybrid in-band program + AD audio topology positive control" --version "1"
}

chmod +x "$EMIT"
author_muxed_only
author_demuxed_all
author_hybrid_inband
echo "All 3 audio topology profiles successfully generated!"
