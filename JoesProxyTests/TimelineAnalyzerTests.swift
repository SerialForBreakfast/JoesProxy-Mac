import XCTest
import zlib
@testable import JoesProxy

final class TimelineAnalyzerTests: XCTestCase {
    func testClassifiesCoreTimelineLanes() {
        let start = Date()
        let sessions = [
            makeSession(path: "/apps-api/v3.1/playback.json", contentType: "application/json", start: start),
            makeSession(path: "/master.m3u8", contentType: "application/vnd.apple.mpegurl", start: start.addingTimeInterval(1)),
            makeSession(path: "/fairplay/license", contentType: "application/octet-stream", start: start.addingTimeInterval(2)),
            makeSession(path: "/segment-01.ts", contentType: "video/mp2t", start: start.addingTimeInterval(3)),
            makeSession(path: "/poster.jpg", contentType: "image/jpeg", start: start.addingTimeInterval(4)),
            makeSession(host: "mobile-collector.newrelic.com", path: "/mobile/v3/data", start: start.addingTimeInterval(5)),
            makeSession(path: "/broken", statusCode: 500, start: start.addingTimeInterval(6))
        ]

        let result = JoesProxy.TimelineAnalyzer().analyze(sessions: sessions)

        let lanes: [JoesProxy.TimelineLane] = result.events.map { $0.lane }
        XCTAssertEqual(
            lanes,
            [.api, .manifest, .drmLicense, .mediaSegments, .imagesAssets, .adsAnalytics, .errorsRetries]
        )
    }

    func testGzipJSONHintMarksPlaybackAPIAndDecodedLabel() throws {
        let json = #"{"streamingUrl":"https://cdn.example.com/master.m3u8"}"#.data(using: .utf8)!
        let body = try XCTUnwrap(gzipCompress(json))
        let session = makeSession(
            path: "/playback/player.json",
            contentType: "application/json",
            headers: [HTTPHeaderField(name: "Content-Encoding", value: "gzip")],
            bodyData: body
        )

        let result = JoesProxy.TimelineAnalyzer().analyze(sessions: [session])
        let event = try XCTUnwrap(result.events.first)

        XCTAssertEqual(event.lane, .api)
        XCTAssertTrue(event.labels.contains(.playbackAPI))
        XCTAssertTrue(event.labels.contains(.manifest))
        XCTAssertTrue(event.labels.contains(.gzipDecoded))
        XCTAssertNil(Mirror(reflecting: event).children.first { $0.label == "bodyData" })
    }

    func testBodyHintingSkipsAnalyticsAndLargeJSON() throws {
        let playbackJSON = #"{"streamingUrl":"https://cdn.example.com/master.m3u8"}"#
        let analytics = makeSession(
            host: "mobile-collector.newrelic.com",
            path: "/mobile/v3/data",
            contentType: "application/json",
            bodyData: Data(playbackJSON.utf8)
        )
        let largePlayback = makeSession(
            path: "/playback/player.json",
            contentType: "application/json",
            bodyData: Data(repeating: UInt8(ascii: "a"), count: 70 * 1024)
        )

        let result = JoesProxy.TimelineAnalyzer().analyze(sessions: [analytics, largePlayback])

        let analyticsEvent = try XCTUnwrap(result.events.first { $0.sessionID == analytics.id })
        XCTAssertEqual(analyticsEvent.lane, .adsAnalytics)
        XCTAssertFalse(analyticsEvent.labels.contains(.playbackAPI))
        XCTAssertFalse(analyticsEvent.labels.contains(.gzipDecoded))

        let largeEvent = try XCTUnwrap(result.events.first { $0.sessionID == largePlayback.id })
        XCTAssertEqual(largeEvent.lane, .api)
        XCTAssertFalse(largeEvent.labels.contains(.playbackAPI))
    }

    func testGapDetectionFindsIdleAndMediaGaps() {
        let start = Date()
        let sessions = [
            makeSession(path: "/api/start.json", start: start, duration: 0.1),
            makeSession(path: "/api/next.json", start: start.addingTimeInterval(3.5), duration: 0.1),
            makeSession(path: "/segment-01.ts", contentType: "video/mp2t", start: start.addingTimeInterval(4), duration: 0.2),
            makeSession(path: "/segment-02.ts", contentType: "video/mp2t", start: start.addingTimeInterval(9), duration: 0.2)
        ]

        let result = JoesProxy.TimelineAnalyzer().analyze(sessions: sessions)

        XCTAssertTrue(result.gaps.contains { $0.reason == .idle && $0.duration > 3 })
        XCTAssertTrue(result.gaps.contains { $0.reason == .mediaSegmentGap && $0.duration > 4 })
        XCTAssertTrue(result.findings.contains { $0.title.contains("Segment gap") })
    }

