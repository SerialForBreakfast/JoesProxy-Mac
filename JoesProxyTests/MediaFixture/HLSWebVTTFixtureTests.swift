import Foundation
import XCTest
@testable import JoesProxy

final class HLSWebVTTFixtureTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    private var directory: URL { root.appendingPathComponent("Fixtures/HLS/multilingual-text-vod-v1") }
    private var vod: HLSPlaybackConfiguration {
        var value = HLSPlaybackConfiguration.conformant
        value.presentationMode = .vodStatic
        return value
    }
    private func specification() throws -> HLSWebVTTFixture.Specification {
        try XCTUnwrap(JSONDecoder().decode(HLSFixtureProfileDescriptor.self,
            from: Data(contentsOf: directory.appendingPathComponent("profile.json"))).textFixture)
    }

    private func live(_ mode: HLSTimeShiftMode = .warmDVR) -> HLSPlaybackConfiguration {
        var value = HLSPlaybackConfiguration.conformant
        value.presentationMode = .liveLoop
        value.timeShiftMode = mode
        return value
    }

    func testLiveTextAndVideoShareEpochLoopsAndRetentionWithoutGrowingResources() async throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        var now = anchor
        let server = HLSFixtureServer(profileDirectory: directory, startedAt: anchor,
            playbackConfiguration: live(), clock: { now })
        let original = server.response(forPath: "text/en/segment-0.vtt?jp_hls_sequence=0", method: "GET", rangeHeader: nil)
        XCTAssertEqual(original.status, 200)
        XCTAssertEqual(original.textTrack?.language, "en")
        XCTAssertNil(server.response(forPath: "text/missing/stream.m3u8", method: "GET", rangeHeader: nil).textTrack)
        XCTAssertEqual(server.response(forPath: "text/en/segment-0.vtt", method: "GET", rangeHeader: nil).status, 404)
        for tick in [0, 4, 24, 48, 3600, 100_000] {
            now = anchor.addingTimeInterval(Double(tick))
            let video = try XCTUnwrap(server.slidingWindow(forPath: "video-720/stream.m3u8"))
            for track in try specification().tracks {
                let text = try XCTUnwrap(server.slidingWindow(forPath: track.playlistPath))
                XCTAssertEqual(text.mediaSequence, video.mediaSequence)
                XCTAssertEqual(text.discontinuitySequence, video.discontinuitySequence)
                XCTAssertEqual(text.firstSegmentProgramDateTime, video.firstSegmentProgramDateTime)
                XCTAssertEqual(text.entries.map(\.virtualIndex), video.entries.map(\.virtualIndex))
                XCTAssertEqual(text.entries.map(\.isLoopBoundaryBefore), video.entries.map(\.isLoopBoundaryBefore))
                let last = try XCTUnwrap(text.entries.last)
                let path = "text/\(track.id)/\(last.segment.uri)?jp_hls_sequence=\(last.virtualIndex)"
                XCTAssertEqual(server.response(forPath: path, method: "GET", rangeHeader: nil).status, 200)
                XCTAssertEqual(server.response(forPath: path, method: "HEAD", rangeHeader: nil).body.count, 0)
            }
        }
        XCTAssertEqual(server.response(forPath: "text/en/segment-0.vtt?jp_hls_sequence=0", method: "GET", rangeHeader: nil).status, 404)
        XCTAssertEqual(server.response(forPath: "text/en/segment-0.vtt?jp_hls_sequence=999999", method: "GET", rangeHeader: nil).status, 404)
        now = anchor.addingTimeInterval(24)
        XCTAssertEqual(server.response(forPath: "text/en/segment-0.vtt?jp_hls_sequence=6", method: "GET", rangeHeader: nil).body, original.body,
            "Loop resets media timestamps with a matching discontinuity, not rewritten cue bytes")
        await server.stop()
    }

    func testColdLiveCompletionAndStopFreezeAllTracksAndRejectFutureSegments() async throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        var now = anchor
        let server = HLSFixtureServer(profileDirectory: directory, startedAt: anchor,
            playbackConfiguration: live(.coldDVR), clock: { now })
        XCTAssertEqual(server.slidingWindow(forPath: "text/en/stream.m3u8")?.entries.count, 0)
        XCTAssertEqual(server.response(forPath: "text/en/segment-0.vtt?jp_hls_sequence=0", method: "GET", rangeHeader: nil).status, 404)
        now = anchor.addingTimeInterval(8)
        try server.completeLive()
        let frozen = server.response(forPath: "text/en/stream.m3u8", method: "GET", rangeHeader: nil)
        XCTAssertTrue(String(decoding: frozen.body, as: UTF8.self).contains("#EXT-X-ENDLIST"))
        now = anchor.addingTimeInterval(3600)
        XCTAssertEqual(server.response(forPath: "text/en/stream.m3u8", method: "GET", rangeHeader: nil), frozen)
        XCTAssertEqual(server.response(forPath: "text/en/segment-0.vtt?jp_hls_sequence=0", method: "GET", rangeHeader: nil).status, 200)
        XCTAssertEqual(server.response(forPath: "text/en/segment-2.vtt?jp_hls_sequence=2", method: "GET", rangeHeader: nil).status, 404)
        await server.stop()
        XCTAssertEqual(server.response(forPath: "text/en/stream.m3u8", method: "GET", rangeHeader: nil).status, 410)
        XCTAssertThrowsError(try server.completeLive())
        XCTAssertNil(server.slidingWindow(forPath: "text/en/stream.m3u8"))
    }

    func testPreparedCaptionSwitchSharesCutoffAndKeepsOldBytesAvailable() async throws {
        let scratch = root.appendingPathComponent(".build/cc-switch-\(UUID().uuidString)")
        let replacement = scratch.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.copyItem(at: directory.deletingLastPathComponent().appendingPathComponent("player-qa-widescreen-v1"),
            to: scratch.appendingPathComponent("player-qa-widescreen-v1"))
        var descriptor = HLSFixtureProfileDescriptor.load(from: directory)
        descriptor.textFixture?.sourceRevision = "replacement-v2"
        descriptor.textFixture?.tracks[0].cues[0].text = "Changed caption test."
        try JSONEncoder().encode(descriptor).write(to: replacement.appendingPathComponent("profile.json"))
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        var now = anchor.addingTimeInterval(4)
        let server = HLSFixtureServer(profileDirectory: directory, startedAt: anchor,
            playbackConfiguration: live(), clock: { now })
        let id = UUID()
        try await server.prepareSwitch(id: id, directory: replacement)
        let oldBytes = server.response(forPath: "text/en/segment-0.vtt?jp_hls_sequence=0", method: "GET", rangeHeader: nil).body
        let before = try XCTUnwrap(server.slidingWindow(forPath: "text/en/stream.m3u8"))
        try server.switchPrepared(id: id)
        XCTAssertEqual(server.slidingWindow(forPath: "text/en/stream.m3u8")?.entries, before.entries)
        now = anchor.addingTimeInterval(12)
        let text = try XCTUnwrap(server.slidingWindow(forPath: "text/en/stream.m3u8"))
        let video = try XCTUnwrap(server.slidingWindow(forPath: "video-720/stream.m3u8"))
        XCTAssertEqual(text.entries.last?.virtualIndex, video.entries.last?.virtualIndex)
        XCTAssertTrue(try XCTUnwrap(text.entries.last).segment.hasDiscontinuityBefore)
        let path = "__jp_media/\(id.uuidString)/text/en/segment-0.vtt?jp_hls_sequence=6"
        XCTAssertEqual(server.response(forPath: path, method: "GET", rangeHeader: "bytes=0-5").body, Data("WEBVTT".utf8))
        XCTAssertEqual(server.response(forPath: path, method: "GET", rangeHeader: nil).textTrack?.id, "en")
        XCTAssertEqual(server.response(forPath: path, method: "GET", rangeHeader: nil).textTrack?.sourceRevision, "replacement-v2")
        XCTAssertTrue(String(decoding: server.response(forPath: path, method: "GET", rangeHeader: nil).body, as: UTF8.self).contains("Changed caption test."))
        XCTAssertEqual(server.response(forPath: "__jp_media/\(id.uuidString)/video-720/seg-000.ts?jp_hls_sequence=6", method: "GET", rangeHeader: nil).status, 200)
        now = anchor.addingTimeInterval(3600)
        XCTAssertEqual(server.response(forPath: "text/en/segment-0.vtt?jp_hls_sequence=0", method: "GET", rangeHeader: nil).status, 200)
        XCTAssertEqual(server.response(forPath: "text/en/segment-0.vtt?jp_hls_sequence=0", method: "GET", rangeHeader: nil).body, oldBytes)
        try server.completeLive()
        XCTAssertEqual(server.response(forPath: path, method: "GET", rangeHeader: nil).status, 200)
        await server.stop()
        XCTAssertThrowsError(try server.switchPrepared(id: id))
    }

    func testStopWinsAgainstPendingPreparationAcrossRepeatedCycles() async throws {
        for _ in 0..<3 {
            let target = try await HLSFixtureServer.make(profileDirectory: directory, playbackConfiguration: live())
            let directory = self.directory
            let id = UUID()
            let preparation = Task { try await target.prepareSwitch(id: id, directory: directory) }
            await target.stop()
            do { try await preparation.value } catch { XCTAssertTrue(error is HLSFixtureServer.FixtureServerError) }
            XCTAssertThrowsError(try target.switchPrepared(id: id))
            XCTAssertNil(target.activePreparedMediaID)
            XCTAssertEqual(target.response(forPath: "text/en/stream.m3u8", method: "GET", rangeHeader: nil).status, 410)
        }
    }

    func testLiveRequiresConformantUniqueIdentityAndPreparationHonorsCancellation() async throws {
        var configuration = live()
        configuration.segmentURIIdentity = .reuseAssetURI
        configuration.intent = .deliberateFault
        XCTAssertThrowsError(try HLSWebVTTFixture.prepare(directory: directory, configuration: configuration))
        configuration = live(); configuration.jitPublicationState = .current
        XCTAssertThrowsError(try HLSWebVTTFixture.prepare(directory: directory, configuration: configuration))
        configuration = live()
        let directory = self.directory
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HLSFixtureServer.make(profileDirectory: directory, playbackConfiguration: configuration)
        }
        do { let server = try await task.value; await server.stop(); XCTFail("Cancelled preparation created a server") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPreparedPackIsDeterministicBoundedAndReusesVerifiedMedia() throws {
        let first = try XCTUnwrap(HLSWebVTTFixture.prepare(directory: directory, configuration: vod))
        let second = try XCTUnwrap(HLSWebVTTFixture.prepare(directory: directory, configuration: vod))
        XCTAssertEqual(first.resources, second.resources)
        XCTAssertEqual(first.hashes, second.hashes)
        XCTAssertEqual(first.resources.keys.filter { $0.hasSuffix(".vtt") }.count, 42)
        XCTAssertLessThan(first.resources.values.reduce(0) { $0 + $1.count }, 256 * 1024)
        XCTAssertFalse(first.mediaFiles.isEmpty)
        XCTAssertTrue(first.mediaFiles.values.allSatisfy { $0.path.contains("/player-qa-widescreen-v1/") })
        let master = String(decoding: try XCTUnwrap(first.resources["master.m3u8"]), as: UTF8.self)
        XCTAssertEqual(master.components(separatedBy: "TYPE=SUBTITLES").count - 1, 7)
        XCTAssertEqual(master.components(separatedBy: "SUBTITLES=\"text\"").count - 1, 3)
        XCTAssertTrue(master.contains("CHARACTERISTICS=\"public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound\""))
        XCTAssertTrue(master.contains("FORCED=YES"))
        XCTAssertFalse(master.contains("TYPE=CLOSED-CAPTIONS"))
        let firstVariant = try XCTUnwrap(master.components(separatedBy: "\n").first { $0.hasPrefix("#EXT-X-STREAM-INF:") })
        let bandwidthText = try XCTUnwrap(firstVariant.components(separatedBy: ",").first)
        let bandwidth = try XCTUnwrap(Int(bandwidthText.replacingOccurrences(of: "#EXT-X-STREAM-INF:BANDWIDTH=", with: "")))
        XCTAssertGreaterThan(bandwidth, 928000, "Declared bandwidth must account for selectable text")
    }

    func testCrossBoundarySilentForcedAndUnicodeCuesKeepExactTiming() throws {
        let pack = try XCTUnwrap(HLSWebVTTFixture.prepare(directory: directory, configuration: vod))
        func text(_ path: String) throws -> String { String(decoding: try XCTUnwrap(pack.resources[path]), as: UTF8.self) }
        for index in 0...1 {
            let body = try text("text/en/segment-\(index).vtt")
            XCTAssertTrue(body.contains("00:00:03.500 --> 00:00:05.500"))
            XCTAssertTrue(body.contains("X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:132000"))
        }
        XCTAssertFalse(try text("text/en/segment-2.vtt").contains("-->"))
        XCTAssertFalse(try text("text/en-forced/segment-0.vtt").contains("-->"))
        XCTAssertTrue(try text("text/en-forced/segment-4.vtt").contains("FORCED-001"))
        XCTAssertTrue(try text("text/ar/segment-0.vtt").contains("العربية"))
        XCTAssertTrue(try text("text/ja/segment-0.vtt").contains("日本語"))
        XCTAssertTrue(try text("text/fr/segment-0.vtt").contains("français"))
    }

    func testInvalidContractsRejectInsteadOfServingMisleadingTracks() throws {
        let original = try specification()
        var value = original
        value.tracks.append(value.tracks[0])
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(value))
        value = original; value.tracks[0].language = "en\",URI=\"bad"
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(value))
        value = original; value.tracks[0].cues[0].endMilliseconds = 50_000
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(value))
        value = original; value.tracks[0].cues[0].text = "text\n\n00:00:01.000 --> 00:00:02.000"
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(value))
        value = original; value.tracks[3].isAutoSelect = false
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(value))
        value = original; value.baseProfileID = "../outside"
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(value))
        XCTAssertThrowsError(try HLSWebVTTFixture.prepare(directory: directory, configuration: .conformant))
        XCTAssertThrowsError(try HLSWebVTTFixture.prepare(directory: directory, configuration: .legacyCompatible))
    }

    func testOldProfileDoesNotAcquireTextOrLoseLiveSupport() throws {
        let base = directory.deletingLastPathComponent().appendingPathComponent("player-qa-widescreen-v1")
        XCTAssertNil(try HLSWebVTTFixture.prepare(directory: base, configuration: .conformant))
        XCTAssertNil(HLSFixtureProfileDescriptor.load(from: base).textFixture)
        XCTAssertEqual(HLSFixtureProfileDescriptor.load(from: base).supportedPresentationModes, HLSPresentationMode.allCases)
        let descriptor = HLSFixtureProfileDescriptor.load(from: directory)
        XCTAssertEqual(descriptor.supportedPresentationModes, [.vodStatic, .liveLoop])
        XCTAssertEqual(descriptor.defaultPlaybackConfiguration.presentationMode, .vodStatic)
    }

    func testTransportServesTextHeadRangesAndSharedVideoWithoutExposingSourceFiles() async throws {
        let server = try await HLSFixtureServer.make(profileDirectory: directory, playbackConfiguration: vod)
        do {
            try await server.start()
            let path = "text/es/segment-0.vtt"
            let get = server.response(forPath: path, method: "GET", rangeHeader: nil)
            XCTAssertEqual(get.status, 200)
            XCTAssertEqual(get.headers["Content-Type"], "text/vtt; charset=utf-8")
            XCTAssertEqual(get.headers["ETag"], "\"\(HLSWebVTTFixture.sha256(get.body))\"")
            let head = server.response(forPath: path, method: "HEAD", rangeHeader: nil)
            XCTAssertTrue(head.body.isEmpty)
            XCTAssertEqual(head.headers["Content-Length"], "\(get.body.count)")
            let range = server.response(forPath: path, method: "GET", rangeHeader: "bytes=0-5")
            XCTAssertEqual(range.status, 206)
            XCTAssertEqual(range.body, Data("WEBVTT".utf8))
            let headRange = server.response(forPath: path, method: "HEAD", rangeHeader: "bytes=0-5")
            XCTAssertTrue(headRange.body.isEmpty)
            XCTAssertEqual(headRange.headers["Content-Length"], "6")
            XCTAssertEqual(server.response(forPath: "profile.json", method: "GET", rangeHeader: nil).status, 404)
            XCTAssertEqual(server.response(forPath: "text/es/missing.vtt", method: "GET", rangeHeader: nil).status, 404)
            XCTAssertEqual(server.response(forPath: "../player-qa-widescreen-v1/master.m3u8", method: "GET", rangeHeader: nil).status, 404)
            XCTAssertEqual(server.response(forPath: path, method: "POST", rangeHeader: nil).status, 405)
            let video = server.response(forPath: "video-720/seg-000.ts", method: "GET", rangeHeader: nil)
            let source = try Data(contentsOf: directory.deletingLastPathComponent().appendingPathComponent("player-qa-widescreen-v1/video-720/seg-000.ts"))
            XCTAssertEqual(video.body, source)
            let baseURL = try XCTUnwrap(server.baseURL)
            let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent(path))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, get.body)
            guard case .vod(let parsed, _) = server.playlistPreview(forPath: "text/es/stream.m3u8") else {
                XCTFail("Text playlist preview must remain VOD"); await server.stop(); return
            }
            XCTAssertEqual(parsed.segments.count, 6)
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    func testCorruptSourceContractFailsClosedBeforeServerConstruction() async throws {
        let scratch = root.appendingPathComponent(".build/cc-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data("{\"textFixture\":{}}".utf8).write(to: scratch.appendingPathComponent("profile.json"))
        do {
            let server = try await HLSFixtureServer.make(profileDirectory: scratch, playbackConfiguration: vod)
            await server.stop()
            XCTFail("Malformed text metadata must not silently become a legacy fixture")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testPinnedInventoryRejectsChangedHashAndUnsafeSharedPaths() throws {
        let scratch = root.appendingPathComponent(".build/cc-inventory-\(UUID().uuidString)")
        let profile = scratch.appendingPathComponent("text")
        let base = scratch.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var descriptor = HLSFixtureProfileDescriptor.load(from: directory)
        descriptor.textFixture?.baseProfileID = "media"
        let inventory = Data("{\"files\":{\"../escape.ts\":{\"sha256\":\"unused\",\"bytes\":1}}}".utf8)
        try inventory.write(to: base.appendingPathComponent("expected-hashes.json"))
        descriptor.textFixture?.baseInventorySHA256 = String(repeating: "0", count: 64)
        try JSONEncoder().encode(descriptor).write(to: profile.appendingPathComponent("profile.json"))
        XCTAssertThrowsError(try HLSWebVTTFixture.prepare(directory: profile, configuration: vod)) { error in
            XCTAssertTrue(error.localizedDescription.contains("inventory changed"))
        }
        descriptor.textFixture?.baseInventorySHA256 = HLSWebVTTFixture.sha256(inventory)
        try JSONEncoder().encode(descriptor).write(to: profile.appendingPathComponent("profile.json"))
        XCTAssertThrowsError(try HLSWebVTTFixture.prepare(directory: profile, configuration: vod)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsafe base path"))
        }
        try Data("{broken legacy metadata".utf8).write(to: profile.appendingPathComponent("profile.json"))
        XCTAssertNil(try HLSWebVTTFixture.prepare(directory: profile, configuration: .conformant))
    }
}
