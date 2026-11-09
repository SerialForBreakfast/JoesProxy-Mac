//
//  DiscontinuityAlignmentCardView.swift
//  JoesProxy
//
//  SwiftUI view for inspecting multi-rendition discontinuity alignment,
//  ABR switching safety, SCTE-35 ad breaks, and accumulated timeline drift.
//

import SwiftUI

struct DiscontinuityAlignmentCardView: View {
    let report: MultiRenditionAlignmentReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Multi-Rendition Discontinuity Alignment")
                        .font(.headline)
                    Text("Audits cross-variant tag parity, SCTE-35 ad boundaries, and ABR switching safety")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                statusBadge
            }

            // Stream Architecture Badges
            HStack(spacing: 8) {
                metricPill(
                    label: "Stream Mode",
                    value: report.isMultiplexed ? "Multiplexed (AV in single container)" : "Demuxed (\(report.audioTrackCount) Audio Tracks)"
                )
                metricPill(
                    label: "Variants",
                    value: "\(report.variantCount)"
                )
                metricPill(
                    label: "Max Accumulated Drift",
                    value: String(format: "%.1fms", report.totalAccumulatedDriftMs)
                )
            }

            // Hazard Warnings
            if !report.hazards.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected Switching & Playback Hazards (\(report.hazards.count))")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.red)

                    ForEach(report.hazards, id: \.userFacingMessage) { hazard in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(hazard.isCriticalSwitchingHazard ? Color.red : Color.orange)
                                .frame(width: 6, height: 6)
                                .padding(.top, 4)

                            Text(hazard.userFacingMessage)
                                .font(.caption2)
                                .foregroundColor(hazard.isCriticalSwitchingHazard ? .red : .orange)
                        }
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.06))
                .cornerRadius(6)
            }

            // Rendition Alignment Table
            if !report.variants.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Variant Discontinuity Alignment Ladder")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    VStack(spacing: 4) {
                        ForEach(report.variants) { variant in
                            HStack {
                                Text(variant.resolution ?? variant.uri)
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .frame(width: 90, alignment: .leading)

                                if let bw = variant.bandwidth {
                                    Text("\(bw / 1000) kbps")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .frame(width: 70, alignment: .leading)
                                }

                                Text("Segments: \(variant.segmentCount)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                Spacer()

                                Text("Discontinuities: \(variant.discontinuityCount)")
                                    .font(.caption2)
                                    .foregroundColor(.blue)

                                Text("Drift: \(String(format: "%.1fms", variant.accumulatedDriftMs))")
                                    .font(.caption2)
                                    .foregroundColor(variant.accumulatedDriftMs > 250 ? .orange : .secondary)
                            }
                            .padding(6)
                            .background(Color.primary.opacity(0.02))
                            .cornerRadius(4)
                        }
                    }
                }
            }

            // SCTE-35 / SSAI Ad Breaks Section
            if !report.adBreaks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SCTE-35 / SSAI Ad Breaks (\(report.adBreaks.count))")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ForEach(report.adBreaks) { ad in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(ad.adBreakID)
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                Spacer()
                                Text("Offset: \(String(format: "%.1fs", ad.startTimeSeconds)) (\(String(format: "%.1fs", ad.durationSeconds)) dur)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if let scte = ad.scte35Payload {
                                Text("SCTE-35: \(scte)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            if let before = ad.channelLayoutBefore, let during = ad.channelLayoutDuringAd {
                                Text("Audio Channel Transition: \(before) -> \(during)")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
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

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(report.isSwitchingSafe ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(report.isSwitchingSafe ? "Switching Safe" : "Switching Hazard")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(report.isSwitchingSafe ? .green : .red)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(report.isSwitchingSafe ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
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
