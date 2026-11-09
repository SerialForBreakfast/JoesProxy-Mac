#!/bin/bash
# Offline authoring for ID3 timed metadata profiles (HF-6):
# 1. id3-muxed-av-equivalent (MPEG-2 TS timed metadata in all A/V variants)
# 2. id3-demuxed-program (timed metadata in demuxed program audio)
# 3. id3-hybrid-program-only (timed metadata on in-band program path only)
# 4. id3-hybrid-equivalent (equivalent timed metadata on both in-band and AD paths)
# 5. id3-packed-audio-timestamp (packed-audio PRIV transportStreamTimestamp frames)

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

# Helper to synthesize a 73-byte ID3v2.3 tag containing TIT2 ("Segment %03d") and TXXX ("marker=event-%03d")
create_id3_tag() {
  local index="$1" outfile="$2"
  local title
  title="$(printf "Segment %03d" "$index")"
  local txxx_desc="marker"
  local txxx_val
  txxx_val="$(printf "event-%03d" "$index")"
  
  # TIT2: 1 byte encoding (0) + title length
  local tit2_payload_len=$(( 1 + ${#title} ))
  local tit2_payload
  tit2_payload="$(printf "\x00%s" "$title")"
  
  # TXXX: 1 byte encoding (0) + desc + \0 + val
  local txxx_payload_len=$(( 1 + ${#txxx_desc} + 1 + ${#txxx_val} ))
  local txxx_payload
  txxx_payload="$(printf "\x00%s\x00%s" "$txxx_desc" "$txxx_val")"
  
  # Total frames length: (10 + tit2_payload_len) + (10 + txxx_payload_len)
  local total_frames_len=$(( 10 + tit2_payload_len + 10 + txxx_payload_len ))
  
  # Synchsafe integer for total_frames_len (assuming < 128 for these small tags)
  local s0=0 s1=0 s2=0 s3=$total_frames_len
  if [ "$total_frames_len" -ge 128 ]; then
    s2=$(( total_frames_len / 128 ))
    s3=$(( total_frames_len % 128 ))
  fi

  {
    # 10-byte ID3v2.3 header
    printf "ID3\x03\x00\x00"
    printf "\\$(printf '%03o' "$s0")\\$(printf '%03o' "$s1")\\$(printf '%03o' "$s2")\\$(printf '%03o' "$s3")"
    
    # TIT2 frame: ID(4) + Size(4 big-endian) + Flags(2) + Payload
    printf "TIT2"
    printf "\x00\x00\x00\\$(printf '%03o' "$tit2_payload_len")\x00\x00"
    printf "%b" "$tit2_payload"
    
    # TXXX frame: ID(4) + Size(4 big-endian) + Flags(2) + Payload
    printf "TXXX"
    printf "\x00\x00\x00\\$(printf '%03o' "$txxx_payload_len")\x00\x00"
    printf "%b" "$txxx_payload"
  } > "$outfile"
}

# Helper to synthesize a packed-audio PRIV timestamp ID3 tag
create_packed_audio_priv_tag() {
  local index="$1" outfile="$2"
  local owner="com.apple.streaming.transportStreamTimestamp"
  # 8 octet payload: 33-bit MPEG timestamp (pts = index * 6 * 90000 = index * 540000)
  local pts=$(( index * 540000 ))
  # Pack into 8 bytes big endian
  local b7=$(( pts & 0xFF ))
  local b6=$(( (pts >> 8) & 0xFF ))
  local b5=$(( (pts >> 16) & 0xFF ))
  local b4=$(( (pts >> 24) & 0xFF ))
  local b3=$(( (pts >> 32) & 0xFF ))
  local b2=0 b1=0 b0=0
  
  local priv_payload_len=$(( ${#owner} + 1 + 8 ))
  local total_frames_len=$(( 10 + priv_payload_len ))
  local s0=0 s1=0 s2=0 s3=$total_frames_len
  if [ "$total_frames_len" -ge 128 ]; then
    s2=$(( total_frames_len / 128 ))
    s3=$(( total_frames_len % 128 ))
  fi

  {
    # 10-byte ID3v2.3 header
    printf "ID3\x03\x00\x00"
    printf "\\$(printf '%03o' "$s0")\\$(printf '%03o' "$s1")\\$(printf '%03o' "$s2")\\$(printf '%03o' "$s3")"
    
    # PRIV frame: ID(4) + Size(4) + Flags(2) + Payload
    printf "PRIV"
    printf "\x00\x00\x00\\$(printf '%03o' "$priv_payload_len")\x00\x00"
    printf "%s\x00" "$owner"
    printf "\\$(printf '%03o' "$b0")\\$(printf '%03o' "$b1")\\$(printf '%03o' "$b2")\\$(printf '%03o' "$b3")\\$(printf '%03o' "$b4")\\$(printf '%03o' "$b5")\\$(printf '%03o' "$b6")\\$(printf '%03o' "$b7")"
  } > "$outfile"
}

inject_id3_into_directory() {
  local dir="$1"
  local temp_tag
  temp_tag="$(mktemp)"
  local idx=0
  for seg in "$dir"/seg-*.ts; do
    if [ -f "$seg" ]; then
      create_id3_tag "$idx" "$temp_tag"
      cat "$temp_tag" "$seg" > "$seg.tmp" && mv "$seg.tmp" "$seg"
      idx=$(( idx + 1 ))
    fi
  done
  rm -f "$temp_tag"
}

inject_priv_into_directory() {
  local dir="$1"
  local temp_tag
  temp_tag="$(mktemp)"
  local idx=0
  for seg in "$dir"/seg-*.ts; do
    if [ -f "$seg" ]; then
      create_packed_audio_priv_tag "$idx" "$temp_tag"
      cat "$temp_tag" "$seg" > "$seg.tmp" && mv "$seg.tmp" "$seg"
      idx=$(( idx + 1 ))
    fi
  done
  rm -f "$temp_tag"
}

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

author_id3_muxed() {
  local profile_id="id3-muxed-av-equivalent"
  local dest="$ROOT/$profile_id"
  local staging="$ROOT/.${profile_id}-staging.$$"
  rm -rf "$dest" "$staging"
  mkdir -p "$staging"

  echo "Authoring $profile_id..."
  gen_muxed_video "$staging" "video-360" "640x360" "24" "3.1"
  gen_muxed_video "$staging" "video-720" "1280x720" "22" "4.0"
  gen_muxed_video "$staging" "video-1080" "1920x1080" "20" "4.1"

  inject_id3_into_directory "$staging/video-360"
  inject_id3_into_directory "$staging/video-720"
  inject_id3_into_directory "$staging/video-1080"

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
  "displayName": "ID3 Muxed A/V Equivalent",
  "purpose": "Multiplexed MPEG-2 TS ID3 timed metadata across all A/V variants.",
  "featureTags": ["positive-control", "id3", "timed-metadata", "mpeg2ts", "abr-consistency", "sdr", "avc", "aac"],
  "renditions": [
    {"width": 640, "height": 360, "bandwidth": $v360_p, "codecs": "avc1.64001f,mp4a.40.2"},
    {"width": 1280, "height": 720, "bandwidth": $v720_p, "codecs": "avc1.640028,mp4a.40.2"},
    {"width": 1920, "height": 1080, "bandwidth": $v1080_p, "codecs": "avc1.640029,mp4a.40.2"}
  ],
  "audioRenditions": [
    {
      "name": "In-Band Program Audio",
      "language": "en",
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
  "id3Schedule": {
    "carrier": "mpeg2TS",
    "version": "id3v2.3",
    "allowedFrameIDs": ["TIT2", "TXXX"],
    "events": [
      {"id": "evt-000", "eventClass": "segmentStart", "mediaTime": 0.0, "segmentIndex": 0, "frameID": "TIT2", "label": "Segment 000"},
      {"id": "evt-002", "eventClass": "intraSegment", "mediaTime": 12.0, "segmentIndex": 2, "frameID": "TIT2", "label": "Segment 002"},
      {"id": "evt-005", "eventClass": "preDiscontinuity", "mediaTime": 30.0, "segmentIndex": 5, "frameID": "TIT2", "label": "Segment 005"}
    ]
  },
  "audioTopology": "muxedOnly",
  "bundleSizeBudgetBytes": $BUNDLE_BUDGET_BYTES,
  "isRecommended": false,
  "conformanceClass": "conformantControl",
  "controlledFaults": [],
  "expectedClientBehavior": "ID3 timed metadata callbacks should remain consistent across ABR switches."
}
EOF

  mv "$staging" "$dest"
  "$EMIT" "$dest" --purpose "ID3 muxed A/V equivalent profile" --version "1"
}

author_id3_demuxed() {
  local profile_id="id3-demuxed-program"
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

  inject_id3_into_directory "$staging/audio-en"

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
  "displayName": "ID3 Demuxed Program",
  "purpose": "Demuxed program audio carrying MPEG-2 TS ID3 timed metadata.",
  "featureTags": ["positive-control", "id3", "timed-metadata", "demuxed-audio", "sdr", "avc", "aac"],
  "renditions": [
    {"width": 640, "height": 360, "bandwidth": $v360_p, "codecs": "avc1.64001f,mp4a.40.2"},
    {"width": 1280, "height": 720, "bandwidth": $v720_p, "codecs": "avc1.640028,mp4a.40.2"},
    {"width": 1920, "height": 1080, "bandwidth": $v1080_p, "codecs": "avc1.640029,mp4a.40.2"}
  ],
  "audioRenditions": [
    {
      "name": "English Program",
      "language": "en",
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
  "id3Schedule": {
    "carrier": "mpeg2TS",
    "version": "id3v2.3",
    "allowedFrameIDs": ["TIT2", "TXXX"],
    "events": [
      {"id": "evt-000", "eventClass": "segmentStart", "mediaTime": 0.0, "segmentIndex": 0, "frameID": "TIT2", "label": "Segment 000"}
    ]
  },
  "audioTopology": "demuxedAll",
  "bundleSizeBudgetBytes": $BUNDLE_BUDGET_BYTES,
  "isRecommended": false,
  "conformanceClass": "conformantControl",
  "controlledFaults": [],
  "expectedClientBehavior": "Timed metadata should arrive through the independent audio rendition."
}
EOF

  mv "$staging" "$dest"
  "$EMIT" "$dest" --purpose "ID3 demuxed program profile" --version "1"
}

author_id3_hybrid_program_only() {
  local profile_id="id3-hybrid-program-only"
  local dest="$ROOT/$profile_id"
  local staging="$ROOT/.${profile_id}-staging.$$"
  rm -rf "$dest" "$staging"
  mkdir -p "$staging"

  echo "Authoring $profile_id..."
  gen_muxed_video "$staging" "video-360" "640x360" "24" "3.1"
  gen_muxed_video "$staging" "video-720" "1280x720" "22" "4.0"
  gen_muxed_video "$staging" "video-1080" "1920x1080" "20" "4.1"
  gen_audio_rendition "$staging" "audio-ad" "880"

  inject_id3_into_directory "$staging/video-360"
  inject_id3_into_directory "$staging/video-720"
  inject_id3_into_directory "$staging/video-1080"

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
  "displayName": "ID3 Hybrid Program Only",
  "purpose": "Hybrid in-band program audio with ID3 metadata where alternate AD carries no metadata.",
  "featureTags": ["id3", "hybrid", "metadata-availability", "sdr", "avc", "aac"],
  "renditions": [
    {"width": 640, "height": 360, "bandwidth": $v360_p, "codecs": "avc1.64001f,mp4a.40.2"},
    {"width": 1280, "height": 720, "bandwidth": $v720_p, "codecs": "avc1.640028,mp4a.40.2"},
    {"width": 1920, "height": 1080, "bandwidth": $v1080_p, "codecs": "avc1.640029,mp4a.40.2"}
  ],
  "audioRenditions": [
    {
      "name": "English Program",
      "language": "en",
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
  "id3Schedule": {
    "carrier": "mpeg2TS",
    "version": "id3v2.3",
    "allowedFrameIDs": ["TIT2", "TXXX"],
    "events": [
      {"id": "evt-000", "eventClass": "segmentStart", "mediaTime": 0.0, "segmentIndex": 0, "frameID": "TIT2", "label": "Segment 000"}
    ]
  },
  "audioTopology": "hybridInBandProgramAD",
  "bundleSizeBudgetBytes": $BUNDLE_BUDGET_BYTES,
  "isRecommended": false,
  "conformanceClass": "stressCase",
  "controlledFaults": [],
  "expectedClientBehavior": "Metadata availability should follow the active in-band program audio track."
}
EOF

  mv "$staging" "$dest"
  "$EMIT" "$dest" --purpose "ID3 hybrid program only profile" --version "1"
}

author_id3_hybrid_equivalent() {
  local profile_id="id3-hybrid-equivalent"
  local dest="$ROOT/$profile_id"
  local staging="$ROOT/.${profile_id}-staging.$$"
  rm -rf "$dest" "$staging"
  mkdir -p "$staging"

  echo "Authoring $profile_id..."
  gen_muxed_video "$staging" "video-360" "640x360" "24" "3.1"
  gen_muxed_video "$staging" "video-720" "1280x720" "22" "4.0"
  gen_muxed_video "$staging" "video-1080" "1920x1080" "20" "4.1"
  gen_audio_rendition "$staging" "audio-ad" "880"

  inject_id3_into_directory "$staging/video-360"
  inject_id3_into_directory "$staging/video-720"
  inject_id3_into_directory "$staging/video-1080"
  inject_id3_into_directory "$staging/audio-ad"

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
  "displayName": "ID3 Hybrid Equivalent",
  "purpose": "Hybrid audio topology with matching logical ID3 schedules on both paths.",
  "featureTags": ["positive-control", "id3", "hybrid", "duplicate-suppression", "sdr", "avc", "aac"],
  "renditions": [
    {"width": 640, "height": 360, "bandwidth": $v360_p, "codecs": "avc1.64001f,mp4a.40.2"},
    {"width": 1280, "height": 720, "bandwidth": $v720_p, "codecs": "avc1.640028,mp4a.40.2"},
    {"width": 1920, "height": 1080, "bandwidth": $v1080_p, "codecs": "avc1.640029,mp4a.40.2"}
  ],
  "audioRenditions": [
    {
      "name": "English Program",
      "language": "en",
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
  "id3Schedule": {
    "carrier": "mpeg2TS",
    "version": "id3v2.3",
    "allowedFrameIDs": ["TIT2", "TXXX"],
    "events": [
      {"id": "evt-000", "eventClass": "segmentStart", "mediaTime": 0.0, "segmentIndex": 0, "frameID": "TIT2", "label": "Segment 000"}
    ]
  },
  "audioTopology": "hybridInBandProgramAD",
  "bundleSizeBudgetBytes": $BUNDLE_BUDGET_BYTES,
  "isRecommended": false,
  "conformanceClass": "conformantControl",
  "controlledFaults": [],
  "expectedClientBehavior": "Switching between in-band program and alternate AD should not duplicate or lose callbacks."
}
EOF

  mv "$staging" "$dest"
  "$EMIT" "$dest" --purpose "ID3 hybrid equivalent profile" --version "1"
}

author_id3_packed_audio() {
  local profile_id="id3-packed-audio-timestamp"
  local dest="$ROOT/$profile_id"
  local staging="$ROOT/.${profile_id}-staging.$$"
  rm -rf "$dest" "$staging"
  mkdir -p "$staging"

  echo "Authoring $profile_id..."
  gen_video_only "$staging" "video-360" "640x360" "24" "3.1"
  gen_video_only "$staging" "video-720" "1280x720" "22" "4.0"
  gen_video_only "$staging" "video-1080" "1920x1080" "20" "4.1"
  gen_audio_rendition "$staging" "audio-en" "440"

  inject_priv_into_directory "$staging/audio-en"

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
  "displayName": "ID3 Packed-Audio Timestamp",
  "purpose": "Packed-audio transport timestamp PRIV validation profile.",
  "featureTags": ["positive-control", "id3", "packed-audio", "timestamp-priv", "sdr", "avc", "aac"],
  "renditions": [
    {"width": 640, "height": 360, "bandwidth": $v360_p, "codecs": "avc1.64001f,mp4a.40.2"},
    {"width": 1280, "height": 720, "bandwidth": $v720_p, "codecs": "avc1.640028,mp4a.40.2"},
    {"width": 1920, "height": 1080, "bandwidth": $v1080_p, "codecs": "avc1.640029,mp4a.40.2"}
  ],
  "audioRenditions": [
    {
      "name": "English Program",
      "language": "en",
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
    }
  ],
  "id3Schedule": {
    "carrier": "packedAudioTimestamp",
    "version": "id3v2.3",
    "allowedFrameIDs": ["PRIV"],
    "events": [
      {"id": "evt-priv-000", "eventClass": "segmentStart", "mediaTime": 0.0, "segmentIndex": 0, "frameID": "PRIV", "label": "Timestamp PRIV"}
    ]
  },
  "audioTopology": "demuxedAll",
  "bundleSizeBudgetBytes": $BUNDLE_BUDGET_BYTES,
  "isRecommended": false,
  "conformanceClass": "conformantControl",
  "controlledFaults": [],
  "expectedClientBehavior": "Packed-audio segment timestamps should match the first audio sample."
}
EOF

  mv "$staging" "$dest"
  "$EMIT" "$dest" --purpose "ID3 packed-audio timestamp profile" --version "1"
}

chmod +x "$EMIT"
author_id3_muxed
author_id3_demuxed
author_id3_hybrid_program_only
author_id3_hybrid_equivalent
author_id3_packed_audio
echo "All 5 ID3 profiles successfully generated!"
