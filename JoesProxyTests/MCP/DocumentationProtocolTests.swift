import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class DocumentationProtocolTests: XCTestCase {
    func testAuthenticatedDocumentationMatchesOfflineCatalogWithoutCaptureEffects() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/DocumentationProtocolTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = MCPPolicyStore(persistenceURL: root.appendingPathComponent("policy.json"))
        policy.load()
        let registry = MCPClientRegistry(persistenceURL: root.appendingPathComponent("clients.json"), credentialStore: MCPInMemoryCredentialStore())
        try registry.load()
        let audit = MCPAuditStore(persistenceURL: root.appendingPathComponent("audit.json"))
        audit.load()
        let sessions = InMemorySessionStore()
        let approvals = MCPApprovalStore()
        let service = MCPProtocolService(policyStore: policy, clientRegistry: registry, auditStore: audit,
            snapshotService: MCPSessionSnapshotService(sessionStore: sessions), approvalStore: approvals)
        let enrollment = try registry.enroll(displayName: "Documentation test")
        var headers = ["authorization": "Bearer \(enrollment.plaintextCredential)", "content-type": "application/json",
            "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)", "accept": "application/json, text/event-stream"]
        let initialized = await service.handleHTTPRequest(method: "POST", path: MCPNetworkConstants.endpointPath, headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#.utf8))
        headers[MCPNetworkConstants.sessionIDHeader.lowercased()] = try XCTUnwrap(initialized.headerValue(named: MCPNetworkConstants.sessionIDHeader))
        headers[MCPNetworkConstants.protocolVersionHeader.lowercased()] = "2025-11-25"
        _ = await service.handleHTTPRequest(method: "POST", path: MCPNetworkConstants.endpointPath, headers: headers,
            body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"documentation_read","arguments":{"topic":"workflow-evidence","section":"bodies","maxResponseBytes":4096}}}"#.utf8)
        let response = await service.handleHTTPRequest(method: "POST", path: MCPNetworkConstants.endpointPath, headers: headers, body: request)
        let object = try response.jsonBodyObject()
        XCTAssertNil(object["error"])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let payload = try XCTUnwrap(structured["payload"] as? [String: Any])
        let live = try JSONDecoder().decode(DocumentationCatalog.Page.self, from: JSONSerialization.data(withJSONObject: payload))
        let offline = try await DocumentationService.shared.query(.init(operation: "read", topic: "workflow-evidence", section: "bodies", maxResponseBytes: 4096), source: "installed", appVersion: "test")
        XCTAssertEqual(live.catalogDigest, offline.catalogDigest)
        XCTAssertEqual(live.entries.first?.sections.first?.markdown, offline.entries.first?.sections.first?.markdown)
        XCTAssertEqual(live.source, "running-server")
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(live).count, 4096)
        let indexResponse = await service.handleHTTPRequest(method: "POST", path: MCPNetworkConstants.endpointPath, headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"joesproxy://docs/index"}}"#.utf8))
        XCTAssertNil(try indexResponse.jsonBodyObject()["error"])
        let workspaceResponse = await service.handleHTTPRequest(method: "POST", path: MCPNetworkConstants.endpointPath,
            headers: headers, body: Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"documentation_read","arguments":{"topic":"agent-documentation","section":"workspace","maxResponseBytes":8192}}}"#.utf8))
        let workspaceResult = try XCTUnwrap(try workspaceResponse.jsonBodyObject()["result"] as? [String: Any])
        let workspaceStructured = try XCTUnwrap(workspaceResult["structuredContent"] as? [String: Any])
        let workspacePayload = try XCTUnwrap(workspaceStructured["payload"] as? [String: Any])
        let workspaceLive = try JSONDecoder().decode(DocumentationCatalog.Page.self,
            from: JSONSerialization.data(withJSONObject: workspacePayload))
        let workspaceOffline = try await DocumentationService.shared.query(
            .init(operation: "read", topic: "agent-documentation", section: "workspace", maxResponseBytes: 8192),
            source: "installed", appVersion: "test")
        XCTAssertEqual(workspaceLive.entries.first?.sections.first?.markdown,
                       workspaceOffline.entries.first?.sections.first?.markdown)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(workspaceLive).count, 8192)
        XCTAssertTrue(sessions.sessions.isEmpty)
        XCTAssertTrue(approvals.pendingRequests.isEmpty)
        var unauthorizedHeaders = headers
        unauthorizedHeaders.removeValue(forKey: "authorization")
        let rejected = await service.handleHTTPRequest(method: "POST", path: MCPNetworkConstants.endpointPath, headers: unauthorizedHeaders, body: request)
        XCTAssertEqual(rejected.status, 401)
    }
}
