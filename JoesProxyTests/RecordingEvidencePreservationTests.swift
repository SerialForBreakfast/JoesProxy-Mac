import XCTest
@testable import JoesProxy

final class RecordingEvidencePreservationTests: XCTestCase {
    func testEverySaveModePreservesExistingMissingBodyEvidenceAndIdentity() throws {
        let request = CapturedRequest(
            method: "POST", scheme: .https, host: "example.test", port: 443,
            path: "/fixture", headers: [], bodyData: nil, bodySize: 120,
            bodyTruncated: true, recordingBodyOmissionReason: .retentionEvicted,
            clientAddress: "192.0.2.1", localCACertificateSHA256Fingerprint: "synthetic"
        )
        let response = CapturedResponse(
            statusCode: 200, headers: [], bodyData: nil, bodySize: 200,
            bodyTruncated: true, recordingBodyOmissionReason: .oversizedMediaExcluded,
            localCACertificateSHA256Fingerprint: "synthetic"
        )
        let envelope = SessionExportEnvelope(
            exportedAt: Date(timeIntervalSince1970: 0), appVersion: "test", proxyPort: 9090,
            sessionCount: 1, sessions: [SessionRecord(
                request: request, response: response, state: .completed,
                timing: SessionTiming(startedAt: Date(timeIntervalSince1970: 0))
            )]
        )
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/recording-evidence-tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).jproxy")
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for fidelity in RecordingSaveFidelity.allCases {
            try JSONSessionExportService().exportAsRecording(envelope, to: url, fidelity: fidelity)
            let payload = try RecordingContainer.unwrap(Data(contentsOf: url))
            let decoded = try decoder.decode(SessionExportEnvelope.self, from: payload)
            XCTAssertEqual(decoded.sessions, envelope.sessions, fidelity.rawValue)
        }

        let har = try JSONSerialization.jsonObject(with: HARSessionExportService().harData(envelope))
        let root = try XCTUnwrap(har as? [String: Any])
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        for side in ["request", "response"] {
            let object = try XCTUnwrap(entries[0][side] as? [String: Any])
            let comment = try XCTUnwrap(object["comment"] as? String)
            XCTAssertTrue(comment.contains("truncated"))
            XCTAssertTrue(comment.contains("unavailable"))
            XCTAssertTrue(comment.contains(side == "request" ? "removed" : "omitted"))
        }
    }
}
