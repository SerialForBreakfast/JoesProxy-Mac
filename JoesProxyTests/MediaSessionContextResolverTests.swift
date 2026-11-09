import Foundation
import XCTest
@testable import JoesProxy

final class MediaSessionContextResolverTests: XCTestCase {
    func testHLSManifestSessionGetsManifestLabel() {
        let session = makeSession(
            path: "/video/master.m3u8",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")]
        )

        let labels = MediaSessionContextResolver.labels(for: session, structure: nil)

        XCTAssertTrue(labels.contains(where: { $0.title == "Manifest" }))
        XCTAssertTrue(labels.contains(where: { $0.title == "Streaming Context" }))
    }

    func testHLSDiscoverySessionGetsAPIDiscoveredLabel() {
        let payload = """
        {"streamingUrl":"https://cdn.example.com/master.m3u8"}
        """.data(using: .utf8)
        let session = makeSession(
            host: "irdeto-control.example.com",
            path: "/session-token",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: payload
        )

        let labels = MediaSessionContextResolver.labels(for: session, structure: nil)

        XCTAssertTrue(labels.contains(where: { $0.title == "API-Discovered Stream" }))
    }

    func testInitializationAssetGetsInitSegmentLabel() {
        let session = makeSession(path: "/video/init.mp4")
        let structure = BinaryMediaStructure(
            kind: .isoBMFF,
            role: .initializationAsset,
            bytesInspected: 1024,
            notes: [],
            tsPacketSize: nil,
            tsSyncPacketCount: nil,
            tsProgramNumbers: [],
            tsStreamTypeCodes: [],
            scte35PIDPresent: false,
            topLevelBoxes: [.init(type: "ftyp", size: 24), .init(type: "moov", size: 80)],
            likelyFragmented: false,
            likelyEncrypted: false,
            segmentIndexPresent: false,
            eventMessagePresent: false,
            eventMessages: [],
            psshCount: 0
        )

        let labels = MediaSessionContextResolver.labels(for: session, structure: structure)

        XCTAssertTrue(labels.contains(where: { $0.title == "Init Segment" }))
    }

    func testMediaFragmentGetsMediaSegmentLabel() {
        let session = makeSession(path: "/video/seg-1.m4s")
        let structure = BinaryMediaStructure(
            kind: .isoBMFF,
            role: .mediaFragment,
            bytesInspected: 2048,
            notes: [],
            tsPacketSize: nil,
            tsSyncPacketCount: nil,
            tsProgramNumbers: [],
            tsStreamTypeCodes: [],
            scte35PIDPresent: false,
            topLevelBoxes: [.init(type: "moof", size: 64), .init(type: "mdat", size: 512)],
            likelyFragmented: true,
            likelyEncrypted: false,
            segmentIndexPresent: true,
            eventMessagePresent: false,
            eventMessages: [],
            psshCount: 0
        )

        let labels = MediaSessionContextResolver.labels(for: session, structure: structure)

        XCTAssertTrue(labels.contains(where: { $0.title == "Media Segment" }))
        XCTAssertTrue(labels.contains(where: { $0.title == "Streaming Context" }))
    }

    private func makeSession(
        host: String = "video.example.com",
        path: String,
        responseHeaders: [HTTPHeaderField] = [HTTPHeaderField(name: "Content-Type", value: "video/mp4")],
        bodyData: Data? = nil
    ) -> SessionRecord {
        SessionRecord(
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
