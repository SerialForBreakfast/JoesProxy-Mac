import Foundation

/// Shared admission remains occupied until inference exits, even after UI cancellation.
actor LocalMockInferenceGate {
    enum Failure: Error { case busy }
    private var active = false
    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !active else { throw Failure.busy }
        active = true
        defer { active = false }
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }
}
