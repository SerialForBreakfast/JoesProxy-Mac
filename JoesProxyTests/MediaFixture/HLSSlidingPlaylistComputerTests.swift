import XCTest
#if !JOESPROXY_CAPTION_CONTRACT_TESTS
@testable import JoesProxy
#endif

final class HLSSlidingPlaylistComputerTests: XCTestCase {
    func testLongElapsedDVRRemainsBoundedAndRejectsUnpublishedSequences() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for shift in [HLSTimeShiftMode.warmDVR, .coldDVR] {
            var configuration = HLSPlaybackConfiguration.conformant
            configuration.presentationMode = .liveLoop
            configuration.timeShiftMode = shift
            configuration.windowSegmentCount = HLSPlaybackConfiguration.maximumWindowSegmentCount
            configuration = try configuration.validated()
            for elapsed in [4.0, 3600, 86400, 604800] {
                let now = start.addingTimeInterval(elapsed)
                let window = HLSSlidingPlaylistComputer.window(segments: segments, targetDuration: 4,
                    startedAt: start, now: now, configuration: configuration)
                XCTAssertLessThanOrEqual(window.entries.count, configuration.windowSegmentCount)
                XCTAssertLessThanOrEqual(window.advertisedDuration, Double(configuration.windowSegmentCount * 4))
                let newest = try XCTUnwrap(window.newestPublishedSequence)
                XCTAssertEqual(window.entries.last?.virtualIndex, newest)
                XCTAssertEqual(HLSSlidingPlaylistComputer.availability(ofVirtualIndex: newest + 1,
                    segments: segments, targetDuration: 4, startedAt: start, now: now,
                    configuration: configuration), .unavailable)
                XCTAssertEqual(HLSSlidingPlaylistComputer.availability(ofVirtualIndex: newest,
                    segments: segments, targetDuration: 4, startedAt: start, now: now,
                    configuration: configuration), .advertised)
                XCTAssertLessThan(HLSSlidingPlaylistComputer.render(window).utf8.count,
                    HLSFixtureLimits.maxRenderedPlaylistBytes)
            }
        }
    }

    private let segments: [HLSStaticSegment] = [
        HLSStaticSegment(uri: "seg-000.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: nil),
        HLSStaticSegment(uri: "seg-001.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: nil),
        HLSStaticSegment(uri: "seg-002.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: nil),
        HLSStaticSegment(uri: "seg-003.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: nil),
        HLSStaticSegment(uri: "seg-004.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: nil),
        HLSStaticSegment(uri: "seg-005.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: nil)
    ]

    func testWindowAtStartBeginsAtSequenceZero() {
        let start = Date()
        let window = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start
        )
        XCTAssertEqual(window.mediaSequence, 0)
        XCTAssertEqual(window.entries.map(\.segment.uri), ["seg-000.ts", "seg-001.ts", "seg-002.ts", "seg-003.ts"])
    }

    func testWindowAdvancesDeterministicallyWithElapsedTime() {
        let start = Date()
        // Legacy behavior is intentionally characterized as forward-looking: at 9 seconds the
        // selected segment is sequence 2 and the remaining entries follow it, including entries
        // whose playback time is later than `now`. HF-1 introduces a separate trailing-live mode
        // without silently changing this compatibility path.
        let window = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(9)
        )
        XCTAssertEqual(window.mediaSequence, 2)
        XCTAssertEqual(window.entries.map(\.segment.uri), ["seg-002.ts", "seg-003.ts", "seg-004.ts", "seg-005.ts"])
        XCTAssertEqual(window.entries.map(\.virtualIndex), [2, 3, 4, 5])
    }

    func testWindowLoopsThroughFiniteSegmentsIndefinitely() {
        let start = Date()
        // 25 seconds elapsed -> virtual sequence 6, which wraps to real index 0 again, but the
        // sequence number itself keeps climbing (this is what makes it "live"-shaped).
        let window = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(25)
        )
        XCTAssertEqual(window.mediaSequence, 6)
        XCTAssertEqual(window.entries.map(\.segment.uri), ["seg-000.ts", "seg-001.ts", "seg-002.ts", "seg-003.ts"])
        XCTAssertEqual(window.entries.map(\.virtualIndex), [6, 7, 8, 9])
    }

    func testConformantLoopDeclaresTimestampResetAndUsesCacheDistinctURIs() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let window = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(25),
            configuration: .conformant
        )
        let rendered = HLSSlidingPlaylistComputer.render(window)

        XCTAssertEqual(window.mediaSequence, 6)
        XCTAssertEqual(window.discontinuitySequence, 0)
        XCTAssertTrue(rendered.contains("#EXT-X-PROGRAM-DATE-TIME:"))
        XCTAssertTrue(rendered.contains("#EXT-X-DISCONTINUITY\n#EXTINF:4.000,\nseg-000.ts?jp_hls_sequence=6"))
        XCTAssertTrue(rendered.contains("seg-003.ts?jp_hls_sequence=9"))
    }

    func testConfiguredWindowCanSpanMoreThanOneAssetCycle() throws {
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.windowSegmentCount = 8
        let window = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: Date(),
            now: Date(),
            configuration: try configuration.validated()
        )

        XCTAssertEqual(window.entries.count, 8)
        XCTAssertEqual(window.entries.map(\.virtualIndex), Array(0...7))
        XCTAssertTrue(HLSSlidingPlaylistComputer.render(window).contains("seg-001.ts?jp_hls_sequence=7"))
    }

    func testLiveLoopStartsWithWarmTrailingHistory() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop

        let window = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start,
            configuration: configuration
        )

        XCTAssertEqual(window.mediaSequence, 0)
        XCTAssertEqual(window.newestPublishedSequence, 3)
        XCTAssertEqual(window.entries.map(\.virtualIndex), [0, 1, 2, 3])
        XCTAssertEqual(window.firstSegmentProgramDateTime, start.addingTimeInterval(-16))
    }

    func testWarmDVRAdvertisesImmediateBoundedHistory() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .warmDVR
        configuration.windowSegmentCount = 15

        let window = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start,
            configuration: try configuration.validated()
        )

        XCTAssertEqual(window.oldestAdvertisedSequence, 0)
        XCTAssertEqual(window.newestPublishedSequence, 14)
        XCTAssertEqual(window.entries.count, 15)
        XCTAssertEqual(window.advertisedDuration, 60)
        XCTAssertEqual(window.earliestProgramDateTime, start.addingTimeInterval(-60))
        XCTAssertEqual(window.liveEdgeProgramDateTime, start)
    }

    func testWarmDVRSupportsEarliestMiddleLiveEdgePauseAndReturnToLive() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .warmDVR
        configuration.windowSegmentCount = 15
        configuration = try configuration.validated()

        let initial = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start,
            configuration: configuration
        )
        XCTAssertEqual(initial.entries.first?.virtualIndex, 0)
        XCTAssertEqual(initial.entries[7].virtualIndex, 7)
        XCTAssertEqual(initial.entries.last?.virtualIndex, 14)

        let afterPause = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(12),
            configuration: configuration
        )
        XCTAssertEqual(afterPause.entries.map(\.virtualIndex), Array(3...17))
        XCTAssertEqual(
            HLSSlidingPlaylistComputer.availability(
                ofVirtualIndex: 7,
                segments: segments,
                targetDuration: 4,
                startedAt: start,
                now: start.addingTimeInterval(12),
                configuration: configuration
            ),
            .advertised
        )
        XCTAssertEqual(afterPause.entries.last?.virtualIndex, 17)

        XCTAssertEqual(
            HLSSlidingPlaylistComputer.availability(
                ofVirtualIndex: 0,
                segments: segments,
                targetDuration: 4,
                startedAt: start,
                now: start.addingTimeInterval(68.001),
                configuration: configuration
            ),
            .unavailable
        )
        let returnedLive = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(68.001),
            configuration: configuration
        )
        XCTAssertEqual(returnedLive.entries.last?.virtualIndex, returnedLive.newestPublishedSequence)
    }

    func testColdDVRGrowsFromEmptyAndThenTrailsTheLiveEdge() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .coldDVR
        configuration.windowSegmentCount = 4
        configuration = try configuration.validated()

        let initial = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start,
            configuration: configuration
        )
        let firstPublished = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(4),
            configuration: configuration
        )
        let trailing = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(20),
            configuration: configuration
        )

        XCTAssertTrue(initial.entries.isEmpty)
        XCTAssertNil(initial.newestPublishedSequence)
        XCTAssertEqual(firstPublished.entries.map(\.virtualIndex), [0])
        XCTAssertEqual(trailing.entries.map(\.virtualIndex), [1, 2, 3, 4])
        XCTAssertEqual(trailing.earliestProgramDateTime, start.addingTimeInterval(4))
        XCTAssertEqual(trailing.liveEdgeProgramDateTime, start.addingTimeInterval(20))
    }

    func testRecentlyEvictedSegmentHasDeterministicGraceThenExpires() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .warmDVR
        configuration.windowSegmentCount = 2
        configuration = try configuration.validated()

        XCTAssertEqual(
            HLSSlidingPlaylistComputer.availability(
                ofVirtualIndex: 0,
                segments: segments,
                targetDuration: 4,
                startedAt: start,
                now: start.addingTimeInterval(4),
                configuration: configuration
            ),
            .retainedAfterEviction(until: start.addingTimeInterval(16))
        )
        XCTAssertEqual(
            HLSSlidingPlaylistComputer.availability(
                ofVirtualIndex: 0,
                segments: segments,
                targetDuration: 4,
                startedAt: start,
                now: start.addingTimeInterval(16),
                configuration: configuration
            ),
            .retainedAfterEviction(until: start.addingTimeInterval(16))
        )
        XCTAssertEqual(
            HLSSlidingPlaylistComputer.availability(
                ofVirtualIndex: 0,
                segments: segments,
                targetDuration: 4,
                startedAt: start,
                now: start.addingTimeInterval(16.001),
                configuration: configuration
            ),
            .unavailable
        )
    }

    func testTimeShiftEvidenceFindsOldestRetainedEvictedSequence() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(12)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .warmDVR
        configuration.windowSegmentCount = 2
        configuration = try configuration.validated()
        let window = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: now,
            configuration: configuration
        )

        XCTAssertEqual(window.entries.map(\.virtualIndex), [3, 4])
        XCTAssertEqual(
            HLSSlidingPlaylistComputer.oldestRetainedButEvictedSequence(
                in: window,
                segments: segments,
                targetDuration: 4,
                startedAt: start,
                now: now
            ),
            0
        )
    }

    func testLiveLoopAdvancesOnlyAfterNextSegmentIsFullyPublished() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop

        let beforeBoundary = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(3.999),
            configuration: configuration
        )
        let atBoundary = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(4),
            configuration: configuration
        )

        XCTAssertEqual(beforeBoundary.entries.map(\.virtualIndex), [0, 1, 2, 3])
        XCTAssertEqual(beforeBoundary.newestPublishedSequence, 3)
        XCTAssertEqual(atBoundary.entries.map(\.virtualIndex), [1, 2, 3, 4])
        XCTAssertEqual(atBoundary.newestPublishedSequence, 4)
    }

    func testLiveLoopUsesFractionalDurationOfSegmentBeingPublished() {
        let fractionalSegments = [
            HLSStaticSegment(uri: "a.aac", duration: 2.25, hasDiscontinuityBefore: false, keyLine: nil),
            HLSStaticSegment(uri: "b.aac", duration: 3.5, hasDiscontinuityBefore: false, keyLine: nil),
            HLSStaticSegment(uri: "c.aac", duration: 1.75, hasDiscontinuityBefore: false, keyLine: nil)
        ]
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.windowSegmentCount = 2

        let beforeBoundary = HLSSlidingPlaylistComputer.window(
            segments: fractionalSegments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(1.749),
            configuration: configuration
        )
        let atBoundary = HLSSlidingPlaylistComputer.window(
            segments: fractionalSegments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(1.75),
            configuration: configuration
        )

        XCTAssertEqual(beforeBoundary.entries.map(\.virtualIndex), [0, 1])
        XCTAssertEqual(atBoundary.entries.map(\.virtualIndex), [1, 2])
    }

    func testLiveLoopSequencesKeepClimbingAcrossMultipleAssetLoops() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop

        let window = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(49),
            configuration: configuration
        )

        XCTAssertEqual(window.mediaSequence, 12)
        XCTAssertEqual(window.newestPublishedSequence, 15)
        XCTAssertEqual(window.entries.map(\.virtualIndex), [12, 13, 14, 15])
        XCTAssertEqual(window.entries.map(\.segment.uri), [
            "seg-000.ts", "seg-001.ts", "seg-002.ts", "seg-003.ts"
        ])
        XCTAssertEqual(window.discontinuitySequence, 1)
    }

    func testLiveLoopCarriesEvictedDiscontinuityInSequenceNumber() {
        let discontinuitySegments = [
            HLSStaticSegment(uri: "a.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: nil),
            HLSStaticSegment(uri: "b.ts", duration: 4, hasDiscontinuityBefore: true, keyLine: nil),
            HLSStaticSegment(uri: "c.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: nil)
        ]
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.windowSegmentCount = 2

        let window = HLSSlidingPlaylistComputer.window(
            segments: discontinuitySegments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(8),
            configuration: configuration
        )

        XCTAssertEqual(window.entries.map(\.virtualIndex), [2, 3])
        XCTAssertEqual(window.discontinuitySequence, 1)
        XCTAssertTrue(HLSSlidingPlaylistComputer.render(window).contains("#EXT-X-DISCONTINUITY-SEQUENCE:1"))
    }

    func testDeliberateTargetDurationFaultUnderreportsSourceValue() throws {
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.intent = .deliberateFault
        configuration.targetDurationTreatment = .underreportByOneSecond
        let window = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: Date(),
            now: Date(),
            configuration: try configuration.validated()
        )

        XCTAssertEqual(window.targetDuration, 3)
        XCTAssertTrue(HLSSlidingPlaylistComputer.render(window).contains("#EXT-X-TARGETDURATION:3"))
    }

    func testTwoCallsWithIdenticalInputsProduceIdenticalOutput() {
        let start = Date()
        let now = start.addingTimeInterval(17)
        let first = HLSSlidingPlaylistComputer.window(segments: segments, targetDuration: 4, startedAt: start, now: now)
        let second = HLSSlidingPlaylistComputer.window(segments: segments, targetDuration: 4, startedAt: start, now: now)
        XCTAssertEqual(first, second)
    }

    func testRenderIncludesMediaSequenceAndDiscontinuityAndKeyLines() {
        let discontinuitySegments: [HLSStaticSegment] = [
            HLSStaticSegment(uri: "a.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: "#EXT-X-KEY:METHOD=AES-128,URI=\"key1\""),
            HLSStaticSegment(uri: "b.ts", duration: 4, hasDiscontinuityBefore: true, keyLine: "#EXT-X-KEY:METHOD=AES-128,URI=\"key2\"")
        ]
        let window = HLSSlidingPlaylistComputer.window(
            segments: discontinuitySegments,
            targetDuration: 4,
            startedAt: Date(),
            now: Date()
        )
        let rendered = HLSSlidingPlaylistComputer.render(window)
        XCTAssertTrue(rendered.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertTrue(rendered.contains("#EXT-X-DISCONTINUITY-SEQUENCE:0"))
        XCTAssertTrue(rendered.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"key1\""))
        XCTAssertTrue(rendered.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"key2\""))
        XCTAssertTrue(rendered.contains("#EXT-X-DISCONTINUITY"))
    }

    func testDiscontinuitySequenceClimbsAcrossLoops() {
        let segments: [HLSStaticSegment] = [
            HLSStaticSegment(uri: "a.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: nil),
            HLSStaticSegment(uri: "b.ts", duration: 4, hasDiscontinuityBefore: true, keyLine: nil),
            HLSStaticSegment(uri: "c.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: nil)
        ]
        // The first entry's marker remains in the playlist, not in the header.
        XCTAssertEqual(HLSSlidingPlaylistComputer.discontinuitySequence(atVirtualIndex: 1, segments: segments), 0)
        XCTAssertEqual(HLSSlidingPlaylistComputer.discontinuitySequence(atVirtualIndex: 4, segments: segments), 1)

        let start = Date()
        // Elapsed 4s → segment 1 ("b"), whose marker is still in the body.
        let early = HLSSlidingPlaylistComputer.window(
            segments: segments,
            targetDuration: 4,
            startedAt: start,
            now: start.addingTimeInterval(4)
        )
        XCTAssertEqual(early.mediaSequence, 1)
        XCTAssertEqual(early.discontinuitySequence, 0)
        let rendered = HLSSlidingPlaylistComputer.render(early)
        XCTAssertTrue(rendered.contains("#EXT-X-DISCONTINUITY-SEQUENCE:0"))
    }

    func testOverlappingLiveWindowsPreserveEffectiveDiscontinuityNumbers() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.windowSegmentCount = 4
        for firstHasMarker in [false, true] {
            let source = [
                HLSStaticSegment(uri: "a.ts", duration: 4, hasDiscontinuityBefore: firstHasMarker, keyLine: nil),
                HLSStaticSegment(uri: "b.ts", duration: 4, hasDiscontinuityBefore: true, keyLine: nil),
                HLSStaticSegment(uri: "c.ts", duration: 4, hasDiscontinuityBefore: false, keyLine: nil)
            ]
            var observed: [Int: Int] = [:]
            for tick in 0..<30 {
                let window = HLSSlidingPlaylistComputer.window(
                    segments: source, targetDuration: 4, startedAt: start,
                    now: start.addingTimeInterval(Double(tick * 4)), configuration: configuration
                )
                var sequence = window.discontinuitySequence
                for entry in window.entries {
                    if entry.segment.hasDiscontinuityBefore || entry.isLoopBoundaryBefore { sequence += 1 }
                    if let previous = observed[entry.virtualIndex] {
                        XCTAssertEqual(sequence, previous, "Published segment changed discontinuity number")
                    }
                    observed[entry.virtualIndex] = sequence
                }
            }
            XCTAssertGreaterThan(observed.count, 30)
        }
    }

    func testEmptySegmentsProduceEmptyWindow() {
        let window = HLSSlidingPlaylistComputer.window(segments: [], targetDuration: 4, startedAt: Date(), now: Date())
        XCTAssertEqual(window.entries, [])
        XCTAssertEqual(window.mediaSequence, 0)
        XCTAssertEqual(window.discontinuitySequence, 0)
    }

    func testParserIgnoresDiscontinuitySequenceTagWhenParsingStaticPlaylists() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXT-X-DISCONTINUITY-SEQUENCE:7
        #EXTINF:4.000000,
        seg-000.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:4.000000,
        seg-001.ts
        #EXT-X-ENDLIST
        """
        let parsed = HLSStaticPlaylistParser.parse(text)
        XCTAssertEqual(parsed.segments.count, 2)
        XCTAssertFalse(parsed.segments[0].hasDiscontinuityBefore)
        XCTAssertTrue(parsed.segments[1].hasDiscontinuityBefore)
    }

    // MARK: - Parser

    func testParserExtractsSegmentsDurationsAndDiscontinuity() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:4.000000,
        seg-000.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:4.000000,
        seg-001.ts
        #EXT-X-ENDLIST
        """
        let parsed = HLSStaticPlaylistParser.parse(text)
        XCTAssertEqual(parsed.targetDuration, 4)
        XCTAssertEqual(parsed.segments.count, 2)
        XCTAssertEqual(parsed.segments[0].uri, "seg-000.ts")
        XCTAssertFalse(parsed.segments[0].hasDiscontinuityBefore)
        XCTAssertEqual(parsed.segments[1].uri, "seg-001.ts")
        XCTAssertTrue(parsed.segments[1].hasDiscontinuityBefore)
    }

    func testParserCarriesKeyLineForwardUntilSuperseded() {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=AES-128,URI="key1"
        #EXTINF:4.000000,
        a.ts
        #EXTINF:4.000000,
        b.ts
        #EXT-X-KEY:METHOD=AES-128,URI="key2"
        #EXTINF:4.000000,
        c.ts
        """
        let parsed = HLSStaticPlaylistParser.parse(text)
        XCTAssertEqual(parsed.segments.map(\.keyLine), [
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key1\"",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key1\"",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key2\""
        ])
    }
}
