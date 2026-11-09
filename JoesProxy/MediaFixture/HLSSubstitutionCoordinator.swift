import Combine
import Foundation

/// Owns the aggregate fixture-run + proxy-route lifecycle exposed as one HLS test-stream experiment.
///
/// Concurrency: main-actor isolated because the fixture run repository and app presentation state
/// are main-actor owned. The request hot path uses the separate `HLSSubstitutionRouteStore` actor.
@MainActor
final class HLSSubstitutionCoordinator: ObservableObject {
    static let persistenceSchemaVersion = 2
    static let localUserOwnerID = "joesproxy-local-user"

    private struct PersistedState: Codable {
        var schemaVersion: Int
        var experiments: [HLSSubstitutionExperiment]
    }

    @Published private(set) var experiments: [HLSSubstitutionExperiment] = []
    @Published private(set) var profiles: [HLSFixtureProfileDescriptor] = []

    let routeStore: HLSSubstitutionRouteStore
    private let runStore: HLSFixtureRunStore
    private let responseOverrideStore: ResponseOverrideStore?
    let persistenceURL: URL
    private let fileManager: FileManager
    private let clock: () -> Date
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    init(
        runStore: HLSFixtureRunStore,
        routeStore: HLSSubstitutionRouteStore,
        responseOverrideStore: ResponseOverrideStore? = nil,
        persistenceURL: URL? = nil,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init
    ) {
        self.runStore = runStore
        self.routeStore = routeStore
        self.responseOverrideStore = responseOverrideStore
        self.fileManager = fileManager
        self.clock = clock
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
        profiles = runStore.availableProfileDescriptors()
        loadFailClosed()
    }

    func refreshProfiles() {
        profiles = runStore.availableProfileDescriptors()
    }

    /// Bundle phase completion preserves the existing route, run identity, expiry and media.
    /// No actor suspension occurs between the ownership check and publication freeze.
    func completeLive(id: UUID, requestingOwnerID: String?) throws {
        guard let experiment = experiments.first(where: { $0.id == id }), experiment.isActive,
              let runID = experiment.fixtureRunID, let server = runStore.liveServer(id: runID),
              experiment.expiresAt.map({ $0 > clock() }) ?? false else {
            throw HLSSubstitutionError.inactiveExperiment
        }
        if let requestingOwnerID, requestingOwnerID != experiment.owner.fixtureOwnerID {
            throw HLSSubstitutionError.notOwner
        }
        try server.completeLive()
    }

    func validateLiveLifecycle(id: UUID) throws {
        guard let experiment = experiments.first(where: { $0.id == id }),
              let runID = experiment.fixtureRunID, let server = runStore.liveServer(id: runID) else {
            throw HLSSubstitutionError.inactiveExperiment
        }
        try server.validateLiveLifecycle()
    }

    func prepareSwitch(id: UUID, replacementID: UUID, directory: URL) async throws {
        guard let runID = experiments.first(where: { $0.id == id })?.fixtureRunID,
              let server = runStore.liveServer(id: runID) else { throw HLSSubstitutionError.inactiveExperiment }
        try await server.prepareSwitch(id: replacementID, directory: directory)
    }

    func switchPrepared(id: UUID, replacementID: UUID, requestingOwnerID: String) throws {
        guard let experiment = experiments.first(where: { $0.id == id }), experiment.isActive,
              let runID = experiment.fixtureRunID, let server = runStore.liveServer(id: runID) else {
            throw HLSSubstitutionError.inactiveExperiment
        }
        guard experiment.owner.fixtureOwnerID == requestingOwnerID else { throw HLSSubstitutionError.notOwner }
        try server.switchPrepared(id: replacementID)
    }

    func lifecycleState(id: UUID, declaredPolicy: HLSRequestPolicy? = nil) -> EffectBundlePresentation.MediaState {
        let experiment = experiments.first { $0.id == id }
        let server = experiment?.fixtureRunID.flatMap { runStore.liveServer(id: $0) }
        return .init(substitutionID: id, active: experiment?.isActive == true && server != nil,
            completedAt: server?.completionTime, activePreparedMediaID: server?.activePreparedMediaID, expiresAt: experiment?.expiresAt,
            scope: (experiment?.requestPolicy ?? declaredPolicy)?.summary ?? HLSRequestPolicy.legacySummary)
    }

