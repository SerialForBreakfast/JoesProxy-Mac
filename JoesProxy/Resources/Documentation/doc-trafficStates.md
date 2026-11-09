# Traffic States

## Overview {#overview}

Each session is either plain HTTP, HTTPS inspected, or HTTPS tunneled. That state determines what metadata and body contents are available.

## Context and limitations {#context}

- Some hosts stay tunneled because of compatibility rules, certificate pinning, or missing trust.
- Inspection Reason explains why a session was inspected or tunneled.

## Next steps {#steps}

- Review HTTPS Rules if a host should stay tunneled or should be intercepted explicitly.
- Agents can inspect a domain with `https_rules_get` or `joesproxyctl https rules get --host media.example.test`.
  Changing it with `https_rules_set` / `joesproxyctl https rules set` requires the returned revision,
  mode `tunnel`, `inspect` or `remove`, explicit `host_and_subdomains_all_clients` scope and exact
  one-use local approval. This persistent preference affects new connections for all clients;
  bundle Stop/expiry does not undo it. Existing connections are not interrupted. A TCP tunnel
  hides HTTPS bodies and HTTP modifications; it does not forward native QUIC.
- For playback stalls, `session_summary` / `joesproxyctl session show <sessionID>` can report
  `transportEvidence`: observed TLS readiness, upstream read gaps, queued writes and downstream
  completion/failure. Recent pending evidence is capped at 256 requests. Unavailable/evicted
  evidence is unknown. Read gaps include local backpressure; completed socket writes do not
  establish player delivery. Compare controlled workloads before assigning a transport cause.
  `transportDiagnostic` supplies a stable reason, impact and read-only recovery checks. An
  incomplete response can have successful prefix writes; that is still a transport failure.
  Pending writes are not proof of a deadlock. Check capture status separately: restoring future
  capture cannot recover omitted history. HTTPS exceptions require existing local approval,
  affect new connections and must not be applied automatically. Inspect current state after an
  uncertain mutation reply before retrying. Proxy delivery never establishes target playback.
- If you expected readable bodies, first check Inspection Reason, body availability/recovery
  fields and capture status. Check target-specific trust readiness only when the evidence
  indicates a setup problem. Do not reinstall a working device profile because a body is missing.

### Investigating playback without confusing evidence and behavior

Start with the running build's capability catalog, capture status and affected session summary.
`body_capture_disabled_for_request` describes evidence loss; it is not proof that forwarding
stopped. `transport_evidence_unavailable` means unknown. `upstream_response_incomplete` and
`downstream_write_failed` describe transport failures. `downstream_delivery_pending` must not
be reported as successful delivery. A read gap alone cannot identify the responsible endpoint.

Use an explicit bounded observation window and record visible player behavior separately.
If a host-rule comparison is appropriate, review its all-client/subdomain scope, retain a
recovery ID, obtain local approval, and observe new connections. Restore needs separate approval
and receipt verification. Do not force reconnection, clear client caches or replay requests
without authorization. HTTP/3 is not implemented; TCP tunneling does not provide native QUIC.
Synthetic framing, reuse and queue-drain tests are useful regression evidence, not proof of
remote throughput or successful playback on a device.


### Reversible HTTPS recovery

Choose a recovery UUID before `https_rules_set` and include `recoveryID` (CLI `--recovery-id`). The approved change records its prior and proposed settings before writing. Use `https_rules_get` with that ID to reconcile an uncertain reply without repeating the mutation. `https_rules_restore` requires its own local approval, the receipt owner, host, exact current revision and `host_and_subdomains_all_clients` scope. Conflicting settings stop restore; no automatic merge, request replay or connection interruption occurs.

Receipts survive restart but never execute on startup. The journal retains at most 32 receipts and 4 MiB; completed receipts may be retired, outstanding ones are not silently evicted. Persistent settings have no TTL and bundle cleanup does not restore them. Storage failure blocks new recovery writes. Inspect settings locally if a receipt is unavailable. Restore evidence does not establish playback success or that an existing connection adopted the new setting.

Host inspection without a recovery ID lists only your retained receipts for that host. Retired IDs remain blocked by a fixed-size used-ID filter; a possible collision rejects safely rather than replaying. If an intent never applied and settings still match its starting point, restore closes it as `not_applied_closed` without changing settings or claiming successful restoration.
