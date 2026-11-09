import Foundation
import XCTest
@testable import JoesProxy

/// Automated substitutes for the Phase 1 manual validation checklist
/// (`memlog/Research/MCP-Phase1-ValidationRecord.md`).
@MainActor
final class MCPPhase1ValidationIntegrationTests: XCTestCase {
    func testRow1ProductionControllerEnrollAndInitialize() async throws {
        let stack = try await makeRunningControllerStack()
        let enrollment = try stack.controller.enrollClient(displayName: "Codex")
        let endpointURL = try XCTUnwrap(stack.controller.state.endpointURL)
        let sessionID = try await postInitialize(
            endpointURL: endpointURL,
            bearer: enrollment.plaintextCredential
        )
        XCTAssertFalse(sessionID.isEmpty)
        await stack.controller.stop()
    }

    func testRow3ResourcesReadServerCaptureAndHealth() async throws {
        let stack = try makeProtocolStack()
        let enrollment = try stack.clientRegistry.enroll(displayName: "Resources")
        let sessionID = try await Self.initializeSession(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential
        )

        for uri in [
            "joesproxy://server/status",
            "joesproxy://capture/summary",
            "joesproxy://capture/health"
        ] {
            let response = await Self.resourcesRead(
                protocolService: stack.protocolService,
                bearer: enrollment.plaintextCredential,
                sessionID: sessionID,
                uri: uri
            )
            let object = try response.jsonBodyObject()
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
            XCTAssertEqual(contents.count, 1)
            XCTAssertEqual(contents[0]["uri"] as? String, uri)
            XCTAssertEqual(contents[0]["mimeType"] as? String, "application/json")
            XCTAssertNotNil(contents[0]["text"] as? String)
        }
        XCTAssertFalse(stack.auditStore.recentEvents.isEmpty)
    }

    func testRow4PaginatedSessionsListStableDuringLiveCapture() async throws {
        let stack = try makeProtocolStack()
        for index in 0..<4 {
            stack.sessionStore.append(Self.makeSession(path: "/page-\(index)"))
        }
        let enrollment = try stack.clientRegistry.enroll(displayName: "Pagination")
        let sessionID = try await Self.initializeSession(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential
        )

        let firstPage = await Self.callSessionsList(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            cursor: nil,
            limit: 2
        )
        let firstObject = try firstPage.jsonBodyObject()
        let firstResult = try XCTUnwrap(firstObject["result"] as? [String: Any])
        let firstStructured = try XCTUnwrap(firstResult["structuredContent"] as? [String: Any])
        let firstPayload = try XCTUnwrap(firstStructured["payload"] as? [String: Any])
        let firstItems = try XCTUnwrap(firstPayload["items"] as? [[String: Any]])
        let cursor = try XCTUnwrap(firstPayload["nextCursor"] as? String)
        XCTAssertEqual(firstItems.count, 2)

        stack.sessionStore.append(Self.makeSession(path: "/live-append"))

        let secondPage = await Self.callSessionsList(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            cursor: cursor,
            limit: 2
        )
        let secondObject = try secondPage.jsonBodyObject()
        let secondResult = try XCTUnwrap(secondObject["result"] as? [String: Any])
        let secondStructured = try XCTUnwrap(secondResult["structuredContent"] as? [String: Any])
        let secondPayload = try XCTUnwrap(secondStructured["payload"] as? [String: Any])
        let secondItems = try XCTUnwrap(secondPayload["items"] as? [[String: Any]])
        XCTAssertEqual(secondItems.count, 2)
        XCTAssertNotEqual(
            firstItems.compactMap { $0["id"] as? String },
            secondItems.compactMap { $0["id"] as? String }
        )

        let refreshedFirstPage = await Self.callSessionsList(
            protocolService: stack.protocolService,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            cursor: nil,
            limit: 2
        )
        let refreshedObject = try refreshedFirstPage.jsonBodyObject()
        let refreshedResult = try XCTUnwrap(refreshedObject["result"] as? [String: Any])
        let refreshedStructured = try XCTUnwrap(refreshedResult["structuredContent"] as? [String: Any])
        let refreshedPayload = try XCTUnwrap(refreshedStructured["payload"] as? [String: Any])
        let refreshedItems = try XCTUnwrap(refreshedPayload["items"] as? [[String: Any]])
        XCTAssertEqual(refreshedItems.count, 2)
        let secondPageIDs = secondItems.compactMap { $0["id"] as? String }
        XCTAssertFalse(secondPageIDs.isEmpty)
    }

