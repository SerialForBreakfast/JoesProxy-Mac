# Serial validation and permission boundaries

Revision: 2026-10-01. Run from the repository root; inspect current helper arguments before use.
The root rules remain authoritative. Do not install or resolve dependencies to repair validation.

## Before starting

- Check for an existing run and resume its process/log instead of launching another. Never overlap
  builds/tests on this worktree or host. An old lock filename alone does not prove an active owner.
- Identify source revision plus relevant dirty changes, product path, configuration, destination,
  DerivedData and existing package checkout. Do not test another installed app by accident.
- Keep explicit build/log/result paths under `build/`; select an existing compatible dependency
  checkout and retain locked-package flags. Do not silently download, update or repair dependencies.
- Read the current canonical simulator policy in AGENTS when a simulator is actually needed.
  Preserve devices and their data; do not clone, erase or switch runtime as incidental setup.

## Disk budget and shared-host coordination

The roughly 170 GB artifact accumulation on this host was a safety failure, not a desirable
evidence archive. Necessary user cleanup takes priority over retaining rebuildable products.

- Before expensive work, measure filesystem free space and the selected build/package/result
  directories. Include other known repository artifact roots, not only `build/`. Use bounded,
  targeted inventories rather than recursive scans of the entire home directory on every check.
- Reuse one compatible development DerivedData tree and one locked dependency checkout. Keep
  Release/profiling products separate only when the active acceptance requires them. Do not create
  fresh per-turn build trees, copy whole DerivedData directories, or retain duplicate package graphs.
- State expected incremental disk demand and headroom from comparable receipts; if unknown, say
  so and begin with the narrowest preparation. Honor helper disk floors and any user-agreed budget.
  Do not invent an approved numeric quota. A free-space check is not permission to fill the disk.
  Recheck at preparation/result-export boundaries and during long runs. Unexpected growth or
  threatened headroom stops new expensive work; inspect only the owned producer before cancellation.
- Retain compact summaries, identities, measured outcomes and selected useful attachments. Keep
  raw failure evidence until diagnosed and release artifacts while needed, but do not accumulate
  every full successful result/build indefinitely. At handoff list sizes, active owners, reusable
  artifacts and exact disposable candidates. Deletion requires the existing explicit authorization
  and target/link validation; never automatically delete a directory because it is named cache.
- After authorized deletion, mark historical raw receipts as removed while preserving summaries
  and their limitations. Do not blame the cleanup, silently reconstruct the old footprint, or claim
  deleted evidence is still inspectable. Dependency restoration remains a separate permission.
- Before launch, inspect bounded process identity/elapsed information and cooperating leases for
  other tasks' Xcode builds, Swift/package compilation and host tests. Avoid dumping full compiler
  argument lists. A missing xcodebuild alone does not mean the machine is idle. Recheck immediately
  before acquiring the existing serial lane; process inspection is not an atomic reservation.
- When busy, perform cheap documentation, syntax and source review work. Do not launch an isolated
  compiler probe as a workaround, repeatedly poll at short intervals, or disturb another owner's
  run. If deferred monitoring is requested, use the product's follow-up mechanism with quiet,
  bounded checks; it may resume only already-authorized work after all prerequisites are met.
  Build availability does not authorize dependency recovery or a new host-control scope.
- Report measured build-directory size and remaining disk space after substantial validation.
  Documentation-only skill edits need no app build and should not contend with active compilers.

## Choose the narrowest lane that answers the question

### Reconcile with the user's successful build first

Use ordinary Debug app builds and focused Debug Policy tests for the development feedback loop.
Keep optimized stability/release acceptance separate; a Debug pass is useful correctness evidence,
not a substitute for Release memory or timing acceptance. The September 22 user build log records
154.9 seconds with actual app/CLI compilation and `-Onone`; it was not merely a no-op build.

Before diagnosing a build-time regression, compare action, target closure, configuration, compiler
flags, architecture, toolchain, source identity, DerivedData/package paths and actual compilation
versus reuse. `Logs/Build/LogStoreManifest.plist` records build-section start/stop and errors; inspect
the matching `.xcactivitylog` for compiler invocations. These times exclude wrapper fingerprinting
and are not interchangeable with total command wall time. Read existing logs before running Xcode.

Local historical evidence: main-app Release compilation completed in 687 seconds; dual-app Release
profiling preparation in 1,474 seconds; a later 38-second preparation shows no SwiftCompile entry,
and a 40-second preparation compiles UI tests without recompiling the main app.
These are different sources/cache states, not speedup ratios or promises for today's build. The
roughly 49-minute cancelled run remains unexplained, not excused by those historical durations.
Detailed evidence is in `memlog/Research/Test-Suite-Performance-And-Coverage-Audit.md`.

