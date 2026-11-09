//
//  HypothesisDAGEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for Hypothesis DAG state machines, branch pruning,
//  and autonomous fault bisection isolation.
//

import XCTest
@testable import JoesProxy

@MainActor
final class HypothesisDAGEngineTests: XCTestCase {

    func testDAGSequentialEvaluationAndBranchPruning() {
        let engine = HypothesisDAGEngine.shared

        // Construct DAG
        let nodes = [
            // Branch 1: Auth
            HypothesisNode(
                id: "H1",
                title: "Authentication Failure",
                explanation: "Upstream returns 401",
                parentID: nil,
                mutation: .statusCodeFault(urlPattern: "*/auth*", statusCode: 401, responseBody: nil),
                expectedOutcome: .clientShowedHTTPStatus(statusCode: 401)
            ),
            HypothesisNode(
                id: "H1.1",
                title: "Expired Refresh Token",
                explanation: "Token payload expired",
                parentID: "H1",
                mutation: .jsonRewrite(urlPattern: "*/auth*", locator: "$.error", operation: "set", value: "token_expired"),
                expectedOutcome: .clientEmittedErrorBeacon(urlPattern: "*/telemetry*", parameterContains: "token_expired")
            ),
            // Branch 2: Home Feed Schema
            HypothesisNode(
                id: "H2",
                title: "Feed Payload Corruption",
                explanation: "Corrupted structure in feed",
                parentID: nil,
                mutation: .jsonRewrite(urlPattern: "*/feed*", locator: "$.items", operation: "set", value: "[]"),
                expectedOutcome: .customEvidenceMatch(key: "error", expectedValue: "empty_feed")
            ),
            HypothesisNode(
                id: "H2.1",
                title: "Null Hero Badge",
                explanation: "Unwrapped null badge in client",
                parentID: "H2",
                mutation: .jsonRewrite(urlPattern: "*/feed*", locator: "$.items[0].badge", operation: "set", value: "null"),
                expectedOutcome: .customEvidenceMatch(key: "crash", expectedValue: "badge_unwrap")
            )
        ]

        let graph = engine.proposeGraph(
            name: "Home Screen Crash Bisection",
            targetBugDescription: "Client crashes on app launch",
            nodes: nodes
        )

        XCTAssertEqual(graph.currentNodeID, "H1")
        XCTAssertFalse(graph.isCompleted)

        // Step 1: Disprove H1
        let (g1, r1) = engine.step(
            graphID: graph.id,
            observedEvidenceMatches: false,
            evidenceSummary: "Client did not encounter 401; auth succeeded"
        )

        XCTAssertNil(r1)
        XCTAssertEqual(g1.nodes.first(where: { $0.id == "H1" })?.status, .disproven)
        // Sub-branch H1.1 must be PRUNED
        XCTAssertEqual(g1.nodes.first(where: { $0.id == "H1.1" })?.status, .pruned)
        // Graph advances to sibling H2
        XCTAssertEqual(g1.currentNodeID, "H2")

        // Step 2: Prove H2
        let (g2, r2) = engine.step(
            graphID: graph.id,
            observedEvidenceMatches: true,
            evidenceSummary: "Client showed feed error"
        )

        XCTAssertNil(r2)
        XCTAssertEqual(g2.nodes.first(where: { $0.id == "H2" })?.status, .proven)
        // Graph narrows down to child H2.1
        XCTAssertEqual(g2.currentNodeID, "H2.1")

        // Step 3: Prove Leaf H2.1
        let (g3, r3) = engine.step(
            graphID: graph.id,
            observedEvidenceMatches: true,
            evidenceSummary: "Client crashed with badge_unwrap exception"
        )

        XCTAssertNotNil(r3)
        XCTAssertTrue(g3.isCompleted)
        XCTAssertEqual(g3.isolatedRootCauseNodeID, "H2.1")
        XCTAssertEqual(g3.provenNode?.id, "H2.1")

        XCTAssertEqual(r3?.provenRootCauseNode?.id, "H2.1")
        XCTAssertEqual(r3?.prunedBranchesCount, 1) // H1.1 was pruned
        XCTAssertEqual(r3?.confidenceScore, 1.0)
    }

    func testGraphReset() {
        let engine = HypothesisDAGEngine.shared
        let node = HypothesisNode(
            id: "H1",
            title: "Test Node",
            explanation: "Test",
            mutation: .dropConnection(urlPattern: "*"),
            expectedOutcome: .customEvidenceMatch(key: "a", expectedValue: "b")
        )

        let graph = engine.proposeGraph(name: "Reset Test", targetBugDescription: "Bug", nodes: [node])
        _ = engine.step(graphID: graph.id, observedEvidenceMatches: true, evidenceSummary: "Matched")

        let reset = engine.resetGraph(id: graph.id)
        XCTAssertNotNil(reset)
        XCTAssertFalse(reset!.isCompleted)
        XCTAssertEqual(reset?.nodes.first?.status, .evaluating)
    }
}
