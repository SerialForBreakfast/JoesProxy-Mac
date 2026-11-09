import CryptoKit
import Foundation
import XCTest
@testable import JoesProxy

/// P2-07 profile-matrix content verification: inventory hashes, documented deltas, discovery of 8.
@MainActor
final class HLSFixtureProfileMatrixTests: XCTestCase {
    private static let expectedProfileIDs: [String] = [
        "baseline-aligned-codecs",
        "bogus-ad-alias-only",
        "combined-defects",
        "discontinuity-at-switch",
        "discontinuity-cross-rendition-drift",
        "key-rotation-only",
        "misaligned-audio-boundary",
        "missing-codecs-only"
    ]

    private static let paramProfileIDs: [String] = [
        "param-aligned-4s",
        "param-cross-disc-v3-aen5-aes4",
        "param-lang-en-es",
        "param-misaligned-v4-a3"
    ]

    private static let playerQAProfileIDs = ["player-qa-widescreen-v1"]
    private static let sixSecondProfileIDs = ["sdr-six-second-positive-v1"]
    private static let audioTopologyProfileIDs = [
        "audio-demuxed-all-aligned",
        "audio-hybrid-inband-program-ad-aligned",
        "audio-muxed-only-aligned"
    ]
    private static let jitAndFineGridProfileIDs = [
        "audio-hybrid-inband-program-ad-fine-grid",
        "audio-hybrid-inband-program-ad-jit"
    ]
    private static let id3ProfileIDs = [
        "id3-demuxed-program",
        "id3-hybrid-equivalent",
        "id3-hybrid-program-only",
        "id3-muxed-av-equivalent",
        "id3-packed-audio-timestamp"
    ]

    private static var allProfileIDs: [String] {
        expectedProfileIDs + paramProfileIDs + playerQAProfileIDs + sixSecondProfileIDs + audioTopologyProfileIDs + jitAndFineGridProfileIDs + id3ProfileIDs + ["multilingual-text-vod-v1"]
    }

