# Local Overrides

## Overview {#overview}

Local Overrides are matching rules that change live traffic: Map Local (serve a draft, inline body, local file, or HLS fixture), Block (synthetic error), Map Remote (different upstream host), bookmark request replacement, live JSON response rewrites, and OpenAPI mock packs (one owned compiled contract). Enabled rules apply until you disable or remove them.

## Context and limitations {#context}

- Overrides are most useful when a live endpoint is hard to change, when you need a repeatable mock, or when you want fault injection (Block) or host retargeting (Map Remote).
- Map Local can serve a captured draft, edited inline text, a local file, or redirect path-prefix traffic to a running HLS fixture.
- An enabled override affects matching traffic until you disable or remove it. Newest matching enabled rule wins.

## Next steps {#steps}

- Create Map Local from a selected session, or open Local Overrides to add Block, Map Remote, or other rule kinds.
- Confirm match mode (exact path, ignore query, path prefix, or path suffix) before enabling.
- A rule can also be scoped to one GraphQL operation name, so it only fires for one query or mutation on an endpoint that serves every operation from the same path — set via the MCP/CLI tools (joesproxyctl block prepare / response map-local prepare --graphql-operation-name), no in-app field for it yet.
- Disable or clear overrides when you are done so future sessions reflect the real upstream response again.

