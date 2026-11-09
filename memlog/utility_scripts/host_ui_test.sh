#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
DRY_RUN=false
if [[ "${1:-}" == --dry-run ]]; then DRY_RUN=true; shift; fi

if [[ "${1:-}" != "--acknowledge-host-control" ]]; then
  echo "This test lane controls the Mac's focus, keyboard, windows, and application lifecycle."
  echo "Run only with the local user's permission:"
  echo "  $0 [--dry-run] --acknowledge-host-control [--plan ui|smoke|full|profiling|stability] [--lean-probe] [xcodebuild test options]"
  exit 64
fi
shift

# Dry-run is inspection only, not host-health or product-freshness certification.
if [[ "$DRY_RUN" != true ]]; then
# A locked login session cannot activate the test app; fail before a costly XCTest timeout.
if /usr/sbin/ioreg -n Root -d 1 2>/dev/null | /usr/bin/grep '"CGSSessionScreenIsLocked"=Yes' >/dev/null; then
  echo "Host UI testing cannot start while this Mac is locked."
  echo "Unlock the Mac and keep the desktop available, then rerun this approved workflow."
  exit 69
fi

SPACE_LINE="$(df -Pk "$ROOT_DIR" | tail -n 1)"
read -r DISK_DEVICE DISK_TOTAL_KB DISK_USED_KB DISK_AVAILABLE_KB DISK_CAPACITY DISK_MOUNT <<< "$SPACE_LINE"
if [[ "$DISK_AVAILABLE_KB" != <-> || "$DISK_AVAILABLE_KB" -lt 5242880 ]]; then
  echo "Host UI testing requires at least 5 GiB free for build and diagnostic artifacts."
  echo "Available space: ${DISK_AVAILABLE_KB:-unknown} KiB. No test was launched; no files were deleted."
  exit 69
fi
fi

PLAN_NAME="JoesProxy-UI"
LANE_NAME="ui"
SCHEME_NAME="JoesProxy"
if [[ "${1:-}" == "--plan" ]]; then
  case "${2:-}" in
    ui)
      ;;
    smoke)
      PLAN_NAME="JoesProxy-Smoke"
      LANE_NAME="smoke"
      ;;
    full)
      PLAN_NAME="JoesProxy"
      LANE_NAME="full"
      ;;
    profiling)
      PLAN_NAME="JoesProxy-Profiling"
      LANE_NAME="profiling"
      SCHEME_NAME="JoesProxy-Profiling"
      ;;
    stability)
      PLAN_NAME="JoesProxy-Stability"
      LANE_NAME="stability"
      SCHEME_NAME="JoesProxy-Stability"
      ;;
    *)
      echo "Unknown host-test plan '${2:-}'. Expected ui, smoke, full, profiling, or stability."
      exit 64
      ;;
  esac
  shift 2
fi

DIAGNOSTIC_OPTIONS=()
if [[ "${1:-}" == "--lean-probe" ]]; then
  if [[ "$LANE_NAME" != "profiling" && "$LANE_NAME" != stability ]]; then
    echo "--lean-probe is profiling-only; correctness lanes keep their normal diagnostics."
    exit 64
  fi
  DIAGNOSTIC_OPTIONS=(-collect-test-diagnostics never)
  echo "Lean probe: retain test results and explicit attachments; suppress automatic verbose diagnostics."
  shift
fi

RUNTIME_PLAN=""
if [[ "${1:-}" == "--xctestrun" ]]; then
  if [[ ( "$LANE_NAME" != "profiling" && "$LANE_NAME" != stability ) || ! -f "${2:-}" ]]; then
    echo "--xctestrun requires the profiling lane and an existing prepared test-run file."
    exit 64
  fi
  RUNTIME_PLAN="$2"
  shift 2
fi

if [[ "$LANE_NAME" == stability && -z "$RUNTIME_PLAN" ]]; then
  echo "Stability never builds during a host run. Prepare with focused_test.sh --lane stability --prepare-only, then supply --xctestrun."
  exit 64
fi
if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run: lane=$LANE_NAME scheme=$SCHEME_NAME plan=$PLAN_NAME prepared=$RUNTIME_PLAN"
  echo "No build, launch, host interaction, writes, or freshness certification."
  exit 0
fi
if [[ "$LANE_NAME" == stability ]]; then
  RUNTIME_PLAN="${RUNTIME_PLAN:A}"
  [[ "$RUNTIME_PLAN" == "$ROOT_DIR/build/"* && "$RUNTIME_PLAN" == *JoesProxy-Stability*.xctestrun ]] || exit 65
  PREPARED_DATA="${RUNTIME_PLAN:h:h:h}"
  [[ -f "$PREPARED_DATA/stability-build-receipt.json" && ! -L "$PREPARED_DATA/stability-build-receipt.json" ]] || { echo "No certified stability preparation receipt."; exit 65; }
  PREPARED_PACKAGES=$(jq -er .packages "$PREPARED_DATA/stability-build-receipt.json")
  PREPARED_OPTIONS=()
  if jq -e '.compilerStats == true' "$PREPARED_DATA/stability-build-receipt.json" >/dev/null; then
    PREPARED_OPTIONS=(--compiler-stats)
  fi
  "$ROOT_DIR/memlog/utility_scripts/focused_test.sh" --lane stability --prepare-only --reuse-build \
    "${PREPARED_OPTIONS[@]}" \
    --derived-data "$PREPARED_DATA" --packages "$PREPARED_PACKAGES" \
    -only-testing JoesProxyUITests/CaptureStabilityProfilingUITests
