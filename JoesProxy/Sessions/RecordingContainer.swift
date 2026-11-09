//
//  RecordingContainer.swift
//  JoesProxy
//
//  Compressed outer container for .jproxy recordings.
//
//  Layout: "JPXR" magic (4 bytes) + format byte + payload.
//  Format 0x01 = LZFSE-compressed JSON; 0x02 = gzip-compressed JSON. The JSON payload — including its
//  schemaVersion field — is byte-identical to the legacy uncompressed format,
//  so this is a container version, not a schema version: version gating still
//  happens on the decoded JSON, and readers distinguish legacy files by the
//  first byte ('{' or whitespace can never collide with the magic).
//

import Foundation

enum RecordingContainerError: LocalizedError {
    /// The magic matched but the format byte is unknown — written by a newer JoesProxy.
    case unsupportedFormat(UInt8)
    case corruptPayload
    case truncatedHeader
    case codecInitializationFailed
    case codecAlreadyFinished
    case expandedSizeLimitExceeded(maxBytes: Int)
    case trailingPayload

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "This recording uses container format \(format), which requires a newer version of JoesProxy."
        case .corruptPayload:
            return "The recording's compressed payload could not be decompressed."
        case .truncatedHeader:
            return "The recording container header is incomplete."
        case .codecInitializationFailed:
            return "Recording compression could not be initialized."
        case .codecAlreadyFinished:
            return "The recording compression stream was already finalized."
        case .expandedSizeLimitExceeded(let maxBytes):
            return "The recording expands beyond the supported limit of \(maxBytes) bytes."
        case .trailingPayload:
            return "The recording contains unexpected data after its compressed payload."
        }
    }
}

enum RecordingContainer {
    static let magic = Data([0x4A, 0x50, 0x58, 0x52]) // "JPXR"
    static let lzfseFormat: UInt8 = 0x01
    static let gzipFormat: UInt8 = 0x02
    static let headerLength = 5

    /// Wraps a JSON payload in the compressed container.
    static func wrap(_ payload: Data) throws -> Data {
        let compressed: Data
        do {
            compressed = try (payload as NSData).compressed(using: .lzfse) as Data
        } catch {
            throw RecordingContainerError.corruptPayload
        }
        var container = magic
        container.append(lzfseFormat)
        container.append(compressed)
        return container
    }

    /// Returns the JSON payload for `.jproxy` file bytes: decompresses container files,
    /// passes legacy plain-JSON files through untouched.
    static func unwrap(_ fileData: Data) throws -> Data {
        guard fileData.prefix(magic.count) == magic else {
            return fileData // legacy uncompressed JSON
        }

        guard fileData.count > headerLength else {
            throw RecordingContainerError.truncatedHeader
        }

        let format = fileData[fileData.index(fileData.startIndex, offsetBy: magic.count)]
        let compressed = Data(fileData.dropFirst(headerLength))
        switch format {
        case lzfseFormat:
            do {
                return try (compressed as NSData).decompressed(using: .lzfse) as Data
            } catch {
                throw RecordingContainerError.corruptPayload
            }
        case gzipFormat:
            return try RecordingGzipReader.data(fromCompressedData: compressed)
        default:
            throw RecordingContainerError.unsupportedFormat(format)
        }
    }

    static func format(at url: URL) throws -> UInt8? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw RecordingContainerError.corruptPayload
        }
        defer { try? handle.close() }

        guard let header = try handle.read(upToCount: headerLength) else {
            throw RecordingContainerError.corruptPayload
        }
        guard header.prefix(magic.count) == magic else {
            return nil
        }
        guard header.count == headerLength else {
            throw RecordingContainerError.truncatedHeader
        }
        return header[header.index(header.startIndex, offsetBy: magic.count)]
    }

    static func unwrapFile(at url: URL) throws -> Data {
        switch try format(at: url) {
        case nil:
            return try Data(contentsOf: url)
        case lzfseFormat:
            return try unwrap(Data(contentsOf: url))
        case gzipFormat:
            return try RecordingGzipReader.data(from: url, payloadOffset: UInt64(headerLength))
        case .some(let format):
            throw RecordingContainerError.unsupportedFormat(format)
        }
    }
}

