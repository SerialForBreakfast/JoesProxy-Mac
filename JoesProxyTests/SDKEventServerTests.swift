import Combine
import Foundation
import XCTest
@testable import JoesProxy

final class SDKEventServerTests: XCTestCase {
    @MainActor
    func testProxyStartDoesNotStartSDKServerWhenToggleIsFalse() async throws {
        let configuration = SDKRuntimeTestConfiguration()
        configuration.proxyPort = 0
        configuration.sdkEventServerEnabled = false
        let sdkServer = RecordingSDKEventServer()
        let runtime = DefaultProxyRuntime(
            configuration: configuration,
            server: ProxyServer(port: 0, bindHost: "127.0.0.1"),
            sdkEventServer: sdkServer
        )
        defer { Task { await runtime.stop() } }

        await runtime.start()

        XCTAssertEqual(sdkServer.startPorts, [])
        XCTAssertEqual(runtime.currentState, .running(port: configuration.proxyPort))
        XCTAssertGreaterThan(configuration.proxyPort, 0)
        await runtime.stop()
    }

    @MainActor
    func testProxyStartStartsSDKServerWhenToggleIsTrue() async throws {
        let configuration = SDKRuntimeTestConfiguration()
        configuration.proxyPort = 0
        configuration.sdkEventServerEnabled = true
        let sdkServer = RecordingSDKEventServer()
        let runtime = DefaultProxyRuntime(
            configuration: configuration,
            server: ProxyServer(port: 0, bindHost: "127.0.0.1"),
            sdkEventServer: sdkServer
        )
        defer { Task { await runtime.stop() } }

        await runtime.start()

        XCTAssertEqual(sdkServer.startPorts, [configuration.sdkEventServerPort])
        XCTAssertEqual(runtime.currentState, .running(port: configuration.proxyPort))
        XCTAssertGreaterThan(configuration.proxyPort, 0)
        await runtime.stop()
    }

    @MainActor
    func testDisablingToggleWhileProxyRunsStopsSDKServer() async throws {
        let configuration = SDKRuntimeTestConfiguration()
        configuration.proxyPort = 0
        configuration.sdkEventServerEnabled = true
        let sdkServer = RecordingSDKEventServer()
        let runtime = DefaultProxyRuntime(
            configuration: configuration,
            server: ProxyServer(port: 0, bindHost: "127.0.0.1"),
            sdkEventServer: sdkServer
        )
        defer { Task { await runtime.stop() } }

        await runtime.start()
        configuration.sdkEventServerEnabled = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while sdkServer.stopCallCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(sdkServer.stopCallCount, 1)
        XCTAssertEqual(runtime.currentState, .running(port: configuration.proxyPort))
        XCTAssertGreaterThan(configuration.proxyPort, 0)
        await runtime.stop()
    }

    @MainActor
    func testSDKStartupFailureDoesNotFailProxyStartup() async throws {
        let configuration = SDKRuntimeTestConfiguration()
        configuration.proxyPort = 0
        configuration.sdkEventServerEnabled = true
        let sdkServer = RecordingSDKEventServer(startError: SDKEventServerTestError.startFailed)
        let runtime = DefaultProxyRuntime(
            configuration: configuration,
            server: ProxyServer(port: 0, bindHost: "127.0.0.1"),
            sdkEventServer: sdkServer
        )
        defer { Task { await runtime.stop() } }

        await runtime.start()

        XCTAssertEqual(sdkServer.startPorts, [configuration.sdkEventServerPort])
        XCTAssertEqual(runtime.currentState, .running(port: configuration.proxyPort))
        XCTAssertGreaterThan(configuration.proxyPort, 0)
        await runtime.stop()
    }

    func testValidHandshakeReturnsAcceptedAck() async throws {
        let sessionStore = InMemorySessionStore()
        let server = SDKEventServer(sessionStore: sessionStore)
        await server.setPairingToken("valid-token")

        let ack = try await server.handshakeAcknowledgement(for: makeHandshakeMessage(token: "valid-token"))

        XCTAssertEqual(ack.type, .handshakeAck)
        XCTAssertTrue(ack.payload.accepted)
        XCTAssertNil(ack.payload.rejectReason)
        XCTAssertEqual(ack.payload.selectedSchemaVersion, SDKSchema.version)
        XCTAssertEqual(ack.payload.serverAppVersion, Bundle.main.marketingVersionOrDev)
        XCTAssertEqual(ack.payload.minimumSupportedSchemaVersion, SDKSchema.version)
        XCTAssertEqual(ack.payload.latestSupportedSchemaVersion, SDKSchema.version)
    }

