//
//  AVAssetMetadataService.swift
//  JoesProxy
//
//  User-initiated AVFoundation inspection for one captured item or live URL.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface

@MainActor
final class AVAssetMetadataService {
    private enum InspectionError: LocalizedError {
        case invalidInput
        case playerFailed(String)
        case timedOut(String)
        case frameUnavailable
        case preparationBusy

        var errorDescription: String? {
            switch self {
            case .invalidInput:
                return "The media inspection input is unavailable."
            case .playerFailed(let message):
                return "The media engine could not prepare this item: \(message)"
            case .timedOut(let stage):
                return "\(stage) timed out."
            case .frameUnavailable:
                return "The media engine did not produce a video frame at the requested time."
            case .preparationBusy:
                return "Media preparation is busy. Wait for another inspection to finish, then retry."
            }
        }
    }

    private struct AssetDetails: Sendable {
        let summary: AVMediaAssetSummary
        let variants: [AVMediaVariantInfo]
        let videoTracks: [VideoTrackInfo]
        let audioTracks: [AudioTrackInfo]
        let subtitleTracks: [SubtitleTrackInfo]
        let mediaSelectionGroups: [AVMediaSelectionGroupInfo]
    }

    private let metadataTimeout: TimeInterval
    private let playerTimeout: TimeInterval
    private let preparationBudget: MediaInspectionWorkBudget
    private let temporaryDirectory: URL

    init(metadataTimeout: TimeInterval = 15, playerTimeout: TimeInterval = 30,
         preparationBudget: MediaInspectionWorkBudget = .shared,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.metadataTimeout = metadataTimeout
        self.playerTimeout = playerTimeout
        self.preparationBudget = preparationBudget
        self.temporaryDirectory = temporaryDirectory
    }

