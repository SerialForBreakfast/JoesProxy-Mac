import Foundation

enum MCPAuditEventKind: String, Equatable, Sendable, Codable {
    case authenticationFailure
    case authenticationSuccess
    case resourceRead
    case toolCall
    case policyDenied
    case rateLimited
    case internalFailure
    case proposalCreated
    case proposalApplied
    case proposalRejected
    case mutationConflict
    case ruleEnabled
    case ruleDisabled
    case ruleDeleted
    case throttleChanged
    case openWorldExecuted
    case openWorldDenied
    case liveProbeStarted
    case returnToNormal
    case grantAdded
    case grantRemoved
    case grantExpired
    case alwaysDenied
    case destructiveAction
    case sessionTerminated
    case freshLaunchReset
}

/// Sanitized audit record; never stores raw bearer tokens.
struct MCPAuditEvent: Equatable, Sendable, Codable, Identifiable {
    var id: UUID
    var kind: MCPAuditEventKind
    var timestamp: Date
    var clientID: String?
    var credentialFingerprint: String?
    var sourceProcess: String?
    var reasonCode: String
    var detail: String?
    /// Explicit, operator-actionable classification used by system notifications. Most policy
    /// denials are ordinary validation failures and intentionally leave this nil.
    var operatorAttention: MCPOperatorAttention? = nil
    /// Present when the event was recorded on an isolated self-validation lane (AI-5).
    var validationRunID: String?
}

/// Aggregated repetitive bad-auth record to prevent store exhaustion.
struct MCPAuditAggregate: Equatable, Sendable, Codable, Identifiable {
    var id: String
    var kind: MCPAuditEventKind
    var reasonCode: String
    var credentialFingerprint: String?
    var firstSeen: Date
    var lastSeen: Date
    var count: Int
}

/// Bounded audit store with aggregation and fail-closed persistence semantics.
///
/// Concurrency: `@MainActor` because it is updated from the server controller on the main actor.
@MainActor
final class MCPAuditStore {
    static let maxRecords = 10_000
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    static let maxBytes = 10 * 1_024 * 1_024

    private(set) var events: [MCPAuditEvent] = []
    private(set) var aggregates: [MCPAuditAggregate] = []
    private(set) var isPersistenceHealthy = true
    private(set) var persistenceFailureReason: String?
    private var approximateBytes = 0
    private let persistenceURL: URL
    private let fileManager: FileManager
    private var persistenceTask: Task<Void, Never>?
    private var mutationGeneration: UInt64 = 0
    private var persistedGeneration: UInt64 = 0

    init(persistenceURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
    }

    func load() {
        do {
            guard fileManager.fileExists(atPath: persistenceURL.path) else {
                isPersistenceHealthy = true
                return
            }
            let data = try Data(contentsOf: persistenceURL)
            let decoded = try JSONDecoder().decode(PersistedAuditState.self, from: data)
            events = decoded.events
            aggregates = decoded.aggregates
            approximateBytes = data.count
            isPersistenceHealthy = true
            persistenceFailureReason = nil
            pruneIfNeeded()
        } catch {
            markPersistenceFailure(error.localizedDescription)
        }
    }

    /// Records an audit event; aggregation applies to repetitive authentication failures.
    func record(_ event: MCPAuditEvent) {
        if event.kind == .authenticationFailure {
            aggregateFailure(event)
        } else {
            events.append(event)
        }
        mutationGeneration &+= 1
        pruneIfNeeded()
        schedulePersistence()
        recordObserver?(event)
    }

    func recordOperatorActionablePolicyBlock(
        clientID: String,
        capability: MCPCapabilityID,
        detail: String,
        kind: MCPAuditEventKind = .policyDenied,
        validationRunID: String? = nil
    ) {
        record(
            MCPAuditEvent(
                id: UUID(),
                kind: kind,
                timestamp: Date(),
                clientID: clientID,
                credentialFingerprint: nil,
                sourceProcess: nil,
                reasonCode: capability.rawValue,
                detail: detail,
                operatorAttention: .policyBlocked(capability: capability),
                validationRunID: validationRunID
            )
        )
    }

    /// Optional hook for attention/recap coordinators (AJ-5).
    var recordObserver: ((MCPAuditEvent) -> Void)?

    /// When persistence is unhealthy, MCP reads must be denied (fail closed).
    var allowsSensitiveReads: Bool {
        isPersistenceHealthy
    }

