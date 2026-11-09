//
//  MCPAgenticServiceTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Agentic Hypothesis DAG and Fault Bisection tools.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPAgenticServiceTests: XCTestCase {

    func testMCPHypothesisDAGWorkflow() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPAgenticService(sessionStore: store, snapshotService: snapshot)

        // 1. Propose DAG
        let inputs = [
            MCPHypothesisNodeInput(
                id: "H1",
                title: "Config Timeout",
                explanation: "Network timeout on /config",
                parentID: nil,
                mutationType: "latencyInjection",
                mutationTarget: "*/api/config*",
                mutationValue: "3000",
                expectedOutcome: "timeout_alert"
            ),
            MCPHypothesisNodeInput(
                id: "H2",
                title: "Corrupted Payload",
                explanation: "Missing user profile field",
                parentID: nil,
                mutationType: "jsonRewrite",
                mutationTarget: "*/api/profile*",
                mutationValue: "$.user.id",
                expectedOutcome: "profile_nil_crash"
            )
        ]

        let proposedGraph = try service.proposeHypothesisDAG(
            name: "Login Flow Triage",
            targetBug: "Login button fails to advance",
            nodeInputs: inputs,
            policyRevision: .initial
        )

        let graphUUID = UUID(uuidString: proposedGraph.id)!
        XCTAssertEqual(proposedGraph.name, "Login Flow Triage")
        XCTAssertEqual(proposedGraph.nodes.count, 2)
        XCTAssertEqual(proposedGraph.currentNodeID, "H1")

        // 2. Step 1: Disprove H1
        let step1 = try service.stepHypothesisGraph(
            graphID: graphUUID,
            evidenceMatches: false,
            evidenceSummary: "App waited without crashing",
            policyRevision: .initial
        )

        XCTAssertFalse(step1.isCompleted)
        XCTAssertEqual(step1.evaluatedNodeID, "H1")
        XCTAssertEqual(step1.evaluatedNodeStatus, "Disproven")
        XCTAssertEqual(step1.nextNodeIDToEvaluate, "H2")

        // 3. Step 2: Prove H2 (Leaf)
        let step2 = try service.stepHypothesisGraph(
            graphID: graphUUID,
            evidenceMatches: true,
            evidenceSummary: "App reproduced exact login crash",
            policyRevision: .initial
        )

        XCTAssertTrue(step2.isCompleted)
        XCTAssertEqual(step2.evaluatedNodeStatus, "Proven")
        XCTAssertNotNil(step2.bisectionReport)

        // 4. Retrieve Bisection Report
        let report = try service.getFaultBisectionReport(
            graphID: graphUUID,
            policyRevision: .initial
        )

        XCTAssertEqual(report.provenRootCauseNode?.id, "H2")
        XCTAssertEqual(report.confidenceScore, 1.0)
        XCTAssertTrue(report.recommendedRemediation.contains("H2"))
    }
}
