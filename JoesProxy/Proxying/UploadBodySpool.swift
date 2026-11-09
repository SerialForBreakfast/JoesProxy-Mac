import Darwin
import Foundation

enum UploadBodySpoolError: LocalizedError, Equatable {
    case capacityUnavailable
    case operationInProgress
    case invalidChunk
    case invalidState
    case unsafeDirectory
    case diskIO(Int32)

    var errorDescription: String? {
        let recovery: String
        switch self {
        case .capacityUnavailable:
            recovery = "Temporary upload capacity is busy. Retry after active uploads finish."
        case .unsafeDirectory:
            recovery = "Private upload storage is unavailable. Check storage permissions and restart capture."
        case .diskIO(let code) where code == ENOSPC:
            recovery = "Temporary upload storage is full. Free disk space and retry."
        case .diskIO:
            recovery = "Temporary upload data could not be read or written. Check storage health and restart capture."
        default:
            recovery = "Temporary upload processing could not complete safely. Retry and report diagnostics if it persists."
        }
        return "\(recovery) This request was stopped; no rules were bypassed."
    }
}

/// Registry/health state is lock protected; file work remains isolated in UploadBodySpool.
final class UploadSpoolService: @unchecked Sendable {
    let directory: URL
    let budget: UploadSpoolBudget
    private let write: UploadBodySpool.WriteOperation
    static let memoryThreshold = 256 * 1024
    private let lock = NSLock()
    private var accepting = true
    private var spools: [ObjectIdentifier: UploadBodySpool] = [:]
    private var cleanupFailed = false

    var needsCleanup: Bool { lock.withLock { cleanupFailed } }
    func recordStorageFailure() { lock.withLock { cleanupFailed = true } }

    init(directory: URL, budget: UploadSpoolBudget = UploadSpoolBudget(),
         write: @escaping UploadBodySpool.WriteOperation = UploadBodySpool.diskWrite) {
        self.directory = directory
        self.budget = budget
        self.write = write
    }

    static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JoesProxy/UploadBodies", isDirectory: true)
    }

    func prepare() async throws {
        do {
            let stopped = lock.withLock { accepting ? [] : Array(spools.values) }
            for spool in stopped { await release(spool) }
            try await UploadBodySpool.prepareDirectory(directory)
            guard stopped.isEmpty || lock.withLock({ spools.isEmpty }) else {
                throw UploadBodySpoolError.diskIO(EIO)
            }
            lock.withLock { accepting = true; cleanupFailed = false }
        } catch {
            lock.withLock { cleanupFailed = true }
            throw error
        }
    }

    func create(lease: UploadSpoolBudget.Lease) async throws -> UploadBodySpool {
        guard lock.withLock({ accepting }) else { lease.release(); throw UploadBodySpoolError.invalidState }
        let spool: UploadBodySpool
        do { spool = try await UploadBodySpool.create(in: directory, lease: lease, write: write) }
        catch {
            if !(error is CancellationError) { lock.withLock { cleanupFailed = true } }
            throw error
        }
        let admitted = lock.withLock {
            guard accepting else { return false }
            spools[ObjectIdentifier(spool)] = spool
            return true
        }
        guard admitted else { try await spool.close(); throw UploadBodySpoolError.invalidState }
        return spool
    }

    func release(_ spool: UploadBodySpool) async {
        do {
            try await spool.close()
            _ = lock.withLock { spools.removeValue(forKey: ObjectIdentifier(spool)) }
        } catch UploadBodySpoolError.operationInProgress {
            // Another terminal path owns the close; it removes the registry entry on completion.
        } catch { lock.withLock { cleanupFailed = true } }
    }

    func stopAdmission() { lock.withLock { accepting = false } }

    /// Awaits owned closes, then allows two seconds for late creation tasks to settle.
    /// This is not a timeout for an OS disk operation already in progress.
    func drain() async -> Bool {
        stopAdmission()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            let current = lock.withLock { Array(spools.values) }
            for spool in current { await release(spool) }
            if budget.activeCount == 0 { return !needsCleanup }
            // A prior write failure is advisory, not evidence that an in-flight close failed.
            // Keep settling owned leases even while recovery health remains degraded.
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        lock.withLock { cleanupFailed = true }
        return false
    }
}

