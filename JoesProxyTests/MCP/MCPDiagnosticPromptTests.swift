import XCTest
@testable import JoesProxy

/// Verifies the native MCP `prompts` capability added for the diagnostic playbook (see
/// `memlog/Research/ADR-MCP-Agent-Diagnostic-Skill.md`).
@MainActor
final class MCPDiagnosticPromptTests: XCTestCase {
    func testInitializeAdvertisesPromptsCapability() async throws {
        let (protocolService, bearer) = try makeService()
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(bearer)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                "accept": "application/json, text/event-stream"
            ],
            body: Data("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
            """.utf8)
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["prompts"])
    }

    func testPromptsListReturnsJoesProxyDiagnose() async throws {
        let (protocolService, bearer) = try makeService()
        let sessionID = try await initializeSession(protocolService: protocolService, bearer: bearer)
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"prompts/list"}"#.utf8)
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let prompts = try XCTUnwrap(result["prompts"] as? [[String: Any]])
        XCTAssertEqual(prompts.count, 3)
        XCTAssertEqual(prompts.map { $0["name"] as? String }, ["joesproxy_diagnose", MCPSetupOnboardingPrompt.name, MCPIntegrationsPrompt.name])
        XCTAssertNotNil(prompts.first?["description"])
    }

    func testPromptsGetReturnsIntegrationsBody() async throws {
        let (protocolService, bearer) = try makeService()
        let sessionID = try await initializeSession(protocolService: protocolService, bearer: bearer)
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"joesproxy_integrations"}}"#.utf8)
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let messages = try XCTUnwrap(result["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [String: Any])
        XCTAssertEqual(content["text"] as? String, MCPIntegrationsPrompt.body)
    }

    func testPromptsGetReturnsExpectedBody() async throws {
        let (protocolService, bearer) = try makeService()
        let sessionID = try await initializeSession(protocolService: protocolService, bearer: bearer)
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"joesproxy_diagnose"}}"#.utf8)
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let messages = try XCTUnwrap(result["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [String: Any])
        XCTAssertEqual(content["text"] as? String, MCPDiagnosticPrompt.body)
    }

    func testPromptsGetRejectsUnknownName() async throws {
        let (protocolService, bearer) = try makeService()
        let sessionID = try await initializeSession(protocolService: protocolService, bearer: bearer)
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{"name":"not_a_real_prompt"}}"#.utf8)
        )
        let object = try response.jsonBodyObject()
        XCTAssertNotNil(object["error"])
        XCTAssertNil(object["result"])
    }

    func testSetupPromptUsesPortableOnboardingBoundaries() async throws {
        let (protocolService, bearer) = try makeService()
        let sessionID = try await initializeSession(protocolService: protocolService, bearer: bearer)
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"joesproxy_setup_onboarding"}}"#.utf8)
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let messages = try XCTUnwrap(result["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [String: Any])
        let body = try XCTUnwrap(content["text"] as? String)
        XCTAssertEqual(body, MCPSetupOnboardingPrompt.body)
        XCTAssertTrue(body.contains("not observe remote profile installation"))
        XCTAssertTrue(body.contains("client_cleanup_status"))
    }

    func testSetupReadinessRequiresExplicitTargetAndReturnsBoundedDTO() async throws {
        let (protocolService, bearer) = try makeService()
        let sessionID = try await initializeSession(protocolService: protocolService, bearer: bearer)
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"setup_readiness","arguments":{"target":"iOS/iPadOS"}}}"#.utf8)
        )
        let object = try response.jsonBodyObject()
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])
        XCTAssertEqual(payload["target"] as? String, "iOS/iPadOS")
        XCTAssertEqual(payload["remoteTrustNotObservable"] as? Bool, true)

        let invalid = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"setup_readiness","arguments":{"target":"phone"}}}"#.utf8)
        )
        XCTAssertNotNil(try invalid.jsonBodyObject()["error"])
    }

    // MARK: - Helpers

    private func makeService() throws -> (MCPProtocolService, bearer: String) {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-prompt.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-prompt.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-prompt.json"))
        auditStore.load()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore()
        )
        protocolService.setSetupReadinessProvider { target, _ in
            MCPSetupReadinessDTO(
                schemaVersion: 1,
                target: target,
                state: "action_required",
                checks: [MCPSetupReadinessCheckDTO(
                    id: "remote_profile_installation",
                    state: .notObservable,
                    detail: "Remote installation is not observable.",
                    evidence: nil,
                    actor: .user,
                    nextHumanAction: "Confirm installation on the target.",
                    confidenceBoundary: "Download is not proof of installation."
                )],
                recommendedNextActions: ["Confirm installation on the target."],
                remoteTrustNotObservable: true
            )
        }
        let enrollment = try clientRegistry.enroll(displayName: "prompt-test")
        return (protocolService, enrollment.plaintextCredential)
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func initializeSession(protocolService: MCPProtocolService, bearer: String) async throws -> String {
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(bearer)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                "accept": "application/json, text/event-stream"
            ],
            body: Data("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
            """.utf8)
        )
        let sessionID = try XCTUnwrap(response.headerValue(named: MCPNetworkConstants.sessionIDHeader))
        _ = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        )
        return sessionID
    }

    private func authenticatedHeaders(bearer: String, sessionID: String) -> [String: String] {
        [
            "authorization": "Bearer \(bearer)",
            "content-type": "application/json",
            "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
            "accept": "application/json, text/event-stream",
            MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25",
            MCPNetworkConstants.sessionIDHeader.lowercased(): sessionID
        ]
    }
}
