//
//  SchemaInferredSynthesizerTests.swift
//  JoesProxyTests
//
//  Unit tests for JSON collection schema inference, item cloning,
//  and type-safe override injection.
//

import XCTest
@testable import JoesProxy

final class SchemaInferredSynthesizerTests: XCTestCase {

    func testSynthesizeItemPreservesTemplateStructureAndTypes() {
        let template: [String: Any] = [
            "id": "channel_prod_1",
            "name": "Live News HD",
            "channel_number": 101,
            "stream_url": "https://cdn.example.com/live/ch1/master.m3u8",
            "is_drm": true,
            "current_program": [
                "title": "Morning Live",
                "duration_minutes": 60
            ]
        ]

        let overrides = [
            "name": "Simulator Clear Feed",
            "channel_number": "999",
            "stream_url": "$ASSET_URL",
            "is_drm": "false"
        ]

        let boundURL = "http://127.0.0.1:9090/fixtures/hls/clear_live_profile.m3u8"

        let synthesized = SchemaInferredSynthesizer.synthesizeItem(
            from: template,
            overrides: overrides,
            boundAssetURL: boundURL
        )

        XCTAssertEqual(synthesized["name"] as? String, "Simulator Clear Feed")
        XCTAssertEqual(synthesized["channel_number"] as? Int, 999)
        XCTAssertEqual(synthesized["stream_url"] as? String, boundURL)
        XCTAssertEqual(synthesized["is_drm"] as? Bool, false)

        // Nested program structure preserved
        let program = synthesized["current_program"] as? [String: Any]
        XCTAssertNotNil(program)
        XCTAssertEqual(program?["title"] as? String, "Morning Live")
    }

    func testInjectItemIntoNestedCollectionPrepend() {
        let json: [String: Any] = [
            "status": "success",
            "channels": [
                ["id": "ch1", "name": "Channel 1"],
                ["id": "ch2", "name": "Channel 2"]
            ]
        ]

        let newItem: [String: Any] = [
            "id": "mock_ch_999",
            "name": "Mock Channel 999"
        ]

        let result = SchemaInferredSynthesizer.injectItem(
            into: json,
            at: "$.channels",
            synthesizedItem: newItem,
            position: .prepend
        )

        XCTAssertNotNil(result)
        let (modified, before, after) = result!
        XCTAssertEqual(before, 2)
        XCTAssertEqual(after, 3)

        let modifiedDict = modified as? [String: Any]
        let channels = modifiedDict?["channels"] as? [[String: Any]]
        XCTAssertEqual(channels?.count, 3)
        XCTAssertEqual(channels?.first?["id"] as? String, "mock_ch_999")
    }

    func testReplaceIndexInCollection() {
        let json: [String: Any] = [
            "items": [
                ["id": "item1"],
                ["id": "item2"]
            ]
        ]

        let newItem: [String: Any] = [
            "id": "replaced_item"
        ]

        let result = SchemaInferredSynthesizer.injectItem(
            into: json,
            at: "$.items",
            synthesizedItem: newItem,
            position: .replaceIndex(1)
        )

        XCTAssertNotNil(result)
        let (modified, before, after) = result!
        XCTAssertEqual(before, 2)
        XCTAssertEqual(after, 2)

        let items = (modified as? [String: Any])?["items"] as? [[String: Any]]
        XCTAssertEqual(items?[1]["id"] as? String, "replaced_item")
    }
}
