import XCTest
@testable import JoesProxy

@MainActor
final class AgentCaptureRecoveryControllerTests: XCTestCase {
    func testRestoreRejectsExistingCaptureWithoutInspectorModel() async {
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(10))
        store.append(SessionRecord(
            request: CapturedRequest(
                method: "GET", scheme: .http, host: "example.test", port: 80,
                path: "/current", headers: [], bodyData: nil, bodySize: nil
            ),
            timing: SessionTiming(startedAt: Date())
        ))
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = RollingCapturePersistenceCoordinator(
            sessionStore: store,
            configuration: UserDefaultsAppConfiguration(userDefaults: defaults),
            proxyPortProvider: { 9090 },
            storageAccessEnabled: false
        )
        let controller = AgentCaptureRecoveryController(sessionStore: store, persistence: persistence)

        do {
            _ = try await controller.restoreLatestCapture()
            XCTFail("Expected existing capture to prevent replacement")
        } catch let error as RollingCaptureRestoreError {
            XCTAssertEqual(error, .captureChanged)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testStartFreshSuppressesAutomaticPromptButPreservesManualRecovery() async throws {
        let store = InMemorySessionStore()
        let suiteName = "AgentCaptureRecovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/AgentCaptureRecovery-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.rollingCaptureAutoSaveEnabled = true
        let persistence = RollingCapturePersistenceCoordinator(
            sessionStore: store,
            configuration: configuration,
            proxyPortProvider: { 9090 },
            storageDirectoryOverride: directory
        )
        let savedSession = SessionRecord(
            request: CapturedRequest(
                method: "GET", scheme: .http, host: "example.test", port: 80,
                path: "/saved", headers: [], bodyData: nil, bodySize: nil
            ),
            timing: SessionTiming(startedAt: Date())
        )
        await persistence.flushSnapshot(sessions: [savedSession])
        XCTAssertNotNil(persistence.shouldOfferRestoreOnLaunch(sessionCount: 0))

        AgentCaptureRecoveryController(sessionStore: store, persistence: persistence).startFresh()

        XCTAssertNil(persistence.shouldOfferRestoreOnLaunch(sessionCount: 0))
        XCTAssertNotNil(persistence.availableRestoreOffer())
    }
}
