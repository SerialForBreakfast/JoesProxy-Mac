# Release workflow

As of November 16, 2026 the public release is 1.9.0 (23). Version 1.9.1 (28) is prepared in source. Building, notarizing and independently testing that installer precede publication. The [changelog](CHANGELOG.md) describes the candidate.

Private 1.9.1 (27) used application source `9bfbf70`, the locked workspace packages and a build-number override of 27. Apple accepted submission `972cd70e-279d-4e04-a8ae-744eccae451a`. The stapled image and mounted app passed Gatekeeper. On a second Mac, upgrading from build 25 preserved the recording, root fingerprint and CLI enrollment. About, Verify Capture with the existing CA, and authenticated CLI status passed. The operator did not record separate HTTP and HTTPS row outcomes.

For build 28, verify a fresh install and an upgrade from public build 23. Check HTTP-only onboarding, certificate retirement and replacement on a disposable account, MCP service and enrollment indicators, Keychain denial and unlock, pending approvals and last-client revocation. Exercise keyboard navigation, VoiceOver, and toolbar reflow. Run the [offline waterfall fixture](docs/releases/fixtures/1.9.1/WATERFALL-BUILD26.md) from both entry points. The build 25 menu crash during a suspected session restore remains unreproduced.

Build 26 used application source `ddcfd46` plus local packaging inputs subsequently recorded in `b87f6f6`. The [build 26 record](docs/releases/1.9.1-build26.md) describes that private handoff. [SHA256SUMS](Releases/SHA256SUMS) lists checksums for the distributed images.

Config/Version.xcconfig defines the marketing version and monotonically increasing build number. The version helper updates configuration, changelog and checked-in diagnostic skill metadata together. Review its changes before validation.

For the next replacement private candidate retaining version 1.9.1, use `bash bump_version.sh 1.9.1 --build-only --dry-run`, then omit --dry-run after review. This advances only CURRENT_PROJECT_VERSION and preserves the marketing version, changelog headings and skill metadata. Do not reuse a distributed build number.

The optional `zsh memlog/utility_scripts/private_candidate_release.sh . build/ReleaseCandidate` controller holds the shared serial leases and delegates to the same release lane. It requires an already working locked release runtime and does not install or update tools. Its --dry-run option checks the selected source/output routes without running the lane. Preserve previous candidates by choosing an unused output directory.

Use the pinned tool and dependency versions already configured by the maintainer. Read Gemfile.lock before selecting the release runtime. Dependency installation or updates require separate authorization.

The existing `fastlane mac release` lane runs serial Policy tests, creates a universal Release archive, exports a signed app, creates a disk image, submits it for notarization, staples it and verifies it. Configure your own team, signing identity, export settings and notarization credentials before distribution. The checked-in team identifiers describe the original project and grant no signing authority.

Keep compiler outputs and test results under build/. Release artifacts belong in release downloads. Keep source and dependency notices together. Validate the exact source, version and final installer checksum. Exclude build/, .build/, vendor/, .bundle/, user workspace state and fastlane/report.xml from source exports; these can contain generated or private local data. Private workstation credentials and history are excluded from this snapshot.

Publishing, installation and host UI acceptance are separate operator actions. The prepared snapshot has no public publication approval. Fresh-install and manual-upgrade testing remain required for a distributable installer. Automated updates require a configured and verified signing key and feed.

Build 26 includes the portable `joesproxy-mcp-diagnostics` folder beside the app. Install the entire folder in the agent's skills directory so its references resolve. The release Policy tests compare the staged source files with the app's skill export.

The DMG includes [Uninstall JoesProxy.txt](docs/Uninstall%20JoesProxy.txt). Verify the guide is readable on the mounted image. Use a disposable test identity for uninstall acceptance and preserve the upgrade account’s CA, enrollment and saved recordings.

## 1.9.1 build 25


The previous private installer was `Releases/JoesProxy-1.9.1-build25.dmg`. Its [candidate record](docs/releases/1.9.1-build25.md) identifies the image and manual checks.
