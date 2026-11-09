import XCTest
@testable import JoesProxy

final class BookmarkRequestMatcherTests: XCTestCase {
    private func makeRequest(path: String) -> CapturedRequest {
        CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
    }

    private func makeRule(path: String, matchMode: ResponseOverrideMatchMode) -> CapturedRequest {
        makeRequest(path: path)
    }

    func testIgnoreQueryMatchIgnoresQueryString() {
        let rule = makeRule(path: "/movies/123.json?locale=en", matchMode: .ignoreQuery)
        let request = makeRequest(path: "/movies/123.json?locale=fr")

        XCTAssertTrue(
            BookmarkRequestMatcher.matches(
                ruleRequest: rule,
                matchMode: .ignoreQuery,
                request: request
            )
        )
    }

    func testPathPrefixMatchesNestedEndpoint() {
        let rule = makeRule(path: "/apps-api/v2.0", matchMode: .pathPrefix)
        let request = makeRequest(path: "/apps-api/v2.0/ipad/app/status.json")

        XCTAssertTrue(
            BookmarkRequestMatcher.matches(
                ruleRequest: rule,
                matchMode: .pathPrefix,
                request: request
            )
        )
    }

    func testDifferentPathsDoNotMatchExactMode() {
        let rule = makeRule(path: "/movies/123.json", matchMode: .ignoreQuery)
        let request = makeRequest(path: "/movie/metadata/123.json")

        XCTAssertFalse(
            BookmarkRequestMatcher.matches(
                ruleRequest: rule,
                matchMode: .ignoreQuery,
                request: request
            )
        )
    }

    func testSourceDescriptionListsAppliedAndSkippedPaths() {
        let rewriteApplied = BookmarkResponseFieldRewrite(
            jsonPath: "movie.title",
            overrideValue: .string("Test")
        )
        let rewriteSkipped = BookmarkResponseFieldRewrite(
            jsonPath: "missing.path",
            overrideValue: .string("X")
        )
        let result = BookmarkJSONRewriteResult(
            patchedData: Data(),
            appliedRuleIDs: [rewriteApplied.id],
            skippedRuleIDs: [rewriteSkipped.id]
        )

        let description = BookmarkRequestMatcher.sourceDescription(
            bookmarkName: "Movie",
            rewrites: [rewriteApplied, rewriteSkipped],
            rewriteResult: result
        )

        XCTAssertTrue(description.contains("applied: movie.title"))
        XCTAssertTrue(description.contains("skipped: missing.path"))
    }
}
