//
//  AppPresentationState.swift
//  JoesProxy
//
//  Observable state for app-level presentation (sheets, modals) triggered from menu items
//  or other global actions. Keeps presentation logic separate from domain view models.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Wraps a URL for use with SwiftUI's sheet(item:).
struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

enum TrafficModificationEditor: Equatable {
    case openAPI
    case testStream
}

struct MCPManagementPresentationContext: Identifiable, Equatable, Sendable {
    let id = UUID()
    let destination: MCPPipelineStatus.ManagementDestination

    static func == (lhs: MCPManagementPresentationContext, rhs: MCPManagementPresentationContext) -> Bool {
        lhs.destination == rhs.destination
    }
}

struct ReproPackagePresentationContext: Identifiable, Equatable, Sendable {
    let id = UUID()
    let package: ReproPackage
    let allowsSaving: Bool

    static func == (lhs: ReproPackagePresentationContext, rhs: ReproPackagePresentationContext) -> Bool {
        lhs.package == rhs.package && lhs.allowsSaving == rhs.allowsSaving
    }
}

enum GuidedSetupSection: String, CaseIterable, Identifiable, Sendable {
    case welcome
    case startCapturing
    case httpsAndTrust
    case exploreTraffic
    case needHelp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .startCapturing:
            return "Start Capturing"
        case .httpsAndTrust:
            return "HTTPS & Trust"
        case .exploreTraffic:
            return "Explore Traffic"
        case .needHelp:
            return "Need Help"
        }
    }

    var compactTitle: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .startCapturing:
            return "Capture"
        case .httpsAndTrust:
            return "Trust"
        case .exploreTraffic:
            return "Explore"
        case .needHelp:
            return "Help"
        }
    }
}

enum GuidedSetupBlockingState: String, Equatable, Sendable {
    case notSetUp
    case installedTrustRequired
    case needsCleanup

    var title: String {
        switch self {
        case .notSetUp:
            return "HTTPS setup is not finished"
        case .installedTrustRequired:
            return "The certificate is installed, but trust is still required"
        case .needsCleanup:
            return "The certificate state needs cleanup before HTTPS inspection can continue"
        }
    }

    var message: String {
        switch self {
        case .notSetUp:
            return "JoesProxy can capture basic proxy traffic, but HTTPS inspection will stay unavailable until the Root CA is created and trusted."
        case .installedTrustRequired:
            return "The Root CA exists, but the current device or Mac has not completed the trust step needed for HTTPS inspection."
        case .needsCleanup:
            return "The current certificate or trust state is no longer usable. Clean it up, then run setup again to restore HTTPS inspection."
        }
    }
}

enum GuidedSetupEntryMode: Equatable, Sendable {
    case firstRun
    case replay
    case repair(GuidedSetupBlockingState)
}

struct GuidedSetupContext: Identifiable, Sendable {
    let id = UUID()
    let section: GuidedSetupSection
    let mode: GuidedSetupEntryMode
}

extension GuidedSetupContext: Equatable {
    static func == (lhs: GuidedSetupContext, rhs: GuidedSetupContext) -> Bool {
        lhs.section == rhs.section && lhs.mode == rhs.mode
    }
}

/// Holds presentation state for app-level sheets and modals.
///
/// Used to show views like the iOS setup walkthrough from menu commands.
/// Injected as `environmentObject` so both `ContentView` and `.commands` can access it.
@MainActor
final class AppPresentationState: ObservableObject {
    private let logger = Logger(subsystem: "com.JoesProxyApp.UI", category: "Presentation")
    @Published var isAboutPresented = false
    @Published private(set) var utilityWindowRequest: UtilityWindowRequest?
    private var utilityWindowOpener: ((UtilityWindowKind) -> Void)?

    func installUtilityWindowOpener(_ opener: @escaping (UtilityWindowKind) -> Void) {
        utilityWindowOpener = opener
        if let request = utilityWindowRequest {
            utilityWindowRequest = nil
            opener(request.kind)
        }
    }

