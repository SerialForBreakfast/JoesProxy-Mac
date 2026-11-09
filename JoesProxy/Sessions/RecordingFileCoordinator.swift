import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns all `NSOpenPanel` and `NSSavePanel` interactions for `.jproxy` recording files.
///
/// Separating file-system UI from recording load/save logic keeps `ProxyViewModel` focused on
/// state management and makes the panel behavior independently evolvable and testable.
///
/// ## Concurrency
/// All methods must be called from the main actor (panels are AppKit UI).
@MainActor
final class RecordingFileCoordinator {

    struct SaveSelection {
        let url: URL
        let fidelity: RecordingSaveFidelity
    }

    // MARK: - Save

    /// Presents a save panel configured for `.jproxy` files.
    ///
    /// - Parameter defaultName: The pre-filled filename (without extension).
    /// - Returns: The chosen URL and save fidelity, or `nil` if the panel was cancelled.
    func promptForSaveSelection(defaultName: String = "Recording") -> SaveSelection? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jproxyRecording]
        panel.nameFieldStringValue = defaultName
        panel.title = "Save Recording"
        panel.prompt = "Save"

        let accessoryModel = RecordingSaveAccessoryViewModel()
        let accessoryView = NSHostingView(rootView: RecordingSaveAccessoryView(viewModel: accessoryModel))
        accessoryView.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.frame = NSRect(x: 0, y: 0, width: 420, height: 170)
        panel.accessoryView = accessoryView

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        return SaveSelection(url: url, fidelity: accessoryModel.selectedFidelity)
    }

    // MARK: - Open

    func promptForHARExport(defaultName: String = "Capture.har") -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.harArchive]
        panel.nameFieldStringValue = defaultName
        panel.title = "Export Capture as HAR"
        panel.prompt = "Export"
        panel.message = "Exports all retained sessions. Captured headers and bodies may contain sensitive information."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Presents an open panel configured for `.jproxy` files.
    ///
    /// - Returns: The URL chosen by the user, or `nil` if the panel was cancelled.
    func promptForOpenURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jproxyRecording]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Open Recording"
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Rolling Capture Off-Path Save

    /// Presents a save panel configured for off-path rolling capture export.
    func promptForRollingCaptureSave(defaultName: String, format: RollingCaptureExportFormat) -> URL? {
        let panel = NSSavePanel()
        let ext = format == .har ? "har" : "jproxy"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .json]
        panel.nameFieldStringValue = defaultName
        panel.title = format == .har ? "Export Rolling Capture as HAR" : "Save Rolling Capture Recording"
        panel.prompt = "Save"
        panel.message = "Save the recorded capture directly to disk without loading sessions into memory."
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Diagnostics Off-Path Save

    /// Presents a save panel configured for previous-run diagnostics export.
    func promptForDiagnosticsSave(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultName
        panel.title = "Save Diagnostics"
        panel.prompt = "Save"
        panel.message = "Save the previous-run diagnostics report to disk."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
private final class RecordingSaveAccessoryViewModel: ObservableObject {
    @Published var selectedFidelity: RecordingSaveFidelity = .fullRecording
}

private struct RecordingSaveAccessoryView: View {
    @ObservedObject var viewModel: RecordingSaveAccessoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recording Fidelity")
                .font(.headline)

            Picker("Recording Fidelity", selection: $viewModel.selectedFidelity) {
                ForEach(RecordingSaveFidelity.allCases) { fidelity in
                    Text(fidelity.title)
                        .tag(fidelity)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Text(viewModel.selectedFidelity.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                RecordingSaveHintBadge(text: viewModel.selectedFidelity.sizeHint)
                RecordingSaveHintBadge(text: viewModel.selectedFidelity.useCaseHint)
            }

            Text("Choose a lighter mode when you want smaller, more shareable recordings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 400, alignment: .leading)
        .padding(.top, 6)
    }
}

private struct RecordingSaveHintBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
    }
}
