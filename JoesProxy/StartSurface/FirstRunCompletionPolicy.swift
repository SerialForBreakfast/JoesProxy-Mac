import Foundation

/// Pure first-run completion rules for BA-3.
///
/// First run completes only after a request attributable to the selected target is observed.
/// Certificate creation, profile download, proxy start, and dismiss-without-evidence never complete
/// first run. HTTP, tunneled HTTPS, and inspected HTTPS all qualify once a target is selected.
enum FirstRunCompletionPolicy {

    /// Lifecycles that still need selected-target capture evidence.
    static func isAwaitingCaptureEvidence(_ lifecycle: OnboardingLifecycle) -> Bool {
        lifecycle == .inProgress || lifecycle == .expertBypassInProgress
    }

    /// Maps a persisted target hint onto ``MCPSetupReadinessTarget``.
    ///
    /// Accepts the contract raw values plus the lowercase hint IDs used in session-start tests.
    static func target(fromStoredID storedID: String?) -> MCPSetupReadinessTarget? {
        guard let storedID, !storedID.isEmpty else {
            return nil
        }
        if let exact = MCPSetupReadinessTarget(rawValue: storedID) {
            return exact
        }
        switch storedID.lowercased() {
        case "macos", "mac":
            return .macOS
        case "ios", "ipados", "ios/ipados":
            return .iOSiPadOS
        case "tvos":
            return .tvOS
        case "simulator", "sim":
            return .simulator
        case "generic":
            return .generic
        default:
            return nil
        }
    }

    /// Whether a captured session counts as evidence for the selected target.
    ///
    /// Until a target is selected, this is always false. Tunneled HTTPS on loopback has no
    /// User-Agent, so ``TrafficSource/unknown`` still matches Mac and Simulator targets.
    static func sessionMatchesSelectedTarget(
        source: TrafficSource,
        selectedTargetID: String?
    ) -> Bool {
        guard let target = target(fromStoredID: selectedTargetID) else {
            return false
        }
        switch target {
        case .generic:
            return true
        case .macOS:
            return source == .mac || source == .unknown
        case .simulator:
            return source == .simulator || source == .unknown
        case .iOSiPadOS, .tvOS:
            return source == .device
        }
    }

    /// Returns `.completed` when first-run evidence is present; otherwise `nil`.
    static func completedLifecycleIfEligible(
        lifecycle: OnboardingLifecycle,
        selectedTargetID: String?,
        sessionSources: [TrafficSource]
    ) -> OnboardingLifecycle? {
        guard isAwaitingCaptureEvidence(lifecycle) else {
            return nil
        }
        let hasMatch = sessionSources.contains { source in
            sessionMatchesSelectedTarget(source: source, selectedTargetID: selectedTargetID)
        }
        return hasMatch ? .completed : nil
    }
}
