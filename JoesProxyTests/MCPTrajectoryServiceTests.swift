//
//  MCPTrajectoryServiceTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Multi-Session Trajectory Diffing tools.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPTrajectoryServiceTests: XCTestCase {

    func testMCPTrajectoryDiffWorkflow() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPTrajectoryService(sessionStore: store, snapshotService: snapshot)

        // Populate baseline & candidate sessions
        let base1 = makeSession(path: "/v1/auth", status: 200)
        let base2 = makeSession(path: "/v1/feed", status: 200)

        let cand1 = makeSession(path: "/v1/auth", status: 200)
        let cand2 = makeSession(path: "/v1/feed", status: 500)

        store.append(base1)
        store.append(base2)
        store.append(cand1)
        store.append(cand2)

        let reportDTO = try service.diffSessionTrajectories(
            baselineSessionIDs: [base1.id, base2.id],
            candidateSessionIDs: [cand1.id, cand2.id],
            baselineName: "Release v1.0",
            candidateName: "Nightly v1.1",
            policyRevision: .initial
        )

        XCTAssertEqual(reportDTO.baselineRunName, "Release v1.0")
        XCTAssertEqual(reportDTO.candidateRunName, "Nightly v1.1")
        XCTAssertEqual(reportDTO.alignedSteps.count, 2)
        XCTAssertEqual(reportDTO.divergencePointIndex, 2)
        XCTAssertNotNil(reportDTO.divergencePointSummary)
        XCTAssertTrue(reportDTO.divergencePointSummary?.contains("500") ?? false)
    }

    private func makeSession(path: String, status: Int) -> SessionRecord {
        let req = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: nil,
            bodySize: nil
        )

        let resp = CapturedResponse(
            statusCode: status,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: "{\"status\":\"ok\"}".data(using: .utf8),
            bodySize: 15
        )

        return SessionRecord(
            request: req,
            response: resp,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}
