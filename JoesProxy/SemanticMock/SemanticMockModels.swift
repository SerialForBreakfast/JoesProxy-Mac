//
//  SemanticMockModels.swift
//  JoesProxy
//
//  Domain models for semantic wire mocking, intent descriptors,
//  and local vector cosine similarity matching.
//

import Foundation

/// A configured rule for matching natural language requests via semantic similarity.
struct SemanticMockRule: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var urlPattern: String // e.g. "*/api/search*" or "*/api/chat*"
    var intentLabel: String // e.g. "cancel_subscription"
    var exampleQueries: [String] // e.g. ["cancel subscription", "stop auto-renew", "end plan"]
    var mockStatusCode: Int = 200
    var mockHeaders: [String: String] = ["Content-Type": "application/json"]
    var mockResponseBody: String
    var confidenceThreshold: Double = 0.70 // 0.0 to 1.0
    var isEnabled: Bool = true
    var matchCount: Int = 0
    var createdAt: Date = Date()
}

/// Result of evaluating a natural language query against semantic mock rules.
struct SemanticMatchResult: Codable, Equatable, Sendable {
    var isMatch: Bool
    var matchedRuleID: UUID?
    var matchedRuleName: String?
    var matchedIntent: String?
    var queryText: String
    var similarityScore: Double // 0.0 to 1.0
    var bestMatchingExample: String?
}
