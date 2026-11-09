import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sheet context for creating an OpenAPI mock pack from Local Overrides.
struct OpenAPIMockPackSheetContext: Identifiable {
    let id = UUID()
    var session: SessionRecord?
}

/// Guided import/review/activate flow for one local OpenAPI 3.0 JSON document.
struct OpenAPIMockPackSheet: View {
    @Environment(\.appTextScale) private var appTextScale

    let session: SessionRecord?
    let compilePreview: (OpenAPIDocumentBookmark, OpenAPIMockOrigin) throws -> OpenAPIMockCompiledPack
    let previewActivation: (OpenAPIMockCompiledPack, OpenAPIMockConflictStrategy) async -> OpenAPIMockActivationDecision
    let onActivate: (OpenAPIMockCompiledPack, OpenAPIDocumentBookmark, OpenAPIMockOrigin, OpenAPIMockConflictStrategy, Bool) -> Void
    let onCancel: () -> Void

    @State private var documentName = "No document selected"
    @State private var bookmark: OpenAPIDocumentBookmark?
    @State private var scheme: SessionScheme
    @State private var host: String
    @State private var port: String
    @State private var replaceConflicts = false
    @State private var addWithoutStarting = false
    @State private var compiled: OpenAPIMockCompiledPack?
    @State private var compileError: String?
    @State private var activationDecision: OpenAPIMockActivationDecision?

    init(
        session: SessionRecord?,
        compilePreview: @escaping (OpenAPIDocumentBookmark, OpenAPIMockOrigin) throws -> OpenAPIMockCompiledPack,
        previewActivation: @escaping (OpenAPIMockCompiledPack, OpenAPIMockConflictStrategy) async -> OpenAPIMockActivationDecision,
        onActivate: @escaping (OpenAPIMockCompiledPack, OpenAPIDocumentBookmark, OpenAPIMockOrigin, OpenAPIMockConflictStrategy, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self.compilePreview = compilePreview
        self.previewActivation = previewActivation
        self.onActivate = onActivate
        self.onCancel = onCancel
        _scheme = State(initialValue: session?.request.scheme ?? .https)
        _host = State(initialValue: session?.request.host ?? "")
        _port = State(initialValue: session?.request.port.map(String.init) ?? "")
    }

    private var resolvedOrigin: OpenAPIMockOrigin? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { return nil }
        let resolvedPort: Int?
        if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedPort = nil
        } else {
            guard let parsed = Int(port), (1...65_535).contains(parsed) else { return nil }
            resolvedPort = parsed
        }
        return OpenAPIMockOrigin(scheme: scheme, host: normalizedHost, port: resolvedPort)
    }

    private var canActivate: Bool {
        bookmark != nil && resolvedOrigin != nil && compiled != nil && compileError == nil
    }

    private var conflictStrategy: OpenAPIMockConflictStrategy {
        replaceConflicts ? .replaceConflicts : .refuse
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("New OpenAPI Mock")
                        .appFont(.title3, scale: appTextScale, weight: .semibold)
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.borderless)
                    Button(addWithoutStarting ? "Add Pack" : "Activate Pack") {
                        guard let bookmark, let origin = resolvedOrigin, let compiled else { return }
                        onActivate(compiled, bookmark, origin, conflictStrategy, addWithoutStarting)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canActivate)
                    .accessibilityLabel(addWithoutStarting ? "Add OpenAPI mock pack" : "Activate OpenAPI mock pack")
                    .accessibilityHint("Compiles the selected document into one owned mock pack.")
                    .accessibilityIdentifier("activateOpenAPIMockPackButton")
                }
                Text("Import a local OpenAPI 3.0 JSON document and activate it as one owned mock pack. Unmatched traffic fails open.")
                    .appFont(.subheadline, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Choose OpenAPI JSON…", action: presentDocumentPicker)
                    .accessibilityIdentifier("openAPIMockChooseDocumentButton")
                Text(documentName)
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("openAPIMockDocumentName")
            }

            GroupBox("Target origin") {
                HStack {
                    Picker("Scheme", selection: $scheme) {
                        Text("HTTPS").tag(SessionScheme.https)
                        Text("HTTP").tag(SessionScheme.http)
                    }
                    .frame(width: 150)
                    TextField("Host", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("openAPIMockHostField")
                    TextField("Port", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityIdentifier("openAPIMockPortField")
                }
                .padding(8)
            }

            if let compileError {
                Label(compileError, systemImage: "exclamationmark.triangle")
                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("openAPIMockCompileError")
            }

            if let compiled {
                coverageSection(compiled)
            }

            Toggle("Replace overlapping local overrides", isOn: $replaceConflicts)
                .accessibilityHint("When enabled, JoesProxy disables overlapping Map Local, Block, and Map Remote rules before serving this pack.")
                .accessibilityIdentifier("openAPIMockReplaceConflictsToggle")

            Toggle("Add without starting", isOn: $addWithoutStarting)
                .accessibilityHint("Saves the pack as Waiting with no live intercept until you press Start.")
                .accessibilityIdentifier("openAPIMockAddWithoutStartingToggle")

            if case .refusedConflicts(let rules) = activationDecision, !replaceConflicts {
                Label(
                    "\(rules.count) overlapping local override\(rules.count == 1 ? "" : "s") detected",
                    systemImage: "exclamationmark.triangle"
                )
                .appFont(.caption, scale: appTextScale, weight: .semibold)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("openAPIMockConflictSummary")
            }

            Text("Schema-valid output does not reproduce real authorization, session state, or business behavior.")
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)

            Label("Default TTL is 1 hour; relaunch restores Stopped.", systemImage: "clock")
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openAPIMockPackSheet")
        .joesProxyResizableWorkspaceSheet(minWidth: 640, minHeight: 520)
        .task(id: compileKey) {
            await refreshCompile()
        }
    }

    private var compileKey: String {
        "\(bookmark?.ref ?? "")|\(scheme.rawValue)|\(host)|\(port)|\(replaceConflicts)"
    }

    @ViewBuilder
    private func coverageSection(_ compiled: OpenAPIMockCompiledPack) -> some View {
        GroupBox("Coverage") {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "\(compiled.report.coverage.supportedOperationCount) operations  •  \(compiled.report.coverage.variantCount) variants  •  \(compiled.report.coverage.unsupportedFeatureCount) unsupported")
                    .appFont(.caption, scale: appTextScale)
                    .accessibilityIdentifier("openAPIMockCoverageSummary")
                ForEach(compiled.report.operations.prefix(8), id: \.defaultVariantID) { operation in
                    Text("\(operation.method) \(operation.template)")
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
                if compiled.report.operations.count > 8 {
                    Text(verbatim: "+\(compiled.report.operations.count - 8) more")
                        .appFont(.caption2, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func presentDocumentPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a local OpenAPI 3.0 JSON document."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                bookmark = try OpenAPIMockDocumentReader.bookmark(forFileURL: url)
                documentName = url.lastPathComponent
            } catch {
                compileError = error.localizedDescription
            }
        }
    }

    private func refreshCompile() async {
        guard let bookmark, let origin = resolvedOrigin else {
            compiled = nil
            activationDecision = nil
            return
        }
        do {
            let next = try compilePreview(bookmark, origin)
            compiled = next
            compileError = nil
            activationDecision = await previewActivation(next, conflictStrategy)
        } catch {
            compiled = nil
            compileError = error.localizedDescription
            activationDecision = nil
        }
    }
}

