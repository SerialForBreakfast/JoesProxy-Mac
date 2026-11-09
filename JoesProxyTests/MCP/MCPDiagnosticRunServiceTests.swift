import XCTest
@testable import JoesProxy

/// AN-6: MCP diagnostic-run composite tools, ownership, disclosure, and approval cardinality.
@MainActor
final class MCPDiagnosticRunServiceTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    func testCreateStartCloseMaterializesEvidenceWithoutApproval() async throws {
        let harness = try makeHarness(grantLifecycle: true)
        await harness.coordinator.bootstrap()
        let client = makeClient()
        let created = try await harness.service.handleTool(
            name: "diagnostic_run_create",
            arguments: [
                "hypothesisSummary": "Health endpoint recovers.",
                "expectedObservation": "Matching GET is observed.",
                "scopes": [[
                    "kind": "http",
                    "method": "GET",
                    "scheme": "https",
                    "host": "example.test",
                    "path": "/v1/health",
                    "pathMatch": "exact"
                ]]
            ],
            client: client
        )
        let runID = try XCTUnwrap((created["payload"] as? [String: Any])?["runID"] as? String)
        XCTAssertEqual((created["payload"] as? [String: Any])?["status"] as? String, "draft")
        let createdWorkflow = try XCTUnwrap((created["payload"] as? [String: Any])?["workflow"] as? [String: Any])
        XCTAssertEqual(createdWorkflow["stage"] as? String, "preflight")
        XCTAssertEqual(harness.approvalStore.pendingCount, 0)

        let started = try await harness.service.handleTool(
            name: "diagnostic_run_start",
            arguments: ["runID": runID],
            client: client
        )
        XCTAssertEqual((started["payload"] as? [String: Any])?["status"] as? String, "watching")
        let startedWorkflow = try XCTUnwrap((started["payload"] as? [String: Any])?["workflow"] as? [String: Any])
        XCTAssertEqual(startedWorkflow["stage"] as? String, "observe")
        XCTAssertEqual(startedWorkflow["targetOutcome"] as? String, "notInferred")
        XCTAssertEqual(harness.approvalStore.pendingCount, 0)

