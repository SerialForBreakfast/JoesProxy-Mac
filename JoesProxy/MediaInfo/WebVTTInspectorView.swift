//
//  WebVTTInspectorView.swift
//  JoesProxy
//
//  SwiftUI view for inspecting WebVTT subtitle tracks, sync drift,
//  broadcast line limit compliance, and defect warnings.
//

import SwiftUI

struct WebVTTInspectorView: View {
    let report: WebVTTTrackReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WebVTT Subtitle & Caption Inspector")
                        .font(.headline)
                    Text("Audits timestamp sync, broadcast line limits, cue overlaps, and encoding defects")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                qualityBadge
            }

            // Summary Metrics Row
            HStack(spacing: 8) {
                metricPill(label: "Cues", value: "\(report.cueCount)")
                metricPill(label: "Duration", value: String(format: "%.1fs", report.totalDurationSeconds))
                if let mpegts = report.mpegtsOffsetPTS {
                    metricPill(label: "MPEGTS Offset", value: "\(mpegts) pts")
                } else {
                    metricPill(label: "MPEGTS Map", value: "None")
                }
                if let drift = report.syncDriftMs {
                    metricPill(label: "Sync Drift", value: String(format: "%+.0fms", drift))
                }
            }

            // Defect Alert Banners
            if !report.defects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected Subtitle Track Defects (\(report.defects.count))")
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

            // Cue Table
            if !report.cues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Subtitle Cues (\(report.cues.count))")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(Array(report.cues.prefix(100).enumerated()), id: \.offset) { idx, cue in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("#\(idx + 1)")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .foregroundColor(.secondary)
                                            .frame(width: 30, alignment: .leading)

                                        Text("\(cue.startTimeString) --> \(cue.endTimeString)")
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.primary)

                                        Spacer()

                                        Text(String(format: "%.1fs", cue.durationSeconds))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)

                                        Text("\(cue.maxLineLength) chars")
                                            .font(.caption2)
                                            .foregroundColor(cue.maxLineLength > 42 ? .red : .secondary)
                                    }

                                    Text(cue.text)
                                        .font(.caption)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(6)
                                        .background(Color.primary.opacity(0.03))
                                        .cornerRadius(4)
                                }
                                .padding(8)
                                .background(Color.primary.opacity(0.02))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private var qualityBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(report.qualityScore >= 80 ? Color.green : (report.qualityScore >= 50 ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            Text(String(format: "Quality: %.0f/100", report.qualityScore))
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
