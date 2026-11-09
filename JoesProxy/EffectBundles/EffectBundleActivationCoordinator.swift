import Combine
import Foundation

struct EffectBundleActivationReceipt: Codable, Equatable, Sendable {
    var bundleID: UUID
    var responseRuleIDs: [UUID]
    var hlsExperimentIDs: [UUID]
    var activatedAt: Date
    var expiresAt: Date
}

/// Activates a retained package as one fail-open unit.
///
/// Components are first installed behind ``EffectBundleActivationGate``. Opening that gate is the
/// only commit point observed by request handling. Stop closes the gate first, then tears down each
/// component. Any incomplete teardown is retained as `cleanupRequired` instead of being hidden.
@MainActor
final class EffectBundleActivationCoordinator: ObservableObject {
    private let repository: EffectBundleRepository
    private let responseOverrideStore: ResponseOverrideStore
    private let hlsCoordinator: HLSSubstitutionCoordinator
    private let activationGate: EffectBundleActivationGate
    private let materializer: EffectBundleRuntimeMaterializer
    private let clock: () -> Date
    private let uptime: () -> TimeInterval
    private let schedulesTimers: Bool
    @Published private(set) var phaseSnapshots: [UUID: EffectBundleTimeline.Snapshot] = [:]
    private var timelines: [UUID: EffectBundleTimeline] = [:]
    private var phaseRuleRevisions: [UUID: [UUID: MCPTargetRevision]] = [:]
    private var phaseHLSRunIDs: [UUID: [UUID: UUID]] = [:]
    private var phaseTasks: [UUID: Task<Void, Never>] = [:]
    private var sleeping = false
    weak var diagnosticRuns: DiagnosticRunCoordinator?
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private var activations: [UUID: Task<EffectBundleActivationReceipt, Error>] = [:]
    private var stopping = Set<UUID>()

    var activatingBundleIDs: Set<UUID> { Set(activations.keys) }

    func supervision(id: UUID, requestingOwnerID: String? = nil) throws -> EffectBundlePresentation.Supervision {
        let record = try repository.metadataRecord(id: id, requestingOwnerID: requestingOwnerID)
        var projection = EffectBundlePresentation.supervision(record, phase: phaseSnapshots[id], routingOpen: activationGate.allows(bundleID: id),
            lifecycleBusy: activations[id] != nil || stopping.contains(id))
        projection.media = record.manifest.hlsSubstitutions.filter { $0.replacesSubstitutionID == nil }.map {
            hlsCoordinator.lifecycleState(id: $0.id, declaredPolicy: $0.requestPolicy)
        }
        return projection
    }

    func observationSnapshot(id: UUID) -> [EffectBundleObservation] { activationGate.observationSnapshot(bundleID: id) }

    func observationActivationID(id: UUID) -> UUID? {
        guard let manifest = repository.record(id: id)?.manifest else { return nil }
        return (manifest.responseEffects.map(\.id) + manifest.hlsSubstitutions.map(\.id))
            .compactMap { activationGate.observationIdentity(resourceID: $0)?.activationID }.first
    }

    init(
        repository: EffectBundleRepository,
        responseOverrideStore: ResponseOverrideStore,
        hlsCoordinator: HLSSubstitutionCoordinator,
        activationGate: EffectBundleActivationGate = .shared,
        runtimeRootURL: URL? = nil,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedulesTimers: Bool = true
    ) {
        self.repository = repository
        self.responseOverrideStore = responseOverrideStore
        self.hlsCoordinator = hlsCoordinator
        self.activationGate = activationGate
        self.materializer = EffectBundleRuntimeMaterializer(
            rootURL: runtimeRootURL,
            fileManager: fileManager
        )
        self.clock = clock
        self.uptime = uptime
        self.schedulesTimers = schedulesTimers
    }