    func activeRunID(id: UUID) -> UUID? {
        guard let experiment = experiments.first(where: { $0.id == id }), experiment.isActive,
              let runID = experiment.fixtureRunID, runStore.liveServer(id: runID) != nil,
              experiment.expiresAt.map({ $0 > clock() }) ?? false else { return nil }
        return runID
    }

    func experiment(id: UUID) async -> HLSSubstitutionExperiment? {
        await synchronizeMetricsAndExpiry()
        return experiments.first(where: { $0.id == id })
    }

    func experiments(ownedBy owner: HLSSubstitutionOwner) async -> [HLSSubstitutionExperiment] {
        await synchronizeMetricsAndExpiry()
        return experiments.filter { $0.owner.fixtureOwnerID == owner.fixtureOwnerID }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    func conflictSummary(
        origin: HLSSubstitutionOrigin,
        scope: HLSSubstitutionScope,
        requestPolicy: HLSRequestPolicy? = nil
    ) async -> HLSSubstitutionConflictSummary {
        let experimentIDs = await routeStore.conflictingExperimentIDs(origin: origin, scope: scope, requestPolicy: requestPolicy)
        let responseRuleIDs = await responseOverrideStore?
            .hlsSubstitutionConflictIDs(origin: origin, scope: scope) ?? []
        return HLSSubstitutionConflictSummary(
            experimentCount: experimentIDs.count,
            responseRuleCount: responseRuleIDs.count
        )
    }

    @discardableResult
    func start(
        owner: HLSSubstitutionOwner,
        profileID: String,
        profileDirectoryOverride: URL? = nil,
        origin: HLSSubstitutionOrigin,
        scope: HLSSubstitutionScope,
        requestPolicy: HLSRequestPolicy? = nil,
        conflictStrategy: HLSSubstitutionConflictStrategy = .cancel,
        playbackConfiguration: HLSPlaybackConfiguration = .conformant,
        duration: TimeInterval? = nil,
        mcpProvenance: MCPProvenance? = nil,
        experimentID: UUID = UUID()
    ) async throws -> HLSSubstitutionExperiment {
        try requestPolicy?.validate(scope: scope)
        guard profileDirectoryOverride != nil || profiles.contains(where: { $0.id == profileID }) else {
            throw HLSSubstitutionError.profileNotFound
        }
        if profileDirectoryOverride == nil {
            try runStore.validateProfileConfiguration(profileID: profileID, configuration: playbackConfiguration)
        }
        if case .selectedPlaylist(let path) = scope {
            let pathWithoutQuery = String(path.split(separator: "?", maxSplits: 1).first ?? "")
            guard pathWithoutQuery.lowercased().hasSuffix(".m3u8") else {
                throw HLSSubstitutionError.invalidPlaylistPath
            }
        }

        if let track = requestPolicy?.missingTextTrackID {
            let directory = try profileDirectoryOverride ?? runStore.profileDirectory(forProfileID: profileID)
            guard HLSFixtureProfileDescriptor.load(from: directory).textFixture?.tracks.contains(where: { $0.id == track }) == true else {
                throw HLSSubstitutionError.invalidRequestPolicy
            }
        }
        let conflicts = await routeStore.conflictingExperimentIDs(origin: origin, scope: scope, requestPolicy: requestPolicy)
        let responseRuleConflicts = await responseOverrideStore?
            .hlsSubstitutionConflictIDs(origin: origin, scope: scope) ?? []
        if !conflicts.isEmpty || !responseRuleConflicts.isEmpty {
            guard conflictStrategy == .replaceExisting else {
                throw HLSSubstitutionError.conflictingExperiment
            }
        }
        let conflictingExperiments = experiments.filter { conflicts.contains($0.id) && $0.isActive }

        let now = clock()
        let validatedConfiguration = try playbackConfiguration.validated()
        let run = try await runStore.startRun(
            clientID: owner.fixtureOwnerID,
            profileID: profileID,
            profileDirectoryOverride: profileDirectoryOverride,
            playbackConfiguration: validatedConfiguration,
            permitsDirectAccess: requestPolicy == nil,
            duration: duration,
            now: now
        )
        var experiment = HLSSubstitutionExperiment(
            id: experimentID,
            owner: owner,
            profileID: profileID,
            profileDirectoryPath: profileDirectoryOverride?.path,
            origin: origin,
            scope: scope,
            mountPath: "/.joesproxy/hls-substitution/\(experimentID.uuidString.lowercased())/",
            fixtureRunID: run.id,
            state: .active,
            startedAt: now,
            expiresAt: run.expiresAt,
            stoppedAt: nil,
            metrics: HLSSubstitutionMetrics(),
            playbackConfiguration: validatedConfiguration,
            mcpProvenance: mcpProvenance,
            requestPolicy: requestPolicy
        )
        do {
            try await routeStore.install(experiment, replacing: Set(conflicts))
            experiments.removeAll { $0.id == experimentID }
            experiments.append(experiment)
            try await responseOverrideStore?.disableRules(ids: Set(responseRuleConflicts))
            for conflict in conflictingExperiments {
                guard let index = experiments.firstIndex(where: { $0.id == conflict.id }) else { continue }
                experiments[index].state = .stopped
                experiments[index].stoppedAt = now
            }
            try persist()
            for conflict in conflictingExperiments {
                if let runID = conflict.fixtureRunID {
                    _ = try? await runStore.stopRun(
                        id: runID,
                        clientID: conflict.owner.fixtureOwnerID,
                        now: now
                    )
                }
            }
            scheduleExpiry(for: experiment)
            return experiment
        } catch {
            await routeStore.remove(experimentID: experimentID)
            for conflict in conflictingExperiments {
                _ = try? await routeStore.install(conflict)
            }
            _ = try? await responseOverrideStore?.enableRules(ids: Set(responseRuleConflicts))
            experiments.removeAll { $0.id == experimentID }
            for conflict in conflictingExperiments {
                experiments.removeAll { $0.id == conflict.id }
                experiments.append(conflict)
            }
            _ = try? await runStore.stopRun(id: run.id, clientID: owner.fixtureOwnerID, now: now)
            _ = try? persist()
            experiment.state = .stopped
            throw error
        }
    }

    @discardableResult
    func restart(
        id: UUID,
        requestingOwnerID: String? = nil,
        conflictStrategy: HLSSubstitutionConflictStrategy = .cancel
    ) async throws -> HLSSubstitutionExperiment {
        guard let experiment = experiments.first(where: { $0.id == id }) else {
            throw HLSSubstitutionError.experimentNotFound
        }
        if let requestingOwnerID, experiment.owner.fixtureOwnerID != requestingOwnerID {
            throw HLSSubstitutionError.notOwner
        }
        return try await start(
            owner: experiment.owner,
            profileID: experiment.profileID,
            profileDirectoryOverride: experiment.profileDirectoryPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            },
            origin: experiment.origin,
            scope: experiment.scope,
            requestPolicy: experiment.requestPolicy,
            conflictStrategy: conflictStrategy,
            playbackConfiguration: experiment.effectivePlaybackConfiguration,
            mcpProvenance: experiment.mcpProvenance,
            experimentID: experiment.id
        )
    }

