//
//  ByteRangeEfficiencyCardView.swift
//  JoesProxy
//
//  SwiftUI card view for inspecting HTTP Byte-Range transactions,
//  CDN edge caching efficiency, and redundant bandwidth waste.
//

import SwiftUI

struct ByteRangeEfficiencyCardView: View {
    let report: ByteRangeEfficiencyReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Byte-Range & CDN Cache Efficiency Inspector")
                        .font(.headline)
                    Text("Audits 206 Partial Content compliance, redundant byte transfers, and CDN cache hits")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                efficiencyBadge
            }

            // Summary Metrics Row
            HStack(spacing: 8) {
                let transStr = ByteCountFormatter.string(fromByteCount: report.totalTransferredBytes, countStyle: .file)
                metricPill(label: "Transferred", value: transStr)

                let redStr = ByteCountFormatter.string(fromByteCount: report.totalRedundantBytes, countStyle: .file)
                metricPill(
                    label: "Redundant Waste",
                    value: "\(redStr) (\(String(format: "%.1f%%", report.overallWastePercentage)))",
                    highlightRed: report.totalRedundantBytes > 0
                )

                metricPill(label: "Responses", value: "206: \(report.partialContent206Count) | 200: \(report.fullContent200Count)")

                let hitPct = String(format: "%.0f%%", report.cacheHitRatio * 100.0)
                metricPill(label: "CDN Cache Hit", value: hitPct)
            }

            // Defect Alert Banners
            if !report.defects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected Byte-Range & CDN Inefficiencies (\(report.defects.count))")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.red)

                    ForEach(report.defects, id: \.userFacingMessage) { defect in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(defect.isCritical ? Color.red : Color.orange)
                                .frame(width: 6, height: 6)
                                .padding(.top, 4)
                            Text(defect.userFacingMessage)
                                .font(.caption2)
                                .foregroundColor(defect.isCritical ? .red : .orange)
                        }
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.06))
                .cornerRadius(6)
            }

            // Transactions Table
            if !report.transactions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Range Transactions (\(report.transactions.count))")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ForEach(report.transactions) { tx in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(tx.requestMethod)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.blue)

                                Text(tx.rangeRequest.displayString)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.primary)

                                Spacer()

                                Text("\(tx.statusCode)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(tx.statusCode == 206 ? .green : (tx.statusCode == 200 ? .red : .orange))

                                Text(tx.cacheStatus.title)
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(tx.cacheStatus.isHit ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                    .foregroundColor(tx.cacheStatus.isHit ? .green : .orange)
                                    .cornerRadius(3)
                            }

                            HStack {
                                Text(tx.requestURL)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()

                                let transFormatted = ByteCountFormatter.string(fromByteCount: tx.transferredBytes, countStyle: .file)
                                Text(transFormatted)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)

                                if tx.redundantBytes > 0 {
                                    let redFormatted = ByteCountFormatter.string(fromByteCount: tx.redundantBytes, countStyle: .file)
                                    Text("+\(redFormatted) wasted")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private var efficiencyBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(report.efficiencyScore >= 80 ? Color.green : (report.efficiencyScore >= 50 ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            Text(String(format: "Efficiency: %.0f/100", report.efficiencyScore))
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(report.efficiencyScore >= 80 ? .green : (report.efficiencyScore >= 50 ? .orange : .red))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((report.efficiencyScore >= 80 ? Color.green : (report.efficiencyScore >= 50 ? Color.orange : Color.red)).opacity(0.1))
        .cornerRadius(6)
    }

    private func metricPill(label: String, value: String, highlightRed: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(highlightRed ? .red : .primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }
}
