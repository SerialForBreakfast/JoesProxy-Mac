import XCTest
@testable import JoesProxy

final class HLSJITPublicationTests: XCTestCase {

    private func profileDirectory(for id: String) -> URL {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Fixtures/HLS/\(id)", isDirectory: true)
    }

    func testFineGridProfileStructureAndDurations() throws {
        let dir = profileDirectory(for: "audio-hybrid-inband-program-ad-fine-grid")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))

        let descriptor = HLSFixtureProfileDescriptor.load(from: dir)
        XCTAssertEqual(descriptor.audioTopology, "hybridInBandProgramAD")
        XCTAssertEqual(descriptor.audioRenditions?.count, 2)

        let program = try XCTUnwrap(descriptor.audioRenditions?.first(where: { $0.name == "English Program" }))
        XCTAssertEqual(program.segmentGridDuration, 6.0)

        let ad = try XCTUnwrap(descriptor.audioRenditions?.first(where: { $0.name == "English Audio Description" }))
        XCTAssertEqual(ad.segmentGridDuration, 3.0)

        // Video should have 15 segments of 6s each = 90s
        let videoPlaylistText = try String(contentsOf: dir.appendingPathComponent("video-360/stream.m3u8"), encoding: .utf8)
        let videoParsed = HLSStaticPlaylistParser.parse(videoPlaylistText)
        XCTAssertEqual(videoParsed.segments.count, 15)

        // AD should have 30 segments of 3s each = 90s
        let adPlaylistText = try String(contentsOf: dir.appendingPathComponent("audio-ad/stream.m3u8"), encoding: .utf8)
        let adParsed = HLSStaticPlaylistParser.parse(adPlaylistText)
        XCTAssertEqual(adParsed.segments.count, 30)
        let totalADDuration = adParsed.segments.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(totalADDuration, 90.0, accuracy: 0.1)
    }

    func testJITPublicationStateLaggingByOneIntervalWithholdsLatestSegment() {
        let segments = (0..<10).map {
            HLSStaticSegment(uri: "seg-\($0).ts", duration: 6.0, hasDiscontinuityBefore: false, keyLine: nil)
        }
        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        // Elapsed 24 seconds = 4 segments completed
        let now = startedAt.addingTimeInterval(24.0)

        var configNormal = HLSPlaybackConfiguration.conformant
        configNormal.presentationMode = .liveLoop
        configNormal.timeShiftMode = .warmDVR
        configNormal.windowSegmentCount = 4
        configNormal.jitPublicationState = .current

        let windowNormal = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 6,
            startedAt: startedAt,
            now: now,
            configuration: configNormal
        )

        var configLag = configNormal
        configLag.jitPublicationState = .laggingByOneInterval

        let windowLag = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 6,
            startedAt: startedAt,
            now: now,
            configuration: configLag
        )

        XCTAssertEqual(
            windowLag.newestPublishedSequence,
            (windowNormal.newestPublishedSequence ?? 0) - 1,
            "Lagging by 1 interval should withhold the latest published segment"
        )
    }

    func testJITPublicationStateInitiallyAbsentReturnsEmptyWindowDuringInitialPeriod() {
        let segments = (0..<10).map {
            HLSStaticSegment(uri: "seg-\($0).ts", duration: 6.0, hasDiscontinuityBefore: false, keyLine: nil)
        }
        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        // Elapsed 12 seconds (< window count 4 * 6s = 24s)
        let now = startedAt.addingTimeInterval(12.0)

        var configAbsent = HLSPlaybackConfiguration.conformant
        configAbsent.presentationMode = .liveLoop
        configAbsent.timeShiftMode = .warmDVR
        configAbsent.windowSegmentCount = 4
        configAbsent.jitPublicationState = .initiallyAbsent

        let windowAbsent = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 6,
            startedAt: startedAt,
            now: now,
            configuration: configAbsent
        )

        XCTAssertTrue(windowAbsent.entries.isEmpty, "Initially absent JIT state should return empty entries before initial window duration")
    }

    func testJITPublicationStatePlaylistPresentSegmentPendingReturnsUnavailableForNewest() throws {
        let segments = (0..<10).map {
            HLSStaticSegment(uri: "seg-\($0).ts", duration: 6.0, hasDiscontinuityBefore: false, keyLine: nil)
        }
        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        let now = startedAt.addingTimeInterval(24.0)

        var configPending = HLSPlaybackConfiguration.conformant
        configPending.presentationMode = .liveLoop
        configPending.timeShiftMode = .warmDVR
        configPending.windowSegmentCount = 4
        configPending.jitPublicationState = .playlistPresentSegmentPending

        let window = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 6,
            startedAt: startedAt,
            now: now,
            configuration: configPending
        )

        let newestSeq = try XCTUnwrap(window.newestPublishedSequence)
        let availabilityNewest = HLSSlidingPlaylistComputer.availability(
            ofVirtualIndex: newestSeq,
            segments: segments,
            targetDuration: 6,
            startedAt: startedAt,
            now: now,
            configuration: configPending
        )
        XCTAssertEqual(availabilityNewest, HLSSlidingPlaylistComputer.VirtualSegmentAvailability.unavailable, "Newest segment should be unavailable when segment is pending")

        let olderSeq = newestSeq - 1
        let availabilityOlder = HLSSlidingPlaylistComputer.availability(
            ofVirtualIndex: olderSeq,
            segments: segments,
            targetDuration: 6,
            startedAt: startedAt,
            now: now,
            configuration: configPending
        )
        XCTAssertEqual(availabilityOlder, HLSSlidingPlaylistComputer.VirtualSegmentAvailability.advertised, "Older segment in the window should be advertised")
    }

    func testSwitchMarkerModelRoundTrips() {
        let marker = HLSSwitchMarker(
            sourceRendition: "English Program",
            sourceTopology: "inBand",
            destinationRendition: "English Audio Description",
            destinationTopology: "uriBacked",
            videoVariant: "video-720",
            lastProgramMediaTime: 12.0,
            firstAlternateMediaTime: 12.0,
            destinationPlaylistAgeSeconds: 1.2,
            destinationLiveEdgeLagSeconds: 0.5,
            destinationGridSeconds: 3.0,
            requestedSequence: 4,
            nearestDiscontinuityTime: 30.0,
            nearestDiscontinuitySequence: 1,
            requestLatencyMilliseconds: 25.0,
            requestStatusCode: 200,
            playerAudibleTransitionObserved: true
        )

        XCTAssertEqual(marker.sourceRendition, "English Program")
        XCTAssertEqual(marker.destinationGridSeconds, 3.0)
        XCTAssertEqual(marker.requestStatusCode, 200)
    }
}
