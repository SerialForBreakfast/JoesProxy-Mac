#!/bin/bash
# Offline-only authoring for the first-class widescreen player QA fixture.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Fixtures/HLS/_lib.sh
. "$ROOT/_lib.sh"

PROFILE="$ROOT/player-qa-widescreen-v1"
DURATION=24
AUDIO_DURATION=23.978667
SEGMENT_DURATION=4

require_ffmpeg
mkdir -p "$PROFILE"

generate_video() {
  local directory="$1" size="$2" bitrate="$3" level="$4"
  local destination="$PROFILE/$directory"
  mkdir -p "$destination"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc=size=${size}:rate=30:duration=${DURATION}:decimals=2,drawgrid=width=iw/10:height=ih/10:thickness=2:color=white@0.45,drawbox=x=8:y=8:w=iw-16:h=ih-16:color=white@0.85:t=4" \
    -an \
    -c:v libx264 -profile:v high -level:v "$level" -pix_fmt yuv420p \
    -b:v "$bitrate" -maxrate "$bitrate" -bufsize "$bitrate" \
    -g 120 -keyint_min 120 -sc_threshold 0 \
    -f hls -hls_time "$SEGMENT_DURATION" -hls_playlist_type vod \
    -hls_segment_filename "$destination/seg-%03d.ts" \
    "$destination/stream.m3u8"
}

generate_tone_audio() {
  local directory="$1" frequency="$2"
  local destination="$PROFILE/$directory"
  mkdir -p "$destination"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "sine=frequency=${frequency}:duration=${AUDIO_DURATION}:sample_rate=48000,volume=0.08" \
    -vn -c:a aac -b:a 128k -ac 2 \
    -f hls -hls_time "$SEGMENT_DURATION" -hls_playlist_type vod \
    -hls_segment_filename "$destination/seg-%03d.ts" \
    "$destination/stream.m3u8"
}

generate_description_audio() {
  local destination="$PROFILE/audio-ad"
  mkdir -p "$destination"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "sine=frequency=440:duration=${AUDIO_DURATION}:sample_rate=48000,volume=0.055" \
    -f lavfi -i "sine=frequency=1000:duration=${AUDIO_DURATION}:sample_rate=48000,volume=0.035" \
    -filter_complex "[0:a][1:a]amix=inputs=2:duration=shortest:normalize=0[a]" \
    -map "[a]" -vn -c:a aac -b:a 128k -ac 2 \
    -f hls -hls_time "$SEGMENT_DURATION" -hls_playlist_type vod \
    -hls_segment_filename "$destination/seg-%03d.ts" \
    "$destination/stream.m3u8"
}

generate_video "video-360" "640x360" "800k" "3.1"
generate_video "video-720" "1280x720" "2200k" "4.0"
generate_video "video-1080" "1920x1080" "4500k" "4.1"
generate_tone_audio "audio-en" "440"
generate_description_audio
generate_tone_audio "audio-es" "660"
generate_tone_audio "audio-de" "330"

cat > "$PROFILE/master.m3u8" <<'EOF'
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Program",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio-en/stream.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Audio Description",LANGUAGE="en",ASSOC-LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,CHARACTERISTICS="public.accessibility.describes-video",CHANNELS="2",URI="audio-ad/stream.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Español",LANGUAGE="es",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="audio-es/stream.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Deutsch",LANGUAGE="de",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="audio-de/stream.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=928000,AVERAGE-BANDWIDTH=800000,RESOLUTION=640x360,FRAME-RATE=30.000,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"
video-360/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2464000,AVERAGE-BANDWIDTH=2200000,RESOLUTION=1280x720,FRAME-RATE=30.000,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud"
video-720/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4964000,AVERAGE-BANDWIDTH=4500000,RESOLUTION=1920x1080,FRAME-RATE=30.000,CODECS="avc1.640029,mp4a.40.2",AUDIO="aud"
video-1080/stream.m3u8
EOF

cat > "$PROFILE/profile.json" <<'EOF'
{
  "id": "player-qa-widescreen-v1",
  "version": "2",
  "displayName": "Widescreen Player QA",
  "purpose": "16:9 adaptive test pattern with multilingual and audio-description rendition switching.",
  "featureTags": ["player-qa", "16:9", "abr", "test-pattern", "timecode", "tone", "alternate-audio", "multilingual", "audio-description"],
  "renditions": [
    {"width": 640, "height": 360, "bandwidth": 800000, "codecs": "avc1.64001f,mp4a.40.2"},
    {"width": 1280, "height": 720, "bandwidth": 2200000, "codecs": "avc1.640028,mp4a.40.2"},
    {"width": 1920, "height": 1080, "bandwidth": 4500000, "codecs": "avc1.640029,mp4a.40.2"}
  ],
  "audioRenditions": [
    {"name": "English Program", "language": "en", "associatedLanguage": null, "channels": "2", "isDefault": true, "isAutoSelect": true, "characteristics": [], "audibleSignature": "440 Hz"},
    {"name": "English Audio Description", "language": "en", "associatedLanguage": "en", "channels": "2", "isDefault": false, "isAutoSelect": true, "characteristics": ["public.accessibility.describes-video"], "audibleSignature": "440 Hz program tone plus 1 kHz synthetic description cue"},
    {"name": "Español", "language": "es", "associatedLanguage": null, "channels": "2", "isDefault": false, "isAutoSelect": true, "characteristics": [], "audibleSignature": "660 Hz"},
    {"name": "Deutsch", "language": "de", "associatedLanguage": null, "channels": "2", "isDefault": false, "isAutoSelect": true, "characteristics": [], "audibleSignature": "330 Hz"}
  ],
  "audioDescription": "Four aligned stereo AAC-LC 48 kHz tracks with distinct safe-level synthetic signatures; the AD rendition carries the platform accessibility characteristic.",
  "bundleSizeBudgetBytes": 10485760,
  "isRecommended": true
}
EOF

echo "Player QA profile authored at $PROFILE"
