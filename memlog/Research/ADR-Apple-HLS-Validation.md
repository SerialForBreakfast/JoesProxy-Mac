# ADR — Apple HLS validation for JoesProxy fixture runs

**Proposed · 2026-11-10.** Initial research and decision proposal. Start with one manually initiated, synthetic VOD experiment. Product integration depends on proving the route and the diagnostic value.

## Context

A playlist can parse successfully and its segments can return HTTP 200 while the stream still has an authoring defect. JoesProxy can show what the manifest declares, which resources a client fetched, and where delivery failed. A developer investigating a bitrate mismatch also needs an independent measurement of the media delivered for that rendition. Apple’s validator acts as another HLS client and checks playlists and segments. Its companion report organizes authoring findings by stream, including declared versus measured bandwidth. Playback quality still requires observation in a player. [Apple’s validation overview](https://developer.apple.com/documentation/http-live-streaming/deploying-a-basic-http-live-streaming-hls-stream) · [Authoring specification appendixes](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices-appendixes/)

The fixture server already serves VOD and sliding playlists. Each active run has an ID, profile version, expiration and reserved hostname. That hostname resolves **inside JoesProxy’s request handler**. Pasting the fixture URL into an external validator does not establish a working route. A saved recording can also lack segments, keys or bodies that a fresh client needs. [Fixture server](../../JoesProxy/MediaFixture/HLSFixtureServer.swift) · [Origin registry](../../JoesProxy/MediaFixture/HLSFixtureOriginRegistry.swift) · [Run record](../../JoesProxy/MediaFixture/HLSFixtureRunStore.swift) · [Manifest inspection](../../JoesProxy/MCP/Media/MCPMediaInspectionService.swift)

## Decision

Pair an Apple validation report with a specific fixture run. Keep Apple’s tools optional and separately obtained. The first deliverable should be a reproducible operator workflow and an example report from synthetic media. Add an in-app action only after the experiment below succeeds. A developer should be able to go from a finding about a particular variant to its captured playlist and segment requests, change one fixture input, and compare the next report.

1. Start an authorized fixture run. Record its run ID, profile/version, playback configuration, master URL and expiration. Use a separate capture window for validator traffic so its requests cannot be mistaken for player behavior.
2. With the locally installed tool’s manual, establish whether that version supports an explicit per-process HTTP proxy route. Try the synthetic master through JoesProxy. Confirm delivery of the master, a child playlist and a segment in the fixture evidence. If the route fails, record it as a routing failure. Evaluate a loopback-only adapter forwarding to the same active fixture handler before pursuing unattended execution. Avoid system-wide proxy changes.
3. Run mediastreamvalidator against that master and retain its JSON output alongside the tool version, invocation settings, timestamps and completion status. Use the installed version’s documented output option. Generate the human-readable report with `hlsreport -o report.html validation_data.json`. Preserve both artifacts: Apple’s report supplies authoring classifications and stream IDs. Validate any future structured importer against versioned samples before exposing counts. [Apple’s report instructions](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices-appendixes/)
4. Associate each finding with the run and its rendition using the report’s stream reference and playlist URI where available. Keep ambiguous or unmatched findings visible. Record validator completion, authoring findings and observed player behavior separately. A timeout, expired fixture or incomplete artifact must yield an incomplete result.
5. For a later app integration, offer **Validate fixture** from an active run. Show the target and duration before launch, provide cancellation, and retain a local report reference. Scope initial execution to self-contained synthetic fixtures with local resource references. External manifests can trigger secondary requests for segments, keys or redirects and need a separate design. Treat raw reports as local artifacts because URLs may contain credentials. An agent-facing read can return a bounded summary and opaque finding IDs.

## Alternatives and consequences

Manual use against an ordinary stream URL works today and is a useful control for diagnosing routing problems. It loses the fixture identity and the ability to correlate a reported rendition with a repeatable capture. Reimplementing Apple’s authoring checks in the manifest inspector would duplicate evolving rules and would require media measurements beyond playlist parsing. Bundling the binaries or requiring them in CI would introduce distribution and tool-version dependencies before the integration has demonstrated value.

Start with VOD because the same bytes can be measured twice. A sliding live window changes during inspection and can outlast the run’s expiration. A later live experiment must record its sampled interval and media sequence range, bound its duration, and distinguish a partial sample from a completed check. Apple discusses different measurement windows for VOD and live streams. [Bandwidth measurement guidance](https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html)

## Acceptance and follow-up

- Validate the same known-good VOD fixture twice. Check rendition identity, captured requests and findings for reproducibility. Keep an unexpected baseline finding as evidence to investigate.
- Change only one variant’s declared bandwidth while serving identical segment bytes. Require the report to identify the affected rendition and verify that the comparison explains the change. Then make a segment unavailable and confirm that delivery failure remains distinguishable from the authoring issue.
- Exercise missing tools, unsupported report versions, cancellation, an expired origin and an unmatched rendition. Preserve partial diagnostics and avoid a clean verdict in each incomplete case.
- Proceed to a report viewer if the experiment reliably identifies the altered rendition and saves a developer the manual work of matching it to requests. If routing remains unproven, support manual report inspection first and defer execution from the app.

Research was source-level. Neither Apple executable was found on this shell’s PATH. Proxy behavior, report schema and the proposed comparisons still require a separately authorized run with the installed tools.

## 2026-11-10 — Local tool discovery

Shell lookup, Spotlight and a filename search of readable application, system, data and mounted-volume paths yielded no mediastreamvalidator, hlsreport or legacy hlsreport.py. The package receipt inventory showed no matching Apple HLS Tools receipt. Protected directories and unopened archives remain outside this evidence. No tool was installed. The synthetic VOD experiment stopped before fixture activation, so proxy routing and report correlation remain untested. Resume with a verified executable location or an explicitly approved installation of Apple’s HLS Tools.

## 2026-11-10 — Installation and fixture preflight

Installation and the synthetic experiment are authorized. The official [Apple Developer download search](https://developer.apple.com/download/all/?q=HTTP%20Live%20Streaming%20Tools) redirected the download session to Apple Account sign-in. Installation is pending acquisition of the official package.

Selected the [aligned-codecs master playlist](../../Fixtures/HLS/baseline-aligned-codecs/master.m3u8) as the baseline candidate. Its low variant declares BANDWIDTH=896000 and AVERAGE-BANDWIDTH=800000. The VOD child playlist references six local transport-stream segments. This gives the experiment a specific rendition and byte-preserving control for a single-field bandwidth change. These are source observations. No validator traffic or Apple report was produced.
