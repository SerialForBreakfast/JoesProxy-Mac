import XCTest
@testable import JoesProxy

@MainActor
final class AgentSetupReadinessMonitorTests: XCTestCase {
    func testMonitorReportsInspectedTrafficWithoutInspectorModel() async {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(10))
        store.append(SessionRecord(
            request: CapturedRequest(
                method: "GET", scheme: .https, host: "example.test", port: 443,
                path: "/ready", headers: [], bodyData: nil, bodySize: nil
            ),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
            timing: SessionTiming(startedAt: Date())
        ))
        let monitor = AgentSetupReadinessMonitor(
            configuration: configuration,
            proxyRuntime: UITestProxyRuntime(initialState: .running(port: 9090), configuredPort: 9090),
            sessionStore: store,
            certificateAuthority: UITestCertificateAuthority(currentIdentity: UITestCertificateAuthority.demoIdentity),
            trustInstaller: UITestTrustInstaller(status: .installed),
            profileSnapshotStore: AgentReadinessProfileSnapshotStore(),
            localNetworkInfoProvider: AgentReadinessNetworkInfoProvider()
        )

        let state = await monitor.readinessState()

        XCTAssertEqual(state.localTrustState, .ready)
        XCTAssertEqual(state.verificationState, .inspected)
        XCTAssertEqual(state.profileHealth, .unknown)
        XCTAssertFalse(state.profileDownloadObserved)
    }

    func testStoppedRuntimeDoesNotInferTrafficReadiness() async {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        let monitor = AgentSetupReadinessMonitor(
            configuration: configuration,
            proxyRuntime: UITestProxyRuntime(initialState: .stopped, configuredPort: 9090),
            sessionStore: InMemorySessionStore(retentionPolicy: .keepLastSessions(10)),
            certificateAuthority: UITestCertificateAuthority(currentIdentity: nil),
            trustInstaller: UITestTrustInstaller(status: .notInstalled),
            profileSnapshotStore: AgentReadinessProfileSnapshotStore(),
            localNetworkInfoProvider: AgentReadinessNetworkInfoProvider()
        )

        let state = await monitor.readinessState()

        XCTAssertEqual(state.localTrustState, .notSetUp)
        XCTAssertEqual(state.verificationState, .proxyStopped)
    }
}

private final class AgentReadinessProfileSnapshotStore: ProfileSnapshotStoring {
    func loadSnapshots() -> [GeneratedProfileSnapshot] { [] }
    func appendSnapshot(_: GeneratedProfileSnapshot) throws {}
}

private struct AgentReadinessNetworkInfoProvider: LocalNetworkInfoProviding {
    func current() -> LocalNetworkInfo { LocalNetworkInfo(lanIP: nil, bonjourName: nil) }
}
