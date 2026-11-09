//
//  WebVTTEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for WebVTT cue parsing, X-TIMESTAMP-MAP sync drift,
//  overlapping cue detection, broadcast line limits, and malformed tags.
//

import XCTest
#if !JOESPROXY_CAPTION_CONTRACT_TESTS
@testable import JoesProxy
#endif

final class WebVTTEngineTests: XCTestCase {

    func testCueParsingAndTimestampCalculation() {
        let vtt = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        1
        00:00:01.500 --> 00:00:04.000
        Welcome to the live broadcast.

        2
        00:00:04.500 --> 00:00:07.250
        Enjoy the game!
        """

        let report = WebVTTEngine.parse(vttText: vtt)

        XCTAssertEqual(report.cueCount, 2)
        XCTAssertEqual(report.hasTimestampMap, true)
        XCTAssertEqual(report.mpegtsOffsetPTS, 900000)
        XCTAssertEqual(report.cues[0].startTimeSeconds, 1.5)
        XCTAssertEqual(report.cues[0].endTimeSeconds, 4.0)
        XCTAssertEqual(report.cues[0].durationSeconds, 2.5)
        XCTAssertEqual(report.cues[0].text, "Welcome to the live broadcast.")
        XCTAssertEqual(report.qualityScore, 100.0)
        XCTAssertTrue(report.defects.isEmpty)
        XCTAssertTrue(report.isSyncSafe)
    }

    func testOverlappingCuesDefectDetected() {
        let vtt = """
        WEBVTT

        00:01.000 --> 00:05.000
        First line of speech.

        00:03.500 --> 00:07.000
        Second line overlapping by 1.5 seconds.
        """

        let report = WebVTTEngine.parse(vttText: vtt)

        XCTAssertEqual(report.cueCount, 2)
        XCTAssertFalse(report.isSyncSafe)
        XCTAssertTrue(report.defects.contains(where: {
            if case .overlappingCues(let a, let b, let overlapMs) = $0 {
                return a == 0 && b == 1 && abs(overlapMs - 1500.0) < 10.0
            }
            return false
        }))
        XCTAssertLessThan(report.qualityScore, 90.0)
    }

    func testBroadcastLineLengthViolationDetected() {
        let vtt = """
        WEBVTT

        00:01.000 --> 00:04.000
        This is an excessively long subtitle line that easily exceeds the standard broadcast limit of 42 characters per line.
        """

        let report = WebVTTEngine.parse(vttText: vtt)

        XCTAssertEqual(report.cueCount, 1)
        XCTAssertTrue(report.defects.contains(where: {
            if case .excessiveLineLength(let idx, let len, let limit) = $0 {
                return idx == 0 && len > 42 && limit == 42
            }
            return false
        }))
    }

    func testUnclosedTagDefectDetected() {
        let vtt = """
        WEBVTT

        00:01.000 --> 00:04.000
        <i>Italic text without closing tag
        """

        let report = WebVTTEngine.parse(vttText: vtt)

        XCTAssertTrue(report.defects.contains(where: {
            if case .unclosedOrMalformedTag(let idx, _) = $0 {
                return idx == 0
            }
            return false
        }))
    }

    func testTimestampMapHeaderAndSyncDrift() {
        let vtt = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        00:00:00.000 --> 00:00:03.000
        Synced content.
        """

        // Expected video PTS: 10.5 seconds (900000 / 90000 = 10.0s, delta = -500ms drift)
        let report = WebVTTEngine.parse(vttText: vtt, videoPTSOffsetSeconds: 10.5)

        XCTAssertNotNil(report.syncDriftMs)
        guard let drift = report.syncDriftMs else { return }
        XCTAssertEqual(drift, -500.0, accuracy: 1.0)
        XCTAssertTrue(report.defects.contains(where: {
            if case .syncDriftFromVideo(let driftMs, _, _) = $0 {
                return abs(driftMs - (-500.0)) < 1.0
            }
            return false
        }))
    }
}
