import XCTest
@testable import JoesProxy

/// Coverage for the `.collectionMock` authoring/activation flow: `preview_collection_mock` →
/// `propose_create_collection_mock` → `apply_create_collection_mock` → `activate_collection_mock`.
/// Mirrors the sibling Live Rewrite coverage in `MCPMutationToolsTests.swift`/
/// `MCPOpenWorldToolsTests.swift`, since this flow was built by mirroring that one exactly.
@MainActor
final class MCPCollectionMockToolsTests: XCTestCase {
    private struct Stack {
        let mutationService: MCPMutationService
        let openWorldService: MCPOpenWorldService
        let responseOverrideStore: ResponseOverrideStore
        let sessionStore: InMemorySessionStore
        let approvalStore: MCPApprovalStore
        let journalStore: MCPEffectJournalStore
        let client: MCPClientRecord
    }

    private func makeStack(profile: MCPDisclosureProfileID) throws -> Stack {
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "collection-mock-journal.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "collection-mock-policy.json"))
        policyStore.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "collection-mock-audit.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let bookmarkStore = InMemoryBookmarkStore()
        let responseOverrideStore = ResponseOverrideStore()
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { policyStore.policyRevision }
        )
        let mutationService = MCPMutationService(
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            auditStore: auditStore,
            snapshotService: snapshotService,
            collectionMockAuthoringService: CollectionMockAuthoringService()
        )
        let openWorldService = MCPOpenWorldService(
            bookmarkStore: bookmarkStore,
            sessionStore: sessionStore,
            responseOverrideStore: responseOverrideStore,
            bookmarkExecutor: OpenWorldRecordingExecutor(),
            directOriginFetcher: RecordingDirectOriginBodyFetcher(),
            sessionMatcher: MCPExecutedSessionMatcher(sessionStore: sessionStore, matchTimeout: 0.05),
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            operationCoordinator: MCPOperationCoordinator(
                sessionStore: sessionStore,
                mediaService: MCPMediaInspectionService(sessionStore: sessionStore, snapshotService: snapshotService),
                snapshotService: snapshotService,
                policyStore: policyStore,
                auditStore: auditStore
            ),
            approvalStore: approvalStore,
            policyStore: policyStore,
            auditStore: auditStore,
            runningProxyPort: { 9090 }
        )
        let client = MCPClientRecord(
            id: "client-collection-mock-test",
            displayName: "collection-mock-test",
            assignedProfileID: profile,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return Stack(
            mutationService: mutationService,
            openWorldService: openWorldService,
            responseOverrideStore: responseOverrideStore,
            sessionStore: sessionStore,
            approvalStore: approvalStore,
            journalStore: journalStore,
            client: client
        )
    }

