import SwiftUI

/// Local setup and repair controls backed by the same settings, credentials, and policies
/// used by the proxy and MCP Management. Opening this view never probes the Keychain.
struct SetupAccessChecklist: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(\.appTextScale) private var textScale
    @ObservedObject var controller: MCPServerController
    let selfValidationCoordinator: MCPSelfValidationCoordinator
    @State private var managementDestination: MCPPipelineStatus.ManagementDestination?
    @State private var credentialError: String?
    @State private var listener: String?
    @State private var destinations: String?
    @State private var routing: Bool?
    @State private var sdk: Bool?
    @State private var localServers: Bool?
    @State private var cliStartup: Bool?
    @State private var preferenceMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture and agent preferences").appFont(.headline, scale: textScale)
            Text("Select the access you need and choose Save Preferences. Reopen this checklist in Help → Guided Setup & Repair.")
            LabeledContent("Proxy listening port") {
                TextField("Listening port", text: draft($listener, current: settings.savedListeningPort))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.canEditProxyPort)
            }
            if !settings.canEditProxyPort { Text(settings.proxyPortEditingHelpText) }
            Toggle("Route this Mac’s traffic when I manually start the proxy", isOn: draft($routing, current: settings.isSystemProxyManagementEnabled))
            if routing == true { Text(settings.systemProxyConsentMessage) }
            Toggle("Allow SDK clients to connect while capturing", isOn: draft($sdk, current: settings.sdkEventServerEnabled))
            Toggle("Allow Map Remote rules to reach local Mac servers", isOn: draft($localServers, current: settings.isLoopbackMapRemoteEnabled))
            if localServers ?? settings.isLoopbackMapRemoteEnabled {
                Text("Enter the destination ports these rules may reach, separated by commas. Removing a port closes matching streams and disables their rules.")
                LabeledContent("Destination ports") {
                    TextField("e.g. 3000, 8080", text: draft($destinations, current: LoopbackDestinationPolicy.formatPortsList(settings.authorizedLoopbackPorts)))
                        .textFieldStyle(.roundedBorder)
                }
                Text("Authorized ports: " + (settings.authorizedLoopbackPorts.isEmpty ? "None" : LoopbackDestinationPolicy.formatPortsList(settings.authorizedLoopbackPorts)))
            }
            Toggle("Allow the local CLI to start MCP", isOn: draft($cliStartup, current: controller.isCLIAutomationStartEnabled))
            Text("Local processes can request MCP startup. Enroll each client and choose its access below.")
            Button("Save Preferences", action: savePreferences)
                .disabled(listener == nil && destinations == nil && routing == nil && sdk == nil && localServers == nil && cliStartup == nil)
            if let preferenceMessage { Text(preferenceMessage) }
            Divider()
            Text("Connect a client (optional)").appFont(.headline, scale: textScale)
            Text("Start MCP, enroll your client, then follow its connection instructions. For Terminal, choose JoesProxy CLI and paste the credential at the login prompt.")
            switch controller.state {
            case .stopped:
                Button("Start MCP on this Mac") {
                    // The main-actor controller owns startup and rejects duplicate starts.
                    Task { await controller.start() }
                }
            case .starting: Text("Starting MCP…")
            case .running(let port, _): Label("MCP listening on port \(String(port))", systemImage: "checkmark.circle")
            case .failed(let message), .degraded(let message):
                Text(message)
                Button("Open MCP Management to repair…") { managementDestination = .overview }
            }
            if controller.enrolledClients.isEmpty { Label("No clients enrolled", systemImage: "circle") }
            Button("Enroll or manage an MCP / CLI client…") { managementDestination = .clients }
            if !controller.pendingApprovals.isEmpty {
                Button("Review pending requests (\(controller.pendingApprovals.count))…") { managementDestination = .approvals }
            }
            ForEach(controller.enrolledClients) { client in
                GroupBox(client.displayName) {
                    VStack(alignment: .leading, spacing: 8) {
                        if controller.requiresVerifierUnlock(client) {
                            Button("Unlock credential for " + client.displayName) {
                                do {
                                    try controller.unlockClientVerifier(client.id)
                                    credentialError = nil
                                } catch {
                                    credentialError = "Credential remains locked. Choose Unlock to try again."
                                }
                            }
                        } else if client.credentialState == .active {
                            Label("Credential ready", systemImage: "checkmark.circle")
                            SetupClientPermissions(controller: controller, client: client)
                                .id(client.credentialGeneration)
                        } else {
                            Text(client.credentialState == .revoked ? "Credential revoked. Open client management to enroll again." : "Credential needs rotation. Open client management and choose Rotate.")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let credentialError { Text(credentialError) }
        }
        .toggleStyle(.checkbox)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: Binding(get: { managementDestination != nil }, set: { if !$0 { managementDestination = nil } })) {
            MCPManagementView(controller: controller, selfValidationCoordinator: selfValidationCoordinator,
                              textScale: textScale, initialDestination: managementDestination ?? .clients)
        }
    }

    /// Untouched fields mirror the live configuration even if another window edits it.
    private func draft<Value: Equatable>(_ edit: Binding<Value?>, current: Value) -> Binding<Value> {
        Binding(get: { edit.wrappedValue ?? current }, set: { value in
            edit.wrappedValue = value == current ? nil : value
            preferenceMessage = nil
        })
    }

    /// Commits only reviewed values. Validate ports before applying permissions or routing consent.
    private func savePreferences() {
        let enabled = localServers ?? settings.isLoopbackMapRemoteEnabled
        if let error = settings.applySetupPorts(listener: listener, destinations: enabled ? destinations : nil) {
            preferenceMessage = error
            return
        }
        if let routing {
            if routing { settings.confirmRoutingConsent() } else { settings.isSystemProxyManagementEnabled = false }
        }
        if let sdk { settings.sdkEventServerEnabled = sdk }
        if let localServers { settings.isLoopbackMapRemoteEnabled = localServers }
        if let cliStartup { controller.isCLIAutomationStartEnabled = cliStartup }
        listener = nil
        destinations = nil
        routing = nil
        sdk = nil
        localServers = nil
        cliStartup = nil
        preferenceMessage = "Preferences saved for future launches."
    }
}

