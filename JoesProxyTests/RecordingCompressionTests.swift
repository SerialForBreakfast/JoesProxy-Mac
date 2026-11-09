import XCTest
@testable import JoesProxy

final class RecordingCompressionTests: XCTestCase {
    private let exportService = JSONSessionExportService()
    private let importService = JSONSessionRecordingImportService()

    func testRecordingWriterUsesGzipV2AndPreservesLogicalEnvelope() async throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let envelope = makeEnvelope(path: #"/search/{\"value\":\"},[\\\"\"}"#)

        try exportService.exportAsRecording(envelope, to: url, fidelity: .fullRecording)

        XCTAssertEqual(try RecordingContainer.format(at: url), RecordingContainer.gzipFormat)
        let payload = try RecordingContainer.unwrap(Data(contentsOf: url))
        let decoded = try JSONDecoder.recordingDecoder.decode(SessionExportEnvelope.self, from: payload)
        XCTAssertEqual(decoded.sessions, envelope.sessions)

        let imported = try await importService.open(from: url)
        XCTAssertEqual(imported.envelope.sessions, envelope.sessions)
        XCTAssertEqual(imported.envelope.recordingFidelity, .fullRecording)
    }

    func testLegacyLZFSEContainerRemainsReadable() async throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let envelope = makeEnvelope()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try RecordingContainer.wrap(encoder.encode(envelope)).write(to: url)

        XCTAssertEqual(try RecordingContainer.format(at: url), RecordingContainer.lzfseFormat)
        let imported = try await importService.open(from: url)
        XCTAssertEqual(imported.envelope.sessions, envelope.sessions)
    }

    func testGzipReaderRejectsBadTrailerAndTrailingPayload() throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try exportService.exportAsRecording(makeEnvelope(), to: url)
        let valid = try Data(contentsOf: url)

        var badTrailer = valid
        badTrailer[badTrailer.index(before: badTrailer.endIndex)] ^= 0xFF
        XCTAssertThrowsError(try RecordingContainer.unwrap(badTrailer)) { error in
            guard case RecordingContainerError.corruptPayload = error else {
                return XCTFail("Expected corruptPayload, got \(error)")
            }
        }

        var trailing = valid
        trailing.append(0x00)
        XCTAssertThrowsError(try RecordingContainer.unwrap(trailing)) { error in
            guard case RecordingContainerError.trailingPayload = error else {
                return XCTFail("Expected trailingPayload, got \(error)")
            }
        }
    }

    func testGzipReaderRejectsTruncatedPayloadAndHeader() throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try exportService.exportAsRecording(makeEnvelope(), to: url)
        let valid = try Data(contentsOf: url)
        let truncated = Data(valid.dropLast(4))

        XCTAssertThrowsError(try RecordingContainer.unwrap(truncated)) { error in
            guard case RecordingContainerError.corruptPayload = error else {
                return XCTFail("Expected corruptPayload, got \(error)")
            }
        }

        var headerOnly = RecordingContainer.magic
        headerOnly.append(RecordingContainer.gzipFormat)
        XCTAssertThrowsError(try RecordingContainer.unwrap(headerOnly)) { error in
            guard case RecordingContainerError.truncatedHeader = error else {
                return XCTFail("Expected truncatedHeader, got \(error)")
            }
        }
    }

    func testBoundedHeaderInspectionFindsSessionCount() throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let sessions = (0..<12).map { makeSession(path: "/items/\($0)") }
        let envelope = makeEnvelope(sessions: sessions)
        try exportService.exportAsRecording(envelope, to: url)

        let root = try JSONSessionRecordingImportService.streamingHeaderRoot(from: url)
        XCTAssertEqual(root["sessionCount"] as? Int, sessions.count)
    }

    func testCancelledSavePreservesExistingDestination() async throws {
        let url = temporaryRecordingURL()
        let original = Data("previous-good-recording".utf8)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let task = Task.detached { [exportService] in
            try exportService.exportAsRecording(makeEnvelope(), to: url)
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testTextHeavyRecordingCompressesSubstantially() throws {
        let url = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let body = Data(String(repeating: #"{\"status\":\"ready\",\"items\":[1,2,3,4]}"#, count: 2_000).utf8)
        let sessions = (0..<100).map { index in
            makeSession(path: "/items/\(index)", body: body)
        }
        let envelope = makeEnvelope(sessions: sessions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let logicalBytes = try encoder.encode(envelope).count

        try exportService.exportAsRecording(envelope, to: url)
        let storedBytes = try Data(contentsOf: url).count

        XCTAssertLessThan(storedBytes, logicalBytes / 5)
    }

    private func temporaryRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jproxy")
    }
}

private func makeEnvelope(
    path: String = "/items",
    sessions: [SessionRecord]? = nil
) -> SessionExportEnvelope {
    let resolvedSessions = sessions ?? [makeSession(path: path)]
    return SessionExportEnvelope(
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
        appVersion: "recording-compression-test",
        proxyPort: 9090,
        sessionCount: resolvedSessions.count,
        sessions: resolvedSessions
    )
}

private func makeSession(path: String, body: Data = Data(#"{\"ok\":true}"#.utf8)) -> SessionRecord {
    SessionRecord(
        request: CapturedRequest(
            method: "GET",
            scheme: .https,
            inspectionKind: .interceptedTLS,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: [HTTPHeaderField(name: "Accept", value: "application/json")],
            bodyData: nil,
            bodySize: nil
        ),
        response: CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: body,
            bodySize: body.count
        ),
        state: .completed,
        timing: SessionTiming(
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            completedAt: Date(timeIntervalSince1970: 1_700_000_101)
        )
    )
}

private extension JSONDecoder {
    static var recordingDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

