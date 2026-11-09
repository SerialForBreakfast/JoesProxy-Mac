//
//  PreviousRunDiagnosticsControls.swift
//  JoesProxy
//
//  Shared copy and save controls for the previous-run diagnostics report.
//

import AppKit
import SwiftUI

/// One copy action for every recovery surface. It reflects preparation and unavailability
/// truthfully, copies the same frozen report on repeated clicks and announces the outcome.
struct PreviousRunDiagnosticsCopyButton: View {
    enum Style {
        case icon
        case labeled
    }

    private enum Feedback {
        case copied
        case failed
    }

    static let copyTitle = "Copy previous-run diagnostics"
    static let copiedTitle = "Diagnostics copied"
    static let failedTitle = "Diagnostics could not be copied"

    @ObservedObject var coordinator: PreviousRunDiagnosticsCoordinator
    var style: Style = .icon
    let accessibilityIdentifier: String
    @State private var feedback: Feedback?
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            switch style {
            case .icon:
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            case .labeled:
                Label(title, systemImage: symbolName)
            }
        }
        .buttonStyle(ConditionalPlainButtonStyle(isPlain: style == .icon))
        .disabled(!coordinator.isExportable)
        .accessibilityLabel(title)
        .accessibilityValue(coordinator.unavailableDescription ?? "")
        .help(coordinator.unavailableDescription ?? title)
        .accessibilityIdentifier(accessibilityIdentifier)
        .onDisappear { resetTask?.cancel() }
    }

    private var title: String {
        switch feedback {
        case .copied?: Self.copiedTitle
        case .failed?: Self.failedTitle
        case nil: style == .icon ? Self.copyTitle : "Copy Previous-Run Diagnostics"
        }
    }

    private var symbolName: String {
        switch feedback {
        case .copied?: "checkmark"
        case .failed?: "exclamationmark.triangle"
        case nil: "doc.on.doc"
        }
    }

    private var tint: Color {
        switch feedback {
        case .copied?: .green
        case .failed?: .orange
        case nil: .secondary
        }
    }

    private func copy() {
        let result: Feedback = coordinator.copy() ? .copied : .failed
        feedback = result
        PreviousRunDiagnosticsAnnouncement.post(result == .copied ? Self.copiedTitle : Self.failedTitle)
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            feedback = nil
        }
    }
}

private struct ConditionalPlainButtonStyle: PrimitiveButtonStyle {
    let isPlain: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if isPlain {
            Button(configuration).buttonStyle(.plain)
        } else {
            Button(configuration).buttonStyle(.automatic)
        }
    }
}

enum PreviousRunDiagnosticsAnnouncement {
    @MainActor
    static func post(_ message: String) {
        if #available(macOS 14.0, *) {
            AccessibilityNotification.Announcement(message).post()
        } else {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: message])
        }
    }
}

/// Save panel flow shared by the recovery menu, Agent recovery and Settings. Cancel is not an error.
@MainActor
enum PreviousRunDiagnosticsSaveFlow {
    enum Outcome: Equatable {
        case saved
        case cancelled
        case failed(String)

        var message: String? {
            switch self {
            case .saved: "Diagnostics saved."
            case .cancelled: nil
            case .failed(let message): message
            }
        }
    }

    static func run(coordinator: PreviousRunDiagnosticsCoordinator,
                    chooseDestination: ((String) -> URL?)? = nil) -> Outcome {
        guard coordinator.isExportable else {
            return .failed(PreviousRunDiagnosticsCoordinator.SaveError.unavailable.localizedDescription)
        }
        let choose = chooseDestination ?? { RecordingFileCoordinator().promptForDiagnosticsSave(defaultName: $0) }
        guard let destination = choose(coordinator.suggestedFileName) else { return .cancelled }
        do {
            try coordinator.save(to: destination)
            PreviousRunDiagnosticsAnnouncement.post("Diagnostics saved")
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Save action that observes availability, so it is disabled while preparing or when no report exists.
struct PreviousRunDiagnosticsSaveButton: View {
    @ObservedObject var coordinator: PreviousRunDiagnosticsCoordinator
    let accessibilityIdentifier: String
    let onOutcome: (PreviousRunDiagnosticsSaveFlow.Outcome) -> Void

    var body: some View {
        Button("Save Diagnostics…") {
            onOutcome(PreviousRunDiagnosticsSaveFlow.run(coordinator: coordinator))
        }
        .disabled(!coordinator.isExportable)
        .help(coordinator.unavailableDescription ?? "Save previous-run diagnostics as a text file")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Recovery Settings access to the same report, available after Start Fresh or a suppressed prompt.
struct PreviousRunDiagnosticsSettingsControls: View {
    @ObservedObject var coordinator: PreviousRunDiagnosticsCoordinator
    @State private var saveMessage: String?
    @State private var isClearConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PreviousRunDiagnosticsCopyButton(
                    coordinator: coordinator, style: .labeled,
                    accessibilityIdentifier: "settingsCopyDiagnosticsButton")
                PreviousRunDiagnosticsSaveButton(
                    coordinator: coordinator,
                    accessibilityIdentifier: "settingsSaveDiagnosticsButton"
                ) { saveMessage = $0.message }
                Button("Clear Diagnostics History…", role: .destructive) {
                    isClearConfirmationPresented = true
                }
                .disabled(!coordinator.isExportable)
                .accessibilityHint("Deletes saved previous-run diagnostic reports. Saved captures are not affected.")
                .accessibilityIdentifier("settingsClearDiagnosticsButton")
            }
            if let unavailable = coordinator.unavailableDescription {
                Text(unavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settingsDiagnosticsAvailability")
            }
            if let saveMessage {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settingsDiagnosticsSaveMessage")
            }
        }
        .confirmationDialog("Clear previous-run diagnostics?", isPresented: $isClearConfirmationPresented) {
            Button("Clear Diagnostics", role: .destructive) {
                coordinator.clearHistory()
                saveMessage = nil
            }
            .accessibilityIdentifier("settingsClearDiagnosticsConfirmButton")
        } message: {
            Text("Saved diagnostic reports are deleted. Saved captures are not affected.")
        }
    }
}