        let closed = try await harness.service.handleTool(
            name: "diagnostic_run_close",
            arguments: [
                "runID": runID,
                "requestedTerminal": "passed",
                "conclusionOutcome": "passed",
                "conclusionReasonCode": "expected_observed",
                "conclusionSummary": "Observed matching traffic.",
                "conclusionConfidence": "medium"
            ],
            client: client
        )
        XCTAssertEqual((closed["payload"] as? [String: Any])?["status"] as? String, "passed")
        XCTAssertNotNil((closed["payload"] as? [String: Any])?["evidenceID"] as? String)
        XCTAssertEqual(harness.approvalStore.pendingCount, 0)
    }

    func testOwnershipIsolationRejectsForeignStatus() async throws {
        let harness = try makeHarness(grantLifecycle: true)
        await harness.coordinator.bootstrap()
        let owner = makeClient(id: "owner-a")
        let foreign = makeClient(id: "owner-b")
        _ = try harness.grantStore.addGrant(clientID: "owner-a", capability: .diagnosticRunLifecycle, mode: .durablePolicy)
        _ = try harness.grantStore.addGrant(clientID: "owner-a", capability: .diagnosticRunInspect, mode: .durablePolicy)
        _ = try harness.grantStore.addGrant(clientID: "owner-b", capability: .diagnosticRunInspect, mode: .durablePolicy)
        let created = try await harness.service.handleTool(
            name: "diagnostic_run_create",
            arguments: [
                "hypothesisSummary": "Owned run.",
                "expectedObservation": "Expected."
            ],
            client: owner
        )
        let runID = try XCTUnwrap((created["payload"] as? [String: Any])?["runID"] as? String)
        do {
            _ = try await harness.service.handleTool(
                name: "diagnostic_run_status",
                arguments: ["runID": runID],
                client: foreign
            )
            XCTFail("expected not found for foreign owner")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .malformedRequest)
        }
    }

    func testMetadataOnlyRedactsExactHostAndPath() async throws {
        let harness = try makeHarness()
        await harness.coordinator.bootstrap()
        let client = MCPClientRecord(
            id: "meta-client",
            displayName: "Metadata",
            assignedProfileID: .metadataOnly,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
        let draft = try harness.coordinator.createDraft(
            owner: .mcpClient(id: client.id, displayNameSnapshot: client.displayName),
            hypothesis: DiagnosticRunHypothesis(
                summary: "Meta projection.",
                expectedObservation: "Expected.",
                source: .mcpClient
            ),
            scopes: [.http(DiagnosticHTTPScope(
                method: "GET",
                scheme: .https,
                host: "secret.example.test",
                port: 443,
                path: "/private/path",
                pathMatch: .exact
            ))]
        )
        let status = try await harness.service.handleTool(
            name: "diagnostic_run_status",
            arguments: ["runID": draft.id.rawValue.uuidString],
            client: client
        )
        let payload = try XCTUnwrap(status["payload"] as? [String: Any])
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("secret.example.test"))
        XCTAssertFalse(json.contains("/private/path"))
        XCTAssertEqual(payload["scopeCount"] as? Int, 1)
    }

    func testRecheckApplyRequiresOneApproval() async throws {
        let harness = try makeHarness(grantLifecycle: false)
        await harness.coordinator.bootstrap()
        let client = makeClient()
        // Seed a closed evidence record locally (no durable grants), then propose/apply via MCP.
        let draft = try harness.coordinator.createDraft(
            owner: .mcpClient(id: client.id, displayNameSnapshot: client.displayName),
            hypothesis: DiagnosticRunHypothesis(
                summary: "Re-check source.",
                expectedObservation: "Expected.",
                source: .mcpClient
            ),
            scopes: [.http(DiagnosticHTTPScope(
                method: "GET",
                scheme: .https,
                host: "example.test",
                port: 443,
                path: "/v1/health",
                pathMatch: .exact
            ))]
        )
        _ = try await harness.coordinator.startWatching(id: draft.id, requestingOwnerID: client.id)
        let closed = try await harness.coordinator.close(
            id: draft.id,
            requestingOwnerID: client.id,
            requestedTerminal: .passed,
            conclusion: DiagnosticRunConclusion(
                outcome: .passed,
                reasonCode: .expectedObserved,
                summary: "Passed once.",
                confidence: .high,
                concludedAt: clock,
                evidenceDigest: "placeholder"
            )
        )
        let evidence = try harness.coordinator.evidenceRecord(
            forRunID: closed.id,
            requestingOwnerID: client.id
        )

        let propose = try await harness.service.handleTool(
            name: "propose_diagnostic_run_recheck",
            arguments: ["evidenceID": evidence.id.uuidString],
            client: client
        )
        let token = try XCTUnwrap((propose["payload"] as? [String: Any])?["proposalToken"] as? String)
        do {
            _ = try await harness.service.handleTool(
                name: "apply_diagnostic_run_recheck",
                arguments: ["proposalToken": token],
                client: client
            )
            XCTFail("expected approvalRequired")
        } catch let error as MCPStructuredError {
            XCTAssertEqual(error.code, .approvalRequired)
        }
        XCTAssertEqual(harness.approvalStore.pendingCount, 1)
    }

    func testCapabilityRouterMapsDiagnosticRunTools() {
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "diagnostic_run_list"), .diagnosticRunInspect)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "diagnostic_run_create"), .diagnosticRunLifecycle)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "apply_diagnostic_run_recheck"), .diagnosticRunLifecycle)
        XCTAssertTrue(
            MCPCapabilitiesManifestBuilder.productionTools.contains { $0.name == "diagnostic_run_close" }
        )
        XCTAssertEqual(MCPCapabilitiesRevision.current, CLIRuntimeIdentity.capabilitiesRevision)
    }

    // MARK: - Helpers

    private struct Harness {
        var service: MCPDiagnosticRunService
        var coordinator: DiagnosticRunCoordinator
        var approvalStore: MCPApprovalStore
        var grantStore: MCPClientGrantStore
    }

    private func makeHarness(grantLifecycle: Bool = false) throws -> Harness {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = DiagnosticRunStore(
            persistenceURL: base.appendingPathComponent("runs.json"),
            clock: { [unowned self] in self.clock }
        )
        let coordinator = DiagnosticRunCoordinator(
            store: store,
            clock: { [unowned self] in self.clock }
        )
        let recheck = DiagnosticRunRegressionRecheckService(
            store: store,
            clock: { [unowned self] in self.clock }
        )
        let journalStore = MCPEffectJournalStore(persistenceURL: base.appendingPathComponent("journal.json"))
        journalStore.load()
        let proposalCoordinator = MCPProposalCoordinator(
            recoveryCoordinator: MCPRecoveryCoordinator(journalStore: journalStore),
            policyRevisionProvider: { .initial }
        )
        let approvalStore = MCPApprovalStore()
        let grantStore = MCPClientGrantStore()
        if grantLifecycle {
            _ = try grantStore.addGrant(clientID: "run-client", capability: .diagnosticRunLifecycle, mode: .durablePolicy)
            _ = try grantStore.addGrant(clientID: "run-client", capability: .diagnosticRunInspect, mode: .durablePolicy)
        }
        let service = MCPDiagnosticRunService(
            runCoordinator: coordinator,
            recheckService: recheck,
            proposalCoordinator: proposalCoordinator,
            approvalStore: approvalStore,
            policyStore: MCPPolicyStore(),
            grantStore: grantStore,
            auditStore: MCPAuditStore()
        )
        return Harness(
            service: service,
            coordinator: coordinator,
            approvalStore: approvalStore,
            grantStore: grantStore
        )
    }

    private func makeClient(id: String = "run-client") -> MCPClientRecord {
        MCPClientRecord(
            id: id,
            displayName: "Run Client",
            assignedProfileID: .shareable,
            credentialState: .active,
            credentialGeneration: 1,
            createdAt: Date(),
            lastSeenAt: nil
        )
    }
}
