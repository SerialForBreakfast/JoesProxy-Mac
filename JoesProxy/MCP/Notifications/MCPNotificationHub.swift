import Combine
import Foundation

/// Main-actor hub that owns subscription state, bounded queues, and live SSE writers.
///
/// Concurrency: `@MainActor` — coordinates with policy, capture, and operation stores on the main actor.
/// SSE writes hop to the channel event loop via ``MCPSSEWriter``.
@MainActor
final class MCPNotificationHub: ObservableObject {
    struct WriterRegistration {
        var key: MCPLogicalSessionKey
        var writer: MCPSSEWriting
        var heartbeatTask: Task<Void, Never>?
    }

    private var registry = MCPSubscriptionRegistry()
    private var queues: [MCPLogicalSessionKey: MCPNotificationQueue] = [:]
    private var writers: [MCPLogicalSessionKey: WriterRegistration] = [:]
    private var lastNotifiedProgress: [String: Double] = [:]
    private var lastNotifiedStage: [String: String] = [:]
    private var sessionChangesCancellable: AnyCancellable?

    /// Published for title-bar operation projection when live SSE probe streams connect/disconnect.
    @Published private(set) var liveListenStreamCount: Int = 0

    private let policyStore: MCPPolicyStore
    private let auditStore: MCPAuditStore
    private let snapshotService: MCPSessionSnapshotService
    private let heartbeatInterval: TimeInterval
    private let encoder = JSONEncoder()

