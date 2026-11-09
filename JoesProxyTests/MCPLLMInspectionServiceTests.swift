//
//  MCPLLMInspectionServiceTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP LLM streaming inspection and fault sandbox service.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPLLMInspectionServiceTests: XCTestCase {

    func testMCPLLMStreamInspectionAndFaultProposal() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPLLMInspectionService(sessionStore: store, snapshotService: snapshot)

        // Populate session
        let sseBody = """
        data: {"model": "gpt-4o-mini", "choices": [{"delta": {"role": "assistant", "content": "AI Output Stream"}}]}
        data: {"choices": [{"delta": {}, "finish_reason": "stop"}]}
        data: [DONE]
        """
        let req = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.openai.com",
            port: 443,
            path: "/v1/chat/completions",
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: nil,
            bodySize: nil
        )
        let resp = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "text/event-stream")],
            bodyData: sseBody.data(using: .utf8),
            bodySize: sseBody.data(using: .utf8)?.count
        )
        let session = SessionRecord(
            request: req,
            response: resp,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
        store.append(session)

        // 1. Inspect Stream via MCP
        let reports = try service.llmStreamInspection(policyRevision: .initial)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.modelName, "gpt-4o-mini")
        XCTAssertEqual(reports.first?.assembledText, "AI Output Stream")

        // 2. Propose Fault via MCP
        let proposal = try service.proposeLLMStreamFault(
            name: "Test Stream Stall",
            urlPattern: "*/v1/chat/completions*",
            faultKind: "tokenStall",
            delayMs: 750,
            targetTokenIndex: 3,
            policyRevision: .initial
        )

        XCTAssertTrue(proposal.isEnabled)
        XCTAssertTrue(proposal.faultKindDescription.contains("750ms"))
    }
}
