#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION_CONFIG="$ROOT_DIR/Config/Version.xcconfig"
CHANGELOG_PATH="$ROOT_DIR/CHANGELOG.md"
VERSION_DOC="RELEASE.md"
SKILL_PATH="$ROOT_DIR/.agents/skills/joesproxy-mcp-diagnostics/SKILL.md"

usage() {
  cat <<'EOF'
Usage:
  ./bump_version.sh <major|minor|patch|X.Y.Z> [--build N] [--date YYYY-MM-DD] [--dry-run]
  ./bump_version.sh X.Y.Z --build-only [--build N] [--dry-run]

Examples:
  ./bump_version.sh patch
  ./bump_version.sh minor --date 2026-04-23
  ./bump_version.sh 1.1.0 --build 7

Behavior:
  - Updates Config/Version.xcconfig
  - Renames [Unreleased] to the new version section, preserving whatever content
    it currently has (empty or not), and inserts a fresh empty [Unreleased]
    skeleton above it
  - Rewrites the "version:" line in .agents/skills/joesproxy-mcp-diagnostics/SKILL.md's
    frontmatter to the new MARKETING_VERSION (the app's own embedded copy of this
    file already derives its version dynamically from Bundle.main; this keeps the
    checked-in, run-outside-the-app copy in sync with it)
  - Defaults build number to CURRENT_PROJECT_VERSION + 1
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

bump_semver() {
  local current="$1"
  local part="$2"
  local major minor patch
  IFS='.' read -r major minor patch <<<"$current"

  case "$part" in
    major)
      printf '%s.0.0' "$((major + 1))"
      ;;
    minor)
      printf '%s.%s.0' "$major" "$((minor + 1))"
      ;;
    patch)
      printf '%s.%s.%s' "$major" "$minor" "$((patch + 1))"
      ;;
    *)
      fail "unsupported bump part: $part"
      ;;
  esac
}

extract_setting() {
  local key="$1"
  local value
  value="$(awk -F '=' -v key="$key" '
    /^[[:space:]]*\/\// { next }
    /^[[:space:]]*#/ { next }
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "$VERSION_CONFIG")"
  printf '%s' "$value"
}

ensure_unreleased_section_exists() {
  grep -q '^## \[Unreleased\]' "$CHANGELOG_PATH" || fail "CHANGELOG is missing a [Unreleased] section"
}

