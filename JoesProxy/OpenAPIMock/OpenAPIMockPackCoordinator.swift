import Combine
import Foundation

/// Owns mock-pack persistence, activation, expiry, and cleanup.
///
/// Concurrency: main-actor isolated like ``HLSSubstitutionCoordinator``. The request hot path
/// uses ``OpenAPIMockRouteStore``. Relaunch restores definitions as stopped — never auto-serving.
@MainActor
final class OpenAPIMockPackCoordinator: ObservableObject {
    static let persistenceSchemaVersion = OpenAPIMockPackSchemaVersion.current
    static let localUserOwnerID = "joesproxy-local-user"

    private struct PersistedRecord: Codable {
        var pack: OpenAPIMockPack
        var compiled: OpenAPIMockCompiledPack
        var displacedRuleIDs: [UUID]
    }

    private struct PersistedState: Codable {
        var schemaVersion: Int
        var records: [PersistedRecord]
    }

    @Published private(set) var packs: [OpenAPIMockPack] = []

    let routeStore: OpenAPIMockRouteStore
    private var compiledByID: [UUID: OpenAPIMockCompiledPack] = [:]
    private var displacedRuleIDsByPack: [UUID: [UUID]] = [:]
    private let responseOverrideStore: ResponseOverrideStore?
    private let persistenceURL: URL
    private let fileManager: FileManager
    private let clock: () -> Date
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    init(
        routeStore: OpenAPIMockRouteStore,
        responseOverrideStore: ResponseOverrideStore? = nil,
        persistenceURL: URL? = nil,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init
    ) {
        self.routeStore = routeStore
        self.responseOverrideStore = responseOverrideStore
        self.fileManager = fileManager
        self.clock = clock
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
        loadFailClosed()
    }

    /// Compiled graph retained for restart. `nil` when the pack is unknown.
    func compiledPack(id: OpenAPIMockPackID) -> OpenAPIMockCompiledPack? {
        compiledByID[id.rawValue]
    }

    func pack(id: OpenAPIMockPackID) async -> OpenAPIMockPack? {
        await synchronizeMetricsAndExpiry()
        return packs.first(where: { $0.id == id })
    }

    func packs(ownedBy owner: OpenAPIMockPackOwner) async -> [OpenAPIMockPack] {
        await synchronizeMetricsAndExpiry()
        return packs.filter { $0.owner.ownerID == owner.ownerID }
    }

    /// Dry-run activation check. Does not persist or install routes.
    func previewActivation(
        compiled: OpenAPIMockCompiledPack,
        owner: OpenAPIMockPackOwner,
        ttl: TimeInterval = OpenAPIMockPackBudget.defaultTTL,
        conflictStrategy: OpenAPIMockConflictStrategy = .refuse,
        packID: OpenAPIMockPackID = OpenAPIMockPackID(rawValue: UUID())
    ) async -> OpenAPIMockActivationDecision {
        let snapshot = await activationSnapshot(
            compiled: compiled,
            owner: owner,
            ttl: ttl,
            conflictStrategy: conflictStrategy,
            packID: packID
        )
        if !snapshot.foreignOverlaps.isEmpty {
            return .refusedConflicts(snapshot.foreignOverlaps + snapshot.overlapping)
        }
        return snapshot.decision
    }

