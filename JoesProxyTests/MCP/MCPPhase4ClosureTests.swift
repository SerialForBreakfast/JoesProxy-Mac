import Combine
import XCTest
@testable import JoesProxy

@MainActor
final class MCPPhase4ClosureTests: XCTestCase {
    func testHTTPSRuleApprovalCannotCreateStandingGrant() throws {
        let stack = try makeStack()
        let request = stack.controller.approvalStore.createPendingRequest(clientID: stack.client.id,
            capability: .httpsRulesManage, argumentDigest: MCPArgumentDigest.normalized(["host": "media.example.test"]),
            policyRevision: stack.controller.policyStore.policyRevision, reason: "Synthetic persistent rule review")
        let resolutions: [MCPApprovalResolution] = [.untilSessionEnd, .untilDate(Date().addingTimeInterval(60)), .durablePolicy]
        for resolution in resolutions {
            XCTAssertThrowsError(try stack.controller.resolvePending(requestID: request.requestID, resolution: resolution))
        }
        XCTAssertNil(stack.controller.grantStore.activeGrant(capability: .httpsRulesManage, clientID: stack.client.id))
        XCTAssertNotNil(try stack.controller.resolvePending(requestID: request.requestID, resolution: .allowOnce))
    }

    private struct Stack {
        let controller: MCPServerController
        let responseOverrideStore: ResponseOverrideStore
        let journalStore: MCPEffectJournalStore
        let client: MCPClientRecord
    }

    func testMetadataOnlyClientWithDurableGrantStillDeniedMutating() {
        let policyStore = MCPPolicyStore()
        policyStore.load()
        let grantStore = MCPClientGrantStore()
        grantStore.load()
        let evaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)

        let client = MCPClientRecord(
            id: "meta-client",
            displayName: "meta",
            assignedProfileID: .metadataOnly,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )

        try? grantStore.addGrant(
            clientID: client.id,
            capability: .enableRule,
            mode: .durablePolicy
        )