import zlib

/// Pointer to an offloaded body stored inside an append-only body packfile.
struct BodySpoolReference: Equatable, Hashable, Codable, Sendable {
    let packIndex: Int
    let offset: UInt64
    let length: UInt32
    let checksum: UInt32 // CRC-32
}

/// Rotated, append-only binary packfile store for offloaded payloads.
final class BodyPackStore: @unchecked Sendable {
    static let magic = Data([0x4A, 0x50, 0x42, 0x4B]) // "JPBK"
    static let headerSize = 29 // 4B magic + 16B UUID + 1B kind + 4B len + 4B CRC32
    static let maxPackBytes: UInt64 = 64 * 1024 * 1024 // 64 MB

    private let spoolDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var currentPackIndex: Int = 1
    private var currentPackSize: UInt64 = 0
    private var writeHandle: FileHandle?

    init(spoolDirectory: URL, fileManager: FileManager = .default) {
        self.spoolDirectory = spoolDirectory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? writeHandle?.close()
    }

    static func calculateCRC32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return UInt32(crc32(0, baseAddress.assumingMemoryBound(to: Bytef.self), uInt(data.count)))
        }
    }

    func packURL(for index: Int) -> URL {
        spoolDirectory.appendingPathComponent(String(format: "body-pack-%04d.bin", index), isDirectory: false)
    }

    func write(sessionID: UUID, kind: UInt8, payload: Data) throws -> BodySpoolReference {
        lock.lock()
        defer { lock.unlock() }

        let payloadLength = UInt32(payload.count)
        let recordSize = UInt64(Self.headerSize + payload.count)
        if currentPackSize + recordSize > Self.maxPackBytes, currentPackSize > 0 {
            try? writeHandle?.close()
            writeHandle = nil
            currentPackIndex += 1
            currentPackSize = 0
        }

        let packIndex = currentPackIndex
        let packFileURL = packURL(for: packIndex)

        if writeHandle == nil {
            if !fileManager.fileExists(atPath: packFileURL.path) {
                fileManager.createFile(atPath: packFileURL.path, contents: nil)
            }
            writeHandle = try FileHandle(forWritingTo: packFileURL)
            try writeHandle?.seekToEnd()
            currentPackSize = try writeHandle?.offset() ?? 0
        }

        guard let handle = writeHandle else {
            throw RecordingContainerError.corruptPayload
        }

        let offset = try handle.offset()
        let checksum = Self.calculateCRC32(payload)

        var header = Data()
        header.append(Self.magic)
        withUnsafeBytes(of: sessionID.uuid) { header.append(contentsOf: $0) }
        header.append(kind)
        var beLength = payloadLength.bigEndian
        withUnsafeBytes(of: &beLength) { header.append(contentsOf: $0) }
        var beChecksum = checksum.bigEndian
        withUnsafeBytes(of: &beChecksum) { header.append(contentsOf: $0) }

        try handle.write(contentsOf: header)
        try handle.write(contentsOf: payload)
        currentPackSize += recordSize

        return BodySpoolReference(
            packIndex: packIndex,
            offset: offset,
            length: payloadLength,
            checksum: checksum
        )
    }

    func read(reference: BodySpoolReference) throws -> Data {
        let packFileURL = packURL(for: reference.packIndex)
        let handle = try FileHandle(forReadingFrom: packFileURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: reference.offset)
        guard let headerData = try handle.read(upToCount: Self.headerSize),
              headerData.count == Self.headerSize else {
            throw RecordingContainerError.truncatedHeader
        }

        guard headerData.prefix(Self.magic.count) == Self.magic else {
            throw RecordingContainerError.corruptPayload
        }

        guard let payload = try handle.read(upToCount: Int(reference.length)),
              payload.count == Int(reference.length) else {
            throw RecordingContainerError.corruptPayload
        }

        let calculatedChecksum = Self.calculateCRC32(payload)
        guard calculatedChecksum == reference.checksum else {
            throw RecordingContainerError.corruptPayload
        }

        return payload
    }
}

