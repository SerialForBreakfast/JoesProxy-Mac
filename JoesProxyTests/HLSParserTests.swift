import XCTest
@testable import JoesProxy

final class HLSParserTests: XCTestCase {
    func testDetectsHLSManifestDiscoveryFromPlaybackAPIResponse() throws {
        // Neutral hand-authored discovery payload (no vendor capture bytes / gzip).
        let responseJSON = """
        {
          "streamingUrl": "https://bakery.cdn.example.com/stream/2413361_fp_fmp4_hls/master.m3u8",
          "url": "https://drm.example.com/license?ContentId=BcTZQV_RJe6L3UVVY9PTN4rHb6_wKquY",
          "time_events_url": "https://events.example.com/time-events",
          "manifest_format": "hls",
          "contentId": "BcTZQV_RJe6L3UVVY9PTN4rHb6_wKquY",
          "daiCmsId": "2606681"
        }
        """
        let responseBody = Data(responseJSON.utf8)

        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "api.example.com",
                port: 443,
                path: "/apps-api/v3.3/ipad/irdeto-control/session-token.json?contentId=BcTZQV_RJe6L3UVVY9PTN4rHb6_wKquY",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [
                    HTTPHeaderField(name: "Content-Type", value: "application/json")
                ],
                bodyData: responseBody,
                bodySize: responseBody.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )

        XCTAssertEqual(MediaDetector.mediaType(for: session), .hlsDiscovery)

