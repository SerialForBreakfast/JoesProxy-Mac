import CryptoKit
import Foundation
import Network
import OSLog

// Manual interoperability harness only — not CI-authoritative for production MCP transport behavior.
// Production cancellation, limits, and protocol semantics are validated in MCPProtocolCancellationTests
// and MCPTransportLimitsTests against MCPProtocolService / MCPNIOHTTPTransport.

enum MCPTransportSpikeDiagnosticEvent: Equatable, Sendable {
    enum RejectionReason: String, Equatable, Sendable {
        case requestTooLarge = "request_too_large"
        case malformedHTTP = "malformed_http"
        case endpointNotFound = "endpoint_not_found"
        case eventStreamUnavailable = "event_stream_unavailable"
        case sessionTerminationUnsupported = "session_termination_unsupported"
        case methodNotAllowed = "method_not_allowed"
        case originRejected = "origin_rejected"
        case hostRejected = "host_rejected"
        case unacceptableResponseType = "unacceptable_response_type"
        case unsupportedContentType = "unsupported_content_type"
        case authorizationUnavailable = "authorization_unavailable"
        case authorizationMissing = "authorization_missing"
        case authorizationInvalid = "authorization_invalid"
        case malformedJSON = "malformed_json"
        case unsupportedBatch = "unsupported_batch"
        case invalidJSONRPC = "invalid_json_rpc"
        case sessionMissing = "session_missing"
        case sessionUnknown = "session_unknown"
        case protocolVersionMissing = "protocol_version_missing"
        case protocolVersionMismatch = "protocol_version_mismatch"
    }

    case listenerStarted(port: UInt16)
    case listenerStopped
    case listenerFailed
    case requestRejected(RejectionReason)
    case initializeAccepted(protocolVersion: String)
    case sessionInitialized
    case toolCallStarted(name: String)
    case cancellationReceived

    var consoleDescription: String {
        switch self {
        case .listenerStarted(let port):
            return "listener_started port=\(port)"
        case .listenerStopped:
            return "listener_stopped"
        case .listenerFailed:
            return "listener_failed"
        case .requestRejected(let reason):
            return "request_rejected reason=\(reason.rawValue)"
        case .initializeAccepted(let protocolVersion):
            return "initialize_accepted protocol=\(protocolVersion)"
        case .sessionInitialized:
            return "session_initialized"
        case .toolCallStarted(let name):
            return "tool_call_started name=\(name)"
        case .cancellationReceived:
            return "cancellation_received"
        }
    }
}