/// One Local Overrides row for an OpenAPI mock pack.
struct OpenAPIMockPackRow: View {
    @Environment(\.appTextScale) private var appTextScale
    let pack: OpenAPIMockPack
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pack.isServing ? "doc.text.fill" : "doc.text")
                .foregroundStyle(pack.isServing ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(pack.origin.displayString)
                    .appFont(.body, scale: appTextScale, weight: .semibold)
                Text(verbatim: metricsLine)
                    .appFont(.caption2, scale: appTextScale)
                    .foregroundStyle(.secondary)
                if let lastMatchedAt = pack.metrics.lastMatchedAt {
                    Text("Last hit \(lastMatchedAt.formatted(date: .omitted, time: .standard))")
                        .appFont(.caption2, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(statusLabel)
                .appFont(.caption, scale: appTextScale, weight: .semibold)
                .foregroundStyle(pack.isServing ? .green : .secondary)
                .accessibilityValue(statusLabel)
            if pack.isServing {
                Button("Stop", action: onStop)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Stop OpenAPI mock pack")
                    .accessibilityIdentifier("openAPIMockStopButton")
            } else {
                Button("Start", action: onStart)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Start OpenAPI mock pack")
                    .accessibilityIdentifier("openAPIMockStartButton")
                if pack.state == .stopped || pack.state == .expired {
                    Button("Restart", action: onRestart)
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Restart OpenAPI mock pack")
                        .accessibilityIdentifier("openAPIMockRestartButton")
                }
                Button("Discard", role: .destructive, action: onDiscard)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Discard OpenAPI mock pack")
                    .accessibilityIdentifier("openAPIMockDiscardButton")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openAPIMockPackRow")
        .accessibilityLabel("OpenAPI mock pack \(pack.origin.displayString)")
        .accessibilityValue("\(statusLabel), \(metricsLine)")
        .accessibilityHint("One owned mock pack. Start, stop, or discard without editing individual Map Local rules.")
    }

    private var metricsLine: String {
        if pack.isServing && pack.metrics.hits == 0 {
            return "No hits yet  Misses \(pack.metrics.misses)  Ops \(pack.coverage.supportedOperationCount)"
        }
        return "Hits \(pack.metrics.hits)  Misses \(pack.metrics.misses)  Ops \(pack.coverage.supportedOperationCount)"
    }

    private var statusLabel: String {
        switch pack.state {
        case .inactive:
            return "Waiting"
        case .serving:
            return "Serving"
        case .stopped:
            return "Stopped"
        case .expired:
            return "Expired"
        case .cleanupRequired:
            return "Stopped"
        }
    }
}
