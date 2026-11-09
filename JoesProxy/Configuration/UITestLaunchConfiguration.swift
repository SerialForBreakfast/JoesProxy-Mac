import Foundation

struct UITestLaunchConfiguration {
    enum Fixture: String {
        case demoSessions = "demo-sessions"
        case epgRewriteClient = "epg-rewrite-client"
        case authoredEvidence = "authored-evidence"
        case transportAssets = "transport-assets"
        case streamingAssets = "streaming-assets"
        case mockJourney = "mock-journey"
        case captionEvidence = "caption-evidence"
        case captionPlayer = "caption-player"
        case guidedMockAuthoring = "guided-mock-authoring"
    }

    enum CertificateState: String {
        case notSetUp
        case installedTrustRequired
        case needsCleanup
        case ready
    }

    enum GuidedSetupMode: String {
        case firstRun = "first-run"
        case replay
        case repair
    }

    enum VerificationState: String {
        case inspected
        case tunneled
        case noTrafficObserved
        case proxyStopped
    }

    enum MCPStatusFixture: String {
        case runningClean = "running-clean"
        case offActive = "off-active"
        case approvals
        case conflict
    }

    /// In-memory rolling-capture restore fixture. `offered` injects a restore sheet without snapshot I/O.
    enum RollingRestoreFixture: String {
        case offered
    }

    let fixture: Fixture?
    let browserMode: SessionBrowserMode?
    let textSize: AppTextSize?
    let sessionCount: Int?
    let proxyPort: UInt16?
    let certificateState: CertificateState?
    let verificationState: VerificationState?
    let guidedSetupSection: GuidedSetupSection?
    let guidedSetupMode: GuidedSetupMode?
    let guidedSetupBlockingState: GuidedSetupBlockingState?
    let opensCertificateSetup: Bool
    let opensSimulatorSetup: Bool
    let opensIOSSetup: Bool
    let exportDestinationPath: String?
    let mcpStatusFixture: MCPStatusFixture?
    let rollingRestore: RollingRestoreFixture?
    var uploadStorageFailure = false

    static var current: UITestLaunchConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments

        var fixture: Fixture?
        var browserMode: SessionBrowserMode?
        var textSize: AppTextSize?
        var sessionCount: Int?
        var proxyPort: UInt16?
        var certificateState: CertificateState?
        var verificationState: VerificationState?
        var guidedSetupSection: GuidedSetupSection?
        var guidedSetupMode: GuidedSetupMode?
        var guidedSetupBlockingState: GuidedSetupBlockingState?
        var opensCertificateSetup = false
        var opensSimulatorSetup = false
        var opensIOSSetup = false
        var exportDestinationPath: String?
        var mcpStatusFixture: MCPStatusFixture?
        var rollingRestore: RollingRestoreFixture?
        var foundAnyUITestArgument = false
        var uploadStorageFailure = false

        for argument in arguments {
            if argument == "--ui-test-upload-storage-failure" {
                foundAnyUITestArgument = true
                uploadStorageFailure = true
            } else if argument.hasPrefix(LaunchArgument.uiTestFixturePrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestFixturePrefix.count))
                fixture = Fixture(rawValue: rawValue)
            } else if argument.hasPrefix(LaunchArgument.uiTestBrowserModePrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestBrowserModePrefix.count))
                browserMode = SessionBrowserMode(rawValue: rawValue)
            } else if argument.hasPrefix(LaunchArgument.uiTestTextSizePrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestTextSizePrefix.count))
                textSize = AppTextSize(rawValue: rawValue)
            } else if argument.hasPrefix(LaunchArgument.uiTestSessionCountPrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestSessionCountPrefix.count))
                if let parsedCount = Int(rawValue), parsedCount > 0 {
                    sessionCount = parsedCount
                }
            } else if argument.hasPrefix(LaunchArgument.uiTestProxyPortPrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestProxyPortPrefix.count))
                if let parsedPort = UInt16(rawValue), parsedPort > 0 {
                    proxyPort = parsedPort
                }
            } else if argument.hasPrefix(LaunchArgument.uiTestCertificateStatePrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestCertificateStatePrefix.count))
                certificateState = CertificateState(rawValue: rawValue)
            } else if argument.hasPrefix(LaunchArgument.uiTestVerificationStatePrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestVerificationStatePrefix.count))
                verificationState = VerificationState(rawValue: rawValue)
            } else if argument.hasPrefix(LaunchArgument.uiTestGuidedSetupSectionPrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestGuidedSetupSectionPrefix.count))
                guidedSetupSection = GuidedSetupSection(rawValue: rawValue)
            } else if argument.hasPrefix(LaunchArgument.uiTestGuidedSetupModePrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestGuidedSetupModePrefix.count))
                guidedSetupMode = GuidedSetupMode(rawValue: rawValue)
            } else if argument.hasPrefix(LaunchArgument.uiTestGuidedSetupBlockingStatePrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestGuidedSetupBlockingStatePrefix.count))
                guidedSetupBlockingState = GuidedSetupBlockingState(rawValue: rawValue)
            } else if argument == LaunchArgument.uiTestOpenCertificateSetup {
                foundAnyUITestArgument = true
                opensCertificateSetup = true
            } else if argument == LaunchArgument.uiTestOpenSimulatorSetup {
                foundAnyUITestArgument = true
                opensSimulatorSetup = true
            } else if argument == LaunchArgument.uiTestOpenIOSSetup {
                foundAnyUITestArgument = true
                opensIOSSetup = true
            } else if argument.hasPrefix(LaunchArgument.uiTestExportDestinationPathPrefix) {
                foundAnyUITestArgument = true
                exportDestinationPath = String(argument.dropFirst(LaunchArgument.uiTestExportDestinationPathPrefix.count))
            } else if argument.hasPrefix(LaunchArgument.uiTestMCPStatusPrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestMCPStatusPrefix.count))
                mcpStatusFixture = MCPStatusFixture(rawValue: rawValue)
            } else if argument.hasPrefix(LaunchArgument.uiTestRollingRestorePrefix) {
                foundAnyUITestArgument = true
                let rawValue = String(argument.dropFirst(LaunchArgument.uiTestRollingRestorePrefix.count))
                rollingRestore = RollingRestoreFixture(rawValue: rawValue)
            }
        }

        guard foundAnyUITestArgument else {
            return nil
        }

        return UITestLaunchConfiguration(
            fixture: fixture,
            browserMode: browserMode,
            textSize: textSize,
            sessionCount: sessionCount,
            proxyPort: proxyPort,
            certificateState: certificateState,
            verificationState: verificationState,
            guidedSetupSection: guidedSetupSection,
            guidedSetupMode: guidedSetupMode,
            guidedSetupBlockingState: guidedSetupBlockingState,
            opensCertificateSetup: opensCertificateSetup,
            opensSimulatorSetup: opensSimulatorSetup,
            opensIOSSetup: opensIOSSetup,
            exportDestinationPath: exportDestinationPath,
            mcpStatusFixture: mcpStatusFixture,
            rollingRestore: rollingRestore,
            uploadStorageFailure: uploadStorageFailure
        )
    }
}
