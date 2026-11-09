//
//  SessionStartCoordinatorTests.swift
//  JoesProxyTests
//
//  Tests for BA-2.2 SessionStartCoordinator zero-await first frame & independent reconciliation.
//

import XCTest
@testable import JoesProxy

private final class HangingProxyProvider: SessionStartLiveProxyProviding {
    func isProxyRunning() async -> Bool {
        // Hangs forever
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        return true
    }

    func proxyPort() -> UInt16 { 9090 }
}

private final class MockFastCertificateProvider: SessionStartLiveCertificateProviding {
    func checkCertificateStatus() async -> (status: String, isTrusted: Bool) {
        ("Production CA Ready", true)
    }
}

@MainActor
final class SessionStartCoordinatorTests: XCTestCase {

    func testZeroAwaitFirstFramePublishesImmediatelyWithoutAwaitingProviders() {
        let testDefaults = UserDefaults(suiteName: "testZeroAwaitFirstFrame")!
        testDefaults.removePersistentDomain(forName: "testZeroAwaitFirstFrame")
        let config = UserDefaultsAppConfiguration(userDefaults: testDefaults)

        let timestamp = Date(timeIntervalSince1970: 1700000000)
        config.sessionStartPresentationRecord = SessionStartPresentationRecord(
            selectedTargetID: "macos",
            lastVerificationSummary: "Port 9090",
            lastVerifiedAt: timestamp
        )

        // Inject a hanging provider
        let hangingProxy = HangingProxyProvider()
        let coordinator = SessionStartCoordinator(
            configuration: config,
            proxyProvider: hangingProxy
        )

        // Must immediately have a valid workingSurfaceState without blocking or awaiting
        let state = coordinator.workingSurfaceState
        XCTAssertEqual(state.selectedTargetID, "macos")
        XCTAssertEqual(state.statusRows.first(where: { $0.id == "status.proxy" })?.truth, .lastKnown(summary: "Port 9090", timestamp: timestamp))
    }

    func testReconciliationUpdatesIndependentProvidersAsynchronously() async {
        let testDefaults = UserDefaults(suiteName: "testReconciliationUpdates")!
        testDefaults.removePersistentDomain(forName: "testReconciliationUpdates")
        let config = UserDefaultsAppConfiguration(userDefaults: testDefaults)

        let certProvider = MockFastCertificateProvider()
        let coordinator = SessionStartCoordinator(
            configuration: config,
            certificateProvider: certProvider
        )

        // Initial state before reconciliation: checking
        XCTAssertEqual(coordinator.workingSurfaceState.statusRows.first(where: { $0.id == "status.certificate" })?.truth, .checking)

        // Trigger reconciliation
        coordinator.startReconciliation()

        // Wait a few milliseconds for async task to complete
        try? await Task.sleep(nanoseconds: 50_000_000)

        // State should now be .current
        XCTAssertEqual(coordinator.workingSurfaceState.statusRows.first(where: { $0.id == "status.certificate" })?.truth, .current("Production CA Ready (Trusted)"))
    }
}
