# Source validation

Revision 2026-11-09. This source targets candidate 1.9.0 (23), with unchanged pinned dependencies and MCP capabilities revision 29. It was published on November 9, 2026; the local results below predate publication and commit `6cec757`, which has no recorded build or test run here.

The text-size correction scales Compact HUD fonts and dimensions, main-window health statistics and inherited controls. The header adapts its layout to larger reading text. Build 23 retains marketing version 1.9.0 and advances only the monotonic build number through the build-only version helper.

| Check | Result and scope |
|---|---|
| Build-23 release Policy gate | 3,038 passed, 15 skipped, zero failures; 13 generic main-thread warnings |
| Build-23 universal signed/notarized installer | Developer ID export, notarization acceptance, stapling, image integrity and Gatekeeper checks passed; app and CLI contain arm64 and x86_64 |
| Packaged app/CLI metadata and Help | Reports 1.9.0 (23); both Compare once Help sections read offline with complete coverage; catalog and license bytes match source |
| Text-size focused checks | 17 passed, zero failures/skips, before the metadata-only build-number bump |
| Live text-size UI cases | 2 passed, zero failures/skips; two main-thread warnings; same font code before the build-number bump |
| Earlier matching text-size Debug build | Passed with signing and sanitizers disabled; development acceptance |
| Earlier fresh-cache setup and app build | Six pinned packages downloaded, unsigned app/CLI checks passed, lockfiles unchanged |
| Earlier companion SDK macOS tests | 90 passed in 15 suites; SDK code unchanged |
| Existing validation-helper baseline | 27 passed |
| Workflow/security-helper regressions | 12 passed, 22 assertions |
| Build-only version and release-controller checks | 6 passed, 21 assertions; shell syntax passed |
| Earlier synthetic HTTP UI walkthrough | 1 passed, zero failures/skips; one runtime warning |
| Source secret scan | Eight synthetic/type-annotation exceptions are narrowly reviewed by whole-file hash; the final export scan and its content-free results accompany the source packet |
| Hosted build and secret scan | Passed on `main` at `b6ab00f` (November 10, 2026); later branch commits are not covered by the secret scan |
| Hosted Swift code analysis | Passed on `main` at `b6ab00f` using Xcode 26.6 on macos-26: zero alerts, 1,020 of 2,593 Swift files scanned, 90 SDK tests passed. Unit and UI test targets are not built by this job. It analyzes an Xcode 26.6 build, not the Xcode 27.0 build |
| Repository security settings | Private vulnerability reporting is not enabled; other settings were not checked |

The verified private image is JoesProxy-1.9.0.dmg, SHA-256 916a3eac4e14fb5adf9fa6b7d079dd6947a49c482e4b90fd4a2a7f67616865df after stapling. All 2,499 recorded release inputs remained byte-identical across packaging. The mounted app passed deep, strict signature verification and Gatekeeper assessment, and the image was ejected. It was not installed or published by this run.

The font UI cases change Settings while Inspector and Compact are already open, verify text growth and reduction, and check enlarged HUD/window containment and all eight tile labels. The native regression measures rendered health glyph dimensions. The persistent-settings test waits for actual asynchronous propagation. These checks do not establish spoken VoiceOver or physical older-OS behavior. The release gate's 13 runtime warnings have the same message as the previous private candidate; this tranche does not diagnose them.

The earlier fresh-cache setup ran on the existing provisioned Mac, not a fresh OS. The HTTP walkthrough used real synthetic loopback traffic, exact JSON-body accessibility inspection and Stop, with isolated storage and suppressed launch recovery. Its final receipt is synthetic text. An earlier wrong-desktop screenshot was rejected and retained privately; no screenshot acceptance is claimed.

Source export excludes private history, device profiles, raw evidence, old screenshots, installers, legacy archives, generated build/ and .build/ output, dependency trees, workspace user state, credentials and user settings. Gallery images are previously reviewed synthetic examples. Attribution, project URLs, original signing identifiers and upstream notices remain intentionally retained. SCANNER-FINDINGS.md describes the narrow reviewed finding categories.

Fresh installation, manual replacement/upgrade, saved recording and inactive-bundle reopening, and human Compare once allow/deny/revocation acceptance remain pending for build 23. The owner previously confirmed preference persistence from 1.8.3 to build 22; that did not prove live resizing. The new candidate requires its own manual check. Spoken VoiceOver and physical older-supported-OS/model-unavailable checks retain their existing deferrals.

The earlier source audit restored the required owned seal input and uses neutral workstation fixtures. The public source has no private Git history. Captured-service credentials were not authenticated or rotated by the privacy scan. Signing/notarization use private operator credentials that are not part of the source packet. Hosted workflow results are listed in the table above. No independent security audit or automatic-update acceptance is claimed.
