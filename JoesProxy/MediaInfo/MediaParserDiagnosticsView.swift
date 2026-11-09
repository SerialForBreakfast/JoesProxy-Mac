//
//  MediaParserDiagnosticsView.swift
//  JoesProxy
//
//  Shared Media Info presentation for parser diagnostics.
//

import SwiftUI

struct MediaParserDiagnosticsView: View {
    let diagnostics: MediaParserDiagnostics
    let textScale: CGFloat

    var body: some View {
        DisclosureGroup("Parsing Diagnostics") {
            VStack(alignment: .leading, spacing: 6) {
                row("Outcome", diagnostics.outcome.rawValue)
                row("Bytes", "\(diagnostics.bytesInspected)/\(diagnostics.bytesAvailable) inspected")
                row("Stages", diagnostics.completedStages.isEmpty ? "None" : diagnostics.completedStages.joined(separator: ", "))
                ForEach(diagnostics.counters.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    row(key, "\(value)")
                }
                ForEach(diagnostics.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .mediaInfoFont(.caption2, scale: textScale)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 6)
        }
        .mediaInfoFont(.caption, scale: textScale)
        .accessibilityIdentifier("mediaInfoParserDiagnostics")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
