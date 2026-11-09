//
//  MCPSemanticMockDTOs.swift
//  JoesProxy
//
//  Data Transfer Objects (DTOs) for MCP Semantic Wire Mocking
//  and Local Vector Cosine Similarity tools.
//

import Foundation

struct MCPSemanticMockRuleDTO: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var urlPattern: String
    var intentLabel: String
    var exampleQueries: [String]
    var mockStatusCode: Int
    var mockResponseBody: String
    var confidenceThreshold: Double
    var isEnabled: Bool
    var matchCount: Int
}

struct MCPSemanticMatchResultDTO: Codable, Sendable, Equatable {
    var isMatch: Bool
    var matchedRuleID: String?
    var matchedRuleName: String?
    var matchedIntent: String?
    var queryText: String
    var similarityScore: Double
    var bestMatchingExample: String?
    var disclosure: MCPMediaDisclosureContextDTO
}

struct MCPListSemanticMockRulesDTO: Codable, Sendable, Equatable {
    var rules: [MCPSemanticMockRuleDTO]
    var totalCount: Int
    var disclosure: MCPMediaDisclosureContextDTO
}
