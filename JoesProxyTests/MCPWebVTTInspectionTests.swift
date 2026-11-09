//
//  MCPWebVTTInspectionTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP WebVTT subtitle and caption track inspection endpoints.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPWebVTTInspectionTests: XCTestCase {

    func testMCPWebVTTInspectionEndpoint() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        let vtt = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        00:01.000 --> 00:05.000
        This is a very long line that exceeds standard 42 characters limit for subtitles.

        00:04.000 --> 00:07.000
        Overlapping cue.
        """

        let session = makeSession(path: "/subtitles/en.vtt", content: vtt)
        store.append(session)

        let result = try service.webvttSubtitleInspection(
            sessionID: session.id,
            policyRevision: .initial
        )

        XCTAssertEqual(result.cueCount, 2)
        XCTAssertEqual(result.hasTimestampMap, true)
        XCTAssertEqual(result.mpegtsOffsetPTS, 900000)
        XCTAssertFalse(result.isSyncSafe) // Has overlapping cues
        XCTAssertGreaterThan(result.defects.count, 0)
        XCTAssertEqual(result.cues.count, 2)
        XCTAssertEqual(result.cues[0].startTimeSeconds, 1.0)
        XCTAssertEqual(result.cues[0].endTimeSeconds, 5.0)
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        content: String
    ) -> SessionRecord {
        let bodyData = content.data(using: .utf8)
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "cdn.example.com",
            port: 443,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        let response = CapturedResponse(
            statusCode: 200,
            headers: [
                HTTPHeaderField(name: "Content-Type", value: "text/vtt"),
                HTTPHeaderField(name: "Content-Length", value: "\(bodyData?.count ?? 0)")
            ],
            bodyData: bodyData,
            bodySize: bodyData?.count
        )

        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}
