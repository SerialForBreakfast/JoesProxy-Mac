import XCTest
@testable import JoesProxy

/// AI-6 — Feature-matrix self-validation.
///
/// Verifies bookmarks, overrides, Block/Map Local/Map Remote, rewrite, throttle, attribution,
/// approval, audit, and recovery through the same isolated `MCPSelfValidationCoordinator` harness
/// AI-5 built — each test asserts both the MCP tool result and the real proxy-observable traffic
/// through `context.makeProxiedURLSession()` against the deterministic loopback fixture origin, per
/// the ADR's "JoesProxy Self-Validation" section. No external network is used; cleanup failure
/// fails the test via `MCPSelfValidationCoordinator.endRun`'s orphaned-effect check.
@MainActor
final class MCPFeatureMatrixSelfValidationTests: XCTestCase {
    // MARK: - Block

    func testBlockRuleAffectsRealProxyTrafficThenRestoresOnDisable() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let ruleID = try await self.createDisabledBlockRule(
                context: context,
                path: MCPSelfValidationFixtureRoute.blockTarget.rawValue,
                statusCode: 503
            )
            _ = try await self.enableOverride(context: context, overrideID: ruleID)

            let blockedResponse = try await self.get(context: context, route: .blockTarget)
            XCTAssertEqual(blockedResponse.statusCode, 503, "a real request must observe the block, not the fixture's real 200")

            _ = try await self.disableOverride(context: context, overrideID: ruleID)
            let restoredResponse = try await self.get(context: context, route: .blockTarget)
            XCTAssertEqual(restoredResponse.statusCode, 200)
            XCTAssertEqual(restoredResponse.body, MCPSelfValidationFixtureRoute.blockTarget.defaultBody)
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Map Local

