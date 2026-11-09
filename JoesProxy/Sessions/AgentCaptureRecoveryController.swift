import Foundation
import Combine

/// Agent-owned rolling-capture restore path.
///
/// This controller owns no session presentation state. It preserves the existing safety contract:
/// one restore at a time, no replacement once capture has changed, and a distinct restore epoch.
@MainActor
final class AgentCaptureRecoveryController: ObservableObject {
    private let sessionStore: any SessionStore
    private let persistence: RollingCapturePersistenceCoordinator
    let diagnosticsCoordinator: PreviousRunDiagnosticsCoordinator?
    @Published private(set) var isRestoring = false
    @Published private(set) var resultMessage: String?
    @Published private(set) var hasSessions: Bool
    private var availabilityObservation: AnyCancellable?

    init(
        sessionStore: any SessionStore,
        persistence: RollingCapturePersistenceCoordinator,
        diagnosticsCoordinator: PreviousRunDiagnosticsCoordinator? = nil
    ) {
        self.sessionStore = sessionStore
        self.persistence = persistence
        self.diagnosticsCoordinator = diagnosticsCoordinator
        hasSessions = !sessionStore.sessions.isEmpty
        availabilityObservation = sessionStore.sessionChangesPublisher
            .map { [weak sessionStore] _ in sessionStore?.sessions.isEmpty == false }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] available in
                if self?.hasSessions != available { self?.hasSessions = available }
            }
    }

    /// Suppresses the automatic restore prompt for the current saved snapshot without deleting it.
    /// A later explicit recovery review can still offer the same snapshot.
    func startFresh() {
        guard !isRestoring else { return }
        persistence.markRestoreDismissed()
        resultMessage = "The saved capture remains available for manual recovery."
    }

    func restoreLatestCapture() async throws -> Int {
        guard !isRestoring else { throw RollingCaptureRestoreError.alreadyRestoring }
        isRestoring = true
        resultMessage = nil
        defer { isRestoring = false }
        do {
            guard sessionStore.sessions.isEmpty else { throw RollingCaptureRestoreError.captureChanged }
            let sessions = try await persistence.restoreLatestSnapshotInBackground()
            try Task.checkCancellation()
            guard sessionStore.sessions.isEmpty else { throw RollingCaptureRestoreError.captureChanged }
            sessionStore.load(sessions: sessions, epochChangeReason: "capture_restored")
            resultMessage = "Restored \(sessions.count) sessions."
            return sessions.count
        } catch {
            resultMessage = error.localizedDescription
            throw error
        }
    }
}
