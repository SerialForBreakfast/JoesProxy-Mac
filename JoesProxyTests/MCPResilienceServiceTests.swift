//
//  MCPResilienceServiceTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Counterfactual Payload Mutation and Resilience tools.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPResilienceServiceTests: XCTestCase {

    func testMCPResilienceWorkflow() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPResilienceService(sessionStore: store, snapshotService: snapshot)

        // Populate session
        let jsonBody = "{\"user_id\": 42}"
        let req = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/api/profile",
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: nil,
            bodySize: nil
        )
        let resp = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: jsonBody.data(using: .utf8),
            bodySize: jsonBody.data(using: .utf8)?.count
        )
        let session = SessionRecord(
            request: req,
            response: resp,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
        store.append(session)

        // 1. Propose Plan
        let proposed = try service.proposeResilienceBisectionPlan(
            sessionID: session.id,
            name: "Profile Resilience",
            policyRevision: .initial
        )

        let planUUID = UUID(uuidString: proposed.id)!
        XCTAssertGreaterThan(proposed.candidates.count, 0)
        XCTAssertEqual(proposed.targetURL, "/api/profile")

        // 2. Step Candidates
        let step1 = try service.stepResilienceBisectionPlan(
            planID: planUUID,
            clientCrashed: true,
            observedError: "Fatal error: unexpected nil",
            policyRevision: .initial
        )

        XCTAssertEqual(step1.evaluatedStatus, "Breaking Point")

        // Step through the remaining candidates to finish
        var isDone = step1.isCompleted
        while !isDone {
            let nextStep = try service.stepResilienceBisectionPlan(
                planID: planUUID,
                clientCrashed: false,
                observedError: nil,
                policyRevision: .initial
            )
            isDone = nextStep.isCompleted
        }

        // 3. Get Report
        let report = try service.getResilienceMatrixReport(
            planID: planUUID,
            policyRevision: .initial
        )

        XCTAssertEqual(report.breakingPointsCount, 1)
        XCTAssertEqual(report.breakingPoints.first?.keyPath, "$.user_id")
        XCTAssertTrue(report.breakingPoints.first?.defensiveFixRecommendation.contains("decodeIfPresent") ?? false)
    }
}
