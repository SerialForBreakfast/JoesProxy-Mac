//
//  StreamingWaterfallEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for Streaming Quality Waterfall analysis engine.
//

import XCTest
@testable import JoesProxy

final class StreamingWaterfallEngineTests: XCTestCase {

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

    func testHLSVariantLadderExtraction() {
        let manifestSession = createSession(
            path: "/stream/master.m3u8",
            body: masterHLS.data(using: .utf8)!,
            contentType: "application/vnd.apple.mpegurl"
        )

        let report = StreamingWaterfallEngine.analyze(target: manifestSession, allSessions: [manifestSession])

        XCTAssertEqual(report.manifestKind, "HLS Master Playlist")
        XCTAssertEqual(report.bitrateLadder.count, 3)
        XCTAssertEqual(report.bitrateLadder[0].bandwidth, 800_000)
        XCTAssertEqual(report.bitrateLadder[0].resolution, "640x360")
        XCTAssertEqual(report.bitrateLadder[1].bandwidth, 2_400_000)
        XCTAssertEqual(report.bitrateLadder[1].resolution, "1280x720")
        XCTAssertEqual(report.bitrateLadder[2].bandwidth, 5_000_000)
        XCTAssertEqual(report.bitrateLadder[2].resolution, "1920x1080")
    }

    func testSegmentDownloadAndSlowSegmentDetection() {
        let now = Date()
        let manifestSession = createSession(
            path: "/stream/master.m3u8",
            body: masterHLS.data(using: .utf8)!,
            contentType: "application/vnd.apple.mpegurl",
            startedAt: now
        )

        // Fast segment: 6s media downloaded in 1.0s (healthy)
        let fastSegment = createSession(
            path: "/stream/720p/segment1.m4s",
            body: Data(repeating: 0xAA, count: 1_800_000),
            contentType: "video/mp4",
            startedAt: now.addingTimeInterval(0.5),
            duration: 1.0,
            headers: [HTTPHeaderField(name: "X-Cache", value: "HIT")]
        )

        // Slow segment: 6s media downloaded in 8.0s (bottleneck > 6.0s)
        let slowSegment = createSession(
            path: "/stream/1080p/segment2.m4s",
            body: Data(repeating: 0xBB, count: 3_750_000),
            contentType: "video/mp4",
            startedAt: now.addingTimeInterval(2.0),
            duration: 8.0,
            headers: [HTTPHeaderField(name: "X-Cache", value: "MISS")]
        )

        let allSessions = [manifestSession, fastSegment, slowSegment]
        let report = StreamingWaterfallEngine.analyze(target: manifestSession, allSessions: allSessions)

        XCTAssertEqual(report.segments.count, 2)
        XCTAssertEqual(report.slowSegmentCount, 1)
        XCTAssertTrue(report.segments[1].isSlowDownload)
        XCTAssertFalse(report.segments[0].isSlowDownload)
        XCTAssertEqual(report.segments[0].isCacheHit, true)
        XCTAssertEqual(report.segments[1].isCacheHit, false)
        XCTAssertEqual(report.cdnCacheHitRatio, 0.5)
    }

    func testQualitySwitchDetection() {
        let now = Date()
        let manifestSession = createSession(
            path: "/stream/master.m3u8",
            body: masterHLS.data(using: .utf8)!,
            contentType: "application/vnd.apple.mpegurl",
            startedAt: now
        )

        // Segment 1: 720p (2.4 Mbps)
        let seg1 = createSession(
            path: "/stream/1280x720/seg1.m4s",
            body: Data(count: 1_800_000),
            contentType: "video/mp4",
            startedAt: now.addingTimeInterval(1.0),
            duration: 1.0
        )

        // Segment 2: 1080p (5.0 Mbps) -> Step Up
        let seg2 = createSession(
            path: "/stream/1920x1080/seg2.m4s",
            body: Data(count: 3_750_000),
            contentType: "video/mp4",
            startedAt: now.addingTimeInterval(2.5),
            duration: 1.2
        )

        // Segment 3: 360p (800 kbps) -> Emergency Drop (<50% of 5 Mbps)
        let seg3 = createSession(
            path: "/stream/640x360/seg3.m4s",
            body: Data(count: 600_000),
            contentType: "video/mp4",
            startedAt: now.addingTimeInterval(4.0),
            duration: 0.5
        )

        let allSessions = [manifestSession, seg1, seg2, seg3]
        let report = StreamingWaterfallEngine.analyze(target: manifestSession, allSessions: allSessions)

        XCTAssertEqual(report.switchingEvents.count, 2)
        XCTAssertEqual(report.switchingEvents[0].switchType, .stepUp)
        XCTAssertEqual(report.switchingEvents[0].fromBandwidth, 2_400_000)
        XCTAssertEqual(report.switchingEvents[0].toBandwidth, 5_000_000)

        XCTAssertEqual(report.switchingEvents[1].switchType, .emergencyDrop)
        XCTAssertEqual(report.switchingEvents[1].fromBandwidth, 5_000_000)
        XCTAssertEqual(report.switchingEvents[1].toBandwidth, 800_000)
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
