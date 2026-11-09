# Request Inspector

## Overview {#overview}

The Request Inspector shows the selected session's summary, headers, bodies, timing, inspection metadata, and override attribution when a Local Override or rewrite changed the response.

## Context and limitations {#context}

- Bodies may be unavailable when a session stayed tunneled, when the request failed before a response arrived, or when the recording was truncated.
- Inspection and Reason fields explain why the inspector shows full contents or only metadata.
- Override attribution banners appear when Map Local, Block, Map Remote, a bookmark rewrite, or a live rewrite produced the response.

## Next steps {#steps}

- Read the Summary fields first, then move to headers, bodies, and timing for deeper inspection.
- If the session is tunneled, use the HTTPS and certificate help topics to understand the limitation.
- Open Media Info when the session is classified as streaming or image media.

