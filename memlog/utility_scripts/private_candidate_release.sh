#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h:h}"
[[ "$#" -ge 2 && "$#" -le 3 ]] || { echo "Usage: private_candidate_release.sh SOURCE_RELATIVE BUILD_RELATIVE [--dry-run]"; exit 64; }
SOURCE_RELATIVE="$1"
BUILD_RELATIVE="$2"
[[ "$SOURCE_RELATIVE" != /* && "$BUILD_RELATIVE" != /* && "$SOURCE_RELATIVE" != *".."* && "$BUILD_RELATIVE" != *".."* ]] || exit 65
SOURCE_ROOT="$(cd "$ROOT_DIR/$SOURCE_RELATIVE" && pwd -P)"
[[ "$SOURCE_ROOT" == "$ROOT_DIR" || "$SOURCE_ROOT" == "$ROOT_DIR/"* ]] || exit 65
BUILD_ROOT="$ROOT_DIR/$BUILD_RELATIVE"
[[ ! -L "$BUILD_ROOT" && -f "$SOURCE_ROOT/fastlane/Fastfile" ]] || exit 65
BUILD_ROOT="${BUILD_ROOT:A}"
[[ "$BUILD_ROOT" == "$ROOT_DIR/build/"* ]] || exit 65
if [[ "${3:-}" == "--dry-run" ]]; then
  echo "Source: $SOURCE_ROOT"
  echo "Output: $BUILD_ROOT"
  echo "Serial locked invocation: bundle exec fastlane mac release"
  exit 0
fi
[[ "$#" == 2 ]] || exit 64
zmodload zsh/system
for state in "$ROOT_DIR/build/FocusedValidation" "$SOURCE_ROOT/build/FocusedValidation"; do
  [[ ! -L "${state:h}" ]] || exit 65
  [[ ! -L "$state" && ! -L "$state/serial.lock" ]] || exit 65
done
mkdir -p "$ROOT_DIR/build/FocusedValidation" "$SOURCE_ROOT/build/FocusedValidation"
touch "$ROOT_DIR/build/FocusedValidation/serial.lock"
zsystem flock -t 0 -f ROOT_RELEASE_LOCK "$ROOT_DIR/build/FocusedValidation/serial.lock" || exit 75
if [[ "$SOURCE_ROOT" != "$ROOT_DIR" ]]; then
  touch "$SOURCE_ROOT/build/FocusedValidation/serial.lock"
  zsystem flock -t 0 -f SOURCE_RELEASE_LOCK "$SOURCE_ROOT/build/FocusedValidation/serial.lock" || exit 75
fi
if pgrep -x xcodebuild >/dev/null || pgrep -x swift-frontend >/dev/null || pgrep -x xctest >/dev/null; then
  echo "Another native build/test owns the lane."
  exit 75
fi
cd "$SOURCE_ROOT"
export JOESPROXY_BUILD_DIRECTORY="$BUILD_ROOT"
export BUNDLE_FROZEN=true
export FASTLANE_SKIP_UPDATE_CHECK=1
export FASTLANE_HIDE_CHANGELOG=1
export FASTLANE_OPT_OUT_USAGE=1
bundle exec fastlane mac release
