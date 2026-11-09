//
//  MediaInfoTransportVideoAnalysisView.swift
//  JoesProxy
//
//  Optional in-depth MPEG-TS frame and GOP analysis presentation.
//

import SwiftUI

struct MediaInfoTransportVideoAnalysisView: View {
    let analysis: MPEGTransportStreamVideoAnalysis?
    let diagnostics: MediaParserDiagnostics?
    let isLoading: Bool
    let analysisAttempted: Bool
    let textScale: CGFloat
    let requestAnalysis: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In-Depth Video and GOP Analysis")
                .mediaInfoFont(.caption, scale: textScale, weight: .semibold)

            if let analysis {
                analysisDetails(analysis)
                if let diagnostics {
                    MediaParserDiagnosticsView(diagnostics: diagnostics, textScale: textScale)
                }
            } else if isLoading {
                loadingView
            } else {
                analysisPrompt
            }
        }
    }

    private func analysisDetails(_ analysis: MPEGTransportStreamVideoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataRow("Codec", value: analysis.codec.rawValue)
            metadataRow("Video PID", value: String(format: "0x%04X", analysis.videoPID))
            metadataRow("Access Units", value: "\(analysis.accessUnitCount)")
            if let frameRate = analysis.observedFrameRate {
                metadataRow("Observed Frame Rate", value: String(format: "%.2f fps", frameRate))
            }
            if let presentationSpan = analysis.presentationTimeSpan {
                metadataRow("Observed Presentation Span", value: formatDuration(presentationSpan))
            }
            metadataRow(
                "Frame Mix",
                value: "I \(analysis.iFrameCount), P \(analysis.pFrameCount), B \(analysis.bFrameCount), Unclassified \(analysis.unclassifiedFrameCount)"
            )
            metadataRow("Random-Access Frames", value: "\(analysis.keyFrameCount)")

            if let averageFrames = analysis.averageGOPFrameCount {
                metadataRow("Average GOP", value: String(format: "%.1f frames", averageFrames))
            }
            if let maximumFrames = analysis.maximumGOPFrameCount {
                metadataRow("Largest Observed GOP", value: "\(maximumFrames) frames")
            }
            if let averageInterval = analysis.averageKeyFrameInterval {
                metadataRow("Average Keyframe Interval", value: formatDuration(averageInterval))
            }
            if let maximumInterval = analysis.maximumKeyFrameInterval {
                metadataRow("Largest Keyframe Interval", value: formatDuration(maximumInterval))
            }
            seekToleranceDetails(analysis)

            if analysis.isInspectionLimited {
                Text("GOP analysis used the first \(analysis.bytesInspected) captured bytes; later keyframes may not be represented.")
                    .mediaInfoFont(.caption2, scale: textScale)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func seekToleranceDetails(_ analysis: MPEGTransportStreamVideoAnalysis) -> some View {
        if let tolerance = analysis.suggestedSeekTolerance {
            metadataRow("Suggested Seek Tolerance", value: "±\(formatDuration(tolerance))")
            Text("This symmetric tolerance is half the largest observed keyframe interval, so the seek window can include the nearest observed random-access frame.")
                .mediaInfoFont(.caption2, scale: textScale)
                .foregroundStyle(.secondary)
        } else {
            Text("At least two random-access frames are required to calculate an observed GOP interval and seek tolerance.")
                .mediaInfoFont(.caption2, scale: textScale)
                .foregroundStyle(.secondary)
        }
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Analyzing captured transport stream…")
                .mediaInfoFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
        }
    }

    private var analysisPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspect captured transport-stream bytes for frame types, GOP intervals, and a seek-tolerance recommendation. Analysis runs only when requested.")
                .mediaInfoFont(.caption2, scale: textScale)
                .foregroundStyle(.secondary)

            if analysisAttempted {
                Label("No supported H.264 or HEVC video access units were found in the captured bytes.", systemImage: "info.circle")
                    .mediaInfoFont(.caption2, scale: textScale)
                    .foregroundStyle(.secondary)
                if let diagnostics {
                    MediaParserDiagnosticsView(diagnostics: diagnostics, textScale: textScale)
                }
            }

            Button(action: requestAnalysis) {
                Label(
                    analysisAttempted ? "Retry GOP Analysis" : "Run In-Depth GOP Analysis",
                    systemImage: "film.stack"
                )
            }
            .accessibilityIdentifier("mediaInfoAnalyzeGOPButton")
        }
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .mediaInfoFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .mediaInfoFont(.body, scale: textScale, design: .monospaced)
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
}
