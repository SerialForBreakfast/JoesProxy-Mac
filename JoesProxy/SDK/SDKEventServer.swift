import Combine
import CryptoKit
import Foundation
import Network
import OSLog

struct SDKEventServerStatus: Equatable, Sendable {
    let isRunning: Bool
    let port: UInt16?
    let pairingToken: String?
    let connectedClientCount: Int

    static let stopped = SDKEventServerStatus(
        isRunning: false,
        port: nil,
        pairingToken: nil,
        connectedClientCount: 0
    )
}

protocol SDKEventServing: AnyObject {
    func status() async -> SDKEventServerStatus
    func start(port: UInt16) async throws
    func stop() async
}

actor SDKEventServer: SDKEventServing {
    private static let supportedSchemaVersions = [SDKSchema.version]

    private struct Client {
        let id: UUID
        let connection: NWConnection
        let deviceName: String
        let bundleID: String
        let selectedSchemaVersion: Int
        let clockOffsetMs: Int
        let connectedAt: Date
    }

    enum ServerError: Error {
        case invalidPort
    }

    private enum WebSocketOpcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    private let sessionStore: any SessionStore
    private let networkEventBuilder: NetworkEventBuilder
    private let annotationStore: SDKAnnotationStore?
    private let streamingClassifier: StreamingEventClassifier
    private let deliveryRatioCalculator: DeliveryRatioCalculator
    private let stallRiskMonitor: StallRiskMonitor
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.JoesProxyApp", category: "SDKEventServer")

    private var listener: NWListener?
    private var pairingToken: String?
    private var runningPort: UInt16?
    private var listenerReservation: ReservedListenerRegistry.ReservationToken?
    private var clients: [UUID: Client] = [:]
    private var sessionCancellable: AnyCancellable?
    /// Most recently parsed manifest-declared segment duration, keyed by request host.
    private var cachedSegmentDurationByHost: [String: Double] = [:]
    /// Hosts for which a manifest has already been observed, used to set `ManifestEvent.isInitial`.
    private var manifestSeenHosts: Set<String> = []

    init(
        sessionStore: any SessionStore,
        networkEventBuilder: NetworkEventBuilder = NetworkEventBuilder(),
        annotationStore: SDKAnnotationStore? = nil,
        streamingClassifier: StreamingEventClassifier = StreamingEventClassifier(),
        deliveryRatioCalculator: DeliveryRatioCalculator = DeliveryRatioCalculator(),
        stallRiskMonitor: StallRiskMonitor = StallRiskMonitor(),
        encoder: JSONEncoder = SDKEventJSONCodec.makeEncoder(),
        decoder: JSONDecoder = SDKEventJSONCodec.makeDecoder()
    ) {
        self.sessionStore = sessionStore
        self.networkEventBuilder = networkEventBuilder
        self.annotationStore = annotationStore
        self.streamingClassifier = streamingClassifier
        self.deliveryRatioCalculator = deliveryRatioCalculator
        self.stallRiskMonitor = stallRiskMonitor
        self.encoder = encoder
        self.decoder = decoder
    }

    func status() async -> SDKEventServerStatus {
        SDKEventServerStatus(
            isRunning: listener != nil,
            port: runningPort,
            pairingToken: pairingToken,
            connectedClientCount: clients.count
        )
    }

    func start(port: UInt16) async throws {
        guard port > 0 else {
            throw ServerError.invalidPort
        }
        guard listener == nil else {
            return
        }

        let token = Self.makePairingToken()
        let newListener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        newListener.service = Self.makeBonjourService(port: port)
        newListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        newListener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { await self?.handleListenerFailure(error) }
            }
        }
        listener = newListener
        pairingToken = token
        runningPort = port
        listenerReservation = ReservedListenerRegistry.shared.reserve(
            owner: "SDKEventServer",
            port: port,
            boundHost: nil
        )
        subscribeToSessionChanges()
        newListener.start(queue: DispatchQueue(label: "com.JoesProxyApp.SDKEventServer"))
        logger.info("SDK event server started on port \(port, privacy: .public) with Bonjour type _joesproxy._tcp")
    }

    func stop() async {
        sessionCancellable?.cancel()
        sessionCancellable = nil
        listener?.cancel()
        listener = nil
        ReservedListenerRegistry.shared.release(listenerReservation)
        listenerReservation = nil
        runningPort = nil
        pairingToken = nil
        clients.values.forEach { $0.connection.cancel() }
        clients.removeAll()
        await annotationStore?.clear()
        cachedSegmentDurationByHost.removeAll()
        manifestSeenHosts.removeAll()
        await stallRiskMonitor.reset()
        logger.info("SDK event server stopped")
    }

    func setPairingToken(_ token: String) {
        pairingToken = token
    }

    func handshakeAcknowledgement(for message: String) throws -> SDKMessageEnvelope<HandshakeAck> {
        try validateHandshake(message).ackEnvelope
    }

    func networkEventEnvelopes(for change: SessionStoreChange) async -> [SDKMessageEnvelope<NetworkEvent>] {
        let events = await events(for: change)
        return events.map { event in
            SDKMessageEnvelope(
                type: .networkEvent,
                version: SDKSchema.version,
                id: UUID(),
                sentAt: Date(),
                payload: event
            )
        }
    }

    func ingestAnnotationMessage(_ message: String, clockOffsetMs: Int) async throws {
        try await processClientMessage(message, clockOffsetMs: clockOffsetMs)
    }

    private func subscribeToSessionChanges() {
        sessionCancellable?.cancel()
        sessionCancellable = sessionStore.sessionChangesPublisher
            .sink { [weak self] change in
                Task { await self?.broadcast(change) }
            }
    }

    private func handleListenerFailure(_ error: NWError) async {
        logger.error("SDK event server listener failed: \(String(describing: error), privacy: .public)")
        await stop()
    }

    private func accept(_ connection: NWConnection) async {
        connection.start(queue: DispatchQueue(label: "com.JoesProxyApp.SDKEventClient"))

        do {
            try await performWebSocketUpgrade(on: connection)
            guard let text = try await receiveTextFrame(from: connection) else {
                connection.cancel()
                return
            }
            let decision = try validateHandshake(text)
            try await send(decision.ackEnvelope, to: connection)

            guard let accepted = decision.acceptedClient else {
                connection.cancel()
                return
            }

            let client = Client(
                id: UUID(),
                connection: connection,
                deviceName: accepted.deviceName,
                bundleID: accepted.bundleID,
                selectedSchemaVersion: accepted.selectedSchemaVersion,
                clockOffsetMs: accepted.clockOffsetMs,
                connectedAt: accepted.connectedAt
            )
            clients[client.id] = client
            await readClientFrames(client.id, connection: connection)
        } catch {
            connection.cancel()
        }
    }

    private func validateHandshake(_ text: String) throws -> HandshakeDecision {
        let data = Data(text.utf8)
        let header = try decoder.decode(SDKMessageHeader.self, from: data)
        let serverDate = Date()

        guard header.type == SDKMessageType.handshake.rawValue else {
            return makeRejectedHandshake(reason: .protocolError, serverDate: serverDate, clockOffsetMs: 0)
        }

        let envelope = try decoder.decode(SDKMessageEnvelope<PairingHandshake>.self, from: data)
        let handshake = envelope.payload
        let clockOffsetMs = Int(serverDate.timeIntervalSince(handshake.deviceTimestamp) * 1_000)

        guard handshake.token == pairingToken else {
            return makeRejectedHandshake(reason: .invalidToken, serverDate: serverDate, clockOffsetMs: clockOffsetMs)
        }

        let clientSupportedVersions = Set(handshake.supportedSchemaVersions + [handshake.schemaVersion])
        guard clientSupportedVersions.contains(SDKSchema.version) else {
            return makeRejectedHandshake(
                reason: .schemaVersionUnsupported,
                serverDate: serverDate,
                clockOffsetMs: clockOffsetMs,
                clientSupportedVersions: clientSupportedVersions
            )
        }

        let ack = HandshakeAck(
            accepted: true,
            rejectReason: nil,
            serverTimestamp: serverDate,
            clockOffsetMs: clockOffsetMs,
            selectedSchemaVersion: SDKSchema.version,
            supportedSchemaVersions: Self.supportedSchemaVersions,
            serverAppVersion: Bundle.main.marketingVersionOrDev,
            minimumSupportedSchemaVersion: Self.supportedSchemaVersions.min(),
            latestSupportedSchemaVersion: Self.supportedSchemaVersions.max()
        )
        let ackEnvelope = SDKMessageEnvelope(
            type: .handshakeAck,
            version: SDKSchema.version,
            id: UUID(),
            sentAt: serverDate,
            payload: ack
        )
        let client = AcceptedHandshakeClient(
            deviceName: handshake.deviceName,
            bundleID: handshake.bundleID,
            selectedSchemaVersion: SDKSchema.version,
            clockOffsetMs: clockOffsetMs,
            connectedAt: serverDate
        )
        return HandshakeDecision(ackEnvelope: ackEnvelope, acceptedClient: client)
    }

    private func makeRejectedHandshake(
        reason: SDKHandshakeRejectReason,
        serverDate: Date,
        clockOffsetMs: Int,
        clientSupportedVersions: Set<Int> = []
    ) -> HandshakeDecision {
        let compatibility = compatibilityResolution(for: clientSupportedVersions)
        let ack = HandshakeAck(
            accepted: false,
            rejectReason: reason,
            serverTimestamp: serverDate,
            clockOffsetMs: clockOffsetMs,
            selectedSchemaVersion: nil,
            supportedSchemaVersions: Self.supportedSchemaVersions,
            serverAppVersion: Bundle.main.marketingVersionOrDev,
            minimumSupportedSchemaVersion: Self.supportedSchemaVersions.min(),
            latestSupportedSchemaVersion: Self.supportedSchemaVersions.max(),
            compatibilityResolution: reason == .schemaVersionUnsupported ? compatibility : nil,
            compatibilityMessage: reason == .schemaVersionUnsupported
                ? compatibilityMessage(for: compatibility)
                : nil
        )
        let envelope = SDKMessageEnvelope(
            type: .handshakeAck,
            version: SDKSchema.version,
            id: UUID(),
            sentAt: serverDate,
            payload: ack
        )
        return HandshakeDecision(ackEnvelope: envelope, acceptedClient: nil)
    }

    private func compatibilityResolution(for clientSupportedVersions: Set<Int>) -> SDKCompatibilityResolution {
        guard let clientMinimum = clientSupportedVersions.min(),
              let clientMaximum = clientSupportedVersions.max(),
              let serverMinimum = Self.supportedSchemaVersions.min(),
              let serverMaximum = Self.supportedSchemaVersions.max() else {
            return .unknown
        }

        if clientMaximum < serverMinimum {
            return .updateSDK
        }
        if clientMinimum > serverMaximum {
            return .updateJoesProxy
        }
        return .unknown
    }

    private func compatibilityMessage(for resolution: SDKCompatibilityResolution) -> String {
        let appVersion = Bundle.main.marketingVersionOrDev
        let schemaSummary = Self.supportedSchemaVersions.map(String.init).joined(separator: ", ")

        switch resolution {
        case .updateSDK:
            return "This SDK is not compatible with JoesProxy \(appVersion). Update the JoesProxySDK package to a version that supports schema \(schemaSummary)."
        case .updateJoesProxy:
            return "This SDK requires a newer JoesProxy app than \(appVersion). Update JoesProxy to a version that supports the SDK schema."
        case .unknown:
            return "This SDK and JoesProxy \(appVersion) do not share a compatible protocol schema. Update JoesProxy and the JoesProxySDK package together."
        }
    }

    private func readClientFrames(_ clientID: UUID, connection: NWConnection) async {
        while clients[clientID] != nil {
            do {
                guard let text = try await receiveTextFrame(from: connection) else {
                    continue
                }
                guard let client = clients[clientID] else {
                    return
                }
                try await processClientMessage(text, clockOffsetMs: client.clockOffsetMs)
            } catch {
                clients[clientID] = nil
                connection.cancel()
                return
            }
        }
    }

    private func broadcast(_ change: SessionStoreChange) async {
        let envelopes = await networkEventEnvelopes(for: change)
        for envelope in envelopes {
            await broadcast(envelope)
        }
        await broadcastStreamingEvents(for: sessionsForChange(change))
    }

    private func sessionsForChange(_ change: SessionStoreChange) -> [SessionRecord] {
        switch change {
        case .appended(let session, _), .updated(let session, _):
            return [session]
        case .updatedBatch(let updatedSessions, _), .loaded(let updatedSessions, _):
            return updatedSessions
        case .bodiesStripped, .removed, .cleared:
            // Stripping only nils body bytes; the redacted metadata SDK clients
            // already received is unchanged, so there is nothing to re-broadcast.
            return []
        }
    }

    private func events(for change: SessionStoreChange) async -> [NetworkEvent] {
        let sessions = sessionsForChange(change)
        var events: [NetworkEvent] = []
        for session in sessions {
            let labels = await annotationStore?.activeLabels(at: session.timing.startedAt) ?? []
            events.append(networkEventBuilder.build(session: session, activeAnnotations: labels))
        }
        return events
    }

    private func broadcastStreamingEvents(for sessions: [SessionRecord]) async {
        for session in sessions {
            guard session.state == .completed,
                  let kind = streamingClassifier.classify(session: session) else {
                continue
            }
            switch kind {
            case .manifest(let format):
                await handleManifest(format: format, session: session)
            case .segment:
                await handleSegment(session: session)
            case .drmLicense(let system):
                await handleDRMLicense(system: system, session: session)
            }
        }
    }

    private func handleManifest(format: String, session: SessionRecord) async {
        let host = session.request.host
        if let duration = parsedSegmentDuration(format: format, session: session) {
            cachedSegmentDurationByHost[host] = duration
        }
        let isInitial = !manifestSeenHosts.contains(host)
        manifestSeenHosts.insert(host)

        let event = ManifestEvent(
            sessionID: session.id,
            timestamp: session.timing.completedAt ?? session.timing.startedAt,
            url: NetworkEventBuilder.eventURL(for: session.request),
            format: format,
            isInitial: isInitial,
            durationSeconds: session.timing.duration,
            statusCode: session.response?.statusCode
        )
        await broadcast(SDKMessageEnvelope(
            type: .manifestEvent,
            version: SDKSchema.version,
            id: UUID(),
            sentAt: Date(),
            payload: event
        ))
    }

    private func handleSegment(session: SessionRecord) async {
        let cachedDuration = cachedSegmentDurationByHost[session.request.host]
        let ratio = deliveryRatioCalculator.ratio(session: session, cachedSegmentDuration: cachedDuration)

        let event = StreamingSegmentEvent(
            sessionID: session.id,
            timestamp: session.timing.completedAt ?? session.timing.startedAt,
            url: NetworkEventBuilder.eventURL(for: session.request),
            lane: TimelineLane.mediaSegments.rawValue,
            byteCount: session.response?.bodySize ?? session.response?.bodyData?.count,
            durationSeconds: session.timing.duration,
            segmentDurationSeconds: cachedDuration,
            deliveryRatio: ratio,
            httpProtocol: session.request.inspectionKind == .tunneledTLS ? "CONNECT" : "HTTP/1.1",
            statusCode: session.response?.statusCode
        )
        await broadcast(SDKMessageEnvelope(
            type: .streamingSegmentEvent,
            version: SDKSchema.version,
            id: UUID(),
            sentAt: Date(),
            payload: event
        ))

        guard let ratio else { return }
        if let stallEvent = await stallRiskMonitor.record(ratio: ratio) {
            await broadcast(SDKMessageEnvelope(
                type: .stallRiskEvent,
                version: SDKSchema.version,
                id: UUID(),
                sentAt: Date(),
                payload: stallEvent
            ))
        }
    }

    private func handleDRMLicense(system: String?, session: SessionRecord) async {
        let eventTime = session.timing.completedAt ?? session.timing.startedAt
        var relativeMs: Int?
        if let playbackStart = await annotationStore?.nearestPlaybackStart(to: eventTime) {
            relativeMs = Int(eventTime.timeIntervalSince(playbackStart) * 1_000)
        }

        let event = DRMLicenseEvent(
            sessionID: session.id,
            timestamp: eventTime,
            url: NetworkEventBuilder.eventURL(for: session.request),
            drmSystem: system,
            relativeToPlaybackStartMs: relativeMs,
            statusCode: session.response?.statusCode,
            durationSeconds: session.timing.duration
        )
        await broadcast(SDKMessageEnvelope(
            type: .drmLicenseEvent,
            version: SDKSchema.version,
            id: UUID(),
            sentAt: Date(),
            payload: event
        ))
    }

    /// Parses a manifest response body to extract the declared segment duration in seconds.
    /// Returns nil when the body cannot be decoded or no duration can be determined.
    private func parsedSegmentDuration(format: String, session: SessionRecord) -> Double? {
        guard let bodyData = session.response?.bodyData,
              let text = String(data: bodyData, encoding: .utf8) else {
            return nil
        }

        if format == "DASH" {
            guard let manifest = DASHParser.parse(text) else { return nil }
            for period in manifest.periods {
                for adaptationSet in period.adaptationSets {
                    if let duration = segmentDuration(from: adaptationSet.segmentTemplate) {
                        return duration
                    }
                    for representation in adaptationSet.representations {
                        if let duration = segmentDuration(from: representation.segmentTemplate) {
                            return duration
                        }
                    }
                }
            }
            return nil
        }

        let manifest = HLSParser.parse(text, baseURL: nil)
        if let targetDuration = manifest.targetDuration, targetDuration > 0 {
            return targetDuration
        }
        let segmentDurations = manifest.segments.compactMap(\.duration)
        guard !segmentDurations.isEmpty else { return nil }
        return segmentDurations.reduce(0, +) / Double(segmentDurations.count)
    }

    private func segmentDuration(from template: DASHSegmentTemplate?) -> Double? {
        guard let template, let duration = template.duration, let timescale = template.timescale, timescale > 0 else {
            return nil
        }
        return Double(duration) / Double(timescale)
    }

    private func processClientMessage(_ text: String, clockOffsetMs: Int) async throws {
        let data = Data(text.utf8)
        let header = try decoder.decode(SDKMessageHeader.self, from: data)
        guard header.type == SDKMessageType.annotationEvent.rawValue else {
            return
        }

        let envelope = try decoder.decode(SDKMessageEnvelope<AnnotationEvent>.self, from: data)
        await annotationStore?.add(envelope.payload, clockOffsetMs: clockOffsetMs)
    }

    private func broadcast<Payload>(_ envelope: SDKMessageEnvelope<Payload>) async {
        let clientIDs = Array(clients.keys)
        for clientID in clientIDs {
            guard let client = clients[clientID] else { continue }
            do {
                try await send(envelope, to: client.connection)
            } catch {
                clients[clientID] = nil
                client.connection.cancel()
            }
        }
    }

    private func performWebSocketUpgrade(on connection: NWConnection) async throws {
        let data = try await receiveHTTPRequestHeader(from: connection)
        guard let request = String(data: data, encoding: .utf8),
              let key = Self.webSocketKey(in: request) else {
            try await sendRaw(Self.httpResponse(status: "400 Bad Request"), to: connection)
            throw WebSocketError.invalidUpgrade
        }

        let accept = Self.webSocketAccept(for: key)
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r
        """
        try await sendRaw(Data(response.utf8), to: connection)
    }

    private func receiveHTTPRequestHeader(from connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while buffer.count < 65_536 {
            let data = try await receiveData(from: connection, minimumLength: 1, maximumLength: 4_096)
            buffer.append(data)
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                return buffer
            }
        }
        throw WebSocketError.invalidUpgrade
    }

    private func receiveTextFrame(from connection: NWConnection) async throws -> String? {
        let header = try await receiveData(from: connection, minimumLength: 2, maximumLength: 2)
        guard header.count == 2 else {
            throw WebSocketError.invalidFrame
        }

        let first = header[header.startIndex]
        let second = header[header.index(after: header.startIndex)]
        let opcode = WebSocketOpcode(rawValue: first & 0x0F)
        let isMasked = (second & 0x80) != 0
        var payloadLength = Int(second & 0x7F)

        if payloadLength == 126 {
            let lengthBytes = try await receiveData(from: connection, minimumLength: 2, maximumLength: 2)
            payloadLength = Int(UInt16(lengthBytes[0]) << 8 | UInt16(lengthBytes[1]))
        } else if payloadLength == 127 {
            throw WebSocketError.unsupportedFrame
        }

        let maskKey = isMasked
            ? try await receiveData(from: connection, minimumLength: 4, maximumLength: 4)
            : Data()
        var payload = payloadLength > 0
            ? try await receiveData(from: connection, minimumLength: payloadLength, maximumLength: payloadLength)
            : Data()

        if isMasked {
            for index in payload.indices {
                let maskIndex = payload.distance(from: payload.startIndex, to: index) % 4
                payload[index] ^= maskKey[maskKey.index(maskKey.startIndex, offsetBy: maskIndex)]
            }
        }

        switch opcode {
        case .text:
            guard let text = String(data: payload, encoding: .utf8) else {
                throw WebSocketError.invalidFrame
            }
            return text
        case .close:
            throw WebSocketError.closed
        case .ping:
            try await sendRaw(Self.makeFrame(opcode: .pong, payload: payload), to: connection)
            return nil
        default:
            throw WebSocketError.unsupportedFrame
        }
    }

    private func send<Payload>(_ envelope: SDKMessageEnvelope<Payload>, to connection: NWConnection) async throws {
        let data = try encoder.encode(envelope)
        try await sendRaw(Self.makeFrame(opcode: .text, payload: data), to: connection)
    }

    private func receiveData(
        from connection: NWConnection,
        minimumLength: Int,
        maximumLength: Int
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minimumLength, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: WebSocketError.closed)
                } else {
                    continuation.resume(throwing: WebSocketError.invalidFrame)
                }
            }
        }
    }

    private func sendRaw(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func makeFrame(opcode: WebSocketOpcode, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode.rawValue)

        if payload.count <= 125 {
            frame.append(UInt8(payload.count))
        } else {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        }

        frame.append(payload)
        return frame
    }

    private static func makePairingToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeBonjourService(port: UInt16) -> NWListener.Service {
        NWListener.Service(
            name: "JoesProxy on \(ProcessInfo.processInfo.hostName)",
            type: "_joesproxy._tcp",
            domain: nil,
            txtRecord: NWTXTRecord([
                "version": String(SDKSchema.version),
                "sdkPort": String(port),
                "profilePath": "profile"
            ])
        )
    }

    private static func webSocketKey(in request: String) -> String? {
        request
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func webSocketAccept(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func httpResponse(status: String) -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\n\r\n".utf8)
    }
}

private struct AcceptedHandshakeClient {
    let deviceName: String
    let bundleID: String
    let selectedSchemaVersion: Int
    let clockOffsetMs: Int
    let connectedAt: Date
}

private struct HandshakeDecision {
    let ackEnvelope: SDKMessageEnvelope<HandshakeAck>
    let acceptedClient: AcceptedHandshakeClient?
}

private enum WebSocketError: Error {
    case invalidUpgrade
    case invalidFrame
    case unsupportedFrame
    case closed
}
