# Bookmarks And Replay

## Overview {#overview}

Bookmarks store repeatable requests. They can be updated from matching captured traffic and replayed through the proxy.

## Context and limitations {#context}

- Bookmarks are separate from captured sessions so you can keep a reusable request even after the original traffic scrolls away or is cleared.
- Auth and cookies can drift over time, so refresh actions pull newer values from current traffic.

## Next steps {#steps}

- Save a captured request as a bookmark when you know you'll need to rerun it later.
- Use Refresh Auth or Update From Session before replaying requests that depend on changing credentials.

