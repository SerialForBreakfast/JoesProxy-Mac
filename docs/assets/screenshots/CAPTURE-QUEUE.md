# Website screenshot collection

This folder is the canonical repository screenshot archive. Preserve original PNG
bytes; website ingestion, derivatives and publication approval are separate steps.
The November 4 editorial request is historical: source is now public. Captures
from this branch must identify their development source, even when the version
fields still read 1.9.1 (28). They are not captures of the signed release.

## Priority: iOS instructions

| Asset | Required state | Acceptance |
| --- | --- | --- |
| `ios-profile-airdrop.png` | Profile delivery section in the real iOS guide | AirDrop button and alternatives visible; do not open the nearby-device chooser. |
| `ios-certificate-qr.png` | Certificate QR sheet | Decode the rendered QR, retain its reserved fixture URL, label demonstration only. No installation/trust claim. |
| `ios-wifi-qr.png` | Automatic URL with expanded QR | Copy Setup URL and configuration warning visible; decode the rendered QR independently. |
| `ios-watch-device-traffic.png` | Verify Routing before starting a device test | Keep the waiting/not-yet-verified context; no fabricated success. |

The existing `setup-devices.png` covers only the overview. Physical-device
installation, full trust and Wi-Fi settings require separate isolated-device
captures. Do not substitute Mac windows for these steps.

## Remaining feature collection

| Request | Collection requirement |
| --- | --- |
| JP-01 | Meaningful JSON edit and prepared review pair, inactive scope visible. Existing `authoring.png` supplies only a prepared-review illustration. |
| JP-02 | Readable batch insertion/reordering and owned artwork before/review pair. Historical 2×2 artwork is unsuitable. |
| JP-03 | Controlled successful downstream write plus unavailable asset evidence; no player-rendering claim. |
| JP-04 | Pending synthetic MCP request, scope and approval choices. No approval action. |
| JP-05 | HLS manifest and controlled segment-failure timeline. A delivery fault is not a confirmed player stall. |
| JP-06 | Conditioning configuration and resulting fixture timing pair, active state explicit. |
| JP-07 | Safely named recording/bookmark/replay workflow. |
| JP-08 | Reserved-address setup guide; see iOS priority above. |
| JP-09 | Active synthetic Compact capture. Existing `compact.png` is stopped. |
| JP-10 | Meaningful VAST/VMAP and test-stream controls, separate images for distinct features. |

For every new original record SHA-256, dimensions, source commit and dirty scope,
app version/build, test and attachment identity, fixture, date, caption/alt text,
rights, privacy review and publication status. Unknown provenance stays unknown.
Crops must retain warnings and record source hash and original-pixel rectangle.

## November 17 initial collection outcome (superseded for iOS below)

- Recovered 12 exact-byte historical originals linked in README.md. These supply
  review candidates for JP-01–05 and the AirDrop portion of JP-08. They do not close
  current-release capture acceptance. The later batch sequence has owned 640×360
  artwork metadata; the two earlier dense examples remain archival only.
- Certificate QR, Wi-Fi QR and Watch for Device Traffic remain uncaptured.
  Source inspection confirms the existing demo fixture injects reserved
  `192.0.2.10` with no Bonjour name. The iOS guide starts a profile listener;
  next capture must use only synthetic certificate data and decode the actual
  rendered QR before accepting it. Do not operate trust or system-routing controls.
- Fresh attempt: `build/HostTestResults/ui-20261117-112144-43157.xcresult`,
  log `build/WebsiteScreenshots.log`, exit 65. XCTest reported
  `Timed out while enabling automation mode.` No screenshot test body ran.
  The result's one failure is runner initialization, not a feature assertion.
- Selected cases were the existing MCP approval, loopback transport and HLS
  screenshot tests. Build used the existing `build/Edge` products and locked
  dependencies. No permissions were reset and no unchanged retry was attempted.
- Resume after a diagnosed host-automation recovery condition, then capture the
  three missing iOS states and refresh AirDrop against the selected release.
  Existing screenshot authorization does not authorize OS permission changes.

## November 17 runner approval and completed iOS capture

The maintainer approved the UI runner. The initialization failure cleared.
`ScreenshotUITests/testCaptureIOSWebsiteDeliveryStates()` now captures all four
iOS states using existing synthetic fixtures. Two harness failures were retained:
XCTest's screenshot returned no QR to Vision, then an offscreen Wi-Fi toggle did
not expand. The corrected case decodes ScreenCaptureKit window PNGs, scopes
scrolling to the setup sheet, and asserts that the Wi-Fi QR is expanded.

Final result: `build/HostTestResults/ui-20261117-115200-46379.xcresult`, exit 0,
one test passed, zero failures/skips; log `build/IOSWebsiteScreenshots3.log`.
All four full-resolution originals are in `ios-2026-11-17/`, with a manifest and
README links. Both QR payloads use reserved `192.0.2.10`, no credentials. Visual
review confirmed intended controls and warnings; no pixels were changed.

The P0/P1 Mac-side iOS image collection is complete for this development build.
Current-release equivalence and publication remain editorial decisions. Physical
iOS installation/trust screens and the remaining JP-06/07/09/10 collection stay open.
