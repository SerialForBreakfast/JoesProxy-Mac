import XCTest
@testable import JoesProxy

@MainActor
final class AgentCaptureHealthMonitorTests: XCTestCase {
    func testMonitorReadsStoreAndRuntimeWithoutInspectorProjection() async {
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(10))
        let runtime = UITestProxyRuntime(initialState: .stopped, configuredPort: 9090)
        let monitor = AgentCaptureHealthMonitor(
            sessionStore: store,
            proxyRuntime: runtime,
            processMetricsSampler: FixedProcessMetricsSampler()
        )

        XCTAssertEqual(monitor.health.sessionCount, 0)
        await runtime.start()
        XCTAssertNotNil(monitor.health.captureStartedAt)

        store.append(SessionRecord(
            request: CapturedRequest(
                method: "GET", scheme: .http, host: "example.test", port: 80,
                path: "/agent-monitor", headers: [], bodyData: nil, bodySize: nil
            ),
            timing: SessionTiming(startedAt: Date())
        ))
        monitor.refresh()
        XCTAssertEqual(monitor.health.sessionCount, 1)
        XCTAssertNotNil(monitor.health.captureDuration)

        await runtime.stop()
        XCTAssertNil(monitor.health.captureStartedAt)
    }
}

private final class FixedProcessMetricsSampler: ProcessMetricsSampling {
    func sample() -> AppProcessMetrics { .empty }
}
