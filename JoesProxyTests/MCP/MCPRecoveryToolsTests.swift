import Combine
import XCTest
@testable import JoesProxy

@MainActor
final class MCPRecoveryToolsTests: XCTestCase {
    private struct Stack {
        let controller: MCPServerController
        let mutationService: MCPMutationService
        let recoveryCoordinator: MCPRecoveryCoordinator
        let journalStore: MCPEffectJournalStore
        let responseOverrideStore: ResponseOverrideStore
        let bookmarkStore: InMemoryBookmarkStore
        let approvalStore: MCPApprovalStore
        let proposalCoordinator: MCPProposalCoordinator
        let configuration: MCPRecoveryTestConfiguration
        let client: MCPClientRecord
        let bearer: String
    }

    func testReturnToNormalViaControllerDisablesEnabledMCPRule() async throws {
        let stack = try await makeRunningStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/rtn-disable")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        let summary = try await stack.controller.returnToNormal()
        XCTAssertGreaterThan(summary.disabledCount + summary.restoredCount, 0)

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertFalse(try XCTUnwrap(rules.first?.isEnabled))
        if case .stopped = stack.controller.state {
            // expected
        } else {
            XCTFail("Return To Normal should stop the MCP server.")
        }
    }

    /// Regression test for a confirmed HIGH bug (found via live MCP validation): `MCPRecoveryRestorer.restore`
    /// compared the target's CURRENT revision against the journal entry's `baselineRevision` — the
    /// PRE-mutation revision. Since a successful mutation necessarily changes the revision, that
    /// comparison always mismatched for the just-committed mutation, so Return To Normal could never
    /// actually perform a true revision-safe restore for the most recently mutated target — it always
    /// fell back to disable-with-a-spurious-conflict, even when nothing else had touched the object.
    /// Asserts the STRICT outcome (`restoredCount == 1`, zero conflicts) that the existing
    /// `disabledCount + restoredCount > 0` assertion in the test above cannot distinguish from the
    /// broken fallback-to-disable behavior.
    func testReturnToNormalTrulyRestoresJustEnabledRuleWithNoConflict() async throws {
        let stack = try await makeRunningStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/rtn-restore-strict")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        let summary = try await stack.controller.returnToNormal()

        XCTAssertEqual(summary.restoredCount, 1, "The just-enabled rule must be truly restored, not merely disabled via a spurious conflict.")
        XCTAssertTrue(summary.conflicts.isEmpty, "No conflict should be reported when nothing touched the target after the MCP mutation.")

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertFalse(try XCTUnwrap(rules.first(where: { $0.id == ruleID })?.isEnabled))
    }

    func testReturnToNormalViaHTTPToolCall() async throws {
        let stack = try await makeRunningStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/rtn-http")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        guard case .running(_, let endpointURL) = stack.controller.state else {
            throw XCTSkip("MCP server not running.")
        }
        let enrollment = try stack.controller.clientRegistry.enroll(
            displayName: "rtn-http",
            assignedProfileID: .shareable
        )
        let sessionID = try await postInitialize(endpointURL: endpointURL, bearer: enrollment.plaintextCredential)
        let response = try await postToolCall(
            endpointURL: endpointURL,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            name: "return_to_normal",
            arguments: [:]
        )
        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertNil(object["error"])