Reuse a compatible existing repo-local Debug tree for agent writes. Inspect the user's external
DerivedData read-only; this comparison does not authorize writing there, transplanting products,
clearing caches or certifying binaries by mtime. No path is permanently canonical merely because
it appears in an example. Check package and product identity on every reuse.

For a future optimized preparation, first establish whether any completed current Release product
is certifiable. If not, name the required compilation and its measured historical cost before
agreeing the budget. Keep one unchanged configuration, main-app-only target closure and existing
dependencies. Do not repeatedly restart whole-module compilation at an arbitrary short limit and
expect partial optimization work to resume. Do not silently increase the existing cutoff either.

Compiler diagnostics are opt-in, not part of normal validation. The installed compiler crashes
on the tested combination of `-profile-stats-events` and `-profile-stats-entities`; do not restore
them. Summary-only `--compiler-stats` passed a tiny probe, not full-app acceptance. Smoke-test new
diagnostic options on a minimal existing source before adding them to a costly app preparation.
Do not alter shipping optimization or extract modules merely to make a profiling build finish.

### Goal determines preparation, not just the selected assertions

| Goal | First useful validation | Broader obligation |
|---|---|---|
| Prose/skill only | Links, frontmatter, mirrored rules, realistic workflow review | No app compile unless executable resources changed |
| Scripts/schemes/plans | Helper regressions, syntax, XML/JSON and dry-run target inspection | Real preparation remains explicitly unverified until executed |
| Pure caption/configuration contracts | Existing source-contract runner over production sources | Relevant app integration after convergence |
| Product logic/transport/MCP/CLI | Selected Debug Policy tests through focused helper | Full serial Policy and app build once after the tranche converges |
| UI correctness | Prepare relevant Debug UI products; approved selected host cases | Relevant size/state/accessibility matrix, not performance conclusions |
| Main-app stability/performance | JoesProxy-Stability Release prepare-only, then certified pilot/run | Optimized runtime identity, bounds, allocation/interaction evidence |
| Full-app versus Agent experiment | Existing JoesProxy-Profiling scheme including both apps | Matched builds/workloads; do not use this scheme for main-app-only stability |
| Release packaging | Established RELEASE.md workflow and locked runtime | Archive/sign/package checks; no installs or lockfile changes by inference |

After packaging, user testing is not permission to launch another test or replace their app.
For prose-only changes inside a Swift prompt string, check literal syntax and portable/native
parity without an app build; preserve the recorded packaged version and flag the correction as
next-build content. A behavior, schema or packaging-resource change needs its own relevant checks.
Do not assume checkout documentation is already present in the installed signed artifact.

The September 23 universal release lane took approximately 33 minutes, including its test build,
Policy execution, dual-architecture archive, export and notarization. Its archive alone took
approximately 20 minutes. This is a release receipt, not a development build budget or a reason
to increase the focused helper's 600-second preparation limit. Quiet whole-module optimization
may still be active: inspect exact compiler ownership/CPU and bounded logs before declaring a hang.

Before any expensive invocation, identify goal, target closure, configuration, existing products,
freshness evidence, expected preparation cost, timebox and stopping condition. `-only-testing`
does not remove unrelated scheme build entries. Debug Policy, Release profiling and release archives
are not interchangeable caches. Reuse the same compatible DerivedData instead of inventing a fresh
directory each turn; cancellation preserves useful intermediates but does not certify a binary.

The helper now timeboxes build-for-testing at **600 seconds**, separate from test execution.
At expiry it interrupts its own child, issues no new receipt and starts no tests. If graceful exit
does not complete within 30 seconds, inspect exact remaining descendants before proceeding; no
force-kill or unrelated-process cleanup is automatic. Do not extend `--build-timeout` or retry
silently. Report the hot target/pass, warm/cold status and options before agreeing a larger budget.
This is a preparation safety limit, not a promised compile duration or a timeout on a 60-minute run.

Main-app stability preparation (no UI launch; run only when preparation is authorized):

```bash
./memlog/utility_scripts/focused_test.sh --lane stability --prepare-only --dry-run --derived-data build/AGW4FullAppDerivedData --packages build/Release181DerivedData/SourcePackages -only-testing JoesProxyUITests/CaptureStabilityProfilingUITests
```

