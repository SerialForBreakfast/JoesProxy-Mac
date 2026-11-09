#!/bin/zsh
# Host-side verification of XCTest UI-completion receipts. Retain all evidence; no cleanup.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ARTIFACT_DIRECTORY="${1:?Expected a host artifact directory}"
EXPECTED_COUNT="${2:?Expected a successful execution count}"
fail() { echo "Visualization export verification failed: $*" >&2; exit 65; }
[[ "$EXPECTED_COUNT" == <-> && "$EXPECTED_COUNT" -gt 0 ]] || fail "invalid execution count"
[[ "$ARTIFACT_DIRECTORY" == "$ROOT_DIR/build/HostTestResults/"* && -d "$ARTIFACT_DIRECTORY" && ! -L "$ARTIFACT_DIRECTORY" ]] || fail "invalid artifact directory"
[[ "$(cd "$ARTIFACT_DIRECTORY" && pwd -P)" == "$ARTIFACT_DIRECTORY" ]] || fail "artifact path contains a link or traversal"
ATTACHMENTS="$ARTIFACT_DIRECTORY/attachments"
[[ -d "$ATTACHMENTS" && ! -L "$ATTACHMENTS" && -f "$ATTACHMENTS/manifest.json" && ! -L "$ATTACHMENTS/manifest.json" ]] || fail "missing attachment manifest"
RECEIPTS=$(jq -r '[.[].attachments[] | select(.suggestedHumanReadableName | startswith("visualization-export-output")) | .exportedFileName] | .[]' "$ATTACHMENTS/manifest.json")
typeset -a receipt_files seen_outputs
receipt_files=("${(@f)RECEIPTS}")
[[ -n "$RECEIPTS" && "${#receipt_files}" -eq "$EXPECTED_COUNT" ]] || fail "expected $EXPECTED_COUNT completion receipts, found ${#receipt_files}"
for receipt_file in "${receipt_files[@]}"; do
  [[ "$receipt_file" != */* && "$receipt_file" != .* && -f "$ATTACHMENTS/$receipt_file" && ! -L "$ATTACHMENTS/$receipt_file" ]] || fail "invalid receipt path"
  output_name=$(<"$ATTACHMENTS/$receipt_file")
  [[ "$output_name" =~ '^VisualizationExportUITest-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.png$' ]] || fail "invalid output filename"
  [[ "${seen_outputs[(Ie)$output_name]}" -eq 0 ]] || fail "duplicate output receipt"
  seen_outputs+=("$output_name")
  output_file="$ARTIFACT_DIRECTORY/$output_name"
  [[ -f "$output_file" && -s "$output_file" && ! -L "$output_file" ]] || fail "missing or empty PNG: $output_name"
  signature=$(od -An -tx1 -N8 "$output_file" | tr -d ' \n')
  [[ "$signature" == 89504e470d0a1a0a ]] || fail "invalid PNG signature: $output_name"
  decoded_file="$ARTIFACT_DIRECTORY/validated-$output_name"
  [[ ! -e "$decoded_file" && ! -L "$decoded_file" ]] || fail "validation output already exists"
  /usr/bin/sips -s format png "$output_file" --out "$decoded_file" > "$ARTIFACT_DIRECTORY/validation-$output_name.log" 2>&1 || fail "PNG decode failed: $output_name"
  [[ -s "$decoded_file" ]] || fail "PNG decoder produced no output"
  /usr/bin/shasum -a 256 "$output_file"
done
echo "Verified $EXPECTED_COUNT exported PNG file(s). Evidence retained: $ARTIFACT_DIRECTORY"
