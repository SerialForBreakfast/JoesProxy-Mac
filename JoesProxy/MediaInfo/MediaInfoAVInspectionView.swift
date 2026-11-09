//
//  MediaInfoAVInspectionView.swift
//  JoesProxy
//
//  Explicit captured/live AVFoundation inspection controls and report presentation.
//

import SwiftUI

struct MediaInfoAVInspectionView: View {
    let session: SessionRecord
    let textScale: CGFloat
    let contentRevision: UInt64

    @State private var selectedSource: AVMediaInspectionSource
    @State private var sampleTimeText = "1.0"
    @State private var inspection = AVMediaInspectionModel()
    private var report: AVMediaInspectionReport? { inspection.report }
    private var isInspecting: Bool { inspection.isInspecting }

    private let eligibility: AVMediaInspectionEligibility

    init(session: SessionRecord, textScale: CGFloat, contentRevision: UInt64 = 0) {
        self.session = session
        self.textScale = textScale
        self.contentRevision = contentRevision
        let eligibility = AVMediaInspectionEligibility.evaluate(session: session)
        self.eligibility = eligibility
        _selectedSource = State(initialValue: eligibility.availableSources.first ?? .liveURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            if isInspecting {
                loadingView
            } else if let report {
                reportView(report)
            }
        }
        .onDisappear {
            inspection.cancel()
        }
        .onChange(of: contentRevision) { inspection.cancel(clearReport: true) }
    }

    private var controls: some View {
        GroupBox("Media Engine Inspection") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Prepare this item with AVFoundation and decode one frame only when requested.")
                    .mediaInfoFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)

                if eligibility.availableSources.count > 1 {
                    Picker("Source", selection: $selectedSource) {
                        ForEach(eligibility.availableSources) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("mediaInfoInspectionSourcePicker")
                    .onChange(of: selectedSource) {
                        inspection.cancel(clearReport: true)
                    }
                } else if let source = eligibility.availableSources.first {
                    Label(source.title, systemImage: source == .capturedItem ? "externaldrive" : "network")
                        .mediaInfoFont(.body, scale: textScale, weight: .semibold)
                }

                sourceExplanation

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Frame Time")
                        .mediaInfoFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                    TextField("Seconds", text: $sampleTimeText)
                        .frame(width: 90)
                        .accessibilityLabel("Frame sample time in seconds")
                        .accessibilityIdentifier("mediaInfoInspectionSampleTime")
                    Text("seconds")
                        .mediaInfoFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if isInspecting {
                        Button("Cancel", role: .cancel) {
                            inspection.cancel()
                        }
                        .accessibilityIdentifier("mediaInfoCancelInspectionButton")
                    } else {
                        Button {
                            runInspection()
                        } label: {
                            Label(report == nil ? "Run Media Engine Inspection" : "Retry Inspection", systemImage: "waveform.path.ecg")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canInspect)
                        .accessibilityIdentifier("mediaInfoRunInspectionButton")
                    }

                    if report != nil && !isInspecting {
                        Button("Run at Different Time") {
                            runInspection()
                        }
                        .disabled(!canInspect)
                        .accessibilityIdentifier("mediaInfoRerunInspectionButton")
                    }
                }

