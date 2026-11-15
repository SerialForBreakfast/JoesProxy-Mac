import SwiftUI

struct SetupLiveChecks: View {
    @ObservedObject var model: ProxyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Certificate: \(model.certificateReadinessSummary)").font(.headline)
            Divider()
            Text("Latest live check").font(.headline)
            ForEach(SetupTrafficProbe.Kind.allCases, id: \.self) { kind in
                let result = model.setupCheckResults[kind] ?? .waiting
                LabeledContent(kind == .http ? "HTTP routing" : "HTTPS inspection") {
                    switch result {
                    case .waiting, .checking: Text(result.message).foregroundStyle(.secondary)
                    case .passed: Label(result.message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Label(result.message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                }
            }
            if case .running = model.proxyState {
                Button(model.runningSetupChecks ? "Checking…" : "Run HTTP & HTTPS checks", action: model.runLiveSetupChecks)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.runningSetupChecks)
                    .accessibilityIdentifier("guidedSetupRunLiveChecks")
            } else {
                Button("Start proxy", action: model.startProxy).disabled(!model.canStartProxy)
            }
            Text("HTTPS passes only when this test request is inspected, not tunneled.").font(.caption)
            DisclosureGroup("Manual curl commands") {
                VStack(alignment: .leading) {
                    Text(model.captureExampleCommand)
                    Text(model.httpsCaptureExampleCommand)
                }.font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }
}