    private func fixturesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS")
    }

    private func profileDirectory(_ id: String) -> URL {
        fixturesRoot().appendingPathComponent(id)
    }

    private func measuredRates(forRenditionAt directory: URL) throws -> (peak: Int, average: Int) {
        let playlistText = try String(
            contentsOf: directory.appendingPathComponent("stream.m3u8"),
            encoding: .utf8
        )
        let segments = HLSParser.parse(playlistText, baseURL: nil).segments
        var totalBytes = 0
        var totalDuration = 0.0
        var peak = 0.0
        for segment in segments {
            let duration = try XCTUnwrap(segment.duration)
            let bytes = try Data(contentsOf: directory.appendingPathComponent(segment.uri)).count
            totalBytes += bytes
            totalDuration += duration
            peak = max(peak, Double(bytes * 8) / duration)
        }
        return (
            peak: Int(ceil(peak)),
            average: Int(ceil(Double(totalBytes * 8) / totalDuration))
        )
    }

    func testCoreFaultProfilesExistOnDisk() {
        for id in Self.expectedProfileIDs {
            let master = profileDirectory(id).appendingPathComponent("master.m3u8")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: master.path),
                "Missing profile \(id) at \(master.path)"
            )
        }
    }

    func testParamProfilesExistOnDisk() {
        for id in Self.paramProfileIDs {
            let master = profileDirectory(id).appendingPathComponent("master.m3u8")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: master.path),
                "Missing param profile \(id) — run Fixtures/HLS/author-param-profile.sh"
            )
        }
    }

    func testAvailableProfilesListsCompleteCatalogWithVersion() {
        let store = HLSFixtureRunStore(
            persistenceURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("hls-matrix-profiles-\(UUID().uuidString).json"),
            profileRootURL: fixturesRoot(),
            originRegistry: nil
        )
        store.load()
        let ids = store.availableProfiles().map(\.id)
        // availableProfiles() enumerates every subdirectory with a master.m3u8, with no filtering
        // by naming convention — param-* profiles (author-param-profile.sh output) are real,
        // independently servable profile directories through the identical HLSFixtureServer path
        // as the core 8, so they are expected here too, not hidden from discovery.
        let expectedIDs = Self.allProfileIDs.sorted()
        XCTAssertEqual(ids, expectedIDs)
        for profile in store.availableProfiles() {
            let expectedVersion = Self.playerQAProfileIDs.contains(profile.id) ? "2" : "1"
            XCTAssertEqual(profile.version, expectedVersion, "profile \(profile.id) should report version \(expectedVersion)")
        }
    }

    func testExpectedHashesMatchOnDiskFiles() throws {
        for id in Self.expectedProfileIDs + Self.playerQAProfileIDs + Self.sixSecondProfileIDs + Self.audioTopologyProfileIDs + Self.jitAndFineGridProfileIDs + Self.id3ProfileIDs {
            let dir = profileDirectory(id)
            let inventoryURL = dir.appendingPathComponent("expected-hashes.json")
            let data = try Data(contentsOf: inventoryURL)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["profile"] as? String, id)
            let expectedVersion = Self.playerQAProfileIDs.contains(id) ? "2" : "1"
            XCTAssertEqual(json["profileVersion"] as? String, expectedVersion)
            let generatedWith = try XCTUnwrap(json["generatedWith"] as? String)
            XCTAssertFalse(generatedWith.isEmpty, "\(id) should record generatedWith provenance")
            // Optional ffmpegVersion is allowed for regeneration recipes; inventory SHA checks ignore it.
            if let ffmpegVersion = json["ffmpegVersion"] as? String {
                XCTAssertFalse(ffmpegVersion.isEmpty, "\(id) ffmpegVersion must be non-empty when present")
            }
            let files = try XCTUnwrap(json["files"] as? [String: [String: Any]])
            XCTAssertFalse(files.isEmpty, "\(id) inventory empty")
            for (relative, meta) in files {
                let url = dir.appendingPathComponent(relative)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(id) missing \(relative)")
                let fileData = try Data(contentsOf: url)
                let digest = SHA256.hash(data: fileData)
                let hex = digest.map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(meta["sha256"] as? String, hex, "\(id)/\(relative) sha256 mismatch")
                XCTAssertEqual(meta["bytes"] as? Int, fileData.count, "\(id)/\(relative) byte count mismatch")
            }
        }
    }

    func testSixSecondSDRPositiveControlHasMeasuredAlignedMediaFactsAndFitsBudget() throws {
        let directory = profileDirectory("sdr-six-second-positive-v1")
        let descriptor = HLSFixtureProfileDescriptor.load(from: directory)
        XCTAssertEqual(descriptor.conformanceClass, "conformantControl")
        XCTAssertEqual(descriptor.controlledFaults, [])
        XCTAssertTrue(descriptor.isRecommended)

        let metadataData = try Data(contentsOf: directory.appendingPathComponent("profile.json"))
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        )
        let provenance = try XCTUnwrap(metadata["sourceProvenance"] as? [String: Any])
        XCTAssertEqual(provenance["kind"] as? String, "project-authored synthetic lavfi sources")
        XCTAssertEqual(provenance["durationSeconds"] as? Int, 90)
        XCTAssertFalse(try XCTUnwrap(provenance["ffmpegVersion"] as? String).isEmpty)
        XCTAssertFalse(try XCTUnwrap(provenance["ffprobeVersion"] as? String).isEmpty)
        let mediaFacts = try XCTUnwrap(metadata["mediaFacts"] as? [String: Any])
        XCTAssertEqual(mediaFacts["segmentDurationSeconds"] as? Int, 6)
        XCTAssertEqual(mediaFacts["segmentCountPerRendition"] as? Int, 15)
        XCTAssertEqual(mediaFacts["continuousTimelineSeconds"] as? Int, 90)
        let validation = try XCTUnwrap(metadata["validationStatus"] as? [String: Any])
        XCTAssertTrue(
            try XCTUnwrap(validation["officialHLSValidator"] as? String).hasPrefix("not run:")
        )

        let inventoryData = try Data(
            contentsOf: directory.appendingPathComponent("expected-hashes.json")
        )
        let inventory = try XCTUnwrap(
            JSONSerialization.jsonObject(with: inventoryData) as? [String: Any]
        )
        let inventoriedFiles = try XCTUnwrap(inventory["files"] as? [String: [String: Any]])
        let installedBytes = try inventoriedFiles.values.reduce(0) { partial, item in
            partial + (try XCTUnwrap(item["bytes"] as? Int))
        }
        XCTAssertLessThanOrEqual(installedBytes, try XCTUnwrap(descriptor.bundleSizeBudgetBytes))

        let masterText = try String(
            contentsOf: directory.appendingPathComponent("master.m3u8"),
            encoding: .utf8
        )
        let master = HLSParser.parse(masterText, baseURL: nil)
        XCTAssertEqual(master.variants.map(\.resolution), ["640x360", "1280x720", "1920x1080"])
        XCTAssertEqual(master.variants.compactMap(\.frameRate), [30, 30, 30])
        XCTAssertTrue(master.variants.allSatisfy { $0.codecs?.contains("mp4a.40.2") == true })
        XCTAssertTrue(master.variants.allSatisfy {
            guard let bandwidth = $0.bandwidth, let average = $0.averageBandwidth else { return false }
            return bandwidth >= average && average > 0
        })
        let audioRates = try measuredRates(
            forRenditionAt: directory.appendingPathComponent("audio-en")
        )
        for variant in master.variants {
            let videoDirectory = directory
                .appendingPathComponent(variant.uri)
                .deletingLastPathComponent()
            let videoRates = try measuredRates(forRenditionAt: videoDirectory)
            XCTAssertEqual(variant.bandwidth, videoRates.peak + audioRates.peak)
            XCTAssertEqual(variant.averageBandwidth, videoRates.average + audioRates.average)
        }

        let renditionPaths = [
            "video-360/stream.m3u8",
            "video-720/stream.m3u8",
            "video-1080/stream.m3u8",
            "audio-en/stream.m3u8"
        ]
        for relativePath in renditionPaths {
            let playlistText = try String(
                contentsOf: directory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let playlist = HLSParser.parse(playlistText, baseURL: nil)
            XCTAssertEqual(playlist.targetDuration, 6)
            XCTAssertEqual(playlist.segmentCount, 15)
            XCTAssertEqual(playlist.segments.compactMap(\.duration).reduce(0, +), 90, accuracy: 0.05)
            XCTAssertTrue(playlistText.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
            XCTAssertTrue(playlistText.contains("#EXT-X-ENDLIST"))
        }
    }

    func testPlayerQAProfileHasSixAlignedSegmentsAndFitsBundleBudget() throws {
        let directory = profileDirectory("player-qa-widescreen-v1")
        let descriptor = HLSFixtureProfileDescriptor.load(from: directory)
        let budget = try XCTUnwrap(descriptor.bundleSizeBudgetBytes)
        var totalBytes = 0
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true {
                totalBytes += values.fileSize ?? 0
            }
        }
        XCTAssertLessThanOrEqual(totalBytes, budget)

        for relativePath in [
            "video-360/stream.m3u8",
            "video-720/stream.m3u8",
            "video-1080/stream.m3u8",
            "audio-en/stream.m3u8",
            "audio-ad/stream.m3u8",
            "audio-es/stream.m3u8",
            "audio-de/stream.m3u8"
        ] {
            let playlist = try String(
                contentsOf: directory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertEqual(
                playlist.split(separator: "\n").filter { $0.hasPrefix("seg-") }.count,
                6,
                "\(relativePath) must contain six aligned segments"
            )
        }
        let master = try String(
            contentsOf: directory.appendingPathComponent("master.m3u8"),
            encoding: .utf8
        )
        XCTAssertTrue(master.contains("RESOLUTION=640x360"))
        XCTAssertTrue(master.contains("RESOLUTION=1280x720"))
        XCTAssertTrue(master.contains("RESOLUTION=1920x1080"))
        XCTAssertEqual(master.components(separatedBy: "FRAME-RATE=30.000").count - 1, 3)
        XCTAssertTrue(master.contains("mp4a.40.2"))
        XCTAssertTrue(master.contains("#EXT-X-INDEPENDENT-SEGMENTS"))

        let parsed = HLSParser.parse(master, baseURL: nil)
        let audioGroups = parsed.mediaGroups.filter { $0.type == "AUDIO" }
        XCTAssertEqual(audioGroups.count, 4)
        XCTAssertEqual(Set(audioGroups.compactMap(\.language)), Set(["en", "es", "de"]))
        XCTAssertEqual(audioGroups.filter(\.isDefault).map(\.name), ["English Program"])
        let descriptionTrack = try XCTUnwrap(audioGroups.first { $0.name == "English Audio Description" })
        XCTAssertEqual(descriptionTrack.associatedLanguage, "en")
        XCTAssertEqual(descriptionTrack.channels, "2")
        XCTAssertEqual(descriptionTrack.characteristics, ["public.accessibility.describes-video"])

        let firstAudioSegments = try ["audio-en", "audio-ad", "audio-es", "audio-de"].map {
            try Data(contentsOf: directory.appendingPathComponent("\($0)/seg-000.ts"))
        }
        XCTAssertEqual(Set(firstAudioSegments).count, 4, "Each selection must have a distinct audible payload")

        let audioDurations = try ["audio-en", "audio-ad", "audio-es", "audio-de"].map { directoryName in
            let playlist = try String(
                contentsOf: directory.appendingPathComponent("\(directoryName)/stream.m3u8"),
                encoding: .utf8
            )
            return HLSParser.parse(playlist, baseURL: nil).segments.compactMap(\.duration)
        }
        XCTAssertTrue(audioDurations.dropFirst().allSatisfy { $0 == audioDurations[0] })
        XCTAssertEqual(audioDurations[0].reduce(0, +), 24, accuracy: 0.05)
    }

    /// Confirms authoring scripts stay out of the app target sources (offline-only packaging).
    func testAppSourcesDoNotShellOutToFFmpeg() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("JoesProxy")
        let enumerator = FileManager.default.enumerator(
            at: appRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            let lowercased = text.lowercased()
            // Comments may mention offline authoring; Process/executable references must not.
            if lowercased.contains("executableurl") && lowercased.contains("ffmpeg") {
                offenders.append(url.lastPathComponent)
            }
            if lowercased.contains("process()") && lowercased.contains("\"ffmpeg\"") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(offenders.isEmpty, "App sources must not Process-launch ffmpeg: \(offenders)")
    }

    func testDocumentedMasterDeltasVersusBaseline() throws {
        let baseline = try String(contentsOf: profileDirectory("baseline-aligned-codecs").appendingPathComponent("master.m3u8"), encoding: .utf8)
        XCTAssertTrue(baseline.contains("CODECS="))
        XCTAssertTrue(baseline.contains("URI=\"audio-ad/stream.m3u8\""))

        let missing = try String(contentsOf: profileDirectory("missing-codecs-only").appendingPathComponent("master.m3u8"), encoding: .utf8)
        XCTAssertFalse(missing.contains("CODECS="))
        XCTAssertTrue(missing.contains("URI=\"audio-ad/stream.m3u8\""))

        let bogus = try String(contentsOf: profileDirectory("bogus-ad-alias-only").appendingPathComponent("master.m3u8"), encoding: .utf8)
        XCTAssertTrue(bogus.contains("CODECS="))
        XCTAssertTrue(bogus.contains("CHARACTERISTICS=\"public.accessibility.describes-video\",URI=\"audio-en/stream.m3u8\""))

        let combined = try String(contentsOf: profileDirectory("combined-defects").appendingPathComponent("master.m3u8"), encoding: .utf8)
        XCTAssertFalse(combined.contains("CODECS="))
        XCTAssertTrue(combined.contains("URI=\"audio-en/stream.m3u8\""))
        XCTAssertTrue(combined.contains("CHARACTERISTICS=\"public.accessibility.describes-video\""))
    }

    func testStreamPlaylistDeltasForDiscontinuityAndKeys() throws {
        let disc = try String(
            contentsOf: profileDirectory("discontinuity-at-switch").appendingPathComponent("video-lo/stream.m3u8"),
            encoding: .utf8
        )
        XCTAssertTrue(disc.contains("#EXT-X-DISCONTINUITY"))

        let keys = try String(
            contentsOf: profileDirectory("key-rotation-only").appendingPathComponent("video-lo/stream.m3u8"),
            encoding: .utf8
        )
        XCTAssertTrue(keys.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"../keys/key-a.key\""))
        XCTAssertTrue(keys.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"../keys/key-b.key\""))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: profileDirectory("key-rotation-only").appendingPathComponent("keys/key-a.key").path
            )
        )

        let baselineStream = try String(
            contentsOf: profileDirectory("baseline-aligned-codecs").appendingPathComponent("video-lo/stream.m3u8"),
            encoding: .utf8
        )
        XCTAssertFalse(baselineStream.contains("#EXT-X-DISCONTINUITY"))
        XCTAssertFalse(baselineStream.contains("#EXT-X-KEY:"))
    }

    func testMisalignedAudioUsesDifferentSegmentGridThanBaselineVideo() throws {
        let baselineAudio = try String(
            contentsOf: profileDirectory("baseline-aligned-codecs").appendingPathComponent("audio-en/stream.m3u8"),
            encoding: .utf8
        )
        let misalignedAudio = try String(
            contentsOf: profileDirectory("misaligned-audio-boundary").appendingPathComponent("audio-en/stream.m3u8"),
            encoding: .utf8
        )
        XCTAssertNotEqual(baselineAudio, misalignedAudio)
        let baselineSegCount = baselineAudio.components(separatedBy: "seg-").count - 1
        let misalignedSegCount = misalignedAudio.components(separatedBy: "seg-").count - 1
        XCTAssertGreaterThan(misalignedSegCount, baselineSegCount)
    }

    func testFixedClockSlidingPlaylistHashIsStablePerProfile() throws {
        // Fixed absolute times so the sliding window is reproducible without wall clock.
        // Use the start of the timeline so the window includes early segments (discontinuity on
        // the third segment is visible; key tags appear on every segment).
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = startedAt
        var hashesByProfile: [String: String] = [:]

        for id in Self.expectedProfileIDs {
            let server = HLSFixtureServer(
                profileDirectory: profileDirectory(id),
                startedAt: startedAt,
                clock: { now }
            )
            let response = server.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
            XCTAssertEqual(response.status, 200, "\(id) stream playlist status")
            let text = String(decoding: response.body, as: UTF8.self)
            let digest = SHA256.hash(data: response.body)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            hashesByProfile[id] = hex

            let again = server.response(forPath: "/video-lo/stream.m3u8", method: "GET", rangeHeader: nil)
            let againHex = SHA256.hash(data: again.body).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, againHex, "\(id) sliding hash must be stable for fixed clock")

            switch id {
            case "discontinuity-at-switch", "combined-defects", "discontinuity-cross-rendition-drift":
                XCTAssertTrue(text.contains("#EXT-X-DISCONTINUITY"), "\(id) sliding window should carry discontinuity")
                XCTAssertTrue(text.contains("#EXT-X-DISCONTINUITY-SEQUENCE:"), "\(id) should emit discontinuity sequence")
            case "key-rotation-only":
                XCTAssertTrue(text.contains("#EXT-X-KEY:"), "\(id) sliding window should carry key tags")
            default:
                break
            }
        }

        let baselineHash = try XCTUnwrap(hashesByProfile["baseline-aligned-codecs"])
        XCTAssertNotEqual(hashesByProfile["discontinuity-at-switch"], baselineHash)
        XCTAssertNotEqual(hashesByProfile["key-rotation-only"], baselineHash)
        XCTAssertNotEqual(hashesByProfile["combined-defects"], baselineHash)
        XCTAssertNotEqual(hashesByProfile["discontinuity-cross-rendition-drift"], baselineHash)
        XCTAssertEqual(hashesByProfile["missing-codecs-only"], baselineHash)
        XCTAssertEqual(hashesByProfile["bogus-ad-alias-only"], baselineHash)
    }

    /// The existing sliding-window stability test above only ever requests `video-lo/stream.m3u8` —
    /// it never proves that the two AUDIO renditions of `discontinuity-cross-rendition-drift`
    /// actually diverge from each other through the live server the way the profile's own
    /// `expected-hashes.json` purpose string claims (video@3, audio-en@5, audio-ad@4). This is the
    /// exact mechanism the JoePlayer discontinuity-switch validation plan depends on, so it needs
    /// its own live-server assertion, not just a static-file check.
    func testCrossRenditionDriftProfileServesDifferentDiscontinuityIndexPerAudioRendition() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        // +4s so the sliding window has advanced past index 0 for every rendition (confirmed by
        // hand against HLSSlidingPlaylistComputer.window()'s cumulative-duration walk): this is
        // required to bring audio-en's discontinuity (true global index 4) inside a 4-segment
        // window at all — at elapsed=0 the window is [0,1,2,3], which cannot include index 4.
        let now = startedAt.addingTimeInterval(4.0)
        let server = HLSFixtureServer(
            profileDirectory: profileDirectory("discontinuity-cross-rendition-drift"),
            startedAt: startedAt,
            clock: { now }
        )

        // The served window doesn't necessarily start at global segment index 0 — its start is
        // the `#EXT-X-MEDIA-SEQUENCE` value. A real HLS client reconstructs the absolute segment
        // index the same way: mediaSequence + position-within-the-served-window.
        func trueGlobalIndexOfFirstDiscontinuity(atPath path: String) -> Int? {
            let response = server.response(forPath: path, method: "GET", rangeHeader: nil)
            XCTAssertEqual(response.status, 200, "\(path) status")
            let text = String(decoding: response.body, as: UTF8.self)
            var mediaSequence: Int?
            var precedingSegmentCountInWindow = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                    mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count))
                }
                if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                    guard let mediaSequence else { return nil }
                    return mediaSequence + precedingSegmentCountInWindow
                }
                if line.hasPrefix("#EXTINF") {
                    precedingSegmentCountInWindow += 1
                }
            }
            return nil
        }

        let videoIndex = trueGlobalIndexOfFirstDiscontinuity(atPath: "/video-lo/stream.m3u8")
        let audioEnIndex = trueGlobalIndexOfFirstDiscontinuity(atPath: "/audio-en/stream.m3u8")
        let audioAdIndex = trueGlobalIndexOfFirstDiscontinuity(atPath: "/audio-ad/stream.m3u8")

        XCTAssertEqual(videoIndex, 2, "video-lo discontinuity should precede the 3rd segment")
        XCTAssertEqual(audioEnIndex, 4, "audio-en discontinuity should precede the 5th segment")
        XCTAssertEqual(audioAdIndex, 3, "audio-ad discontinuity should precede the 4th segment")

        // The regression this test exists to catch: if per-rendition indexing were ever
        // accidentally collapsed back to the uniform "same index on every stream" shape that
        // `discontinuity-at-switch` uses, these three would become equal instead of distinct.
        XCTAssertNotEqual(videoIndex, audioEnIndex)
        XCTAssertNotEqual(videoIndex, audioAdIndex)
        XCTAssertNotEqual(audioEnIndex, audioAdIndex)
    }
}