    @discardableResult
    func stop(id: UUID, requestingOwnerID: String? = nil) async throws -> HLSSubstitutionExperiment {
        guard let index = experiments.firstIndex(where: { $0.id == id }) else {
            throw HLSSubstitutionError.experimentNotFound
        }
        if let requestingOwnerID, experiments[index].owner.fixtureOwnerID != requestingOwnerID {
            throw HLSSubstitutionError.notOwner
        }
        if !experiments[index].isActive {
            return experiments[index]
        }

        let now = clock()
        let metrics = await routeStore.metrics(experimentID: id)
        await routeStore.remove(experimentID: id)
        expiryTasks.removeValue(forKey: id)?.cancel()
        if let runID = experiments[index].fixtureRunID {
            _ = try? await runStore.stopRun(
                id: runID,
                clientID: experiments[index].owner.fixtureOwnerID,
                now: now
            )
        }
        experiments[index].metrics = metrics
        experiments[index].state = .stopped
        experiments[index].stoppedAt = now
        try persist()
        return experiments[index]
    }

    /// Bumps an active experiment's `expiresAt` forward to `now + duration`, without re-proposing or
    /// re-approving anything — same shape and scope as an already-approved rule, just running
    /// longer. Deliberately as cheap as `stop` (policy-gated only, no propose/apply dance): the field
    /// session's complaint was ceremony every ~30 minutes during active debugging, and extending
    /// changes nothing about *what* is being served, only *how long* — unlike `start`, which decides
    /// scope/content and stays behind full approval. Fail-open-on-quit is unaffected: `loadFailClosed`
    /// still purges every persisted-active experiment at launch regardless of its `expiresAt`.
    ///
    /// Absolute-from-now, not additive: `duration` becomes the new full remaining lifetime, not an
    /// increment on top of whatever was left. A no-op stops nothing — the substitution keeps serving
    /// exactly as before, just for longer.
    @discardableResult
    func extend(
        id: UUID,
        requestingOwnerID: String? = nil,
        duration: TimeInterval
    ) async throws -> HLSSubstitutionExperiment {
        guard let index = experiments.firstIndex(where: { $0.id == id }) else {
            throw HLSSubstitutionError.experimentNotFound
        }
        if let requestingOwnerID, experiments[index].owner.fixtureOwnerID != requestingOwnerID {
            throw HLSSubstitutionError.notOwner
        }
        guard experiments[index].isActive else {
            throw HLSSubstitutionError.inactiveExperiment
        }
        let now = clock()
        let newExpiresAt = now.addingTimeInterval(duration)
        experiments[index].expiresAt = newExpiresAt
        if let runID = experiments[index].fixtureRunID {
            try? runStore.extendRun(id: runID, clientID: experiments[index].owner.fixtureOwnerID, expiresAt: newExpiresAt)
        }
        try persist()
        scheduleExpiry(for: experiments[index])
        return experiments[index]
    }

