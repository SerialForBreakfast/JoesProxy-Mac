# Media Info

## Overview {#overview}

Media Info opens a dedicated window for sessions classified as image, AV, HLS, DASH, ad XML, or timed metadata. Tabs expose manifests, variants, segments, ad markers, and deeper inspection when available.

## Context and limitations {#context}

- Sessions classified as media show an Open Media Info action from the inspector.
- HLS tabs surface variants, audio renditions, segments, discontinuities, and ad-related markers when present in the capture.
- Some deep analysis runs asynchronously and may require approval when started from MCP or the CLI.

## Next steps {#steps}

- Select a classified session and open Media Info from the inspector.
- Use HLS or DASH tabs for manifest structure, then related capture sessions for segments and variants.
- For agent-driven HLS experiments, see MCP And CLI help for fixture runs and fixture-redirect Map Local.

