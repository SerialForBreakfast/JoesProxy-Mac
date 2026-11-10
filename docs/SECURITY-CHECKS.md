# Security checks for the public preview

Revision 2026-11-09. The preview is published at `SerialForBreakfast/JoesProxy-Mac`. No hosted security badge is claimed.

## Hosted results, checked November 9, 2026

- Build and SDK tests: passed on initial commit `bd55cdb`.
- Secret scan: passed on `bd55cdb`.
- Swift CodeQL: failed on `bd55cdb` at the traced app build. CodeQL reports that traced analysis is not supported on macOS 27 or above and asks for macOS 26 and Xcode 26 or below. No code-scanning analysis exists and none is claimed. The job has since been moved to an Xcode 26.6 lane, described below, which has not yet run.
- Commit `6cec757` has no hosted run of any workflow.
- Private vulnerability reporting is not enabled. Steps 2 to 4 below were not verified.

## Setup checklist written before publication

1. Select the public destination and confirm that its project links point to the intended repository.
2. Enable private vulnerability reporting and verify that the security reporting button is visible. Update SECURITY.md to describe the working route after verification.
3. Enable secret scanning and push protection available for the destination.
4. Inspect dependency discovery and alerts. Record which lockfiles and dependencies were recognized. Swift/Xcode package coverage requires confirmation.
5. Configure build/test and code scanning on standard public macOS runners with a compatible Xcode version. The source was tested with Xcode 27.0. Record successful extraction and scanned Swift targets for CodeQL.

These remote settings require maintainer access to the repository.

## Build and code scanning setup

Start with manual workflow dispatch and one job at a time while establishing compatibility. Use the locked package versions, an unsigned app build, and the companion SDK's macOS tests. Hosted Policy execution additionally needs a working test-host signing configuration. Keep UI and device tests out of unattended acceptance until explicitly arranged.

CodeQL supports Swift and requires macOS for this language. Configure advanced setup with the actual JoesProxy app target, a compatible extraction toolchain and the security-and-quality query suite when available. Review the extracted database language and target coverage. A workflow that skips or fails extraction does not establish code-analysis coverage.

Use repository-content read permission by default. Grant security-events write only to the trusted job that uploads scanning results. Keep signing/notarization credentials and live capture data out of preview checks. Pin external actions to reviewed immutable commit IDs. Give checks bounded timeouts and artifacts short retention. Changes to external action/tool dependencies require the maintainer's approval.

The prepared workflows are [build and SDK tests](../.github/workflows/public-preview-build.yml), [Swift CodeQL](../.github/workflows/public-preview-codeql.yml), and [secret scanning](../.github/workflows/public-preview-secrets.yml). They run only on main pushes, manual dispatch and the stated weekly schedules. They accept no pull-request trigger.

Checkout, artifact upload and CodeQL actions are pinned to reviewed immutable official revisions. Secret scanning fetches Gitleaks 8.30.1 and verifies its fixed SHA-256 before extraction. No scanner is installed globally by that workflow. The build helper uses Xcode 27.0 for the build job, pinned package resolution, unsigned app compilation, offline CLI checks and SDK tests. CodeQL traces both the app/CLI build and the separate SDK test build. Full app Policy remains separate from these hosted jobs because the test host needs a validated signing configuration.

The build job uses the dedicated xcode-27 image and defaults DEVELOPER_DIR to /Applications/Xcode_27.0.app/Contents/Developer. The image inventory was checked to include Xcode 27.0 build 27A266a at that path. A maintainer can set the JOESPROXY_DEVELOPER_DIR repository variable to an installed equivalent. The helper rejects a selected Xcode version other than the expected one, 27.0 by default. If a later hosted image lacks that toolchain, the job fails for inspection; it never downloads another Xcode or substitutes a different toolchain automatically. The standard macos-26 image lacks Xcode 27.0.

The CodeQL job alone runs on the standard macos-26 image with Xcode 26.6 at /Applications/Xcode_26.6.app, and sets JOESPROXY_PREVIEW_XCODE_VERSION to 26.6 so the helper accepts it. The published image inventory lists that path. This lane is an experiment: the source has only been built with Xcode 27.0, and the companion SDK manifest requires Swift tools 6.3. If the app or SDK does not compile there, the job fails and no code analysis is claimed. A successful run analyzes an Xcode 26.6 build, which is not the tested Xcode 27.0 build.

Each workflow queues by branch in its own concurrency group, so build and CodeQL requests cannot replace each other's pending jobs. Native commands run serially within each isolated hosted job. Build and scan evidence expires after three days. Scanner artifacts contain only the content-free summary; redacted raw findings remain on the disposable runner. Each accepted fixture finding must match its reviewed rule, line and whole-file SHA-256 in Fixtures/Security/ReviewedSecretFindings.json. A new finding or changed fixture requires explicit review.

Run the prepared validation helpers locally:

```sh
ruby memlog/utility_scripts/public_preview_security.rb workflows
ruby memlog/utility_scripts/test_public_preview_security.rb
bash memlog/utility_scripts/public_preview_secret_scan.sh
```

The last command requires the already provisioned Gitleaks 8.30.1. It performs no installation. Reviewed scanner exceptions are checked, rather than hidden with directory suppressions. Generated build directories and Git database bytes are excluded from the current-source directory scan; public Git history still needs its own coverage.

## Local secret scan

The existing local Gitleaks scan ran with redaction, default rules and no broad path suppressions. It returned eight reviewed synthetic/type-annotation findings. See [the reviewed findings](SCANNER-FINDINGS.md). Keep that explicit classification with the result.

A maintainer with the existing scanner can run a fresh directory scan before publication. Scan the exact source directory from within it, retain redacted reports privately, and record scanner version, configuration, exclusions, result count and source digest. A later public Git history should receive its own history scan.

## Later maintenance

OpenSSF Scorecard can assess repository permissions and supply-chain practices once the public project exists. Use its findings as maintenance work with stated scope. Keep automatic dependency updates subject to review.

Publish the tested source revision, test counts/skips, scanner coverage and known limitations. Continue focused tests for local consent, credential handling and revocation. No scanner result establishes complete privacy compliance or an independent security audit.

References: [CodeQL](https://docs.github.com/en/code-security/concepts/code-scanning/codeql/codeql-code-scanning), [private reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository), [public runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [dependency support](https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-repositories), [Scorecard](https://securityscorecards.dev/).
