import SwiftUI

struct WireWaterfallInspectorView: View {
    private enum InspectorTab: String, CaseIterable, Identifiable {
        case waterfall = "Waterfall"
        case chunks = "Chunks"

        var id: String { rawValue }
    }

    @Environment(\.appTextScale) private var appTextScale
    let session: SessionRecord

    @State private var selectedTab: InspectorTab = .waterfall
    @State private var stallThresholdMilliseconds = 500.0
    @State private var selectedChunkIndex: Int?

    private var phases: [WireTimingPhaseMeasurement] {
        WireWaterfallAnalyzer.phases(for: session.timing)
    }

    private var profile: WireTimingProfile? {
        session.timing.wireProfile
    }

    private var timelineDuration: TimeInterval {
        max(session.timing.duration ?? 0, phases.map { $0.startOffset + $0.duration }.max() ?? 0, 0.001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Timing detail", selection: $selectedTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("wireTimingInspectorTab")

            transferSummary
            transportRecovery

            switch selectedTab {
            case .waterfall:
                waterfall
            case .chunks:
                chunkTimeline
            }
        }
    }

    private var transferSummary: some View {
        HStack(spacing: 8) {
            cacheBadge
            if let transfer = profile?.transfer {
                Text("Headers \(formatBytes(transfer.headerByteCount))")
                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                Text("Wire body \(formatBytes(transfer.transferBodyByteCount))")
                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                if let decoded = transfer.decodedBodyByteCount,
                   transfer.contentEncoding != nil {
                    Text("Decoded \(formatBytes(decoded))")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                    if let savings = transfer.compressionSavingsFraction {
                        Text("\(savings.formatted(.percent.precision(.fractionLength(1)))) saved")
                            .appFont(.caption, scale: appTextScale, weight: .semibold)
                            .foregroundStyle(.green)
                    }
                }
            } else {
                Text("Wire transfer metrics were not recorded for this session.")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(nil)
    }

    private var transportRecovery: some View {
        let assessment = TransportRecoveryAssessment.assess(profile?.transport)
        return DisclosureGroup("Transport recovery") {
            VStack(alignment: .leading, spacing: 8) {
                Text(assessment.explanation)
                    .appFont(.caption, scale: appTextScale)
                ForEach(assessment.actions, id: \.tool) { action in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(action.purpose).appFont(.caption, scale: appTextScale, weight: .semibold)
                        Text(action.verification).appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(assessment.limitations).appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        }
        .appFont(.caption, scale: appTextScale)
        .accessibilityIdentifier("wireTransportRecovery")
    }

    @ViewBuilder
    private var cacheBadge: some View {
        switch WireWaterfallAnalyzer.cacheDisposition(headers: session.response?.headers ?? []) {
        case .hit:
            badge("Cache hit", color: .green)
        case .miss:
            badge("Cache miss", color: .orange)
        case .unknown:
            badge("Cache unknown", color: .secondary)
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .appFont(.caption2, scale: appTextScale, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var waterfall: some View {
        if phases.isEmpty {
            Text("This capture predates wire profiling or did not use an observable upstream HTTP path.")
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(phases) { measurement in
                    HStack(spacing: 8) {
                        Text(measurement.phase.title)
                            .appFont(.caption, scale: appTextScale, weight: .medium)
                            .frame(width: 108, alignment: .leading)
                        GeometryReader { geometry in
                            let width = geometry.size.width
                            let start = width * measurement.startOffset / timelineDuration
                            let barWidth = max(2, width * measurement.duration / timelineDuration)
                            Capsule()
                                .fill(color(for: measurement.phase))
                                .frame(width: barWidth, height: 9)
                                .offset(x: start)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 14)
                        Text(formatDuration(measurement.duration))
                            .appFont(.caption2, scale: appTextScale, design: .monospaced)
                            .frame(width: 66, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(measurement.phase.title)
                    .accessibilityValue(formatDuration(measurement.duration))
                }
            }
        }
    }

    @ViewBuilder
    private var chunkTimeline: some View {
        if let profile, !profile.chunks.isEmpty {
            let threshold = stallThresholdMilliseconds / 1_000
            let stalled = WireWaterfallAnalyzer.stalledChunkIndices(profile: profile, threshold: threshold)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Stall threshold")
                        .appFont(.caption, scale: appTextScale, weight: .medium)
                    Slider(value: $stallThresholdMilliseconds, in: 100...5_000, step: 100)
                    Text("\(Int(stallThresholdMilliseconds)) ms")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                        .frame(width: 68, alignment: .trailing)
                }

                GeometryReader { geometry in
                    let lastOffset = max(profile.chunks.last?.offset ?? 0, 0.001)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(height: 1)
                        ForEach(Array(profile.chunks.enumerated()), id: \.offset) { index, chunk in
                            Button {
                                selectedChunkIndex = index
                            } label: {
                                Capsule()
                                    .fill(stalled.contains(index) ? Color.red : Color.accentColor)
                                    .frame(width: stalled.contains(index) ? 4 : 2, height: stalled.contains(index) ? 30 : 20)
                            }
                            .buttonStyle(.plain)
                            .offset(x: max(0, geometry.size.width * chunk.offset / lastOffset - 1))
                            .accessibilityLabel("Chunk \(index + 1)")
                            .accessibilityValue("\(formatBytes(chunk.byteCount)) at \(formatDuration(chunk.offset))")
                        }
                    }
                }
                .frame(height: 34)

                if let selectedChunkIndex, profile.chunks.indices.contains(selectedChunkIndex) {
                    let chunk = profile.chunks[selectedChunkIndex]
                    Text("Chunk \(selectedChunkIndex + 1): \(formatBytes(chunk.byteCount)) at \(formatDuration(chunk.offset))")
                        .appFont(.caption, scale: appTextScale, design: .monospaced)
                }

                Text("\(profile.chunks.count) sampled reads · \(stalled.count) gaps above threshold" + (profile.omittedChunkCount > 0 ? " · \(profile.omittedChunkCount) additional reads summarized" : ""))
                    .appFont(.caption2, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No chunk-arrival samples were recorded for this session.")
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)
        }
    }

    private func color(for phase: WireTimingPhase) -> Color {
        switch phase {
        case .connect: return .blue
        case .tls: return .purple
        case .requestSend: return .indigo
        case .wait: return .orange
        case .contentDownload: return .green
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 0.001 {
            return "\((duration * 1_000_000).formatted(.number.precision(.fractionLength(0)))) µs"
        }
        if duration < 1 {
            return "\((duration * 1_000).formatted(.number.precision(.fractionLength(1)))) ms"
        }
        return "\(duration.formatted(.number.precision(.fractionLength(3)))) s"
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
