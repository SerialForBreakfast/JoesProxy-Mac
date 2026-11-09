#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/memlog/perf-results"
RESULT_BUNDLE="${OUTPUT_DIR}/JoesProxyUIPerformance.xcresult"
RAW_METRICS_JSON="${OUTPUT_DIR}/ui-performance-metrics.json"
METRICS_NDJSON="${OUTPUT_DIR}/ui-performance-metrics.ndjson"
SUMMARY_MD="${OUTPUT_DIR}/ui-performance-summary.md"
SCHEME="JoesProxy"
DESTINATION="platform=macOS"
EXPECTED_METRIC_COUNT=2

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to summarize xcresult performance metrics."
  exit 69
fi

cd "${ROOT_DIR}"
mkdir -p "${OUTPUT_DIR}"
rm -rf "${RESULT_BUNDLE}" "${RAW_METRICS_JSON}" "${METRICS_NDJSON}" "${SUMMARY_MD}"

echo "==> Running UI performance tests"
echo "    Result bundle: ${RESULT_BUNDLE}"

xcodebuild test \
  -scheme "${SCHEME}" \
  -destination "${DESTINATION}" \
  -only-testing "JoesProxyUITests/SessionPerformanceUITests/testLaunchPerformanceWithLargeDemoSessions" \
  -only-testing "JoesProxyUITests/SessionPerformanceUITests/testTableExplorerSwitchPerformanceWithLargeDemoSessions" \
  -resultBundlePath "${RESULT_BUNDLE}"

echo
echo "==> Extracting performance metrics"

TESTS_REF="$(
  xcrun xcresulttool get object --legacy \
    --path "${RESULT_BUNDLE}" \
    --format json \
  | jq -r 'first(.. | objects | .testsRef? | .id._value? // empty)'
)"

if [[ -z "${TESTS_REF}" || "${TESTS_REF}" == "null" ]]; then
  echo "No testsRef was found in ${RESULT_BUNDLE}."
  exit 65
fi

: > "${METRICS_NDJSON}"

while IFS=$'\t' read -r TEST_IDENTIFIER SUMMARY_REF; do
  if [[ -z "${TEST_IDENTIFIER}" || -z "${SUMMARY_REF}" ]]; then
    continue
  fi

  xcrun xcresulttool get object --legacy \
    --path "${RESULT_BUNDLE}" \
    --id "${SUMMARY_REF}" \
    --format json \
  | jq -c --arg testIdentifier "${TEST_IDENTIFIER}" '
      .. | objects
      | select(._type._name? == "ActionTestPerformanceMetricSummary")
      | {
          testIdentifier: $testIdentifier,
          displayName: .displayName._value,
          unitOfMeasurement: .unitOfMeasurement._value,
          identifier: .identifier._value,
          measurements: [.measurements._values[]?._value | tonumber]
        }
    ' >> "${METRICS_NDJSON}"
done < <(
  xcrun xcresulttool get object --legacy \
    --path "${RESULT_BUNDLE}" \
    --id "${TESTS_REF}" \
    --format json \
  | jq -r '
      .. | objects
      | select(._type._name? == "ActionTestMetadata")
      | [.identifier._value? // .name._value? // "", .summaryRef.id._value? // ""]
      | @tsv
    '
)

jq -s '.' "${METRICS_NDJSON}" > "${RAW_METRICS_JSON}"

METRIC_COUNT="$(jq 'length' "${RAW_METRICS_JSON}")"
if [[ "${METRIC_COUNT}" -lt "${EXPECTED_METRIC_COUNT}" ]]; then
  echo "No performance metrics were found in ${RESULT_BUNDLE}."
  echo "Expected at least ${EXPECTED_METRIC_COUNT}; found ${METRIC_COUNT}."
  exit 65
fi

{
  echo "# UI Performance Metrics"
  echo
  echo "- Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "- Result bundle: \`memlog/perf-results/JoesProxyUIPerformance.xcresult\`"
  echo "- Raw metrics: \`memlog/perf-results/ui-performance-metrics.json\`"
  echo
  echo "| Test | Metric | Unit | Samples | Average | Min | Max |"
  echo "|---|---|---:|---:|---:|---:|---:|"
  jq -r '
    def fmt:
      if . == null then
        "n/a"
      else
        (((. * 1000) | round) / 1000 | tostring)
      end;
    def avg:
      if length == 0 then
        null
      else
        add / length
      end;
    .[]
    | .measurements as $measurements
    | "| \(.testIdentifier) | \(.displayName) | \(.unitOfMeasurement) | \($measurements | length) | \(($measurements | avg) | fmt) | \(($measurements | min) | fmt) | \(($measurements | max) | fmt) |"
  ' "${RAW_METRICS_JSON}"
} > "${SUMMARY_MD}"

echo "Metrics JSON: ${RAW_METRICS_JSON}"
echo "Summary: ${SUMMARY_MD}"
