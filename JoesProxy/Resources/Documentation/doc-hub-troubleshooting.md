# Troubleshooting

## Troubleshooting 1 {#p1}

The certificate exists but is not trusted yet. Open HTTPS Setup or the device setup guide and complete the trust step.

## Troubleshooting 2 {#p2}

Confirm the device points to the JoesProxy host and port, the proxy is running, and the app or device is not bypassing the configured proxy. If system proxy routing is enabled, check the routing pill shows Routed.

## Troubleshooting 3 {#p3}

Check whether the session is tunneled, truncated in a saved recording, or part of a pinned TLS flow that cannot be decrypted.

## Troubleshooting 4 {#p4}

With system proxy management on, Mac browsers and background services may appear in the capture list. Filter by source or turn routing off when you need a quiet capture.

## Troubleshooting 5 {#p5}

If the proxy will not start, choose a different port in Settings > Proxy and retry after the current listener is stopped.

