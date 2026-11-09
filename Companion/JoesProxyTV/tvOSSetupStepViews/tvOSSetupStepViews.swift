import SwiftUI
#if os(tvOS)
import UIKit
#endif

struct TVOSWelcomeStepView: View {
    @EnvironmentObject private var state: TVOSSetupPresentationState

    var body: some View {
        TVOSStepHeader(
            eyebrow: "Apple TV setup",
            title: "Make proxy setup less painful.",
            subtitle: "JoesProxy still runs on your Mac. This companion guides the Apple TV through the hidden profile, certificate trust, and verification steps."
        )

        VStack(alignment: .leading, spacing: 16) {
            TVOSInstructionRow(number: 1, text: "Start JoesProxy on your Mac and open the Apple TV setup guide there.")
            TVOSInstructionRow(number: 2, text: "Keep the Mac and Apple TV on the same local network.")
            TVOSInstructionRow(number: 3, text: "Use this app to walk through the tvOS-only setup steps.")
        }

        HStack(spacing: 18) {
            TVOSPrimaryButton(title: "Start Setup", systemImage: "play.fill") {
                state.markCurrentStepComplete()
            }
            Button("Troubleshooting") {
                state.go(to: .troubleshooting)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct TVOSFindMacStepView: View {
    @EnvironmentObject private var state: TVOSSetupPresentationState
    @FocusState private var focusedControl: FindMacFocusTarget?

    private enum FindMacFocusTarget: Hashable {
        case discoverMac
        case manualHost
        case pairingToken
        case checkConnection
    }

    var body: some View {
        TVOSStepHeader(
            eyebrow: "Step 1",
            title: "Find the Mac running JoesProxy.",
            subtitle: "Enable SDK discovery in the Mac Apple TV setup guide, enter the pairing token, then search from here."
        )

        VStack(alignment: .leading, spacing: 18) {
            discoveryStatus

            Text("Mac IP or Bonjour name")
                .font(.headline)
            TextField("192.168.1.20", text: $state.manualMacHost)
                .font(.title2.monospaced())
                .frame(maxWidth: 560)
                .focused($focusedControl, equals: .manualHost)
                .accessibilityIdentifier("tvOSManualMacHostField")

            Text("Pairing token")
                .font(.headline)
            TextField("Token from Mac setup guide", text: $state.pairingToken)
                .font(.title2.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: 560)
                .focused($focusedControl, equals: .pairingToken)
                .accessibilityIdentifier("tvOSPairingTokenField")

            if !state.discoveredProxies.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Discovered on local network")
                        .font(.headline)
                    ForEach(state.discoveredProxies) { proxy in
                        HStack {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading) {
                                Text(proxy.name)
                                    .font(.headline)
                                Text("\(proxy.host)  Profile: \(proxy.profilePort)  SDK: \(proxy.sdkPort ?? 0)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
                    }
                }
            }
        }

        HStack(spacing: 18) {
            TVOSPrimaryButton(title: "Discover Mac", systemImage: "dot.radiowaves.left.and.right") {
                Task { await state.discoverAndConnect(source: "findMacButton") }
            }
            .focused($focusedControl, equals: .discoverMac)
            .accessibilityHint("Searches the local network for a Mac running JoesProxy.")

            Button("Check Connection") {
                state.go(to: .checkReachability)
            }
            .focused($focusedControl, equals: .checkConnection)
            .buttonStyle(.bordered)
            .accessibilityHint("Checks the Mac host shown above using the profile server.")
        }
        .onAppear {
            focusedControl = .discoverMac
        }
    }

    @ViewBuilder
    private var discoveryStatus: some View {
        switch state.connectionState {
        case .disconnected:
            statusPanel(
                systemImage: "desktopcomputer",
                title: "Ready to search",
                detail: "Start JoesProxy on your Mac, enable SDK discovery in the Apple TV setup guide, then enter the pairing token shown there."
            )
        case .discovering:
            HStack(spacing: 14) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Searching for JoesProxy")
                        .font(.headline)
                    Text("Looking for _joesproxy._tcp on the local network.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.08)))
        case .connecting(let proxy):
            statusPanel(
                systemImage: "link",
                title: "Connecting to \(proxy.name)",
                detail: "\(proxy.host) is responding through Bonjour. Opening the SDK event channel."
            )
        case .connected(let proxy):
            statusPanel(
                systemImage: "checkmark.circle.fill",
                title: "Mac found",
                detail: "\(proxy.name) at \(proxy.host). Continue to check the profile server."
            )
            .foregroundStyle(.green)
        case .rejected(let reason):
            statusPanel(
                systemImage: "exclamationmark.triangle.fill",
                title: reason,
                detail: state.discoveryStatusMessage
                    ?? "Discovery did not find a Mac. Enter the Mac IP address manually and check the connection."
            )
            .foregroundStyle(.yellow)
        }
    }

    private func statusPanel(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.08)))
    }
}

struct TVOSReachabilityStepView: View {
    @EnvironmentObject private var state: TVOSSetupPresentationState

    var body: some View {
        TVOSStepHeader(
            eyebrow: "Step 2",
            title: "Check the profile server.",
            subtitle: "The Apple TV must reach the Mac-hosted profile at port 8765 before installation can work."
        )

        VStack(alignment: .leading, spacing: 18) {
            Text(state.profileURLText)
                .font(.title2.monospaced())
                .padding()
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.25)))

            reachabilityStatus
        }

