//
//  CMCDEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for CTA-5004 CMCD and CTA-5006 CMSD parsing,
//  buffer drop detection, throughput underflow, and QoE anomalies.
//

import XCTest
@testable import JoesProxy

final class CMCDEngineTests: XCTestCase {

    func testHeaderParsingAndThroughputHeadroom() {
        let headers = [
            HTTPHeaderField(name: "CMCD-Request", value: "br=2500,d=4000,ot=v,bl=12500,dl=3500,mtp=8200"),
            HTTPHeaderField(name: "CMCD-Object", value: "tb=6000"),
            HTTPHeaderField(name: "CMCD-Status", value: "rtp=12000"),
            HTTPHeaderField(name: "CMCD-Session", value: "sid=\"session-alpha\",cid=\"content-999\",sf=h,st=v,pr=1.0")
        ]

        let report = CMCDEngine.parse(
            requestHeaders: headers,
            urlString: "https://cdn.example.com/segment12.m4s"
        )

        XCTAssertNotNil(report)
        guard let r = report else { return }

        XCTAssertEqual(r.transportMethod, .header)
        XCTAssertEqual(r.cmcd.encodedBitrateKbps, 2500)
        XCTAssertEqual(r.cmcd.objectDurationMs, 4000)
        XCTAssertEqual(r.cmcd.objectType, .video)
        XCTAssertEqual(r.cmcd.bufferLengthMs, 12500)
        XCTAssertEqual(r.cmcd.deadlineMs, 3500)
        XCTAssertEqual(r.cmcd.measuredThroughputKbps, 8200)
        XCTAssertEqual(r.cmcd.topBitrateKbps, 6000)
        XCTAssertEqual(r.cmcd.requestedThroughputKbps, 12000)
        XCTAssertEqual(r.cmcd.sessionID, "session-alpha")
        XCTAssertEqual(r.cmcd.contentID, "content-999")
        XCTAssertEqual(r.cmcd.streamingFormat, .hls)
        XCTAssertEqual(r.cmcd.streamType, .vod)
        XCTAssertEqual(r.cmcd.playbackRate, 1.0)

        // Headroom: (8200 - 2500) / 2500 = +228%
        XCTAssertEqual(r.throughputHeadroomPercentage ?? 0, 228.0, accuracy: 0.01)
        XCTAssertEqual(r.healthScore, 100.0)
        XCTAssertTrue(r.anomalies.isEmpty)
    }

    func testQueryStringParsing() {
        let url = "https://cdn.example.com/stream/segment.m4s?CMCD=br%3D3000%2Cbl%3D9500%2Csid%3D%22web-client-42%22"

        let report = CMCDEngine.parse(
            requestHeaders: [],
            urlString: url
        )

        XCTAssertNotNil(report)
        guard let r = report else { return }

        XCTAssertEqual(r.transportMethod, .queryString)
        XCTAssertEqual(r.cmcd.encodedBitrateKbps, 3000)
        XCTAssertEqual(r.cmcd.bufferLengthMs, 9500)
        XCTAssertEqual(r.cmcd.sessionID, "web-client-42")
    }

    func testCriticalBufferDropAnomalyDetected() {
        let headers = [
            HTTPHeaderField(name: "CMCD-Request", value: "br=4000,bl=1200") // 1.2s buffer (< 2s threshold)
        ]

        let report = CMCDEngine.parse(
            requestHeaders: headers,
            urlString: "https://cdn.example.com/segment.m4s"
        )

        XCTAssertNotNil(report)
        guard let r = report else { return }

        XCTAssertTrue(r.anomalies.contains(where: {
            if case .criticalBufferDrop(let bl, let threshold) = $0 {
                return bl == 1200 && threshold == 2000
            }
            return false
        }))
        XCTAssertLessThan(r.healthScore, 80.0)
    }

    func testThroughputUnderflowAnomalyDetected() {
        let headers = [
            HTTPHeaderField(name: "CMCD-Request", value: "br=5000,mtp=2100,bl=8000") // 2.1 Mbps throughput for 5.0 Mbps segment
        ]

        let report = CMCDEngine.parse(
            requestHeaders: headers,
            urlString: "https://cdn.example.com/segment.m4s"
        )

        XCTAssertNotNil(report)
        guard let r = report else { return }

        XCTAssertTrue(r.anomalies.contains(where: {
            if case .throughputUnderflow(let mtp, let br) = $0 {
                return mtp == 2100 && br == 5000
            }
            return false
        }))
    }

    func testCMSDServerTelemetryParsing() {
        let reqHeaders = [
            HTTPHeaderField(name: "CMCD-Request", value: "br=2000,bl=6000")
        ]
        let respHeaders = [
            HTTPHeaderField(name: "CMSD-Static", value: "etp=16000,mb=8000"),
            HTTPHeaderField(name: "CMSD-Dynamic", value: "rtt=35,rd=10")
        ]

        let report = CMCDEngine.parse(
            requestHeaders: reqHeaders,
            responseHeaders: respHeaders,
            urlString: "https://cdn.example.com/seg.ts"
        )

        XCTAssertNotNil(report)
        guard let r = report else { return }

        XCTAssertNotNil(r.cmsd)
        XCTAssertEqual(r.cmsd?.estimatedThroughputKbps, 16000)
        XCTAssertEqual(r.cmsd?.maxBitrateKbps, 8000)
        XCTAssertEqual(r.cmsd?.roundTripTimeMs, 35)
        XCTAssertEqual(r.cmsd?.responseDelayMs, 10)
    }
}
