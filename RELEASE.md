# Release workflow

Current as of November 14, 2026. The public release is 1.9.0 (23). The signed and notarized 1.9.1 (25) installer is in private acceptance. Use the [candidate record](docs/releases/1.9.1-build25.md) and [checksum manifest](Releases/SHA256SUMS) for this build.

Config/Version.xcconfig defines the marketing version and monotonically increasing build number. The version helper updates configuration, changelog and checked-in diagnostic skill metadata together. Review its changes before validation.

For a replacement private candidate retaining the same marketing version, use `bash bump_version.sh 1.9.0 --build-only --dry-run`, then omit --dry-run after review. This advances only CURRENT_PROJECT_VERSION; it preserves the marketing version, changelog headings and skill metadata. Do not reuse a distributed build number.

The optional `zsh memlog/utility_scripts/private_candidate_release.sh . build/ReleaseCandidate` controller holds the shared serial leases and delegates to the same release lane. It requires an already working locked release runtime and does not install or update tools. Its --dry-run option checks the selected source/output routes without running the lane. Preserve previous candidates by choosing an unused output directory.

Use the pinned tool and dependency versions already configured by the maintainer. Read Gemfile.lock before selecting the release runtime. Dependency installation or updates require separate authorization.

The existing `fastlane mac release` lane runs serial Policy tests, creates a universal Release archive, exports a signed app, creates a disk image, submits it for notarization, staples it and verifies it. Configure your own team, signing identity, export settings and notarization credentials before distribution. The checked-in team identifiers describe the original project and grant no signing authority.

Keep compiler outputs and test results under build/. Release artifacts belong in release downloads. Keep source and dependency notices together. Validate the exact source, version and final installer checksum. Exclude build/, .build/, vendor/, .bundle/, user workspace state and fastlane/report.xml from source exports; these can contain generated or private local data. Private workstation credentials and history are excluded from this snapshot.

Publishing, installation and host UI acceptance are separate operator actions. The prepared snapshot has no public publication approval. Fresh-install and manual-upgrade testing remain required for a distributable installer. Automated updates require a configured and verified signing key and feed.

## 1.9.1 build 25


The current private installer is `Releases/JoesProxy-1.9.1-build25.dmg`. Verify it against `Releases/SHA256SUMS` before transfer. The [candidate record](docs/releases/1.9.1-build25.md) identifies the accepted image and manual checks. Second-Mac acceptance and maintainer authorization for publication are pending.
