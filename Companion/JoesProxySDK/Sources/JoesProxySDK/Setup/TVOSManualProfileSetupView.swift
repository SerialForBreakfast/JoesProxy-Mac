#if os(tvOS) && canImport(SwiftUI)
import Combine
import SwiftUI

public struct TVOSManualProfileSetupView: View {
    @ObservedObject private var assistant: SetupAssistant
    private let onReady: @MainActor () -> Void

    public init(assistant: SetupAssistant, onReady: @escaping @MainActor () -> Void = {}) {
        self.assistant = assistant
        self.onReady = onReady
    }

    public var body: some View {
        VStack(spacing: 28) {
            Text("JoesProxy Setup")
                .font(.title)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 16) {
                Text(profileURLText)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(instructionText)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Open Settings > General > Privacy & Security on Apple TV and use the visible profile option if available. If your tvOS release does not expose profile installation there, install the profile with Apple Configurator. A QR code scanned by a phone installs the profile on the phone, not on this Apple TV.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 920, alignment: .leading)
        }
        .padding(60)
        .task {
            assistant.start()
        }
        .onDisappear {
            assistant.stop()
        }
        .onReceive(assistant.$step) { newStep in
            if newStep == .ready {
                onReady()
            }
        }
    }

    private var profileURLText: String {
        assistant.configuration.profileURLString ?? "Profile URL unavailable"
    }

    private var instructionText: String {
        switch assistant.step {
        case .checkingProxy:
            return "Checking JoesProxy setup."
        case .configureProxy:
            return "Configure this Apple TV to use the Mac proxy, then return here."
        case .installCertificate:
            return "Enter the profile URL from Settings if profile installation is available, or install the profile with Apple Configurator."
        case .trustCertificate:
            return "Trust the JoesProxy certificate in Settings, then return here."
        case .ready:
            return "JoesProxy setup is ready."
        }
    }
}

@available(*, deprecated, renamed: "TVOSManualProfileSetupView", message: "tvOS profile installation requires manual URL entry on Apple TV; QR scanning installs on the scanning phone.")
public typealias QRCodeSetupView = TVOSManualProfileSetupView
#endif
