# JoesProxy contributor and agent guidance

Revision: 2026-10-29 — portable source snapshot. CursorRules.md mirrors this file.

## Authority and preservation

- Read .agents/skills/joesproxy-development/SKILL.md before changing this project.
- Preserve unrelated edits. Complete the authorized task and independent work; one isolated failure does not cancel unrelated work.
- No dependency installs, updates, lockfile changes or repair without specific approval.
- Obtain explicit maintainer approval before Git writes. Approval applies only to the named operations and repository. Publication requires separate approval.
- Ask the maintainer before opening any public issue. Keep benchmark results in versioned reports linked from the release notes.

- Keep authored artifacts in the checkout. Compiler-managed caches may be used only within the owner's existing permissions.
- Do not run arbitrary inline scripts or temporary programs through the shell. Use reviewed project helpers and dedicated tooling.
- Scope authorization, exceptions to a rule and physical user interaction are distinct. Preserve approval for unchanged scope.
- Host UI automation requires explicit local-user approval and the serial host wrapper; never infer permission from a build request. Do not operate the Xcode GUI.
- No live rule approval on the user's behalf. Remote agents may propose and inspect; the local human resolves approvals.
- Keep customer identities, captured credentials, private endpoints and device identifiers out of examples and public evidence. Use reserved domains and synthetic fixtures.

## Efficient validation

Use one serial build/test lane and reuse compatible products. Check resources and other owners before starting a build. Never kill another owner's process. Keep locked-package/no-update flags. Select focused checks first; use JoesProxy-Policy for unattended unit/integration coverage. Smoke/UI/profiling use memlog/utility_scripts/host_ui_test.sh only with scoped permission. Read the helper's arguments and prerequisites before running.

Documentation-only changes get link/content checks. Production changes need focused behavior coverage, then Policy and app build at convergence. Do not retry an unchanged infrastructure failure. Keep evidence small; do not duplicate full build trees or delete caches as incidental repair. State unrun checks honestly.

## Architecture

AppCoordinator is the composition root. AppPresentationState owns app-level presentation. Use constructor injection and existing service boundaries. Swift files in synchronized target folders are auto-included; do not add duplicate project entries. Static app keys belong in JoesProxy/Info.plist. Config/Version.xcconfig owns version values; marketing versions remain maintainer-controlled.

Preserve capture fidelity and forwarding behavior. Keep expensive work off UI/network execution paths, bound queues/caches, and test cancellation and stale-completion races. Respect text scaling, keyboard access and VoiceOver. Use the existing design system.

## Source distribution

This snapshot intentionally omits private history and evidence. See docs/PUBLIC-SNAPSHOT.md. Required Fixtures, locked dependencies, test plans and validation helpers remain included. Do not reconstruct private captures or fetch historical traffic. Release publication and signing changes require separate authority.
