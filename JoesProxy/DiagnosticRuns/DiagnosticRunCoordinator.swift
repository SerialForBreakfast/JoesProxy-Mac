import Foundation
import Combine

/// AppCoordinator-owned coordination object for durable diagnostic runs (AN-2 / AN-3).
///
/// Owns persistence, quotas, lifecycle transitions, reference attach, atomic watch start, close/
/// cleanup proof, expiry, relaunch reconciliation, and owner-scoped observation reads/subscriptions.
/// Does not activate effects, approve mutations, or expose MCP/CLI tools (AN-6).
///
/// Concurrency: `@MainActor` — mutates the store and published snapshot on the main actor. Watch
/// install/remove, effect resolution, and observation-index hops may await injectable collaborators.
@MainActor
final class DiagnosticRunCoordinator: ObservableObject {
    static let localUserOwnerID = DiagnosticRunOwner.localUserOwnerID

    @Published private(set) var runs: [DiagnosticRun] = []

    private let store: DiagnosticRunStore
    private let watchInstaller: any DiagnosticRunWatchInstalling
    private let effectResolver: any DiagnosticRunEffectResolving
    private let observationIndex: DiagnosticRunObservationIndex?
    private let policyRevisionProvider: () -> MCPPolicyRevision
    private let clock: () -> Date
    private let experimentIndex: DiagnosticExperimentWindowIndex
    private weak var experimentBundles: EffectBundleActivationCoordinator?
    private var experimentRepository: EffectBundleRepository?
    private var experimentAdmission: () -> CaptureAdmissionBudget.Snapshot? = { nil }

    init(
        store: DiagnosticRunStore,
        watchInstaller: (any DiagnosticRunWatchInstalling)? = nil,
        effectResolver: (any DiagnosticRunEffectResolving)? = nil,
        observationIndex: DiagnosticRunObservationIndex? = nil,
        policyRevisionProvider: @escaping () -> MCPPolicyRevision = { .initial },
        clock: @escaping () -> Date = Date.init,
        experimentIndex: DiagnosticExperimentWindowIndex = .shared
    ) {
        self.store = store
        self.watchInstaller = watchInstaller ?? NoOpDiagnosticRunWatchInstaller()
        self.effectResolver = effectResolver ?? NoOpDiagnosticRunEffectResolver()
        self.observationIndex = observationIndex
        self.policyRevisionProvider = policyRevisionProvider
        self.clock = clock
        self.experimentIndex = experimentIndex
    }

    func configureExperiments(repository: EffectBundleRepository, bundles: EffectBundleActivationCoordinator,
                              admission: @escaping () -> CaptureAdmissionBudget.Snapshot? = { nil }) {
        experimentRepository = repository
        experimentBundles = bundles
        experimentAdmission = admission
    }

    func noteExperimentCaptureReset() { experimentIndex.noteCaptureReset() }

    func completeExperimentObservation(sessionID: UUID, status: Int?, duration: TimeInterval?) {
        experimentIndex.complete(sessionID: sessionID, status: status, duration: duration)
    }

