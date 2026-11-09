//
//  FaultBisectionCoordinatorTests.swift
//  JoesProxyTests
//
//  Unit tests for live FaultBisectionCoordinator lifecycle and step progression.
//

import XCTest
@testable import JoesProxy

@MainActor
final class FaultBisectionCoordinatorTests: XCTestCase {

    func testCoordinatorLifecycleStepProgressionAndCancellation() {
        let store = InMemorySessionStore()
        let coordinator = FaultBisectionCoordinator(sessionStore: store)

        let now = Date()
        let anchor = makeSession(path: "/api/checkout", startedAt: now)
        let dep1 = makeSession(path: "/api/inventory", startedAt: now.addingTimeInterval(-2))
        let dep2 = makeSession(path: "/api/user", startedAt: now.addingTimeInterval(-4))

        store.append(anchor)
        store.append(dep1)
        store.append(dep2)

        // 1. Start Bisection
        let report = coordinator.startBisection(anchorSessionID: anchor.id)
        XCTAssertNotNil(report)
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertEqual(coordinator.activeReport?.candidateScope.distinctEndpoints.count, 3)

        // 2. Record Step 1 Outcome
        let step1Report = coordinator.recordStepOutcome(outcome: .crashed, logSnippet: "Crash log snippet")
        XCTAssertNotNil(step1Report)
        XCTAssertEqual(step1Report?.steps.count, 1)
        XCTAssertEqual(step1Report?.steps.first?.clientOutcome, .crashed)

        // 3. Cancel Bisection
        coordinator.cancelBisection()
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(coordinator.activeReport?.status, .cancelled)
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
