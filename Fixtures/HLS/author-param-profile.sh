#!/bin/bash
# Materialize parameterized HLS fixture profiles for JoePlayer rendition trials.
#
# Offline developer tool only. Uses rsync from existing matrix profiles; optional ffmpeg
# when regenerating media with new segment durations.
#
# Usage:
#   author-param-profile.sh [--skip-ffmpeg] [--only <profile-id>]
#   author-param-profile.sh all
#
# Profiles:
#   param-aligned-4s
#   param-misaligned-v4-a3
#   param-cross-disc-v3-aen5-aes4
#   param-lang-en-es

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Fixtures/HLS/_lib.sh
. "$ROOT/_lib.sh"

EMIT="$ROOT/emit-expected-hashes.sh"
GEN="$ROOT/generate-profile.sh"
ONLY_PROFILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    all|--all) shift ;;
    --only)
      ONLY_PROFILE="${2:?author-param-profile.sh: --only requires profile-id}"
      shift 2
      ;;
    --skip-ffmpeg) shift ;;
    -h|--help)
      echo "usage: author-param-profile.sh [all] [--only <profile-id>]"
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

require_cmd jq "emitting expected-hashes.json"
require_cmd rsync "copying profile trees"
require_cmd shasum "emitting expected-hashes.json"

should_run() {
  local id="$1"
  if [ -z "$ONLY_PROFILE" ]; then
    return 0
  fi
  [ "$ONLY_PROFILE" = "$id" ]
}

copy_tree() {
  local src="$1"
  local dest="$2"
  rm -rf "$dest"
  mkdir -p "$dest"
  rsync -a --exclude 'expected-hashes.json' "$src/" "$dest/"
}

write_master_lang_en_es() {
  local dest="$1"
  cat > "$dest/master.m3u8" <<'EOF'
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio-en/stream.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Spanish",LANGUAGE="es",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="audio-es/stream.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=896000,AVERAGE-BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42001e,mp4a.40.2",AUDIO="aud"
video-lo/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1568000,AVERAGE-BANDWIDTH=1400000,RESOLUTION=960x540,CODECS="avc1.42001e,mp4a.40.2",AUDIO="aud"
video-hi/stream.m3u8
EOF
}

emit_hashes() {
  local dest="$1"
  local purpose="$2"
  local differs="$3"
  "$EMIT" "$dest" --purpose "$purpose" --differs "$differs" --generated-with "Fixtures/HLS/author-param-profile.sh"
}

if should_run "param-aligned-4s"; then
  echo "=== param-aligned-4s ==="
  DEST="$ROOT/param-aligned-4s"
  copy_tree "$ROOT/baseline-aligned-codecs" "$DEST"
  emit_hashes "$DEST" \
    "Parameter control: aligned 4s video/audio segments." \
    "Alias of baseline-aligned-codecs for JoePlayer param matrix."
fi

if should_run "param-misaligned-v4-a3"; then
  echo "=== param-misaligned-v4-a3 ==="
  DEST="$ROOT/param-misaligned-v4-a3"
  copy_tree "$ROOT/misaligned-audio-boundary" "$DEST"
  emit_hashes "$DEST" \
    "Parameter profile: 4s video / ~3s audio segment grid." \
    "Variable segment length without cross-rendition discontinuity offsets."
fi

if should_run "param-cross-disc-v3-aen5-aes4"; then
  echo "=== param-cross-disc-v3-aen5-aes4 ==="
  DEST="$ROOT/param-cross-disc-v3-aen5-aes4"
  copy_tree "$ROOT/discontinuity-cross-rendition-drift" "$DEST"
  emit_hashes "$DEST" \
    "Parameter profile: misaligned audio plus per-rendition discontinuity indexes." \
    "video@3, audio-ad@4, audio-en@5 for JoePlayer drift trials."
fi

if should_run "param-lang-en-es"; then
  echo "=== param-lang-en-es ==="
  DEST="$ROOT/param-lang-en-es"
  copy_tree "$ROOT/baseline-aligned-codecs" "$DEST"
  rm -rf "$DEST/audio-ad"
  rsync -a "$ROOT/baseline-aligned-codecs/audio-en/" "$DEST/audio-es/"
  write_master_lang_en_es "$DEST"
  emit_hashes "$DEST" \
    "Parameter profile: distinct LANGUAGE=en and LANGUAGE=es audio renditions." \
    "Spanish track reuses English media bytes; master tags es for language-switch trials."
fi

echo "author-param-profile.sh complete"
