//
//  ResponseOverrideManagerView.swift
//  JoesProxy
//
//  All UI for creating, listing, and editing Map Local / Block / Map Remote rules.
//  Includes the rules list sheet, inline rule row, creation sheet, and full editor.
//  Extracted from ContentView for independent compilation and testability.
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct MapLocalSheetContext: Identifiable {
    let session: SessionRecord

    var id: SessionRecord.ID { session.id }
}

struct ResponseOverrideEditorContext: Identifiable {
    let rule: ResponseOverrideRule

    var id: ResponseOverrideRule.ID { rule.id }
}

struct ResponseOverridesSheet: View {
    @Environment(\.appTextScale) private var appTextScale
    @ObservedObject var viewModel: ProxyViewModel
    let onEditRule: (ResponseOverrideRule) -> Void
    let onNewHLSTestStream: () -> Void
    let onNewOpenAPIMockPack: () -> Void
    var onInspectRecoveryRequest: (UUID) -> String? = { _ in "Request inspection is unavailable in this workspace." }
    @Binding var isPresented: Bool
    /// Owned by ``AppPresentationState`` so it outlives this window.
    @ObservedObject var authoringDraft: CapturedMockAuthoringDraft
    /// Retires the draft; returns `false` while an operation is running.
    let discardAuthoringDraft: () async -> Bool
    @State private var showingAuthoring = false
    @State private var confirmingDiscardDraft = false
    @State private var authoringMessage: String?
    @State private var recoveryReview: EffectBundleRecoveryReview?
    @State private var bundleSearch = ""
    @State private var activationReview: EffectBundleRecord?
    @State private var activationReviewReturnID: UUID?
    @FocusState private var activationReviewFocus: UUID?
    @State private var resettingModifications = false
    @State private var resetMessage: String?
    @State private var confirmingClearRules = false
    private let hlsStatusRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @ViewBuilder
    private var managementActions: some View {
                    Button("Import Bundle…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [
                            UTType(filenameExtension: "jproxy-effects") ?? .directory
                        ]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = true
                        if panel.runModal() == .OK, let url = panel.url {
                            Task {
                                await viewModel.importEffectBundle(from: url)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Import Effect Bundle")
                    .accessibilityHint("Import a .jproxy-effects package into managed storage as inactive.")
                    .accessibilityIdentifier("importEffectBundleButton")

                    Button("New OpenAPI Mock…") {
                        onNewOpenAPIMockPack()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("New OpenAPI Mock")
                    .accessibilityHint("Import a local OpenAPI 3.0 JSON document as one mock pack.")
                    .accessibilityIdentifier("newOpenAPIMockPackButton")

                    Button("New Test Stream…") {
                        onNewHLSTestStream()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("newHLSTestStreamButton")

                    if viewModel.hasResponseOverrides {
                        Button("Remove All Rules…", role: .destructive) {
                            confirmingClearRules = true
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }

                    Button("Close") {
                        isPresented = false
                    }
                    .accessibilityIdentifier("trafficModificationsClose")
                    .disabled(authoringDraft.busy)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Traffic Modifications")
                    .appFont(.title2, scale: appTextScale, weight: .semibold)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { managementActions }
                    VStack(alignment: .leading, spacing: 8) { managementActions }
                }

                Text("Active rules intercept matching requests before they reach the upstream server. Map Local serves local content, Block drops the request, and Map Remote forwards to a different host.")
                    .appFont(.subheadline, scale: appTextScale)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(authoringDraft.source == nil ? "Append JSON + Image…" : "Resume JSON + Image Draft…") {
                        if authoringDraft.source != nil {
                            showingAuthoring = true
                        } else {
                            authoringMessage = authoringDraft.selectSource(viewModel.selectedSession)
                            showingAuthoring = authoringMessage == nil
                        }
                    }
                    .disabled(showingAuthoring || authoringDraft.busy)
                    .accessibilityIdentifier("newCapturedMockButton")
                    .help("Select a captured GET response to prepare a scoped JSON fixture with an optional image.")
                    if authoringDraft.source != nil {
                        Button("Discard Draft…", role: .destructive) {
                            confirmingDiscardDraft = true
                        }
                        .disabled(authoringDraft.busy || authoringDraft.discoveringCollections)
                        .accessibilityIdentifier("discardCapturedMockDraftButton")
                        .accessibilityHint("Deletes the unsaved Append JSON + Image draft and its copy of the selected capture.")
                    }
                }
                if authoringDraft.source != nil {
                    Text("An unsaved draft is kept until you save or discard it, including after this window closes or the workspace switches between Compact and Inspector.")
                        .appFont(.caption, scale: appTextScale)
                        .accessibilityIdentifier("capturedMockDraftRetentionNotice")
                }
                if let authoringMessage { Text(authoringMessage).appFont(.caption, scale: appTextScale) }
            }

            if showingAuthoring, let source = authoringDraft.source {
                CapturedMockAuthoringView(source: source, draft: authoringDraft, service: viewModel.collectionMockAuthoringService,
                    iconSuggestions: viewModel.mockIconSuggestionService,
                    textSuggestions: viewModel.similarItemTextGenerator,
                    repository: viewModel.effectBundleRepository,
                    relatedCandidates: viewModel.sessionSummaries.suffix(100).compactMap { viewModel.sessionRecord(for: $0.id) },
                    preflightRevision: { try await viewModel.preflightCapturedMock(revisionID: $0) },
                    onClose: { showingAuthoring = false },
                    onSaved: {
                        showingAuthoring = false
                        // A saved revision must not reappear as an unsaved draft with Save enabled.
                        Task { _ = await discardAuthoringDraft() }
                    })
            } else if viewModel.responseOverrides.isEmpty
                && viewModel.hlsSubstitutionExperiments.isEmpty
                && viewModel.openAPIMockPacks.isEmpty
                && viewModel.effectBundleRecords.isEmpty
                && viewModel.syntheticInjectionPlans.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Modifications", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Create a Map Local, Block, Map Remote, HLS test-stream, OpenAPI mock pack, synthetic collection injection plan, or effect bundle.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !viewModel.effectBundleRecords.isEmpty {
                        Section("Effect Bundles") {
                            TextField("Search bundles by name, ID, or revision", text: $bundleSearch)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("effectBundleSearch")
                            if !viewModel.effectBundleRecords.contains(where: { EffectBundlePresentation.matches($0, query: bundleSearch) }) {
                                Text("No bundles match this search. Other modification types are shown below.")
                                Button("Clear Bundle Search") { bundleSearch = "" }
                            }
                            ForEach(viewModel.effectBundleRecords.filter { EffectBundlePresentation.matches($0, query: bundleSearch) }) { bundle in
                                EffectBundleRow(
                                    record: bundle,
                                    activationFocus: $activationReviewFocus,
                                    onActivate: {
                                        activationReviewReturnID = bundle.id
                                        activationReviewFocus = nil
                                        activationReview = bundle
                                    },
                                    onStop: {
                                        Task { await viewModel.stopEffectBundle(id: bundle.id) }
                                    },
                                    onDiscard: {
                                        Task { await viewModel.discardEffectBundle(id: bundle.id) }
                                    },
                                    recoveryAvailability: recoveryAvailability,
                                    performRecovery: performRecovery
                                )
                                EffectBundlePhaseControls(bundleID: bundle.id, coordinator: viewModel.effectBundleCoordinator)
                                if let diagnostics = viewModel.effectBundleCoordinator.diagnosticRuns {
                                    EffectBundleExperimentView(record: bundle, diagnostics: diagnostics)
                                }
                            }
                        }
                    }
                    if !viewModel.openAPIMockPacks.isEmpty {
                        Section("OpenAPI Mock Packs") {
                            ForEach(viewModel.openAPIMockPacks) { pack in
                                OpenAPIMockPackRow(
                                    pack: pack,
                                    onStart: {
                                        Task { await viewModel.startOpenAPIMockPack(id: pack.id) }
                                    },
                                    onStop: {
                                        Task { await viewModel.stopOpenAPIMockPack(id: pack.id) }
                                    },
                                    onRestart: {
                                        Task { await viewModel.restartOpenAPIMockPack(id: pack.id) }
                                    },
                                    onDiscard: {
                                        Task { await viewModel.discardOpenAPIMockPack(id: pack.id) }
                                    }
                                )
                            }
                        }
                    }
                    if !viewModel.hlsSubstitutionExperiments.isEmpty {
                        Section("HLS Test Streams") {
                            ForEach(viewModel.hlsSubstitutionExperiments) { experiment in
                                HLSTestStreamExperimentRow(
                                    experiment: experiment,
                                    profile: viewModel.hlsFixtureProfiles.first(where: { $0.id == experiment.profileID }),
                                    onStop: {
                                        Task { await viewModel.stopHLSTestStream(id: experiment.id) }
                                    },
                                    onRestart: {
                                        Task { await viewModel.restartHLSTestStream(id: experiment.id) }
                                    }
                                )
                            }
                        }
                    }
                    if !viewModel.syntheticInjectionPlans.isEmpty {
                        Section("Synthetic Collection Injection") {
                            ForEach(viewModel.syntheticInjectionPlans) { plan in
                                SyntheticInjectionPlanRow(
                                    plan: plan,
                                    diagnostics: viewModel.syntheticInjectionDiagnostics[plan.id],
                                    onToggle: { newValue in
                                        viewModel.setSyntheticInjectionPlanEnabled(newValue, id: plan.id)
                                    },
                                    onRemove: {
                                        viewModel.removeSyntheticInjectionPlan(id: plan.id)
                                    }
                                )
                            }
                        }
                    }
                    if !viewModel.responseOverrides.isEmpty {
                        Section("Response Rules") {
                    ForEach(viewModel.responseOverrides) { rule in
                        ResponseOverrideRuleRow(
                            rule: rule,
                            onToggle: { newValue in
                                Task { await viewModel.setResponseOverrideEnabled(newValue, id: rule.id) }
                            },
                            onEdit: { onEditRule(rule) },
                            onDelete: {
                                Task { await viewModel.deleteResponseOverride(id: rule.id) }
                            },
                            onSaveBlock: { statusCode in
                                Task {
                                    await viewModel.updateBlockResponseOverride(
                                        id: rule.id,
                                        label: rule.label,
                                        matchMode: rule.matchMode,
                                        statusCode: statusCode
                                    )
                                }
                            },
                            onSaveMapRemote: { host, port, scheme, path in
                                Task {
                                    await viewModel.updateMapRemoteResponseOverride(
                                        id: rule.id,
                                        label: rule.label,
                                        matchMode: rule.matchMode,
                                        remoteHost: host,
                                        remotePort: port,
                                        remoteScheme: scheme,
                                        remotePath: path
                                    )
                                }
                            }
                        )
                    }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(viewModel.trafficModificationSnapshot.activeModificationCount) active modifications")
                    .appFont(.caption, scale: appTextScale)
                Spacer()
                Button("Disable All Modifications") {
                    resettingModifications = true
                    Task {
                        let result = await viewModel.disableAllTrafficModifications()
                        resetMessage = result.isComplete
                            ? "All traffic modifications disabled. Capture is unchanged."
                            : "\(result.remainingCount) modifications remain active. Review their status and retry."
                        resettingModifications = false
                    }
                }
                .disabled(resettingModifications || viewModel.trafficModificationSnapshot.activeModificationCount == 0)
                .accessibilityIdentifier("managementDisableAllModifications")
            }
            if resettingModifications { ProgressView("Disabling modifications…") }
            if let resetMessage { Text(resetMessage).appFont(.caption, scale: appTextScale) }
            if let error = viewModel.lastErrorMessage {
                Text(error).appFont(.caption, scale: appTextScale).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .task {
            await viewModel.refreshHLSTestStreamStatus()
            await viewModel.refreshOpenAPIMockPackStatus()
            viewModel.refreshSyntheticInjectionPlans()
        }
        .onReceive(hlsStatusRefreshTimer) { _ in
            // Synthetic injection plans have no async status of their own (in-memory only, no
            // network/expiry to poll) — this just catches a plan an MCP client registered or
            // removed elsewhere while this sheet is open, same as the other two.
            viewModel.refreshSyntheticInjectionPlans()
            guard !viewModel.hlsSubstitutionExperiments.isEmpty || !viewModel.openAPIMockPacks.isEmpty else { return }
            Task {
                await viewModel.refreshHLSTestStreamStatus()
                await viewModel.refreshOpenAPIMockPackStatus()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localOverridesSheet")
        .confirmationDialog("Remove all response rules?", isPresented: $confirmingClearRules) {
            Button("Remove All Rules", role: .destructive) {
                Task { await viewModel.clearResponseOverrides() }
            }
        } message: {
            Text("This removes response rules, not saved bundles. Use Disable All Modifications to stop effects without removing their configuration.")
        }
        .confirmationDialog("Discard the Append JSON + Image draft?", isPresented: $confirmingDiscardDraft) {
            Button("Discard Draft", role: .destructive) {
                Task {
                    if await discardAuthoringDraft() {
                        showingAuthoring = false
                        authoringMessage = nil
                    } else {
                        authoringMessage = "Wait for the current operation to finish. Your draft has been retained."
                    }
                }
            }
        } message: {
            Text("Typed edits, bound artwork and related responses are removed. Saved bundles and active modifications are unchanged.")
        }
        .onAppear {
            if UITestLaunchConfiguration.current?.fixture == .guidedMockAuthoring,
               authoringDraft.source == nil, viewModel.effectBundleRecords.isEmpty {
                GuidedMockAuthoringUITestFixture.configure(authoringDraft)
                showingAuthoring = true
            }
        }
        .sheet(item: $activationReview, onDismiss: {
            if let id = activationReviewReturnID,
               viewModel.effectBundleRecords.contains(where: { $0.id == id && !$0.isServing }) {
                activationReviewFocus = id
            }
            activationReviewReturnID = nil
        }) { record in
            EffectBundleActivationReviewView(record: record, onActivate: { ttl in
                guard EffectBundlePresentation.isCurrentReview(record,
                    current: viewModel.effectBundleRecords.first(where: { $0.id == record.id })) else {
                    authoringMessage = "This bundle changed during review. Reopen its activation review before continuing."
                    activationReview = nil
                    return
                }
                Task { await viewModel.activateEffectBundle(reviewed: record, ttl: ttl) }
                activationReview = nil
            }, onCancel: { activationReview = nil })
        }
        .sheet(item: $recoveryReview) { review in
            EffectBundleRecoveryReviewView(review: review, stopBundle: review.assetTarget == nil ? nil : {
                guard let receipt = EffectBundleActivationGate.shared.retainedReceipt(id: review.id,
                    bundleID: review.bundleID), recoveryEffect(receipt) != nil else {
                    return "The original receipt or revision is no longer available. Refresh evidence before stopping."
                }
                guard EffectBundleActivationGate.shared.resource(ruleID: receipt.resource.resourceID) == receipt.resource else {
                    return "This receipt is not from the currently serving activation. Review the current bundle before stopping."
                }
                await viewModel.stopEffectBundle(id: receipt.resource.bundleID)
                guard let record = viewModel.effectBundleRepository.record(id: receipt.resource.bundleID) else {
                    return "Bundle state is unavailable. Review lifecycle evidence."
                }
                return "Bundle state: \(record.state.rawValue). \(record.cleanupMessage ?? "Review retained lifecycle evidence for details.")"
            }, selectedSource: viewModel.selectedSession.map {
                (id: $0.id.uuidString, label: "\($0.request.method) \($0.request.host)\($0.request.path)")
            }, sourceOptions: Array(viewModel.sessionSummaries.lazy.filter { $0.method == "GET" && $0.statusCode != nil }
                .prefix(50)).map {
                    (id: $0.id.uuidString, label: "\($0.host)\(String($0.path.prefix(160))) · \($0.id.uuidString.prefix(8))")
                }, beginReplacement: { sourceID in
                guard let receipt = EffectBundleActivationGate.shared.retainedReceipt(id: review.id,
                    bundleID: review.bundleID), recoveryEffect(receipt) != nil else {
                    return "The receipt or retained revision is unavailable. Refresh evidence; the existing draft is unchanged."
                }
                guard let id = UUID(uuidString: sourceID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return "Enter a capture UUID or explicitly choose the selected request."
                }
                if let reason = authoringDraft.selectSource(viewModel.sessionRecord(for: id),
                    replacing: receipt.resource.revisionID) { return reason }
                showingAuthoring = true
                recoveryReview = nil
                return nil
            })
                .environment(\.appTextScale, appTextScale)
        }
        .joesProxyResizableWorkspaceSheet(minWidth: 720, minHeight: 420)
    }

    private func recoveryEffect(_ receipt: EffectBundleDeliveryReceipt) -> EffectBundleResponseEffect? {
        guard let record = viewModel.effectBundleRepository.record(id: receipt.resource.bundleID),
              record.manifest.authoring?.revisionID == receipt.resource.revisionID,
              record.manifest.assets.contains(where: {
                  $0.id == receipt.resource.assetID && $0.sha256 == receipt.resource.expectedSHA256
              }) else { return nil }
        return record.manifest.responseEffects.first {
            $0.id == receipt.resource.resourceID && $0.bodySource.assetIDs.contains(receipt.resource.assetID)
        }
    }

    private func recoveryAvailability(_ receipt: EffectBundleDeliveryReceipt) -> EffectBundleRecoveryAvailability {
        .init(receiptExists: EffectBundleActivationGate.shared.retainedReceipt(id: receipt.id,
                bundleID: receipt.resource.bundleID) != nil,
            resourceExists: recoveryEffect(receipt) != nil,
            captureExists: receipt.sessionID.flatMap { viewModel.sessionRecord(for: $0) } != nil,
            bundleServing: EffectBundleActivationGate.shared.allows(bundleID: receipt.resource.bundleID))
    }

    private func performRecovery(_ action: EffectBundleRecoveryAction, receipt: EffectBundleDeliveryReceipt) -> String? {
        let choice = EffectBundleRecoveryPolicy.choice(action, receipt: receipt, availability: recoveryAvailability(receipt))
        guard choice.isEnabled else { return choice.unavailableReason }
        switch action {
        case .inspectRequest:
            guard let id = receipt.sessionID else { return "Capture identity is unavailable." }
            return onInspectRecoveryRequest(id)
        case .reviewMatcher, .reviewClientScope, .reviewIntegrity, .checkAsset:
            var review = EffectBundleRecoveryReview(receipt: receipt, action: action,
                effect: recoveryEffect(receipt), request: receipt.sessionID.flatMap { viewModel.sessionRecord(for: $0)?.request })
            if action == .checkAsset || action == .reviewIntegrity {
                review.assetTarget = try? viewModel.effectBundleRepository.recoveryAssetTarget(receipt.resource)
            }
            recoveryReview = review
            return nil
        case .refreshEvidence, .observeNextRequest:
            return "Refresh or observation is handled by the evidence view."
        }
    }
}

// MARK: - ResponseOverrideRuleRow

/// A single row in the Local Overrides list.
///
/// Displays a colored type badge (purple for Map Local variants, red for Block, indigo for Map Remote)
/// and exposes lightweight inline editors for the most-commonly-tweaked fields:
/// - Block rules: status code text field (commits on Return or focus loss)
/// - Map Remote rules: host, port, and scheme controls (commit on Return or focus loss)
struct ResponseOverrideRuleRow: View {
    @Environment(\.appTextScale) private var appTextScale

    let rule: ResponseOverrideRule
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// Called when the user commits a new status code for a Block rule.
    let onSaveBlock: (_ statusCode: Int) -> Void
    /// Called when the user commits new destination details for a Map Remote rule. `path` is nil
    /// to keep reusing the original request's path/query (unchanged pre-`remotePath` behavior).
    let onSaveMapRemote: (_ host: String, _ port: Int?, _ scheme: SessionScheme, _ path: String?) -> Void

    // Inline-edit state for Block rules
    @State private var blockStatusText: String
    // Inline-edit state for Map Remote rules
    @State private var mapRemoteHostText: String
    @State private var mapRemotePortText: String
    @State private var mapRemoteScheme: SessionScheme
    @State private var mapRemotePathText: String

    @FocusState private var blockStatusFocused: Bool
    @FocusState private var mapRemoteHostFocused: Bool
    @FocusState private var mapRemotePortFocused: Bool
    @FocusState private var mapRemotePathFocused: Bool

    init(
        rule: ResponseOverrideRule,
        onToggle: @escaping (Bool) -> Void,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSaveBlock: @escaping (_ statusCode: Int) -> Void,
        onSaveMapRemote: @escaping (_ host: String, _ port: Int?, _ scheme: SessionScheme, _ path: String?) -> Void
    ) {
        self.rule = rule
        self.onToggle = onToggle
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onSaveBlock = onSaveBlock
        self.onSaveMapRemote = onSaveMapRemote
        _blockStatusText = State(initialValue: String(rule.statusCode))
        _mapRemoteHostText = State(initialValue: rule.mapRemoteHost ?? "")
        _mapRemotePortText = State(initialValue: rule.mapRemotePort.map { String($0) } ?? "")
        _mapRemoteScheme = State(initialValue: rule.mapRemoteScheme ?? .https)
        _mapRemotePathText = State(initialValue: rule.mapRemotePath ?? "")
    }

    // MARK: Badge color

    private var sourceKindBadgeColor: Color {
        switch rule.sourceKind {
        case .capturedResponse, .inlineText, .localFile:
            return .purple
        case .block:
            return .red
        case .mapRemote:
            return .indigo
        case .bookmarkRewrite:
            return .blue
        case .liveResponseRewrite:
            return .teal
        case .collectionMock:
            return .teal
        case .fixtureRun:
            return .orange
        case .localDirectory:
            return .mint
        }
    }

    // MARK: Commit helpers

    private func commitBlockStatus() {
        let trimmed = blockStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code = Int(trimmed) else {
            blockStatusText = String(rule.statusCode)
            return
        }
        onSaveBlock(code)
    }

    private func commitMapRemote() {
        let host = mapRemoteHostText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            mapRemoteHostText = rule.mapRemoteHost ?? ""
            return
        }
        let port = Int(mapRemotePortText.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedPath = mapRemotePathText.trimmingCharacters(in: .whitespacesAndNewlines)
        onSaveMapRemote(host, port, mapRemoteScheme, trimmedPath.isEmpty ? nil : trimmedPath)
    }

    // MARK: Body

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {

                // Title + type badge (color matches session-table override badge)
                HStack(spacing: 8) {
                    Text(rule.displayTitle)
                        .appFont(.subheadline, scale: appTextScale, weight: .semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(rule.sourceKind.title)
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(sourceKindBadgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(sourceKindBadgeColor.opacity(0.14))
                        )
                        .accessibilityLabel(rule.sourceKind.title)

                    if let clientAddress = rule.sourceClientAddress, !clientAddress.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Text(clientAddress)
                        }
                        .appFont(.caption2, scale: appTextScale, weight: .semibold, design: .monospaced)
                        .foregroundStyle(Color.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.blue.opacity(0.12))
                        )
                    }
                }

                // Matched URL pattern
                Text(rule.title)
                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                    .foregroundStyle(.tertiary)

                // Status / destination row — inline editable for Block and Map Remote
                if rule.sourceKind == .block {
                    HStack(spacing: 6) {
                        Text("Status")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)

                        TextField("503", text: $blockStatusText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .appFont(.caption, scale: appTextScale)
                            .focused($blockStatusFocused)
                            .onSubmit { commitBlockStatus() }
                            .onChange(of: blockStatusFocused) { _, isFocused in
                                if !isFocused { commitBlockStatus() }
                            }
                            .onChange(of: rule.statusCode) { _, newCode in
                                // Keep field in sync when an external edit (e.g. modal) changes the rule.
                                if !blockStatusFocused {
                                    blockStatusText = String(newCode)
                                }
                            }

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text(rule.sourceDescription)
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }
                } else if rule.sourceKind == .mapRemote {
                    HStack(spacing: 6) {
                        TextField("host", text: $mapRemoteHostText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .appFont(.caption, scale: appTextScale)
                            .focused($mapRemoteHostFocused)
                            .onSubmit { commitMapRemote() }
                            .onChange(of: mapRemoteHostFocused) { _, isFocused in
                                if !isFocused { commitMapRemote() }
                            }

                        TextField("port", text: $mapRemotePortText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .appFont(.caption, scale: appTextScale)
                            .focused($mapRemotePortFocused)
                            .onSubmit { commitMapRemote() }
                            .onChange(of: mapRemotePortFocused) { _, isFocused in
                                if !isFocused { commitMapRemote() }
                            }

                        Picker("", selection: $mapRemoteScheme) {
                            Text(SessionScheme.http.rawValue).tag(SessionScheme.http)
                            Text(SessionScheme.https.rawValue).tag(SessionScheme.https)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 80)
                        .onChange(of: mapRemoteScheme) { _, _ in commitMapRemote() }

                        TextField("path (optional)", text: $mapRemotePathText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .appFont(.caption, scale: appTextScale)
                            .focused($mapRemotePathFocused)
                            .onSubmit { commitMapRemote() }
                            .onChange(of: mapRemotePathFocused) { _, isFocused in
                                if !isFocused { commitMapRemote() }
                            }
                    }
                    .onChange(of: rule.mapRemoteHost) { _, newHost in
                        if !mapRemoteHostFocused { mapRemoteHostText = newHost ?? "" }
                    }
                    .onChange(of: rule.mapRemotePort) { _, newPort in
                        if !mapRemotePortFocused { mapRemotePortText = newPort.map { String($0) } ?? "" }
                    }
                    .onChange(of: rule.mapRemoteScheme) { _, newScheme in
                        mapRemoteScheme = newScheme ?? .https
                    }
                    .onChange(of: rule.mapRemotePath) { _, newPath in
                        if !mapRemotePathFocused { mapRemotePathText = newPath ?? "" }
                    }
                } else if rule.sourceKind == .bookmarkRewrite {
                    Text(rule.sourceDescription)
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                } else if rule.sourceKind == .liveResponseRewrite {
                    Text(rule.sourceDescription)
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(rule.statusCode) · \(rule.sourceDescription)")
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }

                Text(rule.matchMode.description)
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Text("Hits \(rule.hitCount)")
                    Text(rule.lastMatchedAt.map { "Last matched \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not matched yet")
                }
                .appFont(.caption, scale: appTextScale, design: .monospaced)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button { onEdit() } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Edit rule")

            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Delete rule")
        }
        .padding(.vertical, 4)
    }
}

enum InlineJSONEditorMode: String, CaseIterable, Identifiable {
    case raw = "Raw"
    case prettified = "Prettified"

    var id: String { rawValue }
}

struct InlineOverrideBodyEditor: View {
    @Environment(\.appTextScale) private var appTextScale

    @Binding var bodyText: String
    @Binding var contentTypeText: String
    @Binding var jsonViewMode: InlineJSONEditorMode

    private var prettyPrintedJSON: String? {
        Self.prettyPrintedJSONString(from: bodyText)
    }

    private var isJSONContentType: Bool {
        let mimeType = contentTypeText
            .split(separator: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return mimeType.contains("json") || mimeType.hasSuffix("+json")
    }

    private var shouldShowJSONControls: Bool {
        isJSONContentType || prettyPrintedJSON != nil
    }

    private var jsonValidationText: String? {
        guard shouldShowJSONControls else {
            return nil
        }
        guard !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return isJSONContentType ? "JSON body is empty." : nil
        }
        return prettyPrintedJSON == nil ? "Invalid JSON. Fix the body before prettifying." : "Valid JSON."
    }

    private var jsonValidationColor: Color {
        prettyPrintedJSON == nil ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if shouldShowJSONControls {
                HStack(spacing: 12) {
                    Picker("JSON View", selection: $jsonViewMode) {
                        ForEach(InlineJSONEditorMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .onChange(of: jsonViewMode) { _, newValue in
                        if newValue == .prettified {
                            formatJSONIfPossible()
                        }
                    }

                    if let jsonValidationText {
                        Label(jsonValidationText, systemImage: prettyPrintedJSON == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(jsonValidationColor)
                    }

                    Spacer(minLength: 8)

                    Button("Format JSON") {
                        formatJSONIfPossible()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(prettyPrintedJSON == nil)
                }
            }

            TextEditor(text: $bodyText)
                .font(.system(size: 12 * appTextScale, design: .monospaced))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 220)
        }
    }

    private func formatJSONIfPossible() {
        guard let prettyPrintedJSON else {
            return
        }
        bodyText = prettyPrintedJSON
    }

    static func prettyPrintedJSONString(from string: String) -> String? {
        guard let data = string.data(using: .utf8) else {
            return nil
        }

        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            let prettyPrintedData = try? JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            return nil
        }

        return String(data: prettyPrintedData, encoding: .utf8)
    }
}

/// Editable row for a live-response JSON field rewrite in the override manager.
private struct LiveResponseRewriteDraft: Identifiable {
    let id: UUID
    var jsonPath: String
    var operation: JSONMutationOperation
    var valueText: String
    var isRuleEnabled: Bool

    init(
        id: UUID = UUID(),
        jsonPath: String = "",
        operation: JSONMutationOperation = .set,
        valueText: String = "true",
        isRuleEnabled: Bool = true
    ) {
        self.id = id
        self.jsonPath = jsonPath
        self.operation = operation
        self.valueText = valueText
        self.isRuleEnabled = isRuleEnabled
    }

    init(from rewrite: BookmarkResponseFieldRewrite) {
        id = rewrite.id
        jsonPath = rewrite.jsonPath
        operation = rewrite.operation
        valueText = rewrite.overrideValue.displayString
        isRuleEnabled = rewrite.isRuleEnabled
    }

    var isValid: Bool {
        !jsonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func toRewrite() -> BookmarkResponseFieldRewrite {
        BookmarkResponseFieldRewrite(
            id: id,
            jsonPath: jsonPath.trimmingCharacters(in: .whitespacesAndNewlines),
            overrideValue: BookmarkJSONValue.fromUserInput(valueText, mode: .json),
            operation: operation,
            isRuleEnabled: isRuleEnabled
        )
    }
}

/// Inline editor for JSON field rewrites on live-response rewrite override rules.
private struct LiveResponseRewriteEditor: View {
    @Environment(\.appTextScale) private var appTextScale

    @Binding var drafts: [LiveResponseRewriteDraft]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Matching requests reach the real upstream server. JoesProxy patches JSON fields in the response on the way back to the client.")
                .appFont(.subheadline, scale: appTextScale)
                .foregroundStyle(.secondary)

            ForEach($drafts) { $draft in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Toggle("Enabled", isOn: $draft.isRuleEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .help(draft.isRuleEnabled ? "Rewrite enabled" : "Rewrite disabled")

                        TextField("JSON path", text: $draft.jsonPath)
                            .textFieldStyle(.roundedBorder)
                            .appFont(.caption, scale: appTextScale, design: .monospaced)

                        Picker("Operation", selection: $draft.operation) {
                            ForEach(JSONMutationOperation.allCases, id: \.self) { operation in
                                Text(operation.title).tag(operation)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 88)

                        if drafts.count > 1 {
                            Button(role: .destructive) {
                                drafts.removeAll { $0.id == draft.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                    }

                    TextField("Override value (JSON)", text: $draft.valueText)
                        .textFieldStyle(.roundedBorder)
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }

            Button("Add Rewrite") {
                drafts.append(LiveResponseRewriteDraft())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ResponseOverrideEditorSheet: View {
    @Environment(\.appTextScale) private var appTextScale

    let rule: ResponseOverrideRule
    let onSaveCaptured: (String?, ResponseOverrideMatchMode, String, Int, String?, Bool) -> Void
    let onSaveInline: (String?, ResponseOverrideMatchMode, String, Int, String?, String, Bool) -> Void
    let onSaveFile: (String?, ResponseOverrideMatchMode, String, Int, String?, URL, Bool) -> Void
    /// Called when saving a local-directory rule: (label, matchPath, directoryURL, forceNoCache).
    /// Match mode is always pathPrefix for this source kind.
    let onSaveDirectory: (String?, String, URL, Bool) -> Void
    /// Called when saving a block rule: (label, matchMode, matchPath, statusCode)
    let onSaveBlock: (String?, ResponseOverrideMatchMode, String, Int) -> Void
    /// Called when saving a map-remote rule: (label, matchMode, matchPath, remoteHost, remotePort, remoteScheme, remotePath)
    let onSaveMapRemote: (String?, ResponseOverrideMatchMode, String, String, Int?, SessionScheme, String?) -> Void
    /// Called when saving a live-response rewrite rule: (label, matchMode, matchPath, rewrites)
    let onSaveLiveResponseRewrite: (String?, ResponseOverrideMatchMode, String, [BookmarkResponseFieldRewrite]) -> Void
    let onCancel: () -> Void

    @State private var labelText: String
    @State private var selectedMatchMode: ResponseOverrideMatchMode
    /// Editable matcher path/suffix value — see `MapLocalSheet.matchPath` for why this exists (AQ).
    @State private var matchPath: String
    private let originalPath: String
    /// AR: see `MapLocalSheet.forceNoCache` — same purpose, edit-side.
    @State private var forceNoCache: Bool
    @State private var statusCodeText: String
    @State private var contentTypeText: String
    @State private var inlineBodyText: String
    @State private var inlineJSONViewMode: InlineJSONEditorMode
    @State private var selectedFileURL: URL?
    @State private var isFileImporterPresented = false
    @State private var selectedDirectoryURL: URL?
    // Map Remote editing state
    @State private var remoteHostText: String
    @State private var remotePortText: String
    @State private var remoteSchemeSelection: SessionScheme
    @State private var remotePathText: String
    @State private var liveRewriteDrafts: [LiveResponseRewriteDraft]

    init(
        rule: ResponseOverrideRule,
        onSaveCaptured: @escaping (String?, ResponseOverrideMatchMode, String, Int, String?, Bool) -> Void,
        onSaveInline: @escaping (String?, ResponseOverrideMatchMode, String, Int, String?, String, Bool) -> Void,
        onSaveFile: @escaping (String?, ResponseOverrideMatchMode, String, Int, String?, URL, Bool) -> Void,
        onSaveDirectory: @escaping (String?, String, URL, Bool) -> Void,
        onSaveBlock: @escaping (String?, ResponseOverrideMatchMode, String, Int) -> Void,
        onSaveMapRemote: @escaping (String?, ResponseOverrideMatchMode, String, String, Int?, SessionScheme, String?) -> Void,
        onSaveLiveResponseRewrite: @escaping (String?, ResponseOverrideMatchMode, String, [BookmarkResponseFieldRewrite]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.rule = rule
        self.onSaveCaptured = onSaveCaptured
        self.onSaveInline = onSaveInline
        self.onSaveFile = onSaveFile
        self.onSaveDirectory = onSaveDirectory
        self.onSaveBlock = onSaveBlock
        self.onSaveMapRemote = onSaveMapRemote
        self.onSaveLiveResponseRewrite = onSaveLiveResponseRewrite
        self.onCancel = onCancel
        _labelText = State(initialValue: rule.label ?? "")
        _selectedMatchMode = State(initialValue: rule.sourceKind == .localDirectory ? .pathPrefix : rule.matchMode)
        self.originalPath = rule.path
        _matchPath = State(initialValue: rule.path)
        _forceNoCache = State(initialValue: rule.forceNoCache)
        _statusCodeText = State(initialValue: String(rule.statusCode))
        let initialContentType = Self.currentContentType(from: rule.headers)
        _contentTypeText = State(initialValue: initialContentType)
        switch rule.bodySource {
        case .inline(let data):
            let initialBodyText = MapLocalSheet.inlineTextSeed(from: data)
            _inlineBodyText = State(initialValue: initialBodyText)
            _inlineJSONViewMode = State(initialValue: Self.initialJSONViewMode(contentType: initialContentType, bodyText: initialBodyText))
            _selectedFileURL = State(initialValue: nil)
            _selectedDirectoryURL = State(initialValue: nil)
        case .file(let fileURL):
            _inlineBodyText = State(initialValue: "")
            _inlineJSONViewMode = State(initialValue: .raw)
            _selectedFileURL = State(initialValue: fileURL)
            _selectedDirectoryURL = State(initialValue: nil)
        case .directory(let directoryURL):
            _inlineBodyText = State(initialValue: "")
            _inlineJSONViewMode = State(initialValue: .raw)
            _selectedFileURL = State(initialValue: nil)
            _selectedDirectoryURL = State(initialValue: directoryURL)
        }
        _remoteHostText = State(initialValue: rule.mapRemoteHost ?? "")
        _remotePortText = State(initialValue: rule.mapRemotePort.map { String($0) } ?? "")
        _remoteSchemeSelection = State(initialValue: rule.mapRemoteScheme ?? .https)
        _remotePathText = State(initialValue: rule.mapRemotePath ?? "")
        _liveRewriteDrafts = State(
            initialValue: rule.sourceKind == .liveResponseRewrite
                ? rule.liveResponseRewrites.map(LiveResponseRewriteDraft.init(from:))
                : []
        )
    }

    private var resolvedStatusCode: Int? {
        Int(statusCodeText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var resolvedMatchPath: String {
        let trimmed = matchPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/" : trimmed
    }

    private var canSave: Bool {
        switch rule.sourceKind {
        case .capturedResponse, .inlineText:
            return resolvedStatusCode != nil
        case .localFile:
            return resolvedStatusCode != nil && selectedFileURL != nil
        case .block:
            return resolvedStatusCode != nil
        case .mapRemote:
            return !remoteHostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .bookmarkRewrite:
            return false
        case .liveResponseRewrite:
            let rewrites = liveRewriteDrafts.map { $0.toRewrite() }
            return !rewrites.isEmpty && rewrites.contains(where: \.isRuleEnabled)
                && liveRewriteDrafts.allSatisfy(\.isValid)
        case .collectionMock:
            // Collection-mock rules are authored only via the dedicated collection-mock
            // authoring/activation path and have no editable fields here.
            return false
        case .fixtureRun:
            // Fixture-backed rules are authored only via the dedicated MCP/CLI fixture-redirect
            // path (ADR-Streaming-Source-Redirect-To-Fixture.md) and have no editable fields here.
            return false
        case .localDirectory:
            return selectedDirectoryURL != nil && selectedMatchMode == .pathPrefix
        }
    }

    private var sheetTitle: String {
        switch rule.sourceKind {
        case .block:
            return "Edit Block Rule"
        case .mapRemote:
            return "Edit Map Remote Rule"
        case .bookmarkRewrite:
            return "Edit Bookmark Rewrite"
        case .liveResponseRewrite:
            return "Edit Live Response Rewrite"
        default:
            return "Edit Local Override"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sheetTitle)
                        .appFont(.title3, scale: appTextScale, weight: .semibold)

                    Text(rule.title)
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Label")
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.secondary)
                    TextField("Optional override label", text: $labelText)
                        .textFieldStyle(.roundedBorder)
                }

                if rule.sourceKind != .mapRemote && rule.sourceKind != .bookmarkRewrite && rule.sourceKind != .liveResponseRewrite {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status Code")
                            .appFont(.caption, scale: appTextScale, weight: .semibold)
                            .foregroundStyle(.secondary)
                        TextField("200", text: $statusCodeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Match")
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Picker("Match", selection: $selectedMatchMode) {
                        ForEach(ResponseOverrideMatchMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help(selectedMatchMode.description)
                    .onChange(of: selectedMatchMode) { _, newMode in
                        if newMode == .pathSuffix, matchPath == originalPath {
                            matchPath = MapLocalSheet.lastPathComponent(of: originalPath)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(selectedMatchMode == .pathSuffix ? "Path Suffix" : "Path")
                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                    .foregroundStyle(.secondary)
                TextField(originalPath, text: $matchPath)
                    .textFieldStyle(.roundedBorder)
                    .help("The exact string matched against the request path — edit this to control what \(selectedMatchMode.title) actually matches.")
            }

            if rule.sourceKind != .block && rule.sourceKind != .mapRemote && rule.sourceKind != .bookmarkRewrite && rule.sourceKind != .liveResponseRewrite {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Content Type")
                            .appFont(.caption, scale: appTextScale, weight: .semibold)
                            .foregroundStyle(.secondary)
                        TextField("application/json", text: $contentTypeText)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Toggle("Force no-cache", isOn: $forceNoCache)
                    .help("Strips ETag/Last-Modified and forces Cache-Control: no-store on this rule's response, regardless of the global Settings no-caching toggle. Only helps clients that respect HTTP cache headers.")
            }

            Group {
                switch rule.sourceKind {
                case .capturedResponse:
                    GroupBox {
                        Text("This override reuses the captured response body. Editing here updates the label, status code, and content type while preserving the stored body.")
                            .appFont(.subheadline, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .inlineText:
                    GroupBox {
                        InlineOverrideBodyEditor(
                            bodyText: $inlineBodyText,
                            contentTypeText: $contentTypeText,
                            jsonViewMode: $inlineJSONViewMode
                        )
                    } label: {
                        Text("Inline Response Body")
                            .appFont(.headline, scale: appTextScale, weight: .semibold)
                    }
                case .localFile:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Button(selectedFileURL == nil ? "Choose Local File…" : "Choose Different File…") {
                                    isFileImporterPresented = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if let selectedFileURL {
                                    Text(selectedFileURL.lastPathComponent)
                                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text("JoesProxy reads the selected file when a matching request arrives, so changes on disk are picked up on the next request.")
                                .appFont(.caption, scale: appTextScale)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .block:
                    GroupBox {
                        Text("Matching requests will be dropped. JoesProxy returns the status code above without contacting the upstream server.")
                            .appFont(.subheadline, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .mapRemote:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Remote Host")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                        .foregroundStyle(.secondary)
                                    TextField("api.example.com", text: $remoteHostText)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Port")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                        .foregroundStyle(.secondary)
                                    TextField("443", text: $remotePortText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Scheme")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                        .foregroundStyle(.secondary)
                                    Picker("Scheme", selection: $remoteSchemeSelection) {
                                        Text("HTTP").tag(SessionScheme.http)
                                        Text("HTTPS").tag(SessionScheme.https)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 120)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Destination Path (optional)")
                                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                                    .foregroundStyle(.secondary)
                                TextField("/new/path — leave blank to keep the original path", text: $remotePathText)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Text("Matching requests are forwarded to this host instead of the original destination. The original query string is preserved. Leave the path blank to also keep the original path.")
                                .appFont(.caption, scale: appTextScale)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Remote Destination")
                            .appFont(.headline, scale: appTextScale, weight: .semibold)
                    }
                case .bookmarkRewrite:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Matching requests are replaced with the full saved bookmark request before JoesProxy contacts upstream.")
                                .appFont(.subheadline, scale: appTextScale)
                                .foregroundStyle(.secondary)

                            if let rewriteRequest = rule.bookmarkRewriteRequest {
                                Text(verbatim: "Rewrite: \(rewriteRequest.method) \(rewriteRequest.scheme.rawValue)://\(rewriteRequest.host)\(rewriteRequest.path)")
                                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .liveResponseRewrite:
                    GroupBox {
                        LiveResponseRewriteEditor(drafts: $liveRewriteDrafts)
                    } label: {
                        Text("JSON Field Rewrites")
                            .appFont(.headline, scale: appTextScale, weight: .semibold)
                    }
                case .collectionMock:
                    GroupBox {
                        Text("Matching requests are forwarded to the real backend and a reviewed collection-shape mutation is applied to the response. This rule is created and managed through the collection-mock authoring/activation workflow and has no editable fields here.")
                            .appFont(.subheadline, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .fixtureRun:
                    GroupBox {
                        Text("Matching requests are served by a running HLS fixture run instead of a static body. This rule is created and managed through the MCP/CLI fixture-redirect workflow and has no editable fields here.")
                            .appFont(.subheadline, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .localDirectory:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Matching path-prefix requests are served from files in the chosen folder (index.html for trailing /, live disk reads per request).")
                                .appFont(.subheadline, scale: appTextScale)
                                .foregroundStyle(.secondary)
                            HStack {
                                Text(selectedDirectoryURL?.lastPathComponent ?? "No folder selected")
                                    .appFont(.body, scale: appTextScale, design: .monospaced)
                                    .lineLimit(1)
                                Spacer()
                                Button("Choose Folder…") {
                                    MapLocalSheet.presentDirectoryPicker { url in
                                        selectedDirectoryURL = url
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()

                Button("Save Changes") {
                    switch rule.sourceKind {
                    case .capturedResponse:
                        guard let statusCode = resolvedStatusCode else { return }
                        onSaveCaptured(labelText.nilIfBlank, selectedMatchMode, resolvedMatchPath, statusCode, contentTypeText.nilIfBlank, forceNoCache)
                    case .inlineText:
                        guard let statusCode = resolvedStatusCode else { return }
                        onSaveInline(labelText.nilIfBlank, selectedMatchMode, resolvedMatchPath, statusCode, contentTypeText.nilIfBlank, inlineBodyText, forceNoCache)
                    case .localFile:
                        guard let statusCode = resolvedStatusCode, let selectedFileURL else { return }
                        onSaveFile(labelText.nilIfBlank, selectedMatchMode, resolvedMatchPath, statusCode, contentTypeText.nilIfBlank, selectedFileURL, forceNoCache)
                    case .localDirectory:
                        guard let selectedDirectoryURL else { return }
                        onSaveDirectory(labelText.nilIfBlank, resolvedMatchPath, selectedDirectoryURL, forceNoCache)
                    case .block:
                        guard let statusCode = resolvedStatusCode else { return }
                        onSaveBlock(labelText.nilIfBlank, selectedMatchMode, resolvedMatchPath, statusCode)
                    case .mapRemote:
                        let resolvedPort = Int(remotePortText.trimmingCharacters(in: .whitespacesAndNewlines))
                        let trimmedPath = remotePathText.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSaveMapRemote(labelText.nilIfBlank, selectedMatchMode, resolvedMatchPath, remoteHostText, resolvedPort, remoteSchemeSelection, trimmedPath.isEmpty ? nil : trimmedPath)
                    case .bookmarkRewrite:
                        break
                    case .liveResponseRewrite:
                        onSaveLiveResponseRewrite(
                            labelText.nilIfBlank,
                            selectedMatchMode,
                            resolvedMatchPath,
                            liveRewriteDrafts.map { $0.toRewrite() }
                        )
                    case .collectionMock:
                        // Unreachable: `canSave` is always false for this source kind, disabling
                        // the button.
                        break
                    case .fixtureRun:
                        // Unreachable: `canSave` is always false for this source kind, disabling
                        // the button.
                        break
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 720, minHeight: 420)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result {
                selectedFileURL = urls.first
            }
        }
    }

    private static func currentContentType(from headers: [HTTPHeaderField]) -> String {
        headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value ?? ""
    }

    private static func initialJSONViewMode(contentType: String, bodyText: String) -> InlineJSONEditorMode {
        let mimeType = contentType
            .split(separator: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if mimeType.contains("json") || mimeType.hasSuffix("+json") || InlineOverrideBodyEditor.prettyPrintedJSONString(from: bodyText) != nil {
            return .prettified
        }
        return .raw
    }
}

struct MapLocalSheet: View {
    @Environment(\.appTextScale) private var appTextScale

    let session: SessionRecord
    let existingOverrides: [ResponseOverrideRule]
    let onCreateCapturedResponse: (String?, ResponseOverrideMatchMode, String, ResponseOverrideConflictStrategy, Bool) -> Void
    let onCreateInlineOverride: (String?, ResponseOverrideMatchMode, String, ResponseOverrideConflictStrategy, Int, String?, String, Bool) -> Void
    let onCreateFileBackedOverride: (String?, ResponseOverrideMatchMode, String, ResponseOverrideConflictStrategy, Int, String?, URL, Bool) -> Void
    /// Creates a local-directory Map Local rule. Match mode is always pathPrefix.
    let onCreateDirectoryBackedOverride: (String?, String, ResponseOverrideConflictStrategy, URL, Bool) -> Void
    /// Called when the user confirms a block rule. Parameters: label, matchMode, matchPath, statusCode.
    let onCreateBlockRule: (String?, ResponseOverrideMatchMode, String, Int) -> Void
    /// Called when the user confirms a map-remote rule. Parameters: label, matchMode, matchPath, remoteHost, remotePort, remoteScheme, remotePath.
    let onCreateMapRemoteRule: (String?, ResponseOverrideMatchMode, String, String, Int?, SessionScheme, String?) -> Void
    /// Called when the user confirms a live-response rewrite rule.
    let onCreateLiveResponseRewrite: (String?, ResponseOverrideMatchMode, String, String, JSONMutationOperation, BookmarkJSONValue) -> Void
    let onOpenHLSTestStream: () -> Void
    let onCancel: () -> Void

    @State private var selectedSourceKind: ResponseOverrideSourceKind = .capturedResponse
    @State private var matchMode: ResponseOverrideMatchMode = .exactPath
    /// The exact string matched against the request path — editable so a user isn't stuck with the
    /// full captured path when switching to Path Suffix (see AQ: previously this silently reused the
    /// whole captured path with no way to shorten it to e.g. just the filename).
    @State private var matchPath: String = "/"
    /// The originally-captured full path, kept separately from `matchPath` so switching to Path
    /// Suffix can default to just the filename *only* when the user hasn't already customized the
    /// field — never clobbers a manual edit.
    private let capturedPath: String
    /// AR: forces `no-store`/stripped caching headers on this rule's response regardless of the
    /// global/per-domain no-caching Settings toggle. Only offered for source kinds that serve a
    /// response body directly (captured/inline/file) — Map Remote/live rewrite already have the
    /// real upstream no-caching path available via Settings.
    @State private var forceNoCache = false
    @State private var conflictStrategy: ResponseOverrideConflictStrategy
    @State private var overrideLabel: String
    @State private var statusCodeText: String
    @State private var contentType: String
    @State private var inlineBodyText: String
    @State private var inlineJSONViewMode: InlineJSONEditorMode
    @State private var selectedFileURL: URL?
    @State private var isFileImporterPresented = false
    @State private var selectedDirectoryURL: URL?
    @State private var remoteHostText: String = ""
    @State private var remotePortText: String = ""
    @State private var remoteScheme: SessionScheme = .https
    @State private var remotePathText: String = ""
    @State private var liveRewritePath: String = ""
    @State private var liveRewriteOperation: JSONMutationOperation = .set
    @State private var liveRewriteValueText: String = "true"

    init(
        session: SessionRecord,
        existingOverrides: [ResponseOverrideRule],
        onCreateCapturedResponse: @escaping (String?, ResponseOverrideMatchMode, String, ResponseOverrideConflictStrategy, Bool) -> Void,
        onCreateInlineOverride: @escaping (String?, ResponseOverrideMatchMode, String, ResponseOverrideConflictStrategy, Int, String?, String, Bool) -> Void,
        onCreateFileBackedOverride: @escaping (String?, ResponseOverrideMatchMode, String, ResponseOverrideConflictStrategy, Int, String?, URL, Bool) -> Void,
        onCreateDirectoryBackedOverride: @escaping (String?, String, ResponseOverrideConflictStrategy, URL, Bool) -> Void,
        onCreateBlockRule: @escaping (String?, ResponseOverrideMatchMode, String, Int) -> Void,
        onCreateMapRemoteRule: @escaping (String?, ResponseOverrideMatchMode, String, String, Int?, SessionScheme, String?) -> Void,
        onCreateLiveResponseRewrite: @escaping (String?, ResponseOverrideMatchMode, String, String, JSONMutationOperation, BookmarkJSONValue) -> Void,
        onOpenHLSTestStream: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self.existingOverrides = existingOverrides
        self.onCreateCapturedResponse = onCreateCapturedResponse
        self.onCreateInlineOverride = onCreateInlineOverride
        self.onCreateFileBackedOverride = onCreateFileBackedOverride
        self.onCreateDirectoryBackedOverride = onCreateDirectoryBackedOverride
        self.onCreateBlockRule = onCreateBlockRule
        self.onCreateMapRemoteRule = onCreateMapRemoteRule
        self.onCreateLiveResponseRewrite = onCreateLiveResponseRewrite
        self.onOpenHLSTestStream = onOpenHLSTestStream
        self.onCancel = onCancel
        let response = session.response
        let detectedContentType = response?.headers.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value ?? ""
        let normalizedPath = session.request.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : session.request.path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.capturedPath = normalizedPath
        _matchPath = State(initialValue: normalizedPath)
        let normalizedPort = session.request.port ?? (session.request.scheme == .https ? 443 : 80)
        let existingMatchCount = existingOverrides.filter { rule in
            rule.requestMethod.caseInsensitiveCompare(session.request.method) == .orderedSame &&
            rule.requestScheme == session.request.scheme &&
            rule.host.caseInsensitiveCompare(session.request.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == .orderedSame &&
            (rule.port ?? (rule.requestScheme == .https ? 443 : 80)) == normalizedPort &&
            rule.path == normalizedPath &&
            rule.matchMode == .exactPath
        }.count
        _conflictStrategy = State(initialValue: existingMatchCount > 0 ? .replaceExisting : .keepBoth)
        _overrideLabel = State(initialValue: "")
        // Deliberately NOT `response?.statusCode` — inheriting a captured error status (e.g. 404)
        // into a local-content replacement silently serves correct bytes under a status most
        // clients discard/negatively-cache without any error surfaced here. Directory Map Local
        // already hardcodes 200 for the same reason (`ResponseOverrides.swift`); this brings the
        // inline/single-file/Block creation flow in line with it. A deliberate non-2xx (e.g. for a
        // Block rule simulating an error) remains a one-field edit away, just no longer the default.
        _statusCodeText = State(initialValue: "200")
        _contentType = State(initialValue: detectedContentType)
        let initialBodyText = Self.inlineTextSeed(from: response?.bodyData)
        _inlineBodyText = State(initialValue: initialBodyText)
        _inlineJSONViewMode = State(initialValue: Self.initialJSONViewMode(contentType: detectedContentType, bodyText: initialBodyText))
    }

    private var canUseLiveResponseRewrite: Bool {
        guard let bodyData = session.response?.bodyData, !bodyData.isEmpty else {
            return false
        }
        return (try? JSONTreeParser.parseJSONObject(from: bodyData)) != nil
    }

    private var canUseHLSTestStream: Bool {
        let path = String(session.request.path.split(separator: "?", maxSplits: 1).first ?? "")
        if path.lowercased().hasSuffix(".m3u8") { return true }
        let contentType = session.response?.headers.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.lowercased() ?? ""
        return contentType.contains("mpegurl")
    }

    private var creatableSourceKinds: [ResponseOverrideSourceKind] {
        var kinds = ResponseOverrideSourceKind.creatableFromCapturedSession
        if canUseLiveResponseRewrite {
            kinds.append(.liveResponseRewrite)
        }
        return kinds
    }

    private var parsedLiveRewriteValue: BookmarkJSONValue? {
        BookmarkJSONValue.fromUserInput(liveRewriteValueText, mode: .json)
    }

    private var exactMatchOverrideCount: Int {
        existingOverrides.filter { rule in
            rule.requestMethod.caseInsensitiveCompare(session.request.method) == .orderedSame &&
            rule.requestScheme == session.request.scheme &&
            rule.host.caseInsensitiveCompare(session.request.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == .orderedSame &&
            normalizedPort(rule.port, scheme: rule.requestScheme) == normalizedPort(session.request.port, scheme: session.request.scheme) &&
            pathMatches(
                rulePath: normalizedPathForMatch(rule.path, mode: rule.matchMode),
                requestPath: normalizedPathForMatch(normalizedPath(session.request.path), mode: matchMode),
                mode: rule.matchMode == .pathPrefix || matchMode == .pathPrefix ? .pathPrefix : matchMode
            )
        }.count
    }

    private var canUseInlineText: Bool {
        guard let bodyData = session.response?.bodyData, !bodyData.isEmpty else {
            return true
        }

        return String(data: bodyData, encoding: .utf8) != nil
    }

    private var resolvedStatusCode: Int? {
        Int(statusCodeText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Non-nil only for source kinds whose whole purpose is to replace content with locally-owned
    /// bytes (captured/inline/single-file) — a non-2xx status there is very likely an oversight
    /// (most clients discard or negatively-cache such a response) rather than intentional, unlike
    /// `.block`, whose entire purpose is often to simulate exactly this kind of error.
    private var nonSuccessStatusWarning: String? {
        guard [.capturedResponse, .inlineText, .localFile].contains(selectedSourceKind),
              let status = resolvedStatusCode,
              !(200...299).contains(status) else {
            return nil
        }
        return "Status \(status) is not a success code — most clients will discard this content or "
            + "negatively cache the URL instead of using it. Only intentional if you're deliberately "
            + "simulating an error response."
    }

    /// Warns when the originally captured session had a 4xx/5xx status, alerting the user
    /// that the client app might have cached that failure on-disk.
    private var priorCapturedErrorWarning: String? {
        guard let priorStatus = session.response?.statusCode, priorStatus >= 400 else {
            return nil
        }
        return "The original captured response was HTTP \(priorStatus). Target apps may have cached this error on-disk. If mocked content does not appear, force-quit the app or use a cache-busted path."
    }

    /// Mirrors `ResponseOverrideStore`'s own `normalizePath` fallback so the UI and the store agree
    /// on what an empty field means.
    private var resolvedMatchPath: String {
        let trimmed = matchPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/" : trimmed
    }

    static func lastPathComponent(of path: String) -> String {
        let withoutQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        guard let last = withoutQuery.split(separator: "/", omittingEmptySubsequences: true).last else {
            return path
        }
        return String(last)
    }

    /// Presents an `NSOpenPanel` configured for a single directory (security-scoped access).
    static func presentDirectoryPicker(onPicked: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onPicked(url)
        }
    }

    private var canCreate: Bool {
        guard !resolvedMatchPath.isEmpty else {
            return false
        }

        switch selectedSourceKind {
        case .capturedResponse:
            return resolvedStatusCode != nil
        case .inlineText:
            return resolvedStatusCode != nil && canUseInlineText
        case .localFile:
            return resolvedStatusCode != nil && selectedFileURL != nil
        case .localDirectory:
            return selectedDirectoryURL != nil && matchMode == .pathPrefix
        case .block:
            return resolvedStatusCode != nil
        case .mapRemote:
            return !remoteHostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .liveResponseRewrite:
            return !liveRewritePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedLiveRewriteValue != nil
        case .bookmarkRewrite, .fixtureRun, .collectionMock:
            // Not in `creatableSourceKinds`; this sheet never offers any of these as a selectable
            // option, so `selectedSourceKind` can never actually equal them here.
            return false
        }
    }

    private var sheetTitle: String {
        switch selectedSourceKind {
        case .block: return "Block Request"
        case .mapRemote: return "Map Remote"
        case .liveResponseRewrite: return "Live Response Rewrite"
        case .bookmarkRewrite: return "Bookmark Rewrite"
        default: return "Map Local"
        }
    }

    private var resolvedRemotePort: Int? {
        let trimmed = remotePortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sheetTitle)
                        .appFont(.title3, scale: appTextScale, weight: .semibold)

                    Text("Match on method, host, scheme, port, and path for \(session.request.method) \(session.request.host)\(session.request.path).")
                        .appFont(.subheadline, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if canUseHLSTestStream {
                HStack(spacing: 12) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HLS Test Stream")
                            .appFont(.subheadline, scale: appTextScale, weight: .semibold)
                        Text("Replace this playlist and its child requests with a bundled test pattern, tone, and timecode.")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Configure…") {
                        onOpenHLSTestStream()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("mapLocalHLSTestStreamButton")
                }
                .padding(12)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            Picker("Source", selection: $selectedSourceKind) {
                ForEach(creatableSourceKinds) { sourceKind in
                    Text(sourceKind.title).tag(sourceKind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedSourceKind) { _, newKind in
                if newKind == .localDirectory {
                    matchMode = .pathPrefix
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Label")
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.secondary)
                    TextField("Optional rule label", text: $overrideLabel)
                        .textFieldStyle(.roundedBorder)
                }

                if selectedSourceKind != .mapRemote && selectedSourceKind != .liveResponseRewrite && selectedSourceKind != .localDirectory {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status Code")
                            .appFont(.caption, scale: appTextScale, weight: .semibold)
                            .foregroundStyle(.secondary)
                        TextField("200", text: $statusCodeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Match")
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.secondary)
                    if selectedSourceKind == .localDirectory {
                        Text(ResponseOverrideMatchMode.pathPrefix.title)
                            .appFont(.body, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .help("Local Directory requires Path Prefix so each URL under the matcher maps to a file in the folder.")
                    } else {
                        Picker("Match", selection: $matchMode) {
                            ForEach(ResponseOverrideMatchMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .help(matchMode.description)
                        .onChange(of: matchMode) { _, newMode in
                            // Only auto-shorten to the filename if the field still holds the untouched
                            // captured path — never overwrite a value the user already edited by hand.
                            if newMode == .pathSuffix, matchPath == capturedPath {
                                matchPath = Self.lastPathComponent(of: capturedPath)
                            }
                        }
                    }
                }
            }

            if let nonSuccessStatusWarning {
                Label(nonSuccessStatusWarning, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.orange)
            }

            if let priorCapturedErrorWarning {
                Label(priorCapturedErrorWarning, systemImage: "info.circle.fill")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(matchMode == .pathSuffix ? "Path Suffix" : "Path")
                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                    .foregroundStyle(.secondary)
                TextField(capturedPath, text: $matchPath)
                    .textFieldStyle(.roundedBorder)
                    .help("The exact string matched against the request path — edit this to control what \(matchMode.title) actually matches, e.g. shorten to just a filename for Path Suffix.")
            }

            if selectedSourceKind != .block && selectedSourceKind != .mapRemote && selectedSourceKind != .liveResponseRewrite {
                if selectedSourceKind != .localDirectory {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Content Type")
                                .appFont(.caption, scale: appTextScale, weight: .semibold)
                                .foregroundStyle(.secondary)
                            TextField("application/json", text: $contentType)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                Toggle("Force no-cache", isOn: $forceNoCache)
                    .help("Strips ETag/Last-Modified and forces Cache-Control: no-store on this rule's response, regardless of the global Settings no-caching toggle. Only helps clients that respect HTTP cache headers — an app with its own URL-keyed object cache won't be affected; check whether it even re-requests the URL after this rule is live.")
            }

            if exactMatchOverrideCount > 0 {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            exactMatchOverrideCount == 1 ? "Existing Exact-Match Override" : "Existing Exact-Match Overrides",
                            systemImage: "exclamationmark.triangle"
                        )
                        .appFont(.subheadline, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(.orange)

                        Text("This request target already has \(exactMatchOverrideCount) local override\(exactMatchOverrideCount == 1 ? "" : "s"). Choose whether to replace those rules or keep both.")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)

                        Picker("Conflict Handling", selection: $conflictStrategy) {
                            ForEach(ResponseOverrideConflictStrategy.allCases) { strategy in
                                Text(strategy.title).tag(strategy)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Group {
                switch selectedSourceKind {
                case .capturedResponse:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Use the captured response exactly as it was recorded.")
                                .appFont(.subheadline, scale: appTextScale)
                                .foregroundStyle(.secondary)

                            Text("Headers and body are copied from the selected session response. Content-Length and Connection are regenerated automatically.")
                                .appFont(.caption, scale: appTextScale)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .inlineText:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            if canUseInlineText {
                                InlineOverrideBodyEditor(
                                    bodyText: $inlineBodyText,
                                    contentTypeText: $contentType,
                                    jsonViewMode: $inlineJSONViewMode
                                )
                            } else {
                                Text("The captured response body is binary, so inline text editing is not available for this session. Choose Local File instead.")
                                    .appFont(.subheadline, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Inline Response Body")
                            .appFont(.headline, scale: appTextScale, weight: .semibold)
                    }
                case .localFile:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Button(selectedFileURL == nil ? "Choose Local File…" : "Choose Different File…") {
                                    isFileImporterPresented = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if let selectedFileURL {
                                    Text(selectedFileURL.lastPathComponent)
                                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text("JoesProxy reads the selected file when a matching request arrives, so changes on disk are picked up on the next request.")
                                .appFont(.caption, scale: appTextScale)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .localDirectory:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Serve every file under this folder for URLs beneath the path prefix. Trailing slash resolves to index.html when present; edits on disk apply on the next request.")
                                .appFont(.subheadline, scale: appTextScale)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Button(selectedDirectoryURL == nil ? "Choose Folder…" : "Choose Different Folder…") {
                                    Self.presentDirectoryPicker { url in
                                        selectedDirectoryURL = url
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if let selectedDirectoryURL {
                                    Text(selectedDirectoryURL.lastPathComponent)
                                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .block:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Matching requests will be dropped immediately. The client receives a \(statusCodeText.isEmpty ? "503" : statusCodeText) response with no upstream connection.")
                                .appFont(.subheadline, scale: appTextScale)
                                .foregroundStyle(.secondary)

                            Text("Use this to test how your app handles network errors, service outages, or blocked endpoints.")
                                .appFont(.caption, scale: appTextScale)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .mapRemote:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Scheme")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                        .foregroundStyle(.secondary)
                                    Picker("Scheme", selection: $remoteScheme) {
                                        Text("HTTPS").tag(SessionScheme.https)
                                        Text("HTTP").tag(SessionScheme.http)
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 120)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Remote Host")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                        .foregroundStyle(.secondary)
                                    TextField("staging-api.example.com", text: $remoteHostText)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Port (optional)")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                        .foregroundStyle(.secondary)
                                    TextField("443", text: $remotePortText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Destination Path (optional)")
                                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                                    .foregroundStyle(.secondary)
                                TextField("/new/path — leave blank to keep the original path", text: $remotePathText)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Text("The original method, headers, and body are forwarded to the remote host unchanged, along with the original query string. Leave the destination path blank to also keep the original path.")
                                .appFont(.caption, scale: appTextScale)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .bookmarkRewrite:
                    EmptyView()
                case .liveResponseRewrite:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("The request reaches the real backend. JoesProxy may patch JSON fields in the returned response (fail-open when a mutation cannot apply).")
                                .appFont(.subheadline, scale: appTextScale)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("JSON Path")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                        .foregroundStyle(.secondary)
                                    TextField("flag", text: $liveRewritePath)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Operation")
                                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                                        .foregroundStyle(.secondary)
                                    Picker("Operation", selection: $liveRewriteOperation) {
                                        ForEach(JSONMutationOperation.allCases, id: \.self) { operation in
                                            Text(operation.title).tag(operation)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 140)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Override Value (JSON)")
                                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                                    .foregroundStyle(.secondary)
                                TextField(#"true"#, text: $liveRewriteValueText)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .fixtureRun:
                    // Unreachable: not in `creatableSourceKinds`, so this sheet never selects it.
                    EmptyView()
                case .collectionMock:
                    // Unreachable: not in `creatableSourceKinds`, so this sheet never selects it.
                    EmptyView()
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()

                Button("Create Rule") {
                    switch selectedSourceKind {
                    case .capturedResponse:
                        onCreateCapturedResponse(overrideLabel.nilIfBlank, matchMode, resolvedMatchPath, conflictStrategy, forceNoCache)
                    case .inlineText:
                        if let statusCode = resolvedStatusCode {
                            onCreateInlineOverride(overrideLabel.nilIfBlank, matchMode, resolvedMatchPath, conflictStrategy, statusCode, contentType.nilIfBlank, inlineBodyText, forceNoCache)
                        }
                    case .localFile:
                        if let statusCode = resolvedStatusCode, let selectedFileURL {
                            onCreateFileBackedOverride(overrideLabel.nilIfBlank, matchMode, resolvedMatchPath, conflictStrategy, statusCode, contentType.nilIfBlank, selectedFileURL, forceNoCache)
                        }
                    case .localDirectory:
                        if let selectedDirectoryURL {
                            onCreateDirectoryBackedOverride(overrideLabel.nilIfBlank, resolvedMatchPath, conflictStrategy, selectedDirectoryURL, forceNoCache)
                        }
                    case .block:
                        let statusCode = resolvedStatusCode ?? 503
                        onCreateBlockRule(overrideLabel.nilIfBlank, matchMode, resolvedMatchPath, statusCode)
                    case .mapRemote:
                        let host = remoteHostText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !host.isEmpty else { return }
                        let trimmedRemotePath = remotePathText.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCreateMapRemoteRule(overrideLabel.nilIfBlank, matchMode, resolvedMatchPath, host, resolvedRemotePort, remoteScheme, trimmedRemotePath.isEmpty ? nil : trimmedRemotePath)
                    case .bookmarkRewrite:
                        break
                    case .liveResponseRewrite:
                        guard let value = parsedLiveRewriteValue else { return }
                        onCreateLiveResponseRewrite(
                            overrideLabel.nilIfBlank,
                            matchMode,
                            resolvedMatchPath,
                            liveRewritePath.trimmingCharacters(in: .whitespacesAndNewlines),
                            liveRewriteOperation,
                            value
                        )
                    case .fixtureRun:
                        // Unreachable: not in `creatableSourceKinds`, so this sheet never selects it.
                        break
                    case .collectionMock:
                        // Unreachable: not in `creatableSourceKinds`, so this sheet never selects it.
                        break
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 720, minHeight: 420)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result {
                selectedFileURL = urls.first
            }
        }
    }

    static func inlineTextSeed(from bodyData: Data?) -> String {
        guard let bodyData, !bodyData.isEmpty else {
            return ""
        }

        if let prettyPrinted = prettyPrintedJSONString(from: bodyData) {
            return prettyPrinted
        }

        return String(data: bodyData, encoding: .utf8) ?? ""
    }

    private static func prettyPrintedJSONString(from data: Data) -> String? {
        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            let prettyPrintedData = try? JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            return nil
        }

        return String(data: prettyPrintedData, encoding: .utf8)
    }

    private static func initialJSONViewMode(contentType: String, bodyText: String) -> InlineJSONEditorMode {
        let mimeType = contentType
            .split(separator: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if mimeType.contains("json") || mimeType.hasSuffix("+json") || InlineOverrideBodyEditor.prettyPrintedJSONString(from: bodyText) != nil {
            return .prettified
        }
        return .raw
    }

    private func normalizedPath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPath.isEmpty ? "/" : trimmedPath
    }

    private func normalizedPort(_ port: Int?, scheme: SessionScheme) -> Int {
        if let port {
            return port
        }

        switch scheme {
        case .http:
            return 80
        case .https:
            return 443
        }
    }

    private func normalizedPathForMatch(_ path: String, mode: ResponseOverrideMatchMode) -> String {
        switch mode {
        case .exactPath:
            return path
        case .ignoreQuery, .pathPrefix, .pathSuffix, .filename:
            return String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/")
        }
    }

    private func pathMatches(rulePath: String, requestPath: String, mode: ResponseOverrideMatchMode) -> Bool {
        switch mode {
        case .exactPath, .ignoreQuery:
            return rulePath == requestPath
        case .pathPrefix:
            if rulePath == "/" {
                return true
            }
            return requestPath == rulePath || requestPath.hasPrefix(rulePath.hasSuffix("/") ? rulePath : "\(rulePath)/")
        case .pathSuffix:
            return requestPath.hasSuffix(rulePath)
        case .filename:
            return lastPathComponent(of: rulePath) == lastPathComponent(of: requestPath)
        }
    }

    private func lastPathComponent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmedValue = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

struct EffectBundleRow: View {
    @Environment(\.appTextScale) private var appTextScale
    @State private var confirmingDiscard = false
    let record: EffectBundleRecord
    var activationFocus: FocusState<UUID?>.Binding
    let onActivate: () -> Void
    let onStop: () -> Void
    let onDiscard: () -> Void
    var recoveryAvailability: (EffectBundleDeliveryReceipt) -> EffectBundleRecoveryAvailability = { _ in
        .init(receiptExists: true, resourceExists: false, captureExists: false, bundleServing: false)
    }
    var performRecovery: (EffectBundleRecoveryAction, EffectBundleDeliveryReceipt) -> String? = { _, _ in
        "Recovery destination unavailable."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(record.manifest.name)
                        .appFont(.body, scale: appTextScale, weight: .medium)
                    stateBadge
                        .accessibilityIdentifier("effectBundleState-\(record.id.uuidString)")
                }
                Text("Bundle ID: \(record.id.uuidString)")
                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("effectBundleIdentity-\(record.id.uuidString)")
                if let authoring = record.manifest.authoring {
                    Text("Revision: \(authoring.revisionID.uuidString)")
                        .accessibilityIdentifier("effectBundleRevision-\(record.id.uuidString)")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .textSelection(.enabled)
                }
                Text("Imported \(record.importedAt.formatted(date: .abbreviated, time: .shortened))")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                Text("Response rule clients: \(EffectBundlePresentation.clientScopes(record).joined(separator: ", "))")
                    .appFont(.caption, scale: appTextScale)
                if let expiresAt = record.expiresAt {
                    Text("Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                        .appFont(.caption, scale: appTextScale)
                }
                if let message = record.cleanupMessage {
                    Text(message).appFont(.caption, scale: appTextScale).foregroundStyle(.orange)
                }
                if let reason = record.terminationReason {
                    Text("Run ended: \(reason.rawValue)").appFont(.caption, scale: appTextScale)
                }
                HStack(spacing: 12) {
                    Text("\(record.manifest.responseEffects.count) response rules")
                    Text("\(record.manifest.hlsSubstitutions.count) HLS substitutions")
                    Text("\(record.manifest.assets.count) assets")
                }
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)

                if !record.manifest.notes.isEmpty {
                    Text(record.manifest.notes)
                        .appFont(.caption2, scale: appTextScale)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if record.manifest.authoring != nil {
                    EffectBundleEvidenceView(bundleID: record.id, availability: recoveryAvailability, performRecovery: performRecovery)
                }
            }

            HStack {
            if record.isServing {
                Button("Stop") {
                    onStop()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Review Activation…") {
                    onActivate()
                }
                .focusable()
                .focused(activationFocus, equals: record.id)
                .accessibilityIdentifier("effectBundleReviewActivation-\(record.id.uuidString)")
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Menu("Actions") {
                Button("Copy Bundle ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.id.uuidString, forType: .string)
                }
                Button("Discard Bundle…", role: .destructive) {
                    confirmingDiscard = true
                }
                .disabled(record.isServing || record.owner != .localUser)
                .help(record.owner != .localUser
                    ? "Local supervision can activate, advance or stop this bundle. Removing its saved package remains owner-restricted."
                    : "Stop active effects before removing their saved package.")
            }
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("Discard bundle \(record.id.uuidString)?", isPresented: $confirmingDiscard) {
            Button("Discard Bundle", role: .destructive, action: onDiscard)
        } message: {
            Text("This removes the saved package. Stop active effects before discarding it.")
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch record.state {
        case .serving:
            Text("Serving")
                .appFont(.caption2, scale: appTextScale, weight: .bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        case .inactive:
            Text("Inactive")
                .appFont(.caption2, scale: appTextScale)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
        case .stopped:
            Text("Stopped")
                .appFont(.caption2, scale: appTextScale)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
        case .expired:
            Text("Expired")
                .appFont(.caption2, scale: appTextScale)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        case .cleanupRequired:
            Text("Cleanup Required")
                .appFont(.caption2, scale: appTextScale, weight: .semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(Capsule())
        }
    }
}
