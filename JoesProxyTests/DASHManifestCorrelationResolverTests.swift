import Foundation
import XCTest
@testable import JoesProxy

final class DASHManifestCorrelationResolverTests: XCTestCase {
    func testCorrelatesInitializationAssetFromSegmentTemplate() {
        let manifestSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/stream/manifest.mpd",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/dash+xml")],
            bodyData: Data("""
            <MPD type="static">
              <Period>
                <AdaptationSet mimeType="video/mp4">
                  <Representation id="v1" bandwidth="800000">
                    <SegmentTemplate initialization="init-$RepresentationID$.mp4" media="chunk-$Number$.m4s" startNumber="1" />
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """.utf8)
        )

        let initSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/stream/init-v1.mp4",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")]
        )

        let correlation = DASHManifestCorrelationResolver.correlate(session: initSession, within: [manifestSession, initSession])

        XCTAssertEqual(correlation?.referenceKind, .initSegment)
        XCTAssertEqual(correlation?.manifestSessionIDs, [manifestSession.id])
        XCTAssertEqual(correlation?.matches.first?.manifestPath, "/stream/manifest.mpd")
        XCTAssertEqual(correlation?.matches.first?.strategy, .exactURL)
    }

    func testCorrelatesMediaFragmentFromSegmentTemplatePattern() {
        let manifestSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/stream/manifest.mpd",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/dash+xml")],
            bodyData: Data("""
            <MPD type="dynamic">
              <Period>
                <AdaptationSet mimeType="video/mp4">
                  <Representation id="v1" bandwidth="1200000">
                    <SegmentTemplate initialization="init-$RepresentationID$.mp4" media="chunk-$Number$.m4s" startNumber="1" />
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """.utf8)
        )

        let segmentSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/stream/chunk-27.m4s",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")]
        )

        let correlation = DASHManifestCorrelationResolver.correlate(session: segmentSession, within: [manifestSession, segmentSession])

        XCTAssertEqual(correlation?.referenceKind, .mediaSegment)
        XCTAssertEqual(correlation?.manifestSessionIDs, [manifestSession.id])
        XCTAssertEqual(correlation?.matches.first?.matchedReference, "chunk-$Number$.m4s")
        XCTAssertEqual(correlation?.matches.first?.strategy, .templatePattern)
    }

    func testReturnsNilWhenNoMatchingMPDTemplateExists() {
        let segmentSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/stream/orphan-27.m4s",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")]
        )

        let correlation = DASHManifestCorrelationResolver.correlate(session: segmentSession, within: [segmentSession])

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
