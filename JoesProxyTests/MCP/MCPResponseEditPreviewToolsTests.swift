import XCTest
@testable import JoesProxy

final class ResponseEditSelectorResolverTests: XCTestCase {
    func testExactTextReplaceRequiresExpectedOccurrenceCount() throws {
        let original = Data("Showblender LLC and Showblender LLC".utf8)
        XCTAssertThrowsError(
            try ResponseEditSelectorResolver.resolveExactText(
                originalBytes: original,
                find: Data("Showblender LLC".utf8),
                expectedOccurrences: 1,
                operation: .replace,
                replacement: Data("NOBLENDER LLC".utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? ResponseEditSelectorResolver.SelectorError,
                .occurrenceMismatch(expected: 1, actual: 2)
            )
        }

        let patches = try ResponseEditSelectorResolver.resolveExactText(
            originalBytes: original,
            find: Data("Showblender LLC".utf8),
            expectedOccurrences: 2,
            operation: .replace,
            replacement: Data("NOBLENDER LLC".utf8)
        )
        let result = try BoundedBytePatchEngine.apply(originalBytes: original, patches: patches)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "NOBLENDER LLC and NOBLENDER LLC")
    }

    func testMatchRefCanTargetOneOfDuplicateLiterals() throws {
        let original = Data("aaa Showblender LLC bbb Showblender LLC ccc".utf8)
        let find = Data("Showblender LLC".utf8)
        let first = original.range(of: find)!
        let patches = try ResponseEditSelectorResolver.resolveMatchRefs(
            originalBytes: original,
            ranges: [first],
            operation: .replace,
            replacement: Data("NOBLENDER LLC".utf8)
        )
        let result = try BoundedBytePatchEngine.apply(originalBytes: original, patches: patches)
        XCTAssertEqual(
            String(decoding: result.data, as: UTF8.self),
            "aaa NOBLENDER LLC bbb Showblender LLC ccc"
        )
    }
}

@MainActor
final class MCPResponseEditPreviewToolsTests: XCTestCase {
    func testPreviewResponseEditExactTextAndMapLocalBinding() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let policyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-policy.json")
        let policyStore = MCPPolicyStore(persistenceURL: policyURL)
        policyStore.load()
        let journalStore = MCPEffectJournalStore(
            persistenceURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-journal.json")
        )
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let approvalStore = MCPApprovalStore()
        let auditStore = MCPAuditStore(
            persistenceURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-audit.json")
        )
        auditStore.load()
        let responseOverrideStore = ResponseOverrideStore()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { policyStore.policyRevision }
        )
        let grantStore = MCPClientGrantStore()
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
            responseEditService: responseEditService
        )
        let client = MCPClientRecord(
            id: "client-response-preview",
            displayName: "response-preview",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        let body = Data("<h1>Showblender LLC</h1>".utf8)
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "showblender.example",
                port: 443,
                path: "/",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "text/html")],
                bodyData: body,
                bodySize: body.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
        sessionStore.append(session)

        let preview = try await mutationService.handleTool(
            name: "preview_response_edit",
            arguments: [
                "sessionID": session.id.uuidString,
                "edits": [[
                    "selector": [
                        "kind": "exactText",
                        "find": "Showblender LLC",
                        "expectedOccurrences": 1
                    ],
                    "operation": [
                        "kind": "replace",
                        "text": "NOBLENDER LLC"
                    ]
                ]],
                "__mcpInternalSessionID": "mcp-preview"
            ],
            client: client
        )
        let digest = try XCTUnwrap(preview["responseEditPreviewDigest"] as? String)
        XCTAssertTrue(digest.hasPrefix("response-edit-preview-"))
        XCTAssertEqual(preview["contentTrust"] as? String, "metadata_only")
        XCTAssertNotNil(preview["responseHeaderPlan"] as? [String: Any])
        XCTAssertFalse(String(describing: preview).contains("NOBLENDER LLC"))

        let proposal = try await mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: [
                "responseEditPreviewDigest": digest,
                "__mcpInternalSessionID": "mcp-preview"
            ],
            client: client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)

        do {
            _ = try await mutationService.handleTool(
                name: "apply_create_map_local",
                arguments: ["proposalToken": token],
                client: client
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try approvalStore.approve(requestID: requestID)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(authorization)
            let approval = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            _ = try await mutationService.handleTool(
                name: "apply_create_map_local",
                arguments: ["proposalToken": token, "approval": approval],
                client: client
            )
        }

        let rules = await responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first)
        guard case .inline(let stored) = rule.bodySource else {
            return XCTFail("expected inline body")
        }
        XCTAssertEqual(String(decoding: stored ?? Data(), as: UTF8.self), "<h1>NOBLENDER LLC</h1>")
        XCTAssertEqual(rule.statusCode, 200)
        XCTAssertTrue(rule.headers.contains(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
                && $0.value.lowercased().contains("charset=utf-8")
        }))
    }

    func testHeaderPolicyStripsEncodingAndOmitsSetCookie() {
        let plan = ResponseHeaderPolicyPlan.planForEditedDecodedBody(
            statusCode: 200,
            contentType: "text/html",
            capturedHeaders: [
                HTTPHeaderField(name: "Content-Type", value: "text/html"),
                HTTPHeaderField(name: "Content-Encoding", value: "gzip"),
                HTTPHeaderField(name: "ETag", value: "abc"),
                HTTPHeaderField(name: "Set-Cookie", value: "a=b"),
                HTTPHeaderField(name: "Transfer-Encoding", value: "chunked")
            ]
        )
        XCTAssertEqual(plan.contentType, "text/html; charset=utf-8")
        XCTAssertTrue(plan.removedHeaderNames.contains("Content-Encoding"))
        XCTAssertTrue(plan.removedHeaderNames.contains("ETag"))
        XCTAssertTrue(plan.omittedByDefaultHeaderNames.contains("Set-Cookie"))
        XCTAssertEqual(plan.recomputedHeaderNames, ["Content-Length", "Connection"])
        XCTAssertEqual(plan.persistenceHeaders.count, 1)
    }
}
