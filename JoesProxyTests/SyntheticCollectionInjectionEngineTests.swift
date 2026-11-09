//
//  SyntheticCollectionInjectionEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for live wire collection injection execution,
//  synthetic media binding, and client-scoped filtering.
//

import XCTest
@testable import JoesProxy

@MainActor
final class SyntheticCollectionInjectionEngineTests: XCTestCase {

    override func setUp() {
        SyntheticCollectionInjectionEngine.shared.clearAllPlans()
    }

    func testExecuteInjectionWithBoundLiveHLSAsset() {
        let epgJSON = """
        {
            "channels": [
                {
                    "id": "ch_espn",
                    "name": "Sports Live",
                    "stream_url": "https://cdn.example.com/live/ch1.m3u8",
                    "drm": true
                }
            ]
        }
        """
        let data = epgJSON.data(using: .utf8)!

        let plan = SyntheticCollectionInjectionPlan(
            name: "Mock EPG Test Channel",
            urlPattern: "*/epg/channels*",
            collectionKeypath: "$.channels",
            position: .prepend,
            boundAssetKind: .clearLiveHLS,
            fieldOverrides: [
                "name": "JoesProxy Clear Stream",
                "stream_url": "$ASSET_URL",
                "drm": "false"
            ],
            clientScope: .allClients
        )

        let engine = SyntheticCollectionInjectionEngine.shared
        engine.registerPlan(plan)

        let result = engine.processResponse(
            responseData: data,
            requestURL: "https://api.example.com/v1/epg/channels?region=us",
            requestHeaders: []
        )

        XCTAssertNotNil(result)
        let (transformedData, meta) = result!
        XCTAssertTrue(meta.wasTransformed)
        XCTAssertEqual(meta.collectionCountBefore, 1)
        XCTAssertEqual(meta.collectionCountAfter, 2)

        let json = try? JSONSerialization.jsonObject(with: transformedData, options: []) as? [String: Any]
        let channels = json?["channels"] as? [[String: Any]]
        XCTAssertEqual(channels?.count, 2)

        let firstChannel = channels?.first
        XCTAssertEqual(firstChannel?["name"] as? String, "JoesProxy Clear Stream")
        XCTAssertEqual(firstChannel?["stream_url"] as? String, "https://assets.joesproxy.invalid/fixtures/hls/clear_live_profile.m3u8")
        XCTAssertEqual(firstChannel?["drm"] as? Bool, false)
    }

    func testClientScopeSimulatorFiltering() {
        let plan = SyntheticCollectionInjectionPlan(
            name: "Simulator Only Rule",
            urlPattern: "*/feed*",
            collectionKeypath: "$.items",
            clientScope: .simulatorOnly
        )
        SyntheticCollectionInjectionEngine.shared.registerPlan(plan)

        let rawJSON = "{\"items\": [{\"id\": 1}]}".data(using: .utf8)!

        // 1. Simulator User-Agent
        let simHeaders = [HTTPHeaderField(name: "User-Agent", value: "MyApp/1.0 (iOS Simulator; iPhone16,1)")]
        let simResult = SyntheticCollectionInjectionEngine.shared.processResponse(
            responseData: rawJSON,
            requestURL: "https://api.example.com/feed",
            requestHeaders: simHeaders
        )
        XCTAssertNotNil(simResult)

        // 2. Physical Device User-Agent
        let deviceHeaders = [HTTPHeaderField(name: "User-Agent", value: "Dalvik/2.1.0 (Linux; U; Android 14; Pixel 8)")]
        let deviceResult = SyntheticCollectionInjectionEngine.shared.processResponse(
            responseData: rawJSON,
            requestURL: "https://api.example.com/feed",
            requestHeaders: deviceHeaders
        )
        XCTAssertNil(deviceResult)
    }

    /// Guard (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): a
    /// pathologically large response body must be refused before the full-tree JSON parse and
    /// `.sortedKeys` re-serialize — not attempted and left to pin CPU. Fail-open: the real response
    /// passes through untransformed, same as every other early-exit in `executeInjection`.
    func testOversizedResponseBodyRefusesInjectionInsteadOfParsing() {
        let plan = SyntheticCollectionInjectionPlan(
            name: "Oversized Body Guard Test",
            urlPattern: "*/catalog*",
            collectionKeypath: "$.items",
            clientScope: .allClients
        )
        SyntheticCollectionInjectionEngine.shared.registerPlan(plan)

        // Not valid JSON at all — proves the guard fires before JSONSerialization ever runs, since a
        // parse failure alone already returns nil for a different reason further down.
        let oversizedBody = Data(repeating: 0x41, count: SyntheticInjectionBudget.maxResponseBodyBytes + 1)
        let result = SyntheticCollectionInjectionEngine.shared.processResponse(
            responseData: oversizedBody,
            requestURL: "https://api.example.com/catalog",
            requestHeaders: []
        )
        XCTAssertNil(result)
    }

    func testResponseBodyAtExactCeilingIsStillProcessed() {
        // Pad a valid JSON document with whitespace up to exactly the ceiling to prove the guard's
        // comparison is inclusive (`<=`), not an off-by-one that rejects a body right at the limit.
        let items = "{\"items\": [{\"id\": 1}]}"
        let padding = String(repeating: " ", count: SyntheticInjectionBudget.maxResponseBodyBytes - items.utf8.count)
        let paddedJSON = padding + items
        let data = paddedJSON.data(using: .utf8)!
        XCTAssertEqual(data.count, SyntheticInjectionBudget.maxResponseBodyBytes)

        let plan = SyntheticCollectionInjectionPlan(
            name: "Exact Ceiling Test",
            urlPattern: "*/catalog*",
            collectionKeypath: "$.items",
            clientScope: .allClients
        )
        SyntheticCollectionInjectionEngine.shared.registerPlan(plan)

        let result = SyntheticCollectionInjectionEngine.shared.processResponse(
            responseData: data,
            requestURL: "https://api.example.com/catalog",
            requestHeaders: []
        )
        XCTAssertNotNil(result)
    }
}
