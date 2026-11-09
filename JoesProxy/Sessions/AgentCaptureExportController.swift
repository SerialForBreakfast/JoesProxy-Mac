import Foundation
import Combine

/// Saves the shared capture without constructing Inspector rows, selection, or export state.
/// The caller selects a destination; this shared owner retains progress and the result when
/// a supervision window is dismissed. Accepted file writes finish rather than being abandoned.
@MainActor
final class AgentCaptureExportController: ObservableObject {
    enum ExportError: LocalizedError {
        case noSessions
        case alreadySaving

        var errorDescription: String? {
            switch self {
            case .noSessions:
                return "There are no captured sessions to save."
            case .alreadySaving:
                return "A capture export is already running."
            }
        }
    }

    private let sessionStore: any SessionStore
    private let configuration: any AppConfiguration
    private let recordingService: JSONSessionExportService
    @Published private(set) var isSaving = false
    @Published private(set) var resultMessage: String?
    @Published private(set) var hasSessions: Bool
    private var availabilityObservation: AnyCancellable?

    init(
        sessionStore: any SessionStore,
        configuration: any AppConfiguration,
        recordingService: JSONSessionExportService = JSONSessionExportService()
    ) {
        self.sessionStore = sessionStore
        self.configuration = configuration
        self.recordingService = recordingService
        hasSessions = !sessionStore.sessions.isEmpty
        availabilityObservation = sessionStore.sessionChangesPublisher
            .map { [weak sessionStore] _ in sessionStore?.sessions.isEmpty == false }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] available in
                if self?.hasSessions != available { self?.hasSessions = available }
            }
    }

    func saveAllSessions(
        to destinationURL: URL,
        fidelity: RecordingSaveFidelity = .fullRecording,
        asHAR: Bool = false
    ) async throws {
        guard !isSaving else { throw ExportError.alreadySaving }
        let sessions = sessionStore.sessions
        guard !sessions.isEmpty else {
            resultMessage = ExportError.noSessions.localizedDescription
            throw ExportError.noSessions
        }
        isSaving = true
        resultMessage = nil
        defer { isSaving = false }
        let envelope = SessionExportEnvelope(
            exportedAt: Date(),
            appVersion: Bundle.main.marketingVersionOrDev,
            proxyPort: configuration.proxyPort,
            sessionCount: sessions.count,
            sessions: sessions
        )
        let recordingService = recordingService
        do {
            try await Task.detached(priority: .utility) {
                if asHAR {
                    try HARSessionExportService().export(envelope, to: destinationURL)
                } else {
                    try recordingService.exportAsRecording(envelope, to: destinationURL, fidelity: fidelity)
                }
            }.value
            resultMessage = "Saved \(destinationURL.lastPathComponent)."
        } catch {
            resultMessage = error.localizedDescription
            throw error
        }
    }
}
