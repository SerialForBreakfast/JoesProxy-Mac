import Darwin
import Foundation
import XCTest
@testable import JoesProxy

final class MCPTransportSpikeTests: XCTestCase {
    func testSpikeServerBindsLoopbackAndRunsFixtureToolRoundTrip() async throws {
        let server = MCPTransportSpikeServer()
        let bearer = try await server.start(port: 0)
        let status = await server.status()
        let port = try XCTUnwrap(status.port)
        defer { Task { await server.stop() } }

        let baseURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
        let initializeResponse = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: nil,
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": MCPNetworkConstants.preferredProtocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "JoesProxyTests", "version": "1.0"]
            ]
        )

        XCTAssertEqual(initializeResponse.statusCode, 200, String(describing: initializeResponse.json))
        let initializeResult = try XCTUnwrap(initializeResponse.json["result"] as? [String: Any])
        XCTAssertNil(initializeResult["_spikeSessionID"])
        let sessionID = try XCTUnwrap(Self.sessionID(from: initializeResponse))
        XCTAssertFalse(sessionID.isEmpty)

        let initializedResponse = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            method: "notifications/initialized",
            params: [:],
            includeID: false
        )
        XCTAssertEqual(initializedResponse.statusCode, 202, String(describing: initializedResponse.json))

        let toolsListResponse = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            id: 2,
            method: "tools/list",
            params: [:]
        )
        XCTAssertEqual(toolsListResponse.statusCode, 200, String(describing: toolsListResponse.json))
        let tools = try XCTUnwrap(toolsListResponse.json["result"] as? [String: Any])
        let toolEntries = try XCTUnwrap(tools["tools"] as? [[String: Any]])
        XCTAssertTrue(toolEntries.contains { $0["name"] as? String == "mcp_ping" })

        let pingResponse = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            id: 3,
            method: "tools/call",
            params: [
                "name": "mcp_ping",
                "arguments": ["message": "hello-spike\r\n\r\nbody-boundary"]
            ]
        )
        XCTAssertEqual(pingResponse.statusCode, 200, String(describing: pingResponse.json))
        let result = try XCTUnwrap(pingResponse.json["result"] as? [String: Any], String(describing: pingResponse.json))
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["message"] as? String, "hello-spike\r\n\r\nbody-boundary")
        XCTAssertEqual(structured["transport"] as? String, "streamable-http")
    }

    func testSpikeReportsOptionalEventStreamAsUnavailable() async throws {
        let diagnostics = MCPTransportSpikeDiagnosticRecorder()
        let server = MCPTransportSpikeServer { event in
            await diagnostics.record(event)
        }
        let bearer = try await server.start(port: 0)
        let status = await server.status()
        let port = try XCTUnwrap(status.port)
        defer { Task { await server.stop() } }

        let baseURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 405)
        let events = await diagnostics.snapshot()
        XCTAssertTrue(events.contains(.requestRejected(.eventStreamUnavailable)))
    }

    func testSpikeRejectsMissingAndInvalidBearerWithSameShape() async throws {
        let diagnostics = MCPTransportSpikeDiagnosticRecorder()
        let server = MCPTransportSpikeServer { event in
            await diagnostics.record(event)
        }
        let bearer = try await server.start(port: 0)
        let status = await server.status()
        let port = try XCTUnwrap(status.port)
        defer { Task { await server.stop() } }

        let baseURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
        let initResponse = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: nil,
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": MCPNetworkConstants.preferredProtocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "JoesProxyTests", "version": "1.0"]
            ]
        )
        let sessionID = try XCTUnwrap(Self.sessionID(from: initResponse))

        _ = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            method: "notifications/initialized",
            params: [:],
            includeID: false
        )

        let missing = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: nil,
            sessionID: sessionID,
            id: 2,
            method: "tools/list",
            params: [:]
        )
        XCTAssertEqual(missing.statusCode, 401)

        let invalid = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: "invalid-token",
            sessionID: sessionID,
            id: 3,
            method: "tools/list",
            params: [:]
        )
        XCTAssertEqual(invalid.statusCode, 401)
        XCTAssertEqual(
            (missing.json["error"] as? [String: Any])?["message"] as? String,
            (invalid.json["error"] as? [String: Any])?["message"] as? String
        )

        let events = await diagnostics.snapshot()
        XCTAssertTrue(events.contains(.listenerStarted(port: port)))
        XCTAssertTrue(events.contains(.initializeAccepted(
            protocolVersion: MCPNetworkConstants.preferredProtocolVersion
        )))
        XCTAssertTrue(events.contains(.sessionInitialized))
        XCTAssertTrue(events.contains(.requestRejected(.authorizationMissing)))
        XCTAssertTrue(events.contains(.requestRejected(.authorizationInvalid)))
        let renderedEvents = events.map(\.consoleDescription).joined(separator: "\n")
        XCTAssertFalse(renderedEvents.contains(bearer))
        XCTAssertFalse(renderedEvents.contains("invalid-token"))
        XCTAssertFalse(renderedEvents.contains(sessionID))
    }

    func testSpikeRequiresBearerForInitialize() async throws {
        let server = MCPTransportSpikeServer()
        _ = try await server.start(port: 0)
        let status = await server.status()
        let port = try XCTUnwrap(status.port)
        defer { Task { await server.stop() } }

        let baseURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
        let response = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: nil,
            sessionID: nil,
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": MCPNetworkConstants.preferredProtocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "JoesProxyTests", "version": "1.0"]
            ]
        )

        XCTAssertEqual(response.statusCode, 401)
    }

    func testSpikeNegotiatesPreferredVersionForNewerClient() async throws {
        let server = MCPTransportSpikeServer()
        let bearer = try await server.start(port: 0)
        let status = await server.status()
        let port = try XCTUnwrap(status.port)
        defer { Task { await server.stop() } }

        let baseURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
        let response = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: nil,
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": "2099-01-01",
                "capabilities": [:],
                "clientInfo": ["name": "JoesProxyTests", "version": "1.0"]
            ]
        )

        XCTAssertEqual(response.statusCode, 200)
        let result = try XCTUnwrap(response.json["result"] as? [String: Any])
        XCTAssertEqual(
            result["protocolVersion"] as? String,
            MCPNetworkConstants.preferredProtocolVersion
        )
    }

    func testSpikeRejectsOversizedRequestBody() async throws {
        let server = MCPTransportSpikeServer()
        let bearer = try await server.start(port: 0)
        let status = await server.status()
        let port = try XCTUnwrap(status.port)
        defer { Task { await server.stop() } }

        // Declare an oversized Content-Length without uploading 1 MiB — spike rejects on header parse.
        let statusCode = try Self.postRawHTTP(
            host: "127.0.0.1",
            port: port,
            headerLines: [
                "POST \(MCPNetworkConstants.endpointPath) HTTP/1.1",
                "Host: 127.0.0.1:\(port)",
                "Content-Type: application/json",
                "Accept: application/json, text/event-stream",
                "Authorization: Bearer \(bearer)",
                "Content-Length: \(MCPNetworkConstants.maxRequestBodyBytes + 1)"
            ],
            body: Data([0x41])
        )
        XCTAssertEqual(statusCode, 413)
    }

    func testSpikeRejectsUntrustedOriginAndMissingNegotiatedVersionHeader() async throws {
        let server = MCPTransportSpikeServer()
        let bearer = try await server.start(port: 0)
        let status = await server.status()
        let port = try XCTUnwrap(status.port)
        defer { Task { await server.stop() } }

        let baseURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
        let untrustedOrigin = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: nil,
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": MCPNetworkConstants.preferredProtocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "JoesProxyTests", "version": "1.0"]
            ],
            origin: "http://localhost.evil.example"
        )
        XCTAssertEqual(untrustedOrigin.statusCode, 403)

        let wrongPortOrigin = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: nil,
            id: 2,
            method: "initialize",
            params: [
                "protocolVersion": MCPNetworkConstants.preferredProtocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "JoesProxyTests", "version": "1.0"]
            ],
            origin: "http://localhost"
        )
        XCTAssertEqual(wrongPortOrigin.statusCode, 403)

        let initialize = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: nil,
            id: 3,
            method: "initialize",
            params: [
                "protocolVersion": MCPNetworkConstants.preferredProtocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "JoesProxyTests", "version": "1.0"]
            ],
            origin: "http://localhost:\(port)"
        )
        let sessionID = try XCTUnwrap(Self.sessionID(from: initialize))
        let missingVersion = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            method: "notifications/initialized",
            params: [:],
            includeID: false,
            includeProtocolVersion: false
        )
        XCTAssertEqual(missingVersion.statusCode, 400)
    }

    func testSpikeSlowToolHonoursCancellationNotification() async throws {
        let diagnostics = MCPTransportSpikeDiagnosticRecorder()
        let server = MCPTransportSpikeServer { event in
            await diagnostics.record(event)
        }
        let bearer = try await server.start(port: 0)
        let status = await server.status()
        let port = try XCTUnwrap(status.port)
        defer { Task { await server.stop() } }

        let baseURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
        let initResponse = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: nil,
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": MCPNetworkConstants.preferredProtocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "JoesProxyTests", "version": "1.0"]
            ]
        )
        let sessionID = try XCTUnwrap(Self.sessionID(from: initResponse))
        _ = try await Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            method: "notifications/initialized",
            params: [:],
            includeID: false
        )

        async let slowCall = Self.postJSONRPC(
            url: baseURL,
            bearerToken: bearer,
            sessionID: sessionID,
            id: 42,
            method: "tools/call",
            params: [
                "name": "mcp_slow",
                "arguments": ["delayMs": 5_000]
            ]
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
        let events = await diagnostics.snapshot()
        XCTAssertTrue(events.contains(.toolCallStarted(name: "mcp_slow")))
        XCTAssertTrue(events.contains(.cancellationReceived))
    }

    func testCancellationDoesNotCrossSessionBoundaryForSameRequestID() async throws {
        let server = MCPTransportSpikeServer()
        let bearer = try await server.start(port: 0)
        let status = await server.status()
        let port = try XCTUnwrap(status.port)
        defer { Task { await server.stop() } }

        let baseURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
        let firstSessionID = try await Self.initializeSession(
            url: baseURL,
            bearerToken: bearer,
            initializeRequestID: 1
        )
        let secondSessionID = try await Self.initializeSession(
            url: baseURL,
            bearerToken: bearer,
            initializeRequestID: 2
        )

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
        let secondResult = try XCTUnwrap(secondResponse.json["result"] as? [String: Any])
        XCTAssertEqual(secondResult["isError"] as? Bool, false)
    }

    func testSpikePortConflictSurfacesExplicitFailure() async throws {
        let serverA = MCPTransportSpikeServer()
        let serverB = MCPTransportSpikeServer()
        _ = try await serverA.start(port: 0)
        let status = await serverA.status()
        let port = try XCTUnwrap(status.port)

        do {
            _ = try await serverB.start(port: port)
            XCTFail("Expected bind failure for occupied port")
        } catch MCPTransportSpikeServer.ServerError.bindFailed {
            XCTAssertTrue(true)
        }

        await serverA.stop()
        await serverB.stop()
    }

    private static func sessionID(from response: HTTPJSONResponse) -> String? {
        response.headers[MCPNetworkConstants.sessionIDHeader.lowercased()]
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
            params: [
                "protocolVersion": MCPNetworkConstants.preferredProtocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "JoesProxyTests", "version": "1.0"]
            ]
        )
        let sessionID = try XCTUnwrap(sessionID(from: response))
        let initialized = try await postJSONRPC(
            url: url,
            bearerToken: bearerToken,
            sessionID: sessionID,
            method: "notifications/initialized",
            params: [:],
            includeID: false
        )
        XCTAssertEqual(initialized.statusCode, 202)
        return sessionID
    }

    private struct HTTPJSONResponse {
        let statusCode: Int
        let headers: [String: String]
        let json: [String: Any]
    }

    private static func postJSONRPC(
        url: URL,
        bearerToken: String?,
        sessionID: String?,
        id: Int? = nil,
        method: String,
        params: [String: Any],
        includeID: Bool = true,
        includeProtocolVersion: Bool = true,
        origin: String? = nil
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
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
            if includeProtocolVersion {
                request.setValue(
                    MCPNetworkConstants.preferredProtocolVersion,
                    forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader
                )
            }
        }
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
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

        let json: [String: Any]
        if data.isEmpty {
            json = [:]
        } else {
            json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        }

        return HTTPJSONResponse(statusCode: http.statusCode, headers: headers, json: json)
    }

    /// Sends a minimal raw HTTP/1.1 request and returns the response status code.
    private static func postRawHTTP(
        host: String,
        port: UInt16,
        headerLines: [String],
        body: Data
    ) throws -> Int {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw MCPTransportSpikeTestError.portUnavailable
        }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(host))

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw MCPTransportSpikeTestError.portUnavailable
        }

        var requestData = Data()
        requestData.append(Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
        requestData.append(body)
        _ = requestData.withUnsafeBytes { buffer in
            send(socketDescriptor, buffer.baseAddress, buffer.count, 0)
        }

        var responseBuffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = recv(socketDescriptor, &chunk, chunk.count, 0)
            if received <= 0 { break }
            responseBuffer.append(contentsOf: chunk.prefix(received))
            if responseBuffer.contains(Data("\r\n\r\n".utf8)) { break }
        }
        guard let statusLine = String(data: responseBuffer, encoding: .utf8)?
            .split(separator: "\r\n", maxSplits: 1).first else {
            throw MCPTransportSpikeTestError.portUnavailable
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw MCPTransportSpikeTestError.portUnavailable
        }
        return code
    }


}

private enum MCPTransportSpikeTestError: Error {
    case portUnavailable
}

private actor MCPTransportSpikeDiagnosticRecorder {
    private var recordedEvents: [MCPTransportSpikeDiagnosticEvent] = []

    func record(_ event: MCPTransportSpikeDiagnosticEvent) {
        recordedEvents.append(event)
    }

    func snapshot() -> [MCPTransportSpikeDiagnosticEvent] {
        recordedEvents
    }
}
