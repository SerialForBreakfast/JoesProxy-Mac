import XCTest
@testable import JoesProxy

/// AW-1 matching contract: segment-aware templates, query, content-type, and precedence.
final class OpenAPIMockRouteMatcherTests: XCTestCase {
    private let origin = OpenAPIMockOrigin(scheme: .http, host: "catalog.example.invalid")

    func testCatalogRootAndItemTemplateHit() throws {
        let catalog = try route(id: "catalog", method: "GET", template: "/v1/catalog")
        let item = try route(id: "item", method: "GET", template: "/v1/catalog/items/{itemId}")

        XCTAssertEqual(
            try OpenAPIMockRouteMatcher.select(routes: [catalog, item], request: request(path: "/v1/catalog"))?.id,
            "catalog"
        )
        XCTAssertEqual(
            try OpenAPIMockRouteMatcher.select(
                routes: [catalog, item],
                request: request(path: "/v1/catalog/items/item-1")
            )?.id,
            "item"
        )
    }

    func testLiteralFeaturedBeatsItemIdTemplate() throws {
        let templated = try route(id: "by-id", method: "GET", template: "/v1/catalog/items/{itemId}")
        let featured = try route(id: "featured", method: "GET", template: "/v1/catalog/items/featured")

        XCTAssertEqual(
            try OpenAPIMockRouteMatcher.select(
                routes: [templated, featured],
                request: request(path: "/v1/catalog/items/featured")
            )?.id,
            "featured"
        )
        XCTAssertEqual(
            try OpenAPIMockRouteMatcher.select(
                routes: [templated, featured],
                request: request(path: "/v1/catalog/items/item-2")
            )?.id,
            "by-id"
        )
    }

    func testPOSTRequiresJSONContentType() throws {
        let create = try route(
            id: "create",
            method: "POST",
            template: "/v1/catalog/items",
            contentType: "application/json"
        )

        XCTAssertEqual(
            try OpenAPIMockRouteMatcher.select(
                routes: [create],
                request: request(
                    method: "POST",
                    path: "/v1/catalog/items",
                    contentType: "application/json; charset=utf-8"
                )
            )?.id,
            "create"
        )
        XCTAssertNil(
            try OpenAPIMockRouteMatcher.select(
                routes: [create],
                request: request(method: "POST", path: "/v1/catalog/items", contentType: "text/plain")
            )
        )
        XCTAssertNil(
            try OpenAPIMockRouteMatcher.select(
                routes: [create],
                request: request(method: "POST", path: "/v1/catalog/items")
            )
        )
    }

    func testRequiredQueryMatchesAndIgnoresUnlistedKeys() throws {
        let listed = try route(
            id: "list",
            method: "GET",
            template: "/v1/catalog/items",
            query: [OpenAPIMockQueryConstraint(name: "limit", isRequired: true, allowedValues: nil)]
        )

        XCTAssertEqual(
            try OpenAPIMockRouteMatcher.select(
                routes: [listed],
                request: request(path: "/v1/catalog/items", query: ["limit": "10", "debug": "1"])
            )?.id,
            "list"
        )
        XCTAssertNil(
            try OpenAPIMockRouteMatcher.select(
                routes: [listed],
                request: request(path: "/v1/catalog/items", query: ["debug": "1"])
            )
        )
    }

    func testQueryEnumRejectsUnknownValue() throws {
        let listed = try route(
            id: "list",
            method: "GET",
            template: "/v1/catalog/items",
            query: [OpenAPIMockQueryConstraint(
                name: "status",
                isRequired: false,
                allowedValues: ["available", "archived"]
            )]
        )

        XCTAssertNotNil(
            try OpenAPIMockRouteMatcher.select(
                routes: [listed],
                request: request(path: "/v1/catalog/items", query: ["status": "archived"])
            )
        )
        XCTAssertNil(
            try OpenAPIMockRouteMatcher.select(
                routes: [listed],
                request: request(path: "/v1/catalog/items", query: ["status": "unknown"])
            )
        )
    }

    func testStreamIsNotARoute() throws {
        let catalog = try route(id: "catalog", method: "GET", template: "/v1/catalog")
        XCTAssertNil(
            try OpenAPIMockRouteMatcher.select(
                routes: [catalog],
                request: request(path: "/v1/stream")
            )
        )
    }

    func testOriginAndMethodMustMatch() throws {
        let catalog = try route(id: "catalog", method: "GET", template: "/v1/catalog")
        XCTAssertNil(
            try OpenAPIMockRouteMatcher.select(
                routes: [catalog],
                request: request(method: "POST", path: "/v1/catalog")
            )
        )
        let otherOrigin = OpenAPIMockMatchRequest(
            method: "GET",
            origin: OpenAPIMockOrigin(scheme: .https, host: "catalog.example.invalid"),
            path: "/v1/catalog",
            query: [:],
            contentType: nil
        )
        XCTAssertNil(try OpenAPIMockRouteMatcher.select(routes: [catalog], request: otherOrigin))
    }

