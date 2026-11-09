import XCTest
@testable import JoesProxy

@MainActor
final class AgentCaptureExportControllerTests: XCTestCase {
    func testHARExportUsesCanonicalContentAndRetainsReceipt() async throws {
        let suite = "AgentHAR-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/AgentHAR-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("capture.har")
        let store = InMemorySessionStore()
        store.append(SessionRecord(request: CapturedRequest(method: "GET", scheme: .http,
            host: "example.test", port: 80, path: "/synthetic", headers: [], bodyData: nil, bodySize: nil),
            timing: SessionTiming(startedAt: Date())))
        let controller = AgentCaptureExportController(sessionStore: store,
            configuration: UserDefaultsAppConfiguration(userDefaults: defaults))
        try await controller.saveAllSessions(to: destination, asHAR: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
        let log = try XCTUnwrap(json["log"] as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(controller.isSaving)
        XCTAssertEqual(controller.resultMessage, "Saved capture.har.")
        do {
            try await controller.saveAllSessions(to: directory.appendingPathComponent("missing/capture.har"), asHAR: true)
            XCTFail("Missing destination directory must report a failure")
        } catch {
            XCTAssertFalse(controller.isSaving)
            XCTAssertNotEqual(controller.resultMessage, "Saved capture.har.")
        }
    }

    func testEmptyCaptureIsRejectedBeforeDestinationWrite() async {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AgentCaptureExportController(
            sessionStore: InMemorySessionStore(retentionPolicy: .keepLastSessions(10)),
            configuration: UserDefaultsAppConfiguration(userDefaults: defaults)
        )

        do {
            try await controller.saveAllSessions(to: URL(fileURLWithPath: "/agent-export-test.jproxy"))
            XCTFail("Expected an empty capture to be rejected")
        } catch let error as AgentCaptureExportController.ExportError {
            XCTAssertEqual(error.errorDescription, "There are no captured sessions to save.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