    /// Persists a compiled pack as ``OpenAPIMockPackState/inactive`` with no live intercept.
    @discardableResult
    func prepare(
        compiled: OpenAPIMockCompiledPack,
        owner: OpenAPIMockPackOwner,
        documentBookmark: OpenAPIDocumentBookmark,
        ttl: TimeInterval = OpenAPIMockPackBudget.defaultTTL,
        mcpProvenance: MCPProvenance? = nil,
        packID: OpenAPIMockPackID = OpenAPIMockPackID(rawValue: UUID())
    ) async throws -> OpenAPIMockPack {
        try OpenAPIMockPackBudget.validateTTL(ttl)
        let retainedExcludingSelf = packs.filter { $0.id != packID }.count
        try OpenAPIMockPackBudget.validateRetainedPackCount(retainedExcludingSelf)
        try OpenAPIMockPackBudget.validateOperationCount(compiled.routes.count)
        try OpenAPIMockPackBudget.validateDocumentBytes(compiled.report.estimatedFootprintBytes)

        let pack = OpenAPIMockPack(
            id: packID,
            owner: owner,
            origin: compiled.origin,
            documentBookmark: documentBookmark,
            state: .inactive,
            startedAt: nil,
            expiresAt: nil,
            stoppedAt: nil,
            metrics: OpenAPIMockPackMetrics(),
            coverage: compiled.report.coverage,
            mcpProvenance: mcpProvenance
        )
        compiledByID[packID.rawValue] = compiled
        displacedRuleIDsByPack[packID.rawValue] = []
        packs.removeAll { $0.id == packID }
        packs.append(pack)
        try persist()
        return pack
    }

    /// Owner-scoped delete of a non-serving retained pack.
    func discard(id: OpenAPIMockPackID, requestingOwnerID: String? = nil) async throws {
        guard let existing = packs.first(where: { $0.id == id }) else {
            throw OpenAPIMockPackError.packNotFound
        }
        if let requestingOwnerID, existing.owner.ownerID != requestingOwnerID {
            throw OpenAPIMockPackError.notOwner
        }
        if existing.isServing {
            throw OpenAPIMockPackError.packIsServing
        }
        expiryTasks.removeValue(forKey: id.rawValue)?.cancel()
        packs.removeAll { $0.id == id }
        compiledByID.removeValue(forKey: id.rawValue)
        displacedRuleIDsByPack.removeValue(forKey: id.rawValue)
        try persist()
    }

    /// Activates one compiled pack as a single owned effect.
    @discardableResult
    func activate(
        compiled: OpenAPIMockCompiledPack,
        owner: OpenAPIMockPackOwner,
        documentBookmark: OpenAPIDocumentBookmark,
        ttl: TimeInterval = OpenAPIMockPackBudget.defaultTTL,
        conflictStrategy: OpenAPIMockConflictStrategy = .refuse,
        mcpProvenance: MCPProvenance? = nil,
        packID: OpenAPIMockPackID = OpenAPIMockPackID(rawValue: UUID())
    ) async throws -> OpenAPIMockPack {
        let snapshot = await activationSnapshot(
            compiled: compiled,
            owner: owner,
            ttl: ttl,
            conflictStrategy: conflictStrategy,
            packID: packID
        )
        if !snapshot.foreignOverlaps.isEmpty {
            throw OpenAPIMockPackError.overlappingRules(snapshot.foreignOverlaps)
        }
        switch snapshot.decision {
        case .allowed:
            break
        case .refusedBusy:
            throw OpenAPIMockPackError.ownerSlotBusy
        case .refusedConflicts(let rules):
            throw OpenAPIMockPackError.overlappingRules(rules)
        case .refusedBudget(let error):
            throw error
        }
        let overlapping = snapshot.overlapping
        let ownServingOthers = snapshot.ownServingOthers

        if conflictStrategy == .replaceConflicts {
            for other in ownServingOthers {
                _ = try? await stop(id: other.id, requestingOwnerID: owner.ownerID)
            }
        }

        let now = clock()
        var pack = OpenAPIMockPack(
            id: packID,
            owner: owner,
            origin: compiled.origin,
            documentBookmark: documentBookmark,
            state: .serving,
            startedAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            stoppedAt: nil,
            metrics: OpenAPIMockPackMetrics(),
            coverage: compiled.report.coverage,
            mcpProvenance: mcpProvenance
        )
        let displacedIDs = overlapping.map(\.ruleID)
        do {
            try await routeStore.install(
                packID: packID,
                origin: compiled.origin,
                routes: compiled.routes,
                fixtures: compiled.fixturesByVariantID,
                mcpProvenance: mcpProvenance
            )
            try await responseOverrideStore?.disableRules(ids: Set(displacedIDs))
            compiledByID[packID.rawValue] = compiled
            displacedRuleIDsByPack[packID.rawValue] = displacedIDs
            packs.removeAll { $0.id == packID }
            packs.append(pack)
            try persist()
            scheduleExpiry(for: pack)
            return pack
        } catch {
            await routeStore.remove(packID: packID)
            _ = try? await responseOverrideStore?.enableRules(ids: Set(displacedIDs))
            compiledByID.removeValue(forKey: packID.rawValue)
            displacedRuleIDsByPack.removeValue(forKey: packID.rawValue)
            packs.removeAll { $0.id == packID }
            pack.state = .stopped
            pack.stoppedAt = clock()
            _ = try? persist()
            throw error
        }
    }

