import Foundation

/// Lock-protected aggregate relay pressure. Callbacks never execute under the lock.
/// High-water pressure stops further reads; already-read bytes are accounted, never dropped.
/// This is a flow-control watermark, not a hard allocation ceiling for existing socket bursts.
final class RelayBacklogBudget: @unchecked Sendable {
    static let shared = RelayBacklogBudget()
    struct Snapshot: Equatable {
        let bytes: Int
        let peakBytes: Int
        let operations: Int
        let paused: Bool
    }
    private let lock = NSLock()
    private var bytes = 0
    private var peak = 0
    private var operations = 0
    private var paused = false
    private var readers: [UUID: (Bool) -> Void] = [:]
    private let highWater = 32 * 1_024 * 1_024

    func register(_ callback: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        let pressure = lock.withLock { readers[id] = callback; return paused }
        callback(pressure)
        return id
    }

    func unregister(_ id: UUID) { lock.withLock { _ = readers.removeValue(forKey: id) } }

    func adjust(bytes delta: Int, operations operationDelta: Int) {
        let update: (Bool, [(Bool) -> Void])? = lock.withLock {
            bytes += delta
            operations += operationDelta
            peak = max(peak, bytes)
            let next = paused ? bytes > highWater / 2 : bytes >= highWater
            guard next != paused else { return nil }
            paused = next
            return (next, Array(readers.values))
        }
        if let (pressure, callbacks) = update { callbacks.forEach { $0(pressure) } }
    }

    var snapshot: Snapshot {
        lock.withLock { Snapshot(bytes: bytes, peakBytes: peak, operations: operations, paused: paused) }
    }
}
