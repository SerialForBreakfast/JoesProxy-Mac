# MCP And CLI

## Overview {#overview}

The optional MCP server (default loopback port 9091) exposes capture, mutation, media, HLS fixture, OpenAPI mock-pack, and scenario tools to enrolled AI clients. joesproxyctl is the bundled CLI that talks to the same MCP endpoint with approvals and standing grants.

## Context and limitations {#context}

- MCP is off by default and independent of proxy capture until you start it from the MCP menu or Management panel.
- Sensitive reads and mutations use propose/apply plus in-app approval, with optional standing grants for unattended CLI use.
- Always clean up enabled rules, fixture runs, and scenarios before ending an agent session so live traffic returns to normal.

## Rate-limit responses {#rate-limits}

HTTP 429 responses use `code: "rate_limited"` and a `Retry-After` header in whole seconds.
The structured error's `details` object is string-valued: `retryAfterSeconds` and
`limitWindowSeconds` are decimal integer strings, not JSON numbers. Parse them as integers.
Authenticated requests receive guidance from their applicable buckets, including shared capacity.
Unauthenticated requests receive a fixed full-window delay without shared traffic timing.
With the default 60-second window, guidance is between 1 and 60 seconds. Admission expires
requests exactly at the window boundary, but subsequent traffic can consume the available capacity.
This guidance does not authorize automatic retries of mutations whose outcome is unknown.

## Next steps {#steps}

- Open MCP Management to start the server, enroll a client, choose Metadata Only or Shareable disclosure, and grant capabilities.
- Use joesproxyctl doctor, then auth login from a real terminal if credentials are missing.
- Prefer propose/apply with --wait-for-approval, standing grants for repeated work, and cleanup status before session end.

