//
//  VASTCompanionParserTests.swift
//  JoesProxyTests
//
//  Unit tests for VAST Companion Ads XML parsing (Static, HTML, and IFrame resources).
//

import XCTest
@testable import JoesProxy

final class VASTCompanionParserTests: XCTestCase {

    private let vastWithCompanions = """
    <VAST version="4.0">
      <Ad id="ad-100">
        <InLine>
          <Creatives>
            <Creative id="creative-1" sequence="1">
              <Linear>
                <Duration>00:00:15</Duration>
                <MediaFiles>
                  <MediaFile type="video/mp4" width="1920" height="1080">https://cdn.example.com/ad.mp4</MediaFile>
                </MediaFiles>
              </Linear>
              <CompanionAds>
                <Companion id="comp-300x250" width="300" height="250" assetWidth="300" assetHeight="250">
                  <StaticResource creativeType="image/jpeg">https://cdn.example.com/companion_banner.jpg</StaticResource>
                  <CompanionClickThrough>https://advertiser.example.com/landing</CompanionClickThrough>
                  <CompanionClickTracking>https://analytics.example.com/companion-click</CompanionClickTracking>
                  <AltText>300x250 Companion Banner</AltText>
                </Companion>
                <Companion id="comp-html" width="728" height="90">
                  <HTMLResource><![CDATA[<div>Custom Interactive HTML Ad</div>]]></HTMLResource>
                </Companion>
                <Companion id="comp-iframe" width="300" height="60">
                  <IFrameResource>https://cdn.example.com/iframe_widget.html</IFrameResource>
                </Companion>
              </CompanionAds>
            </Creative>
          </Creatives>
        </InLine>
      </Ad>
    </VAST>
    """

    func testVASTCompanionAdsExtraction() {
        let summary = VASTParser.parse(vastWithCompanions)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.ads.count, 1)

        let creative = summary?.ads.first?.creatives.first
        XCTAssertNotNil(creative)
        XCTAssertEqual(creative?.companionCount, 3)
        XCTAssertEqual(creative?.companions.count, 3)

        // 1. Static Resource Companion
        let comp1 = creative?.companions[0]
        XCTAssertEqual(comp1?.id, "comp-300x250")
        XCTAssertEqual(comp1?.width, 300)
        XCTAssertEqual(comp1?.height, 250)
        XCTAssertEqual(comp1?.dimensionString, "300x250")
        XCTAssertEqual(comp1?.altText, "300x250 Companion Banner")
        XCTAssertEqual(comp1?.clickTrackers.count, 1)

        if case .staticResource(let mime, _) = comp1?.resource {
            XCTAssertEqual(mime, "image/jpeg")
        } else {
            XCTFail("Expected StaticResource for comp1")
        }

        // 2. HTML Resource Companion
        let comp2 = creative?.companions[1]
        XCTAssertEqual(comp2?.id, "comp-html")
        XCTAssertEqual(comp2?.width, 728)
        XCTAssertEqual(comp2?.height, 90)
        if case .htmlResource(let content) = comp2?.resource {
            XCTAssertTrue(content.contains("Custom Interactive HTML Ad"))
        } else {
            XCTFail("Expected HTMLResource for comp2")
        }

        // 3. IFrame Resource Companion
        let comp3 = creative?.companions[2]
        XCTAssertEqual(comp3?.id, "comp-iframe")
        XCTAssertEqual(comp3?.width, 300)
        XCTAssertEqual(comp3?.height, 60)
        if case .iFrameResource(let url) = comp3?.resource {
            XCTAssertTrue(url.contains("iframe_widget.html"))
        } else {
            XCTFail("Expected IFrameResource for comp3")
        }
    }
}