    func inspect(_ input: AVMediaInspectionInput) async -> AVMediaInspectionReport {
        var temporaryURL: URL?
        var stages: [AVMediaInspectionStageResult] = []
        var warnings = input.initialWarnings
        var assetDetails: AssetDetails?
        var playerSummary: AVMediaPlayerSummary?
        var frameInfo: AVDecodedFrameInfo?
        var accessEvents: [AVMediaAccessEvent] = []
        var probeErrors: [AVMediaProbeError] = []

        do {
            try Task.checkCancellation()
            let sourceURL: URL
            switch input.source {
            case .capturedItem:
                let fileExtension = input.capturedFileExtension?.isEmpty == false
                    ? input.capturedFileExtension!
                    : "media"
                let url = temporaryDirectory
                    .appendingPathComponent("JoesProxy-MediaInspection-\(UUID().uuidString)")
                    .appendingPathExtension(fileExtension)
                temporaryURL = url
                // Decode and file preparation share bounded admission. Cancellation retains
                // that slot until synchronous I/O exits; cleanup still runs before returning.
                let prepared = await preparationBudget.run { () -> Result<Void, Error> in
                    do {
                        let data: Data?
                        if let response = input.capturedResponse {
                            data = MediaDetector.decodedResponseBody(for: response)
                        } else {
                            data = input.capturedData
                        }
                        try Task.checkCancellation()
                        guard let data, !data.isEmpty else { throw InspectionError.invalidInput }
                        try data.write(to: url, options: .atomic)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
                try Task.checkCancellation()
                guard let prepared else {
                    temporaryURL = nil // Admission rejected; no worker created this file.
                    throw InspectionError.preparationBusy
                }
                try prepared.get()
                sourceURL = url
            case .liveURL:
                guard let url = input.url else { throw InspectionError.invalidInput }
                sourceURL = url
            }

            let asset = AVURLAsset(url: sourceURL)
            defer { asset.cancelLoading() }
            let metadataStart = Date()
            do {
                assetDetails = try await AVMediaMetadataOperation.run(timeout: .seconds(metadataTimeout)) {
                    try await self.loadAssetDetails(asset)
                } stop: {
                    asset.cancelLoading()
                }
                stages.append(stage("asset", "Asset Metadata", startedAt: metadataStart, outcome: .completed))
            } catch {
                warnings.append(error.localizedDescription)
                stages.append(stage(
                    "asset",
                    "Asset Metadata",
                    startedAt: metadataStart,
                    outcome: outcome(for: error),
                    message: error.localizedDescription
                ))
            }

            try Task.checkCancellation()
            let playerStart = Date()
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            defer {
                player.pause()
                item.cancelPendingSeeks()
                player.replaceCurrentItem(with: nil)
            }
            do {
                try await waitUntilReady(item, timeout: playerTimeout)
                playerSummary = makePlayerSummary(item)
                stages.append(stage("player", "Player Preparation", startedAt: playerStart, outcome: .completed))
            } catch {
                stages.append(stage(
                    "player",
                    "Player Preparation",
                    startedAt: playerStart,
                    outcome: outcome(for: error),
                    message: error.localizedDescription
                ))
                warnings.append(error.localizedDescription)
            }

            try Task.checkCancellation()
            if item.status == .readyToPlay {
                let frameStart = Date()
                do {
                    frameInfo = try await decodeFrame(
                        item: item,
                        player: player,
                        requestedTime: input.sampleTime,
                        timeout: playerTimeout
                    )
                    stages.append(stage("frame", "Single-Frame Decode", startedAt: frameStart, outcome: .completed))
                } catch {
                    stages.append(stage(
                        "frame",
                        "Single-Frame Decode",
                        startedAt: frameStart,
                        outcome: outcome(for: error),
                        message: error.localizedDescription
                    ))
                    warnings.append(error.localizedDescription)
                }
                let logs = await loadPlaybackLogs(item)
                accessEvents = logs.accessEvents
                probeErrors = logs.errors
            } else {
                stages.append(AVMediaInspectionStageResult(
                    id: "frame",
                    title: "Single-Frame Decode",
                    duration: 0,
                    outcome: .skipped,
                    message: "Player preparation did not complete."
                ))
            }
        } catch is CancellationError {
            stages.append(AVMediaInspectionStageResult(
                id: "inspection",
                title: "Inspection",
                duration: 0,
                outcome: .cancelled,
                message: "Inspection cancelled."
            ))
        } catch {
            warnings.append(error.localizedDescription)
            stages.append(AVMediaInspectionStageResult(
                id: "inspection",
                title: "Inspection",
                duration: 0,
                outcome: outcome(for: error),
                message: error.localizedDescription
            ))
        }

        if let temporaryURL {
            let cleaned = await Task.detached(priority: .utility) {
                do {
                    try FileManager.default.removeItem(at: temporaryURL)
                    return true
                } catch CocoaError.fileNoSuchFile {
                    return true
                } catch {
                    return false
                }
            }.value
            if !cleaned {
                let message = "Temporary media cleanup failed. The inspection file may remain on disk."
                warnings.append(message)
                stages.append(AVMediaInspectionStageResult(id: "cleanup", title: "Temporary Media Cleanup",
                    duration: 0, outcome: .failed, message: message))
            }
        }

        return AVMediaInspectionReport(
            source: input.source,
            sourceDescription: input.displayName,
            isPartial: stages.contains { $0.outcome != .completed },
            asset: assetDetails?.summary,
            variants: assetDetails?.variants ?? [],
            videoTracks: assetDetails?.videoTracks ?? [],
            audioTracks: assetDetails?.audioTracks ?? [],
            subtitleTracks: assetDetails?.subtitleTracks ?? [],
            mediaSelectionGroups: assetDetails?.mediaSelectionGroups ?? [],
            player: playerSummary,
            decodedFrame: frameInfo,
            accessEvents: accessEvents,
            errors: probeErrors,
            stages: stages,
            warnings: Array(Set(warnings)).sorted()
        )
    }

    private func loadAssetDetails(_ asset: AVURLAsset) async throws -> AssetDetails {
        async let playable = asset.load(.isPlayable)
        async let exportable = asset.load(.isExportable)
        async let protected = asset.load(.hasProtectedContent)
        async let preciseTiming = asset.load(.providesPreciseDurationAndTiming)
        async let duration = asset.load(.duration)
        async let variants = asset.load(.variants)

        let assetDuration = try await duration
        let durationSeconds = assetDuration.seconds.isFinite && assetDuration.seconds >= 0
            ? assetDuration.seconds
            : nil
        let summary = try await AVMediaAssetSummary(
            duration: durationSeconds,
            isPlayable: playable,
            isExportable: exportable,
            hasProtectedContent: protected,
            providesPreciseDurationAndTiming: preciseTiming
        )
        let variantInfo = try await variants.enumerated().map { index, variant in
            let video = variant.videoAttributes
            let audio = variant.audioAttributes
            let playlistURL: String?
            if #available(macOS 26.0, *) {
                playlistURL = CapturedURLRedaction.displayString(for: variant.url.absoluteString)
            } else {
                playlistURL = nil
            }
            return AVMediaVariantInfo(
                id: index,
                playlistURL: playlistURL,
                peakBitRate: variant.peakBitRate,
                averageBitRate: variant.averageBitRate,
                videoRange: video.map { String(describing: $0.videoRange) },
                videoCodecs: video?.codecTypes.map(fourCCToString) ?? [],
                presentationWidth: video.map { Int($0.presentationSize.width) },
                presentationHeight: video.map { Int($0.presentationSize.height) },
                nominalFrameRate: video?.nominalFrameRate,
                audioFormats: audio?.formatIDs.map(fourCCToString) ?? []
            )
        }

        return AssetDetails(
            summary: summary,
            variants: variantInfo,
            videoTracks: try await loadVideoTracks(asset),
            audioTracks: try await loadAudioTracks(asset),
            subtitleTracks: try await loadSubtitleTracks(asset),
            mediaSelectionGroups: try await loadMediaSelectionGroups(asset)
        )
    }

    private func loadVideoTracks(_ asset: AVAsset) async throws -> [VideoTrackInfo] {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var result: [VideoTrackInfo] = []
        for track in tracks {
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformedSize = naturalSize.applying(transform)
            let descriptions = try await track.load(.formatDescriptions)
            result.append(VideoTrackInfo(
                width: Int(abs(transformedSize.width)),
                height: Int(abs(transformedSize.height)),
                estimatedDataRate: try await track.load(.estimatedDataRate),
                nominalFrameRate: try await track.load(.nominalFrameRate),
                codec: descriptions.first.map { fourCCToString(CMFormatDescriptionGetMediaSubType($0)) }
            ))
        }
        return result
    }

    private func loadAudioTracks(_ asset: AVAsset) async throws -> [AudioTrackInfo] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var result: [AudioTrackInfo] = []
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            let basicDescription = descriptions.first.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)
            let languageCode = try await track.load(.languageCode)
            result.append(AudioTrackInfo(
                channels: basicDescription.map { Int($0.pointee.mChannelsPerFrame) },
                sampleRate: basicDescription.map { Float($0.pointee.mSampleRate) },
                language: localizedLanguageName(languageCode),
                codec: descriptions.first.map { fourCCToString(CMFormatDescriptionGetMediaSubType($0)) }
            ))
        }
        return result
    }

    private func loadSubtitleTracks(_ asset: AVAsset) async throws -> [SubtitleTrackInfo] {
        guard let group = try await asset.loadMediaSelectionGroup(for: .legible) else { return [] }
        return group.options.map {
            SubtitleTrackInfo(
                language: localizedLanguageName($0.locale?.language.languageCode?.identifier),
                displayName: $0.displayName
            )
        }
    }

    private func loadMediaSelectionGroups(_ asset: AVURLAsset) async throws -> [AVMediaSelectionGroupInfo] {
        let characteristics = try await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)
        var result: [AVMediaSelectionGroupInfo] = []
        for characteristic in characteristics {
            guard let group = try await asset.loadMediaSelectionGroup(for: characteristic) else { continue }
            result.append(AVMediaSelectionGroupInfo(
                id: characteristic.rawValue,
                characteristic: characteristic.rawValue,
                defaultOption: group.defaultOption?.displayName,
                options: group.options.enumerated().map { index, option in
                    AVMediaSelectionOptionInfo(
                        id: index,
                        displayName: option.displayName,
                        mediaType: option.mediaType.rawValue,
                        language: localizedLanguageName(option.locale?.language.languageCode?.identifier),
                        isPlayable: option.isPlayable
                    )
                }
            ))
        }
        return result
    }

    private func waitUntilReady(_ item: AVPlayerItem, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while item.status == .unknown && Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        switch item.status {
        case .readyToPlay:
            return
        case .failed:
            throw InspectionError.playerFailed(item.error?.localizedDescription ?? "Unknown AVFoundation failure")
        case .unknown:
            throw InspectionError.timedOut("Player preparation")
        @unknown default:
            throw InspectionError.playerFailed("Unknown player status")
        }
    }

    private func makePlayerSummary(_ item: AVPlayerItem) -> AVMediaPlayerSummary {
        AVMediaPlayerSummary(
            status: "Ready to Play",
            presentationWidth: Int(item.presentationSize.width),
            presentationHeight: Int(item.presentationSize.height),
            isPlaybackLikelyToKeepUp: item.isPlaybackLikelyToKeepUp,
            isPlaybackBufferEmpty: item.isPlaybackBufferEmpty,
            isPlaybackBufferFull: item.isPlaybackBufferFull,
            loadedTimeRanges: timeRanges(item.loadedTimeRanges),
            seekableTimeRanges: timeRanges(item.seekableTimeRanges)
        )
    }

    private func timeRanges(_ values: [NSValue]) -> [AVMediaTimeRangeInfo] {
        values.enumerated().compactMap { index, value in
            let range = value.timeRangeValue
            guard range.start.seconds.isFinite, range.duration.seconds.isFinite else { return nil }
            return AVMediaTimeRangeInfo(id: index, start: range.start.seconds, duration: range.duration.seconds)
        }
    }

    private func decodeFrame(
        item: AVPlayerItem,
        player: AVPlayer,
        requestedTime: TimeInterval,
        timeout: TimeInterval
    ) async throws -> AVDecodedFrameInfo {
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        defer {
            player.pause()
            item.remove(output)
        }

        let clampedTime = clampSampleTime(requestedTime, item: item)
        let target = CMTime(seconds: clampedTime, preferredTimescale: 600)
        do {
            try await AVMediaSeekOperation.run(timeout: .seconds(timeout)) { completion in
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero,
                            completionHandler: completion)
            } cancel: {
                item.cancelPendingSeeks()
            }
        } catch AVMediaSeekOperation.Failure.timedOut {
            throw InspectionError.timedOut("Frame seek")
        } catch AVMediaSeekOperation.Failure.interrupted {
            throw InspectionError.playerFailed("Frame seek was interrupted.")
        }
        try Task.checkCancellation()
        player.play()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let itemTime = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                return AVPixelBufferInspector.inspect(
                    pixelBuffer,
                    requestedTime: requestedTime,
                    decodedTime: itemTime.seconds
                )
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw InspectionError.frameUnavailable
    }

    private func clampSampleTime(_ requestedTime: TimeInterval, item: AVPlayerItem) -> TimeInterval {
        let lowerBound = max(0, requestedTime)
        if let range = item.seekableTimeRanges.first?.timeRangeValue,
           range.start.seconds.isFinite,
           range.duration.seconds.isFinite,
           range.duration.seconds > 0 {
            let end = range.start.seconds + range.duration.seconds
            return min(max(lowerBound, range.start.seconds), max(range.start.seconds, end - 0.001))
        }
        if item.duration.seconds.isFinite, item.duration.seconds > 0 {
            return min(lowerBound, max(0, item.duration.seconds - 0.001))
        }
        return lowerBound
    }

    private func loadPlaybackLogs(
        _ item: AVPlayerItem
    ) async -> (accessEvents: [AVMediaAccessEvent], errors: [AVMediaProbeError]) {
        // The macOS 15 deployment SDK exposes only snapshot accessors in Swift.
        // Keep their use isolated so a future SDK replacement is local to this method.
        let accessLog = item.accessLog()
        let errorLog = item.errorLog()

        let accessEvents = (accessLog?.events ?? []).enumerated().map { index, event in
            AVMediaAccessEvent(
                id: index,
                resource: event.uri.map(CapturedURLRedaction.displayString),
                mediaRequestCount: event.numberOfMediaRequests,
                observedBitRate: event.observedBitrate,
                indicatedBitRate: event.indicatedBitrate,
                stalls: event.numberOfStalls,
                transferredBytes: event.numberOfBytesTransferred
            )
        }
        let errors = (errorLog?.events ?? []).enumerated().map { index, event in
            AVMediaProbeError(
                id: index,
                domain: event.errorDomain,
                statusCode: event.errorStatusCode,
                comment: event.errorComment,
                resource: event.uri.map(CapturedURLRedaction.displayString)
            )
        }
        return (accessEvents, errors)
    }

    private func stage(
        _ id: String,
        _ title: String,
        startedAt: Date,
        outcome: AVMediaInspectionStageResult.Outcome,
        message: String? = nil
    ) -> AVMediaInspectionStageResult {
        AVMediaInspectionStageResult(
            id: id,
            title: title,
            duration: Date().timeIntervalSince(startedAt),
            outcome: outcome,
            message: message
        )
    }

    private func outcome(for error: Error) -> AVMediaInspectionStageResult.Outcome {
        if error is CancellationError { return .cancelled }
        if case AVMediaMetadataOperation.Failure.timedOut = error { return .timedOut }
        if case InspectionError.timedOut = error { return .timedOut }
        return .failed
    }

    private func localizedLanguageName(_ languageCode: String?) -> String? {
        languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
    }

    private func fourCCToString(_ value: FourCharCode) -> String {
        AVPixelBufferInspector.fourCCToString(value)
    }
}

