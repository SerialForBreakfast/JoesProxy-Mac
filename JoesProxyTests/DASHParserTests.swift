import XCTest
@testable import JoesProxy

final class DASHParserTests: XCTestCase {
    func testParsesBaseURLsAndSegmentTemplates() throws {
        let xml = """
        <MPD type="dynamic" mediaPresentationDuration="PT32S">
          <BaseURL>https://cdn.example.com/root/</BaseURL>
          <Period start="PT0S">
            <BaseURL>period/</BaseURL>
            <AdaptationSet id="video-main" contentType="video" lang="en" mimeType="video/mp4" codecs="avc1.640028">
              <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main" />
              <Accessibility schemeIdUri="urn:scte:dash:cc:cea-608:2015" value="CC1=eng" />
              <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2" />
              <EventStream schemeIdUri="urn:test:event" value="ad-break" timescale="1000" />
              <BaseURL>video/</BaseURL>
              <SegmentTemplate initialization="init-$RepresentationID$.mp4" media="chunk-$Number$.m4s" timescale="1" duration="4" startNumber="7" />
              <Representation id="v1080" bandwidth="2500000" width="1920" height="1080" frameRate="30000/1001" />
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try XCTUnwrap(DASHParser.parse(xml))
        XCTAssertEqual(manifest.type, "dynamic")
        XCTAssertEqual(manifest.mediaPresentationDuration, "PT32S")
        XCTAssertEqual(manifest.baseURL, "https://cdn.example.com/root/")

        let period = try XCTUnwrap(manifest.periods.first)
        XCTAssertEqual(period.start, "PT0S")
        XCTAssertEqual(period.baseURL, "period/")
        let adaptationSet = try XCTUnwrap(period.adaptationSets.first)
        XCTAssertEqual(adaptationSet.id, "video-main")
        XCTAssertEqual(adaptationSet.contentType, "video")
        XCTAssertEqual(adaptationSet.lang, "en")
        XCTAssertEqual(adaptationSet.roles.first?.value, "main")
        XCTAssertEqual(adaptationSet.accessibility.first?.value, "CC1=eng")
        XCTAssertEqual(adaptationSet.audioChannelConfigurations.first?.value, "2")
        XCTAssertEqual(adaptationSet.eventStreams.first?.value, "ad-break")
        XCTAssertEqual(adaptationSet.eventStreams.first?.timescale, 1_000)
        XCTAssertEqual(adaptationSet.baseURL, "video/")
        XCTAssertEqual(adaptationSet.segmentTemplate?.initialization, "init-$RepresentationID$.mp4")
        XCTAssertEqual(adaptationSet.segmentTemplate?.media, "chunk-$Number$.m4s")
        XCTAssertEqual(adaptationSet.segmentTemplate?.startNumber, 7)

        let representation = try XCTUnwrap(adaptationSet.representations.first)
        XCTAssertEqual(representation.id, "v1080")
        XCTAssertNil(representation.mimeType)
        XCTAssertNil(representation.codecs)
        XCTAssertEqual(representation.bandwidth, 2_500_000)
        XCTAssertEqual(representation.frameRate, "30000/1001")
        XCTAssertNil(representation.baseURL)
        XCTAssertNil(representation.segmentTemplate)
    }

    func testRepresentationOverridesAdaptationTemplate() throws {
        let xml = """
        <MPD>
          <Period>
            <AdaptationSet mimeType="audio/mp4">
              <SegmentTemplate initialization="audio-init.mp4" media="audio-$Number$.m4s" />
              <Representation id="a1" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="128000" audioSamplingRate="48000">
                <BaseURL>audio/</BaseURL>
                <SegmentTemplate initialization="rep-init.mp4" media="rep-$Time$.m4s" />
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let manifest = try XCTUnwrap(DASHParser.parse(xml))
        let representation = try XCTUnwrap(
            manifest.periods.first?.adaptationSets.first?.representations.first
        )

        XCTAssertEqual(representation.baseURL, "audio/")
        XCTAssertEqual(representation.mimeType, "audio/mp4")
        XCTAssertEqual(representation.codecs, "mp4a.40.2")
        XCTAssertEqual(representation.audioSamplingRate, 48_000)
        XCTAssertEqual(representation.segmentTemplate?.initialization, "rep-init.mp4")
        XCTAssertEqual(representation.segmentTemplate?.media, "rep-$Time$.m4s")
    }
}
