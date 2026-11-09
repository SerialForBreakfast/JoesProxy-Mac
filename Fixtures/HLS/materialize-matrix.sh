#!/bin/bash
# Materialize the P2-06 HLS fixture profile matrix from baseline-aligned-codecs.
#
# Offline developer tool only — never invoked by HLSFixtureServer or MCP at runtime.
# Prefer copying baseline media + playlist edits. Regenerates misaligned audio with ffmpeg
# when present; fails clearly if ffmpeg is missing for that step (unless --skip-ffmpeg).
#
# Usage: materialize-matrix.sh [--skip-ffmpeg] [--only <profile-id>]
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Fixtures/HLS/_lib.sh
. "$ROOT/_lib.sh"

BASELINE="$ROOT/baseline-aligned-codecs"
EMIT="$ROOT/emit-expected-hashes.sh"

SKIP_FFMPEG=0
ONLY_PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-ffmpeg)
      SKIP_FFMPEG=1
      shift
      ;;
    --only)
      ONLY_PROFILE="${2:?materialize-matrix.sh: --only requires a profile-id}"
      shift 2
      ;;
    *)
      echo "unknown flag: $1" >&2
      echo "usage: materialize-matrix.sh [--skip-ffmpeg] [--only <profile-id>]" >&2
      exit 1
      ;;
  esac
done

if [ ! -f "$BASELINE/master.m3u8" ]; then
  echo "materialize-matrix.sh: missing baseline at $BASELINE" >&2
  echo "Run: Fixtures/HLS/author-hls.sh baseline" >&2
  exit 1
fi

require_cmd jq "emitting expected-hashes.json"
require_cmd rsync "copying baseline media into matrix profiles"
require_cmd shasum "emitting expected-hashes.json"

if [ ! -x "$EMIT" ]; then
  chmod +x "$EMIT"
fi

GENERATED_WITH="Fixtures/HLS/author-hls.sh matrix"
FFMPEG_VERSION="$(ffmpeg_version_line)"

should_run() {
  local id="$1"
  if [ -z "$ONLY_PROFILE" ]; then
    return 0
  fi
  [ "$ONLY_PROFILE" = "$id" ]
}

copy_baseline_tree() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest"
  # Copy media + master; hashes are regenerated after edits.
  rsync -a --exclude 'expected-hashes.json' "$BASELINE/" "$dest/"
}

write_master() {
  # $1=dest $2=with_codecs(0|1) $3=bogus_ad(0|1)
  local dest="$1"
  local with_codecs="$2"
  local bogus_ad="$3"
  local codecs_lo=""
  local codecs_hi=""
  if [ "$with_codecs" = "1" ]; then
    codecs_lo=',CODECS="avc1.42001e,mp4a.40.2"'
    codecs_hi=',CODECS="avc1.42001e,mp4a.40.2"'
  fi
  local ad_uri="audio-ad/stream.m3u8"
  if [ "$bogus_ad" = "1" ]; then
    ad_uri="audio-en/stream.m3u8"
  fi
  cat > "$dest/master.m3u8" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio-en/stream.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English (Audio Description)",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",CHARACTERISTICS="public.accessibility.describes-video",URI="${ad_uri}"
#EXT-X-STREAM-INF:BANDWIDTH=896000,AVERAGE-BANDWIDTH=800000,RESOLUTION=640x360${codecs_lo},AUDIO="aud"
video-lo/stream.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1568000,AVERAGE-BANDWIDTH=1400000,RESOLUTION=960x540${codecs_hi},AUDIO="aud"
video-hi/stream.m3u8
EOF
}

insert_discontinuity_before_segment() {
  local playlist="$1"
  local before_seg="$2"
  [ -f "$playlist" ] || return 0
  local tmp="$playlist.tmp.$$"
  # Place DISCONTINUITY immediately before the Nth #EXTINF (1-based) so that segment carries
  # hasDiscontinuityBefore through HLSStaticPlaylistParser.
  awk -v target="$before_seg" '
    BEGIN { seg = 0 }
    /^#EXTINF/ {
      seg++
      if (seg == target) print "#EXT-X-DISCONTINUITY"
    }
    { print }
  ' "$playlist" > "$tmp"
  mv "$tmp" "$playlist"
}

