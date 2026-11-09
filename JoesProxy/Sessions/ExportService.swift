import Foundation

protocol ExportService {
    func export(_ envelope: SessionExportEnvelope, to destinationURL: URL) throws
}

/// The top-level container written to and read from `.jproxy` files.
///
/// `schemaVersion` was introduced in schema version 1. Files written before that point omit the
/// field; `init(from:)` treats missing versions as `0` so those files load with best-effort.
struct SessionExportEnvelope: Equatable, Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let proxyPort: UInt16
    let recordingFidelity: RecordingSaveFidelity?
    let sessionCount: Int
    let sessions: [SessionRecord]

    init(
        schemaVersion: Int = RecordingConstants.currentSchemaVersion,
        exportedAt: Date,
        appVersion: String,
        proxyPort: UInt16,
        recordingFidelity: RecordingSaveFidelity? = nil,
        sessionCount: Int,
        sessions: [SessionRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.proxyPort = proxyPort
        self.recordingFidelity = recordingFidelity
        self.sessionCount = sessionCount
        self.sessions = sessions
    }
}

extension SessionExportEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, exportedAt, appVersion, proxyPort, recordingFidelity, sessionCount, sessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Pre-3.5 exports omit schemaVersion; treat those as version 0.
        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        proxyPort = try container.decode(UInt16.self, forKey: .proxyPort)
        recordingFidelity = try container.decodeIfPresent(RecordingSaveFidelity.self, forKey: .recordingFidelity)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        sessions = try container.decode([SessionRecord].self, forKey: .sessions)
    }
}

/// Writes `SessionExportEnvelope` values to disk as JSON.
///
/// Use `export(_:to:)` for standard JSON / HAR exports (no body truncation).
/// Use `exportAsRecording(_:to:)` for `.jproxy` save operations, which enforces
/// the selected save fidelity policy and marks omitted or truncated bodies explicitly.
final class JSONSessionExportService: ExportService {
    private let encoder: JSONEncoder
    private let recordingCompressionLevel: Int32

    init(
        encoder: JSONEncoder = JSONEncoder(),
        recordingCompressionLevel: Int32 = RecordingStorageBudget.gzipCompressionLevel
    ) {
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        self.recordingCompressionLevel = recordingCompressionLevel
    }

    /// Writes the envelope without body truncation. Used for JSON and HAR interop exports.
    func export(_ envelope: SessionExportEnvelope, to destinationURL: URL) throws {
        try jsonData(envelope).write(to: destinationURL, options: .atomic)
    }

    /// In-memory JSON, for callers that don't want a file on disk (e.g. the `sessions_export`
    /// MCP tool, which returns the content as tool result text instead).
    func jsonData(_ envelope: SessionExportEnvelope) throws -> Data {
        let signpost = CapturePerformanceSignposts.signposter.beginInterval("JSONSessionExportService.export")
        defer { CapturePerformanceSignposts.signposter.endInterval("JSONSessionExportService.export", signpost) }

        return try encoder.encode(envelope)
    }

    /// One JSON line per session (no envelope wrapper), for the `ndjson` export format.
    func ndjsonData(_ envelope: SessionExportEnvelope) throws -> Data {
        var lines: [String] = []
        lines.reserveCapacity(envelope.sessions.count)
        for session in envelope.sessions {
            let lineData = try encoder.encode(session)
            guard let line = String(data: lineData, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            lines.append(line)
        }
        let joined = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        return Data(joined.utf8)
    }

    /// Writes the envelope as a `.jproxy` recording using the selected save fidelity.
    /// Does not mutate the original records. The JSON envelope is encoded one session at a time
    /// through the streaming gzip `RecordingContainer`; the importer transparently reads gzip,
    /// current LZFSE, and legacy plain-JSON files.
    func exportAsRecording(
        _ envelope: SessionExportEnvelope,
        to destinationURL: URL,
        fidelity: RecordingSaveFidelity = .fullRecording
    ) throws {
        let signpost = CapturePerformanceSignposts.signposter.beginInterval("JSONSessionExportService.exportAsRecording")
        defer { CapturePerformanceSignposts.signposter.endInterval("JSONSessionExportService.exportAsRecording", signpost) }

        try writeStreamingRecording(envelope, to: destinationURL, fidelity: fidelity)
    }

    // MARK: - Private

    private func writeStreamingRecording(
        _ envelope: SessionExportEnvelope,
        to destinationURL: URL,
        fidelity: RecordingSaveFidelity
    ) throws {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        let stagingURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).recording-stage"
        )
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle = try FileHandle(forWritingTo: stagingURL)
        var didCloseHandle = false
        defer {
            if !didCloseHandle {
                try? handle.close()
            }
        }

