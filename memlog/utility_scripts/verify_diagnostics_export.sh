#!/bin/zsh
# Verify actual exported text against the synthetic clipboard receipt, without printing content.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ARTIFACT_DIRECTORY="${1:?Expected host artifact directory}"
ATTACHMENTS="${2:?Expected exported attachment directory}"
EXPECTED_COUNT="${3:?Expected successful execution count}"
fail() { echo "Diagnostics export verification failed: $*" >&2; exit 65; }
[[ "$EXPECTED_COUNT" == <-> && "$EXPECTED_COUNT" -gt 0 ]] || fail "invalid count"
[[ "$ARTIFACT_DIRECTORY" == "$ROOT_DIR/build/HostTestResults/"* && -d "$ARTIFACT_DIRECTORY" && ! -L "$ARTIFACT_DIRECTORY" ]] || fail "invalid artifact root"
[[ "$(cd "$ARTIFACT_DIRECTORY" && pwd -P)" == "$ARTIFACT_DIRECTORY" ]] || fail "linked artifact root"
[[ "$ATTACHMENTS" == "$ARTIFACT_DIRECTORY/"* && -d "$ATTACHMENTS" && ! -L "$ATTACHMENTS" ]] || fail "invalid attachments"
[[ "$(cd "$ATTACHMENTS" && pwd -P)" == "$ATTACHMENTS" ]] || fail "linked attachments"
[[ -f "$ATTACHMENTS/manifest.json" && ! -L "$ATTACHMENTS/manifest.json" ]] || fail "missing manifest"
RECEIPTS=$(jq -er '[.[].attachments[] | select(.suggestedHumanReadableName | startswith("previous-run-diagnostics-output")) | .exportedFileName] | if length > 0 then .[] else error("missing receipts") end' "$ATTACHMENTS/manifest.json") || fail "invalid manifest"
typeset -a receipt_files seen_outputs
receipt_files=("${(@f)RECEIPTS}")
[[ "${#receipt_files}" -eq "$EXPECTED_COUNT" ]] || fail "receipt count mismatch"
for receipt_file in "${receipt_files[@]}"; do
  [[ "$receipt_file" != */* && "$receipt_file" != .* && -f "$ATTACHMENTS/$receipt_file" && ! -L "$ATTACHMENTS/$receipt_file" ]] || fail "invalid receipt path"
  [[ $(stat -f %z "$ATTACHMENTS/$receipt_file") -le 1048576 ]] || fail "oversized receipt"
  jq -e '.schemaVersion == 1 and (.outputName | type == "string") and (.expectedText | type == "string" and startswith("JoesProxy previous-run diagnostics") and contains("Nothing was uploaded"))' "$ATTACHMENTS/$receipt_file" >/dev/null || fail "invalid receipt contract"
  output_name=$(jq -er .outputName "$ATTACHMENTS/$receipt_file")
  [[ "$output_name" =~ '^PreviousRunDiagnostics-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.txt$' ]] || fail "invalid output name"
  [[ "${seen_outputs[(Ie)$output_name]}" -eq 0 ]] || fail "duplicate output"
  seen_outputs+=("$output_name")
  output_file="$ARTIFACT_DIRECTORY/$output_name"
  [[ -f "$output_file" && ! -L "$output_file" && -s "$output_file" ]] || fail "missing output"
  [[ $(stat -f %z "$output_file") -le 1048576 ]] || fail "oversized output"
  jq -j .expectedText "$ATTACHMENTS/$receipt_file" | cmp -s - "$output_file" || fail "saved bytes differ from copied report"
done
echo "Verified $EXPECTED_COUNT diagnostics export(s), byte-for-byte."
