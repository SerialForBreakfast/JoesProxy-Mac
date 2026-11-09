import XCTest
@testable import JoesProxy

final class ResponseOverrideHeaderPredicateTests: XCTestCase {

    func testHeaderPredicateMatchesWhenHeaderMatches() async throws {
        let store = ResponseOverrideStore()

        let rule = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/user",
            sourceKind: .inlineText,
            sourceDescription: "Mock",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data("{\"user\": \"mocked\"}".utf8)),
            matchHeaderName: "X-Test-Mode",
            matchHeaderValue: "enabled"
        )
        try await store.addRule(rule)

        let matchingRequest = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/user",
            headers: [HTTPHeaderField(name: "X-Test-Mode", value: "enabled")],
            bodyData: nil,
            bodySize: nil
        )

        let nonMatchingRequest = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/user",
            headers: [HTTPHeaderField(name: "X-Test-Mode", value: "disabled")],
            bodyData: nil,
            bodySize: nil
        )

        let matchDecision = try await store.ruleDecision(for: matchingRequest)
        if case .mapLocal = matchDecision {
            // Success
        } else {
            XCTFail("Expected .mapLocal decision for matching header, got \(matchDecision)")
        }

        let nonMatchDecision = try await store.ruleDecision(for: nonMatchingRequest)
        if case .noMatch = nonMatchDecision {
            // Success
        } else {
            XCTFail("Expected .noMatch decision for non-matching header, got \(nonMatchDecision)")
        }
    }

    func testHeaderPredicateCaseInsensitiveNameMatching() async throws {
        let store = ResponseOverrideStore()

        let rule = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/auth",
            sourceKind: .inlineText,
            sourceDescription: "Mock",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data("{}".utf8)),
            matchHeaderName: "authorization",
            matchHeaderValue: "Bearer token123"
        )
        try await store.addRule(rule)

        let matchingRequest = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/auth",
            headers: [HTTPHeaderField(name: "Authorization", value: "Bearer token123")],
            bodyData: nil,
            bodySize: nil
        )

        let matchDecision = try await store.ruleDecision(for: matchingRequest)
        if case .mapLocal = matchDecision {
            // Success
        } else {
            XCTFail("Expected .mapLocal decision for matching case-insensitive header, got \(matchDecision)")
        }
    }
}
