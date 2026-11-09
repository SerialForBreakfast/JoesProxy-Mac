//
//  SemanticMockEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for zero-dependency vector cosine similarity,
//  paraphrased query matching, and in-flight semantic wire interception.
//

import XCTest
@testable import JoesProxy

@MainActor
final class SemanticMockEngineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SemanticMockEngine.shared.clearAllRules()
    }

    func testSemanticCosineSimilarityAndParaphrasing() {
        let engine = SemanticMockEngine.shared

        let rule = SemanticMockRule(
            name: "Cancel Subscription Mock",
            urlPattern: "*/api/search*",
            intentLabel: "cancel_subscription",
            exampleQueries: [
                "cancel subscription",
                "stop auto renew",
                "terminate membership plan"
            ],
            mockStatusCode: 200,
            mockResponseBody: "{\"status\": \"cancelled\"}",
            confidenceThreshold: 0.60
        )
        engine.registerRule(rule)

        // 1. Exact match
        let match1 = engine.evaluateQuery(query: "cancel subscription")
        XCTAssertTrue(match1.isMatch)
        XCTAssertEqual(match1.matchedIntent, "cancel_subscription")
        XCTAssertGreaterThan(match1.similarityScore, 0.95)

        // 2. Paraphrased query
        let match2 = engine.evaluateQuery(query: "how to stop auto renew now")
        XCTAssertTrue(match2.isMatch)
        XCTAssertEqual(match2.matchedIntent, "cancel_subscription")
        XCTAssertGreaterThan(match2.similarityScore, 0.60)

        // 3. Disjoint / Unrelated query
        let match3 = engine.evaluateQuery(query: "track my package delivery status")
        XCTAssertFalse(match3.isMatch)
        XCTAssertLessThan(match3.similarityScore, 0.30)
    }

    func testInFlightRequestQueryExtractionAndEvaluation() {
        let engine = SemanticMockEngine.shared

        let rule = SemanticMockRule(
            name: "FAQ Search Mock",
            urlPattern: "*/api/faq*",
            intentLabel: "refund_policy",
            exampleQueries: ["how do i get a refund", "return policy"],
            mockStatusCode: 200,
            mockResponseBody: "{\"policy\": \"30_days\"}",
            confidenceThreshold: 0.55
        )
        engine.registerRule(rule)

        // Evaluate request with URL parameter
        let result = engine.evaluateRequest(
            url: "https://api.example.com/api/faq?q=how+do+i+get+a+refund",
            bodyData: nil
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.match.matchedIntent, "refund_policy")
        XCTAssertEqual(result?.rule.matchCount, 1)
    }
}
