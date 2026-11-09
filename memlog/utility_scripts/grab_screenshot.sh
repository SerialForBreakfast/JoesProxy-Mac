#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/memlog/ui-review"
SCRATCH_ROOT="${OUTPUT_DIR}/scratch"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
MODES=("table" "explorer" "timeline" "guided-setup")
TEXT_SIZE="standard"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --text-size)
      TEXT_SIZE="${2:-}"
      shift 2
      ;;
    --mode)
      MODES=("${2:-}")
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ "${TEXT_SIZE}" != "standard" && "${TEXT_SIZE}" != "accessibility" ]]; then
  echo "Unsupported text size: ${TEXT_SIZE}"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}" "${SCRATCH_ROOT}"
find "${SCRATCH_ROOT}" -maxdepth 1 -type d -name 'grab-screenshot-*' -exec rm -rf {} +

for MODE in "${MODES[@]}"; do
  SCRATCH_DIR="${SCRATCH_ROOT}/grab-screenshot-${MODE}-${TIMESTAMP}"
  RESULT_BUNDLE="${SCRATCH_DIR}/screenshot-${MODE}-${TIMESTAMP}.xcresult"
  EXPORT_DIR="${SCRATCH_DIR}/attachments"
  if [[ "${TEXT_SIZE}" == "standard" ]]; then
    FINAL_IMAGE="${OUTPUT_DIR}/joesproxy-screenshot-${MODE}-${TIMESTAMP}.png"
  else
    FINAL_IMAGE="${OUTPUT_DIR}/joesproxy-screenshot-${MODE}-${TEXT_SIZE}-${TIMESTAMP}.png"
  fi

  cleanup() {
    rm -rf "${SCRATCH_DIR}"
  }

  trap cleanup EXIT

  case "${MODE}" in
    table)
      if [[ "${TEXT_SIZE}" == "accessibility" ]]; then
        TEST_NAME="testCaptureTableScreenshotWithAccessibilityTextSize"
        TEST_IDENTIFIER="ScreenshotUITests/testCaptureTableScreenshotWithAccessibilityTextSize()"
      else
        TEST_NAME="testCaptureTableScreenshotWithDemoSessions"
        TEST_IDENTIFIER="ScreenshotUITests/testCaptureTableScreenshotWithDemoSessions()"
      fi
      ;;
    explorer)
      if [[ "${TEXT_SIZE}" == "accessibility" ]]; then
        TEST_NAME="testCaptureExplorerScreenshotWithAccessibilityTextSize"
        TEST_IDENTIFIER="ScreenshotUITests/testCaptureExplorerScreenshotWithAccessibilityTextSize()"
      else
        TEST_NAME="testCaptureExplorerScreenshotWithDemoSessions"
        TEST_IDENTIFIER="ScreenshotUITests/testCaptureExplorerScreenshotWithDemoSessions()"
      fi
      ;;
    timeline)
      if [[ "${TEXT_SIZE}" == "accessibility" ]]; then
        TEST_NAME="testCaptureTimelineScreenshotWithAccessibilityTextSize"
        TEST_IDENTIFIER="ScreenshotUITests/testCaptureTimelineScreenshotWithAccessibilityTextSize()"
      else
        TEST_NAME="testCaptureTimelineScreenshotWithDemoSessions"
        TEST_IDENTIFIER="ScreenshotUITests/testCaptureTimelineScreenshotWithDemoSessions()"
      fi
      ;;
    guided-setup)
      TEST_NAME="testCaptureGuidedSetupFirstRunScreenshot"
      TEST_IDENTIFIER="ScreenshotUITests/testCaptureGuidedSetupFirstRunScreenshot()"
      ;;
    *)
      echo "Unsupported screenshot mode: ${MODE}"
      exit 1
      ;;
  esac

  rm -rf "${SCRATCH_DIR}"
  mkdir -p "${SCRATCH_DIR}"

  echo "Running ${MODE} screenshot UI test (${TEXT_SIZE})..."
  echo "Output image: ${FINAL_IMAGE}"

  xcodebuild test \
    -scheme JoesProxy \
    -destination "platform=macOS" \
    -only-testing "JoesProxyUITests/ScreenshotUITests/${TEST_NAME}" \
    -resultBundlePath "${RESULT_BUNDLE}"

  echo
  echo "Exporting ${MODE} screenshot attachment..."

  xcrun xcresulttool export attachments \
    --path "${RESULT_BUNDLE}" \
    --output-path "${EXPORT_DIR}" \
    --test-id "${TEST_IDENTIFIER}"

  ATTACHMENT_IMAGE="$(find "${EXPORT_DIR}" -type f -name "*.png" | head -n 1)"

  if [[ -z "${ATTACHMENT_IMAGE}" ]]; then
    echo "No PNG attachment was exported from ${RESULT_BUNDLE}."
    exit 1
  fi

  cp "${ATTACHMENT_IMAGE}" "${FINAL_IMAGE}"
  cleanup
  trap - EXIT

  echo
  echo "Saved ${MODE} screenshot:"
  echo "  ${FINAL_IMAGE}"
  echo
done
