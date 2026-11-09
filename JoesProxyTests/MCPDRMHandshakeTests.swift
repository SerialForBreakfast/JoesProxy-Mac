//
//  MCPDRMHandshakeTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP DRM license handshake inspection endpoint.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPDRMHandshakeTests: XCTestCase {

    func testMCPDRMHandshakeInspectionEndpoint() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fps.example.com/asset-gold",KEYFORMAT="com.apple.streamingkeydelivery",IV=0x00000000000000000000000000000001
        #EXTINF:6.0,
        seg1.m4s
        """

        let manifestSession = makeSession(path: "/manifest.m3u8", text: manifest)
        store.append(manifestSession)

        let licenseSession = makeSession(
            path: "/fps/license?contentId=asset-gold",
            text: "encrypted-ckc",
            headers: [HTTPHeaderField(name: "Authorization", value: "Bearer sample-token")]
        )
        store.append(licenseSession)

        let result = try service.drmHandshakeInspection(
            manifestSessionID: manifestSession.id,
            licenseSessionIDs: [licenseSession.id],
            policyRevision: .initial
        )

        XCTAssertEqual(result.drmSystem, DRMSystem.fairPlay.title)
        XCTAssertEqual(result.keyInfo?.method, "SAMPLE-AES")
        XCTAssertEqual(result.keyInfo?.contentID, "asset-gold")
        XCTAssertTrue(result.isHandshakeHealthy)
        XCTAssertEqual(result.qualityScore, 100.0)
        XCTAssertTrue(result.defects.isEmpty)
        XCTAssertEqual(result.licenseExchanges.count, 1)
        XCTAssertEqual(result.licenseExchanges[0].statusCode, 200)
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        text: String,
        headers: [HTTPHeaderField] = []
    ) -> SessionRecord {
        let bodyData = text.data(using: .utf8)
        let request = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "fps.example.com",
            port: 443,
            path: path,
            headers: headers,
            bodyData: nil,
            bodySize: nil
        )

        let response = CapturedResponse(
            statusCode: 200,
            headers: [
                HTTPHeaderField(name: "Content-Type", value: "application/octet-stream"),
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
