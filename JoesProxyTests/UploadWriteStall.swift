import Foundation
@testable import JoesProxy

/// State is lock protected. Only the injected file-queue callback blocks; every stall has a
/// five-second escape so a failed regression cannot wedge the shared spool queue indefinitely.
final class UploadWriteStall: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var entered = false
    private var blocked = false
    private var expired = false
    private var largestChunk = 0

    var isBlocked: Bool { lock.withLock { blocked } }
    var timedOut: Bool { lock.withLock { expired } }
    var maximumChunkBytes: Int { lock.withLock { largestChunk } }

    func write(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) throws -> Int {
        let shouldWait = lock.withLock {
            largestChunk = max(largestChunk, bytes.count)
            guard !entered else { return false }
            entered = true
            blocked = true
            return true
        }
        if shouldWait {
            let timeout = resume.wait(timeout: .now() + 5) == .timedOut
            lock.withLock { blocked = false; expired = timeout }
        }
        return try UploadBodySpool.diskWrite(descriptor, bytes)
    }

    func release() { resume.signal() }

    func waitUntilBlocked() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !isBlocked {
            guard ContinuousClock.now < deadline else { throw StallError.didNotStart }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum StallError: Error { case didNotStart }
}
