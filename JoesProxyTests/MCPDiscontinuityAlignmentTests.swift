//
//  MCPDiscontinuityAlignmentTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP SCTE-35 and multi-rendition discontinuity alignment endpoints.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPDiscontinuityAlignmentTests: XCTestCase {

    func testSCTE35AdBreakInspectionEndpoint() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        let masterText = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        /1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        /720p.m3u8
        """
        let masterSession = makeSession(path: "/master.m3u8", content: masterText, contentType: "application/vnd.apple.mpegurl")
        store.append(masterSession)

        let v1Text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:6.0,
        ad1.ts
        """
        let v1Session = makeSession(path: "/1080p.m3u8", content: v1Text, contentType: "application/vnd.apple.mpegurl")
        store.append(v1Session)

        let v2Text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg1.ts
        #EXTINF:6.0,
        ad1.ts
        """
        let v2Session = makeSession(path: "/720p.m3u8", content: v2Text, contentType: "application/vnd.apple.mpegurl")
        store.append(v2Session)

        let dto = try service.scte35AdBreakInspection(
            masterManifestSessionID: masterSession.id,
            variantSessionIDs: [v1Session.id, v2Session.id],
            policyRevision: .initial
        )

        XCTAssertEqual(dto.masterURI, "/master.m3u8")
        XCTAssertEqual(dto.variantCount, 2)
        XCTAssertFalse(dto.isSwitchingSafe) // v2 is missing discontinuity tag
        XCTAssertGreaterThan(dto.hazards.count, 0)
        XCTAssertEqual(dto.variants.count, 2)
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        content: String,
        contentType: String
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
                HTTPHeaderField(name: "Content-Type", value: contentType),
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
