import Foundation
import NIOCore

/// Synchronous commit gate shared by response overrides and HLS routes.
///
/// Bundle components may be installed behind a closed gate, then become visible to request handling
/// in one lock-protected state transition. The same transition fails open on stop before individual
/// components are removed. The lock is intentionally synchronous because both request hot paths
/// need a low-cost lookup without an additional actor hop.
final class EffectBundleActivationGate: @unchecked Sendable {
    struct PhaseIdentity: Equatable, Sendable {
        let bundleID: UUID
        let activationID: UUID
        let phaseID: UUID
    }
    static let shared = EffectBundleActivationGate()

    private let lock = NSLock()
    private var openBundleIDs = Set<UUID>()
    private var phaseRuleIDs: [UUID: Set<UUID>] = [:]
    private var bundleIDByResponseRuleID: [UUID: UUID] = [:]
    private var bundleIDByHLSExperimentID: [UUID: UUID] = [:]
    private var resources: [UUID: EffectBundleResourceIdentity] = [:]
    private var phaseIdentities: [UUID: PhaseIdentity] = [:]
    private var observations: [EffectBundleObservation] = []
    private var observationIdentities: [UUID: EffectBundleObservation.Identity] = [:]
    private var marker: UInt64 = 0
    private var evictedThroughMarker: UInt64 = 0
    private let timelineID = UUID()
    private let now: @Sendable () -> CaptureObservationInstant
    private var markerInstants: [(marker: UInt64, instant: CaptureObservationInstant)]

    init(now: @escaping @Sendable () -> CaptureObservationInstant = { .now() }) {
        self.now = now
        markerInstants = [(0, now())]
    }

    /// Called under the gate lock; retains no request content or session references.
    private func advanceMarker() -> CaptureObservationInstant {
        marker += 1
        let instant = now()
        markerInstants.append((marker, instant))
        if markerInstants.count > 512 { markerInstants.removeFirst() }
        return instant
    }

    // Protected by the existing gate lock. Hashing and transport never run under this lock.
    func registerResources(manifest: EffectBundleManifest, activationID: UUID = UUID(), renderedHashes: [UUID: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        for id in manifest.responseEffects.map(\.id) + manifest.hlsSubstitutions.map(\.id) {
            observationIdentities[id] = .init(bundleID: manifest.id, revisionID: manifest.authoring?.revisionID ?? manifest.id,
                activationID: activationID, resourceID: id,
                phaseID: manifest.phases?.first { $0.responseEffectIDs.contains(id) || $0.hlsSubstitutionIDs.contains(id) }?.id)
        }
        for phase in manifest.phases ?? [] {
            for id in phase.responseEffectIDs {
                phaseIdentities[id] = .init(bundleID: manifest.id, activationID: activationID, phaseID: phase.id)
            }
        }
        for effect in manifest.responseEffects where effect.bodySource.assetIDs.count == 1 {
            guard let asset = manifest.assets.first(where: { $0.id == effect.bodySource.assetIDs[0] }) else { continue }
            resources[effect.id] = .init(bundleID: manifest.id, revisionID: manifest.authoring?.revisionID ?? manifest.id,
                activationID: activationID, resourceID: effect.id, assetID: asset.id, expectedSHA256: asset.sha256,
                phaseID: manifest.phases?.first { $0.responseEffectIDs.contains(effect.id) }?.id,
                materializedSHA256: renderedHashes[effect.id])
        }
    }

    func resource(ruleID: UUID, requireOpen: Bool = true) -> EffectBundleResourceIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let resource = resources[ruleID], !requireOpen || openBundleIDs.contains(resource.bundleID) else { return nil }
        return resource
    }

    func phaseIdentity(ruleID: UUID) -> PhaseIdentity? {
        lock.withLock { phaseIdentities[ruleID] }
    }

    func setMediaPhase(bundleID: UUID, phaseID: UUID) {
        lock.withLock {
            for id in bundleIDByHLSExperimentID.keys where bundleIDByHLSExperimentID[id] == bundleID {
                observationIdentities[id]?.phaseID = phaseID
            }
        }
    }

    func observationSnapshot(bundleID: UUID) -> [EffectBundleObservation] {
        lock.withLock { observations.filter { $0.identity.bundleID == bundleID } }
    }

    func observationCheckpoint() -> (marker: UInt64, timelineID: UUID) {
        lock.withLock { (marker, timelineID) }
    }