fi

# Share the focused helper's cooperating lease; refuse unrelated active builds as well.
SERIAL_STATE="$ROOT_DIR/build/FocusedValidation"
[[ ! -L "$ROOT_DIR/build" && ! -L "$SERIAL_STATE" && ! -L "$SERIAL_STATE/serial.lock" ]] || exit 65
mkdir -p "$SERIAL_STATE"
touch "$SERIAL_STATE/serial.lock"
zmodload zsh/system
zsystem flock -t 0 -f HOST_VALIDATION_LOCK "$SERIAL_STATE/serial.lock" || { echo "Another validation owns the lease."; exit 75; }
BUILD_PROCESSES=$(ps -axo comm=) || { echo "Cannot establish idle build host."; exit 69; }
if print -r -- "$BUILD_PROCESSES" | /usr/bin/grep '/xcodebuild$' >/dev/null; then
  echo "An xcodebuild is already running. No host test launched."
  exit 69
fi

RESULT_DIRECTORY="$ROOT_DIR/build/HostTestResults"
[[ ! -L "$ROOT_DIR/build" && ! -L "$RESULT_DIRECTORY" ]] || { echo "Host artifact directories must not be symbolic links."; exit 65; }
mkdir -p "$RESULT_DIRECTORY"
RESULT_BUNDLE="$RESULT_DIRECTORY/${LANE_NAME}-$(date +%Y%m%d-%H%M%S)-$$.xcresult"
ARTIFACT_DIRECTORY="${RESULT_BUNDLE%.xcresult}-artifacts"
mkdir "$ARTIFACT_DIRECTORY"
# xcodebuild forwards TEST_RUNNER_ variables, removing the prefix, to the test process.
export TEST_RUNNER_JOESPROXY_UI_ARTIFACT_DIRECTORY="$ARTIFACT_DIRECTORY"

echo "Host control acknowledged. Running the serial JoesProxy ${LANE_NAME} test lane."
echo "Result bundle: $RESULT_BUNDLE"
set +e
if [[ -n "$RUNTIME_PLAN" ]]; then
xcodebuild test-without-building \
  "${DIAGNOSTIC_OPTIONS[@]}" \
  "$@" \
  -xctestrun "$RUNTIME_PLAN" \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage NO \
  -resultBundlePath "$RESULT_BUNDLE"
else
xcodebuild test \
  "${DIAGNOSTIC_OPTIONS[@]}" \
  "$@" \
  -scheme "$SCHEME_NAME" \
  -testPlan "$PLAN_NAME" \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage NO \
  -resultBundlePath "$RESULT_BUNDLE"
fi
TEST_STATUS=$?
set -e

echo "Verifying result bundle."
if ! xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE"; then
  echo "The host-test result bundle could not be read: $RESULT_BUNDLE"
  exit 65
fi

# File-output checks belong to the host, not the sandboxed UI runner. Validate successful
# repetitions even when an unrelated test fails; preserve xcodebuild's failure exit below.
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json > "$ARTIFACT_DIRECTORY/tests.json"
EXPORT_TEST='VisualizationExportUITests/testVisualizationExportPNGHappyPathWritesFileWithoutSavePanel()'
EXPORT_PASSES=$(jq --arg id "$EXPORT_TEST" -f "$ROOT_DIR/memlog/utility_scripts/visualization_export_pass_count.jq" "$ARTIFACT_DIRECTORY/tests.json")
if (( EXPORT_PASSES > 0 )); then
  xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" --test-id "$EXPORT_TEST" \
    --output-path "$ARTIFACT_DIRECTORY/attachments"
  /bin/zsh "$ROOT_DIR/memlog/utility_scripts/verify_visualization_export.sh" \
    "$ARTIFACT_DIRECTORY" "$EXPORT_PASSES"
fi

for DIAGNOSTICS_METHOD in testSettingsExportMatchesCopiedReport testSettingsExportWithAccessibilityText testAgentExportPreservesReportAcrossWorkspaceSwitch; do
  DIAGNOSTICS_TEST="PreviousRunDiagnosticsExportUITests/${DIAGNOSTICS_METHOD}()"
  DIAGNOSTICS_PASSES=$(jq --arg id "$DIAGNOSTICS_TEST" -f "$ROOT_DIR/memlog/utility_scripts/visualization_export_pass_count.jq" "$ARTIFACT_DIRECTORY/tests.json")
  if (( DIAGNOSTICS_PASSES > 0 )); then
    DIAGNOSTICS_ATTACHMENTS="$ARTIFACT_DIRECTORY/$DIAGNOSTICS_METHOD"
    xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" --test-id "$DIAGNOSTICS_TEST" \
      --output-path "$DIAGNOSTICS_ATTACHMENTS"
    /bin/zsh "$ROOT_DIR/memlog/utility_scripts/verify_diagnostics_export.sh" \
      "$ARTIFACT_DIRECTORY" "$DIAGNOSTICS_ATTACHMENTS" "$DIAGNOSTICS_PASSES"
  fi
done

exit "$TEST_STATUS"