insert_discontinuity_before_third_segment() {
  insert_discontinuity_before_segment "$1" 3
}

apply_discontinuity_all_streams() {
  local dest="$1"
  local f
  for f in "$dest"/video-*/stream.m3u8 "$dest"/audio-*/stream.m3u8; do
    [ -f "$f" ] || continue
    # Skip if already present (idempotent re-runs).
    if grep -q '^#EXT-X-DISCONTINUITY$' "$f"; then
      continue
    fi
    insert_discontinuity_before_third_segment "$f"
  done
}

## Applies different discontinuity segment indexes per rendition so audio/video boundaries
## diverge in wall-clock time when segment durations already differ (cross-rendition drift).
apply_discontinuity_cross_rendition_drift() {
  local dest="$1"
  local f
  for f in "$dest"/video-*/stream.m3u8; do
    [ -f "$f" ] || continue
    if grep -q '^#EXT-X-DISCONTINUITY$' "$f"; then
      continue
    fi
    insert_discontinuity_before_segment "$f" 3
  done
  if [ -f "$dest/audio-en/stream.m3u8" ] && ! grep -q '^#EXT-X-DISCONTINUITY$' "$dest/audio-en/stream.m3u8"; then
    insert_discontinuity_before_segment "$dest/audio-en/stream.m3u8" 5
  fi
  if [ -f "$dest/audio-ad/stream.m3u8" ] && ! grep -q '^#EXT-X-DISCONTINUITY$' "$dest/audio-ad/stream.m3u8"; then
    insert_discontinuity_before_segment "$dest/audio-ad/stream.m3u8" 4
  fi
}

write_test_keys() {
  local dest="$1"
  mkdir -p "$dest/keys"
  # 16-byte deterministic nonsecret test keys (tag-only rotation; segments remain clear).
  printf 'JP-TEST-KEY-AAA!' > "$dest/keys/key-a.key"
  printf 'JP-TEST-KEY-BBB!' > "$dest/keys/key-b.key"
}

insert_key_rotation_tags() {
  # Insert rotating EXT-X-KEY before segments 1/3/5 (after EXTINF lines 0-indexed: before URI of seg 0,2,4).
  # Tag-only: METHOD=AES-128 with URI to nonsecret keys; media bytes stay clear baseline TS.
  local playlist="$1"
  [ -f "$playlist" ] || return 0
  if grep -q '^#EXT-X-KEY:' "$playlist"; then
    return 0
  fi
  local tmp="$playlist.tmp.$$"
  awk '
    BEGIN { seg = 0 }
    {
      if ($0 ~ /^#EXTINF/) {
        key = (int(seg / 2) % 2 == 0) ? "key-a.key" : "key-b.key"
        # Relative URI from stream playlist dir (video-lo/, audio-en/, …) up to profile keys/.
        printf "#EXT-X-KEY:METHOD=AES-128,URI=\"../keys/%s\"\n", key
        seg++
      }
      print
    }
  ' "$playlist" > "$tmp"
  mv "$tmp" "$playlist"
}

apply_key_rotation_all_streams() {
  local dest="$1"
  write_test_keys "$dest"
  local f
  for f in "$dest"/video-*/stream.m3u8 "$dest"/audio-*/stream.m3u8; do
    [ -f "$f" ] || continue
    insert_key_rotation_tags "$f"
  done
}

generate_misaligned_audio() {
  local dest="$1"
  require_ffmpeg
  local duration=24
  # 3s segments vs baseline video's ~4s segments → intentional A/V boundary misalignment.
  local segment_duration=3

  gen_audio() {
    local name="$1" freq="$2"
    local dir="$dest/$name"
    rm -rf "$dir"
    mkdir -p "$dir"
    ffmpeg -y -hide_banner -loglevel error \
      -f lavfi -i "sine=frequency=${freq}:duration=${duration}:sample_rate=44100" \
      -vn \
      -c:a aac -b:a 96k -ac 2 \
      -f hls -hls_time "$segment_duration" -hls_playlist_type vod \
      -hls_segment_filename "$dir/seg-%03d.ts" \
      "$dir/stream.m3u8"
  }

  echo "  regenerating misaligned audio-en (3s segments, 440Hz)..."
  gen_audio "audio-en" 440
  echo "  regenerating misaligned audio-ad (3s segments, 880Hz)..."
  gen_audio "audio-ad" 880
}

