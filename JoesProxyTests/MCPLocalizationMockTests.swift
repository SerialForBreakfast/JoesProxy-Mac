//
//  MCPLocalizationMockTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Localization Mock tool service endpoints.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPLocalizationMockTests: XCTestCase {

    func testMCPLocalizationServiceLifecycle() throws {
        let store = InMemorySessionStore()
        let service = MCPLocalizationMockService(sessionStore: store)

        // 1. List presets
        let presets = service.listPresets()
        XCTAssertFalse(presets.isEmpty)
        XCTAssertTrue(presets.contains(where: { $0.id == "pseudo_expansion" }))

        // 2. Mock a session
        let session = makeSession(
            path: "/feed",
            json: "{\"category\":\"Movies & TV\",\"url\":\"https://cdn.example.com/poster.jpg\"}"
        )
        store.append(session)

        // 3. Preview localization
        let dto = try service.previewLocalizationTransform(
            sessionID: session.id,
            presetID: "pseudo_expansion"
        )

        XCTAssertEqual(dto.preset, "pseudo_expansion")
        XCTAssertEqual(dto.mutatedStringCount, 1) // category
        XCTAssertEqual(dto.skippedStringCount, 1) // url
        XCTAssertTrue(dto.previewTransformedJSON.contains("[!!! "))
        XCTAssertTrue(dto.previewTransformedJSON.contains("https://cdn.example.com/poster.jpg"))
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        json: String
    ) -> SessionRecord {
        let bodyData = json.data(using: .utf8)
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        let response = CapturedResponse(
            statusCode: 200,
            headers: [
                HTTPHeaderField(name: "Content-Type", value: "application/json"),
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