    /// Reinstalls a retained compiled pack. Live intercept stays off until this succeeds.
    @discardableResult
    func restart(
        id: OpenAPIMockPackID,
        requestingOwnerID: String? = nil,
        conflictStrategy: OpenAPIMockConflictStrategy = .refuse
    ) async throws -> OpenAPIMockPack {
        guard let existing = packs.first(where: { $0.id == id }) else {
            throw OpenAPIMockPackError.packNotFound
        }
        if let requestingOwnerID, existing.owner.ownerID != requestingOwnerID {
            throw OpenAPIMockPackError.notOwner
        }
        guard let compiled = compiledByID[id.rawValue] else {
            throw OpenAPIMockPackError.missingFixture
        }
        if existing.isServing {
            _ = try await stop(id: id, requestingOwnerID: requestingOwnerID)
        }
        return try await activate(
            compiled: compiled,
            owner: existing.owner,
            documentBookmark: existing.documentBookmark,
            ttl: OpenAPIMockPackBudget.defaultTTL,
            conflictStrategy: conflictStrategy,
            mcpProvenance: existing.mcpProvenance,
            packID: existing.id
        )
    }

    /// Drops routing first, then marks the pack stopped. Does not re-enable displaced Map Local rows.
    @discardableResult
    func stop(id: OpenAPIMockPackID, requestingOwnerID: String? = nil) async throws -> OpenAPIMockPack {
        guard let index = packs.firstIndex(where: { $0.id == id }) else {
            throw OpenAPIMockPackError.packNotFound
        }
        if let requestingOwnerID, packs[index].owner.ownerID != requestingOwnerID {
            throw OpenAPIMockPackError.notOwner
        }
        if !packs[index].isServing {
            return packs[index]
        }
        let now = clock()
        let metrics = await routeStore.metrics(packID: id)
        await routeStore.remove(packID: id)
        expiryTasks.removeValue(forKey: id.rawValue)?.cancel()
        packs[index].metrics = metrics
        packs[index].state = .stopped
        packs[index].stoppedAt = now
        try persist()
        return packs[index]
    }

    func stopAll(ownedBy ownerID: String) async {
        let ids = packs.filter { $0.isServing && $0.owner.ownerID == ownerID }.map(\.id)
        for id in ids {
            _ = try? await stop(id: id, requestingOwnerID: ownerID)
        }
    }

    func activeCount(ownedBy ownerID: String) -> Int {
        packs.filter { $0.isServing && $0.owner.ownerID == ownerID }.count
    }

    func synchronizeMetricsAndExpiry() async {
        let now = clock()
        for index in packs.indices where packs[index].isServing {
            packs[index].metrics = await routeStore.metrics(packID: packs[index].id)
            if let expiresAt = packs[index].expiresAt, expiresAt <= now {
                let id = packs[index].id
                await routeStore.remove(packID: id)
                expiryTasks.removeValue(forKey: id.rawValue)?.cancel()
                packs[index].state = .expired
                packs[index].stoppedAt = now
            }
        }
        _ = try? persist()
    }