    private func requestUtilityWindow(_ kind: UtilityWindowKind) {
        if let utilityWindowOpener {
            utilityWindowOpener(kind)
        } else {
            utilityWindowRequest = UtilityWindowRequest(kind: kind)
        }
    }
    @Published var isClearCaptureBusyPresented = false
    @Published var trafficModificationEditor: TrafficModificationEditor?
    @Published var isTrafficModificationWindowOpen = false
    /// App-owned so closing or reopening Traffic Modifications, or switching Compact/Inspector,
    /// never discards in-progress Append JSON + Image authoring. Retired only by an explicit
    /// discard or a successful save.
    @Published private(set) var capturedMockAuthoringDraft = CapturedMockAuthoringDraft()
    @Published var mockIconPicker: MockIconPickerRequest?
    @Published var similarItemTextReview: SimilarItemTextRequest?

    /// Replaces the draft with an empty one, releasing its copy of the selected capture. Refused
    /// while preparation, preview, discovery or saving is running so that work cannot publish into
    /// a draft the user already discarded.
    @discardableResult
    func discardCapturedMockAuthoringDraft() async -> Bool {
        let draft = capturedMockAuthoringDraft
        guard !draft.busy, !draft.discoveringCollections else { return false }
        guard await draft.editPreparedRevision(), capturedMockAuthoringDraft === draft else { return false }
        mockIconPicker = nil
        similarItemTextReview = nil
        capturedMockAuthoringDraft = CapturedMockAuthoringDraft()
        return true
    }
    @Published var isHelpHubPresented = false
    @Published var helpHubTopic: MainWindowHelpTopic?
    @Published var contextualHelpTopic: MainWindowHelpTopic = .capturedSessions
    @Published var isHTTPSRulesRequested = false
    @Published var isCertificateSetupPresented = false
    @Published var isIOSSetupWalkthroughPresented = false
    @Published var isMacOSSetupWalkthroughPresented = false
    @Published var isTVOSSetupWalkthroughPresented = false
    @Published var isSimulatorSetupWalkthroughPresented = false
    @Published var isDeviceAliasManagerPresented = false
    @Published var isBodyFindPresented = false
    @Published var mcpManagementContext: MCPManagementPresentationContext?
    /// Compact / menu-bar pending-approval sheet (AO Axis 1) — thin over `MCPApprovalStore`.
    @Published var isCompactApprovalsPresented = false
    @Published var guidedSetupContext: GuidedSetupContext?
    /// BA-3 path-choice sheet. Not a Guided Setup wizard and not first-run completion.
    @Published var isFirstRunPathChoicePresented = false
    /// Session-only hide for the Inspector companion; lifecycle still drives the Setup chip.
    @Published var isInspectorSetupCompanionDismissed = false
    /// Expert bypass keeps the companion hidden until the Setup chip reveals it.
    @Published var isInspectorSetupCompanionRevealed = false
    /// Mirror of durable first-run lifecycle so SwiftUI can observe choice and completion.
    @Published private(set) var onboardingLifecycle: OnboardingLifecycle
    @Published var jsonViewerFileURL: IdentifiableURL?
    @Published var mediaInfoSessionID: SessionRecord.ID?
    @Published var visualizationExportContext: VisualizationExportPresentationContext?
    @Published var reproPackageContext: ReproPackagePresentationContext?
    /// UI-test-only override: when set, `ContentView` builds a `VisualizationExportPNGExportCoordinator`
    /// that writes directly to this URL instead of presenting a real `NSSavePanel`.
    @Published var visualizationExportPNGDestinationOverride: URL?
    /// Set when a `.jproxy` file is opened externally (Finder, dock drag, or `NSOpenPanel`) while
    /// sessions are already present. `ContentView` observes this to present the replace-or-merge sheet.
    @Published var pendingRecordingURL: IdentifiableURL?

    /// Do not discard an unfinished sheet or editor during Inspector teardown.
    var blocksAgentTransition: Bool {
        isTrafficModificationWindowOpen || trafficModificationEditor != nil || visualizationExportContext != nil ||
        reproPackageContext != nil || pendingRecordingURL != nil || guidedSetupContext != nil ||
        isCertificateSetupPresented || isIOSSetupWalkthroughPresented || isMacOSSetupWalkthroughPresented ||
        isTVOSSetupWalkthroughPresented || isSimulatorSetupWalkthroughPresented ||
        isDeviceAliasManagerPresented || isFirstRunPathChoicePresented
    }

    func finishInspectorPresentation() {
        isBodyFindPresented = false
        isHelpHubPresented = false
        mediaInfoSessionID = nil
    }

    private let configuration: AppConfiguration

    init(configuration: AppConfiguration = UserDefaultsAppConfiguration()) {
        self.configuration = configuration
        self.onboardingLifecycle = configuration.onboardingProgressRecord.lifecycle
    }

