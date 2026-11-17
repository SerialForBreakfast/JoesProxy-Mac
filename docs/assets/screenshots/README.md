# JoesProxy 1.9.1 website screenshot kit

Use [the workspace](workspace.png) for the joesproxy.com landing page: it shows the request list and the JSON inspector together. Use [Explorer](explorer.png) for a closer look at finding requests. For the setup guide, start with [Create Root CA](setup-create.png); show the unlock example only when describing a protected signing identity.

| Image | Suggested placement | Alt text |
| --- | --- | --- |
| [Workspace](workspace.png) | Homepage hero | Stopped capture showing a synthetic request and its structured JSON response. |
| [Explorer](explorer.png) | Exploring traffic | Synthetic requests grouped by host and endpoint. |
| [Timeline](timeline.png) | Timing diagnostics | Timeline highlighting a gap between synthetic requests. |
| [Authoring](authoring.png) | Response mocking | A prepared mock revision awaiting activation. |
| [Evidence](evidence.png) | Troubleshooting | Evidence view identifying synthetic assets whose contents could not be read. |
| [Compact](compact.png) | Monitoring modes | Compact monitoring window with capture stopped. |
| [Create](setup-create.png) | First-time HTTPS setup | Create Root CA is available; signing-key access, installation, and trust have not been verified. |
| [Unlock](setup-unlock.png) | Keychain troubleshooting | After a simulated denial, Unlock Certificate Authority remains available for an explicit retry. |
| [Trust](setup-trust.png) | macOS trust instructions | The signing key is accessible and the root is installed, but Trust Root CA is still required. |

## Source and scope

### Guided Setup & Repair

These November 15 screenshots show the consolidated flow in the isolated macOS app, in dark appearance at standard text size. The proxy and certificate states come from synthetic fixtures. Verify Capture shows the controls before a live check has run.

| Page | What to look for |
| --- | --- |
| [Certificate](setup-certificate.png) | Signing identity, key access, installation, and macOS trust are ready. Advanced certificate settings are collapsed. |
| [Proxy](setup-proxy.png) | The fixture listener uses port 9090. System routing is unchecked. |
| [Verify Capture](setup-verify-capture.png) | HTTP routing and HTTPS inspection have separate results. Users can finish setup here. |
| [Devices](setup-devices.png) | The iOS instructions show the example host and port, certificate guide, and traffic checks. |
| [MCP/CLI](setup-mcp-cli.png) | The optional client setup covers service startup, enrollment, credential access, verification, and approval requests. |

The five page screenshots come from `SetupRecoveryUITests/testCaptureGuidedSetupPages`. The six workspace and feature images are the original October 28 synthetic UI-test captures. The Create, Unlock, and Trust examples come from the November 14 Maximum-mini approval-fixture run. The fingerprint in the Trust example belongs to that fixture.

These are illustrations, not production traffic, playback evidence, or performance benchmarks. Keep one canonical file per view or distinct workflow state; link to it rather than copying it into another gallery. Staging these assets does not publish the website or approve the release.
