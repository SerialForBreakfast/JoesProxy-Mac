fastlane documentation
----

# Runtime

Use the existing Fastlane runtime documented in `RELEASE.md`. Do not install or update Ruby, Bundler, Fastlane, gems, or Xcode components as part of running a lane without explicit approval.

Revision 2026-09-18: commands below use the installed, lockfile-compatible runtime approved on
2026-09-13. Run from the repository root. Packaging requires separate release authorization.
First verify the runtime:

```sh
env PATH="/opt/homebrew/bin:$PATH" BUNDLE_FROZEN=true FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 FASTLANE_OPT_OUT_USAGE=1 /opt/homebrew/bin/bundle exec fastlane --version
```

Authorized packaging:

```sh
env PATH="/opt/homebrew/bin:$PATH" BUNDLE_FROZEN=true FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 FASTLANE_OPT_OUT_USAGE=1 /opt/homebrew/bin/bundle exec fastlane mac release
```

The lane uses serial Policy tests and repository-local artifacts, refuses existing release
outputs, and performs no git writes. Packaging only succeeds after notarization and verification.

# Available Actions

## Mac

### mac test

```sh
env PATH="/opt/homebrew/bin:$PATH" BUNDLE_FROZEN=true FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 FASTLANE_OPT_OUT_USAGE=1 /opt/homebrew/bin/bundle exec fastlane mac test
```

Run serial Policy unit/integration tests. No UI target. Do not overlap another build/test.

### mac build

Legacy Debug build lane. It does not implement the current locked-package and repository-local
artifact discipline; use the development skill's build workflow instead. Do not infer that its
description alone disables signing. This documentation update does not alter the lane.

### mac release

```sh
env PATH="/opt/homebrew/bin:$PATH" BUNDLE_FROZEN=true FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 FASTLANE_OPT_OUT_USAGE=1 /opt/homebrew/bin/bundle exec fastlane mac release
```

Build, sign, notarize, staple, and verify a repo-local Developer ID DMG. No version bump,
commit, tag, upload or installation is performed. DMGs are release assets, not source-history files.

### mac verify_release

Historical 1.8.0 example; choose the exact candidate filename for another release:

```sh
env PATH="/opt/homebrew/bin:$PATH" BUNDLE_FROZEN=true FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 FASTLANE_OPT_OUT_USAGE=1 /opt/homebrew/bin/bundle exec fastlane mac verify_release dmg_path:memlog/releases/JoesProxy-1.8.0.dmg
```

Rechecks stapling and Gatekeeper without rebuilding. Record the final checksum separately.

### mac screenshots

Legacy screenshot lane: do not invoke directly. Use the approved serial host wrapper after
explicit local-user permission, with selected screenshot tests. See the development skill's
`references/ui-and-artifacts.md` for export and inspection instructions.

### mac ui_performance

Legacy performance entry point: use the approved profiling/host workflow instead. Measurement
requires explicit scope approval and verified optimized, non-sanitized products.

----

This README.md is maintained manually; automatic generation is disabled in the Fastfile.

Use [UpgradeAndRelease.md](../docs/development/Release-Operations.md) for orchestration and the
release checklist (private development reference omitted) for candidate evidence.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
