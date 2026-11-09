# MCP And CLI

## Overview {#overview}

The optional MCP server exposes capture and operational tools to enrolled AI clients. `joesproxyctl` is the bundled CLI that talks to the same local endpoint with approvals and standing grants.

## Context and limitations {#context}

- MCP is off by default and independent of proxy capture until a person starts it from the application.
- Sensitive reads and mutations use propose/apply plus in-app approval, with optional standing grants for unattended CLI use.
- Always clean up enabled rules, fixture runs, and scenarios before ending an agent session so live traffic returns to normal.

## Next steps {#steps}

- Start the server manually, enroll a client, choose an appropriate disclosure mode, and grant capabilities.
- Use `joesproxyctl doctor`, then authenticate from a real terminal if credentials are missing.
- Prefer propose/apply with `--wait-for-approval`, use standing grants only for repeated work, and check cleanup status before session end.