    func testInvalidTokenReturnsRejectedAck() async throws {
        let sessionStore = InMemorySessionStore()
        let server = SDKEventServer(sessionStore: sessionStore)
        await server.setPairingToken("valid-token")

        let ack = try await server.handshakeAcknowledgement(for: makeHandshakeMessage(token: "bad-token"))

        XCTAssertFalse(ack.payload.accepted)
        XCTAssertEqual(ack.payload.rejectReason, .invalidToken)
        XCTAssertNil(ack.payload.selectedSchemaVersion)
    }

    func testUnsupportedSchemaReturnsRejectedAck() async throws {
        let sessionStore = InMemorySessionStore()
        let server = SDKEventServer(sessionStore: sessionStore)
        await server.setPairingToken("valid-token")

        let ack = try await server.handshakeAcknowledgement(for: makeHandshakeMessage(
            token: "valid-token",
            schemaVersion: 99,
            supportedSchemaVersions: [99]
        ))

        XCTAssertFalse(ack.payload.accepted)
        XCTAssertEqual(ack.payload.rejectReason, .schemaVersionUnsupported)
        XCTAssertEqual(ack.payload.compatibilityResolution, .updateJoesProxy)
        XCTAssertEqual(ack.payload.serverAppVersion, Bundle.main.marketingVersionOrDev)
        XCTAssertEqual(ack.payload.minimumSupportedSchemaVersion, SDKSchema.version)
        XCTAssertEqual(ack.payload.latestSupportedSchemaVersion, SDKSchema.version)
        XCTAssertTrue(try XCTUnwrap(ack.payload.compatibilityMessage).contains("Update JoesProxy"))
    }

    func testOlderSDKSchemaReturnsUpdateSDKGuidance() async throws {
        let sessionStore = InMemorySessionStore()
        let server = SDKEventServer(sessionStore: sessionStore)
        await server.setPairingToken("valid-token")

        let ack = try await server.handshakeAcknowledgement(for: makeHandshakeMessage(
            token: "valid-token",
            schemaVersion: 0,
            supportedSchemaVersions: [0]
        ))

        XCTAssertFalse(ack.payload.accepted)
        XCTAssertEqual(ack.payload.rejectReason, .schemaVersionUnsupported)
        XCTAssertEqual(ack.payload.compatibilityResolution, .updateSDK)
        XCTAssertTrue(try XCTUnwrap(ack.payload.compatibilityMessage).contains("Update the JoesProxySDK package"))
    }

    @MainActor
    func testAppendedSessionBroadcastsRedactedNetworkEvent() async throws {
        let sessionStore = InMemorySessionStore()
        let server = SDKEventServer(sessionStore: sessionStore)

        let envelopes = await server.networkEventEnvelopes(for: .appended(
            makeSession(path: "/api/items?token=secret#debug"),
            droppedIDs: []
        ))
        let eventEnvelope = try XCTUnwrap(envelopes.first)

        XCTAssertEqual(eventEnvelope.type, .networkEvent)
        XCTAssertEqual(eventEnvelope.payload.phase, .completed)
        XCTAssertEqual(eventEnvelope.payload.url.absoluteString, "https://api.example.com/api/items")
        XCTAssertEqual(eventEnvelope.payload.redactionLevel, .queryRedacted)
        XCTAssertNil(eventEnvelope.payload.sourceSDK)
        XCTAssertNil(eventEnvelope.payload.connectionID)
        XCTAssertNil(eventEnvelope.payload.parentEventID)
    }

