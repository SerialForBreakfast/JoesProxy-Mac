#!/bin/bash
# Shared helpers for offline HLS fixture authoring (P2-optional).
# Sourced by author-hls.sh, generate-profile.sh, and materialize-matrix.sh.
# Compatible with macOS /bin/bash 3.2. Never auto-installs tools.

# require_cmd <name> <why>
# Exits 1 with a multi-line stderr message if <name> is not on PATH.
require_cmd() {
  local name="$1"
  local why="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "offline HLS authoring: required tool '$name' was not found on PATH." >&2
    echo "  Needed for: $why" >&2
    echo "  Install it yourself (this repository never auto-installs dependencies)." >&2
    echo "  Do not ask an agent to brew/apt install without explicit user approval." >&2
    exit 1
  fi
}

# require_ffmpeg — fail clearly before any encode step.
require_ffmpeg() {
  require_cmd ffmpeg \
    "encoding new HLS fixture media (generate-profile / misaligned audio regeneration)"
}

# ffmpeg_version_line — first line of `ffmpeg -version`, or empty if ffmpeg is absent.
ffmpeg_version_line() {
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -version 2>/dev/null | head -n 1
  else
    echo ""
  fi
}

# report_cmd <name> — prints OK or MISSING for preflight (does not exit).
report_cmd() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    printf '  %-10s OK\n' "$name"
    return 0
  else
    printf '  %-10s MISSING\n' "$name"
    return 1
  fi
}
