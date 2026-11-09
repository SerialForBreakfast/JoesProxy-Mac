import Foundation
import OSLog

private let tvOSDiscoveryLogger = Logger(subsystem: "com.ShowBlender.JoesProxyTV", category: "BonjourDiscovery")
private let tvOSTransportLogger = Logger(subsystem: "com.ShowBlender.JoesProxyTV", category: "SDKTransport")

// MARK: - Bonjour discovery

/// Discovers a JoesProxy instance on the local network using Bonjour (_joesproxy._tcp).
///
/// Requires NSLocalNetworkUsageDescription and NSBonjourServices → _joesproxy._tcp in Info.plist.
struct TVOSBonjourDiscoveryService: TVOSProxyDiscoveryServicing {
    let timeout: TimeInterval

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    func discover() async -> [TVOSDiscoveredProxy] {
        let t = timeout
        tvOSDiscoveryLogger.info("Bonjour discovery requested timeout=\(t, privacy: .public)")
        return await withCheckedContinuation { continuation in
            // Bonjour APIs require the main thread; hop via Task(@MainActor).
            Task { @MainActor in
                BonjourDiscoverySession.launch(timeout: t) { proxies in
                    tvOSDiscoveryLogger.info("Bonjour discovery returning proxyCount=\(proxies.count, privacy: .public)")
                    continuation.resume(returning: proxies)
                }
            }
        }
    }
}

/// Bridges NetServiceBrowser delegate callbacks to a Swift continuation.
///
/// The session retains itself (`selfRetain`) from `launch` until `finish` so the
/// NetServiceBrowser's weak delegate reference doesn't orphan it mid-discovery.
@MainActor
private final class BonjourDiscoverySession: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private let timeout: TimeInterval
    private let completion: ([TVOSDiscoveredProxy]) -> Void
    private var found: [TVOSDiscoveredProxy] = []
    private var resolvingServices: [NetService] = []
    private var pendingResolutionCount = 0
    private var finished = false
    private var selfRetain: BonjourDiscoverySession?

    private init(timeout: TimeInterval, completion: @escaping ([TVOSDiscoveredProxy]) -> Void) {
        self.timeout = timeout
        self.completion = completion
        super.init()
        browser.delegate = self
    }

    /// Creates, retains, and starts a session. The session releases itself when done.
    static func launch(timeout: TimeInterval, completion: @escaping ([TVOSDiscoveredProxy]) -> Void) {
        let session = BonjourDiscoverySession(timeout: timeout, completion: completion)
        session.selfRetain = session
        session.start()
    }

    private func start() {
        tvOSDiscoveryLogger.info("Bonjour session starting type=_joesproxy._tcp. domain=local.")
        browser.searchForServices(ofType: "_joesproxy._tcp.", inDomain: "local.")
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(reason: "timeout")
        }
    }

    private func finish(reason: String) {
        guard !finished else { return }
        finished = true
        browser.stop()
        resolvingServices.forEach { $0.delegate = nil }
        resolvingServices.removeAll()
        let result = found
        tvOSDiscoveryLogger.info(
            "Bonjour session finished reason=\(reason, privacy: .public) proxyCount=\(result.count, privacy: .public)"
        )
        selfRetain = nil  // release after capturing result
        completion(result)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        tvOSDiscoveryLogger.info(
            "Bonjour service found name=\(service.name, privacy: .public) type=\(service.type, privacy: .public) domain=\(service.domain, privacy: .public) moreComing=\(moreComing, privacy: .public)"
        )
        resolvingServices.append(service)
        pendingResolutionCount += 1
        service.delegate = self
        service.resolve(withTimeout: timeout)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let txt = TVOSTXTRecord(data: sender.txtRecordData())
        pendingResolutionCount = max(0, pendingResolutionCount - 1)
        guard let host = sender.hostName else {
            tvOSDiscoveryLogger.warning("Bonjour service resolved without host name name=\(sender.name, privacy: .public)")
            return
        }

        let proxy = TVOSDiscoveredProxy(
            name: sender.name,
            host: host,
            proxyPort: sender.port,
            profilePort: 8765,
            sdkPort: txt.sdkPort,
            profilePath: txt.profilePath ?? "profile"
        )
        found.append(proxy)
        tvOSDiscoveryLogger.info(
            "Bonjour service resolved name=\(sender.name, privacy: .public) host=\(host, privacy: .public) servicePort=\(sender.port, privacy: .public) sdkPort=\(txt.sdkPort ?? 0, privacy: .public) profilePath=\(proxy.profilePath, privacy: .public)"
        )
        finish(reason: "resolved")
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pendingResolutionCount = max(0, pendingResolutionCount - 1)
        tvOSDiscoveryLogger.warning(
            "Bonjour service failed to resolve name=\(sender.name, privacy: .public) errors=\(String(describing: errorDict), privacy: .public) pending=\(self.pendingResolutionCount, privacy: .public)"
        )
        if pendingResolutionCount == 0, !found.isEmpty {
            finish(reason: "resolvedAfterFailures")
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        tvOSDiscoveryLogger.error("Bonjour browser did not search errors=\(String(describing: errorDict), privacy: .public)")
        finish(reason: "browserDidNotSearch")
    }
}

