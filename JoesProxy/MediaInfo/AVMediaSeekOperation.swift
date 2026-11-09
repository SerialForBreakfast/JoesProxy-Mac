import Foundation

/// The callback owns only a completion cell, never the player or presentation model.
/// MainActor serializes completion, cancellation and deadline checks; no detached wait survives.
@MainActor
enum AVMediaSeekOperation {
    enum Failure: Error { case timedOut, interrupted }

    private final class Completion {
        var result: Bool?
    }

    static func run(
        timeout: Duration,
        start: (@escaping @Sendable (Bool) -> Void) -> Void,
        cancel: () -> Void
    ) async throws {
        try Task.checkCancellation()
        let completion = Completion()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        defer { cancel() }
        start { finished in
            Task { @MainActor in
                if completion.result == nil { completion.result = finished }
            }
        }
        while true {
            try Task.checkCancellation()
            if let finished = completion.result {
                guard finished else { throw Failure.interrupted }
                return
            }
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