    var recentEvents: [MCPAuditEvent] {
        Array(events.suffix(200))
    }

    func recentEvents(forClientID clientID: String, limit: Int = 20) -> (events: [MCPAuditEvent], hasMore: Bool) {
        let boundedLimit = min(max(1, limit), 50)
        var newestFirst: [MCPAuditEvent] = []
        var hasMore = false
        for event in events.reversed() where event.clientID == clientID {
            if newestFirst.count == boundedLimit {
                hasMore = true
                break
            }
            newestFirst.append(event)
        }
        return (Array(newestFirst.reversed()), hasMore)
    }

    /// Clears in-memory audit history for an isolated self-validation lane (AI-5).
    func resetForSelfValidation() {
        persistenceTask?.cancel()
        persistenceTask = nil
        events.removeAll()
        aggregates.removeAll()
        approximateBytes = 0
        mutationGeneration &+= 1
    }

    private struct PersistedAuditState: Codable, Sendable {
        var events: [MCPAuditEvent]
        var aggregates: [MCPAuditAggregate]
    }

    private func aggregateFailure(_ event: MCPAuditEvent) {
        let aggregateID = [
            event.kind.rawValue,
            event.reasonCode,
            event.credentialFingerprint ?? "none"
        ].joined(separator: "|")
        if let index = aggregates.firstIndex(where: { $0.id == aggregateID }) {
            aggregates[index].lastSeen = event.timestamp
            aggregates[index].count += 1
        } else {
            aggregates.append(
                MCPAuditAggregate(
                    id: aggregateID,
                    kind: event.kind,
                    reasonCode: event.reasonCode,
                    credentialFingerprint: event.credentialFingerprint,
                    firstSeen: event.timestamp,
                    lastSeen: event.timestamp,
                    count: 1
                )
            )
        }
    }

    private func pruneIfNeeded() {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        events.removeAll { $0.timestamp < cutoff }
        aggregates.removeAll { $0.lastSeen < cutoff }
        while events.count > Self.maxRecords {
            events.removeFirst()
        }
    }

    private func schedulePersistence() {
        guard persistenceTask == nil else { return }
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            let succeeded = await self.persistSnapshot()
            self.persistenceTask = nil
            if succeeded, self.persistedGeneration < self.mutationGeneration {
                self.schedulePersistence()
            }
        }
    }

    func flush() async {
        let pendingTask = persistenceTask
        pendingTask?.cancel()
        await pendingTask?.value
        persistenceTask = nil
        _ = await persistSnapshot()
    }

    /// Clears audit history then records a single destructive-action event (AH-7 erase ordering).
    func eraseHistoryRecordingDestructiveAction(detail: String) async {
        let pendingTask = persistenceTask
        pendingTask?.cancel()
        await pendingTask?.value
        persistenceTask = nil

        events.removeAll()
        aggregates.removeAll()
        approximateBytes = 0
        mutationGeneration &+= 1
        _ = await persistSnapshot()

        let event = MCPAuditEvent(
            id: UUID(),
            kind: .destructiveAction,
            timestamp: Date(),
            clientID: nil,
            credentialFingerprint: nil,
            sourceProcess: nil,
            reasonCode: "erase_audit_history",
            detail: detail
        )
        events.append(event)
        mutationGeneration &+= 1
        _ = await persistSnapshot()
    }

    private func persistSnapshot() async -> Bool {
        let state = PersistedAuditState(events: events, aggregates: aggregates)
        let persistenceURL = persistenceURL
        let generation = mutationGeneration
        let result = await Task.detached(priority: .utility) { () -> (bytes: Int, error: String?) in
            do {
                let data = try JSONEncoder().encode(state)
                try FileManager.default.createDirectory(
                    at: persistenceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: persistenceURL, options: .atomic)
                return (data.count, nil)
            } catch {
                return (0, error.localizedDescription)
            }
        }.value

        guard let error = result.error else {
            approximateBytes = result.bytes
            persistedGeneration = max(persistedGeneration, generation)
            isPersistenceHealthy = true
            persistenceFailureReason = nil
            return true
        }
        markPersistenceFailure(error)
        return false
    }

    private func markPersistenceFailure(_ reason: String) {
        isPersistenceHealthy = false
        persistenceFailureReason = reason
    }

    private static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent("mcp-audit.json", isDirectory: false)
    }
}
