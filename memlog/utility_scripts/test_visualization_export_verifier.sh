#!/bin/zsh
# No host UI, permissions changes, dependencies, or cleanup. Retain negative-case receipts.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="$ROOT_DIR/memlog/utility_scripts/test-fixtures/visualization-export"
VERIFIER="$ROOT_DIR/memlog/utility_scripts/verify_visualization_export.sh"
[[ -d "$ROOT_DIR/build/HostTestResults" && ! -L "$ROOT_DIR/build" && ! -L "$ROOT_DIR/build/HostTestResults" ]] || exit 65
RUN_DIR=$(mktemp -d "$ROOT_DIR/build/HostTestResults/export-verifier-XXXXXX")
[[ -n "$RUN_DIR" && "$RUN_DIR" == "$ROOT_DIR/build/HostTestResults/export-verifier-"* ]] || exit 65
OUTPUT_NAME=$(<"$FIXTURES/receipt.txt")
for test_id in single repeated failed skipped absent; do
  expected=0
  [[ "$test_id" != single ]] || expected=1
  [[ "$test_id" != repeated ]] || expected=2
  actual=$(jq --arg id "$test_id" -f "$ROOT_DIR/memlog/utility_scripts/visualization_export_pass_count.jq" "$FIXTURES/tests.json")
  [[ "$actual" -eq "$expected" ]] || { echo "Incorrect successful execution count for $test_id"; exit 1; }
  echo "PASS: execution count $test_id"
done
for scenario in valid missing invalid truncated receipt-count traversal duplicate; do
  CASE_DIR="$RUN_DIR/$scenario"
  mkdir -p "$CASE_DIR/attachments"
  cp "$FIXTURES/manifest.json" "$CASE_DIR/attachments/manifest.json"
  cp "$FIXTURES/receipt.txt" "$CASE_DIR/attachments/receipt.txt"
  expected=1
  case "$scenario" in
    missing) ;;
    invalid) cp "$FIXTURES/invalid.txt" "$CASE_DIR/$OUTPUT_NAME" ;;
    truncated) head -c 8 "$ROOT_DIR/assets/Feature-Screenshots/live-traffic-table.png" > "$CASE_DIR/$OUTPUT_NAME" ;;
    *) cp "$ROOT_DIR/assets/Feature-Screenshots/live-traffic-table.png" "$CASE_DIR/$OUTPUT_NAME" ;;
  esac
  case "$scenario" in
    receipt-count) expected=2 ;;
    traversal) cp "$FIXTURES/traversal.txt" "$CASE_DIR/attachments/receipt.txt" ;;
    duplicate)
      jq '.[0].attachments += .[0].attachments' "$FIXTURES/manifest.json" > "$CASE_DIR/attachments/manifest.json"
      expected=2 ;;
  esac
  result=0
  /bin/zsh "$VERIFIER" "$CASE_DIR" "$expected" > "$CASE_DIR/check.log" 2>&1 || result=$?
  if [[ "$scenario" == valid ]]; then
    [[ "$result" -eq 0 ]] || { echo "Valid PNG rejected; inspect $CASE_DIR/check.log"; exit 1; }
  else
    [[ "$result" -eq 65 ]] || { echo "$scenario returned $result, expected rejection; inspect $CASE_DIR/check.log"; exit 1; }
  fi
  echo "PASS: $scenario"
done
echo "Verifier evidence retained: $RUN_DIR"
