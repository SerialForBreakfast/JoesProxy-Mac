//
//  CMCDTelemetryCardView.swift
//  JoesProxy
//
//  SwiftUI card for inspecting CTA-5004 CMCD and CTA-5006 CMSD player telemetry.
//

import SwiftUI

struct CMCDTelemetryCardView: View {
    let report: CMCDSessionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CTA-5004 CMCD Player Telemetry")
                        .font(.headline)
                    Text("Real-time client QoE, buffer health, throughput headroom, and playback deadlines")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                healthBadge
            }

            // Transport & Session Badges
            HStack(spacing: 8) {
                metricPill(label: "Transport", value: report.transportMethod.rawValue)
                if let sid = report.cmcd.sessionID {
                    metricPill(label: "Session ID", value: sid)
                }
                if let cid = report.cmcd.contentID {
                    metricPill(label: "Content ID", value: cid)
                }
                if let fmt = report.cmcd.streamingFormat {
                    metricPill(label: "Format", value: fmt.title)
                }
            }

            // Primary Buffer & Throughput Gauges
            HStack(spacing: 12) {
                // Buffer Length Gauge
                VStack(alignment: .leading, spacing: 4) {
                    Text("Client Buffer Length")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let bl = report.cmcd.bufferLengthMs {
                        Text(String(format: "%.1fs", Double(bl) / 1000.0))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(bl < 2000 ? .red : (bl < 4000 ? .orange : .green))
                    } else {
                        Text("Not Reported")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.02))
                .cornerRadius(6)

                // Throughput Headroom
                VStack(alignment: .leading, spacing: 4) {
                    Text("Throughput Headroom")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let headroom = report.throughputHeadroomPercentage {
                        Text(String(format: "%+.0f%%", headroom))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(headroom >= 0 ? .green : .red)
                    } else if let mtp = report.cmcd.measuredThroughputKbps {
                        Text("\(mtp) kbps")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                    } else {
                        Text("N/A")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.02))
                .cornerRadius(6)
            }

            // Secondary Metrics Table
            VStack(spacing: 4) {
                if let br = report.cmcd.encodedBitrateKbps {
                    metricRow(label: "Encoded Bitrate (br)", value: "\(br) kbps")
                }
                if let tb = report.cmcd.topBitrateKbps {
                    metricRow(label: "Top Ladder Bitrate (tb)", value: "\(tb) kbps")
                }
                if let mtp = report.cmcd.measuredThroughputKbps {
                    metricRow(label: "Measured Throughput (mtp)", value: "\(mtp) kbps")
                }
                if let dl = report.cmcd.deadlineMs {
                    metricRow(label: "Decoding Deadline (dl)", value: "\(dl)ms")
                }
                if let d = report.cmcd.objectDurationMs {
                    metricRow(label: "Object Duration (d)", value: "\(d)ms")
                }
                if let ot = report.cmcd.objectType {
                    metricRow(label: "Object Type (ot)", value: ot.title)
                }
                if let bs = report.cmcd.bufferStarvation {
                    metricRow(label: "Buffer Starvation (bs)", value: bs ? "YES (STALL)" : "No")
                }
                if let su = report.cmcd.isStartup {
                    metricRow(label: "Startup Segment (su)", value: su ? "Yes" : "No")
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.02))
            .cornerRadius(6)

            // Anomalies List
            if !report.anomalies.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected Telemetry & QoE Risks (\(report.anomalies.count))")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.red)

                    ForEach(report.anomalies, id: \.userFacingMessage) { anomaly in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(anomaly.isCritical ? Color.red : Color.orange)
                                .frame(width: 6, height: 6)
                                .padding(.top, 4)
                            Text(anomaly.userFacingMessage)
                                .font(.caption2)
                                .foregroundColor(anomaly.isCritical ? .red : .orange)
                        }
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.06))
                .cornerRadius(6)
            }

            // CMSD Server Telemetry Section
            if let cmsd = report.cmsd {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CTA-5006 CMSD Server Response Telemetry")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        if let etp = cmsd.estimatedThroughputKbps {
                            metricPill(label: "Server ETP", value: "\(etp) kbps")
                        }
                        if let rtt = cmsd.roundTripTimeMs {
                            metricPill(label: "Server RTT", value: "\(rtt)ms")
                        }
                        if let rd = cmsd.responseDelayMs {
                            metricPill(label: "Response Delay", value: "\(rd)ms")
                        }
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
                .fill(report.healthScore >= 80 ? Color.green : (report.healthScore >= 50 ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            Text(String(format: "Health: %.0f/100", report.healthScore))
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(report.healthScore >= 80 ? .green : (report.healthScore >= 50 ? .orange : .red))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((report.healthScore >= 80 ? Color.green : (report.healthScore >= 50 ? Color.orange : Color.red)).opacity(0.1))
        .cornerRadius(6)
    }

    private func metricPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(4)
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption2)
                .fontWeight(.semibold)
        }
    }
}
