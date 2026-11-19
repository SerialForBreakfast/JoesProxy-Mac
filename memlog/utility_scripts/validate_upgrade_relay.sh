#!/bin/zsh
# Validates protocol-upgrade (WebSocket) relaying through HTTPS inspection on this Mac, against one
# exact commit. Runs the upgrade tests on real loopback sockets through NIO and TLS interception:
# handshake and bidirectional relay, lifetime, slow-reader backpressure, teardown from each side,
# loopback revocation, handshake delivery evidence and nearby HTTPS relay regressions.
#
# It builds the current checkout through focused_test.sh (serial lease, fingerprint, locked
# packages) and, with --full-policy, runs the serial Policy plan on the same products. It refuses a
# dirty source tree or a commit other than --expect-commit, so its receipt describes that commit.
# No dependency changes, no UI control, no network beyond loopback.
#
# Usage:
#   memlog/utility_scripts/validate_upgrade_relay.sh --derived-data build/NAME \
#     --packages build/NAME/SourcePackages [--expect-commit <sha>] [--full-policy] \
#     [--build-timeout <seconds>] [--allow-dirty] [--dry-run]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

DERIVED_DATA=""
PACKAGES=""
EXPECT_COMMIT=""
FULL_POLICY=false
ALLOW_DIRTY=false
DRY_RUN=false
BUILD_TIMEOUT=""

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --derived-data) [[ "$#" -ge 2 ]] || usage; DERIVED_DATA="$2"; shift 2 ;;
    --packages) [[ "$#" -ge 2 ]] || usage; PACKAGES="$2"; shift 2 ;;
    --expect-commit) [[ "$#" -ge 2 ]] || usage; EXPECT_COMMIT="$2"; shift 2 ;;
    --build-timeout) [[ "$#" -ge 2 ]] || usage; BUILD_TIMEOUT="$2"; shift 2 ;;
    --full-policy) FULL_POLICY=true; shift ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unsupported argument: $1"; usage ;;
  esac
done
[[ -n "$DERIVED_DATA" && -n "$PACKAGES" ]] || { echo "--derived-data and --packages are required."; usage; }

# The tests that exercise the upgrade relay and the paths it shares with ordinary HTTPS relaying.
SELECTIONS=(
  JoesProxyTests/ProxyServerTests/testInspectedProtocolUpgradeRelaysBytesBothWays
  JoesProxyTests/ProxyServerTests/testInspectedUpgradeRelayLifetimeBackpressureAndTeardown
  JoesProxyTests/ProxyServerTests/testSequentialHTTPSRequestsStayIsolatedOnOneConnection
  JoesProxyTests/ProxyServerTests/testDelayedTLSAndOriginDoNotBlockHealthySiblingRequests
  JoesProxyTests/StreamingUpstreamForwarderTests
  JoesProxyTests/HTTPUpstreamConnectorTests
  JoesProxyTests/LoopbackDestinationPolicyTests
)

COMMIT=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
SOURCE_PATHS=(JoesProxy JoesProxyTests JoesProxyCLI JoesProxy.xcodeproj JoesProxy.xcworkspace JoesProxy-Policy.xctestplan memlog/utility_scripts)
DIRTY=$(git status --porcelain -- "${SOURCE_PATHS[@]}" 2>/dev/null || true)

if [[ -n "$EXPECT_COMMIT" ]]; then
  EXPECTED=$(git rev-parse --verify "${EXPECT_COMMIT}^{commit}" 2>/dev/null || true)
  [[ "$EXPECTED" == "$COMMIT" ]] || { echo "HEAD is $COMMIT, not the expected commit $EXPECT_COMMIT. Check out that commit first."; exit 65; }
