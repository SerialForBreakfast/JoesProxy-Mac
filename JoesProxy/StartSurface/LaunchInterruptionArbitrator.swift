//
//  LaunchInterruptionArbitrator.swift
//  JoesProxy
//
//  Serializes launch interruptions so that competing alerts/sheets are presented
//  one at a time in strict deterministic priority order and recomputed dynamically (BA-2.5).
//

import Foundation

enum LaunchInterruptionArbitrator {

    struct LaunchFacts: Equatable, Sendable {
        var hasSystemProxyRoutingDisruption: Bool
        var isCertificateUnusable: Bool
        var hasActiveEffectConflict: Bool
        var hasUnsavedCaptureRestorationOffer: Bool
        var onboardingLifecycle: OnboardingLifecycle

        init(
            hasSystemProxyRoutingDisruption: Bool = false,
            isCertificateUnusable: Bool = false,
            hasActiveEffectConflict: Bool = false,
            hasUnsavedCaptureRestorationOffer: Bool = false,
            onboardingLifecycle: OnboardingLifecycle = .completed
        ) {
            self.hasSystemProxyRoutingDisruption = hasSystemProxyRoutingDisruption
            self.isCertificateUnusable = isCertificateUnusable
            self.hasActiveEffectConflict = hasActiveEffectConflict
            self.hasUnsavedCaptureRestorationOffer = hasUnsavedCaptureRestorationOffer
            self.onboardingLifecycle = onboardingLifecycle
        }
    }

    /// Evaluates current launch facts and returns the single highest-priority interruption, or nil if none.
    ///
    /// Priority order:
    /// 1. System proxy restoration (priority 1)
    /// 2. Unusable certificate repair (priority 2)
    /// 3. Active-effect conflict recovery (priority 3)
    /// 4. Saved-capture restoration offer (priority 4)
    /// 5. First-run path choice while onboarding has not started (priority 5)
    ///
    /// In-progress first capture is Inspector companion chrome, not a launch interruption.
    static func nextInterruption(from facts: LaunchFacts) -> LaunchInterruptionKind? {
        if facts.hasSystemProxyRoutingDisruption {
            return .systemProxyRecovery
        }
        if facts.isCertificateUnusable {
            return .certificateRepair
        }
        if facts.hasActiveEffectConflict {
            return .effectConflictRecovery
        }
        if facts.hasUnsavedCaptureRestorationOffer {
            return .savedCaptureRestoration
        }
        if facts.onboardingLifecycle == .notStarted {
            return .guidedSetup
        }
        return nil
    }
}
