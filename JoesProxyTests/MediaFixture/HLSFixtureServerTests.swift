import Foundation
import XCTest
@testable import JoesProxy

final class HLSFixtureServerTests: XCTestCase {
    func testPreparedSwitchPreservesPublishedURLsSequencesAndThenCompletes() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/hls-switch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nvideo/stream.m3u8\n"
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\na.ts\n#EXTINF:6,\nb.ts\n#EXT-X-ENDLIST\n"
        for name in ["original", "replacement"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("video"), withIntermediateDirectories: true)
            try Data(master.utf8).write(to: directory.appendingPathComponent("master.m3u8"))
            try Data(playlist.utf8).write(to: directory.appendingPathComponent("video/stream.m3u8"))
            for segment in ["a", "b"] {
                try Data("\(name)-\(segment)".utf8).write(to: directory.appendingPathComponent("video/\(segment).ts"))
            }
        }
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        var instant = anchor.addingTimeInterval(7)
        var config = HLSPlaybackConfiguration.conformant
        config.presentationMode = .liveLoop
        config.timeShiftMode = .warmDVR
        let server = HLSFixtureServer(profileDirectory: root.appendingPathComponent("original"), startedAt: anchor,
            playbackConfiguration: config, clock: { instant })
        let id = UUID()
        try await server.prepareSwitch(id: id, directory: root.appendingPathComponent("replacement"))
        let before = try XCTUnwrap(server.slidingWindow(forPath: "video/stream.m3u8"))
        try server.switchPrepared(id: id)
        XCTAssertEqual(server.slidingWindow(forPath: "video/stream.m3u8")?.entries, before.entries)
        XCTAssertThrowsError(try server.switchPrepared(id: id), "Repeating a publication switch must not move its boundary")
        instant = anchor.addingTimeInterval(12)
        let after = try XCTUnwrap(server.slidingWindow(forPath: "video/stream.m3u8"))
        XCTAssertEqual(after.newestPublishedSequence, before.newestPublishedSequence! + 1)
        let last = try XCTUnwrap(after.entries.last)
        XCTAssertTrue(last.segment.hasDiscontinuityBefore)
        let servedPath = "/__jp_media/\(id.uuidString)/video/a.ts?jp_hls_sequence=\(last.virtualIndex)"
        XCTAssertEqual(server.response(forPath: servedPath, method: "GET", rangeHeader: nil).body, Data("replacement-a".utf8))
        XCTAssertEqual(server.response(forPath: servedPath, method: "GET", rangeHeader: "bytes=0-2").body, Data("rep".utf8))
        let old = try XCTUnwrap(before.entries.last)
        XCTAssertEqual(server.response(forPath: "/video/\(old.segment.uri)?jp_hls_sequence=\(old.virtualIndex)", method: "GET", rangeHeader: nil).status, 200)
        let forged = server.response(forPath: "/__jp_media/\(id.uuidString)/video/a.ts?jp_hls_sequence=500", method: "GET", rangeHeader: nil)
        XCTAssertEqual(forged.status, 404)
        var observedDiscontinuities: [Int: Int] = [:]
        for tick in 1...8 {
            instant = anchor.addingTimeInterval(Double(tick * 6 + 1))
            let window = try XCTUnwrap(server.slidingWindow(forPath: "video/stream.m3u8"))
            var sequence = window.discontinuitySequence
            for entry in window.entries {
                if entry.segment.hasDiscontinuityBefore || entry.isLoopBoundaryBefore { sequence += 1 }
                if let previous = observedDiscontinuities[entry.virtualIndex] {
                    XCTAssertEqual(sequence, previous, "Switch changed a published segment's discontinuity number")
                }
                observedDiscontinuities[entry.virtualIndex] = sequence
            }
        }
        instant = anchor.addingTimeInterval(48)
        let later = try XCTUnwrap(server.slidingWindow(forPath: "video/stream.m3u8"))
        XCTAssertGreaterThan(later.mediaSequence, after.mediaSequence)
        XCTAssertGreaterThan(later.discontinuitySequence, after.discontinuitySequence)
        try server.completeLive()
        let final = server.response(forPath: "video/stream.m3u8", method: "GET", rangeHeader: nil)
        instant = anchor.addingTimeInterval(600)
        XCTAssertEqual(server.response(forPath: "video/stream.m3u8", method: "GET", rangeHeader: nil), final)
        XCTAssertEqual(server.response(forPath: servedPath, method: "GET", rangeHeader: nil).body, Data("replacement-a".utf8))
        XCTAssertThrowsError(try server.switchPrepared(id: id))
        XCTAssertEqual(server.response(forPath: "/video/\(old.segment.uri)?jp_hls_sequence=\(old.virtualIndex)", method: "GET", rangeHeader: nil).status, 200,
            "Earlier phase URLs remain available beyond the ordinary sliding eviction grace")
    }

    func testLiveCompletionFreezesEveryRenditionAndRetainsExactAdvertisedMedia() throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        var instant = anchor.addingTimeInterval(25)
        var config = HLSPlaybackConfiguration.conformant
        config.presentationMode = .liveLoop
        config.timeShiftMode = .warmDVR
        let server = HLSFixtureServer(profileDirectory: baselineProfileDirectory(), startedAt: anchor,
            playbackConfiguration: config, clock: { instant })
        let paths = ["video-lo/stream.m3u8", "audio-en/stream.m3u8"]
        let before = try paths.map { try XCTUnwrap(server.slidingWindow(forPath: $0)) }
        try server.completeLive()
        let completed = paths.map { server.response(forPath: $0, method: "GET", rangeHeader: nil) }
        let completion = try XCTUnwrap(server.completionTime)
        instant = instant.addingTimeInterval(600)
        try server.completeLive()
        XCTAssertEqual(server.completionTime, completion, "Repeated completion cannot move the final media edge")
        for (index, path) in paths.enumerated() {
            let window = try XCTUnwrap(server.slidingWindow(forPath: path))
            XCTAssertEqual(window.entries, before[index].entries)
            XCTAssertEqual(window.mediaSequence, before[index].mediaSequence)
            XCTAssertEqual(window.discontinuitySequence, before[index].discontinuitySequence)
            XCTAssertTrue(window.isComplete)
            let later = server.response(forPath: path, method: "GET", rangeHeader: nil)
            XCTAssertEqual(completed[index], later)
            XCTAssertTrue(String(decoding: later.body, as: UTF8.self).hasSuffix("#EXT-X-ENDLIST\n"))
            XCTAssertFalse(String(decoding: later.body, as: UTF8.self).contains("#EXT-X-PLAYLIST-TYPE:VOD"))
            let head = server.response(forPath: path, method: "HEAD", rangeHeader: nil)
            XCTAssertTrue(head.body.isEmpty)
            XCTAssertEqual(head.headers["Content-Length"], String(later.body.count))
            let directory = (path as NSString).deletingLastPathComponent
            for entry in window.entries {
                let asset = "\(directory)/\(entry.segment.uri)"
                let retained = server.response(forPath: "\(asset)?jp_hls_sequence=\(entry.virtualIndex)", method: "GET", rangeHeader: nil)
                XCTAssertEqual(retained.status, 200)
                XCTAssertEqual(retained.body, server.response(forPath: asset, method: "GET", rangeHeader: nil).body)
            }
        }
        let future = server.response(forPath: "video-lo/seg-000.ts?jp_hls_sequence=600", method: "GET", rangeHeader: nil)
        XCTAssertEqual(future.status, 404)
    }

    func testCompletionRejectsVODAndUnreviewedPublicationFaults() throws {
        var config = HLSPlaybackConfiguration.conformant
        config.presentationMode = .vodStatic
        let vod = HLSFixtureServer(profileDirectory: baselineProfileDirectory(), playbackConfiguration: config)
        XCTAssertThrowsError(try vod.completeLive())
        config.presentationMode = .liveLoop
        config.jitPublicationState = .playlistPresentSegmentPending
        let jit = HLSFixtureServer(profileDirectory: baselineProfileDirectory(), playbackConfiguration: config)
        XCTAssertThrowsError(try jit.completeLive())
        XCTAssertNil(jit.completionTime)
    }

    private func baselineProfileDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MediaFixture/
            .deletingLastPathComponent() // JoesProxyTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Fixtures/HLS/baseline-aligned-codecs")
    }

    private func sixSecondProfileDirectory() -> URL {
        baselineProfileDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("sdr-six-second-positive-v1")
    }

    private func makeServer(clock: @escaping () -> Date = Date.init) throws -> HLSFixtureServer {
        let dir = baselineProfileDirectory()
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("Fixtures/HLS/baseline-aligned-codecs not present — run generate-profile.sh first.")
        }
        return HLSFixtureServer(profileDirectory: dir, startedAt: Date(), clock: clock)
    }

    // MARK: - Pure response computation (no real network)

    func testServesMasterPlaylistVerbatimWithCorrectContentType() throws {
        let server = try makeServer()
        try XCTSkipUnless(server.isRunning == false) // sanity: not started yet
        let response = server.response(forPath: "/master.m3u8", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/vnd.apple.mpegurl")
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains("#EXT-X-STREAM-INF"))
        XCTAssertTrue(text.contains("CODECS="))
    }

    func testHEADRequestOmitsBodyButReportsContentLength() throws {
        let server = try makeServer()
        let response = server.response(forPath: "/master.m3u8", method: "HEAD", rangeHeader: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertNotNil(response.headers["Content-Length"])
        XCTAssertNotEqual(response.headers["Content-Length"], "0")
    }

    func testUnknownPathReturns404() throws {
        let server = try makeServer()
        let response = server.response(forPath: "/does-not-exist.ts", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 404)
    }

    func testPathTraversalIsRejected() throws {
        let server = try makeServer()
        let response = server.response(forPath: "/../../../../etc/passwd", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 404)
    }

    func testUnsupportedMethodReturns405() throws {
        let server = try makeServer()
        let response = server.response(forPath: "/master.m3u8", method: "POST", rangeHeader: nil)
        XCTAssertEqual(response.status, 405)
    }

    func testServesSegmentFileBytesWithCorrectContentType() throws {
        let server = try makeServer()
        let response = server.response(forPath: "/video-lo/seg-000.ts", method: "GET", rangeHeader: nil)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "video/mp2t")
        XCTAssertFalse(response.body.isEmpty)
    }

    func testRangeRequestReturnsPartialContent() throws {
        let server = try makeServer()
        let full = server.response(forPath: "/video-lo/seg-000.ts", method: "GET", rangeHeader: nil)
        let partial = server.response(forPath: "/video-lo/seg-000.ts", method: "GET", rangeHeader: "bytes=0-99")
        XCTAssertEqual(partial.status, 206)
        XCTAssertEqual(partial.body.count, 100)
        XCTAssertEqual(partial.headers["Content-Range"], "bytes 0-99/\(full.body.count)")
        XCTAssertEqual(Data(partial.body), full.body.prefix(100))
    }

    func testStreamPlaylistReflectsInjectedClockNotWallClock() throws {
        var currentTime = Date()
        let server = try makeServer(clock: { currentTime })
        let atStart = server.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
        currentTime = currentTime.addingTimeInterval(9)
        let later = server.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
        let startText = String(decoding: atStart.body, as: UTF8.self)
        let laterText = String(decoding: later.body, as: UTF8.self)
        XCTAssertTrue(startText.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertNotEqual(startText, laterText)
    }

    func testLegacyServerReplacesAuthoredVODMarkersWithSlidingLiveMarkers() throws {
        let sourceURL = baselineProfileDirectory().appendingPathComponent("video-lo/stream.m3u8")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(source.contains("#EXT-X-ENDLIST"))

        let server = try makeServer()
        let response = server.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
        let served = String(decoding: response.body, as: UTF8.self)

        XCTAssertTrue(served.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertFalse(served.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertFalse(served.contains("#EXT-X-ENDLIST"))
    }

    func testVODStaticServesAuthoredPlaylistBytesIndependentOfClock() throws {
        let sourceURL = baselineProfileDirectory().appendingPathComponent("video-lo/stream.m3u8")
        let authored = try Data(contentsOf: sourceURL)
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .vodStatic
        let server = HLSFixtureServer(
            profileDirectory: baselineProfileDirectory(),
            startedAt: currentTime,
            playbackConfiguration: configuration,
            clock: { currentTime }
        )

        let initial = server.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
        currentTime = currentTime.addingTimeInterval(60)
        let later = server.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
        let head = server.response(forPath: "/video-lo/stream.m3u8", method: "HEAD", rangeHeader: nil)

        XCTAssertEqual(initial.body, authored)
        XCTAssertEqual(later.body, authored)
        XCTAssertEqual(initial.headers["Content-Length"], "\(authored.count)")
        XCTAssertEqual(head.headers["Content-Length"], "\(authored.count)")
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertNil(server.slidingWindow(forPath: "video-lo/stream.m3u8"))
        guard case .vod(let parsed, let playlistText) = server.playlistPreview(
            forPath: "video-lo/stream.m3u8",
            now: currentTime.addingTimeInterval(500)
        ) else {
            return XCTFail("Expected a mode-aware VOD preview")
        }
        XCTAssertEqual(playlistText, String(decoding: authored, as: UTF8.self))
        XCTAssertFalse(parsed.segments.isEmpty)
    }

    func testLiveLoopPreviewAndHTTPUseTheSamePublishedWindow() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let evaluationTime = startedAt.addingTimeInterval(4)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        let server = HLSFixtureServer(
            profileDirectory: baselineProfileDirectory(),
            startedAt: startedAt,
            playbackConfiguration: configuration,
            clock: { evaluationTime }
        )

        let window = try XCTUnwrap(
            server.slidingWindow(forPath: "video-lo/stream.m3u8", now: evaluationTime)
        )
        let response = server.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)

        XCTAssertEqual(window.newestPublishedSequence, 4)
        XCTAssertEqual(window.entries.map(\.virtualIndex), [1, 2, 3, 4])
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), HLSSlidingPlaylistComputer.render(window))
        for entry in window.entries {
            let separator = entry.segment.uri.contains("?") ? "&" : "?"
            let virtualPath = "/video-lo/\(entry.segment.uri)\(separator)jp_hls_sequence=\(entry.virtualIndex)"
            let virtualResponse = server.response(forPath: virtualPath, method: "GET", rangeHeader: nil)
            let immutableResponse = server.response(
                forPath: "/video-lo/\(entry.segment.uri)",
                method: "GET",
                rangeHeader: nil
            )
            XCTAssertEqual(virtualResponse.status, 200)
            XCTAssertEqual(virtualResponse.body, immutableResponse.body)
        }
    }

    func testConfiguredServerAppliesPlaylistControlsAndStillResolvesVirtualSegmentQuery() throws {
        let dir = baselineProfileDirectory()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.playlistCachePolicy = .maxAge
        configuration.playlistMaxAgeSeconds = 12
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let server = HLSFixtureServer(
            profileDirectory: dir,
            startedAt: startedAt,
            playbackConfiguration: configuration,
            clock: { startedAt.addingTimeInterval(25) }
        )

        let playlist = server.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
        let text = String(decoding: playlist.body, as: UTF8.self)
        XCTAssertEqual(playlist.headers["Cache-Control"], "max-age=12")
        XCTAssertTrue(text.contains("?jp_hls_sequence="))
        XCTAssertTrue(text.contains("#EXT-X-DISCONTINUITY"))

        let segment = server.response(
            forPath: "/video-lo/seg-000.ts?jp_hls_sequence=6",
            method: "GET",
            rangeHeader: nil
        )
        let immutableSource = server.response(
            forPath: "/video-lo/seg-000.ts",
            method: "GET",
            rangeHeader: nil
        )
        XCTAssertEqual(segment.status, 200)
        XCTAssertEqual(segment.headers["Content-Type"], immutableSource.headers["Content-Type"])
        XCTAssertEqual(segment.headers["Content-Length"], immutableSource.headers["Content-Length"])
        XCTAssertEqual(segment.body, immutableSource.body)
    }

    func testWarmDVRRetainsRecentlyEvictedVirtualSegmentThenReturnsStable404() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = startedAt.addingTimeInterval(4)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .warmDVR
        configuration.windowSegmentCount = 2
        let server = HLSFixtureServer(
            profileDirectory: baselineProfileDirectory(),
            startedAt: startedAt,
            playbackConfiguration: try configuration.validated(),
            clock: { currentTime }
        )
        let virtualPath = "/video-lo/seg-000.ts?jp_hls_sequence=0"

        XCTAssertEqual(
            server.response(forPath: virtualPath, method: "GET", rangeHeader: nil).status,
            200
        )
        XCTAssertEqual(
            server.oldestRetainedButEvictedSequence(forPath: "video-lo/stream.m3u8"),
            0
        )

        currentTime = startedAt.addingTimeInterval(16.001)
        XCTAssertEqual(
            server.response(forPath: virtualPath, method: "GET", rangeHeader: nil).status,
            404
        )
        XCTAssertEqual(
            server.response(forPath: virtualPath, method: "GET", rangeHeader: nil).status,
            404
        )
        XCTAssertEqual(
            server.response(forPath: "/video-lo/seg-000.ts", method: "GET", rangeHeader: nil).status,
            200
        )
    }

    func testColdDVRRejectsUnpublishedVirtualSegmentButKeepsImmutableAssetAvailable() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .coldDVR
        configuration.windowSegmentCount = 4
        let server = HLSFixtureServer(
            profileDirectory: baselineProfileDirectory(),
            startedAt: startedAt,
            playbackConfiguration: try configuration.validated(),
            clock: { startedAt }
        )

        XCTAssertEqual(
            server.response(
                forPath: "/video-lo/seg-000.ts?jp_hls_sequence=0",
                method: "GET",
                rangeHeader: nil
            ).status,
            404
        )
        XCTAssertEqual(
            server.response(forPath: "/video-lo/seg-000.ts", method: "GET", rangeHeader: nil).status,
            200
        )
        let playlist = server.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
        XCTAssertEqual(playlist.status, 200)
        XCTAssertFalse(String(decoding: playlist.body, as: UTF8.self).contains("#EXTINF:"))
    }

    func testSlidingWindowPreviewMatchesResponseForPath() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = startedAt.addingTimeInterval(12)
        let dir = baselineProfileDirectory()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))
        let server = HLSFixtureServer(profileDirectory: dir, startedAt: startedAt, clock: { currentTime })

        let window = try XCTUnwrap(server.slidingWindow(forPath: "video-lo/stream.m3u8", now: currentTime))
        let previewText = HLSSlidingPlaylistComputer.render(window)
        let live = server.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
        let liveText = String(decoding: live.body, as: UTF8.self)

        XCTAssertEqual(previewText, liveText)
        XCTAssertTrue(previewText.contains("#EXT-X-MEDIA-SEQUENCE:\(window.mediaSequence)"))
        XCTAssertTrue(previewText.contains("#EXT-X-DISCONTINUITY-SEQUENCE:\(window.discontinuitySequence)"))
        XCTAssertFalse(window.entries.isEmpty)

        currentTime = startedAt.addingTimeInterval(0)
        let earlyWindow = try XCTUnwrap(server.slidingWindow(forPath: "video-lo/stream.m3u8", now: currentTime))
        let earlyLive = server.response(forPath: "video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
        XCTAssertEqual(
            HLSSlidingPlaylistComputer.render(earlyWindow),
            String(decoding: earlyLive.body, as: UTF8.self)
        )
        XCTAssertEqual(earlyWindow.mediaSequence, 0)
    }

    func testSlidingWindowPreviewRejectsMasterAndTraversal() throws {
        let server = try makeServer()
        XCTAssertNil(server.slidingWindow(forPath: "master.m3u8"))
        XCTAssertNil(server.slidingWindow(forPath: "../etc/passwd"))
        XCTAssertNil(server.slidingWindow(forPath: "video-lo/seg-000.ts"))
    }

    // MARK: - Real NIO integration (one live round trip)

    func testLiveServerAnswersRealHTTPRequestOverLoopback() async throws {
        let server = try makeServer()
        try await server.start()
        defer { Task { await server.stop() } }
        let baseURL = try XCTUnwrap(server.baseURL)

        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("master.m3u8"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("#EXTM3U"))

        let (segmentData, segmentResponse) = try await URLSession.shared.data(
            from: baseURL.appendingPathComponent("video-lo/seg-000.ts")
        )
        let segmentHTTP = try XCTUnwrap(segmentResponse as? HTTPURLResponse)
        XCTAssertEqual(segmentHTTP.statusCode, 200)
        XCTAssertFalse(segmentData.isEmpty)
    }

    func testSixSecondPositiveControlServesSixEntryRepeatedLoopOverRealOrigin() async throws {
        let directory = sixSecondProfileDirectory()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.path))
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let evaluationTime = startedAt.addingTimeInterval(66)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.windowSegmentCount = 6
        let server = HLSFixtureServer(
            profileDirectory: directory,
            startedAt: startedAt,
            playbackConfiguration: configuration,
            clock: { evaluationTime }
        )
        try await server.start()
        defer { Task { await server.stop() } }
        let baseURL = try XCTUnwrap(server.baseURL)

        let playlistURL = baseURL
            .appendingPathComponent("video-1080")
            .appendingPathComponent("stream.m3u8")
        let (playlistData, playlistResponse) = try await URLSession.shared.data(from: playlistURL)
        XCTAssertEqual((playlistResponse as? HTTPURLResponse)?.statusCode, 200)
        let playlistText = String(decoding: playlistData, as: UTF8.self)
        let playlist = HLSParser.parse(playlistText, baseURL: playlistURL)
        XCTAssertEqual(playlist.segmentCount, 6)
        XCTAssertEqual(playlist.targetDuration, 6)
        XCTAssertEqual(playlist.programDateTimes.count, 1)
        XCTAssertTrue(playlistText.split(separator: "\n").contains("#EXT-X-DISCONTINUITY"))

        let window = try XCTUnwrap(
            server.slidingWindow(forPath: "video-1080/stream.m3u8", now: evaluationTime)
        )
        XCTAssertEqual(window.entries.map(\.virtualIndex), [11, 12, 13, 14, 15, 16])
        XCTAssertEqual(window.newestPublishedSequence, 16)
        for segment in playlist.segments {
            let segmentURL = try XCTUnwrap(URL(string: segment.uri))
            let (segmentData, segmentResponse) = try await URLSession.shared.data(from: segmentURL)
            XCTAssertEqual((segmentResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertFalse(segmentData.isEmpty)
        }
    }

    func testSixSecondWarmDVRRenditionsDescribeTheSameNinetySecondInterval() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let evaluationTime = startedAt.addingTimeInterval(24)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .warmDVR
        configuration.windowSegmentCount = 15
        let server = HLSFixtureServer(
            profileDirectory: sixSecondProfileDirectory(),
            startedAt: startedAt,
            playbackConfiguration: try configuration.validated(),
            clock: { evaluationTime }
        )
        let paths = [
            "video-360/stream.m3u8",
            "video-720/stream.m3u8",
            "video-1080/stream.m3u8",
            "audio-en/stream.m3u8"
        ]
        let windows = try paths.map { path in
            try XCTUnwrap(server.slidingWindow(forPath: path, now: evaluationTime))
        }

        XCTAssertTrue(windows.allSatisfy { $0.oldestAdvertisedSequence == 4 })
        XCTAssertTrue(windows.allSatisfy { $0.newestPublishedSequence == 18 })
        XCTAssertTrue(windows.allSatisfy { abs($0.advertisedDuration - 90) < 0.1 })
        guard let baselineEarliest = windows[0].earliestProgramDateTime,
              let baselineLiveEdge = windows[0].liveEdgeProgramDateTime else {
            return XCTFail("Missing program date time in baseline window")
        }
        for window in windows {
            guard let earliest = window.earliestProgramDateTime,
                  let liveEdge = window.liveEdgeProgramDateTime else {
                return XCTFail("Missing program date time in window")
            }
            XCTAssertLessThan(abs(earliest.timeIntervalSince(baselineEarliest)), 0.1)
            XCTAssertLessThan(abs(liveEdge.timeIntervalSince(baselineLiveEdge)), 0.1)
        }
    }
}
