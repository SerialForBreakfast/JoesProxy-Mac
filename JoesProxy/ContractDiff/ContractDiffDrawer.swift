//
//  ContractDiffDrawer.swift
//  JoesProxy
//
//  Native SwiftUI drawer for inspecting detailed API contract and schema differences.
//

import SwiftUI

struct ContractDiffDrawer: View {
    let report: EndpointContractDiffReport
    let onClose: () -> Void

    @State private var filterBreakingOnly: Bool = false

    private var filteredDiffs: [SchemaFieldDiff] {
        if filterBreakingOnly {
            return report.fieldDiffs.filter { $0.severity == .breaking }
        }
        return report.fieldDiffs
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Image(systemName: "doc.badge.ellipsis")
                    .foregroundColor(.accentColor)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("API Contract & Schema Differential")
                        .font(.headline)
                    Text(report.endpoint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Filter Bar
            HStack {
                Toggle("Show Breaking Changes Only (\(report.breakingChangeCount))", isOn: $filterBreakingOnly)
                    .font(.caption)

                Spacer()

                Text("\(filteredDiffs.count) differences found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.02))

            Divider()

            // Diffs List
            if filteredDiffs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                    Text("No Schema Differences Found")
                        .font(.headline)
                    Text("The live response matches the baseline API contract schema perfectly.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredDiffs) { diff in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            severityBadge(diff.severity)

                            Text(diff.jsonPath)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.bold)

                            Spacer()

                            Text(diff.kind.summary)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Text(diff.explanation)
                            .font(.caption)
                            .foregroundColor(.primary.opacity(0.8))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 580, minHeight: 420)
    }

    private func severityBadge(_ severity: SchemaChangeSeverity) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(severityColor(severity))
                .frame(width: 6, height: 6)
            Text(severity.rawValue)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(severityColor(severity))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(severityColor(severity).opacity(0.1))
        .cornerRadius(4)
    }

    private func severityColor(_ severity: SchemaChangeSeverity) -> Color {
        switch severity {
        case .breaking:
            return .red
        case .compatibleAddition:
            return .green
        case .informational:
            return .blue
        }
    }
}
