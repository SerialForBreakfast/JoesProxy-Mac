import Foundation
import XCTest
@testable import JoesProxy

final class BookmarkResponseInterceptStoreTests: XCTestCase {
    private let responseBody = Data(
        """
        {"appConfig":{"ad_variant_keys_enabled":"true"}}
        """.utf8
    )

    func testEnabledBookmarkProducesMapLocalDecision() async throws {
        let store = BookmarkResponseInterceptStore()
        let bookmark = Bookmark(
            name: "Status",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/apps-api/v2.0/ipad/app/status.json?locale=en",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            savedResponse: BookmarkSavedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: responseBody,
                savedAt: Date()
            ),
            responseRewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: "appConfig.ad_variant_keys_enabled",
                    originalValueSnapshot: "true",
                    overrideValue: .string("false")
                )
            ],
            responseMatchMode: .ignoreQuery
        )

        await store.syncBookmarks([bookmark])
        await store.setEnabledBookmarkIDs([bookmark.id])

        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/apps-api/v2.0/ipad/app/status.json?locale=fr",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        let decision = try await store.ruleDecision(for: request)
        guard case .mapLocal(let resolved) = decision else {
            XCTFail("Expected mapLocal decision")
            return
        }

        XCTAssertEqual(resolved.capturedResponseSource, .bookmarkResponseRewrite)
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(resolved.bodyData)) as? [String: Any]
        let appConfig = object?["appConfig"] as? [String: Any]
        XCTAssertEqual(appConfig?["ad_variant_keys_enabled"] as? String, "false")
    }

    func testDisabledBookmarkIDDoesNotMatch() async throws {
        let store = BookmarkResponseInterceptStore()
        let bookmark = Bookmark(
            name: "Status",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/status.json",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            savedResponse: BookmarkSavedResponse(
                statusCode: 200,
                headers: [],
                bodyData: responseBody,
                savedAt: Date()
            ),
            responseRewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: "appConfig.ad_variant_keys_enabled",
                    overrideValue: .string("false")
                )
            ]
        )

        await store.syncBookmarks([bookmark])
        await store.setEnabledBookmarkIDs([])

        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/status.json",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        let decision = try await store.ruleDecision(for: request)
        XCTAssertNil(decision)
    }
}
