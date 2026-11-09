//
//  LaunchInterruptionArbitratorTests.swift
//  JoesProxyTests
//
//  Tests for BA-2.5 launch interruption priority serialization.
//

import XCTest
@testable import JoesProxy

final class LaunchInterruptionArbitratorTests: XCTestCase {

    func testPriorityOrderArbitration() {
        // Multi-condition state: System Proxy + Cert + Saved Capture + First-run
        let allFacts = LaunchInterruptionArbitrator.LaunchFacts(
            hasSystemProxyRoutingDisruption: true,
            isCertificateUnusable: true,
            hasActiveEffectConflict: true,
            hasUnsavedCaptureRestorationOffer: true,
            onboardingLifecycle: .notStarted
        )

        // 1. Highest priority must be systemProxyRecovery
        XCTAssertEqual(LaunchInterruptionArbitrator.nextInterruption(from: allFacts), .systemProxyRecovery)

        // 2. Once system proxy disruption is resolved -> certificateRepair
        var step2Facts = allFacts
        step2Facts.hasSystemProxyRoutingDisruption = false
        XCTAssertEqual(LaunchInterruptionArbitrator.nextInterruption(from: step2Facts), .certificateRepair)

        // 3. Once certificate is repaired -> effectConflictRecovery
        var step3Facts = step2Facts
        step3Facts.isCertificateUnusable = false
        XCTAssertEqual(LaunchInterruptionArbitrator.nextInterruption(from: step3Facts), .effectConflictRecovery)

        // 4. Once effect conflict is resolved -> savedCaptureRestoration
        var step4Facts = step3Facts
        step4Facts.hasActiveEffectConflict = false
        XCTAssertEqual(LaunchInterruptionArbitrator.nextInterruption(from: step4Facts), .savedCaptureRestoration)

        // 5. Once saved capture choice is made -> guidedSetup
        var step5Facts = step4Facts
        step5Facts.hasUnsavedCaptureRestorationOffer = false
        XCTAssertEqual(LaunchInterruptionArbitrator.nextInterruption(from: step5Facts), .guidedSetup)

        // 6. Once onboarding is completed -> no interruption (clean shell)
        var step6Facts = step5Facts
        step6Facts.onboardingLifecycle = .completed
        XCTAssertNil(LaunchInterruptionArbitrator.nextInterruption(from: step6Facts))
    }

    func testSavedCaptureOutranksFirstRunGuidedSetup() {
        let facts = LaunchInterruptionArbitrator.LaunchFacts(
            hasUnsavedCaptureRestorationOffer: true,
            onboardingLifecycle: .notStarted
        )
        XCTAssertEqual(
            LaunchInterruptionArbitrator.nextInterruption(from: facts),
            .savedCaptureRestoration
        )
    }
}
