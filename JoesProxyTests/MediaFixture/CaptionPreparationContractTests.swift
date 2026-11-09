import Foundation
import XCTest
#if !JOESPROXY_CAPTION_CONTRACT_TESTS
@testable import JoesProxy
#endif

/// The same cases run in Policy and the host-independent source-contract lane.
final class CaptionPreparationContractTests: XCTestCase {
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/HLS/multilingual-text-vod-v1")
    }

    private func specification() throws -> HLSWebVTTFixture.Specification {
        try XCTUnwrap(JSONDecoder().decode(HLSFixtureProfileDescriptor.self,
            from: Data(contentsOf: directory.appendingPathComponent("profile.json"))).textFixture)
    }

    private var configuration: HLSPlaybackConfiguration {
        var value = HLSPlaybackConfiguration.conformant
        value.presentationMode = .vodStatic
        return value
    }

    func testPreparationIsDeterministicBoundedAndPreservesMediaReferences() throws {
        let first = try XCTUnwrap(HLSWebVTTFixture.prepare(directory: directory, configuration: configuration))
        let second = try XCTUnwrap(HLSWebVTTFixture.prepare(directory: directory, configuration: configuration))
        XCTAssertEqual(first.resources, second.resources)
        XCTAssertEqual(first.hashes, second.hashes)
        XCTAssertEqual(first.mediaFiles, second.mediaFiles)
        XCTAssertFalse(first.mediaFiles.isEmpty)
        XCTAssertLessThanOrEqual(first.resources.values.reduce(0) { $0 + $1.count }, 256 * 1024)
        for (path, url) in first.mediaFiles {
            XCTAssertNil(first.resources[path], "Binary media must remain file-backed")
            XCTAssertEqual(HLSWebVTTFixture.sha256(try Data(contentsOf: url)), first.hashes[path])
        }
    }

    func testPreparedTracksHaveResolvableManifestsHashesAndParseableCues() throws {
        let spec = try specification()
        let prepared = try XCTUnwrap(HLSWebVTTFixture.prepare(directory: directory, configuration: configuration))
        let master = String(decoding: try XCTUnwrap(prepared.resources["master.m3u8"]), as: UTF8.self)
        XCTAssertEqual(spec.tracks.count, 7)
        for track in spec.tracks {
            XCTAssertTrue(master.contains("URI=\"\(track.playlistPath)\""))
            let playlist = String(decoding: try XCTUnwrap(prepared.resources[track.playlistPath]), as: UTF8.self)
            let segments = HLSStaticPlaylistParser.parse(playlist).segments
            XCTAssertEqual(segments.count, spec.durationMilliseconds / spec.segmentMilliseconds)
            for (index, segment) in segments.enumerated() {
                let path = "text/\(track.id)/\(segment.uri)"
                let bytes = try XCTUnwrap(prepared.resources[path])
                XCTAssertEqual(prepared.hashes[path], HLSWebVTTFixture.sha256(bytes))
                XCTAssertEqual(prepared.tracks[path]?.sourceRevision, spec.sourceRevision)
                let parsed = WebVTTEngine.parse(vttText: String(decoding: bytes, as: UTF8.self), isHlsSegment: true)
                XCTAssertTrue(parsed.hasTimestampMap)
                XCTAssertEqual(parsed.mpegtsOffsetPTS, Int(spec.mediaTimestamp))
                let start = index * spec.segmentMilliseconds
                let expected = track.cues.filter {
                    $0.startMilliseconds < start + spec.segmentMilliseconds && $0.endMilliseconds > start
                }
                XCTAssertEqual(parsed.cues.compactMap(\.cueIdentifier), expected.map(\.id))
                for cue in parsed.cues {
                    XCTAssertTrue(cue.text.contains("[\(track.language) · \(track.role.rawValue) ·"))
                }
            }
        }
    }

    func testInvalidIdentityLanguageAndSelectionFlagsFailBeforePreparation() throws {
        let original = try specification()
        var bad = original
        bad.tracks[1].id = bad.tracks[0].id
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(bad))
        bad = original
        bad.tracks[0].language = "en\nINJECT"
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(bad))
        bad = original
        bad.tracks[0].isDefault = true
        bad.tracks[0].isAutoSelect = false
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(bad))
    }

    func testMalformedCueTimingAndPayloadAreRejected() throws {
        let original = try specification()
        var bad = original
        bad.tracks[0].cues[0].endMilliseconds = bad.tracks[0].cues[0].startMilliseconds
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(bad))
        bad = original
        bad.tracks[0].cues[0].text = "payload\n00:00:01.000 --> 00:00:02.000"
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(bad))
        bad = original
        bad.tracks[0].cues[0].text = String(repeating: "x", count: 2049)
        XCTAssertThrowsError(try HLSWebVTTFixture.validate(bad))
    }

    func testLivePreparationAcceptsConformantClockAndRejectsUnsafeModes() throws {
        var live = HLSPlaybackConfiguration.conformant
        live.presentationMode = .liveLoop
        live.timeShiftMode = .warmDVR
        XCTAssertNotNil(try HLSWebVTTFixture.prepare(directory: directory, configuration: live))
        live.segmentURIIdentity = .reuseAssetURI
        live.intent = .deliberateFault
        XCTAssertThrowsError(try HLSWebVTTFixture.validateConfiguration(live))
        var jit = configuration
        jit.jitPublicationState = .current
        XCTAssertThrowsError(try HLSWebVTTFixture.validateConfiguration(jit))
    }
}
