import Foundation
import zlib

enum RecordingStorageBudget {
    static let codecBufferBytes = 64 * 1024
    static let maxExpandedBytes = 512 * 1024 * 1024
    static let maxSingleSessionBytes = 8 * 1024 * 1024
    static let maxSessionCount = 250_000
    static let maxHeaderBytes = 1024 * 1024
    static let gzipCompressionLevel: Int32 = 6
}

/// Incremental RFC 1952 writer. The caller owns and closes the file handle.
final class RecordingGzipWriter {
    private let fileHandle: FileHandle
    private var stream = z_stream()
    private let outputBuffer: UnsafeMutablePointer<Bytef>
    private var isInitialized = false
    private var isFinished = false

    init(
        fileHandle: FileHandle,
        compressionLevel: Int32 = RecordingStorageBudget.gzipCompressionLevel
    ) throws {
        self.fileHandle = fileHandle
        outputBuffer = .allocate(capacity: RecordingStorageBudget.codecBufferBytes)

        let status = deflateInit2_(
            &stream,
            compressionLevel,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            outputBuffer.deallocate()
            throw RecordingContainerError.codecInitializationFailed
        }
        isInitialized = true
    }

    deinit {
        if isInitialized {
            deflateEnd(&stream)
        }
        outputBuffer.deallocate()
    }

    func write(_ data: Data) throws {
        guard !isFinished else {
            throw RecordingContainerError.codecAlreadyFinished
        }
        guard !data.isEmpty else { return }

        try data.withUnsafeBytes { rawBuffer in
            let input = rawBuffer.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.baseAddress)
            stream.avail_in = uInt(input.count)

            while stream.avail_in > 0 {
                try drain(flush: Z_NO_FLUSH)
            }
        }
    }

    func finish() throws {
        guard !isFinished else { return }
        stream.next_in = nil
        stream.avail_in = 0

        var status: Int32
        repeat {
            status = try drain(flush: Z_FINISH)
        } while status != Z_STREAM_END

        isFinished = true
    }

    @discardableResult
    private func drain(flush: Int32) throws -> Int32 {
        stream.next_out = outputBuffer
        stream.avail_out = uInt(RecordingStorageBudget.codecBufferBytes)

        let status = deflate(&stream, flush)
        guard status == Z_OK || status == Z_STREAM_END else {
            throw RecordingContainerError.corruptPayload
        }

        let produced = RecordingStorageBudget.codecBufferBytes - Int(stream.avail_out)
        if produced > 0 {
            try fileHandle.write(contentsOf: Data(bytes: outputBuffer, count: produced))
        }
        return status
    }
}

enum RecordingGzipReader {
    /// Inflates only until `consume` returns false. Used for bounded envelope-header inspection;
    /// it intentionally does not claim whole-member integrity validation.
    static func readPrefix(
        from url: URL,
        payloadOffset: UInt64,
        consume: (Data) throws -> Bool
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: payloadOffset)

        var stream = z_stream()
        guard inflateInit2_(
            &stream,
            15 + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw RecordingContainerError.codecInitializationFailed
        }
        defer { inflateEnd(&stream) }

        let prefixBufferBytes = 4 * 1024
        let outputBuffer = UnsafeMutablePointer<Bytef>.allocate(capacity: prefixBufferBytes)
        defer { outputBuffer.deallocate() }

