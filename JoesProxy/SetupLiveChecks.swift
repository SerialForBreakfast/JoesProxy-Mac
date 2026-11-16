import SwiftUI

struct SetupLiveChecks: View {
    @ObservedObject var model: ProxyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SetupStep("Certificate: \(model.certificateReadinessSummary)", model.certificateWorkflowState == .ready ? .complete : .pending)
            Divider()
            Text("Latest live check").font(.headline)
            ForEach(SetupTrafficProbe.Kind.allCases, id: \.self) { kind in
                let result = model.setupCheckResults[kind] ?? .waiting
                HStack(alignment: .firstTextBaseline) {
                    SetupStep(kind == .http ? "HTTP routing" : "HTTPS inspection", status(for: result))
                    Text(result.message).foregroundStyle(.secondary)
                }
            }
            if case .running = model.proxyState {
                let includeHTTPS = model.certificateWorkflowState == .ready
                Button(model.runningSetupChecks ? "Checking…" : (includeHTTPS ? "Run HTTP & HTTPS checks" : "Run HTTP check")) {
                    model.runLiveSetupChecks(includeHTTPS: includeHTTPS)
                }
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

    private func status(for result: SetupTrafficProbe.Outcome) -> SetupStep.Status {
        switch result {
        case .waiting: .pending
        case .checking: .working
        case .passed: .complete
        case .failed: .needsAttention
        }
    }
}
