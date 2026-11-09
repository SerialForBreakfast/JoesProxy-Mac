//
//  CertificateSetupSheet.swift
//  JoesProxy
//
//  Certificate setup walkthrough sheet and HTTPS rules (bypass/intercept) editor sheet.
//  Both are presented from the main window and operate on proxy configuration state.
//  Extracted from ContentView for independent compilation and testability.
//

import AppKit
import SwiftUI

struct CertificateSetupSheet: View {
    @EnvironmentObject private var presentationState: AppPresentationState
    private let trustRefreshTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    @ObservedObject var viewModel: ProxyViewModel
    @Binding var isPresented: Bool
    @State private var isDiagnosticsExpanded = false
    @State private var renewalVerificationFingerprint = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
            Text(viewModel.certificateSetupSheetTitle)
                .font(.title2)
                .fontWeight(.semibold)

            Text(viewModel.certificateSectionTitle)
                .font(.headline)

            Text(viewModel.certificateSetupSheetMessage)
                .foregroundStyle(.secondary)

            CertificateIdentityCard(
                metadata: viewModel.certificateIdentity,
                identityStatus: viewModel.certificateIdentityStatus,
                fingerprint: viewModel.currentCertificateFingerprint,
                serialNumber: viewModel.certificateIdentity?.certificateSerialNumber
                    ?? viewModel.rootCertificate.flatMap {
                        CertificateIdentityExtraction.serialNumber(from: $0.certificateData)
                    },
                notBefore: viewModel.certificateIdentity?.notBefore
                    ?? viewModel.rootCertificate.flatMap {
                        CertificateIdentityExtraction.notBefore(from: $0.certificateData)
                    },
                notAfter: viewModel.certificateIdentity?.notAfter
                    ?? viewModel.rootCertificate.flatMap {
                        CertificateIdentityExtraction.notAfter(from: $0.certificateData)
                    },
                appTextScale: 1.0,
                onCopyFingerprint: { viewModel.copyCertificateFingerprint() },
                onCopyShortCode: { viewModel.copyCertificateShortCode() },
                onAdoptLegacy: viewModel.certificateIdentityStatus == .legacyIdentityUnknown
                    ? { viewModel.adoptLegacyCertificateIdentity() }
                    : nil,
                onNicknameChange: viewModel.certificateIdentity != nil
                    ? { viewModel.updateCertificateIdentityNickname($0) }
                    : nil
            )

