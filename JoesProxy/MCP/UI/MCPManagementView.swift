import SwiftUI

/// MCP management panel with Overview, Clients, Data Access, Activity, and Disclosure Preview.
struct MCPManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var controller: MCPServerController
    @ObservedObject var selfValidationCoordinator: MCPSelfValidationCoordinator
    let textScale: CGFloat
    private let initialDestination: MCPPipelineStatus.ManagementDestination
    private let navigationRequestID: UUID?
    @State private var selectedSection: MCPManagementSection
    @State private var selectedClientKind = MCPClientKind.joesProxyCLI
    @State private var selectedProfileID: MCPDisclosureProfileID = .metadataOnly
    @State private var customClientName = ""
    @State private var enrollmentCredential: String?
    @State private var enrollmentClientLabel = ""
    @State private var enrollmentClientID: String?
    @State private var enrollmentClientKind: MCPClientKind = .joesProxyCLI
    @State private var statusMessage: String?
    @State private var clientPendingRevoke: MCPClientRecord?
    @State private var clientPendingRotate: MCPClientRecord?
    @State private var previewClientID: String?
    @State private var previewUsesSyntheticFixture = true
    @State private var previewSessionID: SessionRecord.ID?
    @State private var previewEnvelope: MCPDisclosurePreviewEngine.Envelope?
    @State private var effectInventory: [MCPEffectInventoryItem] = []
    @State private var recoverySummary: MCPRecoverySummary?
    @State private var showRecoverySummary = false
    @State private var showRevokeAllConfirm = false
    @State private var showResetConfigConfirm = false
    @State private var showDeleteAllConfirm = false
    @State private var showEraseAuditConfirm = false
    @State private var showNewAgentRunSheet = false
    @State private var newAgentRunHypothesis = ""
    @State private var newAgentRunExpected = ""
    @State private var newAgentRunHost = ""
    @State private var newAgentRunPath = ""
    @State private var newAgentRunSessionID = ""
    @State private var pendingDeleteItem: MCPEffectInventoryItem?
    @State private var selectedClientIDs: Set<String> = []
    @State private var showRemoveSelectedClientsConfirm = false
    @State private var expandedRecapClientIDs: Set<String> = []

    init(
        controller: MCPServerController,
        selfValidationCoordinator: MCPSelfValidationCoordinator,
        textScale: CGFloat,
        initialDestination: MCPPipelineStatus.ManagementDestination = .overview,
        navigationRequestID: UUID? = nil
    ) {
        self.controller = controller
        self.selfValidationCoordinator = selfValidationCoordinator
        self.textScale = textScale
        self.initialDestination = initialDestination
        self.navigationRequestID = navigationRequestID
        _selectedSection = State(initialValue: MCPManagementSection(destination: initialDestination))
    }

    private var effectState: MCPEffectState {
        controller.recoveryCoordinator.effectState
    }

    private var compoundUIState: MCPStatusProjection.CompoundUIState {
        MCPStatusProjection.compoundUIState(
            server: mcpServerStateProjection,
            effect: effectState
        )
    }

    private var mcpServerStateProjection: MCPServerState {
        MCPStatusProjection.projectServerState(
            controller.state,
            connectedClientCount: controller.connectedClientCount
        )
    }

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(MCPManagementSection.allCases) { section in
                    mcpManagementSidebarRow(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .navigationTitle("MCP")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let statusMessage {
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                            .appFont(.caption, scale: textScale)
                    }
                    switch selectedSection {
                    case .overview:
                        overviewSection
                    case .clients:
                        clientsSection
                    case .agentSetup:
                        agentSetupSection
                    case .dataAccess:
                        dataAccessSection
                    case .activity:
                        activitySection
                    case .disclosurePreview:
                        disclosurePreviewSection
                    case .approvals:
                        approvalsSection
                    case .scenarios:
                        scenariosSection
                    case .agentRuns:
                        agentRunsSection
                    case .effects:
                        effectsSection
                    }
                }
                .padding()
                .accessibilityIdentifier("mcpManagementDetail-\(selectedSection.rawValue)")
            }
            .navigationTitle(selectedSection.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("mcpManagementCloseButton")
                }
            }
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 760, minHeight: 520)
        .onDisappear { controller.artifactSources?.cancelUnsharedReviews() }
        .onChange(of: selectedSection) { oldValue, newValue in
            if oldValue == .approvals, newValue != .approvals { controller.artifactSources?.cancelUnsharedReviews() }
        }
        .onAppear {
            controller.refreshPendingApprovals()
        }
        .alert(
            "Revoke client?",
            isPresented: Binding(
                get: { clientPendingRevoke != nil },
                set: { if !$0 { clientPendingRevoke = nil } }
            ),
            presenting: clientPendingRevoke
        ) { client in
            Button("Revoke", role: .destructive) {
                revokeClient(client)
            }
            Button("Cancel", role: .cancel) {
                clientPendingRevoke = nil
            }
        } message: { client in
            Text("Revoking \(client.displayName) invalidates its bearer and active MCP sessions.")
        }
        .alert(
            "Rotate credential?",
            isPresented: Binding(
                get: { clientPendingRotate != nil },
                set: { if !$0 { clientPendingRotate = nil } }
            ),
            presenting: clientPendingRotate
        ) { client in
            Button("Rotate", role: client.credentialState == .revoked ? .destructive : nil) {
                rotateClient(client)
            }
            Button("Cancel", role: .cancel) {
                clientPendingRotate = nil
            }
        } message: { client in
            if client.credentialState == .revoked {
                Text("\(client.displayName) is revoked. Rotating issues a new bearer and reactivates it.")
            } else {
                Text("Rotating \(client.displayName) invalidates its current bearer and active MCP sessions immediately.")
            }
        }
        .onChange(of: selectedSection) { _, newSection in
            if newSection == .disclosurePreview {
                refreshPreview()
            }
            if newSection == .effects {
                Task { await refreshEffectInventory() }
            }
        }
        .onChange(of: navigationRequestID) { _, _ in
            selectedSection = MCPManagementSection(destination: initialDestination)
        }
        .onChange(of: controller.enrolledClients.map(\.id)) { _, clientIDs in
            selectedClientIDs = selectedClientIDs.intersection(Set(clientIDs))
        }
        .onChange(of: previewClientID) { _, _ in refreshPreview() }
        .onChange(of: previewUsesSyntheticFixture) { _, _ in refreshPreview() }
        .onChange(of: previewSessionID) { _, _ in refreshPreview() }
        .sheet(isPresented: $showRecoverySummary) {
            if let recoverySummary {
                recoverySummarySheet(recoverySummary)
            }
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Loopback MCP server for Codex and Claude.")
                .appFont(.body, scale: textScale)
            HStack {
                Button(controller.state == .stopped ? "Start MCP" : "Stop MCP") {
                    Task {
                        if case .stopped = controller.state {
                            await controller.start()
                        } else {
                            await controller.stop()
                        }
                    }
                }
                .accessibilityIdentifier("mcpStartStopButton")
            }
            Toggle("Allow JoesProxy CLI to start MCP", isOn: $controller.isCLIAutomationStartEnabled)
                .accessibilityIdentifier("mcpCLIAutomationStartToggle")
            Text("Off by default. When enabled, a local process can launch JoesProxy and request that its loopback MCP server start. It cannot enroll clients or change policy.")
                .foregroundStyle(.secondary)
                .appFont(.caption, scale: textScale)
            HStack(spacing: 8) {
                Text("Local-server Map Remote (loopback destinations & authorized ports) applies across both GUI and MCP rules.")
                    .foregroundStyle(.secondary)
                    .appFont(.caption, scale: textScale)
                Button("Open Proxy Settings…") {
                    openSettings()
                }
                .controlSize(.small)
            }
            unattendedCLIReadinessSection
            statusLine
            if compoundUIState == .offActive || compoundUIState == .offConflict {
                serverOffEffectsWarning
            }
            recoveryActionButtons
            advancedRecoverySection
            Divider()
            if controller.enrolledClients.isEmpty {
                Text("No clients enrolled yet. Add one under Clients to get a one-time bearer token and ready-to-paste Codex/Claude config.")
                    .appFont(.caption, scale: textScale)
            } else {
                Text("\(controller.enrolledClients.count) client(s) enrolled. Manage tokens and copy config under Clients.")
                    .appFont(.caption, scale: textScale)
            }
            Button("Go to Clients →") {
                selectedSection = .clients
            }
            .accessibilityIdentifier("mcpGoToClientsButton")
        }
    }

    private var unattendedCLIReadinessSection: some View {
        let eligibleClients = controller.enrolledClients.filter(runtimeControlIsPreauthorized)
        let cleanupReady: Bool = {
            guard case .clean = effectState, case .idle = controller.operationState else { return false }
            return true
        }()
        let ready = controller.isCLIAutomationStartEnabled && !eligibleClients.isEmpty && cleanupReady
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            Label {
                Text(ready ? "Unattended CLI: Ready" : "Unattended CLI: Setup Required")
                    .appFont(.body, scale: textScale, weight: .semibold)
            } icon: {
                Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ready ? .green : .orange)
            }
            Text(unattendedReadinessDetail(eligibleClients: eligibleClients, cleanupReady: cleanupReady))
                .foregroundStyle(.secondary)
                .appFont(.caption, scale: textScale)
            if !ready {
                Button("Review Client Access") {
                    selectedSection = .clients
                }
                .accessibilityIdentifier("mcpReviewUnattendedAccessButton")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mcpUnattendedReadiness")
    }

    private func runtimeControlIsPreauthorized(_ client: MCPClientRecord) -> Bool {
        client.credentialState == .active
            && controller.policyEvaluator.profileAllows(
                capability: .runtimeControl,
                profileID: client.assignedProfileID
            )
            && !controller.grantStore.isAlwaysDenied(capability: .runtimeControl, clientID: client.id)
            && controller.grantStore.activeGrant(capability: .runtimeControl, clientID: client.id) != nil
    }

    private func unattendedReadinessDetail(
        eligibleClients: [MCPClientRecord],
        cleanupReady: Bool
    ) -> String {
        if !controller.isCLIAutomationStartEnabled {
            return "Enable CLI startup, then grant Runtime Control to the enrolled JoesProxy CLI client."
        }
        if eligibleClients.isEmpty {
            return "No active client has both Shareable access and a Runtime Control grant. Trigger a CLI runtime command, approve it, and choose Add To Client Policy."
        }
        if !cleanupReady {
            return "Runtime control is authorized, but active effects, approvals, scenarios, or operations currently block unattended MCP shutdown."
        }
        let names = eligibleClients.prefix(3).map(\.displayName).joined(separator: ", ")
        return "Authorized client\(eligibleClients.count == 1 ? "" : "s"): \(names). The CLI can start MCP and control the proxy without a new approval."
    }

    private var serverOffEffectsWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("MCP is off but MCP-created proxy effects may still be active.")
                    .appFont(.body, scale: textScale, weight: .semibold)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if case .conflict = effectState {
                Text("Unresolved conflicts require review before normal behavior can be claimed.")
                    .foregroundStyle(.secondary)
                    .appFont(.caption, scale: textScale)
            }
        }
        .accessibilityIdentifier("mcpServerOffEffectsWarning")
    }

    private var recoveryActionButtons: some View {
        HStack(spacing: 8) {
            Button("Review Effects") {
                selectedSection = .effects
            }
            .accessibilityIdentifier("mcpReviewEffectsButton")
            Button("Disable MCP-Created Effects") {
                Task { await runDisableEffects() }
            }
            .accessibilityIdentifier("mcpDisableEffectsButton")
            Button("Return To Normal") {
                Task { await runReturnToNormal() }
            }
            .accessibilityIdentifier("mcpReturnToNormalButton")
        }
    }

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MCP-created or MCP-modified proxy effects. Detached items are kept as yours and skipped by recovery.")
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
            recoveryActionButtons
            advancedRecoverySection
            if case .conflict(let conflicts) = effectState {
                conflictPanel(conflicts)
            }
            if effectInventory.isEmpty {
                Text("No MCP-origin effects in inventory.")
                    .appFont(.body, scale: textScale)
            } else {
                ForEach(effectInventory) { item in
                    effectInventoryRow(item)
                }
            }
        }
        .task { await refreshEffectInventory() }
    }

    private var advancedRecoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Advanced Recovery")
                .appFont(.headline, scale: textScale)
            Text("Destructive actions require confirmation and are not available as MCP tools.")
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Revoke All Clients") {
                    showRevokeAllConfirm = true
                }
                .accessibilityIdentifier("mcpRevokeAllClientsButton")
                Button("Reset MCP Configuration") {
                    showResetConfigConfirm = true
                }
                .accessibilityIdentifier("mcpResetConfigButton")
                Button("Delete MCP-Created Objects", role: .destructive) {
                    showDeleteAllConfirm = true
                }
                .accessibilityIdentifier("mcpDeleteAllObjectsButton")
                Button("Erase Audit History", role: .destructive) {
                    showEraseAuditConfirm = true
                }
                .accessibilityIdentifier("mcpEraseAuditButton")
            }
        }
        .accessibilityIdentifier("mcpAdvancedRecoverySection")
        .alert("Revoke all clients?", isPresented: $showRevokeAllConfirm) {
            Button("Revoke All", role: .destructive) {
                Task { await runRevokeAllClients() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Revokes credentials for \(controller.enrolledClients.count) enrolled client(s).")
        }
        .alert("Reset MCP configuration?", isPresented: $showResetConfigConfirm) {
            Button("Reset", role: .destructive) {
                Task { await runResetMCPConfiguration() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Revokes all credentials and clears all capability grants. Does not delete proxy effects or audit history.")
        }
        .alert("Delete all MCP-created objects?", isPresented: $showDeleteAllConfirm) {
            Button("Delete All", role: .destructive) {
                Task { await runDeleteAllMCPObjects() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently deletes \(effectInventory.filter { $0.mcpOrigin == .mcp }.count) MCP-origin effect(s). Detached items are skipped.")
        }
        .alert("Erase audit history?", isPresented: $showEraseAuditConfirm) {
            Button("Erase", role: .destructive) {
                Task { await runEraseAuditHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears MCP audit records. A single erase event will remain.")
        }
        .alert(
            "Delete MCP effect?",
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let item = pendingDeleteItem {
                    Task { await deleteInventoryItem(item) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteItem = nil
            }
        } message: {
            if let item = pendingDeleteItem {
                Text("Permanently delete \(item.displayLabel)?")
            }
        }
    }

    private func conflictPanel(_ conflicts: [MCPEffectConflictItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unresolved conflicts")
                .appFont(.headline, scale: textScale)
            ForEach(conflicts) { conflict in
                VStack(alignment: .leading, spacing: 4) {
                    Text(conflict.message)
                        .appFont(.body, scale: textScale)
                    HStack {
                        Button("Accept") {
                            Task { await resolveConflict(conflict.id, resolution: .accept) }
                        }
                        if conflict.targetID != nil {
                            Button("Retry restore") {
                                Task { await resolveConflict(conflict.id, resolution: .retryRestore) }
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .accessibilityIdentifier("mcpConflictPanel")
    }

    private func effectInventoryRow(_ item: MCPEffectInventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.displayLabel)
                    .appFont(.body, scale: textScale, weight: .semibold)
                Spacer()
                Text(item.isEnabled ? "Enabled" : "Disabled")
                    .foregroundStyle(item.isEnabled ? .orange : .secondary)
                    .appFont(.caption, scale: textScale)
            }
            Text(item.sanitizedTarget)
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if item.isEnabled {
                    Button("Disable") {
                        Task { await disableInventoryItem(item) }
                    }
                }
                if item.canRestore {
                    Button("Restore prior state") {
                        Task { await restoreInventoryItem(item) }
                    }
                }
                if item.canDetach && item.mcpOrigin == .mcp {
                    Button("Detach (keep as mine)") {
                        Task { await detachInventoryItem(item) }
                    }
                }
                if item.mcpOrigin == .mcp {
                    Button("Delete", role: .destructive) {
                        pendingDeleteItem = item
                    }
                    .accessibilityIdentifier("mcpDeleteEffectButton")
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func recoverySummarySheet(_ summary: MCPRecoverySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recovery summary")
                .appFont(.title3, scale: textScale, weight: .semibold)
            Text("Disabled: \(summary.disabledCount)")
                .appFont(.body, scale: textScale)
            Text("Restored: \(summary.restoredCount)")
                .appFont(.body, scale: textScale)
            if summary.serverStopped {
                Text("MCP server stopped.")
                    .appFont(.body, scale: textScale)
            }
            if summary.cleanupRequired {
                Text("Scenario cleanup is required before Return To Normal can fully succeed.")
                    .foregroundStyle(.orange)
                    .appFont(.body, scale: textScale)
            }
            if !summary.conflicts.isEmpty {
                Text("Unresolved conflicts: \(summary.conflicts.count)")
                    .foregroundStyle(.orange)
                    .appFont(.body, scale: textScale)
            }
            Button("Done") {
                showRecoverySummary = false
            }
        }
        .padding()
        .frame(minWidth: 360)
    }

    private func refreshEffectInventory() async {
        guard let recoveryService = controller.recoveryService else { return }
        effectInventory = await recoveryService.buildInventory()
    }

    private func runReturnToNormal() async {
        do {
            let summary = try await controller.returnToNormal()
            recoverySummary = summary
            showRecoverySummary = true
            statusMessage = "Return To Normal completed."
            await refreshEffectInventory()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func runDisableEffects() async {
        do {
            let summary = try await controller.disableMCPCreatedEffects()
            recoverySummary = summary
            showRecoverySummary = true
            statusMessage = "MCP-created effects disabled."
            await refreshEffectInventory()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func disableInventoryItem(_ item: MCPEffectInventoryItem) async {
        guard item.isEnabled else { return }
        do {
            try await controller.disableMCPEffect(itemID: item.id)
            statusMessage = "Disabled \(item.displayLabel)."
            await refreshEffectInventory()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func restoreInventoryItem(_ item: MCPEffectInventoryItem) async {
        do {
            try await controller.restoreMCPEffect(itemID: item.id)
            statusMessage = "Restored \(item.displayLabel)."
            await refreshEffectInventory()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func detachInventoryItem(_ item: MCPEffectInventoryItem) async {
        do {
            try await controller.detachMCPEffect(itemID: item.id)
            statusMessage = "Detached \(item.displayLabel)."
            await refreshEffectInventory()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func resolveConflict(_ transactionID: String, resolution: MCPRecoveryConflictResolution) async {
        do {
            try await controller.resolveMCPEffectConflict(
                transactionID: transactionID,
                resolution: resolution
            )
            statusMessage = "Conflict updated."
            await refreshEffectInventory()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func deleteInventoryItem(_ item: MCPEffectInventoryItem) async {
        do {
            try await controller.deleteMCPEffect(itemID: item.id)
            pendingDeleteItem = nil
            statusMessage = "Deleted \(item.displayLabel)."
            await refreshEffectInventory()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func runRevokeAllClients() async {
        do {
            _ = try await controller.revokeAllClients()
            statusMessage = "All clients revoked."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func runResetMCPConfiguration() async {
        do {
            _ = try await controller.resetMCPConfiguration()
            statusMessage = "MCP configuration reset."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func runDeleteAllMCPObjects() async {
        do {
            _ = try await controller.deleteAllMCPOriginObjects()
            statusMessage = "MCP-created objects deleted."
            await refreshEffectInventory()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func runEraseAuditHistory() async {
        do {
            _ = try await controller.eraseAuditHistory()
            statusMessage = "Audit history erased."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func resolveApproval(requestID: String, resolution: MCPApprovalResolution) {
        do {
            _ = try controller.resolvePending(requestID: requestID, resolution: resolution)
            switch resolution {
            case .allowOnce:
                statusMessage = "Approved once."
            case .untilSessionEnd:
                statusMessage = "Approved and granted until session ends."
            case .untilDate:
                statusMessage = "Approved and granted for bounded duration."
            case .durablePolicy:
                statusMessage = "Approved and added to client policy."
            case .denyOnce:
                statusMessage = "Denied."
            case .alwaysDeny:
                statusMessage = "Always denied for this capability."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Client", selection: $selectedClientKind) {
                    ForEach(MCPClientKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("mcpClientKindPicker")
                Picker("Profile", selection: $selectedProfileID) {
                    ForEach(controller.policyStore.selectablePhase1Profiles, id: \.id) { profile in
                        Text(profile.title).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
                .accessibilityIdentifier("mcpDisclosureProfilePicker")
                if selectedClientKind == .other {
                    TextField("Custom name", text: $customClientName)
                        .textFieldStyle(.roundedBorder)
                }
                Button("Add Client") {
                    let baseName = selectedClientKind == .other ? customClientName : selectedClientKind.defaultDisplayName
                    guard !baseName.isEmpty else { return }
                    let displayName = uniqueDisplayName(for: baseName)
                    do {
                        let result = try controller.enrollClient(displayName: displayName, profileID: selectedProfileID)
                        enrollmentCredential = result.plaintextCredential
                        enrollmentClientLabel = result.client.displayName
                        enrollmentClientID = result.client.id
                        enrollmentClientKind = selectedClientKind
                        customClientName = ""
                        statusMessage = "Credential shown once below. Copy it now."
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
                .disabled(selectedClientKind == .other && customClientName.isEmpty)
                .accessibilityIdentifier("mcpAddClientButton")
            }
            if let enrollmentCredential {
                enrollmentCredentialPanel(credential: enrollmentCredential, clientLabel: enrollmentClientLabel, kind: enrollmentClientKind)
            } else if controller.enrolledClients.isEmpty {
                Text("Pick which client is connecting and click Add Client. You'll get a one-time bearer token plus that client's exact setup step. Choose JoesProxy CLI for deterministic terminal access without configuring an agent MCP client.")
                    .appFont(.caption, scale: textScale)
            }
            if !controller.enrolledClients.isEmpty {
                clientBatchActionBar
            }
            ForEach(controller.enrolledClients, id: \.id) { client in
                clientRow(client)
            }
        }
        .alert("Remove selected clients?", isPresented: $showRemoveSelectedClientsConfirm) {
            Button("Remove", role: .destructive) {
                removeSelectedClients()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently removes \(selectedClientIDs.count) enrolled client(s) and clears their grants.")
        }
    }

    private var clientBatchActionBar: some View {
        HStack(spacing: 12) {
            Button(allClientsSelected ? "Deselect All" : "Select All") {
                if allClientsSelected {
                    selectedClientIDs.removeAll()
                } else {
                    selectAllClients()
                }
            }
            .accessibilityIdentifier("mcpClientSelectAllButton")
            Button("Remove Selected", role: .destructive) {
                showRemoveSelectedClientsConfirm = true
            }
            .disabled(selectedClientIDs.isEmpty)
            .accessibilityIdentifier("mcpRemoveSelectedClientsButton")
            if !selectedClientIDs.isEmpty {
                Text("\(selectedClientIDs.count) selected")
                    .foregroundStyle(.secondary)
                    .appFont(.caption, scale: textScale)
            }
            Spacer()
        }
    }

    private func clientRow(_ client: MCPClientRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Toggle(isOn: clientSelectionBinding(for: client.id)) {
                    VStack(alignment: .leading) {
                        Text(client.displayName).appFont(.headline, scale: textScale)
                        Text("\(client.assignedProfileID.rawValue) · \(client.credentialState.rawValue)")
                            .appFont(.caption, scale: textScale)
                        Text(connectionStatusDescription(for: client.id))
                            .appFont(.caption, scale: textScale)
                            .foregroundStyle(controller.clientConnectionTracker.windows[client.id]?.isConnected == true ? .green : .secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("mcpClientSelect-\(client.id)")
                Spacer()
                Button("Rotate") {
                    clientPendingRotate = client
                }
                .accessibilityIdentifier("mcpRotateClientButton")
                Button("Revoke") {
                    clientPendingRevoke = client
                }
                .accessibilityIdentifier("mcpRevokeClientButton")
            }
            let grants = controller.grantStore.summaries(for: client.id)
            let runtimeReady = runtimeControlIsPreauthorized(client)
            Label(runtimeReady ? "Unattended runtime control ready" : "Runtime control requires approval or policy setup",
                  systemImage: runtimeReady ? "checkmark.circle.fill" : "lock.fill")
                .appFont(.caption, scale: textScale)
                .foregroundStyle(runtimeReady ? .green : .secondary)
                .accessibilityIdentifier("mcpClientRuntimeReadiness-\(client.id)")
            if client.assignedProfileID == .developerInspection {
                Button("Apply Automation Grant Recipe") {
                    do {
                        _ = try MCPAutomationClientGrantRecipe.apply(
                            to: controller.grantStore,
                            clientID: client.id
                        )
                        statusMessage = "Applied automation Always-Allow / Always-Deny recipe for \(client.displayName)."
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
                .accessibilityIdentifier("mcpApplyAutomationGrantRecipe-\(client.id)")
            }
            if !grants.isEmpty {
                Text("Active grants")
                    .appFont(.caption, scale: textScale, weight: .semibold)
                ForEach(grants, id: \.label) { grant in
                    Text(grant.label)
                        .appFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Passive connection status from `clientConnectionTracker` — reflects a real `initialize`
    /// call the client already made, not an active health-check/ping.
    private func connectionStatusDescription(for clientID: String) -> String {
        guard let window = controller.clientConnectionTracker.windows[clientID] else {
            return "Not yet connected"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relativeTime = formatter.localizedString(for: window.lastActivityAt, relativeTo: Date())
        return window.isConnected ? "Connected \(relativeTime)" : "Disconnected · last seen \(relativeTime)"
    }

    @ViewBuilder
    private func mcpManagementSidebarRow(_ section: MCPManagementSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            Text(section.title)
                .appFont(.body, scale: textScale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mcpManagementSection-\(section.rawValue)")
        .listRowBackground(
            selectedSection == section
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
    }

    private var allClientsSelected: Bool {
        let enrolledIDs = Set(controller.enrolledClients.map(\.id))
        return !enrolledIDs.isEmpty && enrolledIDs.isSubset(of: selectedClientIDs)
    }

    private func selectAllClients() {
        selectedClientIDs = Set(controller.enrolledClients.map(\.id))
    }

    private func clientSelectionBinding(for clientID: String) -> Binding<Bool> {
        Binding(
            get: { selectedClientIDs.contains(clientID) },
            set: { isSelected in
                if isSelected {
                    selectedClientIDs.insert(clientID)
                } else {
                    selectedClientIDs.remove(clientID)
                }
            }
        )
    }

    private func removeSelectedClients() {
        let ids = selectedClientIDs
        guard !ids.isEmpty else { return }
        do {
            try controller.removeClients(clientIDs: ids)
            if let previewClientID, ids.contains(previewClientID) {
                self.previewClientID = nil
                previewEnvelope = nil
            }
            if let enrollmentClientID, ids.contains(enrollmentClientID) {
                enrollmentCredential = nil
                enrollmentClientLabel = ""
                self.enrollmentClientID = nil
            }
            selectedClientIDs.subtract(ids)
            statusMessage = "Removed \(ids.count) client(s)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func enrollmentCredentialPanel(credential: String, clientLabel: String, kind: MCPClientKind) -> some View {
        if kind == .joesProxyCLI,
           let endpointURL = productionEndpointURL,
           case .command(let command) = MCPClientConfigSnippetBuilder.setupInstructions(
               for: kind,
               endpointURL: endpointURL,
               bearerToken: credential,
               clientLabel: clientLabel
           ).mechanism {
            joesProxyCLIEnrollmentSteps(
                command: command,
                credential: credential,
                endpointURL: endpointURL
            )
        } else {
            GroupBox("One-Time Credential") {
                Text(credential)
                    .textSelection(.enabled)
                    .appFont(.caption, scale: textScale, design: .monospaced)
                Text("Warning: this secret is shown once. Store it in your client config now.")
                    .foregroundStyle(.orange)
                    .appFont(.caption, scale: textScale)
                if let endpointURL = productionEndpointURL {
                    setupInstructionsSection(kind: kind, endpointURL: endpointURL, bearerToken: credential, clientLabel: clientLabel)
                } else {
                    Text("Start the MCP server to copy production config snippets with the correct URL.")
                        .appFont(.caption, scale: textScale)
                }
                dismissEnrollmentCredentialButton
            }
        }
    }

    /// Presents JoesProxy CLI enrollment as an ordered terminal workflow: start the command, then
    /// provide the short-lived credential only when the CLI prompts. Both actions stay on the main
    /// actor with the rest of this view's presentation state.
    private func joesProxyCLIEnrollmentSteps(
        command: String,
        credential: String,
        endpointURL: URL
    ) -> some View {
        let instructions = MCPClientConfigSnippetBuilder.setupInstructions(
            for: .joesProxyCLI,
            endpointURL: endpointURL,
            bearerToken: credential,
            clientLabel: enrollmentClientLabel
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text("Complete these steps in order. The command prompts for the credential in Step 2.")
                .appFont(.caption, scale: textScale, weight: .semibold)

            GroupBox("Step 1: Run in a terminal") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Copy this command, paste it into Terminal, and press Return.")
                        .appFont(.caption, scale: textScale)
                    enrollmentValueLabel(command)
                    Button("Copy command") {
                        copyEnrollmentValue(
                            command,
                            status: "Step 1 command copied. Paste it into Terminal and press Return."
                        )
                    }
                    .accessibilityIdentifier("mcpCopySetupSnippetButton")
                }
            }

            GroupBox("Step 2: One-Time Credential") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When Terminal shows “JoesProxy CLI enrollment credential:”, copy this credential and paste it at that prompt.")
                        .appFont(.caption, scale: textScale)
                    enrollmentValueLabel(credential)
                    Button("Copy credential") {
                        copyEnrollmentValue(
                            credential,
                            status: "One-time credential copied. Paste it into the waiting Terminal prompt."
                        )
                    }
                    .accessibilityIdentifier("mcpCopyEnrollmentCredentialButton")
                    Text("Warning: this secret is shown once. Store it in your client config now.")
                        .foregroundStyle(.orange)
                        .appFont(.caption, scale: textScale)
                    Text("Success: the CLI prints a JSON result with \"state\" : \"stored\". It is ready to use immediately.")
                        .foregroundStyle(.secondary)
                        .appFont(.caption, scale: textScale)
                    Text(instructions.restartNote)
                        .foregroundStyle(.secondary)
                        .appFont(.caption, scale: textScale)
                    if let caveat = instructions.caveat {
                        Text(caveat)
                            .foregroundStyle(.orange)
                            .appFont(.caption, scale: textScale)
                    }
                }
            }

            dismissEnrollmentCredentialButton
        }
    }

    /// Renders a selectable, monospaced enrollment value with a visible field boundary so users
    /// can distinguish the exact text to copy from the surrounding instructions.
    private func enrollmentValueLabel(_ value: String) -> some View {
        Text(value)
            .textSelection(.enabled)
            .appFont(.caption, scale: textScale, design: .monospaced)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Copies a single enrollment value without requiring text selection, then describes the next
    /// action in the management status area.
    private func copyEnrollmentValue(_ value: String, status: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        statusMessage = status
    }

    private var dismissEnrollmentCredentialButton: some View {
        Button("Dismiss credential") {
            enrollmentCredential = nil
            enrollmentClientLabel = ""
            enrollmentClientID = nil
        }
        .appFont(.caption, scale: textScale)
    }

    /// Renders exactly one client's real connection mechanism instead of dumping all clients'
    /// snippets regardless of which one the user picked.
    @ViewBuilder
    private func setupInstructionsSection(kind: MCPClientKind, endpointURL: URL, bearerToken: String, clientLabel: String) -> some View {
        let instructions = MCPClientConfigSnippetBuilder.setupInstructions(
            for: kind,
            endpointURL: endpointURL,
            bearerToken: bearerToken,
            clientLabel: clientLabel
        )
        VStack(alignment: .leading, spacing: 8) {
            switch instructions.mechanism {
            case .command(let command):
                Text("Run in a terminal — no file to edit")
                    .appFont(.caption, scale: textScale, weight: .semibold)
                Text(command)
                    .textSelection(.enabled)
                    .appFont(.caption, scale: textScale, design: .monospaced)
                Button("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    statusMessage = "\(kind.title) command copied. Do not commit credentials."
                }
                .accessibilityIdentifier("mcpCopySetupSnippetButton")
            case .fileEdit(let path, let content):
                Text(verbatim: "Add this to \(path):")
                    .appFont(.caption, scale: textScale, weight: .semibold)
                Text(content)
                    .textSelection(.enabled)
                    .appFont(.caption, scale: textScale, design: .monospaced)
                Button("Copy snippet") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    statusMessage = "\(kind.title) snippet copied. Do not commit credentials."
                }
                .accessibilityIdentifier("mcpCopySetupSnippetButton")
            }
            Text(instructions.restartNote)
                .foregroundStyle(.secondary)
                .appFont(.caption, scale: textScale)
            if let caveat = instructions.caveat {
                Text(caveat)
                    .foregroundStyle(.orange)
                    .appFont(.caption, scale: textScale)
            }
        }
    }

    private var agentSetupSection: some View {
        let manifest = MCPCapabilitiesManifestBuilder.buildManifest()
        let lastExported = UserDefaults.standard.string(forKey: MCPAgentExportService.lastExportedBundleVersionKey)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Pick a client below for its exact setup step, or export the MCP agent bundle. JoesProxy CLI is bundled with the app and enrolls independently from Codex CLI or the Codex desktop app.")
                .appFont(.body, scale: textScale)
            GroupBox("Capabilities") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bundle: \(manifest.bundleVersion)")
                    Text("App: \(manifest.appVersion)")
                    Text(verbatim: "Tools: \(manifest.tools.count)")
                    if let lastExported, lastExported != manifest.bundleVersion {
                        Text("Last exported bundle (\(lastExported)) differs from the running server. Re-export after upgrades.")
                            .foregroundStyle(.orange)
                            .appFont(.caption, scale: textScale)
                    }
                }
                .appFont(.body, scale: textScale)
            }
            if controller.enrolledClients.isEmpty {
                Text("Enroll a client under Clients to copy production snippets with a live endpoint URL.")
                    .foregroundStyle(.secondary)
                    .appFont(.caption, scale: textScale)
                Button("Go to Clients →") {
                    selectedSection = .clients
                }
            } else if let endpointURL = productionEndpointURL {
                let activeClient = controller.enrolledClients.first { $0.credentialState == .active }
                if let activeClient {
                    Picker("Client", selection: $selectedClientKind) {
                        ForEach(MCPClientKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    setupInstructionsSection(
                        kind: selectedClientKind,
                        endpointURL: endpointURL,
                        bearerToken: MCPClientConfigSnippetBuilder.enrollmentTokenPlaceholder,
                        clientLabel: activeClient.displayName
                    )
                    Text("Uses a placeholder token. Paste your enrolled bearer after copying, or export immediately after enrollment.")
                        .foregroundStyle(.secondary)
                        .appFont(.caption, scale: textScale)
                }
            } else {
                Text("Start the MCP server to copy snippets with the production endpoint URL.")
                    .foregroundStyle(.secondary)
                    .appFont(.caption, scale: textScale)
            }
            diagnosticSkillSection
            Button("Export Agent Bundle…") {
                exportAgentBundle(manifest: manifest)
            }
            .disabled(productionEndpointURL == nil)
            .accessibilityIdentifier("mcpExportAgentBundleButton")
        }
    }

    /// Copy/Share controls for the standalone diagnostic playbook skill (see
    /// `memlog/Research/ADR-MCP-Agent-Diagnostic-Skill.md`). Unlike the config snippets above, this
    /// content has no bearer token and is safe to share as-is — no enrollment required first.
    @ViewBuilder
    private var diagnosticSkillSection: some View {
        GroupBox("Diagnostic Skill") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Export the agent bundle for a concise Skill and routed references. Copy and Share provide the complete single-file playbook.")
                    .foregroundStyle(.secondary)
                    .appFont(.caption, scale: textScale)
                Text("Skill version: v\(Bundle.main.marketingVersionOrDev) (always tracks the app version)")
                    .foregroundStyle(.secondary)
                    .appFont(.caption, scale: textScale)
                HStack(spacing: 8) {
                    Button("Copy Skill") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MCPAgentExportService.standaloneSkillMarkdown, forType: .string)
                        statusMessage = "Complete standalone skill copied. Use the agent bundle export for the smaller routed Skill folder."
                    }
                    .accessibilityIdentifier("mcpCopySkillButton")
                    if let skillFileURL = try? MCPAgentExportService.writeSkillFile(
                        to: FileManager.default.temporaryDirectory
                    ) {
                        ShareLink(
                            item: skillFileURL,
                            subject: Text("JoesProxy MCP Diagnostics Skill"),
                            message: Text("Portable SKILL.md for debugging with JoesProxy's MCP tools.")
                        ) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("mcpShareSkillButton")
                    }
                }
            }
        }
    }

    private func exportAgentBundle(manifest: MCPCapabilitiesManifest) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.nameFieldStringValue = "JoesProxy-MCP-Agent-\(manifest.bundleVersion)"
        panel.message = "Choose a folder for the MCP agent export bundle."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard let endpointURL = productionEndpointURL else {
            statusMessage = "Start the MCP server before exporting the agent bundle."
            return
        }
        let activeClient = controller.enrolledClients.first { $0.credentialState == .active }
        do {
            let bundleURL = try MCPAgentExportService.exportBundle(
                MCPAgentExportService.ExportRequest(
                    destinationDirectory: destination,
                    endpointURL: endpointURL,
                    bearerToken: nil,
                    clientLabel: activeClient?.displayName ?? "agent",
                    manifest: manifest
                )
            )
            statusMessage = "Exported agent bundle to \(bundleURL.lastPathComponent)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private var dataAccessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phase 1 profiles")
                .appFont(.headline, scale: textScale)
            Text("Media tools inspect captured data only and never probe the original URL. Bounded transport, GOP, ID3, and container analysis can report prefix-scoped results for truncated captures; media-engine inspection still requires a complete item and explicit approval.")
                .appFont(.body, scale: textScale)
                .foregroundStyle(.secondary)
            ForEach(controller.policyStore.selectablePhase1Profiles, id: \.id) { profile in
                Text("\(profile.title) — \(profile.id.rawValue)")
                    .appFont(.body, scale: textScale)
            }
            Text("Policy revision: \(controller.policyStore.policyRevision.rawValue)")
                .appFont(.caption, scale: textScale)
        }
    }

    private var actionablePendingApprovals: [MCPApprovalRequest] {
        let now = Date()
        return controller.pendingApprovals.filter { $0.expiresAt > now }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Per-connection recap and recent audit activity.")
                .appFont(.body, scale: textScale)
                .foregroundStyle(.secondary)
            if controller.clientConnectionTracker.connectedClients.isEmpty {
                Text("No MCP clients connected.")
                    .appFont(.caption, scale: textScale)
            } else {
                ForEach(controller.clientConnectionTracker.connectedClients) { window in
                    clientRecapPanel(window: window)
                }
            }
            Divider()
            Text("Recent audit events")
                .appFont(.headline, scale: textScale)
            ForEach(controller.auditStore.recentEvents.suffix(50), id: \.id) { event in
                Text("\(event.timestamp.formatted()) · \(event.kind.rawValue) · \(event.reasonCode)")
                    .appFont(.caption, scale: textScale)
            }
        }
    }

    private func clientRecapPanel(window: MCPClientConnectionTracker.ConnectionWindow) -> some View {
        let displayName = controller.enrolledClients.first(where: { $0.id == window.clientID })?.displayName
            ?? window.clientID
        let scenarioNames = Dictionary(
            uniqueKeysWithValues: controller.scenarioStore.scenarios.map { ($0.id.rawValue, $0.definition.name) }
        )
        let recap = MCPConnectionRecapBuilder.build(
            clientID: window.clientID,
            displayName: displayName,
            events: controller.auditStore.events,
            connectedAt: window.connectedAt,
            lastActivityAt: window.lastActivityAt,
            scenarioNamesByID: scenarioNames
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(displayName)
                    .appFont(.headline, scale: textScale)
                Spacer()
                Text(verbatim: recap.connectedDurationDescription)
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
                Button(expandedRecapClientIDs.contains(window.clientID) ? "Hide Recap" : "View Recap") {
                    if expandedRecapClientIDs.contains(window.clientID) {
                        expandedRecapClientIDs.remove(window.clientID)
                    } else {
                        expandedRecapClientIDs.insert(window.clientID)
                    }
                }
                .accessibilityIdentifier("mcpViewRecap-\(window.clientID)")
            }
            if expandedRecapClientIDs.contains(window.clientID) {
                ForEach(recap.summaryLines, id: \.self) { line in
                    Text(line)
                        .appFont(.caption, scale: textScale)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var approvalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sensitive MCP reads and create-disabled mutations that require your approval appear here. Approval never executes the request; the client polls its request ID and retries the identical call once.")
                .appFont(.body, scale: textScale)
            if !controller.operationCoordinator.activeOperations.isEmpty {
                Text("Active Media Inspections")
                    .appFont(.headline, scale: textScale)
                ForEach(controller.operationCoordinator.activeOperations, id: \.operationID) { operation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(operation.requestedAnalyses.map(\.rawValue).joined(separator: ", "))
                            .appFont(.body, scale: textScale)
                        ProgressView(value: operation.progress)
                            .accessibilityLabel("Media inspection progress")
                            .accessibilityValue("\(Int(operation.progress * 100)) percent")
                        Text(operation.currentStage ?? operation.status.rawValue)
                            .appFont(.caption, scale: textScale)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mcpActiveMediaInspection")
                }
            }
            if let sources = controller.artifactSources { ArtifactActiveSharesView(registry: sources) }
            if actionablePendingApprovals.isEmpty {
                Text("No pending approvals.")
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(actionablePendingApprovals, id: \.requestID) { request in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.reason)
                            .appFont(.headline, scale: textScale)
                        Text("Client \(request.clientID) · \(request.capability.rawValue) · \(approvalKindLabel(for: request.capability))")
                            .appFont(.caption, scale: textScale)
                        Text("Expires \(request.expiresAt.formatted())")
                            .appFont(.caption, scale: textScale)
                            .foregroundStyle(.secondary)
                        MCPPendingApprovalActions(
                            request: request,
                            allowOnceIdentifier: "mcpApproveButton",
                            denyIdentifier: "mcpDenyButton",
                            resolve: { resolveApproval(requestID: request.requestID, resolution: $0) },
                            artifactSources: controller.artifactSources
                        )
                        .appFont(.body, scale: textScale)
                        Text("Session-end grants clear when the client's last MCP session is terminated, expires, or is evicted. TCP disconnect alone does not end a logical session.")
                            .appFont(.caption, scale: textScale)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Pending approval: \(request.reason)")
                }
            }
        }
        .accessibilityIdentifier("mcpApprovalsList")
    }

    private var scenariosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            selfValidationStatusSection
            Text("Agent-assisted test scenarios progress through draft, validation, approval, arming, activation, observation, and cleanup.")
                .appFont(.body, scale: textScale)
            if !controller.armedScenarioIDs.isEmpty {
                Text("Armed: \(controller.armedScenarioIDs.joined(separator: ", "))")
                    .appFont(.caption, scale: textScale)
                    .accessibilityIdentifier("mcpArmedScenarioIDs")
            }
            if !controller.scenarioLifecycleCoordinator.activeScenarioIDs.isEmpty {
                Text("Active: \(controller.scenarioLifecycleCoordinator.activeScenarioIDs.joined(separator: ", "))")
                    .appFont(.caption, scale: textScale)
                    .accessibilityIdentifier("mcpActiveScenarioIDs")
            }
            let records = controller.scenarioStore.scenarios.filter { !$0.phase.isPrunableTerminal }
            if records.isEmpty {
                Text("No in-flight scenarios.")
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records, id: \.id.rawValue) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.definition.name)
                            .appFont(.headline, scale: textScale)
                        Text(verbatim: "\(record.id.rawValue) · \(record.phase.rawValue)")
                            .appFont(.caption, scale: textScale)
                            .foregroundStyle(.secondary)
                        if let risk = record.validationResult?.riskTier {
                            Text(verbatim: "Risk: \(risk)")
                                .appFont(.caption, scale: textScale)
                        }
                        if record.phase == .awaitingApproval {
                            Button("Approve Scenario") {
                                do {
                                    _ = try controller.approveScenario(record.id)
                                    statusMessage = "Scenario armed."
                                } catch {
                                    statusMessage = error.localizedDescription
                                }
                            }
                            .accessibilityIdentifier("mcpApproveScenarioButton")
                        }
                        if let report = record.evaluationReport {
                            Text(verbatim: "Evidence: \(report.evidenceCount) · Assertions: \(report.assertionResults.count)")
                                .appFont(.caption, scale: textScale)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityIdentifier("mcpScenariosList")
    }

    private var agentRunsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Runs coordinate one investigation: scoped observation, conclusion, cleanup proof, and durable evidence. They do not activate Mac system-proxy routing or approve their own mutations.")
                .appFont(.body, scale: textScale)
            Button("New Agent Run…") {
                showNewAgentRunSheet = true
            }
            .accessibilityIdentifier("mcpNewAgentRunButton")
            .accessibilityLabel("New Agent Run")
            .accessibilityHint("Creates a draft diagnostic run from human-authored hypothesis text.")

            let runs = (controller.diagnosticRunCoordinator?.runs ?? [])
                .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            if runs.isEmpty {
                Text("No diagnostic runs.")
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(runs, id: \.id.rawValue) { run in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(run.hypothesis.summary)
                            .appFont(.headline, scale: textScale)
                        Text(verbatim: "\(run.id.rawValue.uuidString) · \(run.status.rawValue) · owner \(run.owner.ownerID)")
                            .appFont(.caption, scale: textScale)
                            .foregroundStyle(.secondary)
                        Text(verbatim: "Scopes: \(run.scopes.count) · Refs: \(run.references.count) · Hits: \(run.observationSummary.matchedRequestCount) · Misses: \(run.observationSummary.matcherMissCount)")
                            .appFont(.caption, scale: textScale)
                        if let conclusion = run.conclusion {
                            Text(verbatim: "Conclusion: \(conclusion.outcome.rawValue) (\(conclusion.reasonCode.rawValue))")
                                .appFont(.caption, scale: textScale)
                        }
                        Text(verbatim: "Expires: \(run.expiresAt.formatted()) · Cleanup: \(run.cleanupProof?.verifiedClean == true ? "verified" : (run.status == .cleanupRequired ? "required" : "n/a"))")
                            .appFont(.caption, scale: textScale)
                        if run.status == .cleanupRequired {
                            Button("Retry Cleanup") {
                                Task {
                                    do {
                                        _ = try await controller.diagnosticRunCoordinator?.retryCleanup(
                                            id: run.id,
                                            requestingOwnerID: run.owner.ownerID
                                        )
                                        statusMessage = "Cleanup retried."
                                    } catch {
                                        statusMessage = error.localizedDescription
                                    }
                                }
                            }
                            .accessibilityIdentifier("mcpRetryDiagnosticRunCleanupButton")
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mcpAgentRunRow-\(run.id.rawValue.uuidString)")
                }
            }
        }
        .accessibilityIdentifier("mcpAgentRunsList")
        .sheet(isPresented: $showNewAgentRunSheet) {
            newAgentRunSheet
        }
    }

    private var newAgentRunSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Agent Run")
                .appFont(.title3, scale: textScale, weight: .semibold)
            Text("Hypothesis text is human-authored intent. Do not paste untrusted response bodies or credentials into these fields.")
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
            TextField("Hypothesis summary", text: $newAgentRunHypothesis)
                .accessibilityIdentifier("mcpNewAgentRunHypothesisField")
            TextField("Expected observation", text: $newAgentRunExpected)
                .accessibilityIdentifier("mcpNewAgentRunExpectedField")
            TextField("HTTP host (optional)", text: $newAgentRunHost)
                .accessibilityIdentifier("mcpNewAgentRunHostField")
            TextField("HTTP path (optional)", text: $newAgentRunPath)
                .accessibilityIdentifier("mcpNewAgentRunPathField")
            TextField("Captured session ID (optional)", text: $newAgentRunSessionID)
                .accessibilityIdentifier("mcpNewAgentRunSessionIDField")
            HStack {
                Button("Cancel") { showNewAgentRunSheet = false }
                Spacer()
                Button("Create Draft") {
                    createLocalAgentRunDraft()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("mcpCreateAgentRunDraftButton")
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    private func createLocalAgentRunDraft() {
        guard let coordinator = controller.diagnosticRunCoordinator else {
            statusMessage = "Diagnostic runs are unavailable."
            return
        }
        var scopes: [DiagnosticRunScope] = []
        let host = newAgentRunHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = newAgentRunPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty, !path.isEmpty {
            scopes.append(.http(DiagnosticHTTPScope(
                method: "GET",
                scheme: .https,
                host: host,
                port: 443,
                path: path.hasPrefix("/") ? path : "/\(path)",
                pathMatch: .exact
            )))
        }
        if let sessionUUID = UUID(uuidString: newAgentRunSessionID.trimmingCharacters(in: .whitespacesAndNewlines)) {
            scopes.append(.capturedSession(DiagnosticCapturedSessionScope(
                sessionID: sessionUUID,
                captureEpoch: .initial,
                requestFingerprint: "ui-\(sessionUUID.uuidString)"
            )))
        }
        do {
            _ = try coordinator.createDraft(
                owner: .localUser,
                hypothesis: DiagnosticRunHypothesis(
                    summary: newAgentRunHypothesis,
                    expectedObservation: newAgentRunExpected,
                    source: .localUser
                ),
                scopes: scopes
            )
            showNewAgentRunSheet = false
            newAgentRunHypothesis = ""
            newAgentRunExpected = ""
            newAgentRunHost = ""
            newAgentRunPath = ""
            newAgentRunSessionID = ""
            statusMessage = "Created local Agent Run draft."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private var selfValidationStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Self-Validation")
                .appFont(.headline, scale: textScale)
            if let active = selfValidationCoordinator.activeRun {
                Text(verbatim: "Active run: \(active.runID.rawValue)")
                    .appFont(.caption, scale: textScale)
                if let proxyPort = active.validationProxyPort {
                    Text(verbatim: "Validation proxy port: \(proxyPort)")
                        .appFont(.caption, scale: textScale)
                }
                if let fixturePort = active.fixturePort {
                    Text(verbatim: "Fixture port: \(fixturePort)")
                        .appFont(.caption, scale: textScale)
                }
                Text(verbatim: "Phase: \(active.phase.rawValue)")
                    .appFont(.caption, scale: textScale)
            } else if let last = selfValidationCoordinator.lastCompletedRun {
                Text(verbatim: "Last run: \(last.runID.rawValue)")
                    .appFont(.caption, scale: textScale)
                if let outcome = last.outcome {
                    Text(verbatim: "Outcome: \(outcome.rawValue)")
                        .appFont(.caption, scale: textScale)
                }
                if let message = last.failureMessage, !message.isEmpty {
                    Text(message)
                        .appFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Idle — isolated validation infrastructure ready.")
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("mcpSelfValidationStatus")
    }

    private var disclosurePreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview Effective Access")
                .appFont(.headline, scale: textScale)
            Text("Uses the production disclosure serializer only — no live network probe.")
                .appFont(.body, scale: textScale)

            Picker("Client", selection: $previewClientID) {
                Text("Select client").tag(String?.none)
                ForEach(controller.enrolledClients.filter { $0.credentialState == .active }, id: \.id) { client in
                    Text(client.displayName).tag(Optional(client.id))
                }
            }
            .accessibilityIdentifier("mcpPreviewClientPicker")

            Picker("Session source", selection: $previewUsesSyntheticFixture) {
                Text("Synthetic fixture").tag(true)
                Text("Captured session").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mcpPreviewSourcePicker")

            if !previewUsesSyntheticFixture {
                Picker("Session", selection: $previewSessionID) {
                    Text("Select session").tag(SessionRecord.ID?.none)
                    ForEach(controller.snapshotService.allIndexedSessions, id: \.record.id) { indexed in
                        Text("\(indexed.record.request.method) \(indexed.record.request.host)")
                            .tag(Optional(indexed.record.id))
                    }
                }
                .accessibilityIdentifier("mcpPreviewSessionPicker")
            }

            if let previewEnvelope {
                GroupBox("Policy banner") {
                    Text("\(previewEnvelope.clientDisplayName) · \(previewEnvelope.profileTitle)")
                        .appFont(.body, scale: textScale)
                    Text("Profile: \(previewEnvelope.profileID.rawValue) · revision \(previewEnvelope.policyRevision.rawValue)")
                        .appFont(.caption, scale: textScale)
                    Text("Capture epoch: \(previewEnvelope.captureEpoch.rawValue)")
                        .appFont(.caption, scale: textScale)
                }
                GroupBox("Disclosure envelope") {
                    envelopeRow("Source", previewEnvelope.sourceLabel)
                    envelopeRow("Removed fields", previewEnvelope.removedFieldClasses.joined(separator: ", "))
                    envelopeRow(
                        "Partially redacted",
                        previewEnvelope.partiallyRedactedFieldClasses.isEmpty
                            ? "none"
                            : previewEnvelope.partiallyRedactedFieldClasses.joined(separator: ", ")
                    )
                    envelopeRow("Body truncated", previewEnvelope.bodyTruncated ? "yes" : "no")
                    envelopeRow("Estimated JSON bytes", "\(previewEnvelope.estimatedJSONBytes)")
                    if !previewEnvelope.activeTemporaryGrants.isEmpty {
                        envelopeRow(
                            "Active temporary grants",
                            previewEnvelope.activeTemporaryGrants.map(\.label).joined(separator: "; ")
                        )
                    }
                }
                GroupBox("Serialized summary") {
                    Text(previewSummaryJSON(previewEnvelope.summary))
                        .textSelection(.enabled)
                        .appFont(.caption, scale: textScale, design: .monospaced)
                }
            } else if previewClientID != nil {
                Text("Select a session or use the synthetic fixture to preview disclosure output.")
                    .appFont(.caption, scale: textScale)
            }
        }
    }

    private func envelopeRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appFont(.caption, scale: textScale, weight: .semibold)
            Text(value).appFont(.caption, scale: textScale)
        }
    }

    private var statusLine: some View {
        Group {
            switch controller.state {
            case .stopped:
                Text("Server is stopped.")
            case .starting:
                Text("Starting…")
            case .running(_, let url):
                Text("Listening at \(url.absoluteString)")
            case .failed(let message):
                Text("Failed: \(message)").foregroundStyle(.red)
            case .degraded(let message):
                Text("Degraded: \(message)").foregroundStyle(.orange)
            }
        }
        .appFont(.body, scale: textScale)
    }

    private var productionEndpointURL: URL? {
        if case .running(_, let url) = controller.state {
            return url
        }
        return URL(string: "http://127.0.0.1:\(NetworkConstants.mcpDefaultPort)\(MCPNetworkConstants.endpointPath)")
    }

    private func uniqueDisplayName(for base: String) -> String {
        let existing = Set(controller.enrolledClients.map(\.displayName))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) (\(index))") {
            index += 1
        }
        return "\(base) (\(index))"
    }

    private func rotateClient(_ client: MCPClientRecord) {
        do {
            let result = try controller.rotateClient(clientID: client.id)
            enrollmentCredential = result.plaintextCredential
            enrollmentClientLabel = result.client.displayName
            enrollmentClientID = result.client.id
            enrollmentClientKind = MCPClientKind.inferred(fromDisplayName: result.client.displayName)
            statusMessage = "New credential shown once. Update your client config."
        } catch {
            statusMessage = error.localizedDescription
        }
        clientPendingRotate = nil
    }

    private func revokeClient(_ client: MCPClientRecord) {
        do {
            try controller.revokeClient(clientID: client.id)
            if previewClientID == client.id {
                previewClientID = nil
                previewEnvelope = nil
            }
            if enrollmentClientID == client.id {
                enrollmentCredential = nil
                enrollmentClientLabel = ""
                enrollmentClientID = nil
            }
            statusMessage = "Revoked \(client.displayName)."
        } catch {
            statusMessage = error.localizedDescription
        }
        clientPendingRevoke = nil
    }

    private func refreshPreview() {
        guard let clientID = previewClientID,
              let client = controller.enrolledClients.first(where: { $0.id == clientID }) else {
            previewEnvelope = nil
            return
        }
        let engine = MCPDisclosurePreviewEngine(
            policyStore: controller.policyStore,
            grantStore: controller.grantStore,
            snapshotService: controller.snapshotService
        )
        let source: MCPDisclosurePreviewEngine.Source
        if previewUsesSyntheticFixture {
            source = .syntheticFixture
        } else if let sessionID = previewSessionID {
            source = .capturedSession(sessionID)
        } else {
            previewEnvelope = nil
            return
        }
        previewEnvelope = try? engine.preview(client: client, source: source)
    }

    private func previewSummaryJSON(_ summary: MCPSessionSummaryDTO) -> String {
        guard let data = try? JSONEncoder().encode(summary),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func approvalKindLabel(for capability: MCPCapabilityID) -> String {
        switch capability {
        case .enableRule:
            return "Enable rule"
        case .disableRule:
            return "Disable rule"
        case .deleteRule:
            return "Delete rule"
        case .changeThrottle:
            return "Change throttle"
        case .httpsRulesManage:
            return "Change persistent HTTPS rule (all clients, new connections)"
        case .executeBookmark:
            return "Execute bookmark (open-world)"
        case .replayRequest:
            return "Replay request (open-world)"
        case .activateMapRemote:
            return "Activate Map Remote (open-world)"
        case .activateLiveRewrite:
            return "Activate live response rewrite (open-world)"
        case .liveMediaProbe:
            return "Live media probe (open-world)"
        case .scenarioLifecycle:
            return "Test scenario"
        case .hlsFixtureLifecycle:
            return "HLS fixture run"
        case .hlsSubstitutionLifecycle:
            return "HLS test-stream substitution"
        case .openAPIMockLifecycle:
            return "OpenAPI mock pack"
        case .diagnosticRunLifecycle:
            return "Diagnostic run re-check"
        default:
            break
        }
        switch capability.riskTier {
        case .mutatingTool:
            return "Create-disabled mutation"
        case .sensitiveReadTool:
            return "Sensitive read"
        case .expensiveInspection:
            return "Media inspection"
        default:
            return capability.riskTier.rawValue
        }
    }
}

/// Known MCP client surfaces offered in the enrollment picker, so operators select an app
/// instead of free-typing a name that silently becomes a config key.
enum MCPClientKind: String, CaseIterable, Identifiable {
    case joesProxyCLI
    case claudeCode
    case claudeDesktop
    case codexCLI
    case cursor
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .joesProxyCLI: return "JoesProxy CLI"
        case .claudeCode: return "Claude Code (CLI)"
        case .claudeDesktop: return "Claude Desktop"
        case .codexCLI: return "Codex (CLI and desktop app)"
        case .cursor: return "Cursor"
        case .other: return "Other…"
        }
    }

    var defaultDisplayName: String {
        switch self {
        case .joesProxyCLI: return "joesproxy-cli"
        case .claudeCode: return "claude-code"
        case .claudeDesktop: return "claude-desktop"
        case .codexCLI: return "codex"
        case .cursor: return "cursor"
        case .other: return ""
        }
    }

    /// Maps a persisted enrollment display name back to a picker kind.
    ///
    /// Matches the exact default name or the `uniqueDisplayName` suffix form (`"joesproxy-cli (2)"`).
    /// Unrecognized names, including custom Other… labels, return `.other`.
    static func inferred(fromDisplayName displayName: String) -> MCPClientKind {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        for kind in MCPClientKind.allCases where kind != .other {
            let base = kind.defaultDisplayName
            guard !base.isEmpty else { continue }
            if trimmed == base { return kind }
            if trimmed.hasPrefix(base + " (") { return kind }
        }
        return .other
    }
}

enum MCPManagementSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case effects
    case clients
    case agentSetup
    case dataAccess
    case activity
    case approvals
    case scenarios
    case agentRuns
    case disclosurePreview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .effects: return "Effects & Recovery"
        case .clients: return "Clients"
        case .agentSetup: return "Agent Setup"
        case .dataAccess: return "Data Access"
        case .activity: return "Activity"
        case .approvals: return "Approvals"
        case .scenarios: return "Test Scenarios"
        case .agentRuns: return "Agent Runs"
        case .disclosurePreview: return "Disclosure Preview"
        }
    }

    init(destination: MCPPipelineStatus.ManagementDestination) {
        switch destination {
        case .overview: self = .overview
        case .effects: self = .effects
        case .clients: self = .clients
        case .activity: self = .activity
        case .approvals: self = .approvals
        case .scenarios: self = .scenarios
        case .agentRuns: self = .agentRuns
        }
    }
}