    func presentAbout() {
        log("Presenting About window")
        isAboutPresented = true
        requestUtilityWindow(.about)
    }

    func presentHelpHub(topic: MainWindowHelpTopic? = nil) {
        helpHubTopic = topic
        log("Presenting help hub")
        isHelpHubPresented = true
    }

    func presentContextualHelp(topic: MainWindowHelpTopic) {
        contextualHelpTopic = topic
        log("Presenting contextual help for \(topic.rawValue)")
    }

    func presentHTTPSRules() {
        log("Requesting HTTPS Rules presentation")
        isHTTPSRulesRequested = true
    }

    func presentCertificateSetup() {
        log("Presenting certificate setup sheet")
        isCertificateSetupPresented = true
    }

    func presentIOSSetupWalkthrough() {
        log("Presenting iOS setup walkthrough")
        isIOSSetupWalkthroughPresented = true
    }

    func presentMacOSSetupWalkthrough() {
        log("Presenting macOS setup walkthrough")
        isMacOSSetupWalkthroughPresented = true
    }

    func presentTVOSSetupWalkthrough() {
        log("Presenting tvOS setup walkthrough")
        isTVOSSetupWalkthroughPresented = true
    }

    func presentSimulatorSetupWalkthrough() {
        log("Presenting simulator setup walkthrough")
        isSimulatorSetupWalkthroughPresented = true
    }

    func presentBodyFind() {
        log("Presenting body find panel")
        isBodyFindPresented = true
    }

    func presentMCPManagement(
        destination: MCPPipelineStatus.ManagementDestination? = nil
    ) {
        if let destination {
            mcpManagementContext = MCPManagementPresentationContext(destination: destination)
        } else if mcpManagementContext == nil {
            mcpManagementContext = MCPManagementPresentationContext(destination: .overview)
        }
        requestUtilityWindow(.mcpManagement)
    }

    /// Opens the lightweight pending-approval sheet from menu bar / compact surfaces (AO Axis 1).
    func presentCompactApprovals() {
        log("Presenting compact MCP approvals sheet")
        isCompactApprovalsPresented = true
        requestUtilityWindow(.approvals)
    }

    func presentGuidedSetup(
        section: GuidedSetupSection = .welcome,
        mode: GuidedSetupEntryMode = .replay
    ) {
        log("Presenting guided setup in mode \(String(describing: mode)) at section \(section.rawValue)")
        guidedSetupContext = GuidedSetupContext(section: section, mode: mode)
    }

    /// Presents BA-3 path choice when first run has not started and no legacy completion alias exists.
    ///
    /// Presentation itself does not write ``hasCompletedInitialGuidedSetupPresentation`` or
    /// ``OnboardingLifecycle/completed``.
    func presentInitialGuidedSetupIfNeeded() {
        presentFirstRunPathChoiceIfNeeded()
    }

    /// Shows the non-wizard path-choice sheet for a fresh install.
    func presentFirstRunPathChoiceIfNeeded() {
        guard configuration.onboardingProgressRecord.lifecycle == .notStarted else {
            return
        }
        guard !configuration.hasCompletedInitialGuidedSetupPresentation else {
            return
        }
        isFirstRunPathChoicePresented = true
    }

    /// Start First Capture: Inspector plus companion, lifecycle in progress.
    func chooseStartFirstCapture() {
        configuration.preferredWorkingView = .inspector
        persistOnboardingLifecycle(.inProgress)
        isInspectorSetupCompanionDismissed = false
        isInspectorSetupCompanionRevealed = true
        isFirstRunPathChoicePresented = false
    }

    /// Connect an Agent: Compact preference plus in-progress lifecycle. Compact enrollment UI is BA-4.
    func chooseConnectAnAgent() {
        configuration.preferredWorkingView = .compact
        persistOnboardingLifecycle(.inProgress)
        isInspectorSetupCompanionDismissed = true
        isInspectorSetupCompanionRevealed = false
        isFirstRunPathChoicePresented = false
    }

    /// Open Inspector: expert bypass. Does not mark setup complete.
    func chooseOpenInspector() {
        configuration.preferredWorkingView = .inspector
        persistOnboardingLifecycle(.expertBypassInProgress)
        isInspectorSetupCompanionDismissed = false
        isInspectorSetupCompanionRevealed = false
        isFirstRunPathChoicePresented = false
    }

