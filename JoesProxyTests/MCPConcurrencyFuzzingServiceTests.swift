//
//  MCPConcurrencyFuzzingServiceTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Temporal Request Permutations and Race Condition Fuzzing tools.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPConcurrencyFuzzingServiceTests: XCTestCase {

    func testMCPTemporalPermutationWorkflow() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPConcurrencyFuzzingService(sessionStore: store, snapshotService: snapshot)

        // 1. Propose Plan
        let endpoints = [
            MCPPermutationEndpointInput(id: "EP1", name: "Session Init", urlPattern: "*/init*"),
            MCPPermutationEndpointInput(id: "EP2", name: "User Settings", urlPattern: "*/settings*")
        ]

        let proposed = try service.proposeTemporalPermutationPlan(
            name: "App Launch Concurrency",
            targetBatch: "Startup batch",
            endpoints: endpoints,
            spacingMs: 100,
            policyRevision: .initial
        )

        let planUUID = UUID(uuidString: proposed.id)!
        XCTAssertEqual(proposed.sequences.count, 2)
        XCTAssertEqual(proposed.activeSequenceIndex, 0)

        // 2. Step Sequence 1 (Pass)
        let step1 = try service.stepTemporalPermutationPlan(
            planID: planUUID,
            errorDetected: false,
            outcomeSummary: "Passed",
            policyRevision: .initial
        )

        XCTAssertFalse(step1.isCompleted)
        XCTAssertEqual(step1.evaluatedSequenceID, 1)
        XCTAssertEqual(step1.evaluatedStatus, "Safe")

        // 3. Step Sequence 2 (Fail / Race)
        let step2 = try service.stepTemporalPermutationPlan(
            planID: planUUID,
            errorDetected: true,
            outcomeSummary: "Crash on missing settings",
            policyRevision: .initial
        )

        XCTAssertTrue(step2.isCompleted)
        XCTAssertEqual(step2.evaluatedStatus, "Race Condition")
        XCTAssertNotNil(step2.fuzzReport)

        // 4. Get Report
        let report = try service.getRaceConditionFuzzReport(
            planID: planUUID,
            policyRevision: .initial
        )

        XCTAssertEqual(report.failingSequencesCount, 1)
        XCTAssertEqual(report.safeSequencesCount, 1)
        XCTAssertNotNil(report.minimalFailingOrder)
        XCTAssertTrue(report.recommendedDefensiveFix.contains("async barrier"))
    }
}