emit_hashes() {
  local dest="$1"
  local purpose="$2"
  local differs="$3"
  local args=(
    "$dest"
    --purpose "$purpose"
    --differs "$differs"
    --version "1"
    --generated-with "$GENERATED_WITH"
  )
  if [ -n "$FFMPEG_VERSION" ]; then
    args+=(--ffmpeg-version "$FFMPEG_VERSION")
  fi
  "$EMIT" "${args[@]}"
}

refresh_baseline_hashes() {
  local args=(
    "$BASELINE"
    --purpose "Positive control: correct CODECS on every variant, genuine AD, aligned splices."
    --version "1"
    --generated-with "$GENERATED_WITH"
  )
  if [ -n "$FFMPEG_VERSION" ]; then
    args+=(--ffmpeg-version "$FFMPEG_VERSION")
  fi
  "$EMIT" "${args[@]}"
}

if should_run "missing-codecs-only"; then
  echo "=== missing-codecs-only ==="
  DEST="$ROOT/missing-codecs-only"
  copy_baseline_tree "$DEST"
  write_master "$DEST" 0 0
  emit_hashes "$DEST" \
    "Same media as baseline; master omits CODECS from every variant." \
    "master.m3u8 omits CODECS attributes only."
fi

if should_run "bogus-ad-alias-only"; then
  echo "=== bogus-ad-alias-only ==="
  DEST="$ROOT/bogus-ad-alias-only"
  copy_baseline_tree "$DEST"
  write_master "$DEST" 1 1
  emit_hashes "$DEST" \
    "AD EXT-X-MEDIA advertises accessibility but URI points at audio-en." \
    "master.m3u8 AD URI -> audio-en/stream.m3u8 (audio-ad segments unused)."
fi

if should_run "discontinuity-at-switch"; then
  echo "=== discontinuity-at-switch ==="
  DEST="$ROOT/discontinuity-at-switch"
  copy_baseline_tree "$DEST"
  write_master "$DEST" 1 0
  apply_discontinuity_all_streams "$DEST"
  emit_hashes "$DEST" \
    "EXT-X-DISCONTINUITY inserted before the third segment on every rendition." \
    "stream.m3u8 playlists gain one EXT-X-DISCONTINUITY before segment 3."
fi

if should_run "key-rotation-only"; then
  echo "=== key-rotation-only ==="
  DEST="$ROOT/key-rotation-only"
  copy_baseline_tree "$DEST"
  write_master "$DEST" 1 0
  apply_key_rotation_all_streams "$DEST"
  emit_hashes "$DEST" \
    "Tag-only EXT-X-KEY rotation with checked-in nonsecret keys; segments remain clear baseline TS." \
    "stream.m3u8 playlists gain rotating EXT-X-KEY lines; keys/key-a.key and keys/key-b.key added."
fi

if should_run "misaligned-audio-boundary"; then
  echo "=== misaligned-audio-boundary ==="
  DEST="$ROOT/misaligned-audio-boundary"
  if [ "$SKIP_FFMPEG" = "1" ]; then
    if [ ! -f "$DEST/audio-en/stream.m3u8" ]; then
      echo "materialize-matrix.sh: --skip-ffmpeg set but $DEST has no existing audio;" >&2
      echo "  cannot refresh misaligned-audio-boundary without ffmpeg." >&2
      exit 1
    fi
    echo "  --skip-ffmpeg: leaving existing misaligned audio bytes unchanged; refreshing master + hashes."
    write_master "$DEST" 1 0
  else
    copy_baseline_tree "$DEST"
    write_master "$DEST" 1 0
    generate_misaligned_audio "$DEST"
  fi
  emit_hashes "$DEST" \
    "Baseline video with audio regenerated on a 3s segment grid (misaligned vs ~4s video)." \
    "audio-en/ and audio-ad/ regenerated with hls_time=3; video unchanged from baseline."