/// Blocking append-only journal primitive. Production callers use `SessionJournalIO` so
/// encoding, synchronization, and the compaction swap lock never block the store subscriber.
final class SessionJournalWriter: @unchecked Sendable {
    enum CompactionStage: CaseIterable, Sendable {
        case create, open, encode, write, synchronize, close, replace
    }
    private let beforeCompactionStage: @Sendable (CompactionStage) throws -> Void
    var isBufferingCompaction: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionsAppendedDuringCompaction != nil
    }
    static let stagingSuffix = ".journal-stage"

    private let journalURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var writeHandle: FileHandle?
    private var compactionGeneration: UInt64 = 0
    private var sessionsAppendedDuringCompaction: [SessionRecord]?
    private(set) var entryCount: Int = 0

    init(
        journalURL: URL,
        fileManager: FileManager = .default,
        beforeCompactionStage: @escaping @Sendable (CompactionStage) throws -> Void = { _ in }
    ) {
        self.journalURL = journalURL
        self.fileManager = fileManager
        self.beforeCompactionStage = beforeCompactionStage
        try? fileManager.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    deinit {
        try? writeHandle?.close()
    }

    func append(session: SessionRecord) throws {
        lock.lock()
        defer { lock.unlock() }

        if writeHandle == nil {
            if !fileManager.fileExists(atPath: journalURL.path) {
                fileManager.createFile(atPath: journalURL.path, contents: nil)
            }
            writeHandle = try FileHandle(forWritingTo: journalURL)
            try writeHandle?.seekToEnd()
        }

        guard let handle = writeHandle else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lineData = try encoder.encode(session)
        lineData.append(0x0A) // \n newline
        try handle.write(contentsOf: lineData)
        sessionsAppendedDuringCompaction?.append(session)
        entryCount += 1
    }

    /// Flushes appended journal bytes to durable storage without rebuilding the capture.
    func synchronize() throws {
        lock.lock()
        defer { lock.unlock() }
        try writeHandle?.synchronize()
    }

    /// Starts preserving appends that arrive after the caller captured its compaction snapshot.
    func beginCompaction() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        compactionGeneration &+= 1
        sessionsAppendedDuringCompaction = []
        return compactionGeneration
    }

    /// Replaces an amplified journal with one latest record per retained session.
    ///
    /// The replacement is streamed through a sibling staging file, then atomically moved into
    /// place. New appends continue writing to the current journal while the retained-session
    /// snapshot is encoded, then are copied into the replacement under the short swap lock.
    func replaceContents(with sessions: [SessionRecord], generation: UInt64) throws {
        // Registered before any throwing file operation; runs after the swap lock is released.
        defer { cancelCompactionIfCurrent(generation) }
        let stagingURL = journalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(journalURL.lastPathComponent).\(UUID().uuidString)\(Self.stagingSuffix)"
        )
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        try beforeCompactionStage(.create)
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try beforeCompactionStage(.open)
        let handle = try FileHandle(forWritingTo: stagingURL)
        var didCloseHandle = false
        defer {
            if !didCloseHandle {
                try? handle.close()
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            for session in sessions {
                try Task.checkCancellation()
                try beforeCompactionStage(.encode)
                try beforeCompactionStage(.write)
                try Self.writeJournalLine(session, encoder: encoder, to: handle)
            }
        } catch {
            cancelCompactionIfCurrent(generation)
            throw error
        }

        lock.lock()
        defer { lock.unlock() }
        guard compactionGeneration == generation,
              let appendedSessions = sessionsAppendedDuringCompaction else {
            throw CancellationError()
        }

        do {
            for session in appendedSessions {
                try Self.writeJournalLine(session, encoder: encoder, to: handle)
            }
            try beforeCompactionStage(.synchronize)
            try handle.synchronize()
            try beforeCompactionStage(.close)
            try handle.close()
            didCloseHandle = true

            try? writeHandle?.close()
            writeHandle = nil
            try beforeCompactionStage(.replace)
            if fileManager.fileExists(atPath: journalURL.path) {
                _ = try fileManager.replaceItemAt(journalURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: journalURL)
            }
            shouldRemoveStaging = false
            entryCount = sessions.count + appendedSessions.count
        } catch {
            throw error
        }
    }

    func reset() {
        try? resetPersistedJournal()
    }

    func resetPersistedJournal() throws {
        lock.lock()
        defer { lock.unlock() }
        compactionGeneration &+= 1
        sessionsAppendedDuringCompaction = nil
        let handle = writeHandle
        writeHandle = nil
        entryCount = 0
        try handle?.close()
        if fileManager.fileExists(atPath: journalURL.path) {
            try fileManager.removeItem(at: journalURL)
        }
    }

    private func cancelCompactionIfCurrent(_ generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard compactionGeneration == generation else { return }
        sessionsAppendedDuringCompaction = nil
    }

    private static func writeJournalLine(
        _ session: SessionRecord,
        encoder: JSONEncoder,
        to handle: FileHandle
    ) throws {
        var lineData = try autoreleasepool { try encoder.encode(session) }
        lineData.append(0x0A)
        try handle.write(contentsOf: lineData)
    }
}