    private struct ActivationSnapshot {
        var overlapping: [OpenAPIMockOverlappingRule]
        var foreignOverlaps: [OpenAPIMockOverlappingRule]
        var ownServingOthers: [OpenAPIMockPack]
        var decision: OpenAPIMockActivationDecision
    }

    private func activationSnapshot(
        compiled: OpenAPIMockCompiledPack,
        owner: OpenAPIMockPackOwner,
        ttl: TimeInterval,
        conflictStrategy: OpenAPIMockConflictStrategy,
        packID: OpenAPIMockPackID
    ) async -> ActivationSnapshot {
        let overlapping = await responseOverrideStore?.openAPIMockConflictIDs(
            origin: compiled.origin,
            routes: compiled.routes
        ) ?? []
        let foreignServing = packs.filter {
            $0.isServing && $0.origin == compiled.origin && $0.owner.ownerID != owner.ownerID && $0.id != packID
        }
        let foreignOverlaps = foreignServing.map { pack in
            OpenAPIMockOverlappingRule(
                ruleID: pack.id.rawValue,
                method: "*",
                pathDescription: pack.origin.displayString
            )
        }
        let ownServingOthers = packs.filter {
            $0.isServing && $0.owner.ownerID == owner.ownerID && $0.id != packID
        }
        let retainedExcludingSelf = packs.filter { $0.id != packID }.count
        let decision = OpenAPIMockPackActivationPolicy.evaluate(
            OpenAPIMockActivationRequest(
                packID: packID,
                owner: owner,
                origin: compiled.origin,
                routeCount: compiled.routes.count,
                documentByteCount: compiled.report.estimatedFootprintBytes,
                ttl: ttl,
                activePackCountForOwner: ownServingOthers.count,
                retainedPackCount: retainedExcludingSelf,
                overlappingRules: overlapping,
                conflictStrategy: conflictStrategy
            )
        )
        return ActivationSnapshot(
            overlapping: overlapping,
            foreignOverlaps: foreignOverlaps,
            ownServingOthers: ownServingOthers,
            decision: decision
        )
    }

    private func scheduleExpiry(for pack: OpenAPIMockPack) {
        guard let expiresAt = pack.expiresAt else { return }
        expiryTasks.removeValue(forKey: pack.id.rawValue)?.cancel()
        let delay = max(0, expiresAt.timeIntervalSince(clock()))
        expiryTasks[pack.id.rawValue] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.synchronizeMetricsAndExpiry()
        }
    }

    private func loadFailClosed() {
        guard fileManager.fileExists(atPath: persistenceURL.path),
              let data = try? Data(contentsOf: persistenceURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.schemaVersion == Self.persistenceSchemaVersion else {
            packs = []
            return
        }
        packs = state.records.map { record in
            var pack = record.pack
            pack.state = OpenAPIMockPackActivationPolicy.relaunchState(from: pack.state)
            if pack.state == .stopped, pack.stoppedAt == nil {
                pack.stoppedAt = clock()
            }
            compiledByID[pack.id.rawValue] = record.compiled
            displacedRuleIDsByPack[pack.id.rawValue] = record.displacedRuleIDs
            return pack
        }
        _ = try? persist()
    }

    private func persist() throws {
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let records = packs.compactMap { pack -> PersistedRecord? in
            guard let compiled = compiledByID[pack.id.rawValue] else { return nil }
            return PersistedRecord(
                pack: pack,
                compiled: compiled,
                displacedRuleIDs: displacedRuleIDsByPack[pack.id.rawValue] ?? []
            )
        }
        let state = PersistedState(schemaVersion: Self.persistenceSchemaVersion, records: records)
        try JSONEncoder().encode(state).write(to: persistenceURL, options: .atomic)
    }

    private static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent("openapi-mock-pack-store.json")
    }
}
