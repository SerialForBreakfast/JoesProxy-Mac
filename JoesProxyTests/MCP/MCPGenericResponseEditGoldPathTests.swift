import CryptoKit
import XCTest
@testable import JoesProxy

/// G5-04 gold-standard paths: HTML branding replacement and HLS CODECS edit must share the
/// same preview→Map Local→enable→hit→disable lifecycle (different preview tools, one Map Local path).
@MainActor
final class MCPGenericResponseEditGoldPathTests: XCTestCase {
    private struct Stack {
        let sessionStore: InMemorySessionStore
        let snapshotService: MCPSessionSnapshotService
        let responseEditService: MCPResponseEditService
        let mutationService: MCPMutationService
        let responseOverrideStore: ResponseOverrideStore
        let approvalStore: MCPApprovalStore
        let draftStore: ResponseDraftStore
        let client: MCPClientRecord
    }

    private enum PreviewBinding {
        case responseEdit(String)
        case hlsCodecs(String)
    }

    func testHTMLShowblenderToNOBLENDERGoldPath() async throws {
        let stack = try makeStack()
        let original = Data("<html><title>Showblender LLC</title></html>".utf8)
        let expected = Data("<html><title>NOBLENDER LLC</title></html>".utf8)
        let session = makeSession(
            host: "showblender.example",
            path: "/brand.html",
            contentType: "text/html; charset=utf-8",
            body: original
        )
        stack.sessionStore.append(session)

        let context = try stack.responseEditService.responseContext(
            sessionID: session.id,
            client: stack.client
        )
        XCTAssertTrue(context.isUTF8TextEditable)
        XCTAssertEqual(context.completeness, "complete")
        XCTAssertEqual(context.contentTrust, "metadata_only")
        XCTAssertEqual(context.bodySHA256, sha256Hex(original))

        let preview = try await stack.mutationService.handleTool(
            name: "preview_response_edit",
            arguments: [
                "sessionID": session.id.uuidString,
                "edits": [[
                    "selector": [
                        "kind": "exactText",
                        "find": "Showblender LLC",
                        "expectedOccurrences": 1
                    ],
                    "operation": ["kind": "replace", "text": "NOBLENDER LLC"]
                ]],
                "__mcpInternalSessionID": "gold-html"
            ],
            client: stack.client
        )
        let digest = try XCTUnwrap(preview["responseEditPreviewDigest"] as? String)
        XCTAssertTrue(digest.hasPrefix("response-edit-preview-"))
        XCTAssertEqual(preview["contentTrust"] as? String, "metadata_only")
        XCTAssertFalse(String(describing: preview).contains("NOBLENDER LLC"))

        try await assertMapLocalLifecycle(
            stack: stack,
            binding: .responseEdit(digest),
            mcpSessionID: "gold-html",
            request: session.request,
            expectedBody: expected,
            expectedBodySHA256: sha256Hex(expected)
        )
    }

