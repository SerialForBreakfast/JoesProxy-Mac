#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
SCANNER="${GITLEAKS_BIN:-gitleaks}"
EVIDENCE="${JOESPROXY_PREVIEW_SECRET_EVIDENCE:-$ROOT_DIR/build/PublicPreview/evidence}"
mkdir -p "$EVIDENCE/empty-ignore"
[[ "$("$SCANNER" version)" == "8.30.1" ]] || { echo "Expected Gitleaks 8.30.1"; exit 65; }
set +e
"$SCANNER" dir . --config memlog/utility_scripts/public_preview_gitleaks.toml \
  --redact=100 --ignore-gitleaks-allow --gitleaks-ignore-path "$EVIDENCE/empty-ignore" \
  --max-archive-depth 2 --max-decode-depth 5 --timeout 180 \
  --report-format json --report-path "$EVIDENCE/secrets.json" > "$EVIDENCE/secrets.log" 2>&1
SCAN_EXIT=$?
set -e
[[ "$SCAN_EXIT" == 0 || "$SCAN_EXIT" == 1 ]] || { echo "Scanner failed with exit $SCAN_EXIT"; exit "$SCAN_EXIT"; }
if grep -Eq '(^|[[:space:]])(ERR|FTL)([[:space:]]|$)' "$EVIDENCE/secrets.log"; then
  echo "Scanner reported an error; coverage is incomplete."
  exit 65
fi
ruby memlog/utility_scripts/public_preview_security.rb findings "$EVIDENCE/secrets.json" "$EVIDENCE/secret-summary.json"
