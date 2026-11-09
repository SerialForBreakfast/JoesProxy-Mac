//
//  MCPCMCDTelemetryTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP CMCD and CMSD telemetry inspection endpoints.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPCMCDTelemetryTests: XCTestCase {

    func testMCPCMCDTelemetryInspectionEndpoint() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        // 1. Session with healthy CMCD headers
        let s1 = makeSession(
            path: "/seg1.m4s",
            headers: [
                HTTPHeaderField(name: "CMCD-Request", value: "br=2500,bl=12000,mtp=9000"),
                HTTPHeaderField(name: "CMCD-Session", value: "sid=\"user-session-1\",sf=h")
            ]
        )
        store.append(s1)

        // 2. Session with critical buffer drop
        let s2 = makeSession(
            path: "/seg2.m4s",
            headers: [
                HTTPHeaderField(name: "CMCD-Request", value: "br=5000,bl=800,mtp=1200")
            ]
        )
        store.append(s2)

        let result = try service.cmcdTelemetryInspection(
            sessionIDs: [s1.id, s2.id],
            policyRevision: .initial
        )

        XCTAssertEqual(result.totalSessionsInspected, 2)
        XCTAssertEqual(result.sessionsWithCMCDCount, 2)
        XCTAssertEqual(result.criticalAnomaliesCount, 1) // s2 has critical buffer drop & throughput underflow
        XCTAssertEqual(result.reports.count, 2)

        let r1 = result.reports.first(where: { $0.sessionID == s1.id.uuidString })
        XCTAssertNotNil(r1)
        XCTAssertEqual(r1?.cmcd.encodedBitrateKbps, 2500)
        XCTAssertEqual(r1?.cmcd.bufferLengthMs, 12000)
        XCTAssertEqual(r1?.cmcd.sessionID, "user-session-1")
        XCTAssertEqual(r1?.healthScore, 100.0)

        let r2 = result.reports.first(where: { $0.sessionID == s2.id.uuidString })
        XCTAssertNotNil(r2)
        XCTAssertEqual(r2?.cmcd.bufferLengthMs, 800)
        XCTAssertLessThan(r2?.healthScore ?? 100.0, 70.0)
        XCTAssertFalse(r2?.anomalies.isEmpty ?? true)
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        headers: [HTTPHeaderField]
    ) -> SessionRecord {
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "cdn.example.com",
            port: 443,
            path: path,
            headers: headers,
            bodyData: nil,
            bodySize: nil
        )

        let response = CapturedResponse(
            statusCode: 200,
            headers: [
                HTTPHeaderField(name: "Content-Type", value: "video/mp4"),
                HTTPHeaderField(name: "Content-Length", value: "500000")
            ],
            bodyData: Data(count: 1000),
            bodySize: 1000
        )

        var timing = SessionTiming(startedAt: Date())
        timing.completedAt = timing.startedAt.addingTimeInterval(0.25)

        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: timing
        )
    }
}