    func bundleID(responseRuleID: UUID) -> UUID? {
        lock.withLock { bundleIDByResponseRuleID[responseRuleID] }
    }

    func observe(resource: EffectBundleResourceIdentity, servedSHA256: String?,
                 evaluation: EffectBundleDeliveryReceipt.Evaluation = .responseResolved) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let instant = advanceMarker()
        let id = UUID()
        var receipt = EffectBundleDeliveryReceipt(id: id, marker: marker, resource: resource, servedSHA256: servedSHA256,
            matchesReviewedAsset: servedSHA256.map { $0 == resource.expectedSHA256 }, observedAt: instant.date)
        receipt.evaluation = evaluation
        receipt.matchesMaterializedAsset = resource.materializedSHA256.flatMap { expected in servedSHA256.map { $0 == expected } }
        if evaluation != .responseResolved { receipt.delivery = .notApplied }
        appendObservation(.init(id: id, marker: marker,
            identity: .init(bundleID: resource.bundleID, revisionID: resource.revisionID,
                activationID: resource.activationID, resourceID: resource.resourceID, phaseID: resource.phaseID),
            kind: .authoredResponse, observedAt: instant.date, outcome: evaluation.rawValue,
            delivery: receipt.delivery, authored: receipt))
        return id
    }

    func observationIdentity(resourceID: UUID, requireOpen: Bool = true) -> EffectBundleObservation.Identity? {
        lock.withLock {
            guard let identity = observationIdentities[resourceID], !requireOpen || openBundleIDs.contains(identity.bundleID) else { return nil }
            return identity
        }
    }

    func observe(identity: EffectBundleObservation.Identity, kind: EffectBundleObservation.Kind,
                 outcome: String, preparedMediaID: UUID? = nil, segmentSequence: Int? = nil,
                 segmentPath: String? = nil, textTrack: HLSWebVTTFixture.TrackIdentity? = nil) -> UUID {
        lock.withLock {
            let instant = advanceMarker()
            let id = UUID()
            appendObservation(.init(id: id, marker: marker, identity: identity, kind: kind,
                observedAt: instant.date, outcome: String(outcome.prefix(128)),
                preparedMediaID: preparedMediaID, segmentSequence: segmentSequence,
                segmentPath: segmentPath.map { $0.count > 512 ? String($0.prefix(512)) + " [truncated]" : $0 }, textTrack: textTrack))
            return id
        }
    }

    private func appendObservation(_ observation: EffectBundleObservation) {
        observations.append(observation)
        if observations.count > 256 {
            evictedThroughMarker = max(evictedThroughMarker, observations.removeFirst().marker)
        }
    }

    func updateOutcome(id: UUID, outcome: String) {
        lock.withLock {
            guard let index = observations.firstIndex(where: { $0.id == id }) else { return }
            _ = advanceMarker()
            observations[index].marker = marker
            observations[index].outcome = String(outcome.prefix(128))
            observations.sort { $0.marker < $1.marker }
        }
    }

    func completeReceipt(id: UUID, succeeded: Bool? = nil, sessionID: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = observations.firstIndex(where: { $0.id == id }) else { return }
        guard (sessionID != nil && observations[index].sessionID != sessionID)
            || (succeeded != nil && observations[index].delivery == .pending) else { return }
        let instant = advanceMarker()
        observations[index].marker = marker
        if let sessionID { observations[index].sessionID = sessionID }
        if let succeeded, observations[index].delivery == .pending {
            observations[index].delivery = succeeded ? .downstreamWriteSucceeded : .downstreamWriteFailed
            observations[index].completedAt = instant.date
        }
        var observation = observations[index]
        observation.authored?.marker = marker
        observation.authored?.sessionID = observation.sessionID
        observation.authored?.delivery = observation.delivery
        observation.authored?.completedAt = observation.completedAt
        observations[index] = observation
        observations.sort { $0.marker < $1.marker }
    }

    func trackDelivery(_ future: EventLoopFuture<Void>, receiptID: UUID) {
        future.whenComplete { result in
            switch result {
            case .success: self.completeReceipt(id: receiptID, succeeded: true)
            case .failure: self.completeReceipt(id: receiptID, succeeded: false)
            }
        }
    }

    /// Authorization belongs to the repository-backed caller, before querying this process-local cache.
    func retainedReceipt(id: UUID, bundleID: UUID) -> EffectBundleDeliveryReceipt? {
        lock.lock()
        defer { lock.unlock() }
        return observations.first { $0.id == id && $0.identity.bundleID == bundleID }?.authored
    }

    func observationMarker() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        _ = advanceMarker()
        return marker
    }

    func evidence(bundleID: UUID, after: UInt64 = 0) -> EffectBundleDeliveryEvidence {
        lock.lock()
        defer { lock.unlock() }
        let invalidMarker = after > marker
        let cursor = invalidMarker ? 0 : after
        let matches = observations.filter { $0.identity.bundleID == bundleID && $0.marker > cursor }
        let page = Array(matches.prefix(32))
        let gap = after < evictedThroughMarker
        let start = markerInstants.first { $0.marker == after }?.instant
        // A final/empty page establishes a fresh checkpoint even if no requests arrived.
        // Reusing the last traffic marker would keep including old gaps in later idle windows.
        let end = matches.count > 32
            ? markerInstants.first { $0.marker == page.last!.marker }?.instant ?? now()
            : advanceMarker()
        let next = matches.count > 32 ? page.last!.marker : marker
        return .init(receipts: page.compactMap(\.authored), nextMarker: next,
            retentionGap: gap || invalidMarker, hasMore: matches.count > 32,
            observationState: page.isEmpty ? "noRetainedObservation" : "observed",
            window: .init(timelineID: timelineID, afterMarker: after, throughMarker: next,
                start: start, end: end,
                startState: invalidMarker ? "futureOrRestartedMarker" : start == nil ? "markerTimeEvicted" : "available"), observations: page)
    }

    func register(bundleID: UUID, responseRuleIDs: Set<UUID>, hlsExperimentIDs: Set<UUID>) {
        lock.lock()
        defer { lock.unlock() }
        openBundleIDs.remove(bundleID)
        phaseRuleIDs.removeValue(forKey: bundleID)
        for ruleID in responseRuleIDs {
            bundleIDByResponseRuleID[ruleID] = bundleID
        }
        for experimentID in hlsExperimentIDs {
            bundleIDByHLSExperimentID[experimentID] = bundleID
        }
    }

    /// Commit a prepared response-only generation. Old asset rules can remain reachable, while
    /// new request matching moves to the selected phase in one lock-protected operation.
    func selectPhase(bundleID: UUID, responseRuleIDs: Set<UUID>, collectionRuleIDs: Set<UUID> = []) {
        lock.lock()
        defer { lock.unlock() }
        // Staging all reviewed rules must not consume a later phase's live-mutation lifetime.
        // The tracker never calls back into this gate; no reverse lock acquisition is permitted.
        let entering = responseRuleIDs.subtracting(phaseRuleIDs[bundleID] ?? []).intersection(collectionRuleIDs)
        for id in entering { LiveTransformationActivationTracker.shared.recordActivationStart(ruleID: id) }
        phaseRuleIDs[bundleID] = responseRuleIDs
    }

    func open(bundleID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        openBundleIDs.insert(bundleID)
    }

    func close(bundleID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        openBundleIDs.remove(bundleID)
    }

    func unregister(bundleID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        openBundleIDs.remove(bundleID)
        phaseRuleIDs.removeValue(forKey: bundleID)
        resources = resources.filter { $0.value.bundleID != bundleID }
        observationIdentities = observationIdentities.filter { $0.value.bundleID != bundleID }
        phaseIdentities = phaseIdentities.filter { $0.value.bundleID != bundleID }
        bundleIDByResponseRuleID = bundleIDByResponseRuleID.filter { $0.value != bundleID }
        bundleIDByHLSExperimentID = bundleIDByHLSExperimentID.filter { $0.value != bundleID }
    }

    func allows(responseRuleID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let bundleID = bundleIDByResponseRuleID[responseRuleID] else { return true }
        return openBundleIDs.contains(bundleID)
            && (phaseRuleIDs[bundleID]?.contains(responseRuleID) ?? true)
    }

    func allows(bundleID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return openBundleIDs.contains(bundleID)
    }

    func allows(hlsExperimentID: UUID) -> Bool {
        hlsAdmission(experimentID: hlsExperimentID).allowed
    }

    /// Copy admission and attribution together so Advance cannot relabel accepted work.
    func hlsAdmission(experimentID: UUID) -> (allowed: Bool, observation: EffectBundleObservation.Identity?) {
        lock.lock()
        defer { lock.unlock() }
        guard let bundleID = bundleIDByHLSExperimentID[experimentID] else { return (true, nil) }
        guard openBundleIDs.contains(bundleID) else { return (false, nil) }
        return (true, observationIdentities[experimentID])
    }
}
