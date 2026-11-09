import Foundation
import XCTest
@testable import JoesProxy

#if DEBUG
@MainActor
final class MCPSSETransportIntegrationTests: XCTestCase {
    func testSSECaptureNotificationDeliveredAfterAppend() async throws {
        let fixture = try await startSubscriptionTransport()

        let subscription = try await postJSONRPC(
            url: fixture.baseURL,
            bearerToken: fixture.bearer,
            sessionID: fixture.sessionID,
            id: 10,
            method: "resources/subscribe",
            params: ["uri": "joesproxy://capture/summary"]
        )
        XCTAssertEqual(subscription.statusCode, 200)
        XCTAssertNil(subscription.json["error"], "Subscription rejected: \(subscription.json)")
        XCTAssertEqual(fixture.notificationHub.subscribedSessionCount, 1)

        let publicationKey = MCPLogicalSessionKey(clientID: "publication-probe", mcpSessionID: "publication-probe")
        let publicationWriter = MCPMockSSEWriter()
        try fixture.notificationHub.subscribe(key: publicationKey, uri: "joesproxy://capture/summary")
        fixture.notificationHub.registerWriter(key: publicationKey, writer: publicationWriter)

        let collector = SSEFrameCollector()
        let listenTask = Task {
            try await collector.collect(from: fixture.baseURL, bearer: fixture.bearer, sessionID: fixture.sessionID)
        }
        defer { listenTask.cancel() }
        try await waitUntil(timeoutSeconds: 5) {
            fixture.notificationHub.liveListenStreamCount == 2
        }

        let appended = makeSession(path: "/notify.m3u8")
        fixture.sessionStore.append(appended)

        let frame: [String: Any]
        do {
            frame = try await collector.waitForNotification(timeoutSeconds: 5)
        } catch {
            XCTFail("SSE delivery failed: published=\(publicationWriter.frames.count), decodedLineBytes=\(collector.decodedLineByteCount), comments=\(collector.comments.count), subscriptions=\(fixture.notificationHub.subscribedSessionCount)")
            throw error
        }
        XCTAssertFalse(publicationWriter.frames.isEmpty)
        listenTask.cancel()
        XCTAssertEqual(frame["method"] as? String, "notifications/resources/updated")
        if let params = frame["params"] as? [String: Any] {
            XCTAssertEqual(params["uri"] as? String, "joesproxy://capture/summary")
        } else {
            XCTFail("Expected resource updated params")
        }
    }

    func testSSEHeartbeatKeepsConnectionAlivePastIdleTimeout() async throws {
        let fixture = try await startSubscriptionTransport(idleTimeout: 2, heartbeatInterval: 1)

        let collector = SSEFrameCollector()
        let listenTask = Task {
            try await collector.collect(from: fixture.baseURL, bearer: fixture.bearer, sessionID: fixture.sessionID)
        }
        defer { listenTask.cancel() }
        try await waitUntil(timeoutSeconds: 5) { fixture.notificationHub.liveListenStreamCount == 1 }
        try await Task.sleep(for: .seconds(3))
        listenTask.cancel()
        XCTAssertGreaterThanOrEqual(collector.comments.count, 1)
        XCTAssertFalse(collector.closedByServer)
    }

    func testReconnectClosesPriorListenStream() async throws {
        let fixture = try await startSubscriptionTransport()

        let firstCollector = SSEFrameCollector()
        let firstTask = Task {
            try await firstCollector.collect(from: fixture.baseURL, bearer: fixture.bearer, sessionID: fixture.sessionID)
        }
        defer { firstTask.cancel() }
        try await waitUntil(timeoutSeconds: 5) { fixture.notificationHub.liveListenStreamCount == 1 }

        let secondCollector = SSEFrameCollector()
        let secondTask = Task {
            try await secondCollector.collect(from: fixture.baseURL, bearer: fixture.bearer, sessionID: fixture.sessionID)
        }
        defer { secondTask.cancel() }
        try await waitUntil(timeoutSeconds: 2) {
            firstCollector.closedByServer
        }

        firstTask.cancel()
        secondTask.cancel()
        XCTAssertTrue(firstCollector.closedByServer)
        XCTAssertFalse(secondCollector.closedByServer)
    }

    func testStopClosesActiveSSEWriter() async throws {
        let fixture = try await startSubscriptionTransport()
        let collector = SSEFrameCollector()
        let listenTask = Task {
            try await collector.collect(from: fixture.baseURL, bearer: fixture.bearer, sessionID: fixture.sessionID)
        }
        defer { listenTask.cancel() }
        try await waitUntil(timeoutSeconds: 5) {
            fixture.notificationHub.liveListenStreamCount == 1
        }
        await fixture.notificationHub.closeAllWriters()
        await fixture.transport.shutdown()
        try await waitUntil(timeoutSeconds: 2) {
            collector.closedByServer
        }
        listenTask.cancel()
        XCTAssertTrue(collector.closedByServer)
        XCTAssertEqual(fixture.notificationHub.liveListenStreamCount, 0)
    }