private struct TVOSTXTRecord {
    let values: [String: String]

    init(data: Data?) {
        guard let data else { values = [:]; return }
        let dict = NetService.dictionary(fromTXTRecord: data)
        values = dict.reduce(into: [:]) { result, entry in
            result[entry.key] = String(data: entry.value, encoding: .utf8)
        }
    }

    var sdkPort: Int? { values["sdkPort"].flatMap(Int.init) }
    var profilePath: String? { values["profilePath"] }
}

// MARK: - Live WebSocket transport

/// Live transport that connects to the Mac via WebSocket, completes the pairing handshake,
/// and collects incoming SDK message headers.
actor TVOSLiveProxyTransport: TVOSProxyTransporting {
    private var webSocketTask: URLSessionWebSocketTask?
    private var receivedMessages: [Data] = []
    private var receiveLoopTask: Task<Void, Never>?

    func connect(to proxy: TVOSDiscoveredProxy, pairingToken: String?) async -> TVOSProxyConnectionState {
        let port = proxy.sdkPort ?? 9091
        guard let url = URL(string: "ws://\(proxy.host):\(port)/") else {
            tvOSTransportLogger.error("WebSocket URL construction failed host=\(proxy.host, privacy: .public) port=\(port, privacy: .public)")
            return .rejected("Invalid WebSocket URL for \(proxy.host):\(port)")
        }

        tvOSTransportLogger.info(
            "WebSocket connect requested host=\(proxy.host, privacy: .public) port=\(port, privacy: .public) tokenPresent=\((pairingToken?.isEmpty == false), privacy: .public)"
        )
        await cancelReceiveLoop()
        receivedMessages = []

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        do {
            try await sendHandshake(task: task, token: pairingToken ?? "")
            let accepted = try await receiveHandshakeAck(task: task)
            guard accepted else {
                task.cancel(with: .normalClosure, reason: nil)
                tvOSTransportLogger.warning("WebSocket pairing rejected host=\(proxy.host, privacy: .public) port=\(port, privacy: .public)")
                return .rejected("Pairing rejected by Mac")
            }
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            tvOSTransportLogger.error("WebSocket connect failed host=\(proxy.host, privacy: .public) port=\(port, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return .rejected(error.localizedDescription)
        }

        startReceiveLoop(task: task)
        tvOSTransportLogger.info("WebSocket connected host=\(proxy.host, privacy: .public) port=\(port, privacy: .public)")
        return .connected(proxy)
    }

    func disconnect() async {
        tvOSTransportLogger.info("WebSocket disconnect requested")
        await cancelReceiveLoop()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    func collectedEvents() async -> [TVOSSDKMessageHeader] {
        receivedMessages.compactMap { data in
            try? TVOSSDKEventJSONCodec.makeDecoder().decode(TVOSSDKMessageHeader.self, from: data)
        }
    }

    func collectedNetworkEvents() async -> [TVOSObservedNetworkEvent] {
        receivedMessages.compactMap(TVOSNetworkEventObservation.parseEnvelopeJSON)
    }

    // MARK: - Private

    private func sendHandshake(task: URLSessionWebSocketTask, token: String) async throws {
        let now = isoDate(Date())
        let envelope: [String: Any] = [
            "type": "handshake",
            "version": 1,
            "id": UUID().uuidString,
            "sentAt": now,
            "payload": [
                "token": token,
                "deviceName": ProcessInfo.processInfo.hostName,
                "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
                "deviceTimestamp": now,
                "sdkVersion": "0.1.0",
                "schemaVersion": 1,
                "supportedSchemaVersions": [1]
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        tvOSTransportLogger.info(
            "WebSocket sending handshake tokenPresent=\(!token.isEmpty, privacy: .public) payloadBytes=\(data.count, privacy: .public)"
        )
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveHandshakeAck(task: URLSessionWebSocketTask) async throws -> Bool {
        let message = try await task.receive()
        guard case .string(let text) = message,
              let data = text.data(using: .utf8) else {
            throw TVOSLiveTransportError.unexpectedMessageFormat
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let payload = json?["payload"] as? [String: Any],
              let accepted = payload["accepted"] as? Bool else {
            throw TVOSLiveTransportError.malformedAck
        }
        let rejectReason = payload["rejectReason"] as? String
        tvOSTransportLogger.info(
            "WebSocket received handshake ack accepted=\(accepted, privacy: .public) rejectReason=\(rejectReason ?? "none", privacy: .public)"
        )
        return accepted
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        tvOSTransportLogger.info("WebSocket receive loop starting")
        receiveLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    let message = try await task.receive()
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8) {
                        await self.appendMessage(data)
                        if let header = try? TVOSSDKEventJSONCodec.makeDecoder().decode(
                            TVOSSDKMessageHeader.self,
                            from: data
                        ) {
                            tvOSTransportLogger.info(
                                "WebSocket received SDK message type=\(header.type, privacy: .public) version=\(header.version, privacy: .public)"
                            )
                        } else {
                            tvOSTransportLogger.warning("WebSocket received unhandled message")
                        }
                    } else {
                        tvOSTransportLogger.warning("WebSocket received unhandled message")
                    }
                } catch {
                    tvOSTransportLogger.warning("WebSocket receive loop stopped error=\(error.localizedDescription, privacy: .public)")
                    break
                }
            }
        }
    }

    private func cancelReceiveLoop() async {
        if receiveLoopTask != nil {
            tvOSTransportLogger.info("WebSocket receive loop cancelling")
        }
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
    }

    private func appendMessage(_ data: Data) {
        receivedMessages.append(data)
    }

    private func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private enum TVOSLiveTransportError: Error {
    case unexpectedMessageFormat
    case malformedAck
}

// MARK: - Live annotation sender

/// Sends annotation events to the Mac via the live WebSocket transport.
struct TVOSLiveAnnotationSender: TVOSAnnotationSending {
    private let transport: TVOSLiveProxyTransport

    init(transport: TVOSLiveProxyTransport) {
        self.transport = transport
    }

    func record(_ annotation: TVOSAnnotationDraft) async {
        await transport.sendAnnotation(annotation)
    }
}

extension TVOSLiveProxyTransport {
    func sendAnnotation(_ annotation: TVOSAnnotationDraft) async {
        guard let task = webSocketTask else {
            tvOSTransportLogger.warning("Skipping annotation send because WebSocket is disconnected kind=\(annotation.kind.rawValue, privacy: .public)")
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let envelope: [String: Any] = [
            "type": "annotationEvent",
            "version": 1,
            "id": UUID().uuidString,
            "sentAt": formatter.string(from: Date()),
            "payload": [
                "id": annotation.id.uuidString,
                "scopeID": NSNull(),
                "label": annotation.label,
                "kind": "feature",
                "lifecycle": "instant",
                "metadata": annotation.metadata,
                "deviceTimestamp": formatter.string(from: annotation.deviceTimestamp)
            ] as [String: Any]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            tvOSTransportLogger.error("Failed to encode annotation kind=\(annotation.kind.rawValue, privacy: .public)")
            return
        }
        do {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
            tvOSTransportLogger.info("Sent annotation kind=\(annotation.kind.rawValue, privacy: .public) bytes=\(data.count, privacy: .public)")
        } catch {
            tvOSTransportLogger.error("Failed to send annotation kind=\(annotation.kind.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Live facade

/// Production SDK facade used by the tvOS app in release and debug builds.
struct TVOSLiveProxySDKClient: TVOSProxySDKFacading {
    let discoveryService: any TVOSProxyDiscoveryServicing
    let transport: any TVOSProxyTransporting
    let setupProbe: any TVOSProxySetupProbing
    let annotationSender: any TVOSAnnotationSending

    init(discoveryTimeout: TimeInterval = 5) {
        let liveTransport = TVOSLiveProxyTransport()
        discoveryService = TVOSBonjourDiscoveryService(timeout: discoveryTimeout)
        transport = liveTransport
        setupProbe = TVOSReachabilitySetupProbe()
        annotationSender = TVOSLiveAnnotationSender(transport: liveTransport)
    }
}
