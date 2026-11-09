---
name: joesproxy-development
description: Implement, debug, test, and hand off changes to the JoesProxy repository using its established serial validation, macOS UI automation, screenshot, and evidence workflows. Use for development of JoesProxy itself, not merely operating its MCP/CLI against another app.
metadata:
  version: 0.1.5
---

# JoesProxy development loop

Revision: 2026-10-01 — bounded build storage and consideration for parallel tasks.
This is repo-local guidance, not an
exported MCP operating skill. Paths in commands are relative to the repository root.

## Establish the next meaningful slice

1. Read the root [AGENTS.md](../../../AGENTS.md); it owns permissions and repository rules.
   Inspect read-only git status/diff and relevant current source before resuming. Preserve existing
   edits, including unfinished work. A previous task summary is context, not proof of current state.
2. For “continue,” read the [public snapshot status](../../../docs/PUBLIC-SNAPSHOT.md) and the maintainer's assigned task and its actual remaining
   acceptance work. Separate implemented code, passing tests, unrun UI checks and unresolved
   diagnosis. Do not reimplement a safeguard because its broader acceptance task remains unchecked.
3. Name an outcome and select a substantial, bounded chunk. Continue through implementation,
   focused checks and relevant broader validation while safe work remains; do not ask for approval
   after each tiny edit. Stop at a real product choice, permission boundary or missing evidence.
4. Inspect the existing owner and tests before adding a new abstraction. `AppCoordinator` owns
   composition; app presentation belongs in existing presentation/window routes. Swift files in
   synchronized target folders need no manual project-file entries.

## Choose the workflow

- Builds/tests, including resuming an interrupted run: read [validation.md](references/validation.md).
- UI fixes, screenshots or export failures: also read [ui-and-artifacts.md](references/ui-and-artifacts.md).
- Hangs, memory, streaming or performance claims: also read [investigation.md](references/investigation.md).
- Release work: read the repository's [RELEASE.md](../../../RELEASE.md) before acting. This skill
  grants no release, dependency, signing or git-write authority.
- Documentation/skill reconciliation: preserve the currently tested package. Correct mirrored
  portable/native prose together; distinguish checkout corrections from already exported guidance.
  Use text parity, links and frontmatter checks before considering a build. Record bundled-text
  changes as next-build changes, never edits to a signed app or installer.
- Operating traffic experiments against a target app: use the separate `joesproxy-mcp-diagnostics`
  skill. Console/wire correlation belongs to `xcode-proxy-analysis`. Do not mix app development
  commands into the portable diagnostic skill or assume MCP authentication grants host control.

## Faster feedback without weaker coverage

- Treat disk consumption as an operational safety constraint. The prior roughly 170 GB repository
  artifact accumulation required emergency cleanup; do not rebuild that footprint or frame the
  user's necessary cleanup as a mistake. Before expensive work, follow the storage and shared-host
  preflight in [validation.md](references/validation.md). Reuse compatible caches, retain concise
  evidence, and request exact-target cleanup before disposable artifacts accumulate.
- Other tasks share this Mac. Parallel source work is useful; competing builds, compiler probes
  and host tests are not. Defer heavy work while another owner is using the build lane; never kill
  their processes, invalidate their products or clear their caches. Continue cheap independent work.

- When agent preparation is slower than the user's build, compare existing successful build logs
  before changing settings, adding diagnostic flags or asking for more time. Distinguish Debug
  development, Release compilation and no-compile reuse; see the matched-baseline procedure in
  [validation.md](references/validation.md). A timeout ceiling is not a normal-duration estimate.
- Choose the goal-specific lane in [validation.md](references/validation.md) before invoking Xcode.
  Test selection is not build-target selection. Inspect explicit scheme entries and dependencies;
  never compile the Agent prototype for main-app stability merely because a broad scheme includes it.
- Separate preparation from execution. Reuse the inspected DerivedData/package paths and certified
  products; partial/cancelled products are not a runnable candidate. Use the ten-minute default
  preparation timebox; do not silently extend it or restart after cancellation. A long capture's
  approved duration is not an unlimited build budget.
- Documentation and helper changes get reference/syntax/helper checks, not reflexive app builds.
  Product changes still receive focused integration and the broader acceptance checks owed at
  convergence. Do not rerun unchanged broad suites at every internal checkpoint.
- Before editing, map the changed behavior to a cheap falsification check, a real integration
  check, and the broader acceptance checks still owed. Execute prerequisite checks before costly
  matrices; narrowing the inner loop changes order, not the final coverage obligation.
- Reuse only certified matching builds. Separate preparation, runner startup, assertions and
  result finalization when diagnosing cost; fewer selected tests do not imply a hostless runner.
- Follow [validation.md](references/validation.md) for failure classification and recovery.
  Do not retry unchanged infrastructure failures, weaken assertions or expand timeouts blindly.
- Complete dependency-ready work within the approved tranche while a lane is blocked. Progress
  updates are not approval checkpoints. Identify who acts next and distinguish scoped permission,
  a specific rule exception and an observed physical action; retain unchanged approval.
- Respect a recorded release cutoff. Accepted coverage deferrals do not become new mandatory
  loops on “continue.” Reopen the decision for a demonstrated critical defect, not an unchanged
  checklist. Packaging, public download, installation and user acceptance are separate states.

## Implement the state transition, not just the happy-path click

- For repeated Start/Apply actions, use one operation owner and an explicit in-progress state.
  Test duplicate invocation and error/retry behavior; a debounce alone does not establish idempotency.
- Preserve operation progress/errors across Compact/Inspector transitions. Auxiliary windows
  should use their existing independent routes, not force a working-view switch.
- Distinguish shared capture state from hidden presentation work. Suspending Explorer/Timeline
  rendering must not freeze agent reads or recording. Invalidate stale workers and verify rebuild
  on return; inspect all consumers before changing observation or actor isolation.
- Test cancellation, late completion, replacement and concurrent capture before publishing results.
  Move expensive work with bounded ownership, not an unbounded queue. A background reference does
  not guarantee final destruction happens off the main thread.
- Preserve configuration defaults and old installations deliberately. Check actual production
  construction and persisted settings; a standalone test default or stale comment is not authority.
- For API/CLI/tool changes, inspect actual schemas, dispatch, exported guidance and tests together.
  Preserve bounded errors and recovery steps; do not automatically retry a mutation with unknown outcome.

## Finish with evidence and a useful next step

Report the changed behavior, actual test counts/skips, process exit, readable result, remaining
limitations and cleanup. Never equate compiled, assertions passed, screenshot inspected and full
acceptance. Do not claim a historical crash/hang fixed solely because policy tests pass.

When task records need updating, use the assigned scope and snapshot/validation documents present
in this distribution; do not reconstruct excluded private boards. Use a concrete deliverable, observable acceptance, dependency
and exact permission/blocker—not “promotion gated” or “needs grooming” without explanation.
Research-only requests do not authorize new execution-board items. Update existing records rather
than creating a competing board or unsolicited report. Preserve failed evidence with its status.

End with the next substantial unblocked chunk, or the precise input needed. A blocked host lane
does not block source inspection, policy tests or test-fixture preparation. Updating the rules
requires matching edits to `AGENTS.md` and `CursorRules.md`; validate they remain identical.
