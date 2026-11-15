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

The six product images are the original, reviewed October 28 synthetic UI-test captures. The three Setup & Repair images are sheet-only screenshots from the final November 14 Maximum-mini approval-fixture run (`SetupRecoveryUITests`). The fingerprint in the trust example belongs to the test fixture; it is not a value users should copy or expect to match.

These are illustrations, not production traffic, playback evidence, or performance benchmarks. Keep one canonical file per view or distinct workflow state; link to it rather than copying it into another gallery. Staging these assets does not publish the website or approve the release.
