import Foundation

/// Structured retirement: deadline/cancellation stops framework loading before awaiting children.
/// The caller retains admission until operation return, even if framework cancellation is slow.
@MainActor
enum AVMediaMetadataOperation {
    enum Failure: LocalizedError {
        case timedOut
        var errorDescription: String? { "Asset metadata timed out." }
    }

    @MainActor
    private final class Interruption {
        private var finished = false
        private(set) var timedOut = false
        private let stop: @MainActor @Sendable () -> Void

        init(stop: @escaping @MainActor @Sendable () -> Void) { self.stop = stop }
        func complete() { finished = true }
        func expire() {
            guard !finished else { return }
            timedOut = true
            interrupt()
        }
        func interrupt() {
            guard !finished else { return }
            finished = true
            stop()
        }
    }

    static func run<T: Sendable>(
        timeout: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> T,
        stop: @escaping @MainActor @Sendable () -> Void
    ) async throws -> T {
        try Task.checkCancellation()
        let interruption = Interruption(stop: stop)
        return try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask { @MainActor in
                try Task.checkCancellation()
                if interruption.timedOut { throw Failure.timedOut }
                return try await operation()
            }
            group.addTask { @MainActor in
                do { try await Task.sleep(for: timeout) }
                catch { interruption.interrupt(); throw error }
                interruption.expire()
                throw Failure.timedOut
            }
            do {
                guard let result = try await group.next() else { throw CancellationError() }
                try Task.checkCancellation()
                if interruption.timedOut { throw Failure.timedOut }
                interruption.complete()
                return result
            } catch {
                interruption.interrupt()
                try Task.checkCancellation()
                if interruption.timedOut { throw Failure.timedOut }
                throw error
            }
        }
    }
}
