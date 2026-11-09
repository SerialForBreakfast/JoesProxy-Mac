import XCTest
@testable import JoesProxy

final class InspectorBodyPageTests: XCTestCase {
    func testBinaryPagesReconstructCompleteBodyWithBoundedStrings() throws {
        let original = Data((0..<(InspectorBodyPage.byteLimit * 5 + 17)).map { UInt8($0 % 256) })
        let first = InspectorBodyPage(data: original, page: 0, binary: true)
        var reconstructed = Data()
        for index in 0..<first.pageCount {
            let page = InspectorBodyPage(data: original, page: index, binary: true)
            XCTAssertTrue(page.isBase64)
            XCTAssertLessThanOrEqual(page.text.utf8.count, InspectorBodyPage.byteLimit * 4 / 3)
            reconstructed.append(try XCTUnwrap(Data(base64Encoded: page.text)))
        }
        XCTAssertEqual(reconstructed, original)
    }

    func testUTF8ScalarsCrossingEveryBoundaryRemainIntact() {
        for scalar in ["é", "€", "😀"] {
            for crossing in 1..<scalar.utf8.count {
                let text = String(repeating: "a", count: InspectorBodyPage.byteLimit - crossing)
                    + scalar + String(repeating: "b", count: InspectorBodyPage.byteLimit) + scalar
                let data = Data(text.utf8)
                let first = InspectorBodyPage(data: data, page: 0, binary: false)
                var joined = ""
                for index in 0..<first.pageCount {
                    let page = InspectorBodyPage(data: data, page: index, binary: false)
                    XCTAssertFalse(page.isBase64)
                    XCTAssertLessThanOrEqual(page.byteRange.count, InspectorBodyPage.byteLimit + 3)
                    joined += page.text
                }
                XCTAssertEqual(joined, text)
            }
        }
    }

    func testInvalidUTF8IsNotDroppedAtPageBoundaries() throws {
        var data = Data(repeating: 0x80, count: InspectorBodyPage.byteLimit + 4)
        data[InspectorBodyPage.byteLimit - 1] = 0xFF
        let first = InspectorBodyPage(data: data, page: 0, binary: false)
        let second = InspectorBodyPage(data: data, page: 1, binary: false)
        XCTAssertEqual(try XCTUnwrap(Data(base64Encoded: first.text)) + XCTUnwrap(Data(base64Encoded: second.text)), data)
    }

    func testTrailingScalarDoesNotCreateAnEmptyExtraPage() {
        let data = Data((String(repeating: "a", count: InspectorBodyPage.byteLimit - 1) + "😀").utf8)
        let page = InspectorBodyPage(data: data, page: 1, binary: false)
        XCTAssertEqual(page.pageCount, 1)
        XCTAssertEqual(page.pageIndex, 0)
        XCTAssertEqual(Data(page.text.utf8), data)
    }

    func testShrinkingBodyClampsStalePageAndSupportsSlicedData() {
        let data = Data("prefixhello".utf8).dropFirst(6)
        let page = InspectorBodyPage(data: data, page: Int.max, binary: false)
        XCTAssertEqual(page.text, "hello")
        XCTAssertEqual(page.pageIndex, 0)
        XCTAssertEqual(page.byteRange, 0..<5)
        XCTAssertEqual(InspectorBodyPage(data: Data(), page: -1, binary: true).pageCount, 1)
    }

    func testJSONProbeSkipsOpaquePayloadButPreservesUntypedAndDelimitedJSON() {
        let opaqueHeaders = [HTTPHeaderField(name: "Content-Type", value: "application/octet-stream")]
        XCTAssertFalse(InspectorJSONEligibility.shouldProbe(Data(repeating: 42, count: 262_144), headers: opaqueHeaders))
        for content in ["{}", "[]", "preamble\n{\"id\":1}\n{\"id\":2}", "{}\0{}"] {
            XCTAssertTrue(InspectorJSONEligibility.shouldProbe(Data(content.utf8), headers: opaqueHeaders))
            XCTAssertTrue(JSONTreeParser.canParseJSONObject(from: Data(content.utf8)))
        }
        XCTAssertFalse(InspectorJSONEligibility.shouldProbe(Data("{binary}".utf8), headers: [
            HTTPHeaderField(name: "Content-Type", value: "image/png")
        ]))
        XCTAssertTrue(InspectorJSONEligibility.shouldProbe(Data("{}".utf8), headers: [
            HTTPHeaderField(name: "Content-Type", value: "application/example+json")
        ]))
    }
}
