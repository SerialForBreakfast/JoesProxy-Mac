import Foundation
import NIOCore

/// Keeps event loops alive until upload intake and disk-to-socket callbacks have settled.
/// The lock protects admission and drain waiters; channel operations use NIO's thread-safe API.
final class UploadForwardingLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var channels: [UUID: Channel] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var activeCount: Int { lock.withLock { channels.count } }

    func begin(on channel: Channel) -> UUID? {
        lock.withLock {
            guard accepting else { return nil }
            let id = UUID()
            channels[id] = channel
            return id
        }
    }

    /// Call only after the worker's final event-loop callback has completed.
    func finish(_ id: UUID) {
        let completed = lock.withLock {
            channels.removeValue(forKey: id)
            guard channels.isEmpty else { return [CheckedContinuation<Void, Never>]() }
            let completed = waiters
            waiters.removeAll()
            return completed
        }
        completed.forEach { $0.resume() }
    }

    /// Close sockets to unblock writes, but await accepted disk work before loop shutdown.
    /// Cancellation cannot shorten this ownership barrier. A new server run uses a new instance.
    func stopAndDrain() async {
        let current = lock.withLock {
            accepting = false
            return Array(channels.values)
        }
        for channel in current { try? await channel.close().get() }
        await withCheckedContinuation { continuation in
            let finished = lock.withLock {
                guard !channels.isEmpty else { return true }
                waiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }
}
