# System Proxy And Routing

## Overview {#overview}

System Proxy Routing optionally points the active macOS network service's HTTP and HTTPS proxies at JoesProxy while the proxy is running, then restores previous settings when it stops. A routing indicator and optional menu bar item show whether traffic is routed.

## Context and limitations {#context}

- With system proxy management enabled, Simulator and many Mac apps reach JoesProxy without per-app proxy settings.
- Ambient Mac traffic (browsers, updates, telemetry) may also appear in the capture list while routing is active.
- Strict capture disables the PAC direct-connection fallback so little traffic escapes, but a crash can break networking until JoesProxy reopens.

## Next steps {#steps}

- Open Settings > Proxy to enable automatic system proxy management while capturing.
- Prefer Strict Capture off unless you need zero bypass and accept crash-recovery risk.
- Use the routing pill or menu bar item to confirm Direct vs Routed state, and restore previous settings after an unsafe quit.

