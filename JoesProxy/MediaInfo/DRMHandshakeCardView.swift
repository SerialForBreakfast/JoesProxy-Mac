//
//  DRMHandshakeCardView.swift
//  JoesProxy
//
//  SwiftUI card view for inspecting DRM license exchanges, #EXT-X-KEY Content IDs,
//  PSSH box metadata, and handshake defects.
//

import SwiftUI

struct DRMHandshakeCardView: View {
    let report: DRMAuditReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DRM License & Key Handshake Inspector")
                        .font(.headline)
                    Text("Audits Content IDs, PSSH boxes, license tokens, transport security, and latency")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                healthBadge
            }

            // Summary Metrics Row
            HStack(spacing: 8) {
                metricPill(label: "DRM System", value: report.drmSystem.shortName)
                if let key = report.keyInfo {
                    metricPill(label: "Key Method", value: key.method)
                    if let cid = key.contentID {
                        metricPill(label: "Content ID", value: cid)
                    }
                }
                if let latency = report.handshakeLatencyMs {
                    metricPill(label: "License Latency", value: String(format: "%.0fms", latency))
                }
                if !report.psshBoxes.isEmpty {
                    metricPill(label: "PSSH Boxes", value: "\(report.psshBoxes.count)")
                }
            }

            // Defect Alert Banners
            if !report.defects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected DRM Handshake Defects (\(report.defects.count))")
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

            // PSSH Box Details
            if !report.psshBoxes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Protection System Specific Header (PSSH) Metadata")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ForEach(report.psshBoxes) { box in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(box.systemName)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                Spacer()
                                Text("Version \(box.version) | \(box.dataSize) bytes")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Text("SystemID: \(box.systemID)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.primary)

                            if !box.keyIDs.isEmpty {
                                Text("Key IDs: \(box.keyIDs.joined(separator: ", "))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(6)
                    }
                }
            }

            // License Exchanges Table
            if !report.licenseExchanges.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("License Exchanges (\(report.licenseExchanges.count))")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ForEach(report.licenseExchanges) { ex in
                        HStack {
                            Text(ex.requestMethod)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.blue)

                            Text(ex.requestURL)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Text("\(ex.statusCode)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(ex.statusCode == 200 ? .green : .red)

                            Text(String(format: "%.0fms", ex.durationSeconds * 1000.0))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)

                            Text(ex.hasAuthToken ? "Auth" : "No Auth")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(ex.hasAuthToken ? .green : .orange)
                        }
                        .padding(6)
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private var healthBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(report.qualityScore >= 80 ? Color.green : (report.qualityScore >= 50 ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            Text(String(format: "DRM Health: %.0f/100", report.qualityScore))
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(report.qualityScore >= 80 ? .green : (report.qualityScore >= 50 ? .orange : .red))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((report.qualityScore >= 80 ? Color.green : (report.qualityScore >= 50 ? Color.orange : Color.red)).opacity(0.1))
        .cornerRadius(6)
    }

    private func metricPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }
}
