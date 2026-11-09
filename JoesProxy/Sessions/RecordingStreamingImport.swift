import Foundation

struct RecordingSessionRange: Sendable {
    let offset: UInt64
    let length: Int
}

/// Opaque source used by phase 2. New gzip recordings use indexed scratch storage; legacy
/// recordings retain their existing in-memory compatibility path behind the same boundary.
actor RecordingPhase2Source {
    private enum Storage: Sendable {
        case legacyEnvelopeData(Data)
        case indexedSessionFile(URL, [RecordingSessionRange])
    }

    private let storage: Storage
    private var cachedLegacySessions: [SessionRecord]?
    private var isCleanedUp = false

    func totalSessionCount() -> Int {
        switch storage {
        case .legacyEnvelopeData(let data):
            if cachedLegacySessions == nil {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                cachedLegacySessions = (try? decoder.decode(SessionExportEnvelope.self, from: data))?.sessions ?? []
            }
            return cachedLegacySessions?.count ?? 0
        case .indexedSessionFile(_, let ranges):
            return ranges.count
        }
    }

    func retainedScratchBytes() -> Int {
        switch storage {
        case .legacyEnvelopeData:
            return 0
        case .indexedSessionFile(_, let ranges):
            return ranges.reduce(0) { $0 + $1.length }
        }
    }

    init(legacyEnvelopeData: Data) {
        storage = .legacyEnvelopeData(legacyEnvelopeData)
    }

    init(indexedSessionFile url: URL, ranges: [RecordingSessionRange]) {
        storage = .indexedSessionFile(url, ranges)
    }

    deinit {
        if case .indexedSessionFile(let url, _) = storage {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func decodeBatch(startingAt startIndex: Int, limit: Int) -> [SessionRecord] {
        guard !isCleanedUp, limit > 0 else { return [] }

        switch storage {
        case .legacyEnvelopeData(let data):
            if cachedLegacySessions == nil {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                cachedLegacySessions = (try? decoder.decode(SessionExportEnvelope.self, from: data))?.sessions ?? []
            }
            guard let sessions = cachedLegacySessions, startIndex < sessions.count else { return [] }
            return Array(sessions[startIndex..<min(startIndex + limit, sessions.count)])

        case .indexedSessionFile(let url, let ranges):
            guard startIndex < ranges.count,
                  let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var result: [SessionRecord] = []
            result.reserveCapacity(limit)

            for range in ranges[startIndex..<min(startIndex + limit, ranges.count)] {
                let session: SessionRecord? = autoreleasepool {
                    do {
                        try handle.seek(toOffset: range.offset)
                        guard let data = try handle.read(upToCount: range.length),
                              data.count == range.length else { return nil }
                        return try? decoder.decode(SessionRecord.self, from: data)
                    } catch {
                        return nil
                    }
                }
                if let session {
                    result.append(session)
                }
            }
            return result
        }
    }

    func cleanup() {
        guard !isCleanedUp else { return }
        isCleanedUp = true
        cachedLegacySessions = nil
        if case .indexedSessionFile(let url, _) = storage {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension JSONSessionRecordingImportService {
    static func openStreamingGzip(
        from url: URL,
        bestEffort: Bool,
        decoder: JSONDecoder,
        deferBodiesWhenLarge: Bool = true
    ) throws -> RecordingLoadResult {
        let splitter = try RecordingStreamingJSONSplitter()
        do {
            try RecordingGzipReader.read(
                from: url,
                payloadOffset: UInt64(RecordingContainer.headerLength)
            ) { chunk in
                try splitter.consume(chunk)
            }
        } catch let error as RecordingOpenError {
            throw error
        } catch {
            throw RecordingOpenError.malformedJSON(error)
        }

        let importResult = try splitter.finish()
        var phase2OwnsScratch = false
        defer {
            if !phase2OwnsScratch {
                try? FileManager.default.removeItem(at: importResult.scratchURL)
            }
        }

        let recordingHeader = try Self.header(fromRoot: importResult.headerRoot)
        let isTooNew = recordingHeader.schemaVersion > RecordingConstants.currentSchemaVersion
        if isTooNew && !bestEffort {
            throw RecordingOpenError.schemaTooNew(version: recordingHeader.schemaVersion)
        }

        let schemaNotice: String?
        if recordingHeader.schemaVersion == 0 {
            schemaNotice = "This recording was created with an older version of JoesProxy. Some fields may be missing."
        } else if isTooNew {
            schemaNotice = "This recording uses schema v\(recordingHeader.schemaVersion). Some data may not load correctly in this version of JoesProxy."
        } else {
            schemaNotice = nil
        }

        let isLargeFile = deferBodiesWhenLarge &&
            importResult.expandedByteCount >= RecordingConstants.lazyLoadThreshold
        let (sessions, failedIDs) = decodeIndexedSessions(
            from: importResult.scratchURL,
            ranges: importResult.sessionRanges,
            decoder: decoder,
            stripBodies: isLargeFile
        )

        let phase2Source: RecordingPhase2Source?
        if isLargeFile {
            phase2Source = RecordingPhase2Source(
                indexedSessionFile: importResult.scratchURL,
                ranges: importResult.sessionRanges
            )
            phase2OwnsScratch = true
        } else {
            phase2Source = nil
        }

        return RecordingLoadResult(
            envelope: SessionExportEnvelope(
                schemaVersion: recordingHeader.schemaVersion,
                exportedAt: recordingHeader.exportedAt,
                appVersion: recordingHeader.appVersion,
                proxyPort: recordingHeader.proxyPort,
                recordingFidelity: recordingHeader.recordingFidelity,
                sessionCount: recordingHeader.sessionCount,
                sessions: sessions
            ),
            failedSessionIDs: failedIDs,
            schemaNotice: schemaNotice,
            phase2Source: phase2Source
        )
    }

    private static func decodeIndexedSessions(
        from url: URL,
        ranges: [RecordingSessionRange],
        decoder: JSONDecoder,
        stripBodies: Bool
    ) -> ([SessionRecord], [UUID]) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ([], ranges.map { _ in UUID() })
        }
        defer { try? handle.close() }

        var sessions: [SessionRecord] = []
        var failedIDs: [UUID] = []
        sessions.reserveCapacity(ranges.count)

        for range in ranges {
            let outcome: (session: SessionRecord?, failedID: UUID?) = autoreleasepool {
                var decodedSessionID: UUID?
                do {
                    try handle.seek(toOffset: range.offset)
                    guard let rawData = try handle.read(upToCount: range.length),
                          rawData.count == range.length else {
                        return (nil, UUID())
                    }
                    decodedSessionID = Self.sessionID(from: rawData)

                    let targetData: Data
                    if stripBodies {
                        guard let dictionary = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
                            return (nil, Self.sessionID(from: rawData) ?? UUID())
                        }
                        targetData = try JSONSerialization.data(
                            withJSONObject: strippingBodyData(from: dictionary)
                        )
                    } else {
                        targetData = rawData
                    }
                    return (try decoder.decode(SessionRecord.self, from: targetData), nil)
                } catch {
                    return (nil, decodedSessionID ?? UUID())
                }
            }
            if let session = outcome.session {
                sessions.append(session)
            } else {
                failedIDs.append(outcome.failedID ?? UUID())
            }
        }
        return (sessions, failedIDs)
    }

    private static func sessionID(from data: Data) -> UUID? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? String else { return nil }
        return UUID(uuidString: id)
    }

    static func streamingHeaderRoot(from url: URL) throws -> [String: Any] {
        let splitter = try RecordingStreamingJSONSplitter()
        try RecordingGzipReader.readPrefix(
            from: url,
            payloadOffset: UInt64(RecordingContainer.headerLength)
        ) { chunk in
            try splitter.consume(chunk)
            return !splitter.hasLocatedSessionsArray
        }
        return try splitter.headerRootIfAvailable()
    }
}

struct RecordingStreamingImportResult {
    let headerRoot: [String: Any]
    let scratchURL: URL
    let sessionRanges: [RecordingSessionRange]
    let expandedByteCount: Int
}

/// Splits the canonical recording envelope without retaining its expanded bytes. It recognizes
/// top-level `sessions`, then writes each complete session object to scratch storage.
final class RecordingStreamingJSONSplitter {
    private enum Mode {
        case prefix
        case sessions
        case suffix
        case complete
    }

    private let scratchURL: URL
    private let scratchHandle: FileHandle
    private var shouldRemoveScratch = true
    private var didCloseScratch = false

    private var mode: Mode = .prefix
    private var prefix = Data()
    private var prefixDepth = 0
    private var prefixInString = false
    private var prefixEscaped = false
    private var prefixString = Data()
    private var prefixStringDepth = 0
    private var awaitingSessionsColon = false
    private var awaitingSessionsArray = false

    private var currentSession: Data?
    private var sessionObjectDepth = 0
    private var sessionInString = false
    private var sessionEscaped = false
    private var expectsSessionValue = true
    private var allowsClosingSessionsArray = true

    private var scratchOffset: UInt64 = 0
    private(set) var sessionRanges: [RecordingSessionRange] = []
    private(set) var expandedByteCount = 0

    var hasLocatedSessionsArray: Bool {
        mode != .prefix
    }

    init(fileManager: FileManager = .default) throws {
        scratchURL = fileManager.temporaryDirectory
            .appendingPathComponent("JoesProxy-Recording-\(UUID().uuidString)")
            .appendingPathExtension("session-index")
        guard fileManager.createFile(atPath: scratchURL.path, contents: nil) else {
            throw RecordingOpenError.scratchStorageUnavailable
        }
        scratchHandle = try FileHandle(forWritingTo: scratchURL)
    }

    deinit {
        if !didCloseScratch {
            try? scratchHandle.close()
        }
        if shouldRemoveScratch {
            try? FileManager.default.removeItem(at: scratchURL)
        }
    }

    func consume(_ data: Data) throws {
        expandedByteCount += data.count
        for byte in data {
            switch mode {
            case .prefix:
                try consumePrefix(byte)
            case .sessions:
                try consumeSessions(byte)
            case .suffix:
                try consumeSuffix(byte)
            case .complete:
                guard byte.isJSONWhitespace else {
                    throw RecordingOpenError.malformedStreamingEnvelope
                }
            }
        }
    }

    func finish() throws -> RecordingStreamingImportResult {
        guard mode == .complete, currentSession == nil else {
            throw RecordingOpenError.malformedStreamingEnvelope
        }
        try scratchHandle.synchronize()
        try scratchHandle.close()
        didCloseScratch = true

        var headerData = prefix
        headerData.append(contentsOf: Data("]}".utf8))
        guard let root = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            throw RecordingOpenError.malformedStreamingEnvelope
        }

        shouldRemoveScratch = false
        return RecordingStreamingImportResult(
            headerRoot: root,
            scratchURL: scratchURL,
            sessionRanges: sessionRanges,
            expandedByteCount: expandedByteCount
        )
    }

    func headerRootIfAvailable() throws -> [String: Any] {
        guard hasLocatedSessionsArray else {
            throw RecordingOpenError.malformedStreamingEnvelope
        }
        var headerData = prefix
        headerData.append(contentsOf: Data("]}".utf8))
        guard let root = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            throw RecordingOpenError.malformedStreamingEnvelope
        }
        return root
    }

    private func consumePrefix(_ byte: UInt8) throws {
        prefix.append(byte)
        guard prefix.count <= RecordingStorageBudget.maxHeaderBytes else {
            throw RecordingOpenError.headerSizeLimitExceeded(maxBytes: RecordingStorageBudget.maxHeaderBytes)
        }

        if prefixInString {
            if prefixEscaped {
                prefixEscaped = false
                prefixString.append(byte)
            } else if byte == UInt8(ascii: "\\") {
                prefixEscaped = true
                prefixString.append(byte)
            } else if byte == UInt8(ascii: "\"") {
                prefixInString = false
                awaitingSessionsColon = prefixStringDepth == 1 && prefixString == Data("sessions".utf8)
            } else {
                prefixString.append(byte)
            }
            return
        }

        if awaitingSessionsArray {
            if byte.isJSONWhitespace { return }
            guard byte == UInt8(ascii: "[") else {
                throw RecordingOpenError.malformedStreamingEnvelope
            }
            mode = .sessions
            awaitingSessionsArray = false
            return
        }

        if awaitingSessionsColon {
            if byte.isJSONWhitespace { return }
            if byte == UInt8(ascii: ":") {
                awaitingSessionsColon = false
                awaitingSessionsArray = true
                return
            }
            awaitingSessionsColon = false
        }

        switch byte {
        case UInt8(ascii: "{"):
            prefixDepth += 1
        case UInt8(ascii: "}"):
            prefixDepth -= 1
            guard prefixDepth >= 0 else { throw RecordingOpenError.malformedStreamingEnvelope }
        case UInt8(ascii: "\""):
            prefixInString = true
            prefixEscaped = false
            prefixString = Data()
            prefixStringDepth = prefixDepth
        default:
            break
        }
    }

    private func consumeSessions(_ byte: UInt8) throws {
        if currentSession == nil {
            if byte.isJSONWhitespace { return }
            if expectsSessionValue {
                if byte == UInt8(ascii: "]") {
                    guard allowsClosingSessionsArray else {
                        throw RecordingOpenError.malformedStreamingEnvelope
                    }
                    mode = .suffix
                    return
                }
                guard byte == UInt8(ascii: "{") else {
                    throw RecordingOpenError.malformedStreamingEnvelope
                }
                currentSession = Data([byte])
                sessionObjectDepth = 1
                sessionInString = false
                sessionEscaped = false
                expectsSessionValue = false
                return
            }

            if byte == UInt8(ascii: ",") {
                expectsSessionValue = true
                allowsClosingSessionsArray = false
                return
            }
            if byte == UInt8(ascii: "]") {
                mode = .suffix
                return
            }
            throw RecordingOpenError.malformedStreamingEnvelope
        }

        currentSession?.append(byte)
        guard (currentSession?.count ?? 0) <= RecordingStorageBudget.maxSingleSessionBytes else {
            throw RecordingOpenError.sessionSizeLimitExceeded(
                maxBytes: RecordingStorageBudget.maxSingleSessionBytes
            )
        }

        if sessionInString {
            if sessionEscaped {
                sessionEscaped = false
            } else if byte == UInt8(ascii: "\\") {
                sessionEscaped = true
            } else if byte == UInt8(ascii: "\"") {
                sessionInString = false
            }
            return
        }

        switch byte {
        case UInt8(ascii: "\""):
            sessionInString = true
        case UInt8(ascii: "{"):
            sessionObjectDepth += 1
        case UInt8(ascii: "}"):
            sessionObjectDepth -= 1
            if sessionObjectDepth == 0 {
                try finishCurrentSession()
            }
        default:
            break
        }
    }

    private func finishCurrentSession() throws {
        guard let data = currentSession else {
            throw RecordingOpenError.malformedStreamingEnvelope
        }
        guard sessionRanges.count < RecordingStorageBudget.maxSessionCount else {
            throw RecordingOpenError.sessionCountLimitExceeded(
                maxCount: RecordingStorageBudget.maxSessionCount
            )
        }
        try scratchHandle.write(contentsOf: data)
        sessionRanges.append(RecordingSessionRange(offset: scratchOffset, length: data.count))
        scratchOffset += UInt64(data.count)
        currentSession = nil
        allowsClosingSessionsArray = true
    }

    private func consumeSuffix(_ byte: UInt8) throws {
        if byte.isJSONWhitespace { return }
        guard byte == UInt8(ascii: "}") else {
            throw RecordingOpenError.malformedStreamingEnvelope
        }
        mode = .complete
    }
}

private extension UInt8 {
    var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
