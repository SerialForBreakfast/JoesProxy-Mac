import Foundation
import XCTest
@testable import JoesProxy

final class JoesProxyCLITests: XCTestCase {
    func testSearchAndInventoryUseToolTransportAndExposeIncompleteCoverage() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic", endpoint: endpoint)
        let store = MemoryCLISessionStore()
        try store.save(.init(endpoint: endpoint.absoluteString, sessionID: "search-fixture",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let app = CLIApplication(credentialStore: credentials, sessionStore: store, appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: session)
            })
        MockCLIURLProtocol.state.configure { request in
            let call = try request.bodyData().jsonObject()
            let name = (call["params"] as? [String: Any])?["name"] as? String
            let status = name == "artifact_inventory" ? "complete" : "incomplete"
            return try .json(status: 200, object: ["jsonrpc": "2.0", "id": call["id"] as Any,
                "result": ["structuredContent": ["status": status, "items": [], "observedCount": 0]]])
        }
        let identity = ["--handle", "fixture", "--snapshot-revision", "r", "--quiet"]
        let inventory = await app.run(arguments: ["artifact", "inventory"] + identity)
        let search = await app.run(arguments: ["artifact", "search", "--dataset", "responseJSON",
            "--status-code", "503", "--literal", "retry_after"] + identity)
        XCTAssertEqual(inventory, .success)
        XCTAssertEqual(search, .partialResult)
        let params = try MockCLIURLProtocol.state.recordedRequests().compactMap { try $0.bodyData().jsonObject()["params"] as? [String: Any] }
        XCTAssertEqual(params.compactMap { $0["name"] as? String }, ["artifact_inventory", "artifact_search"])
        XCTAssertEqual((params.last?["arguments"] as? [String: Any])?["statusCode"] as? Int, 503)
    }

    func testCalculationCLIUsesRealTransportAndPreservesUnavailableExit() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic", endpoint: endpoint)
        let store = MemoryCLISessionStore()
        try store.save(.init(endpoint: endpoint.absoluteString, sessionID: "calculation-session",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        MockCLIURLProtocol.state.configure { request in
            let call = try request.bodyData().jsonObject()
            return try .json(status: 200, object: ["jsonrpc": "2.0", "id": call["id"] as Any,
                "result": ["isError": true, "structuredContent": ["status": "unavailable", "reason": "incomplete_selection", "result": NSNull()]]])
        }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let app = CLIApplication(credentialStore: credentials, sessionStore: store, appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: session)
            })
        let result = await app.run(arguments: ["capture", "calculate", "--session-ids", UUID().uuidString,
            "--dataset", "responseJSON", "--selection-pointer", "/items", "--operation", "rowCount", "--quiet"])
        XCTAssertEqual(result, .partialResult)
        let calls = MockCLIURLProtocol.state.recordedRequests()
        XCTAssertEqual(calls.count, 1)
        let params = try XCTUnwrap(try calls.first?.bodyData().jsonObject()["params"] as? [String: Any])
        XCTAssertEqual(params["name"] as? String, "capture_calculate")
        XCTAssertEqual((params["arguments"] as? [String: Any])?["selectionPointer"] as? String, "/items")
    }

    func testReceiptCollectionOverheadPreservesRequestCount() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let store = MemoryCLISessionStore()
        try store.save(.init(endpoint: endpoint.absoluteString, sessionID: "synthetic", protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        MockCLIURLProtocol.state.configure { request in
            let call = try request.bodyData().jsonObject()
            return try .json(status: 200, object: ["jsonrpc": "2.0", "id": call["id"] as Any,
                "result": ["structuredContent": ["payload": ["analysisReused": true]]]])
        }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let client = MCPCLIClient(endpoint: endpoint, credential: "synthetic", sessionStore: store, timeout: 5, urlSession: session)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ReceiptOverhead-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try XCTUnwrap(CLIReceiptRecorder(invocation: CLIInvocation.parse(["session", "show", "synthetic",
            "--receipt-output", directory.appendingPathComponent("receipt.json").path, "--receipt-workflow", "synthetic",
            "--receipt-version", "1", "--receipt-environment", "MockURLProtocol"])))
        _ = try await client.callTool(name: "response_evidence_brief", arguments: [:])
        var elapsed: [Double] = []
        for enabled in [false, true] {
            client.receiptRecorder = enabled ? recorder : nil
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<20 { _ = try await client.callTool(name: "response_evidence_brief", arguments: [:]) }
            elapsed.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let start = ProcessInfo.processInfo.systemUptime
        try recorder.write()
        let exportMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 41, "One warmup plus twenty calls per configuration")
        XCTAssertEqual(recorder.attempts.count, 20)
        XCTAssertTrue(recorder.attempts.allSatisfy { $0.analysisReused == true && $0.responseBytes != nil })
        let metrics: [String: Any] = ["fixture": "receipt-http-v1", "callsPerConfiguration": 20,
            "disabledMilliseconds": elapsed[0], "enabledMilliseconds": elapsed[1], "exportMilliseconds": exportMilliseconds,
            "receiptBytes": try Data(contentsOf: recorder.destination).count, "extraCalls": 0, "trendOnly": true]
        print("RECEIPT_HTTP_METRIC " + String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), as: UTF8.self))
    }
    func testHTTPSRecoveryInspectionReconnectsWithoutReplayingMutation() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic", endpoint: endpoint)
        let store = MemoryCLISessionStore()
        try store.save(.init(endpoint: endpoint.absoluteString, sessionID: "expired",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(status: 200, headers: [MCPCLIClient.sessionHeader: "reconnected"],
                    object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]])
            case "notifications/initialized":
                return .init(status: 202, headers: [:], body: Data())
            default:
                XCTAssertEqual((object["params"] as? [String: Any])?["name"] as? String, "https_rules_get")
                if request.value(forHTTPHeaderField: MCPCLIClient.sessionHeader) == "expired" {
                    return .init(status: 404, headers: [:], body: Data())
                }
                return try .json(status: 200, object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": ["recovery": ["state": "applied"]]]])
            }
        }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let app = CLIApplication(credentialStore: credentials, sessionStore: store, appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: session)
            })
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/CLIReceipt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("receipt.json").path
        let arguments = ["https", "rules", "get", "--host", "media.example.test", "--quiet",
            "--receipt-output", path, "--receipt-workflow", "recovery", "--receipt-version", "1", "--receipt-environment", "synthetic"]
        let result = await app.run(arguments: arguments)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 4)
        XCTAssertEqual(try store.load(endpoint: endpoint)?.sessionID, "reconnected")
        let receipt = try CLIReceiptRecorder.read(path)
        XCTAssertEqual(receipt.workflow.attempts.count, 4)
        XCTAssertEqual(receipt.workflow.attempts.map(\.outcome), ["failure", "success", "success", "success"])
        XCTAssertEqual(receipt.workflow.attempts.last?.retryOf, "1")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(contents.contains("media.example.test"))
        XCTAssertFalse(contents.contains("reconnected"))
        XCTAssertFalse(contents.contains("Authorization"))
        let repeated = await app.run(arguments: arguments)
        XCTAssertEqual(repeated, .success, "Failed export to existing file cannot change operation result")
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 5, "Export failure cannot add a request")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), contents)
    }

    func testReceiptCapturesTransportAndProtocolFailuresWithoutExtraCalls() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        for fault in ["timeout", "http", "rpc", "malformed", "missing-result", "tool-error", "unexpected-success-status", "resource-invalid", "reuse"] {
            MockCLIURLProtocol.state.reset()
            let store = MemoryCLISessionStore()
            try store.save(.init(endpoint: endpoint.absoluteString, sessionID: "synthetic",
                protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
            MockCLIURLProtocol.state.configure { request in
                if fault == "timeout" { throw URLError(.timedOut) }
                if fault == "http" { return .init(status: 503, headers: [:], body: Data()) }
                if fault == "malformed" { return .init(status: 200, headers: [:], body: Data("private-body".utf8)) }
                let call = try request.bodyData().jsonObject()
                let result: [String: Any]
                switch fault {
                case "rpc": result = ["error": ["code": -32602, "message": "private-error"]]
                case "missing-result": result = [:]
                case "tool-error": result = ["result": ["isError": true, "structuredContent": ["private": "private-body"]]]
                default: result = ["result": ["structuredContent": ["payload": ["analysisReused": true]]]]
                }
                return try .json(status: fault == "unexpected-success-status" ? 201 : 200, object: result.merging(["jsonrpc": "2.0", "id": call["id"] as Any]) { a, _ in a })
            }
            let session = makeMockURLSession()
            defer { session.invalidateAndCancel() }
            let client = MCPCLIClient(endpoint: endpoint, credential: "private-credential", sessionStore: store, timeout: 5, urlSession: session)
            let recorder = try XCTUnwrap(CLIReceiptRecorder(invocation: CLIInvocation.parse(["session", "show", "private-argument",
                "--receipt-output", "unused", "--receipt-workflow", "synthetic", "--receipt-version", "1", "--receipt-environment", "local"])))
            client.receiptRecorder = recorder
            if fault == "resource-invalid" { _ = try? await client.readResource("joesproxy://server/status") }
            else { _ = try? await client.callTool(name: "session_summary", arguments: ["sessionID": "private-argument"]) }
            XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 1)
            let attempt = try XCTUnwrap(recorder.attempts.first)
            XCTAssertEqual(attempt.outcome, fault == "reuse" ? "success" : "failure", fault)
            XCTAssertEqual(attempt.analysisReused, fault == "reuse" ? true : nil)
            if fault == "timeout" { XCTAssertNil(attempt.responseBytes) }
            let encoded = String(decoding: try JSONEncoder().encode(recorder.attempts), as: UTF8.self)
            XCTAssertFalse(encoded.contains("private-"))
        }
    }

    func testHTTPSRecoveryMutationReplyFaultsNeverReplayAndAllowExplicitInspection() async throws {
        for operation in ["set", "restore"] {
            for fault in ["timeout", "disconnect", "stale-session", "upstream-failure", "malformed-reply"] {
                MockCLIURLProtocol.state.reset()
                let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
                let credentials = MemoryCLICredentialStore()
                try credentials.save("synthetic", endpoint: endpoint)
                let store = MemoryCLISessionStore()
                try store.save(.init(endpoint: endpoint.absoluteString, sessionID: "fault-session",
                    protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
                MockCLIURLProtocol.state.configure { _ in
                    switch fault {
                    case "timeout": throw URLError(.timedOut)
                    case "disconnect": throw URLError(.networkConnectionLost)
                    case "stale-session": return .init(status: 404, headers: [:], body: Data())
                    case "upstream-failure": return .init(status: 502, headers: [:], body: Data())
                    default: return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data("invalid".utf8))
                    }
                }
                let session = makeMockURLSession()
                defer { session.invalidateAndCancel() }
                let app = CLIApplication(credentialStore: credentials, sessionStore: store, appLauncher: MockCLIAppLauncher(),
                    clientFactory: { endpoint, credential, store, timeout in
                        MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: session)
                    })
                let id = UUID().uuidString
                var args = ["https", "rules", operation, "--host", "media.example.test", "--recovery-id", id,
                    "--expected-revision", "reviewed", "--scope", "host_and_subdomains_all_clients", "--quiet"]
                if operation == "set" { args += ["--mode", "tunnel"] }
                let result = await app.run(arguments: args)
                XCTAssertNotEqual(result, .success, "\(operation) \(fault)")
                XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 1, "Never reinitialize/replay uncertain mutation")
                MockCLIURLProtocol.state.configure { request in
                    let call = try request.bodyData().jsonObject()
                    return try .json(status: 200, object: ["jsonrpc": "2.0", "id": call["id"] as Any,
                        "result": ["structuredContent": ["recovery": ["state": "conflict", "recoveryID": id]]]])
                }
                let inspected = await app.run(arguments: ["https", "rules", "get", "--host", "media.example.test",
                    "--recovery-id", id, "--quiet"])
                XCTAssertEqual(inspected, .success)
                let calls = try MockCLIURLProtocol.state.recordedRequests().map { try $0.bodyData().jsonObject() }
                XCTAssertEqual(calls.compactMap { ($0["params"] as? [String: Any])?["name"] as? String },
                    ["https_rules_" + operation, "https_rules_get"])
                print("SCRIPTED_RECOVERY operation=\(operation) fault=\(fault) toolCalls=2 hiddenMutations=0")
            }
        }
    }


    func testSessionCLIUsesSharedTransportRecoveryWithoutMutation() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic", endpoint: endpoint)
        let store = MemoryCLISessionStore()
        try store.save(.init(endpoint: endpoint.absoluteString, sessionID: "recovery-session",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        let expected = TransportRecoveryAssessment.assess(nil)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))
        MockCLIURLProtocol.state.configure { request in
            let call = try request.bodyData().jsonObject()
            return try .json(status: 200, object: ["jsonrpc": "2.0", "id": call["id"] as Any,
                "result": ["structuredContent": ["transportDiagnostic": object]]])
        }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let client = MCPCLIClient(endpoint: endpoint, credential: "synthetic", sessionStore: store, timeout: 5, urlSession: session)
        let id = UUID().uuidString
        let payload = try await client.callTool(name: "session_summary", arguments: ["sessionID": id])
        let decoded = try JSONDecoder().decode(TransportRecoveryAssessment.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(payload["transportDiagnostic"])))
        XCTAssertEqual(decoded, expected)
        let app = CLIApplication(credentialStore: credentials, sessionStore: store, appLauncher: MockCLIAppLauncher(),
            clientFactory: { _, _, _, _ in client })
        let exit = await app.run(arguments: ["session", "show", id, "--quiet"])
        XCTAssertEqual(exit, .success)
        let calls = try MockCLIURLProtocol.state.recordedRequests().map { try $0.bodyData().jsonObject() }
        XCTAssertEqual(calls.count, 2)
        for call in calls {
            let params = try XCTUnwrap(call["params"] as? [String: Any])
            XCTAssertEqual(params["name"] as? String, "session_summary")
            let args = try XCTUnwrap(params["arguments"] as? [String: Any])
            XCTAssertEqual(Set(args.keys), ["sessionID"])
        }
    }

    func testBriefCLIUsesExplicitSelectionsAndOneCallPerOperation() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic", endpoint: endpoint)
        let store = MemoryCLISessionStore()
        try store.save(.init(endpoint: endpoint.absoluteString, sessionID: "brief-session",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        MockCLIURLProtocol.state.configure { request in
            let call = try request.bodyData().jsonObject()
            return try .json(status: 200, object: ["jsonrpc": "2.0", "id": call["id"] as Any,
                "result": ["structuredContent": ["status": "complete", "itemCount": 2]]])
        }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let app = CLIApplication(credentialStore: credentials, sessionStore: store, appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: session)
            })
        let id = UUID().uuidString
        let result = await app.run(arguments: ["session", "brief", id, "--selection-pointer", "/items", "--include-structure", "--quiet"])
        XCTAssertEqual(result, .success)
        let calls = MockCLIURLProtocol.state.recordedRequests()
        XCTAssertEqual(calls.count, 1)
        let params = try XCTUnwrap(try calls.first?.bodyData().jsonObject()["params"] as? [String: Any])
        XCTAssertEqual(params["name"] as? String, "response_evidence_brief")
        let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["selectionPointer"] as? String, "/items")
        XCTAssertEqual(arguments["sessionID"] as? String, id)
        XCTAssertEqual(arguments["includeStructure"] as? Bool, true)
        let candidateID = UUID().uuidString
        let comparison = await app.run(arguments: ["investigate", "compare", "--baseline-sessions", id,
            "--candidate-sessions", candidateID, "--selection-pointer", "/items", "--quiet"])
        XCTAssertEqual(comparison, .success)
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 2)
        let compareParams = try XCTUnwrap(try MockCLIURLProtocol.state.recordedRequests().last?.bodyData().jsonObject()["params"] as? [String: Any])
        XCTAssertEqual(compareParams["name"] as? String, "investigation_compare_brief")
        let selected = try XCTUnwrap(compareParams["arguments"] as? [String: Any])
        XCTAssertEqual(selected["baselineSessionIDs"] as? [String], [id])
        XCTAssertEqual(selected["candidateSessionIDs"] as? [String], [candidateID])
        XCTAssertEqual(selected["selectionPointer"] as? String, "/items")
        let digest = String(repeating: "a", count: 64)
        let runBrief = await app.run(arguments: ["run", "brief", id, "--baseline-window-id", id,
            "--modified-window-id", candidateID, "--if-brief-digest", digest, "--quiet"])
        XCTAssertEqual(runBrief, .success)
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 3)
        let runParams = try XCTUnwrap(try MockCLIURLProtocol.state.recordedRequests().last?.bodyData().jsonObject()["params"] as? [String: Any])
        XCTAssertEqual(runParams["name"] as? String, "diagnostic_run_brief")
        XCTAssertEqual((runParams["arguments"] as? [String: Any])?["ifBriefDigest"] as? String, digest)
    }

    func testWorkflowReportRunsOfflineWithoutCredentials() async throws {
        MockCLIURLProtocol.state.reset()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let input = root.appendingPathComponent("memlog/Research/Agent-Efficiency-Workflow-v1.json")
        let report = try CLIWorkflowCostReport.report(Data(contentsOf: input))
        let delta = try XCTUnwrap(report["candidateMinusBaseline"] as? [String: Any])
        XCTAssertEqual(delta["responseBytes"] as? Int, -6208)
        XCTAssertEqual(delta["analysisExecutions"] as? Int, -8)
        let app = CLIApplication(credentialStore: MemoryCLICredentialStore(), sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(), clientFactory: { endpoint, credential, store, timeout in
                XCTFail("Offline reports must not create a network client")
                return MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout)
            })
        let exit = await app.run(arguments: ["efficiency", "report", "--file", input.path, "--quiet"])
        XCTAssertEqual(exit, .success)
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 0)
    }


    func testHTTPSRuleCLIUsesGovernedToolAndExplicitScopeRevision() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic", endpoint: endpoint)
        let store = MemoryCLISessionStore()
        try store.save(.init(endpoint: endpoint.absoluteString, sessionID: "rules-session",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            return try .json(status: 200, object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                "result": ["structuredContent": ["revision": "reviewed"]]])
        }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let app = CLIApplication(credentialStore: credentials, sessionStore: store, appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: session)
            })
        let recoveryID = UUID().uuidString
        let get = await app.run(arguments: ["https", "rules", "get", "--host", "media.example.test", "--recovery-id", recoveryID, "--quiet"])
        XCTAssertEqual(get, .success)
        let set = await app.run(arguments: ["https", "rules", "set", "--host", "media.example.test", "--mode", "tunnel",
            "--expected-revision", "reviewed", "--scope", "host_and_subdomains_all_clients", "--recovery-id", recoveryID, "--quiet"])
        XCTAssertEqual(set, .success)
        let restore = await app.run(arguments: ["https", "rules", "restore", "--host", "media.example.test",
            "--recovery-id", recoveryID, "--expected-revision", "reviewed", "--scope", "host_and_subdomains_all_clients", "--quiet"])
        XCTAssertEqual(restore, .success)
        let calls = try MockCLIURLProtocol.state.recordedRequests().map { try $0.bodyData().jsonObject() }
        XCTAssertEqual(calls.compactMap { ($0["params"] as? [String: Any])?["name"] as? String }, ["https_rules_get", "https_rules_set", "https_rules_restore"])
        let arguments = try XCTUnwrap((calls.last?["params"] as? [String: Any])?["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["recoveryID"] as? String, recoveryID)
        XCTAssertTrue(calls.allSatisfy { (($0["params"] as? [String: Any])?["arguments"] as? [String: Any])?["recoveryID"] as? String == recoveryID })
        XCTAssertEqual(arguments["expectedRevision"] as? String, "reviewed")
        XCTAssertEqual(arguments["scope"] as? String, "host_and_subdomains_all_clients")
        XCTAssertNil(arguments["approval"])
    }

    func testCaptureStatusAndResumeUseSharedToolsWithoutImplicitBodyRead() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic", endpoint: endpoint)
        let store = MemoryCLISessionStore()
        try store.save(.init(endpoint: endpoint.absoluteString, sessionID: "capture-session",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            return try .json(status: 200, object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                "result": ["structuredContent": ["futureBodyCapture": "bounded_capture_available"]]])
        }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let app = CLIApplication(credentialStore: credentials, sessionStore: store, appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: session)
            })
        for command in ["status", "resume"] {
            let result = await app.run(arguments: ["capture", command, "--quiet"])
            XCTAssertEqual(result, .success)
        }
        let calls = try MockCLIURLProtocol.state.recordedRequests().map { try $0.bodyData().jsonObject() }
        XCTAssertEqual(calls.compactMap { ($0["params"] as? [String: Any])?["name"] as? String },
                       ["capture_status", "capture_resume"])
        for call in calls {
            let params = try XCTUnwrap(call["params"] as? [String: Any])
            XCTAssertTrue(try XCTUnwrap(params["arguments"] as? [String: Any]).isEmpty)
        }
    }

    func testFailedInitializationIsNotPublishedAndExplicitRetryUsesFreshHandshake() async throws {
        for failure in ["timeout", "unauthorized", "unavailable"] {
            MockCLIURLProtocol.state.reset()
            let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
            let store = MemoryCLISessionStore()
            MockCLIURLProtocol.state.configure { request in
                let object = try request.bodyData().jsonObject()
                if object["method"] as? String == "initialize" {
                    return try .json(status: 200, headers: [MCPCLIClient.sessionHeader: "unready"],
                        object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                            "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]])
                }
                XCTAssertEqual(object["method"] as? String, "notifications/initialized")
                if failure == "timeout" { throw URLError(.timedOut) }
                return .init(status: failure == "unauthorized" ? 401 : 503, headers: [:], body: Data())
            }
            let session = makeMockURLSession()
            defer { session.invalidateAndCancel() }
            let client = MCPCLIClient(endpoint: endpoint, credential: "synthetic", sessionStore: store,
                timeout: 5, urlSession: session)
            do {
                _ = try await client.callTool(name: "effect_bundle_prepare", arguments: [:], retryOnStaleSession: false)
                XCTFail("Failed handshake must prevent preparation: \(failure)")
            } catch is CLIError { }
            XCTAssertNil(try store.load(endpoint: endpoint))
            XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 2)

            // Same client, explicit caller retry. No tool was sent in the interrupted attempt.
            MockCLIURLProtocol.state.reset()
            MockCLIURLProtocol.state.configure { request in
                let object = try request.bodyData().jsonObject()
                switch object["method"] as? String {
                case "initialize":
                    return try .json(status: 200, headers: [MCPCLIClient.sessionHeader: "ready"],
                        object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                            "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]])
                case "notifications/initialized":
                    XCTAssertNil(try store.load(endpoint: endpoint), "Do not persist before acknowledgement")
                    return .init(status: 202, headers: [:], body: Data())
                case "tools/call":
                    XCTAssertEqual(request.value(forHTTPHeaderField: MCPCLIClient.sessionHeader), "ready")
                    return try .json(status: 200, object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": ["prepared": true]]])
                default:
                    XCTFail("Unexpected request")
                    return .init(status: 500, headers: [:], body: Data())
                }
            }
            let result = try await client.callTool(name: "effect_bundle_prepare", arguments: [:], retryOnStaleSession: false)
            XCTAssertEqual(result["prepared"] as? Bool, true)
            XCTAssertEqual(try store.load(endpoint: endpoint)?.sessionID, "ready")
            XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 3)
        }
    }

    func testUnexpectedHTTPFailureIsBoundedAndDoesNotEchoServerBodyOrReplay() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let store = MemoryCLISessionStore()
        try store.save(.init(endpoint: endpoint.absoluteString, sessionID: "ready",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        MockCLIURLProtocol.state.configure { _ in
            .init(status: 502, headers: [:], body: Data(String(repeating: "private-sentinel", count: 10_000).utf8))
        }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let client = MCPCLIClient(endpoint: endpoint, credential: "synthetic", sessionStore: store,
            timeout: 5, urlSession: session)
        do {
            _ = try await client.callTool(name: "effect_bundle_advance", arguments: [:], retryOnStaleSession: false)
            XCTFail("Expected upstream HTTP error")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, .serverUnavailable)
            XCTAssertTrue(error.message.contains("502"))
            XCTAssertTrue(error.message.contains("No automatic retry"))
            XCTAssertFalse(error.message.contains("private-sentinel"))
            XCTAssertLessThan(error.message.utf8.count, 1024)
        }
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 1)
        XCTAssertEqual(try store.load(endpoint: endpoint)?.sessionID, "ready")
    }

    func testExplicitWindowCommandsPreserveMCPArgumentsWithoutImplicitActions() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic", endpoint: endpoint)
        let store = MemoryCLISessionStore()
        try store.save(CLIPersistedSession(endpoint: endpoint.absoluteString, sessionID: "window-session",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        let run = UUID().uuidString, bundle = UUID().uuidString, baseline = UUID().uuidString, modified = UUID().uuidString
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            return try .json(status: 200, object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                "result": ["structuredContent": ["schemaVersion": 1, "payload": ["windowID": baseline]]]])
        }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let app = CLIApplication(credentialStore: credentials, sessionStore: store, appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: session)
            })
        let commands = [
            ["run", "window", "begin", run, "--bundle-id", bundle, "--mode", "baseline", "--quiet"],
            ["run", "window", "end", baseline, "--quiet"],
            ["run", "window", "begin", run, "--bundle-id", bundle, "--mode", "modified", "--quiet"],
            ["run", "window", "end", modified, "--quiet"],
            ["effect", "bundle", "compare", "--baseline-window-id", baseline, "--modified-window-id", modified, "--quiet"]
        ]
        for command in commands {
            let result = await app.run(arguments: command)
            XCTAssertEqual(result, .success)
        }
        let requests = MockCLIURLProtocol.state.recordedRequests()
        XCTAssertEqual(requests.count, 5, "No implicit activation, cleanup, historical query or retry")
        guard requests.count == 5 else { return }
        let parameters = try requests.map { try XCTUnwrap($0.bodyData().jsonObject()["params"] as? [String: Any]) }
        XCTAssertEqual(parameters.compactMap { $0["name"] as? String },
            ["diagnostic_run_window_begin", "diagnostic_run_window_end", "diagnostic_run_window_begin", "diagnostic_run_window_end", "effect_bundle_compare"])
        XCTAssertEqual(parameters[0]["arguments"] as? [String: String], ["runID": run, "bundleID": bundle, "mode": "baseline"])
        XCTAssertEqual(parameters[4]["arguments"] as? [String: String], ["baselineWindowID": baseline, "modifiedWindowID": modified])
    }

    func testBundleAdvanceTransportsExactRunAndPhaseWithoutRetry() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic", endpoint: endpoint)
        let store = MemoryCLISessionStore()
        try store.save(CLIPersistedSession(endpoint: endpoint.absoluteString, sessionID: "phase-session",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        let bundle = UUID().uuidString, activation = UUID().uuidString, phase = UUID().uuidString
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            let params = try XCTUnwrap(object["params"] as? [String: Any])
            XCTAssertEqual(params["name"] as? String, "effect_bundle_advance")
            let arguments = try XCTUnwrap(params["arguments"] as? [String: String])
            XCTAssertEqual(arguments, ["bundleID": bundle, "activationID": activation, "expectedPhaseID": phase])
            return try .json(status: 200, object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                "result": ["structuredContent": ["isServing": false]]])
        }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let app = CLIApplication(credentialStore: credentials, sessionStore: store, appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: session)
            })
        let result = await app.run(arguments: ["effect", "bundle", "advance", bundle,
            "--activation-id", activation, "--expected-phase-id", phase, "--quiet"])
        XCTAssertEqual(result, .success)
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 1)
    }
    func testLiveDocumentationConnectionFailureDoesNotFallbackOrLaunch() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic", endpoint: endpoint)
        let sessionStore = MemoryCLISessionStore()
        try sessionStore.save(CLIPersistedSession(endpoint: endpoint.absoluteString, sessionID: "docs-session",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        MockCLIURLProtocol.state.configure { _ in throw URLError(.cannotConnectToHost) }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let launcher = MockCLIAppLauncher()
        let app = CLIApplication(credentialStore: credentials, sessionStore: sessionStore, appLauncher: launcher,
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: session)
            })
        let result = await app.run(arguments: ["docs", "list", "--source", "live", "--quiet"])
        XCTAssertEqual(result, .serverUnavailable)
        XCTAssertEqual(launcher.startRequestCount, 0)
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 1)
    }

    func testOfflineDocumentationDoesNotReadCredentialsOrLaunchApp() async throws {
        let credentials = MemoryCLICredentialStore()
        let launcher = MockCLIAppLauncher()
        let app = CLIApplication(credentialStore: credentials, sessionStore: MemoryCLISessionStore(), appLauncher: launcher)
        for arguments in [["docs", "list", "--quiet"],
                          ["docs", "search", "--query", "missing body", "--quiet"],
                          ["docs", "read", "--topic", "workflow-mocking", "--section", "observe", "--quiet"]] {
            let result = await app.run(arguments: arguments)
            XCTAssertEqual(result, .success)
        }
        XCTAssertEqual(credentials.loadCount, 0)
        XCTAssertEqual(launcher.startRequestCount, 0)
    }

    func testPreparationErrorRetainsBoundedRecoveryDetailsWithoutRetry() async throws {
        MockCLIURLProtocol.state.reset()
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let store = MemoryCLISessionStore()
        try store.save(CLIPersistedSession(endpoint: endpoint.absoluteString, sessionID: "prepared-session",
            protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
        MockCLIURLProtocol.state.configure { _ in
            try .json(status: 200, object: ["jsonrpc": "2.0", "id": 1,
                "error": ["code": -32000, "message": "Correct the image bookmark.",
                    "data": ["mcpCode": "malformed_request", "details": [
                        "phase": "preparation", "field": "images[1].localFileBookmarkRef",
                        "reason": "invalidReference", "recommendedAction": "Select the image again.",
                        "nextTool": "effect_bundle_prepare", "privateExtra": "synthetic-secret"]]]])
        }
        let session = makeMockURLSession()
        defer { session.invalidateAndCancel() }
        let client = MCPCLIClient(endpoint: endpoint, credential: "synthetic", sessionStore: store, timeout: 1, urlSession: session)
        do {
            _ = try await client.callTool(name: "effect_bundle_prepare", arguments: [:])
            XCTFail("Expected a preparation error")
        } catch let error as CLIError {
            guard case .invalidPreparation(_, let details) = error else { return XCTFail("Wrong error class") }
            XCTAssertEqual(error.exitCode, .invalidArguments)
            XCTAssertEqual(details["field"], "images[1].localFileBookmarkRef")
            XCTAssertEqual(details["nextTool"], "effect_bundle_prepare")
            XCTAssertNil(details["privateExtra"])
        }
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 1)
    }

    func testInterruptedApplyReportsUncertaintyWithoutRetryOrSensitiveTransportDetails() async throws {
        for code in [URLError.Code.timedOut, .cannotConnectToHost, .networkConnectionLost] {
            MockCLIURLProtocol.state.reset()
            let endpoint = URL(string: "http://127.0.0.1:9091/mcp?private=synthetic-secret")!
            let store = MemoryCLISessionStore()
            try store.save(CLIPersistedSession(endpoint: endpoint.absoluteString, sessionID: "retained-session",
                protocolVersion: MCPCLIClient.preferredProtocolVersion, updatedAt: Date()))
            MockCLIURLProtocol.state.configure { _ in
                throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "synthetic-secret"])
            }
            let session = makeMockURLSession()
            defer { session.invalidateAndCancel() }
            let client = MCPCLIClient(endpoint: endpoint, credential: "synthetic-secret", sessionStore: store,
                timeout: 1, urlSession: session)
            do {
                _ = try await client.callTool(name: "apply_create_map_local", arguments: ["proposalToken": "synthetic"])
                XCTFail("Expected a transport failure")
            } catch let error as CLIError {
                XCTAssertEqual(error.exitCode, code == .timedOut ? .timedOut : .serverUnavailable)
                XCTAssertTrue(error.message.contains("inspect status"))
                XCTAssertTrue(error.message.contains("No automatic retry"))
                XCTAssertFalse(error.message.contains("synthetic-secret"))
            }
            XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 1)
            XCTAssertEqual(try store.load(endpoint: endpoint)?.sessionID, "retained-session")
        }
    }

    func testMultiImageBindingsKeepOpaqueReferencesAndRejectAmbiguity() throws {
        let input: [[String: String]] = [
            ["itemPointer": "/poster", "file": #filePath],
            ["itemPointer": "/hero", "file": #filePath,
             "deliveryURL": "https://images.example.test/hero.png?format=webp", "imageReference": "files/hero.png"],
            ["itemPointer": "/logo", "localFileBookmarkRef": "b3BhcXVl"]
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let bindings = try CLIImageBindings.prepare(text)
        XCTAssertEqual(bindings.count, 3)
        XCTAssertTrue(bindings.allSatisfy { $0["file"] == nil })
        XCTAssertTrue(bindings.allSatisfy { $0["localFileBookmarkRef"] is String })
        XCTAssertEqual(bindings[1]["deliveryURL"] as? String, input[1]["deliveryURL"])
        XCTAssertEqual(bindings[2]["localFileBookmarkRef"] as? String, "b3BhcXVl")
        for invalid in [
            #"[{"itemPointer":"/a","localFileBookmarkRef":"b3BhcXVl"},{"itemPointer":"/a","localFileBookmarkRef":"b3BhcXVl"}]"#,
            #"[{"itemPointer":"/a","file":"a.png","localFileBookmarkRef":"b3BhcXVl"}]"#,
            #"[{"itemPointer":"/a","localFileBookmarkRef":"b3BhcXVl","deliveryURL":"https://images.example.test/a.png"}]"#,
            #"[{"itemPointer":"/a","localFileBookmarkRef":"b3BhcXVl","unexpected":true}]"#,
            #"[{"itemPointer":"/a","localFileBookmarkRef":""}]"#,
            String(repeating: " ", count: 65_537)
        ] {
            XCTAssertThrowsError(try CLIImageBindings.prepare(invalid))
        }
        let tooMany = (0..<17).map { ["itemPointer": "/image\($0)", "localFileBookmarkRef": "b3BhcXVl"] }
        XCTAssertThrowsError(try CLIImageBindings.prepare(String(
            decoding: JSONSerialization.data(withJSONObject: tooMany), as: UTF8.self)))
        XCTAssertTrue(try CLIImageBindings.prepare("[]").isEmpty)
        let standalone = try CLIImageBindings.prepare(#"[{"localFileBookmarkRef":"b3BhcXVl"},{"localFileBookmarkRef":"b3BhcXVl"}]"#)
        XCTAssertEqual(standalone.count, 2)
        XCTAssertTrue(standalone.allSatisfy { $0["itemPointer"] == nil })
        XCTAssertThrowsError(try CLIImageBindings.prepare("not JSON"))
    }

    func testCoordinatedPrepareForwardsMixedDraftAndRelativeImageBinding() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic-token", endpoint: endpoint)
        var draft = #"{"collectionPointer":"/items","item":{"showId":3,"image":""},"identityPointers":["/showId"],"identityPresence":"wherePresent"}"#
        var calls = 0
        var expectedImageCount = 1
        var expectedRelated: String?
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(status: 200, headers: [MCPCLIClient.sessionHeader: "mock-prepare"],
                    object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                             "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]])
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                calls += 1
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                XCTAssertEqual(params["name"] as? String, "effect_bundle_prepare")
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                XCTAssertEqual(arguments["draftJSON"] as? String, draft)
                XCTAssertEqual(arguments["clientAddress"] as? String, "192.0.2.10")
                XCTAssertEqual(arguments["relatedResponsesJSON"] as? String, expectedRelated)
                let images = try XCTUnwrap(arguments["images"] as? [[String: Any]])
                XCTAssertEqual(images.count, expectedImageCount)
                XCTAssertTrue(images.allSatisfy { $0["file"] == nil })
                let image = try XCTUnwrap(images.first)
                XCTAssertEqual(image["deliveryURL"] as? String, "https://images.example.test/thumbs/mock.png")
                XCTAssertEqual(image["imageReference"] as? String, "files/mock.png")
                XCTAssertNotNil(image["localFileBookmarkRef"] as? String)
                XCTAssertNil(image["originalURL"])
                XCTAssertNil(image["path"])
                return try .json(status: 200, object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": ["schemaVersion": 1, "payload": ["state": "prepared", "isServing": false]]]])
            default: return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let session = makeMockURLSession()
        let application = CLIApplication(credentialStore: credentials, sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(), clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store,
                    timeout: timeout, urlSession: session)
            })
        // Client transport mints an opaque reference; image decoding belongs to shared preparation.
        let arguments = ["effect", "bundle", "prepare", "--session-id", UUID().uuidString,
            "--name", "Synthetic carousel", "--idempotency-key", "mixed-carousel", "--client-address", "192.0.2.10",
            "--draft", draft, "--image-file", #filePath, "--image-pointer", "/image",
            "--image-delivery-url", "https://images.example.test/thumbs/mock.png",
            "--image-reference", "files/mock.png", "--quiet"]
        let result = await application.run(arguments: arguments)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(calls, 1)
        let conflicting = await application.run(arguments: arguments + ["--retain-image-url", "https://images.example.test/old.png"])
        XCTAssertNotEqual(conflicting, .success)
        XCTAssertEqual(calls, 1, "Conflicting bindings must never reach the server")
        let multiple: [[String: String]] = [
            ["itemPointer": "/image", "file": #filePath,
             "deliveryURL": "https://images.example.test/thumbs/mock.png", "imageReference": "files/mock.png"],
            ["file": #filePath]
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: multiple), as: UTF8.self)
        let singleImageIndex = try XCTUnwrap(arguments.firstIndex(of: "--image-file"))
        expectedRelated = #"[{"sessionID":"00000000-0000-0000-0000-000000000002","targetSessionID":"00000000-0000-0000-0000-000000000003","edits":[],"images":[{"pointer":"/logo","assetID":"image-1"}],"identityLinks":[{"pointer":"/id","primaryPointer":"/items/0/id"}]}]"#
        let multiArguments = Array(arguments.prefix(singleImageIndex))
            + ["--images", json, "--related-responses", try XCTUnwrap(expectedRelated), "--quiet"]
        expectedImageCount = 2
        let multiResult = await application.run(arguments: multiArguments)
        XCTAssertEqual(multiResult, .success)
        XCTAssertEqual(calls, 2)
        let mixedResult = await application.run(arguments: arguments + ["--images", json])
        XCTAssertNotEqual(mixedResult, .success)
        XCTAssertEqual(calls, 2, "Mixed authoring modes must not reach the server")
        expectedRelated = #" [{"sessionID":"00000000-0000-0000-0000-000000000002","targetPath":"/items/test-456?language=de","edits":[],"images":[{"pointer":"/logo","assetID":"image-1"}],"identityLinks":[{"pointer":"/id","primaryPointer":"/items/0/id"}]}]"#
        let explicitArguments = Array(arguments.prefix(singleImageIndex))
            + ["--images", json, "--related-responses", try XCTUnwrap(expectedRelated), "--quiet"]
        let explicitResult = await application.run(arguments: explicitArguments)
        XCTAssertEqual(explicitResult, .success)
        XCTAssertEqual(calls, 3, "CLI must forward the explicit target unchanged, without probing it")
        draft = #"{"collectionPointer":"/items","templateIndex":0,"identityPointers":["/id"],"expansionItems":[{"edits":[{"pointer":"/id","value":"first"}]},{"edits":[{"pointer":"/id","value":"second"}],"images":[{"pointer":"/image","assetID":"image-1"}]}]}"#
        var batchArguments = explicitArguments
        batchArguments[try XCTUnwrap(batchArguments.firstIndex(of: "--draft")) + 1] = draft
        let batchResult = await application.run(arguments: batchArguments)
        XCTAssertEqual(batchResult, .success)
        XCTAssertEqual(calls, 4, "Batch JSON and asset references must reach shared preparation unchanged")
    }

    override func setUp() {
        super.setUp()
        MockCLIURLProtocol.state.reset()
    }

    func testInvocationDefaultsToLoopbackAndHumanOutput() throws {
        let invocation = try CLIInvocation.parse(["capture", "digest"])

        XCTAssertEqual(invocation.command, ["capture", "digest"])
        XCTAssertEqual(invocation.endpointURL.absoluteString, "http://127.0.0.1:9091/mcp")
        XCTAssertEqual(invocation.outputMode, .human)
        XCTAssertEqual(invocation.timeout, 45)
    }

    func testPreparedRevisionImportUsesExistingBundleTool() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentials = MemoryCLICredentialStore()
        try credentials.save("synthetic-token", endpoint: endpoint)
        let revisionID = UUID().uuidString
        var calls = 0
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(status: 200, headers: [MCPCLIClient.sessionHeader: "revision-import"],
                    object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                             "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]])
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                calls += 1
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let expected = calls == 1 ? "effect_bundle_import" : (calls >= 4 ? "effect_bundle_retire_preparation" : "effect_bundle_inspect")
                XCTAssertEqual(params["name"] as? String, expected)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                if calls == 3 {
                    XCTAssertEqual(arguments["bundleID"] as? String, revisionID)
                    XCTAssertEqual(arguments["afterMarker"] as? String, "42")
                } else {
                    XCTAssertEqual(arguments["revisionID"] as? String, revisionID)
                }
                XCTAssertNil(arguments["packagePath"])
                return try .json(status: 200, object: ["jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": ["schemaVersion": 1, "payload": ["state": "inactive", "isServing": false]]]])
            default: return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let session = makeMockURLSession()
        let application = CLIApplication(credentialStore: credentials, sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(), clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store,
                    timeout: timeout, urlSession: session)
            })
        let result = await application.run(arguments: ["effect", "bundle", "import", "--revision-id", revisionID, "--quiet"])
        XCTAssertEqual(result, .success)
        XCTAssertEqual(calls, 1)
        let invalid = await application.run(arguments: ["effect", "bundle", "import", "--revision-id", revisionID,
            "--file", "synthetic.jproxy-effects", "--quiet"])
        XCTAssertNotEqual(invalid, .success)
        XCTAssertEqual(calls, 1, "Ambiguous input must not invoke an import")
        let inspected = await application.run(arguments: ["effect", "bundle", "inspect", "--revision-id", revisionID, "--quiet"])
        XCTAssertEqual(inspected, .success)
        XCTAssertEqual(calls, 2)
        let evidence = await application.run(arguments: ["effect", "bundle", "inspect", revisionID,
            "--after-marker", "42", "--quiet"])
        XCTAssertEqual(evidence, .success)
        XCTAssertEqual(calls, 3)
        let badMarker = await application.run(arguments: ["effect", "bundle", "inspect", revisionID,
            "--after-marker", "-1", "--quiet"])
        XCTAssertNotEqual(badMarker, .success)
        XCTAssertEqual(calls, 3)
        let ambiguousInspection = await application.run(arguments: ["effect", "bundle", "inspect", "--revision-id", revisionID,
            "--bundle-id", UUID().uuidString, "--quiet"])
        XCTAssertNotEqual(ambiguousInspection, .success)
        XCTAssertEqual(calls, 3)
        for _ in 0..<2 {
            let retired = await application.run(arguments: ["effect", "bundle", "retire-preparation",
                "--revision-id", revisionID, "--quiet"])
            XCTAssertEqual(retired, .success)
        }
        XCTAssertEqual(calls, 5)
        let invalidRetirement = await application.run(arguments: ["effect", "bundle", "retire-preparation",
            "--revision-id", "invalid", "--quiet"])
        XCTAssertNotEqual(invalidRetirement, .success)
        XCTAssertEqual(calls, 5)
    }

    func testEfficientReadCommandsUseStructuredNegotiationAndExpectedTools() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        let batchURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("read-batch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: batchURL) }
        try Data(#"[{"name":"capture_digest"}]"#.utf8).write(to: batchURL)

        var calledTools: [String] = []
        var snapshotArguments: [String: Any] = [:]
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let capabilities = try XCTUnwrap(params["capabilities"] as? [String: Any])
                let experimental = try XCTUnwrap(capabilities["experimental"] as? [String: Any])
                let joesProxy = try XCTUnwrap(experimental["joesproxy"] as? [String: Any])
                XCTAssertEqual(joesProxy["structuredResultsOnly"] as? Bool, true)
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "efficient-read-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                calledTools.append(name)
                if name == "investigation_snapshot" {
                    snapshotArguments = params["arguments"] as? [String: Any] ?? [:]
                }
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": ["schemaVersion": 1, "payload": ["state": "ok"]]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let snapshotExit = await application.run(
            arguments: [
                "investigate", "snapshot", "--limit", "5",
                "--if-state-token", "capture-state-1", "--quiet"
            ]
        )
        let evidenceExit = await application.run(
            arguments: ["evidence", "get", "evidence-1", "--quiet"]
        )
        let batchExit = await application.run(
            arguments: ["read", "batch", "--file", batchURL.path, "--quiet"]
        )
        XCTAssertEqual(snapshotExit, .success)
        XCTAssertEqual(evidenceExit, .success)
        XCTAssertEqual(batchExit, .success)
        XCTAssertEqual(calledTools, ["investigation_snapshot", "evidence_get", "read_batch"])
        XCTAssertEqual(snapshotArguments["limit"] as? Int, 5)
        XCTAssertEqual(snapshotArguments["ifStateToken"] as? String, "capture-state-1")
    }

    func testWatchSessionsUsesCaptureNotificationsWithoutIdlePolling() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var sessionReadSequences: [UInt64] = []
        var streamRequestCount = 0

        MockCLIURLProtocol.state.configure { request in
            if request.httpMethod == "GET" {
                streamRequestCount += 1
                return MockCLIURLResponse(
                    status: 200,
                    headers: ["Content-Type": "text/event-stream"],
                    body: Data("""
                    data: {"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"joesproxy://capture/summary","captureHighWaterSequence":12}}

                    data: {"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"joesproxy://capture/summary","captureHighWaterSequence":12}}

                    data: {"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"joesproxy://capture/summary"}}

                    """.utf8)
                )
            }

            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "watch-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "resources/subscribe":
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": [:] as [String: Any]
                ])
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                XCTAssertEqual(params["name"] as? String, "sessions_list")
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                let sequence = (arguments["sinceSequence"] as? NSNumber)?.uint64Value ?? 0
                sessionReadSequences.append(sequence)
                let items: [[String: Any]]
                let hasMore: Bool
                switch sessionReadSequences.count {
                case 1:
                    items = []
                    hasMore = false
                case 2:
                    items = [["id": UUID().uuidString, "captureSequence": 11]]
                    hasMore = true
                case 3:
                    items = [["id": UUID().uuidString, "captureSequence": 12]]
                    hasMore = false
                default:
                    items = []
                    hasMore = false
                }
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": [
                        "structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["items": items, "hasMore": hasMore]
                        ]
                    ]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }

        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exit = await application.run(arguments: [
            "watch", "sessions", "--since-sequence", "10", "--quiet", "--timeout", "1"
        ])

        XCTAssertEqual(exit, .success)
        XCTAssertEqual(streamRequestCount, 1)
        XCTAssertEqual(sessionReadSequences, [10, 10, 11, 12])
    }

    func testHLSFixtureLifecycleInvocationParsesOptions() throws {
        let prepare = try CLIInvocation.parse([
            "hls", "fixture", "prepare-start", "--profile-id", "baseline-aligned-codecs",
            "--presentation-mode", "vodStatic"
        ])
        XCTAssertEqual(prepare.command, ["hls", "fixture", "prepare-start"])
        XCTAssertEqual(prepare.options["profile-id"], "baseline-aligned-codecs")
        XCTAssertEqual(prepare.options["presentation-mode"], "vodStatic")

        let status = try CLIInvocation.parse([
            "hls", "fixture", "status", "--run-id", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ])
        XCTAssertEqual(status.command, ["hls", "fixture", "status"])
        XCTAssertEqual(status.options["run-id"], "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")

        let stopPositional = try CLIInvocation.parse([
            "hls", "fixture", "stop", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ])
        XCTAssertEqual(stopPositional.command, ["hls", "fixture", "stop", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"])

        let apply = try CLIInvocation.parse([
            "hls", "fixture", "apply-start", "proposal-token-1", "--wait-for-approval"
        ])
        XCTAssertEqual(apply.command, ["hls", "fixture", "apply-start", "proposal-token-1"])
        XCTAssertTrue(apply.flags.contains("wait-for-approval"))
    }

    func testOpenAPIPackInvocationParsesCompositeWorkflow() throws {
        let prepare = try CLIInvocation.parse([
            "openapi", "pack", "prepare",
            "--file", "/tmp/catalog-v1.json",
            "--host", "catalog.example.invalid",
            "--scheme", "http",
            "--replace-conflicts"
        ])
        XCTAssertEqual(prepare.command, ["openapi", "pack", "prepare"])
        XCTAssertEqual(prepare.options["file"], "/tmp/catalog-v1.json")
        XCTAssertEqual(prepare.options["host"], "catalog.example.invalid")
        XCTAssertTrue(prepare.flags.contains("replace-conflicts"))

        let apply = try CLIInvocation.parse([
            "openapi", "pack", "apply", "proposal-token-1", "--wait-for-approval"
        ])
        XCTAssertEqual(apply.command, ["openapi", "pack", "apply", "proposal-token-1"])
        XCTAssertTrue(apply.flags.contains("wait-for-approval"))

        let status = try CLIInvocation.parse(["openapi", "pack", "status"])
        XCTAssertEqual(status.command, ["openapi", "pack", "status"])
        let stop = try CLIInvocation.parse([
            "openapi", "pack", "stop", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ])
        XCTAssertEqual(stop.command.last, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    func testHLSSubstitutionInvocationParsesCompositeWorkflow() throws {
        let prepare = try CLIInvocation.parse([
            "hls", "substitute", "prepare",
            "--session-id", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "--profile-id", "player-qa-widescreen-v1",
            "--scope", "selected",
            "--intent", "deliberateFault",
            "--loop-boundary", "omitDiscontinuity",
            "--time-shift-mode", "warmDVR",
            "--window-segments", "6"
        ])
        XCTAssertEqual(prepare.command, ["hls", "substitute", "prepare"])
        XCTAssertEqual(prepare.options["scope"], "selected")
        XCTAssertEqual(prepare.options["intent"], "deliberateFault")
        XCTAssertEqual(prepare.options["loop-boundary"], "omitDiscontinuity")
        XCTAssertEqual(prepare.options["time-shift-mode"], "warmDVR")
        XCTAssertEqual(prepare.options["window-segments"], "6")

        let apply = try CLIInvocation.parse([
            "hls", "substitute", "apply", "proposal-token-1", "--wait-for-approval"
        ])
        XCTAssertEqual(apply.command, ["hls", "substitute", "apply", "proposal-token-1"])
        XCTAssertTrue(apply.flags.contains("wait-for-approval"))

        let status = try CLIInvocation.parse(["hls", "substitute", "status"])
        XCTAssertEqual(status.command, ["hls", "substitute", "status"])
        let stop = try CLIInvocation.parse([
            "hls", "substitute", "stop", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ])
        XCTAssertEqual(stop.command.last, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    func testBlockAndThrottleInvocationParsesOptions() throws {
        let blockPrepare = try CLIInvocation.parse([
            "block", "prepare",
            "--method", "GET",
            "--host", "fixture-abc.hls.joesproxy.invalid",
            "--path", "/audio-ad/seg-003.ts",
            "--match-mode", "pathSuffix"
        ])
        XCTAssertEqual(blockPrepare.command, ["block", "prepare"])
        XCTAssertEqual(blockPrepare.options["match-mode"], "pathSuffix")

        let blockApply = try CLIInvocation.parse([
            "block", "apply", "proposal-token-2", "--enable-after"
        ])
        XCTAssertEqual(blockApply.command, ["block", "apply", "proposal-token-2"])
        XCTAssertTrue(blockApply.flags.contains("enable-after"))

        let throttlePrepare = try CLIInvocation.parse([
            "throttle", "prepare", "--preset-id", "mobile-3g"
        ])
        XCTAssertEqual(throttlePrepare.command, ["throttle", "prepare"])
        XCTAssertEqual(throttlePrepare.options["preset-id"], "mobile-3g")

        let throttleApply = try CLIInvocation.parse([
            "throttle", "apply", "proposal-token-3", "--wait-for-approval"
        ])
        XCTAssertEqual(throttleApply.command, ["throttle", "apply", "proposal-token-3"])
    }

    func testBookmarkInvocationParsesOptions() throws {
        let bookmarkCreate = try CLIInvocation.parse([
            "bookmark", "create",
            "--method", "GET",
            "--host", "api.example.com",
            "--path", "/v1/widgets",
            "--name", "Widgets list",
            "--scheme", "https",
            "--port", "8443",
            "--match-mode", "pathPrefix"
        ])
        XCTAssertEqual(bookmarkCreate.command, ["bookmark", "create"])
        XCTAssertEqual(bookmarkCreate.options["name"], "Widgets list")
        XCTAssertEqual(bookmarkCreate.options["match-mode"], "pathPrefix")

        let bookmarkApply = try CLIInvocation.parse([
            "bookmark", "apply", "bookmark-proposal-1", "--wait-for-approval"
        ])
        XCTAssertEqual(bookmarkApply.command, ["bookmark", "apply", "bookmark-proposal-1"])
        XCTAssertTrue(bookmarkApply.flags.contains("wait-for-approval"))

        let bookmarkList = try CLIInvocation.parse([
            "bookmark", "list", "--limit", "10", "--cursor", "cursor-1", "--projection", "summary"
        ])
        XCTAssertEqual(bookmarkList.command, ["bookmark", "list"])
        XCTAssertEqual(bookmarkList.options["projection"], "summary")

        let bookmarkGet = try CLIInvocation.parse([
            "bookmark", "get", "bookmark-id-1"
        ])
        XCTAssertEqual(bookmarkGet.command, ["bookmark", "get", "bookmark-id-1"])
    }

    func testInvocationParsesBoundedMachineOptions() throws {
        let invocation = try CLIInvocation.parse([
            "sessions", "search", "--json", "--limit", "25", "--method", "GET",
            "--endpoint", "http://localhost:9091/mcp", "--timeout", "12"
        ])

        XCTAssertEqual(invocation.command, ["sessions", "search"])
        XCTAssertEqual(invocation.outputMode, .json)
        XCTAssertEqual(invocation.options["limit"], "25")
        XCTAssertEqual(invocation.options["method"], "GET")
        XCTAssertEqual(invocation.timeout, 12)
    }

    func testInvocationRejectsNonLoopbackEndpoint() throws {
        XCTAssertThrowsError(try CLIInvocation.parse([
            "status", "--endpoint", "https://example.com/mcp"
        ])) { error in
            guard case CLIError.invalidArguments(let message) = error else {
                return XCTFail("Expected invalid arguments, got \(error).")
            }
            XCTAssertTrue(message.contains("loopback"))
        }
    }

    func testInvocationParsesExportFilterOptions() throws {
        let invocation = try CLIInvocation.parse([
            "sessions", "export", "--format", "har",
            "--domain", "example.com", "--path", "/v1",
            "--since", "2026-01-01T00:00:00Z", "--until", "2026-01-02T00:00:00Z",
            "--include-headers", "--include-body", "--max-sessions", "50"
        ])

        XCTAssertEqual(invocation.options["format"], "har")
        XCTAssertEqual(invocation.options["domain"], "example.com")
        XCTAssertEqual(invocation.options["path"], "/v1")
        XCTAssertEqual(invocation.options["since"], "2026-01-01T00:00:00Z")
        XCTAssertEqual(invocation.options["until"], "2026-01-02T00:00:00Z")
        XCTAssertEqual(invocation.options["max-sessions"], "50")
        XCTAssertTrue(invocation.flags.contains("include-headers"))
        XCTAssertTrue(invocation.flags.contains("include-body"))
    }

    func testInvocationRejectsMalformedSinceDate() throws {
        XCTAssertThrowsError(try CLIInvocation.parse([
            "sessions", "export", "--since", "not-a-date"
        ])) { error in
            guard case CLIError.invalidArguments(let message) = error else {
                return XCTFail("Expected invalid arguments, got \(error).")
            }
            XCTAssertTrue(message.contains("since"))
        }
    }

    func testInvocationRecognizesRuntimeLifecycleCommands() throws {
        XCTAssertEqual(try CLIInvocation.parse(["doctor"]).command, ["doctor"])
        let guide = try CLIInvocation.parse(["setup", "guide", "--format", "json"])
        XCTAssertEqual(guide.command, ["setup", "guide"])
        XCTAssertEqual(guide.options["format"], "json")
        XCTAssertEqual(try CLIInvocation.parse(["app", "launch"]).command, ["app", "launch"])
        XCTAssertEqual(try CLIInvocation.parse(["mcp", "start"]).command, ["mcp", "start"])
        XCTAssertEqual(try CLIInvocation.parse(["proxy", "stop"]).command, ["proxy", "stop"])
    }

    func testSetupGuideAndDoctorRemainAvailableWithoutCredential() async throws {
        let application = CLIApplication(
            credentialStore: MemoryCLICredentialStore(),
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher()
        )

        let guideExitCode = await application.run(arguments: ["setup", "guide", "--format", "json", "--quiet"])
        XCTAssertEqual(guideExitCode, .success)
        let doctorExitCode = await application.run(arguments: ["doctor", "--quiet"])
        XCTAssertEqual(doctorExitCode, .partialResult)
        XCTAssertTrue(CLISetupGuide.markdown.contains("bootstrap-only"))
        XCTAssertFalse(CLISetupGuide.markdown.contains("Bearer "))
        XCTAssertFalse(CLISetupGuide.markdown.contains("192.168."))
    }

    func testHLSCodecsEditsFileAcceptsOnlyOpaqueRefsAndCodecValues() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("hls-codecs-edits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
        [{"variantRef":"hls-variant-abc123","codecs":"avc1.640028,mp4a.40.2"}]
        """.utf8).write(to: url)

        let invocation = try CLIInvocation.parse([
            "hls", "codecs", "preview", "session-1", "--edits", url.path
        ])
        let edits = try CLIHLSCodecsArguments.edits(invocation: invocation)

        XCTAssertEqual(edits.first?["variantRef"] as? String, "hls-variant-abc123")
        XCTAssertEqual(edits.first?["codecs"] as? String, "avc1.640028,mp4a.40.2")
    }

    func testHLSCodecsEditsFileRejectsManifestBodyFields() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("hls-codecs-invalid-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
        [{"variantRef":"hls-variant-abc123","codecs":"avc1.640028","bodyText":"#EXTM3U"}]
        """.utf8).write(to: url)

        let invocation = try CLIInvocation.parse([
            "hls", "codecs", "preview", "session-1", "--edits", url.path
        ])
        XCTAssertThrowsError(try CLIHLSCodecsArguments.edits(invocation: invocation)) { error in
            guard case CLIError.invalidArguments(let message) = error else {
                return XCTFail("Expected invalid arguments, got \(error).")
            }
            XCTAssertTrue(message.contains("only variantRef and codecs"))
        }
    }

    func testHLSCodecsCLIContextPreviewPrepareRoundTrip() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        let editsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("hls-codecs-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: editsURL) }
        try Data("""
        [{"variantRef":"hls-variant-abc123","codecs":"avc1.640028"}]
        """.utf8).write(to: editsURL)

        var calledTools: [String] = []
        let urlSession = makeMockURLSession()
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "hls-cli-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                calledTools.append(name)
                switch name {
                case "media_manifest_structure":
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["hlsVariants": [["variantRef": "hls-variant-abc123"]]]
                        ]]
                    ])
                case "preview_hls_codecs_edit":
                    XCTAssertEqual(arguments["sessionID"] as? String, "session-1")
                    XCTAssertEqual(arguments["matchMode"] as? String, "ignoreQuery")
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["previewDigest": "preview-1"]
                        ]]
                    ])
                case "propose_create_map_local":
                    XCTAssertEqual(arguments["hlsPreviewDigest"] as? String, "preview-1")
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["proposalToken": "proposal-1"]
                        ]]
                    ])
                case "apply_create_map_local":
                    XCTAssertEqual(arguments["proposalToken"] as? String, "proposal-1")
                    XCTAssertEqual(arguments["idempotencyKey"] as? String, "hls-idem-1")
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["targetID": "rule-1", "isEnabled": false]
                        ]]
                    ])
                default:
                    return MockCLIURLResponse(status: 500, headers: [:], body: Data())
                }
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }

        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let contextExitCode = await application.run(
            arguments: ["hls", "codecs", "context", "session-1", "--quiet"]
        )
        let previewExitCode = await application.run(arguments: [
            "hls", "codecs", "preview", "session-1", "--edits", editsURL.path, "--quiet"
        ])
        let prepareExitCode = await application.run(arguments: [
            "hls", "codecs", "prepare-map-local", "--preview-digest", "preview-1", "--quiet"
        ])
        let applyExitCode = await application.run(arguments: [
            "hls", "codecs", "apply-map-local", "proposal-1",
            "--idempotency-key", "hls-idem-1", "--quiet"
        ])
        XCTAssertEqual(contextExitCode, .success)
        XCTAssertEqual(previewExitCode, .success)
        XCTAssertEqual(prepareExitCode, .success)
        XCTAssertEqual(applyExitCode, .success)
        XCTAssertEqual(
            calledTools,
            [
                "media_manifest_structure",
                "preview_hls_codecs_edit",
                "propose_create_map_local",
                "apply_create_map_local"
            ]
        )
    }

    func testHLSCodecsMatchModeRejectsUnknownValue() throws {
        let invocation = try CLIInvocation.parse([
            "hls", "codecs", "preview", "session-1",
            "--edits", "/tmp/edits.json",
            "--match-mode", "glob"
        ])
        XCTAssertThrowsError(try CLIHLSCodecsArguments.matchMode(invocation: invocation)) { error in
            guard case CLIError.invalidArguments(let message) = error else {
                return XCTFail("Expected invalid arguments, got \(error).")
            }
            XCTAssertTrue(message.contains("ignoreQuery"))
        }
    }

    func testHLSCodecsPathSuffixRequiresPath() throws {
        let invocation = try CLIInvocation.parse([
            "hls", "codecs", "preview", "session-1",
            "--edits", "/tmp/edits.json",
            "--match-mode", "pathSuffix"
        ])
        XCTAssertThrowsError(try CLIHLSCodecsArguments.matchMode(invocation: invocation)) { error in
            guard case CLIError.invalidArguments(let message) = error else {
                return XCTFail("Expected invalid arguments, got \(error).")
            }
            XCTAssertTrue(message.contains("--path"))
        }
    }

    func testHLSCodecsPrepareForwardsIdempotencyKey() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var sawIdempotency = false
        let urlSession = makeMockURLSession()
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "hls-cli-idem"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                XCTAssertEqual(name, "propose_create_map_local")
                XCTAssertEqual(arguments["idempotencyKey"] as? String, "prep-key")
                sawIdempotency = true
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["proposalToken": "proposal-idem"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )
        let code = await application.run(arguments: [
            "hls", "codecs", "prepare-map-local",
            "--preview-digest", "preview-x",
            "--idempotency-key", "prep-key",
            "--quiet"
        ])
        XCTAssertEqual(code, .success)
        XCTAssertTrue(sawIdempotency)
    }

    func testRuleEnableForwardsAcceptConfounder() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var sawAccept = false
        let urlSession = makeMockURLSession()
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "rule-cli-accept"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                XCTAssertEqual(name, "propose_enable_rule")
                XCTAssertEqual(arguments["acceptConfounder"] as? Bool, true)
                sawAccept = true
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["proposalToken": "enable-1"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )
        let code = await application.run(arguments: [
            "rule", "enable", "00000000-0000-0000-0000-000000000001",
            "--accept-confounder", "--quiet"
        ])
        XCTAssertEqual(code, .success)
        XCTAssertTrue(sawAccept)
    }

    func testHLSCodecsInvalidMatchModeExitsWithoutMCPCall() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        let editsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("hls-codecs-bad-mode-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: editsURL) }
        try Data("""
        [{"variantRef":"hls-variant-abc123","codecs":"avc1.640028"}]
        """.utf8).write(to: editsURL)

        var toolsCalled = 0
        let urlSession = makeMockURLSession()
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            if object["method"] as? String == "tools/call" {
                toolsCalled += 1
            }
            return MockCLIURLResponse(status: 500, headers: [:], body: Data())
        }
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )
        let code = await application.run(arguments: [
            "hls", "codecs", "preview", "session-1",
            "--edits", editsURL.path,
            "--match-mode", "glob",
            "--quiet"
        ])
        XCTAssertEqual(code, .invalidArguments)
        XCTAssertEqual(toolsCalled, 0)
    }

    func testResponseCLIContextSearchPreviewPrepareRoundTrip() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        let editsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("response-edit-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: editsURL) }
        try Data("""
        [{"selector":{"kind":"exactText","find":"Showblender LLC","expectedOccurrences":1},"operation":{"kind":"replace","text":"NOBLENDER LLC"}}]
        """.utf8).write(to: editsURL)

        var calledTools: [String] = []
        let urlSession = makeMockURLSession()
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "response-cli-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                calledTools.append(name)
                switch name {
                case "response_context":
                    XCTAssertEqual(arguments["sessionID"] as? String, "session-html-1")
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["isUTF8TextEditable": true, "completeness": "complete"]
                        ]]
                    ])
                case "response_text_search":
                    XCTAssertEqual(arguments["find"] as? String, "Showblender LLC")
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["matchCount": 1, "matches": [["matchRef": "ref-1"]]]
                        ]]
                    ])
                case "preview_response_edit":
                    XCTAssertEqual(arguments["sessionID"] as? String, "session-html-1")
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["responseEditPreviewDigest": "response-edit-preview-abc"]
                        ]]
                    ])
                case "propose_create_map_local":
                    XCTAssertEqual(
                        arguments["responseEditPreviewDigest"] as? String,
                        "response-edit-preview-abc"
                    )
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["proposalToken": "proposal-html-1", "defaultEnabled": false]
                        ]]
                    ])
                default:
                    return MockCLIURLResponse(status: 500, headers: [:], body: Data())
                }
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }

        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let contextExit = await application.run(
            arguments: ["response", "context", "session-html-1", "--quiet"]
        )
        let searchExit = await application.run(arguments: [
            "response", "search", "session-html-1", "--text", "Showblender LLC", "--quiet"
        ])
        let previewExit = await application.run(arguments: [
            "response", "edit", "preview", "session-html-1", "--edits", editsURL.path, "--quiet"
        ])
        let prepareExit = await application.run(arguments: [
            "response", "map-local", "prepare",
            "--preview-digest", "response-edit-preview-abc", "--quiet"
        ])
        XCTAssertEqual(contextExit, .success)
        XCTAssertEqual(searchExit, .success)
        XCTAssertEqual(previewExit, .success)
        XCTAssertEqual(prepareExit, .success)
        XCTAssertEqual(
            calledTools,
            [
                "response_context",
                "response_text_search",
                "preview_response_edit",
                "propose_create_map_local"
            ]
        )
    }

    func testLiveRewritePreviewBuildsTypedBoundedArguments() throws {
        let invocation = try CLIInvocation.parse([
            "rewrite", "preview", "session-1",
            "--method", "get",
            "--scheme", "https",
            "--host", "stage.example.com",
            "--path", "/epg/listings",
            "--json-path", "$.channels[*].programs[*].title",
            "--operation", "appendString",
            "--value", "!"
        ])

        let arguments = try CLILiveRewriteArguments.preview(invocation: invocation, sessionID: "session-1")

        XCTAssertEqual(arguments["method"] as? String, "GET")
        XCTAssertEqual(arguments["host"] as? String, "stage.example.com")
        XCTAssertEqual(arguments["sessionIDs"] as? [String], ["session-1"])
        XCTAssertEqual(arguments["repeatPolicy"] as? String, "ifMissingSuffix")
        XCTAssertEqual(
            (arguments["overrideValue"] as? [String: String])?["value"],
            "!"
        )
    }

    func testCollectionMockPreviewBuildsDraftJSON() throws {
        let invocation = try CLIInvocation.parse([
            "collection-mock", "preview", "session-1",
            "--collection-pointer", "/items",
            "--item-json", #"{"id":"synthetic"}"#,
            "--identity-pointers", "/id, /sku",
            "--count-pointers", "/total",
            "--position", "append"
        ])

        let arguments = try CLICollectionMockArguments.preview(invocation: invocation, sessionID: "session-1")

        XCTAssertEqual(arguments["sessionID"] as? String, "session-1")
        let draftText = try XCTUnwrap(arguments["draftJSON"] as? String)
        let draft = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(draftText.utf8)) as? [String: Any])
        XCTAssertEqual(draft["collectionPointer"] as? String, "/items")
        XCTAssertEqual((draft["item"] as? [String: Any])?["id"] as? String, "synthetic")
        XCTAssertEqual(draft["identityPointers"] as? [String], ["/id", "/sku"])
        XCTAssertEqual(draft["countPointers"] as? [String], ["/total"])
        XCTAssertEqual(draft["position"] as? String, "append")
    }

    func testCollectionMockPreviewRejectsInvalidItemJSON() throws {
        let invocation = try CLIInvocation.parse([
            "collection-mock", "preview", "session-1",
            "--collection-pointer", "/items",
            "--item-json", "not json"
        ])
        XCTAssertThrowsError(try CLICollectionMockArguments.preview(invocation: invocation, sessionID: "session-1"))
    }

    func testCollectionMockProposalBuildsMatcherAndRevisionID() throws {
        let invocation = try CLIInvocation.parse([
            "collection-mock", "prepare", "session-1",
            "--method", "get",
            "--host", "stage.example.com",
            "--path", "/epg/listings",
            "--collection-pointer", "/items",
            "--item-json", #"{"id":"synthetic"}"#
        ])
        let arguments = try CLICollectionMockArguments.proposal(invocation: invocation, revisionID: "revision-1")
        XCTAssertEqual(arguments["method"] as? String, "GET")
        XCTAssertEqual(arguments["host"] as? String, "stage.example.com")
        XCTAssertEqual(arguments["revisionID"] as? String, "revision-1")
    }

    func testRewritePreparePreviewsThenProposesWithBoundDigest() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var calledTools: [String] = []
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "rewrite-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                calledTools.append(name)
                if name == "preview_live_rewrite" {
                    XCTAssertEqual(arguments["sessionIDs"] as? [String], ["session-1"])
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": [
                                "previewDigest": "preview-1",
                                "eligibleCount": 1,
                                "transformedCount": 1,
                                "zeroMatches": false
                            ] as [String: Any]
                        ]]
                    ])
                }
                XCTAssertEqual(name, "propose_create_live_rewrite")
                XCTAssertEqual(arguments["previewDigest"] as? String, "preview-1")
                XCTAssertNil(arguments["sessionIDs"])
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["proposalToken": "proposal-1"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: [
            "rewrite", "prepare", "session-1",
            "--method", "GET",
            "--host", "stage.example.com",
            "--path", "/epg/listings",
            "--json-path", "$.channels[*].programs[*].title",
            "--operation", "appendString",
            "--value", "!",
            "--quiet"
        ])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(calledTools, ["preview_live_rewrite", "propose_create_live_rewrite"])
    }

    func testHARExportRoutesThroughBulkSessionsExportToolWithFilters() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var calledTool: String?
        var calledArguments: [String: Any] = [:]
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "export-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                calledTool = try XCTUnwrap(params["name"] as? String)
                calledArguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": [
                            "format": "har",
                            "sessionCount": 1,
                            "truncated": false,
                            "content": "{\"log\":{\"entries\":[]}}"
                        ]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: [
            "sessions", "export", "--format", "har",
            "--domain", "example.com", "--path", "/v1",
            "--since", "2026-01-01T00:00:00Z", "--until", "2026-01-02T00:00:00Z",
            "--include-headers", "--include-body", "--quiet"
        ])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(calledTool, "sessions_export")
        XCTAssertEqual(calledArguments["domain"] as? String, "example.com")
        XCTAssertEqual(calledArguments["path"] as? String, "/v1")
        XCTAssertEqual(calledArguments["startedAfter"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(calledArguments["startedBefore"] as? String, "2026-01-02T00:00:00Z")
        XCTAssertEqual(calledArguments["format"] as? String, "har")
        XCTAssertEqual(calledArguments["deliverFile"] as? Bool, true)
        XCTAssertEqual(calledArguments["includeHeaders"] as? Bool, true)
        XCTAssertEqual(calledArguments["includeBody"] as? Bool, true)
    }

    func testHARExportWithOutputCopiesManagedFilePath() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        let spilled = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-har-\(UUID().uuidString).har")
        let harBody = #"{"log":{"version":"1.2","creator":{"name":"JoesProxy","version":"t"},"entries":[]}}"#
        try Data(harBody.utf8).write(to: spilled)
        defer { try? FileManager.default.removeItem(at: spilled) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-har-dest-\(UUID().uuidString).har")
        defer { try? FileManager.default.removeItem(at: destination) }

        var calledArguments: [String: Any] = [:]
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "export-session-file"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                calledArguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": [
                            "format": "har",
                            "sessionCount": 42,
                            "truncated": false,
                            "content": NSNull(),
                            "outputPath": spilled.path,
                            "contentByteCount": harBody.utf8.count
                        ]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: [
            "sessions", "export", "--format", "har",
            "--output", destination.path,
            "--quiet"
        ])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(calledArguments["deliverFile"] as? Bool, true)
        XCTAssertNil(calledArguments["maxSessions"])
        let copied = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(copied, harBody)
    }

    func testPlainJSONExportStaysOnMetadataOnlyPathWithoutApproval() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var calledTools: [String] = []
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "export-session-2"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                calledTools.append(name)
                XCTAssertEqual(name, "sessions_search", "plain json/ndjson export must not call the bulk tool")
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["items": [] as [[String: Any]], "hasMore": false]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: ["sessions", "export", "--format", "json", "--quiet"])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(calledTools, ["sessions_search"])
    }

    func testCertificateExportWritesDecodedBytesToOutputPath() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        let certificateBytes = Data("fake-der-cert-bytes".utf8)
        let expectedFingerprint = "deadbeef"
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "cert-export-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                XCTAssertEqual(name, "certificate_export")
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "certificateDataBase64": certificateBytes.base64EncodedString(),
                        "certificateSHA256Fingerprint": expectedFingerprint,
                        "filename": "JoesProxy-Root-CA.cer"
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-cert-export-\(UUID().uuidString).cer")
        addTeardownBlock { try? FileManager.default.removeItem(at: outputURL) }

        let exitCode = await application.run(arguments: ["certificate", "export", "--output", outputURL.path, "--quiet"])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(try Data(contentsOf: outputURL), certificateBytes)
    }

    /// Covers the four argument shapes used across all 40 newly-wired advanced-diagnostics CLI
    /// commands (simple flags, CSV lists, JSON-file arrays, multi-verb families) — proving CLI
    /// command parsing and argument-dict construction actually reach the right MCP tool name with
    /// the right shape, not just that the MCP dispatcher side (verified separately) exists.
    func testResilienceProposeSendsSimpleFlagArguments() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var capturedArguments: [String: Any] = [:]
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(status: 200, headers: [MCPCLIClient.sessionHeader: "resilience-session"], object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                ])
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                XCTAssertEqual(params["name"] as? String, "propose_resilience_bisection_plan")
                capturedArguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": ["id": "plan-1", "sessionID": capturedArguments["sessionID"] as Any]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: self.makeMockURLSession())
            }
        )
        let sessionID = UUID().uuidString
        let exitCode = await application.run(arguments: [
            "resilience", "propose", "--session-id", sessionID, "--name", "Custom Name", "--quiet"
        ])
        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(capturedArguments["sessionID"] as? String, sessionID)
        XCTAssertEqual(capturedArguments["name"] as? String, "Custom Name")
    }

    func testTrajectoryDiffSendsCommaSeparatedSessionIDArrays() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var capturedArguments: [String: Any] = [:]
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(status: 200, headers: [MCPCLIClient.sessionHeader: "trajectory-session"], object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                ])
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                XCTAssertEqual(params["name"] as? String, "diff_session_trajectories")
                capturedArguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": ["divergenceStepIndex": 0]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: self.makeMockURLSession())
            }
        )
        let baseline1 = UUID().uuidString
        let baseline2 = UUID().uuidString
        let candidate1 = UUID().uuidString
        let exitCode = await application.run(arguments: [
            "trajectory", "diff",
            "--baseline-sessions", "\(baseline1),\(baseline2)",
            "--candidate-sessions", candidate1,
            "--quiet"
        ])
        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(capturedArguments["baselineSessionIDs"] as? [String], [baseline1, baseline2])
        XCTAssertEqual(capturedArguments["candidateSessionIDs"] as? [String], [candidate1])
    }

    func testHypothesisProposeReadsNodeInputsFromJSONFile() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        let nodesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-hypothesis-nodes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: nodesURL) }
        try Data(#"""
        [{"id":"n1","title":"Upstream timeout","explanation":"Gateway may be slow","mutationType":"latencyInjection","mutationTarget":"https://payments.example.com/*","expectedOutcome":"Client should time out visibly."}]
        """#.utf8).write(to: nodesURL)
        var capturedArguments: [String: Any] = [:]
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(status: 200, headers: [MCPCLIClient.sessionHeader: "hypothesis-session"], object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                ])
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                XCTAssertEqual(params["name"] as? String, "propose_hypothesis_dag")
                capturedArguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": ["id": "graph-1"]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: self.makeMockURLSession())
            }
        )
        let exitCode = await application.run(arguments: [
            "hypothesis", "propose", "--name", "Test Plan", "--target-bug", "checkout 500s", "--nodes", nodesURL.path, "--quiet"
        ])
        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(capturedArguments["name"] as? String, "Test Plan")
        XCTAssertEqual(capturedArguments["targetBug"] as? String, "checkout 500s")
        let nodeInputs = try XCTUnwrap(capturedArguments["nodeInputs"] as? [[String: Any]])
        XCTAssertEqual(nodeInputs.count, 1)
        XCTAssertEqual(nodeInputs.first?["id"] as? String, "n1")
        XCTAssertEqual(nodeInputs.first?["expectedOutcome"] as? String, "Client should time out visibly.")
    }

    func testSemanticMockFamilyRoutesEachVerbToItsOwnTool() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var calledToolNames: [String] = []
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(status: 200, headers: [MCPCLIClient.sessionHeader: "semantic-session"], object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                ])
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                calledToolNames.append(name)
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": ["ok": true]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        func makeApp() -> CLIApplication {
            CLIApplication(
                credentialStore: credentialStore,
                sessionStore: MemoryCLISessionStore(),
                appLauncher: MockCLIAppLauncher(),
                clientFactory: { endpoint, credential, store, timeout in
                    MCPCLIClient(endpoint: endpoint, credential: credential, sessionStore: store, timeout: timeout, urlSession: self.makeMockURLSession())
                }
            )
        }
        let ruleID = UUID().uuidString
        _ = await makeApp().run(arguments: [
            "semantic", "mock", "propose", "--name", "n", "--url-pattern", "*/search", "--intent-label", "search",
            "--example-queries", "find shoes,show me shoes", "--response-body", "{}", "--quiet"
        ])
        _ = await makeApp().run(arguments: ["semantic", "mock", "list", "--quiet"])
        _ = await makeApp().run(arguments: ["semantic", "mock", "test", "--query", "find shoes", "--quiet"])
        _ = await makeApp().run(arguments: ["semantic", "mock", "delete", "--rule-id", ruleID, "--quiet"])

        XCTAssertEqual(calledToolNames, [
            "propose_semantic_mock_rule", "list_semantic_mock_rules", "test_semantic_query_match", "delete_semantic_mock_rule"
        ])
    }

    func testScenarioDraftReadsBoundedJSONObjectFromFile() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/file-backed-override.json")
        let invocation = try CLIInvocation.parse([
            "scenario", "draft", "--input", fixtureURL.path
        ])

        let arguments = try CLIScenarioArguments.draft(invocation: invocation)
        let json = try XCTUnwrap(arguments["draftJSON"] as? String)
        let data = try XCTUnwrap(json.data(using: .utf8))

        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertLessThanOrEqual(data.count, CLIScenarioArguments.maxDraftBytes)
    }

    func testScenarioObservationProjectionOmitsEvidenceByDefault() {
        let compact = CLIScenarioProjection.compact(
            [
                "scenarioID": ["rawValue": "scenario-1"],
                "phase": "observing",
                "evidence": [
                    ["sessionID": "session-1", "sanitizedPath": "/first"],
                    ["sessionID": "session-2", "sanitizedPath": "/second"]
                ],
                "warnings": ["Observation window is still open."]
            ],
            toolName: "get_test_observations"
        )

        XCTAssertEqual(compact["scenarioID"] as? String, "scenario-1")
        XCTAssertEqual(compact["evidenceCount"] as? Int, 2)
        XCTAssertNil(compact["evidence"])
    }

    func testScenarioOutcomeIsLimitedToStopAndCleanup() throws {
        let invocation = try CLIInvocation.parse([
            "scenario", "arm", "scenario-1", "--outcome", "completed"
        ])

        XCTAssertThrowsError(
            try CLIScenarioArguments.identified("scenario-1", invocation: invocation)
        ) { error in
            guard case CLIError.invalidArguments(let message) = error else {
                return XCTFail("Expected invalid arguments, got \(error).")
            }
            XCTAssertTrue(message.contains("stop and cleanup"))
        }
    }

    func testScenarioArmWaitsForApprovalAndRetriesExactArguments() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var toolCalls: [(String, [String: Any])] = []
        var armAttempt = 0
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "scenario-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                toolCalls.append((name, arguments))
                if name == "arm_test_scenario" {
                    armAttempt += 1
                    if armAttempt == 1 {
                        return try .json(status: 200, object: [
                            "jsonrpc": "2.0",
                            "id": object["id"] as Any,
                            "error": [
                                "code": -32_001,
                                "message": "Approval required.",
                                "data": ["mcpCode": "approval_required", "requestID": "approval-1"]
                            ] as [String: Any]
                        ])
                    }
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["scenarioID": "scenario-1", "phase": "armed"]
                        ]]
                    ])
                }
                XCTAssertEqual(name, "approval_status")
                XCTAssertEqual(arguments["requestID"] as? String, "approval-1")
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        // Production DTO field is `status` (`MCPApprovalStatusDTO`). A prior
                        // mock used `state`, which let wait-for-approval pass unit tests while
                        // never detecting live approvals — see Live-NOBLENDER-Milestone-Lessons.md.
                        "payload": ["requestID": "approval-1", "status": "approved_awaiting_retry"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ApprovalReceipt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("receipt.json").path
        let exitCode = await application.run(arguments: [
            "scenario", "arm", "scenario-1", "--wait-for-approval", "--quiet",
            "--receipt-output", path, "--receipt-workflow", "synthetic", "--receipt-version", "1", "--receipt-environment", "mock"
        ])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(toolCalls.map(\.0), ["arm_test_scenario", "approval_status", "arm_test_scenario"])
        XCTAssertEqual(toolCalls[0].1["scenarioID"] as? String, "scenario-1")
        XCTAssertEqual(toolCalls[2].1["scenarioID"] as? String, "scenario-1")
        let attempts = try CLIReceiptRecorder.read(path).workflow.attempts
        XCTAssertEqual(attempts.count, 5, "Handshake, failed arm, poll and exact retry must all count")
        XCTAssertEqual(attempts[2].outcome, "failure")
        XCTAssertEqual(attempts.last?.retryOf, attempts[2].id)
    }

    /// AK-5 gap: `scenario preview` had zero test coverage of any kind before this.
    func testScenarioPreviewRoundTrip() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/file-backed-override.json")
        var calledTools: [String] = []
        let urlSession = makeMockURLSession()
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "scenario-preview-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                calledTools.append(name)
                XCTAssertEqual(name, "preview_test_scenario")
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["valid": true, "warnings": []]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )
        let exitCode = await application.run(arguments: [
            "scenario", "preview", "--input", fixtureURL.path, "--quiet"
        ])
        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(calledTools, ["preview_test_scenario"])
    }

    /// AK-5 gap: `scenario stop` had zero test coverage of any kind before this — every other
    /// scenario-lifecycle verb has at least one dedicated test.
    func testScenarioStopRoundTrip() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var calledTools: [(String, [String: Any])] = []
        let urlSession = makeMockURLSession()
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "scenario-stop-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                calledTools.append((name, arguments))
                XCTAssertEqual(name, "stop_test_scenario")
                XCTAssertEqual(arguments["scenarioID"] as? String, "scenario-2")
                XCTAssertEqual(arguments["outcome"] as? String, "completed")
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["scenarioID": "scenario-2", "phase": "stopped"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )
        let exitCode = await application.run(arguments: [
            "scenario", "stop", "scenario-2", "--outcome", "completed", "--quiet"
        ])
        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(calledTools.map(\.0), ["stop_test_scenario"])
    }

    /// AK-5 gap: `block apply` had only argument-parsing coverage — no MCP round trip and no proof
    /// the shared exact-retry-after-approval path (`CLIApplication.runTool`) actually works for a
    /// family other than `scenario`. Mirrors `testScenarioArmWaitsForApprovalAndRetriesExactArguments`.
    func testBlockApplyWaitsForApprovalAndRetriesExactArguments() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var toolCalls: [(String, [String: Any])] = []
        var applyAttempt = 0
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "block-apply-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                toolCalls.append((name, arguments))
                if name == "apply_create_block" {
                    applyAttempt += 1
                    if applyAttempt == 1 {
                        return try .json(status: 200, object: [
                            "jsonrpc": "2.0",
                            "id": object["id"] as Any,
                            "error": [
                                "code": -32_001,
                                "message": "Approval required.",
                                "data": ["mcpCode": "approval_required", "requestID": "block-approval-1"]
                            ] as [String: Any]
                        ])
                    }
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["targetID": "block-rule-1", "isEnabled": false]
                        ]]
                    ])
                }
                XCTAssertEqual(name, "approval_status")
                XCTAssertEqual(arguments["requestID"] as? String, "block-approval-1")
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["requestID": "block-approval-1", "status": "approved_awaiting_retry"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: [
            "block", "apply", "block-proposal-1", "--wait-for-approval", "--quiet"
        ])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(toolCalls.map(\.0), ["apply_create_block", "approval_status", "apply_create_block"])
        XCTAssertEqual(toolCalls[0].1["proposalToken"] as? String, "block-proposal-1")
        XCTAssertEqual(toolCalls[2].1["proposalToken"] as? String, "block-proposal-1")
    }

    /// AK-5 gap: `throttle apply` had only argument-parsing coverage — no MCP round trip, no
    /// exact-retry-after-approval proof.
    func testThrottleApplyWaitsForApprovalAndRetriesExactArguments() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var toolCalls: [(String, [String: Any])] = []
        var applyAttempt = 0
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "throttle-apply-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                toolCalls.append((name, arguments))
                if name == "apply_change_throttle" {
                    applyAttempt += 1
                    if applyAttempt == 1 {
                        return try .json(status: 200, object: [
                            "jsonrpc": "2.0",
                            "id": object["id"] as Any,
                            "error": [
                                "code": -32_001,
                                "message": "Approval required.",
                                "data": ["mcpCode": "approval_required", "requestID": "throttle-approval-1"]
                            ] as [String: Any]
                        ])
                    }
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["isEnabled": true]
                        ]]
                    ])
                }
                XCTAssertEqual(name, "approval_status")
                XCTAssertEqual(arguments["requestID"] as? String, "throttle-approval-1")
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["requestID": "throttle-approval-1", "status": "approved_awaiting_retry"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: [
            "throttle", "apply", "throttle-proposal-1", "--wait-for-approval", "--quiet"
        ])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(toolCalls.map(\.0), ["apply_change_throttle", "approval_status", "apply_change_throttle"])
        XCTAssertEqual(toolCalls[0].1["proposalToken"] as? String, "throttle-proposal-1")
        XCTAssertEqual(toolCalls[2].1["proposalToken"] as? String, "throttle-proposal-1")
    }

    /// Bookmark CLI parity: `propose_create_bookmark`/`bookmarks_list`/`bookmark_get` all exist
    /// server-side but had zero `joesproxyctl` exposure. This proves `bookmark create` maps
    /// required and optional matcher fields correctly, `bookmark list` passes pagination and
    /// projection through, and `bookmark get` maps its positional ID to `bookmarkID`.
    func testBookmarkCreateListGetPassExpectedArguments() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var toolCalls: [(String, [String: Any])] = []
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "bookmark-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                toolCalls.append((name, arguments))
                switch name {
                case "propose_create_bookmark":
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["proposalToken": "bookmark-proposal-1", "riskTier": "mutatingTool"]
                        ]]
                    ])
                case "bookmarks_list":
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["items": [], "projection": "summary"]
                        ]]
                    ])
                case "bookmark_get":
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["id": "bookmark-id-1", "name": "Widgets list"]
                        ]]
                    ])
                default:
                    return MockCLIURLResponse(status: 500, headers: [:], body: Data())
                }
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let createExitCode = await application.run(arguments: [
            "bookmark", "create",
            "--method", "GET", "--host", "api.example.com", "--path", "/v1/widgets",
            "--name", "Widgets list", "--scheme", "https", "--port", "8443",
            "--match-mode", "pathPrefix", "--quiet"
        ])
        XCTAssertEqual(createExitCode, .success)
        let createArguments = try XCTUnwrap(toolCalls.first { $0.0 == "propose_create_bookmark" }?.1)
        XCTAssertEqual(createArguments["method"] as? String, "GET")
        XCTAssertEqual(createArguments["host"] as? String, "api.example.com")
        XCTAssertEqual(createArguments["path"] as? String, "/v1/widgets")
        XCTAssertEqual(createArguments["name"] as? String, "Widgets list")
        XCTAssertEqual(createArguments["scheme"] as? String, "https")
        XCTAssertEqual(createArguments["port"] as? Int, 8443)
        XCTAssertEqual(createArguments["matchMode"] as? String, "pathPrefix")

        let listExitCode = await application.run(arguments: [
            "bookmark", "list", "--limit", "10", "--cursor", "cursor-1", "--projection", "summary", "--quiet"
        ])
        XCTAssertEqual(listExitCode, .success)
        let listArguments = try XCTUnwrap(toolCalls.first { $0.0 == "bookmarks_list" }?.1)
        XCTAssertEqual(listArguments["limit"] as? Int, 10)
        XCTAssertEqual(listArguments["cursor"] as? String, "cursor-1")
        XCTAssertEqual(listArguments["projection"] as? String, "summary")

        let getExitCode = await application.run(arguments: ["bookmark", "get", "bookmark-id-1", "--quiet"])
        XCTAssertEqual(getExitCode, .success)
        let getArguments = try XCTUnwrap(toolCalls.first { $0.0 == "bookmark_get" }?.1)
        XCTAssertEqual(getArguments["bookmarkID"] as? String, "bookmark-id-1")
    }

    /// Bookmark CLI parity: `bookmark list` with no `--projection` must default to `minimal`,
    /// matching `bookmarks_list`'s own server-side default.
    func testBookmarkListDefaultsToMinimalProjectionWithNoPagination() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var listArguments: [String: Any] = [:]
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "bookmark-list-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                listArguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["items": [], "projection": "minimal"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: ["bookmark", "list", "--quiet"])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(listArguments["projection"] as? String, "minimal")
        XCTAssertNil(listArguments["limit"])
        XCTAssertNil(listArguments["cursor"])
    }

    /// AT: `rule list` mirrors `bookmark list` — defaults projection to `minimal` and calls `overrides_list`.
    func testRuleListDefaultsToMinimalProjection() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var listArguments: [String: Any] = [:]
        var toolName: String?
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "rule-list-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                toolName = params["name"] as? String
                listArguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["items": [], "projection": "minimal"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: ["rule", "list", "--quiet"])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(toolName, "overrides_list")
        XCTAssertEqual(listArguments["projection"] as? String, "minimal")
    }

    /// AT: `rule get` / `rule delete` / `rule apply-delete` tool routing.
    func testRuleGetAndDeleteProposeApplyToolRouting() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var toolCalls: [(String, [String: Any])] = []
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "rule-delete-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let args = try XCTUnwrap(params["arguments"] as? [String: Any])
                toolCalls.append((name, args))
                if name == "propose_delete_rule" {
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["proposalToken": "del-token"]
                        ]]
                    ])
                }
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["id": "rule-1", "sourceKind": "block"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let getCode = await application.run(arguments: ["rule", "get", "11111111-1111-1111-1111-111111111111", "--quiet"])
        let deleteCode = await application.run(arguments: ["rule", "delete", "11111111-1111-1111-1111-111111111111", "--quiet"])
        let applyDeleteCode = await application.run(arguments: ["rule", "apply-delete", "del-token", "--quiet"])
        XCTAssertEqual(getCode, .success)
        XCTAssertEqual(deleteCode, .success)
        XCTAssertEqual(applyDeleteCode, .success)

        XCTAssertEqual(toolCalls.map(\.0), ["override_get", "propose_delete_rule", "apply_delete_rule"])
        XCTAssertEqual(toolCalls[0].1["overrideID"] as? String, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(toolCalls[1].1["overrideID"] as? String, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(toolCalls[2].1["proposalToken"] as? String, "del-token")
    }

    /// Bookmark CLI parity: `bookmark apply` must reuse the shared exact-retry-after-approval path
    /// (`CLIApplication.runTool`) and must never send an `enableAfterApply` key — unlike
    /// block/map-local rules, bookmarks have no enabled/disabled state to enable-after
    /// (confirmed against `applyCreateBookmark`, which reads only `proposalToken`).
    func testBookmarkApplyWaitsForApprovalAndRetriesExactArgumentsWithNoEnableAfter() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var toolCalls: [(String, [String: Any])] = []
        var applyAttempt = 0
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "bookmark-apply-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                toolCalls.append((name, arguments))
                if name == "apply_create_bookmark" {
                    applyAttempt += 1
                    if applyAttempt == 1 {
                        return try .json(status: 200, object: [
                            "jsonrpc": "2.0",
                            "id": object["id"] as Any,
                            "error": [
                                "code": -32_001,
                                "message": "Approval required.",
                                "data": ["mcpCode": "approval_required", "requestID": "bookmark-approval-1"]
                            ] as [String: Any]
                        ])
                    }
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["targetID": "bookmark-1", "isEnabled": false]
                        ]]
                    ])
                }
                XCTAssertEqual(name, "approval_status")
                XCTAssertEqual(arguments["requestID"] as? String, "bookmark-approval-1")
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["requestID": "bookmark-approval-1", "status": "approved_awaiting_retry"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: [
            "bookmark", "apply", "bookmark-proposal-1", "--wait-for-approval", "--quiet"
        ])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(toolCalls.map(\.0), ["apply_create_bookmark", "approval_status", "apply_create_bookmark"])
        XCTAssertEqual(toolCalls[0].1["proposalToken"] as? String, "bookmark-proposal-1")
        XCTAssertNil(toolCalls[0].1["enableAfterApply"])
        XCTAssertEqual(toolCalls[2].1["proposalToken"] as? String, "bookmark-proposal-1")
        XCTAssertNil(toolCalls[2].1["enableAfterApply"])
    }

    /// AK-5 gap: `hls fixture apply-start` had only argument-parsing coverage — no MCP round trip,
    /// no exact-retry-after-approval proof.
    func testHLSFixtureApplyStartWaitsForApprovalAndRetriesExactArguments() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var toolCalls: [(String, [String: Any])] = []
        var applyAttempt = 0
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "hls-fixture-apply-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                toolCalls.append((name, arguments))
                if name == "apply_hls_fixture_start" {
                    applyAttempt += 1
                    if applyAttempt == 1 {
                        return try .json(status: 200, object: [
                            "jsonrpc": "2.0",
                            "id": object["id"] as Any,
                            "error": [
                                "code": -32_001,
                                "message": "Approval required.",
                                "data": ["mcpCode": "approval_required", "requestID": "fixture-approval-1"]
                            ] as [String: Any]
                        ])
                    }
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["runID": "run-1", "reservedHost": "fixture-run-1.hls.joesproxy.invalid"]
                        ]]
                    ])
                }
                XCTAssertEqual(name, "approval_status")
                XCTAssertEqual(arguments["requestID"] as? String, "fixture-approval-1")
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["requestID": "fixture-approval-1", "status": "approved_awaiting_retry"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: [
            "hls", "fixture", "apply-start", "fixture-proposal-1", "--wait-for-approval", "--quiet"
        ])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(toolCalls.map(\.0), ["apply_hls_fixture_start", "approval_status", "apply_hls_fixture_start"])
        XCTAssertEqual(toolCalls[0].1["proposalToken"] as? String, "fixture-proposal-1")
        XCTAssertEqual(toolCalls[2].1["proposalToken"] as? String, "fixture-proposal-1")
    }

    /// AK-5 gap: `--wait-for-approval` only ever had success-path coverage — nothing proved the
    /// bounded-wait deadline (`CLIApplication.runTool`, `Date() < deadline`) actually expires and
    /// throws rather than looping/hanging when the approval never lands.
    func testWaitForApprovalTimesOutWhenApprovalNeverLands() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var approvalStatusPollCount = 0
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "timeout-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                if name == "apply_create_block" {
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "error": [
                            "code": -32_001,
                            "message": "Approval required.",
                            "data": ["mcpCode": "approval_required", "requestID": "never-approved"]
                        ] as [String: Any]
                    ])
                }
                XCTAssertEqual(name, "approval_status")
                // Never returns approved_awaiting_retry — the deadline must be what ends the loop.
                approvalStatusPollCount += 1
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["requestID": "never-approved", "status": "pending"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        // No `sleep` override here — the poll loop's `while Date() < deadline` check uses the real
        // wall clock, so `--approval-timeout 1` (the minimum allowed, clamped in CLIApplication.swift)
        // bounds this test to ~1 real second, not a fake/instant loop that couldn't prove anything.
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: [
            "block", "apply", "never-approved-proposal",
            "--wait-for-approval", "--approval-timeout", "1", "--quiet"
        ])

        XCTAssertEqual(exitCode, .timedOut)
        XCTAssertGreaterThan(approvalStatusPollCount, 0, "the deadline loop must poll at least once before expiring")
    }

    /// AK-5 gap: no test proved a bare `sessions list`/`sessions search` invocation (no `--limit`)
    /// omits the argument entirely rather than the CLI inventing its own default — the actual
    /// default/cap (50/100) lives server-side (`MCPResourceBudget`, covered separately in
    /// `MCPDisclosureTests.swift`); this proves the CLI doesn't second-guess that.
    func testSessionsListOmitsLimitArgumentWhenNotSpecified() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var capturedArguments: [String: Any] = [:]
        let urlSession = makeMockURLSession()
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "pagination-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                capturedArguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["items": []]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )
        let exitCode = await application.run(arguments: ["sessions", "list", "--quiet"])
        XCTAssertEqual(exitCode, .success)
        XCTAssertNil(capturedArguments["limit"], "CLI must not invent a default — the server owns the bound")
    }

    func testResponseMapLocalApplyEnableAfterChainsCreateThenEnable() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var toolCalls: [(String, [String: Any])] = []
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "enable-after-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                toolCalls.append((name, arguments))
                switch name {
                case "apply_create_map_local":
                    XCTAssertEqual(arguments["proposalToken"] as? String, "proposal-map-1")
                    XCTAssertEqual(arguments["enableAfterApply"] as? Bool, true)
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": [
                                "transactionID": "tx-create-enable",
                                "targetID": "override-1",
                                "isEnabled": true
                            ]
                        ]]
                    ])
                case "override_get":
                    XCTAssertEqual(arguments["overrideID"] as? String, "override-1")
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": [
                                "id": "override-1",
                                "method": "GET",
                                "host": "www.showblender.com",
                                "path": "/",
                                "matchMode": "ignoreQuery",
                                "isEnabled": true
                            ]
                        ]]
                    ])
                default:
                    return MockCLIURLResponse(status: 500, headers: [:], body: Data())
                }
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { _ in },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: [
            "response", "map-local", "apply", "proposal-map-1", "--enable-after", "--json"
        ])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(toolCalls.map(\.0), ["apply_create_map_local", "override_get"])
        XCTAssertEqual(toolCalls[0].1["enableAfterApply"] as? Bool, true)
    }

    func testDoctorUsesOneCompactRuntimeCallWithoutLaunchingApp() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        let launcher = MockCLIAppLauncher()
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "doctor-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                XCTAssertEqual(params["name"] as? String, "runtime_status")
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                let expectedRuntime = try XCTUnwrap(arguments["expectedRuntime"] as? [String: Any])
                XCTAssertEqual(
                    expectedRuntime["capabilitiesBundleVersion"] as? String,
                    "\(expectedRuntime["marketingVersion"] as? String ?? "")+\(CLIRuntimeIdentity.capabilitiesRevision)"
                )
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": [
                            "readyForUnattendedControl": true,
                            "state": "ready",
                            "checks": [] as [[String: Any]],
                            "recommendedNextCommands": ["joesproxyctl proxy start"]
                        ] as [String: Any]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: launcher,
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: ["doctor", "--quiet"])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(launcher.startRequestCount, 0)
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 3)
    }

    func testDoctorRecommendsEnrollmentWhenCredentialIsRejected() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("stale-token", endpoint: endpoint)
        MockCLIURLProtocol.state.configure { request in
            MockCLIURLResponse(status: 401, headers: [:], body: Data())
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: ["doctor", "--quiet"])

        XCTAssertEqual(exitCode, .partialResult)
        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 1)
    }

    func testMCPWaitReusesClientAndPollsAtOneSecondIntervals() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var initializeAttempts = 0
        var sleepIntervals: [UInt64] = []
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                initializeAttempts += 1
                if initializeAttempts == 1 {
                    throw URLError(.cannotConnectToHost)
                }
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "wait-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "resources/read":
                let status = try CLIJSON.string(["state": "running"], pretty: false)
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0",
                    "id": object["id"] as Any,
                    "result": ["contents": [["text": status]]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            sleep: { sleepIntervals.append($0) },
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: ["mcp", "wait", "--timeout", "5", "--quiet"])

        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(initializeAttempts, 2)
        XCTAssertEqual(sleepIntervals, [1_000_000_000])
    }

    func testBundledCLIResolvesContainingApplication() throws {
        let executable = URL(fileURLWithPath: "/Applications/JoesProxy.app/Contents/MacOS/joesproxyctl")
        XCTAssertEqual(
            try CLIWorkspaceAppLauncher.containingAppURL(for: executable).path,
            "/Applications/JoesProxy.app"
        )
    }

    func testLauncherUsesProductionJoesProxyBundleIdentifier() {
        XCTAssertEqual(CLIWorkspaceAppLauncher.joesProxyBundleIdentifier, "com.ShowBlender.JoesProxy")
    }

    func testBundledCLISymlinkResolvesContainingApplication() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("JoesProxyCLISymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let appExecutable = root
            .appendingPathComponent("JoesProxy.app/Contents/MacOS/joesproxyctl")
        let symlink = root.appendingPathComponent("bin/joesproxyctl")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: appExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: appExecutable)
        try fileManager.createDirectory(at: symlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: appExecutable)

        XCTAssertEqual(
            try CLIWorkspaceAppLauncher.containingAppURL(for: symlink).path,
            root.appendingPathComponent("JoesProxy.app").path
        )
    }

    func testUnbundledCLIIsRejectedForApplicationLaunch() {
        XCTAssertThrowsError(
            try CLIWorkspaceAppLauncher.containingAppURL(for: URL(fileURLWithPath: "/usr/local/bin/joesproxyctl"))
        )
    }

    @MainActor
    func testCLIAutomationStartupIsOptInAndPersists() async throws {
        let suiteName = "JoesProxyCLIAutomationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try MCPIsolatedControllerStack.make(userDefaults: defaults).controller
        XCTAssertFalse(first.isCLIAutomationStartEnabled)
        let didStartWhileDisabled = await first.startFromCLI()
        XCTAssertFalse(didStartWhileDisabled)

        first.isCLIAutomationStartEnabled = true
        let reloaded = try MCPIsolatedControllerStack.make(userDefaults: defaults).controller
        XCTAssertTrue(reloaded.isCLIAutomationStartEnabled)
    }

    func testSessionStoreKeepsIndependentEndpointSessions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JoesProxyCLITests-\(UUID().uuidString)", isDirectory: true)
        let persistenceURL = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CLIFileSessionStore(persistenceURL: persistenceURL)
        let firstEndpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let secondEndpoint = URL(string: "http://localhost:9092/mcp")!
        let first = CLIPersistedSession(
            endpoint: firstEndpoint.absoluteString,
            sessionID: "first",
            protocolVersion: "2025-03-26",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let second = CLIPersistedSession(
            endpoint: secondEndpoint.absoluteString,
            sessionID: "second",
            protocolVersion: "2025-03-26",
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        try store.save(first)
        try store.save(second)

        XCTAssertEqual(try store.load(endpoint: firstEndpoint), first)
        XCTAssertEqual(try store.load(endpoint: secondEndpoint), second)
        try store.delete(endpoint: firstEndpoint)
        XCTAssertNil(try store.load(endpoint: firstEndpoint))
        XCTAssertEqual(try store.load(endpoint: secondEndpoint), second)
    }

    func testResultEnvelopeIsStableAndDoesNotInventNullFields() throws {
        let envelope = CLIResultEnvelope(
            command: "capture digest",
            success: true,
            result: ["latestSequence": 42],
            warnings: [],
            errorCode: nil,
            errorMessage: nil
        )
        let object = envelope.jsonObject()

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["command"] as? String, "capture digest")
        XCTAssertEqual((object["result"] as? [String: Int])?["latestSequence"], 42)
        XCTAssertNil(object["errorCode"])
        XCTAssertNoThrow(try CLIJSON.data(object, pretty: false))
    }

    /// AK-5 gap: nothing exercised `--ndjson` output directly — `CLIApplication.emit` renders NDJSON
    /// mode via `CLIJSON.string(object, pretty: mode != .ndjson)`, i.e. the same envelope as `--json`
    /// mode, just non-pretty-printed onto one line. Proves that contract holds, not just that pretty
    /// JSON round-trips (`testResultEnvelopeIsStableAndDoesNotInventNullFields` above only covers
    /// the envelope shape itself, not the NDJSON rendering path).
    func testNDJSONOutputIsCompactSingleLineJSONMatchingTheJSONEnvelope() throws {
        let envelope = CLIResultEnvelope(
            command: "doctor",
            success: true,
            result: [
                "runtime": [
                    "runtimeIdentity": [
                        "appBuildFingerprint": String(repeating: "a", count: 64),
                        "marketingVersion": "1.4.1",
                        "buildVersion": "12",
                        "capabilitiesManifestDigest": String(repeating: "b", count: 64),
                        "skillVersion": "1.4.1"
                    ],
                    "compatibility": ["state": "compatible", "compatible": true]
                ]
            ],
            warnings: [],
            errorCode: nil,
            errorMessage: nil
        )
        let object = envelope.jsonObject()

        let prettyText = try CLIJSON.string(object, pretty: true)
        let ndjsonText = try CLIJSON.string(object, pretty: false)

        XCTAssertTrue(prettyText.contains("\n"), "sanity check: pretty JSON is expected to be multi-line")
        XCTAssertFalse(ndjsonText.contains("\n"), "NDJSON-mode rendering must be a single line, no embedded newlines")

        let roundTripped = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(ndjsonText.utf8)) as? [String: Any]
        )
        XCTAssertEqual(roundTripped["schemaVersion"] as? Int, 1)
        XCTAssertEqual(roundTripped["command"] as? String, "doctor")
        XCTAssertEqual(roundTripped["success"] as? Bool, true)
        let result = try XCTUnwrap(roundTripped["result"] as? [String: Any])
        let runtime = try XCTUnwrap(result["runtime"] as? [String: Any])
        let identity = try XCTUnwrap(runtime["runtimeIdentity"] as? [String: Any])
        XCTAssertEqual(identity["buildVersion"] as? String, "12")
    }

    /// AK-5 gap: `session end`'s cleanup gate (`CLIApplication.swift` — `guard isClean == true else
    /// throw policyDenied`) had zero test coverage in either direction before this.
    func testSessionEndTerminatesWhenCleanupStateIsClean() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var endSessionCalled = false
        let urlSession = makeMockURLSession()
        MockCLIURLProtocol.state.configure { request in
            // `MCPCLIClient.endSession()` issues a bare `DELETE` with no JSON-RPC body once cleanup
            // is confirmed clean — check the HTTP method before attempting to parse a body that
            // won't exist for this one request.
            if request.httpMethod == "DELETE" {
                endSessionCalled = true
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            }
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "session-end-clean"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                XCTAssertEqual(name, "client_cleanup_status")
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["isClean": true]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let sessionStore = MemoryCLISessionStore()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: sessionStore,
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )
        let exitCode = await application.run(arguments: ["session", "end", "--quiet"])
        XCTAssertEqual(exitCode, .success)
        XCTAssertTrue(endSessionCalled, "endSession() must actually be invoked when cleanup state is clean")
    }

    func testSessionEndIsBlockedWhenCleanupStateIsDirty() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var endSessionCalled = false
        let urlSession = makeMockURLSession()
        MockCLIURLProtocol.state.configure { request in
            // A `DELETE` here (MCPCLIClient.endSession()'s wire shape) would mean the code wrongly
            // proceeded past the cleanup gate — exactly the bug this test exists to catch. Check the
            // HTTP method before attempting JSON-RPC body parsing so that bug surfaces as a clear
            // assertion failure below, not an opaque body-parse error.
            if request.httpMethod == "DELETE" {
                endSessionCalled = true
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            }
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "session-end-dirty"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                XCTAssertEqual(name, "client_cleanup_status")
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": [
                            "isClean": false,
                            "pendingApprovalCount": 1,
                            "recommendedAction": "resolve_pending_approvals"
                        ]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )
        let exitCode = await application.run(arguments: ["session", "end", "--quiet"])
        XCTAssertEqual(exitCode, .policyDenied)
        XCTAssertFalse(endSessionCalled, "a dirty cleanup state must block session end, not just report it")
    }

    func testTransportInitializesThenSendsRequiredSessionHeaders() async throws {
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            let method = object["method"] as? String
            switch method {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "session-1"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                return try .json(
                    status: 200,
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": [
                            "structuredContent": [
                                "schemaVersion": 1,
                                "payload": ["latestSequence": 42]
                            ]
                        ]
                    ]
                )
            default:
                XCTFail("Unexpected MCP method \(method ?? "nil").")
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }
        let client = MCPCLIClient(
            endpoint: URL(string: "http://127.0.0.1:9091/mcp")!,
            credential: "secret-token",
            sessionStore: MemoryCLISessionStore(),
            timeout: 5,
            urlSession: makeMockURLSession()
        )

        let response = try await client.callTool(name: "capture_digest", arguments: [:])

        XCTAssertEqual((response["payload"] as? [String: Int])?["latestSequence"], 42)
        let requests = MockCLIURLProtocol.state.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: MCPCLIClient.sessionHeader))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: MCPCLIClient.sessionHeader), "session-1")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: MCPCLIClient.sessionHeader), "session-1")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: MCPCLIClient.protocolHeader), MCPCLIClient.preferredProtocolVersion)
    }

    func testNonIdempotentCallDoesNotReinitializeAfterStaleSession() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let store = MemoryCLISessionStore()
        try store.save(CLIPersistedSession(
            endpoint: endpoint.absoluteString,
            sessionID: "stale-session",
            protocolVersion: MCPCLIClient.preferredProtocolVersion,
            updatedAt: Date()
        ))
        MockCLIURLProtocol.state.configure { _ in
            MockCLIURLResponse(status: 404, headers: [:], body: Data())
        }
        let client = MCPCLIClient(
            endpoint: endpoint,
            credential: "secret-token",
            sessionStore: store,
            timeout: 5,
            urlSession: makeMockURLSession()
        )

        do {
            _ = try await client.callTool(
                name: "operation_cancel",
                arguments: ["operationID": "operation-1"],
                retryOnStaleSession: false
            )
            XCTFail("Expected a stale-session error.")
        } catch let error as CLIError {
            guard case .staleSession = error else {
                return XCTFail("Expected stale session, got \(error).")
            }
        }

        XCTAssertEqual(MockCLIURLProtocol.state.recordedRequests().count, 1)
        XCTAssertEqual(try store.load(endpoint: endpoint)?.sessionID, "stale-session")
    }

    // G6-03: a `stale_proposal`/`stale_cursor`/`stale_target_revision` JSON-RPC error must map to
    // the distinct `.staleProposal` CLIError, not `.staleSession` — conflating the two previously
    // gave "retry with a fresh MCP session" as advice for a failure a fresh session can never fix
    // (a consumed preview digest, or a rule deleted between propose and apply). See
    // Live-NOBLENDER-Audit-2026-08-05.md.
    func testStaleProposalJSONRPCErrorMapsToDistinctCLIErrorNotStaleSession() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let store = MemoryCLISessionStore()
        try store.save(CLIPersistedSession(
            endpoint: endpoint.absoluteString,
            sessionID: "session-1",
            protocolVersion: MCPCLIClient.preferredProtocolVersion,
            updatedAt: Date()
        ))
        let errorBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "error": [
                "code": -32000,
                "message": "The response-edit preview is missing, consumed, or expired.",
                "data": ["mcpCode": "stale_proposal"]
            ]
        ]
        MockCLIURLProtocol.state.configure { _ in
            MockCLIURLResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: errorBody)
            )
        }
        let client = MCPCLIClient(
            endpoint: endpoint,
            credential: "secret-token",
            sessionStore: store,
            timeout: 5,
            urlSession: makeMockURLSession()
        )

        do {
            _ = try await client.callTool(
                name: "propose_create_map_local",
                arguments: ["responseEditPreviewDigest": "response-edit-preview-consumed"],
                retryOnStaleSession: false
            )
            XCTFail("Expected a stale-proposal error.")
        } catch let error as CLIError {
            guard case .staleProposal = error else {
                return XCTFail("Expected .staleProposal, got \(error) (exitCode \(error.exitCode)).")
            }
            XCTAssertEqual(error.exitCode, .staleProposal)
            XCTAssertNotEqual(error.exitCode, .staleSession)
        }
    }

    /// AS: `--directory` mints an opaque bookmark ref and routes to `propose_create_map_local`
    /// without sending a raw filesystem path in MCP arguments.
    func testMapLocalPrepareDirectoryBuildsBookmarkRefArgument() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var capturedArguments: [String: Any]?
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLILocalDirectory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("x".utf8).write(to: directory.appendingPathComponent("index.html"))

        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "dir-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                XCTAssertEqual(name, "propose_create_map_local")
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                capturedArguments = arguments
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["proposalToken": "proposal-dir-1", "matchScope": [
                            "scheme": "https", "host": "www.example.com", "path": "/site"
                        ]]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }

        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: [
            "response", "map-local", "prepare",
            "--directory", directory.path,
            "--method", "GET",
            "--host", "www.example.com",
            "--path", "/site",
            "--not-found", "index.html",
            "--force-no-cache",
            "--quiet"
        ])
        XCTAssertEqual(exitCode, .success)
        let arguments = try XCTUnwrap(capturedArguments)
        XCTAssertEqual(arguments["path"] as? String, "/site")
        XCTAssertEqual(arguments["method"] as? String, "GET")
        XCTAssertEqual(arguments["host"] as? String, "www.example.com")
        XCTAssertEqual(arguments["matchMode"] as? String, "pathPrefix")
        XCTAssertEqual(arguments["notFoundRelativePath"] as? String, "index.html")
        XCTAssertEqual(arguments["forceNoCache"] as? Bool, true)
        let bookmarkRef = try XCTUnwrap(arguments["localDirectoryBookmarkRef"] as? String)
        XCTAssertFalse(bookmarkRef.isEmpty)
        XCTAssertFalse(bookmarkRef.contains(directory.path))
        let encoded = try JSONSerialization.data(withJSONObject: arguments)
        let decoded = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(decoded.contains(directory.path), "CLI must not send the raw directory path over MCP")
    }

    /// P1 (memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6): first-class
    /// single-file binary Map Local via `--file`, mirroring `--directory`'s bookmark-not-raw-path
    /// contract exactly.
    func testMapLocalPrepareFileBuildsBookmarkRefArgument() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var capturedArguments: [String: Any]?
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLILocalFile-\(UUID().uuidString).png")
        try Data("x".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "file-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                XCTAssertEqual(name, "propose_create_map_local")
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                capturedArguments = arguments
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["proposalToken": "proposal-file-1", "matchScope": [
                            "scheme": "https", "host": "cdn.example.com", "path": "/logo.png"
                        ]]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }

        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let exitCode = await application.run(arguments: [
            "response", "map-local", "prepare",
            "--file", fileURL.path,
            "--method", "GET",
            "--host", "cdn.example.com",
            "--path", "/logo.png",
            "--status-code", "200",
            "--content-type", "image/png",
            "--quiet"
        ])
        XCTAssertEqual(exitCode, .success)
        let arguments = try XCTUnwrap(capturedArguments)
        XCTAssertEqual(arguments["path"] as? String, "/logo.png")
        XCTAssertEqual(arguments["method"] as? String, "GET")
        XCTAssertEqual(arguments["host"] as? String, "cdn.example.com")
        // Single-file Map Local must NOT force pathPrefix like --directory does.
        XCTAssertEqual(arguments["matchMode"] as? String, "exactPath")
        XCTAssertEqual(arguments["statusCode"] as? Int, 200)
        XCTAssertEqual(arguments["contentType"] as? String, "image/png")
        let bookmarkRef = try XCTUnwrap(arguments["localFileBookmarkRef"] as? String)
        XCTAssertFalse(bookmarkRef.isEmpty)
        XCTAssertFalse(bookmarkRef.contains(fileURL.path))
        let encoded = try JSONSerialization.data(withJSONObject: arguments)
        let decoded = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(decoded.contains(fileURL.path), "CLI must not send the raw file path over MCP")
    }

    func testOpenAPIPackPrepareBuildsBookmarkRefWithoutFilePath() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var capturedArguments: [String: Any]?
        var capturedToolName: String?
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OpenAPI/catalog-v1.json")

        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "openapi-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                capturedToolName = try XCTUnwrap(params["name"] as? String)
                capturedArguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                return try .json(status: 200, object: [
                    "jsonrpc": "2.0", "id": object["id"] as Any,
                    "result": ["structuredContent": [
                        "schemaVersion": 1,
                        "payload": ["proposalToken": "proposal-openapi-1"]
                    ]]
                ])
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }

        let urlSession = makeMockURLSession()
        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )
        let exitCode = await application.run(arguments: [
            "openapi", "pack", "prepare",
            "--file", catalogURL.path,
            "--host", "catalog.example.invalid",
            "--scheme", "http",
            "--quiet"
        ])
        XCTAssertEqual(exitCode, .success)
        XCTAssertEqual(capturedToolName, "propose_openapi_pack_start")
        let arguments = try XCTUnwrap(capturedArguments)
        XCTAssertEqual(arguments["host"] as? String, "catalog.example.invalid")
        XCTAssertEqual(arguments["scheme"] as? String, "http")
        XCTAssertEqual(arguments["conflictStrategy"] as? String, "refuse")
        let bookmarkRef = try XCTUnwrap(arguments["openapiDocumentBookmarkRef"] as? String)
        XCTAssertFalse(bookmarkRef.isEmpty)
        XCTAssertFalse(bookmarkRef.contains(catalogURL.path))
        let encoded = try JSONSerialization.data(withJSONObject: arguments)
        let decoded = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(decoded.contains(catalogURL.path), "CLI must not send the raw OpenAPI path over MCP")
    }

    /// AN-6 gap: the `run` command family (diagnostic runs) had zero CLI-layer test coverage —
    /// only the MCP-tool layer was unit-tested. Covers `run create` -> `run start` ->
    /// `run observations` -> `run close`, confirmed live 2026-08-12.
    func testDiagnosticRunCreateStartObservationsCloseRoundTrip() async throws {
        let endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        let credentialStore = MemoryCLICredentialStore()
        try credentialStore.save("secret-token", endpoint: endpoint)
        var calledTools: [(String, [String: Any])] = []
        let urlSession = makeMockURLSession()
        MockCLIURLProtocol.state.configure { request in
            let object = try request.bodyData().jsonObject()
            switch object["method"] as? String {
            case "initialize":
                return try .json(
                    status: 200,
                    headers: [MCPCLIClient.sessionHeader: "diagnostic-run-cli-session"],
                    object: [
                        "jsonrpc": "2.0",
                        "id": object["id"] as Any,
                        "result": ["protocolVersion": MCPCLIClient.preferredProtocolVersion]
                    ]
                )
            case "notifications/initialized":
                return MockCLIURLResponse(status: 202, headers: [:], body: Data())
            case "tools/call":
                let params = try XCTUnwrap(object["params"] as? [String: Any])
                let name = try XCTUnwrap(params["name"] as? String)
                let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
                calledTools.append((name, arguments))
                switch name {
                case "diagnostic_run_create":
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["runID": "11111111-1111-1111-1111-111111111111", "status": "draft"]
                        ]]
                    ])
                case "diagnostic_run_start":
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["runID": "11111111-1111-1111-1111-111111111111", "status": "watching"]
                        ]]
                    ])
                case "diagnostic_run_observations":
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": ["records": [] as [[String: Any]], "droppedObservationCount": 0]
                        ]]
                    ])
                case "diagnostic_run_close":
                    return try .json(status: 200, object: [
                        "jsonrpc": "2.0", "id": object["id"] as Any,
                        "result": ["structuredContent": [
                            "schemaVersion": 1,
                            "payload": [
                                "runID": "11111111-1111-1111-1111-111111111111",
                                "status": "passed",
                                "evidenceID": "22222222-2222-2222-2222-222222222222",
                                "cleanupVerified": true
                            ] as [String: Any]
                        ]]
                    ])
                default:
                    return MockCLIURLResponse(status: 500, headers: [:], body: Data())
                }
            default:
                return MockCLIURLResponse(status: 500, headers: [:], body: Data())
            }
        }

        let application = CLIApplication(
            credentialStore: credentialStore,
            sessionStore: MemoryCLISessionStore(),
            appLauncher: MockCLIAppLauncher(),
            clientFactory: { endpoint, credential, store, timeout in
                MCPCLIClient(
                    endpoint: endpoint,
                    credential: credential,
                    sessionStore: store,
                    timeout: timeout,
                    urlSession: urlSession
                )
            }
        )

        let createExit = await application.run(arguments: [
            "run", "create",
            "--hypothesis", "GET api.example.com/v1/widgets returns 200",
            "--expected", "A 2xx status family on every matched request",
            "--host", "api.example.com", "--path", "/v1/widgets", "--method", "GET",
            "--scheme", "https", "--path-match", "exact", "--quiet"
        ])
        let startExit = await application.run(arguments: [
            "run", "start", "11111111-1111-1111-1111-111111111111", "--quiet"
        ])
        let observationsExit = await application.run(arguments: [
            "run", "observations", "11111111-1111-1111-1111-111111111111", "--quiet"
        ])
        let closeExit = await application.run(arguments: [
            "run", "close", "11111111-1111-1111-1111-111111111111",
            "--terminal", "passed", "--outcome", "passed",
            "--reason", "expected_observed", "--summary", "Matched requests returned 2xx.", "--quiet"
        ])

        XCTAssertEqual(createExit, .success)
        XCTAssertEqual(startExit, .success)
        XCTAssertEqual(observationsExit, .success)
        XCTAssertEqual(closeExit, .success)
        XCTAssertEqual(
            calledTools.map(\.0),
            ["diagnostic_run_create", "diagnostic_run_start", "diagnostic_run_observations", "diagnostic_run_close"]
        )

        let createArguments = calledTools[0].1
        XCTAssertEqual(createArguments["hypothesisSummary"] as? String, "GET api.example.com/v1/widgets returns 200")
        XCTAssertEqual(createArguments["expectedObservation"] as? String, "A 2xx status family on every matched request")
        let scopes = try XCTUnwrap(createArguments["scopes"] as? [[String: Any]])
        XCTAssertEqual(scopes.first?["host"] as? String, "api.example.com")
        XCTAssertEqual(scopes.first?["path"] as? String, "/v1/widgets")
        XCTAssertEqual(scopes.first?["pathMatch"] as? String, "exact")

        XCTAssertEqual(calledTools[1].1["runID"] as? String, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(calledTools[2].1["runID"] as? String, "11111111-1111-1111-1111-111111111111")

        let closeArguments = calledTools[3].1
        XCTAssertEqual(closeArguments["runID"] as? String, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(closeArguments["requestedTerminal"] as? String, "passed")
        XCTAssertEqual(closeArguments["conclusionOutcome"] as? String, "passed")
        XCTAssertEqual(closeArguments["conclusionReasonCode"] as? String, "expected_observed")
        XCTAssertEqual(closeArguments["conclusionSummary"] as? String, "Matched requests returned 2xx.")
    }

    func testIntegrationsDiscoveryAndGuides() throws {
        XCTAssertEqual(CLIIntegrations.companions.count, 3)
        XCTAssertEqual(CLIIntegrations.companions.map(\.id), ["tvtestrig", "viewlens", "instruments"])
        XCTAssertTrue(CLIIntegrations.listMarkdown.contains("TVTestRig"))
        XCTAssertTrue(CLIIntegrations.listMarkdown.contains("ViewLens"))

        let tv = try CLIIntegrations.show(name: "tvtestrig")
        XCTAssertEqual(tv.json["integration"] as? String, "tvtestrig")
        XCTAssertTrue(tv.markdown.contains("TVTestRig"))

        let vl = try CLIIntegrations.show(name: "viewlens")
        XCTAssertEqual(vl.json["integration"] as? String, "viewlens")
        XCTAssertTrue(vl.markdown.contains("ViewLens"))

        let inst = try CLIIntegrations.show(name: "instruments")
        XCTAssertEqual(inst.json["integration"] as? String, "instruments")

        XCTAssertThrowsError(try CLIIntegrations.show(name: "unknown-tool"))
    }

    func testIntegrationsRecipeTruncationAudit() throws {
        let result = try CLIIntegrations.recipe(
            kind: "truncation-audit",
            targetURL: "https://api.example.invalid/items",
            field: "headline"
        )
        XCTAssertEqual(result.json["recipe"] as? String, "truncation-audit")
        XCTAssertEqual(result.json["targetURL"] as? String, "https://api.example.invalid/items")
        XCTAssertEqual(result.json["targetField"] as? String, "headline")
        XCTAssertTrue(result.markdown.contains("headline"))
        XCTAssertTrue(result.markdown.contains("api.example.invalid/items"))
        let starter = try XCTUnwrap(result.json["scriptStarter"] as? String)
        XCTAssertTrue(starter.contains("JoesProxy + ViewLens"))

        XCTAssertThrowsError(try CLIIntegrations.recipe(kind: "unknown-recipe", targetURL: nil, field: nil))
    }

    func testIntegrationsCLIExecution() async throws {
        let app = CLIApplication(credentialStore: MemoryCLICredentialStore(), sessionStore: MemoryCLISessionStore(), appLauncher: MockCLIAppLauncher())

        let listResult = await app.run(arguments: ["integrations", "list", "--quiet"])
        XCTAssertEqual(listResult, .success)

        let flagResult = await app.run(arguments: ["--integrations", "--quiet"])
        XCTAssertEqual(flagResult, .success)

        let showResult = await app.run(arguments: ["integrations", "show", "tvtestrig", "--quiet"])
        XCTAssertEqual(showResult, .success)

        let recipeResult = await app.run(arguments: ["integrations", "recipe", "truncation-audit", "--field", "title", "--quiet"])
        XCTAssertEqual(recipeResult, .success)

        let unknownSubResult = await app.run(arguments: ["integrations", "invalid-subcommand", "--quiet"])
        XCTAssertEqual(unknownSubResult, .invalidArguments)

        let missingShowResult = await app.run(arguments: ["integrations", "show", "--quiet"])
        XCTAssertEqual(missingShowResult, .invalidArguments)
    }

    private func makeMockURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCLIURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private typealias MemoryCLISessionStore = TestCLISessionStore
private typealias MemoryCLICredentialStore = TestCLICredentialStore

final class TestCLISessionStore: CLISessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: CLIPersistedSession] = [:]

    func load(endpoint: URL) throws -> CLIPersistedSession? {
        lock.withLock { sessions[endpoint.absoluteString] }
    }

    func save(_ session: CLIPersistedSession) throws {
        lock.withLock { sessions[session.endpoint] = session }
    }

    func delete(endpoint: URL) throws {
        lock.withLock { _ = sessions.removeValue(forKey: endpoint.absoluteString) }
    }
}

final class TestCLICredentialStore: CLICredentialStoring {
    private var credentials: [String: String] = [:]
    private(set) var loadCount = 0

    func load(endpoint: URL) throws -> String? {
        loadCount += 1
        return credentials[endpoint.absoluteString]
    }
    func save(_ credential: String, endpoint: URL) throws { credentials[endpoint.absoluteString] = credential }
    func delete(endpoint: URL) throws { credentials.removeValue(forKey: endpoint.absoluteString) }
}

private final class MockCLIAppLauncher: CLIAppLaunching {
    private(set) var startRequestCount = 0
    private(set) var lastLaunchArguments: [String] = []

    func applicationURL() throws -> URL { URL(fileURLWithPath: "/Applications/JoesProxy.app") }

    func requestMCPStart(launchArguments: [String]) async throws -> URL {
        startRequestCount += 1
        lastLaunchArguments = launchArguments
        return try applicationURL()
    }
}

private struct MockCLIURLResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(status: Int, headers: [String: String] = [:], object: [String: Any]) throws -> Self {
        MockCLIURLResponse(
            status: status,
            headers: headers.merging(["Content-Type": "application/json"]) { current, _ in current },
            body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}

private final class MockCLIURLProtocol: URLProtocol {
    static let state = State()

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((URLRequest) throws -> MockCLIURLResponse)?
        private var requests: [URLRequest] = []

        func reset() {
            lock.withLock {
                handler = nil
                requests = []
            }
        }

        func configure(_ handler: @escaping (URLRequest) throws -> MockCLIURLResponse) {
            lock.withLock { self.handler = handler }
        }

        func response(for request: URLRequest) throws -> MockCLIURLResponse {
            try lock.withLock {
                requests.append(request)
                guard let handler else {
                    throw CLIError.internalFailure("No mock response handler was configured.")
                }
                return try handler(request)
            }
        }

        func recordedRequests() -> [URLRequest] {
            lock.withLock { requests }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let value = try Self.state.response(for: request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: value.status,
                httpVersion: "HTTP/1.1",
                headerFields: value.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !value.body.isEmpty {
                client?.urlProtocol(self, didLoad: value.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Data {
    func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
    }
}

private extension URLRequest {
    func bodyData() throws -> Data {
        if let httpBody {
            return httpBody
        }
        guard let httpBodyStream else {
            throw CLIError.internalFailure("Mock request did not contain an HTTP body.")
        }

        httpBodyStream.open()
        defer { httpBodyStream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = httpBodyStream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw httpBodyStream.streamError
                    ?? CLIError.internalFailure("Mock request body stream failed.")
            }
            if count == 0 {
                return data
            }
            data.append(buffer, count: count)
        }
    }
}
