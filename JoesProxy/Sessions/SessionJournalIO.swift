import Foundation
import Synchronization

enum SessionJournalIOError: Error, Sendable {
    case backlogExceeded
    case writeFailed
    case superseded

    var message: String {
        switch self {
        case .backlogExceeded:
            return "Rolling recovery paused because disk writes could not keep up. Live capture continues, but recovery may be incomplete. Export the current capture, then clear it to restart recovery."
        case .writeFailed:
            return "Rolling recovery paused after a disk write failed. Live capture continues, but recovery may be incomplete. Check available disk space and permissions, export the capture, then clear it to restart recovery."
        case .superseded:
            return "The recovery operation belongs to a cleared capture."
        }
    }
}

/// Blocking file work belongs exclusively to `queue`; admission state belongs to `state`.
/// The subscriber takes only the short admission lock, never the writer's I/O lock.
/// FIFO checkpoint barriers include all prior accepted appends. Reset starts a new generation.
final class SessionJournalIO: @unchecked Sendable {
    private struct Admission {
        var generation: UInt64 = 0
        var pendingCount = 0
        var pendingBytes = 0
        var failure: SessionJournalIOError?
    }

    private let state = Mutex(Admission())
    private let queue = DispatchQueue(label: "com.JoesProxyApp.journal-io", qos: .utility)
    private let journalURL: URL
    private let metadataURL: URL
    private let fileManager: FileManager
    private let maxPendingCount: Int
    private let maxPendingBytes: Int
    private let beforeAppend: @Sendable () throws -> Void
    private let beforeCompactionStage: @Sendable (SessionJournalWriter.CompactionStage) throws -> Void
    private let onFailure: @Sendable (UInt64, SessionJournalIOError) -> Void
    // Queue-confined, including lazy construction (which creates the journal directory).
    private var writer: SessionJournalWriter?

    init(
        journalURL: URL, metadataURL: URL, fileManager: FileManager = .default,
        maxPendingCount: Int = 4_096, maxPendingBytes: Int = 64 * 1_048_576,
        beforeAppend: @escaping @Sendable () throws -> Void = {},
        beforeCompactionStage: @escaping @Sendable (SessionJournalWriter.CompactionStage) throws -> Void = { _ in },
        onFailure: @escaping @Sendable (UInt64, SessionJournalIOError) -> Void = { _, _ in }
    ) {
        self.journalURL = journalURL
        self.metadataURL = metadataURL
        self.fileManager = fileManager
        self.maxPendingCount = maxPendingCount
        self.maxPendingBytes = maxPendingBytes
        self.beforeAppend = beforeAppend
        self.beforeCompactionStage = beforeCompactionStage
        self.onFailure = onFailure
    }

    deinit {
        // Every queued operation retains self, so no operation can still mutate writer.
        // Keep the final FileHandle close on the I/O queue as well.
        let retiredWriter = writer
        queue.async { withExtendedLifetime(retiredWriter) {} }
    }

    var generation: UInt64 { state.withLock { $0.generation } }
    var failure: SessionJournalIOError? { state.withLock { $0.failure } }
    var pendingCount: Int { state.withLock { $0.pendingCount } }

    /// This estimate bounds retained payload and metadata, not encoded JSON size or total RSS.
    private static func retainedBytes(_ session: SessionRecord) -> Int {
        let headers = session.request.headers + (session.response?.headers ?? [])
        return 2_048 + (session.request.bodyData?.count ?? 0) + (session.response?.bodyData?.count ?? 0)
            + session.request.path.utf8.count + session.request.host.utf8.count
            + headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
    }

    @MainActor func append(_ session: SessionRecord) {
        let bytes = Self.retainedBytes(session)
        var rejectedGeneration: UInt64?
        let admitted: UInt64? = state.withLock { value in
            guard value.failure == nil else { return nil }
            guard value.pendingCount < maxPendingCount,
                  bytes <= maxPendingBytes - value.pendingBytes else {
                value.failure = .backlogExceeded
                rejectedGeneration = value.generation
                return nil
            }
            value.pendingCount += 1
            value.pendingBytes += bytes
            return value.generation
        }
        if let rejectedGeneration { onFailure(rejectedGeneration, .backlogExceeded) }
        guard let admitted else { return }
        queue.async { [self] in
            defer {
                state.withLock { value in
                    value.pendingCount -= 1
                    value.pendingBytes -= bytes
                }
            }
            guard generation == admitted else { return }
            do {
                try beforeAppend()
                try writerOnQueue().append(session: session)
            } catch {
                recordFailure(.writeFailed, generation: admitted)
            }
        }
    }

    /// Call on the same serial producer as append/reset. Enqueue before yielding so a
    /// compaction snapshot cannot overtake newer appends and then overwrite them.
    @MainActor func checkpoint(
        sessions: [SessionRecord], compact: Bool,
        commitMetadata: @escaping @Sendable () throws -> Void,
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        let epoch = generation
        queue.async { [self] in
            do {
                try validate(epoch)
                let writer = writerOnQueue()
                if compact {
                    let token = writer.beginCompaction()
                    // No writer append can interleave here: arrivals remain in the bounded
                    // queue, so the final swap never encodes a buffered-arrival tail.
                    try writer.replaceContents(with: sessions, generation: token)
                } else {
                    try writer.synchronize()
                }
                try validate(epoch)
                try commitMetadata()
                let size = (try? journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                completion(.success(size))
            } catch {
                completion(.failure(error))
            }
        }
    }

    @MainActor func reset() {
        let epoch = state.withLock { value in
            value.generation &+= 1
            value.failure = nil
            return value.generation
        }
        queue.async { [self] in
            do {
                try writerOnQueue().resetPersistedJournal()
                if fileManager.fileExists(atPath: metadataURL.path) {
                    try fileManager.removeItem(at: metadataURL)
                }
            } catch { recordFailure(.writeFailed, generation: epoch) }
        }
    }

    private func writerOnQueue() -> SessionJournalWriter {
        if let writer { return writer }
        let created = SessionJournalWriter(journalURL: journalURL, fileManager: fileManager,
                                           beforeCompactionStage: beforeCompactionStage)
        writer = created
        return created
    }

    private func validate(_ epoch: UInt64) throws {
        try state.withLock { value in
            guard value.generation == epoch else { throw SessionJournalIOError.superseded }
            if let failure = value.failure { throw failure }
        }
    }

    private func recordFailure(_ error: SessionJournalIOError, generation epoch: UInt64) {
        let changed = state.withLock { value in
            guard value.generation == epoch, value.failure == nil else { return false }
            value.failure = error
            return true
        }
        if changed { onFailure(epoch, error) }
    }
}
