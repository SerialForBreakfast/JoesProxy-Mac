import XCTest
@testable import JoesProxy

/// MCP `sessions_export` HAR delivery: inline validity, redaction, and file delivery parity.
@MainActor
final class MCPSessionExportHARTests: XCTestCase {
    func testInlineHARExportReturnsValidHAR12() async throws {
        let stack = try await makeStack(sessionCount: 2)
        defer { stack.cleanup() }
        let payload = try await callExport(stack: stack, arguments: ["format": "har"])
        XCTAssertEqual(payload["format"] as? String, "har")
        XCTAssertEqual(payload["sessionCount"] as? Int, 2)
        XCTAssertEqual(payload["truncated"] as? Bool, false)
        let content = try XCTUnwrap(payload["content"] as? String)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        XCTAssertEqual(log["version"] as? String, "1.2")
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(payload["outputPath"] as? String)
    }

    func testInlineHARWithoutIncludeFlagsStripsHeadersAndBodies() async throws {
        let stack = try await makeStack(sessionCount: 1, includeBodies: true)
        defer { stack.cleanup() }
        let payload = try await callExport(stack: stack, arguments: ["format": "har"])
        let content = try XCTUnwrap(payload["content"] as? String)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let entries = try XCTUnwrap((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        let request = try XCTUnwrap(entries.first?["request"] as? [String: Any])
        let headers = try XCTUnwrap(request["headers"] as? [[String: Any]])
        XCTAssertTrue(headers.isEmpty)
        XCTAssertNil(request["postData"])
        let response = try XCTUnwrap(entries.first?["response"] as? [String: Any])
        let responseHeaders = try XCTUnwrap(response["headers"] as? [[String: Any]])
        XCTAssertTrue(responseHeaders.isEmpty)
        let responseContent = try XCTUnwrap(response["content"] as? [String: Any])
        XCTAssertNil(responseContent["text"])
    }

    func testDeliverFileExportsMoreThanInlineSessionCap() async throws {
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-exports-\(UUID().uuidString)", isDirectory: true)
        let stack = try await makeStack(sessionCount: 520, sessionExportDirectory: exportDirectory)
        defer { stack.cleanup() }

        let payload = try await callExport(
            stack: stack,
            arguments: ["format": "har", "deliverFile": true]
        )
        XCTAssertEqual(payload["truncated"] as? Bool, false)
        XCTAssertEqual(payload["sessionCount"] as? Int, 520)
        XCTAssertNil(payload["content"] as? String)
        let outputPath = try XCTUnwrap(payload["outputPath"] as? String)
        XCTAssertTrue(outputPath.hasPrefix(exportDirectory.path))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: outputPath)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.uint16Value & 0o777, 0o600)

        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 520)
        XCTAssertEqual(payload["contentByteCount"] as? Int, data.count)
    }

    func testOversizedInlineAutoSpillsToManagedFile() async throws {
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-spill-\(UUID().uuidString)", isDirectory: true)
        // Large bodies force the encoded MCP envelope over 1 MB without needing 500 sessions.
        let largeBody = Data(repeating: 0x41, count: 200_000)
        let stack = try await makeStack(
            sessionCount: 8,
            includeBodies: true,
            bodyOverride: largeBody,
            sessionExportDirectory: exportDirectory
        )
        defer { stack.cleanup() }

        let payload = try await callExport(
            stack: stack,
            arguments: [
                "format": "har",
                "includeBody": true
            ],
            approveIfNeeded: true
        )
        let outputPath = try XCTUnwrap(payload["outputPath"] as? String)
        XCTAssertNil(payload["content"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((root["log"] as? [String: Any])?["version"] as? String, "1.2")
    }

    // MARK: - Harness

    private struct Stack {
        let protocolService: MCPProtocolService
        let enrollment: MCPClientRegistry.EnrollmentResult
        let transportSessionID: String
        let approvalStore: MCPApprovalStore
        let cleanup: () -> Void
    }

    private func makeStack(
        sessionCount: Int,
        includeBodies: Bool = false,
        bodyOverride: Data? = nil,
        sessionExportDirectory: URL? = nil
    ) async throws -> Stack {
        let policyURL = temporaryURL("policy")
        let clientsURL = temporaryURL("clients")
        let auditURL = temporaryURL("audit")
        let grantsURL = temporaryURL("grants")
        let exportDir = sessionExportDirectory ?? temporaryURL("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: policyURL)
        policyStore.load()
        let clientRegistry = MCPClientRegistry(persistenceURL: clientsURL, credentialStore: credentialStore)
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: auditURL)
        auditStore.load()
        let grantStore = MCPClientGrantStore(persistenceURL: grantsURL)
        grantStore.load()
        let approvalStore = MCPApprovalStore()
        let sessionStore = InMemorySessionStore()
        for index in 0..<sessionCount {
            sessionStore.append(makeSession(index: index, includeBodies: includeBodies, bodyOverride: bodyOverride))
        }
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            grantStore: grantStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: sessionStore),
            approvalStore: approvalStore,
            sessionExportDirectory: exportDir
        )
        let enrollment = try clientRegistry.enroll(displayName: "HARExport", assignedProfileID: .shareable)
        let transportSessionID = try await initializeSession(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential
        )
        return Stack(
            protocolService: protocolService,
            enrollment: enrollment,
            transportSessionID: transportSessionID,
            approvalStore: approvalStore,
            cleanup: {
                try? FileManager.default.removeItem(at: policyURL)
                try? FileManager.default.removeItem(at: clientsURL)
                try? FileManager.default.removeItem(at: auditURL)
                try? FileManager.default.removeItem(at: grantsURL)
                try? FileManager.default.removeItem(at: exportDir)
            }
        )
    }

    private func callExport(
        stack: Stack,
        arguments: [String: Any],
        approveIfNeeded: Bool = false
    ) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "sessions_export",
                "arguments": arguments
            ]
        ])
        var response = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(stack: stack),
            body: body
        )
        var object = try response.jsonBodyObject()
        if approveIfNeeded,
           let error = object["error"] as? [String: Any],
           let data = error["data"] as? [String: Any],
           (data["mcpCode"] as? String) == MCPErrorCode.approvalRequired.rawValue {
            let pending = try XCTUnwrap(stack.approvalStore.pendingRequests.first)
            _ = try stack.approvalStore.approve(requestID: pending.requestID)
            response = await stack.protocolService.handleHTTPRequest(
                method: "POST",
                path: MCPNetworkConstants.endpointPath,
                headers: authenticatedHeaders(stack: stack),
                body: body
            )
            object = try response.jsonBodyObject()
        }
        if let error = object["error"] as? [String: Any] {
            XCTFail("sessions_export failed: \(error)")
            throw NSError(domain: "MCPSessionExportHARTests", code: 1)
        }
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        if let payload = structured["payload"] as? [String: Any] {
            return payload
        }
        return structured
    }

    private func initializeSession(protocolService: MCPProtocolService, bearer: String) async throws -> String {
        let initBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "har-export-test", "version": "1"]
            ]
        ])
        let initResponse = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(bearer)",
                "accept": "application/json, text/event-stream",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25"
            ],
            body: initBody
        )
        let sessionID = try XCTUnwrap(initResponse.headerValue(named: MCPNetworkConstants.sessionIDHeader))
        _ = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(bearer)",
                "accept": "application/json, text/event-stream",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                MCPNetworkConstants.sessionIDHeader.lowercased(): sessionID,
                MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25"
            ],
            body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        )
        return sessionID
    }

    private func authenticatedHeaders(stack: Stack) -> [String: String] {
        [
            "authorization": "Bearer \(stack.enrollment.plaintextCredential)",
            "accept": "application/json, text/event-stream",
            "content-type": "application/json",
            "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
            MCPNetworkConstants.sessionIDHeader.lowercased(): stack.transportSessionID,
            MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25"
        ]
    }

    private func temporaryURL(_ suffix: String, isDirectory: Bool = false) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-har-\(UUID().uuidString)-\(suffix)", isDirectory: isDirectory)
    }

    private func makeSession(index: Int, includeBodies: Bool, bodyOverride: Data?) -> SessionRecord {
        let body = bodyOverride ?? (includeBodies ? Data("body-\(index)".utf8) : nil)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index))
        return SessionRecord(
            request: CapturedRequest(
                method: includeBodies ? "POST" : "GET",
                scheme: .https,
                host: "example.com",
                port: 443,
                path: "/item/\(index)",
                headers: includeBodies
                    ? [HTTPHeaderField(name: "Content-Type", value: "text/plain")]
                    : [HTTPHeaderField(name: "Host", value: "example.com")],
                bodyData: includeBodies ? body : nil,
                bodySize: includeBodies ? body?.count : nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: includeBodies
                    ? [HTTPHeaderField(name: "Content-Type", value: "text/plain")]
                    : [],
                bodyData: includeBodies ? body : nil,
                bodySize: includeBodies ? body?.count : nil
            ),
            state: .completed,
            timing: SessionTiming(startedAt: startedAt, completedAt: startedAt.addingTimeInterval(0.01))
        )
    }
}
