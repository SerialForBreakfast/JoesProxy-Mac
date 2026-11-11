import XCTest
@testable import JoesProxy

/// Covers `capture_activity_since_marker` — the ceremony-free "new requests since a marker, did
/// rule X get hit" composition added per the 1.7.0 field-session feedback (memlog/Research/
/// Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6, P0). Deliberately a small, self-contained
/// stack (not `MCPMutationToolsTests`'s shared `makeStack`) since this tool needs a real,
/// snapshot-indexed `SessionStore` that most mutation tests don't.
@MainActor
final class MCPCaptureActivitySinceMarkerTests: XCTestCase {
    private struct Stack {
        let mutationService: MCPMutationService
        let responseOverrideStore: ResponseOverrideStore
        let client: MCPClientRecord
    }

    func testReportsNoNewRequestsWhenNoneOccurredSinceMarker() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)

        let marker = makeSession(path: "/marker")
        sessionStore.append(marker)

        let result = try await stack.mutationService.handleTool(
            name: "capture_activity_since_marker",
            arguments: ["markerSessionID": marker.id.uuidString],
            client: stack.client
        )

        XCTAssertEqual(result["newRequestCount"] as? Int, 0)
        XCTAssertEqual(result["hasMore"] as? Bool, false)
        XCTAssertEqual((result["newRequests"] as? [[String: Any]])?.count, 0)
        XCTAssertNil(result["rule"])
    }

    func testCountsAndSummarizesRequestsAfterTheMarkerOnly() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)

        let before = makeSession(path: "/before")
        sessionStore.append(before)
        let marker = makeSession(path: "/marker")
        sessionStore.append(marker)
        let after1 = makeSession(path: "/after-1")
        sessionStore.append(after1)
        let after2 = makeSession(path: "/after-2", statusCode: 404)
        sessionStore.append(after2)

        let result = try await stack.mutationService.handleTool(
            name: "capture_activity_since_marker",
            arguments: ["markerSessionID": marker.id.uuidString],
            client: stack.client
        )

        XCTAssertEqual(result["newRequestCount"] as? Int, 2)
        let newRequests = try XCTUnwrap(result["newRequests"] as? [[String: Any]])
        XCTAssertEqual(newRequests.count, 2)
        // Deliberately no host/path in the response — see the function's own doc comment.
        XCTAssertNil(newRequests.first?["host"])
        XCTAssertNil(newRequests.first?["path"])
        XCTAssertEqual(newRequests.first?["method"] as? String, "GET")
        XCTAssertEqual(newRequests.last?["statusCode"] as? Int, 404)
    }

    func testRejectsUnknownMarkerSessionID() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)

        do {
            _ = try await stack.mutationService.handleTool(
                name: "capture_activity_since_marker",
                arguments: ["markerSessionID": UUID().uuidString],
                client: stack.client
            )
            XCTFail("expected malformedRequest for an unknown marker session")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testReportsRuleHitSinceMarkerButNotBeforeIt() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)

        let rule = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/thing",
            matchMode: .exactPath,
            sourceKind: .inlineText,
            sourceDescription: "test rule",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data("{}".utf8)),
            createdAt: Date().addingTimeInterval(-60)
        )
        try await stack.responseOverrideStore.addRule(rule)

        let marker = makeSession(path: "/marker")
        sessionStore.append(marker)

        // No hit yet (rule was never actually matched against traffic in this stack) — `found`
        // should be true but `matchedSinceMarker` false since `lastMatchedAt` is nil.
        let beforeHit = try await stack.mutationService.handleTool(
            name: "capture_activity_since_marker",
            arguments: ["markerSessionID": marker.id.uuidString, "overrideID": rule.id.uuidString],
            client: stack.client
        )
        let ruleBefore = try XCTUnwrap(beforeHit["rule"] as? [String: Any])
        XCTAssertEqual(ruleBefore["found"] as? Bool, true)
        XCTAssertEqual(ruleBefore["matchedSinceMarker"] as? Bool, false)

        // Simulate the rule actually being hit after the marker.
        var hitRule = rule
        hitRule.hitCount += 1
        hitRule.lastMatchedAt = Date()
        try await stack.responseOverrideStore.addRule(hitRule)

        let afterHit = try await stack.mutationService.handleTool(
            name: "capture_activity_since_marker",
            arguments: ["markerSessionID": marker.id.uuidString, "overrideID": rule.id.uuidString],
            client: stack.client
        )
        let ruleAfter = try XCTUnwrap(afterHit["rule"] as? [String: Any])
        XCTAssertEqual(ruleAfter["found"] as? Bool, true)
        XCTAssertEqual(ruleAfter["hitCountTotal"] as? Int, 1)
        XCTAssertEqual(ruleAfter["matchedSinceMarker"] as? Bool, true)
    }

    func testUnknownOverrideIDIsReportedAsNotFoundRatherThanAnError() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)

        let marker = makeSession(path: "/marker")
        sessionStore.append(marker)

        let result = try await stack.mutationService.handleTool(
            name: "capture_activity_since_marker",
            arguments: ["markerSessionID": marker.id.uuidString, "overrideID": UUID().uuidString],
            client: stack.client
        )
        let rule = try XCTUnwrap(result["rule"] as? [String: Any])
        XCTAssertEqual(rule["found"] as? Bool, false)
    }

    func testSinceSequenceAndNearMissPredicateDiagnostics() async throws {
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let stack = try makeStack(snapshotService: snapshotService)

        let rule = ResponseOverrideRule(
            requestMethod: "POST",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v1/checkout",
            matchMode: .exactPath,
            sourceKind: .inlineText,
            sourceDescription: "checkout rule",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data("{}".utf8)),
            createdAt: Date().addingTimeInterval(-60),
            isEnabled: false,
            matchQueryKey: "env",
            matchQueryValue: "staging"
        )
        try await stack.responseOverrideStore.addRule(rule)

        let anchor = makeSession(path: "/anchor")
        sessionStore.append(anchor)
        let nearMiss = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .http,
                inspectionKind: .plain,
                host: "api.example.com",
                port: 80,
                path: "/v1/checkout?env=prod",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
        sessionStore.append(nearMiss)

        let anchorSeq = try XCTUnwrap(snapshotService.indexedSession(id: anchor.id)?.captureSequence)
        let result = try await stack.mutationService.handleTool(
            name: "capture_activity_since_marker",
            arguments: [
                "sinceSequence": anchorSeq,
                "overrideID": rule.id.uuidString
            ],
            client: stack.client
        )
        XCTAssertEqual(result["newRequestCount"] as? Int, 1)
        let ruleReport = try XCTUnwrap(result["rule"] as? [String: Any])
        XCTAssertEqual(ruleReport["isEnabled"] as? Bool, false)
        let nearMisses = try XCTUnwrap(ruleReport["nearMisses"] as? [[String: Any]])
        XCTAssertEqual(nearMisses.count, 1)
        let failed = try XCTUnwrap(nearMisses[0]["failedPredicates"] as? [String])
        XCTAssertTrue(failed.contains("rule_disabled"))
        XCTAssertTrue(failed.contains("scheme_mismatch"))
        XCTAssertTrue(failed.contains("method_mismatch"))
        XCTAssertTrue(failed.contains("path_mismatch"))
        XCTAssertTrue(failed.contains("query_predicate_mismatch"))
    }

    // MARK: - Fixtures

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func makeStack(snapshotService: MCPSessionSnapshotService) throws -> Stack {
        let journalStore = MCPEffectJournalStore(persistenceURL: temporaryURL(named: "activity-since-marker-journal.json"))
        journalStore.load()
        let recoveryCoordinator = MCPRecoveryCoordinator(journalStore: journalStore)
        recoveryCoordinator.bootstrap()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "activity-since-marker-policy.json"))
        policyStore.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "activity-since-marker-audit.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let responseOverrideStore = ResponseOverrideStore()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: recoveryCoordinator,
            policyRevisionProvider: { policyStore.policyRevision }
        )
        let mutationService = MCPMutationService(
            bookmarkStore: InMemoryBookmarkStore(),
            responseOverrideStore: responseOverrideStore,
            proposalCoordinator: proposalCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            approvalStore: approvalStore,
            policyStore: policyStore,
            auditStore: auditStore,
            snapshotService: snapshotService,
            enforcesLiveRewritePreview: false
        )
        let client = MCPClientRecord(
            id: "client-activity-since-marker",
            displayName: "activity-since-marker-test",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        return Stack(mutationService: mutationService, responseOverrideStore: responseOverrideStore, client: client)
    }

    private func makeSession(path: String, statusCode: Int = 200) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "api.example.com",
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: statusCode,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}