enum AVPixelBufferInspector {
    static func inspect(
        _ pixelBuffer: CVPixelBuffer,
        requestedTime: TimeInterval,
        decodedTime: TimeInterval
    ) -> AVDecodedFrameInfo {
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let planes = (0..<planeCount).map { index in
            AVPixelPlaneInfo(
                id: index,
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, index),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, index),
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index)
            )
        }
        let attachmentKeys: [(CFString, String)] = [
            (kCVImageBufferColorPrimariesKey, "Color Primaries"),
            (kCVImageBufferTransferFunctionKey, "Transfer Function"),
            (kCVImageBufferYCbCrMatrixKey, "YCbCr Matrix"),
            (kCVImageBufferCleanApertureKey, "Clean Aperture"),
            (kCVImageBufferPixelAspectRatioKey, "Pixel Aspect Ratio"),
            (kCVImageBufferFieldCountKey, "Field Count"),
            (kCVImageBufferFieldDetailKey, "Field Detail"),
            (kCVImageBufferMasteringDisplayColorVolumeKey, "Mastering Display Color Volume"),
            (kCVImageBufferContentLightLevelInfoKey, "Content Light Level")
        ]
        var attachments: [String: String] = [:]
        for (key, title) in attachmentKeys {
            if let value = CVBufferCopyAttachment(pixelBuffer, key, nil) {
                attachments[title] = describeAttachment(value)
            }
        }

        let ioSurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let dataSize = CVPixelBufferGetDataSize(pixelBuffer)
        let estimatedSize = dataSize > 0
            ? dataSize
            : max(0, CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer))
        let metalCompatible = (CVBufferCopyAttachment(
            pixelBuffer,
            kCVPixelBufferMetalCompatibilityKey,
            nil
        ) as? Bool) ?? true

        return AVDecodedFrameInfo(
            requestedTime: requestedTime,
            decodedTime: decodedTime.isFinite ? decodedTime : requestedTime,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: fourCCToString(format),
            isPlanar: CVPixelBufferIsPlanar(pixelBuffer),
            planeCount: planeCount,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            estimatedByteSize: estimatedSize,
            planes: planes,
            attachments: attachments,
            isMetalCompatible: metalCompatible,
            hasIOSurface: ioSurface != nil,
            ioSurfaceWidth: ioSurface.map(IOSurfaceGetWidth),
            ioSurfaceHeight: ioSurface.map(IOSurfaceGetHeight),
            ioSurfaceBytesPerRow: ioSurface.map(IOSurfaceGetBytesPerRow),
            ioSurfaceAllocationSize: ioSurface.map(IOSurfaceGetAllocSize)
        )
    }

    static func fourCCToString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", value)
    }

    private static func describeAttachment(_ value: CFTypeRef) -> String {
        if let data = value as? Data { return "\(data.count) bytes" }
        return String(describing: value)
    }
}
