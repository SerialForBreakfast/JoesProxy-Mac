//
//  CounterfactualResilienceEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for JSON keypath extraction, counterfactual mutation generation,
//  and evaluator-optimizer breaking point isolation.
//

import XCTest
@testable import JoesProxy

@MainActor
final class CounterfactualResilienceEngineTests: XCTestCase {

    func testCandidateGenerationFromJSON() {
        let engine = CounterfactualResilienceEngine.shared

        let json = """
        {
            "status": "ok",
            "user": {
                "id": 12345,
                "name": "Alice"
            }
        }
        """

        let candidates = engine.generateCandidates(from: json)
        XCTAssertGreaterThan(candidates.count, 0)

        let keyPaths = Set(candidates.map(\.keyPath))
        XCTAssertTrue(keyPaths.contains("$.status"))
        XCTAssertTrue(keyPaths.contains("$.user.id"))
        XCTAssertTrue(keyPaths.contains("$.user.name"))

        let mutationTypes = Set(candidates.map(\.mutationType))
        XCTAssertTrue(mutationTypes.contains(.nullify))
        XCTAssertTrue(mutationTypes.contains(.removeKey))
        XCTAssertTrue(mutationTypes.contains(.typeCoerce))
    }

    func testBisectionStepAndBreakingPointIsolation() {
        let engine = CounterfactualResilienceEngine.shared

        let json = """
        {
            "id": 100
        }
        """

        let sessionID = UUID()
        let plan = engine.proposePlan(
            name: "ID Resilience Test",
            sessionID: sessionID,
            targetURL: "/api/user",
            payloadJSON: json
        )

        XCTAssertFalse(plan.candidates.isEmpty)
        let total = plan.candidates.count

        // Step through candidates
        // Suppose Candidate 1 (Nullify $.id) causes a client crash
        let (p1, r1) = engine.stepPlan(
            planID: plan.id,
            clientCrashed: true,
            observedError: "Swift.DecodingError: key 'id' was null"
        )
        XCTAssertNil(r1)
        XCTAssertEqual(p1.candidates[0].status, .breakingPoint)

        // Step remaining candidates as safe
        var currentPlan = p1
        var report: ClientResilienceMatrixReport? = nil

        for _ in 1..<total {
            let res = engine.stepPlan(
                planID: plan.id,
                clientCrashed: false,
                observedError: nil
            )
            currentPlan = res.plan
            report = res.report
        }

        XCTAssertNotNil(report)
        XCTAssertTrue(currentPlan.isCompleted)
        XCTAssertEqual(report?.breakingPointsCount, 1)
        XCTAssertEqual(report?.resilientFieldsCount, total - 1)

        let breakingPoint = report?.breakingPoints.first
        XCTAssertEqual(breakingPoint?.keyPath, "$.id")
        XCTAssertTrue(breakingPoint?.defensiveFixRecommendation.contains("decodeIfPresent") ?? false)
    }
}
