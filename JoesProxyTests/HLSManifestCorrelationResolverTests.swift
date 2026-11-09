import Foundation
import XCTest
@testable import JoesProxy

final class HLSManifestCorrelationResolverTests: XCTestCase {
    func testCorrelatesInitializationSegmentToCapturedManifest() {
        let manifestSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/master.m3u8",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
            bodyData: Data("""
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-MAP:URI="https://video.example.com/init.mp4"
            #EXTINF:6.0,
            https://video.example.com/seg-1.m4s
            """.utf8)
        )

        let initSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/init.mp4",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")]
        )

        let correlation = HLSManifestCorrelationResolver.correlate(session: initSession, within: [manifestSession, initSession])

        XCTAssertEqual(correlation?.referenceKind, .initSegment)
        XCTAssertEqual(correlation?.manifestSessionIDs, [manifestSession.id])
        XCTAssertEqual(correlation?.matches.first?.manifestPath, "/master.m3u8")
        XCTAssertEqual(correlation?.matches.first?.strategy, .exactURL)
    }

    func testCorrelatesMediaSegmentToCapturedManifest() {
        let manifestSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/media.m3u8",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
            bodyData: Data("""
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXTINF:6.0,
            https://video.example.com/seg-1.ts
            """.utf8)
        )

        let segmentSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/seg-1.ts",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp2t")]
        )

        let correlation = HLSManifestCorrelationResolver.correlate(session: segmentSession, within: [manifestSession, segmentSession])

        XCTAssertEqual(correlation?.referenceKind, .mediaSegment)
        XCTAssertEqual(correlation?.manifestSessionIDs, [manifestSession.id])
        XCTAssertEqual(correlation?.matches.first?.manifestPath, "/media.m3u8")
        XCTAssertEqual(correlation?.matches.first?.matchedReference, "https://video.example.com/seg-1.ts")
    }

    func testCorrelatesMediaSegmentWhenQueryOrderingDiffers() {
        let manifestSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/media.m3u8",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
            bodyData: Data("""
            #EXTM3U
            #EXTINF:6.0,
            https://video.example.com/seg-1.ts?token=abc&expires=123
            """.utf8)
        )

        let segmentSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/seg-1.ts?expires=123&token=abc",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp2t")]
        )

        let correlation = HLSManifestCorrelationResolver.correlate(session: segmentSession, within: [manifestSession, segmentSession])

        XCTAssertEqual(correlation?.referenceKind, .mediaSegment)
        XCTAssertEqual(correlation?.matches.first?.strategy, .exactURL)
    }

    func testReturnsNilWhenNoMatchingManifestExists() {
        let segmentSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/orphan-seg.ts",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp2t")]
        )

        let correlation = HLSManifestCorrelationResolver.correlate(session: segmentSession, within: [segmentSession])

        XCTAssertNil(correlation)
    }

    private func makeSession(
        id: UUID,
        host: String,
        path: String,
        responseHeaders: [HTTPHeaderField],
        bodyData: Data? = nil
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: host,
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: responseHeaders,
                bodyData: bodyData,
                bodySize: bodyData?.count,
                source: .upstream
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }
}
