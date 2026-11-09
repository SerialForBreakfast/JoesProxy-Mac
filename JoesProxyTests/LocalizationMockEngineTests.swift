//
//  LocalizationMockEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for Pseudo-Localization, RTL BiDi, CJK, and URL/Key safety guardrails.
//

import XCTest
@testable import JoesProxy

final class LocalizationMockEngineTests: XCTestCase {

    func testAccentedExpansionAndKeyProtection() {
        let json = """
        {
            "id": "item_12345",
            "title": "Welcome Home",
            "description": "Stream your favorite live sports and shows now",
            "heroImageUrl": "https://cdn.example.com/hero.jpg",
            "count": 42
        }
        """.data(using: .utf8)!

        let result = LocalizationMockEngine.transform(jsonData: json, options: LocalizationTransformOptions(preset: .pseudoAccentedExpansion))

        XCTAssertGreaterThan(result.mutatedStringCount, 0)
        XCTAssertGreaterThan(result.skippedStringCount, 0) // id and heroImageUrl should be skipped
        XCTAssertGreaterThan(result.expansionPercentage, 25.0)

        // Parse transformed JSON to verify AST integrity
        guard let dict = try? JSONSerialization.jsonObject(with: result.transformedData) as? [String: Any] else {
            XCTFail("Transformed data must be valid JSON")
            return
        }

        // Keys must be identical
        XCTAssertNotNil(dict["id"])
        XCTAssertNotNil(dict["title"])
        XCTAssertNotNil(dict["description"])
        XCTAssertNotNil(dict["heroImageUrl"])
        XCTAssertNotNil(dict["count"])

        // Values: id and URL preserved
        XCTAssertEqual(dict["id"] as? String, "item_12345")
        XCTAssertEqual(dict["heroImageUrl"] as? String, "https://cdn.example.com/hero.jpg")
        XCTAssertEqual(dict["count"] as? Int, 42)

        // Values: title and description expanded with brackets
        let transTitle = dict["title"] as? String ?? ""
        XCTAssertTrue(transTitle.hasPrefix("[!!! "))
        XCTAssertTrue(transTitle.hasSuffix(" !!!]"))
        XCTAssertTrue(transTitle.count > "Welcome Home".count)
    }

    func testRTLBiDiSimulation() {
        let json = """
        {
            "headline": "Breaking News Today"
        }
        """.data(using: .utf8)!

        let result = LocalizationMockEngine.transform(jsonData: json, options: LocalizationTransformOptions(preset: .rtlBiDiSimulation))
        let str = result.transformedString

        XCTAssertTrue(str.contains("\u{200F}"))
        XCTAssertTrue(str.contains("Today News Breaking"))
    }

    func testCJKDoubleByteConversion() {
        let json = """
        {
            "badge": "NEW!"
        }
        """.data(using: .utf8)!

        let result = LocalizationMockEngine.transform(jsonData: json, options: LocalizationTransformOptions(preset: .cjkDoubleByte))
        let str = result.transformedString

        // Fullwidth 'N' is \u{FF2E}, 'E' is \u{FF25}, 'W' is \u{FF37}, '!' is \u{FF01}
        XCTAssertTrue(str.contains("【"))
        XCTAssertTrue(str.contains("】"))
    }

    func testGermanCompoundExpansion() {
        let json = """
        {
            "label": "User Profile Settings"
        }
        """.data(using: .utf8)!

        let result = LocalizationMockEngine.transform(jsonData: json, options: LocalizationTransformOptions(preset: .germanCompoundExpansion))
        let str = result.transformedString

        XCTAssertTrue(str.contains("UserübertragungsProfileübertragungsSettings"))
    }
}
