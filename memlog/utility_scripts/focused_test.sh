#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

SCHEME="JoesProxy"
TEST_PLAN="JoesProxy-Policy"
DESTINATION="platform=macOS"
LANE="policy"
BUILD_TIMEOUT=600
COMPILER_STATS=false
PREFLIGHT_OPTIONS=()

REUSE_BUILD=false
DRY_RUN=false
PREPARE_ONLY=false
DERIVED_DATA=""
PACKAGES=""
RETRY_CHANGE=""
SOAK_PROFILE=""
TEST_ALLOWANCE=120
TEST_SELECTIONS=()
SELECTION_NAMES=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --reuse-build) REUSE_BUILD=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --prepare-only) PREPARE_ONLY=true; shift ;;
    --compiler-stats) COMPILER_STATS=true; PREFLIGHT_OPTIONS=(--compiler-stats); shift ;;
    --derived-data|--packages|--retry-after-change|--lane|--build-timeout|--soak-profile)
      [[ "$#" -ge 2 && -n "$2" ]] || exit 64
      case "$1" in
        --derived-data) DERIVED_DATA="$2" ;;
        --packages) PACKAGES="$2" ;;
        --retry-after-change) RETRY_CHANGE="$2" ;;
        --lane) LANE="$2" ;;
        --build-timeout) BUILD_TIMEOUT="$2" ;;
        --soak-profile) SOAK_PROFILE="$2" ;;
      esac
      shift 2 ;;
    -only-testing)
      [[ "$#" -ge 2 ]] || exit 64
      TEST_SELECTIONS+=("-only-testing:$2")
      SELECTION_NAMES+=("$2")
      shift 2 ;;
    -only-testing:*)
      TEST_SELECTIONS+=("$1"); SELECTION_NAMES+=("${1#-only-testing:}"); shift ;;
    *) echo "Unsupported argument: $1. This helper supports Policy/transport execution or stability preparation."; exit 64 ;;
  esac
done

[[ "$BUILD_TIMEOUT" == <-> ]] || { echo "Nonnegative preparation timeout required; 0 requires explicit authorization."; exit 64; }
CONFIGURATION="Debug"
EXTRA_OPTIONS=()
case "$LANE" in
  policy) ;;
  transport)
    SCHEME="JoesProxy-Transport"; TEST_PLAN="JoesProxy-Transport"; CONFIGURATION="Release"
    EXTRA_OPTIONS=(-enableAddressSanitizer NO -enableThreadSanitizer NO -enableUndefinedBehaviorSanitizer NO -enableCodeCoverage NO ENABLE_TESTABILITY=YES ENABLE_ADDRESS_SANITIZER=NO ENABLE_THREAD_SANITIZER=NO ENABLE_UNDEFINED_BEHAVIOR_SANITIZER=NO)
    ;;
  soak)
    # Hostless opt-in capture soak: Release unit products, no UI control. The profile sets duration.
    SCHEME="JoesProxy-Soak"; TEST_PLAN="JoesProxy-Soak"; CONFIGURATION="Release"
    EXTRA_OPTIONS=(-enableAddressSanitizer NO -enableThreadSanitizer NO -enableUndefinedBehaviorSanitizer NO -enableCodeCoverage NO ENABLE_TESTABILITY=YES ENABLE_ADDRESS_SANITIZER=NO ENABLE_THREAD_SANITIZER=NO ENABLE_UNDEFINED_BEHAVIOR_SANITIZER=NO)
    case "$SOAK_PROFILE" in
      pilot) TEST_ALLOWANCE=1500 ;;
      rehearsal) TEST_ALLOWANCE=4500 ;;
      overnight) TEST_ALLOWANCE=29700 ;;
      "") [[ "$PREPARE_ONLY" == true ]] || { echo "Soak execution requires --soak-profile pilot|rehearsal|overnight."; exit 64; } ;;
      *) echo "Unknown soak profile: $SOAK_PROFILE"; exit 64 ;;
    esac
    ;;
  stability)
    [[ "$PREPARE_ONLY" == true ]] || { echo "Stability supports preparation/reuse verification only. Execute through the host wrapper."; exit 64; }
    SCHEME="JoesProxy-Stability"; TEST_PLAN="JoesProxy-Stability"; CONFIGURATION="Release"
    EXTRA_OPTIONS=(-enableAddressSanitizer NO -enableThreadSanitizer NO -enableUndefinedBehaviorSanitizer NO -enableCodeCoverage NO)
    ;;
  *) echo "Unknown lane: $LANE"; exit 64 ;;
esac
[[ -z "$SOAK_PROFILE" || "$LANE" == soak ]] || { echo "--soak-profile applies to the soak lane only."; exit 64; }
if [[ "$COMPILER_STATS" == true && "$LANE" != stability ]]; then
  echo "Compiler statistics are restricted to stability preparation."; exit 64
fi