    func beginExperimentWindow(runID: DiagnosticRunID, bundleID: UUID, mode: DiagnosticExperimentWindow.Mode,
                               requestingOwnerID: String?) throws -> DiagnosticExperimentWindow {
        try requireStore()
        guard let run = store.runs.first(where: { $0.id == runID }), run.expiresAt > clock(), run.status.isNonterminal,
              let repository = experimentRepository, let bundles = experimentBundles else { throw EffectBundleError.bundleNotFound }
        if let requestingOwnerID, run.owner.ownerID != requestingOwnerID { throw EffectBundleError.notOwner }
        let record = try repository.metadataRecord(id: bundleID, requestingOwnerID: requestingOwnerID)
        guard run.owner.ownerID == record.owner.ownerID else { throw EffectBundleError.notOwner }
        let state = try bundles.supervision(id: bundleID, requestingOwnerID: requestingOwnerID)
        guard !state.lifecycleBusy, (mode == .baseline ? !record.isServing : state.routingOpen) else { throw EffectBundleError.activationConflict }
        let resourceIDs = record.manifest.responseEffects.map(\.id) + record.manifest.hlsSubstitutions.filter { $0.replacesSubstitutionID == nil }.map(\.id)
        guard resourceIDs.count <= 32 else { throw EffectBundleError.tooManyResponseEffects(resourceIDs.count) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Fingerprint only matcher metadata. Reviewed payloads are never hashed by observation commands.
        let scopeRows = record.manifest.responseEffects.map { effect in
            ["id": effect.id.uuidString, "method": effect.requestMethod, "scheme": effect.requestScheme.rawValue,
             "host": effect.host, "port": effect.port.map(String.init) ?? "", "path": effect.path,
             "mode": effect.matchMode.rawValue, "client": effect.sourceClientAddress ?? "",
             "queryKey": effect.matchQueryKey ?? "", "queryValue": effect.matchQueryValue ?? "",
             "headerName": effect.matchHeaderName ?? "", "headerValue": effect.matchHeaderValue ?? "",
             "graphQLOperationName": effect.graphQLOperationName ?? "",
             "ignoredQueryNames": (effect.ignoredQueryNames ?? []).sorted().joined(separator: "\u{0}")]
        }
        struct MediaScope: Encodable {
            let id: UUID
            let origin: HLSSubstitutionOrigin
            let scope: HLSSubstitutionScope
            let requestPolicy: HLSRequestPolicy?
        }
        let mediaScopes = record.manifest.hlsSubstitutions.map {
            MediaScope(id: $0.id, origin: $0.origin, scope: $0.scope, requestPolicy: $0.requestPolicy)
        }
        var scopeBytes = try encoder.encode(scopeRows)
        scopeBytes.append(try encoder.encode(mediaScopes))
        // Freeze retained-import provenance: a reimport cannot reuse an old window through its UUID.
        scopeBytes.append(try encoder.encode(record.importedAt.timeIntervalSinceReferenceDate))
        let digest = EffectBundleValidator.sha256Hex(scopeBytes)
        let activationID = state.phase?.activationID ?? bundles.observationActivationID(id: bundleID)
        guard mode == .baseline || activationID != nil else { throw EffectBundleError.activationConflict }
        var window = DiagnosticExperimentWindow(id: UUID(), runID: runID, ownerID: run.owner.ownerID,
            bundleID: bundleID, revisionID: record.manifest.authoring?.revisionID ?? bundleID,
            scopeDigest: digest, mode: mode, activationID: mode == .baseline ? nil : activationID,
            beganAt: clock(), resources: resourceIDs.map { .init(id: $0) })
        let checkpoint = bundles.observationCheckpoint()
        window.evidenceStartMarker = checkpoint.marker
        window.evidenceTimelineID = checkpoint.timelineID
        if let phase = state.phase { window.phaseIDs = [phase.phaseID] }
        let qualifiedWindow = try experimentIndex.begin(window, manifest: record.manifest)
        do { try store.saveExperimentWindow(qualifiedWindow) }
        catch { experimentIndex.remove(id: window.id); throw error }
        return qualifiedWindow
    }

    func endExperimentWindow(id: UUID, requestingOwnerID: String?, targetOutcome: String? = nil,
                             outcomeSource: String? = nil) throws -> DiagnosticExperimentWindow {
        try requireStore()
        guard let saved = store.experimentWindows.first(where: { $0.id == id }) else { throw EffectBundleError.bundleNotFound }
        if let requestingOwnerID, saved.ownerID != requestingOwnerID { throw EffectBundleError.notOwner }
        if saved.endedAt != nil { return saved }
        guard targetOutcome == nil || (["confirmed", "rejected", "unknown"].contains(targetOutcome!) &&
            outcomeSource?.isEmpty == false && (outcomeSource?.utf8.count ?? 0) <= 256) else {
            throw EffectBundleError.invalidBodySource("targetOutcomeSourceRequired")
        }
        var result = try experimentIndex.end(id: id,
            observations: experimentBundles?.observationSnapshot(id: saved.bundleID) ?? [], at: clock())
        if saved.mode == .modified, experimentBundles?.observationActivationID(id: saved.bundleID) != saved.activationID {
            result.qualifications.append("activationEndedOrReplaced")
        }
        if let coverage = try experimentBundles?.deliveryEvidence(id: saved.bundleID, requestingOwnerID: requestingOwnerID,
                                                                  after: saved.evidenceStartMarker) {
            if coverage.retentionGap { result.qualifications.append("deliveryReceiptsEvicted") }
            if coverage.window?.timelineID != saved.evidenceTimelineID { result.qualifications.append("deliveryTimelineChanged") }
        } else { result.qualifications.append("deliveryCoverageUnavailable") }
        if let targetOutcome { result.targetOutcome = targetOutcome; result.targetOutcomeSource = outcomeSource }
        if let snapshot = experimentAdmission() {
            if snapshot.gaps.contains(where: { $0.start.date <= result.endedAt! && ($0.end?.date ?? snapshot.observed.date) >= result.beganAt }) {
                result.qualifications.append("captureAdmissionGap")
            }
            if snapshot.historyStarted.date > result.beganAt || (snapshot.evictedThrough?.date ?? .distantPast) >= result.beganAt {
                result.qualifications.append("admissionHistoryUnavailable")
            }
        } else { result.qualifications.append("admissionCoverageUnavailable") }
        try store.saveExperimentWindow(result)
        experimentIndex.remove(id: id)
        return result
    }

    func experimentWindows(bundleID: UUID, requestingOwnerID: String?) throws -> [DiagnosticExperimentWindow] {
        guard let repository = experimentRepository else { throw EffectBundleError.bundleNotFound }
        _ = try repository.metadataRecord(id: bundleID, requestingOwnerID: requestingOwnerID)
        return store.experimentWindows.filter { $0.bundleID == bundleID && (requestingOwnerID == nil || $0.ownerID == requestingOwnerID) }
    }

    func experimentWindowReferences(runID: DiagnosticRunID, requestingOwnerID: String) -> [[String: String]] {
        store.experimentWindows.filter { $0.runID == runID && $0.ownerID == requestingOwnerID }.prefix(32).map {
            ["windowID": $0.id.uuidString, "bundleID": $0.bundleID.uuidString,
             "revisionID": $0.revisionID.uuidString, "mode": $0.mode.rawValue,
             "state": $0.endedAt == nil ? "open" : "closed"]
        }
    }

    func compareExperimentWindows(baselineID: UUID, modifiedID: UUID, requestingOwnerID: String?) throws -> EffectBundleComparison {
        try requireStore()
        guard let baseline = store.experimentWindows.first(where: { $0.id == baselineID }),
              let modified = store.experimentWindows.first(where: { $0.id == modifiedID }) else { throw EffectBundleError.bundleNotFound }
        if let requestingOwnerID, baseline.ownerID != requestingOwnerID || modified.ownerID != requestingOwnerID { throw EffectBundleError.notOwner }
        guard baseline.mode == .baseline, modified.mode == .modified, baseline.endedAt != nil, modified.endedAt != nil,
              baseline.ownerID == modified.ownerID, baseline.bundleID == modified.bundleID,
              baseline.scopeDigest == modified.scopeDigest, baseline.revisionID == modified.revisionID else {
            throw EffectBundleError.invalidBodySource("incomparableWindows")
        }
        guard let baselineEnd = baseline.endedAt, baselineEnd <= modified.beganAt else {
            throw EffectBundleError.invalidBodySource("overlappingObservationWindows")
        }
        // Persistence keeps explicit close order, even when ISO timestamps round to one second.
        guard let baselineIndex = store.experimentWindows.firstIndex(where: { $0.id == baselineID }),
              let modifiedIndex = store.experimentWindows.firstIndex(where: { $0.id == modifiedID }),
              baselineIndex < modifiedIndex else {
            throw EffectBundleError.invalidBodySource("reversedObservationWindows")
        }
        guard let repository = experimentRepository else { throw EffectBundleError.bundleNotFound }
        let record = try repository.metadataRecord(id: modified.bundleID, requestingOwnerID: requestingOwnerID)
        let report = EffectBundleComparison(baseline: baseline, modified: modified,
            resources: baseline.resources.map { before in
                let after = modified.resources.first { $0.id == before.id } ?? .init(id: before.id)
                return .init(resourceID: before.id, baseline: before, modified: after, observedCountDelta: after.observed - before.observed)
            }, cleanupState: record.state.rawValue, intendedChanges: modified.intendedChanges)
        guard try JSONEncoder().encode(report).count <= EffectBundleJoinedInspection.maximumBytes else {
            throw EffectBundleJoinedInspection.InspectionError.responseBudgetExceeded
        }
        return report
    }

    /// Loads persistence and reconciles relaunch recovery. Call once at app launch.
    ///
    /// Concurrency: `@MainActor` async so Watching relaunch can await cleanup verification without
    /// restoring watches or effects. Safe to call from a launch `Task`.
    func bootstrap() async {
        store.load()
        guard store.isLoaded else {
            runs = []
            return
        }
        for var window in store.experimentWindows where window.endedAt == nil {
            window.endedAt = clock()
            window.qualifications.append("restartInterruptedWindow")
            try? store.saveExperimentWindow(window)
        }
        let now = clock()
        let snapshot = store.runs.filter(\.status.isNonterminal)
        for var run in snapshot {
            switch run.status {
            case .draft:
                if run.expiresAt <= now {
                    run = synthesizeExpiredDraft(run, now: now)
                    try? store.upsert(run)
                    try? await persistEvidenceIfNeeded(for: &run)
                }
            case .watching:
                await reconcileWatchingAfterRelaunch(run.id)
            case .active, .closing:
                run.status = .cleanupRequired
                run.installedWatchIDs = []
                if run.requestedTerminal == nil {
                    run.requestedTerminal = .inconclusive
                }
                run.lastUpdatedAt = now
                try? store.upsert(run)
            case .cleanupRequired:
                run.installedWatchIDs = []
                run.lastUpdatedAt = now
                try? store.upsert(run)
            case .passed, .failed, .inconclusive, .expired:
                break
            }
        }
        publish()
    }

    // MARK: - Create / mutate draft

    /// Creates a Draft run. Inert: no watches and no effects.
    func createDraft(
        owner: DiagnosticRunOwner,
        hypothesis: DiagnosticRunHypothesis,
        scopes: [DiagnosticRunScope] = [],
        lifetime: TimeInterval? = nil,
        runID: DiagnosticRunID? = nil
    ) throws -> DiagnosticRun {
        try requireStore()
        let now = clock()
        try enforceCreateQuotas(owner: owner)
        let validatedHypothesis = try DiagnosticRunValidation.validatedHypothesis(hypothesis)
        try DiagnosticRunValidation.validateScopes(scopes, requireNonEmpty: false)
        let normalizedScopes = try normalizeScopes(scopes)
        let expiresAt = try DiagnosticRunValidation.expiresAt(lifetime: lifetime, now: now)
        let run = DiagnosticRun(
            schemaVersion: DiagnosticRunSchemaVersion.current,
            id: runID ?? DiagnosticRunID(),
            owner: owner,
            hypothesis: validatedHypothesis,
            scopes: normalizedScopes,
            references: [],
            status: .draft,
            requestedTerminal: nil,
            observationSummary: .empty,
            conclusion: nil,
            cleanupProof: nil,
            createdAt: now,
            watchingStartedAt: nil,
            activeAt: nil,
            closingStartedAt: nil,
            expiresAt: expiresAt,
            terminalAt: nil,
            lastUpdatedAt: now,
            installedWatchIDs: []
        )
        try store.upsert(run)
        publish()
        return run
    }

    /// Replaces Draft scopes. Rejected outside Draft.
    func updateDraftScopes(
        id: DiagnosticRunID,
        scopes: [DiagnosticRunScope],
        requestingOwnerID: String
    ) throws -> DiagnosticRun {
        var run = try ownedRun(id: id, requestingOwnerID: requestingOwnerID)
        guard run.status == .draft else {
            throw DiagnosticRunError.illegalTransition(from: run.status, to: .draft)
        }
        try DiagnosticRunValidation.validateScopes(scopes, requireNonEmpty: false)
        run.scopes = try normalizeScopes(scopes)
        run.lastUpdatedAt = clock()
        try store.upsert(run)
        publish()
        return run
    }

    // MARK: - References

    /// Attaches an opaque reference. Never activates the referenced object.
    func attachReference(
        id: DiagnosticRunID,
        reference: DiagnosticRunReference,
        requestingOwnerID: String
    ) async throws -> DiagnosticRun {
        var run = try ownedRun(id: id, requestingOwnerID: requestingOwnerID)
        guard run.status == .draft || run.status == .watching || run.status == .active else {
            throw DiagnosticRunError.attachRejected("References may only be attached before Closing.")
        }
        guard run.references.count < DiagnosticRunBudget.maxReferencesPerRun else {
            throw DiagnosticRunError.quotaExceeded(
                "A run may have at most \(DiagnosticRunBudget.maxReferencesPerRun) references."
            )
        }
        if reference.relationship == .ownerScopedCleanup {
            let liveCount = try await ownerScopedLiveCount(for: run)
            if liveCount >= DiagnosticRunBudget.maxActiveOwnerScopedEffectsPerRun {
                throw DiagnosticRunError.quotaExceeded(
                    "A run may have at most \(DiagnosticRunBudget.maxActiveOwnerScopedEffectsPerRun) owner-scoped live effects."
                )
            }
            let state = await effectResolver.liveState(kind: reference.kind, opaqueID: reference.opaqueID)
            switch state {
            case .notFound:
                throw DiagnosticRunError.staleTarget("Referenced effect was not found.")
            case .inactive(let ownerID), .live(let ownerID):
                // Observe-only may reference foreign effects; cleanup authority never does.
                guard ownerID == requestingOwnerID else {
                    throw DiagnosticRunError.attachRejected(
                        "ownerScopedCleanup requires the requesting owner to own the effect."
                    )
                }
            }
        }
        var attached = reference
        attached.attachedAt = clock()
        run.references.append(attached)
        run = try await refreshActiveState(run)
        run.lastUpdatedAt = clock()
        try store.upsert(run)
        publish()
        return run
    }

    // MARK: - Start watching

    /// Atomically installs watches and transitions Draft → Watching.
    func startWatching(
        id: DiagnosticRunID,
        requestingOwnerID: String
    ) async throws -> DiagnosticRun {
        try requireStore()
        var run = try ownedRun(id: id, requestingOwnerID: requestingOwnerID)
        guard run.status == .draft else {
            throw DiagnosticRunError.illegalTransition(from: run.status, to: .watching)
        }
        let now = clock()
        if run.expiresAt <= now {
            run = synthesizeExpiredDraft(run, now: now)
            try store.upsert(run)
            publish()
            throw DiagnosticRunError.illegalTransition(from: .draft, to: .expired)
        }
        try DiagnosticRunValidation.validateScopes(run.scopes, requireNonEmpty: true)
        run.scopes = try normalizeScopes(run.scopes)

        // Install one scope at a time so a mid-batch failure can roll back earlier watches.
        var installed: [UUID] = []
        do {
            for scope in run.scopes {
                let ids = try await watchInstaller.installWatches(
                    runID: run.id,
                    ownerID: run.owner.ownerID,
                    scopes: [scope]
                )
                installed.append(contentsOf: ids)
            }
            run.status = .watching
            run.watchingStartedAt = now
            run.installedWatchIDs = installed
            run.lastUpdatedAt = now
            run = try await refreshActiveState(run)
            try store.upsert(run)
            publish()
            return run
        } catch {
            if !installed.isEmpty {
                await watchInstaller.removeWatches(installed)
            }
            throw error
        }
    }

    // MARK: - Close / cleanup

    /// Idempotent close: stop watches, request owner-scoped cleanup, persist proof, enter terminal or Cleanup Required.
    func close(
        id: DiagnosticRunID,
        requestingOwnerID: String,
        requestedTerminal: DiagnosticRunRequestedTerminal,
        conclusion: DiagnosticRunConclusion?
    ) async throws -> DiagnosticRun {
        try requireStore()
        var run = try ownedRun(id: id, requestingOwnerID: requestingOwnerID)
        switch run.status {
        case .watching, .active, .cleanupRequired:
            break
        case .closing:
            return try await finishClosing(run, requestingOwnerID: requestingOwnerID)
        case .passed, .failed, .inconclusive, .expired:
            return run
        case .draft:
            throw DiagnosticRunError.illegalTransition(from: .draft, to: .closing)
        }

        if requestedTerminal != .expired {
            guard let conclusion else { throw DiagnosticRunError.conclusionRequired }
            run.conclusion = try DiagnosticRunValidation.validatedConclusion(conclusion)
        }
        let now = clock()
        run.status = .closing
        run.requestedTerminal = requestedTerminal
        run.closingStartedAt = run.closingStartedAt ?? now
        run.lastUpdatedAt = now
        try store.upsert(run)
        publish()
        return try await finishClosing(run, requestingOwnerID: requestingOwnerID)
    }

    /// Retries cleanup for Cleanup Required runs.
    func retryCleanup(
        id: DiagnosticRunID,
        requestingOwnerID: String
    ) async throws -> DiagnosticRun {
        var run = try ownedRun(id: id, requestingOwnerID: requestingOwnerID)
        guard run.status == .cleanupRequired else {
            throw DiagnosticRunError.illegalTransition(from: run.status, to: .closing)
        }
        guard run.requestedTerminal != nil else {
            throw DiagnosticRunError.cleanupRequired("Cleanup Required run is missing a requested terminal state.")
        }
        run.status = .closing
        run.closingStartedAt = clock()
        run.lastUpdatedAt = clock()
        try store.upsert(run)
        publish()
        return try await finishClosing(run, requestingOwnerID: requestingOwnerID)
    }

    /// Forces expiry handling using the injected clock.
    func synchronizeExpiry(now: Date? = nil) async {
        let instant = now ?? clock()
        for run in store.runs where run.status.isNonterminal && run.expiresAt <= instant {
            switch run.status {
            case .draft:
                var expired = synthesizeExpiredDraft(run, now: instant)
                try? store.upsert(expired)
                try? await persistEvidenceIfNeeded(for: &expired)
            case .watching, .active:
                _ = try? await close(
                    id: run.id,
                    requestingOwnerID: run.owner.ownerID,
                    requestedTerminal: .expired,
                    conclusion: nil
                )
            case .closing, .cleanupRequired, .passed, .failed, .inconclusive, .expired:
                continue
            }
        }
        publish()
    }

    /// Stops observation and marks Cleanup Required for every nonterminal run owned by `ownerID`.
    func markCleanupRequired(ownedBy ownerID: String) async {
        for run in store.runs where run.owner.ownerID == ownerID && run.status.isNonterminal {
            var updated = run
            if !updated.installedWatchIDs.isEmpty {
                await watchInstaller.removeWatches(updated.installedWatchIDs)
                updated.installedWatchIDs = []
            }
            if updated.requestedTerminal == nil {
                updated.requestedTerminal = .inconclusive
            }
            updated.status = .cleanupRequired
            updated.lastUpdatedAt = clock()
            try? store.upsert(updated)
            await observationIndex?.stopRun(updated.id)
        }
        await observationIndex?.disconnect(ownerID: ownerID)
        publish()
    }

    /// Stops observation for every nonterminal run (Return To Normal inventory hook).
    func markAllNonterminalCleanupRequired() async {
        let ownerIDs = Set(store.runs.filter(\.status.isNonterminal).map(\.owner.ownerID))
        for ownerID in ownerIDs {
            await markCleanupRequired(ownedBy: ownerID)
        }
    }

    /// Count of nonterminal runs for one owner (client cleanup inventory).
    func nonterminalCount(ownedBy ownerID: String) -> Int {
        store.runs.filter { $0.owner.ownerID == ownerID && $0.status.isNonterminal }.count
    }

    func run(id: DiagnosticRunID) -> DiagnosticRun? {
        store.run(id: id)
    }

    func runs(ownedBy ownerID: String) -> [DiagnosticRun] {
        store.runs.filter { $0.owner.ownerID == ownerID }
    }

    // MARK: - Observation (AN-3)

    /// Applies live observation summaries without persisting. Capture ingest must not write JSON.
    func applyObservationSummaries(_ summaries: [DiagnosticRunID: DiagnosticRunObservationSummary]) {
        guard !summaries.isEmpty else { return }
        for (runID, summary) in summaries {
            guard var run = store.run(id: runID) else { continue }
            guard run.status == .watching || run.status == .active else { continue }
            run.observationSummary = summary
            run.lastUpdatedAt = clock()
            store.replaceInMemory(run)
        }
        publish()
    }

    /// Cursored observation page for one owned run.
    func listObservations(
        id: DiagnosticRunID,
        requestingOwnerID: String,
        cursor: DiagnosticObservationCursor? = nil,
        limit: Int = DiagnosticRunBudget.observationPageDefault,
        afterMarker: UUID? = nil,
        beforeMarker: UUID? = nil
    ) async throws -> DiagnosticRunObservationPage {
        _ = try ownedRun(id: id, requestingOwnerID: requestingOwnerID)
        guard let observationIndex else { throw DiagnosticRunError.observationUnavailable }
        return try await observationIndex.page(
            runID: id,
            ownerID: requestingOwnerID,
            cursor: cursor,
            limit: limit,
            afterMarker: afterMarker,
            beforeMarker: beforeMarker,
            synthesizeAbsenceIfEmpty: beforeMarker != nil,
            now: clock()
        )
    }

    /// Subscribes to coalesced observation notifications for one owned run.
    func subscribeObservations(
        id: DiagnosticRunID,
        requestingOwnerID: String
    ) async throws -> UUID {
        _ = try ownedRun(id: id, requestingOwnerID: requestingOwnerID)
        guard let observationIndex else { throw DiagnosticRunError.observationUnavailable }
        return try await observationIndex.subscribe(runID: id, ownerID: requestingOwnerID)
    }

    func unsubscribeObservations(_ subscriberID: UUID) async {
        await observationIndex?.unsubscribe(subscriberID)
    }

    func drainObservationNotifications(subscriberID: UUID) async -> DiagnosticRunObservationNotification? {
        await observationIndex?.drainNotifications(subscriberID: subscriberID)
    }

    // MARK: - Evidence (AN-4)

    /// Owner-scoped paginated list of immutable evidence records.
    func listEvidence(
        requestingOwnerID: String,
        limit: Int = DiagnosticRunBudget.listPageDefault,
        offset: Int = 0
    ) throws -> DiagnosticEvidenceListPage {
        try requireStore()
        return store.listEvidence(ownerID: requestingOwnerID, limit: limit, offset: offset)
    }

    /// Returns one evidence record when the caller owns it.
    func evidenceRecord(
        id: UUID,
        requestingOwnerID: String
    ) throws -> DiagnosticEvidenceRecord {
        try requireStore()
        guard let record = store.evidenceRecord(id: id) else {
            throw DiagnosticRunError.evidenceNotFound
        }
        guard record.ownerID == requestingOwnerID else {
            throw DiagnosticRunError.notOwner
        }
        return record
    }

    /// Returns evidence for a terminal run when the caller owns it.
    func evidenceRecord(
        forRunID runID: DiagnosticRunID,
        requestingOwnerID: String
    ) throws -> DiagnosticEvidenceRecord {
        try requireStore()
        guard let record = store.evidenceRecord(forRunID: runID) else {
            throw DiagnosticRunError.evidenceNotFound
        }
        guard record.ownerID == requestingOwnerID else {
            throw DiagnosticRunError.notOwner
        }
        return record
    }

    /// Metadata-only disclosure projection for one owned evidence record.
    func disclosedEvidenceRecord(
        id: UUID,
        requestingOwnerID: String
    ) throws -> DiagnosticEvidenceDisclosedRecord {
        let record = try evidenceRecord(id: id, requestingOwnerID: requestingOwnerID)
        return DiagnosticRunEvidenceMaterializer.disclosed(record)
    }

    /// Full export envelope for local backup or future MCP/CLI surfaces.
    func exportEvidence(
        id: UUID,
        requestingOwnerID: String
    ) throws -> DiagnosticRunEvidenceExportEnvelope {
        let record = try evidenceRecord(id: id, requestingOwnerID: requestingOwnerID)
        return DiagnosticRunEvidenceExportEnvelope(
            schemaVersion: DiagnosticEvidenceSchemaVersion.current,
            exportedAt: clock(),
            record: record
        )
    }

    /// Updates editable human notes without changing digests or immutable provenance.
    func updateEvidenceNotes(
        id: UUID,
        requestingOwnerID: String,
        notes: String?
    ) throws -> DiagnosticEvidenceRecord {
        try requireStore()
        return try store.updateEditableNotes(recordID: id, ownerID: requestingOwnerID, notes: notes)
    }

    /// Verifies stored digests still match immutable provenance.
    func verifyEvidenceIntegrity(id: UUID, requestingOwnerID: String) throws -> Bool {
        let record = try evidenceRecord(id: id, requestingOwnerID: requestingOwnerID)
        return try DiagnosticRunEvidenceMaterializer.verifyIntegrity(record)
    }

    // MARK: - Private

    private func finishClosing(
        _ run: DiagnosticRun,
        requestingOwnerID: String
    ) async throws -> DiagnosticRun {
        var working = run
        if !working.installedWatchIDs.isEmpty {
            await watchInstaller.removeWatches(working.installedWatchIDs)
            working.installedWatchIDs = []
        }
        await observationIndex?.stopRun(working.id)
        if let absenceSummary = await observationIndex?.recordAbsenceIfNeeded(
            runID: working.id,
            at: clock()
        ) {
            working.observationSummary = absenceSummary
        } else if let liveSummary = await observationIndex?.summary(for: working.id) {
            working.observationSummary = liveSummary
        }

        let startedAt = working.cleanupProof?.startedAt ?? clock()
        var checked: [String] = []
        var cleaned: [String] = []
        var observeOnly: [String] = []
        var conflicts: [String] = []

        for reference in working.references {
            let refID = "\(reference.kind.rawValue):\(reference.opaqueID)"
            switch reference.relationship {
            case .evidence, .observeOnly:
                observeOnly.append(refID)
                checked.append(refID)
            case .ownerScopedCleanup:
                checked.append(refID)
                let result = await effectResolver.requestRiskReducingCleanup(
                    kind: reference.kind,
                    opaqueID: reference.opaqueID,
                    requestingOwnerID: requestingOwnerID
                )
                if result.cleaned {
                    cleaned.append(refID)
                } else if let code = result.conflictReasonCode {
                    conflicts.append(code)
                } else {
                    conflicts.append("cleanup_failed")
                }
            }
        }

        var remainingLive = 0
        for reference in working.references where reference.relationship == .ownerScopedCleanup {
            if case .live = await effectResolver.liveState(kind: reference.kind, opaqueID: reference.opaqueID) {
                remainingLive += 1
            }
        }

        let completedAt = clock()
        var proof = DiagnosticRunCleanupProof(
            startedAt: startedAt,
            completedAt: completedAt,
            checkedReferenceIDs: Array(checked.prefix(DiagnosticRunBudget.maxCleanupConflictsPerRun)),
            cleanedReferenceIDs: Array(cleaned.prefix(DiagnosticRunBudget.maxCleanupConflictsPerRun)),
            observeOnlyReferenceIDs: Array(observeOnly.prefix(DiagnosticRunBudget.maxCleanupConflictsPerRun)),
            conflictReasonCodes: Array(conflicts.prefix(DiagnosticRunBudget.maxCleanupConflictsPerRun)),
            remainingLiveEffectCount: remainingLive,
            policyRevision: policyRevisionProvider(),
            verifiedClean: remainingLive == 0 && conflicts.isEmpty,
            verificationDigest: nil
        )
        proof.verificationDigest = try? DiagnosticRunValidation.digest(proof)
        working.cleanupProof = proof
        working.lastUpdatedAt = completedAt

        if proof.verifiedClean {
            let terminal = working.requestedTerminal ?? .inconclusive
            working.status = status(for: terminal)
            working.terminalAt = completedAt
            if working.status == .inconclusive, working.conclusion == nil {
                working.conclusion = DiagnosticRunConclusion(
                    outcome: .inconclusive,
                    reasonCode: .operationInterrupted,
                    summary: "Run closed without a conclusive observation.",
                    confidence: .unassessed,
                    concludedAt: completedAt,
                    evidenceDigest: ""
                )
            }
            try await persistEvidenceIfNeeded(for: &working)
        } else {
            working.status = .cleanupRequired
        }
        try store.upsert(working)
        publish()
        if !proof.verifiedClean {
            throw DiagnosticRunError.cleanupNotVerified
        }
        return working
    }

    /// Materializes one immutable evidence record after verified terminal close (AN-4).
    private func persistEvidenceIfNeeded(for run: inout DiagnosticRun) async throws {
        guard run.status.isPrunableTerminal else { return }
        guard run.cleanupProof?.verifiedClean == true else { return }
        if store.evidenceRecord(forRunID: run.id) != nil {
            if var conclusion = run.conclusion,
               let existing = store.evidenceRecord(forRunID: run.id) {
                conclusion.evidenceDigest = existing.evidenceDigest
                run.conclusion = conclusion
            }
            return
        }
        let observations = await observationIndex?.exportObservations(runID: run.id) ?? []
        let record = try DiagnosticRunEvidenceMaterializer.materialize(
            run: run,
            observations: observations,
            now: clock()
        )
        try store.appendEvidence(record)
        if var conclusion = run.conclusion {
            conclusion.evidenceDigest = record.evidenceDigest
            run.conclusion = conclusion
        }
    }

    private func reconcileWatchingAfterRelaunch(_ id: DiagnosticRunID) async {
        guard var run = store.run(id: id), run.status == .watching else { return }
        run.installedWatchIDs = []
        let now = clock()
        run.conclusion = DiagnosticRunConclusion(
            outcome: .inconclusive,
            reasonCode: .operationInterrupted,
            summary: "Observation interrupted by application relaunch.",
            confidence: .unassessed,
            concludedAt: now,
            evidenceDigest: ""
        )
        run.requestedTerminal = .inconclusive
        run.status = .closing
        run.closingStartedAt = now
        try? store.upsert(run)
        _ = try? await finishClosing(run, requestingOwnerID: run.owner.ownerID)
        publish()
    }

    private func synthesizeExpiredDraft(_ run: DiagnosticRun, now: Date) -> DiagnosticRun {
        var expired = run
        var proof = DiagnosticRunCleanupProof(
            startedAt: now,
            completedAt: now,
            checkedReferenceIDs: [],
            cleanedReferenceIDs: [],
            observeOnlyReferenceIDs: [],
            conflictReasonCodes: [],
            remainingLiveEffectCount: 0,
            policyRevision: policyRevisionProvider(),
            verifiedClean: true,
            verificationDigest: nil
        )
        proof.verificationDigest = try? DiagnosticRunValidation.digest(proof)
        expired.cleanupProof = proof
        expired.status = .expired
        expired.requestedTerminal = .expired
        expired.terminalAt = now
        expired.lastUpdatedAt = now
        return expired
    }

    private func refreshActiveState(_ run: DiagnosticRun) async throws -> DiagnosticRun {
        guard run.status == .watching || run.status == .active else { return run }
        let liveCount = try await ownerScopedLiveCount(for: run)
        var updated = run
        if liveCount > 0 {
            updated.status = .active
            updated.activeAt = updated.activeAt ?? clock()
        } else {
            updated.status = .watching
            updated.activeAt = nil
        }
        return updated
    }

    private func ownerScopedLiveCount(for run: DiagnosticRun) async throws -> Int {
        var count = 0
        for reference in run.references where reference.relationship == .ownerScopedCleanup {
            if case .live = await effectResolver.liveState(kind: reference.kind, opaqueID: reference.opaqueID) {
                count += 1
            }
        }
        return count
    }

    private func normalizeScopes(_ scopes: [DiagnosticRunScope]) throws -> [DiagnosticRunScope] {
        try scopes.map { scope in
            switch scope {
            case .http(let http):
                return .http(try DiagnosticRunValidation.normalizedHTTPScope(http))
            case .capturedSession, .effect:
                try DiagnosticRunValidation.validateScope(scope)
                return scope
            }
        }
    }

    private func enforceCreateQuotas(owner: DiagnosticRunOwner) throws {
        let nonterminal = store.runs.filter(\.status.isNonterminal)
        guard nonterminal.count < DiagnosticRunBudget.maxConcurrentNonterminalGlobal else {
            throw DiagnosticRunError.quotaExceeded("Global nonterminal diagnostic-run quota reached.")
        }
        let owned = nonterminal.filter { $0.owner.ownerID == owner.ownerID }
        let limit = owner.ownerID == DiagnosticRunOwner.localUserOwnerID
            ? DiagnosticRunBudget.maxConcurrentNonterminalLocalUser
            : DiagnosticRunBudget.maxConcurrentNonterminalPerMCPOwner
        guard owned.count < limit else {
            throw DiagnosticRunError.quotaExceeded("Owner nonterminal diagnostic-run quota reached.")
        }
    }

    private func ownedRun(id: DiagnosticRunID, requestingOwnerID: String) throws -> DiagnosticRun {
        try requireStore()
        guard let run = store.run(id: id) else { throw DiagnosticRunError.runNotFound }
        guard run.owner.ownerID == requestingOwnerID else { throw DiagnosticRunError.notOwner }
        return run
    }

    private func status(for terminal: DiagnosticRunRequestedTerminal) -> DiagnosticRunStatus {
        switch terminal {
        case .passed: return .passed
        case .failed: return .failed
        case .inconclusive: return .inconclusive
        case .expired: return .expired
        }
    }

    private func requireStore() throws {
        guard store.isLoaded else {
            throw DiagnosticRunError.storeUnavailable(store.loadFailureReason ?? "Diagnostic-run store unavailable.")
        }
    }

    private func publish() {
        runs = store.runs.sorted { $0.createdAt > $1.createdAt }
    }
}