    @MainActor
    func testUpdatedBatchBroadcastsNetworkEventsAndRemovedOrClearedDoNotBroadcast() async throws {
        let sessionStore = InMemorySessionStore()
        let server = SDKEventServer(sessionStore: sessionStore)

        let firstID = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!
        let batchEnvelopes = await server.networkEventEnvelopes(for: .updatedBatch([
            makeSession(id: firstID, path: "/one.json"),
            makeSession(id: secondID, path: "/two.json")
        ], insertedIDs: [firstID, secondID]))

        XCTAssertEqual(Set(batchEnvelopes.map(\.payload.sessionID)), Set([firstID, secondID]))

        let removedEnvelopes = await server.networkEventEnvelopes(for: .removed(ids: [firstID]))
        let clearedEnvelopes = await server.networkEventEnvelopes(for: .cleared)
        XCTAssertTrue(removedEnvelopes.isEmpty)
        XCTAssertTrue(clearedEnvelopes.isEmpty)
    }

    @MainActor
    func testAnnotationMessageLabelsSubsequentNetworkEvents() async throws {
        let sessionStore = InMemorySessionStore()
        let annotationStore = SDKAnnotationStore()
        let server = SDKEventServer(sessionStore: sessionStore, annotationStore: annotationStore)
        let scopeID = UUID()
        let deviceStart = Date(timeIntervalSinceReferenceDate: 90)

        try await server.ingestAnnotationMessage(
            makeAnnotationMessage(
                scopeID: scopeID,
                label: "Home",
                lifecycle: .begin,
                deviceTimestamp: deviceStart
            ),
            clockOffsetMs: 10_000
        )

        let envelopes = await server.networkEventEnvelopes(for: .appended(
            makeSession(path: "/api/items"),
            droppedIDs: []
        ))

        XCTAssertEqual(envelopes.first?.payload.annotations, ["Home"])
    }

    @MainActor
    func testAnnotationEndRemovesLabelFromLaterNetworkEvents() async throws {
        let sessionStore = InMemorySessionStore()
        let annotationStore = SDKAnnotationStore()
        let server = SDKEventServer(sessionStore: sessionStore, annotationStore: annotationStore)
        let scopeID = UUID()

        try await server.ingestAnnotationMessage(
            makeAnnotationMessage(
                scopeID: scopeID,
                label: "Home",
                lifecycle: .begin,
                deviceTimestamp: Date(timeIntervalSinceReferenceDate: 90)
            ),
            clockOffsetMs: 0
        )
        try await server.ingestAnnotationMessage(
            makeAnnotationMessage(
                scopeID: scopeID,
                label: "Home",
                lifecycle: .end,
                deviceTimestamp: Date(timeIntervalSinceReferenceDate: 95)
            ),
            clockOffsetMs: 0
        )

        let envelopes = await server.networkEventEnvelopes(for: .appended(
            makeSession(path: "/api/items"),
            droppedIDs: []
        ))

        XCTAssertEqual(envelopes.first?.payload.annotations, [])
    }

    private func makeHandshakeMessage(
        token: String,
        schemaVersion: Int = SDKSchema.version,
        supportedSchemaVersions: [Int] = [SDKSchema.version]
    ) throws -> String {
        let handshake = PairingHandshake(
            token: token,
            deviceName: "Unit Test Device",
            bundleID: "com.example.UnitTest",
            deviceTimestamp: Date(),
            sdkVersion: "1.0",
            schemaVersion: schemaVersion,
            supportedSchemaVersions: supportedSchemaVersions
        )
        let envelope = SDKMessageEnvelope(
            type: .handshake,
            version: SDKSchema.version,
            id: UUID(),
            sentAt: Date(),
            payload: handshake
        )
        let data = try SDKEventJSONCodec.makeEncoder().encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeAnnotationMessage(
        scopeID: UUID?,
        label: String,
        lifecycle: AnnotationLifecycle,
        deviceTimestamp: Date
    ) throws -> String {
        let annotation = AnnotationEvent(
            id: UUID(),
            scopeID: scopeID,
            label: label,
            kind: .screen,
            lifecycle: lifecycle,
            metadata: [:],
            deviceTimestamp: deviceTimestamp
        )
        let envelope = SDKMessageEnvelope(
            type: .annotationEvent,
            version: SDKSchema.version,
            id: UUID(),
            sentAt: Date(),
            payload: annotation
        )
        let data = try SDKEventJSONCodec.makeEncoder().encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeSession(
        id: UUID = UUID(),
        path: String,
        state: SessionLifecycleState = .completed
    ) -> SessionRecord {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        return SessionRecord(
            id: id,
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "api.example.com",
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: Data("{\"ok\":true}".utf8),
                bodySize: 11
            ),
            state: state,
            timing: SessionTiming(startedAt: start, completedAt: start.addingTimeInterval(0.1))
        )
    }

}

private enum SDKEventServerTestError: Error {
    case timedOut
    case unexpectedMessage
    case startFailed
}

private final class RecordingSDKEventServer: SDKEventServing {
    private(set) var startPorts: [UInt16] = []
    private(set) var stopCallCount = 0
    private let startError: Error?

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func status() async -> SDKEventServerStatus {
        SDKEventServerStatus(
            isRunning: !startPorts.isEmpty && stopCallCount == 0,
            port: startPorts.last,
            pairingToken: nil,
            connectedClientCount: 0
        )
    }

