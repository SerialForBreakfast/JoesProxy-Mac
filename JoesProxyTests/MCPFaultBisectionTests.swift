//
//  MCPFaultBisectionTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Fault Bisection tool endpoints and serialization contracts.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPFaultBisectionTests: XCTestCase {

    func testMCPFaultBisectionServiceLifecycle() throws {
        let store = InMemorySessionStore()
        let service = MCPFaultBisectionService(sessionStore: store)

        let now = Date()
        let anchor = makeSession(path: "/api/checkout", startedAt: now)
        let dep1 = makeSession(path: "/api/cart", startedAt: now.addingTimeInterval(-2))
        store.append(anchor)
        store.append(dep1)

        // 1. Start bisection via MCP
        let startDTO = try service.startBisection(sessionID: anchor.id)
        XCTAssertEqual(startDTO.anchorSessionID, anchor.id.uuidString)
        XCTAssertEqual(startDTO.distinctEndpointCount, 2)
        XCTAssertEqual(startDTO.currentStepNumber, 1)

        // 2. Advance step via MCP
        let stepDTO = try service.recordStep(outcome: "crashed", logSnippet: "Crash in CheckoutView.swift:42")
        XCTAssertEqual(stepDTO.stepNumber, 2)
        XCTAssertEqual(stepDTO.kind, "jsonFieldMutation")

        // 3. Get Report via MCP
        let reportDTO = try service.getReport()
        XCTAssertEqual(reportDTO.anchorSessionID, anchor.id.uuidString)
        XCTAssertEqual(reportDTO.stepCount, 1)

        // 4. Cancel
        let cancelled = service.cancelBisection()
        XCTAssertTrue(cancelled)
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        startedAt: Date = Date()
    ) -> SessionRecord {
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
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: "{\"status\":\"ok\"}".data(using: .utf8),
            bodySize: 15
        )

        var timing = SessionTiming(startedAt: startedAt)
        timing.completedAt = startedAt.addingTimeInterval(0.1)

        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: timing
        )
    }
}
