//
//  ContractDiffCardView.swift
//  JoesProxy
//
//  Executive summary card for API contract compliance and breaking change status.
//

import SwiftUI

struct ContractDiffCardView: View {
    let report: EndpointContractDiffReport
    let onInspectDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Row
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: report.isCompliant ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(report.isCompliant ? .green : .red)
                    Text(report.isCompliant ? "Contract Compliant" : "Breaking Contract Drift")
                        .font(.subheadline)
                        .fontWeight(.bold)
                }

                Spacer()

                Button("View Diffs", action: onInspectDetails)
                    .buttonStyle(.bordered)
                    .font(.caption)
            }

            // Subtitle Endpoint
            Text(report.endpoint)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            // Metrics Row
            HStack(spacing: 8) {
                metricPill(
                    title: "Breaking",
                    count: report.breakingChangeCount,
                    color: report.breakingChangeCount > 0 ? .red : .secondary
                )

                metricPill(
                    title: "Additions",
                    count: report.compatibleAdditionCount,
                    color: report.compatibleAdditionCount > 0 ? .green : .secondary
                )

                metricPill(
                    title: "Total Diffs",
                    count: report.fieldDiffs.count,
                    color: .primary
                )
            }
        }
        .padding(12)
        .background(report.isCompliant ? Color.green.opacity(0.05) : Color.red.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(report.isCompliant ? Color.green.opacity(0.2) : Color.red.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    private func metricPill(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("\(count)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }
}
