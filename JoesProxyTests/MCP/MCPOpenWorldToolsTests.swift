import Combine
import XCTest
@testable import JoesProxy

@MainActor
final class MCPOpenWorldToolsTests: XCTestCase {
    private struct Stack {
        let openWorldService: MCPOpenWorldService
        let mutationService: MCPMutationService
        let responseOverrideStore: ResponseOverrideStore
        let bookmarkStore: InMemoryBookmarkStore
        let sessionStore: InMemorySessionStore
        let approvalStore: MCPApprovalStore
        let auditStore: MCPAuditStore
        let journalStore: MCPEffectJournalStore
        let operationCoordinator: MCPOperationCoordinator
        let trackingLiveProbe: TrackingLiveProbeService
        let executor: OpenWorldRecordingExecutor
        let directOriginFetcher: RecordingDirectOriginBodyFetcher
        let configuration: MCPOpenWorldTestConfiguration
        let client: MCPClientRecord
        var proxyPort: UInt16? = 9090
    }

    func testOpenWorldDeniedForMetadataOnly() async {
        let stack = try? makeStack(profile: .metadataOnly)
        guard let stack else { return XCTFail("stack setup failed") }
        do {
            _ = try await stack.openWorldService.handleTool(
                name: "execute_bookmark",
                arguments: ["bookmarkID": UUID().uuidString],
                client: stack.client,
                mcpSessionID: "s1"
            )
            XCTFail("expected denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
            XCTAssertTrue(stack.auditStore.events.contains { $0.kind == .openWorldDenied })
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCredentialStrippingOnExecutor() async throws {
        let executor = URLSessionBookmarkExecutor()
        // Unit-level: verify header classification helpers used by the executor.
        XCTAssertTrue(URLSessionBookmarkExecutor.credentialHeaderNames.contains("authorization"))
        XCTAssertTrue(URLSessionBookmarkExecutor.credentialHeaderNames.contains("cookie"))
        XCTAssertFalse(URLSessionBookmarkExecutor.transportExcludedHeaderNames.contains("authorization"))
        _ = executor
    }

    func testExecuteBookmarkRequiresApprovalThenStripsCredentials() async throws {
        let stack = try makeStack(profile: .shareable)
        let bookmark = Bookmark(
            name: "exec",
            request: sampleRequest(headers: [
                HTTPHeaderField(name: "Authorization", value: "Bearer secret"),
                HTTPHeaderField(name: "Cookie", value: "a=1")
            ])
        )
        try stack.bookmarkStore.saveBookmarks([bookmark])

        let args: [String: Any] = ["bookmarkID": bookmark.id.uuidString]
        do {
            _ = try await stack.openWorldService.handleTool(
                name: "execute_bookmark",
                arguments: args,
                client: stack.client,
                mcpSessionID: "s1"
            )
            XCTFail("expected approval")
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            var retry = args
            retry["approval"] = try authorizationDictionary(authorization)
            let result = try await stack.openWorldService.handleTool(
                name: "execute_bookmark",
                arguments: retry,
                client: stack.client,
                mcpSessionID: "s1"
            )
            XCTAssertEqual(result["destinationHost"] as? String, "api.example.com")
            XCTAssertEqual(stack.executor.lastStripCredentials, true)
            XCTAssertTrue(stack.auditStore.events.contains { $0.kind == .openWorldExecuted })
        }
    }

    // MARK: - Recapture session body (P3, memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6)

    private func makeSessionWithResponse(
        statusCode: Int = 200,
        bodyData: Data? = Data("truncated".utf8),
        bodyTruncated: Bool = true
    ) -> SessionRecord {
        SessionRecord(
            request: sampleRequest(),
            response: CapturedResponse(
                statusCode: statusCode,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: bodyData,
                bodySize: bodyData?.count,
                bodyTruncated: bodyTruncated
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }

    func testRecaptureSessionBodyRequiresApprovalThenBackfillsSessionBody() async throws {
        let stack = try makeStack(profile: .shareable)
        let session = makeSessionWithResponse()
        stack.sessionStore.append(session)

        let fullBody = Data(String(repeating: "x", count: 10_000).utf8)
        stack.directOriginFetcher.resultToReturn = DirectOriginFetchResult(
            bodyData: fullBody,
            statusCode: 200,
            bodyTruncatedAtCeiling: false
        )

        let args: [String: Any] = ["sessionID": session.id.uuidString]
        do {
            _ = try await stack.openWorldService.handleTool(
                name: "recapture_session_body",
                arguments: args,
                client: stack.client,
                mcpSessionID: "s1"
            )
            XCTFail("expected approval")
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            var retry = args
            retry["approval"] = try authorizationDictionary(authorization)
            let result = try await stack.openWorldService.handleTool(
                name: "recapture_session_body",
                arguments: retry,
                client: stack.client,
                mcpSessionID: "s1"
            )
            XCTAssertEqual(result["sessionID"] as? String, session.id.uuidString)
            XCTAssertEqual(result["recapturedBodyBytes"] as? Int, fullBody.count)
            XCTAssertEqual(result["truncatedAtCeiling"] as? Bool, false)
            XCTAssertEqual(result["includesCredentials"] as? Bool, false)

            // Defaults to stripping credentials, same as replay_request.
            XCTAssertEqual(stack.directOriginFetcher.lastIncludeCredentials, false)
            XCTAssertEqual(stack.directOriginFetcher.lastMaxBodyBytes, SessionBodyRecaptureBudget.maxBodyBytes)

            let updated = try XCTUnwrap(stack.sessionStore.sessions.first(where: { $0.id == session.id }))
            XCTAssertEqual(updated.response?.bodyData, fullBody)
            XCTAssertEqual(updated.response?.bodySize, fullBody.count)
            XCTAssertEqual(updated.response?.bodyTruncated, false)
            // Status code and headers are the ORIGINAL capture's, not the recapture fetch's — this
            // tool backfills the body only, not the whole response frame.
            XCTAssertEqual(updated.response?.statusCode, 200)
            XCTAssertEqual(updated.response?.headers.first?.name, "Content-Type")
            XCTAssertTrue(stack.auditStore.events.contains { $0.kind == .openWorldExecuted })
        }
    }

    func testRecaptureSessionBodyMarksTruncatedAtCeilingWhenFetchExceedsBudget() async throws {
        let stack = try makeStack(profile: .shareable)
        let session = makeSessionWithResponse()
        stack.sessionStore.append(session)
        stack.directOriginFetcher.resultToReturn = DirectOriginFetchResult(
            bodyData: Data(repeating: 0x41, count: SessionBodyRecaptureBudget.maxBodyBytes),
            statusCode: 200,
            bodyTruncatedAtCeiling: true
        )

        let args: [String: Any] = ["sessionID": session.id.uuidString]
        do {
            _ = try await stack.openWorldService.handleTool(
                name: "recapture_session_body", arguments: args, client: stack.client, mcpSessionID: "s1"
            )
            XCTFail("expected approval")
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            var retry = args
            retry["approval"] = try authorizationDictionary(authorization)
            let result = try await stack.openWorldService.handleTool(
                name: "recapture_session_body", arguments: retry, client: stack.client, mcpSessionID: "s1"
            )
            XCTAssertEqual(result["truncatedAtCeiling"] as? Bool, true)
            let updated = try XCTUnwrap(stack.sessionStore.sessions.first(where: { $0.id == session.id }))
            XCTAssertEqual(updated.response?.bodyTruncated, true)
        }
    }

    func testRecaptureSessionBodyRejectsUnknownSessionID() async throws {
        let stack = try makeStack(profile: .shareable)
        do {
            _ = try await stack.openWorldService.handleTool(
                name: "recapture_session_body",
                arguments: ["sessionID": UUID().uuidString],
                client: stack.client,
                mcpSessionID: "s1"
            )
            XCTFail("expected malformedRequest")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testRecaptureSessionBodyRejectsSessionWithNoResponse() async throws {
        let stack = try makeStack(profile: .shareable)
        let pendingSession = SessionRecord(
            request: sampleRequest(),
            response: nil,
            state: .pending,
            timing: SessionTiming(startedAt: Date())
        )
        stack.sessionStore.append(pendingSession)
        do {
            _ = try await stack.openWorldService.handleTool(
                name: "recapture_session_body",
                arguments: ["sessionID": pendingSession.id.uuidString],
                client: stack.client,
                mcpSessionID: "s1"
            )
            XCTFail("expected malformedRequest")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testRecaptureSessionBodyCanIncludeCredentialsWhenExplicitlyRequested() async throws {
        let stack = try makeStack(profile: .shareable)
        let session = makeSessionWithResponse()
        stack.sessionStore.append(session)

        let args: [String: Any] = ["sessionID": session.id.uuidString, "includeCredentials": true]
        do {
            _ = try await stack.openWorldService.handleTool(
                name: "recapture_session_body", arguments: args, client: stack.client, mcpSessionID: "s1"
            )
            XCTFail("expected approval")
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            var retry = args
            retry["approval"] = try authorizationDictionary(authorization)
            _ = try await stack.openWorldService.handleTool(
                name: "recapture_session_body", arguments: retry, client: stack.client, mcpSessionID: "s1"
            )
            XCTAssertEqual(stack.directOriginFetcher.lastIncludeCredentials, true)
        }
    }

    func testProxyNotRunningFailsClosed() async throws {
        let stack = try makeStack(profile: .shareable, proxyPort: nil)
        let bookmark = Bookmark(name: "exec", request: sampleRequest())
        try stack.bookmarkStore.saveBookmarks([bookmark])
        let args: [String: Any] = ["bookmarkID": bookmark.id.uuidString]
        do {
            _ = try await approvedCall(
                stack: stack,
                tool: "execute_bookmark",
                args: args
            )
            XCTFail("expected busy")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .busy)
        }
    }

    func testActivateMapRemoteEnablesRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledMapRemote(stack: stack)
        _ = try await approvedCall(
            stack: stack,
            tool: "activate_map_remote",
            args: ["overrideID": ruleID.uuidString]
        )
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(try XCTUnwrap(rules.first?.isEnabled))
        let decision = try await stack.responseOverrideStore.ruleDecision(for: sampleRequest(path: "/remote"))
        if case .mapRemote = decision {
            // expected
        } else {
            XCTFail("enabled map remote must match")
        }
        XCTAssertEqual(stack.journalStore.entries.last?.phase, .committed)
    }

    func testEnableRuleRejectsMapRemote() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledMapRemote(stack: stack)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_enable_rule",
                arguments: ["overrideID": ruleID.uuidString],
                client: stack.client
            )
            XCTFail("expected denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }

    func testActivateLiveRewriteEnablesRule() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledLiveRewrite(stack: stack)
        _ = try await approvedCall(
            stack: stack,
            tool: "activate_live_rewrite",
            args: ["overrideID": ruleID.uuidString]
        )
        let rules = await stack.responseOverrideStore.rules()
        XCTAssertTrue(try XCTUnwrap(rules.first?.isEnabled))
        let decision = try await stack.responseOverrideStore.ruleDecision(for: sampleRequest(path: "/live.json"))
        if case .liveResponseRewrite = decision {
            // expected
        } else {
            XCTFail("enabled live rewrite must match")
        }
        XCTAssertEqual(stack.journalStore.entries.last?.phase, .committed)
    }

    func testActivateWildcardAppendStringLiveRewriteReportsHonestScopeNoRawValueLeak() async throws {
        let stack = try makeStack(profile: .shareable)
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_live_rewrite",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/epg",
                "matchMode": "exactPath",
                "jsonPath": "$.channels[*].programs[*].title",
                "operation": "appendString",
                "overrideValue": ["type": "string", "value": "!"],
                "repeatPolicy": "ifMissingSuffix"
            ],
            client: stack.client
        )
        XCTAssertTrue((proposal["effectSummary"] as? String)?.contains("every value matched") ?? false)
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedMutationApply(stack: stack, tool: "apply_create_live_rewrite", args: ["proposalToken": token])
        let rules = await stack.responseOverrideStore.rules()
        let ruleID = try XCTUnwrap(rules.first(where: { $0.sourceKind == .liveResponseRewrite })?.id)

        let activateResult = try await approvedCall(
            stack: stack,
            tool: "activate_live_rewrite",
            args: ["overrideID": ruleID.uuidString]
        )
        let summary = try XCTUnwrap(activateResult["rewriteSummary"] as? String)
        XCTAssertTrue(summary.contains("appendString"))
        // The literal override value ("!") must never leak in the disclosed summary — only its
        // type/size/digest descriptor may appear (same raw-value-leak care as every other rewrite).
        XCTAssertFalse(summary.contains("\"!\""))

        let enabledRules = await stack.responseOverrideStore.rules()
        let enabledRule = try XCTUnwrap(enabledRules.first(where: { $0.id == ruleID }))
        XCTAssertEqual(enabledRule.liveResponseRewrites.first?.repeatPolicy, .ifMissingSuffix)
        XCTAssertEqual(enabledRule.liveResponseRewrites.first?.jsonPath, "$.channels[*].programs[*].title")
    }

    func testActivateRemovePropertyLiveRewriteSummaryHasNoDanglingLiteral() async throws {
        let stack = try makeStack(profile: .shareable)
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_live_rewrite",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/epg",
                "matchMode": "exactPath",
                "jsonPath": "$.channels[*].internalDebugField",
                "operation": "removeProperty"
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedMutationApply(stack: stack, tool: "apply_create_live_rewrite", args: ["proposalToken": token])
        let rules = await stack.responseOverrideStore.rules()
        let ruleID = try XCTUnwrap(rules.first(where: { $0.sourceKind == .liveResponseRewrite })?.id)

        let activateResult = try await approvedCall(
            stack: stack,
            tool: "activate_live_rewrite",
            args: ["overrideID": ruleID.uuidString]
        )
        let summary = try XCTUnwrap(activateResult["rewriteSummary"] as? String)
        XCTAssertEqual(summary, "$.channels[*].internalDebugField removeProperty")
    }

    func testProposeCreateLiveRewriteRejectsOverrideValueForRemoveProperty() async throws {
        let stack = try makeStack(profile: .shareable)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_create_live_rewrite",
                arguments: [
                    "method": "GET",
                    "host": "api.example.com",
                    "path": "/epg",
                    "matchMode": "exactPath",
                    "jsonPath": "$.channels[*].internalDebugField",
                    "operation": "removeProperty",
                    "overrideValue": ["type": "string", "value": "should not be here"]
                ],
                client: stack.client
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testActivateLiveRewriteRejectsNonLiveRewriteOverride() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledBlockRule(stack: stack)
        do {
            _ = try await approvedCall(
                stack: stack,
                tool: "activate_live_rewrite",
                args: ["overrideID": ruleID.uuidString]
            )
            XCTFail("expected malformed request")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testEnableRuleRejectsLiveResponseRewrite() async throws {
        let stack = try makeStack(profile: .shareable)
        let ruleID = try await createDisabledLiveRewrite(stack: stack)
        do {
            _ = try await stack.mutationService.handleTool(
                name: "propose_enable_rule",
                arguments: ["overrideID": ruleID.uuidString],
                client: stack.client
            )
            XCTFail("expected denial")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
    }

    func testActivateLiveRewriteExclusiveConflictWhenBlockEnabled() async throws {
        let stack = try makeStack(profile: .shareable)
        let blockRuleID = try await createDisabledBlockRule(stack: stack)
        _ = try await approvedMutationApply(
            stack: stack,
            tool: "apply_enable_rule",
            args: try await enableProposalArgs(stack: stack, overrideID: blockRuleID)
        )
        let liveRuleID = try await createDisabledLiveRewrite(stack: stack, path: "/blocked")
        do {
            _ = try await approvedCall(
                stack: stack,
                tool: "activate_live_rewrite",
                args: ["overrideID": liveRuleID.uuidString]
            )
            XCTFail("expected exclusive conflict")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .conflict)
        }
    }

    func testCaptureOnlyRejectsLiveMediaEngineAnalysis() async throws {
        let stack = try makeStack(profile: .shareable)
        let session = SessionRecord(
            request: sampleRequest(path: "/video.m3u8"),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
                bodyData: Data("#EXTM3U\n".utf8),
                bodySize: 8
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
        stack.sessionStore.append(session)
        do {
            _ = try stack.operationCoordinator.startMediaInspection(
                clientID: stack.client.id,
                mcpSessionID: "s1",
                sourceSessionID: session.id,
                analyses: [.liveMediaEngine],
                sampleTime: 0,
                argumentDigest: "digest",
                authorize: {}
            )
            XCTFail("capture-only must reject live analysis")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .policyDenied)
        }
        XCTAssertEqual(stack.trackingLiveProbe.probeCallCount, 0)
    }

    func testLiveProbeUsesLiveProbeServiceOnly() async throws {
        let stack = try makeStack(profile: .shareable)
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "cdn.example.com",
                port: 443,
                path: "/master.m3u8",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
                bodyData: Data("#EXTM3U\n".utf8),
                bodySize: 8
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
        stack.sessionStore.append(session)
        let result = try await approvedCall(
            stack: stack,
            tool: "live_media_probe_start",
            args: [
                "sessionID": session.id.uuidString,
                "analyses": [MCPMediaAnalysisKind.liveMediaEngine.rawValue]
            ]
        )
        let operationID = try XCTUnwrap(result["operationID"] as? String)
        // Probe runs on a coordinator Task — wait briefly for the live-probe service entry.
        var sawProbe = false
        for _ in 0..<50 {
            if stack.trackingLiveProbe.probeCallCount >= 1 {
                sawProbe = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawProbe, "live probe service must be invoked for operation \(operationID)")
        XCTAssertTrue(stack.auditStore.events.contains { $0.kind == .liveProbeStarted })
    }

    func testFabricatedApprovalNonceRejected() async throws {
        let stack = try makeStack(profile: .shareable)
        let bookmark = Bookmark(name: "exec", request: sampleRequest())
        try stack.bookmarkStore.saveBookmarks([bookmark])
        do {
            _ = try await stack.openWorldService.handleTool(
                name: "execute_bookmark",
                arguments: [
                    "bookmarkID": bookmark.id.uuidString,
                    "approval": [
                        "requestID": UUID().uuidString,
                        "clientID": stack.client.id,
                        "capability": MCPCapabilityID.executeBookmark.rawValue,
                        "argumentDigest": "forged",
                        "policyRevision": stack.client.assignedProfileID.rawValue,
                        "nonce": UUID().uuidString,
                        "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(120))
                    ]
                ],
                client: stack.client,
                mcpSessionID: "s1"
            )
            XCTFail("forged approval must not succeed")
        } catch let error as MCPStructuredError {
            // Missing grant record falls through to a new approval_required, or malformed — not success.
            XCTAssertTrue(
                error.code == .approvalRequired || error.code == .malformedRequest || error.code == .approvalReused
            )
        }
    }

    func testActivateMapRemoteViaHTTPToolCall() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-ow-http.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-ow-http.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-ow-http.json"))
        auditStore.load()
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "journal-ow-http.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let bookmarkStore = InMemoryBookmarkStore()
        let responseOverrideStore = ResponseOverrideStore()
        let sessionStore = InMemorySessionStore()
        let configuration = MCPOpenWorldTestConfiguration()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { policyStore.policyRevision }
        )
        let port = UInt16.random(in: 20_000...60_000)
        let controller = MCPServerController(
            sessionStore: sessionStore,
            port: port,
            credentialStore: credentialStore,
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            recoveryCoordinator: recoveryCoordinator,
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            scenarioStore: MCPScenarioStore(persistenceURL: temporaryURL(named: "scenarios-openworld.json")),
            responseDraftStore: ResponseDraftStore(persistenceURL: temporaryURL(named: "response-drafts-openworld.json")),
            fixtureRunStore: HLSFixtureRunStore(persistenceURL: temporaryURL(named: "hls-fixture-run-store-openworld.json"))
        )
        controller.configureMutationService(
            bookmarkStore: bookmarkStore,
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            configuration: configuration
        )
        let executor = OpenWorldRecordingExecutor()
        controller.configureOpenWorldService(
            bookmarkStore: bookmarkStore,
            sessionStore: sessionStore,
            responseOverrideStore: responseOverrideStore,
            bookmarkExecutor: executor,
            proposalCoordinator: proposalCoordinator,
            configuration: configuration,
            runningProxyPort: { 9090 }
        )
        await controller.start()
        guard case .running(_, let endpointURL) = controller.state else {
            throw XCTSkip("MCP server did not start")
        }
        let enrollment = try clientRegistry.enroll(displayName: "ow-http", assignedProfileID: .shareable)
        let sessionID = try await postInitialize(endpointURL: endpointURL, bearer: enrollment.plaintextCredential)

        let mutationService = try XCTUnwrap(controller.mutationService)
        let client = enrollment.client
        let stack = Stack(
            openWorldService: try XCTUnwrap(controller.openWorldService),
            mutationService: mutationService,
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            sessionStore: sessionStore,
            approvalStore: controller.approvalStore,
            auditStore: auditStore,
            journalStore: journalStore,
            operationCoordinator: controller.operationCoordinator,
            trackingLiveProbe: TrackingLiveProbeService(),
            executor: executor,
            directOriginFetcher: RecordingDirectOriginBodyFetcher(),
            configuration: configuration,
            client: client,
            proxyPort: 9090
        )
        let ruleID = try await createDisabledMapRemote(stack: stack)

        let proposeResponse = try await postToolCall(
            endpointURL: endpointURL,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            name: "activate_map_remote",
            arguments: ["overrideID": ruleID.uuidString]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: proposeResponse.body) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        let requestID = try XCTUnwrap(data["requestID"] as? String)
        let authorization = try controller.approvalStore.approve(requestID: requestID)
        let applyResponse = try await postToolCall(
            endpointURL: endpointURL,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            name: "activate_map_remote",
            arguments: [
                "overrideID": ruleID.uuidString,
                "approval": try authorizationDictionary(authorization)
            ]
        )
        XCTAssertEqual(applyResponse.statusCode, 200)
        let rules = await responseOverrideStore.rules()
        XCTAssertTrue(try XCTUnwrap(rules.first(where: { $0.id == ruleID })?.isEnabled))
        await controller.stop()
    }

    // MARK: - Helpers

    private func makeStack(
        profile: MCPDisclosureProfileID,
        proxyPort: UInt16? = 9090
    ) throws -> Stack {
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "journal-ow.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-ow.json"))
        policyStore.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-ow.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let bookmarkStore = InMemoryBookmarkStore()
        let responseOverrideStore = ResponseOverrideStore()
        let sessionStore = InMemorySessionStore()
        let configuration = MCPOpenWorldTestConfiguration()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { policyStore.policyRevision }
        )
        let trackingLiveProbe = TrackingLiveProbeService()
        let mediaService = MCPMediaInspectionService(sessionStore: sessionStore, snapshotService: MCPSessionSnapshotService(sessionStore: sessionStore))
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let operationCoordinator = MCPOperationCoordinator(
            sessionStore: sessionStore,
            mediaService: mediaService,
            snapshotService: snapshotService,
            policyStore: policyStore,
            auditStore: auditStore,
            liveProbeService: trackingLiveProbe
        )
        let executor = OpenWorldRecordingExecutor()
        let directOriginFetcher = RecordingDirectOriginBodyFetcher()
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
            throttleConfigurationWriter: { configuration.networkThrottleConfiguration = $0 }
        )
        var portBox = proxyPort
        let openWorldService = MCPOpenWorldService(
            bookmarkStore: bookmarkStore,
            sessionStore: sessionStore,
            responseOverrideStore: responseOverrideStore,
            bookmarkExecutor: executor,
            directOriginFetcher: directOriginFetcher,
            sessionMatcher: MCPExecutedSessionMatcher(sessionStore: sessionStore, matchTimeout: 0.05),
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            operationCoordinator: operationCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            auditStore: auditStore,
            runningProxyPort: { portBox },
            throttleConfigurationReader: { configuration.networkThrottleConfiguration }
        )
        let client = MCPClientRecord(
            id: "client-ow-test",
            displayName: "ow-test",
            assignedProfileID: profile,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        _ = portBox
        return Stack(
            openWorldService: openWorldService,
            mutationService: mutationService,
            responseOverrideStore: responseOverrideStore,
            bookmarkStore: bookmarkStore,
            sessionStore: sessionStore,
            approvalStore: approvalStore,
            auditStore: auditStore,
            journalStore: journalStore,
            operationCoordinator: operationCoordinator,
            trackingLiveProbe: trackingLiveProbe,
            executor: executor,
            directOriginFetcher: directOriginFetcher,
            configuration: configuration,
            client: client,
            proxyPort: proxyPort
        )
    }

    private func createDisabledMapRemote(stack: Stack) async throws -> UUID {
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_map_remote",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/remote",
                "matchMode": "exactPath",
                "remoteHost": "origin.example.com",
                "remoteScheme": "https",
                "remotePort": 443
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedMutationApply(stack: stack, tool: "apply_create_map_remote", args: ["proposalToken": token])
        let rules = await stack.responseOverrideStore.rules()
        return try XCTUnwrap(rules.first?.id)
    }

    private func createDisabledLiveRewrite(stack: Stack, path: String = "/live.json") async throws -> UUID {
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_live_rewrite",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": path,
                "matchMode": "exactPath",
                "jsonPath": "$.flag",
                "overrideValue": ["type": "bool", "value": true]
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedMutationApply(stack: stack, tool: "apply_create_live_rewrite", args: ["proposalToken": token])
        let rules = await stack.responseOverrideStore.rules()
        return try XCTUnwrap(rules.first(where: { $0.sourceKind == .liveResponseRewrite })?.id)
    }

    private func enableProposalArgs(stack: Stack, overrideID: UUID) async throws -> [String: Any] {
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: ["overrideID": overrideID.uuidString],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        return ["proposalToken": token]
    }

    private func createDisabledBlockRule(stack: Stack) async throws -> UUID {
        let proposal = try await stack.mutationService.handleTool(
            name: "propose_create_block",
            arguments: [
                "method": "GET",
                "host": "api.example.com",
                "path": "/blocked",
                "matchMode": "exactPath",
                "statusCode": 503
            ],
            client: stack.client
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedMutationApply(stack: stack, tool: "apply_create_block", args: ["proposalToken": token])
        let rules = await stack.responseOverrideStore.rules()
        return try XCTUnwrap(rules.first?.id)
    }

    private func approvedCall(stack: Stack, tool: String, args: [String: Any]) async throws -> [String: Any] {
        do {
            return try await stack.openWorldService.handleTool(
                name: tool,
                arguments: args,
                client: stack.client,
                mcpSessionID: "s1"
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try stack.approvalStore.approve(requestID: requestID)
            var retry = args
            retry["approval"] = try authorizationDictionary(authorization)
            return try await stack.openWorldService.handleTool(
                name: tool,
                arguments: retry,
                client: stack.client,
                mcpSessionID: "s1"
            )
        }
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

    private func authorizationDictionary(_ authorization: MCPApprovalAuthorization) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(authorization)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPStructuredError(code: .internalFailure, message: "authorization encoding failed")
        }
        return object
    }

    private func sampleRequest(
        path: String = "/test",
        headers: [HTTPHeaderField] = []
    ) -> CapturedRequest {
        CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: headers,
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
        let sessionID = try XCTUnwrap(
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        )
        var initializedRequest = URLRequest(url: endpointURL)
        initializedRequest.httpMethod = "POST"
        initializedRequest.httpBody = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        initializedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initializedRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        initializedRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        initializedRequest.setValue("2025-11-25", forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader)
        initializedRequest.setValue(sessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        _ = try await URLSession.shared.data(for: initializedRequest)
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
            "params": ["name": name, "arguments": arguments]
        ]
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-11-25", forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader)
        request.setValue(sessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        let (data, response) = try await URLSession.shared.data(for: request)
        return RawHTTPResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

@MainActor
final class OpenWorldRecordingExecutor: BookmarkExecuting {
    private(set) var lastStripCredentials: Bool?
    func execute(
        bookmark: Bookmark,
        proxyPort: UInt16,
        stripCredentials: Bool
    ) async throws -> BookmarkExecutionResult {
        lastStripCredentials = stripCredentials
        return BookmarkExecutionResult(startedAt: Date())
    }
}

@MainActor
final class RecordingDirectOriginBodyFetcher: DirectOriginBodyFetching {
    private(set) var lastIncludeCredentials: Bool?
    private(set) var lastMaxBodyBytes: Int?
    private(set) var lastRequest: CapturedRequest?
    var resultToReturn: DirectOriginFetchResult = DirectOriginFetchResult(
        bodyData: Data("{}".utf8),
        statusCode: 200,
        bodyTruncatedAtCeiling: false
    )
    var errorToThrow: DirectOriginFetchError?

    func fetch(
        request: CapturedRequest,
        includeCredentials: Bool,
        maxBodyBytes: Int
    ) async throws -> DirectOriginFetchResult {
        lastRequest = request
        lastIncludeCredentials = includeCredentials
        lastMaxBodyBytes = maxBodyBytes
        if let errorToThrow {
            throw errorToThrow
        }
        return resultToReturn
    }
}

@MainActor
final class TrackingLiveProbeService: MCPLiveProbeServicing {
    private(set) var probeCallCount = 0
    func probe(
        sessionID: SessionRecord.ID,
        liveURL: URL,
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        captureEpoch: MCPCaptureEpoch,
        progress: @MainActor (Double, String) -> Void
    ) async throws -> MCPMediaInspectionResultDTO {
        probeCallCount += 1
        progress(1, "complete")
        return MCPMediaInspectionResultDTO(
            sessionID: sessionID.uuidString,
            analyses: [.liveMediaEngine],
            binaryStructure: nil,
            gop: nil,
            id3: nil,
            mediaEngine: MCPMediaEngineInspectionDTO(
                partial: false,
                durationSeconds: 1,
                playable: true,
                exportable: false,
                protectedContent: false,
                preciseTiming: true,
                variantCount: 0,
                videoTrackCount: 0,
                audioTrackCount: 0,
                subtitleTrackCount: 0,
                variants: [],
                videoTracks: [],
                audioTracks: [],
                subtitleLanguages: [],
                mediaSelectionLanguages: [],
                player: nil,
                decodedFrame: nil,
                stages: [],
                warnings: []
            ),
            diagnostics: [],
            warnings: [],
            disclosure: MCPMediaDisclosureContextDTO(
                captureEpoch: captureEpoch,
                policyRevision: policyRevision,
                generatedAt: Date(),
                removedFields: [],
                partialResultReason: nil,
                truncated: false
            )
        )
    }
}

@MainActor
private final class MCPOpenWorldTestConfiguration: AppConfiguration {
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