                if eligibility.availableSources.isEmpty {
                    Label("This item has no available media-engine inspection source.", systemImage: "info.circle")
                        .mediaInfoFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private var sourceExplanation: some View {
        let provenance = selectedSource.provenance
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: selectedSource == .capturedItem ? "externaldrive.fill.badge.checkmark" : "bolt.horizontal.circle")
                .foregroundStyle(selectedSource == .capturedItem ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(provenance.title)
                    .mediaInfoFont(.caption, scale: textScale, weight: .semibold)
                Text(provenance.summary)
                    .mediaInfoFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
                if selectedSource == .liveURL {
                    Text("This starts new network traffic. The CDN, selected variant, or returned content may differ from the capture.")
                        .mediaInfoFont(.caption2, scale: textScale)
                        .foregroundStyle(.orange)
                    if eligibility.containsSensitiveRequestData {
                        Text("The request contains credentials or token-like data. Captured headers are not replayed; the original URL, including its query, is used as captured.")
                            .mediaInfoFont(.caption2, scale: textScale)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }

        if selectedSource == .capturedItem,
           !eligibility.capturedItemAvailable,
           let reason = eligibility.capturedItemReason {
            Text(reason)
                .mediaInfoFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
        }
        if selectedSource == .liveURL,
           !eligibility.liveURLAvailable,
           let reason = eligibility.liveURLReason {
            Text(reason)
                .mediaInfoFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
        }
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Preparing media and decoding one frame…")
                .mediaInfoFont(.body, scale: textScale)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("mediaInfoInspectionProgress")
    }

    private func reportView(_ report: AVMediaInspectionReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if report.isPartial {
                Label("Inspection completed with partial results.", systemImage: "exclamationmark.triangle")
                    .mediaInfoFont(.caption, scale: textScale)
                    .foregroundStyle(.orange)
            }
            overviewSection(report)
            variantsSection(report.variants)
            tracksSection(report)
            playbackSection(report)
            decodedFrameSection(report.decodedFrame)
            diagnosticsSection(report)
        }
        .accessibilityIdentifier("mediaInfoInspectionReport")
    }

    private func overviewSection(_ report: AVMediaInspectionReport) -> some View {
        DisclosureGroup("Overview") {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow("Source", value: report.source.title)
                metadataRow("Item", value: report.sourceDescription)
                if let asset = report.asset {
                    metadataRow("Playable", value: asset.isPlayable ? "Yes" : "No")
                    metadataRow("Protected", value: asset.hasProtectedContent ? "Yes" : "No")
                    metadataRow("Exportable", value: asset.isExportable ? "Yes" : "No")
                    metadataRow("Precise Timing", value: asset.providesPreciseDurationAndTiming ? "Yes" : "No")
                    if let duration = asset.duration {
                        metadataRow("Duration", value: formatDuration(duration))
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func variantsSection(_ variants: [AVMediaVariantInfo]) -> some View {
        DisclosureGroup("Variants (\(variants.count))") {
            if variants.isEmpty {
                Text("No adaptive variants were reported for this item.")
                    .mediaInfoFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(variants) { variant in
                        VStack(alignment: .leading, spacing: 4) {
                            let dimensions = dimensionsText(variant.presentationWidth, variant.presentationHeight)
                            Text(dimensions ?? "Audio or unspecified variant")
                                .mediaInfoFont(.body, scale: textScale, weight: .semibold, design: .monospaced)
                            if let peak = variant.peakBitRate { metadataRow("Peak Bitrate", value: formatBitrate(peak)) }
                            if let average = variant.averageBitRate { metadataRow("Average Bitrate", value: formatBitrate(average)) }
                            if let rate = variant.nominalFrameRate { metadataRow("Frame Rate", value: String(format: "%.2f fps", rate)) }
                            if !variant.videoCodecs.isEmpty { metadataRow("Video Codecs", value: variant.videoCodecs.joined(separator: ", ")) }
                            if !variant.audioFormats.isEmpty { metadataRow("Audio Formats", value: variant.audioFormats.joined(separator: ", ")) }
                            if let range = variant.videoRange { metadataRow("Video Range", value: range) }
                            if let url = variant.playlistURL { metadataRow("Playlist", value: url) }
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func tracksSection(_ report: AVMediaInspectionReport) -> some View {
        DisclosureGroup("Tracks and Languages") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(report.videoTracks.enumerated()), id: \.offset) { _, track in
                    metadataRow(
                        "Video",
                        value: "\(track.width) x \(track.height), \(track.codec ?? "unknown codec"), \(String(format: "%.2f", track.nominalFrameRate)) fps"
                    )
                }
                ForEach(Array(report.audioTracks.enumerated()), id: \.offset) { _, track in
                    let pieces = [
                        track.codec,
                        track.channels.map { "\($0) channels" },
                        track.sampleRate.map { "\(Int($0)) Hz" },
                        track.language
                    ].compactMap { $0 }
                    metadataRow("Audio", value: pieces.joined(separator: ", "))
                }
                ForEach(Array(report.subtitleTracks.enumerated()), id: \.offset) { _, track in
                    metadataRow("Subtitle", value: track.displayName ?? track.language ?? "Unnamed")
                }
                ForEach(report.mediaSelectionGroups) { group in
                    metadataRow(
                        group.characteristic,
                        value: group.options.map(\.displayName).joined(separator: ", ")
                    )
                }
                if report.videoTracks.isEmpty && report.audioTracks.isEmpty && report.subtitleTracks.isEmpty {
                    Text("No static tracks were exposed. Adaptive streams may describe their renditions as variants instead.")
                        .mediaInfoFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    private func playbackSection(_ report: AVMediaInspectionReport) -> some View {
        DisclosureGroup("Playback Probe") {
            VStack(alignment: .leading, spacing: 6) {
                if let player = report.player {
                    metadataRow("Status", value: player.status)
                    metadataRow("Presentation", value: "\(player.presentationWidth) x \(player.presentationHeight)")
                    metadataRow("Likely to Keep Up", value: player.isPlaybackLikelyToKeepUp ? "Yes" : "No")
                    metadataRow("Buffer Empty", value: player.isPlaybackBufferEmpty ? "Yes" : "No")
                    metadataRow("Loaded Ranges", value: "\(player.loadedTimeRanges.count)")
                    metadataRow("Seekable Ranges", value: "\(player.seekableTimeRanges.count)")
                }
                ForEach(report.accessEvents) { event in
                    metadataRow("Media Requests", value: "\(event.mediaRequestCount)")
                    metadataRow("Observed Bitrate", value: formatBitrate(event.observedBitRate))
                    metadataRow("Indicated Bitrate", value: formatBitrate(event.indicatedBitRate))
                    metadataRow("Transferred", value: ByteCountFormatter.string(fromByteCount: event.transferredBytes, countStyle: .file))
                    if let resource = event.resource { metadataRow("Resource", value: resource) }
                }
                if report.player == nil {
                    Text("The player did not become ready.")
                        .mediaInfoFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    private func decodedFrameSection(_ frame: AVDecodedFrameInfo?) -> some View {
        DisclosureGroup("Decoded Frame") {
            VStack(alignment: .leading, spacing: 6) {
                if let frame {
                    metadataRow("Requested Time", value: String(format: "%.3fs", frame.requestedTime))
                    metadataRow("Decoded Time", value: String(format: "%.3fs", frame.decodedTime))
                    metadataRow("Dimensions", value: "\(frame.width) x \(frame.height)")
                    metadataRow("Pixel Format", value: frame.pixelFormat)
                    metadataRow("Layout", value: frame.isPlanar ? "Planar (\(frame.planeCount) planes)" : "Non-planar")
                    metadataRow("Estimated Memory", value: ByteCountFormatter.string(fromByteCount: Int64(frame.estimatedByteSize), countStyle: .memory))
                    metadataRow("Metal Compatible", value: frame.isMetalCompatible ? "Yes" : "No")
                    metadataRow("IOSurface Backing", value: frame.hasIOSurface ? "Present" : "Not provided")
                    ForEach(frame.planes) { plane in
                        metadataRow("Plane \(plane.id)", value: "\(plane.width) x \(plane.height), \(plane.bytesPerRow) bytes/row")
                    }
                    ForEach(frame.attachments.keys.sorted(), id: \.self) { key in
                        metadataRow(key, value: frame.attachments[key] ?? "")
                    }
                    if frame.hasIOSurface {
                        metadataRow("Surface Dimensions", value: dimensionsText(frame.ioSurfaceWidth, frame.ioSurfaceHeight) ?? "Unknown")
                        if let bytesPerRow = frame.ioSurfaceBytesPerRow { metadataRow("Surface Row Bytes", value: "\(bytesPerRow)") }
                        if let size = frame.ioSurfaceAllocationSize {
                            metadataRow("Surface Allocation", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .memory))
                        }
                    }
                } else {
                    Text("No decoded frame was available.")
                        .mediaInfoFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    private func diagnosticsSection(_ report: AVMediaInspectionReport) -> some View {
        DisclosureGroup("Diagnostics") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.stages) { stage in
                    VStack(alignment: .leading, spacing: 2) {
                        metadataRow(stage.title, value: "\(stage.outcome.rawValue), \(String(format: "%.3fs", stage.duration))")
                        if let message = stage.message {
                            Text(message)
                                .mediaInfoFont(.caption2, scale: textScale)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(report.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .mediaInfoFont(.caption, scale: textScale)
                        .foregroundStyle(.orange)
                }
                ForEach(report.errors) { error in
                    Text("\(error.domain) \(error.statusCode): \(error.comment ?? "Playback error")")
                        .mediaInfoFont(.caption, scale: textScale)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 8)
        }
    }

    private var canInspect: Bool {
        guard let value = Double(sampleTimeText), value >= 0, value.isFinite else { return false }
        switch selectedSource {
        case .capturedItem: return eligibility.capturedItemAvailable
        case .liveURL: return eligibility.liveURLAvailable
        }
    }

    private func runInspection() {
        guard canInspect, let sampleTime = Double(sampleTimeText) else { return }
        guard let input = makeInput(source: selectedSource, sampleTime: sampleTime) else { return }
        inspection.request(input)
    }

    private func makeInput(source: AVMediaInspectionSource, sampleTime: TimeInterval) -> AVMediaInspectionInput? {
        switch source {
        case .capturedItem:
            guard let response = session.response else { return nil }
            return AVMediaInspectionInput(
                source: source,
                url: nil,
                capturedData: nil,
                capturedFileExtension: capturedFileExtension,
                displayName: session.request.path.split(separator: "?").first.map(String.init) ?? "Captured media item",
                sampleTime: sampleTime,
                initialWarnings: [],
                capturedResponse: response
            )
        case .liveURL:
            guard let url = MediaDetector.primaryMediaURL(for: session) else { return nil }
            var warnings = ["Live results describe a new AVFoundation request, not the original captured transfer."]
            if eligibility.containsSensitiveRequestHeaders {
                warnings.append("Sensitive captured credentials were not replayed.")
            }
            if eligibility.containsSensitiveURLQuery {
                warnings.append("The live probe used the original URL query; displayed results redact it.")
            }
            return AVMediaInspectionInput(
                source: source,
                url: url,
                capturedData: nil,
                capturedFileExtension: nil,
                displayName: CapturedURLRedaction.displayString(for: url.absoluteString),
                sampleTime: sampleTime,
                initialWarnings: warnings
            )
        }
    }

    private var capturedFileExtension: String? {
        let pathExtension = MediaDetector.absoluteURL(for: session.request)?.pathExtension
        if let pathExtension, !pathExtension.isEmpty { return pathExtension }
        guard let contentType = session.response?.headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.lowercased() else { return nil }
        if contentType.contains("mp2t") { return "ts" }
        if contentType.contains("mp4") { return "mp4" }
        if contentType.contains("quicktime") { return "mov" }
        return nil
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .mediaInfoFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .mediaInfoFont(.body, scale: textScale, design: .monospaced)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "Unknown" }
        return String(format: "%.3fs", seconds)
    }

    private func formatBitrate(_ bitrate: Double) -> String {
        guard bitrate.isFinite, bitrate > 0 else { return "Unknown" }
        if bitrate >= 1_000_000 { return String(format: "%.2f Mbps", bitrate / 1_000_000) }
        return String(format: "%.0f kbps", bitrate / 1_000)
    }

    private func dimensionsText(_ width: Int?, _ height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) x \(height)"
    }
}
