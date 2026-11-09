#!/bin/zsh
# Hostless verifier regressions. Synthetic files stay in the repository; no cleanup or UI.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
[[ -d "$ROOT_DIR/build" && ! -L "$ROOT_DIR/build" && ! -L "$ROOT_DIR/build/HostTestResults" ]] || exit 65
mkdir -p "$ROOT_DIR/build/HostTestResults"
RUN_DIR=$(mktemp -d "$ROOT_DIR/build/HostTestResults/diagnostics-verifier-XXXXXX")
[[ -n "$RUN_DIR" && "$RUN_DIR" == "$ROOT_DIR/build/HostTestResults/diagnostics-verifier-"* ]] || exit 65
OUTPUT_NAME="PreviousRunDiagnostics-00000000-0000-4000-8000-000000000001.txt"
REPORT=$'JoesProxy previous-run diagnostics\nSynthetic report. Nothing was uploaded.\n'
VERIFIER="$ROOT_DIR/memlog/utility_scripts/verify_diagnostics_export.sh"
for scenario in valid missing altered truncated oversized linked-output linked-receipt traversal duplicate receipt-count invalid-schema malformed wrong-prefix; do
  CASE_DIR="$RUN_DIR/$scenario"
  mkdir -p "$CASE_DIR/attachments"
  jq -n '[{attachments:[{suggestedHumanReadableName:"previous-run-diagnostics-output.json",exportedFileName:"receipt.json"}]}]' > "$CASE_DIR/attachments/manifest.json"
  jq -n --arg name "$OUTPUT_NAME" --arg report "$REPORT" \
    '{schemaVersion:1,outputName:$name,expectedText:$report}' > "$CASE_DIR/attachments/receipt.json"
  if [[ "$scenario" != missing ]]; then
    jq -j .expectedText "$CASE_DIR/attachments/receipt.json" > "$CASE_DIR/$OUTPUT_NAME"
  fi
  expected=1
  case "$scenario" in
    altered) print -r -- 'Different report' > "$CASE_DIR/$OUTPUT_NAME" ;;
    truncated) print -rn -- 'JoesProxy' > "$CASE_DIR/$OUTPUT_NAME" ;;
    oversized) /bin/dd if=/dev/zero of="$CASE_DIR/$OUTPUT_NAME" bs=1048577 count=1 2>/dev/null ;;
    linked-output)
      mv "$CASE_DIR/$OUTPUT_NAME" "$CASE_DIR/underlying.txt"
      ln -s underlying.txt "$CASE_DIR/$OUTPUT_NAME" ;;
    linked-receipt)
      mv "$CASE_DIR/attachments/receipt.json" "$CASE_DIR/underlying.json"
      ln -s ../underlying.json "$CASE_DIR/attachments/receipt.json" ;;
    traversal)
      jq -n --arg report "$REPORT" '{schemaVersion:1,outputName:"../outside.txt",expectedText:$report}' > "$CASE_DIR/attachments/receipt.json" ;;
    duplicate)
      jq -n '[{attachments:[{suggestedHumanReadableName:"previous-run-diagnostics-output.json",exportedFileName:"receipt.json"},{suggestedHumanReadableName:"previous-run-diagnostics-output.json",exportedFileName:"receipt.json"}]}]' > "$CASE_DIR/attachments/manifest.json"
      expected=2 ;;
    receipt-count) expected=2 ;;
    invalid-schema)
      jq -n --arg name "$OUTPUT_NAME" --arg report "$REPORT" '{schemaVersion:2,outputName:$name,expectedText:$report}' > "$CASE_DIR/attachments/receipt.json" ;;
    malformed) print -rn -- '{' > "$CASE_DIR/attachments/receipt.json" ;;
    wrong-prefix)
      jq -n --arg name "$OUTPUT_NAME" '{schemaVersion:1,outputName:$name,expectedText:"wrong report"}' > "$CASE_DIR/attachments/receipt.json" ;;
  esac
  result=0
  /bin/zsh "$VERIFIER" "$CASE_DIR" "$CASE_DIR/attachments" "$expected" > "$CASE_DIR/check.log" 2>&1 || result=$?
  if [[ "$scenario" == valid ]]; then
    [[ "$result" -eq 0 ]] || { echo "Valid export rejected: $CASE_DIR/check.log"; exit 1; }
  else
    [[ "$result" -eq 65 ]] || { echo "$scenario returned $result, expected 65: $CASE_DIR/check.log"; exit 1; }
  fi
  echo "PASS: $scenario"
done
echo "Verifier evidence: $RUN_DIR"
