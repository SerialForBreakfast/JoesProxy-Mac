import Combine
import Foundation

/// Sheet-owned state survives Compact/full transitions because the presenter is window-owned.
/// Operations and publication are MainActor-isolated; the injected restore owns background I/O.
@MainActor
final class RollingCaptureRecoveryOperation: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var progressMessage = "Restoring saved capture…"

    func run(exporting: Bool = false, _ action: @MainActor () async throws -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        progressMessage = exporting ? "Saving a copy…" : "Restoring saved capture…"
        errorMessage = nil
        defer { isRunning = false }
        do {
            try Task.checkCancellation()
            try await action()
        } catch is CancellationError {
            let action = exporting ? "Saving a copy" : "Recovery"
            errorMessage = "\(action) was cancelled. The saved recording has not been discarded. Try again or choose Start Fresh."
        } catch {
            let action = exporting ? "save a copy" : "restore the saved recording"
            errorMessage = "Could not \(action). \(error.localizedDescription) Try again or choose Start Fresh."
        }
    }
}
