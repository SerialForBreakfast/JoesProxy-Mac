import Combine
import XCTest
@testable import JoesProxy

@MainActor
final class MCPActiveMutationToolsTests: XCTestCase {
    private struct Stack {
        let mutationService: MCPMutationService
        let recoveryCoordinator: MCPRecoveryCoordinator
        let journalStore: MCPEffectJournalStore
        let responseOverrideStore: ResponseOverrideStore
        let bookmarkStore: InMemoryBookmarkStore
        let approvalStore: MCPApprovalStore
        let auditStore: MCPAuditStore
        let policyStore: MCPPolicyStore
        let configuration: MCPActiveMutationTestConfiguration
        let client: MCPClientRecord
    }

    func testEnableDisabledMCPBlockRuleAffectsTraffic() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/blocked-live")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(try XCTUnwrap(rules.first?.isEnabled))
        let decision = try await stack.responseOverrideStore.ruleDecision(for: sampleRequest(path: "/blocked-live"))
        if case .block = decision {
            // expected
        } else {
            XCTFail("enabled MCP block rule must match traffic")
        }
    }

    func testDisableEnabledMCPRuleStopsMatching() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/toggle-off")
        _ = try await enableRule(stack: stack, overrideID: ruleID)
        _ = try await disableRule(stack: stack, overrideID: ruleID)

        let decision = try await stack.responseOverrideStore.ruleDecision(for: sampleRequest(path: "/toggle-off"))
        if case .noMatch = decision {
            // expected
        } else {
            XCTFail("disabled MCP rule must not affect traffic")
        }
    }

    func testApplyDisableRuleDoesNotRequireInteractiveApproval() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/no-approve-disable")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        let proposal = try await stack.mutationService.handleTool(
            name: "propose_disable_rule",
            arguments: ["overrideID": ruleID.uuidString],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        let applied = try await stack.mutationService.handleTool(
            name: "apply_disable_rule",
            arguments: ["proposalToken": token],
            client: stack.client
        )
        XCTAssertEqual(applied["isEnabled"] as? Bool, false)
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertFalse(try XCTUnwrap(rules.first(where: { $0.id == ruleID })?.isEnabled))
        XCTAssertTrue(stack.auditStore.events.contains { $0.kind == .ruleDisabled })
        XCTAssertTrue(stack.auditStore.events.contains {
            $0.kind == .proposalApplied && $0.reasonCode.hasPrefix("disableRule:")
        })
    }

    func testOverridesListFullProjectionIncludesKindSpecificFields() async throws {
        let stack = try makeStack(profile: .shareable)
        let blockID = try await createDisabledBlockRule(stack: stack, path: "/dto-block")
        let liveID = try await createDisabledLiveRewriteRule(stack: stack, path: "/dto-live")
        _ = try await enableRule(stack: stack, overrideID: blockID)
        _ = try await sampleRequestHit(stack: stack, path: "/dto-block")

        let page = try await stack.mutationService.handleTool(
            name: "overrides_list",
            arguments: ["projection": "full", "limit": 50],
            client: stack.client
        )
        let items = try XCTUnwrap(page["items"] as? [[String: Any]])
        let block = try XCTUnwrap(items.first { $0["id"] as? String == blockID.uuidString })
        XCTAssertEqual(block["sourceKind"] as? String, "block")
        XCTAssertEqual(block["scheme"] as? String, "https")
        XCTAssertEqual((block["hitCount"] as? NSNumber)?.intValue ?? (block["hitCount"] as? Int), 1)
        XCTAssertNotNil(block["lastMatchedAt"])
        XCTAssertEqual(block["dropConnection"] as? Bool, false)
        XCTAssertNotNil(block["sourceDescription"])

        let live = try XCTUnwrap(items.first { $0["id"] as? String == liveID.uuidString })
        XCTAssertEqual(live["sourceKind"] as? String, "liveResponseRewrite")
        let paths = try XCTUnwrap(live["liveRewritePaths"] as? [String])
        XCTAssertFalse(paths.isEmpty)
        XCTAssertNil(live["bodyText"])
        XCTAssertNil(live["patchedBody"])
    }

    func testDeleteMCPOwnedRuleRequiresApprovalAndRemovesRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/delete-me")

        let proposal = try await stack.mutationService.handleTool(
            name: "propose_delete_rule",
            arguments: ["overrideID": ruleID.uuidString],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        XCTAssertEqual(proposal["riskTier"] as? String, MCPCapabilityRiskTier.destructiveTool.rawValue)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_delete_rule",
                arguments: ["proposalToken": token],
                client: stack.client
            )
            XCTFail("apply_delete_rule must require interactive approval")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .approvalRequired)
        }

        let applied = try await approvedApply(
            stack: stack,
            tool: "apply_delete_rule",
            args: ["proposalToken": token]
        )
        XCTAssertEqual(applied["targetID"] as? String, ruleID.uuidString)

        let rules = await stack.responseOverrideStore.rules()
        XCTAssertNil(rules.first(where: { $0.id == ruleID }))
        XCTAssertTrue(stack.auditStore.events.contains { $0.kind == .ruleDeleted })
        XCTAssertTrue(stack.auditStore.events.contains {
            $0.kind == .proposalApplied && $0.reasonCode.hasPrefix("deleteRule:")
        })

        do {
            _ = try await stack.mutationService.handleTool(
                name: "override_get",
                arguments: ["overrideID": ruleID.uuidString],
                client: stack.client
            )
            XCTFail("override_get should fail after delete")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testDeleteRejectsNonMCPOwnedRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let userRule = ResponseOverrideRule(
            label: "user",
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: nil,
            path: "/user-owned",
            matchMode: .exactPath,
            sourceKind: .block,
            sourceDescription: "Block",
            statusCode: 503,
            headers: [],
            bodySource: .inline(Data()),
            isEnabled: true,
            mcpOrigin: nil
        )
        try await stack.responseOverrideStore.addRule(userRule)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_delete_rule",
                arguments: ["overrideID": userRule.id.uuidString],
                client: stack.client
            )
            XCTFail("propose_delete_rule must reject non-MCP rules")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }

    func testApplyDisableRuleStillHonorsAlwaysDeny() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/deny-disable")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        let proposal = try await stack.mutationService.handleTool(
            name: "propose_disable_rule",
            arguments: ["overrideID": ruleID.uuidString],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = stack.mutationService.grantStore.addDenial(
            clientID: stack.client.id,
            capability: .disableRule
        )
        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_disable_rule",
                arguments: ["proposalToken": token],
                client: stack.client
            )
            XCTFail("expected policy denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(try XCTUnwrap(rules.first(where: { $0.id == ruleID })?.isEnabled))
    }

    func testApplyDisableRewriteDoesNotRequireInteractiveApproval() async throws {
        let stack = try makeStack(profile: .shareable)
        let bookmark = Bookmark(
            name: "rewrite-disable",
            request: sampleRequest(),
            savedResponse: BookmarkSavedResponse(
                statusCode: 200,
                headers: [],
                bodyData: Data("{}".utf8),
                savedAt: Date()
            ),
            responseRewrites: [
                BookmarkResponseFieldRewrite(jsonPath: "$.a", overrideValue: .string("b"), isRuleEnabled: true)
            ],
            mcpOrigin: .mcp,
            mcpProvenance: MCPProvenance(
                clientID: stack.client.id,
                operationID: "rewrite-disable-op",
                capability: .createDisabledRewrite,
                createdAt: Date()
            )
        )
        let revised = MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(bookmark)
        try stack.bookmarkStore.saveBookmarks([revised])
        let rewriteID = try XCTUnwrap(revised.responseRewrites.first?.id)

        let proposal = try await stack.mutationService.handleTool(
            name: "propose_disable_rewrite",
            arguments: [
                "bookmarkID": revised.id.uuidString,
                "rewriteID": rewriteID.uuidString
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        let applied = try await stack.mutationService.handleTool(
            name: "apply_disable_rewrite",
            arguments: ["proposalToken": token],
            client: stack.client
        )
        XCTAssertEqual(applied["isEnabled"] as? Bool, false)
        XCTAssertEqual(stack.approvalStore.pendingCount, 0)
        let saved = stack.bookmarkStore.loadBookmarks().first
        XCTAssertFalse(try XCTUnwrap(saved?.responseRewrites.first?.isRuleEnabled))
    }


    func testEnableNonMCPRuleDenied() async throws {
        let stack = try makeStack(profile: .shareable)
        let rule = ResponseOverrideRule(
            label: "legacy",
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/legacy",
            matchMode: .exactPath,
            sourceKind: .block,
            sourceDescription: "block",
            statusCode: 403,
            headers: [],
            bodySource: .inline(nil),
            isEnabled: false
        )
        try await stack.responseOverrideStore.addRule(rule)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_enable_rule",
                arguments: ["overrideID": rule.id.uuidString],
                client: stack.client
            )
            XCTFail("expected policy denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }

    func testEnableRuleRejectsLiveResponseRewrite() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledLiveRewriteRule(stack: stack, path: "/live-deny")
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_enable_rule",
                arguments: ["overrideID": ruleID.uuidString],
                client: stack.client
            )
            XCTFail("expected policy denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }

    func testStaleProposalWhenRuleToggledInUI() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/stale")
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: ["overrideID": ruleID.uuidString],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        try await stack.responseOverrideStore.setEnabled(true, for: ruleID)
        do {
            _ = try await approvedApply(stack: stack, tool: "apply_enable_rule", args: ["proposalToken": token])
            XCTFail("expected stale proposal")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }

    func testStaleDisableProposalWhenRuleToggledInUI() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/stale-disable")
        _ = try await enableRule(stack: stack, overrideID: ruleID)
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_disable_rule",
            arguments: ["overrideID": ruleID.uuidString],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        try await stack.responseOverrideStore.setEnabled(false, for: ruleID)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "apply_disable_rule",
                arguments: ["proposalToken": token],
                client: stack.client
            )
            XCTFail("expected stale proposal")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .staleProposal)
        }
    }

    func testChangeThrottlePersistsMCPProvenance() async throws {
        let stack = try makeStack(profile: .shareable)
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_change_throttle",
            arguments: [
                "isEnabled": true,
                "selectedPresetID": NetworkThrottlePresetID.mobile3G
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedApply(stack: stack, tool: "apply_change_throttle", args: ["proposalToken": token])

        XCTAssertTrue(stack.configuration.networkThrottleConfiguration.isEnabled)
        XCTAssertEqual(stack.configuration.networkThrottleConfiguration.mcpOrigin, .mcp)
        XCTAssertNotNil(stack.configuration.networkThrottleConfiguration.mcpProvenance)
        XCTAssertNotNil(stack.configuration.networkThrottleConfiguration.mcpTargetRevision)
    }

    func testEffectStateActiveAfterEnable() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/effect")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        if case .active(let summary) = stack.recoveryCoordinator.effectState {
            XCTAssertGreaterThan(summary.changedRuleCount, 0)
        } else {
            XCTFail("expected active effect state")
        }

        _ = try await disableRule(stack: stack, overrideID: ruleID)
        if case .clean = stack.recoveryCoordinator.effectState {
            // expected
        } else {
            XCTFail("expected clean effect state after disable")
        }
    }

    func testRollbackSnapshotDecodableFromJournal() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledBlockRule(stack: stack, path: "/rollback")
        _ = try await enableRule(stack: stack, overrideID: ruleID)

        let entry = try XCTUnwrap(stack.journalStore.entries.last { $0.phase == .committed })
        let snapshotData = try XCTUnwrap(entry.rollbackSnapshot)
        let snapshot = try MCPRollbackSnapshotReader.decodeRuleRollback(from: snapshotData)
        XCTAssertFalse(snapshot.isEnabled)
    }

    func testCaptureAttributionStampedOnceForEnabledRule() async throws {
        let provenance = MCPProvenance(
            clientID: "client-mutation-test",
            operationID: "op-1",
            capability: .enableRule,
            createdAt: Date()
        )
        let rule = ResponseOverrideRule(
            label: "block",
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/attr",
            matchMode: .exactPath,
            sourceKind: .block,
            sourceDescription: "block",
            statusCode: 403,
            headers: [],
            bodySource: .inline(nil),
            isEnabled: true,
            mcpOrigin: .mcp,
            mcpProvenance: provenance
        )
        let attribution = try XCTUnwrap(MCPActiveEffectAttributionResolver.attribution(for: rule))
        let response = CapturedResponse(statusCode: 403, headers: [], bodyData: nil, bodySize: nil)
        let stamped = MCPActiveEffectAttributionResolver.stampedResponse(
            response,
            overrideAttribution: attribution,
            throttleAttribution: nil
        )
        XCTAssertNotNil(stamped.mcpAttribution)
        let restamped = MCPActiveEffectAttributionResolver.stampedResponse(
            stamped,
            overrideAttribution: attribution,
            throttleAttribution: nil
        )
        XCTAssertEqual(restamped.mcpAttribution, stamped.mcpAttribution)
    }

    func testThrottleAttributionWhenMCPThrottleActive() {
        var throttle = NetworkThrottleConfiguration.defaults
        throttle.isEnabled = true
        throttle.mcpOrigin = .mcp
        throttle.mcpProvenance = MCPProvenance(
            clientID: "client-mutation-test",
            operationID: "op-throttle",
            capability: .changeThrottle,
            createdAt: Date()
        )
        throttle = MCPTargetRevisionFingerprint.throttleByApplyingRevision(throttle)
        let attribution = MCPActiveEffectAttributionResolver.attribution(for: throttle)
        XCTAssertNotNil(attribution)
        XCTAssertTrue(try XCTUnwrap(attribution?.effectKinds.contains(.throttle)))
    }

    func testEnableRewriteTogglesBookmarkRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let bookmark = Bookmark(
            name: "rewrite",
            request: sampleRequest(),
            savedResponse: BookmarkSavedResponse(
                statusCode: 200,
                headers: [],
                bodyData: Data("{}".utf8),
                savedAt: Date()
            ),
            responseRewrites: [
                BookmarkResponseFieldRewrite(jsonPath: "$.a", overrideValue: .string("b"), isRuleEnabled: false)
            ],
            mcpOrigin: .mcp,
            mcpProvenance: MCPProvenance(
                clientID: stack.client.id,
                operationID: "rewrite-op",
                capability: .createDisabledRewrite,
                createdAt: Date()
            )
        )
        let revised = MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(bookmark)
        try stack.bookmarkStore.saveBookmarks([revised])
        let rewriteID = try XCTUnwrap(revised.responseRewrites.first?.id)

        _ = try await approvedApply(
            stack: stack,
            tool: "apply_enable_rewrite",
            args: try await proposeArgs(
                stack: stack,
                tool: "propose_enable_rewrite",
                args: [
                    "bookmarkID": revised.id.uuidString,
                    "rewriteID": rewriteID.uuidString
                ]
            )
        )

        let saved = stack.bookmarkStore.loadBookmarks().first
        XCTAssertTrue(try XCTUnwrap(saved?.responseRewrites.first?.isRuleEnabled))
    }

    func testEnableRuleViaHTTPToolCall() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-active-http.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-active-http.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-active-http.json"))
        auditStore.load()
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "journal-active-http.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let bookmarkStore = InMemoryBookmarkStore()
        let responseOverrideStore = ResponseOverrideStore()
        let configuration = MCPActiveMutationTestConfiguration()
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
            scenarioStore: MCPScenarioStore(persistenceURL: temporaryURL(named: "scenarios-activemutation.json")),
            responseDraftStore: ResponseDraftStore(persistenceURL: temporaryURL(named: "response-drafts-activemutation.json")),
            fixtureRunStore: HLSFixtureRunStore(persistenceURL: temporaryURL(named: "hls-fixture-run-store-activemutation.json"))
        )
        controller.configureMutationService(
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            configuration: configuration
        )
        await controller.start()
        guard case .running(_, let endpointURL) = controller.state else {
            throw XCTSkip("MCP server did not start.")
        }

        let enrollment = try clientRegistry.enroll(
            displayName: "active-http",
            assignedProfileID: .shareable
        )
        let sessionID = try await postInitialize(endpointURL: endpointURL, bearer: enrollment.plaintextCredential)

        let mutationService = try XCTUnwrap(controller.mutationService)
        let client = enrollment.client
        let ruleID = try await createDisabledBlockRule(
            stack: Stack(
                mutationService: mutationService,
                recoveryCoordinator: recoveryCoordinator,
                journalStore: journalStore,
                responseOverrideStore: responseOverrideStore,
                bookmarkStore: bookmarkStore,
                approvalStore: controller.approvalStore,
                auditStore: auditStore,
                policyStore: policyStore,
                configuration: configuration,
                client: client
            ),
            path: "/http-enable"
        )

        let proposeResponse = try await postToolCall(
            endpointURL: endpointURL,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            name: "propose_enable_rule",
            arguments: ["overrideID": ruleID.uuidString]
        )
        let proposeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: proposeResponse.body) as? [String: Any])
        let result = try XCTUnwrap(proposeObject["result"] as? [String: Any])
        let proposalPayload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let token = try XCTUnwrap(proposalPayload["proposalToken"] as? String)

        let unapprovedApply = try await postToolCall(
            endpointURL: endpointURL,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            name: "apply_enable_rule",
            arguments: ["proposalToken": token]
        )
        let unapprovedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: unapprovedApply.body) as? [String: Any])
        let unapprovedError = try XCTUnwrap(unapprovedObject["error"] as? [String: Any])
        let errorData = try XCTUnwrap(unapprovedError["data"] as? [String: Any])
        let requestID = try XCTUnwrap(errorData["requestID"] as? String)
        let authorization = try controller.approvalStore.approve(requestID: requestID)
        let authorizationObject = try authorizationDictionary(authorization)

        let applyResponse = try await postToolCall(
            endpointURL: endpointURL,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            name: "apply_enable_rule",
            arguments: [
                "proposalToken": token,
                "approval": authorizationObject
            ]
        )
        XCTAssertEqual(applyResponse.statusCode, 200)
        let rules = await responseOverrideStore.rules()
        XCTAssertTrue(try XCTUnwrap(rules.first(where: { $0.id == ruleID })?.isEnabled))
        await controller.stop()
    }

    // MARK: - Helpers

    private func makeStack(profile: MCPDisclosureProfileID) throws -> Stack {
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "journal-active.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-active.json"))
        policyStore.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-active.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let bookmarkStore = InMemoryBookmarkStore()
        let responseOverrideStore = ResponseOverrideStore()
        let configuration = MCPActiveMutationTestConfiguration()
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
            enforcesLiveRewritePreview: false,
            throttleConfigurationReader: { configuration.networkThrottleConfiguration },
            throttleConfigurationWriter: { updated in
                configuration.networkThrottleConfiguration = updated
            }
        )
        let client = MCPClientRecord(
            id: "client-mutation-test",
            displayName: "mutation-test",
            assignedProfileID: profile,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return Stack(
            mutationService: mutationService,
            recoveryCoordinator: recoveryCoordinator,
            journalStore: journalStore,
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            approvalStore: approvalStore,
            auditStore: auditStore,
            policyStore: policyStore,
            configuration: configuration,
            client: client
        )
    }

    private func createDisabledBlockRule(stack: Stack, path: String) async throws -> UUID {
        let token = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_block",
            applyTool: "apply_create_block",
            proposeArgs: [
                "method": "GET",
                "host": "api.example.com",
                "path": path,
                "matchMode": "exactPath",
                "statusCode": 403
            ]
        )
        XCTAssertFalse(token.isEmpty)
        let rules = await stack.responseOverrideStore.rules()
        return try XCTUnwrap(rules.first(where: { $0.path == path })?.id)
    }

    private func createDisabledLiveRewriteRule(stack: Stack, path: String) async throws -> UUID {
        let token = try await proposeAndApply(
            stack: stack,
            proposeTool: "propose_create_live_rewrite",
            applyTool: "apply_create_live_rewrite",
            proposeArgs: [
                "method": "GET",
                "host": "api.example.com",
                "path": path,
                "matchMode": "exactPath",
                "jsonPath": "$.flag",
                "overrideValue": ["type": "bool", "value": true]
            ]
        )
        XCTAssertFalse(token.isEmpty)
        let rules = await stack.responseOverrideStore.rules()
        return try XCTUnwrap(rules.first(where: { $0.path == path })?.id)
    }

    private func sampleRequestHit(stack: Stack, path: String) async throws {
        _ = try await stack.responseOverrideStore.ruleDecision(
            for: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .plain,
                inspectionReason: nil,
                host: "api.example.com",
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            )
        )
    }

    private func enableRule(stack: Stack, overrideID: UUID) async throws -> [String: Any] {
        try await approvedApply(
            stack: stack,
            tool: "apply_enable_rule",
            args: try await proposeArgs(
                stack: stack,
                tool: "propose_enable_rule",
                args: ["overrideID": overrideID.uuidString]
            )
        )
    }

    private func disableRule(stack: Stack, overrideID: UUID) async throws -> [String: Any] {
        try await approvedApply(
            stack: stack,
            tool: "apply_disable_rule",
            args: try await proposeArgs(
                stack: stack,
                tool: "propose_disable_rule",
                args: ["overrideID": overrideID.uuidString]
            )
        )
    }

    private func proposeArgs(stack: Stack, tool: String, args: [String: Any]) async throws -> [String: Any] {
        let proposal = try await stack.mutationService.handleTool(
            name: tool,
            arguments: args,
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        return ["proposalToken": token]
    }

    private func proposeAndApply(
        stack: Stack,
        proposeTool: String,
        applyTool: String,
        proposeArgs: [String: Any]
    ) async throws -> String {
        let proposal = try await stack.mutationService.handleTool(
            name: proposeTool,
            arguments: proposeArgs,
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedApply(stack: stack, tool: applyTool, args: ["proposalToken": token])
        return token
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
        let sessionID = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        let resolvedSessionID = try XCTUnwrap(sessionID)

        var initializedRequest = URLRequest(url: endpointURL)
        initializedRequest.httpMethod = "POST"
        initializedRequest.httpBody = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        initializedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initializedRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        initializedRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        initializedRequest.setValue("2025-11-25", forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader)
        initializedRequest.setValue(resolvedSessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        let (_, initializedResponse) = try await URLSession.shared.data(for: initializedRequest)
        XCTAssertEqual((initializedResponse as? HTTPURLResponse)?.statusCode, 202)
        return resolvedSessionID
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
}

@MainActor
private final class MCPActiveMutationTestConfiguration: AppConfiguration {
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