        try handle.write(contentsOf: RecordingContainer.magic)
        try handle.write(contentsOf: Data([RecordingContainer.gzipFormat]))
        let gzipWriter = try RecordingGzipWriter(
            fileHandle: handle,
            compressionLevel: recordingCompressionLevel
        )

        let header = RecordingStreamingEnvelopeHeader(
            schemaVersion: RecordingConstants.currentSchemaVersion,
            exportedAt: envelope.exportedAt,
            appVersion: envelope.appVersion,
            proxyPort: envelope.proxyPort,
            recordingFidelity: fidelity,
            sessionCount: envelope.sessionCount
        )
        var prefix = try encoder.encode(header)
        guard prefix.last == UInt8(ascii: "}") else {
            throw RecordingContainerError.corruptPayload
        }
        prefix.removeLast()
        prefix.append(contentsOf: Data(",\"sessions\":[".utf8))
        try gzipWriter.write(prefix)

        for (index, record) in envelope.sessions.enumerated() {
            try Task.checkCancellation()
            if index > 0 {
                try gzipWriter.write(Data([UInt8(ascii: ",")]))
            }
            let sessionData = try autoreleasepool {
                try encoder.encode(transformedRecord(record, fidelity: fidelity))
            }
            try gzipWriter.write(sessionData)
        }

