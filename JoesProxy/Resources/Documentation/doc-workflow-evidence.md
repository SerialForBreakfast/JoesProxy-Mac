# Evidence and recovery

## Evidence boundaries {#safety}

Documentation and structural validity are not proof of runtime readiness or business validity. Access, proposal, approval, application, delivery and target outcome are separate facts. Do not repeat mutation requests blindly after a transport interruption: inspect whether they were applied first.

## Missing bodies {#bodies}

Revision 2026-10-17: Inspect `bodyUnavailableReason` and `bodyRecoveryAction` before analysis; these metadata fields do not require body-read approval. An original byte count does not prove bytes remain retained. Deferred means loading is pending; omitted means recording policy excluded bytes; TLS pass-through cannot supply decrypted bodies; pending means the response has not completed. Missing bytes are not proof that capture is globally disabled. Truncated data cannot establish complete original bytes.

Use MCP `capture_status` or CLI `joesproxyctl capture status --json` to inspect live limits, admission pressure and next actions. For a stopped proxy, MCP `capture_resume` or CLI `joesproxyctl capture resume --wait-for-approval --json` requests runtime control through existing local approval or standing grants. Read the returned capture status before claiming readiness. Resume only starts future bounded capture: it does not recover historical bytes, force admission, raise budgets, alter TLS/routing or grant body-read access. Pressure resumes automatically after accepted work drains; zero retention requires local settings review. Never restart a running proxy merely to clear pressure.

Capture is playback-first: if a response-body reservation cannot fit, JoesProxy keeps request details, response headers, status, timing and observed response size when a smaller reservation fits. It omits the response body, marking the session `capture_pressure`. If even metadata cannot fit, the request is not recorded. Neither path waits for capture capacity before forwarding. `metadataOnlyCaptures` counts response-body omissions separately from `rejectedCaptures` (requests not recorded). These totals describe evidence loss, not proof of a device playback failure or successful playback. The existing byte/count limits and automatic recovery remain in force. Unlimited means retained history, not unlimited in-flight memory. The compact Capture Details control separates current pressure from historical omissions; reinstalling a device profile cannot restore missing bytes.

Select a complete capture or recording through supported access. Body-read permission is separate from capture state. A new upstream request cannot reconstruct historical evidence and needs separate authorization; never silently refetch or replay.

Missing bodies alone never justify reinstalling a device proxy or certificate profile. TLS pass-through can reflect an intentional bypass rule rather than broken trust. Preserve working device configuration: inspect target-specific `setup_readiness` and actual TLS evidence before recommending repair. An unobservable trust state is not a failed trust check.

## Target rejection {#target}

A successful downstream write proves transport completion only. Confirm parsing, rendering or playback through a human observation or separately authorized external evidence, recording its source. Preserve the actual served revision and hash. Do not attribute a failure to cache, schema or networking without supporting evidence.

## Partial cleanup {#cleanup}

Stop effects through their owning lifecycle and inspect cleanup status. Retry only the failed supported cleanup operation after understanding its reason. Keep the investigation open when cleanup is incomplete. Closing a diagnostic run does not automatically stop a separately owned bundle; do not delete another client's effects.