MODE=""
CUSTOM_BUILD=""
CUSTOM_DATE=""
DRY_RUN=0
BUILD_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --build)
      [[ $# -ge 2 ]] || fail "--build requires a value"
      CUSTOM_BUILD="$2"
      shift 2
      ;;
    --date)
      [[ $# -ge 2 ]] || fail "--date requires a value"
      CUSTOM_DATE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$MODE" ]] || fail "only one version argument is allowed"
      MODE="$1"
      shift
      ;;
  esac
done

[[ -n "$MODE" ]] || {
  usage
  exit 1
}

[[ -f "$VERSION_CONFIG" ]] || fail "missing $VERSION_CONFIG"
[[ -f "$CHANGELOG_PATH" ]] || fail "missing $CHANGELOG_PATH"
if (( BUILD_ONLY == 0 )); then
  [[ -f "$SKILL_PATH" ]] || fail "missing $SKILL_PATH"
  grep -Eq '^  version: [0-9]+\.[0-9]+\.[0-9]+$' "$SKILL_PATH" || fail "SKILL.md frontmatter is missing a '  version: X.Y.Z' line"
fi

CURRENT_VERSION="$(extract_setting MARKETING_VERSION)"
CURRENT_BUILD="$(extract_setting CURRENT_PROJECT_VERSION)"

is_semver "$CURRENT_VERSION" || fail "current MARKETING_VERSION is not semantic: $CURRENT_VERSION"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || fail "current CURRENT_PROJECT_VERSION is not an integer: $CURRENT_BUILD"

if (( BUILD_ONLY == 1 )); then
  [[ "$MODE" == "$CURRENT_VERSION" ]] || fail "build-only requires the unchanged marketing version $CURRENT_VERSION"
  [[ -z "$CUSTOM_DATE" ]] || fail "--date is not supported for build-only updates"
  NEXT_BUILD="${CUSTOM_BUILD:-$((CURRENT_BUILD + 1))}"
  [[ "$NEXT_BUILD" =~ ^[0-9]+$ ]] || fail "build must be a positive integer"
  (( NEXT_BUILD > CURRENT_BUILD )) || fail "new build number must be greater than current build ($CURRENT_BUILD)"
  grep -Fq "## [$CURRENT_VERSION]" "$CHANGELOG_PATH" ||
    grep -Fq "## $CURRENT_VERSION" "$CHANGELOG_PATH" || fail "CHANGELOG has no entry for $CURRENT_VERSION"
  if (( DRY_RUN == 1 )); then
    printf 'Would retain version %s and advance build %s to %s. Only Config/Version.xcconfig changes.\n' "$CURRENT_VERSION" "$CURRENT_BUILD" "$NEXT_BUILD"
    exit 0
  fi
  VERSION_TMP="$ROOT_DIR/Config/Version.xcconfig.tmp"
  awk -v next_build="$NEXT_BUILD" '
    /^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=/ {
      print "CURRENT_PROJECT_VERSION = " next_build
      next
    }
    { print }
  ' "$VERSION_CONFIG" > "$VERSION_TMP"
  mv "$VERSION_TMP" "$VERSION_CONFIG"
  printf 'Retained version %s; advanced build %s to %s.\n' "$CURRENT_VERSION" "$CURRENT_BUILD" "$NEXT_BUILD"
  exit 0
fi

case "$MODE" in
  major|minor|patch)
    NEXT_VERSION="$(bump_semver "$CURRENT_VERSION" "$MODE")"
    ;;
  *)
    is_semver "$MODE" || fail "version must be major, minor, patch, or X.Y.Z"
    NEXT_VERSION="$MODE"
    ;;
esac

[[ "$NEXT_VERSION" != "$CURRENT_VERSION" ]] || fail "next version matches current version ($CURRENT_VERSION)"

if [[ -n "$CUSTOM_BUILD" ]]; then
  [[ "$CUSTOM_BUILD" =~ ^[0-9]+$ ]] || fail "build must be a positive integer"
  NEXT_BUILD="$CUSTOM_BUILD"
else
  NEXT_BUILD="$((CURRENT_BUILD + 1))"
fi

(( NEXT_BUILD > CURRENT_BUILD )) || fail "new build number must be greater than current build ($CURRENT_BUILD)"

if [[ -n "$CUSTOM_DATE" ]]; then
  [[ "$CUSTOM_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "date must be YYYY-MM-DD"
  RELEASE_DATE="$CUSTOM_DATE"
else
  RELEASE_DATE="$(date +%F)"
fi

grep -Fq "## [$NEXT_VERSION]" "$CHANGELOG_PATH" && fail "CHANGELOG already contains version $NEXT_VERSION"

ensure_unreleased_section_exists

if (( DRY_RUN == 1 )); then
  cat <<EOF
Current version: $CURRENT_VERSION (build $CURRENT_BUILD)
Next version:    $NEXT_VERSION (build $NEXT_BUILD)
Release date:    $RELEASE_DATE

Would update:
  - $VERSION_CONFIG
  - $CHANGELOG_PATH
  - $SKILL_PATH

Would rename "## [Unreleased]" to "## [$NEXT_VERSION] - $RELEASE_DATE" (existing
content under it, if any, is preserved as-is) and insert a fresh empty
"## [Unreleased]" skeleton above it.

Would rewrite SKILL.md's "  version: X.Y.Z" frontmatter line to "  version: $NEXT_VERSION".
EOF
  exit 0
fi

VERSION_TMP="$ROOT_DIR/Config/Version.xcconfig.tmp"
CHANGELOG_TMP="$ROOT_DIR/CHANGELOG.md.tmp"
SKILL_TMP="$SKILL_PATH.tmp"

awk -v next_version="$NEXT_VERSION" -v next_build="$NEXT_BUILD" '
  BEGIN {
    version_updated = 0
    build_updated = 0
  }
  /^[[:space:]]*MARKETING_VERSION[[:space:]]*=/ {
    print "MARKETING_VERSION = " next_version
    version_updated = 1
    next
  }
  /^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=/ {
    print "CURRENT_PROJECT_VERSION = " next_build
    build_updated = 1
    next
  }
  { print }
  END {
    if (!version_updated || !build_updated) {
      exit 1
    }
  }
' "$VERSION_CONFIG" > "$VERSION_TMP" || fail "failed to update version config"

renamed_unreleased=0
awk -v next_version="$NEXT_VERSION" -v release_date="$RELEASE_DATE" -v next_build="$NEXT_BUILD" -v doc="$VERSION_DOC" '
  /^## \[Unreleased\]/ && !replaced {
    print "## [Unreleased]"
    print ""
    print "### Added"
    print ""
    print "### Changed"
    print ""
    print "### Fixed"
    print ""
    print "## [" next_version "] - " release_date
    print ""
    print "App version **" next_version "** (build **" next_build "**). See [release workflow](" doc ")."
    replaced = 1
    next
  }
  { print }
' "$CHANGELOG_PATH" > "$CHANGELOG_TMP" && renamed_unreleased=1

[[ "$renamed_unreleased" -eq 1 ]] || fail "failed to update changelog"
grep -Fq "## [$NEXT_VERSION] - $RELEASE_DATE" "$CHANGELOG_TMP" || fail "failed to rename [Unreleased] section"

skill_version_updated=0
awk -v next_version="$NEXT_VERSION" '
  /^  version: [0-9]+\.[0-9]+\.[0-9]+$/ && !replaced {
    print "  version: " next_version
    replaced = 1
    next
  }
  { print }
  END {
    if (!replaced) exit 1
  }
' "$SKILL_PATH" > "$SKILL_TMP" && skill_version_updated=1

[[ "$skill_version_updated" -eq 1 ]] || fail "failed to update SKILL.md version"
grep -Fq "  version: $NEXT_VERSION" "$SKILL_TMP" || fail "failed to rewrite SKILL.md version line"

mv "$VERSION_TMP" "$VERSION_CONFIG"
mv "$CHANGELOG_TMP" "$CHANGELOG_PATH"
mv "$SKILL_TMP" "$SKILL_PATH"

echo "Updated $VERSION_CONFIG -> $NEXT_VERSION (build $NEXT_BUILD)"
echo "Renamed [Unreleased] in $CHANGELOG_PATH to [$NEXT_VERSION] - $RELEASE_DATE (content preserved) and added a fresh empty [Unreleased]"
echo "Updated $SKILL_PATH -> version: $NEXT_VERSION"
echo "Next steps:"
echo "  1. Review the $NEXT_VERSION section for accuracy"
echo "  2. Run validation"
echo "  3. Package with fastlane mac release, then tag manually: git tag -a v$NEXT_VERSION -m \"Release v$NEXT_VERSION\""
