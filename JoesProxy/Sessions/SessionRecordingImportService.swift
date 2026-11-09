import Foundation

// MARK: - Error types

/// Errors that can occur when opening a `.jproxy` recording file.
enum RecordingOpenError: LocalizedError {
    /// The schema version in the file is newer than `RecordingConstants.currentSchemaVersion`.
    /// The coordinator will surface this as a warning with a "Load Anyway" option rather than
    /// treating it as a terminal failure.
    case schemaTooNew(version: Int)
    /// The file at the given URL does not exist or is not readable.
    case fileNotFound(URL)
    /// The file data could not be decoded as a `SessionExportEnvelope` header.
    case malformedJSON(Error)
    case malformedStreamingEnvelope
    case scratchStorageUnavailable
    case headerSizeLimitExceeded(maxBytes: Int)
    case sessionSizeLimitExceeded(maxBytes: Int)
    case sessionCountLimitExceeded(maxCount: Int)

    var errorDescription: String? {
        switch self {
        case .schemaTooNew(let version):
            return "This recording was saved with schema version \(version), which requires a newer version of JoesProxy."
        case .fileNotFound(let url):
            return "Recording file not found: \(url.lastPathComponent)"
        case .malformedJSON(let underlying):
            return "Could not read recording: \(underlying.localizedDescription)"
        case .malformedStreamingEnvelope:
            return "Could not read recording: the streaming JSON envelope is malformed."
        case .scratchStorageUnavailable:
            return "Could not open recording because temporary storage is unavailable."
        case .headerSizeLimitExceeded(let maxBytes):
            return "The recording header exceeds the supported limit of \(maxBytes) bytes."
        case .sessionSizeLimitExceeded(let maxBytes):
            return "A recording session exceeds the supported limit of \(maxBytes) bytes."
        case .sessionCountLimitExceeded(let maxCount):
            return "The recording contains more than the supported \(maxCount) sessions."
        }
    }
}

// MARK: - Protocol

/// Reads a `.jproxy` recording file from disk and returns a `RecordingLoadResult`.
///
/// ## Concurrency
/// Conformers must be safe to `await` from any actor context. All file I/O and CPU-heavy
/// decoding must be performed off the calling actor so the main thread is never blocked.
///
/// ## Open phases
/// For files below `RecordingConstants.lazyLoadThreshold`, the result contains fully decoded
/// sessions (including body data). For files at or above the threshold, `ResultLoadResult`
/// carries sessions with body data stripped and an opaque `phase2Source` so the coordinator can
/// fill in bodies lazily via `SessionStore.update(_:)` without owning expanded recording bytes.
///
/// ## Schema version policy
/// - Version 0 (pre-3.5, key absent): best-effort load + `schemaNotice`.
/// - Version > `currentSchemaVersion` and `bestEffort == false`: throws `schemaTooNew`.
/// - Version > `currentSchemaVersion` and `bestEffort == true`: loads with advisory notice.
protocol SessionRecordingImportService: Sendable {
    /// Opens the recording at `url`.
    ///
    /// - Parameters:
    ///   - url: Path to the `.jproxy` file.
    ///   - bestEffort: When `true`, a schema version newer than `currentSchemaVersion` is treated
    ///     as a warning rather than an error. Useful for the "Load Anyway" user action.
    func open(from url: URL, bestEffort: Bool) async throws -> RecordingLoadResult
}

extension SessionRecordingImportService {
    func open(from url: URL) async throws -> RecordingLoadResult {
        try await open(from: url, bestEffort: false)
    }
}

// MARK: - Result

/// The outcome of a successful recording open operation.
struct RecordingLoadResult: Sendable {
    let envelope: SessionExportEnvelope
    /// IDs of sessions that could not be decoded individually. Other sessions loaded normally.
    let failedSessionIDs: [UUID]
    /// Human-readable notice for schema-version 0 files or best-effort future-schema loads.
    let schemaNotice: String?
    /// Non-nil when the file was large enough to trigger phase-1 body stripping.
    let phase2Source: RecordingPhase2Source?
}

// MARK: - Implementation