    init(
        sessionStore: any SessionStore,
        policyStore: MCPPolicyStore,
        auditStore: MCPAuditStore,
        snapshotService: MCPSessionSnapshotService,
        heartbeatInterval: TimeInterval = MCPServerLimits.sseHeartbeatInterval
    ) {
        self.policyStore = policyStore
        self.auditStore = auditStore
        self.snapshotService = snapshotService
        self.heartbeatInterval = heartbeatInterval
        encoder.dateEncodingStrategy = .iso8601
        sessionChangesCancellable = sessionStore.sessionChangesPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                self?.handleSessionStoreChange(change)
            }
    }

    var subscribedSessionCount: Int {
        registry.activeSessionCount
    }

    private func refreshLiveListenStreamCount() {
        liveListenStreamCount = writers.count
    }

    func subscribe(key: MCPLogicalSessionKey, uri: String) throws {
        guard MCPSubscriptionResource.isAllowed(uri) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown subscription resource: \(uri)")
        }
        registry.subscribe(key, uri: uri)
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .resourceRead,
                timestamp: Date(),
                clientID: key.clientID,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "subscribe:\(uri)",
                detail: nil
            )
        )
        flushQueue(for: key)
    }

    func unsubscribe(key: MCPLogicalSessionKey, uri: String) {
        registry.unsubscribe(key, uri: uri)
        if registry.subscribedURIs(for: key).isEmpty {
            queues.removeValue(forKey: key)
        }
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .resourceRead,
                timestamp: Date(),
                clientID: key.clientID,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: "unsubscribe:\(uri)",
                detail: nil
            )
        )
    }

    func registerWriter(key: MCPLogicalSessionKey, writer: MCPSSEWriting) {
        if let existing = writers[key] {
            existing.heartbeatTask?.cancel()
            existing.writer.close()
        }
        let heartbeatTask = startHeartbeat(for: writer)
        writers[key] = WriterRegistration(key: key, writer: writer, heartbeatTask: heartbeatTask)
        refreshLiveListenStreamCount()
        flushQueue(for: key)
    }

    func unregisterWriter(key: MCPLogicalSessionKey, writer: MCPSSEWriting? = nil, removeSubscriptions: Bool = true) {
        guard let registration = writers[key] else { return }
        if let writer, registration.writer !== writer { return }
        writers.removeValue(forKey: key)
        registration.heartbeatTask?.cancel()
        registration.writer.close()
        queues.removeValue(forKey: key)
        let prefix = "\(key.clientID):\(key.mcpSessionID):"
        lastNotifiedProgress = lastNotifiedProgress.filter { !$0.key.hasPrefix(prefix) }
        lastNotifiedStage = lastNotifiedStage.filter { !$0.key.hasPrefix(prefix) }
        if removeSubscriptions {
            registry.removeSession(key)
        }
        refreshLiveListenStreamCount()
    }

    /// Graceful-shutdown-only teardown: unlike `unregisterWriter`, this actually waits for every
    /// writer's underlying channel close to complete (`closeAndWait()`) before returning, so the
    /// caller can safely proceed to tear down the event-loop group without racing a still-scheduled
    /// close.
    func closeAllWriters() async {
        let keys = Array(writers.keys)
        for key in keys {
            guard let registration = writers[key] else { continue }
            writers.removeValue(forKey: key)
            registration.heartbeatTask?.cancel()
            await registration.writer.closeAndWait()
            queues.removeValue(forKey: key)
            let prefix = "\(key.clientID):\(key.mcpSessionID):"
            lastNotifiedProgress = lastNotifiedProgress.filter { !$0.key.hasPrefix(prefix) }
            lastNotifiedStage = lastNotifiedStage.filter { !$0.key.hasPrefix(prefix) }
        }
        registry.removeAll()
        queues.removeAll()
        refreshLiveListenStreamCount()
    }

    func invalidateSession(_ key: MCPLogicalSessionKey, reason: String) {
        enqueueInvalidation(for: key, uri: nil, reason: reason)
        unregisterWriter(key: key, removeSubscriptions: true)
    }

    func invalidateAllSessions(reason: String) {
        let captureEpoch = snapshotService.captureEpoch
        let policyRevision = policyStore.policyRevision
        let keys = Set(writers.keys).union(registry.allKeys)
        for key in keys {
            enqueue(
                .resourceInvalidated(
                    uri: nil,
                    reason: reason,
                    captureEpoch: captureEpoch,
                    policyRevision: policyRevision,
                    droppedEventCount: takeDroppedCount(for: key)
                ),
                for: key
            )
            unregisterWriter(key: key, removeSubscriptions: true)
        }
        registry.removeAll()
        queues.removeAll()
    }

    func publishCaptureUpdates() {
        for uri in MCPSubscriptionResource.allowedURIs {
            for key in registry.sessionsSubscribed(to: uri) {
                enqueue(.resourceUpdated(uri: uri, droppedEventCount: takeDroppedCount(for: key)), for: key)
            }
        }
    }

    func publishToolsListChanged(clientID: String) {
        let keys = Set(writers.keys).union(registry.allKeys).filter { $0.clientID == clientID }
        for key in keys {
            enqueue(.toolsListChanged, for: key)
        }
    }

    func publishOperationUpdate(
        key: MCPLogicalSessionKey,
        descriptor: MCPOperationDescriptorDTO,
        isTerminal: Bool
    ) {
        let progressKey = progressTrackingKey(key: key, operationID: descriptor.operationID)
        if !isTerminal {
            let stage = descriptor.currentStage ?? ""
            let progress = descriptor.progress
            let priorStage = lastNotifiedStage[progressKey]
            let priorProgress = lastNotifiedProgress[progressKey] ?? -1
            let stageChanged = priorStage != stage
            let progressDelta = abs(progress - priorProgress)
            guard stageChanged || progressDelta >= MCPServerLimits.operationNotificationProgressDelta else {
                return
            }
            lastNotifiedStage[progressKey] = stage
            lastNotifiedProgress[progressKey] = progress
        } else {
            lastNotifiedStage.removeValue(forKey: progressKey)
            lastNotifiedProgress.removeValue(forKey: progressKey)
        }
        enqueue(
            .operationUpdated(operationID: descriptor.operationID, descriptor: descriptor, isTerminal: isTerminal),
            for: key
        )
    }

    private func handleSessionStoreChange(_ change: SessionStoreChange) {
        switch change {
        case .appended, .updated, .updatedBatch:
            publishCaptureUpdates()
        case .removed, .bodiesStripped:
            publishCaptureUpdates()
            broadcastInvalidation(reason: "capture_mutated")
        case .cleared:
            invalidateAllSessions(reason: "capture_cleared")
        case .loaded(_, let reason):
            invalidateAllSessions(reason: reason)
        }
    }

    private func broadcastInvalidation(reason: String) {
        let captureEpoch = snapshotService.captureEpoch
        let policyRevision = policyStore.policyRevision
        for key in registry.allKeys {
            enqueue(
                .resourceInvalidated(
                    uri: nil,
                    reason: reason,
                    captureEpoch: captureEpoch,
                    policyRevision: policyRevision,
                    droppedEventCount: takeDroppedCount(for: key)
                ),
                for: key
            )
        }
    }

    private func enqueueInvalidation(for key: MCPLogicalSessionKey, uri: String?, reason: String) {
        enqueue(
            .resourceInvalidated(
                uri: uri,
                reason: reason,
                captureEpoch: snapshotService.captureEpoch,
                policyRevision: policyStore.policyRevision,
                droppedEventCount: takeDroppedCount(for: key)
            ),
            for: key
        )
    }

    private func enqueue(_ event: MCPNotificationEvent, for key: MCPLogicalSessionKey) {
        var queue = notificationQueue(for: key)
        queue.enqueue(event)
        queues[key] = queue
        flushQueue(for: key)
    }

    private func notificationQueue(for key: MCPLogicalSessionKey) -> MCPNotificationQueue {
        queues[key, default: MCPNotificationQueue()]
    }

    /// Reads and clears the session's accumulated drop count in one step, writing the now-zeroed
    /// queue back. Every call site that embeds `droppedEventCount` in an event must use this
    /// instead of reading `accumulatedDroppedCount` directly, so a given drop is reported exactly
    /// once instead of being re-reported on every later notification (or, for `publishCaptureUpdates`,
    /// silently hidden by a hardcoded `0`).
    private func takeDroppedCount(for key: MCPLogicalSessionKey) -> Int {
        var queue = notificationQueue(for: key)
        let count = queue.takeDroppedCount()
        queues[key] = queue
        return count
    }

    private func flushQueue(for key: MCPLogicalSessionKey) {
        guard let registration = writers[key] else { return }
        var queue = notificationQueue(for: key)
        let events = queue.drain()
        queues[key] = queue
        for event in events {
            let payload = notificationPayload(for: event, key: key)
            let delivered = registration.writer.writeSSE(jsonObject: payload)
            if !delivered {
                auditBackpressure(clientID: key.clientID, reason: "notification_backpressure")
                var requeue = notificationQueue(for: key)
                requeue.enqueue(event)
                queues[key] = requeue
                unregisterWriter(key: key, removeSubscriptions: true)
                return
            }
        }
    }

    private func notificationPayload(for event: MCPNotificationEvent, key: MCPLogicalSessionKey) -> [String: Any] {
        switch event {
        case .toolsListChanged:
            return [
                "jsonrpc": "2.0",
                "method": "notifications/tools/list_changed",
                "params": [:] as [String: Any]
            ]
        case .resourceUpdated(let uri, let droppedEventCount):
            var params: [String: Any] = [
                "uri": uri,
                "captureHighWaterSequence": snapshotService.highWaterSequence
            ]
            if droppedEventCount > 0 {
                params["droppedEventCount"] = droppedEventCount
            }
            return [
                "jsonrpc": "2.0",
                "method": "notifications/resources/updated",
                "params": params
            ]
        case .operationUpdated(_, let descriptor, let isTerminal):
            let dto = MCPOperationNotificationDTO(
                descriptor: descriptor,
                includeResult: isTerminal,
                droppedEventCount: takeDroppedCount(for: key)
            )
            let envelope = MCPDTOEnvelope(payload: dto)
            let payloadData = (try? encoder.encode(envelope)) ?? Data()
            let payloadObject = (try? JSONSerialization.jsonObject(with: payloadData)) ?? [:]
            return [
                "jsonrpc": "2.0",
                "method": "notifications/joesproxy/operation_updated",
                "params": payloadObject
            ]
        case .resourceInvalidated(let uri, let reason, let captureEpoch, let policyRevision, let droppedEventCount):
            let dto = MCPResourceInvalidationDTO(
                uri: uri,
                reason: reason,
                captureEpoch: captureEpoch,
                policyRevision: policyRevision,
                droppedEventCount: droppedEventCount
            )
            let envelope = MCPDTOEnvelope(payload: dto)
            let payloadData = (try? encoder.encode(envelope)) ?? Data()
            let payloadObject = (try? JSONSerialization.jsonObject(with: payloadData)) ?? [:]
            return [
                "jsonrpc": "2.0",
                "method": "notifications/joesproxy/resource_invalidated",
                "params": payloadObject
            ]
        }
    }

    private func startHeartbeat(for writer: MCPSSEWriting) -> Task<Void, Never> {
        Task { [interval = heartbeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if !writer.writeComment("keepalive") {
                    break
                }
            }
        }
    }

    private func progressTrackingKey(key: MCPLogicalSessionKey, operationID: String) -> String {
        "\(key.clientID):\(key.mcpSessionID):\(operationID)"
    }

    private func auditBackpressure(clientID: String, reason: String) {
        auditStore.record(
            MCPAuditEvent(
                id: UUID(),
                kind: .internalFailure,
                timestamp: Date(),
                clientID: clientID,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: reason,
                detail: nil
            )
        )
    }
}
