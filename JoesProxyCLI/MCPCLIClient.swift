import Foundation

struct MCPCLIResponse {
    var statusCode: Int
    var headers: [AnyHashable: Any]
    var object: [String: Any]?
    var body: Data
}

final class MCPCLIClient {
    static let preferredProtocolVersion = "2025-03-26"
    static let sessionHeader = "Mcp-Session-Id"
    static let protocolHeader = "MCP-Protocol-Version"

    private let endpoint: URL
    private let credential: String
    private let sessionStore: any CLISessionStoring
    private let urlSession: URLSession
    private let timeout: TimeInterval
    private var logicalSession: CLIPersistedSession?
    private var nextRequestID = 1
    var receiptRecorder: CLIReceiptRecorder?

    init(
        endpoint: URL,
        credential: String,
        sessionStore: any CLISessionStoring,
        timeout: TimeInterval,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.credential = credential
        self.sessionStore = sessionStore
        self.timeout = timeout
        self.urlSession = urlSession
        logicalSession = try? sessionStore.load(endpoint: endpoint)
    }

    func ping() async throws -> [String: Any] {
        try await readResource("joesproxy://server/status")
    }

    func readResource(_ uri: String) async throws -> [String: Any] {
        let result = try await callMethod(
            "resources/read",
            params: ["uri": uri],
            retryOnStaleSession: true
        )
        do {
            guard let contents = result["contents"] as? [[String: Any]],
                  let text = contents.first?["text"] as? String,
                  let data = text.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError.malformedResponse("JoesProxy returned an invalid resource payload.")
            }
            return object
        } catch {
            receiptRecorder?.markLastFailure()
            throw error
        }
    }

    func callTool(
        name: String,
        arguments: [String: Any],
        retryOnStaleSession: Bool = true,
        receiptRetryOf: String? = nil
    ) async throws -> [String: Any] {
        let result = try await callMethod(
            "tools/call",
            params: ["name": name, "arguments": arguments],
            retryOnStaleSession: retryOnStaleSession,
            receiptRetryOf: receiptRetryOf
        )
        guard let structured = result["structuredContent"] as? [String: Any] else {
            throw CLIError.malformedResponse("JoesProxy returned a tool result without structured content.")
        }
        return structured
    }

    func endSession() async throws {
        guard let logicalSession else {
            try sessionStore.delete(endpoint: endpoint)
            return
        }
        var request = baseRequest(method: "DELETE")
        applySessionHeaders(logicalSession, to: &request)
        let response = try await perform(request)
        guard response.statusCode == 200 || response.statusCode == 202 || response.statusCode == 404 else {
            try throwHTTPError(response)
        }
        self.logicalSession = nil
        try sessionStore.delete(endpoint: endpoint)
    }

    func watch(
        resourceURI: String,
        duration: TimeInterval?,
        onSubscribed: (() async throws -> Void)? = nil,
        onEvent: @escaping ([String: Any]) async throws -> Void
    ) async throws {
        _ = try await callMethod(
            "resources/subscribe",
            params: ["uri": resourceURI],
            retryOnStaleSession: true
        )
        guard let logicalSession else {
            throw CLIError.staleSession("No initialized MCP session is available for notifications.")
        }
        try await onSubscribed?()
        var request = baseRequest(method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applySessionHeaders(logicalSession, to: &request)
        if let duration { request.timeoutInterval = duration }

        do {
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CLIError.malformedResponse("JoesProxy returned a non-HTTP notification response.")
            }
            guard http.statusCode == 200 else {
                throw CLIError.staleSession("The MCP notification stream could not be opened (HTTP \(http.statusCode)).")
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data: ") else { continue }
                let json = String(line.dropFirst("data: ".count))
                guard let data = json.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                try await onEvent(object)
            }
        } catch is CancellationError {
            throw CLIError.timedOut("The watch operation ended.")
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.serverUnavailable("The MCP notification stream ended: \(error.localizedDescription)")
        }
    }

    private func callMethod(
        _ method: String,
        params: [String: Any],
        retryOnStaleSession: Bool,
        receiptRetryOf: String? = nil
    ) async throws -> [String: Any] {
        if method != "initialize" {
            try await ensureSession()
        }
        let id = nextRequestID
        nextRequestID += 1
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        var request = baseRequest(method: "POST")
        if method != "initialize", let logicalSession {
            applySessionHeaders(logicalSession, to: &request)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let response = try await perform(request, operation: method, retryOf: receiptRetryOf)
        if response.statusCode == 404, method != "initialize", retryOnStaleSession {
            let failedAttempt = receiptRecorder?.lastID
            logicalSession = nil
            try sessionStore.delete(endpoint: endpoint)
            try await ensureSession()
            return try await callMethod(method, params: params, retryOnStaleSession: false, receiptRetryOf: failedAttempt)
        }
        guard response.statusCode == 200 else { try throwHTTPError(response) }
        guard let object = response.object else {
            throw CLIError.malformedResponse("JoesProxy returned an empty JSON-RPC response.")
        }
        if let error = object["error"] as? [String: Any] {
            throw jsonRPCError(error)
        }
        guard let result = object["result"] as? [String: Any] else {
            throw CLIError.malformedResponse("JoesProxy returned a JSON-RPC response without a result.")
        }
        return result
    }

    private func ensureSession() async throws {
        if logicalSession != nil { return }
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": nextRequestID,
            "method": "initialize",
            "params": [
                "protocolVersion": Self.preferredProtocolVersion,
                "capabilities": [
                    "experimental": [
                        "joesproxy": ["structuredResultsOnly": true]
                    ]
                ],
                "clientInfo": ["name": "joesproxyctl", "version": "1"]
            ]
        ]
        nextRequestID += 1
        var request = baseRequest(method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let response = try await perform(request, operation: "initialize")
        guard response.statusCode == 200 else { try throwHTTPError(response) }
        guard let object = response.object,
              let result = object["result"] as? [String: Any],
              let protocolVersion = result["protocolVersion"] as? String,
              let sessionID = header(Self.sessionHeader, in: response.headers) else {
            throw CLIError.malformedResponse("JoesProxy initialization did not return a logical session.")
        }
        let state = CLIPersistedSession(
            endpoint: endpoint.absoluteString,
            sessionID: sessionID,
            protocolVersion: protocolVersion,
            updatedAt: Date()
        )
        // A failed initialized notification must not poison subsequent commands with an
        // unready session. Publish locally only after the complete handshake succeeds.
        try await sendInitializedNotification(state)
        try sessionStore.save(state)
        logicalSession = state
    }

    private func sendInitializedNotification(_ state: CLIPersistedSession) async throws {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:] as [String: Any]
        ]
        var request = baseRequest(method: "POST")
        applySessionHeaders(state, to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let response = try await perform(request)
        guard response.statusCode == 202 else { try throwHTTPError(response) }
    }

    private func baseRequest(method: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func applySessionHeaders(_ state: CLIPersistedSession, to request: inout URLRequest) {
        request.setValue(state.sessionID, forHTTPHeaderField: Self.sessionHeader)
        request.setValue(state.protocolVersion, forHTTPHeaderField: Self.protocolHeader)
    }

    private func perform(_ request: URLRequest, operation: String = "transport", retryOf: String? = nil) async throws -> MCPCLIResponse {
        let started = ProcessInfo.processInfo.systemUptime
        var byteCount: Int?
        var succeeded = false
        var reused: Bool?
        defer {
            receiptRecorder?.record(operation: operation, bytes: byteCount, succeeded: succeeded,
                elapsed: ProcessInfo.processInfo.systemUptime - started, reused: reused, retryOf: retryOf)
        }
        do {
            let (data, response) = try await urlSession.data(for: request)
            byteCount = data.count
            guard let http = response as? HTTPURLResponse else {
                throw CLIError.malformedResponse("JoesProxy returned a non-HTTP response.")
            }
            let object = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            succeeded = http.statusCode == 200 && object != nil && object?["error"] == nil
            if operation == "transport" {
                succeeded = request.httpMethod == "DELETE" ? [200, 202, 404].contains(http.statusCode) : http.statusCode == 202
            }
            let result = object?["result"] as? [String: Any]
            if operation != "transport", result == nil { succeeded = false }
            if result?["isError"] as? Bool == true { succeeded = false }
            let structured = result?["structuredContent"] as? [String: Any]
            if operation == "tools/call", structured == nil { succeeded = false }
            if operation == "initialize",
               result?["protocolVersion"] as? String == nil || http.value(forHTTPHeaderField: Self.sessionHeader) == nil {
                succeeded = false
            }
            let payload = structured?["payload"] as? [String: Any] ?? structured
            reused = succeeded ? payload?["analysisReused"] as? Bool : nil
            return MCPCLIResponse(
                statusCode: http.statusCode,
                headers: http.allHeaderFields,
                object: object,
                body: data
            )
        } catch let error as CLIError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw CLIError.timedOut("The MCP request timed out. Its outcome may be unknown; inspect status before retrying an apply operation. No automatic retry was made.")
        } catch {
            throw CLIError.serverUnavailable(
                "The MCP connection failed. Check the configured endpoint and run joesproxyctl doctor. If the server is stopped, start MCP in JoesProxy. An interrupted request may already have taken effect; inspect status before retrying an apply operation. No automatic retry was made."
            )
        }
    }

    private func throwHTTPError(_ response: MCPCLIResponse) throws -> Never {
        switch response.statusCode {
        case 401:
            throw CLIError.authenticationFailed("The MCP server rejected the stored credential. Check that the endpoint belongs to the intended JoesProxy instance.")
        case 403:
            throw CLIError.policyDenied("The enrolled CLI profile does not permit this operation.")
        case 404:
            throw CLIError.staleSession("The MCP logical session is no longer valid.")
        case 408:
            throw CLIError.timedOut("The MCP request timed out.")
        case 429:
            throw CLIError.rateLimited("JoesProxy is busy or rate limited this client. Retry after the reported interval.")
        default:
            throw CLIError.serverUnavailable("The MCP endpoint returned HTTP \(response.statusCode). Check the endpoint with joesproxyctl doctor. An interrupted operation may have taken effect; inspect status before retrying. No automatic retry was made.")
        }
    }

    private func jsonRPCError(_ error: [String: Any]) -> CLIError {
        let message = error["message"] as? String ?? "JoesProxy rejected the request."
        let data = error["data"] as? [String: Any]
        let preparationDetails = data?["details"] as? [String: Any]
        if preparationDetails?["phase"] as? String == "documentation",
           let reason = preparationDetails?["reason"] as? String, reason.utf8.count <= 128,
           let recovery = preparationDetails?["recommendedAction"] as? String, recovery.utf8.count <= 1024 {
            return .documentation(reason: reason, recovery: recovery)
        }
        if data?["mcpCode"] as? String == "malformed_request", preparationDetails?["phase"] as? String == "preparation" {
            var details: [String: String] = [:]
            for key in ["phase", "field", "reason", "recommendedAction", "nextTool"] {
                if let value = preparationDetails?[key] as? String, value.utf8.count <= 1024 { details[key] = value }
            }
            return .invalidPreparation(message: message, details: details)
        }
        switch data?["mcpCode"] as? String {
        case "malformed_request":
            return .invalidArguments(message)
        case "approval_required":
            return .approvalRequired(requestID: data?["requestID"] as? String, message: message)
        case "policy_denied":
            return .policyDenied(message)
        case "rate_limited", "busy":
            return .rateLimited(message)
        case "timeout":
            return .timedOut(message)
        case "unauthorized":
            return .authenticationFailed(message)
        case "stale_cursor", "stale_target_revision", "stale_proposal":
            return .staleProposal(message)
        default:
            if message.lowercased().contains("policy denied") { return .policyDenied(message) }
            return .internalFailure(message)
        }
    }

    private func header(_ name: String, in headers: [AnyHashable: Any]) -> String? {
        headers.first { String(describing: $0.key).caseInsensitiveCompare(name) == .orderedSame }
            .map { String(describing: $0.value) }
    }
}
