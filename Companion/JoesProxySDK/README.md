# JoesProxySDK

Debug-only companion SDK for apps that connect to JoesProxy during local network capture sessions.

This package lives inside the JoesProxy workspace at `Companion/JoesProxySDK`. See the [contributor guide](../../CONTRIBUTING.md) for source validation and [snapshot scope](../../docs/PUBLIC-SNAPSHOT.md) for included material.

## Info.plist

Apps using Bonjour discovery must include local network usage copy and the JoesProxy service type in the debug target's `Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>JoesProxy uses the local network to connect this debug build to the JoesProxy app on your Mac.</string>
<key>NSBonjourServices</key>
<array>
    <string>_joesproxy._tcp</string>
</array>
```

Keep these keys out of release builds unless the shipped app intentionally uses local-network discovery.

## Connect

```swift
#if DEBUG
await ProxySDK.shared.discoverAndConnect(token: "<pairing token>")
#endif
```

If Bonjour is blocked by the network, connect manually:

```swift
#if DEBUG
await ProxySDK.shared.connect(host: "MacBook-Pro.local", port: 9091, token: "<pairing token>")
#endif
```

## Version Compatibility

The SDK and JoesProxy negotiate a protocol schema during the pairing handshake. If the app and SDK do not share a compatible schema, the connection moves to:

```swift
.rejected(reason: .schemaVersionUnsupported, compatibility: info)
```

Show `info?.userFacingMessage` to tell the developer whether to update the JoesProxy app or the `JoesProxySDK` package. The handshake acknowledgement also includes the JoesProxy app version and the schema range supported by that app.

## Testing

Add `ProxySDKTesting` as a test-only dependency in your app's `Package.swift` (or Xcode test target). It provides `ProxyCapture`, eight typed assertions, a `DiagnosticReport` for CI artifacts, and a `NetworkEventFixture` builder for fixture-only tests.

### Collecting a capture window

```swift
import ProxySDKTesting

// In setUp / setUpWithError / override func setUp() async throws:
let capture = ProxySDK.shared.startCapture(label: "CheckoutFlow")

// … run UI actions …

// In tearDown:
capture.end()

// Assert between setUp and tearDown:
try capture.assertCDNHit(matching: "cdn.myapp.com")
try capture.assertNoRetries()
try capture.assertP95Latency(under: 1.0)
```

All assertions are **no-ops when no proxy is connected** (empty capture). This keeps tests green in CI environments where JoesProxy is not running.

### Available assertions

| Method | What it checks |
|--------|----------------|
| `assertCDNHit(matching:)` | ≥1 matching request was served from CDN cache |
| `assertNoCacheMiss(matching:)` | No matching request had a cache miss |
| `assertNoRetries()` / `assertNoRetries(matching:)` | No requests had `retryCount > 0` |
| `assertHTTP2(matching:)` | All matching requests used HTTP/2 |
| `assertAllTLS12OrBetter()` | Reserved — always passes in schema v1 |
| `assertParallel(_:)` | Named URL patterns ran with overlapping time windows |
| `assertOnlyAllowedDomains(_:)` | Every request went to an allowlisted domain (supports `*.domain.com` wildcards) |
| `assertP95Latency(under:matching:)` | 95th-percentile latency is under the given threshold |

### CI diagnostic artifact

```swift
let data = try capture.diagnosticReport().jsonData()
// XCTest: add(XCTAttachment(data: data, uniformTypeIdentifier: "public.json"))
// Swift Testing: write data to a file in the test's output directory
```

The JSON report includes `requestCount`, `errorRate`, `p50LatencySeconds`, `p95LatencySeconds`, `cdnHitRate`, `totalRetryCount`, and a `thirdPartySummary` that counts requests per `sourceSDK` label.

### Unit-testing assertion logic without a proxy

Use `ProxyCapture.makeFixture(events:)` with `NetworkEventFixture.make(...)` to exercise assertions against synthetic data:

```swift
import ProxySDKTesting

let cap = ProxyCapture.makeFixture(events: [
    NetworkEventFixture.make(url: URL(string: "https://cdn.myapp.com/v2/bundle.js")!, cacheStatus: .hit),
    NetworkEventFixture.make(url: URL(string: "https://api.myapp.com/v1/launch")!, total: 0.08),
])
try cap.assertCDNHit(matching: "cdn.myapp.com")
try cap.assertP95Latency(under: 0.5)
```
