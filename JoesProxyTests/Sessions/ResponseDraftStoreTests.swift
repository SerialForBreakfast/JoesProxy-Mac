import XCTest
@testable import JoesProxy

@MainActor
final class ResponseDraftStoreTests: XCTestCase {
    func testCreateCommitPersistAndOwnershipQuotas() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-drafts.json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ResponseDraftStore(persistenceURL: url)
        store.load()
        XCTAssertTrue(store.isLoaded)

        let matcher = MCPMutationMatcher(
            method: "GET",
            scheme: .https,
            host: "example.test",
            port: nil,
            path: "/index.html",
            matchMode: .ignoreQuery
        )
        let body = Data("Showblender LLC".utf8)
        let draft = try store.createDraft(
            clientID: "client-a",
            label: "html",
            sourceSessionID: UUID(),
            sourceCaptureSequence: 7,
            matcher: matcher,
            bodyData: body,
            bodySHA256: "abc",
            statusCode: 200,
            contentType: "text/html"
        )
        XCTAssertEqual(draft.revisions.count, 1)

        let patched = Data("NOBLENDER LLC".utf8)
        let committed = try store.commitRevision(
            draftID: draft.id,
            clientID: "client-a",
            bodyData: patched,
            bodySHA256: "def",
            statusCode: 200,
            contentType: "text/html",
            previewDigest: "response-edit-preview-test"
        )
        XCTAssertEqual(committed.revisions.count, 2)
        XCTAssertEqual(committed.currentRevision?.bodyData, patched)
        XCTAssertNotEqual(committed.originalRevisionID, committed.currentRevisionID)

        XCTAssertThrowsError(
            try store.commitRevision(
                draftID: draft.id,
                clientID: "other",
                bodyData: patched,
                bodySHA256: "def",
                statusCode: 200,
                contentType: "text/html",
                previewDigest: nil
            )
        ) { error in
            XCTAssertEqual(error as? ResponseDraftStoreError, .notOwner)
        }

        let reloaded = ResponseDraftStore(persistenceURL: url)
        reloaded.load()
        XCTAssertEqual(reloaded.draft(id: draft.id)?.revisions.count, 2)
        XCTAssertEqual(reloaded.draft(id: draft.id)?.currentRevision?.bodyData, patched)
    }

    func testDraftCountQuota() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-draft-quota.json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ResponseDraftStore(persistenceURL: url)
        store.load()
        let matcher = MCPMutationMatcher(
            method: "GET",
            scheme: .https,
            host: "example.test",
            port: nil,
            path: "/",
            matchMode: .exactPath
        )
        let body = Data("abc".utf8)
        for _ in 0..<ResponseDraftStore.maxDraftsPerClient {
            _ = try store.createDraft(
                clientID: "quota-client",
                label: nil,
                sourceSessionID: UUID(),
                sourceCaptureSequence: 1,
                matcher: matcher,
                bodyData: body,
                bodySHA256: "x",
                statusCode: 200,
                contentType: "text/plain"
            )
        }
        XCTAssertThrowsError(
            try store.createDraft(
                clientID: "quota-client",
                label: nil,
                sourceSessionID: UUID(),
                sourceCaptureSequence: 1,
                matcher: matcher,
                bodyData: body,
                bodySHA256: "x",
                statusCode: 200,
                contentType: "text/plain"
            )
        ) { error in
            guard case .quotaExceeded = error as? ResponseDraftStoreError else {
                return XCTFail("Expected quotaExceeded")
            }
        }
    }
}

@MainActor
final class MCPResponseDraftToolsTests: XCTestCase {
    private struct Stack {
        let sessionStore: InMemorySessionStore
        let mutationService: MCPMutationService
        let approvalStore: MCPApprovalStore
        let responseOverrideStore: ResponseOverrideStore
        let client: MCPClientRecord
    }

    private func makeStack() throws -> Stack {
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
        let draftStore = ResponseDraftStore(
            persistenceURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-drafts.json")
        )
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
            id: "client-response-draft",
            displayName: "response-draft",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return Stack(
            sessionStore: sessionStore,
            mutationService: mutationService,
            approvalStore: approvalStore,
            responseOverrideStore: responseOverrideStore,
            client: client
        )
    }

    private func seedHTMLSession(into store: InMemorySessionStore) -> SessionRecord {
        let body = Data("<html>Showblender LLC</html>".utf8)
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "showblender.test",
                port: nil,
                path: "/page.html",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "text/html; charset=utf-8")],
                bodyData: body,
                bodySize: body.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
        store.append(session)
        return session
    }

    private func applyWithApproval(
        stack: Stack,
        toolName: String,
        proposalToken: String
    ) async throws -> [String: Any] {
        do {
            return try await stack.mutationService.handleTool(
                name: toolName,
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
                name: toolName,
                arguments: ["proposalToken": proposalToken, "approval": approval],
                client: stack.client
            )
        }
    }

    func testDraftSavePreviewCommitAndMapLocalFromRevision() async throws {
        let stack = try makeStack()
        let session = seedHTMLSession(into: stack.sessionStore)

        let proposeCreate = try await stack.mutationService.handleTool(
            name: "propose_create_response_draft",
            arguments: ["sessionID": session.id.uuidString, "label": "showblender"],
            client: stack.client
        )
        let createToken = try XCTUnwrap(proposeCreate["proposalToken"] as? String)
        let created = try await applyWithApproval(
            stack: stack,
            toolName: "apply_create_response_draft",
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
                    "operation": [
                        "kind": "replace",
                        "text": "NOBLENDER LLC"
                    ]
                ]],
                "__mcpInternalSessionID": "mcp-draft"
            ],
            client: stack.client
        )
        let digest = try XCTUnwrap(preview["responseEditPreviewDigest"] as? String)

        let proposeCommit = try await stack.mutationService.handleTool(
            name: "propose_commit_response_edit",
            arguments: [
                "draftID": draftID,
                "responseEditPreviewDigest": digest,
                "__mcpInternalSessionID": "mcp-draft"
            ],
            client: stack.client
        )
        let commitToken = try XCTUnwrap(proposeCommit["proposalToken"] as? String)
        let committed = try await applyWithApproval(
            stack: stack,
            toolName: "apply_commit_response_edit",
            proposalToken: commitToken
        )
        let revisionID = try XCTUnwrap(committed["currentRevisionID"] as? String)

        let proposeMap = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: ["responseRevisionID": revisionID],
            client: stack.client
        )
        let mapToken = try XCTUnwrap(proposeMap["proposalToken"] as? String)
        let mapped = try await applyWithApproval(
            stack: stack,
            toolName: "apply_create_map_local",
            proposalToken: mapToken
        )
        let overrideID = try XCTUnwrap(mapped["targetID"] as? String)
        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first { $0.id.uuidString == overrideID })
        XCTAssertFalse(rule.isEnabled)
        if case .inline(let data) = rule.bodySource {
            XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "<html>NOBLENDER LLC</html>")
        } else {
            XCTFail("Expected inline body")
        }

        let get = try await stack.mutationService.handleTool(
            name: "response_draft_get",
            arguments: ["draftID": draftID],
            client: stack.client
        )
        let payload = try XCTUnwrap(get["payload"] as? [String: Any])
        XCTAssertEqual(payload["isReferencedByMapLocalRule"] as? Bool, true)
    }
}
