//
//  StreamingQualityWaterfallView.swift
//  JoesProxy
//
//  Native SwiftUI visual inspector for Streaming Quality Waterfall (HLS & DASH).
//

import SwiftUI

struct StreamingQualityWaterfallView: View {
    let report: StreamingQualityWaterfallReport
    @Environment(\.appTextScale) private var appTextScale

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                kpiScorecardSection
                bitrateLadderSection
                segmentWaterfallSection
            }
            .padding()
        }
        .accessibilityIdentifier("streamingQualityWaterfallView")
    }

    // MARK: - KPI Scorecards

    private var kpiScorecardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Streaming Quality & Buffer Overview")
                .mediaInfoFont(.headline, scale: appTextScale, weight: .semibold)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                kpiCard(
                    title: "Startup Latency (TTFF)",
                    value: report.ttff != nil ? String(format: "%.2f s", report.ttff!) : "—",
                    subtitle: "First frame delivered",
                    icon: "bolt.fill",
                    tint: .blue
                )

                kpiCard(
                    title: "Average Bitrate",
                    value: formatBandwidth(report.averageBitrateBps),
                    subtitle: "\(report.bitrateLadder.count) variants available",
                    icon: "antenna.radiowaves.left.and.right",
                    tint: .purple
                )

                kpiCard(
                    title: "Slow Segments",
                    value: "\(report.slowSegmentCount)",
                    subtitle: report.slowSegmentCount > 0 ? "Download > Duration" : "All within budget",
                    icon: "exclamationmark.triangle.fill",
                    tint: report.slowSegmentCount > 0 ? .orange : .green
                )

                kpiCard(
                    title: "Buffer Stalls",
                    value: "\(report.estimatedStallCount)",
                    subtitle: report.estimatedStallCount > 0 ? "Starvation detected" : "Smooth playback",
                    icon: "waveform.path.ecg",
                    tint: report.estimatedStallCount > 0 ? .red : .green
                )

                kpiCard(
                    title: "Quality Switches",
                    value: "\(report.switchingEvents.count)",
                    subtitle: report.oscillationCount > 0 ? "\(report.oscillationCount) oscillations" : "Stable ladder",
                    icon: "arrow.triangle.swap",
                    tint: report.oscillationCount > 0 ? .orange : .blue
                )

                if let hitRatio = report.cdnCacheHitRatio {
                    kpiCard(
                        title: "CDN Cache Hit",
                        value: String(format: "%.0f%%", hitRatio * 100),
                        subtitle: "Edge cache efficiency",
                        icon: "shippingbox.fill",
                        tint: hitRatio > 0.8 ? .green : .secondary
                    )
                }
            }
        }
    }

    // MARK: - Bitrate Ladder

    private var bitrateLadderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active Bitrate Ladder (\(report.manifestKind))")
                .mediaInfoFont(.subheadline, scale: appTextScale, weight: .semibold)

            if report.bitrateLadder.isEmpty {
                Text("No master manifest variants detected in this stream.")
                    .mediaInfoFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(report.bitrateLadder) { variant in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(variant.resolution ?? "Audio / Other")
                                .mediaInfoFont(.caption, scale: appTextScale, weight: .bold)
                            Text(variant.formattedBandwidth)
                                .mediaInfoFont(.caption2, scale: appTextScale)
                                .foregroundStyle(.secondary)
                            if let codecs = variant.codecs {
                                Text(codecs)
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    // MARK: - Segment Waterfall

    private var segmentWaterfallSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Segment Download Latency vs. Duration Waterfall")
                .mediaInfoFont(.subheadline, scale: appTextScale, weight: .semibold)

            if report.segments.isEmpty {
                Text("No media segments captured for this stream.")
                    .mediaInfoFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(report.segments) { segment in
                        segmentRow(segment)
                    }
                }
            }
        }
    }

    private func segmentRow(_ segment: StreamingWaterfallSegment) -> some View {
        HStack(spacing: 12) {
            // Sequence & Type
            HStack(spacing: 6) {
                Text("#\(segment.sequenceNumber ?? 0)")
                    .mediaInfoFont(.caption, scale: appTextScale, weight: .bold)
                    .frame(width: 36, alignment: .leading)

                typeBadge(segment.mediaType)
            }
            .frame(width: 100, alignment: .leading)

            // Resolution / Quality Badge
            if let res = segment.variantResolution {
                Text(res)
                    .mediaInfoFont(.caption2, scale: appTextScale, weight: .semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .cornerRadius(4)
            }

            // Waterfall Latency Bar
            GeometryReader { geometry in
                let maxSpan = max(10.0, segment.segmentDuration * 1.5)
                let downloadWidth = min(geometry.size.width, (segment.downloadDuration / maxSpan) * geometry.size.width)
                let durationWidth = min(geometry.size.width, (segment.segmentDuration / maxSpan) * geometry.size.width)

                ZStack(alignment: .leading) {
                    // Playable duration baseline (dotted / translucent)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: durationWidth, height: 12)

                    // Actual download time bar
                    RoundedRectangle(cornerRadius: 3)
                        .fill(segment.isSlowDownload ? Color.red : Color.green)
                        .frame(width: max(4, downloadWidth), height: 12)
                }
            }
            .frame(height: 12)

            // Metrics Summary
            HStack(spacing: 8) {
                Text(String(format: "%.2fs", segment.downloadDuration))
                    .mediaInfoFont(.caption2, scale: appTextScale, weight: segment.isSlowDownload ? .bold : .regular)
                    .foregroundStyle(segment.isSlowDownload ? .red : .primary)
                    .frame(width: 48, alignment: .trailing)

                Text(segment.formattedSpeed)
                    .mediaInfoFont(.caption2, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)

                if let hit = segment.isCacheHit {
                    Text(hit ? "HIT" : "MISS")
                        .mediaInfoFont(.caption2, scale: appTextScale, weight: .bold)
                        .foregroundStyle(hit ? .green : .orange)
                        .frame(width: 36, alignment: .center)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(segment.isSlowDownload ? Color.red.opacity(0.05) : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    // MARK: - Helpers

    private func kpiCard(
        title: String,
        value: String,
        subtitle: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .mediaInfoFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .mediaInfoFont(.title3, scale: appTextScale, weight: .bold)
            Text(subtitle)
                .mediaInfoFont(.caption2, scale: appTextScale)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func typeBadge(_ type: StreamingSegmentMediaType) -> some View {
        let title: String
        let tint: Color
        switch type {
        case .video:
            title = "Video"
            tint = .blue
        case .audio:
            title = "Audio"
            tint = .purple
        case .subtitle:
            title = "Sub"
            tint = .teal
        case .initSegment:
            title = "Init"
            tint = .orange
        case .manifest:
            title = "Manifest"
            tint = .indigo
        case .unknown:
            title = "Segment"
            tint = .secondary
        }

        return Text(title)
            .mediaInfoFont(.caption2, scale: appTextScale, weight: .medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
            .cornerRadius(4)
    }

    private func formatBandwidth(_ bps: Double) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", bps / 1_000_000.0)
        } else if bps >= 1000 {
            return String(format: "%.0f kbps", bps / 1000.0)
        } else {
            return "\(Int(bps)) bps"
        }
    }
}
