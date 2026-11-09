//
//  MCPByteRangeEfficiencyTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Byte-Range and CDN cache efficiency inspection endpoint.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPByteRangeEfficiencyTests: XCTestCase {

    func testMCPByteRangeInspectionEndpoint() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        // 1. Efficient 206 session
        let s1 = makeSession(
            path: "/seg1.m4s",
            statusCode: 206,
            reqHeaders: [HTTPHeaderField(name: "Range", value: "bytes=0-1999")],
            respHeaders: [
                HTTPHeaderField(name: "Content-Range", value: "bytes 0-1999/200000"),
                HTTPHeaderField(name: "CF-Cache-Status", value: "HIT"),
                HTTPHeaderField(name: "Content-Length", value: "2000")
            ],
            bodySize: 2000
        )
        store.append(s1)

        // 2. Inefficient 200 OK session
        let s2 = makeSession(
            path: "/seg2.m4s",
            statusCode: 200,
            reqHeaders: [HTTPHeaderField(name: "Range", value: "bytes=0-1999")],
            respHeaders: [
                HTTPHeaderField(name: "CF-Cache-Status", value: "MISS"),
                HTTPHeaderField(name: "Content-Length", value: "500000")
            ],
            bodySize: 500000
        )
        store.append(s2)

        let result = try service.byteRangeEfficiencyInspection(
            sessionIDs: [s1.id, s2.id],
            policyRevision: .initial
        )

        XCTAssertEqual(result.totalTransactions, 2)
        XCTAssertEqual(result.partialContent206Count, 1)
        XCTAssertEqual(result.fullContent200Count, 1)
        XCTAssertEqual(result.totalRequestedBytes, 4000)
        XCTAssertEqual(result.totalTransferredBytes, 502000)
        XCTAssertEqual(result.totalRedundantBytes, 498000)
        XCTAssertGreaterThan(result.overallWastePercentage, 99.0)
        XCTAssertEqual(result.cacheHitRatio, 0.5)
        XCTAssertFalse(result.isEfficient)
        XCTAssertGreaterThan(result.defects.count, 0)
        XCTAssertEqual(result.transactions.count, 2)
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
