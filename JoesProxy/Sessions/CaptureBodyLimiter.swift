import Foundation

struct CapturedBody: Equatable, Sendable {
    let data: Data?
    let size: Int?
    let truncated: Bool
}

struct CaptureBodyLimiter: Sendable {
    static let live = CaptureBodyLimiter(limit: RecordingConstants.liveCaptureBodySizeLimit)

    let limit: Int

    func makeAccumulator() -> BoundedCaptureAccumulator {
        BoundedCaptureAccumulator(limit: limit)
    }

    func retainedBody(from body: Data) -> CapturedBody {
        guard !body.isEmpty else {
            return CapturedBody(data: nil, size: nil, truncated: false)
        }

        guard body.count > limit else {
            return CapturedBody(data: body, size: body.count, truncated: false)
        }

        return CapturedBody(
            data: limit > 0 ? Data(body.prefix(limit)) : nil,
            size: body.count,
            truncated: true
        )
    }
}

/// In-flight accumulator for streaming response bodies that enforces the live capture limit
/// (1 MB by default) without allocating unbounded memory for multi-gigabyte downloads.
final class BoundedCaptureAccumulator: @unchecked Sendable {
    let limit: Int
    private let countWithoutBody: Bool
    private let lock = NSLock()
    private var prefixData = Data()
    private var totalBytes: Int = 0
    private var isTruncated: Bool = false

    init(limit: Int = RecordingConstants.liveCaptureBodySizeLimit, countWithoutBody: Bool = false) {
        self.limit = limit
        self.countWithoutBody = countWithoutBody
        self.prefixData.reserveCapacity(min(limit, 65_536))
    }

    func append(data: Data) {
        guard (limit > 0 || countWithoutBody), !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        totalBytes += data.count
        if prefixData.count < limit {
            let available = limit - prefixData.count
            let toAppend = min(available, data.count)
            prefixData.append(data.prefix(toAppend))
        }
        if totalBytes > limit {
            isTruncated = true
        }
    }

    func append(bytes ptr: UnsafeRawBufferPointer) {
        guard (limit > 0 || countWithoutBody), let base = ptr.baseAddress, ptr.count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        totalBytes += ptr.count
        if prefixData.count < limit {
            let available = limit - prefixData.count
            let toAppend = min(available, ptr.count)
            prefixData.append(base.assumingMemoryBound(to: UInt8.self), count: toAppend)
        }
        if totalBytes > limit {
            isTruncated = true
        }
    }

    func finalize() -> CapturedBody {
        lock.lock()
        defer { lock.unlock() }
        guard totalBytes > 0 else {
            return CapturedBody(data: nil, size: nil, truncated: false)
        }
        return CapturedBody(
            data: prefixData.isEmpty ? nil : prefixData,
            size: totalBytes,
            truncated: isTruncated || totalBytes > limit
        )
    }

    /// Terminal handoff: the collector no longer owns the captured prefix. Transport/mutation
    /// buffers have separate budgets; the recorder owns the returned capture bytes until delivery.
    func takeFinalizedBody() -> CapturedBody {
        lock.lock()
        defer { lock.unlock() }
        let result = CapturedBody(data: prefixData.isEmpty ? nil : prefixData,
            size: totalBytes > 0 ? totalBytes : nil,
            truncated: isTruncated || totalBytes > limit)
        prefixData = Data()
        totalBytes = 0
        isTruncated = false
        return result
    }
}