if [[ "${#TEST_SELECTIONS[@]}" -eq 0 || -z "$DERIVED_DATA" || -z "$PACKAGES" ]]; then
  echo "Usage: $0 [--lane policy|transport|stability|soak] [--soak-profile pilot|rehearsal|overnight] --derived-data build/NAME --packages build/NAME/SourcePackages [--reuse-build|--prepare-only] [--dry-run] [--compiler-stats] [--build-timeout 600] -only-testing TARGET/CLASS[/METHOD] [...]"
  echo "Explicit existing package storage is required. No dependency installation or updates."
  exit 64
fi

PREFLIGHT="$ROOT_DIR/memlog/utility_scripts/validation_preflight.py"
PATHS=$(python3 -B "$PREFLIGHT" "${PREFLIGHT_OPTIONS[@]}" --lane "$LANE" --derived-data "$DERIVED_DATA" --packages "$PACKAGES" --paths-only "${SELECTION_NAMES[@]}")
DERIVED_DATA=$(print -r -- "$PATHS" | jq -er .derivedData)
PACKAGES=$(print -r -- "$PATHS" | jq -er .packages)
BUILD_OPTIONS=(-scheme "$SCHEME" -testPlan "$TEST_PLAN" -destination "$DESTINATION"
  -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath "$PACKAGES"
  -parallel-testing-enabled NO -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates "${EXTRA_OPTIONS[@]}")
if [[ "$COMPILER_STATS" == true ]]; then
  STATS_DIRECTORY="$DERIVED_DATA/CompilerStats"
  [[ ! -L "$STATS_DIRECTORY" ]] || exit 65
  BUILD_OPTIONS+=("JOESPROXY_COMPILER_DIAGNOSTIC_FLAGS=-Xfrontend -stats-output-dir -Xfrontend \"$STATS_DIRECTORY\"")
fi

if [[ "$BUILD_TIMEOUT" == 0 ]]; then
  echo "$LANE preparation: monitored completion without a wall-clock cutoff; requires explicit authorization. No UI control."
else
  echo "$LANE preparation: ${BUILD_TIMEOUT}s limit. No UI control or physical interaction requested."
fi
if [[ "$DRY_RUN" == true ]]; then
  print -r -- "Build:" xcodebuild build-for-testing "${(@q)BUILD_OPTIONS}" "${(@q)TEST_SELECTIONS}"
  if [[ "$LANE" != stability ]]; then
    print -r -- "Run:" xcodebuild test-without-building "${(@q)BUILD_OPTIONS}" "${(@q)TEST_SELECTIONS}"
  else
    echo "Execution is separate: use the approved host wrapper's stability lane with the certified xctestrun."
  fi
  echo "Dry run: no writes, build, runner launch, or freshness/host-health certification."
  exit 0
fi

STATE="$ROOT_DIR/build/FocusedValidation"
[[ ! -L "$ROOT_DIR/build" && ! -L "$STATE" && ! -L "$STATE/serial.lock" ]] || exit 65
mkdir -p "$STATE"
touch "$STATE/serial.lock"
zmodload zsh/system
zsystem flock -t 0 -f VALIDATION_LOCK "$STATE/serial.lock" || { echo "Another focused validation owns the lease."; exit 75; }
if [[ -f "$STATE/runner-blocked.json" && "$PREPARE_ONLY" == false && -z "$RETRY_CHANGE" ]]; then
  echo "Runner failure is latched. Inspect $STATE/runner-blocked.json. Record an observed change with --retry-after-change; this is not an approval flag."
  exit 69
fi
INPUTS=$(python3 -B "$PREFLIGHT" "${PREFLIGHT_OPTIONS[@]}" --lane "$LANE" --derived-data "$DERIVED_DATA" --packages "$PACKAGES" --check-idle "${SELECTION_NAMES[@]}")
RUN_DIR=$(mktemp -d "$STATE/run-XXXXXX")
[[ -n "$RUN_DIR" && "$RUN_DIR" == "$STATE/run-"* ]] || exit 65
RECEIPT="$DERIVED_DATA/focused-build-receipt.json"
[[ "$LANE" != stability ]] || RECEIPT="$DERIVED_DATA/stability-build-receipt.json"
[[ "$LANE" != transport ]] || RECEIPT="$DERIVED_DATA/transport-build-receipt.json"
[[ "$LANE" != soak ]] || RECEIPT="$DERIVED_DATA/soak-build-receipt.json"
[[ ! -L "$RECEIPT" && ! -L "$STATE/runner-blocked.json" ]] || exit 65
BUILD_SECONDS=0
RUN_SECONDS=0
STARTED=$SECONDS

