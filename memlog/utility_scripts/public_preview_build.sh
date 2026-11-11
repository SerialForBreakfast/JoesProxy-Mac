#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
BUILD_ROOT="${JOESPROXY_PREVIEW_BUILD_ROOT:-$ROOT_DIR/build/PublicPreview}"
PACKAGES="$BUILD_ROOT/SourcePackages"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
EVIDENCE="$BUILD_ROOT/evidence"
EXPECTED_XCODE="${JOESPROXY_PREVIEW_XCODE_VERSION:-27.0}"
mkdir -p "$EVIDENCE"

xcodebuild -version > "$EVIDENCE/toolchain.txt"
ACTUAL_XCODE="$(awk 'NR == 1 { print $2 }' "$EVIDENCE/toolchain.txt")"
if [[ "$ACTUAL_XCODE" != "$EXPECTED_XCODE" ]]; then
  echo "Expected Xcode $EXPECTED_XCODE; selected Xcode is $ACTUAL_XCODE."
  exit 65
fi

LOCKFILE="JoesProxy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
WORKSPACE_LOCKFILE="JoesProxy.xcworkspace/xcshareddata/swiftpm/Package.resolved"
LOCK_HASHES="$(shasum -a 256 "$LOCKFILE" "$WORKSPACE_LOCKFILE" Gemfile.lock)"
EXPECTED_VERSION="$(awk -F ' = ' '/^MARKETING_VERSION = / { print $2 }' Config/Version.xcconfig)"
EXPECTED_BUILD="$(awk -F ' = ' '/^CURRENT_PROJECT_VERSION = / { print $2 }' Config/Version.xcconfig)"
verify_locks() {
  [[ "$(shasum -a 256 "$LOCKFILE" "$WORKSPACE_LOCKFILE" Gemfile.lock)" == "$LOCK_HASHES" ]] || {
    echo "Dependency lockfiles changed; review required."
    exit 65
  }
}
trap verify_locks EXIT

COMMON=(-project JoesProxy.xcodeproj -scheme JoesProxy
  -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath "$PACKAGES"
  -packageCachePath "$BUILD_ROOT/PackageCache" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates)

case "${1:-}" in
  resolve)
    xcodebuild -resolvePackageDependencies "${COMMON[@]}" 2>&1 | tee "$EVIDENCE/dependencies.log"
    ;;
  build)
    xcodebuild build "${COMMON[@]}" -disableAutomaticPackageResolution \
      -configuration Debug -destination "platform=macOS" \
      -jobs 2 CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$EVIDENCE/app-build.log"
    CLI="$DERIVED_DATA/Build/Products/Debug/JoesProxy.app/Contents/MacOS/joesproxyctl"
    "$CLI" version --json > "$EVIDENCE/cli-version.json"
    "$CLI" docs read --topic reference-cli --section compare-saved-responses --format json > "$EVIDENCE/cli-help.json"
    jq -e --arg version "$EXPECTED_VERSION" --arg build "$EXPECTED_BUILD" \
      '.success and .result.version == $version and .result.build == $build' "$EVIDENCE/cli-version.json"
    jq -e '.success and .result.incomplete == false' "$EVIDENCE/cli-help.json"
    ;;
  filtered-calculations)
    xcodebuild test "${COMMON[@]}" -disableAutomaticPackageResolution -configuration Debug \
      -resultBundlePath "$EVIDENCE/filtered-calculations.xcresult" \
      -destination "platform=macOS" -testPlan JoesProxy-Policy -parallel-testing-enabled NO \
      -only-testing:JoesProxyTests/MCPResponseDisclosureIntegrationTests/testFilteredCalculationChecksAuthorityAndQualifiesEmptyWindows \
      -only-testing:JoesProxyTests/MCPResponseDisclosureIntegrationTests/testFilteredWindowDetectsLateCompletion \
      -only-testing:JoesProxyTests/MCPResponseDisclosureIntegrationTests/testFilteredGroupsReconcileTiesHistoryLossAndWorkLimit \
      -only-testing:JoesProxyTests/MCPResponseDisclosureIntegrationTests/testFilteredCalculationAgainstPagedSearchAndExplicitBatches \
      -only-testing:JoesProxyTests/CLIArtifactArgumentsTests/testFilteredMetadataArgumentsRequireExactlyOneSelection \
      -only-testing:JoesProxyTests/JoesProxyCLITests \
      -only-testing:JoesProxyTests/ArtifactCalculationTests \
      -only-testing:JoesProxyTests/ResponseEvidenceBriefTests \
      -only-testing:JoesProxyTests/InvestigationComparisonBriefTests \
      -only-testing:JoesProxyTests/AuthChainBriefTests \
      -only-testing:JoesProxyTests/MCPCaptureActivitySinceMarkerTests \
      -only-testing:JoesProxyTests/MCPMediaDiscoveryTests \
      -only-testing:JoesProxyTests/MCPAgentExportTests \
      -only-testing:JoesProxyTests/MCPRuntimeIdentityTests \
      -only-testing:JoesProxyTests/MCPDiagnosticRunServiceTests \
      -only-testing:JoesProxyTests/DocumentationCatalogTests \
      -jobs 2 CODE_SIGN_IDENTITY=- 2>&1 | tee "$EVIDENCE/filtered-calculations.log"
    grep -F "filtered-capture-300 baselineCalls=" "$EVIDENCE/filtered-calculations.log"
    ;;
  sdk)
    swift test --package-path Companion/JoesProxySDK --scratch-path "$BUILD_ROOT/SDKTests" \
      --disable-automatic-resolution --skip-update 2>&1 | tee "$EVIDENCE/sdk-tests.log"
    ;;
  *)
    echo "Usage: public_preview_build.sh resolve|build|sdk"
    exit 64
    ;;
esac