    func start(port: UInt16) async throws {
        startPorts.append(port)
        if let startError {
            throw startError
        }
    }

    func stop() async {
        stopCallCount += 1
    }
}

private final class SDKRuntimeTestConfiguration: AppConfiguration {
    var proxyPort: UInt16 = 9090 { didSet { didChangeSubject.send(()) } }
    var logLevel: AppLogLevel = .info { didSet { didChangeSubject.send(()) } }
    var verboseHTTPSLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var isFindDebugLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var appTextSizeRawValue = AppTextSize.standard.rawValue { didSet { didChangeSubject.send(()) } }
    var isInspectorCopyRedactionEnabled = true { didSet { didChangeSubject.send(()) } }
    var sessionSortFieldRawValue = ProxyViewModel.SessionSortField.startedAt.rawValue { didSet { didChangeSubject.send(()) } }
    var isSessionSortAscending = false { didSet { didChangeSubject.send(()) } }
    var isSessionAutoScrollEnabled = false { didSet { didChangeSubject.send(()) } }
    var sessionBrowserModeRawValue = SessionBrowserMode.table.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerGroupingRawValue = SessionExplorerGrouping.byHost.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.exactHosts.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerExpandedNodeIDs: [String] = [] { didSet { didChangeSubject.send(()) } }
    var sessionInspectorSplitFraction = 0.62 { didSet { didChangeSubject.send(()) } }
    var httpsBypassDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var httpsInterceptDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var isNoCachingEnabled = false { didSet { didChangeSubject.send(()) } }
    var noCachingDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var isSystemProxyManagementEnabled = false { didSet { didChangeSubject.send(()) } }
    var systemProxyStrictCapture = false { didSet { didChangeSubject.send(()) } }
    var hasAcknowledgedSystemProxyRouting = false { didSet { didChangeSubject.send(()) } }
    var showSystemProxyMenuBarItem = false { didSet { didChangeSubject.send(()) } }
    var runInMenuBarOnly = false
    var hasCompletedInitialGuidedSetupPresentation = false { didSet { didChangeSubject.send(()) } }
    var warnsBeforeQuittingWithUnsavedSessions = true { didSet { didChangeSubject.send(()) } }
    var sdkEventServerEnabled = false { didSet { didChangeSubject.send(()) } }
    var sdkEventServerPort: UInt16 { 9091 }
    var networkThrottleConfiguration = NetworkThrottleConfiguration.defaults { didSet { didChangeSubject.send(()) } }
    var profileHostStrategyRawValue = ProfileHostStrategy.bonjourLocal.rawValue { didSet { didChangeSubject.send(()) } }
    var manualProfileHost = "" { didSet { didChangeSubject.send(()) } }
    var responseOverridesData: Data? { didSet { didChangeSubject.send(()) } }
    var captureRetentionPolicy: CaptureRetentionPolicy = .unlimited { didSet { didChangeSubject.send(()) } }
    let certificateLabel = "SDKRuntimeTestRoot"

    private let didChangeSubject = PassthroughSubject<Void, Never>()

    var didChangePublisher: AnyPublisher<Void, Never> {
        didChangeSubject.eraseToAnyPublisher()
    }

    func resetToDefaults() {
        sdkEventServerEnabled = false
        networkThrottleConfiguration = .defaults
    }
}
