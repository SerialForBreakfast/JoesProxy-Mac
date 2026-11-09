//
//  FaultBisectionEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for AI Fault Bisection state machine and search algorithms.
//

import XCTest
@testable import JoesProxy

final class FaultBisectionEngineTests: XCTestCase {

    func testCandidateScopeExtractionFiltersStaticAssets() {
        let now = Date()
        let anchor = makeSession(path: "/api/checkout", startedAt: now)
        let jsonAPI1 = makeSession(path: "/api/cart", startedAt: now.addingTimeInterval(-5))
        let jsonAPI2 = makeSession(path: "/api/pricing", startedAt: now.addingTimeInterval(-10))
        let imageAsset = makeSession(path: "/images/banner.png", startedAt: now.addingTimeInterval(-15))
        let videoSegment = makeSession(path: "/video/segment_1.m4s", startedAt: now.addingTimeInterval(-20))
        let outsideWindow = makeSession(path: "/api/old", startedAt: now.addingTimeInterval(-45))

        let allSessions = [anchor, jsonAPI1, jsonAPI2, imageAsset, videoSegment, outsideWindow]

        let scope = FaultBisectionEngine.buildCandidateScope(
            anchorSession: anchor,
            allSessions: allSessions,
            windowSeconds: 30.0
        )

        XCTAssertEqual(scope.anchorSessionID, anchor.id)
        XCTAssertEqual(scope.candidateSessionIDs.count, 3) // anchor, cart, pricing
        XCTAssertEqual(scope.distinctEndpoints.count, 3)
        XCTAssertTrue(scope.distinctEndpoints.contains(where: { $0.path == "/api/checkout" }))
        XCTAssertTrue(scope.distinctEndpoints.contains(where: { $0.path == "/api/cart" }))
        XCTAssertTrue(scope.distinctEndpoints.contains(where: { $0.path == "/api/pricing" }))
    }

    func testBinaryPartitionConvergenceToCulpritEndpoint() {
        let now = Date()
        let anchor = makeSession(path: "/api/checkout", startedAt: now)
        let api1 = makeSession(path: "/api/1", startedAt: now.addingTimeInterval(-1))
        let api2 = makeSession(path: "/api/2", startedAt: now.addingTimeInterval(-2))
        let api3 = makeSession(path: "/api/3", startedAt: now.addingTimeInterval(-3))
        let api4 = makeSession(path: "/api/4", startedAt: now.addingTimeInterval(-4))

        let scope = FaultBisectionEngine.buildCandidateScope(
            anchorSession: anchor,
            allSessions: [anchor, api1, api2, api3, api4],
            windowSeconds: 30.0
        )

        // Step 1: Initial Binary Partition
        let action1 = FaultBisectionEngine.nextAction(scope: scope, priorSteps: [])
        XCTAssertEqual(action1.kind, .binaryPartition)
        XCTAssertEqual(action1.targetEndpoints.count, 2)

        // Step 1 Result: Client crashed when testing partition (contains culprit)
        let step1Result = BisectionStepResult(
            stepNumber: 1,
            kind: .binaryPartition,
            testedEndpoints: action1.targetEndpoints.map { $0.id },
            testedFieldMutation: nil,
            mutationDescription: action1.actionDescription,
            clientOutcome: .crashed,
            logSnippets: ["DecodingError on field"],
            timestamp: Date()
        )

        // Step 2: Second Partition
        let action2 = FaultBisectionEngine.nextAction(scope: scope, priorSteps: [step1Result])
        XCTAssertEqual(action2.targetEndpoints.count, 1)

        // Step 2 Result: Client crashed again -> Culprit isolated
        let step2Result = BisectionStepResult(
            stepNumber: 2,
            kind: .binaryPartition,
            testedEndpoints: action2.targetEndpoints.map { $0.id },
            testedFieldMutation: nil,
            mutationDescription: action2.actionDescription,
            clientOutcome: .crashed,
            logSnippets: ["Crash reproduced"],
            timestamp: Date()
        )

        // Step 3: Proceeds to field mutation or verification
        let action3 = FaultBisectionEngine.nextAction(scope: scope, priorSteps: [step1Result, step2Result])
        XCTAssertTrue(action3.kind == .jsonFieldMutation || action3.kind == .verification)
    }

    func testJSONFieldMutationExtraction() {
        let json = """
        {
            "user": {
                "id": 12345,
                "name": "Jane",
                "preferences": {
                    "theme": "dark"
                }
            },
            "items": [
                {
                    "sku": "ABC-123",
                    "price": 99.99
                }
            ]
        }
        """.data(using: .utf8)!

        let mutations = FaultBisectionEngine.generateFieldMutations(jsonData: json)

        XCTAssertFalse(mutations.isEmpty)
        XCTAssertTrue(mutations.contains(where: { $0.formattedKeyPath == "user.name" }))
        XCTAssertTrue(mutations.contains(where: { $0.formattedKeyPath == "user.preferences.theme" }))
        XCTAssertTrue(mutations.contains(where: { $0.formattedKeyPath == "items.0.sku" }))
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
            headers: [HTTPHeaderField(name: "Accept", value: "application/json")],
            bodyData: nil,
            bodySize: nil
        )

        let body = "{\"status\":\"ok\"}".data(using: .utf8)
        let response = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: body,
            bodySize: body?.count
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