        try gzipWriter.write(Data("]}".utf8))
        try gzipWriter.finish()
        try handle.synchronize()
        try handle.close()
        didCloseHandle = true

        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
        shouldRemoveStaging = false
    }

    private func transformedRecord(
        _ record: SessionRecord,
        fidelity: RecordingSaveFidelity
    ) -> SessionRecord {
        // Full fidelity preserves all available evidence, including capture-time limitations.
        guard fidelity != .fullRecording else { return record }
        var transformed = record
        transformed.request = transformedRequest(record.request, record: record, fidelity: fidelity)
        if let response = record.response {
            transformed.response = transformedResponse(response, record: record, fidelity: fidelity)
        }
        return transformed
    }

    private func transformedRequest(
        _ request: CapturedRequest,
        record: SessionRecord,
        fidelity: RecordingSaveFidelity
    ) -> CapturedRequest {
        transformedRequestOrResponseBody(
            bodyData: request.bodyData,
            bodySize: request.bodySize,
            headers: request.headers,
            mediaType: MediaDetector.mediaType(for: record),
            path: request.path,
            fidelity: fidelity,
            build: { bodyData, bodyTruncated, omissionReason in
                CapturedRequest(
                    method: request.method,
                    scheme: request.scheme,
                    inspectionKind: request.inspectionKind,
                    inspectionReason: request.inspectionReason,
                    host: request.host,
                    port: request.port,
                    path: request.path,
                    headers: request.headers,
                    bodyData: bodyData,
                    bodySize: request.bodySize,
                    bodyTruncated: bodyTruncated || request.bodyTruncated,
                    recordingBodyOmissionReason: omissionReason ?? request.recordingBodyOmissionReason,
                    bodyDeferred: request.bodyDeferred,
                    clientAddress: request.clientAddress,
                    localCACertificateSHA256Fingerprint: request.localCACertificateSHA256Fingerprint,
                    remoteTrustState: request.remoteTrustState
                )
            }
        )
    }

    private func transformedResponse(
        _ response: CapturedResponse,
        record: SessionRecord,
        fidelity: RecordingSaveFidelity
    ) -> CapturedResponse {
        transformedRequestOrResponseBody(
            bodyData: response.bodyData,
            bodySize: response.bodySize,
            headers: response.headers,
            mediaType: MediaDetector.mediaType(for: record),
            path: record.request.path,
            fidelity: fidelity,
            build: { bodyData, bodyTruncated, omissionReason in
                CapturedResponse(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    bodyData: bodyData,
                    bodySize: response.bodySize,
                    source: response.source,
                    sourceDescription: response.sourceDescription,
                    bodyTruncated: bodyTruncated || response.bodyTruncated,
                    recordingBodyOmissionReason: omissionReason ?? response.recordingBodyOmissionReason,
                    bodyDeferred: response.bodyDeferred,
                    mcpAttribution: response.mcpAttribution,
                    localCACertificateSHA256Fingerprint: response.localCACertificateSHA256Fingerprint
                )
            }
        )
    }

    private func transformedRequestOrResponseBody<T>(
        bodyData: Data?,
        bodySize: Int?,
        headers: [HTTPHeaderField],
        mediaType: MediaType,
        path: String,
        fidelity: RecordingSaveFidelity,
        build: (Data?, Bool, RecordingBodyOmissionReason?) -> T
    ) -> T {
        guard let bodyData else {
            return build(nil, false, nil)
        }

        switch fidelity {
        case .fullRecording:
            return build(bodyData, false, nil)

        case .metadataOnly:
            return build(nil, false, bodySize == nil ? nil : .metadataOnly)

        case .textBodiesOnly:
            guard isReadableTextBody(bodyData: bodyData, headers: headers) else {
                return build(nil, false, bodySize == nil ? nil : .binaryExcludedFromTextMode)
            }
            return truncatedBodyResult(
                bodyData: bodyData,
                limit: RecordingConstants.textBodySizeLimit,
                build: build
            )

        case .mediaFocused:
            if isReadableTextBody(bodyData: bodyData, headers: headers) {
                return truncatedBodyResult(
                    bodyData: bodyData,
                    limit: RecordingConstants.textBodySizeLimit,
                    build: build
                )
            }

            guard isMediaRelevant(mediaType: mediaType) else {
                return build(nil, false, bodySize == nil ? nil : .nonMediaBinaryExcluded)
            }

            let limit = mediaBodyLimit(path: path)
            if bodyData.count > limit {
                return build(nil, false, .oversizedMediaExcluded)
            }

            return build(bodyData, false, nil)
        }
    }

    private func truncatedBodyResult<T>(
        bodyData: Data,
        limit: Int,
        build: (Data?, Bool, RecordingBodyOmissionReason?) -> T
    ) -> T {
        guard bodyData.count > limit else {
            return build(bodyData, false, nil)
        }
        return build(Data(bodyData.prefix(limit)), true, nil)
    }

    private func isReadableTextBody(bodyData: Data, headers: [HTTPHeaderField]) -> Bool {
        if let contentType = headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value.lowercased() {
            let mimeType = contentType.split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? contentType
            if mimeType.hasPrefix("text/") ||
                mimeType.contains("json") ||
                mimeType.contains("xml") ||
                mimeType.contains("javascript") ||
                mimeType.contains("x-www-form-urlencoded") ||
                mimeType == "application/vnd.apple.mpegurl" ||
                mimeType == "audio/mpegurl" ||
                mimeType == "application/dash+xml" {
                return true
            }
        }

        return String(data: bodyData, encoding: .utf8) != nil
    }

    private func isMediaRelevant(mediaType: MediaType) -> Bool {
        switch mediaType {
        case .hls, .hlsDiscovery, .dash, .video, .adXml:
            return true
        case .image, .none:
            return false
        }
    }

    private func mediaBodyLimit(path: String) -> Int {
        isLikelyInitializationSegment(path: path)
            ? RecordingConstants.mediaInitSegmentBodySizeLimit
            : RecordingConstants.mediaSegmentBodySizeLimit
    }

    private func isLikelyInitializationSegment(path: String) -> Bool {
        let normalizedPath = path.lowercased()
        return normalizedPath.contains("init") ||
            normalizedPath.contains("header") ||
            normalizedPath.contains("bootstrap")
    }
}

private struct RecordingStreamingEnvelopeHeader: Encodable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let proxyPort: UInt16
    let recordingFidelity: RecordingSaveFidelity?
    let sessionCount: Int
}
