#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "Usage: bash stage_diagnostic_skill.sh <existing DMG staging directory>" >&2
  exit 64
fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
name=joesproxy-mcp-diagnostics
source_dir="$root/.agents/skills/$name"
destination="$1/$name"

# The Policy export tests compare these Markdown files to the running app's export.
# Require a fresh destination so an old reference cannot survive a retry.
mkdir "$destination"
mkdir "$destination/references"
cp "$source_dir/SKILL.md" "$destination/"
cp "$source_dir"/references/*.md "$destination/references/"
