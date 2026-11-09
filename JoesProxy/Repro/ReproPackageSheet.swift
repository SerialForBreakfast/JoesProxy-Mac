import AppKit
import SwiftUI

struct ReproPackageSheet: View {
    let context: ReproPackagePresentationContext
    @ObservedObject var viewModel: ProxyViewModel
    let onDismiss: () -> Void

    @State private var replayMessage: String?
    @State private var replayingSessionID: String?
    @State private var saveMessage: String?
    @Environment(\.appTextScale) private var textScale
    private let fileCoordinator = ReproFileCoordinator()

    private var inspection: ReproPackageInspection {
        ReproPackageEngine().inspection(of: context.package)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.package.title)
                        .appFont(.title2, scale: textScale, weight: .semibold)
                    Text(sourceDescription)
                        .appFont(.subheadline, scale: textScale)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }

            Text(context.package.notes)
                .appFont(.body, scale: textScale)

            HStack(spacing: 18) {
                metric("Requests", value: inspection.sessionCount)
                metric("Replayable", value: inspection.replayableSessionCount)
                metric("Hypotheses", value: inspection.hypothesisGraphCount)
                metric("Redactions", value: inspection.redactionReport.totalRedactions)
            }
            .accessibilityElement(children: .combine)

            GroupBox("Privacy and validation boundary") {
                Text("Request and response bodies, credentials, query values, private addresses, and local paths are omitted. Replay is limited to credential-free read requests. A matching HTTP status is useful evidence, but it does not prove the original client state was reproduced.")
                    .appFont(.body, scale: textScale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }

            List(context.package.sessions) { session in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(session.request.method)
                            .appFont(.caption, scale: textScale, weight: .bold, design: .monospaced)
                        Text(session.request.host + session.request.path)
                            .appFont(.body, scale: textScale, design: .monospaced)
                            .lineLimit(1)
                        Spacer()
                        if let status = session.expectedOutcome.statusCode {
                            Text(verbatim: "Expected \(status)")
                                .appFont(.caption, scale: textScale)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        if let script = context.package.scripts.first(where: { $0.sessionID == session.id }) {
                            Button("Copy Safe curl") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(script.command, forType: .string)
                                replayMessage = "Copied the sanitized request."
                            }
                        }
                        Button(replayingSessionID == session.id ? "Replaying…" : "Replay Through Proxy") {
                            replay(session)
                        }
                        .disabled(replayingSessionID != nil || !viewModel.canReplayReproSession(session))
                        Spacer()
                    }
                }
                .padding(.vertical, 5)
                .accessibilityElement(children: .contain)
            }
            .frame(minHeight: 250)

            if let message = replayMessage ?? saveMessage {
                Text(message)
                    .appFont(.body, scale: textScale)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Reproduction package result: \(message)")
            }

            HStack {
                Text("Schema \(context.package.schemaVersion) · JoesProxy \(context.package.appVersion)")
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
                Spacer()
                if context.allowsSaving {
                    Button("Save Package…") {
                        savePackage()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 880, minHeight: 580)
    }

    private var sourceDescription: String {
        switch context.package.source {
        case .nativeCapture:
            return "Sanitized from the current JoesProxy capture"
        case .harImport:
            return "Converted from HAR into sanitized reproduction evidence"
        }
    }

    private func metric(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(value)")
                .appFont(.title3, scale: textScale, weight: .semibold)
            Text(label)
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
        }
    }

    private func replay(_ session: ReproSession) {
        replayingSessionID = session.id
        replayMessage = nil
        Task {
            do {
                replayMessage = try await viewModel.replayReproSession(session).summary
            } catch {
                replayMessage = error.localizedDescription
            }
            replayingSessionID = nil
        }
    }

    private func savePackage() {
        guard let url = fileCoordinator.promptForSaveURL(defaultName: context.package.title) else { return }
        saveMessage = "Saving…"
        Task {
            do {
                try await viewModel.saveReproPackage(context.package, to: url)
                saveMessage = "Saved \(url.lastPathComponent)."
            } catch {
                saveMessage = error.localizedDescription
            }
        }
    }
}
