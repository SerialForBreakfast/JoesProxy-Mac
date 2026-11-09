import XCTest
@testable import JoesProxy

final class MediaSessionContextResolverCorrelationTests: XCTestCase {
    func testVideoSessionAddsReferencedByCapturedManifestLabelWhenCorrelationExists() {
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "video.example.com",
                port: 443,
                path: "/seg-2.m4s",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")],
                bodyData: nil,
                bodySize: nil
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )

        let structure = BinaryMediaStructure(
            kind: .isoBMFF,
            role: .mediaFragment,
            bytesInspected: 1024,
            notes: [],
            tsPacketSize: nil,
            tsSyncPacketCount: nil,
            tsProgramNumbers: [],
            tsStreamTypeCodes: [],
            scte35PIDPresent: false,
            topLevelBoxes: [],
            likelyFragmented: true,
            likelyEncrypted: false,
            segmentIndexPresent: false,
            eventMessagePresent: false,
            eventMessages: [],
            psshCount: 0
        )
        let correlation = HLSManifestCorrelation(
            referenceKind: .mediaSegment,
            matches: [
                ManifestReferenceMatch(
                    manifestSessionID: UUID(),
                    manifestHost: "video.example.com",
                    manifestPath: "/media.m3u8",
                    matchedReference: "https://video.example.com/seg-2.m4s",
                    strategy: .exactURL
                )
            ]
        )

        let labels = MediaSessionContextResolver.labels(
            for: session,
            structure: structure,
            hlsManifestCorrelation: correlation
        )

        XCTAssertTrue(labels.contains(where: { $0.title == "Referenced By Captured HLS Manifest" }))
    }

    func testVideoSessionAddsReferencedByCapturedDashManifestLabelWhenCorrelationExists() {
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "video.example.com",
                port: 443,
                path: "/chunk-27.m4s",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")],
                bodyData: nil,
                bodySize: nil
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )

        let structure = BinaryMediaStructure(
            kind: .isoBMFF,
            role: .mediaFragment,
            bytesInspected: 1024,
            notes: [],
            tsPacketSize: nil,
            tsSyncPacketCount: nil,
            tsProgramNumbers: [],
            tsStreamTypeCodes: [],
            scte35PIDPresent: false,
            topLevelBoxes: [],
            likelyFragmented: true,
            likelyEncrypted: false,
            segmentIndexPresent: false,
            eventMessagePresent: false,
            eventMessages: [],
            psshCount: 0
        )
        let correlation = DASHManifestCorrelation(
            referenceKind: .mediaSegment,
            matches: [
                ManifestReferenceMatch(
                    manifestSessionID: UUID(),
                    manifestHost: "video.example.com",
                    manifestPath: "/manifest.mpd",
                    matchedReference: "chunk-$Number$.m4s",
                    strategy: .templatePattern
                )
            ]
        )

        let labels = MediaSessionContextResolver.labels(
            for: session,
            structure: structure,
            dashManifestCorrelation: correlation
        )

        XCTAssertTrue(labels.contains(where: { $0.title == "Referenced By Captured DASH Manifest" }))
    }
}