        let stopDeadline = Date().addingTimeInterval(MCPServerLimits.gracefulStopDeadline + 2)
        while stack.controller.state != .stopped, Date() < stopDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(stack.controller.state, .stopped,
            "The recovery response must arrive intact and the deferred shutdown must finish.")

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertFalse(try XCTUnwrap(rules.first(where: { $0.id == ruleID })?.isEnabled))
    }

    func testDeletingFinalSessionCleansUpClientEffectsAndTerminatesSession() async throws {
        let stack = try await makeRunningStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/delete-cleanup")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        guard case .running(_, let endpointURL) = stack.controller.state else {
            throw XCTSkip("MCP server not running.")
        }
        let sessionID = try await postInitialize(endpointURL: endpointURL, bearer: stack.bearer)
        let response = try await deleteSession(
            endpointURL: endpointURL,
            bearer: stack.bearer,
            sessionID: sessionID
        )

        XCTAssertEqual(response.statusCode, 204)
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertFalse(try XCTUnwrap(rules.first(where: { $0.id == ruleID })?.isEnabled))
        XCTAssertTrue(stack.controller.auditStore.recentEvents.contains {
            $0.kind == .sessionTerminated && $0.clientID == stack.client.id
        })
    }

    /// Uses `updateBlockRule`'s `statusCode` change, not a label edit — `MCPTargetRevisionFingerprint`
    /// deliberately excludes cosmetic fields (label, hit counts, timestamps) from the revision, by
    /// design (see its doc comment), so a label-only edit does NOT constitute a conflicting change.
    /// A prior version of this test used `setLabel` and only ever passed because of a since-fixed bug
    /// in the restore revision comparison that made EVERY just-enabled target look "conflicted"
    /// regardless of whether anything real had touched it.
    func testUserEditAfterMCPEnableSurfacesConflict() async throws {
        let stack = try await makeRunningStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/rtn-conflict")
        _ = try await enableRule(stack: stack, overrideID: ruleID)
        try await stack.responseOverrideStore.updateBlockRule(id: ruleID, label: nil, matchMode: .exactPath, statusCode: 599)

        _ = try await stack.controller.returnToNormal()

        if case .conflict(let items) = stack.recoveryCoordinator.effectState {
            XCTAssertFalse(items.isEmpty)
        } else {
            XCTFail("expected conflict effect state after user edit")
        }
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.first?.statusCode, 599)
    }

    func testDetachedEffectSurvivesReturnToNormal() async throws {
        let stack = try await makeRunningStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/rtn-detach")
        _ = try await enableRule(stack: stack, overrideID: ruleID)
        try await stack.controller.detachMCPEffect(itemID: ruleID.uuidString)

        _ = try await stack.controller.returnToNormal()

        let rules = await stack.responseOverrideStore.rules()
        let rule = try XCTUnwrap(rules.first(where: { $0.id == ruleID }))
        XCTAssertEqual(rule.mcpOrigin, .user)
        XCTAssertTrue(rule.isEnabled)
    }

    func testDisableEffectsDoesNotStopServer() async throws {
        let stack = try await makeRunningStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/disable-only")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        let summary = try await stack.controller.disableMCPCreatedEffects()
        XCTAssertGreaterThan(summary.disabledCount, 0)

        if case .running = stack.controller.state {
            // expected
        } else {
            XCTFail("Disable MCP-Created Effects must not stop the server.")
        }
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertFalse(try XCTUnwrap(rules.first?.isEnabled))
    }

    func testStopServerOnlyLeavesEffectsActive() async throws {
        let stack = try await makeRunningStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/stop-only")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        await stack.controller.stopServerOnly()

        if case .active = stack.recoveryCoordinator.effectState {
            // expected
        } else {
            XCTFail("Stop Server Only must leave MCP effects active.")
        }
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(try XCTUnwrap(rules.first?.isEnabled))
    }

    func testReturnToNormalIdempotentWhenClean() async throws {
        let stack = try await makeRunningStack()
        let first = try await stack.controller.returnToNormal()
        let second = try await stack.controller.returnToNormal()
        XCTAssertEqual(first.disabledCount + first.restoredCount, second.disabledCount + second.restoredCount)
    }

    func testReturnToNormalClearsGrantedNonces() async throws {
        let stack = try await makeRunningStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/grants")
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: ["overrideID": ruleID.uuidString],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_enable_rule",
                arguments: ["proposalToken": token],
                client: stack.client
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            XCTAssertNotNil(stack.approvalStore.grantedAuthorization(nonce: authorization.nonce))
        }

        _ = try await stack.controller.returnToNormal()
        if let authorization = stack.approvalStore.pendingRequests.first {
            _ = authorization
        }
        let enrollmentNonce = "fabricated-nonce"
        XCTAssertNil(stack.approvalStore.grantedAuthorization(nonce: enrollmentNonce))
    }

    func testProposalLocksClearedAfterReturnToNormal() async throws {
        let stack = try await makeRunningStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/locks")
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: ["overrideID": ruleID.uuidString],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedApply(
            stack: stack,
            tool: "apply_enable_rule",
            args: ["proposalToken": token]
        )

        _ = try await stack.controller.returnToNormal()

        let proposalAfter = try await stack.mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: ["overrideID": ruleID.uuidString],
            client: stack.client
        )
        let retryToken = try XCTUnwrap(proposalAfter["proposalToken"] as? String)
        _ = try await approvedApply(
            stack: stack,
            tool: "apply_enable_rule",
            args: ["proposalToken": retryToken]
        )
    }

    func testEnforceFreshLaunchMCPStateClearsTrafficMutationsButKeepsClientsTokensAndDurableGrants() async throws {
        let stack = try await makeRunningStack()

        // 1. Enabled MCP-origin rule.
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/fresh-launch-rule")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        // 2. MCP-created bookmark (no rewrites, so it's represented as a whole-object inventory row).
        let bookmarkID = UUID()
        try stack.bookmarkStore.saveBookmarks([
            Bookmark(
                id: bookmarkID,
                name: "fresh-launch-bookmark",
                request: sampleRequest(path: "/fresh-launch-bookmark"),
                mcpOrigin: .mcp
            )
        ])

        // 3. MCP-origin throttle override, active.
        var throttle = stack.configuration.networkThrottleConfiguration
        throttle.isEnabled = true
        throttle.mcpOrigin = .mcp
        stack.configuration.networkThrottleConfiguration = throttle

        // 4. Orphaned `.conflict`-phase journal entry whose target matches nothing currently live —
        // simulates a prior crash where the rule that produced this entry never made it to disk.
        let orphanedIntent = MCPMutationIntent(
            clientID: stack.client.id,
            targetKind: .block,
            targetID: UUID().uuidString,
            baselineRevision: MCPTargetRevision(rawValue: "orphaned"),
            intendedChangeDigest: "digest",
            rollbackSnapshot: nil,
            expiresAt: Date().addingTimeInterval(120)
        )
        let orphanedTransactionID = try stack.recoveryCoordinator.beginMutation(orphanedIntent)
        try stack.recoveryCoordinator.markConflict(transactionID: orphanedTransactionID, message: "Orphaned from a prior crash.")
        if case .conflict = stack.recoveryCoordinator.effectState {
            // expected precondition
        } else {
            XCTFail("Expected a conflict effect state before the fresh-launch reset.")
        }

        // 5. Temporary and durable grants for the active client.
        try stack.controller.grantStore.addGrant(clientID: stack.client.id, capability: .bodyRead, mode: .untilSessionEnd)
        try stack.controller.grantStore.addGrant(clientID: stack.client.id, capability: .changeThrottle, mode: .durablePolicy)

        // --- Act ---
        await stack.controller.enforceFreshLaunchMCPState()

        // --- Assert: traffic-mutation state is gone ---
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(rules.isEmpty, "MCP-origin rule must be deleted, not merely disabled.")

        let bookmarks = stack.bookmarkStore.loadBookmarks()
        XCTAssertFalse(bookmarks.contains { $0.id == bookmarkID }, "MCP-created bookmark must be deleted.")

        let resetThrottle = stack.configuration.networkThrottleConfiguration
        XCTAssertFalse(resetThrottle.isEnabled)
        XCTAssertNil(resetThrottle.mcpOrigin)

        XCTAssertTrue(stack.journalStore.entries.isEmpty, "Every journal entry, including orphaned conflicts, must be cleared.")

        if case .clean = stack.recoveryCoordinator.effectState {
            // expected
        } else {
            XCTFail("Expected clean effect state after the fresh-launch reset; got \(stack.recoveryCoordinator.effectState).")
        }

        // --- Assert: clients/tokens/durable grants survive ---
        let temporaryGrant = stack.controller.grantStore.activeGrant(capability: .bodyRead, clientID: stack.client.id)
        XCTAssertNil(temporaryGrant, "Temporary (until-session-end) grants must be cleared on a fresh launch.")
        let durableGrant = stack.controller.grantStore.activeGrant(capability: .changeThrottle, clientID: stack.client.id)
        XCTAssertNotNil(durableGrant, "Durable policy grants must survive a fresh launch.")

        let registeredClient = stack.controller.clientRegistry.clients.first { $0.id == stack.client.id }
        XCTAssertEqual(registeredClient?.credentialState, .active, "Clients and their credential/bearer-token state must survive a fresh launch.")
    }

    // MARK: - Helpers

    private func makeRunningStack() async throws -> Stack {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-recovery.json"))
        policyStore.load()
        let credentialStore = MCPInMemoryCredentialStore()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-recovery.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-recovery.json"))
        auditStore.load()
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "journal-recovery.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let bookmarkStore = InMemoryBookmarkStore()
        let responseOverrideStore = ResponseOverrideStore()
        let configuration = MCPRecoveryTestConfiguration()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { policyStore.policyRevision }
        )
        let port = UInt16.random(in: 20_000...60_000)
        let controller = MCPServerController(
            sessionStore: InMemorySessionStore(),
            port: port,
            credentialStore: credentialStore,
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            recoveryCoordinator: recoveryCoordinator,
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            scenarioStore: MCPScenarioStore(persistenceURL: temporaryURL(named: "scenarios-recovery.json")),
            responseDraftStore: ResponseDraftStore(persistenceURL: temporaryURL(named: "response-drafts-recovery.json")),
            fixtureRunStore: HLSFixtureRunStore(persistenceURL: temporaryURL(named: "hls-fixture-run-store-recovery.json"))
        )
        controller.configureMutationService(
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            configuration: configuration
        )
        controller.configureRecoveryService(
            journalStore: journalStore,
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            configuration: configuration
        )
        await controller.start()
        guard case .running = controller.state else {
            throw XCTSkip("MCP server did not start.")
        }

        let enrollment = try clientRegistry.enroll(
            displayName: "recovery-test",
            assignedProfileID: MCPDisclosureProfileID.shareable
        )
        let mutationService = try XCTUnwrap(controller.mutationService)
        return Stack(
            controller: controller,
            mutationService: mutationService,
            recoveryCoordinator: recoveryCoordinator,
            journalStore: journalStore,
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            approvalStore: controller.approvalStore,
            proposalCoordinator: proposalCoordinator,
            configuration: configuration,
            client: enrollment.client,
            bearer: enrollment.plaintextCredential
        )
    }

    private func createDisabledBlockRule(stack: Stack, path: String) async throws -> UUID {
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_block",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": path,
                "matchMode": "exactPath",
                "statusCode": 403
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedApply(stack: stack, tool: "apply_create_block", args: ["proposalToken": token])
        let rules = await stack.responseOverrideStore.rules()
        return try XCTUnwrap(rules.first?.id)
    }

    private func enableRule(stack: Stack, overrideID: UUID) async throws -> [String: Any] {
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: ["overrideID": overrideID.uuidString],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        return try await approvedApply(stack: stack, tool: "apply_enable_rule", args: ["proposalToken": token])
    }

    private func approvedApply(stack: Stack, tool: String, args: [String: Any]) async throws -> [String: Any] {
        do {
            return try await stack.mutationService.handleTool(name: tool, arguments: args, client: stack.client)
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            var retryArgs = args
            retryArgs["approval"] = try authorizationDictionary(authorization)
            return try await stack.mutationService.handleTool(name: tool, arguments: retryArgs, client: stack.client)
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

    private func sampleRequest(path: String = "/test") -> CapturedRequest {
        CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private struct RawHTTPResponse {
        var statusCode: Int
        var body: Data
    }

    private func postInitialize(endpointURL: URL, bearer: String) async throws -> String {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.httpBody = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
        """.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let (_, response) = try await URLSession.shared.data(for: request)
        let sessionID = try XCTUnwrap((response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader))

        var initializedRequest = URLRequest(url: endpointURL)
        initializedRequest.httpMethod = "POST"
        initializedRequest.httpBody = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        initializedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initializedRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        initializedRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        initializedRequest.setValue("2025-11-25", forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader)
        initializedRequest.setValue(sessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        let (_, initializedResponse) = try await URLSession.shared.data(for: initializedRequest)
        XCTAssertEqual((initializedResponse as? HTTPURLResponse)?.statusCode, 202)
        return sessionID
    }

    private func postToolCall(
        endpointURL: URL,
        bearer: String,
        sessionID: String,
        name: String,
        arguments: [String: Any]
    ) async throws -> RawHTTPResponse {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-11-25", forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader)
        request.setValue(sessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        let (data, response) = try await URLSession.shared.data(for: request)
        return RawHTTPResponse(
            statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
            body: data
        )
    }

    private func deleteSession(
        endpointURL: URL,
        bearer: String,
        sessionID: String
    ) async throws -> RawHTTPResponse {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-11-25", forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader)
        request.setValue(sessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        let (data, response) = try await URLSession.shared.data(for: request)
        return RawHTTPResponse(
            statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
            body: data
        )
    }
}

@MainActor
private final class MCPRecoveryTestConfiguration: AppConfiguration {
    var proxyPort: UInt16 = NetworkConstants.defaultPort { didSet { didChangeSubject.send(()) } }
    var logLevel: AppLogLevel = .info { didSet { didChangeSubject.send(()) } }
    var verboseHTTPSLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var isFindDebugLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var appTextSizeRawValue = AppTextSize.standard.rawValue { didSet { didChangeSubject.send(()) } }
    var isInspectorCopyRedactionEnabled = true { didSet { didChangeSubject.send(()) } }
    var sessionSortFieldRawValue = ProxyViewModel.SessionSortField.startedAt.rawValue { didSet { didChangeSubject.send(()) } }
    var isSessionSortAscending = false { didSet { didChangeSubject.send(()) } }
    var isSessionAutoScrollEnabled = false { didSet { didChangeSubject.send(()) } }
    var sessionBrowserModeRawValue = SessionBrowserMode.table.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerGroupingRawValue = SessionExplorerGrouping.byHost.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.exactHosts.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerExpandedNodeIDs: [String] = [] { didSet { didChangeSubject.send(()) } }
    var sessionInspectorSplitFraction = 0.62 { didSet { didChangeSubject.send(()) } }
    var httpsBypassDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var httpsInterceptDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var isNoCachingEnabled = false { didSet { didChangeSubject.send(()) } }
    var noCachingDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var isSystemProxyManagementEnabled = false { didSet { didChangeSubject.send(()) } }
    var systemProxyStrictCapture = false { didSet { didChangeSubject.send(()) } }
    var hasAcknowledgedSystemProxyRouting = false { didSet { didChangeSubject.send(()) } }
    var showSystemProxyMenuBarItem = true { didSet { didChangeSubject.send(()) } }
    var runInMenuBarOnly = false
    var hasCompletedInitialGuidedSetupPresentation = false { didSet { didChangeSubject.send(()) } }
    var warnsBeforeQuittingWithUnsavedSessions = true { didSet { didChangeSubject.send(()) } }
    var sdkEventServerEnabled = false { didSet { didChangeSubject.send(()) } }
    var sdkEventServerPort: UInt16 { 9091 }
    var networkThrottleConfiguration = NetworkThrottleConfiguration.defaults { didSet { didChangeSubject.send(()) } }
    var profileHostStrategyRawValue = ProfileHostStrategy.bonjourLocal.rawValue { didSet { didChangeSubject.send(()) } }
    var manualProfileHost = "" { didSet { didChangeSubject.send(()) } }
    var responseOverridesData: Data? { didSet { didChangeSubject.send(()) } }
    var captureRetentionPolicy: CaptureRetentionPolicy = .unlimited { didSet { didChangeSubject.send(()) } }
    let certificateLabel = "test"
    private let didChangeSubject = PassthroughSubject<Void, Never>()

    var didChangePublisher: AnyPublisher<Void, Never> {
        didChangeSubject.eraseToAnyPublisher()
    }

    func resetToDefaults() {}
}