        XCTAssertFalse(evaluator.effectiveAllows(capability: .enableRule, client: client))
        XCTAssertFalse(evaluator.skipsApprovalNonce(capability: .enableRule, client: client))
    }

    func testShareableClientWithGrantSkipsApprovalNonce() throws {
        let policyStore = MCPPolicyStore()
        policyStore.load()
        let grantStore = MCPClientGrantStore()
        grantStore.load()
        let evaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)

        let client = MCPClientRecord(
            id: "shareable-client",
            displayName: "shareable",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )

        XCTAssertFalse(evaluator.skipsApprovalNonce(capability: .enableRule, client: client))

        _ = try grantStore.addGrant(
            clientID: client.id,
            capability: .enableRule,
            mode: .durablePolicy
        )

        XCTAssertTrue(evaluator.skipsApprovalNonce(capability: .enableRule, client: client))
    }

    func testUntilSessionEndGrantSurvivesPartialSessionRemoval() throws {
        let stack = try makeStack()
        let clientID = stack.client.id

        _ = try stack.controller.grantStore.addGrant(
            clientID: clientID,
            capability: .enableRule,
            mode: .untilSessionEnd
        )

        let sessionA = stack.controller.protocolService.testRegisterSession(clientID: clientID)
        let sessionB = stack.controller.protocolService.testRegisterSession(clientID: clientID)
        XCTAssertEqual(stack.controller.protocolService.activeSessionCount(forClientID: clientID), 2)

        stack.controller.protocolService.testRemoveSession(sessionID: sessionA)
        XCTAssertNotNil(stack.controller.grantStore.activeGrant(capability: .enableRule, clientID: clientID))

        stack.controller.protocolService.testRemoveSession(sessionID: sessionB)
        XCTAssertNil(stack.controller.grantStore.activeGrant(capability: .enableRule, clientID: clientID))
    }

    func testReturnToNormalClearsTemporaryGrantsRetainsDurable() async throws {
        let stack = try makeStack()
        let clientID = stack.client.id

        _ = try stack.controller.grantStore.addGrant(
            clientID: clientID,
            capability: .enableRule,
            mode: .untilSessionEnd
        )
        _ = try stack.controller.grantStore.addGrant(
            clientID: clientID,
            capability: .disableRule,
            mode: .durablePolicy
        )

        _ = try await stack.controller.returnToNormal()

        XCTAssertNil(stack.controller.grantStore.activeGrant(capability: .enableRule, clientID: clientID))
        XCTAssertNotNil(stack.controller.grantStore.activeGrant(capability: .disableRule, clientID: clientID))
    }

    func testEraseAuditHistoryLeavesSingleDestructiveEvent() async {
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-erase.json"))
        auditStore.load()
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .toolCall,
                timestamp: Date(),
                clientID: "c1",
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "test",
                detail: nil
            )
        )

        await auditStore.eraseHistoryRecordingDestructiveAction(detail: "test erase")

        XCTAssertEqual(auditStore.events.count, 1)
        XCTAssertEqual(auditStore.events.first?.kind, .destructiveAction)
        XCTAssertEqual(auditStore.events.first?.reasonCode, "erase_audit_history")
    }

    func testRevokeAllRevokesEveryClient() throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let registry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-batch.json"),
            credentialStore: credentialStore
        )
        try registry.load()
        _ = try registry.enroll(displayName: "a", assignedProfileID: .metadataOnly)
        _ = try registry.enroll(displayName: "b", assignedProfileID: .metadataOnly)

        try registry.revokeAll()

        XCTAssertTrue(registry.clients.allSatisfy { $0.credentialState == .revoked })
    }

    func testJournalRemoveEntriesRefusesUnresolvedIntent() throws {
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "journal-guard.json"))
        journalStore.load()
        try journalStore.appendIntent(
            MCPEffectJournalEntry(
                id: UUID(),
                transactionID: "tx-intent",
                clientID: "c1",
                targetKind: .block,
                targetID: "target-1",
                baselineRevision: nil,
                intendedChangeDigest: "digest",
                rollbackSnapshot: nil,
                expiresAt: Date().addingTimeInterval(120),
                phase: .intent,
                createdAt: Date(),
                conflictMessage: nil
            )
        )

        XCTAssertThrowsError(try journalStore.removeEntries(forTargetID: "target-1")) { error in
            XCTAssertEqual(error as? MCPEffectJournalStoreError, .unresolvedEntriesRemain)
        }
    }

    func testDeleteEffectRemovesMCPRule() async throws {
        let stack = try makeStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/delete-me")

        try await stack.controller.deleteMCPEffect(itemID: ruleID.uuidString)

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(rules.isEmpty)
    }

    func testResetMCPConfigurationPreservesEffectsAndAudit() async throws {
        let stack = try makeStack()
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/reset-keep")
        stack.controller.auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .toolCall,
                timestamp: Date(),
                clientID: stack.client.id,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "before-reset",
                detail: nil
            )
        )
        let auditBefore = stack.controller.auditStore.events.count

        _ = try await stack.controller.resetMCPConfiguration()

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.first?.id, ruleID)
        XCTAssertEqual(stack.controller.auditStore.events.count, auditBefore + 1)
        XCTAssertTrue(
            stack.controller.auditStore.events.contains { $0.reasonCode == "before-reset" }
        )
        XCTAssertTrue(
            stack.controller.auditStore.events.contains {
                $0.kind == .destructiveAction && $0.reasonCode == MCPDestructiveRecoveryAction.resetMCPConfiguration.rawValue
            }
        )
        XCTAssertTrue(stack.controller.enrolledClients.allSatisfy { $0.credentialState == .revoked })
    }

    func testUntilSessionEndResolutionAlsoApprovesTriggeringRequest() async throws {
        let stack = try makeStack()
        let proposal = try await stack.controller.mutationService!.handleTool(
            name: "propose_create_block",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/grant-resolution",
                "matchMode": "exactPath",
                "statusCode": 403
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)

        do {
            _ = try await stack.controller.mutationService!.handleTool(
                name: "apply_create_block",
                arguments: ["proposalToken": token],
                client: stack.client
            )
            XCTFail("Expected apply_create_block to require approval on the first call.")
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])

            // Picking a grant mode broader than "Allow Once" must also unblock the very call that
            // triggered the prompt — otherwise the client's in-flight request fails and has to be
            // retried even though the operator just granted access.
            let authorization = try stack.controller.resolvePending(
                requestID: requestID,
                resolution: .untilSessionEnd
            )
            XCTAssertNotNil(authorization, "untilSessionEnd must approve the triggering request, not just mint a grant for future calls.")

            var retryArgs: [String: Any] = ["proposalToken": token]
            retryArgs["approval"] = try authorizationDictionary(XCTUnwrap(authorization))
            _ = try await stack.controller.mutationService!.handleTool(
                name: "apply_create_block",
                arguments: retryArgs,
                client: stack.client
            )
        }

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertEqual(rules.count, 1)
    }

    func testGrantStoreCapEnforcedForNonExpiringGrants() throws {
        let grantStore = MCPClientGrantStore(persistenceURL: temporaryURL(named: "grants-cap.json"))
        grantStore.load()

        for index in 0..<(MCPClientGrantStore.maxActiveGrants + 20) {
            _ = try grantStore.addGrant(
                clientID: "client-\(index)",
                capability: .enableRule,
                mode: .untilSessionEnd
            )
        }

        XCTAssertLessThanOrEqual(grantStore.grants.count, MCPClientGrantStore.maxActiveGrants)
    }

    func testOverrideInspectDenialDoesNotLeakThroughBookmarkInspectCheck() async throws {
        let stack = try makeStack()
        _ = stack.controller.grantStore.addDenial(clientID: stack.client.id, capability: .overrideInspect)

        do {
            _ = try await stack.controller.mutationService!.handleTool(
                name: "overrides_list",
                arguments: [:],
                client: stack.client
            )
            XCTFail("Expected overrides_list to be denied for a client with an .overrideInspect always-deny.")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }

    func testRevokeAllPersistsRevokedStateEvenWhenKeychainDeleteFails() throws {
        let credentialStore = FailingSecondDeleteCredentialStore()
        let persistenceURL = temporaryURL(named: "clients-batch-partial-failure.json")
        let registry = MCPClientRegistry(persistenceURL: persistenceURL, credentialStore: credentialStore)
        try registry.load()
        _ = try registry.enroll(displayName: "a", assignedProfileID: .metadataOnly)
        let failing = try registry.enroll(displayName: "b", assignedProfileID: .metadataOnly)
        _ = try registry.enroll(displayName: "c", assignedProfileID: .metadataOnly)
        credentialStore.failingClientID = failing.client.id

        try registry.revokeAll()
        XCTAssertTrue(registry.clients.allSatisfy { $0.credentialState == .revoked })

        // Read the persisted file directly rather than through a second `load()` — reloading would
        // re-run `reconcileKeychainVerifiers()`, which retries the same failing Keychain delete via
        // a separate, unrelated code path and would throw again, masking what this test checks.
        let data = try Data(contentsOf: persistenceURL)
        let persisted = try JSONDecoder().decode(MCPClientRegistry.PersistedState.self, from: data)
        XCTAssertTrue(
            persisted.clients.allSatisfy { $0.credentialState == .revoked },
            "revokeAll must persist the revoked state to disk even when a Keychain delete fails partway through."
        )
    }

    func testAlwaysDenyBlocksShareableClientEvenWithGrant() throws {
        let policyStore = MCPPolicyStore()
        policyStore.load()
        let grantStore = MCPClientGrantStore()
        grantStore.load()
        let evaluator = MCPPolicyEvaluator(policyStore: policyStore, grantStore: grantStore)

        let client = MCPClientRecord(
            id: "deny-client",
            displayName: "deny",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )

        _ = try grantStore.addGrant(clientID: client.id, capability: .enableRule, mode: .durablePolicy)
        _ = grantStore.addDenial(clientID: client.id, capability: .enableRule)

        XCTAssertFalse(evaluator.effectiveAllows(capability: .enableRule, client: client))
    }

    // MARK: - Helpers

    private func makeStack() throws -> Stack {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-phase4.json"))
        policyStore.load()
        let credentialStore = MCPInMemoryCredentialStore()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-phase4.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let enrollment = try clientRegistry.enroll(displayName: "phase4", assignedProfileID: .shareable)
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-phase4.json"))
        auditStore.load()
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "journal-phase4.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let bookmarkStore = InMemoryBookmarkStore()
        let responseOverrideStore = ResponseOverrideStore()
        let configuration = MCPPhase4TestConfiguration()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { policyStore.policyRevision }
        )
        let controller = MCPServerController(
            sessionStore: InMemorySessionStore(),
            port: UInt16.random(in: 20_000...60_000),
            credentialStore: credentialStore,
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            recoveryCoordinator: recoveryCoordinator,
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            scenarioStore: MCPScenarioStore(persistenceURL: temporaryURL(named: "scenarios-phase4.json")),
            responseDraftStore: ResponseDraftStore(persistenceURL: temporaryURL(named: "response-drafts-phase4.json")),
            fixtureRunStore: HLSFixtureRunStore(persistenceURL: temporaryURL(named: "hls-fixture-run-store-phase4.json"))
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
        controller.bootstrap()
        return Stack(
            controller: controller,
            responseOverrideStore: responseOverrideStore,
            journalStore: journalStore,
            client: enrollment.client
        )
    }

    private func createDisabledBlockRule(stack: Stack, path: String) async throws -> UUID {
        let proposal = try await stack.controller.mutationService!.handleTool(
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
        _ = try await approvedApply(
            stack: stack,
            tool: "apply_create_block",
            args: ["proposalToken": token]
        )
        let rules = await stack.responseOverrideStore.rules()
        return try XCTUnwrap(rules.first?.id)
    }

    private func approvedApply(
        stack: Stack,
        tool: String,
        args: [String: Any]
    ) async throws -> [String: Any] {
        do {
            return try await stack.controller.mutationService!.handleTool(
                name: tool,
                arguments: args,
                client: stack.client
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.controller.approvePending(requestID: requestID)
            var retryArgs = args
            retryArgs["approval"] = try authorizationDictionary(authorization)
            return try await stack.controller.mutationService!.handleTool(
                name: tool,
                arguments: retryArgs,
                client: stack.client
            )
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

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + named)
    }
}

/// Credential store whose `deleteAllVerifiers` throws for one designated client, used to prove
/// `MCPClientRegistry.revokeAll()` persists the revoked state before attempting Keychain cleanup.
private final class FailingSecondDeleteCredentialStore: MCPClientCredentialStoring, @unchecked Sendable {
    private let inner = MCPInMemoryCredentialStore()
    var failingClientID: String?

    func saveVerifier(clientID: String, generation: Int, verifier: Data) throws {
        try inner.saveVerifier(clientID: clientID, generation: generation, verifier: verifier)
    }

    func loadVerifier(clientID: String, generation: Int) throws -> Data? {
        try inner.loadVerifier(clientID: clientID, generation: generation)
    }

    func deleteVerifier(clientID: String, generation: Int) throws {
        try inner.deleteVerifier(clientID: clientID, generation: generation)
    }

    func deleteAllVerifiers(clientID: String) throws {
        if clientID == failingClientID {
            throw MCPStructuredError(code: .internalFailure, message: "Simulated Keychain failure.")
        }
        try inner.deleteAllVerifiers(clientID: clientID)
    }
}

@MainActor
private final class MCPPhase4TestConfiguration: AppConfiguration {
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
    var didChangePublisher: AnyPublisher<Void, Never> { didChangeSubject.eraseToAnyPublisher() }

    func resetToDefaults() {}
}
