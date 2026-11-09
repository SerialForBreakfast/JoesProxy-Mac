import XCTest
@testable import JoesProxy

final class MCPTargetRevisionFingerprintTests: XCTestCase {
    func testBookmarkRevisionIgnoresCosmeticNameChange() {
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v1/items",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        var first = Bookmark(id: UUID(), name: "Alpha", request: request)
        var second = Bookmark(id: first.id, name: "Beta", request: request)
        XCTAssertEqual(
            MCPTargetRevisionFingerprint.semanticPayload(for: first),
            MCPTargetRevisionFingerprint.semanticPayload(for: second)
        )
        first = MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(first)
        second = MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(second)
        XCTAssertEqual(first.mcpTargetRevision, second.mcpTargetRevision)
    }

    func testBookmarkRevisionBumpsOnSemanticPathChange() {
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v1/items",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        var first = MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(
            Bookmark(id: UUID(), name: "Same", request: request)
        )
        let changedRequest = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v2/items",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        var second = MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(
            Bookmark(id: first.id, name: "Same", request: changedRequest)
        )
        XCTAssertNotEqual(first.mcpTargetRevision, second.mcpTargetRevision)
    }

    func testResponseOverrideRevisionBumpsWhenEnabledChanges() {
        var disabledRule = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/blocked",
            sourceKind: .block,
            sourceDescription: "Blocked",
            statusCode: 403,
            headers: [],
            bodySource: .inline(Data()),
            isEnabled: false
        )
        var enabledRule = disabledRule
        enabledRule.isEnabled = true
        disabledRule = MCPTargetRevisionFingerprint.ruleByApplyingRevision(disabledRule)
        enabledRule = MCPTargetRevisionFingerprint.ruleByApplyingRevision(enabledRule)
        XCTAssertNotEqual(disabledRule.mcpTargetRevision, enabledRule.mcpTargetRevision)
    }

    // MARK: - mapRemotePath / mapRemoteQueryPolicy / mapRemoteQuery fingerprint coverage
    //
    // Direct inequality tests per review: construct two semantic payloads differing by exactly
    // one new field and assert their target revisions differ — rather than the break-then-restore
    // procedure used earlier in this session, which only proves a field affects SOME behavior, not
    // specifically that it participates in the revision hash.

    private func makeMapRemoteRule(
        remotePath: String? = nil,
        remoteQueryPolicy: MapRemoteQueryPolicy = .preserve,
        remoteQuery: String? = nil
    ) -> ResponseOverrideRule {
        ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/proxy",
            sourceKind: .mapRemote,
            sourceDescription: "Remapped to remote host",
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            isEnabled: false,
            mapRemoteHost: "staging.example.com",
            mapRemotePort: 443,
            mapRemoteScheme: .https,
            mapRemotePath: remotePath,
            mapRemoteQueryPolicy: remoteQueryPolicy,
            mapRemoteQuery: remoteQuery
        )
    }

    func testMapRemoteRevisionBumpsWhenPathOverrideAdded() {
        let withoutPath = MCPTargetRevisionFingerprint.ruleByApplyingRevision(makeMapRemoteRule())
        let withPath = MCPTargetRevisionFingerprint.ruleByApplyingRevision(makeMapRemoteRule(remotePath: "/v2/proxy"))
        XCTAssertNotEqual(withoutPath.mcpTargetRevision, withPath.mcpTargetRevision)
    }

    func testMapRemoteRevisionBumpsWhenPathOverrideValueChanges() {
        let first = MCPTargetRevisionFingerprint.ruleByApplyingRevision(makeMapRemoteRule(remotePath: "/v2/proxy"))
        let second = MCPTargetRevisionFingerprint.ruleByApplyingRevision(makeMapRemoteRule(remotePath: "/v3/proxy"))
        XCTAssertNotEqual(first.mcpTargetRevision, second.mcpTargetRevision)
    }

    func testMapRemoteRevisionBumpsWhenQueryPolicyChanges() {
        let preserve = MCPTargetRevisionFingerprint.ruleByApplyingRevision(
            makeMapRemoteRule(remotePath: "/v2/proxy", remoteQueryPolicy: .preserve)
        )
        let drop = MCPTargetRevisionFingerprint.ruleByApplyingRevision(
            makeMapRemoteRule(remotePath: "/v2/proxy", remoteQueryPolicy: .drop)
        )
        XCTAssertNotEqual(preserve.mcpTargetRevision, drop.mcpTargetRevision)
    }

    func testMapRemoteRevisionBumpsWhenReplacementQueryChanges() {
        let first = MCPTargetRevisionFingerprint.ruleByApplyingRevision(
            makeMapRemoteRule(remotePath: "/v2/proxy", remoteQueryPolicy: .replace, remoteQuery: "a=1")
        )
        let second = MCPTargetRevisionFingerprint.ruleByApplyingRevision(
            makeMapRemoteRule(remotePath: "/v2/proxy", remoteQueryPolicy: .replace, remoteQuery: "a=2")
        )
        XCTAssertNotEqual(first.mcpTargetRevision, second.mcpTargetRevision)
    }

    private func makeLiveResponseRewriteRule(
        jsonPath: String,
        operation: JSONMutationOperation,
        repeatPolicy: JSONMutationRepeatPolicy? = nil
    ) -> ResponseOverrideRule {
        ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/data",
            sourceKind: .liveResponseRewrite,
            sourceDescription: "Live response rewrite",
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            liveResponseRewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: jsonPath,
                    overrideValue: .bool(true),
                    operation: operation,
                    repeatPolicy: repeatPolicy
                )
            ]
        )
    }

    func testLiveResponseRewriteRevisionBumpsWhenRepeatPolicyChanges() {
        let alwaysRule = MCPTargetRevisionFingerprint.ruleByApplyingRevision(
            makeLiveResponseRewriteRule(jsonPath: "title", operation: .appendString, repeatPolicy: .always)
        )
        let ifMissingSuffixRule = MCPTargetRevisionFingerprint.ruleByApplyingRevision(
            makeLiveResponseRewriteRule(jsonPath: "title", operation: .appendString, repeatPolicy: .ifMissingSuffix)
        )
        XCTAssertNotEqual(alwaysRule.mcpTargetRevision, ifMissingSuffixRule.mcpTargetRevision)
    }

    func testLiveResponseRewriteRevisionBumpsWhenExpectedSchemaFingerprintChanges() {
        var withoutFingerprint = makeLiveResponseRewriteRule(jsonPath: "title", operation: .appendString)
        withoutFingerprint.expectedSchemaFingerprint = nil
        var withFingerprint = withoutFingerprint
        withFingerprint.expectedSchemaFingerprint = JSONStructuralProfiler.profile(
            bodyData: Data(#"{"title":"x"}"#.utf8)
        ).schemaFingerprint

        let first = MCPTargetRevisionFingerprint.ruleByApplyingRevision(withoutFingerprint)
        let second = MCPTargetRevisionFingerprint.ruleByApplyingRevision(withFingerprint)
        XCTAssertNotEqual(first.mcpTargetRevision, second.mcpTargetRevision)
    }

    func testLiveResponseRewriteRevisionBumpsWhenLocatorChanges() {
        let first = MCPTargetRevisionFingerprint.ruleByApplyingRevision(
            makeLiveResponseRewriteRule(jsonPath: "flag", operation: .set)
        )
        let second = MCPTargetRevisionFingerprint.ruleByApplyingRevision(
            makeLiveResponseRewriteRule(jsonPath: "other", operation: .set)
        )
        XCTAssertNotEqual(first.mcpTargetRevision, second.mcpTargetRevision)
    }

    func testLiveResponseRewriteRevisionBumpsWhenOperationChanges() {
        let setRule = MCPTargetRevisionFingerprint.ruleByApplyingRevision(
            makeLiveResponseRewriteRule(jsonPath: "flag", operation: .set)
        )
        let insertRule = MCPTargetRevisionFingerprint.ruleByApplyingRevision(
            makeLiveResponseRewriteRule(jsonPath: "flag", operation: .insert)
        )
        XCTAssertNotEqual(setRule.mcpTargetRevision, insertRule.mcpTargetRevision)
    }
}
