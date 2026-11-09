import Combine
import Foundation

/// Main-actor bridge from ``SessionStore`` into ``DiagnosticRunObservationIndex``.
///
/// Extracts Sendable capture facts (no bodies, headers, or query values) and hops to the
/// observation actor. Never performs diagnostic-run persistence on the ingest path.
///
/// Concurrency: `@MainActor` — observes the main-actor session store; matching runs off-main
/// in the observation actor.
@MainActor
final class DiagnosticRunCaptureBridge {
    private let snapshotService: MCPSessionSnapshotService
    private let index: DiagnosticRunObservationIndex
    private let coordinator: DiagnosticRunCoordinator
    private var cancellable: AnyCancellable?

    init(
        sessionStore: any SessionStore,
        snapshotService: MCPSessionSnapshotService,
        index: DiagnosticRunObservationIndex,
        coordinator: DiagnosticRunCoordinator
    ) {
        self.snapshotService = snapshotService
        self.index = index
        self.coordinator = coordinator
        cancellable = sessionStore.sessionChangesPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                self?.handle(change)
            }
    }

    private func handle(_ change: SessionStoreChange) {
        switch change {
        case .appended(let session, _):
            forward(session)
        case .updated(let session, _):
            forward(session)
        case .updatedBatch(let sessions, _):
            for session in sessions {
                forward(session)
            }
        case .bodiesStripped, .removed:
            break
        case .cleared:
            coordinator.noteExperimentCaptureReset()
            Task { [weak self] in
                guard let self else { return }
                let result = await self.index.noteCaptureEpochChange(
                    to: self.snapshotService.captureEpoch,
                    reason: .captureEpochChanged,
                    at: Date()
                )
                self.coordinator.applyObservationSummaries(result.updatedSummaries)
            }
        case .loaded:
            coordinator.noteExperimentCaptureReset()
            Task { [weak self] in
                guard let self else { return }
                let result = await self.index.noteCaptureEpochChange(
                    to: self.snapshotService.captureEpoch,
                    reason: .captureEpochChanged,
                    at: Date()
                )
                self.coordinator.applyObservationSummaries(result.updatedSummaries)
            }
        }
    }

    private func forward(_ session: SessionRecord) {
        if session.state == .completed || session.state == .failed {
            coordinator.completeExperimentObservation(sessionID: session.id,
                status: session.response?.statusCode, duration: session.timing.duration)
        }
        let captureSequence = snapshotService.indexedSession(id: session.id)?.captureSequence ?? 0
        guard let event = DiagnosticRunCaptureEvent.make(
            from: session,
            captureSequence: captureSequence,
            captureEpoch: snapshotService.captureEpoch
        ) else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.index.ingest(event)
            self.coordinator.applyObservationSummaries(result.updatedSummaries)
        }
    }
}

/// Live `DiagnosticRunCaptureHistoryQuerying` adapter over the same session snapshot index the
/// capture bridge observes live — used by regression re-check to synchronously re-scan
/// already-captured sessions instead of installing a new watch.
@MainActor
final class MCPSessionSnapshotCaptureHistory: DiagnosticRunCaptureHistoryQuerying {
    private let snapshotService: MCPSessionSnapshotService

    init(snapshotService: MCPSessionSnapshotService) {
        self.snapshotService = snapshotService
    }

    func capturedEvents(since: Date) -> [DiagnosticRunCaptureEvent] {
        snapshotService.allIndexedSessions.compactMap { indexed in
            guard let event = DiagnosticRunCaptureEvent.make(
                from: indexed.record,
                captureSequence: indexed.captureSequence,
                captureEpoch: snapshotService.captureEpoch
            ) else { return nil }
            return event.observedAt >= since ? event : nil
        }
    }
}
