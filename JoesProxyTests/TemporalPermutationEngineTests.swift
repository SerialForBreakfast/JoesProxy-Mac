//
//  TemporalPermutationEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for concurrent request permutation matrix generation,
//  delay scheduling, and async race condition isolation.
//

import XCTest
@testable import JoesProxy

@MainActor
final class TemporalPermutationEngineTests: XCTestCase {

    func testPermutationMatrixGenerationAndDelayScheduling() {
        let engine = TemporalPermutationEngine.shared

        let endpoints = [
            PermutationEndpoint(id: "AUTH", name: "Auth Refresh", urlPattern: "*/auth*"),
            PermutationEndpoint(id: "CONFIG", name: "App Config", urlPattern: "*/config*"),
            PermutationEndpoint(id: "FEED", name: "Home Feed", urlPattern: "*/feed*")
        ]

        let plan = engine.proposePlan(
            name: "App Launch Concurrency Test",
            targetBatchDescription: "Cold start initialization",
            endpoints: endpoints,
            spacingMs: 200
        )

        // 3 endpoints -> 3! = 6 permutations
        XCTAssertEqual(plan.sequences.count, 6)
        XCTAssertEqual(plan.activeSequenceIndex, 0)
        XCTAssertFalse(plan.isCompleted)

        let firstSeq = plan.sequences.first
        XCTAssertNotNil(firstSeq)
        XCTAssertEqual(firstSeq?.order.count, 3)

        // Check delay spacing
        let firstEP = firstSeq!.order[0]
        let secondEP = firstSeq!.order[1]
        let thirdEP = firstSeq!.order[2]

        XCTAssertEqual(firstSeq?.delaysMs[firstEP], 0)
        XCTAssertEqual(firstSeq?.delaysMs[secondEP], 200)
        XCTAssertEqual(firstSeq?.delaysMs[thirdEP], 400)
    }

    func testStepPlanAndRaceConditionDetection() {
        let engine = TemporalPermutationEngine.shared

        let endpoints = [
            PermutationEndpoint(id: "A", name: "Endpoint A", urlPattern: "*/a*"),
            PermutationEndpoint(id: "B", name: "Endpoint B", urlPattern: "*/b*")
        ]

        // 2 endpoints -> 2 permutations: [A, B] and [B, A]
        let plan = engine.proposePlan(
            name: "Two Endpoint Race",
            targetBatchDescription: "A and B race",
            endpoints: endpoints
        )

        XCTAssertEqual(plan.sequences.count, 2)

        // Step 1: [A, B] -> Safe
        let (p1, r1) = engine.stepPlan(
            planID: plan.id,
            errorDetected: false,
            outcomeSummary: "Client rendered normally"
        )
        XCTAssertNil(r1)
        XCTAssertEqual(p1.sequences[0].status, .passed)
        XCTAssertEqual(p1.activeSequenceIndex, 1)

        // Step 2: [B, A] -> Race condition detected!
        let (p2, r2) = engine.stepPlan(
            planID: plan.id,
            errorDetected: true,
            outcomeSummary: "Client crashed due to uninitialized dependency"
        )

        XCTAssertNotNil(r2)
        XCTAssertTrue(p2.isCompleted)
        XCTAssertEqual(p2.sequences[1].status, .raceConditionDetected)

        XCTAssertEqual(r2?.totalSequencesTested, 2)
        XCTAssertEqual(r2?.failingSequencesCount, 1)
        XCTAssertEqual(r2?.safeSequencesCount, 1)
        XCTAssertEqual(r2?.minimalFailingOrder, ["B", "A"])
        XCTAssertTrue(r2?.rootCauseSummary.contains("B -> A") ?? false)
    }
}
