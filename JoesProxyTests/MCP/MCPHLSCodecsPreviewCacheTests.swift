import XCTest
@testable import JoesProxy

/// P1-03 focused coverage: HLS CODECS preview digest, cache eviction/TTL/invalidation, fail-closed store.
@MainActor
final class MCPHLSCodecsPreviewCacheTests: XCTestCase {
    private struct Stack {
        let mutationService: MCPMutationService
        let policyStore: MCPPolicyStore
        let client: MCPClientRecord
    }

    private func hlsMasterBody() -> Data {
        Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,AUDIO="main"
        https://cdn.example.com/video/one.m3u8?sid=secret
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,AUDIO="main"
        https://cdn.example.com/video/two.m3u8?sid=secret
        """.utf8)
    }

    private func makeSession(bodyData: Data, path: String = "/master.m3u8") -> SessionRecord {
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
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "hls-preview-journal.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "hls-preview-policy.json"))
        policyStore.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "hls-preview-audit.json"))
        auditStore.load()
        let mutationService = MCPMutationService(
            bookmarkStore: InMemoryBookmarkStore(),
            responseOverrideStore: ResponseOverrideStore(),
            proposalCoordinator: MCPProposalCoordinator(
                recoveryCoordinator: recoveryCoordinator,
                policyRevisionProvider: { policyStore.policyRevision }
            ),
            recoveryCoordinator: recoveryCoordinator,
            approvalStore: MCPApprovalStore(),
            policyStore: policyStore,
            auditStore: auditStore,
            snapshotService: snapshotService
        )
        let client = MCPClientRecord(
            id: "client-hls-preview-cache",
            displayName: "hls-preview-cache",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return Stack(mutationService: mutationService, policyStore: policyStore, client: client)
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func preview(
        stack: Stack,
        session: SessionRecord,
        sessionStore: InMemorySessionStore,
        snapshotService: MCPSessionSnapshotService,
        codecs: String,
        mcpSessionID: String = "hls-cache-session"
    ) async throws -> String {
        let inspection = MCPMediaInspectionService(sessionStore: sessionStore, snapshotService: snapshotService)
        let ref = try XCTUnwrap(
            inspection.manifestStructure(sessionID: session.id, policyRevision: .initial).hlsVariants.first?.variantRef
        )
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
        return try XCTUnwrap(payload["previewDigest"] as? String)
    }

    func testDigestIsStableAcrossRepeatedComputes() {
        let matcher = MCPMutationMatcher(
            method: "GET",
            scheme: .https,
            host: "cdn.example.com",
            port: 443,
            path: "/master.m3u8",
            matchMode: .ignoreQuery
        )
        let sessionID = UUID()
        let first = MCPHLSCodecsPreviewDigest.compute(
            sessionID: sessionID,
            captureSequence: 1,
            originalBodyHash: "aaa",
            patchedBodyHash: "bbb",
            edits: [("ref-1", "avc1.640028")],
            matcher: matcher,
            sourceStatus: 200,
            contentType: "application/vnd.apple.mpegurl",
            transformerVersion: HLSCODECSEditTransformer.transformerVersion
        )
        let second = MCPHLSCodecsPreviewDigest.compute(
            sessionID: sessionID,
            captureSequence: 1,
            originalBodyHash: "aaa",
            patchedBodyHash: "bbb",
            edits: [("ref-1", "avc1.640028")],
            matcher: matcher,
            sourceStatus: 200,
            contentType: "application/vnd.apple.mpegurl",
            transformerVersion: HLSCODECSEditTransformer.transformerVersion
        )
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("hls-codecs-preview-"))
    }

    func testSemanticCheckRejectsNonCodecsFieldDrift() throws {
        let original = HLSParser.parse(String(decoding: hlsMasterBody(), as: UTF8.self), baseURL: nil)
        var patchedText = String(decoding: hlsMasterBody(), as: UTF8.self)
        patchedText = patchedText.replacingOccurrences(of: "1280x720", with: "640x360")
        let patched = HLSParser.parse(patchedText, baseURL: nil)
        XCTAssertThrowsError(
            try HLSCODECSPreviewSemanticCheck.assertCodecsOnlyChange(
                original: original,
                patched: patched,
                editedOrdinals: [0]
            )
        ) { error in
            XCTAssertEqual(
                error as? HLSCODECSPreviewSemanticCheck.Failure,
                .nonCodecsFieldChanged(ordinal: 0, field: "resolution")
            )
        }
    }

    func testSemanticCheckAllowsCodecsChangeOnEditedOrdinalOnly() throws {
        let original = HLSParser.parse(String(decoding: hlsMasterBody(), as: UTF8.self), baseURL: nil)
        let locator = try XCTUnwrap(HLSCODECSEditTransformer.variantLocators(in: hlsMasterBody()).first)
        let result = try HLSCODECSEditTransformer.apply(
            originalBytes: hlsMasterBody(),
            edits: [HLSCODECSVariantEdit(locator: locator, codecs: "avc1.640028,mp4a.40.2")]
        )
        let patched = HLSParser.parse(String(decoding: result.data, as: UTF8.self), baseURL: nil)
        try HLSCODECSPreviewSemanticCheck.assertCodecsOnlyChange(
            original: original,
            patched: patched,
            editedOrdinals: [0]
        )
    }

    func testFailClosedDoesNotCacheOnForgedVariantRef() async throws {
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
                    "edits": [["variantRef": "forged-ref", "codecs": "avc1.640028"]],
                    "__mcpInternalSessionID": "s1"
                ],
                client: stack.client
            )
            XCTFail("expected forged ref rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
        XCTAssertEqual(stack.mutationService.testing_responseEditPreviewCount(), 0)
    }

    func testEntryCapEvictsOldestPreview() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        stack.mutationService.responseEditPreviewMaxEntriesForTesting = 2

        var digests: [String] = []
        for index in 0 ..< 3 {
            let session = makeSession(bodyData: hlsMasterBody(), path: "/master-\(index).m3u8")
            sessionStore.append(session)
            let digest = try await preview(
                stack: stack,
                session: session,
                sessionStore: sessionStore,
                snapshotService: snapshotService,
                codecs: "avc1.64\(index)028"
            )
            digests.append(digest)
        }

        XCTAssertEqual(stack.mutationService.testing_responseEditPreviewCount(), 2)
        XCTAssertFalse(stack.mutationService.testing_hasResponseEditPreview(digest: digests[0]))
        XCTAssertTrue(stack.mutationService.testing_hasResponseEditPreview(digest: digests[1]))
        XCTAssertTrue(stack.mutationService.testing_hasResponseEditPreview(digest: digests[2]))
    }

    func testTTLExpiryRemovesPreview() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        stack.mutationService.responseEditPreviewTTLForTesting = 0.05
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)
        let digest = try await preview(
            stack: stack,
            session: session,
            sessionStore: sessionStore,
            snapshotService: snapshotService,
            codecs: "avc1.640028"
        )
        XCTAssertTrue(stack.mutationService.testing_hasResponseEditPreview(digest: digest))

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(stack.mutationService.testing_hasResponseEditPreview(digest: digest))

        do {
            _ = try stack.mutationService.resolvedResponseEditPreviewIfRequested(
                arguments: [
                    "hlsPreviewDigest": digest,
                    "__mcpInternalSessionID": "hls-cache-session"
                ],
                client: stack.client
            )
            XCTFail("expected expired preview rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }

    func testInvalidateTransientStateClearsClientPreviewsOnly() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)
        let digest = try await preview(
            stack: stack,
            session: session,
            sessionStore: sessionStore,
            snapshotService: snapshotService,
            codecs: "avc1.640028"
        )
        XCTAssertEqual(stack.mutationService.testing_responseEditPreviewCount(), 1)

        stack.mutationService.invalidateTransientState(clientID: "other-client")
        XCTAssertTrue(stack.mutationService.testing_hasResponseEditPreview(digest: digest))

        stack.mutationService.invalidateTransientState(clientID: stack.client.id)
        XCTAssertEqual(stack.mutationService.testing_responseEditPreviewCount(), 0)
    }

    func testMissingSourceSessionInvalidatesPreview() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody())
        sessionStore.append(session)
        let digest = try await preview(
            stack: stack,
            session: session,
            sessionStore: sessionStore,
            snapshotService: snapshotService,
            codecs: "avc1.640028"
        )

        sessionStore.clear()
        XCTAssertFalse(stack.mutationService.testing_hasResponseEditPreview(digest: digest))

        do {
            _ = try stack.mutationService.resolvedResponseEditPreviewIfRequested(
                arguments: [
                    "hlsPreviewDigest": digest,
                    "__mcpInternalSessionID": "hls-cache-session"
                ],
                client: stack.client
            )
            XCTFail("expected missing-source rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }
}