/// Reader for the append-only session journal.
enum SessionJournalReader {
    static func readSessions(from journalURL: URL, fileManager: FileManager = .default) -> [SessionRecord] {
        guard fileManager.fileExists(atPath: journalURL.path),
              let data = try? Data(contentsOf: journalURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var sessions: [SessionRecord] = []
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let lineData = data[lineStart..<lineEnd]
            if !lineData.isEmpty, let session = try? decoder.decode(SessionRecord.self, from: lineData) {
                sessions.append(session)
            }
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
        }
        return sessions
    }
}

/// Manages ephemeral body spooling, disk bounds, and Tier 3 memory hydration caching.
final class BodySpoolCoordinator: @unchecked Sendable {
    private let packStore: BodyPackStore
    private let cache = NSCache<NSUUID, NSData>()
    private let maxMemoryCacheBytes: Int = 50 * 1024 * 1024 // 50 MB
    private let spoolThresholdBytes: Int = 256 * 1024 // 256 KB

    init(spoolDirectory: URL) {
        self.packStore = BodyPackStore(spoolDirectory: spoolDirectory)
        self.cache.totalCostLimit = maxMemoryCacheBytes
    }

    func spoolIfNeeded(
        bodyData: Data?,
        sessionID: UUID,
        kind: UInt8,
        contentType: String?
    ) -> (inlineData: Data?, reference: BodySpoolReference?) {
        guard let bodyData, !bodyData.isEmpty else {
            return (nil, nil)
        }

        let isLarge = bodyData.count > spoolThresholdBytes
        let isMedia = isStreamingMediaContentType(contentType)
        if !isLarge && !isMedia {
            return (bodyData, nil)
        }

        do {
            let ref = try packStore.write(sessionID: sessionID, kind: kind, payload: bodyData)
            cache.setObject(bodyData as NSData, forKey: sessionID as NSUUID, cost: bodyData.count)
            return (nil, ref)
        } catch {
            return (bodyData, nil)
        }
    }

    func loadBody(for sessionID: UUID, reference: BodySpoolReference) throws -> Data {
        if let cached = cache.object(forKey: sessionID as NSUUID) as Data? {
            return cached
        }
        let data = try packStore.read(reference: reference)
        cache.setObject(data as NSData, forKey: sessionID as NSUUID, cost: data.count)
        return data
    }

    private func isStreamingMediaContentType(_ contentType: String?) -> Bool {
        guard let contentType = contentType?.lowercased() else { return false }
        return contentType.contains("video/") ||
               contentType.contains("audio/") ||
               contentType.contains("application/vnd.apple.mpegurl") ||
               contentType.contains("application/dash+xml") ||
               contentType.contains("application/octet-stream")
    }
}