fi

if should_run "combined-defects"; then
  echo "=== combined-defects ==="
  DEST="$ROOT/combined-defects"
  if [ "$SKIP_FFMPEG" = "1" ]; then
    if [ ! -f "$ROOT/misaligned-audio-boundary/audio-en/stream.m3u8" ]; then
      echo "materialize-matrix.sh: --skip-ffmpeg set but misaligned-audio-boundary audio is missing;" >&2
      echo "  combined-defects needs that audio tree (or a full matrix run with ffmpeg)." >&2
      exit 1
    fi
    echo "  --skip-ffmpeg: reusing existing misaligned-audio-boundary audio bytes."
  fi
  if [ ! -f "$ROOT/misaligned-audio-boundary/audio-en/stream.m3u8" ]; then
    echo "materialize-matrix.sh: misaligned-audio-boundary must exist before combined-defects." >&2
    echo "  Run without --only, or run --only misaligned-audio-boundary first." >&2
    exit 1
  fi
  copy_baseline_tree "$DEST"
  # Start from misaligned audio (copy from that profile after it exists).
  rm -rf "$DEST/audio-en" "$DEST/audio-ad"
  rsync -a "$ROOT/misaligned-audio-boundary/audio-en/" "$DEST/audio-en/"
  rsync -a "$ROOT/misaligned-audio-boundary/audio-ad/" "$DEST/audio-ad/"
  write_master "$DEST" 0 1
  apply_discontinuity_all_streams "$DEST"
  apply_key_rotation_all_streams "$DEST"
  emit_hashes "$DEST" \
    "Combined: missing CODECS, bogus AD URI, discontinuity, key tags, misaligned audio." \
    "All matrix deltas together — closest analog to field captures."
fi

if should_run "discontinuity-cross-rendition-drift"; then
  echo "=== discontinuity-cross-rendition-drift ==="
  DEST="$ROOT/discontinuity-cross-rendition-drift"
  if [ "$SKIP_FFMPEG" = "1" ]; then
    if [ ! -f "$ROOT/misaligned-audio-boundary/audio-en/stream.m3u8" ]; then
      echo "materialize-matrix.sh: --skip-ffmpeg set but misaligned-audio-boundary audio is missing;" >&2
      echo "  discontinuity-cross-rendition-drift needs that audio tree." >&2
      exit 1
    fi
    echo "  --skip-ffmpeg: reusing existing misaligned-audio-boundary audio bytes."
  fi
  if [ ! -f "$ROOT/misaligned-audio-boundary/audio-en/stream.m3u8" ]; then
    echo "materialize-matrix.sh: misaligned-audio-boundary must exist before discontinuity-cross-rendition-drift." >&2
    exit 1
  fi
  copy_baseline_tree "$DEST"
  rm -rf "$DEST/audio-en" "$DEST/audio-ad"
  rsync -a "$ROOT/misaligned-audio-boundary/audio-en/" "$DEST/audio-en/"
  rsync -a "$ROOT/misaligned-audio-boundary/audio-ad/" "$DEST/audio-ad/"
  write_master "$DEST" 1 0
  apply_discontinuity_cross_rendition_drift "$DEST"
  emit_hashes "$DEST" \
    "Misaligned audio plus per-rendition discontinuity indexes (video@3, audio-en@5, audio-ad@4)." \
    "Cross-rendition discontinuity placement for JoePlayer track-switch drift trials."
fi

# Refresh baseline inventory when running the full matrix (or when --only targets baseline refresh).
if [ -z "$ONLY_PROFILE" ]; then
  echo "=== refresh baseline-aligned-codecs hashes ==="
  refresh_baseline_hashes
fi

if [ -n "$ONLY_PROFILE" ]; then
  echo "Matrix materialization complete (--only $ONLY_PROFILE)."
else
  echo "Matrix materialization complete."
fi