fi
if [[ -n "$DIRTY" && "$ALLOW_DIRTY" != true ]]; then
  echo "Source changes are not committed, so the result would not describe $COMMIT:"
  echo "$DIRTY"
  echo "Commit or stash them, or pass --allow-dirty to validate the working tree (recorded as dirty)."
  exit 65
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT_DIR="build/UpgradeRelayValidation/$STAMP-${COMMIT[1,8]}"
FOCUSED_ARGS=(--derived-data "$DERIVED_DATA" --packages "$PACKAGES")
[[ -z "$BUILD_TIMEOUT" ]] || FOCUSED_ARGS+=(--build-timeout "$BUILD_TIMEOUT")
for selection in "${SELECTIONS[@]}"; do FOCUSED_ARGS+=(-only-testing "$selection"); done
POLICY_ARGS=(test-without-building -scheme JoesProxy -testPlan JoesProxy-Policy -parallel-testing-enabled NO
  -destination platform=macOS -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath "$PACKAGES"
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates
  -resultBundlePath "$OUT_DIR/Policy.xcresult")

echo "Upgrade relay validation for $BRANCH at $COMMIT${DIRTY:+ (dirty working tree)}"
if [[ "$DRY_RUN" == true ]]; then
  echo "Would run: memlog/utility_scripts/focused_test.sh ${FOCUSED_ARGS[*]}"
  [[ "$FULL_POLICY" != true ]] || echo "Would run: xcodebuild ${POLICY_ARGS[*]}"
  echo "Would write: $OUT_DIR/receipt.json"
  exit 0
fi

mkdir -p "$OUT_DIR"
FOCUSED_STATUS=0
./memlog/utility_scripts/focused_test.sh "${FOCUSED_ARGS[@]}" 2>&1 | tee "$OUT_DIR/focused.log" || FOCUSED_STATUS=$?
FOCUSED_RECEIPT=$(sed -n 's/^[a-z_]*: \(.*receipt\.json\)$/\1/p' "$OUT_DIR/focused.log" | tail -1)
FOCUSED_OUTCOME="not_run"
if [[ -n "$FOCUSED_RECEIPT" && -f "$FOCUSED_RECEIPT" ]]; then
  FOCUSED_OUTCOME=$(plutil -extract outcome raw -o - "$FOCUSED_RECEIPT" 2>/dev/null || echo unknown)
  cp "$FOCUSED_RECEIPT" "$OUT_DIR/focused-receipt.json"
  SUMMARY="$(dirname "$FOCUSED_RECEIPT")/summary.json"
  [[ ! -f "$SUMMARY" ]] || cp "$SUMMARY" "$OUT_DIR/focused-summary.json"
fi

POLICY_OUTCOME="not_requested"
POLICY_STATUS=0
if [[ "$FULL_POLICY" == true ]]; then
  if [[ "$FOCUSED_OUTCOME" != passed ]]; then
    POLICY_OUTCOME="skipped_after_focused_failure"
  else
    xcodebuild "${POLICY_ARGS[@]}" > "$OUT_DIR/policy.log" 2>&1 || POLICY_STATUS=$?
    if xcrun xcresulttool get test-results summary --path "$OUT_DIR/Policy.xcresult" > "$OUT_DIR/policy-summary.json" 2>/dev/null; then
      POLICY_OUTCOME=$(plutil -extract result raw -o - "$OUT_DIR/policy-summary.json" 2>/dev/null || echo unknown)
    else
      POLICY_OUTCOME="no_result_bundle"
    fi
  fi
fi

cat > "$OUT_DIR/receipt.json" <<EOF
{
  "validation": "upgrade-relay-v1",
  "commit": "$COMMIT",
  "branch": "$BRANCH",
  "dirtyWorkingTree": $([[ -n "$DIRTY" ]] && echo true || echo false),
  "xcode": "$(xcodebuild -version 2>/dev/null | head -1)",
  "macOS": "$(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(uname -m)",
  "focused": {"outcome": "$FOCUSED_OUTCOME", "exitStatus": $FOCUSED_STATUS, "selections": ${#SELECTIONS[@]}},
  "fullPolicy": {"outcome": "$POLICY_OUTCOME", "exitStatus": $POLICY_STATUS},
  "notCovered": "Real third-party WebSocket servers, HTTP/2 extended CONNECT (RFC 8441), and the signed release build."
}
EOF

echo "Receipt: $OUT_DIR/receipt.json"
echo "Focused: $FOCUSED_OUTCOME; full Policy: $POLICY_OUTCOME"
[[ "$FOCUSED_OUTCOME" == passed ]] || exit 1
[[ "$FULL_POLICY" != true || "$POLICY_OUTCOME" == Passed ]] || exit 1
