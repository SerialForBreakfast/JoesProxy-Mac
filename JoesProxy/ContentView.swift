//
//  ContentView.swift
//  JoesProxy
//
//  Created by Joseph McCraw on 11/5/24.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

struct ContentView: View {
    private static let sessionTableColumnConfigKey = "sessionTableColumnConfig"

    private enum Layout {
        static let sessionTableMinWidth = WorkspaceLayoutMetrics.browserMinimumWidth
        static let inspectorMinWidth = WorkspaceLayoutMetrics.inspectorMinimumWidth
    }

    // SwiftUI: string literals in `Text("…\(n)")` use `LocalizedStringKey` and may group digits (e.g. port 9090 → 9,090). Use `Text(verbatim:)` for ports and similar.

    private typealias PrimaryPaneMode = ProxyViewModel.PrimaryPaneMode

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var presentationState: AppPresentationState
    @ObservedObject var viewModel: ProxyViewModel
    @ObservedObject var simulatorSetupViewModel: SimulatorSetupViewModel
    @ObservedObject var routingModel: SystemProxyRoutingModel
    @State private var isRoutingPopoverPresented = false
    @State private var isHelpDocumentationReady = false
    @ObservedObject var systemProxyController: SystemProxyController
    @ObservedObject var mcpServerController: MCPServerController
    @ObservedObject var selfValidationCoordinator: MCPSelfValidationCoordinator
    @ObservedObject var sessionStartCoordinator: SessionStartCoordinator
    @ObservedObject var compactModeController: CompactModeController
    var uploadSpoolService: UploadSpoolService?
    @State private var exportAlert: ExportAlertContext?
    @State private var isHTTPSRulesPresented = false
    @State private var isSessionIconLegendPresented = false
    private var primaryPaneMode: PrimaryPaneMode {
        get { viewModel.primaryPaneMode }
        nonmutating set { viewModel.primaryPaneMode = newValue }
    }
    private var selectedExplorerNodeID: String? {
        get { viewModel.selectedExplorerNodeID }
        nonmutating set { viewModel.selectedExplorerNodeID = newValue }
    }
    @FocusState private var isExplorerFocused: Bool
    @State private var bookmarkMergeSheetContext: BookmarkMergeSheetContext?
    @State private var mapLocalSheetContext: MapLocalSheetContext?
    @State private var hlsTestStreamSheetContext: HLSTestStreamSheetContext?
    @State private var openAPIMockPackSheetContext: OpenAPIMockPackSheetContext?
    @State private var isSuppressingInspectorSplitCapture = false
    @State private var restoreInspectorSplitTask: Task<Void, Never>?
    @State private var explorerSelectionSyncTask: Task<Void, Never>?
    @State private var explorerSelectionChangeTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.JoesProxyApp.UI", category: "ContentView")
    private var textScale: CGFloat { viewModel.appTextSize.fontScale }
    private var hasInspectorEditorPresented: Bool {
        bookmarkMergeSheetContext != nil || mapLocalSheetContext != nil ||
        hlsTestStreamSheetContext != nil || openAPIMockPackSheetContext != nil || isHTTPSRulesPresented
    }

    @State private var columnCustomization: TableColumnCustomization<SessionTableRowPresentation>
    @State private var columnConfigPersistenceTask: Task<Void, Never>?
    @State private var sessionTablePaneWidth: CGFloat = 800
    @State private var workspaceLayout = WorkspaceLayoutState()
    @State private var browserPaneLayoutMode: PaneLayoutMode = .roomy
    @State private var inspectorPaneLayoutMode: PaneLayoutMode = .roomy
    @State private var isSetupSummaryPresented = false
    @State private var isWorkspaceRecoveryPresented = false
    private var workspacePaneFocus: WorkspacePaneFocus {
        get { viewModel.workspacePaneFocus }
        nonmutating set { viewModel.workspacePaneFocus = newValue }
    }
    @State private var recoveryInspectionID: UUID?
    @State private var isSessionFilterPopoverPresented = false
    @StateObject private var workspaceNotices = WorkspaceNoticeCoordinator()

    init(
        viewModel: ProxyViewModel,
        simulatorSetupViewModel: SimulatorSetupViewModel,
        routingModel: SystemProxyRoutingModel,
        systemProxyController: SystemProxyController,
        mcpServerController: MCPServerController,
        selfValidationCoordinator: MCPSelfValidationCoordinator,
        sessionStartCoordinator: SessionStartCoordinator,
        compactModeController: CompactModeController,
        uploadSpoolService: UploadSpoolService? = nil
    ) {
        self.viewModel = viewModel
        self.simulatorSetupViewModel = simulatorSetupViewModel
        self.routingModel = routingModel
        self.systemProxyController = systemProxyController
        self.mcpServerController = mcpServerController
        self.selfValidationCoordinator = selfValidationCoordinator
        self.sessionStartCoordinator = sessionStartCoordinator
        self.compactModeController = compactModeController
        self.uploadSpoolService = uploadSpoolService

        let storedJSON = UserDefaults.standard.string(forKey: Self.sessionTableColumnConfigKey) ?? ""
        _columnCustomization = State(initialValue: Self.decodeColumnCustomization(storedJSON))
    }

    // Value type is phantom: the persisted JSON keys on customizationID strings, so
    // saved column layouts survive switching to identity-only rows.
    private var columnCustomizationBinding: Binding<TableColumnCustomization<SessionTableRowPresentation>> {
        Binding {
            columnCustomization
        } set: { newValue in
            columnCustomization = newValue
            scheduleColumnCustomizationPersistence(newValue)
        }
    }

    private static func decodeColumnCustomization(
        _ json: String
    ) -> TableColumnCustomization<SessionTableRowPresentation> {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let customization = try? JSONDecoder().decode(
                TableColumnCustomization<SessionTableRowPresentation>.self,
                from: data
              ) else {
            return TableColumnCustomization()
        }
        return customization
    }