    func testGETIgnoresRequestContentType() throws {
        let catalog = try route(
            id: "catalog",
            method: "GET",
            template: "/v1/catalog",
            contentType: "application/json"
        )
        XCTAssertEqual(
            try OpenAPIMockRouteMatcher.select(
                routes: [catalog],
                request: request(path: "/v1/catalog", contentType: "text/plain")
            )?.id,
            "catalog"
        )
    }

    func testPercentDecodedLiteralSegment() throws {
        let spaced = try route(id: "spaced", method: "GET", template: "/v1/catalog/hello%20world")
        XCTAssertEqual(
            try OpenAPIMockRouteMatcher.select(
                routes: [spaced],
                request: request(path: "/v1/catalog/hello%20world")
            )?.id,
            "spaced"
        )
    }

    func testRemainingTieConflict() throws {
        let left = try route(id: "a", method: "GET", template: "/v1/catalog/{x}")
        let right = try route(id: "b", method: "GET", template: "/v1/catalog/{y}")
        XCTAssertThrowsError(
            try OpenAPIMockRouteMatcher.select(
                routes: [left, right],
                request: request(path: "/v1/catalog/n")
            )
        ) { error in
            XCTAssertEqual(error as? OpenAPIMockPackError, .remainingTieConflict)
        }
    }

    func testContentTypeConstraintBeatsUnconstrainedOnTieBreak() throws {
        let plain = try route(id: "plain", method: "POST", template: "/v1/catalog/items")
        let json = try route(
            id: "json",
            method: "POST",
            template: "/v1/catalog/items",
            contentType: "application/json"
        )
        XCTAssertEqual(
            try OpenAPIMockRouteMatcher.select(
                routes: [plain, json],
                request: request(
                    method: "POST",
                    path: "/v1/catalog/items",
                    contentType: "application/json"
                )
            )?.id,
            "json"
        )
    }

    func testMoreQueryConstraintsWin() throws {
        let loose = try route(id: "loose", method: "GET", template: "/v1/catalog/items")
        let limited = try route(
            id: "limited",
            method: "GET",
            template: "/v1/catalog/items",
            query: [OpenAPIMockQueryConstraint(name: "limit", isRequired: true, allowedValues: nil)]
        )
        XCTAssertEqual(
            try OpenAPIMockRouteMatcher.select(
                routes: [loose, limited],
                request: request(path: "/v1/catalog/items", query: ["limit": "5"])
            )?.id,
            "limited"
        )
    }

    func testWildcardTemplatesAreRejected() {
        XCTAssertThrowsError(try OpenAPIMockPathTemplate.parse("/v1/catalog/{path*}")) { error in
            XCTAssertEqual(error as? OpenAPIMockPackError, .invalidPathTemplate("/v1/catalog/{path*}"))
        }
        XCTAssertThrowsError(try OpenAPIMockPathTemplate.parse("/v1/catalog/*"))
    }

    func testTooManyPathSegmentsRejected() {
        let long = "/" + (1...17).map { "s\($0)" }.joined(separator: "/")
        XCTAssertThrowsError(try OpenAPIMockPathTemplate.parse(long)) { error in
            XCTAssertEqual(error as? OpenAPIMockPackError, .tooManyPathSegments(count: 17))
        }
    }

    func testMissingFixtureIsFailOpen() throws {
        let catalog = try route(id: "catalog", method: "GET", template: "/v1/catalog")
        XCTAssertEqual(
            OpenAPIMockRouteMatcher.interceptDecision(matchedRoute: catalog, selectedVariant: nil),
            .noMatch
        )
        XCTAssertEqual(
            OpenAPIMockRouteMatcher.interceptDecision(matchedRoute: nil, selectedVariant: nil),
            .noMatch
        )
    }

    func testMethodIsCaseInsensitive() throws {
        let catalog = try route(id: "catalog", method: "get", template: "/v1/catalog")
        XCTAssertEqual(
            try OpenAPIMockRouteMatcher.select(
                routes: [catalog],
                request: request(method: "GET", path: "/v1/catalog")
            )?.id,
            "catalog"
        )
    }

    private func route(
        id: String,
        method: String,
        template: String,
        query: [OpenAPIMockQueryConstraint] = [],
        contentType: String? = nil
    ) throws -> OpenAPIMockRoute {
        OpenAPIMockRoute(
            id: id,
            origin: origin,
            method: method,
            pathTemplate: try OpenAPIMockPathTemplate.parse(template),
            queryConstraints: query,
            requestContentType: contentType
        )
    }

    private func request(
        method: String = "GET",
        path: String,
        query: [String: String] = [:],
        contentType: String? = nil
    ) -> OpenAPIMockMatchRequest {
        OpenAPIMockMatchRequest(
            method: method,
            origin: origin,
            path: path,
            query: query,
            contentType: contentType
        )
    }
}