/// Reads and decodes a `.jproxy` file using `JSONSerialization` for structural splitting and
/// `JSONDecoder` for typed decoding.
///
/// ## Two-phase strategy
/// For files above `RecordingConstants.lazyLoadThreshold`:
/// - Phase 1: Decodes sessions with `bodyData` stripped so the session list appears immediately.
/// - Phase 2: The coordinator re-decodes sessions with full bodies from `phase2Source`
///   and calls `SessionStore.update(_:)` in batches, filling in bodies progressively.
///
/// ## Per-session decode
/// Sessions are decoded individually so a single malformed session causes a skip rather than
/// aborting the entire load. Skipped session IDs are collected in `failedSessionIDs`.
final class JSONSessionRecordingImportService: SessionRecordingImportService {
    let decoder: JSONDecoder

    init(decoder: JSONDecoder = JSONDecoder()) {
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func open(from url: URL, bestEffort: Bool) async throws -> RecordingLoadResult {
        return try await Task.detached(priority: .userInitiated) { [decoder] in
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RecordingOpenError.fileNotFound(url)
            }

            let containerFormat: UInt8?
            do {
                containerFormat = try RecordingContainer.format(at: url)
            } catch {
                throw RecordingOpenError.malformedJSON(error)
            }
            if containerFormat == RecordingContainer.gzipFormat {
                return try Self.openStreamingGzip(from: url, bestEffort: bestEffort, decoder: decoder)
            }
            if let containerFormat, containerFormat != RecordingContainer.lzfseFormat {
                throw RecordingOpenError.malformedJSON(
                    RecordingContainerError.unsupportedFormat(containerFormat)
                )
            }

            let fileData: Data
            do {
                fileData = try Data(contentsOf: url)
            } catch {
                throw RecordingOpenError.fileNotFound(url)
            }

            // Compressed-container files decompress here; legacy plain-JSON files pass
            // through untouched. Everything downstream (including phase 2) sees plain JSON.
            let data: Data
            do {
                data = try RecordingContainer.unwrap(fileData)
            } catch {
                throw RecordingOpenError.malformedJSON(error)
            }

            // Single parse: the same JSONSerialization root serves the header check and
            // the per-session decode below (previously two full passes over the file).
            let rootObject: Any
            do {
                rootObject = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw RecordingOpenError.malformedJSON(error)
            }
            guard let root = rootObject as? [String: Any] else {
                throw RecordingOpenError.malformedJSON(RecordingHeaderError.notAnObject)
            }
            let header = try Self.header(fromRoot: root)

            // Schema version policy.
            let isTooNew = header.schemaVersion > RecordingConstants.currentSchemaVersion
            if isTooNew && !bestEffort {
                throw RecordingOpenError.schemaTooNew(version: header.schemaVersion)
            }

            let schemaNotice: String?
            if header.schemaVersion == 0 {
                schemaNotice = "This recording was created with an older version of JoesProxy. Some fields may be missing."
            } else if isTooNew {
                schemaNotice = "This recording uses schema v\(header.schemaVersion). Some data may not load correctly in this version of JoesProxy."
            } else {
                schemaNotice = nil
            }

            let isLargeFile = data.count >= RecordingConstants.lazyLoadThreshold
            let (sessions, failedIDs) = Self.decodeSessionsIndividually(
                fromSessionsArray: root["sessions"] as? [[String: Any]] ?? [],
                decoder: decoder,
                stripBodies: isLargeFile
            )

            let envelope = SessionExportEnvelope(
                schemaVersion: header.schemaVersion,
                exportedAt: header.exportedAt,
                appVersion: header.appVersion,
                proxyPort: header.proxyPort,
                recordingFidelity: header.recordingFidelity,
                sessionCount: header.sessionCount,
                sessions: sessions
            )

            return RecordingLoadResult(
                envelope: envelope,
                failedSessionIDs: failedIDs,
                schemaNotice: schemaNotice,
                phase2Source: isLargeFile ? RecordingPhase2Source(legacyEnvelopeData: data) : nil
            )
        }.value
    }

    // MARK: - Per-session decode

