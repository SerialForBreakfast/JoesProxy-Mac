# Hangs, memory and streaming: evidence before conclusions

Revision: 2026-09-23. Derived from the Compact streaming-hang investigation, not a claim that its
root cause has been established. Current acceptance work belongs in `Tasks.md`, not this skill.

## Identify the incident and binary

Distinguish a hang report, exception crash, force-quit and client-observed stall. Record reported
symptoms separately from sampled facts. Process age is not workload duration; a sampled tail is
not the onset. Read bounded sections of large reports, not whole multi-megabyte clipboard plists.
Keep unrelated process/private data out of notes. Match executable/dSYM UUID before symbolication;
current checkout behavior must not be attributed to an older binary without evidence.

## Choose a discriminating measurement

- Idle event loops do not exonerate forwarding: requests may await routing, another actor or a
  dependency. Correlate independent client requests with acceptance/routing/upstream/head/completion
  times. Aggregate progress counters are not per-request correlation or proof of client playback.
- Body limits do not cap metadata or total process footprint. Check production configuration and
  persisted policy, payload sizes, session population and other owners. A footprint drop during
  allocator reclamation is a lead, not proof of a leak or its initiating operation.
- Inspect existing deferred release before proposing “move cleanup off-main.” Measure queue
  saturation/caller fallback and final owners; do not fix pressure with unlimited pending graphs.
- Compact does not imply idle shared work. Separate hidden view projections from capture,
  filtering, persistence and agent reads. Compare smaller and large-session workloads with a
  matched Inspector control; do not silently disable required behavior to improve measurements.
- An unanswered heartbeat is a responsiveness observation, not proof of deadlock. Scheduling
  gaps, disk failures, onset-only buffers and missing recovery timestamps limit its conclusions.
  Detector unit tests do not establish real timer/main-queue behavior during a UI stall.

Define workload, retained bytes, traffic rate, duration, build/machine, measurement overhead,
thresholds and stop conditions before an approved profiling run. Trace before the trigger through
recovery. Synthetic tests come first; use no private traffic fixtures. Never deliberately freeze
the user's app or run a host soak under ordinary code-edit permission.

## Close only the claim supported by the evidence

Compare memory at equivalent drained checkpoints, with reservation/backlog state and retained
session population recorded. A partial stationary run cannot substitute for idle/drain recovery.
An arbitrary duration is not a proof target by itself: define the question and stop criteria,
then respect the maintainer's accepted release deferrals rather than repeating longer runs.
No sampled pause or >=250 ms delay means none appeared in those samples, not that none occurred.
Keep safety-trigger exits, harness assertions and external interference separately attributed.

Prefer a failing deterministic regression and narrow fix. Validate focused, Policy and app build
serially, then repeat an authorized matched workload. If reproduction fails, report the tested
conditions and remaining uncertainty. “Not reproduced,” “mitigated” and “root cause fixed” are
different outcomes. A newly found bug is not necessarily the original incident's cause.

Keep transport availability, UI responsiveness and client rendering/playback separate in results.
Report measurement limitations and cleanup, and state the next evidence that would change the
conclusion. Do not delay safe source/test work merely because the final host run needs permission.
