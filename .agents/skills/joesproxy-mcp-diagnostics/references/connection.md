## Cold-start bootstrap

From a **stopped app / cold client**, all of the following are required, in order, before anything
in "Connect quick-check" below even matters — confirmed live end-to-end
(`MCPAndCLIUserExperienceValidation.md`). Skipping straight to protocol mechanics on a cold start
wastes turns rediscovering this sequence one error at a time.

1. **App, MCP, and the proxy are three separate things that must each be started.**
   `joesproxyctl app launch` starts the app and requests MCP start, but capturing/mutating traffic
   still needs a separate, explicit `joesproxyctl proxy start` afterward — MCP being up does not
   imply the proxy is.
2. **Run `joesproxyctl doctor --json` after every step, not just once.** It gives a precise staged
   diagnosis (`mcp_unavailable` → `authentication_required` → `action_required` (profile/policy) →
   `action_required` (runtime grant) → `ready`), each with a concrete `recommendedNextCommands`
   entry — treat those (and `recommendedNextActions` on `setup_readiness`) as the **authoritative**
   next step. Do not improvise a different mutation because a prior session "usually" needed one.
   Doctor now reports the running app's build fingerprint, marketing/build versions, capability-
   manifest digest, skill version, and an explicit compatibility result. Treat an incompatible
   result as a hard restaging signal: use the bounded recommended actions instead of inferring that
   a stored credential or a recently modified file belongs to the running app.
3. **A previously-stored CLI credential can be silently rejected** (`authentication_required`,
   "The CLI credential was rejected") with no diagnostic as to why. The CLI cannot self-serve a
   fresh one — by design, a credential must never appear in a command argument or chat transcript.
   A human must mint a new one-time credential in the app's MCP Management UI; then run
   `joesproxyctl auth login` again.
4. **The client's disclosure profile must be Shareable (not the default Metadata Only), with no
   Always-Deny runtime-control rule, before runtime-control tools even exist as callable tools at
   all** — this is a hard gate, not merely an approval step. On Metadata Only, calling
   `proxy_start`/`mcp_stop`/etc. returns `"Unknown or unavailable tool: proxy_start"`
   (`internalFailure`), never an approval prompt. If you see that exact error shape, the fix is
   changing the profile in MCP Management — retrying or waiting for approval will not help.
5. **Runtime control, header read, and body read are three independently-gated capabilities**, each
   needing its own first-time approval even though they can feel like "the same" request to a human
   approver. Approving one does **not** cover the next, and identical pending calls are deduplicated; changing the request can create a different
   `requestID`. Inspect pending approvals before retrying.
6. **Use `joesproxyctl approvals list` to see everything currently pending for this client** — every
   entry's `capability`/`reason`/`expiresAt`, not just the single `requestID` the specific call that
   triggered it returned. Run this whenever you're unsure what's actually blocking you, or before
   asking an operator to approve something, so you can tell them exactly what and why.
7. **MCP and CLI can never activate Mac-wide system-proxy routing.** If the local user has armed
   "Automatically set macOS system proxy while capturing," `proxy_start` is rejected with
   `policy_denied` before approval or runtime execution. `runtime_status`/`doctor` surface an
   `action_required` check. The user must either start the proxy manually in JoesProxy (accepting
   Mac routing) or manually turn Mac routing off before remote runtime control can start it.
8. **Use `setup_readiness` for target-specific onboarding evidence, not ad hoc guessing.** Call it
   with exactly one explicit `target`: `macOS`, `iOS/iPadOS`, `tvOS`, `Simulator`, or `generic`
   (required — there is no "check everything" mode). The result is a bounded `checks` array, each
   with a `state` (`confirmed` / `observed` / `needs_user_confirmation` / `not_observable`) and an
   `actor` (`app` / `agent` / `user`) naming who is responsible for that fact, plus top-level
   `recommendedNextActions`. Treat `not_observable` as final, not as something to retry or work
   around — JoesProxy genuinely cannot see remote profile installation, remote certificate trust, or
   a device's Wi-Fi proxy settings; a generated/downloaded profile is evidence of generation, not of
   installation. Complete only the specific `nextHumanAction` a check names, not the whole cold-start
   sequence again.

## Launch in Compact Mode for agent-driven sessions

Compact Mode is useful when the user wants lightweight monitoring while an agent investigates.
It avoids mounting the full session browser and inspector. Do not switch modes or restart an
existing app without the user's intent: the full workspace remains useful for human review.
This is a UI-workload reduction, not a guarantee that all capture or analysis costs disappear.

**Cold-launch an agent session directly into Compact Mode:**

```
joesproxyctl app launch -- --compact-mode
```

(Or `joesproxyctl mcp start -- --compact-mode` to launch and
wait for MCP to come up in one call.) Everything after a bare `--` is forwarded verbatim as the
launched app's own `CommandLine.arguments` — confirmed live 2026-08-25 by inspecting the launched
process's actual argv, not just the CLI's echoed response.

- `--compact-mode` starts the main window as the lightweight HUD (proxy/MCP status tiles, start/
  stop toggles, an Approvals button) instead of the full session UI — **without** overwriting the
  human's own persisted window preference, so their next normal launch is unaffected.
- Keep normal launch recovery visible. Test-only recovery-suppression flags are not part of an
  ordinary user workflow; let the user choose whether to restore retained captures.
- These only take effect on a genuine **cold** launch — macOS has no mechanism to inject new argv
  into an already-running process. If JoesProxy is already running (started earlier, by a human, in
  full mode), the flags are silently ignored; compact mode would need to be toggled from the running
  UI instead. `joesproxyctl status`/`doctor` tells you whether it's already running before you
  bother passing them.
- If you're driving JoesProxy from outside `joesproxyctl` entirely (e.g. scripting `open` directly),
  the equivalent is `open -a "JoesProxy" --args --compact-mode` —
  but prefer the `joesproxyctl` form above when available, since it's the same tool you'll use for
  every subsequent step.
- Proxy serving, session capture, and every MCP tool continue to work identically in compact mode —
  this only removes the human-facing session-inspection surface, not the underlying automation
  surface this skill drives.
- Pending MCP approvals remain reachable: the compact HUD has its own **Approvals** button, so a
  human co-driving the session doesn't need to leave compact mode to resolve one.