    func testGetListenRejectsMissingAuthorization() async throws {
        let fixture = try await startSubscriptionTransport()

        var request = URLRequest(url: fixture.baseURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(fixture.sessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)
    }

    // MARK: - Stack

    private struct SubscriptionTransportFixture {
        let transport: MCPNIOHTTPTransport
        let baseURL: URL
        let bearer: String
        let sessionID: String
        let sessionStore: InMemorySessionStore
        let notificationHub: MCPNotificationHub
    }

    private func startSubscriptionTransport(
        idleTimeout: TimeInterval = 30,
        heartbeatInterval: TimeInterval = MCPServerLimits.sseHeartbeatInterval
    ) async throws -> SubscriptionTransportFixture {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-sse.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-sse.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-sse.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let sessionStore = InMemorySessionStore()
        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let notificationHub = MCPNotificationHub(
            sessionStore: sessionStore,
            policyStore: policyStore,
            auditStore: auditStore,
            snapshotService: snapshotService,
            heartbeatInterval: heartbeatInterval
        )
        let mediaService = MCPMediaInspectionService(sessionStore: sessionStore, snapshotService: snapshotService)
        let operationCoordinator = MCPOperationCoordinator(
            sessionStore: sessionStore,
            mediaService: mediaService,
            snapshotService: snapshotService,
            policyStore: policyStore,
            auditStore: auditStore,
            notificationHub: notificationHub
        )
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: snapshotService,
            approvalStore: approvalStore,
            mediaInspectionService: mediaService,
            operationCoordinator: operationCoordinator,
            notificationHub: notificationHub,
            boundPort: 0
        )
        let transport = MCPNIOHTTPTransport(
            protocolService: protocolService,
            idleTimeout: idleTimeout
        )
        try await transport.start(port: 0)
        // Finish writer closure before event-loop shutdown and before the next test starts.
        addTeardownBlock { @MainActor in
            await notificationHub.closeAllWriters()
            if transport.boundPort != nil {
                await transport.shutdown()
            }
        }
        let port = try XCTUnwrap(transport.boundPort)
        protocolService.rebindLoopbackPort(port)
        let enrollment = try clientRegistry.enroll(displayName: "SSE")
        let baseURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
        let sessionID = try await initializeSession(
            url: baseURL,
            bearerToken: enrollment.plaintextCredential
        )
        return SubscriptionTransportFixture(
            transport: transport,
            baseURL: baseURL,
            bearer: enrollment.plaintextCredential,
            sessionID: sessionID,
            sessionStore: sessionStore,
            notificationHub: notificationHub
        )
    }

    private func makeSession(path: String) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "media.example.com",
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
                bodyData: Data("#EXTM3U\n".utf8),
                bodySize: 8
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func waitUntil(timeoutSeconds: TimeInterval, description: String = "SSE readiness or closure", condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw MCPStructuredError(code: .timeout, message: "Timed out waiting for \(description).")
    }

    private func initializeSession(url: URL, bearerToken: String) async throws -> String {
        let response = try await postJSONRPC(
            url: url,
            bearerToken: bearerToken,
            sessionID: nil,
            id: 1,
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

    private struct HTTPJSONResponse {
        let statusCode: Int
        let headers: [String: String]
        let json: [String: Any]
    }

    private func postJSONRPC(
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

@MainActor
private final class SSEFrameCollector {
    private(set) var decodedLineByteCount = 0
    private(set) var comments: [String] = []
    private(set) var closedByServer = false
    private var notification: [String: Any]?
    private var notificationContinuation: CheckedContinuation<[String: Any], Error>?
    private var readError: Error?

    func collect(from url: URL, bearer: String, sessionID: String) async throws {
        do {
            try await readStream(from: url, bearer: bearer, sessionID: sessionID)
        } catch {
            readError = error
            if let continuation = notificationContinuation {
                notificationContinuation = nil
                continuation.resume(throwing: error)
            }
            throw error
        }
    }

    private func readStream(from url: URL, bearer: String, sessionID: String) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        request.setValue(
            MCPNetworkConstants.preferredProtocolVersion,
            forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader
        )
        if let port = url.port {
            request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        }

        let (asyncBytes, response) = try await session.bytes(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        // Decode off the per-byte MainActor path; one actor delivery per line avoids
        // making network timing depend on hundreds of test-executor resumptions.
        for try await line in asyncBytes.lines {
            decodedLineByteCount += line.utf8.count
            process(line: line)
            if let notification, let notificationContinuation {
                self.notificationContinuation = nil
                notificationContinuation.resume(returning: notification)
                return
            }
        }
        closedByServer = true
        if let notificationContinuation {
            self.notificationContinuation = nil
            notificationContinuation.resume(throwing: MCPStructuredError(code: .internalFailure, message: "Stream closed before notification."))
        }
    }

    func waitForNotification(timeoutSeconds: TimeInterval) async throws -> [String: Any] {
        if let readError { throw readError }
        if closedByServer {
            throw MCPStructuredError(code: .internalFailure, message: "Stream already closed before notification.")
        }
        if let notification {
            return notification
        }
        return try await withCheckedThrowingContinuation { continuation in
            notificationContinuation = continuation
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if notificationContinuation != nil {
                    notificationContinuation?.resume(throwing: MCPStructuredError(code: .timeout, message: "Timed out waiting for SSE notification."))
                    notificationContinuation = nil
                }
            }
        }
    }

    private func process(line: String) {
        if line.hasPrefix(":") {
            comments.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
        }
        guard line.hasPrefix("data: ") else { return }
        let jsonText = String(line.dropFirst("data: ".count))
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if object["method"] as? String == "notifications/resources/updated" {
            notification = object
        }
    }
}
#endif