    /// Completes first run only when selected-target capture evidence exists.
    func completeFirstRunIfEligible(sessionSources: [TrafficSource]) {
        let selectedTargetID = configuration.sessionStartPresentationRecord.selectedTargetID
        guard let completed = FirstRunCompletionPolicy.completedLifecycleIfEligible(
            lifecycle: onboardingLifecycle,
            selectedTargetID: selectedTargetID,
            sessionSources: sessionSources
        ) else {
            return
        }
        persistOnboardingLifecycle(completed)
        configuration.hasCompletedInitialGuidedSetupPresentation = true
        isInspectorSetupCompanionDismissed = true
        isInspectorSetupCompanionRevealed = false
        isFirstRunPathChoicePresented = false
    }

    /// Quiet Setup chip while first capture or expert bypass is still in progress.
    var showsFirstRunSetupChip: Bool {
        FirstRunCompletionPolicy.isAwaitingCaptureEvidence(onboardingLifecycle)
    }

    /// Inspector companion visibility. In-progress shows it by default; expert bypass uses the chip.
    var shouldShowInspectorSetupCompanion: Bool {
        switch onboardingLifecycle {
        case .inProgress:
            return !isInspectorSetupCompanionDismissed
        case .expertBypassInProgress:
            return isInspectorSetupCompanionRevealed && !isInspectorSetupCompanionDismissed
        default:
            return false
        }
    }

    func dismissInspectorSetupCompanion() {
        isInspectorSetupCompanionDismissed = true
    }

    func revealInspectorSetupCompanionFromChip() {
        isInspectorSetupCompanionDismissed = false
        isInspectorSetupCompanionRevealed = true
    }

    func dismissGuidedSetup() {
        guidedSetupContext = nil
    }

    private func persistOnboardingLifecycle(_ lifecycle: OnboardingLifecycle) {
        configuration.onboardingProgressRecord = OnboardingProgressRecord(lifecycle: lifecycle)
        onboardingLifecycle = lifecycle
    }

    func presentGuidedRepair(for blockingState: GuidedSetupBlockingState) {
        presentGuidedSetup(section: .httpsAndTrust, mode: .repair(blockingState))
    }

    func transitionFromHelpHub(to destination: HelpDestination) {
        isHelpHubPresented = false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch destination {
            case .certificateSetup:
                self.presentCertificateSetup()
            case .iOSSetup:
                self.presentIOSSetupWalkthrough()
            case .macOSSetup:
                self.presentMacOSSetupWalkthrough()
            case .tvOSSetup:
                self.presentTVOSSetupWalkthrough()
            case .simulatorSetup:
                self.presentSimulatorSetupWalkthrough()
            }
        }
    }

    func transitionFromGuidedSetup(to destination: HelpDestination) {
        guidedSetupContext = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch destination {
            case .certificateSetup:
                self.presentCertificateSetup()
            case .iOSSetup:
                self.presentIOSSetupWalkthrough()
            case .macOSSetup:
                self.presentMacOSSetupWalkthrough()
            case .tvOSSetup:
                self.presentTVOSSetupWalkthrough()
            case .simulatorSetup:
                self.presentSimulatorSetupWalkthrough()
            }
        }
    }

    func presentJSONViewer(fileURL: URL) {
        log("Presenting JSON viewer for \(fileURL.lastPathComponent)")
        jsonViewerFileURL = IdentifiableURL(url: fileURL)
    }

    func presentMediaInfo(sessionID: SessionRecord.ID) {
        mediaInfoSessionID = sessionID
        log("Presenting media info for session \(sessionID.uuidString)")
    }

    func presentVisualizationExport(context: VisualizationExportPresentationContext) {
        visualizationExportContext = context
        log("Presenting visualization export for \(context.sourceSummary)")
    }

    /// Presents the system Open panel for JSON files. If the user selects a file, presents the JSON viewer.
    func openJSONFileFromPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Open JSON File"

        if panel.runModal() == .OK, let url = panel.url {
            presentJSONViewer(fileURL: url)
        }
    }

    private func log(_ message: String) {
        guard RuntimeDebugFlag.isUILifecycleLoggingEnabled else {
            return
        }
        logger.info("UI lifecycle: \(message, privacy: .public)")
    }
}

enum HelpDestination {
    case certificateSetup
    case iOSSetup
    case macOSSetup
    case tvOSSetup
    case simulatorSetup
}
