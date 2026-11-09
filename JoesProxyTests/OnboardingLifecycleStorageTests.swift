import AppKit
import XCTest
@testable import JoesProxy

@MainActor
final class OnboardingLifecycleStorageTests: XCTestCase {
    func testInvalidLaunchWorkspacePreservesLegacyCompactPreference() {
        let defaults = makeDefaults()
        defaults.set("future-workspace", forKey: "launchWorkspacePreferenceRawValue")
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.preferredWorkingView = .compact
        XCTAssertEqual(configuration.launchWorkspacePreference, .inspector)
        XCTAssertEqual(configuration.preferredWorkingView, .compact)
        XCTAssertEqual(defaults.string(forKey: "launchWorkspacePreferenceRawValue"), "future-workspace")
    }

    func testFreshConfigurationStartsOnboardingInInspector() {
        let configuration = makeConfiguration()

        XCTAssertEqual(
            configuration.onboardingProgressRecord,
            OnboardingProgressRecord(lifecycle: .notStarted)
        )
        XCTAssertEqual(configuration.preferredWorkingView, .inspector)
    }

    func testLegacyPresentedBooleanMigratesWithoutReopeningFirstRun() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hasCompletedInitialGuidedSetupPresentation")

        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        let reloaded = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .legacyDismissed)
        XCTAssertEqual(reloaded.onboardingProgressRecord.lifecycle, .legacyDismissed)
        XCTAssertEqual(
            reloaded.onboardingProgressRecord.schemaVersion,
            OnboardingProgressRecord.currentSchemaVersion
        )
    }

    func testLegacyUnpresentedBooleanMigratesToNotStarted() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "hasCompletedInitialGuidedSetupPresentation")

        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .notStarted)
    }

    func testLifecycleAndWorkingViewPersistAcrossConfigurationReload() {
        let defaults = makeDefaults()
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.onboardingProgressRecord = OnboardingProgressRecord(
            lifecycle: .expertBypassInProgress
        )
        configuration.preferredWorkingView = .compact

        let reloaded = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertEqual(reloaded.onboardingProgressRecord.lifecycle, .expertBypassInProgress)
        XCTAssertEqual(reloaded.preferredWorkingView, .compact)
    }

    func testWorkspacePreferenceDefaultsToInspectorAndDoesNotRewriteCompactPreference() {
        let defaults = makeDefaults()
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.preferredWorkingView = .compact

        XCTAssertEqual(configuration.launchWorkspacePreference, .inspector)

        configuration.launchWorkspacePreference = .agent
        let reloaded = UserDefaultsAppConfiguration(userDefaults: defaults)
        XCTAssertEqual(reloaded.launchWorkspacePreference, .agent)
        XCTAssertEqual(reloaded.preferredWorkingView, .compact)
    }

    func testLegacyPresentationWritePreservesNonReappearanceDuringTransition() {
        let configuration = makeConfiguration()

        configuration.hasCompletedInitialGuidedSetupPresentation = true

        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .legacyDismissed)
    }

    func testUnsupportedLifecycleSchemaFailsSafeToLegacyStateWithoutOverwritingIt() throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hasCompletedInitialGuidedSetupPresentation")
        let futureRecord = OnboardingProgressRecord(schemaVersion: 99, lifecycle: .completed)
        let futureData = try JSONEncoder().encode(futureRecord)
        defaults.set(futureData, forKey: "onboardingProgressData")

        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .legacyDismissed)
        XCTAssertEqual(defaults.data(forKey: "onboardingProgressData"), futureData)
    }

    func testResetClearsLifecycleAndRestoresInspectorPreference() {
        let configuration = makeConfiguration()
        configuration.hasCompletedInitialGuidedSetupPresentation = true
        configuration.onboardingProgressRecord = OnboardingProgressRecord(lifecycle: .completed)
        configuration.preferredWorkingView = .compact

        configuration.resetToDefaults()

        XCTAssertFalse(configuration.hasCompletedInitialGuidedSetupPresentation)
        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .notStarted)
        XCTAssertEqual(configuration.preferredWorkingView, .inspector)
    }

    func testCompactControllerRestoresAndPersistsExplicitWorkingViewSwitches() {
        let configuration = makeConfiguration()
        configuration.preferredWorkingView = .compact
        var presentationStates: [Bool] = []
        let controller = CompactModeController(
            monitoringViewModel: makeMonitoringViewModel(),
            configuration: configuration,
            onInspectorPresentationChanged: { presentationStates.append($0) }
        )

        XCTAssertTrue(controller.isCompactModeActive)
        XCTAssertEqual(presentationStates, [false])

        controller.toggle()

        XCTAssertFalse(controller.isCompactModeActive)
        XCTAssertEqual(configuration.preferredWorkingView, .inspector)

        controller.toggle()

        XCTAssertTrue(controller.isCompactModeActive)
        XCTAssertEqual(configuration.preferredWorkingView, .compact)
        XCTAssertEqual(presentationStates, [false, true, false])
    }

    func testTemporaryFullViewPresentationDoesNotRewriteCompactPreference() {
        let configuration = makeConfiguration()
        configuration.preferredWorkingView = .compact
        let controller = CompactModeController(
            monitoringViewModel: makeMonitoringViewModel(),
            configuration: configuration
        )

        controller.performRequiringFullView {}

        XCTAssertFalse(controller.isCompactModeActive)
        XCTAssertEqual(configuration.preferredWorkingView, .compact)
    }

    func testCompactColdLaunchWinsOverLargeInitialWindowAndRestoresWorkspace() {
        let configuration = makeConfiguration()
        configuration.preferredWorkingView = .compact
        let controller = CompactModeController(
            monitoringViewModel: makeMonitoringViewModel(), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let configurator = MainWindowConfigurator(compactModeController: controller, isTestLaunch: true)
        let coordinator = configurator.makeCoordinator()
        configurator.configureWindow(window, coordinator: coordinator)
        XCTAssertLessThan(window.frame.width, 500)
        XCTAssertEqual(window.minSize, window.maxSize)
        let compactFrame = window.frame
        configurator.configureWindow(window, coordinator: coordinator)
        XCTAssertEqual(window.frame, compactFrame, "Later updates must not reapply the workspace frame")
        controller.performRequiringFullView {}
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).width, 1440, accuracy: 1)
        XCTAssertEqual(configuration.preferredWorkingView, .compact)
    }

    func testInspectorColdLaunchIsNotClampedToCompactSize() {
        let controller = CompactModeController(
            monitoringViewModel: makeMonitoringViewModel(), configuration: makeConfiguration())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let configurator = MainWindowConfigurator(compactModeController: controller, isTestLaunch: true)
        configurator.configureWindow(window, coordinator: configurator.makeCoordinator())
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).width, 1440, accuracy: 1)
        XCTAssertNotEqual(window.minSize, window.maxSize)
    }

    private func makeConfiguration() -> UserDefaultsAppConfiguration {
        UserDefaultsAppConfiguration(userDefaults: makeDefaults())
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.JoesProxyApp.Tests.OnboardingLifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeMonitoringViewModel() -> MinimalMonitoringViewModel {
        MinimalMonitoringViewModel(
            captureHealthProvider: { .empty },
            transportSnapshotProvider: { .empty },
            proxyStatusProvider: { ("Stopped", .safe) },
            refreshInterval: 999
        )
    }
}
