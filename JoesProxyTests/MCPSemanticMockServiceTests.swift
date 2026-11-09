//
//  MCPSemanticMockServiceTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Semantic Wire Mocking and Vector Cosine Similarity tools.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPSemanticMockServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SemanticMockEngine.shared.clearAllRules()
    }

    func testMCPSemanticMockWorkflow() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPSemanticMockService(sessionStore: store, snapshotService: snapshot)

        // 1. Propose Rule
        let ruleDTO = try service.proposeSemanticMockRule(
            name: "Support Bot Mock",
            urlPattern: "*/api/chat*",
            intentLabel: "reset_password",
            exampleQueries: ["forgot password", "reset login credentials"],
            mockStatusCode: 200,
            mockResponseBody: "{\"link\": \"https://example.com/reset\"}",
            confidenceThreshold: 0.60,
            policyRevision: .initial
        )

        XCTAssertEqual(ruleDTO.name, "Support Bot Mock")
        XCTAssertEqual(ruleDTO.intentLabel, "reset_password")

        // 2. List Rules
        let listDTO = try service.listSemanticMockRules(policyRevision: .initial)
        XCTAssertEqual(listDTO.totalCount, 1)

        // 3. Test Match
        let matchDTO = try service.testSemanticQueryMatch(
            query: "how can i reset my login credentials",
            policyRevision: .initial
        )

        XCTAssertTrue(matchDTO.isMatch)
        XCTAssertEqual(matchDTO.matchedIntent, "reset_password")

        // 4. Delete Rule
        let deleted = try service.deleteSemanticMockRule(
            ruleID: UUID(uuidString: ruleDTO.id)!,
            policyRevision: .initial
        )
        XCTAssertTrue(deleted)

        let afterList = try service.listSemanticMockRules(policyRevision: .initial)
        XCTAssertEqual(afterList.totalCount, 0)
    }
}
