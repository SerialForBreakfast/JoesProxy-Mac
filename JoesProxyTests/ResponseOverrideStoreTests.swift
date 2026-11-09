import Foundation
import XCTest
@testable import JoesProxy

final class ResponseOverrideStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeRequest(
        method: String = "GET",
        scheme: SessionScheme = .https,
        host: String = "api.example.com",
        port: Int = 443,
        path: String = "/v1/items"
    ) -> CapturedRequest {
        CapturedRequest(
            method: method,
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
    }

    private func makeInlineRule(
        for request: CapturedRequest,
        statusCode: Int = 200,
        body: Data? = nil,
        sourceKind: ResponseOverrideSourceKind = .inlineText
    ) -> ResponseOverrideRule {
        ResponseOverrideRule(
            requestMethod: request.method,
            requestScheme: request.scheme,
            host: request.host,
            port: request.port,
            path: request.path,
            sourceKind: sourceKind,
            sourceDescription: "test",
            statusCode: statusCode,
            headers: [],
            bodySource: .inline(body)
        )
    }

    private func makeSession(
        method: String = "GET",
        host: String = "api.example.com",
        path: String = "/v1/items",
        response: CapturedResponse? = CapturedResponse(
            statusCode: 200,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
    ) -> SessionRecord {
        SessionRecord(
            request: makeRequest(method: method, host: host, path: path),
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date().addingTimeInterval(0.2))
        )
    }

    // MARK: - noMatch

    func testNoMatchWhenStoreIsEmpty() async throws {
        let store = ResponseOverrideStore()
        let decision = try await store.ruleDecision(for: makeRequest())
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch for empty store, got \(decision)")
            return
        }
    }

    // MARK: - Map Local (regression guard)

    func testMapLocalDecisionReturnedForInlineRule() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        let body = Data("hello".utf8)
        try await store.addRule(makeInlineRule(for: request, statusCode: 201, body: body))

        let decision = try await store.ruleDecision(for: request)
        guard case .mapLocal(let resolved) = decision else {
            XCTFail("Expected .mapLocal, got \(decision)")
            return
        }
        XCTAssertEqual(resolved.statusCode, 201)
        XCTAssertEqual(resolved.bodyData, body)
    }

    /// AR: a rule's `forceNoCache` flag must survive from creation through to the
    /// `ResolvedResponseOverride` the serving path actually consumes — this is the store-level half
    /// of the fix; `ProxyConnectionHandlerNoCachingTests`-style coverage in `ProxyServerTests.swift`
    /// proves the header-mutation half.
    func testForceNoCacheOnRuleFlowsThroughToResolvedOverride() async throws {
        let store = ResponseOverrideStore()
        let session = makeSession(host: "cdn.example.com", path: "/asset.json")

        let rule = try await store.addInlineTextOverride(
            from: session,
            label: "Forced no-cache asset",
            statusCode: 200,
            contentType: "application/json",
            bodyText: "{}",
            forceNoCache: true
        )
        XCTAssertTrue(rule.forceNoCache)

        let decision = try await store.ruleDecision(for: session.request)
        guard case .mapLocal(let resolved) = decision else {
            XCTFail("Expected .mapLocal, got \(decision)")
            return
        }
        XCTAssertTrue(resolved.forceNoCache)
    }

    /// Baseline: without opting in, `forceNoCache` defaults to `false` end to end — confirms this
    /// is additive, not a behavior change for every existing rule.
    func testForceNoCacheDefaultsToFalseWhenNotRequested() async throws {
        let store = ResponseOverrideStore()
        let session = makeSession(host: "cdn.example.com", path: "/asset.json")

        let rule = try await store.addInlineTextOverride(
            from: session,
            label: "Default asset",
            statusCode: 200,
            contentType: "application/json",
            bodyText: "{}"
        )
        XCTAssertFalse(rule.forceNoCache)

        let decision = try await store.ruleDecision(for: session.request)
        guard case .mapLocal(let resolved) = decision else {
            XCTFail("Expected .mapLocal, got \(decision)")
            return
        }
        XCTAssertFalse(resolved.forceNoCache)
    }

    func testCapturedResponseOverrideMatchesCapturedRequestAndTracksUsage() async throws {
        let store = ResponseOverrideStore()
        let session = makeSession(path: "/v1/profile")

        _ = try await store.addCapturedResponseOverride(from: session)
        let decision = try await store.ruleDecision(for: session.request)
        guard case .mapLocal(let matched) = decision else {
            XCTFail("Expected .mapLocal, got \(decision)")
            return
        }

        XCTAssertEqual(matched.statusCode, 200)
        XCTAssertEqual(matched.sourceKind, .capturedResponse)

        let rules = await store.rules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.hitCount, 1)
        XCTAssertNotNil(rules.first?.lastMatchedAt)
    }

    func testFileBackedOverrideReadsBody() async throws {
        let store = ResponseOverrideStore()
        let session = makeSession(host: "cdn.example.com", path: "/asset.json")
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("file-backed-override.json")
        let fileBody = try Data(contentsOf: fileURL)

        _ = try await store.addFileBackedOverride(
            from: session,
            label: "Local Asset",
            statusCode: 202,
            contentType: "application/json",
            fileURL: fileURL
        )

        let fileDecision = try await store.ruleDecision(for: session.request)
        guard case .mapLocal(let matched) = fileDecision else {
            XCTFail("Expected .mapLocal, got \(fileDecision)")
            return
        }

        XCTAssertEqual(matched.statusCode, 202)
        XCTAssertEqual(matched.bodyData, fileBody)
        XCTAssertTrue(matched.headers.contains(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame &&
            $0.value == "application/json"
        }))
    }

    /// AQ: Path Suffix UI defaults to the last path component (filename), stripping folders and query.
    func testPathSuffixDefaultUsesLastPathComponentHelper() {
        XCTAssertEqual(
            MapLocalSheet.lastPathComponent(of: "/w720-q70/joeseal-v5/JoeSealOfApproval.png"),
            "JoeSealOfApproval.png"
        )
        XCTAssertEqual(
            MapLocalSheet.lastPathComponent(of: "/assets/app.js?v=12"),
            "app.js"
        )
        XCTAssertEqual(MapLocalSheet.lastPathComponent(of: "bare-file.json"), "bare-file.json")
        XCTAssertEqual(MapLocalSheet.lastPathComponent(of: "/"), "/")
    }

    /// AQ regression test: without an explicit `matchPath`, every `add*` override function silently
    /// reused the entire captured session path as the literal matcher value — so switching to
    /// `.pathSuffix` had no way to shorten the match to just a filename. This proves the new
    /// `matchPath` parameter actually overrides the derived session path.
    func testFileBackedOverrideWithExplicitMatchPathUsesGivenPathNotSessionPath() async throws {
        let store = ResponseOverrideStore()
        let session = makeSession(host: "cdn.example.com", path: "/w720-q70/joeseal-v5/JoeSealOfApproval.png")
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("file-backed-override.json")

        let rule = try await store.addFileBackedOverride(
            from: session,
            label: "Seal image",
            matchMode: .pathSuffix,
            matchPath: "JoeSealOfApproval.png",
            statusCode: 200,
            contentType: "image/webp",
            fileURL: fileURL
        )

        XCTAssertEqual(rule.path, "JoeSealOfApproval.png")
        XCTAssertNotEqual(rule.path, session.request.path)
    }

    /// The exact real-world deadlock this fixes: a Path Suffix rule created with just the filename
    /// as its matcher must match a *different* folder carrying the same filename — proving the fix
    /// end to end via `ruleDecision(for:)`, not just that the stored `path` field changed.
    func testPathSuffixRuleWithExplicitFilenameMatchesDifferentFolder() async throws {
        let store = ResponseOverrideStore()
        let originalSession = makeSession(host: "cdn.example.com", path: "/w720-q70/joeseal-v5/JoeSealOfApproval.png")
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("file-backed-override.json")

        _ = try await store.addFileBackedOverride(
            from: originalSession,
            label: "Seal image",
            matchMode: .pathSuffix,
            matchPath: "JoeSealOfApproval.png",
            statusCode: 200,
            contentType: "image/webp",
            fileURL: fileURL
        )

        // Cache-busted to a different folder, same filename — this is exactly what broke before AQ.
        let bustedRequest = makeRequest(host: "cdn.example.com", path: "/w720-q70/b7/joeseal-v5/JoeSealOfApproval.png")
        let decision = try await store.ruleDecision(for: bustedRequest)
        guard case .mapLocal = decision else {
            XCTFail("Expected .mapLocal for a differently-foldered request matching by filename suffix, got \(decision)")
            return
        }
    }

    /// P1 (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): `.filename` is
    /// the first-class replacement for the `.pathSuffix`-trimmed-to-a-bare-filename workaround
    /// proven above — same real-world job (match by filename regardless of nesting), cleaner mode.
    func testFilenameMatchModeMatchesAcrossDifferentFolders() async throws {
        let store = ResponseOverrideStore()
        let originalSession = makeSession(host: "cdn.example.com", path: "/w720-q70/joeseal-v5/JoeSealOfApproval.png")
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("file-backed-override.json")

        _ = try await store.addFileBackedOverride(
            from: originalSession,
            label: "Seal image",
            matchMode: .filename,
            matchPath: "JoeSealOfApproval.png",
            statusCode: 200,
            contentType: "image/webp",
            fileURL: fileURL
        )

        let bustedRequest = makeRequest(host: "cdn.example.com", path: "/w720-q70/b7/joeseal-v5/JoeSealOfApproval.png")
        let decision = try await store.ruleDecision(for: bustedRequest)
        guard case .mapLocal = decision else {
            XCTFail("Expected .mapLocal for a differently-foldered request matching by filename, got \(decision)")
            return
        }
    }

    func testFilenameMatchModeDoesNotMatchDifferentFilename() async throws {
        let store = ResponseOverrideStore()
        let originalSession = makeSession(host: "cdn.example.com", path: "/w720-q70/joeseal-v5/JoeSealOfApproval.png")
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("file-backed-override.json")

        _ = try await store.addFileBackedOverride(
            from: originalSession,
            label: "Seal image",
            matchMode: .filename,
            matchPath: "JoeSealOfApproval.png",
            statusCode: 200,
            contentType: "image/webp",
            fileURL: fileURL
        )

        let unrelatedRequest = makeRequest(host: "cdn.example.com", path: "/w720-q70/joeseal-v5/OtherAsset.png")
        let decision = try await store.ruleDecision(for: unrelatedRequest)
        guard case .noMatch = decision else {
            XCTFail("Expected no match for a different filename under .filename mode, got \(decision)")
            return
        }
    }

    /// Confirms editing an existing rule can actually change its matcher path — previously
    /// `updateFileBackedOverride` never touched `rule.path` at all.
    func testUpdateFileBackedOverrideCanChangeMatchPath() async throws {
        let store = ResponseOverrideStore()
        let session = makeSession(host: "cdn.example.com", path: "/w720-q70/joeseal-v5/JoeSealOfApproval.png")
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("file-backed-override.json")

        let rule = try await store.addFileBackedOverride(
            from: session,
            label: "Seal image",
            statusCode: 200,
            contentType: "image/webp",
            fileURL: fileURL
        )
        XCTAssertEqual(rule.path, session.request.path)

        try await store.updateFileBackedOverride(
            id: rule.id,
            label: rule.label,
            matchMode: .pathSuffix,
            matchPath: "JoeSealOfApproval.png",
            statusCode: 200,
            contentType: "image/webp",
            fileURL: fileURL
        )

        let updated = await store.rules().first { $0.id == rule.id }
        XCTAssertEqual(updated?.path, "JoeSealOfApproval.png")
    }

    // MARK: - Block rules

    func testBlockDecisionReturnedForBlockRule() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        try await store.addBlockRule(from: request, statusCode: 503, label: "Test block")

        let decision = try await store.ruleDecision(for: request)
        guard case .block(_, let statusCode, _, _) = decision else {
            XCTFail("Expected .block, got \(decision)")
            return
        }
        XCTAssertEqual(statusCode, 503)
    }

    func testBlockRuleUsesConfiguredStatusCode() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        try await store.addBlockRule(from: request, statusCode: 404, label: nil)

        let decision = try await store.ruleDecision(for: request)
        guard case .block(_, let statusCode, _, _) = decision else {
            XCTFail("Expected .block")
            return
        }
        XCTAssertEqual(statusCode, 404)
    }

    func testBlockRuleDoesNotMatchDifferentHost() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(host: "api.example.com")
        try await store.addBlockRule(from: request, statusCode: 503, label: nil)

        let otherRequest = makeRequest(host: "other.example.com")
        let decision = try await store.ruleDecision(for: otherRequest)
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch for different host, got \(decision)")
            return
        }
    }

    func testDisabledBlockRuleDoesNotMatch() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        let rule = try await store.addBlockRule(from: request, statusCode: 503, label: nil)
        try await store.setEnabled(false, for: rule.id)

        let decision = try await store.ruleDecision(for: request)
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch for disabled rule, got \(decision)")
            return
        }
    }

    func testBlockRuleHitCountIncrements() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        let rule = try await store.addBlockRule(from: request, statusCode: 503, label: nil)
        XCTAssertEqual(rule.hitCount, 0)

        _ = try await store.ruleDecision(for: request)
        _ = try await store.ruleDecision(for: request)

        let updated = await store.rules().first(where: { $0.id == rule.id })
        XCTAssertEqual(updated?.hitCount, 2)
    }

    // MARK: - Map Remote rules

    func testMapRemoteDecisionReturnedForMapRemoteRule() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(host: "api.example.com", port: 443)
        try await store.addMapRemoteRule(
            from: request,
            label: nil,
            remoteHost: "staging-api.example.com",
            remotePort: 443,
            remoteScheme: .https
        )

        let decision = try await store.ruleDecision(for: request)
        guard case .mapRemote(_, let host, let port, let scheme, _) = decision else {
            XCTFail("Expected .mapRemote, got \(decision)")
            return
        }
        XCTAssertEqual(host, "staging-api.example.com")
        XCTAssertEqual(port, 443)
        XCTAssertEqual(scheme, .https)
    }

    func testMapRemoteDerivesDefaultHttpsPort() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        try await store.addMapRemoteRule(
            from: request, label: nil,
            remoteHost: "staging.example.com", remotePort: nil, remoteScheme: .https
        )

        let decision = try await store.ruleDecision(for: request)
        guard case .mapRemote(_, _, let port, _, _) = decision else {
            XCTFail("Expected .mapRemote")
            return
        }
        XCTAssertEqual(port, 443)
    }

    func testMapRemoteDerivesDefaultHttpPort() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(scheme: .http, port: 80)
        try await store.addMapRemoteRule(
            from: request, label: nil,
            remoteHost: "staging.example.com", remotePort: nil, remoteScheme: .http
        )

        let decision = try await store.ruleDecision(for: request)
        guard case .mapRemote(_, _, let port, let scheme, _) = decision else {
            XCTFail("Expected .mapRemote")
            return
        }
        XCTAssertEqual(port, 80)
        XCTAssertEqual(scheme, .http)
    }

    func testMapRemoteDoesNotMatchDifferentPath() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/items")
        try await store.addMapRemoteRule(
            from: request, label: nil,
            remoteHost: "staging.example.com", remotePort: nil, remoteScheme: .https
        )

        let otherRequest = makeRequest(path: "/v1/other")
        let decision = try await store.ruleDecision(for: otherRequest)
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch for different path, got \(decision)")
            return
        }
    }

    // MARK: - Bookmark rewrite rules

    func testBookmarkRewriteDecisionReturnsFullBookmarkRequest() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(
            method: "POST",
            host: "api.example.com",
            path: "/v1/items?incoming=true"
        )
        let rewriteBody = Data("{\"rewritten\":true}".utf8)
        let bookmark = Bookmark(
            name: "Rewrite Items",
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/v1/items?incoming=true",
                headers: [
                    HTTPHeaderField(name: "Authorization", value: "Bearer saved"),
                    HTTPHeaderField(name: "Host", value: "api.example.com"),
                    HTTPHeaderField(name: "Content-Length", value: "999")
                ],
                bodyData: rewriteBody,
                bodySize: rewriteBody.count
            )
        )
        try await store.addBookmarkRewriteRule(from: bookmark, label: nil)

        let decision = try await store.ruleDecision(for: request)
        guard case .bookmarkRewrite(_, let rewrittenRequest, let sourceDescription) = decision else {
            XCTFail("Expected .bookmarkRewrite, got \(decision)")
            return
        }

        XCTAssertEqual(rewrittenRequest.method, "POST")
        XCTAssertEqual(rewrittenRequest.host, "api.example.com")
        XCTAssertEqual(rewrittenRequest.path, "/v1/items?incoming=true")
        XCTAssertEqual(rewrittenRequest.bodyData, rewriteBody)
        XCTAssertEqual(rewrittenRequest.headers, [HTTPHeaderField(name: "Authorization", value: "Bearer saved")])
        XCTAssertTrue(sourceDescription.contains("Rewritten from bookmark"))
    }

    func testBookmarkRewriteRuleSurvivesPersistenceRoundTrip() async throws {
        let store = ResponseOverrideStore()
        let bookmark = Bookmark(
            name: "Saved Rewrite",
            request: makeRequest(path: "/v1/rewrite")
        )
        try await store.addBookmarkRewriteRule(from: bookmark, label: "Use Saved")

        let data = try await store.persistedData()
        let restored = ResponseOverrideStore()
        try await restored.loadPersistedData(data)

        let decision = try await restored.ruleDecision(for: makeRequest(path: "/v1/rewrite"))
        guard case .bookmarkRewrite(_, let rewrittenRequest, _) = decision else {
            XCTFail("Expected .bookmarkRewrite after round-trip, got \(decision)")
            return
        }

        XCTAssertEqual(rewrittenRequest.path, "/v1/rewrite")
    }

    func testDisabledBookmarkRewriteRuleDoesNotMatch() async throws {
        let store = ResponseOverrideStore()
        let bookmark = Bookmark(
            name: "Disabled Rewrite",
            request: makeRequest(path: "/v1/rewrite")
        )
        let rule = try await store.addBookmarkRewriteRule(from: bookmark, label: nil)
        try await store.setEnabled(false, for: rule.id)

        let decision = try await store.ruleDecision(for: makeRequest(path: "/v1/rewrite"))
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch for disabled rewrite rule, got \(decision)")
            return
        }
    }

    func testBookmarkRewriteIgnoreQueryMatchesChangedQuery() async throws {
        let store = ResponseOverrideStore()
        let bookmark = Bookmark(
            name: "Ignore Query Rewrite",
            request: makeRequest(path: "/v1/profile?token=old")
        )
        try await store.addBookmarkRewriteRule(from: bookmark, label: nil, matchMode: .ignoreQuery)

        let decision = try await store.ruleDecision(for: makeRequest(path: "/v1/profile?token=new"))
        guard case .bookmarkRewrite(_, let rewrittenRequest, _) = decision else {
            XCTFail("Expected .bookmarkRewrite for changed query, got \(decision)")
            return
        }
        XCTAssertEqual(rewrittenRequest.path, "/v1/profile?token=old")
    }

    func testBookmarkRewritePathPrefixMatchesNestedPath() async throws {
        let store = ResponseOverrideStore()
        let bookmark = Bookmark(
            name: "Prefix Rewrite",
            request: makeRequest(path: "/v1/users")
        )
        try await store.addBookmarkRewriteRule(from: bookmark, label: nil, matchMode: .pathPrefix)

        let decision = try await store.ruleDecision(for: makeRequest(path: "/v1/users/123/profile?include=details"))
        guard case .bookmarkRewrite(_, let rewrittenRequest, _) = decision else {
            XCTFail("Expected .bookmarkRewrite for nested path, got \(decision)")
            return
        }
        XCTAssertEqual(rewrittenRequest.path, "/v1/users")
    }

    // MARK: - Persistence round-trips

    func testCapturedResponseOverrideSurvivesPersistenceRoundTrip() async throws {
        let store = ResponseOverrideStore()
        let session = makeSession(method: "POST", path: "/v1/events?token=abc")

        let createdRule = try await store.addCapturedResponseOverride(from: session)
        let persistedData = try await store.persistedData()

        let restoredStore = ResponseOverrideStore()
        try await restoredStore.loadPersistedData(persistedData)

        let restoredRules = await restoredStore.rules()
        XCTAssertEqual(restoredRules.count, 1)
        XCTAssertEqual(restoredRules.first?.id, createdRule.id)
        XCTAssertEqual(restoredRules.first?.requestMethod, "POST")
        XCTAssertEqual(restoredRules.first?.host, "api.example.com")
        XCTAssertEqual(restoredRules.first?.path, "/v1/events?token=abc")
        let persistedDecision = try await restoredStore.ruleDecision(for: session.request)
        guard case .mapLocal(let persistedResolved) = persistedDecision else {
            XCTFail("Expected .mapLocal after restore, got \(persistedDecision)")
            return
        }
        XCTAssertEqual(persistedResolved.statusCode, 200)
    }

    func testInlineOverrideLabelSurvivesPersistenceRoundTrip() async throws {
        let store = ResponseOverrideStore()
        let session = makeSession(host: "cdn.example.com", path: "/config.json")

        let createdRule = try await store.addInlineTextOverride(
            from: session,
            label: "Config Stub",
            statusCode: 200,
            contentType: "application/json",
            bodyText: #"{"ok":true}"#
        )
        let persistedData = try await store.persistedData()

        let restoredStore = ResponseOverrideStore()
        try await restoredStore.loadPersistedData(persistedData)

        let restoredRules = await restoredStore.rules()
        let restoredRule = try XCTUnwrap(restoredRules.first)
        XCTAssertEqual(restoredRule.id, createdRule.id)
        XCTAssertEqual(restoredRule.label, "Config Stub")
        XCTAssertEqual(restoredRule.displayTitle, "Config Stub")
    }

    func testIgnoreQueryMatchModeSurvivesPersistenceRoundTrip() async throws {
        let store = ResponseOverrideStore()
        let session = makeSession(path: "/v1/profile?token=old")

        let createdRule = try await store.addCapturedResponseOverride(
            from: session,
            matchMode: .ignoreQuery
        )
        let persistedData = try await store.persistedData()

        let restoredStore = ResponseOverrideStore()
        try await restoredStore.loadPersistedData(persistedData)

        let restoredRules = await restoredStore.rules()
        let restoredRule = try XCTUnwrap(restoredRules.first)
        XCTAssertEqual(restoredRule.id, createdRule.id)
        XCTAssertEqual(restoredRule.matchMode, .ignoreQuery)

        let changedQueryRequest = makeRequest(path: "/v1/profile?token=new")
        let queryDecision = try await restoredStore.ruleDecision(for: changedQueryRequest)
        guard case .mapLocal(let queryResolved) = queryDecision else {
            XCTFail("Expected .mapLocal for changed query, got \(queryDecision)")
            return
        }
        XCTAssertEqual(queryResolved.statusCode, 200)
    }

    func testBlockRuleSurvivesPersistenceRoundTrip() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        try await store.addBlockRule(from: request, statusCode: 418, label: "Teapot")

        let data = try await store.persistedData()
        let restored = ResponseOverrideStore()
        try await restored.loadPersistedData(data)

        let decision = try await restored.ruleDecision(for: request)
        guard case .block(_, let statusCode, _, _) = decision else {
            XCTFail("Expected .block after round-trip, got \(decision)")
            return
        }
        XCTAssertEqual(statusCode, 418)
    }

    func testMapRemoteRuleSurvivesPersistenceRoundTrip() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        try await store.addMapRemoteRule(
            from: request, label: "Staging",
            remoteHost: "staging.example.com", remotePort: 8443, remoteScheme: .https
        )

        let data = try await store.persistedData()
        let restored = ResponseOverrideStore()
        try await restored.loadPersistedData(data)

        let decision = try await restored.ruleDecision(for: request)
        guard case .mapRemote(_, let host, let port, let scheme, _) = decision else {
            XCTFail("Expected .mapRemote after round-trip, got \(decision)")
            return
        }
        XCTAssertEqual(host, "staging.example.com")
        XCTAssertEqual(port, 8443)
        XCTAssertEqual(scheme, .https)
    }

    func testMapRemoteRuleWithPathOverrideSurvivesPersistenceRoundTrip() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/items?x=1")
        try await store.addMapRemoteRule(
            from: request, label: "Staging",
            remoteHost: "staging.example.com", remotePort: 8443, remoteScheme: .https,
            remotePath: "/v2/items"
        )

        let data = try await store.persistedData()
        let restored = ResponseOverrideStore()
        try await restored.loadPersistedData(data)

        let decision = try await restored.ruleDecision(for: request)
        guard case .mapRemote(_, _, _, _, let requestTarget) = decision else {
            XCTFail("Expected .mapRemote after round-trip, got \(decision)")
            return
        }
        // Default policy is .preserve — the overridden path keeps the original query.
        XCTAssertEqual(requestTarget, "/v2/items?x=1")
    }

    /// A rule persisted before `mapRemotePath`/`mapRemoteQueryPolicy`/`mapRemoteQuery` existed
    /// must still decode cleanly, with the query policy defaulting to `.preserve` (the only
    /// behavior that existed before these fields) and no path override.
    func testMapRemoteDecodesLegacyPersistedDataWithoutPathFields() async throws {
        let ruleID = UUID()
        let legacyJSON = """
        [{
            "id": "\(ruleID.uuidString)",
            "requestMethod": "GET",
            "requestScheme": "https",
            "host": "api.example.com",
            "path": "/v1/items",
            "matchMode": "exactPath",
            "sourceKind": "mapRemote",
            "sourceDescription": "Remapped to remote host",
            "statusCode": 200,
            "headers": [],
            "bodySource": {"kind": "inline"},
            "createdAt": 0,
            "isEnabled": true,
            "hitCount": 0,
            "mapRemoteHost": "staging.example.com",
            "mapRemotePort": 443,
            "mapRemoteScheme": "https"
        }]
        """
        let store = ResponseOverrideStore()
        try await store.loadPersistedData(Data(legacyJSON.utf8))

        let request = makeRequest()
        let decision = try await store.ruleDecision(for: request)
        guard case .mapRemote(_, _, _, _, let requestTarget) = decision else {
            XCTFail("Expected .mapRemote, got \(decision)")
            return
        }
        XCTAssertNil(requestTarget, "no mapRemotePath in legacy data means the original path/query is reused verbatim")
    }

    func testMapRemoteQueryPolicyReplaceUsesConfiguredQuery() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/items?x=1")
        try await store.addMapRemoteRule(
            from: request, label: nil,
            remoteHost: "staging.example.com", remotePort: nil, remoteScheme: .https,
            remotePath: "/v2/items", remoteQueryPolicy: .replace, remoteQuery: "y=2"
        )
        let decision = try await store.ruleDecision(for: request)
        guard case .mapRemote(_, _, _, _, let requestTarget) = decision else {
            XCTFail("Expected .mapRemote, got \(decision)")
            return
        }
        XCTAssertEqual(requestTarget, "/v2/items?y=2")
    }

    func testMapRemoteQueryPolicyDropOmitsQuery() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/items?x=1")
        try await store.addMapRemoteRule(
            from: request, label: nil,
            remoteHost: "staging.example.com", remotePort: nil, remoteScheme: .https,
            remotePath: "/v2/items", remoteQueryPolicy: .drop
        )
        let decision = try await store.ruleDecision(for: request)
        guard case .mapRemote(_, _, _, _, let requestTarget) = decision else {
            XCTFail("Expected .mapRemote, got \(decision)")
            return
        }
        XCTAssertEqual(requestTarget, "/v2/items")
    }

    func testMapRemoteWithNoPathOverrideReusesOriginalPathVerbatim() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/items?x=1")
        try await store.addMapRemoteRule(
            from: request, label: nil,
            remoteHost: "staging.example.com", remotePort: nil, remoteScheme: .https
        )
        let decision = try await store.ruleDecision(for: request)
        guard case .mapRemote(_, _, _, _, let requestTarget) = decision else {
            XCTFail("Expected .mapRemote, got \(decision)")
            return
        }
        XCTAssertNil(requestTarget, "no path override means the caller must reuse the original request's path/query unchanged")
    }

    func testMapLocalRuleSurvivesRoundTripWithNewFieldsPresent() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        let body = Data("legacy".utf8)
        try await store.addRule(makeInlineRule(for: request, body: body))

        let data = try await store.persistedData()
        let restored = ResponseOverrideStore()
        try await restored.loadPersistedData(data)

        let decision = try await restored.ruleDecision(for: request)
        guard case .mapLocal(let resolved) = decision else {
            XCTFail("Expected .mapLocal after round-trip, got \(decision)")
            return
        }
        XCTAssertEqual(resolved.bodyData, body)
    }

    // MARK: - Conflict and match modes

    func testReplaceExistingRemovesExactMatchBeforeAddingNewRule() async throws {
        let store = ResponseOverrideStore()
        let session = makeSession(path: "/v1/profile")

        _ = try await store.addInlineTextOverride(
            from: session,
            label: "Old",
            conflictStrategy: .keepBoth,
            statusCode: 200,
            contentType: "application/json",
            bodyText: #"{"version":1}"#
        )

        _ = try await store.addInlineTextOverride(
            from: session,
            label: "New",
            conflictStrategy: .replaceExisting,
            statusCode: 201,
            contentType: "application/json",
            bodyText: #"{"version":2}"#
        )

        let rules = await store.rules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.label, "New")

        let replaceDecision = try await store.ruleDecision(for: session.request)
        guard case .mapLocal(let replaceResolved) = replaceDecision else {
            XCTFail("Expected .mapLocal for replaced rule, got \(replaceDecision)")
            return
        }
        XCTAssertEqual(replaceResolved.statusCode, 201)
        XCTAssertEqual(replaceResolved.bodyData, Data(#"{"version":2}"#.utf8))
    }

    func testReplaceExistingRemovesIgnoreQueryMatchRules() async throws {
        let store = ResponseOverrideStore()
        let existingSession = makeSession(path: "/v1/profile?token=old")
        let replacementSession = makeSession(path: "/v1/profile?token=new")

        _ = try await store.addInlineTextOverride(
            from: existingSession,
            label: "Old Query-Agnostic Rule",
            matchMode: .ignoreQuery,
            conflictStrategy: .keepBoth,
            statusCode: 200,
            contentType: "application/json",
            bodyText: #"{"version":1}"#
        )

        _ = try await store.addInlineTextOverride(
            from: replacementSession,
            label: "Replacement Query-Agnostic Rule",
            matchMode: .ignoreQuery,
            conflictStrategy: .replaceExisting,
            statusCode: 201,
            contentType: "application/json",
            bodyText: #"{"version":2}"#
        )

        let rules = await store.rules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.label, "Replacement Query-Agnostic Rule")
        XCTAssertEqual(rules.first?.matchMode, .ignoreQuery)

        let ignoreQueryDecision = try await store.ruleDecision(for: existingSession.request)
        guard case .mapLocal(let ignoreQueryResolved) = ignoreQueryDecision else {
            XCTFail("Expected .mapLocal for ignoreQuery rule, got \(ignoreQueryDecision)")
            return
        }
        XCTAssertEqual(ignoreQueryResolved.statusCode, 201)
        XCTAssertEqual(ignoreQueryResolved.bodyData, Data(#"{"version":2}"#.utf8))
    }

    func testPathPrefixMatchesNestedPathsAndIgnoresQuery() async throws {
        let store = ResponseOverrideStore()
        let sourceSession = makeSession(path: "/v1/users")

        _ = try await store.addInlineTextOverride(
            from: sourceSession,
            label: "Users Prefix",
            matchMode: .pathPrefix,
            statusCode: 203,
            contentType: "application/json",
            bodyText: #"{"source":"prefix"}"#
        )

        let nestedRequest = makeRequest(path: "/v1/users/123/profile?include=details")

        let nestedDecision = try await store.ruleDecision(for: nestedRequest)
        guard case .mapLocal(let nestedResolved) = nestedDecision else {
            XCTFail("Expected .mapLocal for nested path, got \(nestedDecision)")
            return
        }
        XCTAssertEqual(nestedResolved.statusCode, 203)
        XCTAssertEqual(nestedResolved.bodyData, Data(#"{"source":"prefix"}"#.utf8))
    }

    func testPathPrefixDoesNotMatchSiblingPaths() async throws {
        let store = ResponseOverrideStore()
        let sourceSession = makeSession(path: "/v1/users")

        _ = try await store.addCapturedResponseOverride(
            from: sourceSession,
            matchMode: .pathPrefix
        )

        let siblingRequest = makeRequest(path: "/v1/usersettings")

        let siblingDecision = try await store.ruleDecision(for: siblingRequest)
        guard case .noMatch = siblingDecision else {
            XCTFail("Expected .noMatch for sibling path, got \(siblingDecision)")
            return
        }
    }

    // Reference scenario (memlog/Research/reference-scenario): two endpoints sharing the same
    // dynamic-id prefix (/v1/sessions/{id}/heartbeat vs /v1/sessions/{id}/status) only diverge in
    // their trailing suffix — proves .pathPrefix cannot isolate one from the other, and .pathSuffix
    // can.
    func testPathSuffixBlocksHeartbeatButNotSiblingStatusEndpoint() async throws {
        let store = ResponseOverrideStore()
        let heartbeatRule = makeRequest(path: "/heartbeat")
        try await store.addBlockRule(from: heartbeatRule, statusCode: 503, label: "Kill heartbeat", matchMode: .pathSuffix)

        let heartbeatRequest = makeRequest(path: "/v1/sessions/session-A/heartbeat")
        let heartbeatDecision = try await store.ruleDecision(for: heartbeatRequest)
        guard case .block(_, let statusCode, _, _) = heartbeatDecision else {
            XCTFail("Expected .block for heartbeat, got \(heartbeatDecision)")
            return
        }
        XCTAssertEqual(statusCode, 503)

        let statusRequest = makeRequest(path: "/v1/sessions/session-A/status")
        let statusDecision = try await store.ruleDecision(for: statusRequest)
        guard case .noMatch = statusDecision else {
            XCTFail("Expected .noMatch for sibling status endpoint, got \(statusDecision)")
            return
        }

        let bootstrapRequest = makeRequest(path: "/v1/config/bootstrap")
        let bootstrapDecision = try await store.ruleDecision(for: bootstrapRequest)
        guard case .noMatch = bootstrapDecision else {
            XCTFail("Expected .noMatch for unrelated control endpoint, got \(bootstrapDecision)")
            return
        }
    }

    func testPathPrefixCannotIsolateHeartbeatFromSiblingStatusEndpoint() async throws {
        // Documents why .pathPrefix is insufficient for this shape: a prefix matcher scoped
        // tightly enough to hit /v1/sessions/session-A/heartbeat necessarily also hits
        // /v1/sessions/session-A/status, since both share that exact prefix through the id.
        let store = ResponseOverrideStore()
        let prefixRule = makeRequest(path: "/v1/sessions/session-A")
        try await store.addBlockRule(from: prefixRule, statusCode: 503, label: "Overbroad prefix", matchMode: .pathPrefix)

        let statusRequest = makeRequest(path: "/v1/sessions/session-A/status")
        let statusDecision = try await store.ruleDecision(for: statusRequest)
        guard case .block = statusDecision else {
            XCTFail("Expected .pathPrefix to (incorrectly, for this use case) also catch the sibling status endpoint, got \(statusDecision)")
            return
        }
    }

    // MARK: - updateBlockRule

    func testUpdateBlockRuleChangesStatusCodeAndLabel() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        let rule = try await store.addBlockRule(from: request, statusCode: 503, label: nil, matchMode: .exactPath)

        try await store.updateBlockRule(id: rule.id, label: "Custom block", matchMode: .ignoreQuery, statusCode: 403)

        let decision = try await store.ruleDecision(for: request)
        guard case .block(_, let statusCode, _, _) = decision else {
            XCTFail("Expected .block decision after update, got \(decision)")
            return
        }
        XCTAssertEqual(statusCode, 403)

        let updated = await store.rules().first(where: { $0.id == rule.id })
        XCTAssertEqual(updated?.label, "Custom block")
        XCTAssertEqual(updated?.matchMode, .ignoreQuery)
    }

    func testUpdateBlockRuleIgnoresNonBlockRule() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        let inlineRule = makeInlineRule(for: request, statusCode: 200)
        try await store.addRule(inlineRule)

        // Calling updateBlockRule on a non-block rule must be a no-op.
        try await store.updateBlockRule(id: inlineRule.id, label: "should not apply", matchMode: .exactPath, statusCode: 999)

        let rule = await store.rules().first(where: { $0.id == inlineRule.id })
        XCTAssertEqual(rule?.statusCode, 200)
        XCTAssertNil(rule?.label)
    }

    // MARK: - updateMapRemoteRule

    func testUpdateMapRemoteRuleChangesDestination() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        let rule = try await store.addMapRemoteRule(
            from: request,
            label: nil,
            matchMode: .exactPath,
            remoteHost: "staging.example.com",
            remotePort: 443,
            remoteScheme: .https
        )

        try await store.updateMapRemoteRule(
            id: rule.id,
            label: "Prod → Dev",
            matchMode: .ignoreQuery,
            remoteHost: "dev.example.com",
            remotePort: 8080,
            remoteScheme: .http
        )

        let updated = await store.rules().first(where: { $0.id == rule.id })
        XCTAssertEqual(updated?.mapRemoteHost, "dev.example.com")
        XCTAssertEqual(updated?.mapRemotePort, 8080)
        XCTAssertEqual(updated?.mapRemoteScheme, .http)
        XCTAssertEqual(updated?.label, "Prod → Dev")
        XCTAssertEqual(updated?.matchMode, .ignoreQuery)
    }

    func testUpdateMapRemoteRuleSourceDescriptionRefreshes() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        let rule = try await store.addMapRemoteRule(
            from: request,
            label: nil,
            matchMode: .exactPath,
            remoteHost: "staging.example.com",
            remotePort: 443,
            remoteScheme: .https
        )

        try await store.updateMapRemoteRule(
            id: rule.id,
            label: nil,
            matchMode: .exactPath,
            remoteHost: "dev.example.com",
            remotePort: 9090,
            remoteScheme: .http
        )

        let updated = await store.rules().first(where: { $0.id == rule.id })
        XCTAssert(updated?.sourceDescription.contains("dev.example.com") == true, "Source description should reflect new host")
        XCTAssert(updated?.sourceDescription.contains("9090") == true, "Source description should reflect new port")
    }

    // MARK: - updateInlineTextOverride

    func testUpdateInlineTextOverrideChangesStoredRule() async throws {
        let store = ResponseOverrideStore()
        let session = makeSession(path: "/v1/settings")
        let rule = try await store.addInlineTextOverride(
            from: session,
            label: "Settings",
            statusCode: 200,
            contentType: "application/json",
            bodyText: #"{"enabled":false}"#
        )

        try await store.updateInlineTextOverride(
            id: rule.id,
            label: "Settings Edited",
            matchMode: .ignoreQuery,
            statusCode: 202,
            contentType: "application/json; charset=utf-8",
            bodyText: #"{"enabled":true}"#
        )

        let updatedRules = await store.rules()
        let updatedRule = try XCTUnwrap(updatedRules.first)
        XCTAssertEqual(updatedRule.label, "Settings Edited")
        XCTAssertEqual(updatedRule.matchMode, .ignoreQuery)
        XCTAssertEqual(updatedRule.statusCode, 202)
        XCTAssertTrue(updatedRule.headers.contains(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame &&
            $0.value == "application/json; charset=utf-8"
        }))

        let updatedRequest = makeRequest(path: "/v1/settings?cache=false")

        let updatedDecision = try await store.ruleDecision(for: updatedRequest)
        guard case .mapLocal(let updatedResolved) = updatedDecision else {
            XCTFail("Expected .mapLocal after update, got \(updatedDecision)")
            return
        }
        XCTAssertEqual(updatedResolved.statusCode, 202)
        XCTAssertEqual(updatedResolved.bodyData, Data(#"{"enabled":true}"#.utf8))
    }

    // MARK: - Live response rewrite

    func testLiveResponseRewriteRuleDecisionReturnsLiveRewriteCase() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/flags")
        try await store.addLiveResponseRewriteRule(
            from: request,
            label: "Patch flag",
            rewrites: [
                BookmarkResponseFieldRewrite(jsonPath: "flag", overrideValue: .bool(true))
            ]
        )

        let decision = try await store.ruleDecision(for: request)
        guard case .liveResponseRewrite(_, let rewrites, _, _) = decision else {
            XCTFail("Expected .liveResponseRewrite, got \(decision)")
            return
        }
        XCTAssertEqual(rewrites.count, 1)
        XCTAssertEqual(rewrites.first?.jsonPath, "flag")
    }

    func testLiveResponseRewritePersistsAndRestoresRewrites() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/data")
        try await store.addLiveResponseRewriteRule(
            from: request,
            label: "Live",
            rewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: "enabled",
                    overrideValue: .bool(false),
                    operation: .set
                )
            ]
        )

        let data = try await store.persistedData()
        let restored = ResponseOverrideStore()
        try await restored.loadPersistedData(data)

        let restoredRules = await restored.rules()
        let rule = try XCTUnwrap(restoredRules.first)
        XCTAssertEqual(rule.sourceKind, .liveResponseRewrite)
        XCTAssertEqual(rule.liveResponseRewrites.count, 1)
        XCTAssertEqual(rule.liveResponseRewrites.first?.jsonPath, "enabled")
        XCTAssertEqual(rule.liveResponseRewrites.first?.operation, .set)
    }

    // MARK: - Live collection mock

    private func makeCollectionMockPlan() throws -> CompiledCollectionMock {
        try CollectionMockCompiler.prepare(
            source: Data(#"{"items":[{"id":"original"}],"total":1}"#.utf8),
            draft: .init(collectionPointer: "/items", item: .object(["id": .string("synthetic")]),
                templateIndex: nil, edits: [], identityPointers: ["/id"], countPointers: ["/total"],
                position: .append)
        )
    }

    func testCollectionMockRuleDecisionReturnsLiveCollectionMockCase() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/feed")
        let plan = try makeCollectionMockPlan()
        _ = try await store.addCollectionMockRule(from: request, label: "Mock feed item", plan: plan)

        let decision = try await store.ruleDecision(for: request)
        guard case .liveCollectionMock(let ruleID, let decidedPlan, let sourceDescription, _) = decision else {
            XCTFail("Expected .liveCollectionMock, got \(decision)")
            return
        }
        XCTAssertNotEqual(ruleID, UUID())
        XCTAssertEqual(decidedPlan, plan)
        XCTAssertFalse(sourceDescription.isEmpty)
    }

    func testCollectionMockRuleDecisionNoMatchWhenDisabled() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/feed")
        let rule = try await store.addCollectionMockRule(from: request, label: nil, plan: try makeCollectionMockPlan())
        try await store.setEnabled(false, for: rule.id)

        let decision = try await store.ruleDecision(for: request)
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch for a disabled rule, got \(decision)")
            return
        }
    }

    func testCollectionMockRulePersistsAndRestoresPlan() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/feed")
        let plan = try makeCollectionMockPlan()
        _ = try await store.addCollectionMockRule(from: request, label: "Mock", plan: plan)

        let data = try await store.persistedData()
        let restored = ResponseOverrideStore()
        try await restored.loadPersistedData(data)

        let restoredRules = await restored.rules()
        let rule = try XCTUnwrap(restoredRules.first)
        XCTAssertEqual(rule.sourceKind, .collectionMock)
        XCTAssertEqual(rule.collectionMockPlan, plan)
    }

    func testCollectionMockRuleActivationTracksEnableAndDisable() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/feed")
        let rule = try await store.addCollectionMockRule(from: request, label: nil, plan: try makeCollectionMockPlan())
        defer { LiveTransformationActivationTracker.shared.clear(ruleID: rule.id) }

        XCTAssertTrue(LiveTransformationActivationTracker.shared.isWithinBudget(ruleID: rule.id))
        try await store.setEnabled(false, for: rule.id)
        // Cleared entries fail open by design (see `LiveTransformationActivationTracker`'s doc
        // comment); the meaningful assertion is that `recordTransformed` calls before disabling
        // don't leak into a freshly re-enabled activation.
        LiveTransformationActivationTracker.shared.recordTransformed(ruleID: rule.id)
        try await store.setEnabled(true, for: rule.id)
        XCTAssertTrue(LiveTransformationActivationTracker.shared.isWithinBudget(ruleID: rule.id))
    }

    func testCollectionMockRuleRemovalClearsActivationTracker() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/feed")
        let rule = try await store.addCollectionMockRule(from: request, label: nil, plan: try makeCollectionMockPlan())
        for _ in 0..<LiveTransformationExecutionBudget.maxTransformedResponsesPerActivation {
            LiveTransformationActivationTracker.shared.recordTransformed(ruleID: rule.id)
        }
        XCTAssertFalse(LiveTransformationActivationTracker.shared.isWithinBudget(ruleID: rule.id))
        await store.removeRule(id: rule.id)
        // Removal clears the tracker entry entirely; a fresh (never-recorded) ruleID fails open.
        XCTAssertTrue(LiveTransformationActivationTracker.shared.isWithinBudget(ruleID: rule.id))
    }

    func testLiveResponseRewriteRejectsExclusiveConflictWithBlockRule() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/v1/api")
        try await store.addBlockRule(from: request, statusCode: 503, label: nil)

        do {
            _ = try await store.addLiveResponseRewriteRule(
                from: request,
                label: nil,
                rewrites: [
                    BookmarkResponseFieldRewrite(jsonPath: "flag", overrideValue: .bool(true))
                ]
            )
            XCTFail("Expected exclusiveRuleConflict")
        } catch ResponseOverrideError.exclusiveRuleConflict {
            // Expected: enabled block rule already matches this matcher.
        }
    }

    // MARK: - GraphQL operationName matching

    func testGraphQLOperationNameOnlyMatchesRequestWithThatOperation() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(method: "POST", path: "/graphql")
        try await store.addBlockRule(
            from: request,
            statusCode: 503,
            label: nil,
            graphQLOperationName: "GetUser"
        )

        let matchingRequest = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/graphql",
            headers: [],
            bodyData: Data(#"{"operationName":"GetUser","query":"{ user { id } }"}"#.utf8),
            bodySize: nil
        )
        let matchingDecision = try await store.ruleDecision(for: matchingRequest)
        guard case .block = matchingDecision else {
            XCTFail("Expected .block for matching operationName, got \(matchingDecision)")
            return
        }

        let otherRequest = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/graphql",
            headers: [],
            bodyData: Data(#"{"operationName":"GetPosts","query":"{ posts { id } }"}"#.utf8),
            bodySize: nil
        )
        let otherDecision = try await store.ruleDecision(for: otherRequest)
        guard case .noMatch = otherDecision else {
            XCTFail("Expected .noMatch for different operationName, got \(otherDecision)")
            return
        }
    }

    func testGraphQLOperationNameFailsClosedOnMissingOperationNameField() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(method: "POST", path: "/graphql")
        try await store.addBlockRule(
            from: request,
            statusCode: 503,
            label: nil,
            graphQLOperationName: "GetUser"
        )

        let bodyWithoutOperationName = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/graphql",
            headers: [],
            bodyData: Data(#"{"query":"{ user { id } }"}"#.utf8),
            bodySize: nil
        )
        let decision = try await store.ruleDecision(for: bodyWithoutOperationName)
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch when operationName key is absent, got \(decision)")
            return
        }
    }

    func testGraphQLOperationNameFailsClosedOnNonJSONBody() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(method: "POST", path: "/graphql")
        try await store.addBlockRule(
            from: request,
            statusCode: 503,
            label: nil,
            graphQLOperationName: "GetUser"
        )

        let nonJSONRequest = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/graphql",
            headers: [],
            bodyData: Data("not json".utf8),
            bodySize: nil
        )
        let decision = try await store.ruleDecision(for: nonJSONRequest)
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch for non-JSON body, got \(decision)")
            return
        }
    }

    func testGraphQLOperationNameFailsClosedOnTruncatedBody() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(method: "POST", path: "/graphql")
        try await store.addBlockRule(
            from: request,
            statusCode: 503,
            label: nil,
            graphQLOperationName: "GetUser"
        )

        // Body happens to still parse as valid (but wrong) JSON — the truncation flag must be
        // checked explicitly, not inferred from a parse failure that may not occur.
        let truncatedRequest = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/graphql",
            headers: [],
            bodyData: Data(#"{"operationName":"GetUser"}"#.utf8),
            bodySize: nil,
            bodyTruncated: true
        )
        let decision = try await store.ruleDecision(for: truncatedRequest)
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch for truncated body even if parseable, got \(decision)")
            return
        }
    }

    func testTwoRulesWithDifferentGraphQLOperationNamesOnSamePathDoNotConflict() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(method: "POST", path: "/graphql")
        try await store.addBlockRule(
            from: request, statusCode: 503, label: "GetUser block",
            graphQLOperationName: "GetUser"
        )

        // Must not throw — two rules scoped to different operations on the same matcher coexist.
        _ = try await store.addBlockRule(
            from: request, statusCode: 503, label: "GetPosts block",
            graphQLOperationName: "GetPosts"
        )
    }

    func testRuleWithNilGraphQLOperationNameConflictsWithScopedRule() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(method: "POST", path: "/graphql")
        try await store.addBlockRule(
            from: request, statusCode: 503, label: "GetUser block",
            graphQLOperationName: "GetUser"
        )

        do {
            _ = try await store.addBlockRule(from: request, statusCode: 503, label: "Unscoped block")
            XCTFail("Expected exclusiveRuleConflict: an unscoped rule shadows a scoped one")
        } catch ResponseOverrideError.exclusiveRuleConflict {
            // Expected.
        }
    }

    func testTwoRulesWithSameGraphQLOperationNameOnSamePathConflict() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(method: "POST", path: "/graphql")
        try await store.addBlockRule(
            from: request, statusCode: 503, label: "First",
            graphQLOperationName: "GetUser"
        )

        do {
            _ = try await store.addBlockRule(
                from: request, statusCode: 503, label: "Duplicate",
                graphQLOperationName: "GetUser"
            )
            XCTFail("Expected exclusiveRuleConflict for a duplicate operation-scoped rule")
        } catch ResponseOverrideError.exclusiveRuleConflict {
            // Expected.
        }
    }

    func testGraphQLOperationNameSurvivesPersistenceRoundTrip() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(method: "POST", path: "/graphql")
        try await store.addBlockRule(
            from: request, statusCode: 503, label: nil,
            graphQLOperationName: "GetUser"
        )

        let data = try await store.persistedData()
        let restored = ResponseOverrideStore()
        try await restored.loadPersistedData(data)

        let matchingRequest = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/graphql",
            headers: [],
            bodyData: Data(#"{"operationName":"GetUser"}"#.utf8),
            bodySize: nil
        )
        let decision = try await restored.ruleDecision(for: matchingRequest)
        guard case .block = decision else {
            XCTFail("Expected .block after round-trip, got \(decision)")
            return
        }
    }

    /// A rule persisted before `graphQLOperationName` existed must still decode cleanly, with the
    /// field defaulting to nil (matches every operation, the only behavior that existed before).
    func testLegacyPersistedRuleWithoutGraphQLOperationNameDecodesAsNil() async throws {
        let ruleID = UUID()
        let legacyJSON = """
        [{
            "id": "\(ruleID.uuidString)",
            "requestMethod": "POST",
            "requestScheme": "https",
            "host": "api.example.com",
            "path": "/graphql",
            "matchMode": "exactPath",
            "sourceKind": "block",
            "sourceDescription": "Block",
            "statusCode": 503,
            "headers": [],
            "bodySource": {"kind": "inline"},
            "createdAt": 0,
            "isEnabled": true,
            "hitCount": 0
        }]
        """
        let store = ResponseOverrideStore()
        try await store.loadPersistedData(Data(legacyJSON.utf8))

        // No operationName in the request body at all — a nil-scoped legacy rule still matches
        // every operation, exactly as it did before this field existed.
        let request = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/graphql",
            headers: [],
            bodyData: Data(#"{"query":"{ anything }"}"#.utf8),
            bodySize: nil
        )
        let decision = try await store.ruleDecision(for: request)
        guard case .block = decision else {
            XCTFail("Expected legacy rule (no graphQLOperationName key) to still match, got \(decision)")
            return
        }
    }

    // MARK: - Query-parameter predicate (P1, memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6)

    // `.ignoreQuery` throughout: the predicate scopes one query key independent of the rest of the
    // query string, which only makes sense combined with a matchMode that doesn't require the
    // entire query string to match byte-for-byte (`.exactPath` would defeat the whole point).
    func testMatchQueryPredicateOnlyMatchesRequestWithThatKeyValue() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/catalog/item")
        try await store.addBlockRule(
            from: request,
            statusCode: 503,
            label: nil,
            matchMode: .ignoreQuery,
            matchQueryKey: "contentId",
            matchQueryValue: "1234"
        )

        let matchingRequest = makeRequest(path: "/catalog/item?contentId=1234")
        let matchingDecision = try await store.ruleDecision(for: matchingRequest)
        guard case .block = matchingDecision else {
            XCTFail("Expected .block for matching contentId, got \(matchingDecision)")
            return
        }

        let otherRequest = makeRequest(path: "/catalog/item?contentId=5678")
        let otherDecision = try await store.ruleDecision(for: otherRequest)
        guard case .noMatch = otherDecision else {
            XCTFail("Expected .noMatch for a different contentId value, got \(otherDecision)")
            return
        }
    }

    func testMatchQueryPredicateFailsClosedOnMissingQueryKey() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/catalog/item")
        try await store.addBlockRule(
            from: request,
            statusCode: 503,
            label: nil,
            matchMode: .ignoreQuery,
            matchQueryKey: "contentId",
            matchQueryValue: "1234"
        )

        let requestWithoutKey = makeRequest(path: "/catalog/item?otherKey=1234")
        let decision = try await store.ruleDecision(for: requestWithoutKey)
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch when the required query key is absent, got \(decision)")
            return
        }
    }

    func testTwoRulesWithDifferentMatchQueryValuesOnSameKeySamePathDoNotConflict() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/catalog/item")
        try await store.addBlockRule(
            from: request, statusCode: 503, label: "contentId 1234", matchMode: .ignoreQuery,
            matchQueryKey: "contentId", matchQueryValue: "1234"
        )

        // Must not throw — two rules scoped to different values of the same key coexist (a real
        // request's query string can only ever satisfy one of them).
        _ = try await store.addBlockRule(
            from: request, statusCode: 503, label: "contentId 5678", matchMode: .ignoreQuery,
            matchQueryKey: "contentId", matchQueryValue: "5678"
        )
    }

    func testRuleWithNilMatchQueryPredicateConflictsWithScopedRule() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/catalog/item")
        try await store.addBlockRule(
            from: request, statusCode: 503, label: "contentId 1234", matchMode: .ignoreQuery,
            matchQueryKey: "contentId", matchQueryValue: "1234"
        )

        do {
            _ = try await store.addBlockRule(
                from: request, statusCode: 503, label: "Unscoped block", matchMode: .ignoreQuery
            )
            XCTFail("Expected exclusiveRuleConflict: an unscoped rule shadows a query-scoped one")
        } catch ResponseOverrideError.exclusiveRuleConflict {
            // Expected.
        }
    }

    func testTwoRulesWithSameMatchQueryKeyValueOnSamePathConflict() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/catalog/item")
        try await store.addBlockRule(
            from: request, statusCode: 503, label: "First", matchMode: .ignoreQuery,
            matchQueryKey: "contentId", matchQueryValue: "1234"
        )

        do {
            _ = try await store.addBlockRule(
                from: request, statusCode: 503, label: "Duplicate", matchMode: .ignoreQuery,
                matchQueryKey: "contentId", matchQueryValue: "1234"
            )
            XCTFail("Expected exclusiveRuleConflict for a duplicate query-scoped rule")
        } catch ResponseOverrideError.exclusiveRuleConflict {
            // Expected.
        }
    }

    func testMatchQueryPredicateSurvivesPersistenceRoundTrip() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest(path: "/catalog/item")
        try await store.addBlockRule(
            from: request, statusCode: 503, label: nil, matchMode: .ignoreQuery,
            matchQueryKey: "contentId", matchQueryValue: "1234"
        )

        let data = try await store.persistedData()
        let restored = ResponseOverrideStore()
        try await restored.loadPersistedData(data)

        let matchingRequest = makeRequest(path: "/catalog/item?contentId=1234")
        let decision = try await restored.ruleDecision(for: matchingRequest)
        guard case .block = decision else {
            XCTFail("Expected .block after round-trip, got \(decision)")
            return
        }
    }

    /// A rule persisted before `matchQueryKey`/`matchQueryValue` existed must still decode cleanly,
    /// with both fields defaulting to nil (matches regardless of query, the only behavior that
    /// existed before this field).
    func testLegacyPersistedRuleWithoutMatchQueryPredicateDecodesAsNil() async throws {
        let ruleID = UUID()
        let legacyJSON = """
        [{
            "id": "\(ruleID.uuidString)",
            "requestMethod": "GET",
            "requestScheme": "https",
            "host": "api.example.com",
            "path": "/catalog/item",
            "matchMode": "ignoreQuery",
            "sourceKind": "block",
            "sourceDescription": "Block",
            "statusCode": 503,
            "headers": [],
            "bodySource": {"kind": "inline"},
            "createdAt": 0,
            "isEnabled": true,
            "hitCount": 0
        }]
        """
        let store = ResponseOverrideStore()
        try await store.loadPersistedData(Data(legacyJSON.utf8))

        let request = makeRequest(path: "/catalog/item?contentId=anything")
        let decision = try await store.ruleDecision(for: request)
        guard case .block = decision else {
            XCTFail("Expected legacy rule (no matchQueryKey/matchQueryValue) to still match, got \(decision)")
            return
        }
    }

    func testLiveResponseRewriteDecodesLegacyPersistedDataWithoutRewritesField() async throws {
        let ruleID = UUID()
        let legacyJSON = """
        [{
            "id": "\(ruleID.uuidString)",
            "requestMethod": "GET",
            "requestScheme": "https",
            "host": "api.example.com",
            "path": "/v1/data",
            "matchMode": "exactPath",
            "sourceKind": "liveResponseRewrite",
            "sourceDescription": "Live response rewrite",
            "statusCode": 200,
            "headers": [],
            "bodySource": {"kind": "inline"},
            "createdAt": 0,
            "isEnabled": true,
            "hitCount": 0
        }]
        """
        let store = ResponseOverrideStore()
        try await store.loadPersistedData(Data(legacyJSON.utf8))

        let rules = await store.rules()
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.sourceKind, .liveResponseRewrite)
        XCTAssertTrue(rule.liveResponseRewrites.isEmpty)
    }

    // MARK: - Fixture-backed Map Local (ADR-Streaming-Source-Redirect-To-Fixture.md)

    private func makeFixtureRunRule(
        host: String = "cdn.example.com",
        path: String = "/videos/bipbop",
        matchMode: ResponseOverrideMatchMode = .pathPrefix,
        fixtureRunID: UUID? = UUID()
    ) -> ResponseOverrideRule {
        ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: host,
            port: nil,
            path: path,
            matchMode: matchMode,
            sourceKind: .fixtureRun,
            sourceDescription: "test fixture redirect",
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            fixtureRunID: fixtureRunID
        )
    }

    /// New-behavior test: a real external host+path matched against a `.fixtureRun` rule resolves
    /// to `.fixtureRedirect` with the matcher's path prefix stripped from the real request path —
    /// exactly the relative path `HLSFixtureServer.response(forPath:)` expects.
    func testFixtureRunDecisionReturnsFixtureRedirectWithStrippedRelativePath() async throws {
        let store = ResponseOverrideStore()
        let runID = UUID()
        try await store.addRule(makeFixtureRunRule(fixtureRunID: runID))

        let request = makeRequest(host: "cdn.example.com", path: "/videos/bipbop/master.m3u8")
        let decision = try await store.ruleDecision(for: request)
        guard case .fixtureRedirect(_, let decisionRunID, let relativePath) = decision else {
            XCTFail("Expected .fixtureRedirect, got \(decision)")
            return
        }
        XCTAssertEqual(decisionRunID, runID)
        XCTAssertEqual(relativePath, "master.m3u8")
    }

    /// A request landing exactly on the matcher's path prefix (no trailing segment) strips down to
    /// an empty relative path — `HLSFixtureServer` treats that as a miss, matching how the reserved-
    /// host dispatch path already behaves for the same edge case.
    func testFixtureRunDecisionStripsToEmptyRelativePathAtExactPrefix() async throws {
        let store = ResponseOverrideStore()
        try await store.addRule(makeFixtureRunRule(path: "/videos/bipbop"))

        let request = makeRequest(host: "cdn.example.com", path: "/videos/bipbop")
        let decision = try await store.ruleDecision(for: request)
        guard case .fixtureRedirect(_, _, let relativePath) = decision else {
            XCTFail("Expected .fixtureRedirect, got \(decision)")
            return
        }
        XCTAssertEqual(relativePath, "")
    }

    /// Defensive fail-open: a persisted `.fixtureRun` rule missing its `fixtureRunID` (should never
    /// happen via the MCP creation path, but persistence is hand-editable/forward-compatible) must
    /// behave as `.noMatch`, not crash or serve a nonsensical redirect.
    func testFixtureRunRuleWithoutFixtureRunIDFailsOpenToNoMatch() async throws {
        let store = ResponseOverrideStore()
        try await store.addRule(makeFixtureRunRule(fixtureRunID: nil))

        let request = makeRequest(host: "cdn.example.com", path: "/videos/bipbop/master.m3u8")
        let decision = try await store.ruleDecision(for: request)
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch, got \(decision)")
            return
        }
    }

    /// Defensive fail-open: `.fixtureRun` only supports `matchMode: pathPrefix` (validated at
    /// creation time by `MCPMutationValidator`/`proposeCreateFixtureRunMapLocal`), but a hand-edited
    /// persisted rule with a different matchMode must still fail open rather than dispatch
    /// incorrectly.
    func testFixtureRunRuleWithNonPathPrefixMatchModeFailsOpenToNoMatch() async throws {
        let store = ResponseOverrideStore()
        try await store.addRule(makeFixtureRunRule(path: "/videos/bipbop/master.m3u8", matchMode: .exactPath))

        let request = makeRequest(host: "cdn.example.com", path: "/videos/bipbop/master.m3u8")
        let decision = try await store.ruleDecision(for: request)
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch, got \(decision)")
            return
        }
    }

    // MARK: - Local Directory Map Local (AS / ADR-Map-Local-Directory-Mocking.md)

    private func makeTempDirectoryTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDirectoryRule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("two".utf8).write(to: root.appendingPathComponent("b.txt"))
        return root
    }

    /// Path-prefix strip yields distinct relative paths for sibling URLs under the same folder rule.
    func testLocalDirectoryDecisionStripsPrefixForSubtreeCardinality() async throws {
        let store = ResponseOverrideStore()
        let directory = try makeTempDirectoryTree()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.addDirectoryBackedOverride(
            method: "GET",
            scheme: .https,
            host: "www.example.com",
            port: nil,
            path: "/static",
            label: "site",
            directoryURL: directory
        )

        let decisionA = try await store.ruleDecision(for: makeRequest(host: "www.example.com", path: "/static/a.txt"))
        let decisionB = try await store.ruleDecision(for: makeRequest(host: "www.example.com", path: "/static/b.txt"))
        guard case .localDirectoryRedirect(_, let relativeA) = decisionA else {
            XCTFail("Expected .localDirectoryRedirect for a.txt, got \(decisionA)")
            return
        }
        guard case .localDirectoryRedirect(_, let relativeB) = decisionB else {
            XCTFail("Expected .localDirectoryRedirect for b.txt, got \(decisionB)")
            return
        }
        XCTAssertEqual(relativeA, "a.txt")
        XCTAssertEqual(relativeB, "b.txt")
        XCTAssertNotEqual(relativeA, relativeB)
    }

    /// Non-pathPrefix or non-directory body must fail open at decision time (no crash, no redirect).
    func testLocalDirectoryRuleWithNonPathPrefixMatchModeFailsOpenToNoMatch() async throws {
        let store = ResponseOverrideStore()
        let directory = try makeTempDirectoryTree()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.addRule(
            ResponseOverrideRule(
                requestMethod: "GET",
                requestScheme: .https,
                host: "www.example.com",
                port: nil,
                path: "/static/a.txt",
                matchMode: .exactPath,
                sourceKind: .localDirectory,
                sourceDescription: "bad mode",
                statusCode: 200,
                headers: [],
                bodySource: .directory(directory)
            )
        )
        let decision = try await store.ruleDecision(for: makeRequest(host: "www.example.com", path: "/static/a.txt"))
        guard case .noMatch = decision else {
            XCTFail("Expected .noMatch, got \(decision)")
            return
        }
    }

    /// P1 (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): a directory rule
    /// defaults to `.strictLocal` (today's original, only-ever behavior) unless a policy is
    /// explicitly requested.
    func testDirectoryBackedOverrideDefaultsToStrictLocalMissingFilePolicy() async throws {
        let store = ResponseOverrideStore()
        let directory = try makeTempDirectoryTree()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rule = try await store.addDirectoryBackedOverride(
            method: "GET",
            scheme: .https,
            host: "www.example.com",
            port: nil,
            path: "/static",
            label: "site",
            directoryURL: directory
        )
        XCTAssertEqual(rule.missingFilePolicy, .strictLocal)
    }

    func testDirectoryBackedOverrideCanRequestOverlayFailOpenPolicy() async throws {
        let store = ResponseOverrideStore()
        let directory = try makeTempDirectoryTree()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rule = try await store.addDirectoryBackedOverride(
            method: "GET",
            scheme: .https,
            host: "www.example.com",
            port: nil,
            path: "/static",
            label: "site",
            directoryURL: directory,
            missingFilePolicy: .overlayFailOpen
        )
        XCTAssertEqual(rule.missingFilePolicy, .overlayFailOpen)
    }

    /// `missingFilePolicy` must survive a persist/reload round trip — old persisted rules with no
    /// stored value must silently decode as `.strictLocal`, not fail to decode.
    func testMissingFilePolicySurvivesPersistenceRoundTrip() async throws {
        let store = ResponseOverrideStore()
        let directory = try makeTempDirectoryTree()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.addDirectoryBackedOverride(
            method: "GET",
            scheme: .https,
            host: "www.example.com",
            port: nil,
            path: "/static",
            label: "site",
            directoryURL: directory,
            notFoundRelativePath: "404.html",
            missingFilePolicy: .configuredFallback
        )
        let persistedData = try await store.persistedData()

        let restoredStore = ResponseOverrideStore()
        try await restoredStore.loadPersistedData(persistedData)
        let restoredRules = await restoredStore.rules()
        let restored = try XCTUnwrap(restoredRules.first)
        XCTAssertEqual(restored.missingFilePolicy, .configuredFallback)
        XCTAssertEqual(restored.notFoundRelativePath, "404.html")
    }

    // MARK: - changes stream (ProxyViewModel UI sync)

    /// `ProxyViewModel` observes `changes` for the app's lifetime to keep the "Local Overrides" UI
    /// in sync — including mutations made via MCP, which never call `ProxyViewModel`'s own
    /// `refreshResponseOverrides()`. Regression coverage for a live-confirmed bug (2026-08-10) where
    /// MCP-created/enabled rules never appeared in the app UI at all.
    func testChangesStreamFiresOnAddRule() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()

        try await store.addRule(makeInlineRule(for: request))

        var iterator = store.changes.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertNotNil(event, "Expected a change event to be buffered after addRule")
    }

    func testChangesStreamFiresOnSetEnabled() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        try await store.addRule(makeInlineRule(for: request))
        let rules = await store.rules()
        let ruleID = try XCTUnwrap(rules.first?.id)

        // Drain the addRule event first so this test isolates setEnabled specifically.
        var iterator = store.changes.makeAsyncIterator()
        _ = await iterator.next()

        try await store.setEnabled(false, for: ruleID)
        let event = await iterator.next()
        XCTAssertNotNil(event, "Expected a change event to be buffered after setEnabled")
    }

    func testChangesStreamFiresOnRemoveRule() async throws {
        let store = ResponseOverrideStore()
        let request = makeRequest()
        try await store.addRule(makeInlineRule(for: request))
        let rules = await store.rules()
        let ruleID = try XCTUnwrap(rules.first?.id)

        var iterator = store.changes.makeAsyncIterator()
        _ = await iterator.next()

        await store.removeRule(id: ruleID)
        let event = await iterator.next()
        XCTAssertNotNil(event, "Expected a change event to be buffered after removeRule")
    }
}
