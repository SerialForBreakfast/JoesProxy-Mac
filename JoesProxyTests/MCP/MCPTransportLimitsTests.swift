import Foundation
import NIO
import NIOPosix
import XCTest
@testable import JoesProxy

@MainActor
final class MCPTransportLimitsTests: XCTestCase {
    func testRejectsOversizedRequestBodyAtNIOBoundary() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-limits.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-limits.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-limits.json"))
        auditStore.load()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore(),
            boundPort: 0
        )
        let enrollment = try clientRegistry.enroll(displayName: "Limits")
        let transport = MCPNIOHTTPTransport(protocolService: protocolService)
        try await transport.start(port: 0)
        let port = try XCTUnwrap(transport.boundPort)

        let oversizedBody = Data(repeating: 0x41, count: MCPNetworkConstants.maxRequestBodyBytes + 1)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!)
        request.httpMethod = "POST"
        request.httpBody = oversizedBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(enrollment.plaintextCredential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let (_, response) = try await URLSession.shared.data(for: request)
        await transport.shutdown()

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)
    }

    func testNegativeContentLengthIsRejectedWithoutCrashingTransport() async throws {
        let protocolService = try makeProtocolService(port: 0)
        let transport = MCPNIOHTTPTransport(protocolService: protocolService)
        try await transport.start(port: 0)
        let port = try XCTUnwrap(transport.boundPort)
        let rawResponse = try await Self.sendRawRequest(
            """
            POST /mcp HTTP/1.1\r
            Host: 127.0.0.1:\(port)\r
            Content-Length: -1\r
            \r
            """,
            port: port
        )
        await transport.shutdown()

        XCTAssertTrue(rawResponse.hasPrefix("HTTP/1.1 400"))
    }

    func testRejectsExcessiveJSONNesting() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-depth.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-depth.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-depth.json"))
        auditStore.load()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore()
        )
        let enrollment = try clientRegistry.enroll(displayName: "Depth")
        let initResponse = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(enrollment.plaintextCredential)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                "accept": "application/json, text/event-stream"
            ],
            body: Data("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
            """.utf8)
        )
        let sessionID = initResponse.headerValue(named: MCPNetworkConstants.sessionIDHeader)
        XCTAssertNotNil(sessionID)

        var nested = "null"
        for _ in 0..<(MCPServerLimits.maxJSONDepth + 2) {
            nested = "{\"a\":\(nested)}"
        }
        let deepBody = Data("""
        {"jsonrpc":"2.0","id":2,"method":"ping","params":\(nested)}
        """.utf8)
        let response = await protocolService.handleHTTPRequest(
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
            body: deepBody
        )
        let text = response.bodyText
        XCTAssertTrue(text.contains("JSON nesting too deep") || text.contains("Invalid Request"))
    }

    func testUnknownResourceReturnsMalformedRequestNotPolicyDenied() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-uri.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-uri.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-uri.json"))
        auditStore.load()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore()
        )
        let enrollment = try clientRegistry.enroll(displayName: "URI")
        let sessionID = try await Self.initializeSession(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential
        )
        let readBody = Data("""
        {"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"joesproxy://unknown/resource"}}
        """.utf8)
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: Self.authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID),
            body: readBody
        )
        let text = response.bodyText
        XCTAssertTrue(text.contains("Unknown resource"))
        XCTAssertFalse(text.contains("Policy denied"))
    }

    func testUnknownResourceStillProducesAuditRow() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-audit-uri.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-audit-uri.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-audit-uri.json"))
        auditStore.load()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore()
        )
        let enrollment = try clientRegistry.enroll(displayName: "AuditURI")
        let sessionID = try await Self.initializeSession(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential
        )
        let beforeCount = auditStore.recentEvents.count
        let readBody = Data("""
        {"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"joesproxy://unknown/resource"}}
        """.utf8)
        _ = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: Self.authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionID),
            body: readBody
        )
        XCTAssertGreaterThan(auditStore.recentEvents.count, beforeCount)
        XCTAssertTrue(auditStore.recentEvents.contains { $0.kind == .resourceRead && $0.reasonCode == "joesproxy://unknown/resource" })
    }

    func testMissingSessionIs400AndConcurrentSameCredentialSessionsAreIsolated() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-session-recovery.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-session-recovery.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-session-recovery.json"))
        auditStore.load()
        let service = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore()
        )
        let enrollment = try clientRegistry.enroll(displayName: "Concurrent")
        let missing = await service.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(enrollment.plaintextCredential)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                "accept": "application/json, text/event-stream"
            ],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"resources/list","params":{}}"#.utf8)
        )
        XCTAssertEqual(missing.status, 400)

        var sessionIDs: [String] = []
        for _ in 0..<5 {
            sessionIDs.append(try await Self.initializeSession(
                protocolService: service,
                bearer: enrollment.plaintextCredential
            ))
        }
        XCTAssertEqual(service.activeSessionCount(forClientID: enrollment.client.id), 4)
        let evicted = await service.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: Self.authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionIDs[0]),
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"resources/list","params":{}}"#.utf8)
        )
        XCTAssertEqual(evicted.status, 404)
        let evictedObject = try evicted.jsonBodyObject()
        let evictedError = try XCTUnwrap(evictedObject["error"] as? [String: Any])
        let evictedData = try XCTUnwrap(evictedError["data"] as? [String: Any])
        XCTAssertEqual(evictedData["sessionState"] as? String, "evicted_capacity")
        XCTAssertEqual(evictedData["recovery"] as? String, "reinitialize")

        let otherEnrollment = try clientRegistry.enroll(displayName: "Other")
        let crossClient = await service.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: Self.authenticatedHeaders(
                bearer: otherEnrollment.plaintextCredential,
                sessionID: sessionIDs[0]
            ),
            body: Data(#"{"jsonrpc":"2.0","id":4,"method":"resources/list","params":{}}"#.utf8)
        )
        let crossClientObject = try crossClient.jsonBodyObject()
        let crossClientError = try XCTUnwrap(crossClientObject["error"] as? [String: Any])
        XCTAssertNil(crossClientError["data"])

        let newest = await service.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: Self.authenticatedHeaders(bearer: enrollment.plaintextCredential, sessionID: sessionIDs[4]),
            body: Data(#"{"jsonrpc":"2.0","id":3,"method":"resources/list","params":{}}"#.utf8)
        )
        XCTAssertEqual(newest.status, 200)
    }

    #if DEBUG
    func testRejectsWhenClientInFlightLimitExceeded() async throws {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-inflight.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-inflight.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-inflight.json"))
        auditStore.load()
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore(),
            boundPort: 0,
            exposeDebugTools: true
        )
        let transport = MCPNIOHTTPTransport(protocolService: protocolService)
        try await transport.start(port: 0)
        let port = try XCTUnwrap(transport.boundPort)
        protocolService.rebindLoopbackPort(port)
        let enrollment = try clientRegistry.enroll(displayName: "Inflight")
        let baseURL = URL(string: "http://127.0.0.1:\(port)\(MCPNetworkConstants.endpointPath)")!
        let sessionID = try await Self.initializeProductionSession(
            url: baseURL,
            bearer: enrollment.plaintextCredential,
            port: port
        )

        let limit = MCPServerLimits.concurrentInFlightRequestsPerClient
        async let calls: [Int] = withTaskGroup(of: Int.self) { group in
            for index in 0..<(limit + 1) {
                group.addTask {
                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.httpBody = try? JSONSerialization.data(withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": index,
                        "method": "tools/call",
                        "params": [
                            "name": "mcp_slow",
                            "arguments": ["delayMs": 1_000]
                        ]
                    ])
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(enrollment.plaintextCredential)", forHTTPHeaderField: "Authorization")
                    request.setValue(sessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
                    request.setValue(
                        MCPNetworkConstants.preferredProtocolVersion,
                        forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader
                    )
                    request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
                    let (_, response) = (try? await URLSession.shared.data(for: request)) ?? (Data(), nil)
                    return (response as? HTTPURLResponse)?.statusCode ?? 0
                }
            }
            var statuses: [Int] = []
            for await status in group {
                statuses.append(status)
            }
            return statuses
        }
        let statuses = try await calls
        await transport.shutdown()
        XCTAssertTrue(statuses.contains(429))
    }
    #endif

    func testRateLimiterDefaultsTrackServerLimits() {
        let limiter = MCPRateLimiter()
        XCTAssertEqual(limiter.activeConfiguration.globalRequestsPerMinute, MCPServerLimits.globalRequestRatePerMinute)
        XCTAssertEqual(limiter.activeConfiguration.clientRequestsPerMinute, MCPServerLimits.requestRatePerClientPerMinute)
        XCTAssertEqual(
            limiter.activeConfiguration.controlPlaneClientRequestsPerMinute,
            MCPServerLimits.controlPlaneRequestRatePerClientPerMinute
        )
    }

    func testControlPlanePollingDoesNotConsumeSubstantiveRateBudget() {
        var configuration = MCPRateLimiter.Configuration()
        configuration.globalRequestsPerMinute = 1
        configuration.clientRequestsPerMinute = 1
        configuration.controlPlaneGlobalRequestsPerMinute = 3
        configuration.controlPlaneClientRequestsPerMinute = 3
        var limiter = MCPRateLimiter(configuration: configuration)
        let now = Date(timeIntervalSince1970: 1_000)

        for _ in 0..<3 {
            XCTAssertTrue(limiter.allowGlobalRequest(rateClass: .controlPlane, at: now))
            XCTAssertTrue(limiter.allowFingerprintRequest("fingerprint", rateClass: .controlPlane, at: now))
            XCTAssertTrue(limiter.allowClientRequest(clientID: "client", rateClass: .controlPlane, at: now))
        }
        XCTAssertFalse(limiter.allowClientRequest(clientID: "client", rateClass: .controlPlane, at: now))
        XCTAssertTrue(limiter.allowGlobalRequest(at: now))
        XCTAssertTrue(limiter.allowFingerprintRequest("fingerprint", at: now))
        XCTAssertTrue(limiter.allowClientRequest(clientID: "client", at: now))
        XCTAssertFalse(limiter.allowClientRequest(clientID: "client", at: now))
    }

    func testApprovalAndRuntimeStatusAreControlPlaneButMutationIsSubstantive() throws {
        func body(tool: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": tool, "arguments": [:]]
            ])
        }

        XCTAssertEqual(
            MCPRequestRateClassifier.rateClass(httpMethod: "POST", body: try body(tool: "approval_status")),
            .controlPlane
        )
        XCTAssertEqual(
            MCPRequestRateClassifier.rateClass(httpMethod: "POST", body: try body(tool: "runtime_status")),
            .controlPlane
        )
        XCTAssertEqual(
            MCPRequestRateClassifier.rateClass(httpMethod: "POST", body: try body(tool: "apply_enable_rule")),
            .substantive
        )
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }

    private func makeProtocolService(port: UInt16) throws -> MCPProtocolService {
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-\(port).json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-\(port).json"),
            credentialStore: MCPInMemoryCredentialStore()
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-\(port).json"))
        auditStore.load()
        return MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: MCPSessionSnapshotService(sessionStore: InMemorySessionStore()),
            approvalStore: MCPApprovalStore(),
            boundPort: port
        )
    }

    private static func initializeSession(protocolService: MCPProtocolService, bearer: String) async throws -> String {
        let initResponse = await protocolService.handleHTTPRequest(
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
        let sessionID = try XCTUnwrap(initResponse.headerValue(named: MCPNetworkConstants.sessionIDHeader))
        _ = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        )
        return sessionID
    }

    private static func initializeProductionSession(
        url: URL,
        bearer: String,
        port: UInt16
    ) async throws -> String {
        var initRequest = URLRequest(url: url)
        initRequest.httpMethod = "POST"
        initRequest.httpBody = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
        """.utf8)
        initRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        initRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        initRequest.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        let (initData, initResponse) = try await URLSession.shared.data(for: initRequest)
        _ = initData
        let http = try XCTUnwrap(initResponse as? HTTPURLResponse)
        var sessionID: String?
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, key.caseInsensitiveCompare(MCPNetworkConstants.sessionIDHeader) == .orderedSame,
               let value = value as? String {
                sessionID = value
            }
        }
        let resolvedSessionID = try XCTUnwrap(sessionID)
        var initializedRequest = URLRequest(url: url)
        initializedRequest.httpMethod = "POST"
        initializedRequest.httpBody = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        initializedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initializedRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        initializedRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        initializedRequest.setValue(resolvedSessionID, forHTTPHeaderField: MCPNetworkConstants.sessionIDHeader)
        initializedRequest.setValue("2025-11-25", forHTTPHeaderField: MCPNetworkConstants.protocolVersionHeader)
        initializedRequest.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        _ = try await URLSession.shared.data(for: initializedRequest)
        return resolvedSessionID
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

    private static func sendRawRequest(_ request: String, port: UInt16) async throws -> String {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let promise = group.next().makePromise(of: String.self)
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(MCPRawResponseCollector(promise: promise))
            }
            .connect(host: "127.0.0.1", port: Int(port))
            .get()
        var buffer = channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try await channel.writeAndFlush(buffer).get()
        let response = try await promise.futureResult.get()
        try await group.shutdownGracefully()
        return response
    }
}

private final class MCPRawResponseCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<String>
    private var bytes: [UInt8] = []
    private var completed = false

    init(promise: EventLoopPromise<String>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let incoming = buffer.readBytes(length: buffer.readableBytes) {
            bytes.append(contentsOf: incoming)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        promise.succeed(String(decoding: bytes, as: UTF8.self))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        completed = true
        promise.fail(error)
        context.close(promise: nil)
    }
}