            if let actionTitle = viewModel.certificatePrimaryActionTitle {
                Button(actionTitle) {
                    viewModel.performPrimaryCertificateAction()
                }

                Text(viewModel.certificatePrimaryActionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.shouldShowTrustInstructions {
                GroupBox("Trust In Keychain Access") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(viewModel.certificateTrustInstructions.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Text(viewModel.certificateTrustSuccessText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(viewModel.certificateRefreshHelpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Why trust is required") {
                            openHelpTopic(.certificateSetup)
                        }
                        .buttonStyle(.link)

                        if viewModel.certificateWorkflowState == .installedTrustRequired {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Waiting for macOS to report the trust change.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if viewModel.shouldShowSetupVerificationSection {
                GroupBox("Verify Capture") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(viewModel.setupVerificationIntroText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button(viewModel.setupVerificationButtonTitle) {
                            viewModel.runSetupVerification()
                        }
                        .accessibilityIdentifier("testYourSetupButton")

                        if let setupVerificationState = viewModel.setupVerificationState {
                            setupVerificationCard(for: setupVerificationState)
                            setupVerificationActions(for: setupVerificationState)
                            setupVerificationHelpLink(for: setupVerificationState)
                        } else {
                            diagnosticCommandList
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            DisclosureGroup("Diagnostics", isExpanded: $isDiagnosticsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(viewModel.certificateDiagnosticsText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    HStack {
                        Button("Refresh Status") {
                            viewModel.refreshCertificateStatus()
                        }

                        Button("Remove Installed Certificate") {
                            viewModel.removeRootCertificate()
                        }
                    }

                    if viewModel.canResetCertificateState && viewModel.certificateWorkflowState != .needsCleanup {
                        Button("Reset Certificate State") {
                            viewModel.confirmResetCertificateState()
                        }
                        .foregroundStyle(.red)
                    }

                    Divider()

                    Text("Renewal & shared root")
                        .font(.caption.weight(.semibold))

                    if let pending = viewModel.pendingCertificateRenewal {
                        Text("Pending renewal: \(pending.shortCode) — \(pending.certificateSHA256Fingerprint.prefix(16))…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("certificatePendingRenewalSummary")

                        TextField("Verification fingerprint (pending root)", text: $renewalVerificationFingerprint)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("certificateRenewalVerificationField")

                        HStack {
                            Button("Promote Renewal") {
                                promoteRenewal(pendingFingerprint: pending.certificateSHA256Fingerprint)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(renewalVerificationFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("certificatePromoteRenewalButton")

                            Button("Cancel Pending Renewal") {
                                do {
                                    try viewModel.cancelCertificateRenewal()
                                    renewalVerificationFingerprint = ""
                                } catch {
                                    viewModel.presentCertificateIdentityError(
                                        title: "Could Not Cancel Renewal",
                                        message: error.localizedDescription
                                    )
                                }
                            }
                            .accessibilityIdentifier("certificateCancelRenewalButton")
                        }
                    }

                    HStack {
                        Button("Prepare Renewal Root") {
                            do {
                                _ = try viewModel.prepareCertificateRenewal()
                            } catch {
                                viewModel.presentCertificateIdentityError(
                                    title: "Could Not Prepare Renewal",
                                    message: error.localizedDescription
                                )
                            }
                        }
                        .disabled(viewModel.pendingCertificateRenewal != nil)
                        .accessibilityIdentifier("certificatePrepareRenewalButton")

                        Button("Export Shared Root…") {
                            exportSharedRoot()
                        }

                        Button("Import Shared Root…") {
                            importSharedRoot()
                        }
                    }
                }
                .padding(.top, 4)
            }

                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()

                Button("Close") {
                    isPresented = false
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 520, minHeight: 420)
        .accessibilityIdentifier("certificateSetupSheet")
        .onAppear {
            viewModel.refreshCertificateStatus()
        }
        .onReceive(trustRefreshTimer) { _ in
            if viewModel.certificateWorkflowState == .installedTrustRequired {
                viewModel.refreshCertificateStatus()
            }
        }
    }

    private func setupVerificationCard(for state: ProxyViewModel.SetupVerificationState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.title)
                .font(.headline)

            Text(state.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setupVerificationResultCard")
    }

    @ViewBuilder
    private func setupVerificationActions(for state: ProxyViewModel.SetupVerificationState) -> some View {
        switch state {
        case .proxyStopped:
            Button("Start Proxy") {
                viewModel.startProxy()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canStartProxy)
            .accessibilityIdentifier("setupVerificationStartProxyButton")
        case .noTrafficObserved:
            diagnosticCommandList
        case .tunneled:
            diagnosticCommandList
        case .inspected:
            EmptyView()
        }
    }

    private var diagnosticCommandList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run a request through the proxy, then verify again.")
                .font(.caption)
                .foregroundStyle(.secondary)

            diagnosticCommandRow(
                title: "HTTP routing",
                command: viewModel.captureExampleCommand,
                copyIdentifier: "setupDiagnosticHTTPCommandCopyButton"
            )

            diagnosticCommandRow(
                title: "HTTPS inspection",
                command: viewModel.httpsCaptureExampleCommand,
                copyIdentifier: "setupDiagnosticHTTPSCommandCopyButton"
            )
        }
        .accessibilityIdentifier("setupDiagnosticCommands")
    }

    private func diagnosticCommandRow(title: String, command: String, copyIdentifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 8)

                Button("Copy") {
                    copyTextToPasteboard(command)
                }
                .controlSize(.small)
                .accessibilityLabel("Copy \(title) diagnostic command")
                .accessibilityIdentifier(copyIdentifier)
            }

            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func setupVerificationHelpLink(for state: ProxyViewModel.SetupVerificationState) -> some View {
        switch state {
        case .inspected:
            EmptyView()
        case .tunneled:
            Button("Understand why traffic can stay tunneled") {
                openHelpTopic(.trafficStates)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("setupVerificationTrafficHelpButton")
        case .noTrafficObserved, .proxyStopped:
            Button("Troubleshoot setup verification") {
                openHelpTopic(.trafficStates)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("setupVerificationTrafficHelpButton")
        }
    }

    private func openHelpTopic(_ topic: MainWindowHelpTopic) {
        isPresented = false
        presentationState.presentHelpHub(topic: topic)
    }

    private func copyTextToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func promoteRenewal(pendingFingerprint: String) {
        do {
            try viewModel.promoteCertificateRenewal(
                pendingFingerprint: pendingFingerprint,
                verificationFingerprint: renewalVerificationFingerprint
            )
            renewalVerificationFingerprint = ""
        } catch {
            viewModel.presentCertificateIdentityError(
                title: "Could Not Promote Renewal",
                message: error.localizedDescription
            )
        }
    }

    /// Exports the live root private key after an explicit confirmation dialog (Phase D5).
    private func exportSharedRoot() {
        let alert = NSAlert()
        alert.messageText = "Export shared root private key?"
        alert.informativeText = "This file contains the JoesProxy root private key. Anyone with the file can intercept HTTPS for devices that trust this CA. Do not sync it to cloud storage."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "joesproxy-shared-root.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try viewModel.exportSharedRootPackage(to: url)
        } catch {
            viewModel.presentCertificateIdentityError(
                title: "Shared Root Export Failed",
                message: error.localizedDescription
            )
        }
    }

    /// Imports a shared-root package after an explicit confirmation dialog (Phase D5).
    private func importSharedRoot() {
        let alert = NSAlert()
        alert.messageText = "Import shared root private key?"
        alert.informativeText = "This replaces the CA identity used by this Mac with the imported root and marks it as imported/shared. Existing device profiles for the previous root will stop matching inspected traffic until reinstalled."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Import…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try viewModel.importSharedRootPackage(from: url)
        } catch {
            viewModel.presentCertificateIdentityError(
                title: "Shared Root Import Failed",
                message: error.localizedDescription
            )
        }
    }
}

struct HTTPSRulesSheet: View {
    @ObservedObject var viewModel: ProxyViewModel
    @Binding var isPresented: Bool
    @State private var bypassDomainDraft = ""
    @State private var interceptDomainDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HTTPS Rules")
                .font(.title2.weight(.semibold))

            Text("Built-in compatibility domains always tunnel. Add custom bypass domains for hosts that should stay tunneled, or intercept domains for hosts you want to inspect explicitly.")
                .foregroundStyle(.secondary)

            GroupBox("Built-In Compatibility Bypasses") {
                ruleList(viewModel.builtInHTTPSBypassDomains, removeAction: nil)
                    .padding(.top, 6)
            }

            GroupBox("Custom Bypass Domains") {
                VStack(alignment: .leading, spacing: 10) {
                    domainInputRow(
                        title: "Add bypass domain",
                        placeholder: "api.example.com",
                        text: $bypassDomainDraft
                    ) {
                        viewModel.addHTTPSBypassDomain(bypassDomainDraft)
                        bypassDomainDraft = ""
                    }

                    ruleList(viewModel.httpsBypassDomains) { domain in
                        viewModel.removeHTTPSBypassDomain(domain)
                    }
                }
                .padding(.top, 6)
            }

            GroupBox("Custom Intercept Domains") {
                VStack(alignment: .leading, spacing: 10) {
                    domainInputRow(
                        title: "Add intercept domain",
                        placeholder: "staging.example.com",
                        text: $interceptDomainDraft
                    ) {
                        viewModel.addHTTPSInterceptDomain(interceptDomainDraft)
                        interceptDomainDraft = ""
                    }

                    ruleList(viewModel.httpsInterceptDomains) { domain in
                        viewModel.removeHTTPSInterceptDomain(domain)
                    }
                }
                .padding(.top, 6)
            }

            HStack {
                Button("Reset Rules To Defaults") {
                    viewModel.resetHTTPSRulesToDefaults()
                }
                .disabled(!viewModel.hasCustomHTTPSRules)

                Spacer()

                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 560, minHeight: 520)
    }

    @ViewBuilder
    private func domainInputRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                .onSubmit(action)

            Button("Add", action: action)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private func ruleList(
        _ domains: [String],
        removeAction: ((String) -> Void)?
    ) -> some View {
        if domains.isEmpty {
            Text("No domains configured.")
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(domains, id: \.self) { domain in
                        HStack {
                            Text(domain)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)

                            Spacer()

                            if let removeAction {
                                Button {
                                    removeAction(domain)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(domain)")
                            }
                        }

                        if domain != domains.last {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }
}