The example deliberately previews only. For an authorized preparation, omit `--dry-run`; for
verification of already certified products use `--reuse-build --prepare-only`. The stability receipt
is separate from Policy and binds source, scheme/plan, toolchain, packages and products. It covers
the complete stability class so pilot/full selection does not require recompilation. Inspect the
actual generated `JoesProxy-Stability` xctestrun path, not an invented SDK filename. Execute only
through `host_ui_test.sh --plan stability --xctestrun` with the explicit host-control acknowledgement
and approved test selection. That lane refuses implicit builds and rechecks the preparation receipt.
The existing profiling comparison lane remains available for the different two-app experiment.

Never run a partial Release app from a cancelled build or assume a recent mtime proves freshness.
Certified reuse avoids compilation, not necessarily all hashing/startup overhead. A successful
dry-run or helper unit test does not establish actual target closure, signing, runner or host health.

### Plan the feedback loop, retain the acceptance obligation

For each changed behavior, identify the earliest useful failure, the actual caller/integration
that must be exercised, and the broader checks owed before handoff. Keep these in the existing
task/evidence record rather than creating a second board. Cheap checks gate expensive dependent
work; a blocked gate does not prevent independent implementation or review.

- Check fixture/tool availability, arguments, selected test identity and packaged resources before
  long matrix runs. Prove discovery and one representative successful operation before variations.
- Cover negative paths, concurrency/cancellation, cleanup and authority boundaries where affected.
  Do not remove tests, loosen assertions, turn failures into skips or disable correctness diagnostics
  to make the loop faster. Skips and missing expected tests remain explicit acceptance gaps.
- During edits, run the selected contract/integration checks. After convergence, run required
  broader Policy/build checks serially; UI/player checks retain their separate scope permission.
  A passing contract is not evidence of UI behavior, playback or delivery to a device.
- Prefer deterministic signals and bounded waits tied to real state over fixed sleeps. Diagnose a
  timeout before increasing it. Extract hostless boundaries only against shared production code,
  with dependency mapping and retained real integration tests; no duplicated test-only substitute.
- Measure comparable end-to-end loops with the same scope/configuration and warm/cold conditions.
  Report preparation/fingerprinting, compilation, startup, assertions and finalization separately
  where measured. Include failures/retries; do not compare build-phase time with total reuse time
  as a speedup ratio. Test count alone does not measure coverage quality.

### Minimize interruptions, not accountability

Use brief progress updates while completing the authorized tranche, not questions after each
passing helper. At a genuine blocker, report the exact condition, evidence, affected acceptance,
safe work continuing, owner and resume condition. Examples:

- **Me:** Continue source review and fixture checks; runner initialization failed before cases.
  No physical action or new permission has been established.
- **You — physical action:** Unlock the desktop after an observed locked-desktop preflight.
  The scoped test work is already authorized.
- **You — specific exception:** Approve a named dependency installation only if necessary;
  existing test approval does not cover installation. Continue independent work meanwhile.

Commands intended for the user must be complete and unambiguous, including the working directory
and executable path when needed. Never tell the user to infer substitutions from an earlier command.

| Lane | Use | Permission |
|---|---|---|
| Policy | Unit/integration logic and synthetic transport | No desktop control; ordinary build permissions still apply |
| Smoke | Existing tiny end-to-end critical paths | Explicit local-user host-control permission |
| UI | Seeded behavior, windows, screenshots | Explicit local-user host-control permission |
| Full | Compatible unit/UI final acceptance | Explicit local-user host-control permission |
| Profiling | Synthetic timing/memory comparison | Explicit local-user host-control permission; not a correctness substitute |

Caption source contracts have an additional host-independent inner loop:

```bash
python3 -B memlog/utility_scripts/caption_contract_test.py
```

The working directory is this host's checkout; other machines use their actual repository path.
This maintained runner compiles seven real production files and shared XCTest cases directly with
installed Xcode tools, without app startup, a package graph, network fixtures or player execution.
Only test imports vary; production implementations and limits are not duplicated. It rebuilds each
time, records source hashes/timings, bounds compilation/execution, requires every intended case to
pass exactly once and preserves artifacts in `build/CaptionContracts/`. No `.xcresult` is produced;
the exact-case log, process exits and JSON receipt are its evidence. Use the Policy/app lane afterward
for actual target linkage, concurrency/build settings and integration. This lane cannot clear an
app-host runner failure latch or establish UI/player acceptance. It has its own cooperating lease
and active-xcodebuild preflight, not a universal lock against other build tools.