    private func scheduleColumnCustomizationPersistence(
        _ customization: TableColumnCustomization<SessionTableRowPresentation>
    ) {
        columnConfigPersistenceTask?.cancel()
        columnConfigPersistenceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            persistColumnCustomization(customization)
        }
    }

    private func persistColumnCustomization(
        _ customization: TableColumnCustomization<SessionTableRowPresentation>
    ) {
        guard let data = try? JSONEncoder().encode(customization),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: Self.sessionTableColumnConfigKey)
    }

    private var selectedSessionBinding: Binding<SessionRecord.ID?> {
        Binding {
            viewModel.selectedSessionID
        } set: { id in
            viewModel.selectSessionFromUser(id)
            guard workspaceWindowTier == .focused else { return }
            workspacePaneFocus = WorkspacePaneFocus.afterExplicitDetailEntry(
                current: workspacePaneFocus,
                hasValidDetailDestination: id != nil
            )
        }
    }

    private var selectedBookmarkBinding: Binding<Bookmark.ID?> {
        Binding {
            viewModel.selectedBookmarkID
        } set: { id in
            viewModel.selectedBookmarkID = id
            guard workspaceWindowTier == .focused else { return }
            workspacePaneFocus = WorkspacePaneFocus.afterExplicitDetailEntry(
                current: workspacePaneFocus,
                hasValidDetailDestination: id != nil
            )
        }
    }

    var body: some View {
        presentationContent
            .task {
                do {
                    try await HelpDocumentation.load()
                    isHelpDocumentationReady = true
                } catch { /* Help presents the catalog recovery action when opened. */ }
            }
            .sheet(isPresented: $presentationState.isHelpHubPresented) {
                HelpHubView(
                    isPresented: $presentationState.isHelpHubPresented,
                    focusedTopic: presentationState.helpHubTopic,
                    certificateSetupTitle: viewModel.certificateSetupEntryPointTitle,
                    openCertificateSetup: {
                        presentationState.transitionFromHelpHub(to: .certificateSetup)
                    },
                    openMacOSGuide: {
                        presentationState.transitionFromHelpHub(to: .macOSSetup)
                    },
                    openIOSGuide: {
                        presentationState.transitionFromHelpHub(to: .iOSSetup)
                    },
                    openTVOSGuide: {
                        presentationState.transitionFromHelpHub(to: .tvOSSetup)
                    }
                )
            }
            .sheet(item: $presentationState.guidedSetupContext) { context in
                GuidedSetupRepairView(
                    isPresented: Binding(
                        get: { presentationState.guidedSetupContext != nil },
                        set: { isPresented in
                            if !isPresented {
                                presentationState.dismissGuidedSetup()
                            }
                        }
                    ),
                    context: context,
                    setupChecklistItems: viewModel.guidedSetupChecklistItems,
                    nextSetupActionItem: viewModel.guidedSetupNextActionItem,
                    certificateSetupTitle: viewModel.certificateSetupEntryPointTitle,
                    openCertificateSetup: {
                        presentationState.transitionFromGuidedSetup(to: .certificateSetup)
                    },
                    openMacOSGuide: {
                        presentationState.transitionFromGuidedSetup(to: .macOSSetup)
                    },
                    openIOSGuide: {
                        presentationState.transitionFromGuidedSetup(to: .iOSSetup)
                    },
                    openTVOSGuide: {
                        presentationState.transitionFromGuidedSetup(to: .tvOSSetup)
                    },
                    exportSkill: {
                        let panel = NSSavePanel()
                        panel.canCreateDirectories = true
                        panel.nameFieldStringValue = MCPAgentExportService.skillFileName
                        panel.title = "Export MCP Skill"
                        panel.prompt = "Export"
                        panel.message = "Portable diagnostic playbook for AI agents — no credential, endpoint, or captured traffic data. Drop into .claude/skills/, .cursor/skills/, etc."
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        try? MCPAgentExportService.standaloneSkillMarkdown.write(to: url, atomically: true, encoding: .utf8)
                    },
                    openHelpTopic: { topic in
                        presentationState.dismissGuidedSetup()
                        presentationState.presentHelpHub(topic: topic)
                    },
                    openHelpHub: {
                        presentationState.dismissGuidedSetup()
                        presentationState.presentHelpHub()
                    },
                    startProxy: {
                        viewModel.startProxy()
                    },
                    runSetupVerification: {
                        viewModel.runSetupVerification()
                    },
                    retryStatusValidation: {
                        viewModel.refreshCertificateStatus()
                    },
                    resetCertificateState: {
                        viewModel.confirmResetCertificateState()
                    },
                    captureSetupNetworkSnapshot: {
                        viewModel.captureSetupNetworkSnapshot()
                    },
                    profileHostStrategy: $viewModel.profileHostStrategy,
                    manualProfileHost: $viewModel.manualProfileHost,
                    profileHostResolution: viewModel.currentProfileHostResolution,
                    latestProfileSnapshot: viewModel.latestProfileSnapshot,
                    profileSnapshotDiagnosis: viewModel.profileSnapshotDiagnosis,
                    currentCertificateFingerprint: viewModel.currentCertificateFingerprint,
                    currentProxyPort: viewModel.configuration.proxyPort,
                    profileServerURL: viewModel.profileServerURL,
                    exportIOSTrustProfile: { url in
                        try viewModel.exportIOSTrustProfile(to: url)
                    },
                    exportTVOSManagedProfile: { url in
                        try viewModel.exportTVOSManagedProfile(to: url)
                    },
                    copyProfileValue: { value in
                        viewModel.copyProfileMaintenanceValue(value)
                    },
                    certificateIdentity: viewModel.certificateIdentity,
                    certificateIdentityStatus: viewModel.certificateIdentityStatus,
                    adoptLegacyCertificateIdentity: {
                        viewModel.adoptLegacyCertificateIdentity()
                    },
                    updateCertificateIdentityNickname: { nickname in
                        viewModel.updateCertificateIdentityNickname(nickname)
                    },
                    copyCertificateFingerprint: {
                        viewModel.copyCertificateFingerprint()
                    },
                    copyCertificateShortCode: {
                        viewModel.copyCertificateShortCode()
                    }
                )
            }
            .sheet(isPresented: $presentationState.isCertificateSetupPresented, onDismiss: {
                log("Certificate setup sheet dismissed")
                viewModel.refreshCertificateStatus()
            }) {
                CertificateSetupSheet(
                    viewModel: viewModel,
                    isPresented: $presentationState.isCertificateSetupPresented
                )
            }
            .sheet(isPresented: $presentationState.isIOSSetupWalkthroughPresented) {
                iOSSetupWalkthroughView(
                    isPresented: $presentationState.isIOSSetupWalkthroughPresented,
                    viewModel: viewModel
                )
            }
            .sheet(isPresented: $presentationState.isMacOSSetupWalkthroughPresented) {
                macOSSetupWalkthroughView(
                    isPresented: $presentationState.isMacOSSetupWalkthroughPresented,
                    viewModel: viewModel
                )
            }
            .sheet(isPresented: $presentationState.isTVOSSetupWalkthroughPresented) {
                TVOSSetupWalkthroughView(
                    isPresented: $presentationState.isTVOSSetupWalkthroughPresented,
                    viewModel: viewModel
                )
            }
            .sheet(isPresented: $presentationState.isSimulatorSetupWalkthroughPresented) {
                SimulatorSetupWalkthroughView(
                    isPresented: $presentationState.isSimulatorSetupWalkthroughPresented,
                    viewModel: simulatorSetupViewModel,
                    systemProxyController: systemProxyController,
                    isProxyRunning: viewModel.isProxyRunningNow,
                    startProxy: { viewModel.startProxy() }
                )
            }
            .sheet(isPresented: $presentationState.isDeviceAliasManagerPresented) {
                DeviceAliasManagerView(
                    devices: viewModel.discoveredDevices,
                    onSaveAlias: { ip, alias in
                        viewModel.setDeviceAlias(ipAddress: ip, alias: alias)
                    }
                )
            }
            .sheet(isPresented: $isHTTPSRulesPresented) {
                HTTPSRulesSheet(
                    viewModel: viewModel,
                    isPresented: $isHTTPSRulesPresented
                )
            }
            .sheet(isPresented: $presentationState.isBodyFindPresented) {
                SessionFindPanelView(
                    viewModel: viewModel,
                    onSelectResult: { result in
                        primaryPaneMode = .sessions
                        viewModel.selectSessionFindResult(result)
                        workspacePaneFocus = .detail
                    }
                )
            }
            .sheet(item: $presentationState.visualizationExportContext) { context in
                VisualizationExportSheet(
                    context: context,
                    diagnosticInterlockCoordinator: mcpServerController.diagnosticInterlockCoordinator,
                    pngExportCoordinator: presentationState.visualizationExportPNGDestinationOverride.map { destinationURL in
                        VisualizationExportPNGExportCoordinator(destinationSelector: { _, _ in .file(destinationURL) })
                    },
                    onDismiss: {
                        presentationState.visualizationExportContext = nil
                    },
                    onOpenHelpTopic: { topic in
                        openHelpWindow(topic: topic)
                    }
                )
            }
            .overlay(alignment: .top) {
                if let toast = mcpServerController.attentionCoordinator.pendingToast {
                    MCPAttentionToastView(message: toast, textScale: textScale) {
                        mcpServerController.attentionCoordinator.clearToast()
                    }
                    .padding(.top, 8)
                }
            }
    }

    private var presentationContent: some View {
        configuredContent
            .sheet(item: $bookmarkMergeSheetContext) { context in
                BookmarkMergeSheet(
                    bookmark: context.bookmark,
                    sourceSession: context.sourceSession,
                    initialPreset: .authAndCookies,
                    onApply: { preset, customOptions in
                        viewModel.applyBookmarkUpdate(
                            bookmarkID: context.bookmark.id,
                            sourceSessionID: context.sourceSession.id,
                            preset: preset,
                            customOptions: customOptions
                        )
                        primaryPaneMode = .bookmarks
                        bookmarkMergeSheetContext = nil
                    },
                    onCancel: {
                        bookmarkMergeSheetContext = nil
                    }
                )
            }
            .sheet(item: $mapLocalSheetContext) { context in
                MapLocalSheet(
                    session: context.session,
                    existingOverrides: viewModel.responseOverrides,
                    onCreateCapturedResponse: { label, matchMode, matchPath, conflictStrategy, forceNoCache in
                        Task {
                            await viewModel.createCapturedResponseOverride(
                                from: context.session,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                conflictStrategy: conflictStrategy,
                                forceNoCache: forceNoCache
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateInlineOverride: { label, matchMode, matchPath, conflictStrategy, statusCode, contentType, bodyText, forceNoCache in
                        Task {
                            await viewModel.createInlineResponseOverride(
                                from: context.session,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                conflictStrategy: conflictStrategy,
                                statusCode: statusCode,
                                contentType: contentType,
                                bodyText: bodyText,
                                forceNoCache: forceNoCache
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateFileBackedOverride: { label, matchMode, matchPath, conflictStrategy, statusCode, contentType, fileURL, forceNoCache in
                        Task {
                            await viewModel.createFileBackedResponseOverride(
                                from: context.session,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                conflictStrategy: conflictStrategy,
                                statusCode: statusCode,
                                contentType: contentType,
                                fileURL: fileURL,
                                forceNoCache: forceNoCache
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateDirectoryBackedOverride: { label, matchPath, conflictStrategy, directoryURL, forceNoCache in
                        Task {
                            await viewModel.createDirectoryBackedResponseOverride(
                                from: context.session,
                                label: label,
                                matchPath: matchPath,
                                conflictStrategy: conflictStrategy,
                                directoryURL: directoryURL,
                                forceNoCache: forceNoCache
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateBlockRule: { label, matchMode, matchPath, statusCode in
                        Task {
                            await viewModel.createBlockRule(
                                from: context.session,
                                statusCode: statusCode,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateMapRemoteRule: { label, matchMode, matchPath, remoteHost, remotePort, remoteScheme, remotePath, allowLoopbackDestination, preserveHostHeader in
                        Task {
                            await viewModel.createMapRemoteRule(
                                from: context.session,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                remoteHost: remoteHost,
                                remotePort: remotePort,
                                remoteScheme: remoteScheme,
                                remotePath: remotePath,
                                allowLoopbackDestination: allowLoopbackDestination,
                                preserveHostHeader: preserveHostHeader
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateLiveResponseRewrite: { label, matchMode, matchPath, jsonPath, operation, value in
                        Task {
                            await viewModel.createLiveResponseRewriteRule(
                                from: context.session,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                jsonPath: jsonPath,
                                operation: operation,
                                overrideValue: value
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onOpenHLSTestStream: {
                        mapLocalSheetContext = nil
                        hlsTestStreamSheetContext = HLSTestStreamSheetContext(session: context.session)
                    },
                    onCancel: {
                        mapLocalSheetContext = nil
                    }
                )
            }
            .sheet(item: $hlsTestStreamSheetContext) { context in
                HLSTestStreamSheet(
                    session: context.session,
                    profiles: viewModel.hlsFixtureProfiles,
                    loadConflictSummary: { origin, scope in
                        await viewModel.hlsTestStreamConflictSummary(origin: origin, scope: scope)
                    },
                    onStart: { profileID, origin, scope, conflictStrategy in
                        Task {
                            await viewModel.startHLSTestStream(
                                profileID: profileID,
                                origin: origin,
                                scope: scope,
                                conflictStrategy: conflictStrategy
                            )
                        }
                        hlsTestStreamSheetContext = nil
                    },
                    onCancel: {
                        hlsTestStreamSheetContext = nil
                    }
                )
            }
            .sheet(item: $openAPIMockPackSheetContext) { context in
                OpenAPIMockPackSheet(
                    session: context.session,
                    compilePreview: { bookmark, origin in
                        try viewModel.compileOpenAPIMockPack(bookmark: bookmark, origin: origin)
                    },
                    previewActivation: { compiled, strategy in
                        await viewModel.previewOpenAPIMockActivation(
                            compiled: compiled,
                            conflictStrategy: strategy
                        )
                    },
                    onActivate: { compiled, bookmark, origin, strategy, addWithoutStarting in
                        Task {
                            await viewModel.submitOpenAPIMockPack(
                                compiled: compiled,
                                bookmark: bookmark,
                                origin: origin,
                                conflictStrategy: strategy,
                                addWithoutStarting: addWithoutStarting
                            )
                        }
                        openAPIMockPackSheetContext = nil
                    },
                    onCancel: {
                        openAPIMockPackSheetContext = nil
                    }
                )
            }
            .sheet(item: $presentationState.pendingRecordingURL) { identifiable in
                RecordingOpenModeSheet(
                    fileName: identifiable.url.lastPathComponent,
                    onReplace: {
                        presentationState.pendingRecordingURL = nil
                        Task { await viewModel.openRecording(from: identifiable.url, mode: .replace) }
                    },
                    onMerge: {
                        presentationState.pendingRecordingURL = nil
                        Task { await viewModel.openRecording(from: identifiable.url, mode: .merge) }
                    },
                    onCancel: {
                        presentationState.pendingRecordingURL = nil
                    }
                )
            }
            .sheet(item: $presentationState.reproPackageContext) { context in
                ReproPackageSheet(
                    context: context,
                    viewModel: viewModel,
                    onDismiss: { presentationState.reproPackageContext = nil }
                )
            }
            .sheet(isPresented: Binding(
                get: { viewModel.pendingSchemaWarning != nil },
                set: { if !$0 { viewModel.cancelSchemaWarning() } }
            )) {
                if let warning = viewModel.pendingSchemaWarning {
                    SchemaVersionWarningSheet(
                        fileVersion: warning.fileVersion,
                        onLoadAnyway: { Task { await viewModel.confirmSchemaWarning() } },
                        onCancel: { viewModel.cancelSchemaWarning() }
                    )
                }
            }
            .alert(item: $viewModel.trustAlertContext) { context in
                switch context.primaryAction {
                case .acknowledge:
                    return Alert(
                        title: Text(context.title),
                        message: Text(context.message),
                        dismissButton: .default(Text("OK")) {
                            viewModel.dismissTrustAlert()
                        }
                    )
                case .resetCertificateState:
                    return Alert(
                        title: Text(context.title),
                        message: Text(context.message),
                        primaryButton: .destructive(Text("Reset Certificate State")) {
                            viewModel.dismissTrustAlert()
                            viewModel.resetCertificateState()
                        },
                        secondaryButton: .cancel {
                            viewModel.dismissTrustAlert()
                        }
                    )
                }
            }
            .alert(item: $exportAlert) { context in
                Alert(
                    title: Text(context.title),
                    message: Text(context.message),
                    dismissButton: .default(Text("OK"))
                )
            }
    }

    private var configuredContent: some View {
        rootContent
            .padding()
            .appFont(.body, scale: textScale)
            .dynamicTypeSize(viewModel.appTextSize.dynamicTypeSize)
            .environment(\.appTextScale, textScale)
            .frame(
                minWidth: WorkspaceLayoutMetrics.minimumWindowWidth,
                minHeight: WorkspaceLayoutMetrics.minimumWindowHeight
            )
            .onAppear {
                log("ContentView appeared")
                viewModel.scheduleCertificateStatusRefresh()
                sessionStartCoordinator.startReconciliation()
                sessionStartCoordinator.syncPersistedOnboardingState()
                if viewModel.setupNetworkSnapshot == nil {
                    viewModel.captureSetupNetworkSnapshot()
                }
                considerFirstRunCompletion()
                DispatchQueue.main.async {
                    reconcileExplorerSelection()
                }
            }
            .onChange(of: viewModel.sessionCount) { _, _ in
                considerFirstRunCompletion()
            }
            .onChange(of: hasInspectorEditorPresented) { _, presented in
                viewModel.hasInspectorEditorPresented = presented
            }
            .onDisappear {
                log("ContentView disappeared")
                viewModel.hasInspectorEditorPresented = false
                columnConfigPersistenceTask?.cancel()
                persistColumnCustomization(columnCustomization)
                explorerSelectionSyncTask?.cancel()
                explorerSelectionChangeTask?.cancel()
                restoreInspectorSplitTask?.cancel()
            }
            .onChange(of: scenePhase) { _, newValue in
                log("Scene phase changed to \(String(describing: newValue))")
                if newValue == .active {
                    viewModel.scheduleCertificateStatusRefresh()
                }
            }
            .onChange(of: presentationState.isCertificateSetupPresented) { _, isPresented in
                log("Certificate setup sheet presented = \(isPresented)")
            }
            .onChange(of: presentationState.isHelpHubPresented) { _, isPresented in
                log("Help hub presented = \(isPresented)")
                if !isPresented {
                    presentationState.helpHubTopic = nil
                }
            }
            .onChange(of: presentationState.isHTTPSRulesRequested) { _, isRequested in
                guard isRequested else { return }
                isHTTPSRulesPresented = true
                Task { @MainActor in
                    presentationState.isHTTPSRulesRequested = false
                }
            }
            .onChange(of: presentationState.isIOSSetupWalkthroughPresented) { _, isPresented in
                log("iOS setup walkthrough presented = \(isPresented)")
            }
            .onChange(of: presentationState.isMacOSSetupWalkthroughPresented) { _, isPresented in
                log("macOS setup walkthrough presented = \(isPresented)")
            }
            .onChange(of: presentationState.isTVOSSetupWalkthroughPresented) { _, isPresented in
                log("tvOS setup walkthrough presented = \(isPresented)")
            }
            .onChange(of: viewModel.selectedSessionID) { _, selectedSessionID in
                log("Selected session changed to \(selectedSessionID?.uuidString ?? "nil")")
                scheduleExplorerSelectionSync()
                if workspaceWindowTier == .focused {
                    workspacePaneFocus = WorkspacePaneFocus.afterBackgroundSelectionChange(
                        current: workspacePaneFocus,
                        hasValidDetailDestination: hasFocusedDetailDestination
                    )
                }
            }
            .onChange(of: primaryPaneMode) { _, _ in
                if primaryPaneMode == .sessions, recoveryInspectionID == viewModel.selectedSessionID,
                   recoveryInspectionID != nil {
                    workspacePaneFocus = .detail
                } else {
                    recoveryInspectionID = nil
                    workspacePaneFocus = .browser
                }
            }
            .onChange(of: selectedExplorerNodeID) { _, newValue in
                recoveryInspectionID = nil
                scheduleExplorerSelectionChange(newValue)
            }
            .onChange(of: viewModel.sessionExplorerRevision) { _, _ in
                scheduleExplorerSelectionSync()
            }
            .onChange(of: viewModel.sessionBrowserMode) { _, newValue in
                preserveInspectorSplitAcrossBrowserModeChange()
                if newValue == .explorer {
                    scheduleExplorerSelectionSync()
                }
            }
            .onChange(of: presentationState.jsonViewerFileURL?.id) { _, _ in
                if let identifiable = presentationState.jsonViewerFileURL {
                    openWindow(value: identifiable.url)
                    Task { @MainActor in
                        presentationState.jsonViewerFileURL = nil
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspaceCommandRequested)) { notification in
                guard let rawValue = notification.userInfo?["action"] as? String,
                      let action = WorkspaceCommandAction(rawValue: rawValue) else {
                    return
                }

                handleWorkspaceCommand(action)
            }
    }

    private var rootContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusToolbar
            if let uploadSpoolService { UploadStorageNotice(service: uploadSpoolService) }

            WorkspaceNoticeRegion(notices: projectedWorkspaceNotices,
                                  constrained: workspaceLayout.height == .constrained,
                                  perform: { _ in isWorkspaceRecoveryPresented = true },
                                  dismiss: { workspaceNotices.dismissPersistentNotice(id: $0) })

            if presentationState.shouldShowInspectorSetupCompanion {
                if workspaceLayout.height == .constrained {
                    Button("Setup guidance") { isSetupSummaryPresented = true }
                        .accessibilityIdentifier("workspaceSetupSummary")
                } else {
                    inspectorSetupCompanion
                }
            }

            workspaceContainer
        }
        .sheet(isPresented: $isWorkspaceRecoveryPresented) {
            ScrollView { workspaceRecoveryContent.padding() }
                .frame(minWidth: 360, idealWidth: 560, minHeight: 240, idealHeight: 420)
        }
        .sheet(isPresented: $isSetupSummaryPresented) {
            ScrollView {
                VStack {
                    Button("Done") { isSetupSummaryPresented = false }
                    inspectorSetupCompanion
                }.padding()
            }
                .frame(minWidth: 360, idealWidth: 560, minHeight: 240, idealHeight: 420)
        }
        .reportWorkspaceLayout(textScale: textScale) { workspaceLayout = $0 }
        .overlay(alignment: .top) {
            if let toast = workspaceNotices.toast {
                WorkspaceToastView(toast: toast) { workspaceNotices.dismissToast() }
                    .padding(.top, 54)
            }
        }
    }

    private var projectedWorkspaceNotices: [WorkspacePersistentNotice] {
        var notices = workspaceNotices.persistentNotices
        func append(_ id: String, _ title: String, _ message: String, blocking: Bool = true) {
            notices.append(WorkspacePersistentNotice(id: id, title: title, message: message,
                severity: blocking ? .blocking : .advisory, actionID: id,
                actionTitle: "Resolve", isDismissible: false))
        }
        if let message = proxyFailureMessage { append("capture", "Capture needs attention", message) }
        if systemProxyController.pendingRecovery != nil {
            append("routing", "Routing recovery", "Review the saved system routing state before restoring it.")
        }
        if shouldShowCertificateRecoveryBanner {
            append("certificate", "Certificate setup needs attention", "Review certificate status and recovery options.")
        }
        if let message = exportFailureMessage { append("export", "Export failed", message) }
        if let message = viewModel.recordingSchemaNotice { append("schema", "Recording compatibility", message, blocking: false) }
        if let message = viewModel.rollingCapturePersistenceError {
            append("persistence", "Rolling recovery needs attention", message)
        }
        if case .loadWarning(let ids) = viewModel.recordingLoadState, !ids.isEmpty {
            append("load-warning", "Recording partially loaded", "\(ids.count) bodies could not be loaded.", blocking: false)
        }
        if case .failed(let message) = viewModel.recordingLoadState { append("load", "Recording load failed", message) }
        return notices
    }

    private var workspaceRecoveryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Done") { isWorkspaceRecoveryPresented = false }
            ForEach(workspaceNotices.persistentNotices) { notice in
                WorkspacePersistentNoticeView(notice: notice) {
                    workspaceNotices.dismissPersistentNotice(id: notice.id)
                }
            }

            if let proxyFailureMessage = proxyFailureMessage {
                proxyFailureBanner(message: proxyFailureMessage)
            }

            if systemProxyController.pendingRecovery != nil {
                systemProxyRecoveryBanner
            }

            if shouldShowCertificateRecoveryBanner {
                certificateRecoveryBanner
            }

            if let exportFailureMessage = exportFailureMessage {
                exportFailureBanner(message: exportFailureMessage)
            }

            if let notice = viewModel.recordingSchemaNotice {
                recordingNoticeBanner(message: notice)
            }
            if let notice = viewModel.rollingCapturePersistenceError {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Rolling recovery needs attention", systemImage: "exclamationmark.triangle.fill")
                        .appFont(.subheadline, scale: textScale, weight: .semibold)
                    Text(notice)
                        .appFont(.caption, scale: textScale)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("rollingCapturePersistenceError")
            }

            if case .loadWarning(let ids) = viewModel.recordingLoadState, !ids.isEmpty {
                recordingLoadWarningBanner(failedCount: ids.count)
            }

            if case .failed(let message) = viewModel.recordingLoadState {
                recordingLoadErrorBanner(message: message)
            }

        }
    }

    private var workspaceWindowTier: WorkspaceWindowTier {
        workspaceLayout.tier
    }

    @ViewBuilder
    private var workspaceContainer: some View {
        if workspaceWindowTier.usesTwoPanes {
            HSplitView {
                browserPane
                    .frame(minWidth: Layout.sessionTableMinWidth, maxWidth: .infinity)
                    .background(
                        PersistentHSplitViewObserver(
                            splitFraction: $viewModel.sessionInspectorSplitFraction,
                            minLeadingWidth: Layout.sessionTableMinWidth,
                            minTrailingWidth: Layout.inspectorMinWidth,
                            isCaptureSuppressed: isSuppressingInspectorSplitCapture
                        )
                    )
                inspectorPane
                    .frame(minWidth: Layout.inspectorMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
            .transition(.opacity)
        } else {
            Group {
                if workspacePaneFocus == .detail, hasFocusedDetailDestination {
                    inspectorPane
                } else {
                    browserPane
                }
            }
            .transition(.opacity)
        }
    }

    private var browserPane: some View {
        WorkspacePaneContainer(kind: .browser, textScale: textScale, modeChanged: { browserPaneLayoutMode = $0 }) {
            browserPaneHeader
        } content: {
            if primaryPaneMode == .sessions, let bookmarkUpdateContext = viewModel.bookmarkUpdateContext {
                bookmarkUpdateBanner(context: bookmarkUpdateContext)
            }
            Group {
                if primaryPaneMode == .sessions,
                   viewModel.sessionBrowserMode == .table,
                   browserPaneLayoutMode == .narrow {
                    compactSessionList
                } else {
                    primaryPaneContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } footer: {
            browserPaneFooter
        }
        .onKeyPress(.return) {
            guard workspaceWindowTier == .focused, hasFocusedDetailDestination else { return .ignored }
            enterFocusedDetail()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard workspaceWindowTier == .focused, hasFocusedDetailDestination else { return .ignored }
            enterFocusedDetail()
            return .handled
        }
        .accessibilityIdentifier("workspaceBrowserPane")
    }

    private var inspectorPane: some View {
        WorkspacePaneContainer(kind: .inspector, textScale: textScale, modeChanged: { inspectorPaneLayoutMode = $0 }) {
            inspectorPaneHeader
        } content: {
            inspectorContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } footer: { EmptyView() }
        .onExitCommand {
            if workspaceWindowTier == .focused {
                workspacePaneFocus = .browser
            }
        }
        .accessibilityIdentifier("workspaceInspectorPane")
    }

    private var hasFocusedDetailDestination: Bool {
        if recoveryInspectionID != nil, recoveryInspectionID == viewModel.selectedSessionID,
           primaryPaneMode == .sessions { return viewModel.selectedSession != nil }
        switch primaryPaneMode {
        case .sessions:
            if viewModel.sessionBrowserMode == .explorer,
               selectedExplorerNode?.isFolder == true {
                return true
            }
            return activeSessionSelection != nil
        case .bookmarks:
            return viewModel.selectedBookmark != nil
        }
    }

    private var statusToolbar: some View {
        MainStatusTitleBar(
            proxyState: viewModel.proxyState,
            canStartProxy: viewModel.canStartProxy,
            canStopProxy: viewModel.canStopProxy,
            proxyPort: viewModel.configuration.proxyPort,
            certificateWorkflowState: viewModel.certificateWorkflowState,
            certificateStatusGuidance: viewModel.certificateStatusGuidance,
            httpsProxyMode: viewModel.httpsProxyMode,
            hasCustomHTTPSRules: viewModel.hasCustomHTTPSRules,
            captureHealth: viewModel.captureHealth,
            lastErrorMessage: viewModel.lastErrorMessage,
            suggestedHelpTopicTitle: isHelpDocumentationReady ? suggestedHelpTopic.title : "Help",
            textScale: textScale,
            systemProxyIndicator: AnyView(systemProxyToolbarIndicator),
            toggleProxy: toggleProxy,
            openProxyHelp: { openHelpWindow(topic: .capturedSessions) },
            openCertificateSetup: { presentationState.presentCertificateSetup() },
            openHTTPSRules: { isHTTPSRulesPresented = true },
            openContextualHelp: { openHelpWindow(topic: suggestedHelpTopic) },
            openFindInBodies: { presentationState.presentBodyFind() },
            mcpPipelineStatus: mcpServerController.mcpPipelineStatus,
            openMCPManagement: { destination in
                presentationState.presentMCPManagement(destination: destination)
            },
            showsSetupChip: presentationState.showsFirstRunSetupChip,
            openSetupCompanion: {
                presentationState.revealInspectorSetupCompanionFromChip()
            }
        )
    }

    private var inspectorSetupCompanion: some View {
        InspectorSetupCompanionView(
            isProxyRunning: isProxyRunningForFirstRun,
            selectedTargetID: sessionStartCoordinator.workingSurfaceState.selectedTargetID,
            hasObservedSelectedTargetRequest: hasObservedSelectedTargetRequest,
            setupNetworkDriftSummary: viewModel.setupNetworkDriftSummary,
            onSelectTarget: { targetID in
                sessionStartCoordinator.selectTarget(targetID: targetID)
                considerFirstRunCompletion()
            },
            onOpenMacOSGuide: {
                presentationState.presentMacOSSetupWalkthrough()
            },
            onOpenIOSGuide: {
                presentationState.presentIOSSetupWalkthrough()
            },
            onOpenTVOSGuide: {
                presentationState.presentTVOSSetupWalkthrough()
            },
            onOpenSimulatorGuide: {
                presentationState.presentSimulatorSetupWalkthrough()
            },
            onDismiss: {
                presentationState.dismissInspectorSetupCompanion()
            }
        )
    }

    private var isProxyRunningForFirstRun: Bool {
        if case .running = viewModel.proxyState {
            return true
        }
        return false
    }

    private var hasObservedSelectedTargetRequest: Bool {
        viewModel.sessionSummaries.contains { summary in
            FirstRunCompletionPolicy.sessionMatchesSelectedTarget(
                source: summary.source,
                selectedTargetID: sessionStartCoordinator.workingSurfaceState.selectedTargetID
            )
        }
    }

    /// Completes first run when a selected-target request exists. Certificate setup is not a gate.
    private func considerFirstRunCompletion() {
        presentationState.completeFirstRunIfEligible(
            sessionSources: viewModel.sessionSummaries.map(\.source)
        )
        sessionStartCoordinator.syncPersistedOnboardingState()
    }

    private var browserPaneHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                browserNavigationRow(compact: browserPaneLayoutMode != .roomy)
                browserNavigationRow(compact: true)
            }

            if primaryPaneMode == .sessions, viewModel.sessionBrowserMode == .explorer {
                ExplorerToolbarMenusView(
                    grouping: $viewModel.sessionExplorerGrouping,
                    hostGrouping: $viewModel.sessionExplorerHostGrouping
                )
            }

            if primaryPaneMode == .sessions {
                HStack(spacing: 8) {
                    sessionSearchField
                    filterPopoverButton
                }
                activeFilterPillBar
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browserPaneHeader")
    }

    private func browserNavigationRow(compact: Bool) -> some View {
            HStack(spacing: 8) {
                if compact {
                    Menu {
                        Picker("Content", selection: primaryPaneModeBinding) {
                            ForEach(PrimaryPaneMode.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label(primaryPaneMode.title, systemImage: primaryPaneMode == .sessions ? "tray.full" : "bookmark")
                    }
                    .accessibilityIdentifier("primaryPaneMenuCompact")
                } else {
                    Picker("Content", selection: primaryPaneModeBinding) {
                        ForEach(PrimaryPaneMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("primaryPanePicker")
                }

                if primaryPaneMode == .sessions {
                    if compact {
                        Menu {
                            Picker("Browser", selection: sessionBrowserModeBinding) {
                                ForEach(SessionBrowserMode.allCases) { Text($0.title).tag($0) }
                            }
                        } label: {
                            Label(viewModel.sessionBrowserMode.title, systemImage: "rectangle.split.3x1")
                        }
                        .accessibilityIdentifier("sessionBrowserMenuCompact")
                    } else {
                        Picker("Browser", selection: sessionBrowserModeBinding) {
                            ForEach(SessionBrowserMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("sessionBrowserPicker")
                    }

                    Text(verbatim: sessionCountSummaryText)
                        .appFont(.caption, scale: textScale, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(sessionCountSummaryAccessibilityLabel)
                } else {
                    Text(verbatim: "\(viewModel.bookmarkCount)")
                        .appFont(.caption, scale: textScale, design: .monospaced)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if workspaceWindowTier == .focused, hasFocusedDetailDestination {
                    Button("Inspect") { enterFocusedDetail() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .keyboardShortcut("]", modifiers: [.command])
                        .accessibilityHint("Opens the selected item in the detail pane.")
                        .accessibilityIdentifier("focusedInspectButton")
                }
            }

    }

    private var primaryPaneModeBinding: Binding<PrimaryPaneMode> {
        Binding(get: { primaryPaneMode }) { newValue in
            primaryPaneMode = newValue
            workspacePaneFocus = .browser
        }
    }

    private var sessionBrowserModeBinding: Binding<SessionBrowserMode> {
        Binding(get: { viewModel.sessionBrowserMode }) { newValue in
            viewModel.sessionBrowserMode = newValue
            workspacePaneFocus = .browser
        }
    }

    private var sessionSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search captured sessions", text: $viewModel.sessionSearchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search captured sessions")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
        .frame(minWidth: 120, maxWidth: .infinity)
        .accessibilityIdentifier("sessionSearchField")
    }

    private var structuredFilterCount: Int {
        let criteria = viewModel.sessionFilterCriteria
        return [
            !criteria.hostContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            criteria.method != nil,
            criteria.scheme != nil,
            criteria.inspectionMatch != nil,
            criteria.statusMatch != nil,
            criteria.sourceMatch != nil,
            criteria.clientAddressMatch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ].filter { $0 }.count
    }

    private var filterPopoverButton: some View {
        Button {
            isSessionFilterPopoverPresented.toggle()
        } label: {
            Label(
                structuredFilterCount > 0 ? "Filter: \(structuredFilterCount) active" : "Filter",
                systemImage: "line.3.horizontal.decrease.circle\(structuredFilterCount > 0 ? ".fill" : "")"
            )
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(structuredFilterCount > 0 ? .accentColor : nil)
        .popover(isPresented: $isSessionFilterPopoverPresented) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Filter Sessions")
                        .appFont(.headline, scale: textScale, weight: .semibold)
                    Spacer()
                    if viewModel.hasActiveSessionFilters {
                        Button("Clear All") { clearSessionFiltersWithNotice() }
                            .buttonStyle(.borderless)
                    }
                }
                sessionFilterControls
            }
            .padding(14)
            .frame(width: 560)
        }
        .accessibilityValue(structuredFilterCount == 0 ? "No structured filters active" : "\(structuredFilterCount) active")
        .accessibilityIdentifier("sessionFilterPopoverButton")
    }

    @ViewBuilder
    private var activeFilterPillBar: some View {
        if !activeSessionFilterPills.isEmpty {
            let visiblePills = Array(activeSessionFilterPills.prefix(maximumVisibleFilterPills))
            let hiddenPillCount = activeSessionFilterPills.count - visiblePills.count
            HStack(alignment: .top, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(24 * textScale)), count: workspaceLayout.height == .constrained ? 1 : 2), spacing: 5) {
                        ForEach(visiblePills) { pill in
                            Button {
                                pill.remove()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(pill.label).lineLimit(1)
                                    Image(systemName: "xmark.circle.fill").accessibilityHidden(true)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .accessibilityLabel("Remove \(pill.label) filter")
                        }
                        if hiddenPillCount > 0 {
                            Button("+\(hiddenPillCount) more") {
                                isSessionFilterPopoverPresented = true
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .accessibilityLabel("Show \(hiddenPillCount) more active filters")
                        }
                    }
                    .frame(height: (workspaceLayout.height == .constrained ? 28 : 56) * textScale)
                }
                Button("Clear All") { clearSessionFiltersWithNotice() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .fixedSize()
            }
            .accessibilityIdentifier("activeFilterPillBar")
        }
    }

    private var browserPaneFooter: some View {
        Group {
            if primaryPaneMode == .sessions {
                HStack(spacing: 8) {
                    SessionFollowToolbarControlsView(
                        followState: viewModel.sessionFollowState,
                        hasSessions: viewModel.hasSessions,
                        setFollowLiveEnabled: viewModel.setFollowLiveEnabled,
                        jumpToLatest: viewModel.jumpToLatestSession,
                        iconOnly: browserPaneLayoutMode == .narrow
                    )

                    Spacer(minLength: 4)

                    if viewModel.sessionBrowserMode == .table {
                        SessionTableToolbarControlsView(
                            sortField: $viewModel.sessionSortField,
                            isAscending: $viewModel.isSessionSortAscending,
                            iconOnly: browserPaneLayoutMode != .roomy
                        )
                    }

                    SessionManagementMenusView(
                        sessionCount: viewModel.sessionCount,
                        hasSelectedSessions: viewModel.hasSelectedSessions,
                        hasSessions: viewModel.hasSessions,
                        clearSelected: clearSelectedSessionsWithNotice,
                        clearAll: {
                            let count = viewModel.sessionCount
                            guard viewModel.clearAllSessions() == .cleared else {
                                presentationState.isClearCaptureBusyPresented = true
                                return
                            }
                            workspacePaneFocus = .browser
                            workspaceNotices.presentToast("Cleared \(count) captured sessions.")
                        },
                        exportSelectedJSON: { exportSessions(scope: .selected, format: .json) },
                        exportAllJSON: { exportSessions(scope: .all, format: .json) },
                        exportSelectedHAR: { exportSessions(scope: .selected, format: .har) },
                        exportAllHAR: { exportSessions(scope: .all, format: .har) },
                        exportVisualization: presentVisualizationExport,
                        iconOnly: browserPaneLayoutMode != .roomy
                    )

                    if case .idle = viewModel.exportState { EmptyView() } else { exportStatusBadge }
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("browserSessionFooter")
            }
        }
    }

    private var inspectorPaneHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            if inspectorPaneLayoutMode == .compact { inspectorIdentityLabel }
        HStack(spacing: 8) {
            if workspaceWindowTier == .focused {
                Button {
                    workspacePaneFocus = .browser
                } label: {
                    Label(primaryPaneMode.title, systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("[", modifiers: [.command])
                .accessibilityIdentifier("focusedBackButton")
            }

            if inspectorPaneLayoutMode == .roomy { inspectorIdentityLabel }
            Spacer(minLength: 4)
            modifyHubMenu
            inspectorShareMenu
        }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspectorPaneHeader")
    }

    @ViewBuilder
    private var inspectorIdentityLabel: some View {
        if primaryPaneMode == .bookmarks, let bookmark = viewModel.selectedBookmark {
            Label(bookmark.name, systemImage: "bookmark.fill")
                .appFont(.subheadline, scale: textScale, weight: .semibold)
                .lineLimit(1)
        } else if let session = activeSessionSelection {
            HStack(spacing: 6) {
                Text(session.request.method)
                    .appFont(.caption, scale: textScale, weight: .bold, design: .monospaced)
                Text(session.request.path)
                    .appFont(.subheadline, scale: textScale, weight: .semibold, design: .monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status = session.response?.statusCode {
                    Text(verbatim: "\(status)")
                        .appFont(.caption, scale: textScale, weight: .bold, design: .monospaced)
                }
            }
            .accessibilityElement(children: .combine)
        } else if let selectedExplorerNode, selectedExplorerNode.isFolder {
            Label(selectedExplorerNode.title, systemImage: "folder.fill")
                .lineLimit(1)
        } else {
            Text("No Selection")
                .appFont(.subheadline, scale: textScale, weight: .semibold)
                .foregroundStyle(.secondary)
        }
    }

    private var modifyHubMenu: some View {
        let snapshot = viewModel.trafficModificationSnapshot
        return Menu {
            Section("Current Selection") {
                Button("Map Local for This Request…") {
                    guard let session = activeSessionSelection else { return }
                    performMapLocal(for: session)
                }
                .disabled(activeSessionSelection.map { !viewModel.canCreateResponseOverride(from: $0) } ?? true)

                Button("Replace with Test Stream…") {
                    guard let session = activeSessionSelection else { return }
                    performHLSTestStream(for: session)
                }
                .disabled(activeSessionSelection.map { !viewModel.canReplaceWithHLSTestStream($0) } ?? true)

                Button("Block Endpoint…") {
                    guard let session = activeSessionSelection else { return }
                    mapLocalSheetContext = MapLocalSheetContext(session: session)
                }
                .disabled(activeSessionSelection == nil)
            }

            Section("Active Simulation") {
                Toggle("Network Throttling", isOn: networkThrottlingEnabledBinding)
                    .accessibilityIdentifier("networkThrottlingToggle")
                Picker("Throttle Preset", selection: networkThrottlePresetBinding) {
                    ForEach(viewModel.networkThrottleConfiguration.presets) { Text($0.name).tag($0.id) }
                }
                .accessibilityIdentifier("networkThrottlingPresetMenu")
                Button("Open Traffic Modification Manager…") {
                    openWindow(id: TrafficModificationsWindowView.windowID)
                }
            }

            Divider()
            Button("Disable All Traffic Modifications", role: .destructive) {
                resetAllTrafficModifications()
            }
            .disabled(snapshot.activeModificationCount == 0 || viewModel.isResettingTrafficModifications)
        } label: {
            Label {
                Text(viewModel.isResettingTrafficModifications
                    ? "Resetting…"
                    : snapshot.activeModificationCount > 0
                        ? "Modify (\(snapshot.activeModificationCount) active)"
                        : "Modify")
            } icon: {
                if viewModel.isResettingTrafficModifications {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: snapshot.activeModificationCount > 0 ? "arrow.triangle.branch.circle.fill" : "arrow.triangle.branch.circle")
                }
            }
            .foregroundStyle(snapshot.activeModificationCount > 0 ? Color.orange : Color.primary)
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .accessibilityValue(snapshot.activeModificationCount == 0 ? "No traffic modifications active" : "\(snapshot.activeModificationCount) active")
        .accessibilityIdentifier("modifyHubMenu")
    }

    private var inspectorShareMenu: some View {
        Menu {
            if let session = activeSessionSelection {
                Button("Copy as curl") { performCopyCurl(for: session) }
                Button("Add to Bookmarks") { performAddBookmark(for: session) }
            } else if let bookmark = viewModel.selectedBookmark {
                Button("Copy as curl") { performCopyCurl(for: bookmark) }
            }
        } label: {
            Label(inspectorPaneLayoutMode == .compact ? "" : "Share", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .disabled(activeSessionSelection == nil && viewModel.selectedBookmark == nil)
        .accessibilityLabel("Copy and share selected item")
        .accessibilityIdentifier("inspectorShareMenu")
    }

    private var compactSessionList: some View {
        Group {
            if viewModel.hasVisibleSessions {
                List(viewModel.sessionTableDisplayedSummaries) { summary in
                    Button {
                        viewModel.selectSessionFromUser(summary.id)
                        enterFocusedDetail()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(summary.method)
                                    .appFont(.caption, scale: textScale, weight: .bold, design: .monospaced)
                                Spacer()
                                Text(statusText(for: summary))
                                    .appFont(.caption, scale: textScale, weight: .semibold, design: .monospaced)
                                    .foregroundStyle(statusColor(for: summary))
                            }
                            Text(summary.host)
                                .appFont(.subheadline, scale: textScale, weight: .semibold)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(summary.path)
                                .appFont(.caption, scale: textScale, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("compactSessionRow")
                }
                .listStyle(.inset)
            } else {
                sessionEmptyState
            }
        }
        .accessibilityIdentifier("compactSessionList")
    }

    private func enterFocusedDetail() {
        workspacePaneFocus = WorkspacePaneFocus.afterExplicitDetailEntry(
            current: workspacePaneFocus,
            hasValidDetailDestination: hasFocusedDetailDestination
        )
    }

    private var maximumVisibleFilterPills: Int {
        switch browserPaneLayoutMode {
        case .narrow: return 3
        case .compact: return 5
        case .roomy: return 7
        }
    }

    private func clearSelectedSessionsWithNotice() {
        let count = viewModel.selectedSessionIDs.count
        viewModel.clearSelectedSessions()
        if count > 0 {
            workspaceNotices.presentToast("Cleared \(count) selected session\(count == 1 ? "" : "s").")
        }
    }

    private func clearSessionFiltersWithNotice() {
        guard viewModel.hasActiveSessionFilters else { return }
        viewModel.clearSessionFilters()
        workspaceNotices.presentToast("Session filters cleared.")
    }

    private func resetAllTrafficModifications() {
        Task {
            let result = await viewModel.disableAllTrafficModifications()
            if result.isComplete {
                workspaceNotices.presentToast("Disabled \(result.disabledCount) traffic modification\(result.disabledCount == 1 ? "" : "s").")
            } else {
                workspaceNotices.present(
                    WorkspacePersistentNotice(
                        id: "traffic-modification-reset",
                        title: "Some modifications remain active",
                        message: "\(result.remainingCount) traffic modification\(result.remainingCount == 1 ? "" : "s") could not be disabled. Open Modify to review them.",
                        severity: .blocking
                    )
                )
            }
        }
    }

    private var activeSessionFilterPills: [SessionFilterPill] {
        let criteria = viewModel.sessionFilterCriteria
        var pills: [SessionFilterPill] = []

        let host = criteria.hostContains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty {
            pills.append(SessionFilterPill(id: "host", label: "Host: \(host)") {
                viewModel.sessionFilterCriteria.hostContains = ""
            })
        }
        if let method = criteria.method {
            pills.append(SessionFilterPill(id: "method", label: "Method: \(method)") {
                viewModel.sessionFilterCriteria.method = nil
            })
        }
        if let scheme = criteria.scheme {
            pills.append(SessionFilterPill(id: "scheme", label: "Scheme: \(scheme.rawValue.uppercased())") {
                viewModel.sessionFilterCriteria.scheme = nil
            })
        }
        if criteria.inspectionMatch != nil {
            let title = inspectionFilterBinding.wrappedValue.title
            pills.append(SessionFilterPill(id: "inspection", label: "Inspection: \(title)") {
                viewModel.sessionFilterCriteria.inspectionMatch = nil
            })
        }
        if criteria.statusMatch != nil {
            let title = statusFilterBinding.wrappedValue.title
            pills.append(SessionFilterPill(id: "status", label: "Status: \(title)") {
                viewModel.sessionFilterCriteria.statusMatch = nil
            })
        }
        if let source = criteria.sourceMatch {
            pills.append(SessionFilterPill(id: "source", label: "Source: \(source.title)") {
                viewModel.sessionFilterCriteria.sourceMatch = nil
            })
        }
        if let address = criteria.clientAddressMatch,
           !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let displayName = viewModel.discoveredDevices.first(where: { $0.ipAddress == address })?.displayName ?? address
            pills.append(SessionFilterPill(id: "device", label: "Device: \(displayName)") {
                viewModel.sessionFilterCriteria.clientAddressMatch = nil
            })
        }
        return pills
    }

    private func sessionTableShowsColumn(_ column: SessionTableColumnID) -> Bool {
        SessionTableColumnVisibility.isVisible(column, paneWidth: sessionTablePaneWidth)
    }

    // MARK: Session table cells (SessionSummary-backed; extracted to keep the Table
    // expression type-checkable and rows free of full SessionRecord dependence)

    @TableColumnBuilder<SessionTableRowPresentation, Never>
    private var sessionTableColumns: some TableColumnContent<SessionTableRowPresentation, Never> {
        if sessionTableShowsColumn(.time) {
            TableColumn("Time") { row in sessionTableTimeCell(row.summary) }
                .width(
                    min: max(56, tableTimeColumnWidth * 0.8),
                    ideal: tableTimeColumnWidth,
                    max: max(150, tableTimeColumnWidth * 1.8)
                )
                .customizationID("time")
                .defaultVisibility(.hidden)
        }

        TableColumn("Method") { row in sessionTableMethodCell(row.summary) }
            .width(
                min: max(64, tableMethodColumnWidth * 0.8),
                ideal: tableMethodColumnWidth,
                max: max(160, tableMethodColumnWidth * 1.7)
            )
            .customizationID("method")

        TableColumn("Domain") { row in sessionTableDomainCell(row.summary) }
            .width(min: 120, ideal: 220, max: 560)
            .customizationID("domain")

        if sessionTableShowsColumn(.source) {
            TableColumn("Source") { row in sessionTableSourceCell(row.summary) }
                .width(
                    min: max(64, tableSourceColumnWidth * 0.8),
                    ideal: tableSourceColumnWidth,
                    max: max(180, tableSourceColumnWidth * 1.8)
                )
                .customizationID("source")
        }

        TableColumn("Path") { row in sessionTablePathCell(row.summary) }
            .width(min: 140, ideal: 320, max: 960)
            .customizationID("path")

        if sessionTableShowsColumn(.media) {
            TableColumn("Media") { row in sessionTableMediaCell(row.summary) }
                .width(min: tableMediaColumnWidth, ideal: tableMediaColumnWidth, max: tableMediaColumnWidth)
                .customizationID("media")
        }

        if sessionTableShowsColumn(.status) {
            TableColumn("Status") { row in sessionTableStatusCell(row.summary) }
                .width(min: 60, ideal: 78, max: 150)
                .customizationID("status")
        }

        if sessionTableShowsColumn(.size) {
            TableColumn("Size") { row in sessionTableSizeCell(row.summary) }
                .width(
                    min: max(56, tableSizeColumnWidth * 0.8),
                    ideal: tableSizeColumnWidth,
                    max: max(160, tableSizeColumnWidth * 1.8)
                )
                .customizationID("size")
                .defaultVisibility(.hidden)
        }

        if sessionTableShowsColumn(.duration) {
            TableColumn("Duration") { row in sessionTableDurationCell(row.summary) }
                .width(min: 70, ideal: 96, max: 180)
                .customizationID("duration")
        }
    }

    private func sessionTableTimeCell(_ summary: SessionSummary) -> some View {
        tableCell(alignment: .trailing) {
            Text(Self.tableTimeFormatter.string(from: summary.startedAt))
                .appFont(.subheadline, scale: textScale, design: .monospaced)
                .foregroundStyle(.secondary)
        }
    }

    private func sessionTableMethodCell(_ summary: SessionSummary) -> some View {
        tableCell(alignment: .center) {
            RequestMethodBadge(method: summary.method, scale: textScale)
        }
    }

    private func sessionTableDomainCell(_ summary: SessionSummary) -> some View {
        tableCell {
            HStack(spacing: 6) {
                Image(systemName: sessionIconName(for: summary))
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(sessionIconTint(for: summary))
                Text(summary.host)
                    .appFont(.subheadline, scale: textScale)
                    .lineLimit(1)
                    .truncationMode(.middle)
                overrideBadge(for: overrideSource(summary))
                mcpAttributionBadge(for: summary.mcpAttribution)
                schemeBadge(for: summary.scheme)
            }
        }
    }

    private func sessionTableSourceCell(_ summary: SessionSummary) -> some View {
        tableCell(alignment: .center) {
            deviceSourceBadge(for: summary)
        }
    }

    @ViewBuilder
    private func deviceSourceBadge(for summary: SessionSummary) -> some View {
        if let displayName = viewModel.deviceDisplayName(for: summary.clientAddress) {
            HStack(spacing: 5) {
                sourceBadge(for: summary.source)
                Text(displayName)
                    .appFont(.caption, scale: textScale, weight: .semibold, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(Color.secondary.opacity(0.12)))
                    .accessibilityLabel("Source device: \(displayName)")
            }
        } else {
            sourceBadge(for: summary.source)
        }
    }

    private func sessionTablePathCell(_ summary: SessionSummary) -> some View {
        tableCell {
            Text(summary.path)
                .appFont(.subheadline, scale: textScale, design: .monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(Text(verbatim: summary.path))
        }
    }

    private func sessionTableMediaCell(_ summary: SessionSummary) -> some View {
        tableCell(alignment: .center) {
            if let mediaSymbolName = mediaSymbolName(for: summary.mediaType) {
                Image(systemName: mediaSymbolName)
                    .font(.system(size: tableMediaIconSize, weight: .semibold))
                    .foregroundStyle(mediaSymbolTint(for: summary.mediaType))
                    .frame(width: tableMediaIconSize, height: tableMediaIconSize)
                    // No .help() — see schemeBadge: tooltips inside Table rows crash on recycle.
                    .accessibilityLabel(mediaDescription(for: summary.mediaType))
            }
        }
    }

    private func sessionTableStatusCell(_ summary: SessionSummary) -> some View {
        tableCell(alignment: .trailing) {
            Text(statusText(for: summary))
                .appFont(.subheadline, scale: textScale, weight: .semibold, design: .monospaced)
                .foregroundStyle(statusColor(for: summary))
        }
    }

    private func sessionTableSizeCell(_ summary: SessionSummary) -> some View {
        tableCell(alignment: .trailing) {
            Text(formattedByteSize(summary.responseBodySize))
                .appFont(.subheadline, scale: textScale, design: .monospaced)
                .foregroundStyle(.secondary)
        }
    }

    private func sessionTableDurationCell(_ summary: SessionSummary) -> some View {
        tableCell(alignment: .trailing) {
            Text(durationText(for: summary))
                .appFont(.subheadline, scale: textScale, design: .monospaced)
                .foregroundStyle(.secondary)
        }
    }

    private var sessionTable: some View {
        Group {
            if viewModel.hasVisibleSessions {
                VStack(spacing: 8) {
                    sessionTableCore

                    if viewModel.sessionTableHiddenSessionCount > 0 {
                        Button {
                            viewModel.showMoreSessionTableSessions()
                        } label: {
                            Text("Show \(viewModel.sessionTableHiddenSessionCount) older sessions…")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("sessionTableShowMoreButton")
                    }
                }
            } else {
                sessionEmptyState
            }
        }
        .reportWorkspaceColumns(textScale: textScale) { sessionTablePaneWidth = $0 }
        .accessibilityIdentifier("sessionTable")
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if viewModel.hasVisibleSessions {
                Button {
                    isSessionIconLegendPresented = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(8)
                .accessibilityIdentifier("sessionIconLegendButton")
                .accessibilityLabel("Show session icon legend")
                .popover(isPresented: $isSessionIconLegendPresented) {
                    SessionIconLegendView()
                }
            }
        }
    }

    private var sessionTableCore: some View {
        Table(viewModel.sessionTableDisplayedRowIdentities, selection: selectedSessionBinding, columnCustomization: columnCustomizationBinding) {
            sessionTableColumns
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: SessionRecord.ID.self) { selectedIDs in
            sessionTableContextMenu(selection: selectedIDs)
        }
        .accessibilityLabel("Captured sessions")
        .accessibilityValue(viewModel.selectedSessionID == nil ? "No selection" : (viewModel.selectedSession.map {
            "Selected: \($0.request.method) \($0.request.host)\($0.request.path)"
        } ?? "No selection"))
        .accessibilityIdentifier("sessionTable")
    }

    @ViewBuilder
    private func sessionTableContextMenu(selection selectedIDs: Set<SessionRecord.ID>) -> some View {
        if let session = sessionForContextMenu(selection: selectedIDs) {
            Button {
                performMapLocal(for: session)
            } label: {
                Label("Map Local…", systemImage: "arrow.triangle.branch")
            }
            .disabled(!viewModel.canCreateResponseOverride(from: session))

            if viewModel.canReplaceWithHLSTestStream(session) {
                Button {
                    performHLSTestStream(for: session)
                } label: {
                    Label("Replace with Test Stream…", systemImage: "play.rectangle.on.rectangle")
                }
            }

            Button {
                performAddBookmark(for: session)
            } label: {
                Label("Add to Bookmarks", systemImage: "bookmark")
            }

            Button {
                presentationState.presentMCPManagement(destination: .agentRuns)
            } label: {
                Label("Create Agent Run…", systemImage: "waveform.path.ecg")
            }
            .accessibilityIdentifier("createAgentRunFromSessionButton")
            .help("Opens Agent Runs. Paste this session’s ID into the guided draft if you want a captured-session scope; keep hypothesis text human-authored.")

            Button {
                performCopyCurl(for: session)
            } label: {
                Label("Copy as curl", systemImage: "document.on.document")
            }

            Button {
                performCopySwiftMock(for: session)
            } label: {
                Label("Copy as Swift Mock (Mocker)", systemImage: "curlybraces")
            }

            Divider()

            Button {
                viewModel.setSessionHostFilter(session.request.host)
            } label: {
                Label("Filter to \(session.request.host)", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    private var sessionExplorerView: some View {
        Group {
            if viewModel.hasVisibleSessions, !viewModel.sessionExplorerTree.isEmpty {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(viewModel.sessionExplorerVisibleRows) { row in
                                explorerNodeRow(row.node, depth: row.depth)
                                    .id(row.node.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel("Captured sessions explorer")
                    .accessibilityHint("Use up and down arrow keys to navigate, right arrow to expand, left arrow to collapse, space or return to select.")
                    .focusable()
                    .focused($isExplorerFocused)
                    .onKeyPress(.upArrow) {
                        navigateExplorer(direction: .up, scrollProxy: scrollProxy)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        navigateExplorer(direction: .down, scrollProxy: scrollProxy)
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        navigateExplorer(direction: .expandOrDescend, scrollProxy: scrollProxy)
                        return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        navigateExplorer(direction: .collapseOrAscend, scrollProxy: scrollProxy)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        activateSelectedExplorerNode()
                        return .handled
                    }
                    .onKeyPress(.space) {
                        activateSelectedExplorerNode()
                        return .handled
                    }
                }
            } else if viewModel.isRebuildingExplorer, viewModel.hasVisibleSessions {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Building Explorer Hierarchy…")
                        .appFont(.headline, scale: textScale, weight: .semibold)
                    Text("Grouping captured requests by domain, host, and path.")
                        .appFont(.subheadline, scale: textScale)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Building explorer hierarchy. Grouping captured requests by domain, host, and path.")
            } else {
                sessionEmptyState
            }
        }
        .accessibilityIdentifier("sessionExplorerView")
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isExplorerFocused ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: isExplorerFocused ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var sessionTimelineView: some View {
        SessionTimelineView(
            analysis: viewModel.timelineAnalysisResult,
            filter: $viewModel.timelineFilterState,
            selectedSessionID: selectedSessionBinding,
            isAnalyzing: viewModel.isAnalyzingTimeline,
            pinCount: viewModel.timelinePinCount,
            hasSelectedPin: viewModel.hasSelectedTimelineRequestPin,
            textScale: textScale,
            onToggleSelectedPin: viewModel.toggleTimelinePinForSelectedSession,
            onPinVisibleRange: viewModel.pinTimelineVisibleRange,
            onClearPins: viewModel.clearTimelinePins,
            onClearFilters: viewModel.clearTimelineFilters,
            diagnosticInterlockCoordinator: mcpServerController.diagnosticInterlockCoordinator
        )
    }

    @ViewBuilder
    private var primaryPaneContent: some View {
        switch primaryPaneMode {
        case .sessions:
            switch viewModel.sessionBrowserMode {
            case .table:
                sessionTable
            case .explorer:
                sessionExplorerView
            case .timeline:
                sessionTimelineView
            }
        case .bookmarks:
            bookmarksList
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch primaryPaneMode {
        case .sessions:
            switch recoveryInspectionID != nil && recoveryInspectionID == viewModel.selectedSessionID ? .table : viewModel.sessionBrowserMode {
            case .table, .timeline:
                SessionDetailView(
                    session: viewModel.selectedSession,
                    contentRevision: viewModel.selectedSessionContentRevision,
                    clientDisplayName: viewModel.deviceDisplayName(for: viewModel.selectedSession?.request.clientAddress),
                    activeFindResultLocation: activeFindResultLocation(for: viewModel.selectedSession),
                    findQuery: activeFindQuery(for: viewModel.selectedSession),
                    findNavigationID: activeFindNavigationID(for: viewModel.selectedSession),
                    requestFindMatchContext: findMatchContext(for: viewModel.selectedSession, location: .requestBody),
                    responseFindMatchContext: findMatchContext(for: viewModel.selectedSession, location: .responseBody),
                    findDebugLoggingEnabled: viewModel.isFindDebugLoggingEnabled,
                    onAddBookmark: { session in
                        viewModel.addBookmark(from: session)
                        primaryPaneMode = .bookmarks
                    },
                    onMapLocal: { session in
                        startMapLocal(for: session)
                    },
                    onOpenMediaInfo: { session in
                        openMediaInfoWindow(for: session)
                    },
                    onOpenHelpTopic: { topic in
                        openHelpWindow(topic: topic)
                    },
                    diagnosticInterlockCoordinator: mcpServerController.diagnosticInterlockCoordinator,
                    openAPISchemaStore: viewModel.openAPISchemaStore
                )
            case .explorer:
                if let selectedExplorerNode, selectedExplorerNode.isFolder {
                    ExplorerFolderDetailView(
                        node: selectedExplorerNode,
                        sessionSummaries: viewModel.explorerSessionSummaries(for: selectedExplorerNode.id),
                        grouping: viewModel.sessionExplorerGrouping,
                        onSelectSession: { sessionID in
                            selectExplorerLeaf(for: sessionID)
                        },
                        onAddBookmark: { sessionID in
                            guard let session = viewModel.visibleSession(for: sessionID) else {
                                return
                            }
                            viewModel.addBookmark(from: session)
                            primaryPaneMode = .bookmarks
                        }
                    )
                } else {
                    let detailSession = selectedExplorerLeafSession ?? viewModel.selectedSession
                    SessionDetailView(
                        session: detailSession,
                        contentRevision: viewModel.selectedSessionContentRevision,
                        clientDisplayName: viewModel.deviceDisplayName(for: detailSession?.request.clientAddress),
                        activeFindResultLocation: activeFindResultLocation(for: detailSession),
                        findQuery: activeFindQuery(for: detailSession),
                        findNavigationID: activeFindNavigationID(for: detailSession),
                        requestFindMatchContext: findMatchContext(for: detailSession, location: .requestBody),
                        responseFindMatchContext: findMatchContext(for: detailSession, location: .responseBody),
                        findDebugLoggingEnabled: viewModel.isFindDebugLoggingEnabled,
                        onAddBookmark: { session in
                            viewModel.addBookmark(from: session)
                            primaryPaneMode = .bookmarks
                        },
                        onMapLocal: { session in
                            startMapLocal(for: session)
                        },
                        onOpenMediaInfo: { session in
                            openMediaInfoWindow(for: session)
                        },
                        onOpenHelpTopic: { topic in
                            openHelpWindow(topic: topic)
                        },
                        diagnosticInterlockCoordinator: mcpServerController.diagnosticInterlockCoordinator,
                        openAPISchemaStore: viewModel.openAPISchemaStore
                    )
                }
            }
        case .bookmarks:
            BookmarkDetailView(
                bookmark: viewModel.selectedBookmark,
                canExecute: viewModel.canExecuteSelectedBookmark,
                executionMessage: viewModel.selectedBookmarkExecutionMessage,
                executionState: viewModel.bookmarkExecutionState,
                isProxyRunning: {
                    if case .running = viewModel.proxyState { return true }
                    return false
                }(),
                isResponseRewriteEnabled: viewModel.selectedBookmark.map {
                    viewModel.isBookmarkResponseRewriteEnabled(id: $0.id)
                } ?? false,
                canEnableResponseRewrite: viewModel.selectedBookmark.map {
                    viewModel.canEnableBookmarkResponseRewrite(id: $0.id)
                } ?? false,
                onExecute: { bookmarkID in
                    if await viewModel.executeBookmark(id: bookmarkID) {
                        primaryPaneMode = .sessions
                    }
                },
                onRename: { bookmarkID, name in
                    viewModel.updateBookmarkName(name, for: bookmarkID)
                },
                onUpdateRequest: { bookmarkID, request in
                    viewModel.updateBookmarkRequest(request, for: bookmarkID)
                },
                onDelete: { bookmarkID in
                    viewModel.deleteBookmark(id: bookmarkID)
                },
                onEnableResponseRewrite: { bookmarkID in
                    Task {
                        await viewModel.enableBookmarkResponseRewrite(id: bookmarkID)
                    }
                },
                onDisableResponseRewrite: { bookmarkID in
                    Task {
                        await viewModel.disableBookmarkResponseRewrite(id: bookmarkID)
                    }
                },
                onUpdateResponseMatchMode: { bookmarkID, matchMode in
                    viewModel.updateBookmarkResponseMatchMode(matchMode, for: bookmarkID)
                },
                onAddResponseRewrite: { bookmarkID, path, value, operation, valueInputMode in
                    viewModel.addBookmarkResponseRewrite(
                        jsonPath: path,
                        overrideValue: BookmarkJSONValue.fromUserInput(value, mode: valueInputMode),
                        for: bookmarkID,
                        operation: operation,
                        valueInputMode: valueInputMode
                    )
                },
                onRemoveResponseRewrite: { bookmarkID, rewriteID in
                    viewModel.removeBookmarkResponseRewrite(id: rewriteID, for: bookmarkID)
                },
                onSetResponseRewriteEnabled: { bookmarkID, rewriteID, isEnabled in
                    viewModel.setBookmarkResponseRewriteEnabled(isEnabled, rewriteID: rewriteID, for: bookmarkID)
                },
                onUpdateResponseRewriteOverride: { bookmarkID, rewriteID, value, valueInputMode in
                    viewModel.updateBookmarkResponseRewriteOverride(
                        rewriteID: rewriteID,
                        overrideValueText: value,
                        for: bookmarkID,
                        valueInputMode: valueInputMode
                    )
                },
                onUpdateResponseRewritePath: { bookmarkID, rewriteID, path in
                    viewModel.updateBookmarkResponseRewritePath(
                        rewriteID: rewriteID,
                        jsonPath: path,
                        for: bookmarkID
                    )
                },
                onSetResponseRewriteOperation: { bookmarkID, rewriteID, operation in
                    viewModel.setBookmarkResponseRewriteOperation(
                        operation,
                        rewriteID: rewriteID,
                        for: bookmarkID
                    )
                },
                responseRewriteApplicability: viewModel.selectedBookmark.flatMap {
                    viewModel.bookmarkResponseRewriteApplicability(for: $0.id)
                },
                responseRewriteActivity: viewModel.selectedBookmark.flatMap {
                    viewModel.bookmarkResponseRewriteActivity(for: $0.id)
                },
                trafficHints: viewModel.selectedBookmark.map {
                    viewModel.bookmarkResponseRewriteTrafficHints(for: $0.id)
                } ?? [],
                savedResponseRefreshCandidate: viewModel.selectedBookmark.flatMap {
                    viewModel.bookmarkSavedResponseRefreshCandidate(for: $0.id)
                },
                onRefreshSavedResponse: { bookmarkID in
                    viewModel.refreshBookmarkSavedResponseFromLatestMatchingSession(id: bookmarkID)
                },
                onClearSavedResponse: { bookmarkID in
                    viewModel.clearBookmarkSavedResponse(for: bookmarkID)
                },
                onOpenResponseRewriteHelp: {
                    openHelpWindow(topic: .bookmarkResponseRewrites)
                }
            )
        }
    }

    private func activeFindResultLocation(for session: SessionRecord?) -> SessionFindResult.MatchLocation? {
        guard let session else {
            logFind("No active find target because detail session is nil")
            return nil
        }
        guard viewModel.activeFindResultSessionID == session.id else {
            logFind("Ignoring active find target for visible session \(session.id.uuidString); active session is \(viewModel.activeFindResultSessionID?.uuidString ?? "nil")")
            return nil
        }
        guard let location = viewModel.activeFindResultLocation else {
            logFind("Ignoring active find target for session \(session.id.uuidString); active location is nil")
            return nil
        }
        guard viewModel.sessionFindResults.contains(where: { $0.sessionID == session.id && $0.location == location }) else {
            logFind("Ignoring active find target for session \(session.id.uuidString); no current result at \(location.rawValue)")
            return nil
        }
        logFind("Active find target accepted session=\(session.id.uuidString) location=\(location.rawValue) query='\(viewModel.sessionFindQuery)'")
        return location
    }

    private func activeFindQuery(for session: SessionRecord?) -> String? {
        guard activeFindResultLocation(for: session) != nil else {
            return nil
        }
        let trimmedQuery = viewModel.sessionFindQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedQuery.isEmpty ? nil : trimmedQuery
    }

    private func activeFindNavigationID(for session: SessionRecord?) -> UUID? {
        guard activeFindResultLocation(for: session) != nil else {
            return nil
        }
        return viewModel.activeFindNavigationID
    }

    private func findMatchContext(
        for session: SessionRecord?,
        location: SessionFindResult.MatchLocation
    ) -> SessionFindBodyMatchContext? {
        viewModel.sessionFindBodyMatchContext(for: session?.id, location: location)
    }

    private func logFind(_ message: String) {
        guard viewModel.isFindDebugLoggingEnabled else { return }
        debugPrint("Find debug: \(message)")
    }

    private var capturedSessionsHelpButton: some View {
        ContextHelpButton(
            accessibilityLabel: "Captured sessions help",
            accessibilityHint: "Explains captured sessions, browser modes, filters, and inspection flow.",
            accessibilityIdentifier: "capturedSessionsHelpButton"
        ) {
            helpPopoverContent(
                title: "Captured Sessions",
                summary: "Captured Sessions is the main live workspace for reviewing traffic that passed through JoesProxy.",
                topic: .capturedSessions,
                highlights: [
                    "Use Table for a dense chronological list and Explorer for grouped navigation by host and path.",
                    "Search, filters, sorting, and Follow Live help narrow the active traffic set quickly.",
                    "Select a session to inspect summaries, headers, bodies, timing, and any limits such as tunneling or truncation."
                ]
            )
        }
    }

    private var bookmarksHelpButton: some View {
        ContextHelpButton(
            accessibilityLabel: "Bookmarks help",
            accessibilityHint: "Explains saved bookmarks, replay, and update-from-session workflows.",
            accessibilityIdentifier: "bookmarksHelpButton"
        ) {
            helpPopoverContent(
                title: "Bookmarks",
                summary: "Bookmarks save repeatable requests and can mock JSON responses with field rewrites for the current proxy session.",
                topic: .bookmarksReplay,
                highlights: [
                    "Create bookmarks from captured sessions when you want a durable request template.",
                    "Use Refresh Auth or Update From Session to pull in newer cookies, tokens, headers, or query values from matching traffic.",
                    "Run Selected sends the bookmarked request back through JoesProxy so it appears in the same session workspace.",
                    "Response Rewrites serve the bookmark's saved JSON with field overrides when matching traffic is enabled for the session."
                ]
            )
        }
    }

    private var localOverridesHelpButton: some View {
        ContextHelpButton(
            accessibilityLabel: "Local overrides help",
            accessibilityHint: "Explains temporary local overrides and how they affect request handling.",
            accessibilityIdentifier: "localOverridesHelpButton"
        ) {
            helpPopoverContent(
                title: "Local Overrides",
                summary: "Local Overrides replace an upstream response with local content so you can mock or debug behavior without changing the live service.",
                topic: .localOverrides,
                highlights: [
                    "Map Local creates a temporary override from the selected captured session.",
                    "Overrides are useful when you need a repeatable local response while keeping the rest of the app pointed at the same endpoint.",
                    "Use the Local Overrides list to inspect, disable, or remove active rules."
                ]
            )
        }
    }

    private var exportHelpButton: some View {
        ContextHelpButton(
            accessibilityLabel: "Export help",
            accessibilityHint: "Explains recording export formats and what data may be shared.",
            accessibilityIdentifier: "exportHelpButton"
        ) {
            helpPopoverContent(
                title: "Export",
                summary: "JoesProxy can export the current session set for collaboration, archive, or interop workflows.",
                topic: .exportPrivacy,
                highlights: [
                    "JSON exports preserve the JoesProxy recording model for reopen and deeper analysis.",
                    "HAR exports are for tool interoperability and may not preserve JoesProxy-specific state exactly.",
                    "Exports can include sensitive headers and bodies, so review the selected scope before sharing files."
                ]
            )
        }
    }

    @ViewBuilder
    private func helpPopoverContent(
        title: String,
        summary: String,
        topic: MainWindowHelpTopic,
        highlights: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .appFont(.headline, scale: textScale, weight: .semibold)

            Text(summary)
                .appFont(.body, scale: textScale)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(highlights, id: \.self) { highlight in
                    Label {
                        Text(highlight)
                            .appFont(.caption, scale: textScale)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .appFont(.caption2, scale: textScale)
                            .foregroundStyle(.secondary)
                    }
                    .labelStyle(.titleAndIcon)
                }
            }

            Divider()

            Button("Open Current Screen Help") {
                openHelpWindow(topic: topic)
            }
            .buttonStyle(.link)
            .accessibilityHint("Opens the help window for this topic.")
        }
        .frame(width: 320, alignment: .leading)
        .padding(14)
    }

    private func toggleProxy() {
        if viewModel.canStartProxy {
            log("Start proxy requested from toolbar")
            viewModel.startProxy()
        } else if viewModel.canStopProxy {
            log("Stop proxy requested from toolbar")
            viewModel.stopProxy()
        }
    }

    private var networkThrottlingEnabledBinding: Binding<Bool> {
        Binding {
            viewModel.networkThrottleConfiguration.isEnabled
        } set: { isEnabled in
            viewModel.setNetworkThrottlingEnabled(isEnabled)
        }
    }

    private var networkThrottlePresetBinding: Binding<String> {
        Binding {
            viewModel.networkThrottleConfiguration.selectedPresetID
        } set: { presetID in
            viewModel.selectNetworkThrottlePreset(id: presetID)
        }
    }

    @ViewBuilder
    private var sessionEmptyState: some View {
        if viewModel.hasActiveSessionFilters && viewModel.filteredOutSessionCount > 0 {
            ContentUnavailableView {
                Label("No Matching Sessions", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No sessions match the active filters (\(viewModel.filteredOutSessionCount) hidden).")
            } actions: {
                Button("Clear Filters") {
                    clearSessionFiltersWithNotice()
                }
                .accessibilityIdentifier("clearSessionFiltersEmptyStateButton")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("sessionEmptyStateNoMatches")
        } else {
            ContentUnavailableView {
                Label(viewModel.isProxyRunningNow ? "Waiting for traffic" : "No Traffic Captured Yet", systemImage: "tray")
            } description: {
                Text(viewModel.isProxyRunningNow ? "Captured requests will appear here." : "Start capture or import a recording to begin.")
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("sessionEmptyStatePlaceholder")
        }
    }

    private var bookmarksList: some View {
        Group {
            if viewModel.hasBookmarks {
                List(selection: selectedBookmarkBinding) {
                    ForEach(viewModel.bookmarks) { bookmark in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(.blue)
                                    .accessibilityHidden(true)

                                Text(bookmark.name)
                                    .appFont(.headline, scale: textScale, weight: .semibold)
                                    .lineLimit(1)

                                Spacer(minLength: 8)

                                if case .executing(let bookmarkID) = viewModel.bookmarkExecutionState,
                                   bookmarkID == bookmark.id {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Button {
                                        viewModel.selectedBookmarkID = bookmark.id
                                        Task {
                                            if await viewModel.executeBookmark(id: bookmark.id) {
                                                primaryPaneMode = .sessions
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "play.fill")
                                            .appFont(.caption, scale: textScale, weight: .semibold)
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .help("Run this bookmark through JoesProxy.")
                                }

                                if bookmark.enabledResponseRewriteCount > 0 {
                                    let isActive = viewModel.isBookmarkResponseRewriteEnabled(id: bookmark.id)
                                    HStack(spacing: 4) {
                                        Label("\(bookmark.enabledResponseRewriteCount)", systemImage: "pencil.and.outline")
                                            .appFont(.caption2, scale: textScale, weight: .semibold)
                                            .foregroundStyle(isActive ? .green : .orange)
                                        if isActive {
                                            Text("Active")
                                                .appFont(.caption2, scale: textScale, weight: .semibold)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    .accessibilityLabel(
                                        isActive
                                            ? "\(bookmark.enabledResponseRewriteCount) response rewrites, active this session"
                                            : "\(bookmark.enabledResponseRewriteCount) response rewrites configured, not active this session"
                                    )
                                }

                                Text(bookmark.request.method)
                                    .appFont(.caption, scale: textScale, weight: .semibold, design: .monospaced)
                                    .foregroundStyle(.secondary)
                            }

                            Text(bookmark.request.host)
                                .appFont(.subheadline, scale: textScale, weight: .semibold)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Text(bookmark.request.path)
                                .appFont(.caption, scale: textScale, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 4)
                        .tag(bookmark.id)
                        .contextMenu {
                            Button {
                                performRunBookmark(bookmark)
                            } label: {
                                Label("Run Bookmark", systemImage: "play.fill")
                            }

                            Button {
                                performCopyCurl(for: bookmark)
                            } label: {
                                Label("Copy as curl", systemImage: "document.on.document")
                            }

                            Button {
                                _ = viewModel.refreshBookmarkAuthFromLatestMatchingSession(id: bookmark.id)
                            } label: {
                                Label("Refresh Auth From Latest Match", systemImage: "key.horizontal.fill")
                            }

                            Button {
                                startBookmarkUpdate(for: bookmark.id)
                            } label: {
                                Label("Update From Session…", systemImage: "arrow.clockwise.circle")
                            }

                            Divider()

                            Button(role: .destructive) {
                                viewModel.deleteBookmark(id: bookmark.id)
                            } label: {
                                Label("Delete Bookmark", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .accessibilityLabel("Bookmarks")
            } else {
                bookmarksEmptyState
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func bookmarkUpdateBanner(context: ProxyViewModel.BookmarkUpdateContext) -> some View {
        if let bookmark = viewModel.bookmarks.first(where: { $0.id == context.bookmarkID }) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Update Bookmark From Captured Session")
                        .appFont(.subheadline, scale: textScale, weight: .semibold)

                    Text("\(bookmark.name) · \(context.candidateSessionIDs.count) likely match\(context.candidateSessionIDs.count == 1 ? "" : "es")")
                        .appFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let selectedSession = activeSessionSelection {
                    if let limitationMessage = viewModel.bookmarkUpdateLimitationMessage(for: selectedSession.id) {
                        Text(limitationMessage)
                            .appFont(.caption, scale: textScale)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Button("Use Selected Session…") {
                            presentBookmarkMergeSheet(bookmark: bookmark, sourceSession: selectedSession)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else {
                    Text("Select a recent captured request to continue.")
                        .appFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }

                Button("Cancel") {
                    viewModel.cancelBookmarkUpdate()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.orange.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private var bookmarksEmptyState: some View {
        ContentUnavailableView {
            Label("No Bookmarks Yet", systemImage: "bookmark")
        } description: {
            Text("Select a captured session and choose Bookmark Selected to save a request for later.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activeSessionSelection: SessionRecord? {
        guard primaryPaneMode == .sessions else {
            return nil
        }
        if recoveryInspectionID != nil, recoveryInspectionID == viewModel.selectedSessionID {
            return viewModel.selectedSession
        }

        switch viewModel.sessionBrowserMode {
        case .table, .timeline:
            return viewModel.selectedSession
        case .explorer:
            return selectedExplorerLeafSession
        }
    }

    private var suggestedHelpTopic: MainWindowHelpTopic {
        MainWindowHelpResolver.suggestedTopic(
            for: MainWindowHelpContext(
                primaryContext: primaryPaneMode == .sessions ? .sessions : .bookmarks,
                certificateNeedsAttention: shouldShowCertificateRecoveryBanner,
                selectedSessionInspectionKind: activeSessionSelection?.request.inspectionKind,
                hasActiveOverrides: viewModel.activeResponseOverrideCount > 0,
                exportStateIsActive: {
                    if case .idle = viewModel.exportState {
                        return false
                    }
                    return true
                }(),
                visualizationExportStateIsActive: presentationState.visualizationExportContext != nil
            )
        )
    }

    private var selectedExplorerNode: SessionExplorerNode? {
        viewModel.sessionExplorerTree.node(id: selectedExplorerNodeID)
    }

    private var selectedExplorerLeafSession: SessionRecord? {
        guard let sessionID = selectedExplorerNode?.summary?.id else {
            return nil
        }

        return viewModel.visibleSession(for: sessionID)
    }

    private func openHelpWindow(topic: MainWindowHelpTopic) {
        presentationState.presentContextualHelp(topic: topic)
        openWindow(id: "contextual-help")
    }

    private func openMediaInfoWindow(for session: SessionRecord) {
        viewModel.pauseFollowLiveForUserInteraction()
        presentationState.presentMediaInfo(sessionID: session.id)
        openWindow(id: "media-info")
    }

    private func preserveInspectorSplitAcrossBrowserModeChange() {
        let preservedFraction = viewModel.sessionInspectorSplitFraction
        isSuppressingInspectorSplitCapture = true
        restoreInspectorSplitTask?.cancel()
        restoreInspectorSplitTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }

            viewModel.sessionInspectorSplitFraction = preservedFraction
            await Task.yield()
            await Task.yield()
            isSuppressingInspectorSplitCapture = false
            restoreInspectorSplitTask = nil
        }
    }

    private func reconcileExplorerSelection() {
        let explorerTree = viewModel.sessionExplorerTree
        guard !explorerTree.isEmpty else {
            selectedExplorerNodeID = nil
            return
        }

        if let selectedExplorerNodeID, let selectedNode = explorerTree.node(id: selectedExplorerNodeID) {
            viewModel.expandExplorerAncestors(selectedNode.ancestorIDs)
            return
        }

        if let selectedSessionID = viewModel.selectedSession?.id,
           let leafNodeID = explorerTree.leafNodeID(for: selectedSessionID),
           let leafNode = explorerTree.node(id: leafNodeID) {
            selectedExplorerNodeID = leafNodeID
            viewModel.expandExplorerAncestors(leafNode.ancestorIDs)
            return
        }

        selectedExplorerNodeID = explorerTree.roots.first?.id
    }

    private func syncExplorerSelectionToSessionSelection() {
        guard primaryPaneMode == .sessions, viewModel.sessionBrowserMode == .explorer else {
            return
        }

        if let selectedExplorerNode, selectedExplorerNode.isFolder {
            return
        }

        guard let selectedSessionID = viewModel.selectedSession?.id,
              let leafNodeID = viewModel.sessionExplorerTree.leafNodeID(for: selectedSessionID),
              let leafNode = viewModel.sessionExplorerTree.node(id: leafNodeID) else {
            return
        }

        if selectedExplorerNodeID != leafNodeID {
            selectedExplorerNodeID = leafNodeID
        }
        viewModel.expandExplorerAncestors(leafNode.ancestorIDs)
    }

    private func handleExplorerSelectionChange(_ node: SessionExplorerNode) {
        viewModel.expandExplorerAncestors(node.ancestorIDs)

        guard let sessionID = node.summary?.id else {
            return
        }

        synchronizeSelectedSessionFromExplorer(sessionID)
    }

    private func selectExplorerLeaf(for sessionID: SessionRecord.ID) {
        guard let leafNodeID = viewModel.sessionExplorerTree.leafNodeID(for: sessionID),
              let leafNode = viewModel.sessionExplorerTree.node(id: leafNodeID) else {
            return
        }

        viewModel.expandExplorerAncestors(leafNode.ancestorIDs)
        selectedExplorerNodeID = leafNodeID
        synchronizeSelectedSessionFromExplorer(sessionID)
    }

    private func synchronizeSelectedSessionFromExplorer(_ sessionID: SessionRecord.ID) {
        guard viewModel.selectedSessionID != sessionID else {
            return
        }

        Task { @MainActor in
            guard viewModel.selectedSessionID != sessionID else {
                return
            }

            viewModel.selectSessionFromUser(sessionID)
        }
    }

    private func scheduleExplorerSelectionSync() {
        explorerSelectionSyncTask?.cancel()
        explorerSelectionSyncTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            reconcileExplorerSelection()
            syncExplorerSelectionToSessionSelection()
            explorerSelectionSyncTask = nil
        }
    }

    private func scheduleExplorerSelectionChange(_ nodeID: String?) {
        explorerSelectionChangeTask?.cancel()
        explorerSelectionChangeTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            if let selectedNode = viewModel.sessionExplorerTree.node(id: nodeID) {
                handleExplorerSelectionChange(selectedNode)
            }
            explorerSelectionChangeTask = nil
        }
    }

    private func explorerSession(for sessionID: SessionRecord.ID) -> SessionRecord? {
        viewModel.visibleSession(for: sessionID)
    }

    private func explorerSession(for node: SessionExplorerNode) -> SessionRecord? {
        guard let sessionID = node.summary?.id else {
            return nil
        }

        return explorerSession(for: sessionID)
    }

    private func startBookmarkUpdate(for bookmarkID: Bookmark.ID) {
        bookmarkMergeSheetContext = nil
        primaryPaneMode = .sessions
        viewModel.sessionBrowserMode = .table
        viewModel.beginBookmarkUpdate(id: bookmarkID)
    }

    private func presentBookmarkMergeSheet(bookmark: Bookmark, sourceSession: SessionRecord) {
        bookmarkMergeSheetContext = BookmarkMergeSheetContext(
            bookmark: bookmark,
            sourceSession: sourceSession
        )
    }

    private func startMapLocal(for session: SessionRecord) {
        if let limitationMessage = viewModel.mapLocalLimitationMessage(for: session) {
            viewModel.lastErrorMessage = limitationMessage
            return
        }

        mapLocalSheetContext = MapLocalSheetContext(session: session)
    }

    private func explorerNodeRow(_ node: SessionExplorerNode, depth: Int) -> some View {
        let isSelected = selectedExplorerNodeID == node.id
        let indent = CGFloat(depth) * 16

        return HStack(spacing: 8) {
            Color.clear
                .frame(width: indent, height: 1)
                .accessibilityHidden(true)

            if node.isFolder {
                Button {
                    toggleExplorerNodeExpansion(node.id)
                } label: {
                    Image(systemName: viewModel.sessionExplorerExpandedNodeIDs.contains(node.id) ? "chevron.down" : "chevron.right")
                        .appFont(.caption, scale: textScale, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .frame(width: explorerDisclosureTargetSize, height: explorerDisclosureTargetSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(viewModel.sessionExplorerExpandedNodeIDs.contains(node.id) ? "Collapse \(node.title)." : "Expand \(node.title).")
                .accessibilityLabel(viewModel.sessionExplorerExpandedNodeIDs.contains(node.id) ? "Collapse group" : "Expand group")
                .accessibilityHint("Toggles the contents of \(node.title).")
            } else {
                Color.clear
                    .frame(width: explorerDisclosureTargetSize, height: explorerDisclosureTargetSize)
                    .accessibilityHidden(true)
            }

            Group {
                if node.isFolder {
                    explorerFolderLabel(node)
                } else if let summary = node.summary {
                    explorerLeafLabel(summary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, explorerRowHorizontalPadding)
        .padding(.vertical, explorerRowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.16)
                        : Color.clear
                )
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedExplorerNodeID = node.id
            if node.isFolder {
                toggleExplorerNodeExpansion(node.id)
            } else if let sessionID = node.summary?.id {
                viewModel.selectSessionFromUser(sessionID)
                if workspaceWindowTier == .focused {
                    workspacePaneFocus = .detail
                }
            }
        }
        .contextMenu {
            if let session = explorerSession(for: node) {
                Button {
                    performMapLocal(for: session)
                } label: {
                    Label("Map Local…", systemImage: "arrow.triangle.branch")
                }
                .disabled(!viewModel.canCreateResponseOverride(from: session))

                if viewModel.canReplaceWithHLSTestStream(session) {
                    Button {
                        performHLSTestStream(for: session)
                    } label: {
                        Label("Replace with Test Stream…", systemImage: "play.rectangle.on.rectangle")
                    }
                }

                Button {
                    performAddBookmark(for: session)
                } label: {
                    Label("Add to Bookmarks", systemImage: "bookmark")
                }

                Button {
                    presentationState.presentMCPManagement(destination: .agentRuns)
                } label: {
                    Label("Create Agent Run…", systemImage: "waveform.path.ecg")
                }

                Button {
                    performCopyCurl(for: session)
                } label: {
                    Label("Copy as curl", systemImage: "document.on.document")
                }

                Button {
                    performCopySwiftMock(for: session)
                } label: {
                    Label("Copy as Swift Mock (Mocker)", systemImage: "curlybraces")
                }
            }
        }
        .help(explorerHelpText(for: node))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(explorerAccessibilityLabel(for: node))
        .accessibilityValue(explorerAccessibilityValue(for: node, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(named: "Select") {
            selectExplorerNodeFromUser(node)
        }
        .accessibilityAction(named: viewModel.sessionExplorerExpandedNodeIDs.contains(node.id) ? "Collapse" : "Expand") {
            toggleExplorerNodeExpansion(node.id)
        }
    }

    private enum ExplorerNavigationDirection {
        case up
        case down
        case expandOrDescend
        case collapseOrAscend
    }

    private func navigateExplorer(direction: ExplorerNavigationDirection, scrollProxy: ScrollViewProxy) {
        let visibleRows = viewModel.sessionExplorerVisibleRows
        guard !visibleRows.isEmpty else { return }

        let currentIndex = visibleRows.firstIndex { $0.node.id == selectedExplorerNodeID }

        switch direction {
        case .up:
            if let currentIndex, currentIndex > 0 {
                let targetID = visibleRows[currentIndex - 1].node.id
                selectAndScrollExplorerNode(targetID, scrollProxy: scrollProxy)
            } else if let firstID = visibleRows.first?.node.id {
                selectAndScrollExplorerNode(firstID, scrollProxy: scrollProxy)
            }

        case .down:
            if let currentIndex, currentIndex < visibleRows.count - 1 {
                let targetID = visibleRows[currentIndex + 1].node.id
                selectAndScrollExplorerNode(targetID, scrollProxy: scrollProxy)
            } else if let firstID = visibleRows.first?.node.id {
                selectAndScrollExplorerNode(firstID, scrollProxy: scrollProxy)
            }

        case .expandOrDescend:
            guard let selectedID = selectedExplorerNodeID,
                  let node = viewModel.sessionExplorerTree.node(id: selectedID) else { return }

            if node.isFolder {
                if !viewModel.sessionExplorerExpandedNodeIDs.contains(node.id) {
                    toggleExplorerNodeExpansion(node.id)
                } else if let currentIndex, currentIndex < visibleRows.count - 1 {
                    let nextRow = visibleRows[currentIndex + 1]
                    if nextRow.depth > visibleRows[currentIndex].depth {
                        selectAndScrollExplorerNode(nextRow.node.id, scrollProxy: scrollProxy)
                    }
                }
            } else if workspaceWindowTier == .focused {
                enterFocusedDetail()
            }

        case .collapseOrAscend:
            guard let selectedID = selectedExplorerNodeID,
                  let node = viewModel.sessionExplorerTree.node(id: selectedID) else { return }

            if node.isFolder && viewModel.sessionExplorerExpandedNodeIDs.contains(node.id) {
                toggleExplorerNodeExpansion(node.id)
            } else if let parentID = node.ancestorIDs.last {
                selectAndScrollExplorerNode(parentID, scrollProxy: scrollProxy)
            }
        }
    }

    private func selectAndScrollExplorerNode(_ nodeID: String, scrollProxy: ScrollViewProxy) {
        selectedExplorerNodeID = nodeID
        if let sessionID = viewModel.sessionExplorerTree.node(id: nodeID)?.summary?.id {
            viewModel.selectSessionFromUser(sessionID)
        }
        scrollProxy.scrollTo(nodeID, anchor: .center)
    }

    private func selectExplorerNodeFromUser(_ node: SessionExplorerNode) {
        selectedExplorerNodeID = node.id
        if let sessionID = node.summary?.id {
            viewModel.selectSessionFromUser(sessionID)
        }
    }

    private func activateSelectedExplorerNode() {
        guard let selectedID = selectedExplorerNodeID,
              let node = viewModel.sessionExplorerTree.node(id: selectedID) else { return }

        if node.isFolder {
            toggleExplorerNodeExpansion(node.id)
        } else if let sessionID = node.summary?.id {
            viewModel.selectSessionFromUser(sessionID)
            if workspaceWindowTier == .focused {
                workspacePaneFocus = .detail
            }
        }
    }

    private func toggleExplorerNodeExpansion(_ nodeID: String) {
        if viewModel.sessionExplorerExpandedNodeIDs.contains(nodeID) {
            viewModel.sessionExplorerExpandedNodeIDs.remove(nodeID)
        } else {
            viewModel.sessionExplorerExpandedNodeIDs.insert(nodeID)
        }
    }

    private func explorerAccessibilityValue(for node: SessionExplorerNode, isSelected: Bool) -> String {
        if node.isFolder {
            let isExpanded = viewModel.sessionExplorerExpandedNodeIDs.contains(node.id)
            let expansionState = isExpanded ? "Expanded" : "Collapsed"
            let countDescription = "\(node.aggregateCount) requests"
            if isSelected {
                return "\(expansionState), selected, \(countDescription)"
            }
            return "\(expansionState), \(countDescription)"
        } else {
            return isSelected ? "Selected" : ""
        }
    }

    private func explorerFolderLabel(_ node: SessionExplorerNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: explorerFolderIconName(for: node))
                .appFont(.caption, scale: textScale)
                .foregroundStyle(explorerFolderIconTint(for: node))

            Text(node.title)
                .appFont(.subheadline, scale: textScale, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("\(node.aggregateCount)")
                .appFont(.caption, scale: textScale, design: .monospaced)
                .foregroundStyle(.secondary)

            if node.failedCount > 0 {
                Text("\(node.failedCount) failed")
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func explorerLeafLabel(_ summary: SessionSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: sessionIconName(for: summary))
                .appFont(.caption, scale: textScale)
                .foregroundStyle(sessionIconTint(for: summary))

            RequestMethodBadge(method: summary.method, scale: textScale)

            overrideBadge(for: overrideSource(summary))
            mcpAttributionBadge(for: summary.mcpAttribution)

            Spacer(minLength: 8)

            Text(summary.startedAt.formatted(date: .omitted, time: .shortened))
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)

            Text(statusText(for: summary))
                .appFont(.caption, scale: textScale, weight: .semibold, design: .monospaced)
                .foregroundStyle(statusColor(for: summary))

            Text(durationText(for: summary))
                .appFont(.caption, scale: textScale, design: .monospaced)
                .foregroundStyle(.secondary)
        }
    }

    private func explorerAccessibilityLabel(for node: SessionExplorerNode) -> String {
        if let summary = node.summary {
            let overrideSuffix = overrideAccessibilitySuffix(for: overrideSource(summary))
            let mcpSuffix = mcpAttributionAccessibilitySuffix(for: summary.mcpAttribution)
            return "\(summary.method) \(summary.host) \(summary.path) \(statusText(for: summary)) \(durationText(for: summary)).\(overrideSuffix)\(mcpSuffix)"
        }

        let failureLabel = node.failedCount > 0 ? ", \(node.failedCount) failed" : ""
        return "\(node.title), \(node.aggregateCount) requests\(failureLabel)"
    }

    private func explorerHelpText(for node: SessionExplorerNode) -> String {
        if let summary = node.summary {
            let overrideSuffix = overrideAccessibilitySuffix(for: overrideSource(summary))
            let mcpSuffix = mcpAttributionAccessibilitySuffix(for: summary.mcpAttribution)
            return "\(summary.method) \(summary.host)\(summary.path). \(statusText(for: summary)). Duration \(durationText(for: summary)).\(overrideSuffix)\(mcpSuffix)"
        }

        let failureLabel = node.failedCount > 0 ? "\(node.failedCount) failed, " : ""
        return "\(node.title). \(failureLabel)\(node.aggregateCount) requests in this group."
    }

    private func explorerFolderIconName(for node: SessionExplorerNode) -> String {
        switch node.role {
        case .domainFamily:
            return "square.stack.3d.up.fill"
        case .host:
            return "globe"
        case .path:
            return "folder.fill"
        case .request:
            return "circle.fill"
        }
    }

    private func explorerFolderIconTint(for node: SessionExplorerNode) -> Color {
        switch node.role {
        case .domainFamily:
            return .teal
        case .host:
            return .blue
        case .path, .request:
            return .secondary
        }
    }

    @ViewBuilder
    private var sessionFilterControls: some View {
        SessionFilterControlsView(
            searchText: $viewModel.sessionSearchText,
            domainFilterText: Binding(
                get: { viewModel.sessionFilterCriteria.hostContains },
                set: { viewModel.sessionFilterCriteria.hostContains = $0 }
            ),
            methodFilter: methodFilterBinding,
            schemeFilter: schemeFilterBinding,
            inspectionFilter: inspectionFilterBinding,
            statusFilter: statusFilterBinding,
            sourceFilter: sourceFilterBinding,
            deviceFilterIP: Binding(
                get: { viewModel.sessionFilterCriteria.clientAddressMatch },
                set: { viewModel.sessionFilterCriteria.clientAddressMatch = $0 }
            ),
            discoveredDevices: viewModel.discoveredDevices,
            onManageDevices: { presentationState.isDeviceAliasManagerPresented = true },
            controlSize: filterControlSize,
            searchFieldMinimumWidth: searchFieldMinimumWidth,
            searchFieldIdealWidth: searchFieldIdealWidth,
            searchFieldMaximumWidth: searchFieldMaximumWidth,
            domainFilterMinimumWidth: domainFilterMinimumWidth,
            domainFilterIdealWidth: domainFilterIdealWidth,
            domainFilterMaximumWidth: domainFilterMaximumWidth,
            methodFilterWidth: scaledWidth(128),
            schemeFilterWidth: scaledWidth(112),
            inspectionFilterWidth: scaledWidth(168),
            statusFilterWidth: scaledWidth(148),
            sourceFilterWidth: scaledWidth(128)
        )
    }

    private var filterControlSize: ControlSize {
        switch viewModel.appTextSize {
        case .small, .standard, .large:
            return .regular
        case .extraLarge, .accessibility:
            return .large
        }
    }

    private var searchFieldMinimumWidth: CGFloat {
        scaledWidth(210)
    }

    private var searchFieldIdealWidth: CGFloat {
        scaledWidth(300)
    }

    private var searchFieldMaximumWidth: CGFloat {
        scaledWidth(360)
    }

    private var primaryPanePickerWidth: CGFloat {
        scaledWidth(188)
    }

    private var sessionBrowserPickerWidth: CGFloat {
        scaledWidth(244)
    }

    private var domainFilterMinimumWidth: CGFloat {
        scaledWidth(132)
    }

    private var domainFilterIdealWidth: CGFloat {
        scaledWidth(180)
    }

    private var domainFilterMaximumWidth: CGFloat {
        scaledWidth(220)
    }

    private var explorerDisclosureTargetSize: CGFloat {
        switch viewModel.appTextSize {
        case .small:
            return 22
        case .standard:
            return 24
        case .large:
            return 26
        case .extraLarge:
            return 28
        case .accessibility:
            return 32
        }
    }

    private var explorerRowVerticalPadding: CGFloat {
        switch viewModel.appTextSize {
        case .small:
            return 2
        case .standard:
            return 3
        case .large:
            return 4
        case .extraLarge:
            return 5
        case .accessibility:
            return 7
        }
    }

    private var explorerRowHorizontalPadding: CGFloat {
        switch viewModel.appTextSize {
        case .small, .standard:
            return 8
        case .large:
            return 9
        case .extraLarge:
            return 10
        case .accessibility:
            return 12
        }
    }

    private var tableRowMinHeight: CGFloat {
        switch viewModel.appTextSize {
        case .small:
            return 22
        case .standard:
            return 24
        case .large:
            return 28
        case .extraLarge:
            return 32
        case .accessibility:
            return 38
        }
    }

    private var tableCellVerticalPadding: CGFloat {
        switch viewModel.appTextSize {
        case .small:
            return 1
        case .standard:
            return 1
        case .large:
            return 2
        case .extraLarge:
            return 3
        case .accessibility:
            return 4
        }
    }

    private var tableMethodColumnWidth: CGFloat {
        switch viewModel.appTextSize {
        case .small:
            return 70
        case .standard:
            return 78
        case .large:
            return 88
        case .extraLarge:
            return 98
        case .accessibility:
            return 110
        }
    }

    private var tableSourceColumnWidth: CGFloat {
        switch viewModel.appTextSize {
        case .small:
            return 72
        case .standard:
            return 82
        case .large:
            return 92
        case .extraLarge:
            return 102
        case .accessibility:
            return 116
        }
    }

    private var tableTimeColumnWidth: CGFloat {
        switch viewModel.appTextSize {
        case .small:
            return 64
        case .standard:
            return 72
        case .large:
            return 80
        case .extraLarge:
            return 90
        case .accessibility:
            return 102
        }
    }

    private var tableSizeColumnWidth: CGFloat {
        switch viewModel.appTextSize {
        case .small:
            return 60
        case .standard:
            return 68
        case .large:
            return 76
        case .extraLarge:
            return 84
        case .accessibility:
            return 96
        }
    }

    @MainActor private static let tableTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func formattedByteSize(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private var tableMediaColumnWidth: CGFloat {
        tableRowMinHeight + (tableCellVerticalPadding * 2)
    }

    private var tableMediaIconSize: CGFloat {
        max(14, tableRowMinHeight - 8)
    }

    @ViewBuilder
    private func tableCell<Content: View>(
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, minHeight: tableRowMinHeight, alignment: tableCellAlignment(for: alignment))
        .padding(.vertical, tableCellVerticalPadding)
    }

    private func tableCellAlignment(for alignment: HorizontalAlignment) -> Alignment {
        switch alignment {
        case .center:
            return .center
        case .trailing:
            return .trailing
        default:
            return .leading
        }
    }

    private var inspectorSectionSpacing: CGFloat {
        switch viewModel.appTextSize {
        case .small:
            return 10
        case .standard:
            return 12
        case .large:
            return 14
        case .extraLarge:
            return 16
        case .accessibility:
            return 18
        }
    }

    private var inspectorDisclosureTopPadding: CGFloat {
        switch viewModel.appTextSize {
        case .small, .standard:
            return 4
        case .large:
            return 5
        case .extraLarge:
            return 6
        case .accessibility:
            return 8
        }
    }

    private var inspectorDisclosureContentSpacing: CGFloat {
        switch viewModel.appTextSize {
        case .small:
            return 6
        case .standard:
            return 8
        case .large:
            return 9
        case .extraLarge:
            return 10
        case .accessibility:
            return 12
        }
    }

    private func scaledWidth(_ base: CGFloat) -> CGFloat {
        base * viewModel.appTextSize.widthMultiplier
    }

    private func sessionForContextMenu(selection selectedIDs: Set<SessionRecord.ID>) -> SessionRecord? {
        let targetID = selectedIDs.first ?? viewModel.selectedSessionID
        guard let targetID else {
            return nil
        }

        return viewModel.filteredSessions.first { $0.id == targetID }
    }

    private var methodFilterBinding: Binding<MethodFilterOption> {
        Binding(
            get: { MethodFilterOption(method: viewModel.sessionFilterCriteria.method) },
            set: { option in
                viewModel.sessionFilterCriteria.method = option.method
            }
        )
    }

    private var schemeFilterBinding: Binding<SchemeFilterOption> {
        Binding(
            get: { SchemeFilterOption(scheme: viewModel.sessionFilterCriteria.scheme) },
            set: { option in
                viewModel.sessionFilterCriteria.scheme = option.scheme
            }
        )
    }

    private var statusFilterBinding: Binding<StatusFilterOption> {
        Binding(
            get: { StatusFilterOption(match: viewModel.sessionFilterCriteria.statusMatch) },
            set: { option in
                viewModel.sessionFilterCriteria.statusMatch = option.match
            }
        )
    }

    private var inspectionFilterBinding: Binding<InspectionFilterOption> {
        Binding(
            get: { InspectionFilterOption(inspectionMatch: viewModel.sessionFilterCriteria.inspectionMatch) },
            set: { option in
                viewModel.sessionFilterCriteria.inspectionMatch = option.inspectionMatch
            }
        )
    }

    private var sourceFilterBinding: Binding<SourceFilterOption> {
        Binding(
            get: { SourceFilterOption(source: viewModel.sessionFilterCriteria.sourceMatch) },
            set: { option in
                viewModel.sessionFilterCriteria.sourceMatch = option.source
            }
        )
    }

    private var sessionCountSummaryText: String {
        if viewModel.hasActiveSessionFilters {
            return "\(viewModel.filteredSessionCount) of \(viewModel.sessionCount)"
        }

        return "\(viewModel.sessionCount)"
    }

    private var sessionCountSummaryAccessibilityLabel: String {
        if viewModel.hasActiveSessionFilters {
            return "\(viewModel.filteredSessionCount) visible sessions out of \(viewModel.sessionCount) total"
        }

        return "\(viewModel.sessionCount) captured sessions"
    }

    private func exportSessions(scope: ExportScope, format: ProxyViewModel.ExportFormat) {
        let ext = format == .har ? "har" : "json"
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .json]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = defaultExportFileName(for: scope, format: format)
        savePanel.title = scope == .all ? "Export Sessions" : "Export Selected Session"
        savePanel.message = "Exported files may include sensitive headers such as Authorization and Cookie."

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else {
            return
        }

        Task {
            do {
                switch scope {
                case .all:
                    try await viewModel.exportAllSessionsInBackground(to: destinationURL, as: format)
                case .selected:
                    try await viewModel.exportSelectedSessionsInBackground(to: destinationURL, as: format)
                }
                workspaceNotices.presentToast("Export complete: \(destinationURL.lastPathComponent)")
            } catch {
                exportAlert = ExportAlertContext(
                    title: "Export Failed",
                    message: NetworkFailureClassifier.userFacingMessage(for: error, surface: .fileExport)
                )
            }
        }
    }

    private func presentVisualizationExport() {
        guard let context = viewModel.makeVisualizationExportPresentationContext() else {
            return
        }
        presentationState.presentVisualizationExport(context: context)
    }

    private func defaultExportFileName(for scope: ExportScope, format: ProxyViewModel.ExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = scope == .all ? "joesproxy-sessions" : "joesproxy-selected-session"
        let ext = format == .har ? "har" : "json"
        return "\(prefix)-\(formatter.string(from: Date())).\(ext)"
    }

    private func log(_ message: String) {
        guard RuntimeDebugFlag.isUILifecycleLoggingEnabled else {
            return
        }
        logger.info("UI lifecycle: \(message, privacy: .public)")
    }

    private func statusText(for session: SessionRecord) -> String {
        if session.request.inspectionKind == .tunneledTLS {
            return "Tunnel"
        }
        if let statusCode = session.response?.statusCode {
            return String(statusCode)
        }
        return "Pending"
    }

    private func statusText(for summary: SessionSummary) -> String {
        if summary.inspectionKind == .tunneledTLS {
            return "Tunnel"
        }
        if let statusCode = summary.statusCode {
            return String(statusCode)
        }
        return "Pending"
    }

    private func statusColor(for session: SessionRecord) -> Color {
        guard let statusCode = session.response?.statusCode else {
            return .secondary
        }
        switch statusCode {
        case 200..<300: return .green
        case 300..<400: return .teal
        case 400..<500: return .orange
        case 500...599: return .red
        default:        return .secondary
        }
    }

    private func statusColor(for summary: SessionSummary) -> Color {
        guard let statusCode = summary.statusCode else {
            return .secondary
        }
        switch statusCode {
        case 200..<300: return .green
        case 300..<400: return .teal
        case 400..<500: return .orange
        case 500...599: return .red
        default:        return .secondary
        }
    }

    private func durationText(for session: SessionRecord) -> String {
        guard let duration = session.timing.duration else {
            return lifecycleText(for: session.state)
        }

        return duration.formatted(.number.precision(.fractionLength(3))) + "s"
    }

    private func overrideAccessibilitySuffix(for source: CapturedResponseSource?) -> String {
        switch source {
        case .localOverride:
            return " Served from local override."
        case .blocked:
            return " Blocked by rule."
        case .mapRemote:
            return " Remapped to different host."
        case .bookmarkRewrite:
            return " Rewritten from bookmark."
        case .bookmarkResponseRewrite:
            return " Served from bookmark response rewrite."
        case .liveResponseRewrite:
            return " Live response rewrite applied to real upstream JSON."
        case .upstream, nil:
            return ""
        }
    }

    private func overrideSource(_ session: SessionRecord) -> CapturedResponseSource? {
        guard let source = session.response?.source, source != .upstream else { return nil }
        return source
    }

    private func overrideSource(_ summary: SessionSummary) -> CapturedResponseSource? {
        guard let source = summary.responseSource, source != .upstream else { return nil }
        return source
    }

    /// Dedicated, always-visible indicator for MCP-originated throttling (ADR: "Throttling
    /// indicator") — independent of the general persistent effect indicator, since throttling
    /// otherwise looks identical to a real slow network and the toolbar toggle alone does not say
    /// who turned it on. Not inside a `Table` row, so `.help()` is safe here.
    @ViewBuilder
    private var mcpThrottleIndicator: some View {
        let configuration = viewModel.networkThrottleConfiguration
        if configuration.isEnabled, configuration.mcpOrigin == .mcp, let provenance = configuration.mcpProvenance {
            let activeDuration = Date().timeIntervalSince(provenance.createdAt)
            Text("MCP")
                .appFont(.caption2, scale: textScale, weight: .bold, design: .monospaced)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(Color.purple))
                .help("Throttling enabled by MCP client \(provenance.clientID), active for \(formattedDuration(activeDuration)).")
                .accessibilityLabel("MCP-enabled network throttling")
                .accessibilityValue("Client \(provenance.clientID), active for \(formattedDuration(activeDuration))")
        }
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    /// Shows independently of `overrideBadge` — a throttled response has MCP attribution but no
    /// `CapturedResponseSource` override, since throttling never changes the response source.
    @ViewBuilder
    private func mcpAttributionBadge(for attribution: MCPCaptureAttribution?) -> some View {
        if let attribution {
            Text("· MCP")
                .appFont(.caption, scale: textScale, weight: .semibold, design: .monospaced)
                .foregroundStyle(Color.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(Color.purple.opacity(0.14)))
                .accessibilityLabel(mcpAttributionAccessibilityLabel(for: attribution))
                // No .help() here: this badge renders inside NSTableView-backed Table rows,
                // and SwiftUI's HelpView attachment crashes AppKit's row-constraint update
                // when cells recycle during a resize ("no common ancestor" NSGenericException).
        }
    }

    /// Attribution preference: scenario over bare client ID (ADR). Scenario attribution is not yet
    /// populated (blocked on AI-1) so this currently always falls back to the sanitized client ID —
    /// the same identifier already shown in the MCP management panel's approval rows, not a secret.
    private func mcpAttributionAccessibilityLabel(for attribution: MCPCaptureAttribution) -> String {
        if let scenarioID = attribution.scenarioID {
            return "MCP test scenario: \(scenarioID)"
        }
        return "MCP client \(attribution.provenance.clientID)"
    }

    private func mcpAttributionAccessibilitySuffix(for attribution: MCPCaptureAttribution?) -> String {
        guard let attribution else { return "" }
        return " \(mcpAttributionAccessibilityLabel(for: attribution))."
    }

    /// Returns a small colored badge for the given override source, or `nil` if the response is from upstream.
    @ViewBuilder
    private func overrideBadge(for source: CapturedResponseSource?) -> some View {
        if let source {
            let (label, color, a11yLabel) = overrideBadgeAppearance(source)
            Text(label)
                .appFont(.caption, scale: textScale, weight: .semibold, design: .monospaced)
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(color.opacity(0.14)))
                .accessibilityLabel(a11yLabel)
        }
    }

    /// A compact badge identifying the traffic source (Mac / Simulator / Device). Hidden when unknown.
    @ViewBuilder
    private func schemeBadge(for scheme: SessionScheme?) -> some View {
        if scheme == .http {
            Text("HTTP")
                .appFont(.caption, scale: textScale, weight: .semibold)
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(Color.orange.opacity(0.14)))
                .accessibilityLabel("Unencrypted HTTP")
                // No .help() here: this badge renders inside NSTableView-backed Table rows,
                // and SwiftUI's HelpView attachment crashes AppKit's row-constraint update
                // when cells recycle during a resize ("no common ancestor" NSGenericException).
        }
    }

    @ViewBuilder
    private func sourceBadge(for source: TrafficSource?) -> some View {
        if let source, source != .unknown {
            let color = sourceBadgeColor(source)
            Text(source.badgeText)
                .appFont(.caption, scale: textScale, weight: .semibold)
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(color.opacity(0.14)))
                .accessibilityLabel("Source: \(source.title)")
                // No .help() — see schemeBadge: tooltips inside Table rows crash on recycle.
        }
    }

    private func sourceBadgeColor(_ source: TrafficSource) -> Color {
        switch source {
        case .mac: return .blue
        case .simulator: return .teal
        case .device: return .green
        case .unknown: return .secondary
        }
    }

    private func overrideBadgeAppearance(_ source: CapturedResponseSource) -> (label: String, color: Color, a11yLabel: String) {
        switch source {
        case .localOverride:
            return ("Local", .purple, "Served from local override")
        case .blocked:
            return ("Blocked", .red, "Blocked by rule")
        case .mapRemote:
            return ("Remapped", .indigo, "Remapped to different host")
        case .bookmarkRewrite:
            return ("Rewrite", .blue, "Rewritten from bookmark")
        case .bookmarkResponseRewrite:
            return ("Bk Response", .teal, "Response served from bookmark snapshot with field overrides")
        case .liveResponseRewrite:
            return ("Live Rewrite", .teal, "Live response JSON rewrite on real upstream traffic")
        case .upstream:
            return ("", .secondary, "")
        }
    }

    private func durationText(for summary: SessionSummary) -> String {
        guard let duration = summary.duration else {
            return lifecycleText(for: summary.state)
        }

        return duration.formatted(.number.precision(.fractionLength(3))) + "s"
    }

    private func mediaSymbolName(for mediaType: MediaType) -> String? {
        switch mediaType {
        case .image:
            return "photo"
        case .hls:
            return "play.tv.fill"
        case .hlsDiscovery:
            return "sparkles.rectangle.stack.fill"
        case .dash:
            return "square.stack.3d.forward.dottedline.fill"
        case .video:
            return "film.fill"
        case .adXml:
            return "doc.text.fill"
        case .none:
            return nil
        }
    }

    private func mediaSymbolTint(for mediaType: MediaType) -> Color {
        switch mediaType {
        case .image:
            return .purple
        case .hls:
            return .blue
        case .hlsDiscovery:
            return .indigo
        case .dash:
            return .orange
        case .video:
            return .pink
        case .adXml:
            return .mint
        case .none:
            return .secondary
        }
    }

    private func mediaDescription(for mediaType: MediaType) -> String {
        switch mediaType {
        case .image:
            return "Image response"
        case .hls:
            return "HLS manifest"
        case .hlsDiscovery:
            return "Manifest discovered from playback API"
        case .dash:
            return "DASH manifest"
        case .video:
            return "Video or media asset"
        case .adXml(let kind):
            return "\(kind.rawValue.uppercased()) ad XML response"
        case .none:
            return "Not a media session"
        }
    }

    private func sessionIconName(for session: SessionRecord) -> String {
        switch session.request.inspectionKind {
        case .plain:
            return "globe"
        case .interceptedTLS:
            return "lock.fill"
        case .tunneledTLS:
            return "lock.slash"
        }
    }

    private func sessionIconName(for summary: SessionSummary) -> String {
        switch summary.inspectionKind {
        case .plain:
            return "globe"
        case .interceptedTLS:
            return "lock.fill"
        case .tunneledTLS:
            return "lock.slash"
        }
    }

    private func sessionIconTint(for session: SessionRecord) -> Color {
        switch session.request.inspectionKind {
        case .plain:
            return .secondary
        case .interceptedTLS:
            return .green
        case .tunneledTLS:
            return .orange
        }
    }

    private func sessionIconTint(for summary: SessionSummary) -> Color {
        switch summary.inspectionKind {
        case .plain:
            return .secondary
        case .interceptedTLS:
            return .green
        case .tunneledTLS:
            return .orange
        }
    }

    private func handleWorkspaceCommand(_ action: WorkspaceCommandAction) {
        switch action {
        case .showSessions:
            primaryPaneMode = .sessions
        case .showBookmarks:
            primaryPaneMode = .bookmarks
        case .showLocalOverrides:
            openWindow(id: TrafficModificationsWindowView.windowID)
        case .showTable:
            primaryPaneMode = .sessions
            viewModel.sessionBrowserMode = .table
        case .showExplorer:
            primaryPaneMode = .sessions
            viewModel.sessionBrowserMode = .explorer
        case .showTimeline:
            primaryPaneMode = .sessions
            viewModel.sessionBrowserMode = .timeline
        case .mapSelectedLocal:
            guard let session = activeSessionSelection else { return }
            performMapLocal(for: session)
        case .replaceSelectedWithHLSTestStream:
            guard let session = activeSessionSelection,
                  viewModel.canReplaceWithHLSTestStream(session) else { return }
            performHLSTestStream(for: session)
        case .newOpenAPIMockPack:
            openAPIMockPackSheetContext = OpenAPIMockPackSheetContext(session: activeSessionSelection)
        case .bookmarkSelectedSession:
            guard let session = activeSessionSelection else { return }
            performAddBookmark(for: session)
        case .copySelectedAsCurl:
            if let session = activeSessionSelection {
                performCopyCurl(for: session)
            } else if let bookmark = viewModel.selectedBookmark {
                performCopyCurl(for: bookmark)
            }
        case .runSelectedBookmark:
            guard let bookmark = viewModel.selectedBookmark else { return }
            performRunBookmark(bookmark)
        case .clearAllSessions:
            if viewModel.clearAllSessions() == .busy {
                presentationState.isClearCaptureBusyPresented = true
            }
        }
    }

    private func performMapLocal(for session: SessionRecord) {
        viewModel.selectSessionFromUser(session.id)
        startMapLocal(for: session)
    }

    private func performHLSTestStream(for session: SessionRecord) {
        viewModel.selectSessionFromUser(session.id)
        hlsTestStreamSheetContext = HLSTestStreamSheetContext(session: session)
    }

    private func performAddBookmark(for session: SessionRecord) {
        viewModel.selectSessionFromUser(session.id)
        viewModel.addBookmark(from: session)
        primaryPaneMode = .bookmarks
    }

    private func performCopyCurl(for session: SessionRecord) {
        viewModel.selectSessionFromUser(session.id)
        copyCurlRequest(for: session.request)
    }

    private func performCopySwiftMock(for session: SessionRecord) {
        viewModel.selectSessionFromUser(session.id)
        let snippet = SwiftMockerExporter.generateSnippet(for: session, framework: .mocker)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
    }

    private func performCopyCurl(for bookmark: Bookmark) {
        viewModel.selectedBookmarkID = bookmark.id
        copyCurlRequest(for: bookmark.request)
    }

    private func performRunBookmark(_ bookmark: Bookmark) {
        viewModel.selectedBookmarkID = bookmark.id
        Task {
            if await viewModel.executeBookmark(id: bookmark.id) {
                primaryPaneMode = .sessions
            }
        }
    }

    private func copyCurlRequest(for request: CapturedRequest) {
        let command = curlCommand(for: request)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func curlCommand(for request: CapturedRequest) -> String {
        let url = MediaDetector.absoluteURL(for: request)?.absoluteString ?? request.path
        var lines: [String] = [
            "curl",
            "--request \(shellQuoted(request.method))",
            shellQuoted(url)
        ]

        for header in request.headers where header.name.caseInsensitiveCompare("Proxy-Connection") != .orderedSame {
            lines.append("--header \(shellQuoted("\(header.name): \(header.value)"))")
        }

        if let bodyData = request.bodyData, !bodyData.isEmpty,
           !CapturedBodyDecoder.isKnownBinaryContentType(headers: request.headers) {
            if let bodyText = String(data: bodyData, encoding: .utf8),
               !bodyText.contains("\n") {
                lines.append("--data-raw \(shellQuoted(bodyText))")
            } else if let bodyText = String(data: bodyData, encoding: .utf8) {
                return """
                \(lines.joined(separator: " \\\n  ")) \\
                  --data-binary @- <<'JOESPROXY_BODY'
                \(bodyText)
                JOESPROXY_BODY
                """
            }
        }

        return lines.joined(separator: " \\\n  ")
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func lifecycleText(for state: SessionLifecycleState) -> String {
        switch state {
        case .pending:
            return "Pending"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Canceled"
        }
    }

    private var proxyFailureMessage: String? {
        guard case .failed(let message) = viewModel.proxyState else {
            return nil
        }

        return message
    }

    private var shouldShowCertificateRecoveryBanner: Bool {
        switch viewModel.certificateWorkflowState {
        case .installedTrustRequired, .needsCleanup:
            return true
        case .notSetUp, .ready:
            return false
        }
    }

    private var exportFailureMessage: String? {
        guard case .failed(let message) = viewModel.exportState else {
            return nil
        }

        return message
    }

    private enum SystemProxyIndicatorState {
        case off
        case armed
        case active(host: String, port: UInt16)
        case failed(String)
    }

    private var systemProxyIndicatorState: SystemProxyIndicatorState {
        switch systemProxyController.status {
        case .active(let host, let port, _):
            return .active(host: host, port: port)
        case .failed(let message):
            return .failed(message)
        case .inactive:
            return routingModel.isRoutingEnabled ? .armed : .off
        }
    }

    @ViewBuilder
    private var systemProxyToolbarIndicator: some View {
        Button {
            isRoutingPopoverPresented = true
        } label: {
            systemProxyIndicatorPill
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isRoutingPopoverPresented, arrowEdge: .bottom) {
            systemProxyRoutingPopover
        }
        .alert(SystemProxyRoutingCopy.consentTitle, isPresented: $routingModel.pendingConsent) {
            Button("Cancel", role: .cancel) { routingModel.cancelConsent() }
            Button("Enable") { routingModel.confirmConsent() }
        } message: {
            Text(routingModel.consentMessage)
        }
    }

    @ViewBuilder
    private var systemProxyIndicatorPill: some View {
        switch systemProxyIndicatorState {
        case .off:
            Label("Mac routing: off", systemImage: "network.slash")
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
                .help("Mac and Simulator traffic is not routed through JoesProxy. Click for details.")
                .accessibilityIdentifier("systemProxyOffIndicator")
        case .armed:
            Label("System proxy: armed", systemImage: "network")
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
                .help("macOS routing is armed and activates when the proxy starts. Click for details.")
                .accessibilityIdentifier("systemProxyArmedIndicator")
        case .active(let host, let port):
            Label {
                Text(verbatim: "System proxy \(host):\(port)")
            } icon: {
                Image(systemName: "network.badge.shield.half.filled")
            }
            .appFont(.caption, scale: textScale)
            .foregroundStyle(.green)
            .help("macOS system proxy is routed through JoesProxy. Click for details.")
            .accessibilityIdentifier("systemProxyActiveIndicator")
        case .failed(let message):
            Label("System proxy error", systemImage: "exclamationmark.triangle.fill")
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.orange)
                .help(message)
                .accessibilityHint(message)
                .accessibilityIdentifier("systemProxyErrorIndicator")
        }
    }

    private var systemProxyRoutingPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS Traffic Routing")
                .font(.headline)

            Toggle("Route macOS traffic through JoesProxy", isOn: Binding(
                get: { routingModel.isRoutingEnabled },
                set: { routingModel.isRoutingEnabled = $0 }
            ))
            .accessibilityIdentifier("systemProxyPopoverToggle")

            Group {
                switch systemProxyIndicatorState {
                case .off:
                    Text("Off. Mac and Simulator traffic is not routed through JoesProxy.")
                case .armed:
                    Text(viewModel.isProxyRunningNow
                        ? "Activating…"
                        : "Armed — routing activates only when you start the proxy in JoesProxy. MCP and CLI starts are blocked.")
                case .active(let host, let port):
                    Text("Active — macOS and Simulator traffic routes through JoesProxy at \(host):\(String(port)).")
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(routingModel.isStrictCapture
                ? "Strict capture: a crash leaves the proxy set until JoesProxy reopens."
                : "Fails open: if JoesProxy stops unexpectedly, traffic falls back to a direct connection.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if case .active = systemProxyIndicatorState {
                Button("Disable and Restore Previous Settings") {
                    Task { await systemProxyController.disable() }
                    isRoutingPopoverPresented = false
                }
                .accessibilityIdentifier("systemProxyDisableButton")
            }

            Button("Simulator Setup…") {
                isRoutingPopoverPresented = false
                presentationState.presentSimulatorSetupWalkthrough()
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var systemProxyRecoveryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe.badge.chevron.backward")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Restore System Proxy?")
                    .font(.subheadline.weight(.semibold))
                Text("JoesProxy may have left your macOS system proxy pointing at it after quitting. Restore your previous settings?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Keep Current") {
                systemProxyController.dismissRecovery()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("systemProxyRecoveryKeepButton")

            Button("Restore") {
                Task { await systemProxyController.confirmRecovery() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("systemProxyRecoveryRestoreButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
        .accessibilityIdentifier("systemProxyRecoveryBanner")
    }

    private func proxyFailureBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Proxy Start Failed")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if viewModel.proxyPortErrorGuidance != nil {
                    Text("Change the port in Settings, then tap Retry.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button("Retry") {
                if viewModel.canStartProxy {
                    viewModel.startProxy()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var certificateRecoveryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.certificateWorkflowState == .needsCleanup ? "exclamationmark.triangle.fill" : "lock.trianglebadge.exclamationmark")
                .foregroundStyle(viewModel.certificateWorkflowState == .needsCleanup ? .orange : .yellow)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(certificateRecoveryTitle)
                    .font(.subheadline.weight(.semibold))
                Text(viewModel.certificateStatusGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(certificateRecoveryActionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open HTTPS Setup") {
                presentationState.presentCertificateSetup()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("Learn More") {
                openHelpWindow(topic: .certificateSetup)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            if viewModel.certificateWorkflowState == .needsCleanup {
                Button("Reset Certificate State") {
                    viewModel.resetCertificateState()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.yellow.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.18), lineWidth: 1)
        )
    }

    private var certificateRecoveryTitle: String {
        switch viewModel.certificateWorkflowState {
        case .installedTrustRequired:
            return "HTTPS Trust Still Required"
        case .needsCleanup:
            return "Certificate Cleanup Required"
        case .notSetUp, .ready:
            return ""
        }
    }

    private var certificateRecoveryActionSummary: String {
        switch viewModel.certificateWorkflowState {
        case .installedTrustRequired:
            return "HTTPS setup is not finished yet. Open HTTPS Setup to trust the Root CA so inspected request and response contents can appear."
        case .needsCleanup:
            return "JoesProxy found stale or conflicting certificate state. Open HTTPS Setup to review it, or reset the certificate state before trying again."
        case .notSetUp, .ready:
            return ""
        }
    }

    @ViewBuilder
    private func exportFailureBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Export Failed")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Adjust the destination or permissions, then export again.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Dismiss") {
                viewModel.dismissExportState()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private func recordingNoticeBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recording Notice")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Dismiss") {
                viewModel.dismissRecordingLoadState()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.18), lineWidth: 1)
        )
    }

    private func recordingLoadWarningBanner(failedCount: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Partial Load")
                    .font(.subheadline.weight(.semibold))
                Text("\(failedCount) session\(failedCount == 1 ? "" : "s") could not be decoded and were skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Dismiss") {
                viewModel.dismissRecordingLoadState()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private func recordingLoadErrorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Failed to Open Recording")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Dismiss") {
                viewModel.dismissRecordingLoadState()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
        )
    }

    private var exportStatusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: exportStatusIconName)
                .foregroundStyle(exportStatusTint)
                .accessibilityHidden(true)

            Text(exportStatusText)
                .font(.caption)
                .foregroundStyle(exportStatusTint)
                .lineLimit(1)

            Button {
                viewModel.dismissExportState()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss export status")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(exportStatusTint.opacity(0.12))
        )
    }

    private var exportStatusText: String {
        switch viewModel.exportState {
        case .idle:
            return ""
        case .exporting(let scopeDescription):
            return scopeDescription
        case .succeeded(let fileName):
            return "Exported \(fileName)"
        case .failed:
            return "Export failed"
        }
    }

    private var exportStatusIconName: String {
        switch viewModel.exportState {
        case .idle:
            return "circle"
        case .exporting:
            return "arrow.up.circle"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var exportStatusTint: Color {
        switch viewModel.exportState {
        case .idle:
            return .secondary
        case .exporting:
            return .orange
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }
}


#Preview {
    let coordinator = AppCoordinator()
    ContentView(
        viewModel: coordinator.viewModel,
        simulatorSetupViewModel: coordinator.simulatorSetupViewModel,
        routingModel: coordinator.systemProxyRoutingModel,
        systemProxyController: coordinator.systemProxyController,
        mcpServerController: coordinator.mcpServerController,
        selfValidationCoordinator: coordinator.selfValidationCoordinator,
        sessionStartCoordinator: coordinator.sessionStartCoordinator,
        compactModeController: coordinator.compactModeController
    )
        .environmentObject(AppPresentationState())
}
