import XCTest
@testable import JoesProxy

@MainActor
final class AuthChainBriefTests: XCTestCase {
    func testZeroSecretAuthContinuityAndEndpointDeduplication() throws {
        let serializer = MCPDisclosureSerializer()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let loginReq = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.example.test",
            port: 443,
            path: "/v1/auth/login",
            headers: [HTTPHeaderField(name: "Authorization", value: "Bearer secret-token-old")],
            bodyData: nil,
            bodySize: nil
        )
        let loginResp = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Set-Cookie", value: "sid=secret-cookie-123; Path=/; HttpOnly")],
            bodyData: nil,
            bodySize: nil
        )
        let s1 = SessionRecord(
            request: loginReq,
            response: loginResp,
            state: .completed,
            timing: SessionTiming(startedAt: baseDate, completedAt: baseDate.addingTimeInterval(0.05))
        )

        // Request 2: uses new bearer token (200), does not echo sid cookie
        let s2 = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.test",
                port: 443,
                path: "/v1/users/12345/items",
                headers: [HTTPHeaderField(name: "Authorization", value: "Bearer secret-token-new")],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: Data("[]".utf8), bodySize: 2),
            state: .completed,
            timing: SessionTiming(startedAt: baseDate.addingTimeInterval(1), completedAt: baseDate.addingTimeInterval(1.2))
        )

        // Request 3: reuses stale old bearer token after rotation and gets 401
        let s3 = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.test",
                port: 443,
                path: "/v1/users/999999/items",
                headers: [HTTPHeaderField(name: "Authorization", value: "Bearer secret-token-old")],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(statusCode: 401, headers: [], bodyData: nil, bodySize: nil),
            state: .completed,
            timing: SessionTiming(startedAt: baseDate.addingTimeInterval(2), completedAt: baseDate.addingTimeInterval(2.5))
        )

        let report = AuthChainBrief.analyze(records: [s1, s2, s3], disclosure: serializer)
        XCTAssertEqual(report.status, "complete")
        XCTAssertEqual(report.inspectedSessionCount, 3)
        XCTAssertTrue(report.tokens.contains { $0.label == "bearer#1" })
        XCTAssertTrue(report.tokens.contains { $0.label == "bearer#2" })
        XCTAssertTrue(report.tokens.contains { $0.label == "cookie:sid#1" })
        XCTAssertTrue(report.anomalies.contains { $0.kind == "credential_rejected" })
        XCTAssertTrue(report.anomalies.contains { $0.kind == "stale_credential_reused_after_rotation" })
        XCTAssertTrue(report.anomalies.contains { $0.kind == "set_cookie_not_echoed" })

        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret-token-old"))
        XCTAssertFalse(encoded.contains("secret-token-new"))
        XCTAssertFalse(encoded.contains("secret-cookie-123"))

        // Also verify MCPSessionSnapshotService filters and endpoint deduplication
        let store = InMemorySessionStore()
        store.append(s1)
        store.append(s2)
        store.append(s3)
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let errorFilter = MCPSessionSnapshotService.ListFilter(statusClass: "4xx")
        XCTAssertFalse(MCPSessionSnapshotService.matchesFilter(s1, filter: errorFilter, disclosure: serializer))
        XCTAssertFalse(MCPSessionSnapshotService.matchesFilter(s2, filter: errorFilter, disclosure: serializer))
        XCTAssertTrue(MCPSessionSnapshotService.matchesFilter(s3, filter: errorFilter, disclosure: serializer))

        let durationFilter = MCPSessionSnapshotService.ListFilter(minDurationMs: 400)
        XCTAssertFalse(MCPSessionSnapshotService.matchesFilter(s2, filter: durationFilter, disclosure: serializer))
        XCTAssertTrue(MCPSessionSnapshotService.matchesFilter(s3, filter: durationFilter, disclosure: serializer))

        let page = try snapshot.page(
            request: .init(limit: 10, cursor: nil, queryDigest: "test", orderingDigest: "seq", filter: nil),
            clientID: "c1",
            policyRevision: MCPPolicyRevision(rawValue: "rev-1")
        )
        let policyStore = MCPPolicyStore(
            persistenceURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        policyStore.load()
        let profile = try policyStore.resolvedProfile(for: .shareable)
        let groups = MCPSessionSnapshotService.deduplicateEndpoints(
            items: page.items,
            profile: profile,
            disclosure: serializer
        )
        // s2 (/v1/users/12345/items) and s3 (/v1/users/999999/items) collapse into one endpoint.
        XCTAssertEqual(groups.count, 2)
        let collapsed = try XCTUnwrap(groups.first { $0.count == 2 })
        XCTAssertEqual(collapsed.normalizedPath, "/v1/users/:id/items")
        XCTAssertEqual(collapsed.statusCounts, ["200": 1, "401": 1])
    }

    func testMCPProtocolWiresSessionsSearchAuthChainAndBriefProjection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("auth-chain-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: dir.appendingPathComponent("policy.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: dir.appendingPathComponent("clients.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: dir.appendingPathComponent("audit.json"))
        auditStore.load()
        let sessionStore = InMemorySessionStore()
        let approvalStore = MCPApprovalStore()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: sessionStore),
            approvalStore: approvalStore
        )

        let body = Data(#"{"items":[{"id":"a1","status":"ok","authToken":"top-secret-token"},{"id":"a2","status":"fail"}]}"#.utf8)
        let s1 = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.test",
                port: 443,
                path: "/v1/items/1",
                headers: [HTTPHeaderField(name: "Authorization", value: "Bearer secret-tok-1")],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(statusCode: 401, headers: [], bodyData: body, bodySize: body.count),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
        sessionStore.append(s1)

        let shareable = try clientRegistry.enroll(displayName: "ShareableClient", assignedProfileID: .shareable)

        func call(
            bearer: String,
            sessionID: String? = nil,
            method: String,
            params: [String: Any]? = nil,
            includeID: Bool = true
        ) async throws -> MCPHTTPResponse {
            var headers: [String: String] = [
                "authorization": "Bearer \(bearer)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                "accept": "application/json, text/event-stream",
                MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25"
            ]
            if let sessionID { headers[MCPNetworkConstants.sessionIDHeader.lowercased()] = sessionID }
            var rpc: [String: Any] = ["jsonrpc": "2.0", "method": method]
            if includeID { rpc["id"] = 1 }
            if let params { rpc["params"] = params }
            return await protocolService.handleHTTPRequest(
                method: "POST",
                path: MCPNetworkConstants.endpointPath,
                headers: headers,
                body: try JSONSerialization.data(withJSONObject: rpc)
            )
        }

        let initResp = try await call(
            bearer: shareable.plaintextCredential,
            method: "initialize",
            params: ["protocolVersion": "2025-11-25", "capabilities": [:]]
        )
        let mcpSession = try XCTUnwrap(initResp.headerValue(named: MCPNetworkConstants.sessionIDHeader))
        _ = try await call(
            bearer: shareable.plaintextCredential,
            sessionID: mcpSession,
            method: "notifications/initialized",
            includeID: false
        )

        // 1. sessions_search with statusClass + deduplicateBy + includeAuthChain
        let searchResp = try await call(
            bearer: shareable.plaintextCredential,
            sessionID: mcpSession,
            method: "tools/call",
            params: [
                "name": "sessions_search",
                "arguments": [
                    "statusClass": "4xx",
                    "deduplicateBy": "endpoint",
                    "includeAuthChain": true
                ]
            ]
        )
        let searchObj = try searchResp.jsonBodyObject()
        let searchResult = try XCTUnwrap(searchObj["result"] as? [String: Any])
        let searchStructured = try XCTUnwrap(searchResult["structuredContent"] as? [String: Any])
        let searchPayload = try XCTUnwrap(searchStructured["payload"] as? [String: Any])
        let endpointGroups = try XCTUnwrap(searchPayload["endpointGroups"] as? [[String: Any]])
        XCTAssertEqual(endpointGroups.first?["normalizedPath"] as? String, "/v1/items/:id")
        let authChain = try XCTUnwrap(searchPayload["authChain"] as? [String: Any])
        let anomalies = try XCTUnwrap(authChain["anomalies"] as? [[String: Any]])
        XCTAssertTrue(anomalies.contains { ($0["kind"] as? String) == "credential_rejected" })
        let encodedSearch = String(decoding: searchResp.body, as: UTF8.self)
        XCTAssertFalse(encodedSearch.contains("secret-tok-1"))

        // 2. response_evidence_brief with fieldPointers + rowLimit through MCP transport
        let briefArgs: [String: Any] = [
            "sessionID": s1.id.uuidString,
            "selectionPointer": "/items",
            "fieldPointers": ["/id", "/status", "/authToken"],
            "rowLimit": 1
        ]
        let pendingResp = try await call(
            bearer: shareable.plaintextCredential,
            sessionID: mcpSession,
            method: "tools/call",
            params: ["name": "response_evidence_brief", "arguments": briefArgs]
        )
        let pendingObj = try pendingResp.jsonBodyObject()
        let pendingError = try XCTUnwrap(pendingObj["error"] as? [String: Any])
        let pendingData = try XCTUnwrap(pendingError["data"] as? [String: Any])
        let requestID = try XCTUnwrap(pendingData["requestID"] as? String)
        _ = try approvalStore.approve(requestID: requestID)

        let briefResp = try await call(
            bearer: shareable.plaintextCredential,
            sessionID: mcpSession,
            method: "tools/call",
            params: ["name": "response_evidence_brief", "arguments": briefArgs]
        )
        let briefObj = try briefResp.jsonBodyObject()
        let briefResult = try XCTUnwrap(briefObj["result"] as? [String: Any])
        let briefStructured = try XCTUnwrap(briefResult["structuredContent"] as? [String: Any])
        let projection = try XCTUnwrap(briefStructured["projection"] as? [String: Any])
        XCTAssertEqual(projection["columns"] as? [String], ["/id", "/status", "/authToken"])
        let rows = try XCTUnwrap(projection["rows"] as? [[Any]])
        XCTAssertEqual(rows.first as? [String], ["a1", "ok", "<redacted>"])
        XCTAssertEqual(projection["omittedRowCount"] as? Int, 1)

        // 3. metadataOnly profile rejects includeAuthChain: true
        let meta = try clientRegistry.enroll(displayName: "MetaClient", assignedProfileID: .metadataOnly)
        let metaInit = try await call(
            bearer: meta.plaintextCredential,
            method: "initialize",
            params: ["protocolVersion": "2025-11-25", "capabilities": [:]]
        )
        let metaSession = try XCTUnwrap(metaInit.headerValue(named: MCPNetworkConstants.sessionIDHeader))
        _ = try await call(
            bearer: meta.plaintextCredential,
            sessionID: metaSession,
            method: "notifications/initialized",
            includeID: false
        )
        let deniedResp = try await call(
            bearer: meta.plaintextCredential,
            sessionID: metaSession,
            method: "tools/call",
            params: ["name": "sessions_search", "arguments": ["includeAuthChain": true]]
        )
        let deniedObj = try deniedResp.jsonBodyObject()
        XCTAssertNotNil(deniedObj["error"])
    }
}
