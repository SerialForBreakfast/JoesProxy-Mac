# Network Throttling

## Overview {#overview}

Network Throttling delays and paces bytes sent through JoesProxy so you can test apps against slower connection profiles such as 56k, ISDN, T1, and mobile networks.

## Context and limitations {#context}

- Throttling applies only to HTTP and HTTPS traffic routed through JoesProxy.
- It simulates bandwidth and latency. Packet loss is not simulated because dropping bytes at the HTTP/TLS proxy layer corrupts streams instead of modeling network loss accurately.
- QUIC, HTTP/3 over UDP, and other non-HTTP(S)-proxy traffic are outside JoesProxy's scope.

## Next steps {#steps}

- Enable Throttling from the session toolbar, then choose a preset.
- Open Settings > Throttling to edit preset bandwidth or latency values.
- Use a real device or simulator routed through JoesProxy when you need to test app behavior under the simulated connection.

