# Certificate And HTTPS Setup

## Overview {#overview}

JoesProxy uses a local Root CA to decrypt HTTPS traffic. Devices must trust that certificate before request and response contents can be inspected.

## Context and limitations {#context}

- HTTPS inspection is unavailable until the Root CA exists and is trusted on the requesting device.
- Trust-required and cleanup-required states usually mean the certificate exists but the OS trust state needs attention.

## Next steps {#steps}

- Open HTTPS Setup to create, install, trust, or reset the certificate state.
- Use the macOS, iOS, Simulator, or Apple TV setup guides when a device still cannot inspect HTTPS traffic.

