import Foundation
import Testing
@testable import JoesProxySDK

@Suite("ProxySDK Connection", .serialized)
@MainActor
struct ProxySDKConnectionTests {
    @Test func manualConnectSendsHandshakeAndMovesToConnected() async throws {
        let transport = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)])
        let sdk = ProxySDK(
            transportFactory: { transport },
            discovery: MockDiscovery()
        )

        await sdk.connect(host: "macbook.local", port: 9091, token: "abc123")

        #expect(sdk.connectionState == ProxySDKConnectionState.connected(host: "macbook.local", port: 9091, clockOffsetMs: 42))
        #expect(sdk.clockOffsetMs == 42)

        let sentMessages = await transport.sentMessages
        #expect(sentMessages.count == 1)

        let envelope = try SDKEventJSONCodec.makeDecoder().decode(
            SDKMessageEnvelope<PairingHandshake>.self,
            from: Data(sentMessages[0].utf8)
        )
        #expect(envelope.type == SDKMessageType.handshake)
        #expect(envelope.payload.token == "abc123")
        #expect(envelope.payload.supportedSchemaVersions == [SDKSchema.version])
    }

    @Test func rejectedHandshakeMovesToRejectedState() async throws {
        let transport = MockWebSocketTransport(
            incoming: [try Self.handshakeAck(accepted: false, rejectReason: .invalidToken)]
        )
        let sdk = ProxySDK(
            transportFactory: { transport },
            discovery: MockDiscovery()
        )

        await sdk.connect(host: "macbook.local", port: 9091, token: "wrong")

        #expect(sdk.connectionState == ProxySDKConnectionState.rejected(reason: SDKHandshakeRejectReason.invalidToken, compatibility: nil))
        #expect(await transport.isClosed)
    }

    @Test func schemaRejectedHandshakeCarriesCompatibilityGuidance() async throws {
        let compatibility = SDKCompatibilityInfo(
            serverAppVersion: "1.2.3",
            minimumSupportedSchemaVersion: 2,
            latestSupportedSchemaVersion: 2,
            compatibilityResolution: .updateSDK,
            message: "Update the JoesProxySDK package."
        )
        let transport = MockWebSocketTransport(
            incoming: [
                try Self.handshakeAck(
                    accepted: false,
                    rejectReason: .schemaVersionUnsupported,
                    compatibility: compatibility
                )
            ]
        )
        let sdk = ProxySDK(
            transportFactory: { transport },
            discovery: MockDiscovery()
        )

        await sdk.connect(host: "macbook.local", port: 9091, token: "old-sdk")

        #expect(sdk.connectionState == ProxySDKConnectionState.rejected(
            reason: SDKHandshakeRejectReason.schemaVersionUnsupported,
            compatibility: compatibility
        ))
        #expect(await transport.isClosed)
    }

    @Test func discoverAndConnectUsesResolvedBonjourService() async throws {
        let transport = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)])
        let discovery = MockDiscovery(
            service: DiscoveredJoesProxyService(
                name: "JoesProxy",
                host: "studio.local",
                port: 9090,
                sdkPort: 9091,
                profilePath: "/profile",
                version: 1
            )
        )
        let sdk = ProxySDK(
            transportFactory: { transport },
            discovery: discovery
        )

        await sdk.discoverAndConnect(token: "abc123", timeout: 0.1)

        #expect(sdk.connectionState == ProxySDKConnectionState.connected(host: "studio.local", port: 9091, clockOffsetMs: 42))
    }

    @Test func incomingNetworkEventDispatchesToHandlers() async throws {
        let transport = MockWebSocketTransport(
            incoming: [
                try Self.handshakeAck(accepted: true),
                try Self.networkEventMessage()
            ]
        )
        let sdk = ProxySDK(
            transportFactory: { transport },
            discovery: MockDiscovery()
        )
        let recorder = NetworkEventRecorder()
        sdk.onNetworkEvent { event in
            Task { await recorder.append(event) }
        }

        await sdk.connect(host: "macbook.local", port: 9091, token: "abc123")
        try await Task.sleep(nanoseconds: 50_000_000)

        let events = await recorder.events
        #expect(events.count == 1)
        #expect(events.first?.url.absoluteString == "https://example.com/api")
    }

    @Test func bonjourTXTRecordParsesSDKFields() {
        let data = NetService.data(fromTXTRecord: [
            "version": Data("1".utf8),
            "sdkPort": Data("9091".utf8),
            "profilePath": Data("/profile".utf8)
        ])

        let record = BonjourTXTRecord(data: data)

        #expect(record.version == 1)
        #expect(record.sdkPort == 9091)
        #expect(record.profilePath == "/profile")
    }

    @Test func reconnectUsesBackoffAndLastManualConnection() async throws {
        let first = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)], throwsWhenEmpty: true)
        let second = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)])
        let factory = MockTransportFactory(transports: [first, second])
        let sdk = ProxySDK(
            transportFactory: { factory.next() },
            discovery: MockDiscovery(),
            reconnectDelaysNanoseconds: [0],
            sleep: { _ in }
        )

        await sdk.connect(host: "macbook.local", port: 9091, token: "abc123")
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(factory.createdCount == 2)
        #expect(sdk.connectionState == ProxySDKConnectionState.connected(host: "macbook.local", port: 9091, clockOffsetMs: 42))
        #expect(await second.sentMessages.count == 1)
        await sdk.disconnect()
    }

    @Test func reconnectReplaysLastFiveBufferedOutgoingMessages() async throws {
        let first = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)])
        let second = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)])
        let factory = MockTransportFactory(transports: [first, second])
        let sdk = ProxySDK(
            transportFactory: { factory.next() },
            discovery: MockDiscovery(),
            reconnectDelaysNanoseconds: [0],
            sleep: { _ in }
        )

        await sdk.connect(host: "macbook.local", port: 9091, token: "abc123")
        for index in 0..<6 {
            await sdk.sendAnnotationEvent(Self.annotation(label: "event-\(index)"))
        }
        await first.failWhenEmpty()
        try await Task.sleep(nanoseconds: 50_000_000)

        let sentMessages = await second.sentMessages
        #expect(sentMessages.count == 6)

        let replayedAnnotations = try sentMessages.dropFirst().map { message in
            try SDKEventJSONCodec.makeDecoder().decode(
                SDKMessageEnvelope<AnnotationEvent>.self,
                from: Data(message.utf8)
            ).payload.label
        }
        #expect(replayedAnnotations == ["event-1", "event-2", "event-3", "event-4", "event-5"])
        await sdk.disconnect()
    }

    @Test func featureAnnotationSendsInstantEventWithMetadata() async throws {
        let transport = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)])
        let sdk = ProxySDK(
            transportFactory: { transport },
            discovery: MockDiscovery()
        )

        await sdk.connect(host: "macbook.local", port: 9091, token: "abc123")
        await sdk.annotate(feature: "Paywall", metadata: ["variant": "A"])

        let annotations = try await Self.sentAnnotations(from: transport)
        #expect(annotations.count == 1)
        #expect(annotations[0].label == "Paywall")
        #expect(annotations[0].kind == .feature)
        #expect(annotations[0].lifecycle == .instant)
        #expect(annotations[0].metadata["variant"] == "A")
        await sdk.disconnect()
    }

    @Test func screenAnnotationClosesPreviousScreenWindow() async throws {
        let transport = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)])
        let sdk = ProxySDK(
            transportFactory: { transport },
            discovery: MockDiscovery()
        )

        await sdk.connect(host: "macbook.local", port: 9091, token: "abc123")
        await sdk.annotate(screen: "Home")
        await sdk.annotate(screen: "Details")

        let annotations = try await Self.sentAnnotations(from: transport)
        #expect(annotations.map(\.label) == ["Home", "Home", "Details"])
        #expect(annotations.map(\.lifecycle) == [.begin, .end, .begin])
        #expect(annotations[0].scopeID == annotations[1].scopeID)
        #expect(annotations[2].scopeID != annotations[0].scopeID)
        await sdk.disconnect()
    }

    @Test func sessionAnnotationSendsEndWhenBodyThrows() async throws {
        let transport = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)])
        let sdk = ProxySDK(
            transportFactory: { transport },
            discovery: MockDiscovery()
        )

        await sdk.connect(host: "macbook.local", port: 9091, token: "abc123")
        await #expect(throws: TestFailure.self) {
            try await sdk.session("Checkout") {
                throw TestFailure()
            }
        }

        let annotations = try await Self.sentAnnotations(from: transport)
        #expect(annotations.map(\.label) == ["Checkout", "Checkout"])
        #expect(annotations.map(\.kind) == [.testCapture, .testCapture])
        #expect(annotations.map(\.lifecycle) == [.begin, .end])
        #expect(annotations[0].scopeID == annotations[1].scopeID)
        await sdk.disconnect()
    }

    @Test func playbackMarkersSendExpectedKindsAndMetadata() async throws {
        let transport = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)])
        let sdk = ProxySDK(
            transportFactory: { transport },
            discovery: MockDiscovery()
        )

        await sdk.connect(host: "macbook.local", port: 9091, token: "abc123")
        await sdk.markLaunch()
        await sdk.markReady(label: "First Frame")
        await sdk.markPlaybackStart(contentID: "episode-42")
        await sdk.markPlaybackReady()

        let annotations = try await Self.sentAnnotations(from: transport)
        #expect(annotations.map(\.kind) == [.launchMarker, .readyMarker, .playbackStart, .playbackReady])
        #expect(annotations[1].label == "First Frame")
        #expect(annotations[2].metadata["contentID"] == "episode-42")
        await sdk.disconnect()
    }

    @Test func annotationMethodsNoOpWhenDisconnected() async throws {
        let transport = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)])
        let sdk = ProxySDK(
            transportFactory: { transport },
            discovery: MockDiscovery()
        )

        await sdk.connect(host: "macbook.local", port: 9091, token: "abc123")
        await sdk.disconnect()
        await sdk.annotate(feature: "Ignored")
        await sdk.markLaunch()

        let sentMessages = await transport.sentMessages
        #expect(sentMessages.count == 1)
    }

    @Test func diagnoseSetupReturnsProbeStatus() async {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let statuses: [ProxySDKSetupStatus] = [
            .proxyNotFound,
            .proxyFoundCertNotInstalled,
            .proxyFoundCertNotTrusted,
            .ready(certExpiry: expiry)
        ]

        for status in statuses {
            let sdk = ProxySDK(
                transportFactory: { MockWebSocketTransport(incoming: []) },
                discovery: MockDiscovery(),
                certTrustProbe: MockCertTrustProbe(status: status)
            )

            let result = await sdk.diagnoseSetup(proxyHost: "macbook.local", port: 9090)
            #expect(result == status)
        }
    }

    @Test func diagnoseSetupCompletionUsesLastManualConnection() async throws {
        let transport = MockWebSocketTransport(incoming: [try Self.handshakeAck(accepted: true)])
        let probe = MockCertTrustProbe(status: .proxyFoundCertNotTrusted)
        let sdk = ProxySDK(
            transportFactory: { transport },
            discovery: MockDiscovery(),
            certTrustProbe: probe
        )
        let recorder = SetupStatusRecorder()

        await sdk.connect(host: "macbook.local", port: 9091, token: "abc123")
        sdk.diagnoseSetup { status in
            Task { await recorder.append(status) }
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        let statuses = await recorder.statuses
        #expect(statuses == [.proxyFoundCertNotTrusted])
        #expect(await probe.requests == [ProbeRequest(host: "macbook.local", port: 9091)])
        await sdk.disconnect()
    }

    private static func handshakeAck(
        accepted: Bool,
        rejectReason: SDKHandshakeRejectReason? = nil,
        compatibility: SDKCompatibilityInfo? = nil
    ) throws -> String {
        let ack = HandshakeAck(
            accepted: accepted,
            rejectReason: rejectReason,
            serverTimestamp: Date(timeIntervalSince1970: 1_800_000_000),
            clockOffsetMs: accepted ? 42 : 0,
            selectedSchemaVersion: accepted ? SDKSchema.version : nil,
            supportedSchemaVersions: [SDKSchema.version],
            serverAppVersion: compatibility?.serverAppVersion,
            minimumSupportedSchemaVersion: compatibility?.minimumSupportedSchemaVersion,
            latestSupportedSchemaVersion: compatibility?.latestSupportedSchemaVersion,
            compatibilityResolution: compatibility?.compatibilityResolution,
            compatibilityMessage: compatibility?.message
        )
        let envelope = SDKMessageEnvelope(
            type: .handshakeAck,
            version: SDKSchema.version,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            sentAt: ack.serverTimestamp,
            payload: ack
        )
        let data = try SDKEventJSONCodec.makeEncoder().encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    private static func networkEventMessage() throws -> String {
        let event = NetworkEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            phase: .completed,
            timestamp: Date(timeIntervalSince1970: 1_800_000_001),
            url: URL(string: "https://example.com/api")!,
            redactionLevel: .queryRedacted,
            method: "GET",
            statusCode: 200,
            timing: NetworkTiming(dns: nil, tcp: nil, tls: nil, ttfb: 0.1, transfer: 0, total: 0.1),
            sizes: NetworkSizes(requestBytes: 0, responseBytes: 128, compressedResponseBytes: nil),
            connectionInfo: ConnectionInfo(httpProtocol: "HTTP/1.1", isConnectionReused: false, cdnRegion: nil),
            redirectCount: 0,
            retryCount: 0,
            cacheStatus: nil,
            certificateExpiry: nil,
            annotations: [],
            sourceSDK: nil,
            lane: "API",
            connectionID: nil,
            parentEventID: nil
        )
        let envelope = SDKMessageEnvelope(
            type: .networkEvent,
            version: SDKSchema.version,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
            sentAt: event.timestamp,
            payload: event
        )
        let data = try SDKEventJSONCodec.makeEncoder().encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    private static func annotation(label: String) -> AnnotationEvent {
        AnnotationEvent(
            id: UUID(),
            scopeID: nil,
            label: label,
            kind: .feature,
            lifecycle: .instant,
            metadata: [:],
            deviceTimestamp: Date(timeIntervalSince1970: 1_800_000_002)
        )
    }

    private static func sentAnnotations(from transport: MockWebSocketTransport) async throws -> [AnnotationEvent] {
        let messages = await transport.sentMessages.dropFirst()
        return try messages.map { message in
            try SDKEventJSONCodec.makeDecoder().decode(
                SDKMessageEnvelope<AnnotationEvent>.self,
                from: Data(message.utf8)
            ).payload
        }
    }
}

private struct TestFailure: Error, Equatable {}

private actor MockWebSocketTransport: ProxySDKWebSocketTransport {
    private var incoming: [String]
    private var throwsWhenEmpty: Bool
    private(set) var sentMessages: [String] = []
    private(set) var isClosed = false

    init(incoming: [String], throwsWhenEmpty: Bool = false) {
        self.incoming = incoming
        self.throwsWhenEmpty = throwsWhenEmpty
    }

    func connect(to url: URL) async throws {}

    func sendText(_ text: String) async throws {
        sentMessages.append(text)
    }

    func receiveText() async throws -> String {
        while incoming.isEmpty {
            if throwsWhenEmpty || isClosed {
                throw ProxySDKError.protocolError("No mock message available.")
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return incoming.removeFirst()
    }

    func close() async {
        isClosed = true
    }

    func failWhenEmpty() {
        throwsWhenEmpty = true
    }
}

private final class MockTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [MockWebSocketTransport]
    private(set) var createdCount = 0

    init(transports: [MockWebSocketTransport]) {
        self.transports = transports
    }

    func next() -> MockWebSocketTransport {
        lock.lock()
        defer { lock.unlock() }
        createdCount += 1
        return transports.removeFirst()
    }
}

private struct MockDiscovery: JoesProxyDiscovering {
    let service: DiscoveredJoesProxyService?

    init(service: DiscoveredJoesProxyService? = nil) {
        self.service = service
    }

    @MainActor
    func discover(timeout: TimeInterval) async throws -> DiscoveredJoesProxyService {
        guard let service else {
            throw ProxySDKError.discoveryTimedOut
        }
        return service
    }
}

private actor NetworkEventRecorder {
    private(set) var events: [NetworkEvent] = []

    func append(_ event: NetworkEvent) {
        events.append(event)
    }
}

private struct ProbeRequest: Equatable, Sendable {
    let host: String
    let port: Int
}

private actor MockCertTrustProbe: CertTrustProbing {
    private let status: ProxySDKSetupStatus
    private(set) var requests: [ProbeRequest] = []

    init(status: ProxySDKSetupStatus) {
        self.status = status
    }

    func run(proxyHost: String, port: Int) async -> ProxySDKSetupStatus {
        requests.append(ProbeRequest(host: proxyHost, port: port))
        return status
    }
}

private actor SetupStatusRecorder {
    private(set) var statuses: [ProxySDKSetupStatus] = []

    func append(_ status: ProxySDKSetupStatus) {
        statuses.append(status)
    }
}
