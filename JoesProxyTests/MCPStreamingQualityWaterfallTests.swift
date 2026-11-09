//
//  MCPStreamingQualityWaterfallTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Streaming Quality Waterfall diagnostic reporting.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPStreamingQualityWaterfallTests: XCTestCase {

    private let masterHLS = """
    #EXTM3U
    #EXT-X-VERSION:4
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
    360p.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
    720p.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
    1080p.m3u8
    """

    func testStreamingWaterfallMCPDTO() async throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        let manifestSession = createSession(
            path: "/stream/master.m3u8",
            body: masterHLS.data(using: .utf8)!,
            contentType: "application/vnd.apple.mpegurl"
        )

        let seg1 = createSession(
            path: "/stream/720p/segment1.m4s",
            body: Data(repeating: 0xAA, count: 1_200_000),
            contentType: "video/mp4",
            duration: 0.8,
            headers: [HTTPHeaderField(name: "X-Cache", value: "HIT")]
        )

        let seg2 = createSession(
            path: "/stream/1080p/segment2.m4s",
            body: Data(repeating: 0xBB, count: 3_500_000),
            contentType: "video/mp4",
            duration: 7.5,
            headers: [HTTPHeaderField(name: "X-Cache", value: "MISS")]
        )

        store.append(manifestSession)
        store.append(seg1)
        store.append(seg2)

        let dto = try service.streamingWaterfall(
            sessionID: manifestSession.id,
            policyRevision: .initial
        )

        XCTAssertEqual(dto.manifestKind, "HLS Master Playlist")
        XCTAssertEqual(dto.bitrateLadder.count, 3)
        XCTAssertEqual(dto.segmentCount, 2)
        XCTAssertEqual(dto.slowSegmentCount, 1)
        XCTAssertEqual(dto.segments.count, 2)
        XCTAssertEqual(dto.segments[0].variantResolution, "1280x720")
        XCTAssertEqual(dto.segments[0].isCacheHit, true)
        XCTAssertEqual(dto.segments[1].isSlowDownload, true)
        XCTAssertEqual(dto.segments[1].isCacheHit, false)
        XCTAssertEqual(dto.switchingEvents.count, 1)
        XCTAssertEqual(dto.switchingEvents[0].switchType, "stepUp")
    }

    // MARK: - Helper

    private func createSession(
        path: String,
        body: Data,
        contentType: String,
        startedAt: Date = Date(),
        duration: TimeInterval = 0.5,
        headers: [HTTPHeaderField] = []
    ) -> SessionRecord {
        var allHeaders = headers
        allHeaders.append(HTTPHeaderField(name: "Content-Type", value: contentType))
        allHeaders.append(HTTPHeaderField(name: "Content-Length", value: "\(body.count)"))

        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "video.example.com",
            port: 443,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        let response = CapturedResponse(
            statusCode: 200,
            headers: allHeaders,
            bodyData: body,
            bodySize: body.count
        )

        var timing = SessionTiming(startedAt: startedAt)
        timing.completedAt = startedAt.addingTimeInterval(duration)

        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: timing
        )
    }
}