/// Stages only explicitly edited capabilities, then confirms future access once for the named client.
struct SetupClientPermissions: View {
    @ObservedObject var controller: MCPServerController
    let client: MCPClientRecord
    @State private var changes: [MCPCapabilityID: Bool] = [:]
    @State private var message: String?
    @State private var saving = false

    var body: some View {
        DisclosureGroup("Standing approvals for " + client.displayName) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Profile: " + client.assignedProfileID.rawValue)
                Text("Select access to remember for future calls. Existing temporary permissions keep their expiry. File sharing, HTTPS rule changes and certificate cleanup require review when requested.")
                let capabilities = ([MCPCapabilityID.runtimeControl] + MCPCapabilityID.allCases.filter { $0 != .runtimeControl }).filter {
                    $0.setupPermissionTitle != nil && controller.policyEvaluator.effectiveAllows(capability: $0, client: client)
                }
                if capabilities.isEmpty {
                    Text("This profile has no configurable standing approvals. Choose a disclosure profile when enrolling a client.")
                }
                ForEach(capabilities, id: \.self) { capability in
                    Toggle(capability.setupPermissionTitle ?? capability.rawValue, isOn: selection(for: capability))
                }
                Button("Save approvals for " + client.displayName) {
                    guard !saving else { return }
                    saving = true
                    Task { await save() }
                }
                .disabled(changes.isEmpty)
                if let message { Text(message) }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .disabled(saving)
        }
    }

    /// Apply explicit changes on the UI actor, then wait for the store's serial disk writer
    /// before confirming persistence. Keep failed selections available for retry.
    @MainActor private func save() async {
        defer { saving = false }
        do {
            try controller.applySetupGrants(changes, for: client)
            if await controller.grantStore.saveReviewedChanges() {
                changes.removeAll()
                message = "Approvals saved."
            } else {
                message = "Access changed for this run. Saving failed. Choose Save approvals to retry."
            }
        } catch let error as MCPStructuredError {
            message = error.message
        } catch { message = error.localizedDescription }
    }

    /// A temporary grant stays temporary unless the user explicitly selects standing access.
    private func selection(for capability: MCPCapabilityID) -> Binding<Bool> {
        let saved = controller.grantStore.activeGrant(capability: capability, clientID: client.id)?.mode == .durablePolicy
        return Binding(get: { changes[capability] ?? saved }, set: { selected in
            changes[capability] = selected == saved ? nil : selected
            message = nil
        })
    }
}
