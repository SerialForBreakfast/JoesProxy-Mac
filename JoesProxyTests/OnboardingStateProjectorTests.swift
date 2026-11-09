//
//  OnboardingStateProjectorTests.swift
//  JoesProxyTests
//
//  Tests for BA-2.3 truthful projection and presentation states.
//

import XCTest
@testable import JoesProxy

final class OnboardingStateProjectorTests: XCTestCase {

    func testInitialProjectionWithPersistedHintsPreservesPresentationTruth() {
        let timestamp = Date(timeIntervalSince1970: 1700000000)
        let hints = SessionStartPresentationRecord(
            selectedTargetID: "simulator",
            lastVerificationSummary: "Port 9090",
            lastVerifiedAt: timestamp
        )

        let inputs = OnboardingStateProjector.DomainInputs(
            hints: hints,
            preferredView: .inspector,
            proxyRunning: nil, // Live check in flight
            certificateStatus: nil // Live check in flight
        )

        let state = OnboardingStateProjector.project(from: inputs)

        XCTAssertEqual(state.selectedTargetID, "simulator")
        XCTAssertEqual(state.preferredView, .inspector)

        // Proxy row should be .lastKnown, NOT green .current
        let proxyRow = state.statusRows.first(where: { $0.id == "status.proxy" })
        XCTAssertNotNil(proxyRow)
        XCTAssertEqual(proxyRow?.truth, .lastKnown(summary: "Port 9090", timestamp: timestamp))
        XCTAssertFalse(proxyRow?.truth.isLiveGreen ?? true)

        // Certificate row should be .lastKnown
        let certRow = state.statusRows.first(where: { $0.id == "status.certificate" })
        XCTAssertNotNil(certRow)
        XCTAssertEqual(certRow?.truth, .lastKnown(summary: "CA Installed", timestamp: timestamp))
    }

    func testLiveConfirmedStateTransitionsToCurrent() {
        let hints = SessionStartPresentationRecord.default
        let inputs = OnboardingStateProjector.DomainInputs(
            hints: hints,
            preferredView: .compact,
            proxyRunning: true,
            proxyPort: 8080,
            certificateStatus: "Valid",
            isCertificateTrusted: true,
            isSystemProxyActive: false
        )

        let state = OnboardingStateProjector.project(from: inputs)

        let proxyRow = state.statusRows.first(where: { $0.id == "status.proxy" })
        XCTAssertEqual(proxyRow?.truth, .current("Running on port 8080"))
        XCTAssertTrue(proxyRow?.truth.isLiveGreen ?? false)

        let certRow = state.statusRows.first(where: { $0.id == "status.certificate" })
        XCTAssertEqual(certRow?.truth, .current("Valid (Trusted)"))

        let routingRow = state.statusRows.first(where: { $0.id == "status.routing" })
        XCTAssertEqual(routingRow?.truth, .current("Direct / App Targeted"))
    }

    func testIssuesAreSortedDeterministicallyBySeverity() {
        let launchFacts = LaunchInterruptionArbitrator.LaunchFacts(
            hasSystemProxyRoutingDisruption: true,
            isCertificateUnusable: true
        )
        let inputs = OnboardingStateProjector.DomainInputs(
            proxyRunning: false,
            launchFacts: launchFacts
        )

        let state = OnboardingStateProjector.project(from: inputs)

        // Critical issues first, then info
        XCTAssertEqual(state.issues.count, 3)
        XCTAssertEqual(state.issues[0].severity, .critical)
        XCTAssertEqual(state.issues[1].severity, .critical)
        XCTAssertEqual(state.issues[2].severity, .info)
    }
}