    /// Explicit human UI actions may supervise any owner. Never dispatch these from MCP/CLI.
    /// Activation retains the reviewed identity; remote callers still supply their own owner ID.
    @discardableResult
    func activateFromLocalUI(reviewed record: EffectBundleRecord, ttl: TimeInterval? = nil) async throws -> EffectBundleActivationReceipt {
        try await activate(id: record.id, ttl: ttl, reviewedRecord: record)
    }

    @discardableResult
    func advanceFromLocalUI(id: UUID, activationID: UUID, expectedPhaseID: UUID) async throws -> EffectBundleTimeline.Snapshot? {
        try await advance(id: id, activationID: activationID, expectedPhaseID: expectedPhaseID)
    }

    @discardableResult
    func stopFromLocalUI(id: UUID) async throws -> EffectBundleRecord {
        try await stop(id: id)
    }

    @discardableResult
    func activate(
        id: UUID,
        requestingOwnerID: String? = nil,
        ttl: TimeInterval? = nil,
        reviewedRecord: EffectBundleRecord? = nil
    ) async throws -> EffectBundleActivationReceipt {
        _ = try repository.metadataRecord(id: id, requestingOwnerID: requestingOwnerID)
        guard activations[id] == nil, activations.count < 2, !stopping.contains(id) else { throw EffectBundleError.activationConflict }
        try Task.checkCancellation()
        let worker = Task { try await performActivation(id: id, requestingOwnerID: requestingOwnerID, ttl: ttl, reviewedRecord: reviewedRecord) }
        activations[id] = worker
        defer { activations.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// One owned worker per bundle. Stop cancels and drains it before teardown, so an actor hop
    /// cannot publish rules after Stop returns. No approval or routing scope is changed here.
    private func performActivation(id: UUID, requestingOwnerID: String?, ttl: TimeInterval?, reviewedRecord: EffectBundleRecord?) async throws -> EffectBundleActivationReceipt {
        try Task.checkCancellation()
        if let reviewedRecord,
           !EffectBundlePresentation.isCurrentReview(reviewedRecord, current: repository.record(id: id)) {
            throw EffectBundleError.activationConflict
        }
        guard repository.record(id: id)?.isServing != true else {
            throw EffectBundleError.activationConflict
        }
        let retained = try repository.manifestAndPackageURL(
            id: id,
            requestingOwnerID: requestingOwnerID
        )
        let duration = ttl ?? retained.manifest.defaultTTLSeconds
        guard duration.isFinite, duration > 0, duration <= EffectBundleBudget.maxTTL else {
            throw EffectBundleError.invalidTTL
        }
        // A phase schema is not permission to flatten unsupported lifecycle semantics into
        // simultaneous effects. Reject before materialization, registration, or rule installation.
        if retained.manifest.phases != nil {
            guard !sleeping else { throw EffectBundleError.unsupportedPhaseFeature("activation while sleeping") }
            if let blocker = EffectBundlePresentation.phaseBlockers(retained.manifest).first {
                throw EffectBundleError.unsupportedPhaseFeature(blocker.explanation)
            }
        }

        let now = clock()
        let startedUptime = uptime()
        let expiresAt = now.addingTimeInterval(duration)
        let timeline = retained.manifest.phases.map {
            EffectBundleTimeline(phases: $0, activatedAt: now, uptime: startedUptime, duration: duration)
        }
        let layout = try await EffectBundleMaterializationExecutor.shared.materialize(using: materializer,
            manifest: retained.manifest,
            packageURL: retained.packageURL, anchor: now
        )
        let rules: [ResponseOverrideRule]
        do {
            try Task.checkCancellation()
            rules = try retained.manifest.responseEffects.map {
                try makeResponseRule(effect: $0, bundleID: id, layout: layout)
            }
        } catch {
            try? materializer.remove(bundleID: id)
            throw error
        }

        let responseRuleIDs = Set(rules.map(\.id))
        let hlsExperimentIDs = Set(retained.manifest.hlsSubstitutions.filter { $0.replacesSubstitutionID == nil }.map(\.id))
        let responseConflicts = await responseOverrideStore.effectBundleConflictIDs(for: rules)
        if Task.isCancelled {
            try materializer.remove(bundleID: id)
            throw CancellationError()
        }
        guard responseConflicts.isEmpty else {
            try? materializer.remove(bundleID: id)
            throw EffectBundleError.activationConflict
        }
        for substitution in retained.manifest.hlsSubstitutions {
            let conflict = await hlsCoordinator.conflictSummary(
                origin: substitution.origin,
                scope: substitution.scope,
                requestPolicy: substitution.requestPolicy
            )
            guard conflict.totalCount == 0 else {
                try? materializer.remove(bundleID: id)
                throw EffectBundleError.activationConflict
            }
            if Task.isCancelled {
                try materializer.remove(bundleID: id)
                throw CancellationError()
            }
        }

        activationGate.register(
            bundleID: id,
            responseRuleIDs: responseRuleIDs,
            hlsExperimentIDs: hlsExperimentIDs
        )
        var startedHLSIDs: [UUID] = []
        activationGate.registerResources(manifest: retained.manifest, activationID: timeline?.activationID ?? UUID(),
                                         renderedHashes: layout.renderedSHA256ByID)
        do {
            for var rule in rules {
                rule.authoredResource = activationGate.resource(ruleID: rule.id, requireOpen: false)
                try await responseOverrideStore.addRule(rule)
                try Task.checkCancellation()
            }
            let owner = try hlsOwner(forBundleID: id)
            for substitution in retained.manifest.hlsSubstitutions where substitution.replacesSubstitutionID == nil {
                let profileDirectory = layout.url(forLogicalRoot: substitution.profileRootLogicalPath)
                _ = try await hlsCoordinator.start(
                    owner: owner,
                    profileID: substitution.profileID,
                    profileDirectoryOverride: profileDirectory,
                    origin: substitution.origin,
                    scope: substitution.scope,
                    requestPolicy: substitution.requestPolicy,
                    conflictStrategy: .cancel,
                    playbackConfiguration: substitution.playbackConfiguration,
                    duration: duration,
                    experimentID: substitution.id
                )
                startedHLSIDs.append(substitution.id)
                try Task.checkCancellation()
                if timeline != nil { try hlsCoordinator.validateLiveLifecycle(id: substitution.id) }
            }
            for substitution in retained.manifest.hlsSubstitutions {
                guard let target = substitution.replacesSubstitutionID else { continue }
                try await hlsCoordinator.prepareSwitch(id: target, replacementID: substitution.id,
                    directory: layout.url(forLogicalRoot: substitution.profileRootLogicalPath))
                try Task.checkCancellation()
            }
            try await responseOverrideStore.enableRules(ids: responseRuleIDs)
            try Task.checkCancellation()
            if timeline != nil {
                let conflicts = await responseOverrideStore.effectBundlePhaseConflicts(bundleID: id, ruleIDs: responseRuleIDs)
                try Task.checkCancellation()
                guard conflicts.isEmpty else { throw EffectBundleError.activationConflict }
                phaseRuleRevisions[id] = try await responseOverrideStore.effectBundlePhaseRevisions(bundleID: id, ruleIDs: responseRuleIDs)
                try Task.checkCancellation()
                var runs: [UUID: UUID] = [:]
                for hlsID in startedHLSIDs {
                    guard let runID = hlsCoordinator.activeRunID(id: hlsID) else { throw EffectBundleError.activationConflict }
                    runs[hlsID] = runID
                }
                phaseHLSRunIDs[id] = runs
            }
            if uptime() >= startedUptime + duration || (timeline != nil && sleeping) {
                throw EffectBundleError.invalidTTL
            }
            _ = try repository.markServing(id: id, activatedAt: now, expiresAt: expiresAt)
            if let timeline {
                timelines[id] = timeline
                publishPhase(bundleID: id, manifest: retained.manifest, timeline: timeline)
            }
            activationGate.open(bundleID: id)
            if let timeline { schedulePhase(bundleID: id, timeline: timeline) }
            else { scheduleExpiry(bundleID: id, expiresAt: expiresAt) }
            return EffectBundleActivationReceipt(
                bundleID: id,
                responseRuleIDs: responseRuleIDs.sorted { $0.uuidString < $1.uuidString },
                hlsExperimentIDs: hlsExperimentIDs.sorted { $0.uuidString < $1.uuidString },
                activatedAt: now,
                expiresAt: expiresAt
            )
        } catch {
            let activationError = error
            do {
                try await rollbackActivation(
                    bundleID: id,
                    responseRuleIDs: responseRuleIDs,
                    startedHLSIDs: startedHLSIDs,
                    requestingOwnerID: requestingOwnerID
                )
            } catch {
                _ = try? repository.setCleanupRequired(id: id, message: error.localizedDescription)
                throw EffectBundleError.cleanupRequired(error.localizedDescription)
            }
            throw activationError
        }
    }

    /// Compare-and-advance: retries and timer races cannot skip a reviewed phase. Ownership is
    /// checked before exposing state; the run identity prevents an old command affecting a restart.
    @discardableResult
    func advance(id: UUID, requestingOwnerID: String? = nil,
                 activationID: UUID, expectedPhaseID: UUID) async throws -> EffectBundleTimeline.Snapshot? {
        let record = try repository.metadataRecord(id: id, requestingOwnerID: requestingOwnerID)
        guard !sleeping, !stopping.contains(id), var timeline = timelines[id],
              timeline.activationID == activationID, timeline.phase.id == expectedPhaseID,
              activationGate.allows(bundleID: id) else { throw EffectBundleError.stalePhase }
        guard timeline.advance(at: uptime()) else {
            let expired = uptime() >= timeline.expiryUptime
            _ = try await stop(id: id, requestingOwnerID: requestingOwnerID, expired: expired,
                               reason: expired ? .expired : .completed)
            return nil
        }
        let conflicts = await responseOverrideStore.effectBundlePhaseConflicts(bundleID: id,
            ruleIDs: Set(timeline.phase.responseEffectIDs), expectedRevisions: phaseRuleRevisions[id])
        guard !sleeping, !stopping.contains(id), let current = timelines[id],
              current.activationID == activationID, current.phase.id == expectedPhaseID,
              activationGate.allows(bundleID: id) else { throw EffectBundleError.stalePhase }
        let mediaChanged = (phaseHLSRunIDs[id] ?? [:]).contains { hlsCoordinator.activeRunID(id: $0.key) != $0.value }
        if !conflicts.isEmpty || mediaChanged || uptime() >= timeline.expiryUptime {
            let conflicted = !conflicts.isEmpty || mediaChanged
            _ = try await stop(id: id, requestingOwnerID: requestingOwnerID, expired: !conflicted,
                               reason: conflicted ? .transitionConflict : .expired)
            if conflicted { throw EffectBundleError.activationConflict }
            return nil
        }
        do {
            for id in timeline.phase.hlsSubstitutionIDs {
                guard let replacement = record.manifest.hlsSubstitutions.first(where: { $0.id == id }),
                      let target = replacement.replacesSubstitutionID else { continue }
                try hlsCoordinator.switchPrepared(id: target, replacementID: id, requestingOwnerID: record.owner.ownerID)
            }
            for hlsID in timeline.phase.completeHLSSubstitutionIDs ?? [] {
                try hlsCoordinator.completeLive(id: hlsID, requestingOwnerID: record.owner.ownerID)
            }
        } catch {
            let transitionError = error
            _ = try await stop(id: id, requestingOwnerID: requestingOwnerID, reason: .transitionConflict)
            throw transitionError
        }
        timelines[id] = timeline
        publishPhase(bundleID: id, manifest: record.manifest, timeline: timeline)
        schedulePhase(bundleID: id, timeline: timeline)
        return timeline.snapshot
    }

    /// Close every timed gate before awaiting any cleanup. Invoked by app-owned sleep/wake
    /// observation, never from a view lifecycle. Failed cleanup remains in the repository.
    func stopTimedRunsForSleep() async {
        let ids = Set(timelines.keys).union(activations.keys.filter {
            repository.record(id: $0)?.manifest.phases != nil
        })
        for id in ids {
            activationGate.close(bundleID: id)
            activations[id]?.cancel()
        }
        for id in ids { _ = try? await stop(id: id, reason: .sleep) }
    }

    func handleSleepState(isSleeping: Bool) async {
        sleeping = isSleeping
        await stopTimedRunsForSleep()
    }

    private func publishPhase(bundleID: UUID, manifest: EffectBundleManifest, timeline: EffectBundleTimeline) {
        activationGate.setMediaPhase(bundleID: bundleID, phaseID: timeline.phase.id)
        DiagnosticExperimentWindowIndex.shared.notePhase(activationID: timeline.activationID, phaseID: timeline.phase.id)
        let earlierIDs = Set(timeline.phases.prefix(timeline.phaseIndex).flatMap(\.responseEffectIDs))
        // Only explicit image resources remain routable from earlier phases. JSON endpoints
        // must select the new phase; retaining their runtime files does not enable old matchers.
        let imageIDs = manifest.responseEffects.filter { effect in
            earlierIDs.contains(effect.id) && effect.bodySource.assetIDs.contains { id in
                manifest.assets.contains { $0.id == id && ($0.contentType?.hasPrefix("image/") ?? false) }
            }
        }.map(\.id)
        activationGate.selectPhase(bundleID: bundleID,
            responseRuleIDs: Set(timeline.phase.responseEffectIDs).union(imageIDs),
            collectionRuleIDs: Set(manifest.responseEffects.filter { $0.sourceKind == .collectionMock }.map(\.id)))
        phaseSnapshots[bundleID] = timeline.snapshot
    }

    private func schedulePhase(bundleID: UUID, timeline: EffectBundleTimeline) {
        phaseTasks.removeValue(forKey: bundleID)?.cancel()
        guard schedulesTimers else { return }
        let delay = max(0, timeline.deadlineUptime - uptime())
        phaseTasks[bundleID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.advanceIfDue(id: bundleID, activationID: timeline.activationID,
                                    expectedPhaseID: timeline.phase.id)
        }
    }

    /// Used by the timer and deterministic clock-driven regressions. Early wakeups do not
    /// shorten a reviewed phase, and obsolete callbacks cannot touch a new run.
    func advanceIfDue(id: UUID, activationID: UUID, expectedPhaseID: UUID) async {
        guard let timeline = timelines[id], timeline.activationID == activationID,
              timeline.phase.id == expectedPhaseID else { return }
        guard uptime() >= timeline.deadlineUptime else {
            schedulePhase(bundleID: id, timeline: timeline)
            return
        }
        _ = try? await advance(id: id, activationID: activationID, expectedPhaseID: expectedPhaseID)
    }

    func deliveryEvidence(id: UUID, requestingOwnerID: String? = nil, after: UInt64 = 0) throws -> EffectBundleDeliveryEvidence {
        if let requestingOwnerID {
            _ = try repository.metadataRecord(id: id, requestingOwnerID: requestingOwnerID)
        } else {
            guard repository.record(id: id) != nil else { throw EffectBundleError.bundleNotFound }
        }
        return activationGate.evidence(bundleID: id, after: after)
    }

    func observationCheckpoint() -> (marker: UInt64, timelineID: UUID) {
        activationGate.observationCheckpoint()
    }

    @discardableResult
    func stop(
        id: UUID,
        requestingOwnerID: String? = nil,
        expired: Bool = false,
        reason: EffectBundleTerminationReason? = nil
    ) async throws -> EffectBundleRecord {
        // Cleanup uses reviewed identity, not readable package assets. A missing/corrupt package
        // must never prevent the fail-open gate from closing.
        let retained = try repository.metadataRecord(id: id, requestingOwnerID: requestingOwnerID)
        guard stopping.insert(id).inserted else { throw EffectBundleError.activationConflict }
        defer { stopping.remove(id) }
        activationGate.close(bundleID: id)
        phaseTasks.removeValue(forKey: id)?.cancel()
        timelines.removeValue(forKey: id)
        phaseRuleRevisions.removeValue(forKey: id)
        phaseHLSRunIDs.removeValue(forKey: id)
        phaseSnapshots.removeValue(forKey: id)
        expiryTasks.removeValue(forKey: id)?.cancel()
        if let activation = activations[id] {
            activation.cancel()
            _ = await activation.result
        }

        var cleanupFailures: [String] = []
        for substitution in retained.manifest.hlsSubstitutions {
            do {
                _ = try await hlsCoordinator.stop(
                    id: substitution.id,
                    requestingOwnerID: requestingOwnerID
                )
            } catch HLSSubstitutionError.inactiveExperiment {
                continue
            } catch HLSSubstitutionError.experimentNotFound {
                continue
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        }
        do {
            try await responseOverrideStore.disableRules(
                ids: Set(retained.manifest.responseEffects.map(\.id))
            )
            await responseOverrideStore.removeRules(effectBundleID: id)
        } catch {
            cleanupFailures.append(error.localizedDescription)
        }
        do {
            try materializer.remove(bundleID: id)
        } catch {
            cleanupFailures.append(error.localizedDescription)
        }
        activationGate.unregister(bundleID: id)

        guard cleanupFailures.isEmpty else {
            let message = cleanupFailures.joined(separator: " ")
            _ = try? repository.setCleanupRequired(id: id, message: message)
            throw EffectBundleError.cleanupRequired(message)
        }
        return try repository.markStopped(id: id, at: clock(), expired: expired, reason: reason)
    }

    private func rollbackActivation(
        bundleID: UUID,
        responseRuleIDs: Set<UUID>,
        startedHLSIDs: [UUID],
        requestingOwnerID: String?
    ) async throws {
        phaseRuleRevisions.removeValue(forKey: bundleID)
        phaseHLSRunIDs.removeValue(forKey: bundleID)
        activationGate.close(bundleID: bundleID)
        var failures: [String] = []
        for experimentID in startedHLSIDs.reversed() {
            do {
                _ = try await hlsCoordinator.stop(
                    id: experimentID,
                    requestingOwnerID: requestingOwnerID
                )
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        do {
            try await responseOverrideStore.disableRules(ids: responseRuleIDs)
            await responseOverrideStore.removeRules(effectBundleID: bundleID)
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            try materializer.remove(bundleID: bundleID)
        } catch {
            failures.append(error.localizedDescription)
        }
        activationGate.unregister(bundleID: bundleID)
        if !failures.isEmpty {
            throw EffectBundleError.cleanupRequired(failures.joined(separator: " "))
        }
    }

    private func makeResponseRule(
        effect: EffectBundleResponseEffect,
        bundleID: UUID,
        layout: EffectBundleRuntimeLayout
    ) throws -> ResponseOverrideRule {
        let bodySource: ResponseOverrideBodySource
        switch effect.bodySource.kind {
        case .none:
            bodySource = .inline(nil)
        case .inline:
            guard let assetID = effect.bodySource.assetIDs.first,
                  let assetURL = layout.responseURLByID[effect.id] ?? layout.assetURLByID[assetID] else {
                throw EffectBundleError.invalidBodySource(effect.id.uuidString)
            }
            bodySource = .inline(try Data(contentsOf: assetURL, options: [.mappedIfSafe]))
        case .file:
            guard let assetID = effect.bodySource.assetIDs.first,
                  let assetURL = layout.responseURLByID[effect.id] ?? layout.assetURLByID[assetID] else {
                throw EffectBundleError.invalidBodySource(effect.id.uuidString)
            }
            bodySource = .file(assetURL)
        case .directory:
            guard let root = effect.bodySource.rootLogicalPath else {
                throw EffectBundleError.invalidBodySource(effect.id.uuidString)
            }
            bodySource = .directory(layout.url(forLogicalRoot: root))
        }

        return ResponseOverrideRule(
            id: effect.id,
            label: effect.label,
            requestMethod: effect.requestMethod,
            requestScheme: effect.requestScheme,
            host: effect.host,
            port: effect.port,
            path: effect.path,
            matchMode: effect.matchMode,
            sourceKind: effect.sourceKind,
            sourceDescription: sourceDescription(for: effect, layout: layout),
            statusCode: effect.statusCode,
            headers: layout.renderedSHA256ByID[effect.id] == nil ? effect.headers : effect.headers.filter {
                !["content-length", "transfer-encoding", "content-encoding", "etag", "last-modified", "content-md5", "digest", "content-digest", "repr-digest"].contains($0.name.lowercased())
            },
            bodySource: bodySource,
            isEnabled: false,
            mapRemoteHost: effect.mapRemoteHost,
            mapRemotePort: effect.mapRemotePort,
            mapRemoteScheme: effect.mapRemoteScheme,
            mapRemotePath: effect.mapRemotePath,
            mapRemoteQueryPolicy: effect.mapRemoteQueryPolicy,
            mapRemoteQuery: effect.mapRemoteQuery,
            bookmarkRewriteRequest: effect.bookmarkRewriteRequest,
            liveResponseRewrites: effect.liveResponseRewrites,
            expectedSchemaFingerprint: effect.expectedSchemaFingerprint,
            collectionMockPlan: effect.collectionMockPlan,
            effectBundleID: bundleID,
            dropConnection: effect.dropConnection,
            forceNoCache: effect.forceNoCache,
            notFoundRelativePath: effect.notFoundRelativePath,
            missingFilePolicy: effect.missingFilePolicy,
            graphQLOperationName: effect.graphQLOperationName,
            matchQueryKey: effect.matchQueryKey,
            matchQueryValue: effect.matchQueryValue,
            matchHeaderName: effect.matchHeaderName,
            matchHeaderValue: effect.matchHeaderValue,
            sourceClientAddress: effect.sourceClientAddress,
            ignoredQueryNames: effect.ignoredQueryNames
        )
    }

    private func sourceDescription(
        for effect: EffectBundleResponseEffect,
        layout: EffectBundleRuntimeLayout
    ) -> String {
        switch effect.sourceKind {
        case .localFile:
            let name = effect.bodySource.assetIDs.first
                .flatMap { layout.assetURLByID[$0]?.lastPathComponent } ?? "asset"
            return "\(effect.sourceKind.sourceDescription): \(name)"
        case .localDirectory:
            return "\(effect.sourceKind.sourceDescription): \(effect.bodySource.rootLogicalPath ?? "assets")"
        case .mapRemote:
            let scheme = effect.mapRemoteScheme?.rawValue ?? "https"
            return "\(effect.sourceKind.sourceDescription): \(scheme)://\(effect.mapRemoteHost ?? "unknown")"
        case .bookmarkRewrite:
            guard let request = effect.bookmarkRewriteRequest else { return effect.sourceKind.sourceDescription }
            return "\(effect.sourceKind.sourceDescription): \(request.method) \(request.host)\(request.path)"
        case .liveResponseRewrite:
            return LiveResponseRewriteDescriptions.ruleSourceDescription(rewrites: effect.liveResponseRewrites)
        default:
            return effect.sourceKind.sourceDescription
        }
    }

    private func hlsOwner(forBundleID id: UUID) throws -> HLSSubstitutionOwner {
        guard let record = repository.record(id: id) else {
            throw EffectBundleError.bundleNotFound
        }
        switch record.owner {
        case .localUser:
            return .localUser
        case .mcpClient(let id, let displayName):
            return .mcpClient(id: id, displayName: displayName)
        }
    }

    private func scheduleExpiry(bundleID: UUID, expiresAt: Date) {
        expiryTasks.removeValue(forKey: bundleID)?.cancel()
        let delay = max(0, expiresAt.timeIntervalSince(clock()))
        expiryTasks[bundleID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            _ = try? await self?.stop(id: bundleID, expired: true)
        }
    }
}
