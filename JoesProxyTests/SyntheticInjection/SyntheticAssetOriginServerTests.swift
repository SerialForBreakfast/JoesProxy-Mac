//
//  SyntheticAssetOriginServerTests.swift
//  JoesProxyTests
//
//  Unit tests for virtual synthetic asset origin matching and HTTP response generation.
//

import XCTest
@testable import JoesProxy

@MainActor
final class SyntheticAssetOriginServerTests: XCTestCase {

    func testIsSyntheticHost() {
        XCTAssertTrue(SyntheticAssetOriginServer.isSyntheticHost("assets.joesproxy.invalid"))
        XCTAssertTrue(SyntheticAssetOriginServer.isSyntheticHost("ASSETS.JOESPROXY.INVALID"))
        XCTAssertTrue(SyntheticAssetOriginServer.isSyntheticHost("synthetic.joesproxy.invalid"))
        XCTAssertTrue(SyntheticAssetOriginServer.isSyntheticHost("custom.synthetic.joesproxy.invalid"))

        XCTAssertFalse(SyntheticAssetOriginServer.isSyntheticHost("api.example.com"))
        XCTAssertFalse(SyntheticAssetOriginServer.isSyntheticHost("127.0.0.1"))
        XCTAssertFalse(SyntheticAssetOriginServer.isSyntheticHost("joesproxy.invalid"))
    }

    func testTestPatternPNGResponse() {
        let server = SyntheticAssetOriginServer.shared
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "assets.joesproxy.invalid",
            port: 443,
            path: "/fixtures/images/test_pattern.png",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        let response = server.response(for: request)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.headers.first(where: { $0.name == "Content-Type" })?.value, "image/png")
        XCTAssertFalse(response?.bodyData.isEmpty ?? true)
    }

    func testVASTSampleXMLResponse() {
        let server = SyntheticAssetOriginServer.shared
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "assets.joesproxy.invalid",
            port: 443,
            path: "/fixtures/ads/vast_linear_sample.xml",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        let response = server.response(for: request)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.headers.first(where: { $0.name == "Content-Type" })?.value, "application/xml; charset=utf-8")
        let xmlString = String(data: response?.bodyData ?? Data(), encoding: .utf8)
        XCTAssertTrue(xmlString?.contains("<VAST") ?? false)
    }

    func testClearVODPlaylistResponse() {
        let server = SyntheticAssetOriginServer.shared
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "assets.joesproxy.invalid",
            port: 443,
            path: "/fixtures/hls/clear_vod_scte35.m3u8",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        let response = server.response(for: request)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.headers.first(where: { $0.name == "Content-Type" })?.value, "application/vnd.apple.mpegurl")
        let m3u8 = String(data: response?.bodyData ?? Data(), encoding: .utf8)
        XCTAssertTrue(m3u8?.contains("#EXTM3U") ?? false)
        XCTAssertTrue(m3u8?.contains("#EXT-X-CUE-OUT") ?? false)
    }

    func testClearLivePlaylistResponse() {
        let server = SyntheticAssetOriginServer.shared
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "assets.joesproxy.invalid",
            port: 443,
            path: "/fixtures/hls/clear_live_profile.m3u8",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        let response = server.response(for: request)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.headers.first(where: { $0.name == "Content-Type" })?.value, "application/vnd.apple.mpegurl")
        let m3u8 = String(data: response?.bodyData ?? Data(), encoding: .utf8)
        XCTAssertTrue(m3u8?.contains("#EXT-X-MEDIA-SEQUENCE") ?? false)
    }
}