        HStack(spacing: 18) {
            TVOSPrimaryButton(title: "Run Check", systemImage: "checkmark.seal") {
                Task { await state.checkReachability() }
            }
            Button("Continue Manually") {
                state.markCurrentStepComplete()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var reachabilityStatus: some View {
        switch state.reachabilityResult {
        case .notChecked:
            Text("Not checked yet.")
                .foregroundStyle(.secondary)
        case .checking:
            HStack {
                ProgressView()
                Text("Checking profile server...")
            }
        case .reachable(_, let profileURL):
            Label("Reachable: \(profileURL.absoluteString)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .blocked(let issue):
            VStack(alignment: .leading, spacing: 8) {
                Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(issue.recovery)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TVOSHiddenProfilesStepView: View {
    @EnvironmentObject private var state: TVOSSetupPresentationState

    var body: some View {
        TVOSStepHeader(
            eyebrow: "Step 3",
            title: "Open profile installation.",
            subtitle: "tvOS profile access varies by release. On tvOS 26.x, start from Privacy & Security; if the shortcut is unavailable, use Apple Configurator."
        )

        VStack(alignment: .leading, spacing: 16) {
            TVOSInstructionRow(number: 1, text: "Open Settings > General > Privacy & Security.")
            TVOSInstructionRow(number: 2, text: "Look for Profiles, Device Management, or Add Profile.")
            TVOSInstructionRow(number: 3, text: "If no profile option appears, the legacy Analytics Play/Pause shortcut may be unavailable on this tvOS version.")
            TVOSInstructionRow(number: 4, text: "Use Apple Configurator if profile installation is blocked from Settings.")
        }

        HStack(spacing: 18) {
            TVOSPrimaryButton(title: "Open Settings", systemImage: "gearshape.fill") {
                TVOSSystemActions.openSettings()
            }
            Button("Profile Install Is Open") {
                state.markCurrentStepComplete()
            }
            .buttonStyle(.bordered)
        }
    }
}

struct TVOSInstallProfileStepView: View {
    @EnvironmentObject private var state: TVOSSetupPresentationState

    var body: some View {
        TVOSStepHeader(
            eyebrow: "Step 4",
            title: "Install the JoesProxy profile.",
            subtitle: state.selectedProxy == nil
                ? "Copy the URL from the Mac setup guide, then paste with the iPhone Apple TV keyboard when available. The Apple TV app cannot write to the system clipboard."
                : "Bonjour discovered the profile URL below. Paste it in the hidden Profiles menu when the iPhone Apple TV keyboard is available."
        )

        Text(state.profileURLText)
            .font(.system(size: 34, weight: .semibold, design: .monospaced))
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.28)))
            .accessibilityIdentifier("tvOSProfileURL")

        VStack(alignment: .leading, spacing: 16) {
            TVOSInstructionRow(number: 1, text: "Select Add Profile in Settings or Apple Configurator.")
            TVOSInstructionRow(number: 2, text: "Paste with the iPhone keyboard when available, or enter the URL exactly as shown.")
            TVOSInstructionRow(number: 3, text: "Confirm installation when tvOS prompts you.")
            TVOSInstructionRow(number: 4, text: "Restart the Apple TV if the proxy does not take effect.")
        }

        HStack(spacing: 18) {
            TVOSPrimaryButton(title: "Profile Is Installed", systemImage: "arrow.down.doc.fill") {
                state.markCurrentStepComplete()
            }
            Button("Open Settings") {
                TVOSSystemActions.openSettings()
            }
            .buttonStyle(.bordered)
        }
    }
}

struct TVOSTrustCertificateStepView: View {
    @EnvironmentObject private var state: TVOSSetupPresentationState

    var body: some View {
        TVOSStepHeader(
            eyebrow: "Step 5",
            title: "Trust the certificate.",
            subtitle: "Installing the profile is not enough. HTTPS inspection works only after JoesProxy Root CA is trusted."
        )

        VStack(alignment: .leading, spacing: 16) {
            TVOSInstructionRow(number: 1, text: "Open Settings > General > About.")
            TVOSInstructionRow(number: 2, text: "Open Certificate Trust Settings.")
            TVOSInstructionRow(number: 3, text: "Find JoesProxy Root CA.")
            TVOSInstructionRow(number: 4, text: "Enable full trust and confirm.")
        }

        Text("Certificate Trust Settings appears only after a custom certificate is installed.")
            .font(.headline)
            .foregroundStyle(.secondary)

        HStack(spacing: 18) {
            TVOSPrimaryButton(title: "Open Settings", systemImage: "gearshape.fill") {
                TVOSSystemActions.openSettings()
            }
            Button("Certificate Is Trusted") {
                state.markCurrentStepComplete()
            }
            .buttonStyle(.bordered)
        }
    }
}

struct TVOSVerifyTrafficStepView: View {
    @EnvironmentObject private var state: TVOSSetupPresentationState

    var body: some View {
        TVOSStepHeader(
            eyebrow: "Step 6",
            title: "Verify traffic in JoesProxy.",
            subtitle: "Ping JoesProxy from the Apple TV. The Mac setup guide watches for device traffic and updates when capture is working."
        )

        VStack(alignment: .leading, spacing: 16) {
            TVOSInstructionRow(number: 1, text: "Keep JoesProxy running on the Mac and open the Apple TV setup guide there.")
            TVOSInstructionRow(number: 2, text: "On the Mac guide, choose Watch for Apple TV Traffic.")
            TVOSInstructionRow(number: 3, text: "Tap Ping JoesProxy here to send a small HTTP request through the configured proxy.")
            TVOSInstructionRow(number: 4, text: "Confirm the Mac guide shows traffic captured. You can also browse in another tvOS app.")
        }

        verificationStatus

        HStack(spacing: 12) {
            Text("SDK events received: \(state.receivedEventCount)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Refresh") {
                Task { await state.refreshEventCount() }
            }
            .buttonStyle(.bordered)
        }

        HStack(spacing: 18) {
            TVOSPrimaryButton(title: verificationButtonTitle, systemImage: "dot.radiowaves.left.and.right") {
                Task { await state.sendTrafficVerificationPing() }
            }
            .disabled(state.trafficVerificationResult == .pinging
                || state.trafficVerificationResult == .watchingForCapture)

            Button("Troubleshooting") {
                state.go(to: .troubleshooting)
            }
            .buttonStyle(.bordered)
        }
    }

    private var verificationButtonTitle: String {
        switch state.trafficVerificationResult {
        case .ready, .failed, .noTrafficObserved:
            return "Ping JoesProxy"
        case .pinging, .watchingForCapture:
            return "Pinging…"
        case .trafficInspected, .trafficTunneled, .trafficObserved:
            return "Ping Again"
        }
    }

    @ViewBuilder
    private var verificationStatus: some View {
        switch state.trafficVerificationResult {
        case .ready:
            Text("Not verified yet. The ping uses the Apple TV global proxy profile — no separate playback test is required.")
                .font(.headline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .pinging, .watchingForCapture:
            HStack(spacing: 12) {
                ProgressView()
                Text(state.trafficVerificationResult == .pinging
                    ? "Sending verification ping through the proxy…"
                    : "Waiting for Mac SDK traffic confirmation…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        case .trafficInspected(let host):
            Label("Traffic inspected for \(host). HTTPS request details are visible in JoesProxy.", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .trafficTunneled(let host):
            Label("Traffic tunneled for \(host). JoesProxy saw CONNECT traffic but not decrypted HTTPS.", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .trafficObserved(let host):
            Label("Traffic observed for \(host). Capture depth could not be classified from the SDK event.", systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .noTrafficObserved:
            Label("Ping sent, but no matching traffic appeared in the Mac SDK event stream.", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Verification ping failed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TVOSTroubleshootingStepView: View {
    @EnvironmentObject private var state: TVOSSetupPresentationState

    var body: some View {
        TVOSStepHeader(
            eyebrow: "Help",
            title: "Common setup blockers.",
            subtitle: "Apple TV setup has unavoidable manual steps. These checks solve the usual Charles, Proxyman, and JoesProxy friction points."
        )

        VStack(alignment: .leading, spacing: 18) {
            troubleshootingRow("Profile will not download", "Start the Apple TV setup guide in JoesProxy on the Mac, confirm both devices are on the same network, and allow macOS firewall prompts.")
            troubleshootingRow("Certificate Trust Settings is missing", "Install the profile first. tvOS hides Certificate Trust Settings until a custom root certificate is present.")
            troubleshootingRow("Play/Pause does nothing", "On newer tvOS releases, the old hidden Analytics shortcut may be unavailable. Use Settings > General > Privacy & Security if profile options are visible, or install with Apple Configurator.")
            troubleshootingRow("HTTPS fails after install", "Return to Certificate Trust Settings and enable JoesProxy Root CA.")
            troubleshootingRow("App traffic is still missing", "The app may use certificate pinning or custom networking. Try a different app or inspect only metadata/tunneled sessions.")
        }

        Button("Back to Setup") {
            state.go(to: .findMac)
        }
        .buttonStyle(.borderedProminent)
    }

    private func troubleshootingRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.bold())
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.08)))
    }
}

private enum TVOSSystemActions {
    static func openSettings() {
        #if os(tvOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
        #endif
    }
}
