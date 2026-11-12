# Public source snapshot

Revision 2026-11-09. Prepared from 1.9.0 (23) source, MCP capabilities revision 29.

## Publication status, checked November 11, 2026

This source is published at the public repository `SerialForBreakfast/JoesProxy-Mac`. Release
`1.9.0` carries the build-23 disk image as an asset; its hosted SHA-256 digest and size matched
`Releases/SHA256SUMS` when checked November 9. On `main` at `b6ab00f` the hosted build, secret
scan and Swift CodeQL job passed, with zero code-scanning alerts. The CodeQL job uses Xcode 26.6
and covers part of the Swift source; see [security checks](SECURITY-CHECKS.md) for its limits.
Private vulnerability reporting is not enabled.

## Preparation record

The entries below were written before publication. Where they say the repository was not
initialized or that publication is on hold, the status above supersedes them.

Source review November 9: updated stale release/readiness documents, corrected download OS/size
facts, contribution policy and local-versus-shared privacy claims. Added portable build-23 notes
and artifact metadata; About's privacy link now targets the included privacy guide instead of a
missing website anchor. Removed a private historical manifest path from old candidate notes.
The eight redacted scanner findings matched the reviewed source hashes exactly; zero unexpected
findings. Scanner 8.30.1 used default extended rules, ignored inline allow comments, archive depth
2, decode depth 5, 180-second limit and a 10 MB per-file limit. The DMG was skipped by that limit
and checked separately against its retained SHA-256. A final scan is owed after the last edits.
No private workstation-name/path matches were found by the narrow owner-specific text checks.
Synthetic home paths, LAN test vectors and nonsecret HLS test keys remain intentional fixtures.
This review does not inspect every image pixel, prove binary privacy or establish remote services.
No builds, previews, UI runs, Git writes or publication occurred.

Revision November 9, 2026: staged as `JoesProxy-Mac` for a fresh public repository. Repository,
issues, releases and project-site links target `SerialForBreakfast/JoesProxy-Mac`; account ownership
and destination availability have not been checked remotely. Product/bundle names remain JoesProxy.
The original build-23 archive is preserved; this edited directory is a derivative that still needs
validation and an updated publication scan. Earlier build/test evidence applies to the original
snapshot, not a new build of these link edits. No Git repository was initialized or published.

`Releases/` contains an unchanged build-23 DMG for later release-asset upload. The installer is
excluded from Git and still contains the original links. It does not match these edited source
files byte for byte. Select the original installer or a separately validated replacement explicitly
before release. Builds, previews, UI runs, Git writes and publication remain on hold.

JoesProxy began on November 5, 2024. Its prepared 1.9.0 public preview follows two years of development by Joseph McCraw. The start date is recorded in the original app-file headers and the earliest private development commit. This project history accompanies the fresh public source snapshot.

The public preview is intended for trying and inspecting the app. External code contributions and unsolicited pull requests are currently closed. This source includes first-time setup, the synthetic HTTP walkthrough, privacy/storage guidance, pinned hosted workflows and their helpers, followed by the live text-size correction for the main window and Compact HUD. Build 23 retains version 1.9.0 and includes that correction. CLI/analysis behavior and dependency versions remain unchanged. Earlier archives and build 22 are preserved as historical artifacts. See VALIDATION.md for the replacement candidate's actual verification and remaining manual acceptance.

This directory contains app, CLI, companions, tests, synthetic fixtures, locked dependency manifests, portable agent guidance and public documentation. Private history, local credentials, device profiles, raw captures, installers, legacy archives, generated renders, editorial drafts and old desktop screenshots are excluded.

The six gallery images are previously reviewed synthetic examples. Current icon resources include their pinned catalog and license. Required synthetic measurement JSON files remain under memlog/Research because tests read them. Private raw measurement receipts are excluded.

Intentional project attribution, license ownership and original signing-team identifiers are retained. Configure your own signing before running signed builds or distributing. Generic home-directory patterns in redaction code and synthetic paths in tests exercise privacy behavior.

No remote publication or Git initialization is part of snapshot preparation. Validation results will identify checks against this exact source. A source build does not establish fresh-install, upgrade, spoken accessibility or device acceptance.
