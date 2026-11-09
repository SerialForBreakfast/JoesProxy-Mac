//
//  MCPContractDiffTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP API Contract Differential and Regression Suite tool endpoints.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPContractDiffTests: XCTestCase {

    func testMCPContractDiffServiceEndpoints() throws {
        let store = InMemorySessionStore()
        let service = MCPContractDiffService(sessionStore: store)

        let baseline = makeSession(
            path: "/v1/products",
            status: 200,
            json: "{\"items\":[{\"id\":\"p1\",\"price\":99.9}]}"
        )

        let liveBroken = makeSession(
            path: "/v1/products",
            status: 200,
            json: "{\"items\":[{\"id\":999,\"price\":\"99.9\"}]}" // id is number instead of string, price is string instead of number
        )

        store.append(baseline)
        store.append(liveBroken)

        // 1. Single session diff
        let diffDTO = try service.diffSessions(
            liveSessionID: liveBroken.id,
            baselineSessionID: baseline.id
        )

        XCTAssertFalse(diffDTO.isCompliant)
        XCTAssertGreaterThan(diffDTO.breakingChangeCount, 0)
        XCTAssertFalse(diffDTO.diffs.isEmpty)

        // 2. Regression suite run
        let suiteDTO = try service.runRegressionSuite(
            liveSessionIDs: [liveBroken.id],
            baselineSessionIDs: [baseline.id]
        )

        XCTAssertFalse(suiteDTO.isSuitePassed)
        XCTAssertEqual(suiteDTO.totalEndpointsTested, 1)
        XCTAssertEqual(suiteDTO.breakingEndpointsCount, 1)
        XCTAssertGreaterThan(suiteDTO.totalBreakingChanges, 0)
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        status: Int,
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
            statusCode: status,
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