if [[ "$REUSE_BUILD" == false ]]; then
  if [[ "$COMPILER_STATS" == true ]]; then mkdir -p "$STATS_DIRECTORY"; fi
  echo "==> build-for-testing ($SCHEME, $TEST_PLAN)"
  python3 -B "$ROOT_DIR/memlog/utility_scripts/bounded_build.py" --seconds "$BUILD_TIMEOUT" -- xcodebuild build-for-testing "${BUILD_OPTIONS[@]}" "${TEST_SELECTIONS[@]}" > "$RUN_DIR/build.log" 2>&1 || { echo "Preparation failed/timeboxed: $RUN_DIR/build.log. Inspect remaining processes before retry; no test started."; exit 65; }
  BUILD_SECONDS=$((SECONDS - STARTED))
  AFTER=$(python3 -B "$PREFLIGHT" "${PREFLIGHT_OPTIONS[@]}" --lane "$LANE" --derived-data "$DERIVED_DATA" --packages "$PACKAGES" "${SELECTION_NAMES[@]}")
  [[ "$INPUTS" == "$AFTER" ]] || { echo "Inputs changed during build; refusing to certify or run stale products."; exit 65; }
  python3 -B "$PREFLIGHT" "${PREFLIGHT_OPTIONS[@]}" --lane "$LANE" --derived-data "$DERIVED_DATA" --packages "$PACKAGES" --products "${SELECTION_NAMES[@]}" > "$RUN_DIR/build-receipt.json"
  jq -e --argjson inputs "$INPUTS" 'del(.products) == $inputs' "$RUN_DIR/build-receipt.json" >/dev/null || { echo "Inputs changed while certifying products; refusing reuse receipt."; exit 65; }
  cp "$RUN_DIR/build-receipt.json" "$RECEIPT"
else
  [[ -f "$RECEIPT" && ! -L "$RECEIPT" ]] || { echo "No certified receipt. Prepare this scope first."; exit 65; }
  python3 -B "$PREFLIGHT" "${PREFLIGHT_OPTIONS[@]}" --lane "$LANE" --derived-data "$DERIVED_DATA" --packages "$PACKAGES" --products "${SELECTION_NAMES[@]}" > "$RUN_DIR/current-products.json"
  cmp -s "$RECEIPT" "$RUN_DIR/current-products.json" || { echo "Source, scope, configuration, packages or products changed. Rebuild without --reuse-build."; exit 65; }
  echo "==> Reusing fingerprint-verified test products."
fi

if [[ "$PREPARE_ONLY" == true ]]; then
  echo "Prepared, not executed (build phase: $BUILD_SECONDS seconds; fingerprint time excluded): $RUN_DIR"
  exit 0
fi
echo "==> test-without-building ($SCHEME, $TEST_PLAN, serial): ${TEST_SELECTIONS[*]}"
STARTED=$SECONDS
RESULT=0
if [[ "$LANE" == soak ]]; then
  # xcodebuild forwards TEST_RUNNER_-prefixed variables to the test host with the prefix removed.
  export TEST_RUNNER_JOESPROXY_SOAK_PROFILE="$SOAK_PROFILE"
  export TEST_RUNNER_JOESPROXY_SOAK_OUTPUT="$RUN_DIR"
  [[ "${JOESPROXY_SOAK_SEEDED_FAULT:-}" != 1 ]] || export TEST_RUNNER_JOESPROXY_SOAK_SEEDED_FAULT=1
fi
xcodebuild test-without-building "${BUILD_OPTIONS[@]}" "${TEST_SELECTIONS[@]}" -test-timeouts-enabled YES -maximum-test-execution-time-allowance "$TEST_ALLOWANCE" -resultBundlePath "$RUN_DIR/tests.xcresult" > "$RUN_DIR/tests.log" 2>&1 || RESULT=$?
RUN_SECONDS=$((SECONDS - STARTED))
xcrun xcresulttool get test-results summary --path "$RUN_DIR/tests.xcresult" --format json > "$RUN_DIR/summary.json" 2> "$RUN_DIR/summary-error.log" || true
OUTCOME=$(python3 -B "$PREFLIGHT" --classify "$RESULT" "$RUN_DIR/summary.json" "$RUN_DIR/tests.log")
jq -n --arg outcome "$OUTCOME" --arg retry "$RETRY_CHANGE" --argjson code "$RESULT" --argjson buildSeconds "$BUILD_SECONDS" --argjson testSeconds "$RUN_SECONDS" '{outcome:$outcome,exitCode:$code,buildSeconds:$buildSeconds,testSeconds:$testSeconds,retryAfterChange:$retry}' > "$RUN_DIR/receipt.json"
case "$OUTCOME" in
  infrastructure_blocked|incomplete_result|empty_selection) cp "$RUN_DIR/receipt.json" "$STATE/runner-blocked.json" ;;
  passed) [[ ! -f "$STATE/runner-blocked.json" ]] || mv "$STATE/runner-blocked.json" "$RUN_DIR/previous-runner-blocked.json" ;;
esac
echo "$OUTCOME: $RUN_DIR/receipt.json"
[[ "$OUTCOME" == passed ]] || exit 65
