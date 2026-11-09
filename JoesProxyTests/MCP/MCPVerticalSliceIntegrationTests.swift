import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class MCPVerticalSliceIntegrationTests: XCTestCase {
    func testResourcesReadServerStatusThroughAuthPolicyAndAudit() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(
            persistenceURL: temporaryURL(named: "policy.json")
        )
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit.json"))
        auditStore.load()

        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: snapshotService,
            approvalStore: MCPApprovalStore()
        )

        let enrollment = try clientRegistry.enroll(displayName: "Integration")
        let initializeBody = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
        """.utf8)
        let initResponse = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(enrollment.plaintextCredential)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                "accept": "application/json, text/event-stream"
            ],
            body: initializeBody
        )
        let sessionID = initResponse.headerValue(named: MCPNetworkConstants.sessionIDHeader)
        XCTAssertNotNil(sessionID)

        _ = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(enrollment.plaintextCredential)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                "accept": "application/json, text/event-stream",
                MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25",
                MCPNetworkConstants.sessionIDHeader.lowercased(): sessionID ?? ""
            ],
            body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        )

        let readBody = Data("""
        {"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"joesproxy://server/status"}}
        """.utf8)
        let readResponse = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(enrollment.plaintextCredential)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                "accept": "application/json, text/event-stream",
                MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25",
                MCPNetworkConstants.sessionIDHeader.lowercased(): sessionID ?? ""
            ],
            body: readBody
        )
        let responseObject = try readResponse.jsonBodyObject()
        let result = try XCTUnwrap(responseObject["result"] as? [String: Any])
        let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["uri"] as? String, "joesproxy://server/status")
        XCTAssertEqual(contents[0]["mimeType"] as? String, "application/json")
        XCTAssertNotNil(contents[0]["text"] as? String)
        XCTAssertNil(result["structuredContent"])
        XCTAssertFalse(auditStore.recentEvents.isEmpty)
    }

    func testAuthenticatedClientCannotUseAnotherClientsSession() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-binding.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-binding.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-binding.json"))
        auditStore.load()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore()
        )
        let firstClient = try clientRegistry.enroll(displayName: "First")
        let secondClient = try clientRegistry.enroll(displayName: "Second")
        let firstSessionID = try await Self.initializeSession(
            protocolService: protocolService,
            bearer: firstClient.plaintextCredential
        )

        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: Self.authenticatedHeaders(
                bearer: secondClient.plaintextCredential,
                sessionID: firstSessionID
            ),
            body: Data("""
            {"jsonrpc":"2.0","id":7,"method":"resources/read","params":{"uri":"joesproxy://server/status"}}
            """.utf8)
        )
        XCTAssertEqual(response.status, 404)
        let object = try response.jsonBodyObject()
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "Session not found; initialize a new session.")
        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertNil(object["result"])
    }

    func testToolCursorRoundTripsAndLargeTextFallbackIsCompact() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-cursor.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-cursor.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-cursor.json"))
        auditStore.load()
        let sessionStore = InMemorySessionStore()
        for index in 0..<20 {
            sessionStore.append(Self.makeSession(path: "/\(index)"))
        }
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: sessionStore),
            approvalStore: MCPApprovalStore()
        )
        let enrollment = try clientRegistry.enroll(displayName: "Cursor")
        let sessionID = try await Self.initializeSession(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential
        )

        let first = await Self.callSessionsList(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            cursor: nil
        )
        let firstObject = try first.jsonBodyObject()
        let firstResult = try XCTUnwrap(firstObject["result"] as? [String: Any])
        let firstStructured = try XCTUnwrap(firstResult["structuredContent"] as? [String: Any])
        let firstPayload = try XCTUnwrap(firstStructured["payload"] as? [String: Any])
        let firstItems = try XCTUnwrap(firstPayload["items"] as? [[String: Any]])
        let cursor = try XCTUnwrap(firstPayload["nextCursor"] as? String)
        let content = try XCTUnwrap(firstResult["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(firstItems.count, 1)
        XCTAssertEqual(firstPayload["hasMore"] as? Bool, true)
        XCTAssertEqual(firstPayload["projection"] as? String, "minimal")
        XCTAssertNil(firstItems.first?["startedAt"])
        XCTAssertNil(firstItems.first?["hostCategory"])
        XCTAssertLessThanOrEqual(cursor.count, 36)
        let fallbackText = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(fallbackText.contains("api.example.com"))
        let stateToken = try XCTUnwrap(firstPayload["stateToken"] as? String)

        let digest = await Self.callTool(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            name: "capture_digest",
            arguments: ["ifStateToken": stateToken]
        )
        let digestObject = try digest.jsonBodyObject()
        let digestResult = try XCTUnwrap(digestObject["result"] as? [String: Any])
        let digestStructured = try XCTUnwrap(digestResult["structuredContent"] as? [String: Any])
        let digestPayload = try XCTUnwrap(digestStructured["payload"] as? [String: Any])
        XCTAssertEqual(digestPayload["unchanged"] as? Bool, true)
        XCTAssertEqual(digestPayload["recommendedAction"] as? String, "reuse_cached_capture_state")

        let cleanup = await Self.callTool(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            name: "client_cleanup_status",
            arguments: [:]
        )
        let cleanupObject = try cleanup.jsonBodyObject()
        let cleanupResult = try XCTUnwrap(cleanupObject["result"] as? [String: Any])
        let cleanupStructured = try XCTUnwrap(cleanupResult["structuredContent"] as? [String: Any])
        let cleanupPayload = try XCTUnwrap(cleanupStructured["payload"] as? [String: Any])
        XCTAssertEqual(cleanupPayload["isClean"] as? Bool, true)
        XCTAssertEqual(cleanupPayload["recommendedAction"] as? String, "safe_to_terminate")

        let unchanged = await Self.callSessionsList(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            cursor: nil,
            ifStateToken: stateToken
        )
        let unchangedObject = try unchanged.jsonBodyObject()
        let unchangedResult = try XCTUnwrap(unchangedObject["result"] as? [String: Any])
        let unchangedStructured = try XCTUnwrap(unchangedResult["structuredContent"] as? [String: Any])
        let unchangedPayload = try XCTUnwrap(unchangedStructured["payload"] as? [String: Any])
        XCTAssertEqual(unchangedPayload["unchanged"] as? Bool, true)
        XCTAssertEqual((unchangedPayload["items"] as? [[String: Any]])?.count, 0)

        let second = await Self.callSessionsList(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            cursor: cursor
        )
        let secondObject = try second.jsonBodyObject()
        let secondResult = try XCTUnwrap(secondObject["result"] as? [String: Any])
        let secondStructured = try XCTUnwrap(secondResult["structuredContent"] as? [String: Any])
        let secondPayload = try XCTUnwrap(secondStructured["payload"] as? [String: Any])
        let secondItems = try XCTUnwrap(secondPayload["items"] as? [[String: Any]])
        XCTAssertEqual(secondItems.count, 1)
        XCTAssertNotEqual(firstItems.first?["id"] as? String, secondItems.first?["id"] as? String)

        let delta = await Self.callSessionsList(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            cursor: nil,
            limit: 20,
            projection: "summary",
            sinceSequence: 19
        )
        let deltaObject = try delta.jsonBodyObject()
        let deltaResult = try XCTUnwrap(deltaObject["result"] as? [String: Any])
        let deltaStructured = try XCTUnwrap(deltaResult["structuredContent"] as? [String: Any])
        let deltaPayload = try XCTUnwrap(deltaStructured["payload"] as? [String: Any])
        let deltaItems = try XCTUnwrap(deltaPayload["items"] as? [[String: Any]])
        XCTAssertEqual(deltaPayload["projection"] as? String, "summary")
        XCTAssertEqual(deltaItems.count, 1)
        XCTAssertEqual(deltaItems.first?["captureSequence"] as? Int, 20)
        XCTAssertNotNil(deltaItems.first?["startedAt"])

        let largePage = await Self.callSessionsList(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            cursor: nil,
            limit: 20
        )
        let largeObject = try largePage.jsonBodyObject()
        let largeResult = try XCTUnwrap(largeObject["result"] as? [String: Any])
        let largeContent = try XCTUnwrap(largeResult["content"] as? [[String: Any]])
        let largeText = try XCTUnwrap(largeContent.first?["text"] as? String)
        XCTAssertTrue(largeText.contains("structuredContentAvailable"))
        XCTAssertFalse(largeText.contains("api.example.com"))
    }

    func testDeleteFinalSessionPreservesSessionWhenCleanupConflictsThenTerminatesAfterResolution() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-delete.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-delete.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-delete.json"))
        auditStore.load()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore()
        )
        let enrollment = try clientRegistry.enroll(displayName: "Delete")
        let sessionID = try await Self.initializeSession(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential
        )
        protocolService.setSessionTerminationHandler { _ in
            var summary = MCPRecoverySummary.empty(action: .terminateSession)
            summary.cleanupRequired = true
            summary.conflicts = [
                MCPEffectConflictItem(
                    id: "conflict",
                    kind: .block,
                    message: "Needs resolution.",
                    targetID: nil
                )
            ]
            return summary
        }

        let conflict = await protocolService.handleHTTPRequest(
            method: "DELETE",
            path: MCPNetworkConstants.endpointPath,
            headers: Self.authenticatedHeaders(
                bearer: enrollment.plaintextCredential,
                sessionID: sessionID
            ),
            body: Data()
        )
        XCTAssertEqual(conflict.status, 409)
        XCTAssertEqual(protocolService.activeSessionCount, 1)

        protocolService.setSessionTerminationHandler { _ in
            MCPRecoverySummary.empty(action: .terminateSession)
        }
        let success = await protocolService.handleHTTPRequest(
            method: "DELETE",
            path: MCPNetworkConstants.endpointPath,
            headers: Self.authenticatedHeaders(
                bearer: enrollment.plaintextCredential,
                sessionID: sessionID
            ),
            body: Data()
        )
        XCTAssertEqual(success.status, 204)
        XCTAssertEqual(protocolService.activeSessionCount, 0)
        XCTAssertTrue(auditStore.recentEvents.contains { $0.kind == .sessionTerminated })
    }

    func testDeleteRejectsAnotherClientsSession() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-delete-owner.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-delete-owner.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-delete-owner.json"))
        auditStore.load()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore()
        )
        let owner = try clientRegistry.enroll(displayName: "Owner")
        let other = try clientRegistry.enroll(displayName: "Other")
        let sessionID = try await Self.initializeSession(
            protocolService: protocolService,
            bearer: owner.plaintextCredential
        )

        let response = await protocolService.handleHTTPRequest(
            method: "DELETE",
            path: MCPNetworkConstants.endpointPath,
            headers: Self.authenticatedHeaders(
                bearer: other.plaintextCredential,
                sessionID: sessionID
            ),
            body: Data()
        )
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(protocolService.activeSessionCount, 1)
    }

    func testNIOTransportServesAuthenticatedInitialize() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-nio.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-nio.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-nio.json"))
        auditStore.load()
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: snapshotService,
            approvalStore: MCPApprovalStore(),
            boundPort: 19_092
        )
        let enrollment = try clientRegistry.enroll(displayName: "NIO")
        let transport = MCPNIOHTTPTransport(protocolService: protocolService)
        let port: UInt16 = 19_092
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!)
        request.httpMethod = "POST"
        request.httpBody = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
        """.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(enrollment.plaintextCredential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        try await transport.start(port: port)
        let (data, response) = try await URLSession.shared.data(for: request)
        await transport.shutdown()
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("protocolVersion") ?? false)
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private static func initializeSession(
        protocolService: MCPProtocolService,
        bearer: String
    ) async throws -> String {
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

    private static func authenticatedHeaders(bearer: String, sessionID: String) -> [String: String] {
        [
            "authorization": "Bearer \(bearer)",
            "content-type": "application/json",
            "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
            "accept": "application/json, text/event-stream",
            MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25",
            MCPNetworkConstants.sessionIDHeader.lowercased(): sessionID
        ]
    }

    private static func callSessionsList(
        protocolService: MCPProtocolService,
        bearer: String,
        sessionID: String,
        cursor: String?,
        limit: Int = 1,
        projection: String? = nil,
        sinceSequence: UInt64? = nil,
        ifStateToken: String? = nil
    ) async -> MCPHTTPResponse {
        var arguments: [String: Any] = ["limit": limit]
        arguments["cursor"] = cursor
        arguments["projection"] = projection
        arguments["sinceSequence"] = sinceSequence
        arguments["ifStateToken"] = ifStateToken
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "sessions_list",
                "arguments": arguments
            ]
        ]
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: body
        )
    }

    private static func callTool(
        protocolService: MCPProtocolService,
        bearer: String,
        sessionID: String,
        name: String,
        arguments: [String: Any]
    ) async -> MCPHTTPResponse {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments
            ]
        ]
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: body
        )
    }

    private static func makeSession(path: String) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }
}
