//
//  ByteRangeAuditorEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for HTTP Range header parsing, 200 OK vs 206 Partial Content
//  bandwidth waste calculation, and CDN edge cache hit ratio auditing.
//

import XCTest
@testable import JoesProxy

final class ByteRangeAuditorEngineTests: XCTestCase {

    func testFullContent200OKServedForRangeRequest() {
        let reqHeaders = [
            HTTPHeaderField(name: "Range", value: "bytes=0-4095")
        ]
        let respHeaders = [
            HTTPHeaderField(name: "Content-Type", value: "video/mp4"),
            HTTPHeaderField(name: "Content-Length", value: "10485760"), // 10MB
            HTTPHeaderField(name: "CF-Cache-Status", value: "MISS")
        ]

        let session = makeSession(
            path: "/video.mp4",
            statusCode: 200,
            reqHeaders: reqHeaders,
            respHeaders: respHeaders,
            bodySize: 10485760
        )

        let report = ByteRangeAuditorEngine.audit(sessions: [session])

        XCTAssertEqual(report.totalTransactions, 1)
        XCTAssertEqual(report.fullContent200Count, 1)
        XCTAssertEqual(report.partialContent206Count, 0)
        XCTAssertEqual(report.totalRequestedBytes, 4096)
        XCTAssertEqual(report.totalTransferredBytes, 10485760)
        XCTAssertEqual(report.totalRedundantBytes, 10485760 - 4096)
        XCTAssertGreaterThan(report.overallWastePercentage, 99.0)
        XCTAssertFalse(report.isEfficient)
        XCTAssertTrue(report.defects.contains(where: {
            if case .fullContentServedForRangeRequest = $0 { return true }
            return false
        }))
    }

    func testCompliant206PartialContent() {
        let reqHeaders = [
            HTTPHeaderField(name: "Range", value: "bytes=1000-4999")
        ]
        let respHeaders = [
            HTTPHeaderField(name: "Content-Type", value: "video/mp4"),
            HTTPHeaderField(name: "Content-Range", value: "bytes 1000-4999/50000000"),
            HTTPHeaderField(name: "Content-Length", value: "4000"),
            HTTPHeaderField(name: "CF-Cache-Status", value: "HIT")
        ]

        let session = makeSession(
            path: "/stream/seg.m4s",
            statusCode: 206,
            reqHeaders: reqHeaders,
            respHeaders: respHeaders,
            bodySize: 4000
        )

        let report = ByteRangeAuditorEngine.audit(sessions: [session])

        XCTAssertEqual(report.totalTransactions, 1)
        XCTAssertEqual(report.partialContent206Count, 1)
        XCTAssertEqual(report.fullContent200Count, 0)
        XCTAssertEqual(report.totalRequestedBytes, 4000)
        XCTAssertEqual(report.totalTransferredBytes, 4000)
        XCTAssertEqual(report.totalRedundantBytes, 0)
        XCTAssertEqual(report.overallWastePercentage, 0.0)
        XCTAssertEqual(report.cacheHitRatio, 1.0)
        XCTAssertEqual(report.efficiencyScore, 100.0)
        XCTAssertTrue(report.isEfficient)
    }

    func testCDNCacheHitRatioCalculation() {
        let s1 = makeSession(
            path: "/seg1.m4s",
            statusCode: 206,
            reqHeaders: [HTTPHeaderField(name: "Range", value: "bytes=0-999")],
            respHeaders: [HTTPHeaderField(name: "CF-Cache-Status", value: "HIT"), HTTPHeaderField(name: "Content-Length", value: "1000")],
            bodySize: 1000
        )

        let s2 = makeSession(
            path: "/seg2.m4s",
            statusCode: 206,
            reqHeaders: [HTTPHeaderField(name: "Range", value: "bytes=0-999")],
            respHeaders: [HTTPHeaderField(name: "CF-Cache-Status", value: "MISS"), HTTPHeaderField(name: "Content-Length", value: "1000")],
            bodySize: 1000
        )

        let report = ByteRangeAuditorEngine.audit(sessions: [s1, s2])

        XCTAssertEqual(report.totalTransactions, 2)
        XCTAssertEqual(report.cacheHitRatio, 0.5)
    }

    func testRangeNotSatisfiable416() {
        let session = makeSession(
            path: "/video.mp4",
            statusCode: 416,
            reqHeaders: [HTTPHeaderField(name: "Range", value: "bytes=9999999-")],
            respHeaders: [],
            bodySize: 0
        )

        let report = ByteRangeAuditorEngine.audit(sessions: [session])

        XCTAssertTrue(report.defects.contains(where: {
            if case .rangeNotSatisfiable416 = $0 { return true }
            return false
        }))
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        statusCode: Int,
        reqHeaders: [HTTPHeaderField],
        respHeaders: [HTTPHeaderField],
        bodySize: Int
    ) -> SessionRecord {
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "cdn.example.com",
            port: 443,
            path: path,
            headers: reqHeaders,
            bodyData: nil,
            bodySize: nil
        )

        let response = CapturedResponse(
            statusCode: statusCode,
            headers: respHeaders,
            bodyData: Data(count: min(bodySize, 100)),
            bodySize: bodySize
        )

        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}