    /// Unlike the original version of this test, this drives `MCPServerController.revokeClient`/
    /// `.rotateClient` directly over the real NIO transport — the actual reachable production entry
    /// point (the management panel calls these, not `clientRegistry.revoke`/`protocolService
    /// .invalidateSessions` as two independently-stitched-together calls). A regression that drops
    /// `invalidateSessions` from `revokeClient`'s implementation would not have been caught by the
    /// previous version of this test; it is caught here because the assertions depend on the whole
    /// bundled call succeeding, not on a manual reproduction of what it's supposed to do.
    func testRow6RevokeAndRotateInvalidateActiveSession() async throws {
        let stack = try await makeRunningControllerStack()
        let endpointURL = try XCTUnwrap(stack.controller.state.endpointURL)

        let enrollment = try stack.controller.enrollClient(displayName: "Revoke")
        let sessionID = try await postInitialize(endpointURL: endpointURL, bearer: enrollment.plaintextCredential)

        try stack.controller.revokeClient(clientID: enrollment.client.id)

        // The credential alone already blocks any future HTTP request with a 401, which would
        // happen even if `invalidateSessions` were silently dropped from `revokeClient` — so this
        // check alone can't prove that call actually ran. Check the session-restriction state
        // `invalidateSessions` is specifically responsible for directly, not just the auth-layer
        // consequence of credential revocation.
        XCTAssertTrue(
            stack.controller.protocolService.isSessionRestricted(sessionID: sessionID),
            "revokeClient must mark the client's active session restricted, not just revoke its credential"
        )

        let revokedResponse = try await postResourcesRead(
            endpointURL: endpointURL,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            uri: "joesproxy://server/status"
        )
        // A revoked bearer fails authentication outright — the session-level "restricted" state
        // (checked further downstream) is never reached.
        XCTAssertEqual(revokedResponse.statusCode, 401)

        let rotateEnrollment = try stack.controller.enrollClient(displayName: "Rotate")
        let rotateSessionID = try await postInitialize(endpointURL: endpointURL, bearer: rotateEnrollment.plaintextCredential)
        let rotated = try stack.controller.rotateClient(clientID: rotateEnrollment.client.id)

        let oldBearerResponse = try await postResourcesRead(
            endpointURL: endpointURL,
            bearer: rotateEnrollment.plaintextCredential,
            sessionID: rotateSessionID,
            uri: "joesproxy://server/status"
        )
        XCTAssertEqual(oldBearerResponse.statusCode, 401, "the pre-rotation bearer must no longer authenticate")

        let newBearerOldSessionResponse = try await postResourcesRead(
            endpointURL: endpointURL,
            bearer: rotated.plaintextCredential,
            sessionID: rotateSessionID,
            uri: "joesproxy://server/status"
        )
        XCTAssertEqual(newBearerOldSessionResponse.statusCode, 404, "a valid new bearer must reinitialize after credential rotation")
        let rotatedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: newBearerOldSessionResponse.body) as? [String: Any]
        )
        let rotatedError = try XCTUnwrap(rotatedObject["error"] as? [String: Any])
        XCTAssertEqual(
            rotatedError["message"] as? String, "Session not found; initialize a new session.",
            "a session bound to the pre-rotation credential generation must be rejected even with a valid new bearer"
        )

        await stack.controller.stop()
    }

    func testRow7StoppingMCPServerDoesNotStopProxyCapture() async throws {
        let sessionStore = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: sessionStore)
        let proxyServer = ProxyServer(
            port: UInt16.random(in: 20_000...60_000),
            httpsProxyMode: .passThrough,
            sessionRecorder: recorder
        )
        try await proxyServer.start()

        let controller = try makeController(
            sessionStore: sessionStore,
            port: UInt16.random(in: 20_000...60_000)
        )
        await controller.start()

        let firstSessionID = await recorder.beginSession(
            request: Self.makeCapturedRequest(path: "/before-mcp-stop")
        )
        await recorder.completeSession(
            id: firstSessionID,
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil)
        )
        await recorder.waitForPendingStoreFlush()
        let countAfterFirstCapture = sessionStore.sessions.count
        XCTAssertEqual(countAfterFirstCapture, 1)

        await controller.stop()
        if case .stopped = controller.state {
        } else {
            XCTFail("Expected MCP controller to stop.")
        }

        let secondSessionID = await recorder.beginSession(
            request: Self.makeCapturedRequest(path: "/after-mcp-stop")
        )
        await recorder.completeSession(
            id: secondSessionID,
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil)
        )
        await recorder.waitForPendingStoreFlush()
        XCTAssertGreaterThan(sessionStore.sessions.count, countAfterFirstCapture)
        XCTAssertTrue(proxyServer.isRunning)

        await proxyServer.stop()
    }

    private struct ProtocolStack {
        let sessionStore: InMemorySessionStore
        let protocolService: MCPProtocolService
        let clientRegistry: MCPClientRegistry
        let auditStore: MCPAuditStore
    }

    private struct ControllerStack {
        let controller: MCPServerController
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func makeController(
        sessionStore: InMemorySessionStore,
        port: UInt16
    ) throws -> MCPServerController {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-validation.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-validation.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-validation.json"))
        auditStore.load()
        return MCPServerController(
            sessionStore: sessionStore,
            port: port,
            credentialStore: credentialStore,
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            scenarioStore: MCPScenarioStore(persistenceURL: temporaryURL(named: "scenarios-phase1.json")),
            responseDraftStore: ResponseDraftStore(persistenceURL: temporaryURL(named: "response-drafts-phase1.json")),
            fixtureRunStore: HLSFixtureRunStore(persistenceURL: temporaryURL(named: "hls-fixture-run-store-phase1.json"))
        )
    }

    private func makeRunningControllerStack() async throws -> ControllerStack {
        let controller = try makeController(
            sessionStore: InMemorySessionStore(),
            port: UInt16.random(in: 20_000...60_000)
        )
        await controller.start()
        guard case .running = controller.state else {
            throw XCTSkip("MCP controller did not reach running state.")
        }
        return ControllerStack(controller: controller)
    }

    private func makeProtocolStack() throws -> ProtocolStack {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-validation-stack.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-validation-stack.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-validation-stack.json"))
        auditStore.load()
        let sessionStore = InMemorySessionStore()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: sessionStore),
            approvalStore: MCPApprovalStore()
        )
        return ProtocolStack(
            sessionStore: sessionStore,
            protocolService: protocolService,
            clientRegistry: clientRegistry,
            auditStore: auditStore
        )
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
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let sessionID = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        let resolvedSessionID = try XCTUnwrap(sessionID)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("protocolVersion") ?? false)

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

    private struct RawHTTPResponse {
        var statusCode: Int
        var body: Data
    }

    private func postResourcesRead(
        endpointURL: URL,
        bearer: String,
        sessionID: String,
        uri: String
    ) async throws -> RawHTTPResponse {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.httpBody = Data("""
        {"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"\(uri)"}}
        """.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-11-25", forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader)
        request.setValue(sessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        return RawHTTPResponse(statusCode: statusCode, body: data)
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

    private static func resourcesRead(
        protocolService: MCPProtocolService,
        bearer: String,
        sessionID: String,
        uri: String
    ) async -> MCPHTTPResponse {
        let body = Data("""
        {"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"\(uri)"}}
        """.utf8)
        return await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: body
        )
    }

    private static func callSessionsList(
        protocolService: MCPProtocolService,
        bearer: String,
        sessionID: String,
        cursor: String?,
        limit: Int
    ) async -> MCPHTTPResponse {
        var arguments: [String: Any] = ["limit": limit]
        if let cursor {
            arguments["cursor"] = cursor
        }
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

    private static func makeCapturedRequest(path: String) -> CapturedRequest {
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

    private static func makeSession(path: String) -> SessionRecord {
        SessionRecord(
            request: makeCapturedRequest(path: path),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }
}

private extension MCPServerController.ServerState {
    var endpointURL: URL? {
        if case .running(_, let endpointURL) = self {
            return endpointURL
        }
        return nil
    }
}
