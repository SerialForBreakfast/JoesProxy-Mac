import SwiftUI

/// Non-wizard first-run path choice (BA-3).
///
/// Two primary actions plus a secondary expert escape. Does not claim the proxy is running and
/// does not complete first-run on its own.
struct FirstRunPathChoiceView: View {
    @Environment(\.appTextScale) private var appTextScale

    let onStartFirstCapture: () -> Void
    let onConnectAnAgent: () -> Void
    let onOpenInspector: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("How do you want to start?")
                    .appFont(.title2, scale: appTextScale, weight: .semibold)

                Text("Pick a working surface. Capture evidence — not this screen — finishes first-run setup.")
                    .appFont(.body, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 12) {
                pathCard(
                    title: "Guided First Capture",
                    detail: "Open the Inspector with a setup companion beside the session list.",
                    systemImage: "list.bullet.rectangle",
                    buttonTitle: "Start First Capture",
                    identifier: "startFirstCaptureButton",
                    action: onStartFirstCapture
                )

                pathCard(
                    title: "Agent-Assisted Capture",
                    detail: "Open Compact Monitor so an enrolled agent can help with the first capture.",
                    systemImage: "antenna.radiowaves.left.and.right",
                    buttonTitle: "Connect an Agent",
                    identifier: "connectAnAgentButton",
                    action: onConnectAnAgent
                )
            }

            Button(action: onOpenInspector) {
                Text("Open Inspector")
                    .appFont(.body, scale: appTextScale, weight: .medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("openInspectorButton")
            .help("Skip teaching and open the Inspector. Setup stays in progress until a selected-target request is captured.")
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 640)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRunPathChoiceView")
    }

    private func pathCard(
        title: String,
        detail: String,
        systemImage: String,
        buttonTitle: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .appFont(.headline, scale: appTextScale, weight: .semibold)

            Text(detail)
                .appFont(.body, scale: appTextScale)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: action) {
                Text(buttonTitle)
                    .appFont(.body, scale: appTextScale, weight: .semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(identifier)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
