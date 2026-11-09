import XCTest
@testable import JoesProxy

final class CapturedQueryMatcherTests: XCTestCase {
    private let names = ["token", "pageCorrelationId"]
    private let baseline = "/carousel/items?userId=7&profileId=2&start=0&rows=20&token=old"

    func testRotatingValuesAndOrderChangeButStableScopeDoesNot() {
        XCTAssertTrue(CapturedQueryMatcher.matches(
            "/carousel/items?rows=20&token=new&start=0&profileId=2&pageCorrelationId=new&userId=7",
            baseline: baseline, ignoring: names))
        for path in [
            "/carousel/items?userId=8&profileId=2&start=0&rows=20",
            "/carousel/items?userId=7&profileId=3&start=0&rows=20",
            "/carousel/items?userId=7&profileId=2&start=20&rows=20",
            "/other/items?userId=7&profileId=2&start=0&rows=20",
            "/carousel/items?userId=7&userId=8&profileId=2&start=0&rows=20",
            "/carousel/items?userId=7&start=0&rows=20"
        ] {
            XCTAssertFalse(CapturedQueryMatcher.matches(path, baseline: baseline, ignoring: names))
        }
        XCTAssertFalse(CapturedQueryMatcher.matches("/items?flag", baseline: "/items?flag=", ignoring: names))
        XCTAssertNil(CapturedQueryMatcher.canonicalPath(baseline, ignoring: ["token", "token"]))
        XCTAssertNil(CapturedQueryMatcher.canonicalPath(baseline, ignoring: []))
        XCTAssertFalse(CapturedQueryMatcher.canonicalPath(baseline, ignoring: names)!.contains("old"))
    }

    func testRuntimeRetainsDeviceAndQueryRestrictions() async throws {
        let store = ResponseOverrideStore()
        let rule = ResponseOverrideRule(requestMethod: "GET", requestScheme: .https,
            host: "api.example.test", port: 443, path: baseline, matchMode: .ignoreQuery,
            sourceKind: .block, sourceDescription: "Synthetic scope test", statusCode: 503,
            headers: [], bodySource: .inline(nil), sourceClientAddress: "192.0.2.10", ignoredQueryNames: names)
        try await store.addRule(rule)
        for (client, profile, shouldMatch) in [("192.0.2.10", "2", true), ("192.0.2.11", "2", false), ("192.0.2.10", "3", false)] {
            let request = CapturedRequest(method: "GET", scheme: .https, host: "api.example.test", port: 443,
                path: "/carousel/items?userId=7&profileId=\(profile)&start=0&rows=20&token=new",
                headers: [], bodyData: nil, bodySize: nil, clientAddress: client)
            let decision = try await store.ruleDecision(for: request)
            if case .block = decision { XCTAssertTrue(shouldMatch) }
            else { XCTAssertFalse(shouldMatch) }
        }
    }

    func testExactImageMatcherRequiresObservedQueryAndKeepsClientScope() async throws {
        for expectedPath in ["/thumbs/poster.png", "/thumbs/poster.png?format=webp"] {
            let store = ResponseOverrideStore()
            let rule = ResponseOverrideRule(requestMethod: "GET", requestScheme: .https,
                host: "images.example.test", port: 443, path: expectedPath, matchMode: .exactPath,
                sourceKind: .block, sourceDescription: "Synthetic image matcher", statusCode: 503,
                headers: [], bodySource: .inline(nil), sourceClientAddress: "192.0.2.10")
            try await store.addRule(rule)
            for (path, client) in [
                ("/thumbs/poster.png?format=webp", "192.0.2.10"),
                ("/thumbs/poster.png?format=webp", "192.0.2.11"),
                ("/thumbs/poster.png?format=jpeg", "192.0.2.10"),
                ("/thumbs/sibling.png?format=webp", "192.0.2.10")
            ] {
                let request = CapturedRequest(method: "GET", scheme: .https,
                    host: "images.example.test", port: 443, path: path,
                    headers: [], bodyData: nil, bodySize: nil, clientAddress: client)
                let decision = try await store.ruleDecision(for: request)
                let shouldMatch = path == expectedPath && client == "192.0.2.10"
                if case .block = decision { XCTAssertTrue(shouldMatch) }
                else { XCTAssertFalse(shouldMatch) }
            }
        }
    }
}
