import XCTest
@testable import JoesProxy

/// P1-05: matcher cardinality disclosure and enable-time confounder gating.
@MainActor
final class MCPHLSCodecsMatcherScopeTests: XCTestCase {
    private struct Stack {
        let mutationService: MCPMutationService
        let responseOverrideStore: ResponseOverrideStore
        let approvalStore: MCPApprovalStore
        let client: MCPClientRecord
    }

    private let mcpSessionID = "hls-matcher-scope-session"

    private func hlsMasterBody() -> Data {
        Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,AUDIO="main"
        https://cdn.example.com/video/one.m3u8?sid=secret
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,AUDIO="main"
        https://cdn.example.com/video/two.m3u8?sid=secret
        """.utf8)
    }

    private func makeSession(bodyData: Data, path: String) -> SessionRecord {
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
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "hls-scope-journal.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "hls-scope-policy.json"))
        policyStore.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "hls-scope-audit.json"))
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
            id: "client-hls-matcher-scope",
            displayName: "hls-matcher-scope",
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

    private func overlappingEnabledRule() -> ResponseOverrideRule {
        // pathSuffix overlaps the ignoreQuery `/master.m3u8` probe without sharing an exact
        // matcher (avoids ResponseOverride exclusive-rule conflict on enable).
        ResponseOverrideRule(
            id: UUID(),
            label: "confounder",
            requestMethod: "GET",
            requestScheme: .https,
            host: "cdn.example.com",
            port: 443,
            path: "master.m3u8",
            matchMode: .pathSuffix,
            sourceKind: .block,
            sourceDescription: "block",
            statusCode: 403,
            headers: [],
            bodySource: .inline(nil),
            createdAt: Date(),
            isEnabled: true,
            mcpOrigin: .mcp,
            mcpProvenance: nil,
            mcpTargetRevision: MCPTargetRevision(rawValue: "rev-confounder")
        )
    }

    private func approveAndApplyEnable(
        stack: Stack,
        overrideID: UUID,
        acceptConfounder: Bool
    ) async throws {
        var proposeArgs: [String: Any] = ["overrideID": overrideID.uuidString]
        if acceptConfounder {
            proposeArgs["acceptConfounder"] = true
        }
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: proposeArgs,
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        var applyArgs: [String: Any] = ["proposalToken": token]
        if acceptConfounder {
            applyArgs["acceptConfounder"] = true
        }
        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_enable_rule",
                arguments: applyArgs,
                client: stack.client
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(authorization)
            let approval = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            applyArgs["approval"] = approval
            _ = try await stack.mutationService.handleTool(
                name: "apply_enable_rule",
                arguments: applyArgs,
                client: stack.client
            )
        }
    }

    func testPathSuffixMultiMatchWarnsAndDisclosesObservedAt() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let first = makeSession(bodyData: hlsMasterBody(), path: "/a/master.m3u8")
        let second = makeSession(bodyData: hlsMasterBody(), path: "/b/master.m3u8")
        sessionStore.append(first)
        sessionStore.append(second)
        let ref = try variantRef(session: first, sessionStore: sessionStore, snapshotService: snapshotService)

        let preview = try await stack.mutationService.handleTool(
            name: "preview_hls_codecs_edit",
            arguments: [
                "sessionID": first.id.uuidString,
                "edits": [["variantRef": ref, "codecs": "avc1.640028"]],
                "matchMode": "pathSuffix",
                "path": "master.m3u8",
                "__mcpInternalSessionID": mcpSessionID
            ],
            client: stack.client
        )
        let scope = try XCTUnwrap(preview["matcherScope"] as? [String: Any])
        XCTAssertEqual(scope["observedCaptureCardinality"] as? Int, 2)
        XCTAssertEqual(scope["cardinalityIsHistorical"] as? Bool, true)
        XCTAssertNotNil(scope["warning"] as? String)
        let observedAt = try XCTUnwrap(scope["observedAt"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: observedAt))
        XCTAssertEqual(scope["conflictingEnabledRuleIDs"] as? [String], [])
        XCTAssertEqual(scope["activeScenarioIDs"] as? [String], [])
    }

    func testPreviewListsEnabledOverlappingRule() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody(), path: "/master.m3u8?sid=secret")
        sessionStore.append(session)
        let confounder = overlappingEnabledRule()
        try await stack.responseOverrideStore.addRule(confounder)
        let ref = try variantRef(session: session, sessionStore: sessionStore, snapshotService: snapshotService)

        let preview = try await stack.mutationService.handleTool(
            name: "preview_hls_codecs_edit",
            arguments: [
                "sessionID": session.id.uuidString,
                "edits": [["variantRef": ref, "codecs": "avc1.640028"]],
                "matchMode": "ignoreQuery",
                "__mcpInternalSessionID": mcpSessionID
            ],
            client: stack.client
        )
        let scope = try XCTUnwrap(preview["matcherScope"] as? [String: Any])
        let conflicts = try XCTUnwrap(scope["conflictingEnabledRuleIDs"] as? [String])
        XCTAssertEqual(conflicts, [confounder.id.uuidString])
    }

    func testEnableWithoutAcceptConfounderFailsWhenOverlappingEnabledRuleExists() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        let session = makeSession(bodyData: hlsMasterBody(), path: "/master.m3u8")
        sessionStore.append(session)
        try await stack.responseOverrideStore.addRule(overlappingEnabledRule())

        let disabled = ResponseOverrideRule(
            id: UUID(),
            label: "codecs-map-local",
            requestMethod: "GET",
            requestScheme: .https,
            host: "cdn.example.com",
            port: 443,
            path: "/master.m3u8",
            matchMode: .ignoreQuery,
            sourceKind: .inlineText,
            sourceDescription: "map local",
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
            bodySource: .inline(hlsMasterBody()),
            createdAt: Date(),
            isEnabled: false,
            mcpOrigin: .mcp,
            mcpProvenance: nil,
            mcpTargetRevision: MCPTargetRevision(rawValue: "rev-disabled")
        )
        try await stack.responseOverrideStore.addRule(disabled)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_enable_rule",
                arguments: ["overrideID": disabled.id.uuidString],
                client: stack.client
            )
            XCTFail("expected confounder rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.message.contains("acceptConfounder"))
        }
    }

    func testEnableWithAcceptConfounderSucceeds() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        try await stack.responseOverrideStore.addRule(overlappingEnabledRule())
        let disabled = ResponseOverrideRule(
            id: UUID(),
            label: "codecs-map-local",
            requestMethod: "GET",
            requestScheme: .https,
            host: "cdn.example.com",
            port: 443,
            path: "/master.m3u8",
            matchMode: .ignoreQuery,
            sourceKind: .inlineText,
            sourceDescription: "map local",
            statusCode: 200,
            headers: [],
            bodySource: .inline(hlsMasterBody()),
            createdAt: Date(),
            isEnabled: false,
            mcpOrigin: .mcp,
            mcpProvenance: nil,
            mcpTargetRevision: MCPTargetRevision(rawValue: "rev-disabled-2")
        )
        try await stack.responseOverrideStore.addRule(disabled)

        try await approveAndApplyEnable(stack: stack, overrideID: disabled.id, acceptConfounder: true)
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(try XCTUnwrap(rules.first(where: { $0.id == disabled.id })).isEnabled)
    }

    func testActiveScenarioIDsBlockEnableWithoutAccept() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        stack.mutationService.activeScenarioIDsProvider = { ["scenario-active-1"] }
        let disabled = ResponseOverrideRule(
            id: UUID(),
            label: "codecs-map-local",
            requestMethod: "GET",
            requestScheme: .https,
            host: "cdn.example.com",
            port: 443,
            path: "/master.m3u8",
            matchMode: .ignoreQuery,
            sourceKind: .inlineText,
            sourceDescription: "map local",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data("#EXTM3U\n".utf8)),
            createdAt: Date(),
            isEnabled: false,
            mcpOrigin: .mcp,
            mcpProvenance: nil,
            mcpTargetRevision: MCPTargetRevision(rawValue: "rev-scenario")
        )
        try await stack.responseOverrideStore.addRule(disabled)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_enable_rule",
                arguments: ["overrideID": disabled.id.uuidString],
                client: stack.client
            )
            XCTFail("expected scenario confounder rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertTrue(error.details?["activeScenarioIDs"]?.contains("scenario-active-1") == true)
        }

        try await approveAndApplyEnable(stack: stack, overrideID: disabled.id, acceptConfounder: true)
    }

    func testPathSuffixMultiMatchBlocksEnableWithoutAccept() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)
        sessionStore.append(makeSession(bodyData: hlsMasterBody(), path: "/a/master.m3u8"))
        sessionStore.append(makeSession(bodyData: hlsMasterBody(), path: "/b/master.m3u8"))
        let disabled = ResponseOverrideRule(
            id: UUID(),
            label: "suffix-rule",
            requestMethod: "GET",
            requestScheme: .https,
            host: "cdn.example.com",
            port: 443,
            path: "master.m3u8",
            matchMode: .pathSuffix,
            sourceKind: .inlineText,
            sourceDescription: "map local",
            statusCode: 200,
            headers: [],
            bodySource: .inline(hlsMasterBody()),
            createdAt: Date(),
            isEnabled: false,
            mcpOrigin: .mcp,
            mcpProvenance: nil,
            mcpTargetRevision: MCPTargetRevision(rawValue: "rev-suffix")
        )
        try await stack.responseOverrideStore.addRule(disabled)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_enable_rule",
                arguments: ["overrideID": disabled.id.uuidString],
                client: stack.client
            )
            XCTFail("expected pathSuffix cardinality rejection")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
            XCTAssertEqual(error.details?["observedCaptureCardinality"], "2")
        }
    }
}
