//
//  DiscontinuityAlignmentEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for SCTE-35 ad break alignment, cross-variant discontinuity parity,
//  audio channel layout jumps, and accumulated timeline drift.
//

import XCTest
@testable import JoesProxy

final class DiscontinuityAlignmentEngineTests: XCTestCase {

    func testCrossVariantDiscontinuityMismatchDetected() {
        let masterText = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        720p.m3u8
        """
        let master = HLSParser.parse(masterText)

        let manifest1080pText = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:6.0,
        ad_seg1.ts
        """
        let manifest1080p = HLSParser.parse(manifest1080pText)

        let manifest720pText = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg1.ts
        #EXTINF:6.0,
        ad_seg1.ts
        """
        let manifest720p = HLSParser.parse(manifest720pText)

        let report = DiscontinuityAlignmentEngine.auditMultiRendition(
            masterManifest: master,
            masterURI: "master.m3u8",
            variantManifests: [
                "1080p.m3u8": manifest1080p,
                "720p.m3u8": manifest720p
            ]
        )

        XCTAssertFalse(report.isSwitchingSafe)
        XCTAssertEqual(report.variantCount, 2)
        XCTAssertTrue(report.hazards.contains(where: {
            if case .missingDiscontinuityTag = $0 { return true }
            return false
        }))
    }

    func testSegmentDurationDriftDetected() {
        let masterText = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360p.m3u8
        """
        let master = HLSParser.parse(masterText)

        let manifest1080pText = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg1.ts
        #EXTINF:6.0,
        seg2.ts
        """
        let manifest1080p = HLSParser.parse(manifest1080pText)

        let manifest360pText = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg1.ts
        #EXTINF:6.25,
        seg2.ts
        """
        let manifest360p = HLSParser.parse(manifest360pText)

        let report = DiscontinuityAlignmentEngine.auditMultiRendition(
            masterManifest: master,
            masterURI: "master.m3u8",
            variantManifests: [
                "1080p.m3u8": manifest1080p,
                "360p.m3u8": manifest360p
            ]
        )

        XCTAssertTrue(report.hazards.contains(where: {
            if case .segmentDurationDrift(_, _, _, let driftMs) = $0 {
                return driftMs >= 200.0
            }
            return false
        }))
    }

    func testAudioChannelLayoutJumpAcrossAdDetected() {
        let masterText = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-surround",NAME="English",CHANNELS="6",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-stereo",NAME="Stereo",CHANNELS="2",DEFAULT=NO,AUTOSELECT=YES
        #EXT-X-DATERANGE:ID="ad-midroll-1",START-DATE="2026-08-21T12:00:00Z",PLANNED-DURATION=30.0,SCTE35-OUT=0xFC302500000000
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,AUDIO="audio-surround"
        video.m3u8
        """
        let master = HLSParser.parse(masterText)

        let report = DiscontinuityAlignmentEngine.auditMultiRendition(
            masterManifest: master,
            masterURI: "master.m3u8",
            variantManifests: [:]
        )

        XCTAssertFalse(report.isMultiplexed)
        XCTAssertEqual(report.audioTrackCount, 2)
        XCTAssertTrue(report.hazards.contains(where: {
            if case .audioLayoutMismatchAcrossAdBoundary = $0 { return true }
            return false
        }))
    }

    func testSynchronizedMultiRenditionIsSwitchingSafe() {
        let masterText = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        720p.m3u8
        """
        let master = HLSParser.parse(masterText)

        let manifest1080pText = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:6.0,
        seg2.ts
        """
        let manifest1080p = HLSParser.parse(manifest1080pText)

        let manifest720pText = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:6.0,
        seg2.ts
        """
        let manifest720p = HLSParser.parse(manifest720pText)

        let report = DiscontinuityAlignmentEngine.auditMultiRendition(
            masterManifest: master,
            masterURI: "master.m3u8",
            variantManifests: [
                "1080p.m3u8": manifest1080p,
                "720p.m3u8": manifest720p
            ]
        )

        XCTAssertTrue(report.isSwitchingSafe)
        XCTAssertEqual(report.hazards.count, 0)
    }
}