    /// Decodes sessions individually from the raw file data so that a single malformed record
    /// causes a skip rather than aborting the entire load.
    ///
    /// When `stripBodies` is `true`, `bodyData` fields are removed from each session's JSON
    /// representation before decoding. This lets phase 1 populate the session list quickly;
    /// the coordinator fills in bodies later using the original `data`.
    static func decodeSessionsIndividually(
        fromSessionsArray sessionsArray: [[String: Any]],
        decoder: JSONDecoder,
        stripBodies: Bool
    ) -> ([SessionRecord], [UUID]) {
        var decoded: [SessionRecord] = []
        var failedIDs: [UUID] = []

        for sessionDict in sessionsArray {
            let targetDict = stripBodies ? Self.strippingBodyData(from: sessionDict) : sessionDict

            guard
                let sessionData = try? JSONSerialization.data(withJSONObject: targetDict),
                let session = try? decoder.decode(SessionRecord.self, from: sessionData)
            else {
                let id = (sessionDict["id"] as? String).flatMap(UUID.init) ?? UUID()
                failedIDs.append(id)
                continue
            }

            decoded.append(session)
        }

        return (decoded, failedIDs)
    }

    /// Returns a copy of `sessionDict` with `bodyData` removed from the request and response
    /// sub-dictionaries and `bodyDeferred` set to `true`. The `bodyDeferred` key is picked up by
    /// the `Codable` decoder and marks the decoded session as pending a phase-2 body fill.
    /// It is never serialized to a `.jproxy` file — see `CapturedRequest.encode(to:)`.
    static func strippingBodyData(from sessionDict: [String: Any]) -> [String: Any] {
        var result = sessionDict
        if var request = result["request"] as? [String: Any] {
            request.removeValue(forKey: "bodyData")
            request["bodyDeferred"] = true
            result["request"] = request
        }
        if var response = result["response"] as? [String: Any] {
            response.removeValue(forKey: "bodyData")
            response["bodyDeferred"] = true
            result["response"] = response
        }
        return result
    }
}

// MARK: - Internal header type

/// Top-level envelope metadata, extracted from the already-parsed JSON root so the file
/// is parsed exactly once. Field requirements match the previous `Decodable` header:
/// only `schemaVersion` is optional (pre-3.5 files omit it → 0).
struct RecordingHeader {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let proxyPort: UInt16
    let recordingFidelity: RecordingSaveFidelity?
    let sessionCount: Int
}

private enum RecordingHeaderError: LocalizedError {
    case notAnObject
    case missingOrInvalidField(String)

    var errorDescription: String? {
        switch self {
        case .notAnObject:
            return "The recording is not a JSON object."
        case .missingOrInvalidField(let field):
            return "The recording header is missing or has an invalid '\(field)' field."
        }
    }
}

extension JSONSessionRecordingImportService {
    fileprivate static let headerDateFormatter = ISO8601DateFormatter()

    static func header(fromRoot root: [String: Any]) throws -> RecordingHeader {
        guard let exportedAtString = root["exportedAt"] as? String,
              let exportedAt = headerDateFormatter.date(from: exportedAtString) else {
            throw RecordingOpenError.malformedJSON(RecordingHeaderError.missingOrInvalidField("exportedAt"))
        }
        guard let appVersion = root["appVersion"] as? String else {
            throw RecordingOpenError.malformedJSON(RecordingHeaderError.missingOrInvalidField("appVersion"))
        }
        guard let proxyPortValue = root["proxyPort"] as? Int,
              let proxyPort = UInt16(exactly: proxyPortValue) else {
            throw RecordingOpenError.malformedJSON(RecordingHeaderError.missingOrInvalidField("proxyPort"))
        }
        guard let sessionCount = root["sessionCount"] as? Int else {
            throw RecordingOpenError.malformedJSON(RecordingHeaderError.missingOrInvalidField("sessionCount"))
        }

        return RecordingHeader(
            schemaVersion: root["schemaVersion"] as? Int ?? 0,
            exportedAt: exportedAt,
            appVersion: appVersion,
            proxyPort: proxyPort,
            recordingFidelity: (root["recordingFidelity"] as? String).flatMap(RecordingSaveFidelity.init(rawValue:)),
            sessionCount: sessionCount
        )
    }
}
