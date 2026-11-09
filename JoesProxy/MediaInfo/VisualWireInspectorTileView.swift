//
//  VisualWireInspectorTileView.swift
//  JoesProxy
//
//  SwiftUI tile displaying dominant palette, compression BPP, aspect ratios, and anomaly flags.
//

import SwiftUI
import AppKit

struct VisualWireInspectorTileView: View {
    let report: VisualAssetReport

    @State private var copiedHex: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Anomaly Warnings Banner
            if !report.anomalies.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.anomalies, id: \.userFacingMessage) { anomaly in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text(anomaly.userFacingMessage)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                        }
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }

            // Metrics Badges
            HStack(spacing: 8) {
                metricBadge(
                    label: "Dimensions",
                    value: "\(report.pixelWidth)x\(report.pixelHeight)"
                )

                metricBadge(
                    label: "Aspect Ratio",
                    value: report.aspectRatioString
                )

                metricBadge(
                    label: "BPP",
                    value: String(format: "%.2f", report.bytesPerPixel)
                )

                if report.hasTransparency {
                    metricBadge(
                        label: "Alpha",
                        value: report.isFullyTransparent ? "100% Blank" : "Transparent"
                    )
                }
            }

            // Dominant Color Palette Bar
            if !report.dominantPalette.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dominant Color Palette")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    HStack(spacing: 6) {
                        ForEach(report.dominantPalette) { swatch in
                            Button(action: {
                                copyHex(swatch.hex)
                            }) {
                                VStack(spacing: 3) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(red: swatch.red, green: swatch.green, blue: swatch.blue))
                                        .frame(height: 24)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
                                        )

                                    Text(swatch.hex)
                                        .font(.system(size: 9).monospaced())
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Click to copy \(swatch.hex) (\(Int(swatch.weight * 100))%)")
                        }
                    }

                    if let hex = copiedHex {
                        Text("Copied \(hex)!")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func metricBadge(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospaced())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(6)
    }

    private func copyHex(_ hex: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        copiedHex = hex
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedHex = nil
        }
    }
}
