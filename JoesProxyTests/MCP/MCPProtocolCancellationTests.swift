import Foundation
import XCTest
@testable import JoesProxy

#if DEBUG
@MainActor
final class MCPProtocolCancellationTests: XCTestCase {
    func testProductionSlowToolHonoursCancellationNotification() async throws {
        let (transport, baseURL, bearer, sessionID) = try await startProductionTransport()
        defer { Task { await transport.shutdown() } }

        async let slowCall = Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            id: 42,
            method: "tools/call",
            params: ["name": "mcp_slow", "arguments": ["delayMs": 5_000]]
        )

        try await Task.sleep(for: .milliseconds(200))
        _ = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            method: "notifications/cancelled",
            params: ["requestId": 42, "reason": "test-cancel"],
            includeID: false
        )

        let slowResponse = try await slowCall
        let error = try XCTUnwrap(slowResponse.json["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "Request cancelled.")
    }

    /// Regression test for a confirmed bug: `cancelledRequestIDs` was only ever added to, never
    /// pruned, except when the whole session was torn down. Since simple/pooled clients commonly
    /// reuse small integer ids across a long-lived session, once any id was cancelled once, every
    /// later call reusing that same id would be permanently rejected with "Request cancelled" for
    /// the rest of the session — even for an entirely unrelated, legitimate call.
    func testCancelledRequestIDCanBeReusedAfterItsResponseIsDelivered() async throws {
        let (transport, baseURL, bearer, sessionID) = try await startProductionTransport()
        defer { Task { await transport.shutdown() } }

        async let slowCall = Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            id: 42,
            method: "tools/call",
            params: ["name": "mcp_slow", "arguments": ["delayMs": 5_000]]
        )
        try await Task.sleep(for: .milliseconds(200))
        _ = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            method: "notifications/cancelled",
            params: ["requestId": 42, "reason": "test-cancel"],
            includeID: false
        )
        let cancelledResponse = try await slowCall
        XCTAssertEqual(
            (cancelledResponse.json["error"] as? [String: Any])?["message"] as? String,
            "Request cancelled.",
            "sanity check: the original call must actually have been cancelled"
        )

        // A brand-new, unrelated call reusing the same id — this must succeed normally now that
        // the original call's response has been delivered, not be rejected as "already cancelled."
        let reusedIDResponse = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            id: 42,
            method: "tools/call",
            params: ["name": "mcp_slow", "arguments": ["delayMs": 0]]
        )
        XCTAssertNil(reusedIDResponse.json["error"], "reusing a previously-cancelled id for a new call must not be permanently blocked")
        XCTAssertNotNil(reusedIDResponse.json["result"])
    }

    func testCancellationDoesNotCrossSessionBoundaryForSameRequestID() async throws {
        let (transport, baseURL, bearer, _) = try await startProductionTransport()
        defer { Task { await transport.shutdown() } }

        let firstSessionID = try await Self.initializeSession(url: baseURL, bearerToken: bearer, initializeRequestID: 1)
        let secondSessionID = try await Self.initializeSession(url: baseURL, bearerToken: bearer, initializeRequestID: 2)

        async let firstCall = Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: firstSessionID,
            id: 42,
            method: "tools/call",
            params: ["name": "mcp_slow", "arguments": ["delayMs": 5_000]]
        )
        async let secondCall = Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: secondSessionID,
            id: 42,
            method: "tools/call",
            params: ["name": "mcp_slow", "arguments": ["delayMs": 300]]
        )

        try await Task.sleep(for: .milliseconds(150))
        _ = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: firstSessionID,
            method: "notifications/cancelled",
            params: ["requestId": 42],
            includeID: false
        )

        let firstResponse = try await firstCall
        let firstError = try XCTUnwrap(firstResponse.json["error"] as? [String: Any])
        XCTAssertEqual(firstError["message"] as? String, "Request cancelled.")

        let secondResponse = try await secondCall
        XCTAssertNil(secondResponse.json["error"])
    }

    private func startProductionTransport() async throws -> (MCPNIOHTTPTransport, URL, String, String) {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-cancel.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-cancel.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-cancel.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: approvalStore,
            boundPort: 0,
            exposeDebugTools: true
        )
        let transport = MCPNIOHTTPTransport(protocolService: protocolService)
        try await transport.start(port: 0)
        let port = try XCTUnwrap(transport.boundPort)
        protocolService.rebindLoopbackPort(port)
        let enrollment = try clientRegistry.enroll(displayName: "Cancel")
        let baseURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
        let sessionID = try await Self.initializeSession(
            url: baseURL,
            bearerToken: enrollment.plaintextCredential,
            initializeRequestID: 1
        )
        return (transport, baseURL, enrollment.plaintextCredential, sessionID)
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private struct HTTPJSONResponse {
        let statusCode: Int
        let headers: [String: String]
        let json: [String: Any]
    }

    private static func initializeSession(
        url: URL,
        bearerToken: String,
        initializeRequestID: Int
    ) async throws -> String {
        let response = try await postJSONRPC(
            url: url,
            bearerToken: bearerToken,
            sessionID: nil,
            id: initializeRequestID,
            method: "initialize",
            params: ["protocolVersion": MCPNetworkConstants.preferredProtocolVersion, "capabilities": [:]]
        )
        let sessionID = try XCTUnwrap(response.headers[MCPNetworkConstants.sessionIDHeader.lowercased()])
        _ = try await postJSONRPC(
            url: url,
            bearerToken: bearerToken,
            sessionID: sessionID,
            method: "notifications/initialized",
            params: [:],
            includeID: false
        )
        return sessionID
    }

    private static func postJSONRPC(
        url: URL,
        bearerToken: String,
        sessionID: String?,
        id: Int? = nil,
        method: String,
        params: [String: Any],
        includeID: Bool = true
    ) async throws -> HTTPJSONResponse {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        if includeID, let id {
            payload["id"] = id
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
            request.setValue(
                MCPNetworkConstants.preferredProtocolVersion,
                forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader
            )
            if let port = url.port {
                request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
            }
        }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        let json = data.isEmpty
            ? [:]
            : ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        return HTTPJSONResponse(statusCode: http.statusCode, headers: headers, json: json)
    }
}
#endif
