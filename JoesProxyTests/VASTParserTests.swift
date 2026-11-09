import XCTest
@testable import JoesProxy

final class VASTParserTests: XCTestCase {
    func testParsesInlineVASTSummary() throws {
        let xml = """
        <VAST version="4.2">
          <Ad id="ad-1">
            <InLine>
              <Impression><![CDATA[https://track.example.com/imp?token=secret]]></Impression>
              <Creatives>
                <Creative AdID="creative-1" sequence="1">
                  <Linear>
                    <Duration>00:00:15.000</Duration>
                    <MediaFiles>
                      <MediaFile delivery="progressive" type="video/mp4" width="1280" height="720">
                        <![CDATA[https://cdn.example.com/ad.mp4?sig=abc]]>
                      </MediaFile>
                    </MediaFiles>
                  </Linear>
                </Creative>
              </Creatives>
            </InLine>
          </Ad>
        </VAST>
        """

        let summary = try XCTUnwrap(VASTParser.parse(xml))

        XCTAssertEqual(summary.version, "4.2")
        XCTAssertEqual(summary.ads.count, 1)
        XCTAssertEqual(summary.ads.first?.kind, .inline)
        XCTAssertEqual(summary.impressionURLCount, 1)
        XCTAssertEqual(try XCTUnwrap(summary.ads.first?.creatives.first?.durationSeconds), 15, accuracy: 0.001)
        XCTAssertEqual(
            summary.ads.first?.creatives.first?.mediaFiles.first?.urlRedacted,
            "https://cdn.example.com/ad.mp4"
        )
    }

    func testParsesWrapperVASTSummary() throws {
        let xml = """
        <VAST version="3.0">
          <Ad id="wrapper-1">
            <Wrapper>
              <Impression>https://track.example.com/wrapper-imp?x=1</Impression>
              <VASTAdTagURI><![CDATA[https://secondary.example.com/vast.xml?campaign=1]]></VASTAdTagURI>
            </Wrapper>
          </Ad>
        </VAST>
        """

        let summary = try XCTUnwrap(VASTParser.parse(xml))

        XCTAssertEqual(summary.ads.first?.kind, .wrapper)
        XCTAssertEqual(summary.maxWrapperDepth, 1)
        XCTAssertEqual(
            summary.ads.first?.wrapperURLRedacted,
            "https://secondary.example.com/vast.xml"
        )
    }
}
