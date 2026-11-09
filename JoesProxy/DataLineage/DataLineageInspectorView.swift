//
//  DataLineageInspectorView.swift
//  JoesProxy
//
//  SwiftUI view for inspecting end-to-end data provenance,
//  MITM response watermarking, and analytics beacon parameter attribution.
//

import SwiftUI

struct DataLineageInspectorView: View {
    let report: AnalyticsAttributionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Data Lineage & Attribution Inspector")
                        .font(.headline)
                    Text("Traces analytics beacon parameters and tracking values back to source API responses")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                attributionBadge
            }

            // Summary Metrics Row
            HStack(spacing: 8) {
                metricPill(label: "Tracking Parameters", value: "\(report.totalTrackingParameters)")
                metricPill(label: "Attributed Sources", value: "\(report.attributedCount)")
                metricPill(
                    label: "Unattributed",
                    value: "\(report.unattributedCount)",
                    highlightOrange: report.unattributedCount > 0
                )
                let pctStr = String(format: "%.0f%%", report.attributionPercentage)
                metricPill(label: "Coverage", value: pctStr)
            }

            // Lineage Flows List
            if !report.flows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Data Lineage Flows (\(report.flows.count))")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ForEach(report.flows) { flow in
                        VStack(alignment: .leading, spacing: 6) {
                            // Source Node
                            HStack {
                                Text("SOURCE")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.15))
                                    .foregroundColor(.blue)
                                    .cornerRadius(3)

                                Text(flow.sourceNode.endpointURL)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()

                                Text(flow.sourceNode.keypath)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            // Flow Link / Token
                            HStack {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)

                                Text(flow.flowType.rawValue)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.primary)

                                if let token = flow.watermarkToken {
                                    Text("[\(token)]")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.purple)
                                }

                                Spacer()

                                if flow.latencyMs > 0 {
                                    Text("+\(String(format: "%.0fms", flow.latencyMs))")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.leading, 12)

                            // Sink Node
                            HStack {
                                Text("SINK")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundColor(.green)
                                    .cornerRadius(3)

                                Text(flow.sinkNode.keypath)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))

                                Spacer()

                                Text(flow.sinkNode.value)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(6)
                    }
                }
            }

            // Unattributed Parameters List
            if !report.unattributedParameters.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unattributed Parameters (\(report.unattributedParameters.count))")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)

                    ForEach(Array(report.unattributedParameters.enumerated()), id: \.offset) { _, param in
                        HStack {
                            Text(param.keypath)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary)

                            Spacer()

                            Text(param.value)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(6)
                        .background(Color.orange.opacity(0.05))
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private var attributionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(report.attributionPercentage >= 80 ? Color.green : (report.attributionPercentage >= 40 ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            Text(String(format: "Attribution: %.0f%%", report.attributionPercentage))
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(report.attributionPercentage >= 80 ? .green : (report.attributionPercentage >= 40 ? .orange : .red))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((report.attributionPercentage >= 80 ? Color.green : (report.attributionPercentage >= 40 ? Color.orange : Color.red)).opacity(0.1))
        .cornerRadius(6)
    }

    private func metricPill(label: String, value: String, highlightOrange: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(highlightOrange ? .orange : .primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }
}
