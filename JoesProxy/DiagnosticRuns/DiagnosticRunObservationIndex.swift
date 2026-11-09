import Foundation

/// Off-main-actor scoped observation index (AN-3).
///
/// Filters capture facts by installed run watches before any agent-facing publication. Matching,
/// coalescing, and cursor state live here so the proxy request path never blocks on run I/O.
///
/// Concurrency: `actor` — ingest from the capture bridge; coordinator reads/subscribes await this
/// boundary. Does not persist; AN-4 owns immutable evidence records.
actor DiagnosticRunObservationIndex {
    private struct RunState {
        var ownerID: String
        var watches: [UUID: DiagnosticInstalledWatch] = [:]
        var observations: [DiagnosticRunObservationRecord] = []
        var nextSequence: UInt64 = 1
        var summary = DiagnosticRunObservationSummary.empty
        var ingestedSessionIDs: Set<UUID> = []
        var lastMarker: (id: UUID, sequence: UInt64, observedAt: Date)?
        var previousMarker: (id: UUID, sequence: UInt64, observedAt: Date)?
        var watchingStartedAt: Date
        var acceptsIngest = true
    }

    private struct Subscriber {
        var runID: DiagnosticRunID
        var ownerID: String
        var pending: DiagnosticRunObservationNotification?
        var accumulatedDropped = 0
    }

    private var runs: [DiagnosticRunID: RunState] = [:]
    private var watchToRun: [UUID: DiagnosticRunID] = [:]
    private var subscribers: [UUID: Subscriber] = [:]

    /// Installs already-resolved watches. Partial installs are the caller's responsibility to roll back.
    func installWatches(
        _ watches: [DiagnosticInstalledWatch],
        watchingStartedAt: Date
    ) throws -> [UUID] {
        guard !watches.isEmpty else {
            throw DiagnosticRunError.invalidScopes("At least one scope is required.")
        }
        var ids: [UUID] = []
        for watch in watches {
            var state = runs[watch.runID] ?? RunState(
                ownerID: watch.ownerID,
                watchingStartedAt: watchingStartedAt
            )
            state.ownerID = watch.ownerID
            state.watches[watch.id] = watch
            state.acceptsIngest = true
            runs[watch.runID] = state
            watchToRun[watch.id] = watch.runID
            ids.append(watch.id)
        }
        return ids
    }

    /// Removes watches and stops ingest when a run has none left. Idempotent.
    func removeWatches(_ watchIDs: [UUID]) {
        var affected = Set<DiagnosticRunID>()
        for watchID in watchIDs {
            guard let runID = watchToRun.removeValue(forKey: watchID) else { continue }
            runs[runID]?.watches.removeValue(forKey: watchID)
            affected.insert(runID)
        }
        for runID in affected {
            guard var state = runs[runID] else { continue }
            if state.watches.isEmpty {
                state.acceptsIngest = false
                runs[runID] = state
                removeSubscribers(runID: runID)
            }
        }
    }

    /// Stops ingest and subscriptions for one run without deleting already-recorded observations.
    func stopRun(_ runID: DiagnosticRunID) {
        runs[runID]?.acceptsIngest = false
        removeSubscribers(runID: runID)
    }

    func ingest(_ event: DiagnosticRunCaptureEvent) -> DiagnosticRunIngestResult {
        var updated: [DiagnosticRunID: DiagnosticRunObservationSummary] = [:]
        for (runID, _) in runs {
            if let summary = ingest(event, into: runID) {
                updated[runID] = summary
            }
        }
        return DiagnosticRunIngestResult(updatedSummaries: updated)
    }

    /// Marks every watching run's evidence unavailable and invalidates epoch-bound cursors.
    func noteCaptureEpochChange(
        to newEpoch: MCPCaptureEpoch,
        reason: DiagnosticEvidenceUnavailableReason,
        at observedAt: Date
    ) -> DiagnosticRunIngestResult {
        var updated: [DiagnosticRunID: DiagnosticRunObservationSummary] = [:]
        for runID in runs.keys {
            guard var state = runs[runID], state.acceptsIngest else { continue }
            if !state.summary.captureEpochs.contains(newEpoch) {
                if state.summary.captureEpochs.count >= DiagnosticRunBudget.maxCaptureEpochsPerRun {
                    state.acceptsIngest = false
                } else {
                    state.summary.captureEpochs.append(newEpoch)
                }
            }
            state.summary.evidenceUnavailableReason = reason
            state.acceptsIngest = false
            append(
                DiagnosticRunObservationRecord(
                    id: UUID(),
                    runID: runID,
                    sequence: 0,
                    kind: .captureUnavailable,
                    observedAt: observedAt,
                    captureEpoch: newEpoch,
                    captureSequence: nil,
                    sessionID: nil,
                    method: nil,
                    scheme: nil,
                    host: nil,
                    port: nil,
                    path: nil,
                    statusFamily: nil,
                    latencyMilliseconds: nil,
                    attributionIDs: [],
                    markerID: nil,
                    unavailableReason: reason
                ),
                to: &state
            )
            runs[runID] = state
            notifySubscribers(runID: runID, state: state, extraDropped: 0)
            updated[runID] = state.summary
        }
        return DiagnosticRunIngestResult(updatedSummaries: updated)
    }

    func summary(for runID: DiagnosticRunID) -> DiagnosticRunObservationSummary? {
        runs[runID]?.summary
    }

    /// Returns a frozen copy of all observations for evidence materialization (AN-4).
    func exportObservations(runID: DiagnosticRunID) -> [DiagnosticRunObservationRecord] {
        runs[runID]?.observations ?? []
    }

    /// Cursored observation page. Marker bounds are inclusive of the after-marker sequence exclusive
    /// of the before-marker sequence when both are present.
    func page(
        runID: DiagnosticRunID,
        ownerID: String,
        cursor: DiagnosticObservationCursor?,
        limit: Int,
        afterMarker: UUID?,
        beforeMarker: UUID?,
        synthesizeAbsenceIfEmpty: Bool,
        now: Date
    ) throws -> DiagnosticRunObservationPage {
        guard let state = runs[runID] else {
            throw DiagnosticRunError.runNotFound
        }
        guard state.ownerID == ownerID else { throw DiagnosticRunError.notOwner }
        if let cursor {
            guard cursor.runID == runID, cursor.ownerID == ownerID else {
                throw DiagnosticRunError.cursorExpired
            }
            if state.summary.evidenceUnavailableReason == .captureEpochChanged,
               let currentEpoch = state.summary.captureEpochs.last,
               cursor.captureEpoch != currentEpoch {
                throw DiagnosticRunError.cursorExpired
            }
        }

        let boundedLimit = min(max(limit, 1), DiagnosticRunBudget.observationPageMax)
        var records = state.observations
        if let afterMarker {
            guard let marker = state.observations.first(where: { $0.kind == .marker && $0.markerID == afterMarker })
                    ?? state.observations.first(where: { $0.sessionID == afterMarker && $0.kind == .marker }) else {
                throw DiagnosticRunError.staleTarget("afterMarker was not observed on this run.")
            }
            records = records.filter { $0.sequence > marker.sequence }
        }
        if let beforeMarker {
            guard let marker = state.observations.first(where: { $0.kind == .marker && $0.markerID == beforeMarker })
                    ?? state.observations.first(where: { $0.sessionID == beforeMarker && $0.kind == .marker }) else {
                throw DiagnosticRunError.staleTarget("beforeMarker was not observed on this run.")
            }
            records = records.filter { $0.sequence < marker.sequence }
        }
        if let cursor {
            records = records.filter { $0.sequence > cursor.lastSequence }
        }

        if synthesizeAbsenceIfEmpty, beforeMarker != nil {
            let hasHitOrMiss = records.contains { $0.kind == .hit || $0.kind == .matcherMiss }
            if !hasHitOrMiss, !records.contains(where: { $0.kind == .absence }) {
                let absence = DiagnosticRunObservationRecord(
                    id: UUID(),
                    runID: runID,
                    sequence: records.last?.sequence ?? 0,
                    kind: .absence,
                    observedAt: now,
                    captureEpoch: state.summary.captureEpochs.last ?? MCPCaptureEpoch.initial,
                    captureSequence: nil,
                    sessionID: nil,
                    method: nil,
                    scheme: nil,
                    host: nil,
                    port: nil,
                    path: nil,
                    statusFamily: nil,
                    latencyMilliseconds: nil,
                    attributionIDs: [],
                    markerID: beforeMarker,
                    unavailableReason: nil
                )
                records.append(absence)
            }
        }

        let pageRecords = Array(records.prefix(boundedLimit))
        let next: DiagnosticObservationCursor?
        if pageRecords.count == boundedLimit, let last = pageRecords.last {
            next = DiagnosticObservationCursor(
                runID: runID,
                ownerID: ownerID,
                captureEpoch: last.captureEpoch,
                lastSequence: last.sequence
            )
        } else {
            next = nil
        }
        return DiagnosticRunObservationPage(
            records: pageRecords,
            nextCursor: next,
            droppedObservationCount: state.summary.droppedObservationCount,
            evidenceUnavailableReason: state.summary.evidenceUnavailableReason
        )
    }

    /// Inserts an absence record when the watching window produced neither hits nor misses.
    func recordAbsenceIfNeeded(runID: DiagnosticRunID, at observedAt: Date) -> DiagnosticRunObservationSummary? {
        guard var state = runs[runID] else { return nil }
        let hasHit = state.observations.contains { $0.kind == .hit }
        let hasMiss = state.observations.contains { $0.kind == .matcherMiss }
        let hasAbsence = state.observations.contains { $0.kind == .absence }
        guard !hasHit, !hasMiss, !hasAbsence else { return state.summary }
        let epoch = state.summary.captureEpochs.last ?? MCPCaptureEpoch.initial
        append(
            DiagnosticRunObservationRecord(
                id: UUID(),
                runID: runID,
                sequence: 0,
                kind: .absence,
                observedAt: observedAt,
                captureEpoch: epoch,
                captureSequence: nil,
                sessionID: nil,
                method: nil,
                scheme: nil,
                host: nil,
                port: nil,
                path: nil,
                statusFamily: nil,
                latencyMilliseconds: nil,
                attributionIDs: [],
                markerID: state.lastMarker?.id,
                unavailableReason: nil
            ),
            to: &state
        )
        runs[runID] = state
        notifySubscribers(runID: runID, state: state, extraDropped: 0)
        return state.summary
    }

    func subscribe(runID: DiagnosticRunID, ownerID: String) throws -> UUID {
        guard let state = runs[runID] else { throw DiagnosticRunError.runNotFound }
        guard state.ownerID == ownerID else { throw DiagnosticRunError.notOwner }
        let id = UUID()
        subscribers[id] = Subscriber(runID: runID, ownerID: ownerID, pending: nil)
        return id
    }

    func unsubscribe(_ subscriberID: UUID) {
        subscribers.removeValue(forKey: subscriberID)
    }

    /// Disconnect cleanup: drop every subscription owned by `ownerID`.
    func disconnect(ownerID: String) {
        subscribers = subscribers.filter { $0.value.ownerID != ownerID }
    }

    func drainNotifications(subscriberID: UUID) -> DiagnosticRunObservationNotification? {
        guard var subscriber = subscribers[subscriberID] else { return nil }
        let pending = subscriber.pending
        subscriber.pending = nil
        subscriber.accumulatedDropped = 0
        subscribers[subscriberID] = subscriber
        return pending
    }

    // MARK: - Private

    private func ingest(
        _ event: DiagnosticRunCaptureEvent,
        into runID: DiagnosticRunID
    ) -> DiagnosticRunObservationSummary? {
        guard var state = runs[runID], state.acceptsIngest, !state.watches.isEmpty else { return nil }
        if !state.summary.captureEpochs.contains(event.captureEpoch) {
            if state.summary.captureEpochs.count >= DiagnosticRunBudget.maxCaptureEpochsPerRun {
                state.acceptsIngest = false
                state.summary.evidenceUnavailableReason = .captureEpochChanged
                runs[runID] = state
                return state.summary
            }
            state.summary.captureEpochs.append(event.captureEpoch)
        }

        if event.isMarker {
            if state.ingestedSessionIDs.contains(event.sessionID) { return nil }
            state.ingestedSessionIDs.insert(event.sessionID)
            state.previousMarker = state.lastMarker
            state.lastMarker = (event.sessionID, state.nextSequence, event.observedAt)
            state.summary.lastMarkerID = event.sessionID
            append(
                DiagnosticRunObservationRecord(
                    id: UUID(),
                    runID: runID,
                    sequence: 0,
                    kind: .marker,
                    observedAt: event.observedAt,
                    captureEpoch: event.captureEpoch,
                    captureSequence: event.captureSequence,
                    sessionID: event.sessionID,
                    method: nil,
                    scheme: nil,
                    host: nil,
                    port: nil,
                    path: nil,
                    statusFamily: nil,
                    latencyMilliseconds: nil,
                    attributionIDs: [],
                    markerID: event.sessionID,
                    unavailableReason: nil
                ),
                to: &state
            )
            runs[runID] = state
            notifySubscribers(runID: runID, state: state, extraDropped: 0)
            return state.summary
        }

        if state.ingestedSessionIDs.contains(event.sessionID) {
            return nil
        }

        var best: DiagnosticRunScopeMatcher.Decision = .ignore
        for watch in state.watches.values {
            switch DiagnosticRunScopeMatcher.decision(for: event, watch: watch) {
            case .hit:
                best = .hit
            case .matcherMiss:
                if best != .hit { best = .matcherMiss }
            case .ignore:
                break
            }
        }
        guard best != .ignore else { return nil }
        state.ingestedSessionIDs.insert(event.sessionID)

        let kind: DiagnosticObservationKind = best == .hit ? .hit : .matcherMiss
        if kind == .hit {
            state.summary.matchedRequestCount += 1
            if let family = DiagnosticRunScopeMatcher.statusFamily(for: event.statusCode) {
                state.summary.statusFamilies[family, default: 0] += 1
            }
            if let latency = event.latencyMilliseconds {
                state.summary.minimumLatencyMilliseconds = min(
                    state.summary.minimumLatencyMilliseconds ?? latency,
                    latency
                )
                state.summary.maximumLatencyMilliseconds = max(
                    state.summary.maximumLatencyMilliseconds ?? latency,
                    latency
                )
            }
        } else {
            state.summary.matcherMissCount += 1
        }
        state.summary.lastObservedAt = event.observedAt

        append(
            DiagnosticRunObservationRecord(
                id: UUID(),
                runID: runID,
                sequence: 0,
                kind: kind,
                observedAt: event.observedAt,
                captureEpoch: event.captureEpoch,
                captureSequence: event.captureSequence,
                sessionID: event.sessionID,
                method: event.method,
                scheme: event.scheme,
                host: event.host,
                port: event.port,
                path: event.path,
                statusFamily: DiagnosticRunScopeMatcher.statusFamily(for: event.statusCode),
                latencyMilliseconds: event.latencyMilliseconds,
                attributionIDs: event.attributionIDs,
                markerID: nil,
                unavailableReason: nil
            ),
            to: &state
        )
        runs[runID] = state
        notifySubscribers(runID: runID, state: state, extraDropped: 0)
        return state.summary
    }

    private func append(_ record: DiagnosticRunObservationRecord, to state: inout RunState) {
        var stored = record
        stored.sequence = state.nextSequence
        state.nextSequence += 1
        if state.observations.count >= DiagnosticRunBudget.maxLiveObservationsPerRun {
            state.summary.droppedObservationCount += 1
            notifySubscribers(runID: stored.runID, state: state, extraDropped: 1)
            return
        }
        state.observations.append(stored)
    }

    private func notifySubscribers(runID: DiagnosticRunID, state: RunState, extraDropped: Int) {
        let latest = state.observations.last?.sequence ?? 0
        let epoch = state.summary.captureEpochs.last ?? MCPCaptureEpoch.initial
        for (id, subscriber) in subscribers where subscriber.runID == runID {
            var next = subscriber
            let dropped = next.accumulatedDropped + extraDropped
            if var pending = next.pending {
                pending.latestSequence = latest
                pending.captureEpoch = epoch
                pending.droppedEventCount += extraDropped
                next.pending = pending
            } else {
                next.pending = DiagnosticRunObservationNotification(
                    runID: runID,
                    latestSequence: latest,
                    captureEpoch: epoch,
                    droppedEventCount: dropped
                )
            }
            next.accumulatedDropped = 0
            subscribers[id] = next
        }
    }

    private func removeSubscribers(runID: DiagnosticRunID) {
        subscribers = subscribers.filter { $0.value.runID != runID }
    }
}
