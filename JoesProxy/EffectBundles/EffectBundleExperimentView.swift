import SwiftUI

struct EffectBundleExperimentView: View {
    @Environment(\.appTextScale) private var textScale
    let record: EffectBundleRecord
    @ObservedObject var diagnostics: DiagnosticRunCoordinator
    @State private var runID: UUID?
    @State private var windows: [DiagnosticExperimentWindow] = []
    @State private var baselineID: UUID?
    @State private var modifiedID: UUID?
    @State private var report: EffectBundleComparison?
    @State private var failure: String?

    var body: some View {
        DisclosureGroup("Explicit before/after report") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose an existing diagnostic run owned by this bundle's owner. These controls observe only; they never activate or stop effects.")
                Picker("Diagnostic run", selection: $runID) {
                    Text("Choose a run").tag(Optional<UUID>.none)
                    ForEach(diagnostics.runs.filter { $0.owner.ownerID == record.owner.ownerID }, id: \.id) { run in
                        Text(run.id.rawValue.uuidString).tag(Optional(run.id.rawValue))
                    }
                }
                HStack {
                    Button("Begin Baseline") { begin(.baseline) }.disabled(runID == nil || record.isServing)
                    Button("Begin Modified Run") { begin(.modified) }.disabled(runID == nil || !record.isServing)
                    Button("Refresh Windows") { refresh() }
                }
                ForEach(windows.filter { $0.endedAt == nil }) { window in
                    Button("End \(window.mode.rawValue) window \(window.id.uuidString.prefix(8))") {
                        perform { _ = try diagnostics.endExperimentWindow(id: window.id, requestingOwnerID: nil) }
                    }
                }
                Picker("Baseline", selection: $baselineID) {
                    Text("Choose closed baseline").tag(Optional<UUID>.none)
                    ForEach(windows.filter { $0.mode == .baseline && $0.endedAt != nil }) { window in
                        Text("\(window.beganAt.ISO8601Format()) · \(window.id.uuidString.prefix(8))").tag(Optional(window.id))
                    }
                }
                Picker("Modified run", selection: $modifiedID) {
                    Text("Choose closed run").tag(Optional<UUID>.none)
                    ForEach(windows.filter { $0.mode == .modified && $0.endedAt != nil }) { window in
                        Text("\(window.beganAt.ISO8601Format()) · \(window.id.uuidString.prefix(8))").tag(Optional(window.id))
                    }
                }
                Button("Compare Explicit Windows") {
                    guard let baselineID, let modifiedID else { return }
                    perform { report = try diagnostics.compareExperimentWindows(baselineID: baselineID, modifiedID: modifiedID, requestingOwnerID: nil) }
                }
                .disabled(baselineID == nil || modifiedID == nil)
                .accessibilityIdentifier("effectBundleCompare-\(record.id)")
                if let failure { Text(failure).foregroundStyle(.red) }
                if let report {
                    Text(report.qualification)
                    Text("Cleanup: \(report.cleanupState) · Target: \(report.modified.targetOutcome)")
                    if let source = report.modified.targetOutcomeSource { Text("Target evidence source: \(source)") }
                    DisclosureGroup("Scope and window provenance") {
                        Text("Revision: \(report.modified.revisionID.uuidString)")
                        Text("Scope fingerprint: \(report.modified.scopeDigest)")
                        Text("Baseline window: \(report.baseline.id.uuidString)")
                        Text("Modified window: \(report.modified.id.uuidString)")
                        Text("Baseline: \(report.baseline.beganAt.ISO8601Format()) → \(report.baseline.endedAt?.ISO8601Format() ?? "Open")")
                        Text("Modified run: \(report.modified.beganAt.ISO8601Format()) → \(report.modified.endedAt?.ISO8601Format() ?? "Open")")
                        Text("Activation: \(report.modified.activationID?.uuidString ?? "Unavailable")")
                        Text("Observed phases: \(report.modified.phaseIDs.map(\.uuidString).joined(separator: ", "))")
                    }.textSelection(.enabled)
                    ForEach(report.resources, id: \.resourceID) { row in
                        DisclosureGroup("\(row.resourceID.uuidString.prefix(8)): baseline \(row.baseline.observed), run \(row.modified.observed)") {
                            Text("Delivered \(row.modified.delivered) · Failed \(row.modified.deliveryFailed) · Pending writes \(row.modified.deliveryPending)")
                            ForEach(row.modified.textTracks ?? [], id: \.identity) { track in
                                Text("Text \(track.identity.language) / \(track.identity.role): \(track.delivered) delivered, \(track.failed) failed, \(track.pending) pending. Selection/rendering unconfirmed.")
                            }
                            Text("Timing samples: baseline \(row.baseline.latencySamples), run \(row.modified.latencySamples)")
                            Text("Run status families: \(row.modified.statusFamilies.keys.sorted().map { "\($0): \(row.modified.statusFamilies[$0] ?? 0)" }.joined(separator: ", "))")
                            Text("Transformations: \(row.modified.outcomes.keys.sorted().map { "\($0): \(row.modified.outcomes[$0] ?? 0)" }.joined(separator: ", "))")
                        }
                    }
                    DisclosureGroup("Reviewed intent — not an observed body diff") {
                        ForEach(Array(report.intendedChanges.enumerated()), id: \.offset) { _, change in Text(change) }
                    }
                    Text((report.baseline.qualifications + report.modified.qualifications).joined(separator: ", "))
                }
            }
            .appFont(.caption, scale: textScale)
        }
        .onAppear { refresh() }
    }

    private func begin(_ mode: DiagnosticExperimentWindow.Mode) {
        guard let runID else { return }
        perform { _ = try diagnostics.beginExperimentWindow(runID: .init(rawValue: runID), bundleID: record.id, mode: mode, requestingOwnerID: nil) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); failure = nil; refresh() } catch { failure = error.localizedDescription }
    }

    private func refresh() {
        do { windows = try diagnostics.experimentWindows(bundleID: record.id, requestingOwnerID: nil) }
        catch { failure = error.localizedDescription }
    }
}
