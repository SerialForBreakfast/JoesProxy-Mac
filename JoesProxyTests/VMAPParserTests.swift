import XCTest
@testable import JoesProxy

final class VMAPParserTests: XCTestCase {
    func testParsesVMAPSummary() throws {
        let xml = """
        <vmap:VMAP xmlns:vmap="http://www.iab.net/videosuite/vmap" version="1.0">
          <vmap:AdBreak timeOffset="start" breakType="linear" breakId="preroll-1">
            <vmap:AdSource id="preroll" allowMultipleAds="false" followRedirects="true">
              <vmap:AdTagURI templateType="vast3">
                <![CDATA[https://ads.example.com/vast?break=preroll&token=secret]]>
              </vmap:AdTagURI>
            </vmap:AdSource>
          </vmap:AdBreak>
        </vmap:VMAP>
        """

        let summary = try XCTUnwrap(VMAPParser.parse(xml))

        XCTAssertEqual(summary.version, "1.0")
        XCTAssertEqual(summary.adBreaks.count, 1)
        XCTAssertEqual(summary.adBreaks.first?.timeOffset, "start")
        XCTAssertEqual(summary.adBreaks.first?.breakID, "preroll-1")
        XCTAssertEqual(summary.adBreaks.first?.adSourceURI, "https://ads.example.com/vast")
    }
}