    /// GraphQL operation-name scoping is only wired into the direct-argument (plain bodyText/
    /// fixtureRunID/localDirectoryBookmarkRef) paths of `propose_create_map_local` — the
    /// preview/revision-derived paths inherit their matcher from an earlier tool call and cannot
    /// pick up a fresh `graphqlOperationName`. Passing both must fail loudly, not silently ignore
    /// the argument.
    func testProposeCreateMapLocalRejectsGraphQLOperationNameWithPreviewDigest() async throws {
        let stack = try makeStack()
        let session = makeSession(
            host: "showblender.example",
            path: "/brand.html",
            contentType: "text/html; charset=utf-8",
            body: Data("<html><title>Showblender LLC</title></html>".utf8)
        )
        stack.sessionStore.append(session)

        let preview = try await stack.mutationService.handleTool(
            name: "preview_response_edit",
            arguments: [
                "sessionID": session.id.uuidString,
                "edits": [[
                    "selector": [
                        "kind": "exactText",
                        "find": "Showblender LLC",
                        "expectedOccurrences": 1
                    ],
                    "operation": ["kind": "replace", "text": "NOBLENDER LLC"]
                ]]
            ],
            client: stack.client
        )
        let digest = try XCTUnwrap(preview["responseEditPreviewDigest"] as? String)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "responseEditPreviewDigest": digest,
                    "graphqlOperationName": "GetUser"
                ],
                client: stack.client
            )
            XCTFail("expected graphqlOperationName + responseEditPreviewDigest to be rejected")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("graphqlOperationName"))
        }
    }

    /// Same rationale as the GraphQL test above, for the query-parameter predicate
    /// (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): `matchQueryKey`/
    /// `matchQueryValue` cannot be combined with a preview-digest-derived Map Local either.
    func testProposeCreateMapLocalRejectsMatchQueryPredicateWithPreviewDigest() async throws {
        let stack = try makeStack()
        let session = makeSession(
            host: "showblender.example",
            path: "/brand.html",
            contentType: "text/html; charset=utf-8",
            body: Data("<html><title>Showblender LLC</title></html>".utf8)
        )
        stack.sessionStore.append(session)

        let preview = try await stack.mutationService.handleTool(
            name: "preview_response_edit",
            arguments: [
                "sessionID": session.id.uuidString,
                "edits": [[
                    "selector": [
                        "kind": "exactText",
                        "find": "Showblender LLC",
                        "expectedOccurrences": 1
                    ],
                    "operation": ["kind": "replace", "text": "NOBLENDER LLC"]
                ]]
            ],
            client: stack.client
        )
        let digest = try XCTUnwrap(preview["responseEditPreviewDigest"] as? String)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "responseEditPreviewDigest": digest,
                    "matchQueryKey": "contentId",
                    "matchQueryValue": "1234"
                ],
                client: stack.client
            )
            XCTFail("expected matchQueryKey + responseEditPreviewDigest to be rejected")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("matchQueryKey"))
        }
    }

    func testHLSCODECSGoldPathSharesMapLocalLifecycle() async throws {
        let stack = try makeStack()
        let original = hlsMasterBody()
        let session = makeSession(
            host: "cdn.example.com",
            path: "/master.m3u8?sid=secret",
            contentType: "application/vnd.apple.mpegurl",
            body: original
        )
        stack.sessionStore.append(session)

        let context = try stack.responseEditService.responseContext(
            sessionID: session.id,
            client: stack.client
        )
        XCTAssertTrue(context.isUTF8TextEditable)
        XCTAssertEqual(context.completeness, "complete")
        XCTAssertFalse(try XCTUnwrap(context.bodySHA256).isEmpty)

        let inspection = MCPMediaInspectionService(
            sessionStore: stack.sessionStore,
            snapshotService: stack.snapshotService
        )
        let structure = try inspection.manifestStructure(
            sessionID: session.id,
            policyRevision: .initial
        )
        let variantRef = try XCTUnwrap(structure.hlsVariants.first?.variantRef)

        let preview = try await stack.mutationService.handleTool(
            name: "preview_hls_codecs_edit",
            arguments: [
                "sessionID": session.id.uuidString,
                "edits": [["variantRef": variantRef, "codecs": "avc1.640028,mp4a.40.2"]],
                "matchMode": "ignoreQuery",
                "__mcpInternalSessionID": "gold-hls"
            ],
            client: stack.client
        )
        let digest = try XCTUnwrap(preview["previewDigest"] as? String ?? preview["hlsPreviewDigest"] as? String)
        XCTAssertEqual(preview["codecValueProvenance"] as? String, "user_supplied")
        XCTAssertFalse(String(describing: preview).contains("secret"))

        let locator = try XCTUnwrap(HLSCODECSEditTransformer.variantLocators(in: original).first)
        let expected = try HLSCODECSEditTransformer.apply(
            originalBytes: original,
            edits: [HLSCODECSVariantEdit(locator: locator, codecs: "avc1.640028,mp4a.40.2")]
        ).data

        try await assertMapLocalLifecycle(
            stack: stack,
            binding: .hlsCodecs(digest),
            mcpSessionID: "gold-hls",
            request: session.request,
            expectedBody: expected,
            expectedBodySHA256: sha256Hex(expected)
        )
    }

    func testHTMLDraftCommitThenMapLocalFromRevisionGoldPath() async throws {
        let stack = try makeStack()
        let original = Data("Showblender LLC page".utf8)
        let expected = Data("NOBLENDER LLC page".utf8)
        let session = makeSession(
            host: "showblender.example",
            path: "/page",
            contentType: "text/html",
            body: original
        )
        stack.sessionStore.append(session)

        let createProposal = try await stack.mutationService.handleTool(
            name: "propose_create_response_draft",
            arguments: ["sessionID": session.id.uuidString, "label": "gold-html-draft"],
            client: stack.client
        )
        let createToken = try XCTUnwrap(createProposal["proposalToken"] as? String)
        let created = try await applyApproved(
            stack: stack,
            tool: "apply_create_response_draft",
            proposalToken: createToken
        )
        let draftID = try XCTUnwrap(created["targetID"] as? String)

        let preview = try await stack.mutationService.handleTool(
            name: "preview_response_edit",
            arguments: [
                "sessionID": session.id.uuidString,
                "edits": [[
                    "selector": [
                        "kind": "exactText",
                        "find": "Showblender LLC",
                        "expectedOccurrences": 1
                    ],
                    "operation": ["kind": "replace", "text": "NOBLENDER LLC"]
                ]],
                "__mcpInternalSessionID": "gold-draft"
            ],
            client: stack.client
        )
        let digest = try XCTUnwrap(preview["responseEditPreviewDigest"] as? String)

        let commitProposal = try await stack.mutationService.handleTool(
            name: "propose_commit_response_edit",
            arguments: [
                "draftID": draftID,
                "responseEditPreviewDigest": digest,
                "__mcpInternalSessionID": "gold-draft"
            ],
            client: stack.client
        )
        let commitToken = try XCTUnwrap(commitProposal["proposalToken"] as? String)
        let committed = try await applyApproved(
            stack: stack,
            tool: "apply_commit_response_edit",
            proposalToken: commitToken
        )
        let revisionID = try XCTUnwrap(committed["currentRevisionID"] as? String)

        let mapProposal = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: ["responseRevisionID": revisionID],
            client: stack.client
        )
        let mapToken = try XCTUnwrap(mapProposal["proposalToken"] as? String)
        let mapped = try await applyApproved(
            stack: stack,
            tool: "apply_create_map_local",
            proposalToken: mapToken
        )
        let overrideID = try XCTUnwrap(mapped["targetID"] as? String)

        _ = try await enableRule(stack: stack, overrideID: overrideID)
        let hit = try await stack.responseOverrideStore.ruleDecision(for: session.request)
        guard case .mapLocal(let resolved) = hit else {
            return XCTFail("Expected Map Local hit after enable, got \(hit)")
        }
        XCTAssertEqual(resolved.bodyData, expected)
        XCTAssertEqual(sha256Hex(resolved.bodyData ?? Data()), sha256Hex(expected))

        let rulesAfterHit = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rulesAfterHit.first { $0.id.uuidString == overrideID }?.hitCount, 1)

        _ = try await disableRule(stack: stack, overrideID: overrideID)
        let miss = try await stack.responseOverrideStore.ruleDecision(for: session.request)
        if case .noMatch = miss {
            // expected
        } else {
            XCTFail("Disabled rule must not match, got \(miss)")
        }
    }

    // MARK: - Shared lifecycle

    func testMissingPreviewIdentifiesTheCorrectRecoveryToolWithoutEchoingDigest() throws {
        let stack = try makeStack()
        for (key, tool) in [("responseEditPreviewDigest", "preview_response_edit"),
                            ("hlsPreviewDigest", "preview_hls_codecs_edit")] {
            XCTAssertThrowsError(try stack.mutationService.resolvedResponseEditPreviewIfRequested(
                arguments: [key: "synthetic-private-digest"], client: stack.client)) { error in
                guard let structured = error as? MCPStructuredError else { return XCTFail("Expected structured error") }
                XCTAssertEqual(structured.code, .staleProposal)
                XCTAssertEqual(structured.details?["nextTool"], tool)
                XCTAssertTrue(structured.message.contains("review the result"))
                XCTAssertTrue(structured.message.contains("Reconnecting does not refresh"))
                XCTAssertFalse(structured.message.contains("synthetic-private-digest"))
            }
        }
    }

    func testPreviewMatcherEchoAllowsReviewedClientScopeButRejectsChangedPath() async throws {
        let stack = try makeStack()
        let session = makeSession(host: "api.example.com", path: "/listing.json",
                                  contentType: "application/json", body: Data("{\"title\":\"Before\"}".utf8))
        stack.sessionStore.append(session)
        let preview = try await stack.mutationService.handleTool(
            name: "preview_response_edit",
            arguments: ["sessionID": session.id.uuidString,
                        "edits": [["selector": ["kind": "exactText", "find": "Before", "expectedOccurrences": 1],
                                   "operation": ["kind": "replace", "text": "After"]]],
                        "__mcpInternalSessionID": "scoped-preview"], client: stack.client)
        let digest = try XCTUnwrap(preview["responseEditPreviewDigest"] as? String)
        var arguments: [String: Any] = [
            "responseEditPreviewDigest": digest, "__mcpInternalSessionID": "scoped-preview",
            "method": "GET", "scheme": "https", "host": "api.example.com", "port": 443,
            "path": "/wrong.json", "matchMode": "ignoreQuery",
            "sourceClientAddress": "192.0.2.10", "forceNoCache": true
        ]
        do {
            _ = try await stack.mutationService.handleTool(name: "propose_create_map_local",
                                                          arguments: arguments, client: stack.client)
            XCTFail("A client restriction must not permit a changed request path")
        } catch {
            XCTAssertTrue(String(describing: error).contains("matcher differs"))
            XCTAssertEqual((error as? MCPStructuredError)?.details?["reason"], "preview_matcher_mismatch")
            XCTAssertTrue((error as? MCPStructuredError)?.message.contains("Omit the repeated request matcher") == true)
        }
        arguments["path"] = "/listing.json"
        let proposal = try await stack.mutationService.handleTool(name: "propose_create_map_local",
                                                                 arguments: arguments, client: stack.client)
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await applyApproved(stack: stack, tool: "apply_create_map_local", proposalToken: token)
        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.sourceClientAddress, "192.0.2.10")
        XCTAssertTrue(rule.forceNoCache)
        XCTAssertFalse(rule.isEnabled)
    }

    private func assertMapLocalLifecycle(
        stack: Stack,
        binding: PreviewBinding,
        mcpSessionID: String,
        request: CapturedRequest,
        expectedBody: Data,
        expectedBodySHA256: String
    ) async throws {
        var proposeArgs: [String: Any] = ["__mcpInternalSessionID": mcpSessionID]
        switch binding {
        case .responseEdit(let digest):
            proposeArgs["responseEditPreviewDigest"] = digest
        case .hlsCodecs(let digest):
            proposeArgs["hlsPreviewDigest"] = digest
        }

        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: proposeArgs,
            client: stack.client
        )
        let proposalToken = try XCTUnwrap(proposal["proposalToken"] as? String)
        XCTAssertEqual(proposal["defaultEnabled"] as? Bool, false)

        let applied = try await applyApproved(
            stack: stack,
            tool: "apply_create_map_local",
            proposalToken: proposalToken
        )
        let overrideID = try XCTUnwrap(applied["targetID"] as? String)
        XCTAssertEqual(applied["isEnabled"] as? Bool, false)

        var rules = await stack.responseOverrideStore.rules()
        let disabledRule = try XCTUnwrap(rules.first { $0.id.uuidString == overrideID })
        XCTAssertFalse(disabledRule.isEnabled)
        guard case .inline(let stored) = disabledRule.bodySource else {
            return XCTFail("Map Local must persist inline body bytes")
        }
        XCTAssertEqual(stored, expectedBody)
        XCTAssertEqual(sha256Hex(stored ?? Data()), expectedBodySHA256)

        let disabledDecision = try await stack.responseOverrideStore.ruleDecision(for: request)
        if case .noMatch = disabledDecision {
            // create-disabled: no traffic effect yet
        } else {
            XCTFail("Disabled Map Local must not match traffic, got \(disabledDecision)")
        }

        _ = try await enableRule(stack: stack, overrideID: overrideID)
        let hit = try await stack.responseOverrideStore.ruleDecision(for: request)
        guard case .mapLocal(let resolved) = hit else {
            return XCTFail("Enabled Map Local must match, got \(hit)")
        }
        XCTAssertEqual(resolved.bodyData, expectedBody)
        XCTAssertEqual(sha256Hex(resolved.bodyData ?? Data()), expectedBodySHA256)
        XCTAssertEqual(resolved.ruleID.uuidString, overrideID)

        rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.first { $0.id.uuidString == overrideID }?.hitCount, 1)
        XCTAssertNotNil(rules.first { $0.id.uuidString == overrideID }?.lastMatchedAt)

        _ = try await disableRule(stack: stack, overrideID: overrideID)
        let afterDisable = try await stack.responseOverrideStore.ruleDecision(for: request)
        if case .noMatch = afterDisable {
            // exact cleanup of live effect
        } else {
            XCTFail("Disable must restore no-match, got \(afterDisable)")
        }
    }

    private func enableRule(stack: Stack, overrideID: String) async throws -> [String: Any] {
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: ["overrideID": overrideID],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        return try await applyApproved(stack: stack, tool: "apply_enable_rule", proposalToken: token)
    }

    private func disableRule(stack: Stack, overrideID: String) async throws -> [String: Any] {
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_disable_rule",
            arguments: ["overrideID": overrideID],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        return try await applyApproved(stack: stack, tool: "apply_disable_rule", proposalToken: token)
    }

    private func applyApproved(
        stack: Stack,
        tool: String,
        proposalToken: String
    ) async throws -> [String: Any] {
        do {
            return try await stack.mutationService.handleTool(
                name: tool,
                arguments: ["proposalToken": proposalToken],
                client: stack.client
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(authorization)
            let approval = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try await stack.mutationService.handleTool(
                name: tool,
                arguments: ["proposalToken": proposalToken, "approval": approval],
                client: stack.client
            )
        }
    }

    // MARK: - Fixtures

    private func makeStack() throws -> Stack {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "gold-journal.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "gold-policy.json"))
        policyStore.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "gold-audit.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let responseOverrideStore = ResponseOverrideStore()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { policyStore.policyRevision }
        )
        let grantStore = MCPClientGrantStore()
        let draftStore = ResponseDraftStore(persistenceURL: temporaryURL(named: "gold-drafts.json"))
        draftStore.load()
        let responseEditService = MCPResponseEditService(
            snapshotService: snapshotService,
            policyStore: policyStore,
            grantStore: grantStore
        )
        let mutationService = MCPMutationService(
            bookmarkStore: InMemoryBookmarkStore(),
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            grantStore: grantStore,
            auditStore: auditStore,
            snapshotService: snapshotService,
            responseEditService: responseEditService,
            responseDraftStore: draftStore
        )
        let client = MCPClientRecord(
            id: "client-gold-response-edit",
            displayName: "gold-response-edit",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return Stack(
            sessionStore: sessionStore,
            snapshotService: snapshotService,
            responseEditService: responseEditService,
            mutationService: mutationService,
            responseOverrideStore: responseOverrideStore,
            approvalStore: approvalStore,
            draftStore: draftStore,
            client: client
        )
    }

    private func makeSession(
        host: String,
        path: String,
        contentType: String,
        body: Data
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: host,
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: contentType)],
                bodyData: body,
                bodySize: body.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    private func hlsMasterBody() -> Data {
        Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="mp4a.40.2,avc1.4d401e"
        https://cdn.example.com/low.m3u8?sid=secret
        """.utf8)
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