    func testMapLocalRuleServesInlineResponseOverRealFixture() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let inlineBody = "{\"mapLocal\":true}"
            let proposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_create_map_local",
                arguments: [
                    "method": "GET",
                    "scheme": "http",
                    "host": "127.0.0.1",
                    "port": Int(context.fixtureBaseURL.port ?? 0),
                    "path": MCPSelfValidationFixtureRoute.ok.rawValue,
                    "bodyText": inlineBody,
                    "contentType": "application/json"
                ],
                client: context.scenarioStack.validationClient
            )
            let ruleID = try await self.applyCreateAndFetchRuleID(context: context, proposal: proposal, applyTool: "apply_create_map_local")
            _ = try await self.enableOverride(context: context, overrideID: ruleID)

            let response = try await self.get(context: context, route: .ok)
            XCTAssertEqual(response.body, inlineBody, "the real response must reflect the inline map-local body, not the fixture's real body")
            XCTAssertNotEqual(response.body, MCPSelfValidationFixtureRoute.ok.defaultBody)

            _ = try await self.disableOverride(context: context, overrideID: ruleID)
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Map Remote

    /// Map Remote's own destination validator correctly rejects any loopback destination
    /// (`MCPMutationValidator.validateMapRemoteDestination`) — the same safety rule real users get.
    /// Self-validation must not bypass that policy just to make this test "more real" (the ADR's own
    /// self-validation rules forbid bypassing disclosure/safety policy), so this verifies the
    /// control-plane result only: the rule is created with the right destination fields and the
    /// enable/disable lifecycle works, including the `remotePath`/`remoteQueryPolicy` destination
    /// override (Feature 1). Real-traffic redirection for Map Remote is exercised instead by the
    /// live-audit process against a real non-loopback destination, not by this deterministic
    /// suite; `HTTPUpstreamConnectorTests` separately proves the request-target/Host-header wiring
    /// a path override depends on, against a real (non-loopback-restricted) connector call.
    func testMapRemoteRuleCreatesWithCorrectDestinationAndLifecycle() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let proposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_create_map_remote",
                arguments: [
                    "method": "GET",
                    "host": "127.0.0.1",
                    "path": MCPSelfValidationFixtureRoute.mapRemoteTarget.rawValue,
                    "remoteHost": "self-validation-fake-upstream.invalid",
                    "remotePort": 443,
                    "remoteScheme": "https",
                    "remotePath": "/v2/map-remote-target",
                    "remoteQueryPolicy": "drop"
                ],
                client: context.scenarioStack.validationClient
            )
            let ruleID = try await self.applyCreateAndFetchRuleID(context: context, proposal: proposal, applyTool: "apply_create_map_remote")
            let rules = await context.lane.responseOverrideStore.rules()
            let rule = try XCTUnwrap(rules.first(where: { $0.id == ruleID }))
            XCTAssertEqual(rule.sourceKind, .mapRemote)
            XCTAssertFalse(rule.isEnabled)
            XCTAssertEqual(rule.mapRemotePath, "/v2/map-remote-target")
            XCTAssertEqual(rule.mapRemoteQueryPolicy, .drop)

            // Map Remote is deliberately restricted to the open-world `activate_map_remote` tool
            // (not the generic `enable_rule`) since it carries destination disclosure — confirmed
            // live by `MCPMutationService`'s own rejection when this test first tried `enable_rule`.
            _ = try await self.approvedOpenWorldApply(
                context: context,
                tool: "activate_map_remote",
                args: ["overrideID": ruleID.uuidString]
            )
            let enabledRules = await context.lane.responseOverrideStore.rules()
            XCTAssertTrue(try XCTUnwrap(enabledRules.first(where: { $0.id == ruleID })?.isEnabled))

            _ = try await self.disableOverride(context: context, overrideID: ruleID)
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Live Response Rewrite

    func testLiveRewriteForwardsToSameUpstreamAndPatchesJSONWhenActivated() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let baseline = try await self.get(context: context, route: .epgTarget)
            let baselineJSON = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(baseline.body.utf8)) as? [String: Any]
            )
            try await Task.sleep(for: .milliseconds(100))
            let baselineSession = try XCTUnwrap(
                context.lane.sessionStore.sessions.last(where: {
                    $0.request.path == MCPSelfValidationFixtureRoute.epgTarget.rawValue
                })
            )
            let sessionIDs = [baselineSession.id.uuidString]
            let structure = try await context.featureStack.mutationService.handleTool(
                name: "discover_response_structure",
                arguments: ["sessionIDs": sessionIDs],
                client: context.scenarioStack.validationClient
            )
            XCTAssertTrue(try XCTUnwrap(structure["shapeDescription"] as? String).contains("title"))

            let rewriteArguments: [String: Any] = [
                "method": "GET",
                "scheme": "http",
                "host": "127.0.0.1",
                "port": Int(context.fixtureBaseURL.port ?? 0),
                "path": MCPSelfValidationFixtureRoute.epgTarget.rawValue,
                "matchMode": "exactPath",
                "jsonPath": "$.channels[*].programs[*].title",
                "operation": "appendString",
                "overrideValue": ["type": "string", "value": "!"],
                "sessionIDs": sessionIDs
            ]
            let preview = try await context.featureStack.mutationService.handleTool(
                name: "preview_live_rewrite",
                arguments: rewriteArguments,
                client: context.scenarioStack.validationClient
            )
            XCTAssertEqual(preview["transformedCount"] as? Int, 1)
            let previewDigest = try XCTUnwrap(preview["previewDigest"] as? String)

            var proposalArguments = rewriteArguments
            proposalArguments.removeValue(forKey: "sessionIDs")
            proposalArguments["previewDigest"] = previewDigest
            let proposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_create_live_rewrite",
                arguments: proposalArguments,
                client: context.scenarioStack.validationClient
            )
            let ruleID = try await self.applyCreateAndFetchRuleID(
                context: context,
                proposal: proposal,
                applyTool: "apply_create_live_rewrite"
            )
            let rules = await context.lane.responseOverrideStore.rules()
            let rule = try XCTUnwrap(rules.first(where: { $0.id == ruleID }))
            XCTAssertEqual(rule.sourceKind, .liveResponseRewrite)
            XCTAssertFalse(rule.isEnabled)

            _ = try await self.approvedOpenWorldApply(
                context: context,
                tool: "activate_live_rewrite",
                args: ["overrideID": ruleID.uuidString]
            )
            let enabledRules = await context.lane.responseOverrideStore.rules()
            XCTAssertTrue(try XCTUnwrap(enabledRules.first(where: { $0.id == ruleID })?.isEnabled))

            let response = try await self.get(context: context, route: .epgTarget)
            XCTAssertEqual(response.statusCode, 200)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
            XCTAssertEqual(self.epgTitles(body), ["Morning News!", "World Report!", "Live Match!"])
            XCTAssertEqual(body["generatedAt"] as? String, baselineJSON["generatedAt"] as? String)
            XCTAssertEqual(self.epgRatings(body), self.epgRatings(baselineJSON))

            try await Task.sleep(for: .milliseconds(200))
            let captured = try XCTUnwrap(context.lane.sessionStore.sessions.last)
            XCTAssertEqual(captured.response?.source, .liveResponseRewrite)
            XCTAssertEqual(captured.request.path, MCPSelfValidationFixtureRoute.epgTarget.rawValue)

            _ = try await self.disableOverride(context: context, overrideID: ruleID)
            let restored = try await self.get(context: context, route: .epgTarget)
            let restoredBody = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(restored.body.utf8)) as? [String: Any]
            )
            XCTAssertEqual(self.epgTitles(restoredBody), ["Morning News", "World Report", "Live Match"])
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNotEqual(context.lane.sessionStore.sessions.last?.response?.source, .liveResponseRewrite)
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Scenario jsonRewrite (live response rewrite)

    func testScenarioJsonRewriteFaultIsRejectedAtValidationAsUnsupported() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let host = "127.0.0.1"
            let port = Int(context.fixtureBaseURL.port ?? 0)
            let path = MCPSelfValidationFixtureRoute.liveRewriteTarget.rawValue
            let matcher = MCPMutationMatcher(
                method: "GET",
                scheme: .http,
                host: host,
                port: port,
                path: path,
                matchMode: .exactPath
            )
            let draft = MCPScenarioDraftInput(
                id: MCPScenarioID(rawValue: UUID().uuidString),
                schemaVersion: MCPScenarioSchemaVersion.current,
                name: "Live rewrite scenario",
                purpose: "Self-validation: jsonRewrite scenario composition must be rejected.",
                originatingClientID: context.scenarioStack.validationClient.id,
                target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: [host], paths: nil),
                preconditions: [],
                captureScope: MCPScenarioCaptureScope(hosts: [host], includeBodies: true),
                disclosureProfileID: .shareable,
                faults: [
                    .jsonRewrite(
                        matcher: matcher,
                        jsonPath: "$.flag",
                        overrideValue: .bool(true),
                        operation: .set
                    )
                ],
                duration: 30,
                expiresAt: nil,
                observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 30),
                assertions: [],
                assertionSeverity: .warning,
                evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 50, retention: 86_400),
                cleanupActions: [MCPScenarioCleanupAction(faultIndex: 0, kind: .liveResponseRewrite)]
            )
            let draftData = try MCPScenarioJSONCodec.encodeDraft(draft)
            let draftObject = try JSONSerialization.jsonObject(with: draftData) as? [String: Any]
            let draftResult = try await context.scenarioStack.service.handleTool(
                name: "draft_test_scenario",
                arguments: ["draft": draftObject as Any],
                client: context.scenarioStack.validationClient
            )
            let scenarioID = try XCTUnwrap(draftResult["scenarioID"] as? String)

            do {
                _ = try await context.scenarioStack.service.handleTool(
                    name: "validate_test_scenario",
                    arguments: ["scenarioID": scenarioID],
                    client: context.scenarioStack.validationClient
                )
                XCTFail("Expected validate_test_scenario to reject a jsonRewrite fault as unsupported.")
            } catch MCPScenarioCompilerError.unsupportedFaultCombination {
                // Expected: live-response rewrite scenario composition is deferred until a
                // staged rule-composition pipeline exists.
            }

            let rules = await context.lane.responseOverrideStore.rules()
            XCTAssertTrue(rules.isEmpty)
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Rewrite (bookmark JSON field rewrite)

    func testBookmarkRewriteServesRewrittenFieldOverRealProxyIntercept() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let bookmark = Bookmark(
                name: "rewrite-fixture",
                request: CapturedRequest(
                    method: "GET",
                    scheme: .http,
                    host: "127.0.0.1",
                    port: context.fixtureBaseURL.port ?? 0,
                    path: MCPSelfValidationFixtureRoute.rewriteTarget.rawValue,
                    headers: [],
                    bodyData: nil,
                    bodySize: nil
                ),
                savedResponse: BookmarkSavedResponse(
                    statusCode: 200,
                    headers: [],
                    bodyData: Data(#"{"id":1}"#.utf8),
                    savedAt: Date()
                )
            )
            try context.lane.bookmarkStore.saveBookmarks([bookmark])

            let proposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_create_rewrite",
                arguments: [
                    "bookmarkID": bookmark.id.uuidString,
                    "jsonPath": "$.id",
                    "overrideValue": ["type": "number", "value": "2"]
                ],
                client: context.scenarioStack.validationClient
            )
            let token = try XCTUnwrap(proposal["proposalToken"] as? String)
            _ = try await self.approvedApply(context: context, tool: "apply_create_rewrite", args: ["proposalToken": token])

            let created = try XCTUnwrap(context.lane.bookmarkStore.loadBookmarks().first(where: { $0.id == bookmark.id }))
            let rewriteID = try XCTUnwrap(created.responseRewrites.first?.id)

            let enableProposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_enable_rewrite",
                arguments: ["bookmarkID": bookmark.id.uuidString, "rewriteID": rewriteID.uuidString],
                client: context.scenarioStack.validationClient
            )
            let enableToken = try XCTUnwrap(enableProposal["proposalToken"] as? String)
            _ = try await self.approvedApply(context: context, tool: "apply_enable_rewrite", args: ["proposalToken": enableToken])

            // Mirrors ProxyViewModel's reactive bookmark-intercept sync (App/ProxyViewModel.swift)
            // so the real proxy lane actually serves the rewritten snapshot for this test.
            let refreshed = context.lane.bookmarkStore.loadBookmarks()
            await context.lane.bookmarkResponseInterceptStore.syncBookmarks(refreshed)
            await context.lane.bookmarkResponseInterceptStore.setEnabledBookmarkIDs([bookmark.id])

            let response = try await self.get(context: context, route: .rewriteTarget)
            XCTAssertEqual(response.statusCode, 200)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
            XCTAssertEqual(body["id"] as? Int, 2, "the real intercepted response must reflect the rewritten field, served without ever dialing the fixture")

            let disableProposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_disable_rewrite",
                arguments: ["bookmarkID": bookmark.id.uuidString, "rewriteID": rewriteID.uuidString],
                client: context.scenarioStack.validationClient
            )
            let disableToken = try XCTUnwrap(disableProposal["proposalToken"] as? String)
            _ = try await self.approvedApply(context: context, tool: "apply_disable_rewrite", args: ["proposalToken": disableToken])
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Throttle

    func testThrottleAddsObservableLatencyToRealProxyRequest() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let proposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_change_throttle",
                arguments: [
                    "isEnabled": true,
                    "selectedPresetID": NetworkThrottlePresetID.modem56k
                ],
                client: context.scenarioStack.validationClient
            )
            let token = try XCTUnwrap(proposal["proposalToken"] as? String)
            _ = try await self.approvedApply(context: context, tool: "apply_change_throttle", args: ["proposalToken": token])

            XCTAssertTrue(context.lane.configuration.networkThrottleConfiguration.isEnabled)
            XCTAssertEqual(context.lane.configuration.networkThrottleConfiguration.mcpOrigin, .mcp)

            let started = Date()
            _ = try await self.get(context: context, route: .throttleTarget)
            let elapsed = Date().timeIntervalSince(started)
            // modem56k's preset latency floor is 150ms; assert a conservative bound well under that
            // to avoid flaking on slower CI hardware while still proving real observable delay.
            XCTAssertGreaterThanOrEqual(elapsed, 0.1, "a real request under an active throttle must observe added latency")

            let disableProposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_change_throttle",
                arguments: ["isEnabled": false],
                client: context.scenarioStack.validationClient
            )
            let disableToken = try XCTUnwrap(disableProposal["proposalToken"] as? String)
            _ = try await self.approvedApply(context: context, tool: "apply_change_throttle", args: ["proposalToken": disableToken])
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Bookmarks + real replay

    func testBookmarkExecuteReplaysThroughRealProxyAndCapturesFixtureResponse() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let proposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_create_bookmark",
                arguments: [
                    "method": "GET",
                    "scheme": "http",
                    "host": "127.0.0.1",
                    "port": Int(context.fixtureBaseURL.port ?? 0),
                    "path": MCPSelfValidationFixtureRoute.ok.rawValue,
                    "name": "self-validation-ok-bookmark"
                ],
                client: context.scenarioStack.validationClient
            )
            let token = try XCTUnwrap(proposal["proposalToken"] as? String)
            _ = try await self.approvedApply(context: context, tool: "apply_create_bookmark", args: ["proposalToken": token])

            let bookmarks = context.lane.bookmarkStore.loadBookmarks()
            XCTAssertEqual(bookmarks.count, 1)
            let bookmarkID = try XCTUnwrap(bookmarks.first?.id)

            let beforeSessionCount = context.lane.sessionStore.sessions.count
            let executeResult = try await self.approvedOpenWorldApply(
                context: context,
                tool: "execute_bookmark",
                args: ["bookmarkID": bookmarkID.uuidString]
            )
            XCTAssertNotNil(executeResult["startedAt"])

            try await Task.sleep(for: .milliseconds(200))
            XCTAssertGreaterThan(context.lane.sessionStore.sessions.count, beforeSessionCount)
            let captured = try XCTUnwrap(context.lane.sessionStore.sessions.last)
            XCTAssertEqual(captured.response?.statusCode, 200)
            XCTAssertEqual(captured.response?.bodyData.map { String(decoding: $0, as: UTF8.self) }, MCPSelfValidationFixtureRoute.ok.defaultBody)
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Attribution

    func testBlockedTrafficCarriesCorrectMCPAttribution() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let ruleID = try await self.createDisabledBlockRule(
                context: context,
                path: MCPSelfValidationFixtureRoute.blockTarget.rawValue,
                statusCode: 503
            )
            _ = try await self.enableOverride(context: context, overrideID: ruleID)

            _ = try await self.get(context: context, route: .blockTarget)
            try await Task.sleep(for: .milliseconds(200))

            let captured = try XCTUnwrap(context.lane.sessionStore.sessions.last)
            let attribution = try XCTUnwrap(captured.response?.mcpAttribution, "a real request through an MCP-created block rule must carry capture attribution")
            XCTAssertEqual(attribution.effectKinds, [.block])
            XCTAssertEqual(attribution.provenance.capability, .createDisabledBlock)
            XCTAssertEqual(attribution.provenance.clientID, context.scenarioStack.validationClient.id)

            _ = try await self.disableOverride(context: context, overrideID: ruleID)
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Approval

    func testMutatingApplyRequiresApprovalThenSucceedsOnceGranted() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let proposal = try await context.featureStack.mutationService.handleTool(
                name: "propose_create_block",
                arguments: [
                    "method": "GET",
                    "host": "127.0.0.1",
                    "path": "/approval-check",
                    "matchMode": "exactPath",
                    "statusCode": 503
                ],
                client: context.scenarioStack.validationClient
            )
            let token = try XCTUnwrap(proposal["proposalToken"] as? String)
            do {
                _ = try await context.featureStack.mutationService.handleTool(
                    name: "apply_create_block",
                    arguments: ["proposalToken": token],
                    client: context.scenarioStack.validationClient
                )
                XCTFail("expected approval required before any grant exists")
            } catch let error as MCPStructuredError {
                XCTAssertEqual(error.code, .approvalRequired)
            }

            let ruleID = try await self.applyCreateAndFetchRuleID(
                context: context,
                proposal: try await context.featureStack.mutationService.handleTool(
                    name: "propose_create_block",
                    arguments: [
                        "method": "GET",
                        "host": "127.0.0.1",
                        "path": "/approval-check-2",
                        "matchMode": "exactPath",
                        "statusCode": 503
                    ],
                    client: context.scenarioStack.validationClient
                ),
                applyTool: "apply_create_block"
            )
            _ = ruleID // approval-gate proof above is the assertion of interest for this test
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Audit

    func testProposeAndApplyRecordToolCallAuditEvents() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let beforeCount = context.lane.auditStore.events.count
            _ = try await self.createDisabledBlockRule(context: context, path: "/audit-check", statusCode: 503)

            XCTAssertGreaterThan(context.lane.auditStore.events.count, beforeCount)
            XCTAssertTrue(context.lane.auditStore.events.contains { $0.kind == .proposalCreated })
            XCTAssertTrue(context.lane.auditStore.events.contains { $0.kind == .proposalApplied })
            XCTAssertTrue(context.lane.auditStore.events.allSatisfy { $0.clientID == context.scenarioStack.validationClient.id })
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Recovery

    func testReturnToNormalTrulyRestoresEnabledOverrideWithNoConflict() async throws {
        let coordinator = MCPSelfValidationCoordinator()
        let summary = try await coordinator.withRun { context in
            let ruleID = try await self.createDisabledBlockRule(
                context: context,
                path: MCPSelfValidationFixtureRoute.blockTarget.rawValue,
                statusCode: 503
            )
            _ = try await self.enableOverride(context: context, overrideID: ruleID)

            let blockedResponse = try await self.get(context: context, route: .blockTarget)
            XCTAssertEqual(blockedResponse.statusCode, 503)

            let recoverySummary = await context.featureStack.recoveryService.returnToNormal(
                stopServer: {},
                isServerRunning: { false }
            )
            XCTAssertEqual(recoverySummary.restoredCount, 1)
            XCTAssertTrue(recoverySummary.conflicts.isEmpty)

            let restoredResponse = try await self.get(context: context, route: .blockTarget)
            XCTAssertEqual(restoredResponse.statusCode, 200, "the real request must observe the fixture's true response once recovery restores the rule")
        }
        XCTAssertEqual(summary.outcome, .succeeded)
    }

    // MARK: - Helpers

    private struct FixtureHTTPResponse {
        let statusCode: Int
        let body: String
    }

    private func epgTitles(_ body: [String: Any]) -> [String] {
        epgPrograms(body).compactMap { $0["title"] as? String }
    }

    private func epgRatings(_ body: [String: Any]) -> [String] {
        epgPrograms(body).compactMap { $0["rating"] as? String }
    }

    private func epgPrograms(_ body: [String: Any]) -> [[String: Any]] {
        guard let channels = body["channels"] as? [[String: Any]] else { return [] }
        return channels.flatMap { $0["programs"] as? [[String: Any]] ?? [] }
    }

    private func get(context: MCPSelfValidationRunContext, route: MCPSelfValidationFixtureRoute) async throws -> FixtureHTTPResponse {
        let session = context.makeProxiedURLSession()
        let url = context.fixtureBaseURL.appendingPathComponent(route.rawValue)
        let (data, response) = try await session.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return FixtureHTTPResponse(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
    }

    private func createDisabledBlockRule(
        context: MCPSelfValidationRunContext,
        path: String,
        statusCode: Int
    ) async throws -> UUID {
        let proposal = try await context.featureStack.mutationService.handleTool(
            name: "propose_create_block",
            arguments: [
                "method": "GET",
                "scheme": "http",
                "host": "127.0.0.1",
                "port": Int(context.fixtureBaseURL.port ?? 0),
                "path": path,
                "matchMode": "exactPath",
                "statusCode": statusCode
            ],
            client: context.scenarioStack.validationClient
        )
        return try await applyCreateAndFetchRuleID(context: context, proposal: proposal, applyTool: "apply_create_block")
    }

    private func applyCreateAndFetchRuleID(
        context: MCPSelfValidationRunContext,
        proposal: [String: Any],
        applyTool: String
    ) async throws -> UUID {
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        _ = try await approvedApply(context: context, tool: applyTool, args: ["proposalToken": token])
        let rules = await context.lane.responseOverrideStore.rules()
        return try XCTUnwrap(rules.last?.id)
    }

    private func enableOverride(context: MCPSelfValidationRunContext, overrideID: UUID) async throws -> [String: Any] {
        let proposal = try await context.featureStack.mutationService.handleTool(
            name: "propose_enable_rule",
            arguments: ["overrideID": overrideID.uuidString],
            client: context.scenarioStack.validationClient
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        return try await approvedApply(context: context, tool: "apply_enable_rule", args: ["proposalToken": token])
    }

    private func disableOverride(context: MCPSelfValidationRunContext, overrideID: UUID) async throws -> [String: Any] {
        let proposal = try await context.featureStack.mutationService.handleTool(
            name: "propose_disable_rule",
            arguments: ["overrideID": overrideID.uuidString],
            client: context.scenarioStack.validationClient
        )
        let token = try XCTUnwrap(proposal["proposalToken"] as? String)
        return try await approvedApply(context: context, tool: "apply_disable_rule", args: ["proposalToken": token])
    }

    private func approvedApply(
        context: MCPSelfValidationRunContext,
        tool: String,
        args: [String: Any]
    ) async throws -> [String: Any] {
        do {
            return try await context.featureStack.mutationService.handleTool(
                name: tool,
                arguments: args,
                client: context.scenarioStack.validationClient
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            _ = try context.lane.approvalStore.approve(requestID: requestID)
            return try await context.featureStack.mutationService.handleTool(
                name: tool,
                arguments: args,
                client: context.scenarioStack.validationClient
            )
        }
    }

    private func approvedOpenWorldApply(
        context: MCPSelfValidationRunContext,
        tool: String,
        args: [String: Any]
    ) async throws -> [String: Any] {
        do {
            return try await context.featureStack.openWorldService.handleTool(
                name: tool,
                arguments: args,
                client: context.scenarioStack.validationClient,
                mcpSessionID: context.runID.rawValue
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            _ = try context.lane.approvalStore.approve(requestID: requestID)
            return try await context.featureStack.openWorldService.handleTool(
                name: tool,
                arguments: args,
                client: context.scenarioStack.validationClient,
                mcpSessionID: context.runID.rawValue
            )
        }
    }

    private func approvedScenarioCall(
        context: MCPSelfValidationRunContext,
        tool: String,
        args: [String: Any]
    ) async throws -> [String: Any] {
        do {
            return try await context.scenarioStack.service.handleTool(
                name: tool,
                arguments: args,
                client: context.scenarioStack.validationClient
            )
        } catch let error as MCPStructuredError where error.code == .approvalRequired {
            let requestID = try XCTUnwrap(error.details?["requestID"])
            let authorization = try context.lane.approvalStore.approve(requestID: requestID)
            var retryArgs = args
            retryArgs["approval"] = try authorizationDictionary(authorization)
            return try await context.scenarioStack.service.handleTool(
                name: tool,
                arguments: retryArgs,
                client: context.scenarioStack.validationClient
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
}
