//
//  DataProvenanceWatermarkerTests.swift
//  JoesProxyTests
//
//  Unit tests for JSON synthetic watermark injection and provenance token registry.
//

import XCTest
@testable import JoesProxy

final class DataProvenanceWatermarkerTests: XCTestCase {

    func testSuffixWatermarkInjection() {
        let json = """
        {
            "id": "asset_456",
            "title": "Evening News"
        }
        """
        let data = json.data(using: .utf8)!
        let sessionID = UUID()

        let rule = DataWatermarkRule(
            name: "Asset ID Watermark",
            urlPattern: "*/api/catalog/*",
            targetKeypaths: ["$.id"],
            strategy: .suffix(tag: "JP_SRC_feed")
        )

        let result = DataProvenanceWatermarker.watermark(
            jsonData: data,
            rule: rule,
            sessionID: sessionID,
            endpointURL: "https://api.example.com/api/catalog/item"
        )

        let modifiedStr = String(data: result.modifiedData, encoding: .utf8)!
        XCTAssertTrue(modifiedStr.contains("asset_456__JP_SRC_feed_"))
        XCTAssertEqual(result.injectedTokens.count, 1)

        let token = result.injectedTokens.keys.first!
        XCTAssertEqual(result.injectedTokens[token]?.keypath, "$.id")
        XCTAssertEqual(result.injectedTokens[token]?.value, "asset_456")
    }

    func testAutoAllStringsWatermarking() {
        let json = """
        {
            "user": {
                "name": "Alice",
                "role": "editor"
            },
            "tags": ["live", "news"]
        }
        """
        let data = json.data(using: .utf8)!
        let sessionID = UUID()

        let rule = DataWatermarkRule(
            name: "Auto All Strings",
            urlPattern: "*",
            strategy: .autoAllStrings(tagPrefix: "USER")
        )

        let result = DataProvenanceWatermarker.watermark(
            jsonData: data,
            rule: rule,
            sessionID: sessionID,
            endpointURL: "https://api.example.com/profile"
        )

        let modifiedStr = String(data: result.modifiedData, encoding: .utf8)!
        XCTAssertTrue(modifiedStr.contains("Alice__[JP_USER_"))
        XCTAssertTrue(modifiedStr.contains("editor__[JP_USER_"))
        XCTAssertTrue(modifiedStr.contains("live__[JP_USER_"))
        XCTAssertEqual(result.injectedTokens.count, 4)
    }

    func testPropertyInjectionStrategy() {
        let json = """
        {
            "status": "ok"
        }
        """
        let data = json.data(using: .utf8)!
        let sessionID = UUID()

        let rule = DataWatermarkRule(
            name: "Property Injection",
            urlPattern: "*",
            strategy: .property(key: "_jp_source", value: "provenance_feed_42")
        )

        let result = DataProvenanceWatermarker.watermark(
            jsonData: data,
            rule: rule,
            sessionID: sessionID,
            endpointURL: "https://api.example.com/status"
        )

        let modifiedStr = String(data: result.modifiedData, encoding: .utf8)!
        XCTAssertTrue(modifiedStr.contains("\"_jp_source\" : \"provenance_feed_42\"") || modifiedStr.contains("\"_jp_source\":\"provenance_feed_42\""))
        XCTAssertEqual(result.injectedTokens["provenance_feed_42"]?.keypath, "$._jp_source")
    }
}