        while let inputData = try handle.read(upToCount: RecordingStorageBudget.codecBufferBytes),
              !inputData.isEmpty {
            var shouldContinue = true
            try inputData.withUnsafeBytes { rawBuffer in
                let input = rawBuffer.bindMemory(to: Bytef.self)
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.baseAddress)
                stream.avail_in = uInt(input.count)

                while stream.avail_in > 0 && shouldContinue {
                    stream.next_out = outputBuffer
                    stream.avail_out = uInt(prefixBufferBytes)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw RecordingContainerError.corruptPayload
                    }
                    let produced = prefixBufferBytes - Int(stream.avail_out)
                    if produced > 0 {
                        shouldContinue = try consume(Data(bytes: outputBuffer, count: produced))
                    }
                    if status == Z_STREAM_END { return }
                }
            }
            if !shouldContinue { return }
        }
        throw RecordingContainerError.corruptPayload
    }

    /// Streams the gzip member at `payloadOffset` and validates that it is the only payload.
    static func read(
        from url: URL,
        payloadOffset: UInt64,
        maxExpandedBytes: Int = RecordingStorageBudget.maxExpandedBytes,
        consume: (Data) throws -> Void
    ) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: payloadOffset)
        } catch {
            throw RecordingContainerError.corruptPayload
        }
        defer { try? handle.close() }

        var stream = z_stream()
        guard inflateInit2_(
            &stream,
            15 + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw RecordingContainerError.codecInitializationFailed
        }
        defer { inflateEnd(&stream) }

        let outputBuffer = UnsafeMutablePointer<Bytef>.allocate(
            capacity: RecordingStorageBudget.codecBufferBytes
        )
        defer { outputBuffer.deallocate() }

        var expandedBytes = 0
        var reachedEnd = false

        while !reachedEnd {
            guard let inputData = try handle.read(upToCount: RecordingStorageBudget.codecBufferBytes),
                  !inputData.isEmpty else {
                throw RecordingContainerError.corruptPayload
            }

            try inputData.withUnsafeBytes { rawBuffer in
                let input = rawBuffer.bindMemory(to: Bytef.self)
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.baseAddress)
                stream.avail_in = uInt(input.count)

                while stream.avail_in > 0 && !reachedEnd {
                    stream.next_out = outputBuffer
                    stream.avail_out = uInt(RecordingStorageBudget.codecBufferBytes)

                    let status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw RecordingContainerError.corruptPayload
                    }

                    let produced = RecordingStorageBudget.codecBufferBytes - Int(stream.avail_out)
                    if produced > 0 {
                        expandedBytes += produced
                        guard expandedBytes <= maxExpandedBytes else {
                            throw RecordingContainerError.expandedSizeLimitExceeded(maxBytes: maxExpandedBytes)
                        }
                        try consume(Data(bytes: outputBuffer, count: produced))
                    }

                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0 else {
                            throw RecordingContainerError.trailingPayload
                        }
                        reachedEnd = true
                    }
                }
            }
        }

        if let trailing = try handle.read(upToCount: 1), !trailing.isEmpty {
            throw RecordingContainerError.trailingPayload
        }
    }

    static func data(
        from url: URL,
        payloadOffset: UInt64,
        maxExpandedBytes: Int = RecordingStorageBudget.maxExpandedBytes
    ) throws -> Data {
        var result = Data()
        try read(from: url, payloadOffset: payloadOffset, maxExpandedBytes: maxExpandedBytes) {
            result.append($0)
        }
        return result
    }

    static func data(
        fromCompressedData compressedData: Data,
        maxExpandedBytes: Int = RecordingStorageBudget.maxExpandedBytes,
        checkProgress: () throws -> Void = {}
    ) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(
            &stream,
            15 + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw RecordingContainerError.codecInitializationFailed
        }
        defer { inflateEnd(&stream) }

        let outputBuffer = UnsafeMutablePointer<Bytef>.allocate(
            capacity: RecordingStorageBudget.codecBufferBytes
        )
        defer { outputBuffer.deallocate() }

        var result = Data()
        try compressedData.withUnsafeBytes { rawBuffer in
            let input = rawBuffer.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.baseAddress)
            stream.avail_in = uInt(input.count)

            var status: Int32 = Z_OK
            repeat {
                try checkProgress()
                stream.next_out = outputBuffer
                stream.avail_out = uInt(RecordingStorageBudget.codecBufferBytes)
                status = inflate(&stream, Z_NO_FLUSH)
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw RecordingContainerError.corruptPayload
                }

                let produced = RecordingStorageBudget.codecBufferBytes - Int(stream.avail_out)
                if produced > 0 {
                    guard result.count + produced <= maxExpandedBytes else {
                        throw RecordingContainerError.expandedSizeLimitExceeded(maxBytes: maxExpandedBytes)
                    }
                    result.append(outputBuffer, count: produced)
                }
            } while status != Z_STREAM_END

            guard stream.avail_in == 0 else {
                throw RecordingContainerError.trailingPayload
            }
        }
        return result
    }
}