    func stopAll(ownedBy ownerID: String) async {
        let ids = experiments.filter { $0.isActive && $0.owner.fixtureOwnerID == ownerID }.map(\.id)
        for id in ids {
            _ = try? await stop(id: id, requestingOwnerID: ownerID)
        }
    }

    func clearAll() async {
        let activeIDs = experiments.filter(\.isActive).map(\.id)
        for id in activeIDs {
            _ = try? await stop(id: id)
        }
        experiments.removeAll()
        _ = try? persist()
    }

    func activeCount(ownedBy ownerID: String) -> Int {
        experiments.filter { $0.isActive && $0.owner.fixtureOwnerID == ownerID }.count
    }

    func synchronizeMetricsAndExpiry() async {
        let now = clock()
        _ = try? await runStore.expireOverdueRuns(now: now)
        for index in experiments.indices where experiments[index].isActive {
            experiments[index].metrics = await routeStore.metrics(experimentID: experiments[index].id)
            if let expiresAt = experiments[index].expiresAt, expiresAt <= now {
                let id = experiments[index].id
                await routeStore.remove(experimentID: id)
                expiryTasks.removeValue(forKey: id)?.cancel()
                experiments[index].state = .expired
                experiments[index].stoppedAt = now
            }
        }
        _ = try? persist()
    }

    private func scheduleExpiry(for experiment: HLSSubstitutionExperiment) {
        guard let expiresAt = experiment.expiresAt else { return }
        expiryTasks.removeValue(forKey: experiment.id)?.cancel()
        let delay = max(0, expiresAt.timeIntervalSince(clock()))
        expiryTasks[experiment.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.synchronizeMetricsAndExpiry()
        }
    }

    private func loadFailClosed() {
        guard fileManager.fileExists(atPath: persistenceURL.path),
              let data = try? Data(contentsOf: persistenceURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              (1...Self.persistenceSchemaVersion).contains(state.schemaVersion) else {
            experiments = []
            return
        }
        let now = clock()
        experiments = state.experiments.map { stored in
            var copy = stored
            if copy.isActive {
                copy.state = .stopped
                copy.stoppedAt = now
            }
            copy.fixtureRunID = nil
            return copy
        }
        _ = try? persist()
    }

    private func persist() throws {
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let state = PersistedState(
            schemaVersion: Self.persistenceSchemaVersion,
            experiments: experiments
        )
        try JSONEncoder().encode(state).write(to: persistenceURL, options: .atomic)
    }

    private static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("JoesProxy", isDirectory: true)
            .appendingPathComponent("hls-substitution-store.json")
    }
}