    func testAroundSelectedFilterLimitsVisibleEvents() {
        let start = Date()
        let selected = makeSession(path: "/api/selected.json", start: start.addingTimeInterval(10))
        let sessions = [
            makeSession(path: "/api/early.json", start: start),
            selected,
            makeSession(path: "/api/near.json", start: start.addingTimeInterval(14)),
            makeSession(path: "/api/late.json", start: start.addingTimeInterval(20))
        ]

        let result = JoesProxy.TimelineAnalyzer().analyze(
            sessions: sessions,
            filter: JoesProxy.TimelineFilterState(aroundSelection: .fiveSeconds),
            selectedSessionID: selected.id
        )

        XCTAssertEqual(result.visibleEvents.map(\.pathSummary), ["/api/selected.json", "/api/near.json"])
    }

    func testPinsSurviveFiltersAndPinnedOnly() {
        let first = makeSession(path: "/api/first.json")
        let second = makeSession(path: "/api/second.json")

        let result = JoesProxy.TimelineAnalyzer().analyze(
            sessions: [first, second],
            filter: JoesProxy.TimelineFilterState(pinnedOnly: true),
            pins: [.request(second.id)]
        )

        XCTAssertEqual(result.visibleEvents.map(\.sessionID), [second.id])
        XCTAssertTrue(result.visibleEvents[0].labels.contains(.pinned))
    }

    func testAnalysisCacheReusesEventsAndPinChangesAvoidReclassification() {
        let first = makeSession(path: "/api/first.json")
        let second = makeSession(path: "/api/second.json")
        var cache = JoesProxy.TimelineAnalysisCache()

        let initial = cache.update(sessions: [first, second], pins: [])
        XCTAssertEqual(initial.classifiedCount, 2)
        XCTAssertEqual(initial.reusedCount, 0)

        let pinned = cache.update(sessions: [first, second], pins: [.request(second.id)])
        XCTAssertEqual(pinned.classifiedCount, 0)
        XCTAssertEqual(pinned.reusedCount, 2)
        XCTAssertTrue(try XCTUnwrap(pinned.events.first { $0.sessionID == second.id }).isPinned)

        let updatedSecond = makeSession(id: second.id, path: "/api/second-updated.json")
        let updated = cache.update(sessions: [first, updatedSecond], pins: [.request(second.id)])
        XCTAssertEqual(updated.classifiedCount, 1)
        XCTAssertEqual(updated.reusedCount, 1)
    }

    func testDirtyIDTrackedUpdateMatchesFullFingerprintUpdate() {
        let start = Date()
        let a = makeSession(path: "/api/a.json", start: start)
        let b = makeSession(path: "/api/b.json", start: start.addingTimeInterval(1))
        let c = makeSession(path: "/api/c.json", start: start.addingTimeInterval(2))

        var dirtyTracked = JoesProxy.TimelineAnalysisCache()
        var fingerprinted = JoesProxy.TimelineAnalysisCache()

        _ = dirtyTracked.update(sessions: [a, b], pins: [], dirtyIDs: [a.id, b.id])
        _ = fingerprinted.update(sessions: [a, b], pins: [])

        // Append c, update b, drop a — mixed append/update/drop in one pass.
        let updatedB = makeSession(id: b.id, path: "/api/b-updated.json", start: start.addingTimeInterval(1))
        let dirtyResult = dirtyTracked.update(sessions: [updatedB, c], pins: [], dirtyIDs: [updatedB.id, c.id])
        let fullResult = fingerprinted.update(sessions: [updatedB, c], pins: [])

        XCTAssertEqual(dirtyResult.events, fullResult.events)
        XCTAssertEqual(dirtyResult.classifiedCount, fullResult.classifiedCount)
        XCTAssertEqual(dirtyResult.removedCount, 1)

        // An idle pass (nothing dirty) must reuse every event without reclassifying.
        let idle = dirtyTracked.update(sessions: [updatedB, c], pins: [], dirtyIDs: [])
        XCTAssertEqual(idle.classifiedCount, 0)
        XCTAssertEqual(idle.reusedCount, 2)
        XCTAssertEqual(idle.events, fullResult.events)
    }

