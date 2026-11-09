import XCTest
@testable import JoesProxy

final class MediaDeliveryHeaderSummaryTests: XCTestCase {
    func testIncludesInterestingHeadersForManifestResponses() {
        let response = CapturedResponse(
            statusCode: 200,
            headers: [
                HTTPHeaderField(name: "Cache-Control", value: "public, max-age=30"),
                HTTPHeaderField(name: "Age", value: "12"),
                HTTPHeaderField(name: "CF-Cache-Status", value: "HIT"),
                HTTPHeaderField(name: "Set-Cookie", value: "ignore-me")
            ],
            bodyData: nil,
            bodySize: nil
        )

        let summary = MediaDeliveryHeaderSummary.from(
            response: response,
            mediaType: .hls,
            structure: nil
        )

        XCTAssertEqual(
            summary?.items.map(\.name),
            ["Cache-Control", "Age", "CF-Cache-Status"]
        )
    }

    func testIncludesInterestingHeadersForMediaSegments() {
        let response = CapturedResponse(
            statusCode: 206,
            headers: [
                HTTPHeaderField(name: "Content-Range", value: "bytes 0-1023/8192"),
                HTTPHeaderField(name: "X-Cache", value: "TCP_HIT"),
                HTTPHeaderField(name: "Content-Type", value: "video/mp2t")
            ],
            bodyData: nil,
            bodySize: nil
        )

        let structure = BinaryMediaStructure(
            kind: .mpegTransportStream,
            role: .transportSegment,
            bytesInspected: 1024,
            notes: [],
            tsPacketSize: 188,
            tsSyncPacketCount: 4,
            tsProgramNumbers: [],
            tsStreamTypeCodes: [],
            scte35PIDPresent: false,
            topLevelBoxes: [],
            likelyFragmented: false,
            likelyEncrypted: false,
            segmentIndexPresent: false,
            eventMessagePresent: false,
            eventMessages: [],
            psshCount: 0
        )

        let summary = MediaDeliveryHeaderSummary.from(
            response: response,
            mediaType: .video(mimeType: "video/mp2t"),
            structure: structure
        )

        XCTAssertEqual(
            summary?.items.map(\.name),
            ["Content-Range", "X-Cache"]
        )
    }

    func testTruncatesLongHeaderValues() throws {
        let longValue = String(repeating: "a", count: 150)
        let response = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "X-Test", value: longValue)],
            bodyData: nil,
            bodySize: nil
        )

        let summary = MediaDeliveryHeaderSummary.from(
            response: response,
            mediaType: .dash,
            structure: nil
        )

        let value = try XCTUnwrap(summary?.items.first?.value)
        XCTAssertLessThanOrEqual(value.count, 120)
        XCTAssertTrue(value.hasSuffix("…"))
    }

    func testIgnoresNonMediaResponses() {
        let response = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Cache-Control", value: "public")],
            bodyData: nil,
            bodySize: nil
        )

        let summary = MediaDeliveryHeaderSummary.from(
            response: response,
            mediaType: .none,
            structure: nil
        )

        XCTAssertNil(summary)
    }
}
