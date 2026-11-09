import Combine
import Foundation

@MainActor
public final class ProxySDK: ObservableObject {
    public static let shared = ProxySDK()

    @Published public private(set) var connectionState: ProxySDKConnectionState = .disconnected
    @Published public private(set) var clockOffsetMs: Int?

    private let transportFactory: @Sendable () -> any ProxySDKWebSocketTransport
    private let discovery: any JoesProxyDiscovering
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let reconnectDelaysNanoseconds: [UInt64]
    private let sleep: @Sendable (UInt64) async -> Void
    private let certTrustProbe: any CertTrustProbing
    private var transport: (any ProxySDKWebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var networkEventHandlers: [UUID: @Sendable (NetworkEvent) -> Void] = [:]
    private var lastManualConnection: ManualConnection?
    private var shouldReconnect = false
    private var outgoingBuffer: [String] = []
    private var activeScreen: ActiveScreenAnnotation?
    public lazy var streamingMonitor = StreamingMonitor()
    #if os(iOS) && DEBUG
    private lazy var overlayController = SDKOverlayController()
    private var overlayActivated = false
    #endif

    public convenience init() {
        self.init(
            transportFactory: { URLSessionProxySDKWebSocketTransport() },
            discovery: BonjourJoesProxyDiscovery()
        )
    }

    init(
        transportFactory: @escaping @Sendable () -> any ProxySDKWebSocketTransport,
        discovery: any JoesProxyDiscovering,
        encoder: JSONEncoder = SDKEventJSONCodec.makeEncoder(),
        decoder: JSONDecoder = SDKEventJSONCodec.makeDecoder(),
        reconnectDelaysNanoseconds: [UInt64] = [1, 2, 4, 8, 16, 30].map { $0 * 1_000_000_000 },
        certTrustProbe: any CertTrustProbing = CertTrustProbe(),
        sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.transportFactory = transportFactory
        self.discovery = discovery
        self.encoder = encoder
        self.decoder = decoder
        self.reconnectDelaysNanoseconds = reconnectDelaysNanoseconds
        self.certTrustProbe = certTrustProbe
        self.sleep = sleep
    }

    deinit {
        receiveTask?.cancel()
    }

    public func connect(host: String, port: Int, token: String) async {
        #if DEBUG || PROXYSDK_TESTING
        await connectManually(host: host, port: port, token: token, cancelReceiveLoop: true)
        #else
        connectionState = .disconnected
        #endif
    }

    public func discoverAndConnect(token: String, timeout: TimeInterval = 2) async {
        #if DEBUG || PROXYSDK_TESTING
        connectionState = .discovering
        do {
            let service = try await discovery.discover(timeout: timeout)
            await connectManually(host: service.host, port: service.eventServerPort, token: token, cancelReceiveLoop: true)
        } catch {
            connectionState = .failed(message: String(describing: error))
        }
        #else
        connectionState = .disconnected
        #endif
    }

    public func diagnoseSetup(proxyHost: String, port: Int) async -> ProxySDKSetupStatus {
        #if DEBUG || PROXYSDK_TESTING
        await certTrustProbe.run(proxyHost: proxyHost, port: port)
        #else
        .proxyNotFound
        #endif
    }

    public func diagnoseSetup(completion: @escaping @Sendable (ProxySDKSetupStatus) -> Void) {
        #if DEBUG || PROXYSDK_TESTING
        guard let lastManualConnection else {
            completion(.proxyNotFound)
            return
        }
        Task {
            let status = await certTrustProbe.run(proxyHost: lastManualConnection.host, port: lastManualConnection.port)
            completion(status)
        }
        #else
        completion(.proxyNotFound)
        #endif
    }

    public func disconnect() async {
        if let activeScreen {
            await sendAnnotation(
                label: activeScreen.label,
                kind: .screen,
                lifecycle: .end,
                scopeID: activeScreen.scopeID,
                metadata: [:]
            )
            self.activeScreen = nil
        }
        shouldReconnect = false
        lastManualConnection = nil
        receiveTask?.cancel()
        receiveTask = nil
        await transport?.close()
        transport = nil
        clockOffsetMs = nil
        connectionState = .disconnected
    }

    @discardableResult
    public func onNetworkEvent(_ handler: @escaping @Sendable (NetworkEvent) -> Void) -> UUID {
        let id = UUID()
        networkEventHandlers[id] = handler
        return id
    }

    public func removeNetworkEventHandler(_ id: UUID) {
        networkEventHandlers.removeValue(forKey: id)
    }

    public func annotate(screen: String) async {
        if let activeScreen {
            await sendAnnotation(
                label: activeScreen.label,
                kind: .screen,
                lifecycle: .end,
                scopeID: activeScreen.scopeID,
                metadata: [:]
            )
        }

        let scopeID = UUID()
        activeScreen = ActiveScreenAnnotation(scopeID: scopeID, label: screen)
        await sendAnnotation(
            label: screen,
            kind: .screen,
            lifecycle: .begin,
            scopeID: scopeID,
            metadata: [:]
        )
    }

    public func annotate(feature: String, metadata: [String: String] = [:]) async {
        await sendAnnotation(
            label: feature,
            kind: .feature,
            lifecycle: .instant,
            scopeID: nil,
            metadata: metadata
        )
    }

    public func session<T>(_ label: String, body: () async throws -> T) async rethrows -> T {
        let scopeID = UUID()
        await sendAnnotation(
            label: label,
            kind: .testCapture,
            lifecycle: .begin,
            scopeID: scopeID,
            metadata: [:]
        )

        do {
            let result = try await body()
            await sendAnnotation(
                label: label,
                kind: .testCapture,
                lifecycle: .end,
                scopeID: scopeID,
                metadata: [:]
            )
            return result
        } catch {
            await sendAnnotation(
                label: label,
                kind: .testCapture,
                lifecycle: .end,
                scopeID: scopeID,
                metadata: [:]
            )
            throw error
        }
    }

    public func markLaunch() async {
        await sendAnnotation(
            label: "Launch",
            kind: .launchMarker,
            lifecycle: .instant,
            scopeID: nil,
            metadata: [:]
        )
    }

    public func markReady(label: String = "Ready") async {
        await sendAnnotation(
            label: label,
            kind: .readyMarker,
            lifecycle: .instant,
            scopeID: nil,
            metadata: [:]
        )
    }

    public func markPlaybackStart(contentID: String) async {
        await sendAnnotation(
            label: "Playback Start",
            kind: .playbackStart,
            lifecycle: .instant,
            scopeID: nil,
            metadata: ["contentID": contentID]
        )
    }

    public func markPlaybackReady() async {
        await sendAnnotation(
            label: "Playback Ready",
            kind: .playbackReady,
            lifecycle: .instant,
            scopeID: nil,
            metadata: [:]
        )
    }

    func sendAnnotationEvent(_ event: AnnotationEvent) async {
        #if DEBUG || PROXYSDK_TESTING
        guard transport != nil else {
            return
        }
        let envelope = SDKMessageEnvelope(
            type: .annotationEvent,
            version: SDKSchema.version,
            id: UUID(),
            sentAt: Date(),
            payload: event
        )
        await sendEnvelope(envelope)
        #endif
    }

    private func sendAnnotation(
        label: String,
        kind: AnnotationKind,
        lifecycle: AnnotationLifecycle,
        scopeID: UUID?,
        metadata: [String: String]
    ) async {
        await sendAnnotationEvent(
            AnnotationEvent(
                id: UUID(),
                scopeID: scopeID,
                label: label,
                kind: kind,
                lifecycle: lifecycle,
                metadata: metadata,
                deviceTimestamp: Date()
            )
        )
    }

    private func connectManually(host: String, port: Int, token: String, cancelReceiveLoop: Bool) async {
        guard port > 0, port <= 65_535 else {
            connectionState = .failed(message: String(describing: ProxySDKError.invalidPort(port)))
            return
        }
        guard let url = URL(string: "ws://\(host):\(port)/") else {
            connectionState = .failed(message: String(describing: ProxySDKError.invalidWebSocketURL))
            return
        }

        await disconnectForReconnect(cancelReceiveLoop: cancelReceiveLoop)
        connectionState = .connecting(host: host, port: port)
        lastManualConnection = ManualConnection(host: host, port: port, token: token)
        shouldReconnect = true

        let newTransport = transportFactory()
        transport = newTransport

        do {
            try await newTransport.connect(to: url)
            let handshake = makeHandshake(token: token)
            let envelope = SDKMessageEnvelope(
                type: .handshake,
                version: SDKSchema.version,
                id: UUID(),
                sentAt: handshake.deviceTimestamp,
                payload: handshake
            )
            let data = try encoder.encode(envelope)
            let message = String(decoding: data, as: UTF8.self)
            try await newTransport.sendText(message)

            let ackText = try await newTransport.receiveText()
            let ack = try decoder.decode(SDKMessageEnvelope<HandshakeAck>.self, from: Data(ackText.utf8))
            guard ack.type == .handshakeAck else {
                throw ProxySDKError.protocolError("Expected handshake acknowledgement.")
            }

            if !ack.payload.accepted {
                let reason = ack.payload.rejectReason ?? .protocolError
                let compatibility = SDKCompatibilityInfo(handshakeAck: ack.payload)
                connectionState = .rejected(reason: reason, compatibility: compatibility.hasDetails ? compatibility : nil)
                await newTransport.close()
                return
            }

            clockOffsetMs = ack.payload.clockOffsetMs
            connectionState = .connected(host: host, port: port, clockOffsetMs: ack.payload.clockOffsetMs)
            try await replayOutgoingBuffer(on: newTransport)
            startReceiveLoop(transport: newTransport)
        } catch {
            connectionState = .failed(message: String(describing: error))
            await newTransport.close()
        }
    }

    private func disconnectForReconnect(cancelReceiveLoop: Bool) async {
        if cancelReceiveLoop {
            receiveTask?.cancel()
            receiveTask = nil
        }
        await transport?.close()
        transport = nil
        clockOffsetMs = nil
    }

    private func sendEnvelope<Payload: Codable & Equatable & Sendable>(_ envelope: SDKMessageEnvelope<Payload>) async {
        do {
            let data = try encoder.encode(envelope)
            let text = String(decoding: data, as: UTF8.self)
            try await sendText(text, shouldBuffer: true)
        } catch {
            connectionState = .failed(message: String(describing: error))
        }
    }

    private func sendText(_ text: String, shouldBuffer: Bool) async throws {
        if shouldBuffer {
            outgoingBuffer.append(text)
            if outgoingBuffer.count > 5 {
                outgoingBuffer.removeFirst(outgoingBuffer.count - 5)
            }
        }
        guard let transport else {
            return
        }
        try await transport.sendText(text)
    }

    private func replayOutgoingBuffer(on transport: any ProxySDKWebSocketTransport) async throws {
        for message in outgoingBuffer {
            try await transport.sendText(message)
        }
    }

    private func makeHandshake(token: String) -> PairingHandshake {
        PairingHandshake(
            token: token,
            deviceName: ProcessInfo.processInfo.hostName,
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            deviceTimestamp: Date(),
            sdkVersion: "0.1.0",
            schemaVersion: SDKSchema.version,
            supportedSchemaVersions: [SDKSchema.version]
        )
    }

    private func startReceiveLoop(transport: any ProxySDKWebSocketTransport) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await transport.receiveText()
                    self?.handleIncomingMessage(text)
                } catch {
                    await self?.handleReceiveFailure(error)
                    return
                }
            }
        }
    }

    private func handleIncomingMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            return
        }
        guard let header = try? decoder.decode(SDKMessageHeader.self, from: data) else {
            return
        }

        switch SDKMessageType(rawValue: header.type) {
        case .networkEvent:
            guard let envelope = try? decoder.decode(SDKMessageEnvelope<NetworkEvent>.self, from: data) else {
                return
            }
            networkEventHandlers.values.forEach { $0(envelope.payload) }
        case .streamingSegmentEvent:
            guard let envelope = try? decoder.decode(SDKMessageEnvelope<StreamingSegmentEvent>.self, from: data) else {
                return
            }
            streamingMonitor.dispatch(envelope.payload)
        case .drmLicenseEvent:
            guard let envelope = try? decoder.decode(SDKMessageEnvelope<DRMLicenseEvent>.self, from: data) else {
                return
            }
            streamingMonitor.dispatch(envelope.payload)
        case .manifestEvent:
            guard let envelope = try? decoder.decode(SDKMessageEnvelope<ManifestEvent>.self, from: data) else {
                return
            }
            streamingMonitor.dispatch(envelope.payload)
        case .stallRiskEvent:
            guard let envelope = try? decoder.decode(SDKMessageEnvelope<StallRiskEvent>.self, from: data) else {
                return
            }
            streamingMonitor.dispatch(envelope.payload)
        default:
            break
        }
    }

    private func handleReceiveFailure(_ error: Error) async {
        guard shouldReconnect, let lastManualConnection else {
            connectionState = .failed(message: String(describing: error))
            return
        }

        connectionState = .failed(message: String(describing: error))
        await reconnect(lastManualConnection)
    }

    private func reconnect(_ connection: ManualConnection) async {
        for delay in reconnectDelaysNanoseconds where !Task.isCancelled {
            await sleep(delay)
            guard !Task.isCancelled else {
                return
            }
            await connectManually(host: connection.host, port: connection.port, token: connection.token, cancelReceiveLoop: false)
            if case .connected = connectionState {
                return
            }
        }
    }
}

// MARK: - Developer Overlay (iOS, DEBUG only)

#if os(iOS) && DEBUG
extension ProxySDK {
    /// Shows the developer overlay waterfall. Registers the 3-finger long-press activator
    /// on first call. Safe to call from a debug button; no-op in Release builds.
    public func showOverlay() {
        if !overlayActivated {
            overlayController.activate()
            overlayActivated = true
        }
        overlayController.show()
    }

    /// Hides the developer overlay.
    public func hideOverlay() {
        overlayController.hide()
    }

    /// `true` when the overlay window is currently on screen.
    public var isOverlayVisible: Bool {
        overlayController.isVisible
    }
}
#endif

private struct ManualConnection: Sendable {
    let host: String
    let port: Int
    let token: String
}

private struct ActiveScreenAnnotation: Sendable {
    let scopeID: UUID
    let label: String
}
