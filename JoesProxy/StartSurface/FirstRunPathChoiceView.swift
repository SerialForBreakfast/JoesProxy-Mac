import SwiftUI

/// First-run preferences, optional trust setup and capture paths. Completion still requires
/// observed capture evidence for the selected target.
struct FirstRunPathChoiceView: View {
    @Environment(\.appTextScale) private var appTextScale
    @ObservedObject var viewModel: ProxyViewModel
    let accessChecklist: SetupAccessChecklist
    @State private var showCertificateSetup = false

    let onStartFirstCapture: () -> Void
    let onConnectAnAgent: () -> Void
    let onOpenInspector: () -> Void

    var body: some View {
        ScrollView {
            setupContent.padding(24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Open Inspector", action: onOpenInspector)
                    .accessibilityIdentifier("openInspectorButton")
                Spacer()
                Button("Connect an Agent", action: onConnectAnAgent)
                    .accessibilityIdentifier("connectAnAgentButton")
                Button("Start First Capture", action: onStartFirstCapture)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("startFirstCaptureButton")
            }
            .padding()
            .background(.regularMaterial)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 640)
        .sheet(isPresented: $showCertificateSetup) {
            CertificateSetupSheet(viewModel: viewModel, isPresented: $showCertificateSetup)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRunPathChoiceView")
    }

    /// Keeps network preferences, optional enrollment and trust review available before capture.
    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("How do you want to start?")
                    .appFont(.title2, scale: appTextScale, weight: .semibold)

                Text("Review your capture preferences, then choose how to send your first request. Plain HTTP capture only needs a running proxy and a client pointed at its listening port.")
                    .appFont(.body, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            accessChecklist
            Divider()
            if let trust = viewModel.guidedSetupChecklistItems.first(where: { $0.id == "certificate" }) {
                Label("HTTPS certificate trust", systemImage: trust.state == .complete ? "checkmark.circle.fill" : "circle")
                Text(trust.detail)
                Button(viewModel.certificateSetupEntryPointTitle) { showCertificateSetup = true }
            }
        }
    }
}