        let discovery = try XCTUnwrap(MediaDetector.hlsDiscovery(for: session))
        XCTAssertEqual(discovery.kind, .content)
        XCTAssertEqual(discovery.contentID, "BcTZQV_RJe6L3UVVY9PTN4rHb6_wKquY")
        XCTAssertEqual(discovery.daiCMSID, "2606681")
        XCTAssertEqual(discovery.manifestURL.host, "bakery.cdn.example.com")
        XCTAssertTrue(discovery.manifestURL.absoluteString.hasSuffix("/2413361_fp_fmp4_hls/master.m3u8"))
        XCTAssertEqual(discovery.drmLicenseURL?.host, "drm.example.com")
    }

    func testParsesMasterPlaylistVariantsAndMediaGroups() throws {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-main",NAME="English Audio Description",LANGUAGE="en",ASSOC-LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,CHARACTERISTICS="public.accessibility.describes-video",CHANNELS="2",URI="audio/en/prog.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=3200000,AVERAGE-BANDWIDTH=2800000,RESOLUTION=1920x1080,FRAME-RATE=29.97,VIDEO-RANGE=PQ,HDCP-LEVEL=TYPE-0,CODECS="avc1.640028,mp4a.40.2",AUDIO="audio-main"
        video/1080/prog.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=1280x720,VIDEO-RANGE=SDR,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="audio-main"
        https://cdn.example.com/video/720/prog.m3u8
        """

        let parsed = HLSParser.parse(
            manifest,
            baseURL: URL(string: "https://stream.example.com/live/master.m3u8")
        )

        XCTAssertTrue(parsed.isMasterPlaylist)
        XCTAssertEqual(parsed.version, 7)
        XCTAssertEqual(parsed.variants.count, 2)
        XCTAssertEqual(parsed.mediaGroups.count, 1)
        XCTAssertEqual(parsed.mediaGroups.first?.type, "AUDIO")
        XCTAssertEqual(parsed.mediaGroups.first?.groupID, "audio-main")
        XCTAssertEqual(parsed.mediaGroups.first?.language, "en")
        XCTAssertEqual(parsed.mediaGroups.first?.associatedLanguage, "en")
        XCTAssertEqual(parsed.mediaGroups.first?.channels, "2")
        XCTAssertEqual(parsed.mediaGroups.first?.characteristics, ["public.accessibility.describes-video"])
        XCTAssertFalse(parsed.mediaGroups.first?.isDefault ?? true)
        XCTAssertTrue(parsed.mediaGroups.first?.autoSelect ?? false)
        XCTAssertEqual(parsed.mediaGroups.first?.uri, "https://stream.example.com/live/audio/en/prog.m3u8")

        let firstVariant = try XCTUnwrap(parsed.variants.first)
        XCTAssertEqual(firstVariant.bandwidth, 3_200_000)
        XCTAssertEqual(firstVariant.averageBandwidth, 2_800_000)
        XCTAssertEqual(firstVariant.resolution, "1920x1080")
        XCTAssertEqual(try XCTUnwrap(firstVariant.frameRate), 29.97, accuracy: 0.001)
        XCTAssertEqual(firstVariant.videoRange, "PQ")
        XCTAssertEqual(firstVariant.hdcpLevel, "TYPE-0")
        XCTAssertEqual(firstVariant.audioGroupID, "audio-main")
        XCTAssertEqual(firstVariant.uri, "https://stream.example.com/live/video/1080/prog.m3u8")
        XCTAssertEqual(parsed.videoRanges, ["PQ", "SDR"])
        XCTAssertEqual(parsed.hdcpLevels, ["TYPE-0"])
        XCTAssertTrue(parsed.referencedHosts.contains("stream.example.com"))
        XCTAssertTrue(parsed.referencedHosts.contains("cdn.example.com"))
    }

    func testParsesMediaPlaylistSegmentsKeysAndAdBreakTimeline() throws {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/key"
        #EXT-X-PROGRAM-DATE-TIME:2026-04-07T12:00:00Z
        #EXTINF:6.0,
        segment-001.ts
        #EXT-X-CUE-OUT:12.0
        #EXT-X-PROGRAM-DATE-TIME:2026-04-07T12:00:06Z
        #EXTINF:6.0,
        ad-001.ts
        #EXT-X-BYTERANGE:1200@0
        #EXTINF:6.0,
        ad-002.ts
        #EXT-X-CUE-IN
        #EXT-X-DATERANGE:ID="postroll",DURATION=10.0,SCTE35-OUT=0xFC30,X-ASSET-LIST="promo",X-CUSTOM-TRACK="alt"
        #EXT-X-DISCONTINUITY
        #EXTINF:6.0,
        segment-002.ts
        """

        let parsed = HLSParser.parse(
            manifest,
            baseURL: URL(string: "https://video.example.com/hls/media/prog.m3u8")
        )

        XCTAssertFalse(parsed.isMasterPlaylist)
        XCTAssertEqual(parsed.targetDuration, 6.0)
        XCTAssertEqual(parsed.initializationSegmentURI, "https://video.example.com/hls/media/init.mp4")
        XCTAssertEqual(parsed.keys.first?.uri, "https://keys.example.com/key")
        XCTAssertEqual(parsed.segmentCount, 4)
        XCTAssertEqual(parsed.segments.count, 4)
        XCTAssertEqual(parsed.programDateTimes.count, 2)
        XCTAssertEqual(parsed.segments[0].programDateTime, "2026-04-07T12:00:00Z")
        XCTAssertEqual(parsed.segments[1].programDateTime, "2026-04-07T12:00:06Z")

        let secondSegment = parsed.segments[1]
        XCTAssertEqual(try XCTUnwrap(secondSegment.startTime), 6.0, accuracy: 0.001)
        XCTAssertTrue(secondSegment.isAdSegment)
        XCTAssertEqual(secondSegment.uri, "https://video.example.com/hls/media/ad-001.ts")

        let thirdSegment = parsed.segments[2]
        XCTAssertEqual(thirdSegment.byteRange, "1200@0")
        XCTAssertTrue(thirdSegment.isAdSegment)

        let lastSegment = parsed.segments[3]
        XCTAssertTrue(lastSegment.isDiscontinuityBoundary)
        XCTAssertTrue(lastSegment.isAdSegment)

        XCTAssertEqual(parsed.adBreaks.count, 2)
        XCTAssertEqual(parsed.adBreaks[0].cueType, "CUE-OUT")
        XCTAssertEqual(parsed.adBreaks[0].startTime, 6.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(parsed.adBreaks[0].endTime), 18.0, accuracy: 0.001)
        XCTAssertEqual(parsed.adBreaks[1].cueType, "DATERANGE")
        XCTAssertEqual(try XCTUnwrap(parsed.adBreaks[1].duration), 10.0, accuracy: 0.001)
        XCTAssertEqual(parsed.adMarkers.last?.scte35Out, "0xFC30")
        XCTAssertEqual(parsed.vendorDateRangeAttributes["X-ASSET-LIST"], ["promo"])
        XCTAssertEqual(parsed.vendorDateRangeAttributes["X-CUSTOM-TRACK"], ["alt"])
    }

    func testRelativeSegmentURIKeepsVirtualSequenceQuerySeparateFromPath() throws {
        let manifest = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg-014.ts?jp_hls_sequence=15
        """

        let parsed = HLSParser.parse(
            manifest,
            baseURL: URL(string: "http://127.0.0.1:9090/video-1080/stream.m3u8")
        )

        let segmentURL = try XCTUnwrap(URL(string: try XCTUnwrap(parsed.segments.first?.uri)))
        XCTAssertEqual(segmentURL.path, "/video-1080/seg-014.ts")
        XCTAssertEqual(segmentURL.query, "jp_hls_sequence=15")
    }

    func testParsesContentSteeringTag() throws {
        let manifest = """
        #EXTM3U
        #EXT-X-CONTENT-STEERING:SERVER-URI="https://steering.example.com/steering.json",PATHWAY-ID="cdn-a",RELOAD-URI="https://steering.example.com/reload"
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720
        video.m3u8
        """

        let parsed = HLSParser.parse(
            manifest,
            baseURL: URL(string: "https://stream.example.com/master.m3u8")
        )

        let steering = try XCTUnwrap(parsed.contentSteering)
        XCTAssertEqual(steering.serverURI, "https://steering.example.com/steering.json")
        XCTAssertEqual(steering.pathwayID, "cdn-a")
        XCTAssertEqual(steering.reloadURI, "https://steering.example.com/reload")
    }
}
