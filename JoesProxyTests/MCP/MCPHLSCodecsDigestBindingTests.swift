import XCTest
@testable import JoesProxy

/// P1-04 / P1-10: `hlsPreviewDigest` → Map Local propose/apply binding, consume, and disclosure privacy.
@MainActor
final class MCPHLSCodecsDigestBindingTests: XCTestCase {
    private struct Stack {
        let mutationService: MCPMutationService
        let responseOverrideStore: ResponseOverrideStore
        let approvalStore: MCPApprovalStore
        let policyStore: MCPPolicyStore
        let client: MCPClientRecord
    }

    private let mcpSessionID = "hls-digest-binding-session"

    private func hlsMasterBody() -> Data {
        Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,AUDIO="main"
        https://cdn.example.com/video/one.m3u8?sid=secret
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,AUDIO="main"
        https://cdn.example.com/video/two.m3u8?sid=secret
        """.utf8)
    }

    private func makeSession(
        bodyData: Data,
        path: String = "/master.m3u8?sid=secret"
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "cdn.example.com",
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
                bodyData: bodyData,
                bodySize: bodyData.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    private func makeStack(snapshotService: MCPSessionSnapshotService) throws -> Stack {
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "hls-binding-journal.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "hls-binding-policy.json"))
        policyStore.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "hls-binding-audit.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let responseOverrideStore = ResponseOverrideStore()
        let mutationService = MCPMutationService(
            bookmarkStore: InMemoryBookmarkStore(),
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: MCPProposalCoordinator(
                recoveryCoordinator: recoveryCoordinator,
                policyRevisionProvider: { policyStore.policyRevision }
            ),
            recoveryCoordinator: recoveryCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            auditStore: auditStore,
            snapshotService: snapshotService
        )
        let client = MCPClientRecord(
            id: "client-hls-digest-binding",
            displayName: "hls-digest-binding",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return Stack(
            mutationService: mutationService,
            responseOverrideStore: responseOverrideStore,
            approvalStore: approvalStore,
            policyStore: policyStore,
            client: client
        )
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func variantRef(
        session: SessionRecord,
        sessionStore: InMemorySessionStore,
        snapshotService: MCPSessionSnapshotService
    ) throws -> String {
        let inspection = MCPMediaInspectionService(sessionStore: sessionStore, snapshotService: snapshotService)
        return try XCTUnwrap(
            inspection.manifestStructure(sessionID: session.id, policyRevision: .initial).hlsVariants.first?.variantRef
        )
    }

    private func previewDigest(
        stack: Stack,
        session: SessionRecord,
        sessionStore: InMemorySessionStore,
        snapshotService: MCPSessionSnapshotService,
        codecs: String = "avc1.640028,mp4a.40.2"
    ) async throws -> (digest: String, payload: [String: Any]) {
        let ref = try variantRef(session: session, sessionStore: sessionStore, snapshotService: snapshotService)
        let payload = try await stack.mutationService.handleTool(
            name: "preview_hls_codecs_edit",
            arguments: [
                "sessionID": session.id.uuidString,
                "edits": [["variantRef": ref, "codecs": codecs]],
                "matchMode": "ignoreQuery",
                "__mcpInternalSessionID": mcpSessionID
            ],
            client: stack.client
        )
        let digest = try XCTUnwrap(payload["previewDigest"] as? String)
        return (digest, payload)
    }

    private func approveAndApplyMapLocal(
        stack: Stack,
        proposalToken: String
    ) async throws {
        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_create_map_local",
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
            _ = try await stack.mutationService.handleTool(
                name: "apply_create_map_local",
                arguments: [
                    "proposalToken": proposalToken,
                    "approval": approval
                ],
                client: stack.client
            )
        }
    }

    func testGoldPathProposeDisclosureAndApplyUsesServerBody() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)

        let preview = try await previewDigest(
            stack: stack,
            session: session,
            sessionStore: sessionStore,
            snapshotService: snapshotService
        )
        XCTAssertTrue(preview.digest.hasPrefix("hls-codecs-preview-"))

        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: [
                "hlsPreviewDigest": preview.digest,
                "__mcpInternalSessionID": mcpSessionID
            ],
            client: stack.client
        )
        let effectSummary = try XCTUnwrap(proposal["effectSummary"] as? String)
        XCTAssertTrue(effectSummary.contains("validated CODECS-only edit"))
        XCTAssertEqual(proposal["previewDigest"] as? String, preview.digest)
        XCTAssertEqual(proposal["codecValueProvenance"] as? String, "user_supplied")
        XCTAssertEqual(proposal["mediaVerified"] as? Bool, false)
        XCTAssertNotNil(proposal["transformedBodyHash"] as? String)
        XCTAssertNotNil(proposal["codecsDiffSummary"] as? String)
        XCTAssertFalse(String(describing: proposal).contains("secret"))
        XCTAssertFalse(String(describing: proposal).contains("#EXTM3U"))
        XCTAssertFalse(stack.mutationService.testing_hasResponseEditPreview(digest: preview.digest))

        let proposalToken = try XCTUnwrap(proposal["proposalToken"] as? String)
        let plan = try XCTUnwrap(stack.mutationService.plansByProposalToken[proposalToken])
        XCTAssertEqual(plan.draftPreviewDigest, preview.digest)

        try await approveAndApplyMapLocal(stack: stack, proposalToken: proposalToken)
        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first)
        guard case .inline(let storedBody) = rule.bodySource else {
            return XCTFail("expected inline body source")
        }
        let expected = try HLSCODECSEditTransformer.apply(
            originalBytes: hlsMasterBody(),
            edits: [
                HLSCODECSVariantEdit(
                    locator: try XCTUnwrap(HLSCODECSEditTransformer.variantLocators(in: hlsMasterBody()).first),
                    codecs: "avc1.640028,mp4a.40.2"
                )
            ]
        ).data
        XCTAssertEqual(storedBody, expected)
    }

    func testCallerBodyStatusAndContentTypeRejectedWithDigest() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)
        let preview = try await previewDigest(
            stack: stack,
            session: session,
            sessionStore: sessionStore,
            snapshotService: snapshotService
        )

        for conflicting in [
            ["bodyText": "caller body"],
            ["statusCode": 418],
            ["contentType": "text/plain"]
        ] as [[String: Any]] {
            var arguments: [String: Any] = [
                "hlsPreviewDigest": preview.digest,
                "__mcpInternalSessionID": mcpSessionID
            ]
            for (key, value) in conflicting {
                arguments[key] = value
            }
            do {
                _ = try await stack.mutationService.handleTool(
                    name: "propose_create_map_local",
                    arguments: arguments,
                    client: stack.client
                )
                XCTFail("expected rejection for \(conflicting.keys)")
            } catch let error as MCPStructuredError {
                XCTAssertEqual(error.code, .malformedRequest)
            }
        }
        XCTAssertTrue(stack.mutationService.testing_hasResponseEditPreview(digest: preview.digest))
    }

    func testMismatchedMatcherRejected() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)
        let preview = try await previewDigest(
            stack: stack,
            session: session,
            sessionStore: sessionStore,
            snapshotService: snapshotService
        )

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "hlsPreviewDigest": preview.digest,
                    "method": "GET",
                    "host": "other.example.com",
                    "path": "/master.m3u8",
                    "matchMode": "ignoreQuery",
                    "__mcpInternalSessionID": mcpSessionID
                ],
                client: stack.client
            )
            XCTFail("expected matcher mismatch rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("matcher differs"))
        }
    }

    func testConsumedDigestCannotBeReused() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)
        let preview = try await previewDigest(
            stack: stack,
            session: session,
            sessionStore: sessionStore,
            snapshotService: snapshotService
        )

        _ = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: [
                "hlsPreviewDigest": preview.digest,
                "__mcpInternalSessionID": mcpSessionID
            ],
            client: stack.client
        )

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "hlsPreviewDigest": preview.digest,
                    "__mcpInternalSessionID": mcpSessionID
                ],
                client: stack.client
            )
            XCTFail("expected consumed digest rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
            XCTAssertTrue(error.message.contains("consumed") || error.message.contains("missing"))
        }
    }

    func testExpiredPreviewRejectedAtPropose() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        stack.mutationService.responseEditPreviewTTLForTesting = 0.05
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)
        let preview = try await previewDigest(
            stack: stack,
            session: session,
            sessionStore: sessionStore,
            snapshotService: snapshotService
        )

        try await Task.sleep(nanoseconds: 80_000_000)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "hlsPreviewDigest": preview.digest,
                    "__mcpInternalSessionID": mcpSessionID
                ],
                client: stack.client
            )
            XCTFail("expected expired preview rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }

    func testPolicyRevisionMismatchRejectedAtPropose() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)
        let preview = try await previewDigest(
            stack: stack,
            session: session,
            sessionStore: sessionStore,
            snapshotService: snapshotService
        )

        _ = stack.policyStore.bumpRevisionForTightening()

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "hlsPreviewDigest": preview.digest,
                    "__mcpInternalSessionID": mcpSessionID
                ],
                client: stack.client
            )
            XCTFail("expected policy mismatch rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }

    func testCaptureEpochMismatchRejectedAtPropose() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)
        let preview = try await previewDigest(
            stack: stack,
            session: session,
            sessionStore: sessionStore,
            snapshotService: snapshotService
        )

        // Reload keeps the session indexed but advances capture epoch.
        sessionStore.load(sessions: [session], epochChangeReason: "test_reload")

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "hlsPreviewDigest": preview.digest,
                    "__mcpInternalSessionID": mcpSessionID
                ],
                client: stack.client
            )
            XCTFail("expected capture-epoch mismatch rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }

    func testProposalSurvivesCacheEvictionAfterPropose() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        stack.mutationService.responseEditPreviewMaxEntriesForTesting = 1
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)
        let preview = try await previewDigest(
            stack: stack,
            session: session,
            sessionStore: sessionStore,
            snapshotService: snapshotService
        )

        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_map_local",
            arguments: [
                "hlsPreviewDigest": preview.digest,
                "__mcpInternalSessionID": mcpSessionID
            ],
            client: stack.client
        )
        let proposalToken = try XCTUnwrap(proposal["proposalToken"] as? String)

        // Fill / churn the preview cache after consume — proposal must still apply.
        for index in 0 ..< 2 {
            let churnSession = makeSession(bodyData: hlsMasterBody(), path: "/churn-\(index).m3u8")
            sessionStore.append(churnSession)
            _ = try await previewDigest(
                stack: stack,
                session: churnSession,
                sessionStore: sessionStore,
                snapshotService: snapshotService,
                codecs: "avc1.64\(index)028"
            )
        }
        XCTAssertFalse(stack.mutationService.testing_hasResponseEditPreview(digest: preview.digest))

        try await approveAndApplyMapLocal(stack: stack, proposalToken: proposalToken)
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.count, 1)
        guard case .inline(let storedBody) = rules[0].bodySource else {
            return XCTFail("expected inline body")
        }
        let expected = try HLSCODECSEditTransformer.apply(
            originalBytes: hlsMasterBody(),
            edits: [
                HLSCODECSVariantEdit(
                    locator: try XCTUnwrap(HLSCODECSEditTransformer.variantLocators(in: hlsMasterBody()).first),
                    codecs: "avc1.640028,mp4a.40.2"
                )
            ]
        ).data
        XCTAssertEqual(storedBody, expected)
    }

    func testForgedVariantRefRejectedAtPreview() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "preview_hls_codecs_edit",
                arguments: [
                    "sessionID": session.id.uuidString,
                    "edits": [["variantRef": "hls-variant-forged", "codecs": "avc1.640028"]],
                    "__mcpInternalSessionID": mcpSessionID
                ],
                client: stack.client
            )
            XCTFail("expected forged variantRef rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
        XCTAssertEqual(stack.mutationService.testing_responseEditPreviewCount(), 0)
    }
}