    private func makeSession(bodyData: Data, path: String = "/feed") -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET", scheme: .https, host: "api.example.com", port: 443, path: path,
                headers: [], bodyData: nil, bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: bodyData, bodySize: bodyData.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    private let feedBody = Data(#"{"items":[{"id":"original"}],"total":1}"#.utf8)
    private let draftJSON = #"{"collectionPointer":"/items","item":{"id":"synthetic"},"identityPointers":["/id"],"countPointers":["/total"],"position":"append"}"#

    private func previewRevisionID(stack: Stack, sessionID: String) async throws -> String {
        let preview = try await stack.mutationService.handleTool(
            name: "preview_collection_mock",
            arguments: ["sessionID": sessionID, "draftJSON": draftJSON],
            client: stack.client
        )
        return try XCTUnwrap(preview["revisionID"] as? String)
    }

    private func approvedMutationApply(stack: Stack, tool: String, args: [String: Any]) async throws -> [String: Any] {
        do {
            return try await stack.mutationService.handleTool(name: tool, arguments: args, client: stack.client)
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            var retry = args
            retry["approval"] = try authorizationDictionary(authorization)
            return try await stack.mutationService.handleTool(name: tool, arguments: retry, client: stack.client)
        }
    }

    private func approvedOpenWorldCall(stack: Stack, tool: String, args: [String: Any]) async throws -> [String: Any] {
        do {
            return try await stack.openWorldService.handleTool(name: tool, arguments: args, client: stack.client, mcpSessionID: "s1")
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            var retry = args
            retry["approval"] = try authorizationDictionary(authorization)
            return try await stack.openWorldService.handleTool(name: tool, arguments: retry, client: stack.client, mcpSessionID: "s1")
        }
    }

    private func authorizationDictionary(_ authorization: MCPApprovalAuthorization) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(authorization)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPStructuredError(code: .internalFailure, message: "authorization encoding failed")
        }
        return object
    }

    private func createDisabledCollectionMock(stack: Stack, path: String = "/feed") async throws -> UUID {
        let session = makeSession(bodyData: feedBody, path: path)
        stack.sessionStore.append(session)
        let revisionID = try await previewRevisionID(stack: stack, sessionID: session.id.uuidString)
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_collection_mock",
            arguments: ["method": "GET", "host": "api.example.com", "path": path, "matchMode": "exactPath", "revisionID": revisionID],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedMutationApply(stack: stack, tool: "apply_create_collection_mock", args: ["proposalToken": token])
        let rules = await stack.responseOverrideStore.rules()
        return try XCTUnwrap(rules.first(where: { $0.sourceKind == .collectionMock })?.id)
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    // MARK: - Preview

    func testPreviewCollectionMockReturnsRevisionAndCounts() async throws {
        let stack = try makeStack(profile: .shareable)
        let session = makeSession(bodyData: feedBody)
        stack.sessionStore.append(session)
        let preview = try await stack.mutationService.handleTool(
            name: "preview_collection_mock",
            arguments: ["sessionID": session.id.uuidString, "draftJSON": draftJSON],
            client: stack.client
        )
        XCTAssertNotNil(preview["revisionID"] as? String)
        XCTAssertEqual(preview["beforeCount"] as? Int, 1)
        XCTAssertEqual(preview["afterCount"] as? Int, 2)
        let summary = try XCTUnwrap(preview["summary"] as? String)
        XCTAssertTrue(summary.contains("/items"))
    }

    func testPreviewCollectionMockRejectsUnknownSession() async throws {
        let stack = try makeStack(profile: .shareable)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "preview_collection_mock",
                arguments: ["sessionID": UUID().uuidString, "draftJSON": draftJSON],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    // MARK: - Propose / apply

    func testProposeCollectionMockFailsWithUnknownRevisionID() async throws {
        let stack = try makeStack(profile: .shareable)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_collection_mock",
                arguments: ["method": "GET", "host": "api.example.com", "path": "/feed", "revisionID": UUID().uuidString],
                client: stack.client
            )
            XCTFail("expected staleProposal")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }

    func testCollectionMockHappyPathCreatesDisabledRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledCollectionMock(stack: stack)
        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first(where: { $0.id == ruleID }))
        XCTAssertEqual(rule.sourceKind, .collectionMock)
        XCTAssertFalse(rule.isEnabled)
        XCTAssertEqual(rule.mcpOrigin, .mcp)
        XCTAssertEqual(rule.collectionMockPlan?.collectionPointer, "/items")
        XCTAssertEqual(rule.collectionMockPlan?.identityPointers, ["/id"])
    }

    func testApplyCollectionMockRequiresApproval() async throws {
        let stack = try makeStack(profile: .shareable)
        let session = makeSession(bodyData: feedBody)
        stack.sessionStore.append(session)
        let revisionID = try await previewRevisionID(stack: stack, sessionID: session.id.uuidString)
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_collection_mock",
            arguments: ["method": "GET", "host": "api.example.com", "path": "/feed", "revisionID": revisionID],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_create_collection_mock",
                arguments: ["proposalToken": token],
                client: stack.client
            )
            XCTFail("expected approvalRequired")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .approvalRequired)
        }
    }

    // MARK: - Activate

    func testActivateCollectionMockEnablesRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledCollectionMock(stack: stack)
        let result = try await approvedOpenWorldCall(
            stack: stack, tool: "activate_collection_mock", args: ["overrideID": ruleID.uuidString]
        )
        XCTAssertEqual(result["isEnabled"] as? Bool, true)
        let summary = try XCTUnwrap(result["summary"] as? String)
        XCTAssertTrue(summary.contains("/items"))
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(try XCTUnwrap(rules.first(where: { $0.id == ruleID })?.isEnabled))
        let decision = try await stack.responseOverrideStore.ruleDecision(for: CapturedRequest(
            method: "GET", scheme: .https, host: "api.example.com", port: 443, path: "/feed",
            headers: [], bodyData: nil, bodySize: nil
        ))
        guard case .liveCollectionMock = decision else {
            XCTFail("enabled collection mock must match")
            return
        }
        XCTAssertEqual(stack.journalStore.entries.last?.phase, .committed)
    }

    func testActivateCollectionMockRejectsNonCollectionMockOverride() async throws {
        let stack = try makeStack(profile: .shareable)
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_block",
            arguments: ["method": "GET", "host": "api.example.com", "path": "/blocked", "matchMode": "exactPath", "statusCode": 503],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedMutationApply(stack: stack, tool: "apply_create_block", args: ["proposalToken": token])
        let rules = await stack.responseOverrideStore.rules()
        let blockID = try XCTUnwrap(rules.first?.id)
        do {
            _ = try await approvedOpenWorldCall(stack: stack, tool: "activate_collection_mock", args: ["overrideID": blockID.uuidString])
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testActivateCollectionMockRejectsAlreadyEnabled() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledCollectionMock(stack: stack)
        _ = try await approvedOpenWorldCall(stack: stack, tool: "activate_collection_mock", args: ["overrideID": ruleID.uuidString])
        do {
            _ = try await approvedOpenWorldCall(stack: stack, tool: "activate_collection_mock", args: ["overrideID": ruleID.uuidString])
            XCTFail("expected malformed request for already-enabled rule")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    // MARK: - Policy gating (regression guard for the profileAllows fail-open fix)

    func testProposeCollectionMockRejectedBelowShareableProfile() async throws {
        let stack = try makeStack(profile: .metadataOnly)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_collection_mock",
                arguments: ["method": "GET", "host": "api.example.com", "path": "/feed", "revisionID": UUID().uuidString],
                client: stack.client
            )
            XCTFail("expected policyDenied")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }

    func testActivateCollectionMockRejectedBelowShareableProfile() async throws {
        let shareableStack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledCollectionMock(stack: shareableStack)
        // Re-target a metadataOnly client at the same override store to isolate the profile check
        // from rule existence/ownership checks (both already pass for the shareable client above).
        let metadataOnlyClient = MCPClientRecord(
            id: "client-collection-mock-metadata-only",
            displayName: "metadata-only",
            assignedProfileID: .metadataOnly,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        do {
            _ = try await shareableStack.openWorldService.handleTool(
                name: "activate_collection_mock",
                arguments: ["overrideID": ruleID.uuidString],
                client: metadataOnlyClient,
                mcpSessionID: "s1"
            )
            XCTFail("expected policyDenied")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }
}
