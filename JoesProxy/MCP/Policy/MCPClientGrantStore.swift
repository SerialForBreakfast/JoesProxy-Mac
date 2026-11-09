import Foundation

enum MCPClientGrantStoreError: Error, Equatable, Sendable {
    case grantDurationExceedsMaximum
    case grantNotFound
}

/// In-memory client capability grants and denials with audit-style debounced persistence.
///
/// Concurrency: `@MainActor` — read on every tool gate; writes debounce disk I/O off the UI path.
@MainActor
final class MCPClientGrantStore {
    static let persistenceFileName = "mcp-client-grants.json"
    static let persistenceSchemaVersion = 1
    static let maxActiveGrants = 200
    static let maxGrantDuration: TimeInterval = 24 * 60 * 60

    struct PersistedState: Equatable, Sendable, Codable {
        var schemaVersion: Int
        var grants: [MCPClientCapabilityGrant]
        var denials: [MCPClientCapabilityDenial]
    }

    private(set) var grants: [MCPClientCapabilityGrant] = []
    private(set) var denials: [MCPClientCapabilityDenial] = []
    private(set) var isLoaded = false
    private(set) var persistCount = 0

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
            if fileManager.fileExists(atPath: persistenceURL.path) {
                let data = try Data(contentsOf: persistenceURL)
                let persisted = try JSONDecoder().decode(PersistedState.self, from: data)
                guard persisted.schemaVersion == Self.persistenceSchemaVersion else {
                    grants = []
                    denials = []
                    isLoaded = true
                    return
                }
                grants = persisted.grants
                denials = persisted.denials
            }
            pruneExpired(now: Date())
            enforceActiveGrantCap()
            isLoaded = true
        } catch {
            grants = []
            denials = []
            isLoaded = true
        }
    }

    /// Adds a grant after validating bounded duration for `.untilDate` mode.
    @discardableResult
    func addGrant(
        clientID: String,
        capability: MCPCapabilityID,
        mode: MCPClientGrantMode,
        expiresAt: Date? = nil,
        grantedByRequestID: String? = nil,
        now: Date = Date()
    ) throws -> MCPClientCapabilityGrant {
        if mode == .untilDate {
            guard let expiresAt else {
                throw MCPClientGrantStoreError.grantDurationExceedsMaximum
            }
            let duration = expiresAt.timeIntervalSince(now)
            guard duration > 0, duration <= Self.maxGrantDuration else {
                throw MCPClientGrantStoreError.grantDurationExceedsMaximum
            }
        }

        grants.removeAll {
            $0.clientID == clientID && $0.capability == capability
        }
        let grant = MCPClientCapabilityGrant(
            id: UUID(),
            clientID: clientID,
            capability: capability,
            mode: mode,
            expiresAt: mode == .untilDate ? expiresAt : nil,
            createdAt: now,
            grantedByRequestID: grantedByRequestID
        )
        grants.append(grant)
        pruneExpired(now: now)
        enforceActiveGrantCap()
        noteMutation()
        return grant
    }

    func addDenial(clientID: String, capability: MCPCapabilityID, now: Date = Date()) -> MCPClientCapabilityDenial {
        denials.removeAll { $0.clientID == clientID && $0.capability == capability }
        let denial = MCPClientCapabilityDenial(
            id: UUID(),
            clientID: clientID,
            capability: capability,
            createdAt: now
        )
        denials.append(denial)
        grants.removeAll { $0.clientID == clientID && $0.capability == capability }
        noteMutation()
        return denial
    }

    func removeGrant(id: UUID) throws {
        guard grants.contains(where: { $0.id == id }) else {
            throw MCPClientGrantStoreError.grantNotFound
        }
        grants.removeAll { $0.id == id }
        noteMutation()
    }

    func clearUntilSessionEndGrants(clientID: String) {
        let before = grants.count
        grants.removeAll { $0.clientID == clientID && $0.mode == .untilSessionEnd }
        if grants.count != before {
            noteMutation()
        }
    }

    /// Removes all grants and denials for one client (used when removing enrollment records).
    func clearGrantsAndDenials(clientID: String) {
        let beforeGrantCount = grants.count
        let beforeDenialCount = denials.count
        grants.removeAll { $0.clientID == clientID }
        denials.removeAll { $0.clientID == clientID }
        if grants.count != beforeGrantCount || denials.count != beforeDenialCount {
            noteMutation()
        }
    }

    /// Removes temporary grants (session-end and bounded duration). Retains durable policy grants.
    func clearTemporaryGrants() {
        let before = grants.count
        grants.removeAll { $0.mode == .untilSessionEnd || $0.mode == .untilDate }
        if grants.count != before {
            noteMutation()
        }
    }

    func clearAllGrantsAndDenials() {
        grants.removeAll()
        denials.removeAll()
        noteMutation()
    }

    func isAlwaysDenied(capability: MCPCapabilityID, clientID: String) -> Bool {
        denials.contains { $0.clientID == clientID && $0.capability == capability }
    }

    func activeGrant(capability: MCPCapabilityID, clientID: String, now: Date = Date()) -> MCPClientCapabilityGrant? {
        pruneExpired(now: now)
        return grants.first { grant in
            grant.clientID == clientID
                && grant.capability == capability
                && !isExpired(grant, now: now)
        }
    }

    func activeGrants(for clientID: String, now: Date = Date()) -> [MCPClientCapabilityGrant] {
        pruneExpired(now: now)
        return grants.filter { $0.clientID == clientID && !isExpired($0, now: now) }
    }

    func summaries(for clientID: String, now: Date = Date()) -> [MCPClientCapabilityGrantSummary] {
        activeGrants(for: clientID, now: now).map { grant in
            MCPClientCapabilityGrantSummary(
                capability: grant.capability,
                mode: grant.mode,
                expiresAt: grant.expiresAt,
                label: Self.summaryLabel(for: grant)
            )
        }
    }

    func flush() async {
        let pendingTask = persistenceTask
        pendingTask?.cancel()
        await pendingTask?.value
        persistenceTask = nil
        _ = await persistSnapshot()
    }

    /// Clears grants and denials for an isolated self-validation lane (AI-5).
    func resetForSelfValidation() {
        persistenceTask?.cancel()
        persistenceTask = nil
        grants.removeAll()
        denials.removeAll()
        mutationGeneration &+= 1
    }

    private func isExpired(_ grant: MCPClientCapabilityGrant, now: Date) -> Bool {
        if grant.mode == .untilDate, let expiresAt = grant.expiresAt {
            return now >= expiresAt
        }
        return false
    }

    @discardableResult
    private func pruneExpired(now: Date) -> [MCPClientCapabilityGrant] {
        let expired = grants.filter { isExpired($0, now: now) }
        guard !expired.isEmpty else { return [] }
        grants.removeAll { grant in expired.contains(where: { $0.id == grant.id }) }
        noteMutation()
        return expired
    }

    /// Enforces ``maxActiveGrants`` independent of expiry — `.untilSessionEnd` and `.durablePolicy`
    /// grants never expire via `isExpired`, so the cap must be checked unconditionally on every add,
    /// not only as a side effect of pruning already-expired `.untilDate` grants.
    private func enforceActiveGrantCap() {
        guard grants.count > Self.maxActiveGrants else { return }
        grants.removeFirst(grants.count - Self.maxActiveGrants)
        noteMutation()
    }

    private func noteMutation() {
        mutationGeneration &+= 1
        schedulePersistence()
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

    private func persistSnapshot() async -> Bool {
        let state = PersistedState(schemaVersion: Self.persistenceSchemaVersion, grants: grants, denials: denials)
        let persistenceURL = persistenceURL
        let generation = mutationGeneration
        let result = await Task.detached(priority: .utility) { () -> String? in
            do {
                let data = try JSONEncoder().encode(state)
                try FileManager.default.createDirectory(
                    at: persistenceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: persistenceURL, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value

        guard result == nil else { return false }
        persistedGeneration = max(persistedGeneration, generation)
        persistCount += 1
        return true
    }

    private static func summaryLabel(for grant: MCPClientCapabilityGrant) -> String {
        switch grant.mode {
        case .untilSessionEnd:
            return "\(grant.capability.rawValue) until session ends"
        case .untilDate:
            if let expiresAt = grant.expiresAt {
                return "\(grant.capability.rawValue) until \(expiresAt.formatted())"
            }
            return grant.capability.rawValue
        case .durablePolicy:
            return "\(grant.capability.rawValue) (policy)"
        }
    }

    private static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent(persistenceFileName, isDirectory: false)
    }
}
