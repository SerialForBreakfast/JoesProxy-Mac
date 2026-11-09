#!/bin/bash
# Emit expected-hashes.json for an HLS fixture profile directory (offline authoring only).
#
# Usage: emit-expected-hashes.sh <profile-dir> --purpose <text>
#          [--differs <text>] [--version <v>] [--generated-with <text>] [--ffmpeg-version <text>]
#
# Writes <profile-dir>/expected-hashes.json with sha256 + byte counts for every regular file
# under the profile (excluding expected-hashes.json itself). No ffmpeg/ffprobe required.
# Compatible with macOS /bin/bash 3.2.

set -euo pipefail

PROFILE_DIR="${1:?usage: emit-expected-hashes.sh <profile-dir> --purpose <text> [--differs <text>] [--version <v>] [--generated-with <text>] [--ffmpeg-version <text>]}"
shift || true

PURPOSE=""
DIFFERS=""
VERSION="1"
GENERATED_WITH="Fixtures/HLS/author-hls.sh (offline authoring only)"
FFMPEG_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --purpose)
      PURPOSE="${2:?}"
      shift 2
      ;;
    --differs)
      DIFFERS="${2:?}"
      shift 2
      ;;
    --version)
      VERSION="${2:?}"
      shift 2
      ;;
    --generated-with)
      GENERATED_WITH="${2:?}"
      shift 2
      ;;
    --ffmpeg-version)
      FFMPEG_VERSION="${2:?}"
      shift 2
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$PURPOSE" ]; then
  echo "emit-expected-hashes.sh: --purpose is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "emit-expected-hashes.sh: jq is required but was not found on PATH." >&2
  echo "  Install jq yourself (this repository never auto-installs dependencies)." >&2
  exit 1
fi

if ! command -v shasum >/dev/null 2>&1; then
  echo "emit-expected-hashes.sh: shasum is required but was not found on PATH." >&2
  exit 1
fi

PROFILE_DIR="$(cd "$PROFILE_DIR" && pwd)"
PROFILE_NAME="$(basename "$PROFILE_DIR")"
OUT="$PROFILE_DIR/expected-hashes.json"
FILE_LIST="$PROFILE_DIR/.hash-file-list.$$"
TMP="$PROFILE_DIR/.hashes.$$"

cleanup() {
  rm -f "$FILE_LIST" "$TMP"
}
trap cleanup EXIT

find "$PROFILE_DIR" -type f ! -name 'expected-hashes.json' ! -name '.hash-file-list.*' ! -name '.hashes.*' -print \
  | sed "s|^$PROFILE_DIR/||" \
  | LC_ALL=C sort > "$FILE_LIST"

json_string() {
  # Encode a string as a JSON string using jq (no python).
  jq -Rn --arg s "$1" '$s'
}

COUNT="$(wc -l < "$FILE_LIST" | tr -d ' ')"
{
  printf '{\n'
  printf '  "profile": %s,\n' "$(json_string "$PROFILE_NAME")"
  printf '  "profileVersion": %s,\n' "$(json_string "$VERSION")"
  printf '  "purpose": %s,\n' "$(json_string "$PURPOSE")"
  if [ -n "$DIFFERS" ]; then
    printf '  "differsFromBaseline": %s,\n' "$(json_string "$DIFFERS")"
  fi
  printf '  "generatedWith": %s,\n' "$(json_string "$GENERATED_WITH")"
  if [ -n "$FFMPEG_VERSION" ]; then
    printf '  "ffmpegVersion": %s,\n' "$(json_string "$FFMPEG_VERSION")"
  fi
  printf '  "files": {\n'
  i=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    i=$((i + 1))
    abs="$PROFILE_DIR/$rel"
    sha="$(shasum -a 256 "$abs" | awk '{print $1}')"
    bytes="$(wc -c < "$abs" | tr -d ' ')"
    printf '    %s: {\n' "$(json_string "$rel")"
    printf '      "sha256": %s,\n' "$(json_string "$sha")"
    printf '      "bytes": %s\n' "$bytes"
    if [ "$i" -lt "$COUNT" ]; then
      printf '    },\n'
    else
      printf '    }\n'
    fi
  done < "$FILE_LIST"
  printf '  }\n'
  printf '}\n'
} > "$TMP"

mv "$TMP" "$OUT"
trap - EXIT
rm -f "$FILE_LIST"
echo "Wrote $OUT ($COUNT files)"