/// AG-0 interoperability spike: loopback Streamable HTTP MCP server with bearer auth.
///
/// Not wired into ``AppCoordinator``; used by tests and manual client validation only.
/// Concurrency: isolated on this actor; start/stop and handleConnection run off the main actor.
actor MCPTransportSpikeServer {
    struct Configuration: Sendable {
        var port: UInt16
        var endpointPath: String
        var supportedProtocolVersions: [String]
        var maxRequestBodyBytes: Int
        var maxHeaderBytes: Int

        static let `default` = Configuration(
            port: NetworkConstants.mcpDefaultPort,
            endpointPath: MCPNetworkConstants.endpointPath,
            supportedProtocolVersions: MCPNetworkConstants.supportedProtocolVersions,
            maxRequestBodyBytes: MCPNetworkConstants.maxRequestBodyBytes,
            maxHeaderBytes: MCPNetworkConstants.maxHeaderBytes
        )

        var preferredProtocolVersion: String {
            supportedProtocolVersions.first ?? MCPNetworkConstants.preferredProtocolVersion
        }
    }

    struct Status: Equatable, Sendable {
        var isRunning: Bool
        var port: UInt16?
        var endpointURL: URL?
        var connectedClientCount: Int
        var sessionCount: Int

        static let stopped = Status(
            isRunning: false,
            port: nil,
            endpointURL: nil,
            connectedClientCount: 0,
            sessionCount: 0
        )
    }

    enum ServerError: Error, Equatable {
        case invalidPort
        case bindFailed(String)
        case alreadyRunning
        case notRunning
    }

    private struct ParsedHTTPRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private struct RequestRejection {
        var reason: MCPTransportSpikeDiagnosticEvent.RejectionReason
        var response: Data
    }

    private enum RequestReceiveResult {
        case data(Data)
        case tooLarge
    }

    private struct Session {
        let id: String
        let protocolVersion: String
        var initialized: Bool
        var cancelledRequestIDs: Set<JSONValue>
    }

    private struct RequestKey: Hashable {
        let sessionID: String
        let requestID: JSONValue
    }

    private enum JSONValue: Hashable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null

        init?(any value: Any) {
            switch value {
            case let string as String:
                self = .string(string)
            case let int as Int:
                self = .int(int)
            case let double as Double:
                self = .double(double)
            case let bool as Bool:
                self = .bool(bool)
            case let number as NSNumber:
                self = .int(number.intValue)
            case is NSNull:
                self = .null
            default:
                return nil
            }
        }
    }

    private let configuration: Configuration
    private let logger = Logger(subsystem: "com.JoesProxyApp", category: "MCPTransportSpike")
    private let diagnosticSink: @Sendable (MCPTransportSpikeDiagnosticEvent) async -> Void

    private var listener: NWListener?
    private var runningPort: UInt16?
    private var bearerVerifier: Data?
    private var sessions: [String: Session] = [:]
    private var activeConnections = 0
    private var slowToolTasks: [RequestKey: Task<Void, Never>] = [:]

    init(
        configuration: Configuration = .default,
        diagnosticSink: @escaping @Sendable (MCPTransportSpikeDiagnosticEvent) async -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.diagnosticSink = diagnosticSink
    }

    func status() -> Status {
        Status(
            isRunning: listener != nil,
            port: runningPort,
            endpointURL: endpointURL(),
            connectedClientCount: activeConnections,
            sessionCount: sessions.count
        )
    }

    /// Starts the spike listener on loopback only and returns the one-time bearer credential.
    /// Explicit port zero requests a listener-owned ephemeral port for isolated tests.
    func start(port: UInt16? = nil, bearerCredential suppliedCredential: String? = nil) async throws -> String {
        guard listener == nil else {
            throw ServerError.alreadyRunning
        }

        let bindPort = port ?? configuration.port
        let credential = suppliedCredential ?? Self.makeBearerCredential()
        guard credential.utf8.count >= 32 else {
            throw ServerError.bindFailed("Bearer credential must contain at least 32 UTF-8 bytes")
        }
        bearerVerifier = Self.hashCredential(credential)

        let parameters = NWParameters.tcp
        guard let networkPort = bindPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: bindPort) else {
            throw ServerError.invalidPort
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: networkPort
        )

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            bearerVerifier = nil
            throw ServerError.bindFailed(error.localizedDescription)
        }

        newListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleConnection(connection) }
        }
        newListener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { await self?.handleListenerFailure(error) }
            }
        }

        newListener.start(queue: .global(qos: .utility))
        listener = newListener
        do {
            runningPort = try await waitForBoundPort(newListener)
        } catch {
            resetRuntimeState()
            throw error
        }
        logger.info("MCP transport spike started on 127.0.0.1:\(self.runningPort ?? bindPort)")
        await emit(.listenerStarted(port: runningPort ?? bindPort))
        return credential
    }

    private func waitForBoundPort(_ listener: NWListener, attempts: Int = 50) async throws -> UInt16 {
        for _ in 0..<attempts {
            if let port = listener.port?.rawValue, port != 0 {
                return port
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ServerError.bindFailed("Listener did not report a bound port")
    }

    func stop() async {
        if listener != nil {
            await emit(.listenerStopped)
        }
        resetRuntimeState()
        logger.info("MCP transport spike stopped")
    }

    private func endpointURL() -> URL? {
        guard let runningPort else { return nil }
        return URL(string: "http://127.0.0.1:\(runningPort)\(configuration.endpointPath)")
    }

    private func handleListenerFailure(_ error: NWError) async {
        logger.error("MCP spike listener failed: \(error.localizedDescription)")
        await emit(.listenerFailed)
        resetRuntimeState()
    }

    private func emit(_ event: MCPTransportSpikeDiagnosticEvent) async {
        logger.info("\(event.consoleDescription, privacy: .public)")
        await diagnosticSink(event)
    }

    private func resetRuntimeState() {
        listener?.cancel()
        listener = nil
        runningPort = nil
        bearerVerifier = nil
        sessions.removeAll()
        slowToolTasks.values.forEach { $0.cancel() }
        slowToolTasks.removeAll()
    }

    private func handleConnection(_ connection: NWConnection) async {
        activeConnections += 1
        defer { activeConnections -= 1 }

        connection.start(queue: .global(qos: .utility))
        let receiveResult = await receiveRequestData(from: connection)
        guard case .data(let requestData) = receiveResult else {
            await emit(.requestRejected(.requestTooLarge))
            await sendHTTPResponse(
                on: connection,
                statusCode: 413,
                body: Data("Payload Too Large".utf8)
            )
            connection.cancel()
            return
        }
        guard let request = parseHTTPRequest(from: requestData) else {
            await emit(.requestRejected(.malformedHTTP))
            await sendHTTPResponse(on: connection, statusCode: 400, body: Data("Bad Request".utf8))
            connection.cancel()
            return
        }

        let responseData = await route(request: request)
        await sendRaw(responseData, on: connection)
        connection.cancel()
    }

    private func route(request: ParsedHTTPRequest) async -> Data {
        guard request.path == configuration.endpointPath else {
            return await rejectedResponse(
                .endpointNotFound,
                response: httpResponse(statusCode: 404, headers: [:], body: Data("Not Found".utf8))
            )
        }

        if request.method == "GET" {
            return await rejectedResponse(
                .eventStreamUnavailable,
                response: httpResponse(statusCode: 405, headers: [:], body: Data("Method Not Allowed".utf8))
            )
        }

        if request.method == "DELETE" {
            return await rejectedResponse(
                .sessionTerminationUnsupported,
                response: httpResponse(statusCode: 405, headers: [:], body: Data("Method Not Allowed".utf8))
            )
        }

        guard request.method == "POST" else {
            return await rejectedResponse(
                .methodNotAllowed,
                response: httpResponse(statusCode: 405, headers: [:], body: Data("Method Not Allowed".utf8))
            )
        }

        if let originError = validateOrigin(request.headers) {
            return await rejectedResponse(.originRejected, response: originError)
        }

        if let hostError = validateHost(request.headers) {
            return await rejectedResponse(.hostRejected, response: hostError)
        }

        if request.body.count > configuration.maxRequestBodyBytes {
            return await rejectedResponse(
                .requestTooLarge,
                response: jsonErrorResponse(
                    statusCode: 413,
                    code: -32000,
                    message: "Request body exceeds limit."
                )
            )
        }

        guard validateAcceptHeader(request.headers) else {
            return await rejectedResponse(
                .unacceptableResponseType,
                response: httpResponse(statusCode: 406, headers: [:], body: Data("Not Acceptable".utf8))
            )
        }

        guard request.headers["content-type"]?.lowercased().contains("application/json") == true else {
            return await rejectedResponse(
                .unsupportedContentType,
                response: httpResponse(statusCode: 415, headers: [:], body: Data("Unsupported Media Type".utf8))
            )
        }

        if let authorizationFailure = validateAuthorization(request.headers) {
            return await rejectedResponse(
                authorizationFailure.reason,
                response: authorizationFailure.response
            )
        }

        guard let jsonObject = parseJSONObject(from: request.body) else {
            return await rejectedResponse(
                .malformedJSON,
                response: jsonErrorResponse(statusCode: 400, code: -32700, message: "Parse error.")
            )
        }

        if let batch = jsonObject as? [Any] {
            return await rejectedResponse(
                .unsupportedBatch,
                response: jsonErrorResponse(
                    statusCode: 400,
                    code: -32600,
                    message: batch.isEmpty
                        ? "Empty JSON-RPC batch is invalid."
                        : "JSON-RPC batching is not supported."
                )
            )
        }

        if let dict = jsonObject as? [String: Any] {
            if let protocolError = validateSessionAndProtocol(message: dict, request: request) {
                return await rejectedResponse(protocolError.reason, response: protocolError.response)
            }
            return await handleSingleMessage(dict, request: request)
        }

        return await rejectedResponse(
            .invalidJSONRPC,
            response: jsonErrorResponse(statusCode: 400, code: -32600, message: "Invalid Request.")
        )
    }

    private func rejectedResponse(
        _ reason: MCPTransportSpikeDiagnosticEvent.RejectionReason,
        response: Data
    ) async -> Data {
        await emit(.requestRejected(reason))
        return response
    }

    private func handleSingleMessage(
        _ message: [String: Any],
        request: ParsedHTTPRequest
    ) async -> Data {
        if message["method"] != nil, message["id"] == nil {
            await handleNotification(message, request: request)
            return httpResponse(statusCode: 202, headers: [:], body: Data())
        }

        guard let responseObject = await buildJSONRPCResponse(for: message, request: request) else {
            return httpResponse(statusCode: 202, headers: [:], body: Data())
        }

        var headers = sessionHeaders(for: request)
        if let method = message["method"] as? String,
           method == "initialize",
           let result = responseObject["result"] as? [String: Any],
           let sessionID = result["_spikeSessionID"] as? String {
            headers[MCPNetworkConstants.sessionIDHeader] = sessionID
        }

        return jsonResponse(
            statusCode: 200,
            headers: headers,
            object: sanitizeResponseForWire(responseObject)
        )
    }

    private func sanitizeResponseForWire(_ response: [String: Any]) -> [String: Any] {
        guard var result = response["result"] as? [String: Any] else {
            return response
        }
        result.removeValue(forKey: "_spikeSessionID")
        var sanitized = response
        sanitized["result"] = result
        return sanitized
    }

    private func buildJSONRPCResponse(
        for message: [String: Any],
        request: ParsedHTTPRequest
    ) async -> [String: Any]? {
        guard let method = message["method"] as? String else {
            return nil
        }

        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let response = handleInitialize(id: id, params: params, request: request)
            if let result = response["result"] as? [String: Any],
               let protocolVersion = result["protocolVersion"] as? String {
                await emit(.initializeAccepted(protocolVersion: protocolVersion))
            }
            return response
        case "notifications/initialized", "initialized":
            if let sessionID = sessionHeaderValue(in: request.headers),
               var session = sessions[sessionID] {
                session.initialized = true
                sessions[sessionID] = session
                await emit(.sessionInitialized)
            }
            return nil
        case "notifications/cancelled":
            await emit(.cancellationReceived)
            handleCancelledNotification(params: params, request: request)
            return nil
        case "tools/list":
            return handleToolsList(id: id, request: request)
        case "resources/list":
            return handleResourcesList(id: id, request: request)
        case "tools/call":
            return await handleToolsCall(id: id, params: params, request: request)
        case "ping":
            return [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": ["ok": true]
            ]
        default:
            return jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleInitialize(
        id: Any?,
        params: [String: Any],
        request: ParsedHTTPRequest
    ) -> [String: Any] {
        let requestedVersion = params["protocolVersion"] as? String ?? ""
        let negotiatedVersion = configuration.supportedProtocolVersions.contains(requestedVersion)
            ? requestedVersion
            : configuration.preferredProtocolVersion

        let sessionID = Self.makeSessionID()
        sessions[sessionID] = Session(
            id: sessionID,
            protocolVersion: negotiatedVersion,
            initialized: false,
            cancelledRequestIDs: []
        )

        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "protocolVersion": negotiatedVersion,
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["listChanged": false]
                ],
                "serverInfo": [
                    "name": "JoesProxy MCP Transport Spike",
                    "version": "0.1.0-ag0"
                ],
                "_spikeSessionID": sessionID
            ]
        ]
    }

    private func handleToolsList(id: Any?, request: ParsedHTTPRequest) -> [String: Any] {
        guard sessionIsReady(request: request) else {
            return jsonRPCError(id: id, code: -32001, message: "Session not initialized.")
        }

        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "tools": [
                    [
                        "name": "mcp_ping",
                        "description": "Returns a harmless structured pong for AG-0 transport validation.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "message": ["type": "string"]
                            ]
                        ]
                    ],
                    [
                        "name": "mcp_slow",
                        "description": "Sleeps briefly so cancellation can be exercised.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "delayMs": ["type": "integer"]
                            ]
                        ]
                    ],
                    [
                        "name": "mcp_notify",
                        "description": "Returns a bounded payload fixture; it does not emit a server notification.",
                        "inputSchema": ["type": "object"]
                    ]
                ]
            ]
        ]
    }

    private func handleResourcesList(id: Any?, request: ParsedHTTPRequest) -> [String: Any] {
        guard sessionIsReady(request: request) else {
            return jsonRPCError(id: id, code: -32001, message: "Session not initialized.")
        }

        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "resources": []
            ]
        ]
    }

    private func handleToolsCall(
        id: Any?,
        params: [String: Any],
        request: ParsedHTTPRequest
    ) async -> [String: Any] {
        guard sessionIsReady(request: request) else {
            return jsonRPCError(id: id, code: -32001, message: "Session not initialized.")
        }

        let toolName = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        if let requestKey = JSONValue(any: id ?? NSNull()),
           let sessionID = sessionHeaderValue(in: request.headers),
           sessions[sessionID]?.cancelledRequestIDs.contains(requestKey) == true {
            return jsonRPCError(id: id, code: -32800, message: "Request cancelled.")
        }

        switch toolName {
        case "mcp_ping":
            await emit(.toolCallStarted(name: "mcp_ping"))
            let message = arguments["message"] as? String ?? "pong"
            let payload: [String: Any] = [
                "ok": true,
                "message": message,
                "transport": "streamable-http",
                "protocolVersion": sessionProtocolVersion(request: request)
                    ?? configuration.preferredProtocolVersion
            ]
            return toolResult(id: id, payload: payload)
        case "mcp_slow":
            await emit(.toolCallStarted(name: "mcp_slow"))
            let delayMs = arguments["delayMs"] as? Int ?? 2_000
            guard (0 ... MCPNetworkConstants.maxSlowToolDelayMilliseconds).contains(delayMs) else {
                return jsonRPCError(
                    id: id,
                    code: -32602,
                    message: "delayMs must be between 0 and \(MCPNetworkConstants.maxSlowToolDelayMilliseconds)."
                )
            }
            do {
                try await runSlowTool(id: id, delayMs: delayMs, request: request)
                return toolResult(id: id, payload: ["completed": true, "delayMs": delayMs])
            } catch is CancellationError {
                return jsonRPCError(id: id, code: -32800, message: "Request cancelled.")
            } catch {
                return jsonRPCError(id: id, code: -32603, message: "Internal error.")
            }
        case "mcp_notify":
            await emit(.toolCallStarted(name: "mcp_notify"))
            return toolResult(
                id: id,
                payload: [
                    "notificationSent": false,
                    "progress": 1.0,
                    "message": "bounded payload path verified"
                ]
            )
        default:
            return jsonRPCError(id: id, code: -32602, message: "Unknown tool: \(toolName)")
        }
    }

    private func runSlowTool(id: Any?, delayMs: Int, request: ParsedHTTPRequest) async throws {
        guard let requestKey = JSONValue(any: id ?? NSNull()) else {
            try await Task.sleep(for: .milliseconds(delayMs))
            return
        }

        let sessionID = sessionHeaderValue(in: request.headers) ?? ""
        let taskKey = RequestKey(sessionID: sessionID, requestID: requestKey)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = Task {
                    let step = max(delayMs / 4, 50)
                    var elapsed = 0
                    while elapsed < delayMs {
                        if Task.isCancelled
                            || sessions[sessionID]?.cancelledRequestIDs.contains(requestKey) == true {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(step))
                        elapsed += step
                    }
                    continuation.resume()
                }
                slowToolTasks[taskKey] = task
            }
        } onCancel: {
            Task { await self.markCancelled(requestKey: requestKey, sessionID: sessionID) }
        }

        slowToolTasks.removeValue(forKey: taskKey)
    }

    private func markCancelled(requestKey: JSONValue, sessionID: String) {
        let taskKey = RequestKey(sessionID: sessionID, requestID: requestKey)
        slowToolTasks[taskKey]?.cancel()
        slowToolTasks.removeValue(forKey: taskKey)
        if var session = sessions[sessionID] {
            session.cancelledRequestIDs.insert(requestKey)
            sessions[sessionID] = session
        }
    }

    private func handleNotification(_ message: [String: Any], request: ParsedHTTPRequest) async {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "notifications/initialized", "initialized":
            if let sessionID = sessionHeaderValue(in: request.headers),
               var session = sessions[sessionID] {
                session.initialized = true
                sessions[sessionID] = session
                await emit(.sessionInitialized)
            }
        case "notifications/cancelled":
            await emit(.cancellationReceived)
            handleCancelledNotification(params: params, request: request)
        default:
            break
        }
    }

    private func handleCancelledNotification(params: [String: Any], request: ParsedHTTPRequest) {
        guard let requestID = JSONValue(any: params["requestId"] ?? NSNull()),
              let sessionID = sessionHeaderValue(in: request.headers),
              var session = sessions[sessionID] else {
            return
        }
        let taskKey = RequestKey(sessionID: sessionID, requestID: requestID)
        slowToolTasks[taskKey]?.cancel()
        slowToolTasks.removeValue(forKey: taskKey)
        session.cancelledRequestIDs.insert(requestID)
        sessions[sessionID] = session
    }

    private func toolResult(id: Any?, payload: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": jsonString(from: payload) ?? "{}"
                    ]
                ],
                "structuredContent": payload,
                "isError": false
            ]
        ]
    }

    private func sessionIsReady(request: ParsedHTTPRequest) -> Bool {
        guard let sessionID = sessionHeaderValue(in: request.headers),
              let session = sessions[sessionID] else {
            return false
        }
        return session.initialized
    }

    private func validateAuthorization(_ headers: [String: String]) -> RequestRejection? {
        guard let verifier = bearerVerifier else {
            return RequestRejection(
                reason: .authorizationUnavailable,
                response: unauthorizedResponse()
            )
        }

        guard let header = headers["authorization"] else {
            return RequestRejection(
                reason: .authorizationMissing,
                response: unauthorizedResponse()
            )
        }
        guard header.lowercased().hasPrefix("bearer ") else {
            return RequestRejection(
                reason: .authorizationInvalid,
                response: unauthorizedResponse()
            )
        }

        let token = String(header.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        guard Self.constantTimeEqual(Self.hashCredential(token), verifier) else {
            return RequestRejection(
                reason: .authorizationInvalid,
                response: unauthorizedResponse()
            )
        }
        return nil
    }

    private func unauthorizedResponse() -> Data {
        jsonErrorResponse(statusCode: 401, code: -32001, message: "Unauthorized.")
    }

    private func validateOrigin(_ headers: [String: String]) -> Data? {
        guard let origin = headers["origin"], !origin.isEmpty else {
            return nil
        }
        guard let components = URLComponents(string: origin),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              ["127.0.0.1", "localhost"].contains(host),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.port == Int(runningPort ?? configuration.port) else {
            return httpResponse(statusCode: 403, headers: [:], body: Data("Forbidden".utf8))
        }
        return nil
    }

    private func validateHost(_ headers: [String: String]) -> Data? {
        guard let hostHeader = headers["host"],
              let components = URLComponents(string: "http://\(hostHeader)"),
              let host = components.host?.lowercased(),
              ["127.0.0.1", "localhost"].contains(host),
              components.port == Int(runningPort ?? configuration.port) else {
            return httpResponse(statusCode: 403, headers: [:], body: Data("Forbidden".utf8))
        }
        return nil
    }

    private func validateSessionAndProtocol(
        message: [String: Any],
        request: ParsedHTTPRequest
    ) -> RequestRejection? {
        guard message["method"] as? String != "initialize" else {
            return nil
        }

        guard let sessionID = sessionHeaderValue(in: request.headers) else {
            return RequestRejection(
                reason: .sessionMissing,
                response: jsonErrorResponse(
                    statusCode: 400,
                    code: -32001,
                    message: "Missing MCP session ID."
                )
            )
        }
        guard let session = sessions[sessionID] else {
            return RequestRejection(
                reason: .sessionUnknown,
                response: jsonErrorResponse(
                    statusCode: 404,
                    code: -32001,
                    message: "Unknown MCP session."
                )
            )
        }

        let headerName = MCPNetworkConstants.protocolVersionHeader.lowercased()
        if let suppliedVersion = request.headers[headerName] {
            guard suppliedVersion == session.protocolVersion else {
                return RequestRejection(
                    reason: .protocolVersionMismatch,
                    response: jsonErrorResponse(
                        statusCode: 400,
                        code: -32003,
                        message: "MCP protocol version does not match the negotiated session."
                    )
                )
            }
        } else if session.protocolVersion != "2025-03-26" {
            return RequestRejection(
                reason: .protocolVersionMissing,
                response: jsonErrorResponse(
                    statusCode: 400,
                    code: -32003,
                    message: "Missing MCP protocol version header."
                )
            )
        }
        return nil
    }

    private func validateAcceptHeader(_ headers: [String: String]) -> Bool {
        guard let accept = headers["accept"]?.lowercased() else {
            return false
        }
        return accept.contains("application/json") && accept.contains("text/event-stream")
    }

    private func sessionHeaderValue(in headers: [String: String]) -> String? {
        headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
    }

    private func sessionHeaders(for request: ParsedHTTPRequest) -> [String: String] {
        if let sessionID = sessionHeaderValue(in: request.headers) {
            return sessionHeaders(sessionID: sessionID)
        }
        return [:]
    }

    private func sessionHeaders(sessionID: String) -> [String: String] {
        [MCPNetworkConstants.sessionIDHeader: sessionID]
    }

    private func sessionProtocolVersion(request: ParsedHTTPRequest) -> String? {
        guard let sessionID = sessionHeaderValue(in: request.headers) else {
            return nil
        }
        return sessions[sessionID]?.protocolVersion
    }

    // MARK: - HTTP helpers

    private func parseHTTPRequest(from data: Data) -> ParsedHTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data.prefix(upTo: headerEnd.lowerBound)
        guard let headerSection = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, data.count >= bodyStart + contentLength else {
            return nil
        }
        let body = data.subdata(in: bodyStart ..< bodyStart + contentLength)

        let rawPath = String(requestParts[1])
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        return ParsedHTTPRequest(
            method: String(requestParts[0]),
            path: path,
            headers: headers,
            body: body
        )
    }

    private func receiveRequestData(from connection: NWConnection) async -> RequestReceiveResult {
        var buffer = Data()
        while true {
            let chunk = await withCheckedContinuation { (continuation: CheckedContinuation<(Data, Bool), Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, _ in
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
            buffer.append(chunk.0)
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                if headerEnd.lowerBound > configuration.maxHeaderBytes {
                    return .tooLarge
                }
                guard let contentLength = Self.contentLength(in: buffer, headerEnd: headerEnd),
                      contentLength >= 0 else {
                    return .data(buffer)
                }
                if contentLength > configuration.maxRequestBodyBytes {
                    return .tooLarge
                }
                let expectedLength = headerEnd.upperBound + contentLength
                if buffer.count >= expectedLength {
                    return .data(Data(buffer.prefix(expectedLength)))
                }
            } else if buffer.count > configuration.maxHeaderBytes {
                return .tooLarge
            }
            if chunk.1 || chunk.0.isEmpty {
                return .data(buffer)
            }
        }
    }

    private static func contentLength(
        in buffer: Data,
        headerEnd: Range<Data.Index>
    ) -> Int? {
        let headerData = buffer.prefix(upTo: headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        for line in headerText.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
               let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                return length
            }
        }
        return 0
    }

    private func sendRaw(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(
                content: data,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in
                    continuation.resume()
                }
            )
        }
    }

    private func sendHTTPResponse(on connection: NWConnection, statusCode: Int, body: Data) async {
        let response = httpResponse(statusCode: statusCode, headers: [:], body: body)
        await sendRaw(response, on: connection)
    }

    private func httpResponse(statusCode: Int, headers: [String: String], body: Data) -> Data {
        var headerLines = [
            "HTTP/1.1 \(statusCode) \(HTTPStatusPhrase.phrase(for: statusCode))",
            "Content-Length: \(body.count)",
            "Connection: close"
        ]
        for (name, value) in headers {
            headerLines.append("\(name): \(value)")
        }
        headerLines.append("")
        headerLines.append("")
        var response = Data(headerLines.joined(separator: "\r\n").utf8)
        response.append(body)
        return response
    }

    private func jsonResponse(statusCode: Int, headers: [String: String], object: Any) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var merged = headers
        merged["Content-Type"] = "application/json"
        return httpResponse(statusCode: statusCode, headers: merged, body: body)
    }

    private func jsonErrorResponse(statusCode: Int, code: Int, message: String) -> Data {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        return jsonResponse(statusCode: statusCode, headers: [:], object: body)
    }

    private func jsonRPCError(id: Any?, code: Int, message: String, data: [String: Any]? = nil) -> [String: Any] {
        var error: [String: Any] = [
            "code": code,
            "message": message
        ]
        if let data {
            error["data"] = data
        }
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "error": error
        ]
    }

    private func parseJSONObject(from data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    private func jsonString(from object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func makeBearerCredential() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0 ... 255) }
        return Data(bytes).base64EncodedString()
    }

    private static func hashCredential(_ credential: String) -> Data {
        Data(SHA256.hash(data: Data(credential.utf8)))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func makeSessionID() -> String {
        UUID().uuidString
    }
}

private enum HTTPStatusPhrase {
    static func phrase(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        default: return "Error"
        }
    }
}
