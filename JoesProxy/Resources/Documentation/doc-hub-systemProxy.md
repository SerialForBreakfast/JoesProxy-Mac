# System Proxy Routing

## System Proxy Routing 1 {#p1}

Settings > Proxy can automatically point macOS HTTP/HTTPS proxy settings at JoesProxy while capturing, then restore the previous settings when capture stops.

## System Proxy Routing 2 {#p2}

Browsers, updates, and telemetry that honor the system proxy may appear alongside intentional DUT or Simulator traffic. Use source badges and filters to separate them.

## System Proxy Routing 3 {#p3}

Disables the PAC direct-connection fallback so little traffic escapes the proxy. Leave it off unless you need zero bypass and accept that an unsafe quit can break networking until JoesProxy reopens.

## System Proxy Routing 4 {#p4}

The routing pill and menu bar item show Direct vs Routed state. Restore previous settings after an unsafe quit if networking looks wrong.

