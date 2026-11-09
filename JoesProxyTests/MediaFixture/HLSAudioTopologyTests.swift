import XCTest
@testable import JoesProxy

final class HLSAudioTopologyTests: XCTestCase {

    private func profileDirectory(for id: String) -> URL {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Fixtures/HLS/\(id)", isDirectory: true)
    }

    func testParserHandlesURILessMediaTagForHybridMaster() {
        let hybridManifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Program",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Audio Description",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",CHARACTERISTICS="public.accessibility.describes-video",URI="audio-ad/stream.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=345082,AVERAGE-BANDWIDTH=343191,RESOLUTION=640x360,FRAME-RATE=30.000,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"
        video-360/stream.m3u8
        """

        let parsed = HLSParser.parse(hybridManifest)
        XCTAssertEqual(parsed.mediaGroups.count, 2)

        let programAudio = parsed.mediaGroups.first(where: { $0.name == "English Program" })
        XCTAssertNotNil(programAudio)
        XCTAssertNil(programAudio?.uri)
        XCTAssertEqual(programAudio?.isDefault, true)
        XCTAssertEqual(programAudio?.autoSelect, true)

        let audioDescription = parsed.mediaGroups.first(where: { $0.name == "English Audio Description" })
        XCTAssertNotNil(audioDescription)
        XCTAssertEqual(audioDescription?.uri, "audio-ad/stream.m3u8")
        XCTAssertEqual(audioDescription?.isDefault, false)
        XCTAssertEqual(audioDescription?.autoSelect, true)
        XCTAssertEqual(audioDescription?.characteristics, ["public.accessibility.describes-video"])
    }

    func testSubstitutionMasterRewritePreservesURILessMediaTags() {
        let masterText = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Program",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Audio Description",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",CHARACTERISTICS="public.accessibility.describes-video",URI="audio-ad/stream.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=345082,RESOLUTION=640x360,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"
        video-360/stream.m3u8
        """
        let response = HLSFixtureResponse(status: 200, headers: [:], body: Data(masterText.utf8))
        let rewritten = HLSSubstitutionManifestRouter.rewriteMaster(
            response,
            mountPath: "/test-stream-mount",
            method: "GET"
        )
        let rewrittenText = String(decoding: rewritten.body, as: UTF8.self)

        // The URI-less EXT-X-MEDIA line should remain without any URI
        XCTAssertTrue(rewrittenText.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English Program\",LANGUAGE=\"en\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"2\""))
        // The URI-backed EXT-X-MEDIA line should have its URI rooted
        XCTAssertTrue(rewrittenText.contains("URI=\"/test-stream-mount/audio-ad/stream.m3u8\""))
        // The variant URI should be rooted
        XCTAssertTrue(rewrittenText.contains("/test-stream-mount/video-360/stream.m3u8"))
    }

    func testMuxedOnlyProfileIntegrity() throws {
        let dir = profileDirectory(for: "audio-muxed-only-aligned")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))

        let descriptor = HLSFixtureProfileDescriptor.load(from: dir)
        XCTAssertEqual(descriptor.audioTopology, "muxedOnly")
        XCTAssertEqual(descriptor.renditions.count, 3)
        XCTAssertEqual(descriptor.audioRenditions?.count, 1)

        let audio = try XCTUnwrap(descriptor.audioRenditions?.first)
        XCTAssertEqual(audio.deliveryKind, "inBand")
        XCTAssertEqual(audio.variantsCarryingInBand, ["video-360", "video-720", "video-1080"])
        XCTAssertEqual(audio.segmentGridDuration, 6.0)

        let masterData = try Data(contentsOf: dir.appendingPathComponent("master.m3u8"))
        let masterText = String(decoding: masterData, as: UTF8.self)
        XCTAssertFalse(masterText.contains("#EXT-X-MEDIA"))
        XCTAssertFalse(masterText.contains("AUDIO=\""))
    }

    func testDemuxedAllProfileIntegrity() throws {
        let dir = profileDirectory(for: "audio-demuxed-all-aligned")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))

        let descriptor = HLSFixtureProfileDescriptor.load(from: dir)
        XCTAssertEqual(descriptor.audioTopology, "demuxedAll")
        XCTAssertEqual(descriptor.renditions.count, 3)
        XCTAssertEqual(descriptor.audioRenditions?.count, 2)

        let program = try XCTUnwrap(descriptor.audioRenditions?.first(where: { $0.name == "English Program" }))
        XCTAssertEqual(program.deliveryKind, "uriBacked")
        XCTAssertEqual(program.isDefault, true)

        let ad = try XCTUnwrap(descriptor.audioRenditions?.first(where: { $0.name == "English Audio Description" }))
        XCTAssertEqual(ad.deliveryKind, "uriBacked")
        XCTAssertEqual(ad.characteristics, ["public.accessibility.describes-video"])

        let masterData = try Data(contentsOf: dir.appendingPathComponent("master.m3u8"))
        let masterText = String(decoding: masterData, as: UTF8.self)
        XCTAssertTrue(masterText.contains("URI=\"audio-en/stream.m3u8\""))
        XCTAssertTrue(masterText.contains("URI=\"audio-ad/stream.m3u8\""))
        XCTAssertTrue(masterText.contains("AUDIO=\"aud\""))
    }

    func testHybridProfileIntegrity() throws {
        let dir = profileDirectory(for: "audio-hybrid-inband-program-ad-aligned")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))

        let descriptor = HLSFixtureProfileDescriptor.load(from: dir)
        XCTAssertEqual(descriptor.audioTopology, "hybridInBandProgramAD")
        XCTAssertEqual(descriptor.renditions.count, 3)
        XCTAssertEqual(descriptor.audioRenditions?.count, 2)

        let program = try XCTUnwrap(descriptor.audioRenditions?.first(where: { $0.name == "English Program" }))
        XCTAssertEqual(program.deliveryKind, "inBand")
        XCTAssertEqual(program.variantsCarryingInBand, ["video-360", "video-720", "video-1080"])

        let ad = try XCTUnwrap(descriptor.audioRenditions?.first(where: { $0.name == "English Audio Description" }))
        XCTAssertEqual(ad.deliveryKind, "uriBacked")
        XCTAssertEqual(ad.characteristics, ["public.accessibility.describes-video"])

        let masterData = try Data(contentsOf: dir.appendingPathComponent("master.m3u8"))
        let masterText = String(decoding: masterData, as: UTF8.self)
        XCTAssertTrue(masterText.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English Program\",LANGUAGE=\"en\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"2\"\n"))
        XCTAssertTrue(masterText.contains("URI=\"audio-ad/stream.m3u8\""))
        XCTAssertTrue(masterText.contains("AUDIO=\"aud\""))
    }

    func testAllThreeTopologiesShareEqualTimelineAndDurations() throws {
        let profiles = [
            "audio-muxed-only-aligned",
            "audio-demuxed-all-aligned",
            "audio-hybrid-inband-program-ad-aligned"
        ]

        for profileID in profiles {
            let dir = profileDirectory(for: profileID)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))

            for variant in ["video-360", "video-720", "video-1080"] {
                let playlistURL = dir.appendingPathComponent("\(variant)/stream.m3u8")
                let text = try String(contentsOf: playlistURL, encoding: .utf8)
                let parsed = HLSStaticPlaylistParser.parse(text)
                XCTAssertEqual(parsed.segments.count, 15, "Profile \(profileID) \(variant) segment count")
                XCTAssertEqual(parsed.targetDuration, 6, "Profile \(profileID) \(variant) target duration")
                let totalDuration = parsed.segments.reduce(0) { $0 + $1.duration }
                XCTAssertEqual(totalDuration, 90.0, accuracy: 0.1, "Profile \(profileID) \(variant) total duration")
            }
        }
    }
}