Focused helper requires explicit repo-local `--derived-data` and existing `--packages` paths plus
`-only-testing JoesProxyTests/TestClass[/testMethod]`. Unknown classes/methods, UI selectors and
escaping paths reject before compilation. `--dry-run` has no writes/launches and is not a runner
health check. `--prepare-only` compiles without executing. `--reuse-build` requires a receipt from
this helper for the same selections, content, toolchain/SDK, settings, dependencies and products.
It rejects stale/external build products rather than guessing freshness from timestamps. Source
trees are enumerated in `validation_preflight.py`; review that manifest when adding targets/root
build inputs. Internal symlinks are included, external/broken links fail closed. Hashing large
products has a cost; measure it before calling reuse a speedup.

The helper uses a cooperating serial lease and refuses a visible active xcodebuild. This is not
a system-wide reservation against noncooperating callers. Logs/results/timing receipts live in
`build/FocusedValidation/`. Runner infrastructure failures and unreadable results latch execution;
`--retry-after-change` records an observed recovery condition, not a new permission or automatic
repair. Existing failures from other wrappers still need human/agent inspection; they are not
automatically imported. The 120-second per-test limit does not bound XCTest initialization.

For new media behavior, fail in stages: tool/fixture availability → contract → one real caller →
one decoded cue → switching matrix → UI/player acceptance. Broader Policy and app packaging follow
convergence, not every test edit. Script-only work first runs its own regression tests and shell
syntax/dry-run checks; disclose unrun app/Policy checks rather than manufacturing a host pass.

Always distinguish already-authorized work, a requested rule exception, and a required physical
action. A timeout is not evidence of an OS dialog. Do not re-request unchanged authorization.

For direct Policy/build invocations retain:
`-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates`,
the selected repo-local `-derivedDataPath` and existing `-clonedSourcePackagesDirPath` when applicable.
Policy uses `-testPlan JoesProxy-Policy -parallel-testing-enabled NO`; build uses the app scheme.
For production code, run focused tests, then full Policy and app build at tranche convergence,
not after every helper checkpoint. For workflow-only edits run helper/syntax/config checks and
disclose the unrun real build/host acceptance. Do not turn a
prose-only skill update into a host run; validate references/frontmatter/mirrors and disclose that
no app validation was performed for the documentation change.

All host runs go through `memlog/utility_scripts/host_ui_test.sh --acknowledge-host-control`
with `--plan ui|smoke|full|profiling|stability` and the specific selection. The flag is not human consent.
Pass locked-package and artifact options explicitly: the wrapper currently does not supply them.
It enforces serial execution, disables coverage and checks result readability. Respect its shared
lease, known-locked-desktop and disk checks; do not bypass the wrapper for screenshots or profiling.
Profiling needs optimized Release and explicit sanitizer-disable options; inspect resulting products
and loaded runtime libraries before calling a measurement checker-free. Prepared `--xctestrun`
and `--lean-probe` are profiling/stability options, not general UI shortcuts. The stability lane
requires prepared products; the older profiling lane still permits combined build/run for its
existing callers and should not be used as a bypass for stability preparation limits.

## While running and after exit

- Give an estimate for work over five minutes and concise updates. Poll the existing session;
  inspect bounded failure lines rather than repeatedly streaming full build logs.
- Separate compilation, runner initialization, assertion execution, artifact export and finalization.
  Passing assertions followed by a hang or unreadable bundle are incomplete validation.
- Require normal process exit and inspect the summary with
  `xcrun xcresulttool get test-results summary --path <exact-result-bundle> --format json`.
  Report passed/skipped/failed accurately; skipped is not passed.
- Read results after their producer finishes finalization; concurrent result conversion can
  conflict with the runner/reporter. A finalization race is not a reason to rerun tests or delete
  result contents. Preserve the error, wait for completion, then retry the read-only summary.
- Classify a failure before changing anything. No test started means infrastructure failure,
  not evidence of a UI defect. Retry only after a named condition changes or a user explicitly
  requests a diagnostic retry; retain prior failures rather than hiding them.
- Never reset automation/security permissions, change signing, install tools, delete caches,
  terminate another owner's process or weaken assertions to get green. Ask for the specific
  missing authority while continuing unrelated safe work.
- Confirm only test-owned processes/listeners/effects are removed. Preserve user app state,
  captures and artifacts. Follow the root's exact-target and symlink rules for cleanup.

Store-level approvals and seeded button clicks test mechanics only. MCP/CLI must never resolve
live approvals, and enabling system routing remains a manual local-user action. Test permission
does not authorize either. Do not automate OS permission dialogs on the user's behalf.
