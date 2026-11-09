import Foundation

/// Transport reads this; the store advances on clear/load and the recorder on drained shutdown.
/// The lock protects all mutable state. No session content crosses this synchronization boundary.
final class LiveCaptureEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    var current: UInt64 { lock.withLock { generation } }

    func advance() { lock.withLock { generation &+= 1 } }
}
