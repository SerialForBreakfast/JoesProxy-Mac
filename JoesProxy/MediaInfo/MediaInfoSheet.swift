//
//  MediaInfoSheet.swift
//  JoesProxy
//
//  Media metadata panel for image, AVAsset, HLS, and DASH inspection.
//

import OSLog
import SwiftUI

/// Sheet presenting media metadata for a captured session.
///
/// Performance: work is lazy. AVFoundation inspection, GOP analysis, and ID3 parsing run only after
/// an explicit user action; opening the window or changing tabs never starts a media-engine probe.
struct MediaInfoSheet: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session.id == rhs.session.id && lhs.contentRevision == rhs.contentRevision
            && lhs.manifestRevision == rhs.manifestRevision
    }
    let session: SessionRecord
    let sessions: [SessionRecord]
    var manifestRevision: UInt64 = 0
    var contentRevision: UInt64 = 0
    @ObservedObject var manifestModel: MediaManifestModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appTextSizeRawValue") private var appTextSizeRawValue = AppTextSize.standard.rawValue
    @State private var selectedTab: MediaInfoTab = .image
    @State private var inspectionCapacityUnavailable = false
    @State private var inspectionRetry = 0
    private var parsedHLSManifestSessions: [ParsedHLSManifestSession] { manifestModel.result.hls }
    private var parsedDASHManifestSessions: [ParsedDASHManifestSession] { manifestModel.result.dash }
    @State private var imageMetadata: ImageMetadata?
    @State private var adXmlParseResult: AdXMLParseResult?
    @State private var adXmlLoading = false
    @State private var timedMetadataResults: [TimedMetadataDetectionResult] = []
    @State private var timedMetadataLoading = false
    @State private var timedMetadataTask: Task<Void, Never>?
    @State private var capturedBinaryStructure: BinaryMediaStructure?
    @State private var capturedBinaryStructureLoading = false
    @State private var transportVideoAnalysis: MPEGTransportStreamVideoAnalysis?
    @State private var transportVideoDiagnostics: MediaParserDiagnostics?
    @State private var transportVideoAnalysisLoading = false
    @State private var transportVideoAnalysisAttempted = false
    @State private var transportVideoAnalysisRequestID = 0

    private let imageMetadataService = ImageMetadataService()
    private let timedMetadataParser = TimedMetadataID3Parser()
    private let mediaParserLogger = Logger(subsystem: "com.JoesProxyApp.MediaInfo", category: "MediaParsing")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            tabPicker
            tabContent
            if inspectionCapacityUnavailable {
                HStack {
                    Text("Media analysis is busy. Retry when the current analysis finishes.")
                        .appFont(.caption, scale: appTextScale)
                    Button("Retry Analysis") {
                        inspectionCapacityUnavailable = false
                        inspectionRetry &+= 1
                    }
                }.padding(8)
            }
            if manifestModel.result.omittedCount > 0 {
                Text(verbatim: "\(manifestModel.result.omittedCount) related manifests could not be parsed within the lookup budget. Inspect those captures directly; correlation is incomplete.")
                    .appFont(.caption, scale: appTextScale)
                    .padding(8)
            }
        }
        .frame(minWidth: 760, idealWidth: 980, maxWidth: .infinity, minHeight: 560, idealHeight: 720, maxHeight: .infinity)
        .background(MediaInfoWindowConfigurator())
        .dynamicTypeSize(appTextSize.dynamicTypeSize)
        .onAppear {
            selectDefaultTab()
        }
        .task(id: imageMetadataTaskID) {
            guard selectedTab == .image else { return }
            await loadImageMetadataIfNeeded()
        }
        .task(id: adXmlTaskID) {
            guard selectedTab == .adXml else { return }
            await loadAdXmlIfNeeded()
        }
        .task(id: "\(manifestRevision)-\(selectedTab)") {
            guard selectedTab == .hls || selectedTab == .dash || selectedTab == .avAsset else { return }
            manifestModel.request(sessions)
        }
        .onDisappear {
            manifestModel.cancelPending()
            timedMetadataTask?.cancel()
        }
        .task(id: binaryStructureTaskID) {
            guard selectedTab == .avAsset else { return }
            await loadCapturedBinaryStructure()
        }
        .task(id: "\(session.id)-\(contentRevision)-\(transportVideoAnalysisRequestID)-\(inspectionRetry)") {
            guard transportVideoAnalysisRequestID > 0 else { return }
            await loadTransportVideoAnalysis()
        }
        .task(id: "\(session.id)-\(contentRevision)") {
            timedMetadataTask?.cancel()
            timedMetadataResults = []
            timedMetadataLoading = false
            transportVideoAnalysis = nil
            transportVideoDiagnostics = nil
            transportVideoAnalysisLoading = false
            transportVideoAnalysisAttempted = false
            transportVideoAnalysisRequestID = 0
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Media Info")
                    .mediaInfoFont(.headline, scale: appTextScale, weight: .semibold)
                Text(session.request.host + session.request.path)
                    .mediaInfoFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Close") {
                dismiss()
            }
            .accessibilityIdentifier("mediaInfoCloseButton")
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var tabPicker: some View {
        Picker("Section", selection: $selectedTab) {
            ForEach(MediaInfoTab.allCases, id: \.self) { tab in
                if tab.isAvailable(for: session) {
                    Text(tab.title).tag(tab)
                }
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityHint("Choose which captured media details to inspect.")
    }

    @ViewBuilder
    private var tabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selectedTab != .avAsset {
                    provenanceSection(for: selectedTab)
                }
                if !sessionLabels.isEmpty {
                    sessionLabelsSection(sessionLabels)
                }
                manifestCorrelationSection
                if let cmcdReport = CMCDEngine.parse(
                    requestHeaders: session.request.headers,
                    responseHeaders: session.response?.headers ?? [],
                    urlString: MediaDetector.absoluteURL(for: session.request)?.absoluteString ?? session.request.path,
                    responseDurationSeconds: session.timing.duration,
                    sessionID: session.id
                ) {
                    CMCDTelemetryCardView(report: cmcdReport)
                }

                if let bodyData = session.response?.bodyData,
                   let text = String(data: bodyData, encoding: .utf8),
                   text.contains("WEBVTT") {
                    let isHls = session.request.path.contains(".vtt") || session.request.path.contains(".m3u8")
                    let vttReport = WebVTTEngine.parse(vttText: text, isHlsSegment: isHls)
                    WebVTTInspectorView(report: vttReport)
                }

                let drmReport = DRMAuditorEngine.audit(
                    manifestSessions: [session],
                    licenseSessions: sessions.filter {
                        let path = $0.request.path.lowercased()
                        return path.contains("license") || path.contains("fps") || path.contains("fairplay") || path.contains("widevine") || path.contains("getcertificate")
                    },
                    mediaSessions: [session]
                )
                if drmReport.keyInfo != nil || !drmReport.psshBoxes.isEmpty || !drmReport.licenseExchanges.isEmpty {
                    DRMHandshakeCardView(report: drmReport)
                }

                let byteRangeReport = ByteRangeAuditorEngine.audit(sessions: [session])
                if byteRangeReport.totalTransactions > 0 {
                    ByteRangeEfficiencyCardView(report: byteRangeReport)
                }

                switch selectedTab {
                case .image:
                    imageSection
                case .avAsset:
                    avAssetSection
                case .hls:
                    hlsSection
                case .dash:
                    dashSection
                case .waterfall:
                    waterfallSection
                case .adXml:
                    adXmlSection
                case .timedMetadata:
                    timedMetadataSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var waterfallSection: some View {
        let report = StreamingWaterfallEngine.analyze(target: session, allSessions: sessions)
        StreamingQualityWaterfallView(report: report)
    }

    @ViewBuilder
    private var imageSection: some View {
        if case .image = MediaDetector.mediaType(for: session),
           let bodyData = session.response?.bodyData,
           !bodyData.isEmpty {
            let contentType = session.response?.headers.first { $0.name.lowercased() == "content-type" }?.value
            VStack(alignment: .leading, spacing: 12) {
                ImageViewer(bodyData: bodyData, contentType: contentType,
                    sessionID: session.id, contentRevision: contentRevision)
                if let imageMetadata {
                    imageMetadataView(imageMetadata)
                }
            }
        } else {
            Text("No image in response")
                .foregroundStyle(.secondary)
        }
    }

    private func imageMetadataView(_ metadata: ImageMetadata) -> some View {
        GroupBox("Image Metadata") {
            VStack(alignment: .leading, spacing: 8) {
                if let error = metadata.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let width = metadata.pixelWidth, let height = metadata.pixelHeight {
                    metadataRow("Dimensions", value: "\(width) x \(height)")
                }
                if metadata.frameCount > 0 {
                    metadataRow("Frames", value: "\(metadata.frameCount)")
                }
                if metadata.isAnimated {
                    metadataRow("Animation", value: "Animated image")
                }
                if let container = metadata.preferredMIMEType ?? metadata.containerTypeIdentifier {
                    metadataRow("Container", value: container)
                }
                if let orientation = metadata.orientationDescription {
                    metadataRow("Orientation", value: orientation)
                }
                if let colorModel = metadata.colorModel {
                    metadataRow("Color Model", value: colorModel)
                }
                if let hasAlpha = metadata.hasAlpha {
                    metadataRow("Alpha", value: hasAlpha ? "Yes" : "No")
                }
                if let dpi = metadata.dpiDescription {
                    metadataRow("DPI", value: dpi)
                }
                if let exif = metadata.exifSummary {
                    if let make = exif.make { metadataRow("Camera Make", value: make) }
                    if let model = exif.model { metadataRow("Camera Model", value: model) }
                    if let lens = exif.lensModel { metadataRow("Lens", value: lens) }
                    if let capturedAt = exif.dateTimeOriginal {
                        metadataRow("Captured At", value: capturedAt)
                    }
                }
                if !metadata.auxiliaryDataTypes.isEmpty {
                    metadataRow("Auxiliary Data", value: metadata.auxiliaryDataTypes.joined(separator: ", "))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private var adXmlSection: some View {
        if case .adXml = MediaDetector.mediaType(for: session) {
            if adXmlLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Parsing ad XML…")
                        .mediaInfoFont(.body, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
            } else if let result = adXmlParseResult {
                adXmlSummaryView(result)
            } else {
                Text("No ad XML summary available")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No ad XML in response")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func adXmlSummaryView(_ result: AdXMLParseResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            deliveryHeaderSection

            metadataRow("Document Kind", value: result.kind.rawValue.uppercased())

            if let vast = result.vast {
                vastSummaryView(vast)
            } else if let vmap = result.vmap {
                vmapSummaryView(vmap)
            } else {
                Text("Captured XML did not match a supported VAST or VMAP summary shape.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func vastSummaryView(_ summary: VASTSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let version = summary.version {
                metadataRow("VAST Version", value: version)
            }
            metadataRow("Ads", value: "\(summary.ads.count)")
            metadataRow("Impression URLs", value: "\(summary.impressionURLCount)")
            metadataRow("Click Tracking URLs", value: "\(summary.clickTrackingURLCount)")
            if summary.maxWrapperDepth > 0 {
                metadataRow("Wrapper Depth", value: "\(summary.maxWrapperDepth)")
            }

            ForEach(summary.ads) { ad in
                GroupBox(ad.kind == .wrapper ? "Wrapper Ad" : "Inline Ad") {
                    VStack(alignment: .leading, spacing: 8) {
                        metadataRow("Ad ID", value: ad.id)
                        if let wrapperURL = ad.wrapperURLRedacted {
                            metadataRow("Wrapper URI", value: wrapperURL)
                        }
                        ForEach(ad.creatives) { creative in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(creative.adID ?? creative.id)
                                    .mediaInfoFont(.caption, scale: appTextScale, weight: .semibold)
                                if let duration = creative.durationSeconds {
                                    metadataRow("Duration", value: String(format: "%.1fs", duration))
                                }
                                metadataRow("Media Files", value: "\(creative.mediaFiles.count)")
                                metadataRow("Companions", value: "\(creative.companionCount)")
                                ForEach(creative.mediaFiles) { mediaFile in
                                    if let url = mediaFile.urlRedacted {
                                        metadataRow(mediaFile.mimeType ?? "Media", value: url)
                                    }
                                }
                                ForEach(creative.companions) { companion in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Companion: \(companion.dimensionString)")
                                            .mediaInfoFont(.caption2, scale: appTextScale, weight: .bold)
                                            .foregroundColor(.secondary)
                                        if let res = companion.resource {
                                            metadataRow("Resource", value: res.displayString)
                                        }
                                        if let click = companion.clickThroughURL {
                                            metadataRow("Click-Through", value: click)
                                        }
                                    }
                                    .padding(.top, 2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
        }
    }

    private func vmapSummaryView(_ summary: VMAPSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let version = summary.version {
                metadataRow("VMAP Version", value: version)
            }
            metadataRow("Ad Breaks", value: "\(summary.adBreaks.count)")

            ForEach(summary.adBreaks) { adBreak in
                GroupBox("Ad Break") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let timeOffset = adBreak.timeOffset {
                            metadataRow("Time Offset", value: timeOffset)
                        }
                        if let breakID = adBreak.breakID {
                            metadataRow("Break ID", value: breakID)
                        }
                        if let breakType = adBreak.breakType {
                            metadataRow("Break Type", value: breakType)
                        }
                        if let sourceURI = adBreak.adSourceURI {
                            metadataRow("Ad Source", value: sourceURI)
                        }
                        metadataRow("Nested VAST Ads", value: "\(adBreak.vastAdCount)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
        }
    }

    @ViewBuilder
    private var timedMetadataSection: some View {
        let context = timedMetadataAnalysisContext
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("ID3 Timed Metadata") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("JoesProxy can inspect this captured media item for ID3 timed metadata without replaying the stream.")
                        .mediaInfoFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)

                    metadataRow("Trigger", value: context.trigger.rawValue)

                    if context.isAnalysisAvailable {
                        Label("Timed metadata analysis available", systemImage: "checkmark.circle")
                            .mediaInfoFont(.caption, scale: appTextScale)
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("mediaInfoID3AnalysisAvailable")
                        metadataRow("Captured Item", value: "Selected response body")
                        metadataRow("Parse Mode", value: "Frame headers and payload summaries")
                        Button {
                            analyzeTimedMetadata(context: context)
                        } label: {
                            Label("Analyze Selected Item", systemImage: "tag")
                        }
                        .disabled(timedMetadataLoading)
                        .accessibilityIdentifier("mediaInfoAnalyzeID3Button")
                    } else {
                        Label(
                            "The selected item has no captured media body available for ID3 analysis.",
                            systemImage: "info.circle"
                        )
                        .mediaInfoFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                    }

                    ForEach(context.notes, id: \.self) { note in
                        Text(note)
                            .mediaInfoFont(.caption2, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            if timedMetadataLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing ID3 markers…")
                        .mediaInfoFont(.body, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
            } else if !timedMetadataResults.isEmpty {
                timedMetadataResultsView(timedMetadataResults, context: context)
            }
        }
    }

    private func timedMetadataResultsView(
        _ results: [TimedMetadataDetectionResult],
        context: TimedMetadataAnalysisContext
    ) -> some View {
        let markerCount = results.reduce(0) { $0 + $1.markers.count }
        return VStack(alignment: .leading, spacing: 12) {
            GroupBox("Analysis Summary") {
                VStack(alignment: .leading, spacing: 8) {
                    metadataRow("Items Analyzed", value: "\(results.count)")
                    metadataRow("ID3 Markers Found", value: "\(markerCount)")
                    metadataRow("Source", value: TimedMetadataAnalysisSource.proxySegmentParser.rawValue)
                    metadataRow("Parse Mode", value: "Frame headers and payload summaries")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            ForEach(results) { result in
                timedMetadataResultView(result)
            }
        }
    }

    private func timedMetadataResultView(_ result: TimedMetadataDetectionResult) -> some View {
        GroupBox(result.assetURL?.lastPathComponent ?? "Captured Segment") {
            VStack(alignment: .leading, spacing: 8) {
                metadataRow("Container", value: result.containerType.rawValue)
                metadataRow("Markers", value: "\(result.markers.count)")
                MediaParserDiagnosticsView(diagnostics: result.diagnostics, textScale: appTextScale)

                if !result.analysisWarnings.isEmpty {
                    ForEach(result.analysisWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .mediaInfoFont(.caption, scale: appTextScale)
                            .foregroundStyle(.orange)
                    }
                }

                ForEach(result.markers) { marker in
                    VStack(alignment: .leading, spacing: 4) {
                        let sequenceText = marker.segmentSequence.map { "#\($0 + 1)" } ?? "Unknown segment"
                        Text(sequenceText)
                            .mediaInfoFont(.caption, scale: appTextScale, weight: .semibold)
                        if let relativePlaybackTime = marker.relativePlaybackTime {
                            metadataRow("Playback Time", value: formatDuration(relativePlaybackTime))
                        }
                        if let byteOffset = marker.byteOffset {
                            metadataRow("Byte Offset", value: "\(byteOffset)")
                        }
                        if !marker.frameIdentifiers.isEmpty {
                            metadataRow("Frames", value: marker.frameIdentifiers.joined(separator: ", "))
                        }
                        if let payloadSummary = marker.payloadSummary {
                            metadataRow("Payload", value: payloadSummary)
                        }
                        metadataRow("Decode", value: marker.payloadDecodeStatus.rawValue)
                        if marker.payloadRedacted {
                            Text("Private payload details are redacted by default.")
                                .mediaInfoFont(.caption2, scale: appTextScale)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private var avAssetSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let structure = capturedBinaryStructure {
                capturedStructureView(structure)
            } else if capturedBinaryStructureLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Analyzing captured segment…")
                        .mediaInfoFont(.body, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }

            MediaInfoAVInspectionView(session: session, textScale: appTextScale, contentRevision: contentRevision)
                .id(session.id)
        }
    }

    @ViewBuilder
    private var hlsSection: some View {
        let mediaType = MediaDetector.mediaType(for: session)

        if mediaType == .hls,
           let response = session.response,
           let bodyData = MediaDetector.decodedResponseBody(for: response),
           let manifest = String(data: bodyData, encoding: .utf8) {
            let baseURL = MediaDetector.absoluteURL(for: session.request)
            let parsed = HLSParser.parse(manifest, baseURL: baseURL)
            hlsMetadataView(parsed)
        } else if mediaType == .hlsDiscovery,
                  let discovery = MediaDetector.hlsDiscovery(for: session) {
            hlsDiscoveryView(discovery)
        } else {
            Text("No HLS manifest in response")
                .foregroundStyle(.secondary)
        }
    }

    private func hlsMetadataView(_ manifest: HLSManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let classifications = hlsClassifications(for: manifest)

            classificationSection(classifications)
            deliveryHeaderSection

            if let v = manifest.version {
                metadataRow("Version", value: "\(v)")
            }
            metadataRow("Type", value: manifest.isMasterPlaylist ? "Master" : "Media")
            if let td = manifest.targetDuration {
                metadataRow("Target Duration", value: "\(td)s")
            }
            if manifest.segmentCount > 0 {
                metadataRow("Segments", value: "\(manifest.segmentCount)")
            }
            if let initializationSegmentURI = manifest.initializationSegmentURI {
                metadataRow("Init Segment", value: initializationSegmentURI)
            }
            if !manifest.referencedHosts.isEmpty {
                metadataRow("Origins", value: manifest.referencedHosts.joined(separator: ", "))
            }
            if !manifest.videoRanges.isEmpty {
                metadataRow("Video Range", value: manifest.videoRanges.joined(separator: ", "))
            }
            if !manifest.hdcpLevels.isEmpty {
                metadataRow("HDCP Levels", value: manifest.hdcpLevels.joined(separator: ", "))
            }
            if let programDateTimeSummary = hlsProgramDateTimeSummary(for: manifest) {
                metadataRow("Program Date-Time", value: programDateTimeSummary)
            }
            if let steering = manifest.contentSteering {
                GroupBox("Content Steering") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let serverURI = steering.serverURI {
                            metadataRow("Server URI", value: serverURI)
                        }
                        if let pathwayID = steering.pathwayID {
                            metadataRow("Pathway ID", value: pathwayID)
                        }
                        if let reloadURI = steering.reloadURI {
                            metadataRow("Reload URI", value: reloadURI)
                        }
                        Text("Steering JSON is not fetched automatically. Copy the server URI if you need to inspect it separately.")
                            .mediaInfoFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            if !manifest.vendorDateRangeAttributes.isEmpty {
                GroupBox("DATERANGE Vendor Attributes") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(manifest.vendorDateRangeAttributes.keys.sorted(), id: \.self) { key in
                            if let values = manifest.vendorDateRangeAttributes[key] {
                                metadataRow(key, value: values.joined(separator: " • "))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            if !manifest.variants.isEmpty || !manifest.adMarkers.isEmpty {
                let alignmentReport = DiscontinuityAlignmentEngine.auditMultiRendition(
                    masterManifest: manifest,
                    masterURI: session.request.path,
                    variantManifests: [:]
                )
                DiscontinuityAlignmentCardView(report: alignmentReport)
            }

            if !manifest.variants.isEmpty {
                GroupBox("Variants") {
                    ForEach(Array(manifest.variants.enumerated()), id: \.offset) { _, v in
                        VStack(alignment: .leading, spacing: 4) {
                            if let res = v.resolution {
                                Text(res)
                                    .mediaInfoFont(.body, scale: appTextScale, design: .monospaced)
                            }
                            if let bw = v.bandwidth {
                                Text("Peak bandwidth: \(formattedBitrate(bw))")
                                    .mediaInfoFont(.caption, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            }
                            if let averageBandwidth = v.averageBandwidth {
                                Text("Average bandwidth: \(formattedBitrate(averageBandwidth))")
                                    .mediaInfoFont(.caption, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            }
                            if let frameRate = v.frameRate {
                                Text("Frame rate: \(frameRate.formatted(.number.precision(.fractionLength(2)))) fps")
                                    .mediaInfoFont(.caption, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            }
                            if let codecs = v.codecs {
                                Text("Codecs: \(codecs)")
                                    .mediaInfoFont(.caption, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            }
                            if let videoRange = v.videoRange {
                                Text("Video range: \(videoRange)")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            }
                            if let hdcpLevel = v.hdcpLevel {
                                Text("HDCP level: \(hdcpLevel)")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            }
                            if let name = v.name {
                                Text(name)
                                    .mediaInfoFont(.caption, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            }
                            if let audioGroupID = v.audioGroupID {
                                Text("Audio group: \(audioGroupID)")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                            if let subtitlesGroupID = v.subtitlesGroupID {
                                Text("Subtitles group: \(subtitlesGroupID)")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(v.uri)
                                .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
            }
            if !manifest.mediaGroups.isEmpty {
                GroupBox("Tracks") {
                    ForEach(Array(manifest.mediaGroups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(group.type)
                                    .mediaInfoFont(.body, scale: appTextScale, design: .monospaced)
                                if let name = group.name {
                                    Text(name)
                                        .mediaInfoFont(.caption, scale: appTextScale)
                                        .foregroundStyle(.secondary)
                                }
                                if let language = group.language {
                                    Text(language)
                                        .mediaInfoFont(.caption, scale: appTextScale)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            let flags = [
                                group.isDefault ? "default" : nil,
                                group.autoSelect ? "autoselect" : nil,
                                group.isForced ? "forced" : nil
                            ]
                            .compactMap { $0 }
                            .joined(separator: ", ")
                            if !flags.isEmpty {
                                Text(flags)
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                            if let groupID = group.groupID {
                                Text("Group ID: \(groupID)")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                            if let associatedLanguage = group.associatedLanguage {
                                Text("Associated language: \(associatedLanguage)")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                            if let channels = group.channels {
                                Text("Channels: \(channels)")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                            if !group.characteristics.isEmpty {
                                Text("Characteristics: \(group.characteristics.joined(separator: ", "))")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                            if let uri = group.uri {
                                Text(uri)
                                    .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
            }
            if !manifest.keys.isEmpty {
                GroupBox("DRM / Keys") {
                    ForEach(Array(manifest.keys.enumerated()), id: \.offset) { _, k in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Method: \(k.method)")
                                .mediaInfoFont(.body, scale: appTextScale, design: .monospaced)
                            if let uri = k.uri {
                                Text(uri)
                                    .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
            }
            if !manifest.adBreaks.isEmpty {
                GroupBox("Ad Break Timeline") {
                    ForEach(Array(manifest.adBreaks.enumerated()), id: \.offset) { _, adBreak in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(adBreak.cueType)
                                    .mediaInfoFont(.body, scale: appTextScale, design: .monospaced)
                                Text("Start \(formatDuration(adBreak.startTime))")
                                    .mediaInfoFont(.caption, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                                if let duration = adBreak.duration {
                                    Text("Duration \(formatDuration(duration))")
                                        .mediaInfoFont(.caption, scale: appTextScale)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let endTime = adBreak.endTime {
                                Text("Ends at \(formatDuration(endTime))")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                            if let id = adBreak.id {
                                Text("ID: \(id)")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
            }
            if !manifest.adMarkers.isEmpty {
                GroupBox("Ad Markers") {
                    ForEach(Array(manifest.adMarkers.enumerated()), id: \.offset) { _, m in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(m.type)
                                    .mediaInfoFont(.body, scale: appTextScale, design: .monospaced)
                                if let startTime = m.startTime {
                                    Text(formatDuration(startTime))
                                        .mediaInfoFont(.caption, scale: appTextScale)
                                }
                                if let duration = m.duration ?? m.plannedDuration {
                                    Text(formatDuration(duration))
                                        .mediaInfoFont(.caption, scale: appTextScale)
                                }
                                if let id = m.id {
                                    Text(id)
                                        .mediaInfoFont(.caption, scale: appTextScale)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let assetValue = m.assetValue {
                                Text("Asset: \(assetValue)")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            }
                            if let scte35Out = m.scte35Out {
                                Text("SCTE-35 OUT: \(scte35Out)")
                                    .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if let scte35In = m.scte35In {
                                Text("SCTE-35 IN: \(scte35In)")
                                    .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
            }
            if !manifest.segments.isEmpty {
                GroupBox("Segments") {
                    ForEach(Array(manifest.segments.prefix(12).enumerated()), id: \.offset) { index, segment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("#\(index + 1)")
                                    .mediaInfoFont(.body, scale: appTextScale, design: .monospaced)
                                if let startTime = segment.startTime {
                                    Text(formatDuration(startTime))
                                        .mediaInfoFont(.caption, scale: appTextScale)
                                        .foregroundStyle(.secondary)
                                }
                                if let duration = segment.duration {
                                    Text(formatDuration(duration))
                                        .mediaInfoFont(.caption, scale: appTextScale)
                                        .foregroundStyle(.secondary)
                                }
                                if segment.isAdSegment {
                                    Text("Ad")
                                        .mediaInfoFont(.caption, scale: appTextScale)
                                        .foregroundStyle(.orange)
                                }
                            }
                            if let programDateTime = segment.programDateTime {
                                Text(programDateTime)
                                    .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
                                    .foregroundStyle(.secondary)
                            }
                            if let host = segment.host {
                                Text(host)
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                            if let byteRange = segment.byteRange {
                                Text("Byte range: \(byteRange)")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(segment.uri)
                                .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    if manifest.segments.count > 12 {
                        Text("Showing first 12 of \(manifest.segments.count) segments")
                            .mediaInfoFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    private func hlsDiscoveryView(_ discovery: HLSStreamDiscovery) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            classificationSection(hlsDiscoveryClassifications(for: discovery))

            GroupBox("Manifest Discovered From Playback API") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This response exposed the stream manifest URL even though the manifest request itself was not captured in this session.")
                        .mediaInfoFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)

                    metadataRow("Manifest Host", value: discovery.manifestURL.host ?? "Unknown")
                    metadataRow("Manifest URL", value: discovery.manifestURL.absoluteString)

                    if let manifestFormat = discovery.manifestFormat {
                        metadataRow("Format", value: manifestFormat)
                    }

                    if let contentID = discovery.contentID {
                        metadataRow("Content ID", value: contentID)
                    }

                    if let daiCMSID = discovery.daiCMSID {
                        metadataRow("DAI CMS ID", value: daiCMSID)
                    }

                    if let drmLicenseURL = discovery.drmLicenseURL {
                        metadataRow("DRM License", value: drmLicenseURL.absoluteString)
                    }

                    if let timeEventsURL = discovery.timeEventsURL {
                        metadataRow("Time Events", value: timeEventsURL.absoluteString)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var dashSection: some View {
        if case .dash = MediaDetector.mediaType(for: session),
           let bodyData = session.response?.bodyData,
           let xml = String(data: bodyData, encoding: .utf8),
           let parsed = DASHParser.parse(xml) {
            dashMetadataView(parsed)
        } else {
            Text("No DASH manifest in response")
                .foregroundStyle(.secondary)
        }
    }

    private func dashMetadataView(_ manifest: DASHManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            dashOverviewSection(manifest)
            deliveryHeaderSection

            if let t = manifest.type {
                metadataRow("Type", value: t)
            }
            if let dur = manifest.mediaPresentationDuration {
                metadataRow("Duration", value: dur)
            }
            if let baseURL = manifest.baseURL {
                metadataRow("Manifest Base URL", value: baseURL)
            }
            if !manifest.contentProtection.isEmpty {
                GroupBox("Content Protection") {
                    ForEach(Array(manifest.contentProtection.enumerated()), id: \.offset) { i, cp in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cp.schemeIdUri)
                                .mediaInfoFont(.caption, scale: appTextScale, design: .monospaced)
                            if let v = cp.value {
                                Text(v)
                                    .mediaInfoFont(.caption, scale: appTextScale)
                                    .foregroundStyle(.secondary)
                            }
                            if let kid = cp.defaultKid {
                                Text("KID: \(kid)")
                                    .mediaInfoFont(.caption2, scale: appTextScale)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
            }
            ForEach(Array(manifest.periods.enumerated()), id: \.offset) { pi, period in
                GroupBox("Period \(pi + 1)") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let start = period.start {
                            metadataRow("Start", value: start)
                        }
                        if let duration = period.duration {
                            metadataRow("Duration", value: duration)
                        }
                        if let baseURL = period.baseURL {
                            metadataRow("Base URL", value: baseURL)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                    ForEach(Array(period.adaptationSets.enumerated()), id: \.offset) { ai, aset in
                        VStack(alignment: .leading, spacing: 8) {
                            adaptationSetSummary(index: ai, adaptationSet: aset)
                            if let template = aset.segmentTemplate {
                                dashTemplateSummary(template, title: "Adaptation Template")
                            }
                            ForEach(Array(aset.representations.enumerated()), id: \.offset) { _, rep in
                                representationSummary(
                                    representation: rep,
                                    adaptationSet: aset
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
            }
        }
    }

    private func dashTemplateSummary(_ template: DASHSegmentTemplate, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .mediaInfoFont(.caption2, scale: appTextScale)
                .foregroundStyle(.secondary)
            if let initialization = template.initialization {
                Text("init: \(initialization)")
                    .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
            }
            if let media = template.media {
                Text("media: \(media)")
                    .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
            }
            HStack(spacing: 10) {
                if let startNumber = template.startNumber {
                    Text("start: \(startNumber)")
                }
                if let timescale = template.timescale {
                    Text("timescale: \(timescale)")
                }
                if let duration = template.duration {
                    Text("duration: \(duration)")
                }
            }
            .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func dashOverviewSection(_ manifest: DASHManifest) -> some View {
        let periodCount = manifest.periods.count
        let adaptationCount = manifest.periods.reduce(0) { $0 + $1.adaptationSets.count }
        let representationCount = manifest.periods.reduce(0) { partialResult, period in
            partialResult + period.adaptationSets.reduce(0) { $0 + $1.representations.count }
        }

        return GroupBox("Streaming Layout") {
            HStack(spacing: 16) {
                dashOverviewMetric(title: "Periods", value: "\(periodCount)")
                dashOverviewMetric(title: "Adaptation Sets", value: "\(adaptationCount)")
                dashOverviewMetric(title: "Representations", value: "\(representationCount)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func dashOverviewMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .mediaInfoFont(.caption2, scale: appTextScale)
                .foregroundStyle(.secondary)
            Text(value)
                .mediaInfoFont(.body, scale: appTextScale, weight: .semibold, design: .monospaced)
        }
    }

    private func adaptationSetSummary(index: Int, adaptationSet: DASHAdaptationSet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(adaptationSetTitle(index: index, adaptationSet: adaptationSet))
                .mediaInfoFont(.caption, scale: appTextScale, weight: .semibold)

            let detailLine = adaptationSetDetailLine(adaptationSet)
            if !detailLine.isEmpty {
                Text(detailLine)
                    .mediaInfoFont(.caption2, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }

            if let baseURL = adaptationSet.baseURL {
                metadataRow("Base URL", value: baseURL)
            }

            if !adaptationSet.roles.isEmpty {
                descriptorSummaryRow("Roles", descriptors: adaptationSet.roles)
            }

            if !adaptationSet.accessibility.isEmpty {
                descriptorSummaryRow("Accessibility", descriptors: adaptationSet.accessibility)
            }

            if !adaptationSet.audioChannelConfigurations.isEmpty {
                audioChannelSummaryRow(adaptationSet.audioChannelConfigurations)
            }

            if !adaptationSet.eventStreams.isEmpty {
                eventStreamSummaryRow(adaptationSet.eventStreams)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func representationSummary(
        representation: DASHRepresentation,
        adaptationSet: DASHAdaptationSet
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(representation.id ?? "Unnamed Representation")
                    .mediaInfoFont(.caption, scale: appTextScale, weight: .semibold)

                if let bw = representation.bandwidth {
                    Text("\(bw) bps")
                        .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.secondary)
                }

                if let dimensions = representationDimensions(representation) {
                    Text(dimensions)
                        .mediaInfoFont(.caption2, scale: appTextScale, design: .monospaced)
                        .foregroundStyle(.secondary)
                }
            }

            let detailLine = representationDetailLine(representation, adaptationSet: adaptationSet)
            if !detailLine.isEmpty {
                Text(detailLine)
                    .mediaInfoFont(.caption2, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }

            if let baseURL = representation.baseURL ?? adaptationSet.baseURL {
                metadataRow("Effective Base URL", value: baseURL)
            }

            if let template = representation.segmentTemplate ?? adaptationSet.segmentTemplate {
                dashTemplateSummary(
                    template,
                    title: representation.segmentTemplate != nil ? "Representation Template" : "Inherited Adaptation Template"
                )
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func adaptationSetTitle(index: Int, adaptationSet: DASHAdaptationSet) -> String {
        let primary = adaptationSet.contentType ?? adaptationSet.mimeType ?? "Adaptation Set \(index + 1)"
        if let id = adaptationSet.id {
            return "\(primary) (\(id))"
        }
        return primary
    }

    private func adaptationSetDetailLine(_ adaptationSet: DASHAdaptationSet) -> String {
        [
            adaptationSet.lang.map { "lang \($0)" },
            adaptationSet.mimeType,
            adaptationSet.codecs
        ]
        .compactMap { $0 }
        .joined(separator: " • ")
    }

    private func representationDetailLine(
        _ representation: DASHRepresentation,
        adaptationSet: DASHAdaptationSet
    ) -> String {
        [
            representation.mimeType ?? adaptationSet.mimeType,
            representation.codecs ?? adaptationSet.codecs,
            representation.frameRate.map { "fps \($0)" },
            representation.audioSamplingRate.map { "audio \($0) Hz" }
        ]
        .compactMap { $0 }
        .joined(separator: " • ")
    }

    private func representationDimensions(_ representation: DASHRepresentation) -> String? {
        guard let width = representation.width, let height = representation.height else {
            return nil
        }
        return "\(width)x\(height)"
    }

    private func hlsProgramDateTimeSummary(for manifest: HLSManifest) -> String? {
        guard let first = manifest.programDateTimes.first else {
            return nil
        }
        guard let last = manifest.programDateTimes.last, manifest.programDateTimes.count > 1 else {
            return first
        }
        return "\(first) → \(last) (\(manifest.programDateTimes.count) tags)"
    }

    @ViewBuilder
    private var deliveryHeaderSection: some View {
        if let summary = deliveryHeaderSummary {
            GroupBox("Delivery Context") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Captured response headers only")
                        .mediaInfoFont(.caption2, scale: appTextScale)
                        .foregroundStyle(.secondary)

                    ForEach(Array(summary.items.enumerated()), id: \.offset) { _, item in
                        metadataRow(item.name, value: item.value)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    private func descriptorSummaryRow(_ label: String, descriptors: [DASHDescriptor]) -> some View {
        metadataRow(label, value: descriptors.map(descriptorSummary).joined(separator: " • "))
    }

    private func audioChannelSummaryRow(_ configs: [DASHAudioChannelConfiguration]) -> some View {
        metadataRow(
            "Audio Channels",
            value: configs.map {
                [$0.value, $0.schemeIdUri].compactMap { $0 }.joined(separator: " ")
            }
            .joined(separator: " • ")
        )
    }

    private func eventStreamSummaryRow(_ eventStreams: [DASHEventStream]) -> some View {
        metadataRow(
            "Event Streams",
            value: eventStreams.map { stream in
                var parts: [String] = []
                if let schemeIdUri = stream.schemeIdUri {
                    parts.append(schemeIdUri)
                }
                if let value = stream.value {
                    parts.append(value)
                }
                if let timescale = stream.timescale {
                    parts.append("timescale \(timescale)")
                }
                return parts.joined(separator: " ")
            }
            .joined(separator: " • ")
        )
    }

    private func descriptorSummary(_ descriptor: DASHDescriptor) -> String {
        [descriptor.value, descriptor.schemeIdUri]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .mediaInfoFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .mediaInfoFont(.body, scale: appTextScale, design: .monospaced)
        }
    }

    @ViewBuilder
    private func provenanceSection(for tab: MediaInfoTab) -> some View {
        let provenance = provenanceForTab(tab)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: provenance == .capturedResponse ? "externaldrive.fill.badge.checkmark" : "bolt.horizontal.circle")
                .foregroundStyle(provenance == .capturedResponse ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(provenance.title)
                    .mediaInfoFont(.caption, scale: appTextScale, weight: .semibold)
                Text(provenance.summary)
                    .mediaInfoFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func provenanceForTab(_ tab: MediaInfoTab) -> MediaInspectionProvenance {
        switch tab {
        case .avAsset:
            return .liveSystemProbe
        case .image, .hls, .dash, .waterfall, .adXml, .timedMetadata:
            return .capturedResponse
        }
    }

    private var imageMetadataTaskID: String {
        "image-\(session.id)-\(contentRevision)-\(selectedTab)-\(inspectionRetry)"
    }

    private var adXmlTaskID: String {
        "adxml-\(session.id)-\(contentRevision)-\(selectedTab)-\(inspectionRetry)"
    }

    private func loadImageMetadataIfNeeded() async {
        guard let bodyData = session.response?.bodyData,
              !bodyData.isEmpty else {
            return
        }

        let data = bodyData
        let metadata = await MediaInspectionWorkBudget.shared.run {
            ImageMetadataService().loadMetadata(from: data)
        }
        guard !Task.isCancelled else { return }
        guard let metadata else { inspectionCapacityUnavailable = true; return }
        imageMetadata = metadata
    }

    private func loadAdXmlIfNeeded() async {
        guard let response = session.response else {
            return
        }

        adXmlLoading = true
        let capturedSession = session
        let result = await MediaInspectionWorkBudget.shared.run { () -> AdXMLParseResult? in
            guard case .adXml(let capturedKind) = MediaDetector.mediaType(for: capturedSession),
                  let bodyData = MediaDetector.decodedResponseBody(for: response),
                  let xml = String(data: bodyData, encoding: .utf8) else { return nil }
            return AdXMLParser.parse(xml: xml, kind: capturedKind)
        }
        guard !Task.isCancelled else { return }
        guard let result else { adXmlLoading = false; inspectionCapacityUnavailable = true; return }
        adXmlParseResult = result
        adXmlLoading = false
    }

    private var binaryStructureTaskID: String {
        "binary-\(session.id)-\(contentRevision)-\(selectedTab)-\(inspectionRetry)"
    }

    private func loadCapturedBinaryStructure() async {
        capturedBinaryStructure = nil
        guard let response = session.response else {
            capturedBinaryStructureLoading = false
            return
        }

        capturedBinaryStructureLoading = true
        let capturedSession = session
        let structure = await MediaInspectionWorkBudget.shared.run { () -> BinaryMediaStructure? in
            guard case .video = MediaDetector.mediaType(for: capturedSession),
                  let bodyData = MediaDetector.decodedResponseBody(for: response) else { return nil }
            return BinaryMediaStructureProbe().inspect(data: bodyData)
        }
        guard !Task.isCancelled else { return }
        guard let structure else { capturedBinaryStructureLoading = false; inspectionCapacityUnavailable = true; return }
        capturedBinaryStructure = structure
        capturedBinaryStructureLoading = false
    }

    private func loadTransportVideoAnalysis() async {
        guard capturedBinaryStructure?.kind == .mpegTransportStream,
              let response = session.response else {
            transportVideoAnalysisAttempted = true
            return
        }

        transportVideoAnalysisLoading = true
        transportVideoAnalysisAttempted = false
        let result = await MediaInspectionWorkBudget.shared.run { () -> MPEGTransportStreamVideoAnalysisResult? in
            guard let bodyData = MediaDetector.decodedResponseBody(for: response) else { return nil }
            return MPEGTransportStreamVideoAnalyzer().analyzeWithDiagnostics(data: bodyData)
        }
        guard !Task.isCancelled else { return }
        transportVideoAnalysisLoading = false
        guard let result else { inspectionCapacityUnavailable = true; return }
        guard let result else { transportVideoAnalysisAttempted = true; return }
        transportVideoAnalysis = result.analysis
        transportVideoDiagnostics = result.diagnostics
        transportVideoAnalysisLoading = false
        transportVideoAnalysisAttempted = true
        mediaParserLogger.info("\(result.diagnostics.logMessage, privacy: .public)")
    }

    private var sessionLabels: [MediaSessionLabel] {
        MediaSessionContextResolver.labels(
            for: session,
            structure: capturedBinaryStructure,
            hlsManifestCorrelation: hlsManifestCorrelation,
            dashManifestCorrelation: dashManifestCorrelation,
            timedMetadataContext: timedMetadataAnalysisContext
        )
    }

    private var hlsManifestCorrelation: HLSManifestCorrelation? {
        HLSManifestCorrelationResolver.correlate(session: session, within: parsedHLSManifestSessions)
    }

    private var dashManifestCorrelation: DASHManifestCorrelation? {
        DASHManifestCorrelationResolver.correlate(session: session, within: parsedDASHManifestSessions)
    }

    private var deliveryHeaderSummary: MediaDeliveryHeaderSummary? {
        MediaDeliveryHeaderSummary.from(
            response: session.response,
            mediaType: MediaDetector.mediaType(for: session),
            structure: capturedBinaryStructure
        )
    }

    private var timedMetadataAnalysisContext: TimedMetadataAnalysisContext {
        TimedMetadataCandidateResolver.selectedItemContext(
            for: session,
            parsedHLSManifestSessions: parsedHLSManifestSessions,
            sessions: sessions
        )
    }

    private func analyzeTimedMetadata(context: TimedMetadataAnalysisContext) {
        guard context.isAnalysisAvailable, !timedMetadataLoading else {
            return
        }

        timedMetadataLoading = true
        timedMetadataResults = []

        let candidates = context.candidates
        let capturedSessions = TimedMetadataCandidateResolver.capturedSessions(for: candidates, in: sessions)
        let parser = timedMetadataParser
        let loading = $timedMetadataLoading
        let output = $timedMetadataResults
        let capacityUnavailable = $inspectionCapacityUnavailable
        let logger = mediaParserLogger

        timedMetadataTask?.cancel()
        timedMetadataTask = Task { @MainActor in
            let results = await MediaInspectionWorkBudget.shared.run {
                TimedMetadataCandidateResolver.analyze(
                    candidates: candidates,
                    sessions: capturedSessions,
                    parser: parser,
                    shouldCancel: { Task.isCancelled }
                )
            }
            guard !Task.isCancelled else { return }
            guard let results else {
                loading.wrappedValue = false
                capacityUnavailable.wrappedValue = true
                return
            }

            output.wrappedValue = results
            loading.wrappedValue = false
            for result in results {
                logger.info("\(result.diagnostics.logMessage, privacy: .public)")
            }
        }
    }

    private func sessionLabelsSection(_ labels: [MediaSessionLabel]) -> some View {
        GroupBox("Session Labels") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(labels) { label in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label.title)
                            .mediaInfoFont(.caption, scale: appTextScale, weight: .semibold)
                        Text(label.summary)
                            .mediaInfoFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func capturedStructureView(_ structure: BinaryMediaStructure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Captured Structure") {
                VStack(alignment: .leading, spacing: 8) {
                    metadataRow("Format", value: structure.kind.rawValue)
                    metadataRow("Role", value: structure.role.rawValue)
                    metadataRow("Bytes Inspected", value: "\(structure.bytesInspected)")

                    if let tsPacketSize = structure.tsPacketSize {
                        metadataRow("TS Packet Size", value: "\(tsPacketSize)")
                    }

                    if let tsSyncPacketCount = structure.tsSyncPacketCount {
                        metadataRow("TS Sync Packets", value: "\(tsSyncPacketCount)")
                    }

                    if !structure.tsProgramNumbers.isEmpty {
                        metadataRow("TS Programs", value: structure.tsProgramNumbers.map(String.init).joined(separator: ", "))
                    }

                    if !structure.tsStreamTypeCodes.isEmpty {
                        metadataRow(
                            "TS Stream Types",
                            value: structure.tsStreamTypeCodes
                                .map { String(format: "0x%02X", $0) }
                                .joined(separator: ", ")
                        )
                    }

                    if structure.tsPacketSize != nil {
                        metadataRow("SCTE-35 PID", value: structure.scte35PIDPresent ? "Present" : "Not detected")
                    }

                    if structure.kind == .mpegTransportStream {
                        Divider()
                        MediaInfoTransportVideoAnalysisView(
                            analysis: transportVideoAnalysis,
                            diagnostics: transportVideoDiagnostics,
                            isLoading: transportVideoAnalysisLoading,
                            analysisAttempted: transportVideoAnalysisAttempted,
                            textScale: appTextScale,
                            requestAnalysis: { transportVideoAnalysisRequestID += 1 }
                        )
                    }

                    if structure.kind == .isoBMFF {
                        metadataRow("Fragmented", value: structure.likelyFragmented ? "Likely" : "No strong signal")
                        metadataRow("DRM Metadata", value: structure.likelyEncrypted ? "\(structure.psshCount) top-level pssh box(es)" : "No top-level pssh detected")
                        metadataRow("Segment Index", value: structure.segmentIndexPresent ? "sidx present" : "Not detected")
                        metadataRow("Event Messages", value: structure.eventMessages.isEmpty ? (structure.eventMessagePresent ? "emsg present" : "Not detected") : "\(structure.eventMessages.count) parsed")
                    }

                    if !structure.eventMessages.isEmpty {
                        GroupBox("Parsed Event Messages") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(structure.eventMessages.enumerated()), id: \.offset) { index, event in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Event \(index + 1)")
                                            .mediaInfoFont(.caption, scale: appTextScale, weight: .semibold)
                                        if let schemeIDURI = event.schemeIDURI {
                                            metadataRow("Scheme", value: schemeIDURI)
                                        }
                                        if let value = event.value, !value.isEmpty {
                                            metadataRow("Value", value: value)
                                        }
                                        if let timescale = event.timescale {
                                            metadataRow("Timescale", value: "\(timescale)")
                                        }
                                        if let eventDuration = event.eventDuration {
                                            metadataRow("Duration", value: "\(eventDuration)")
                                        }
                                        if let eventID = event.eventID {
                                            metadataRow("Event ID", value: "\(eventID)")
                                        }
                                    }
                                    .padding(8)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                    }

                    if !structure.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notes")
                                .mediaInfoFont(.caption, scale: appTextScale)
                                .foregroundStyle(.secondary)
                            ForEach(structure.notes, id: \.self) { note in
                                Text(note)
                                    .mediaInfoFont(.caption, scale: appTextScale)
                            }
                        }
                    }

                    if !structure.topLevelBoxes.isEmpty {
                        GroupBox("Top-Level Boxes") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(structure.topLevelBoxes.enumerated()), id: \.offset) { _, box in
                                    HStack(spacing: 10) {
                                        Text(box.type)
                                            .mediaInfoFont(.body, scale: appTextScale, design: .monospaced)
                                        Text("\(box.size) bytes")
                                            .mediaInfoFont(.caption, scale: appTextScale)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var manifestCorrelationSection: some View {
        if hlsManifestCorrelation != nil || dashManifestCorrelation != nil {
            GroupBox("Manifest Correlation") {
                VStack(alignment: .leading, spacing: 10) {
                    if let hlsManifestCorrelation {
                        manifestCorrelationDetails(
                            manifestKind: "HLS",
                            correlation: hlsManifestCorrelation
                        )
                    }

                    if let dashManifestCorrelation {
                        manifestCorrelationDetails(
                            manifestKind: "DASH",
                            correlation: dashManifestCorrelation
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    private func manifestCorrelationDetails(
        manifestKind: String,
        correlation: HLSManifestCorrelation
    ) -> some View {
        manifestCorrelationDetails(
            manifestKind: manifestKind,
            referenceKind: correlation.referenceKind,
            matches: correlation.matches
        )
    }

    private func manifestCorrelationDetails(
        manifestKind: String,
        correlation: DASHManifestCorrelation
    ) -> some View {
        manifestCorrelationDetails(
            manifestKind: manifestKind,
            referenceKind: correlation.referenceKind,
            matches: correlation.matches
        )
    }

    private func manifestCorrelationDetails(
        manifestKind: String,
        referenceKind: MediaManifestReferenceKind,
        matches: [ManifestReferenceMatch]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(manifestKind) • \(referenceKind.rawValue)")
                .mediaInfoFont(.caption, scale: appTextScale, weight: .semibold)
            ForEach(Array(matches.enumerated()), id: \.offset) { _, match in
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.manifestPath)
                        .mediaInfoFont(.caption, scale: appTextScale, design: .monospaced)
                    Text("Matched \(match.matchedReference) via \(match.strategy.rawValue)")
                        .mediaInfoFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(manifestKind) manifest \(match.manifestPath)")
                .accessibilityValue("Matched \(match.matchedReference) via \(match.strategy.rawValue)")
            }
        }
    }

    @ViewBuilder
    private func classificationSection(_ classifications: [HLSClassification]) -> some View {
        if !classifications.isEmpty {
            GroupBox("Classification") {
                FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(classifications) { classification in
                        Label(classification.title, systemImage: classification.symbolName)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(classification.tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(classification.tint)
                            .help(classification.helpText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded(.towardZero))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }

        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func formattedBitrate(_ bitrate: Int) -> String {
        let measurement = Measurement(value: Double(bitrate), unit: UnitInformationStorage.bits)
        return measurement.formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    private func selectDefaultTab() {
        let available = MediaInfoTab.allCases.filter { $0.isAvailable(for: session) }
        guard !available.isEmpty else { return }
        if available.contains(selectedTab) {
            return
        }

        let type = MediaDetector.mediaType(for: session)
        let preferred: MediaInfoTab?
        switch type {
        case .hls, .hlsDiscovery:
            preferred = .hls
        case .dash:
            preferred = .dash
        case .adXml:
            preferred = .adXml
        case .image:
            preferred = .image
        case .video:
            preferred = .avAsset
        case .none:
            preferred = nil
        }

        if let preferred, available.contains(preferred) {
            selectedTab = preferred
        } else {
            selectedTab = available[0]
        }
    }

    private var appTextSize: AppTextSize {
        AppTextSize(rawValue: appTextSizeRawValue) ?? .standard
    }

    private var appTextScale: CGFloat {
        appTextSize.fontScale
    }


    private func hlsClassifications(for manifest: HLSManifest) -> [HLSClassification] {
        let requestHost = session.request.host.lowercased()
        let requestPath = session.request.path.lowercased()
        let allHosts = Set(([requestHost] + manifest.referencedHosts.map { $0.lowercased() }).filter { !$0.isEmpty })

        let isKnownAdHost = allHosts.contains { MediaHostSignals.isAdServingHost($0) }

        let hasAdSignal = isKnownAdHost || !manifest.adMarkers.isEmpty || manifest.segments.contains(where: \.isAdSegment)
        let isAudioPlaylist = requestPath.contains("aac") ||
            requestPath.contains("audio") ||
            manifest.mediaGroups.contains { $0.type.uppercased() == "AUDIO" }
        let isSubtitlePlaylist = requestPath.contains("sub") ||
            requestPath.contains("vtt") ||
            manifest.mediaGroups.contains { type in
                let uppercased = type.type.uppercased()
                return uppercased == "SUBTITLES" || uppercased == "CLOSED-CAPTIONS"
            }
        /// Program media without an ad signal: master with variants, or media playlist with segments.
        let describesProgramMedia = manifest.isMasterPlaylist
            ? !manifest.variants.isEmpty
            : manifest.segmentCount > 0

        var classifications: [HLSClassification] = []

        if hasAdSignal {
            classifications.append(
                HLSClassification(
                    title: "Ad Delivery",
                    symbolName: "megaphone.fill",
                    helpText: "This playlist appears to be part of ad playback. The request host or manifest markers match ad-delivery signals.",
                    tint: .orange
                )
            )
        } else if describesProgramMedia {
            classifications.append(
                HLSClassification(
                    title: "Content Delivery",
                    symbolName: "film.stack.fill",
                    helpText: "This playlist describes program media (variants or segments) and does not match ad-delivery signals.",
                    tint: .blue
                )
            )
        }

        if manifest.isMasterPlaylist {
            classifications.append(
                HLSClassification(
                    title: "Master Manifest",
                    symbolName: "square.stack.3d.up.fill",
                    helpText: "A master HLS manifest that points to one or more variant playlists.",
                    tint: .purple
                )
            )
        } else {
            classifications.append(
                HLSClassification(
                    title: "Media Playlist",
                    symbolName: "list.bullet.rectangle.portrait.fill",
                    helpText: "A media playlist that points directly to segments instead of more variants.",
                    tint: .secondary
                )
            )
        }

        if isAudioPlaylist {
            classifications.append(
                HLSClassification(
                    title: "Audio Track",
                    symbolName: "waveform",
                    helpText: "This request looks like an audio rendition or audio-only playlist.",
                    tint: .green
                )
            )
        }

        if isSubtitlePlaylist {
            classifications.append(
                HLSClassification(
                    title: "Text Track",
                    symbolName: "captions.bubble.fill",
                    helpText: "This request looks like a subtitles or captions playlist.",
                    tint: .teal
                )
            )
        }

        if !manifest.referencedHosts.isEmpty {
            classifications.append(
                HLSClassification(
                    title: "Hosts \(manifest.referencedHosts.count)",
                    symbolName: "network",
                    helpText: "Referenced hosts: \(manifest.referencedHosts.joined(separator: ", "))",
                    tint: .indigo
                )
            )
        }

        return classifications
    }

    private func hlsDiscoveryClassifications(for discovery: HLSStreamDiscovery) -> [HLSClassification] {
        var classifications: [HLSClassification] = [
            HLSClassification(
                title: "Playback API",
                symbolName: "sparkles.rectangle.stack.fill",
                helpText: "This session is an API response that exposed the HLS manifest URL for playback.",
                tint: .purple
            ),
            HLSClassification(
                title: "Master Manifest",
                symbolName: "square.stack.3d.up.fill",
                helpText: "The discovered URL points to a master HLS manifest.",
                tint: .purple
            )
        ]

        switch discovery.kind {
        case .content:
            classifications.append(
                HLSClassification(
                    title: "Content Delivery",
                    symbolName: "film.stack.fill",
                    helpText: "The manifest URL appears to belong to the main program stream.",
                    tint: .blue
                )
            )
        case .ad:
            classifications.append(
                HLSClassification(
                    title: "Ad Delivery",
                    symbolName: "megaphone.fill",
                    helpText: "The manifest URL appears to belong to ad playback.",
                    tint: .orange
                )
            )
        case .live:
            classifications.append(
                HLSClassification(
                    title: "Live Delivery",
                    symbolName: "dot.radiowaves.left.and.right",
                    helpText: "The manifest URL appears to belong to a live stream.",
                    tint: .red
                )
            )
        case .unknown:
            classifications.append(
                HLSClassification(
                    title: "Unclassified",
                    symbolName: "questionmark.circle",
                    helpText: "JoesProxy detected an HLS manifest URL in the API response, but could not confidently classify the stream.",
                    tint: .secondary
                )
            )
        }

        if discovery.drmLicenseURL != nil {
            classifications.append(
                HLSClassification(
                    title: "DRM License",
                    symbolName: "key.fill",
                    helpText: "This playback response also exposed a DRM license endpoint.",
                    tint: .yellow
                )
            )
        }

        return classifications
    }
}