/// Admission precedes dispatch. A lease covers creation, I/O and asynchronous destruction.
/// This is a storage budget, not permission to reject or bypass a live upload.
final class UploadSpoolBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0
    private var peak = 0

    init(limit: Int = 8) { self.limit = max(0, limit) }

    var activeCount: Int { lock.withLock { count } }
    var peakCount: Int { lock.withLock { peak } }

    func reserve() -> Lease? {
        lock.withLock {
            guard count < limit else { return nil }
            count += 1
            peak = max(peak, count)
            return Lease(owner: self)
        }
    }

    final class Lease: @unchecked Sendable {
        private let owner: UploadSpoolBudget
        private let lock = NSLock()
        private var released = false
        fileprivate init(owner: UploadSpoolBudget) { self.owner = owner }
        fileprivate func release() {
            lock.withLock {
                guard !released else { return }
                released = true
                owner.lock.withLock { owner.count -= 1 }
            }
        }
        deinit { release() }
    }
}

/// One awaited operation per spool; overlapping calls fail instead of queuing body buffers.
/// Blocking file operations run on a dedicated queue, never on an actor or network executor.
/// Callers must close after their current operation returns, including cancellation/error paths.
actor UploadBodySpool {
    /// Invoked synchronously on the file queue; the borrowed buffer must not escape.
    typealias WriteOperation = @Sendable (Int32, UnsafeRawBufferPointer) throws -> Int
    static let diskWrite: WriteOperation = { descriptor, bytes in
        let result = Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        guard result >= 0 else { throw UploadBodySpoolError.diskIO(errno) }
        return result
    }
    static let maximumChunkBytes = 64 * 1024
    private static let ioQueue = DispatchQueue(label: "com.joesproxy.upload-spool", qos: .utility)

    private let file: Storage
    private var busy = false
    private var sealed = false
    private var failed = false
    private var closed = false
    private var closing = false
    private var idleWaiter: CheckedContinuation<Void, Never>?
    private(set) var byteCount = 0

    private init(file: Storage) { self.file = file }

    static func create(in directory: URL, budget: UploadSpoolBudget,
                       write: @escaping WriteOperation = diskWrite) async throws -> UploadBodySpool {
        guard let lease = budget.reserve() else { throw UploadBodySpoolError.capacityUnavailable }
        return try await create(in: directory, lease: lease, write: write)
    }

    /// Production reserves synchronously before creating the disk-worker task.
    static func create(in directory: URL, lease: UploadSpoolBudget.Lease,
                       write: @escaping WriteOperation = diskWrite) async throws -> UploadBodySpool {
        if Task.isCancelled { lease.release(); throw CancellationError() }
        let file: Storage
        do {
            file = try await performIO { try Storage(directory: directory, lease: lease, write: write) }
        } catch {
            // Do not depend on the executor releasing its closure before the caller retries.
            lease.release()
            throw error
        }
        if Task.isCancelled {
            try await performIO { try file.close() }
            throw CancellationError()
        }
        return UploadBodySpool(file: file)
    }

    static func prepareDirectory(_ directory: URL) async throws {
        try await performIO {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let root = try Storage.openDirectory(directory)
            defer { Darwin.close(root) }
            guard let entries = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else {
                throw UploadBodySpoolError.unsafeDirectory
            }
            var inspected = 0
            for case let url as URL in entries {
                inspected += 1
                guard inspected <= 4096 else { throw UploadBodySpoolError.capacityUnavailable }
                guard url.pathExtension == "upload", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
                let name = url.lastPathComponent
                var named = stat()
                guard fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }
                    throw UploadBodySpoolError.diskIO(errno)
                }
                guard named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
                      named.st_uid == geteuid() else { continue }
                let fd = openat(root, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else {
                    if errno == ENOENT || errno == ELOOP { continue }
                    throw UploadBodySpoolError.diskIO(errno)
                }
                defer { Darwin.close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_nlink == 1, info.st_uid == geteuid() else { continue }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    if errno == EWOULDBLOCK { continue }
                    throw UploadBodySpoolError.diskIO(errno)
                }
                guard fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      named.st_ino == info.st_ino, named.st_dev == info.st_dev else { continue }
                guard unlinkat(root, name, 0) == 0 else { throw UploadBodySpoolError.diskIO(errno) }
            }
        }
    }

    func append(_ bytes: Data) async throws {
        guard !busy else { throw UploadBodySpoolError.operationInProgress }
        guard !closed, !closing, !sealed, !failed else { throw UploadBodySpoolError.invalidState }
        guard !bytes.isEmpty, bytes.count <= Self.maximumChunkBytes else {
            throw UploadBodySpoolError.invalidChunk
        }
        try Task.checkCancellation()
        busy = true
        defer { finishOperation() }
        do {
            let file = self.file
            try await Self.performIO { try file.append(bytes) }
            byteCount += bytes.count
        } catch {
            failed = true
            throw error
        }
        // Cancellation does not release admission before the actual disk operation finishes.
        try Task.checkCancellation()
    }

    func seal() throws {
        guard !busy else { throw UploadBodySpoolError.operationInProgress }
        guard !closed, !failed else { throw UploadBodySpoolError.invalidState }
        sealed = true
    }

    func read(at offset: Int) async throws -> Data {
        guard !busy else { throw UploadBodySpoolError.operationInProgress }
        guard sealed, !closed, !closing, !failed, offset >= 0, offset <= byteCount else {
            throw UploadBodySpoolError.invalidState
        }
        try Task.checkCancellation()
        busy = true
        defer { finishOperation() }
        let file = self.file
        let count = min(Self.maximumChunkBytes, byteCount - offset)
        let result = try await Self.performIO { try file.read(at: offset, count: count) }
        try Task.checkCancellation()
        return result
    }

    /// Cleanup deliberately runs even when the calling task is cancelled. An unlink failure
    /// remains an error with the file lock and lease retained so cleanup can be retried.
    func close() async throws {
        guard !closed else { return }
        guard !closing else { throw UploadBodySpoolError.operationInProgress }
        closing = true
        if busy { await withCheckedContinuation { idleWaiter = $0 } }
        busy = true
        defer { closing = false; finishOperation() }
        let file = self.file
        try await Self.performIO { try file.close() }
        closed = true
    }

    private func finishOperation() {
        busy = false
        let waiter = idleWaiter
        idleWaiter = nil
        waiter?.resume()
    }

    private static func performIO<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }

    /// Mutable descriptors and lease are confined to ioQueue. Deinit schedules its final
    /// cleanup there as well; the retained lease bounds outstanding destruction jobs.
    private final class Storage: @unchecked Sendable {
        private var directoryDescriptor: Int32
        private var descriptor: Int32
        private let name: String
        private var lease: UploadSpoolBudget.Lease?
        private let write: WriteOperation

        static func openDirectory(_ directory: URL) throws -> Int32 {
            let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw UploadBodySpoolError.unsafeDirectory }
            var info = stat()
            guard fstat(root, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                Darwin.close(root)
                throw UploadBodySpoolError.unsafeDirectory
            }
            return root
        }

        init(directory: URL, lease: UploadSpoolBudget.Lease, write: @escaping WriteOperation) throws {
            let root = try Self.openDirectory(directory)
            let name = UUID().uuidString + ".upload"
            let descriptor = openat(root, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                let code = errno
                Darwin.close(root)
                throw UploadBodySpoolError.diskIO(code)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                unlinkat(root, name, 0)
                Darwin.close(descriptor)
                Darwin.close(root)
                throw UploadBodySpoolError.diskIO(code)
            }
            self.directoryDescriptor = root
            self.descriptor = descriptor
            self.name = name
            self.lease = lease
            self.write = write
        }

        func append(_ bytes: Data) throws {
            try bytes.withUnsafeBytes { raw in
                var written = 0
                while written < raw.count {
                    let result: Int
                    do {
                        result = try write(descriptor, UnsafeRawBufferPointer(rebasing: raw[written...]))
                    } catch UploadBodySpoolError.diskIO(EINTR) { continue }
                    guard result > 0, result <= raw.count - written else { throw UploadBodySpoolError.diskIO(EIO) }
                    written += result
                }
            }
        }

        func read(at offset: Int, count: Int) throws -> Data {
            var result = Data(count: count)
            try result.withUnsafeMutableBytes { raw in
                var received = 0
                while received < count {
                    let amount = pread(descriptor, raw.baseAddress!.advanced(by: received), count - received, off_t(offset + received))
                    if amount < 0, errno == EINTR { continue }
                    guard amount > 0 else { throw UploadBodySpoolError.diskIO(amount == 0 ? EIO : errno) }
                    received += amount
                }
            }
            return result
        }

        func close() throws {
            guard descriptor >= 0 else { return }
            guard unlinkat(directoryDescriptor, name, 0) == 0 || errno == ENOENT else {
                throw UploadBodySpoolError.diskIO(errno)
            }
            Darwin.close(descriptor)
            Darwin.close(directoryDescriptor)
            descriptor = -1
            directoryDescriptor = -1
            lease?.release()
            lease = nil
        }

        deinit {
            let descriptor = descriptor
            let root = directoryDescriptor
            let name = name
            let lease = lease
            guard descriptor >= 0 else { return }
            UploadBodySpool.ioQueue.async {
                _ = unlinkat(root, name, 0)
                Darwin.close(descriptor)
                Darwin.close(root)
                withExtendedLifetime(lease) {}
            }
        }
    }
}
