import Foundation
import XCTest
@testable import JoesProxy

final class JSONSyntaxHighlighterTests: XCTestCase {

    func testHighlightTokensAndRangesMatchSourceString() {
        let json = """
        {
          "name": "JoesProxy",
          "version": 1.5,
          "enabled": true,
          "disabled": false,
          "notes": null,
          "items": [10, -20, 3.14, 1e-5],
          "emoji": "test 🚀 text"
        }
        """

        let spans = JSONSyntaxHighlighter.spans(for: json)
        XCTAssertFalse(spans.isEmpty)

        let nsString = json as NSString

        // Verify every span has valid range within nsString
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.range.location, 0)
            XCTAssertGreaterThan(span.range.length, 0)
            XCTAssertLessThanOrEqual(span.range.location + span.range.length, nsString.length)
        }

        // Verify specific key and value spans
        let keySpans = spans.filter { $0.color == .key }
        let keyTexts = keySpans.map { nsString.substring(with: $0.range) }
        XCTAssertEqual(keyTexts, ["\"name\"", "\"version\"", "\"enabled\"", "\"disabled\"", "\"notes\"", "\"items\"", "\"emoji\""])

        let stringSpans = spans.filter { $0.color == .string }
        let stringTexts = stringSpans.map { nsString.substring(with: $0.range) }
        XCTAssertEqual(stringTexts, ["\"JoesProxy\"", "\"test 🚀 text\""])

        let numberSpans = spans.filter { $0.color == .number }
        let numberTexts = numberSpans.map { nsString.substring(with: $0.range) }
        XCTAssertEqual(numberTexts, ["1.5", "10", "-20", "3.14", "1e-5"])

        let boolSpans = spans.filter { $0.color == .boolean }
        let boolTexts = boolSpans.map { nsString.substring(with: $0.range) }
        XCTAssertEqual(boolTexts, ["true", "false"])

        let nullSpans = spans.filter { $0.color == .null }
        let nullTexts = nullSpans.map { nsString.substring(with: $0.range) }
        XCTAssertEqual(nullTexts, ["null"])
    }

    func testEscapedCharactersInStrings() {
        let json = #"{"escaped": "line1\nline2 \"quote\" \\ slash"}"#
        let spans = JSONSyntaxHighlighter.spans(for: json)
        let nsString = json as NSString

        let keySpan = spans.first { $0.color == .key }
        XCTAssertNotNil(keySpan)
        XCTAssertEqual(nsString.substring(with: keySpan!.range), "\"escaped\"")

        let stringSpan = spans.first { $0.color == .string }
        XCTAssertNotNil(stringSpan)
        XCTAssertEqual(nsString.substring(with: stringSpan!.range), #""line1\nline2 \"quote\" \\ slash""#)
    }

    func testEmptyAndMinimalJSON() {
        XCTAssertTrue(JSONSyntaxHighlighter.spans(for: "").isEmpty)

        let spans = JSONSyntaxHighlighter.spans(for: "{}")
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].color, .bracket)
        XCTAssertEqual(spans[1].color, .bracket)
    }
}
