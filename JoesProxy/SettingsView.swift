import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var captureViewModel: ProxyViewModel
    let reviewSavedCapture: () -> Void
    @ObservedObject var mcpSystemNotificationCoordinator: MCPSystemNotificationCoordinator
    @State private var isResetConfirmationPresented = false
    @State private var noCachingDomainDraft = ""

    var body: some View {
        TabView(selection: $viewModel.selectedSettingsTab) {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(0)

            proxyTab
                .tabItem {
                    Label("Proxy", systemImage: "network")
                }
                .tag(1)

            noCachingTab
                .tabItem {
                    Label("No Caching", systemImage: "xmark.circle")
                }
                .tag(2)

            throttlingTab
                .tabItem {
                    Label("Throttling", systemImage: "speedometer")
                }
                .tag(3)

            advancedTab
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .tag(4)
        }
        .frame(width: 600, height: 420)
        .padding(20)
        .alert("Reset Defaults?", isPresented: $isResetConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                viewModel.resetDefaults()
            }
        } message: {
            Text("Reset the default port, text size, inspector copy privacy, quit warning, MCP notifications, long-capture storage preference, sorting preferences, split view, custom HTTPS rules, no-caching settings, and throttling presets.")
        }
    }

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Text Size", selection: $viewModel.appTextSize) {
                    ForEach(AppTextSize.allCases) { textSize in
                        Text(textSize.title).tag(textSize)
                    }
                }
                .pickerStyle(.inline)
                .accessibilityLabel("Text size")
                .accessibilityHint("Changes the reading size used in the main window.")
                .accessibilityIdentifier("settingsTextSizePicker")

                Text("Changes take effect in the main window immediately and are saved automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup Workspace") {
                Picker("Workspace", selection: $viewModel.launchWorkspacePreference) {
                    Text("Inspector").tag(LaunchWorkspacePreference.inspector)
                    Text("Agent").tag(LaunchWorkspacePreference.agent)
                }
                .accessibilityIdentifier("settingsLaunchWorkspacePicker")

                Text("The Agent workspace preference is applied on the next normal launch. Compact mode remains a separate window presentation preference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Inspector Copy Privacy") {
                Toggle("Redact sensitive headers on copy", isOn: $viewModel.isInspectorCopyRedactionEnabled)
                    .accessibilityLabel("Redact sensitive headers on copy")
                    .accessibilityHint("Controls whether copied inspector headers mask authorization, cookie, and token-like fields.")
                    .accessibilityIdentifier("settingsInspectorCopyRedactionToggle")

                Text("When enabled, copied Request Inspector headers mask authorization, cookie, and token-like values. The on-screen inspector remains unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quit Warning") {
                Toggle("Warn before quitting with unsaved sessions", isOn: $viewModel.warnsBeforeQuittingWithUnsavedSessions)
                    .accessibilityLabel("Warn before quitting with unsaved sessions")
                    .accessibilityHint("Controls whether JoesProxy warns before quitting when captured sessions have not been saved as a recording.")
                    .accessibilityIdentifier("settingsQuitWarningToggle")

                Text("When enabled, JoesProxy warns before quitting with captured sessions that have not been saved as a recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Capture Behavior") {
                Toggle("Auto-scroll to newest request when capture starts", isOn: $viewModel.isSessionAutoScrollEnabled)
                    .accessibilityLabel("Auto-scroll to newest request when capture starts")
                    .accessibilityHint("Controls whether starting proxy capture or clearing sessions begins by automatically selecting and following incoming traffic.")
                    .accessibilityIdentifier("settingsAutoScrollDefaultToggle")

                Text("When enabled, starting a capture automatically follows live requests as they arrive. Selecting any session manually pauses auto-scroll for inspection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("MCP Notifications") {
                Toggle("Notify me when MCP needs attention", isOn: mcpNotificationsBinding)
                    .accessibilityLabel("Notify me when MCP needs attention")
                    .accessibilityHint("Requests silent macOS notifications for pending MCP approvals and blocked client access while JoesProxy is not active.")
                    .accessibilityIdentifier("settingsMCPNotificationsToggle")

                LabeledContent(
                    "Notification Status",
                    value: mcpSystemNotificationCoordinator.authorizationStatusDescription
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("MCP notification status")
                .accessibilityValue(mcpSystemNotificationCoordinator.authorizationStatusDescription)
                .accessibilityIdentifier("settingsMCPNotificationStatus")

                Text("Notifications are silent and appear only while JoesProxy is not frontmost. Approvals still require review inside JoesProxy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if mcpSystemNotificationCoordinator.authorizationStatus == .denied {
                    Text("Allow notifications in System Settings → Notifications → JoesProxy, then return here and enable them again.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settingsMCPNotificationPermissionHelp")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await mcpSystemNotificationCoordinator.refreshAuthorizationStatus()
        }
    }

    private var mcpNotificationsBinding: Binding<Bool> {
        Binding(
            get: { mcpSystemNotificationCoordinator.isEnabled },
            set: { enabled in
                Task { await mcpSystemNotificationCoordinator.setEnabled(enabled) }
            }
        )
    }

    private var proxyTab: some View {
        Form {
            Section("Status") {
                LabeledContent("Proxy State", value: viewModel.proxyStatusDescription)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Proxy state")
                    .accessibilityValue(viewModel.proxyStatusDescription)
            }

            Section("Listening Port") {
                LabeledContent("Proxy Port") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField("Port", text: $viewModel.proxyPortDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 96)
                            .disabled(!viewModel.canEditProxyPort)
                            .onSubmit {
                                viewModel.applyProxyPortDraft()
                            }
                            .accessibilityLabel("Proxy port")
                            .accessibilityHint("Sets the local listening port for the proxy.")
                            .accessibilityIdentifier("settingsProxyPortField")

                        Button("Apply") {
                            viewModel.applyProxyPortDraft()
                        }
                        .disabled(!viewModel.canEditProxyPort)
                        .accessibilityHint("Saves the current port value.")
                        .accessibilityIdentifier("settingsApplyProxyPortButton")
                    }
                }

                Text(viewModel.proxyPortEditingHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Use a local port that is free on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let proxyPortValidationMessage = viewModel.proxyPortValidationMessage {
                    Text(proxyPortValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(proxyPortValidationMessage)
                        .accessibilityIdentifier("settingsProxyPortValidationMessage")
                }
            }

            Section("Local-Server Routing") {
                Toggle("Allow Map Remote to target local Mac servers", isOn: $viewModel.isLoopbackMapRemoteEnabled)
                    .accessibilityLabel("Allow Map Remote to target local Mac servers")
                    .accessibilityHint("Enables Map Remote rules that explicitly opt in to forward traffic to authorized ports on this Mac.")
                    .accessibilityIdentifier("settingsLoopbackMapRemoteToggle")

                Text("Off by default. Loopback means the Mac running JoesProxy, not the test device. Turning this off or removing a port immediately blocks new requests, closes active remapped streams, and disables matching rules so they never resume silently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Authorized Ports") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField("e.g. 3000, 8080", text: $viewModel.authorizedLoopbackPortsDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit {
                                viewModel.commitAuthorizedLoopbackPortsDraft()
                            }
                            .accessibilityLabel("Authorized local destination ports")
                            .accessibilityIdentifier("settingsLoopbackAuthorizedPortsField")

                        Button("Save Ports") {
                            viewModel.commitAuthorizedLoopbackPortsDraft()
                        }
                        .accessibilityIdentifier("settingsSaveLoopbackPortsButton")
                    }
                }

                if !viewModel.authorizedLoopbackPorts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(viewModel.authorizedLoopbackPorts, id: \.self) { port in
                                HStack(spacing: 4) {
                                    Text(verbatim: ":\(port)")
                                        .font(.system(.caption, design: .monospaced))
                                    Button {
                                        viewModel.removeAuthorizedLoopbackPort(port)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove authorized port \(port)")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                }

                if let loopbackPortsValidationMessage = viewModel.loopbackPortsValidationMessage {
                    Text(loopbackPortsValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(loopbackPortsValidationMessage)
                        .accessibilityIdentifier("settingsLoopbackPortsValidationMessage")
                }
            }

            Section("SDK Connections") {
                Toggle("Allow SDK clients to connect to JoesProxy", isOn: $viewModel.sdkEventServerEnabled)
                    .accessibilityLabel("Allow SDK clients to connect to JoesProxy")
                    .accessibilityHint("Controls whether JoesProxy opens a local SDK event server while the proxy is running.")
                    .accessibilityIdentifier("settingsSDKEventServerToggle")

                LabeledContent("SDK Event Server", value: viewModel.sdkEventServerStatusDescription)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("SDK event server")
                    .accessibilityValue(viewModel.sdkEventServerStatusDescription)
                    .accessibilityIdentifier("settingsSDKEventServerStatus")

                LabeledContent("SDK Event Port", value: viewModel.sdkEventServerPortDescription)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("SDK event port")
                    .accessibilityValue(viewModel.sdkEventServerPortDescription)

                LabeledContent("Connected Clients", value: viewModel.sdkEventServerClientCountDescription)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Connected SDK clients")
                    .accessibilityValue(viewModel.sdkEventServerClientCountDescription)
                    .accessibilityIdentifier("settingsSDKEventServerClientCount")

                if viewModel.shouldShowSDKEventServerPairingToken {
                    LabeledContent("Pairing Token") {
                        HStack(spacing: 8) {
                            Text(viewModel.sdkEventServerPairingTokenDescription)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)

                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    viewModel.sdkEventServerPairingTokenDescription,
                                    forType: .string
                                )
                            }
                            .accessibilityLabel("Copy SDK pairing token")
                            .accessibilityHint("Copies the current SDK pairing token to the clipboard.")
                            .accessibilityIdentifier("settingsSDKEventServerCopyPairingTokenButton")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("SDK pairing token")
                    .accessibilityValue(viewModel.sdkEventServerPairingTokenDescription)
                    .accessibilityIdentifier("settingsSDKEventServerPairingToken")
                }

                Text("When enabled and the proxy is running, JoesProxy opens a local-network SDK event server for apps using the JoesProxy SDK. Keep this off unless you are testing an app that supports SDK connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task {
                await viewModel.refreshSDKEventServerStatus()
            }

            Section("System Proxy") {
                Toggle("Automatically set macOS system proxy while capturing", isOn: $viewModel.isSystemProxyManagementEnabled)
                    .accessibilityLabel("Automatically set macOS system proxy while capturing")
                    .accessibilityHint("This manual-only control routes Mac traffic when you start the proxy in JoesProxy. MCP and CLI cannot activate it.")
                    .accessibilityIdentifier("settingsSystemProxyToggle")

                Text("When enabled, manually starting the proxy in JoesProxy sets the active network service's Web Proxy (HTTP) and Secure Web Proxy (HTTPS) to 127.0.0.1 on the listening port, and stopping the proxy restores your previous settings. MCP and CLI are never allowed to activate Mac traffic routing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Changing network settings may be unavailable on standard (non-admin) accounts. If JoesProxy was force-quit while active, it offers to restore your previous proxy settings on next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Strict capture (no automatic bypass)", isOn: $viewModel.systemProxyStrictCapture)
                    .accessibilityLabel("Strict capture, no automatic bypass")
                    .accessibilityHint("Uses a static system proxy with no direct-connection fallback. Captures all traffic, but if JoesProxy crashes the network will not work until JoesProxy is reopened.")
                    .accessibilityIdentifier("settingsSystemProxyStrictToggle")

                Text("Off (recommended): JoesProxy uses an automatic proxy configuration that falls back to a direct connection if JoesProxy stops, so a crash never breaks your network — at the cost that a momentary proxy failure may let some traffic bypass capture. On: all traffic is captured with no fallback, but a crash breaks connectivity until you reopen JoesProxy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show routing status in menu bar", isOn: $viewModel.showSystemProxyMenuBarItem)
                    .accessibilityLabel("Show routing status in menu bar")
                    .accessibilityHint("Adds a menu bar item that shows whether macOS traffic is routed through JoesProxy and lets you toggle routing without opening the main window.")
                    .accessibilityIdentifier("settingsSystemProxyMenuBarToggle")

                Toggle("Run in menu bar only", isOn: $viewModel.runInMenuBarOnly)
                    .accessibilityLabel("Run in menu bar only")
                    .accessibilityHint("Hides the Dock icon and keeps JoesProxy reachable from the menu bar. Open JoesProxy from the menu bar to show the main window again.")
                    .accessibilityIdentifier("settingsRunInMenuBarOnlyToggle")
                    .onChange(of: viewModel.runInMenuBarOnly) { _, _ in
                        viewModel.applyMenuBarOnlyActivationPolicy()
                    }

                Text("When enabled, JoesProxy runs without a Dock icon. Use the menu bar item to open the main window or approve pending MCP requests. Turn this off in Settings (accessible from the menu bar path or after opening the window) to restore normal Dock presence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Route system proxy through JoesProxy?", isPresented: $viewModel.pendingRoutingConsent) {
            Button("Cancel", role: .cancel) { viewModel.cancelRoutingConsent() }
            Button("Enable") { viewModel.confirmRoutingConsent() }
        } message: {
            Text(viewModel.systemProxyConsentMessage)
        }
    }

    private var noCachingTab: some View {
        Form {
            Section("Global Control") {
                Toggle("Disable Caching For All Traffic", isOn: $viewModel.isNoCachingEnabled)
                    .accessibilityLabel("Disable caching for all traffic")
                    .accessibilityHint("When enabled, JoesProxy strips caching headers from all intercepted request and response traffic.")
                    .accessibilityIdentifier("settingsNoCachingGlobalToggle")

                Text("When enabled, JoesProxy adds Cache-Control: no-cache and Pragma: no-cache to outgoing requests, and overrides response caching headers so the proxied app always receives fresh responses from the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Only applies to intercepted HTTP and HTTPS sessions. Tunneled HTTPS pass-through sessions are not affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Per-Domain No-Caching") {
                Text("Domains in this list always have caching disabled, independent of the global toggle above. Useful for targeting a specific API host without affecting all traffic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("api.example.com", text: $noCachingDomainDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("No-caching domain")
                        .accessibilityHint("Enter a domain to always disable caching for, then press Add.")
                        .accessibilityIdentifier("settingsNoCachingDomainField")
                        .onSubmit {
                            viewModel.addNoCachingDomain(noCachingDomainDraft)
                            noCachingDomainDraft = ""
                        }

                    Button("Add") {
                        viewModel.addNoCachingDomain(noCachingDomainDraft)
                        noCachingDomainDraft = ""
                    }
                    .disabled(noCachingDomainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Adds the domain to the no-caching list.")
                    .accessibilityIdentifier("settingsNoCachingAddDomainButton")
                }

                if viewModel.noCachingDomains.isEmpty {
                    Text("No domains configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.noCachingDomains, id: \.self) { domain in
                                HStack {
                                    Text(domain)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)

                                    Spacer()

                                    Button {
                                        viewModel.removeNoCachingDomain(domain)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove \(domain)")
                                    .accessibilityLabel("Remove \(domain)")
                                    .accessibilityIdentifier("settingsNoCachingRemoveDomainButton_\(domain)")
                                }

                                if domain != viewModel.noCachingDomains.last {
                                    Divider()
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var throttlingTab: some View {
        Form {
            Section("Global Control") {
                Toggle("Enable network throttling", isOn: networkThrottlingEnabledBinding)
                    .accessibilityLabel("Enable network throttling")
                    .accessibilityHint("Applies the selected bandwidth and latency preset to traffic routed through JoesProxy.")
                    .accessibilityIdentifier("settingsNetworkThrottlingToggle")

                Text("Throttling applies to HTTP, inspected HTTPS, and CONNECT tunnel traffic routed through JoesProxy. It simulates bandwidth and latency, not packet loss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preset") {
                Picker("Active Preset", selection: selectedThrottlePresetBinding) {
                    ForEach(viewModel.networkThrottleConfiguration.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .accessibilityLabel("Active throttling preset")
                .accessibilityValue(viewModel.selectedThrottlePresetName)
                .accessibilityIdentifier("settingsNetworkThrottlePresetPicker")

                Text(viewModel.selectedThrottlePresetSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Edit Selected Preset") {
                LabeledContent("Downstream (Kbps)") {
                    TextField("1600", text: $viewModel.throttleDownstreamDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onSubmit { viewModel.applySelectedThrottlePresetDraft() }
                        .accessibilityLabel("Downstream bandwidth in kilobits per second")
                        .accessibilityIdentifier("settingsNetworkThrottleDownstreamField")
                }

                LabeledContent("Upstream (Kbps)") {
                    TextField("768", text: $viewModel.throttleUpstreamDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onSubmit { viewModel.applySelectedThrottlePresetDraft() }
                        .accessibilityLabel("Upstream bandwidth in kilobits per second")
                        .accessibilityIdentifier("settingsNetworkThrottleUpstreamField")
                }

                LabeledContent("Latency (ms)") {
                    TextField("150", text: $viewModel.throttleLatencyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onSubmit { viewModel.applySelectedThrottlePresetDraft() }
                        .accessibilityLabel("Network latency in milliseconds")
                        .accessibilityIdentifier("settingsNetworkThrottleLatencyField")
                }

                HStack(spacing: 8) {
                    Button("Apply") {
                        viewModel.applySelectedThrottlePresetDraft()
                    }
                    .accessibilityHint("Saves the current bandwidth and latency values for the selected preset.")
                    .accessibilityIdentifier("settingsApplyNetworkThrottlePresetButton")

                    Button("Restore Presets") {
                        viewModel.restoreNetworkThrottlePresets()
                    }
                    .accessibilityHint("Restores the built-in throttling presets and disables throttling.")
                    .accessibilityIdentifier("settingsRestoreNetworkThrottlePresetsButton")
                }

                Text("Changes affect new throttled writes. Existing captured session data is unchanged, and standard upstream responses are still buffered before JoesProxy sends them to the client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let networkThrottleValidationMessage = viewModel.networkThrottleValidationMessage {
                    Text(networkThrottleValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(networkThrottleValidationMessage)
                        .accessibilityIdentifier("settingsNetworkThrottleValidationMessage")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var networkThrottlingEnabledBinding: Binding<Bool> {
        Binding {
            viewModel.networkThrottleConfiguration.isEnabled
        } set: { isEnabled in
            viewModel.networkThrottleConfiguration.isEnabled = isEnabled
        }
    }

    private var selectedThrottlePresetBinding: Binding<String> {
        Binding {
            viewModel.selectedThrottlePresetID
        } set: { presetID in
            viewModel.selectedThrottlePresetID = presetID
        }
    }

    private var advancedTab: some View {
        ScrollViewReader { scroll in
            advancedForm
                .task(id: viewModel.recoverySettingsRequest) {
                    // Resolve the form's row anchors after the selected tab has mounted.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    if viewModel.showsRecoverySettings {
                        scroll.scrollTo("rollingCaptureRecovery", anchor: .top)
                    } else if viewModel.showsCapacitySettings {
                        scroll.scrollTo("capacitySettings", anchor: .top)
                    }
                }
        }
    }

    private var advancedForm: some View {
        Form {
            Section("Reset") {
                Button("Reset Defaults", role: .destructive) {
                    isResetConfirmationPresented = true
                }
                .disabled(!viewModel.canResetDefaults)
                .accessibilityHint("Restores saved preferences to their default values.")
                .accessibilityIdentifier("settingsResetDefaultsButton")

                Text("Reset restores saved preferences such as text size, inspector copy privacy, quit warning, long-capture storage, sorting, proxy port, split view, HTTPS rules, and no-caching settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !viewModel.canResetDefaults {
                    Text("Stop the proxy before resetting defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                Toggle("Log Find navigation details", isOn: $viewModel.isFindDebugLoggingEnabled)
                    .accessibilityLabel("Log Find navigation details")
                    .accessibilityHint("Prints body Find selection, routing, and highlight information to the debug log.")
                    .accessibilityIdentifier("settingsFindDebugLoggingToggle")

                Text("Enable briefly while diagnosing Find focus issues. It logs selected result IDs, body locations, rendered body mode, and highlight match decisions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Long Capture Storage") {
                Picker("Retention Policy", selection: $viewModel.captureRetentionPolicyMode) {
                    ForEach(SettingsViewModel.RetentionPolicyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .accessibilityLabel("Retention policy")
                .accessibilityHint("Controls how JoesProxy bounds in-memory session storage during long captures.")
                .accessibilityIdentifier("settingsCaptureRetentionPolicyPicker")
                .id("capacitySettings")

                LabeledContent(viewModel.captureRetentionValueLabel) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField(
                            viewModel.captureRetentionPolicyMode == .keepLastSessions ? "5000" : "200",
                            text: $viewModel.captureRetentionLimitDraft
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .disabled(viewModel.captureRetentionPolicyMode == .unlimited)
                        .onSubmit {
                            viewModel.applyCaptureRetentionPolicy()
                        }
                        .accessibilityLabel(viewModel.captureRetentionValueLabel)
                        .accessibilityHint("Applies the current long-capture storage limit.")
                        .accessibilityIdentifier("settingsCaptureRetentionLimitField")

                        Button("Apply") {
                            viewModel.applyCaptureRetentionPolicy()
                        }
                        .accessibilityHint("Saves the current long-capture storage preference.")
                        .accessibilityIdentifier("settingsApplyCaptureRetentionButton")
                    }
                }

                if viewModel.captureRetentionPolicyMode == .bounded {
                    LabeledContent("Body Data to Keep (MB)") {
                        TextField("250", text: $viewModel.captureRetentionBodyLimitDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onSubmit { viewModel.applyCaptureRetentionPolicy() }
                            .accessibilityLabel("Retained body data limit in megabytes")
                            .accessibilityIdentifier("settingsCaptureRetentionBodyLimitField")
                    }
                }

                Text(viewModel.captureRetentionHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Unlimited keeps captured history; it does not remove in-flight memory safeguards. Under pressure, JoesProxy skips response bodies first, keeping details when capacity allows. Capture never waits for memory to become available; forwarding is independent. Body capture recovers automatically. Use bounded history for long runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("See Help > Help Topics & Glossary for guidance on long-capture storage and recording save modes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Changes are saved immediately and take effect on newly captured traffic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let captureRetentionValidationMessage = viewModel.captureRetentionValidationMessage {
                    Text(captureRetentionValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(captureRetentionValidationMessage)
                        .accessibilityIdentifier("settingsCaptureRetentionValidationMessage")
                }

                Divider()

                LabeledContent("Per-Response Body Cap (KB)") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField(
                            "1024",
                            text: $viewModel.liveCaptureBodyLimitDraft
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onSubmit {
                            viewModel.applyLiveCaptureBodyLimit()
                        }
                        .accessibilityLabel("Per-response body retention cap in kilobytes")
                        .accessibilityHint("Applies the maximum number of bytes retained from each individual response body.")
                        .accessibilityIdentifier("settingsLiveCaptureBodyLimitField")

                        Button("Apply") {
                            viewModel.applyLiveCaptureBodyLimit()
                        }
                        .accessibilityHint("Saves the per-response body retention limit.")
                        .accessibilityIdentifier("settingsApplyLiveCaptureBodyLimitButton")
                    }
                }

                Text("Each response reserves capacity up front. A larger body cap keeps more bytes per response but fits fewer simultaneous captures. Lower this cap if bodies are frequently skipped. The full payload continues downstream.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let liveCaptureBodyLimitValidationMessage = viewModel.liveCaptureBodyLimitValidationMessage {
                    Text(liveCaptureBodyLimitValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(liveCaptureBodyLimitValidationMessage)
                        .accessibilityIdentifier("settingsLiveCaptureBodyLimitValidationMessage")
                }
            }

            Section("Rolling Capture Recovery") {
                LabeledContent("Offer to restore saved captures on launch") {
                    Toggle("Offer to restore saved captures on launch", isOn: $viewModel.rollingCaptureRestorePromptEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Offer to restore saved captures on launch")
                        .accessibilityHint("Changes future launch prompts, without disabling checkpoints or safety recovery.")
                        .accessibilityIdentifier("settingsRollingCaptureRestorePromptToggle")
                }
                .id("rollingCaptureRecovery")

                Button("Review Saved Capture…", action: reviewSavedCapture)
                    .disabled(!captureViewModel.canReviewRollingCapture)
                    .accessibilityIdentifier("settingsReviewSavedCaptureButton")
                if !captureViewModel.canReviewRollingCapture {
                    Text("No readable saved capture is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Automatically checkpoint rolling capture", isOn: $viewModel.rollingCaptureAutoSaveEnabled)
                    .accessibilityLabel("Automatically checkpoint rolling capture")
                    .accessibilityHint("Synchronizes the recovery journal periodically and compacts it when needed. Full recording files are created only at explicit recovery and export boundaries.")
                    .accessibilityIdentifier("settingsRollingCaptureAutoSaveToggle")

                Text("Recovery checkpoints are stored locally under Application Support/JoesProxy/RollingCaptures. New sessions are appended to a journal instead of repeatedly rewriting the full capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("A checkpoint is requested within 60 seconds of a change or after 100 new sessions by default. Active saves and disk speed can delay completion. The journal is compacted periodically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Record previous-run diagnostics", isOn: $viewModel.previousRunDiagnosticsEnabled)
                    .accessibilityLabel("Record previous-run diagnostics")
                    .accessibilityHint("Enables local, content-free health checkpoints and diagnostic reporting across app launches.")
                    .accessibilityIdentifier("settingsPreviousRunDiagnosticsToggle")

                if let diagnostics = viewModel.diagnosticsCoordinator {
                    PreviousRunDiagnosticsSettingsControls(coordinator: diagnostics)
                }

                Text("Previous-run diagnostics keep up to 3 local, content-free health reports for 7 days (2 MB total). Traffic contents, hosts, URLs, headers, bodies, paths and credentials are never included, and nothing is uploaded. Turning this off stops recording for this run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
