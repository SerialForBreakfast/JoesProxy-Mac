# Public-source and candidate readiness

Revision November 9, 2026. Destination: **JoesProxy-Mac**, published November 9, 2026 as the
public repository `SerialForBreakfast/JoesProxy-Mac` with release `1.9.0`. Private history remains
separate. See [snapshot provenance](../PUBLIC-SNAPSHOT.md) for the checked publication status.

## Current candidate

The starting point is the reviewed 1.9.0 (23) source export: 2,722 original files, verified
against its manifest before editing. Source archive SHA-256:
`cd08d18fe7b27e0495cdaaa4c68bf20a4d6a271f776702c8fefc824649cc46d5`.
Project links target `SerialForBreakfast/JoesProxy-Mac`. The repository and its release page
are live; the project website was not checked. Later source edits require their own validation.

The unchanged [build-23 installer](1.9.0-build23.md) is the `1.9.0` release asset; its hosted
digest matches the checksum in `Releases/`. The DMG is ignored by Git and contains original
embedded links. It does not match the published source byte for byte, and it predates commit
`6cec757`. Upload any replacement binary as a release asset, not a source commit.

No installer was rebuilt for publication. Remaining manual acceptance is not implied by
notarization. Hosted code analysis has not succeeded and the latest commit has no hosted run.

## Retained layout

Source targets, locked dependencies, synthetic fixtures and portable guidance remain included.
README introduces the product; bundled Help owns runtime guidance; RELEASE.md owns release
procedure. The private task board and raw audit evidence are intentionally excluded.

## Owner decisions recorded before public distribution

Publication has since occurred. Items below that were not completed remain open follow-ups.

- Original-material rights and retained identity decisions were recorded November 7. Changed
  material still needs review. Original signing identifiers grant no signing authority.
- Required fixture keys and privacy-test inputs are synthetic, not deployable credentials.
- Review/scan the exact edited source and record a final manifest. Bounded scans do not certify
  absence of secrets. Complete remaining manual acceptance and authorized hosted security checks.
- Configure and verify private vulnerability reporting at the destination. External code contributions remain closed.
- Classify/rotate historical private credentials if needed. Exclusion from a fresh snapshot does not revoke them.

## Preserved local material

Private histories, captures, profiles, audit logs and old installers are not part of this source
distribution. Source omission cannot revoke previously exposed credentials. See
[validation scope](../VALIDATION.md) and [snapshot provenance](../PUBLIC-SNAPSHOT.md).
