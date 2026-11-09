## Capture completeness and bounded investigations

Revision: 2026-09-13. Separate forwarded bytes, retained bodies, exported evidence and process
memory. A successful response can have only a retained prefix; retention may later remove the
body, and overload can leave a capture-admission gap while forwarding continues.

- Check response_context and available completeness/omission fields before analysis, mocking or
  export. If the reason is unavailable, report it as unknown rather than inventing an eviction
  cause. Do not change retention settings or disable limits just to make a conclusion possible.
- Full Recording preserves currently available bytes without another save-time truncation.
  It cannot restore bytes already missing. Compression preserves its input, not historical
  completeness. HAR is not guaranteed exact wire/protocol evidence or target-state reproduction.
- Start with bounded summaries and handles. Inspect only the relevant body/manifest; cancel
  superseded operations and observe completion/cleanup before requesting replacements.
- For performance work, agree on workload, duration and stop conditions first. Separate logical
  byte/queue counts from physical footprint and CPU; do not infer a leak from peak RSS or a single
  warm-up increase. Honor a user-imposed run limit: an inconclusive run is not permission to retry.
- When handing work back, name the actor and exact next action. Give complete runnable commands
  with the verified executable path, or clearly label parameterized examples. Do not ask the user
  to infer which command fragment, duplicate bundle or approval request you meant.

