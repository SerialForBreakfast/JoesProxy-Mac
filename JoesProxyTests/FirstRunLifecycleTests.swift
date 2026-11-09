import XCTest
@testable import JoesProxy

@MainActor
final class FirstRunLifecycleTests: XCTestCase {

    func testStartFirstCaptureWritesInProgressWithoutCompleting() {
        let configuration = makeConfiguration()
        let presentationState = AppPresentationState(configuration: configuration)

        presentationState.presentFirstRunPathChoiceIfNeeded()
        presentationState.chooseStartFirstCapture()

        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .inProgress)
        XCTAssertEqual(configuration.preferredWorkingView, .inspector)
        XCTAssertTrue(presentationState.shouldShowInspectorSetupCompanion)
        XCTAssertTrue(presentationState.showsFirstRunSetupChip)
        XCTAssertFalse(configuration.hasCompletedInitialGuidedSetupPresentation)
        XCTAssertFalse(presentationState.isFirstRunPathChoicePresented)
    }

    func testConnectAnAgentWritesInProgressAndCompactPreference() {
        let configuration = makeConfiguration()
        let presentationState = AppPresentationState(configuration: configuration)

        presentationState.chooseConnectAnAgent()

        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .inProgress)
        XCTAssertEqual(configuration.preferredWorkingView, .compact)
        XCTAssertFalse(presentationState.shouldShowInspectorSetupCompanion)
        XCTAssertTrue(presentationState.showsFirstRunSetupChip)
        XCTAssertFalse(configuration.hasCompletedInitialGuidedSetupPresentation)
    }

    func testOpenInspectorWritesExpertBypassWithoutCompleting() {
        let configuration = makeConfiguration()
        let presentationState = AppPresentationState(configuration: configuration)

        presentationState.chooseOpenInspector()

        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .expertBypassInProgress)
        XCTAssertEqual(configuration.preferredWorkingView, .inspector)
        XCTAssertFalse(presentationState.shouldShowInspectorSetupCompanion)
        XCTAssertTrue(presentationState.showsFirstRunSetupChip)
        XCTAssertFalse(configuration.hasCompletedInitialGuidedSetupPresentation)
    }

    func testFirstMatchingRequestCompletesInProgressAndExpertBypass() {
        let configuration = makeConfiguration()
        let presentationState = AppPresentationState(configuration: configuration)
        presentationState.chooseStartFirstCapture()
        configuration.sessionStartPresentationRecord.selectedTargetID = MCPSetupReadinessTarget.macOS.rawValue

        presentationState.completeFirstRunIfEligible(sessionSources: [.mac])

        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .completed)
        XCTAssertTrue(configuration.hasCompletedInitialGuidedSetupPresentation)
        XCTAssertFalse(presentationState.showsFirstRunSetupChip)
        XCTAssertFalse(presentationState.shouldShowInspectorSetupCompanion)
    }

    func testUnknownLoopbackTrafficCompletesMacAndSimulatorTargets() {
        XCTAssertTrue(
            FirstRunCompletionPolicy.sessionMatchesSelectedTarget(
                source: .unknown,
                selectedTargetID: MCPSetupReadinessTarget.macOS.rawValue
            )
        )
        XCTAssertTrue(
            FirstRunCompletionPolicy.sessionMatchesSelectedTarget(
                source: .unknown,
                selectedTargetID: MCPSetupReadinessTarget.simulator.rawValue
            )
        )
        XCTAssertFalse(
            FirstRunCompletionPolicy.sessionMatchesSelectedTarget(
                source: .unknown,
                selectedTargetID: MCPSetupReadinessTarget.iOSiPadOS.rawValue
            )
        )
    }

    func testDoesNotCompleteUntilATargetIsSelected() {
        let configuration = makeConfiguration()
        let presentationState = AppPresentationState(configuration: configuration)
        presentationState.chooseStartFirstCapture()

        presentationState.completeFirstRunIfEligible(sessionSources: [.mac, .device, .unknown])

        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .inProgress)
        XCTAssertFalse(configuration.hasCompletedInitialGuidedSetupPresentation)
    }

    func testDeviceTrafficDoesNotCompleteMacTarget() {
        let configuration = makeConfiguration()
        let presentationState = AppPresentationState(configuration: configuration)
        presentationState.chooseOpenInspector()
        configuration.sessionStartPresentationRecord.selectedTargetID = MCPSetupReadinessTarget.macOS.rawValue

        presentationState.completeFirstRunIfEligible(sessionSources: [.device])

        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .expertBypassInProgress)
        XCTAssertFalse(configuration.hasCompletedInitialGuidedSetupPresentation)
    }

    func testPathChoicePresentDoesNotWriteCompletion() {
        let configuration = makeConfiguration()
        let presentationState = AppPresentationState(configuration: configuration)

        presentationState.presentFirstRunPathChoiceIfNeeded()

        XCTAssertTrue(presentationState.isFirstRunPathChoicePresented)
        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .notStarted)
        XCTAssertFalse(configuration.hasCompletedInitialGuidedSetupPresentation)
    }

    func testSavedCaptureRestoreOutranksFirstRunPathChoice() {
        let facts = LaunchInterruptionArbitrator.LaunchFacts(
            hasUnsavedCaptureRestorationOffer: true,
            onboardingLifecycle: .notStarted
        )
        XCTAssertEqual(
            LaunchInterruptionArbitrator.nextInterruption(from: facts),
            .savedCaptureRestoration
        )
    }

    func testInProgressFirstCaptureIsNotALaunchInterruption() {
        let facts = LaunchInterruptionArbitrator.LaunchFacts(
            onboardingLifecycle: .inProgress
        )
        XCTAssertNil(LaunchInterruptionArbitrator.nextInterruption(from: facts))
    }

    func testExpertBypassIsNotALaunchInterruption() {
        let facts = LaunchInterruptionArbitrator.LaunchFacts(
            onboardingLifecycle: .expertBypassInProgress
        )
        XCTAssertNil(LaunchInterruptionArbitrator.nextInterruption(from: facts))
    }

    func testGenericTargetAcceptsAnyObservedRequest() {
        XCTAssertTrue(
            FirstRunCompletionPolicy.sessionMatchesSelectedTarget(
                source: .unknown,
                selectedTargetID: MCPSetupReadinessTarget.generic.rawValue
            )
        )
        XCTAssertEqual(
            FirstRunCompletionPolicy.completedLifecycleIfEligible(
                lifecycle: .inProgress,
                selectedTargetID: MCPSetupReadinessTarget.generic.rawValue,
                sessionSources: [.unknown]
            ),
            .completed
        )
    }

    func testCoordinatorSyncClearsPathChoiceInterruptionAfterStart() {
        let configuration = makeConfiguration()
        let coordinator = SessionStartCoordinator(configuration: configuration)

        XCTAssertEqual(coordinator.workingSurfaceState.activeInterruption, .guidedSetup)

        configuration.onboardingProgressRecord = OnboardingProgressRecord(lifecycle: .inProgress)
        coordinator.syncPersistedOnboardingState()

        XCTAssertNil(coordinator.workingSurfaceState.activeInterruption)
    }

    private func makeConfiguration() -> UserDefaultsAppConfiguration {
        let suiteName = "com.JoesProxyApp.Tests.FirstRunLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return UserDefaultsAppConfiguration(userDefaults: defaults)
    }
}