    func testLargeTimelineResultCapsRenderedEventsButKeepsFilteredCount() {
        let start = Date()
        let sessions = (0..<650).map { index in
            makeSession(
                path: "/api/item-\(index).json",
                start: start.addingTimeInterval(TimeInterval(index))
            )
        }

        let result = JoesProxy.TimelineAnalyzer().analyze(sessions: sessions)

        XCTAssertEqual(result.visibleEvents.count, 650)
        XCTAssertEqual(result.filteredEventCount, 650)
        XCTAssertEqual(result.renderedEventCount, JoesProxy.TimelineRenderPolicy.defaultVisibleEventLimit)
        XCTAssertEqual(result.renderedEvents.count, JoesProxy.TimelineRenderPolicy.defaultVisibleEventLimit)
        XCTAssertEqual(result.eventsByLane[.api]?.count, JoesProxy.TimelineRenderPolicy.defaultVisibleEventLimit)
        XCTAssertEqual(result.renderedEvents.first?.pathSummary, "/api/item-150.json")
        XCTAssertEqual(result.renderedEvents.last?.pathSummary, "/api/item-649.json")
    }

    func testMediaSummaryDetectsPlaybackChain() throws {
        let start = Date()
        let playbackBody = Data(#"{"streamingUrl":"https://cdn.example.com/master.m3u8"}"#.utf8)
        let playback = makeSession(
            path: "/apps-api/v3.1/dynamicplay/show.json",
            contentType: "application/json",
            bodyData: playbackBody,
            start: start
        )
        let manifest = makeSession(
            path: "/master.m3u8",
            contentType: "application/vnd.apple.mpegurl",
            start: start.addingTimeInterval(1)
        )
        let license = makeSession(
            path: "/fairplay/license",
            contentType: "application/octet-stream",
            start: start.addingTimeInterval(2)
        )
        let segment = makeSession(
            path: "/segment-01.ts",
            contentType: "video/mp2t",
            start: start.addingTimeInterval(4)
        )

        let result = JoesProxy.TimelineAnalyzer().analyze(sessions: [playback, manifest, license, segment])
        let summary: JoesProxy.MediaTimelineSummary = try XCTUnwrap(result.mediaSummary)

        XCTAssertEqual(summary.playbackAPISessionID, playback.id)
        XCTAssertEqual(summary.manifestSessionIDs, [manifest.id])
        XCTAssertEqual(summary.licenseSessionIDs, [license.id])
        XCTAssertEqual(summary.mediaSegmentSessionIDs, [segment.id])
        XCTAssertEqual(try XCTUnwrap(summary.firstManifestDelay), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.firstLicenseDelay), 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.firstSegmentDelay), 4, accuracy: 0.001)
    }

    private func makeSession(
        id: UUID = UUID(),
        method: String = "GET",
        host: String = "example.com",
        path: String,
        contentType: String = "application/json",
        statusCode: Int = 200,
        headers: [HTTPHeaderField] = [],
        bodyData: Data? = nil,
        start: Date = Date(),
        duration: TimeInterval = 0.25
    ) -> SessionRecord {
        let responseHeaders = [HTTPHeaderField(name: "Content-Type", value: contentType)] + headers
        return SessionRecord(
            id: id,
            request: CapturedRequest(
                method: method,
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
                statusCode: statusCode,
                headers: responseHeaders,
                bodyData: bodyData,
                bodySize: bodyData?.count ?? 128
            ),
            state: .completed,
            timing: SessionTiming(startedAt: start, completedAt: start.addingTimeInterval(duration))
        )
    }

    private func gzipCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else {
            return Data()
        }

        var stream = z_stream()
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bytes.baseAddress)
            stream.avail_in = uInt(data.count)
        }

        let windowBits: Int32 = 15 + 16
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            windowBits,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }

        let chunkSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var output = Data()
        var deflateStatus: Int32

        repeat {
            stream.next_out = buffer
            stream.avail_out = uInt(chunkSize)
            deflateStatus = deflate(&stream, Z_FINISH)

            guard deflateStatus == Z_OK || deflateStatus == Z_STREAM_END else {
                return nil
            }

            let produced = chunkSize - Int(stream.avail_out)
            if produced > 0 {
                output.append(buffer, count: produced)
            }
        } while deflateStatus != Z_STREAM_END

        return output
    }
}
