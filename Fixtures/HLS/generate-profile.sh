#!/bin/bash
# Offline content-authoring script for a JoesProxy HLS fixture profile (P2-01/P2-06).
#
# NOT a runtime dependency: this is run once, by a developer, with a real ffmpeg install, to
# produce checked-in, deterministic HLS content. HLSFixtureServer never invokes ffmpeg — it only
# serves these already-generated files. See memlog/Research/HLS-CODECS-Testing-Roadmap.md
# "Phase 2" and the P2-optional task in the active plan for why a live encode is deliberately not
# the runtime path.
#
# Usage: generate-profile.sh <profile-dir> [--codecs] [--no-ad] [--bogus-ad] [--discontinuity]
#   [--duration <seconds>] [--video-segment <seconds>] [--audio-segment <seconds>]
#
# Produces, under <profile-dir>:
#   video-lo/   640x360  ~800k H.264, 4s TS segments
#   video-hi/   960x540 ~1400k H.264, 4s TS segments
#   audio-en/   English program audio, AAC, sine 440Hz
#   audio-ad/   English Audio Description, AAC, sine 880Hz (a distinct, audibly different tone)
#   master.m3u8
#
# Each video variant's picture is ffmpeg's built-in `testsrc` pattern, which already burns in a
# running timestamp (the "decimals" testsrc option controls precision) — no drawtext/libfreetype
# dependency required (this machine's ffmpeg build does not have it compiled in).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Fixtures/HLS/_lib.sh
. "$SCRIPT_DIR/_lib.sh"

PROFILE_DIR="${1:?usage: generate-profile.sh <profile-dir> [flags]}"
shift || true

WITH_CODECS=1
WITH_AD=1
BOGUS_AD=0
WITH_DISCONTINUITY=0
DURATION=24
SEGMENT_DURATION=4
AUDIO_SEGMENT_DURATION=4
while [ $# -gt 0 ]; do
  case "$1" in
    --no-codecs) WITH_CODECS=0; shift ;;
    --no-ad) WITH_AD=0; shift ;;
    --bogus-ad) BOGUS_AD=1; shift ;;
    --discontinuity) WITH_DISCONTINUITY=1; shift ;;
    --duration) DURATION="${2:?}"; shift 2 ;;
    --video-segment) SEGMENT_DURATION="${2:?}"; shift 2 ;;
    --audio-segment) AUDIO_SEGMENT_DURATION="${2:?}"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

require_ffmpeg

mkdir -p "$PROFILE_DIR"

gen_video() {
  local name="$1" size="$2" bitrate="$3"
  local dir="$PROFILE_DIR/$name"
  mkdir -p "$dir"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc=size=${size}:rate=25:duration=${DURATION}:decimals=2" \
    -an \
    -c:v libx264 -profile:v baseline -level 3.0 -pix_fmt yuv420p \
    -b:v "$bitrate" -maxrate "$bitrate" -bufsize "$bitrate" \
    -g 100 -keyint_min 100 -sc_threshold 0 \
    -f hls -hls_time "$SEGMENT_DURATION" -hls_playlist_type vod \
    -hls_segment_filename "$dir/seg-%03d.ts" \
    "$dir/stream.m3u8"
}

gen_audio() {
  local name="$1" freq="$2"
  local dir="$PROFILE_DIR/$name"
  mkdir -p "$dir"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "sine=frequency=${freq}:duration=${DURATION}:sample_rate=44100" \
    -vn \
    -c:a aac -b:a 96k -ac 2 \
    -f hls -hls_time "$AUDIO_SEGMENT_DURATION" -hls_playlist_type vod \
    -hls_segment_filename "$dir/seg-%03d.ts" \
    "$dir/stream.m3u8"
}

echo "Generating video-lo (640x360)..."
gen_video "video-lo" "640x360" "800k"
echo "Generating video-hi (960x540)..."
gen_video "video-hi" "960x540" "1400k"
echo "Generating audio-en (440Hz)..."
gen_audio "audio-en" 440

if [ "$WITH_AD" = "1" ]; then
  if [ "$BOGUS_AD" = "1" ]; then
    echo "Generating audio-ad as a bogus alias of audio-en (same tone, separate copy)..."
    gen_audio "audio-ad" 440
  else
    echo "Generating audio-ad (880Hz, audibly distinct)..."
    gen_audio "audio-ad" 880
  fi
fi

CODECS_ATTR=""
if [ "$WITH_CODECS" = "1" ]; then
  CODECS_ATTR=',CODECS="avc1.42001e,mp4a.40.2"'
fi

AUDIO_MEDIA=""
if [ "$WITH_AD" = "1" ]; then
  AUDIO_MEDIA=$(cat <<EOF
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio-en/stream.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English (Audio Description)",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",CHARACTERISTICS="public.accessibility.describes-video",URI="audio-ad/stream.m3u8"
EOF
)
else
  AUDIO_MEDIA=$(cat <<EOF
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio-en/stream.m3u8"
EOF
)
fi

cat > "$PROFILE_DIR/master.m3u8" <<EOF
#EXTM3U
#EXT-X-VERSION:3
$AUDIO_MEDIA
#EXT-X-STREAM-INF:BANDWIDTH=896000,AVERAGE-BANDWIDTH=800000,RESOLUTION=640x360${CODECS_ATTR},AUDIO="aud"
video-lo/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1568000,AVERAGE-BANDWIDTH=1400000,RESOLUTION=960x540${CODECS_ATTR},AUDIO="aud"
video-hi/stream.m3u8
EOF

if [ "$WITH_DISCONTINUITY" = "1" ]; then
  for f in "$PROFILE_DIR"/video-*/stream.m3u8 "$PROFILE_DIR"/audio-*/stream.m3u8; do
    [ -f "$f" ] || continue
    awk '
      BEGIN { seg = 0 }
      /^#EXTINF/ {
        seg++
        if (seg == 3) print "#EXT-X-DISCONTINUITY"
      }
      { print }
    ' "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
  done
fi

echo "Done: $PROFILE_DIR"
