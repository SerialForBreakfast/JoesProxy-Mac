# JoesProxy 1.9.1 website screenshot kit

The [capture queue](CAPTURE-QUEUE.md) tracks the additional iOS and feature images
requested for the website and historical archive. New development captures must
retain their source identity and publication-review status alongside the PNGs.

## Recovered originals for review

Twelve additional PNG originals were recovered on November 17 from the November
4–5 test exports, matched by test/attachment identity and visually inspected.
Their manifests record SHA-256, dimensions, captions and limitations. Historical
app builds and commits are unknown, so these are not certified release captures.
No pixels were changed, no crops were made, and publication approval is pending.

| Story | Originals |
| --- | --- |
| iOS profile delivery | [AirDrop and Safari alternatives](history-2026-11-05/setup-evidence/ios-profile-airdrop.png) — reserved URL, stopped proxy, device unverified. |
| Batch authoring | [Editor](history-2026-11-04/editorial/batch-editor.png), [prepared review](history-2026-11-04/editorial/batch-review.png), [resulting JSON](history-2026-11-04/editorial/batch-result.png), [artwork binding](history-2026-11-04/editorial/artwork-binding.png). |
| Human approval | [Pending MCP request](history-2026-11-04/editorial/mcp-approval.png). |
| Delivery evidence | [Completed write](history-2026-11-05/setup-evidence/transport-success.png), [unavailable asset](history-2026-11-05/setup-evidence/transport-unavailable.png). Rendering/playback remain unconfirmed. |
| HLS analysis | [Manifest](history-2026-11-05/hls/hls-manifest.png), [controlled segment failure](history-2026-11-05/hls/hls-segment-fault.png). No player-stall claim. |
| Earlier implementation history | [Batch preparation](history-2026-11-04/batch-prepared.png), [2×2 artwork example](history-2026-11-04/artwork-prepared.png). Retained for posterity; prefer the later editorial sequence for review. |

## Fresh iOS setup captures — November 17

The four requested states are captured and visually reviewed:

- [AirDrop profile delivery](ios-2026-11-17/ios-profile-airdrop.png)
- [Expanded certificate QR](ios-2026-11-17/ios-certificate-qr.png)
- [Automatic Wi-Fi URL and QR](ios-2026-11-17/ios-wifi-qr.png)
- [Watch for Device Traffic, before starting](ios-2026-11-17/ios-watch-device-traffic.png)

These are full-resolution originals from the real UI with synthetic certificate
and proxy state, dark appearance and standard text size. Both QR payloads were
decoded and checked against the reserved fixture URLs. Use a demonstration caption:
users must use their own app's codes. No device installation, trust, transfer or
traffic verification is claimed.

The [manifest](ios-2026-11-17/manifest.json) records source/build identity,
checksums, dimensions, test/attachment identity and proposed captions. This is the
development checkout with 1.9.1 (28) version fields, not the signed release binary.
Publication approval remains pending; no website files were changed.

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
