//
//  MCPSemanticMockService.swift
//  JoesProxy
//
//  MCP tool endpoints for Semantic Wire Mocking,
//  vector cosine similarity query evaluation, and rule management.
//

import Foundation

@MainActor
final class MCPSemanticMockService {
    private let sessionStore: any SessionStore
    private let snapshotService: MCPSessionSnapshotService

    init(
        sessionStore: any SessionStore,
        snapshotService: MCPSessionSnapshotService
    ) {
        self.sessionStore = sessionStore
        self.snapshotService = snapshotService
    }

    // MARK: - Propose Semantic Mock Rule

    func proposeSemanticMockRule(
        name: String,
        urlPattern: String,
        intentLabel: String,
        exampleQueries: [String],
        mockStatusCode: Int = 200,
        mockResponseBody: String,
        confidenceThreshold: Double = 0.70,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPSemanticMockRuleDTO {
        let rule = SemanticMockRule(
            name: name,
            urlPattern: urlPattern,
            intentLabel: intentLabel,
            exampleQueries: exampleQueries,
            mockStatusCode: mockStatusCode,
            mockHeaders: ["Content-Type": "application/json"],
            mockResponseBody: mockResponseBody,
            confidenceThreshold: confidenceThreshold,
            isEnabled: true
        )

        SemanticMockEngine.shared.registerRule(rule)
        return mapRuleToDTO(rule)
    }

    // MARK: - List Rules

    func listSemanticMockRules(
        policyRevision: MCPPolicyRevision
    ) throws -> MCPListSemanticMockRulesDTO {
        let rules = SemanticMockEngine.shared.allRules()
        let dtos = rules.map { mapRuleToDTO($0) }

        return MCPListSemanticMockRulesDTO(
            rules: dtos,
            totalCount: dtos.count,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    // MARK: - Test Query Match

    func testSemanticQueryMatch(
        query: String,
        targetURL: String? = nil,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPSemanticMatchResultDTO {
        let result = SemanticMockEngine.shared.evaluateQuery(query: query, targetURL: targetURL)

        return MCPSemanticMatchResultDTO(
            isMatch: result.isMatch,
            matchedRuleID: result.matchedRuleID?.uuidString,
            matchedRuleName: result.matchedRuleName,
            matchedIntent: result.matchedIntent,
            queryText: result.queryText,
            similarityScore: result.similarityScore,
            bestMatchingExample: result.bestMatchingExample,
            disclosure: makeDisclosure(policyRevision: policyRevision)
        )
    }

    // MARK: - Delete Rule

    func deleteSemanticMockRule(
        ruleID: UUID,
        policyRevision: MCPPolicyRevision
    ) throws -> Bool {
        SemanticMockEngine.shared.removeRule(id: ruleID)
        return true
    }

    // MARK: - Helpers

    private func mapRuleToDTO(_ rule: SemanticMockRule) -> MCPSemanticMockRuleDTO {
        MCPSemanticMockRuleDTO(
            id: rule.id.uuidString,
            name: rule.name,
            urlPattern: rule.urlPattern,
            intentLabel: rule.intentLabel,
            exampleQueries: rule.exampleQueries,
            mockStatusCode: rule.mockStatusCode,
            mockResponseBody: rule.mockResponseBody,
            confidenceThreshold: rule.confidenceThreshold,
            isEnabled: rule.isEnabled,
            matchCount: rule.matchCount
        )
    }

    private func makeDisclosure(policyRevision: MCPPolicyRevision) -> MCPMediaDisclosureContextDTO {
        MCPMediaDisclosureContextDTO(
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyRevision,
            generatedAt: Date(),
            removedFields: [],
            partialResultReason: nil,
            truncated: false
        )
    }
}
