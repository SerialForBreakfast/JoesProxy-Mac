import XCTest
@testable import JoesProxy

final class ExportServiceTests: XCTestCase {
    func testJSONExportUsesEnvelopeMetadata() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let service = JSONSessionExportService(encoder: encoder)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let completedAt = startedAt.addingTimeInterval(1)

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .http,
                host: "example.com",
                port: 80,
                path: "/status",
                headers: [HTTPHeaderField(name: "Host", value: "example.com")],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Length", value: "2")],
                bodyData: Data("OK".utf8),
                bodySize: 2
            ),
            state: .completed,
            timing: SessionTiming(startedAt: startedAt, completedAt: completedAt)
        )

        let envelope = SessionExportEnvelope(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: Bundle.main.marketingVersionOrDev,
            proxyPort: 9090,
            sessionCount: 1,
            sessions: [session]
        )

        try service.export(envelope, to: destinationURL)

        let exportedData = try Data(contentsOf: destinationURL)
        let decodedEnvelope = try JSONDecoder.iso8601.decode(SessionExportEnvelope.self, from: exportedData)

        XCTAssertEqual(decodedEnvelope, envelope)
    }

    func testRecordingExportUsesCompactJSON() throws {
        let service = JSONSessionExportService()
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jproxy")

        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .http,
                host: "example.com",
                port: 80,
                path: "/status",
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: Data("{\"ok\":true}".utf8),
                bodySize: 11
            ),
            response: nil,
            state: .completed,
            timing: SessionTiming(startedAt: Date(timeIntervalSince1970: 1_700_000_100))
        )

        let envelope = SessionExportEnvelope(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: Bundle.main.marketingVersionOrDev,
            proxyPort: 9090,
            sessionCount: 1,
            sessions: [session]
        )

        try service.exportAsRecording(envelope, to: destinationURL, fidelity: .fullRecording)

        let fileData = try Data(contentsOf: destinationURL)
        XCTAssertEqual(fileData.prefix(4), RecordingContainer.magic, "Recordings are written in the JPXR container.")
        XCTAssertEqual(fileData[4], RecordingContainer.gzipFormat, "New recordings use the streaming gzip format.")

        let payload = try RecordingContainer.unwrap(fileData)
        let exported = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertFalse(exported.contains("\n  "), "Recording JSON should be compact rather than pretty printed.")
    }

    func testRecordingContainerCompressesRepresentativePayload() throws {
        // JSON with base64-ish bodies — representative of real recordings. LZFSE should
        // shrink it substantially; guard against the container silently becoming a no-op.
        let sessionsJSON = (0..<200).map { index in
            #"{"id":"\#(UUID().uuidString)","host":"api.example.com","path":"/v1/items/\#(index)","bodyData":"eyJvayI6dHJ1ZSwiZGF0YSI6WzEsMiwzLDQsNSw2LDcsOF19"}"#
        }.joined(separator: ",")
        let payload = Data(#"{"schemaVersion":2,"sessions":[\#(sessionsJSON)]}"#.utf8)

        let wrapped = try RecordingContainer.wrap(payload)

        XCTAssertLessThan(wrapped.count, payload.count / 2, "Expected at least 2x compression on representative JSON")
        XCTAssertEqual(try RecordingContainer.unwrap(wrapped), payload)
    }

    func testRecordingContainerRoundTripAndLegacyPassthrough() throws {
        let payload = Data(#"{"schemaVersion":2,"hello":"world"}"#.utf8)

        let wrapped = try RecordingContainer.wrap(payload)
        XCTAssertEqual(wrapped.prefix(4), RecordingContainer.magic)
        XCTAssertEqual(try RecordingContainer.unwrap(wrapped), payload)

        // Legacy plain-JSON bytes pass through untouched.
        XCTAssertEqual(try RecordingContainer.unwrap(payload), payload)

        // Unknown format byte fails with a clear error instead of a JSON parse failure.
        var future = RecordingContainer.magic
        future.append(0x7F)
        future.append(payload)
        XCTAssertThrowsError(try RecordingContainer.unwrap(future)) { error in
            guard case RecordingContainerError.unsupportedFormat(0x7F) = error else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
        }
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
