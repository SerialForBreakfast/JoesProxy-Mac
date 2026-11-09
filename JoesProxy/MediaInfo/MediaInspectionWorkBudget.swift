import Foundation

/// The lock protects admission only; decoding runs off-main. No waiting closures are queued.
/// A cancelled synchronous parser keeps its slot until it actually exits.
final class MediaInspectionWorkBudget: @unchecked Sendable {
    static let shared = MediaInspectionWorkBudget()
    private let lock = NSLock()
    private var running = 0
    private let limit = 2

    func run<T: Sendable>(_ operation: @escaping @Sendable () -> T) async -> T? {
        guard !Task.isCancelled, lock.withLock({
            guard running < limit else { return false }
            running += 1
            return true
        }) else { return nil }
        let worker = Task.detached(priority: .utility) { () -> T? in
            defer { self.lock.withLock { self.running -= 1 } }
            guard !Task.isCancelled else { return nil }
            return operation()
        }
        let value = await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
        return Task.isCancelled ? nil : value
    }
}
