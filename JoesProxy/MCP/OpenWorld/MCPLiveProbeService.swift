import Foundation

/// Performs open-world live media URL probes for AH-5.
///
/// Concurrency: `@MainActor` entry; AVFoundation work runs via the same cancellation bridge as
/// capture-only inspection. Only invoked from ``MCPOperationCoordinator``'s `.liveProbe` kind.
@MainActor
protocol MCPLiveProbeServicing: AnyObject {
    func probe(
        sessionID: SessionRecord.ID,
        liveURL: URL,
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        captureEpoch: MCPCaptureEpoch,
        progress: @MainActor (Double, String) -> Void
    ) async throws -> MCPMediaInspectionResultDTO
}

@MainActor
final class MCPLiveProbeService: MCPLiveProbeServicing {
    private let avService: AVAssetMetadataService

    init(avService: AVAssetMetadataService? = nil) {
        self.avService = avService ?? AVAssetMetadataService()
    }

    func probe(
        sessionID: SessionRecord.ID,
        liveURL: URL,
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        captureEpoch: MCPCaptureEpoch,
        progress: @MainActor (Double, String) -> Void
    ) async throws -> MCPMediaInspectionResultDTO {
        progress(0.1, "live_media_engine")
        let input = AVMediaInspectionInput(
            source: .liveURL,
            url: liveURL,
            capturedData: nil,
            capturedFileExtension: nil,
            displayName: "Live media probe \(sessionID.uuidString)",
            sampleTime: sampleTime,
            initialWarnings: [
                "This result came from a live network probe of the original URL, not the captured response body."
            ]
        )
        let report = await avService.inspect(input)
        try Task.checkCancellation()
        progress(1, "complete")

        let mediaEngine = MCPMediaEngineInspectionDTO(
            partial: report.isPartial,
            durationSeconds: report.asset?.duration,
            playable: report.asset?.isPlayable,
            exportable: report.asset?.isExportable,
            protectedContent: report.asset?.hasProtectedContent,
            preciseTiming: report.asset?.providesPreciseDurationAndTiming,
            variantCount: report.variants.count,
            videoTrackCount: report.videoTracks.count,
            audioTrackCount: report.audioTracks.count,
            subtitleTrackCount: report.subtitleTracks.count,
            variants: report.variants.prefix(100).map {
                MCPMediaEngineVariantDTO(
                    peakBitRate: $0.peakBitRate,
                    averageBitRate: $0.averageBitRate,
                    videoRange: $0.videoRange,
                    videoCodecs: $0.videoCodecs,
                    width: $0.presentationWidth,
                    height: $0.presentationHeight,
                    nominalFrameRate: $0.nominalFrameRate,
                    audioFormats: $0.audioFormats
                )
            },
            videoTracks: report.videoTracks.prefix(100).map {
                MCPMediaEngineVideoTrackDTO(
                    width: $0.width,
                    height: $0.height,
                    estimatedDataRate: $0.estimatedDataRate,
                    nominalFrameRate: $0.nominalFrameRate,
                    codec: $0.codec
                )
            },
            audioTracks: report.audioTracks.prefix(100).map {
                MCPMediaEngineAudioTrackDTO(
                    channels: $0.channels,
                    sampleRate: $0.sampleRate,
                    language: $0.language,
                    codec: $0.codec
                )
            },
            subtitleLanguages: Array(Set(report.subtitleTracks.compactMap(\.language))).sorted(),
            mediaSelectionLanguages: Array(Set(
                report.mediaSelectionGroups.flatMap(\.options).compactMap(\.language)
            )).sorted(),
            player: report.player.map {
                MCPMediaEnginePlayerDTO(
                    status: $0.status,
                    presentationWidth: $0.presentationWidth,
                    presentationHeight: $0.presentationHeight,
                    likelyToKeepUp: $0.isPlaybackLikelyToKeepUp,
                    bufferEmpty: $0.isPlaybackBufferEmpty,
                    bufferFull: $0.isPlaybackBufferFull,
                    loadedRanges: $0.loadedTimeRanges.map {
                        MCPMediaTimeRangeDTO(start: $0.start, duration: $0.duration)
                    },
                    seekableRanges: $0.seekableTimeRanges.map {
                        MCPMediaTimeRangeDTO(start: $0.start, duration: $0.duration)
                    }
                )
            },
            decodedFrame: nil,
            stages: report.stages.map {
                MCPOperationStageDTO(
                    id: $0.id,
                    title: $0.title,
                    durationSeconds: $0.duration,
                    outcome: $0.outcome.rawValue,
                    message: $0.message
                )
            },
            warnings: report.warnings
        )

        return MCPMediaInspectionResultDTO(
            sessionID: sessionID.uuidString,
            analyses: [.liveMediaEngine],
            binaryStructure: nil,
            gop: nil,
            id3: nil,
            mediaEngine: mediaEngine,
            diagnostics: [],
            warnings: report.warnings,
            disclosure: MCPMediaDisclosureContextDTO(
                captureEpoch: captureEpoch,
                policyRevision: policyRevision,
                generatedAt: Date(),
                removedFields: [
                    "rawBody", "rawURLs", "queryValues", "credentials",
                    "pixelData", "ioSurfaceIdentifiers", "accessLogResources"
                ],
                partialResultReason: report.isPartial ? "Live probe returned partial results." : nil,
                truncated: report.variants.count > 100
                    || report.videoTracks.count > 100
                    || report.audioTracks.count > 100
            )
        )
    }
}
