#!/usr/bin/env swift
// playlist_parser.swift
//
// Inspect an HLS master (or media) playlist URL with AVFoundation.
// Fetches the playlist text, builds an AVURLAsset and AVPlayerItem, and prints
// the properties AVFoundation exposes for debugging and Media Info research.
//
// Run:
//   swift memlog/utility_scripts/playlist_parser.swift <master-playlist-url>
//
// Example:
//   swift memlog/utility_scripts/playlist_parser.swift \
//     https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8
//
// Options:
//   --mode <metadata|player|frame> Inspection depth (default: frame)
//   --timeout <seconds>     Max wait for AVPlayerItem readiness (default: 45)
//   --sample-time <seconds> Decode frame at this timestamp (default: 1.0)
//   --skip-playlist-text    Do not print the raw .m3u8 response body
//   --skip-pixel-buffer     Skip CVPixelBuffer extraction and inspection
//   --verbose               Include process-local pointers and surface identifiers

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface

enum PlaylistParserError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidURL(String)
    case playlistFetchFailed(String)
    case assetInspectionFailed(String)
    case playerItemNotReady(AVPlayerItem.Status, Error?)
    case pixelBufferExtractionFailed(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return """
            Usage: playlist_parser.swift <master-playlist-url> [options]

            Options:
              --mode <mode>            metadata, player, or frame (default: frame)
              --timeout <seconds>       Max wait for AVPlayerItem readiness (default: 45)
              --sample-time <seconds>   Decode frame at this timestamp (default: 1.0)
              --skip-playlist-text      Do not print the raw .m3u8 response body
              --skip-pixel-buffer       Skip CVPixelBuffer extraction and inspection
              --verbose                 Include process-local pointers and surface identifiers

            Creates an AVURLAsset and AVPlayerItem for the URL, prints AVFoundation properties,
            then decodes one video frame to CVPixelBuffer and prints CoreVideo properties.
            """
        case .invalidURL(let value):
            return "Invalid playlist URL: \(value)"
        case .playlistFetchFailed(let message):
            return "Failed to fetch playlist: \(message)"
        case .assetInspectionFailed(let message):
            return "Asset inspection failed: \(message)"
        case .playerItemNotReady(let status, let error):
            if let error {
                return "AVPlayerItem did not become ready (status=\(status.rawValue)): \(error.localizedDescription)"
            }
            return "AVPlayerItem did not become ready (status=\(status.rawValue))."
        case .pixelBufferExtractionFailed(let message):
            return "CVPixelBuffer extraction failed: \(message)"
        }
    }
}

struct PlaylistParserOptions {
    enum Mode: String {
        case metadata
        case player
        case frame
    }

    var playlistURL: URL
    var mode: Mode = .frame
    var timeout: TimeInterval = 45
    var sampleTimeSeconds: Double = 1.0
    var skipPlaylistText = false
    var skipPixelBuffer = false
    var verbose = false
}

enum PlaylistParser {
    static func run() async {
        do {
            let options = try parseOptions()
            try await inspectPlaylist(options: options)
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    private static func parseOptions() throws -> PlaylistParserOptions {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            throw PlaylistParserError.invalidArguments
        }

        var mode = PlaylistParserOptions.Mode.frame
        var timeout: TimeInterval = 45
        var sampleTimeSeconds: Double = 1.0
        var skipPlaylistText = false
        var skipPixelBuffer = false
        var verbose = false

        if let modeIndex = arguments.firstIndex(of: "--mode") {
            guard modeIndex + 1 < arguments.count,
                  let parsed = PlaylistParserOptions.Mode(rawValue: arguments[modeIndex + 1]) else {
                throw PlaylistParserError.invalidArguments
            }
            mode = parsed
            arguments.removeSubrange(modeIndex...(modeIndex + 1))
        }

        if let timeoutIndex = arguments.firstIndex(of: "--timeout") {
            guard timeoutIndex + 1 < arguments.count,
                  let parsed = TimeInterval(arguments[timeoutIndex + 1]) else {
                throw PlaylistParserError.invalidArguments
            }
            timeout = parsed
            arguments.removeSubrange(timeoutIndex...(timeoutIndex + 1))
        }

        if let sampleTimeIndex = arguments.firstIndex(of: "--sample-time") {
            guard sampleTimeIndex + 1 < arguments.count,
                  let parsed = Double(arguments[sampleTimeIndex + 1]) else {
                throw PlaylistParserError.invalidArguments
            }
            sampleTimeSeconds = parsed
            arguments.removeSubrange(sampleTimeIndex...(sampleTimeIndex + 1))
        }

        if let skipIndex = arguments.firstIndex(of: "--skip-playlist-text") {
            skipPlaylistText = true
            arguments.remove(at: skipIndex)
        }

        if let skipPixelBufferIndex = arguments.firstIndex(of: "--skip-pixel-buffer") {
            skipPixelBuffer = true
            arguments.remove(at: skipPixelBufferIndex)
        }

        if let verboseIndex = arguments.firstIndex(of: "--verbose") {
            verbose = true
            arguments.remove(at: verboseIndex)
        }

        guard arguments.count == 1 else {
            throw PlaylistParserError.invalidArguments
        }

        guard let url = URL(string: arguments[0]), url.scheme != nil else {
            throw PlaylistParserError.invalidURL(arguments[0])
        }

        return PlaylistParserOptions(
            playlistURL: url,
            mode: mode,
            timeout: timeout,
            sampleTimeSeconds: sampleTimeSeconds,
            skipPlaylistText: skipPlaylistText,
            skipPixelBuffer: skipPixelBuffer,
            verbose: verbose
        )
    }

    private static func inspectPlaylist(options: PlaylistParserOptions) async throws {
        printSection("Input")
        printField("URL", options.playlistURL.absoluteString)

        if !options.skipPlaylistText {
            printSection("Raw Playlist")
            let playlistText = try await fetchPlaylistText(from: options.playlistURL)
            print(playlistText)
        }

        let asset = AVURLAsset(url: options.playlistURL)
        let assetStart = Date()
        try await printAssetProperties(asset)
        printField("stage.assetMetadata.duration", formatStageDuration(since: assetStart))

        guard options.mode != .metadata else {
            printSection("Done")
            print("Metadata inspection complete.")
            return
        }

        let playerStart = Date()
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.pause()

        let status = await waitForPlayerItemReady(playerItem, timeout: options.timeout)
        guard status == .readyToPlay else {
            throw PlaylistParserError.playerItemNotReady(status, playerItem.error)
        }

        printPlayerItemProperties(playerItem)
        printPlayerItemTrackProperties(playerItem)
        printAccessAndErrorLogs(playerItem)
        printField("stage.playerPreparation.duration", formatStageDuration(since: playerStart))

        if options.mode == .frame && !options.skipPixelBuffer {
            let frameStart = Date()
            let pixelBuffer = try await extractPixelBuffer(
                from: playerItem,
                player: player,
                at: options.sampleTimeSeconds,
                timeout: options.timeout
            )
            printPixelBufferProperties(
                pixelBuffer,
                sampleTimeSeconds: options.sampleTimeSeconds,
                verbose: options.verbose
            )
            printField("stage.singleFrameDecode.duration", formatStageDuration(since: frameStart))
        }

        printSection("Done")
        print("Inspection complete.")
    }

    private static func fetchPlaylistText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("JoesProxy-playlist-parser/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                printField("HTTP status", http.statusCode)
                printField("Content-Type", http.value(forHTTPHeaderField: "Content-Type") ?? "(none)")
            }

            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            if let text = String(data: data, encoding: .isoLatin1) {
                return text
            }
            return data.map { String(format: "%02x", $0) }.joined(separator: " ")
        } catch {
            throw PlaylistParserError.playlistFetchFailed(error.localizedDescription)
        }
    }

    private static func printAssetProperties(_ asset: AVURLAsset) async throws {
        printSection("AVURLAsset")

        printField("url", asset.url.absoluteString)

        do {
            printField("isPlayable", try await asset.load(.isPlayable))
            printField("isExportable", try await asset.load(.isExportable))
            printField("hasProtectedContent", try await asset.load(.hasProtectedContent))
            printField("providesPreciseDurationAndTiming", try await asset.load(.providesPreciseDurationAndTiming))
            printField("preferredRate", try await asset.load(.preferredRate))
            printField("preferredVolume", try await asset.load(.preferredVolume))

            let duration = try await asset.load(.duration)
            printField("duration", formatTime(duration))

            let metadata = try await asset.load(.metadata)
            await printMetadataItems(metadata, label: "metadata")

            let metadataFormats = try await asset.load(.availableMetadataFormats)
            printField("availableMetadataFormats", metadataFormats)

            for format in metadataFormats {
                let formatMetadata = try await asset.loadMetadata(for: format)
                await printMetadataItems(formatMetadata, label: "metadata[\(format)]")
            }

            let characteristics = try await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)
            printField("availableMediaCharacteristicsWithMediaSelectionOptions", characteristics)

            await printMediaSelectionGroups(for: asset, characteristics: characteristics)

            let trackGroups = try await asset.load(.trackGroups)
            printField("trackGroups.count", trackGroups.count)
            for (index, group) in trackGroups.enumerated() {
                printField("trackGroups[\(index)].trackIDs", group.trackIDs)
            }

            if #available(macOS 12.0, *) {
                let variants = try await asset.load(.variants)
                printSection("AVAsset.variants")
                printField("count", variants.count)
                for (index, variant) in variants.enumerated() {
                    printVariant(variant, index: index)
                }
            }

            let tracks = try await asset.load(.tracks)
            printSection("AVAsset.tracks")
            printField("count", tracks.count)
            for (index, track) in tracks.enumerated() {
                try await printAssetTrack(track, index: index)
            }
        } catch {
            throw PlaylistParserError.assetInspectionFailed(error.localizedDescription)
        }
    }

    @available(macOS 12.0, *)
    private static func printVariant(_ variant: AVAssetVariant, index: Int) {
        printSubsection("variant[\(index)]")
        printField("peakBitRate", variant.peakBitRate ?? "nil")
        printField("averageBitRate", variant.averageBitRate ?? "nil")

        if let video = variant.videoAttributes {
            printField("video.videoRange", String(describing: video.videoRange))
            printField(
                "video.codecTypes",
                video.codecTypes.map { fourCCToString($0) }.joined(separator: ", ")
            )
            printField("video.presentationSize", formatSize(video.presentationSize))
            printField("video.nominalFrameRate", video.nominalFrameRate ?? "nil")
            printField("video.videoLayoutAttributes", String(describing: video.videoLayoutAttributes))
        } else {
            printField("videoAttributes", "nil")
        }

        if let audio = variant.audioAttributes {
            printField(
                "audio.formatIDs",
                audio.formatIDs.map { fourCCToString($0) }.joined(separator: ", ")
            )
        } else {
            printField("audioAttributes", "nil")
        }
    }

    private static func printMediaSelectionGroups(
        for asset: AVURLAsset,
        characteristics: [AVMediaCharacteristic]
    ) async {
        printSection("Media Selection Groups")

        for characteristic in characteristics {
            guard let group = try? await asset.loadMediaSelectionGroup(for: characteristic) else {
                printField(String(describing: characteristic), "nil")
                continue
            }

            printSubsection(String(describing: characteristic))
            printField("defaultOption.displayName", group.defaultOption?.displayName ?? "nil")
            printField("options.count", group.options.count)

            for (index, option) in group.options.enumerated() {
                printSubsection("option[\(index)]")
                printField("displayName", option.displayName)
                printField("mediaType", option.mediaType.rawValue)
                printField("locale", option.locale?.identifier ?? "nil")
                printField("isPlayable", option.isPlayable)
                printField("extendedLanguageTag", option.extendedLanguageTag ?? "nil")
                printField(
                    "mediaSubTypes",
                    option.mediaSubTypes.map { fourCCToString($0.uint32Value) }.joined(separator: ", ")
                )
                printField("availableMetadataFormats", option.availableMetadataFormats)

                let optionMetadata = option.commonMetadata
                if !optionMetadata.isEmpty {
                    await printMetadataItems(optionMetadata, label: "commonMetadata")
                }
            }
        }
    }

    private static func printAssetTrack(_ track: AVAssetTrack, index: Int) async throws {
        printSubsection("track[\(index)]")
        printField("mediaType", track.mediaType.rawValue)
        printField("trackID", track.trackID)
        printField("isEnabled", try await track.load(.isEnabled))
        printField("isPlayable", try await track.load(.isPlayable))
        printField("languageCode", try await track.load(.languageCode) ?? "nil")
        printField("naturalTimeScale", try await track.load(.naturalTimeScale))
        printField("nominalFrameRate", try await track.load(.nominalFrameRate))
        printField("estimatedDataRate", try await track.load(.estimatedDataRate))
        printField("totalSampleDataLength", try await track.load(.totalSampleDataLength))

        let timeRange = try await track.load(.timeRange)
        printField("timeRange.start", formatTime(timeRange.start))
        printField("timeRange.duration", formatTime(timeRange.duration))

        let naturalSize = try await track.load(.naturalSize)
        printField("naturalSize", formatSize(naturalSize))

        let preferredTransform = try await track.load(.preferredTransform)
        printField("preferredTransform", formatTransform(preferredTransform))

        let formatDescriptions = try await track.load(.formatDescriptions)
        printField("formatDescriptions.count", formatDescriptions.count)
        for (formatIndex, formatDescription) in formatDescriptions.enumerated() {
            let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
            printField("formatDescriptions[\(formatIndex)].mediaSubType", fourCCToString(subtype))
        }
    }

    private static func printPlayerItemProperties(_ item: AVPlayerItem) {
        printSection("AVPlayerItem")

        printField("status", item.status.rawValue)
        printField("status.name", playerItemStatusName(item.status))
        printField("error", item.error?.localizedDescription ?? "nil")
        printField("duration", formatTime(item.duration))
        printField("presentationSize", formatSize(item.presentationSize))
        printField("forwardPlaybackEndTime", formatTime(item.forwardPlaybackEndTime))
        printField("reversePlaybackEndTime", formatTime(item.reversePlaybackEndTime))
        printField("preferredForwardBufferDuration", item.preferredForwardBufferDuration)
        printField("preferredPeakBitRate", item.preferredPeakBitRate)
        printField("preferredMaximumResolution", formatSize(item.preferredMaximumResolution))
        printField("startsOnFirstEligibleVariant", item.startsOnFirstEligibleVariant)
        printField("automaticallyHandlesInterstitialEvents", item.automaticallyHandlesInterstitialEvents)
        printField("canPlayFastForward", item.canPlayFastForward)
        printField("canPlayReverse", item.canPlayReverse)
        printField("canPlaySlowForward", item.canPlaySlowForward)
        printField("canPlaySlowReverse", item.canPlaySlowReverse)
        printField("isPlaybackLikelyToKeepUp", item.isPlaybackLikelyToKeepUp)
        printField("isPlaybackBufferEmpty", item.isPlaybackBufferEmpty)
        printField("isPlaybackBufferFull", item.isPlaybackBufferFull)
        printField("loadedTimeRanges.count", item.loadedTimeRanges.count)
        printField("seekableTimeRanges.count", item.seekableTimeRanges.count)

        for (index, range) in item.loadedTimeRanges.enumerated() {
            let timeRange = range.timeRangeValue
            printField("loadedTimeRanges[\(index)]", "\(formatTime(timeRange.start)) + \(formatTime(timeRange.duration))")
        }

        for (index, range) in item.seekableTimeRanges.enumerated() {
            let timeRange = range.timeRangeValue
            printField("seekableTimeRanges[\(index)]", "\(formatTime(timeRange.start)) + \(formatTime(timeRange.duration))")
        }

        printField("timedMetadata", "Not sampled; use AVPlayerItemMetadataOutput during a bounded playback window")
    }

    private static func printPlayerItemTrackProperties(_ item: AVPlayerItem) {
        printSection("AVPlayerItem.tracks")
        printField("count", item.tracks.count)

        for (index, track) in item.tracks.enumerated() {
            printSubsection("track[\(index)]")
            printField("isEnabled", track.isEnabled)
            printField("assetTrack.trackID", track.assetTrack?.trackID ?? -1)
            printField("assetTrack.mediaType", track.assetTrack?.mediaType.rawValue ?? "nil")
        }
    }

    private static func printAccessAndErrorLogs(_ item: AVPlayerItem) {
        printSection("AVPlayerItem Logs")

        if let accessLog = item.accessLog() {
            printField("accessLog.events.count", accessLog.events.count)
            for (index, event) in accessLog.events.enumerated() {
                printSubsection("accessLog.events[\(index)]")
                printField("uri", event.uri ?? "nil")
                printField("serverAddress", event.serverAddress ?? "nil")
                printField("playbackStartDate", event.playbackStartDate?.description ?? "nil")
                printField("durationWatched", event.durationWatched)
                printField("numberOfMediaRequests", event.numberOfMediaRequests)
                printField("observedBitrate", event.observedBitrate)
                printField("indicatedBitrate", event.indicatedBitrate)
                printField("numberOfStalls", event.numberOfStalls)
            }
        } else {
            printField("accessLog", "nil")
        }

        if let errorLog = item.errorLog() {
            printField("errorLog.events.count", errorLog.events.count)
            for (index, event) in errorLog.events.enumerated() {
                printSubsection("errorLog.events[\(index)]")
                printField("errorDomain", event.errorDomain)
                printField("errorStatusCode", event.errorStatusCode)
                printField("errorComment", event.errorComment ?? "nil")
                printField("uri", event.uri ?? "nil")
                printField("serverAddress", event.serverAddress ?? "nil")
            }
        } else {
            printField("errorLog", "nil")
        }
    }

    private static func extractPixelBuffer(
        from playerItem: AVPlayerItem,
        player: AVPlayer,
        at sampleTimeSeconds: Double,
        timeout: TimeInterval
    ) async throws -> CVPixelBuffer {
        printSection("CVPixelBuffer Extraction")
        printField("sampleTimeSeconds", sampleTimeSeconds)
        printField("method", "AVPlayerItemVideoOutput.copyPixelBuffer")

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        printField("requestedPixelBufferAttributes", pixelBufferAttributes)

        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBufferAttributes)
        playerItem.add(videoOutput)

        let targetTime = CMTime(seconds: sampleTimeSeconds, preferredTimescale: 600)
        _ = await player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let itemTime = playerItem.currentTime()
            if videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
               let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                player.pause()
                printField("decodedItemTime", formatTime(itemTime))
                return pixelBuffer
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        player.pause()
        throw PlaylistParserError.pixelBufferExtractionFailed(
            "Timed out after \(timeout)s waiting for AVPlayerItemVideoOutput to produce a frame."
        )
    }

    private static func printPixelBufferProperties(
        _ pixelBuffer: CVPixelBuffer,
        sampleTimeSeconds: Double,
        verbose: Bool
    ) {
        printSection("CVPixelBuffer")
        printField("sampleTimeSeconds", sampleTimeSeconds)
        printField("typeID", CVPixelBufferGetTypeID())
        if verbose {
            printField("retainCount", CFGetRetainCount(pixelBuffer))
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        printField("width", width)
        printField("height", height)
        printField("pixelFormat", "0x\(String(pixelFormat, radix: 16)) (\(fourCCToString(pixelFormat)))")
        printField("bytesPerRow", CVPixelBufferGetBytesPerRow(pixelBuffer))
        printField("dataSize", CVPixelBufferGetDataSize(pixelBuffer))
        printField("isPlanar", CVPixelBufferIsPlanar(pixelBuffer))
        printField("planeCount", CVPixelBufferGetPlaneCount(pixelBuffer))

        var extendedTop: Int = 0
        var extendedBottom: Int = 0
        var extendedLeft: Int = 0
        var extendedRight: Int = 0
        CVPixelBufferGetExtendedPixels(
            pixelBuffer,
            &extendedLeft,
            &extendedRight,
            &extendedTop,
            &extendedBottom
        )
        printField("extendedPixels.top", extendedTop)
        printField("extendedPixels.bottom", extendedBottom)
        printField("extendedPixels.left", extendedLeft)
        printField("extendedPixels.right", extendedRight)

        if CVPixelBufferIsPlanar(pixelBuffer) {
            for planeIndex in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                printSubsection("plane[\(planeIndex)]")
                printField("width", CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex))
                printField("height", CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex))
                printField("bytesPerRow", CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex))
                if verbose {
                    printField("baseAddress", formatPointer(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex)))
                }
            }
        } else {
            if verbose {
                printField("baseAddress", formatPointer(CVPixelBufferGetBaseAddress(pixelBuffer)))
            }
        }

        printField("baseAddressLockedReadable", isPixelBufferBaseAddressReadable(pixelBuffer))

        printPixelFormatDescription(for: pixelFormat)
        printPixelBufferAttachments(pixelBuffer)
        printIOSurfaceProperties(for: pixelBuffer, verbose: verbose)
    }

    private static func isPixelBufferBaseAddressReadable(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let lockFlags = CVPixelBufferLockFlags.readOnly
        guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags) }

        if CVPixelBufferIsPlanar(pixelBuffer) {
            for planeIndex in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                if CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex) != nil {
                    return true
                }
            }
            return false
        }
        return CVPixelBufferGetBaseAddress(pixelBuffer) != nil
    }

    private static func printPixelFormatDescription(for pixelFormat: OSType) {
        printSection("CVPixelFormatDescription")

        guard let description = CVPixelFormatDescriptionCreateWithPixelFormatType(
            kCFAllocatorDefault,
            pixelFormat
        ) as? [String: Any] else {
            printField("description", "unavailable")
            return
        }

        for key in description.keys.sorted() {
            printField(key, formatPropertyValue(description[key]))
        }
    }

    private static func printPixelBufferAttachments(_ pixelBuffer: CVPixelBuffer) {
        printSection("CVPixelBuffer Attachments")

        printAttachmentGroup(pixelBuffer, mode: .shouldPropagate, label: "shouldPropagate")
        printAttachmentGroup(pixelBuffer, mode: .shouldNotPropagate, label: "shouldNotPropagate")

        let knownAttachmentKeys: [(CFString, String)] = [
            (kCVImageBufferColorPrimariesKey, "ColorPrimaries"),
            (kCVImageBufferTransferFunctionKey, "TransferFunction"),
            (kCVImageBufferYCbCrMatrixKey, "YCbCrMatrix"),
            (kCVImageBufferChromaLocationTopFieldKey, "ChromaLocationTopField"),
            (kCVImageBufferChromaLocationBottomFieldKey, "ChromaLocationBottomField"),
            (kCVImageBufferFieldCountKey, "FieldCount"),
            (kCVImageBufferFieldDetailKey, "FieldDetail"),
            (kCVImageBufferPixelAspectRatioKey, "PixelAspectRatio"),
            (kCVImageBufferCleanApertureKey, "CleanAperture"),
            (kCVImageBufferDisplayDimensionsKey, "DisplayDimensions"),
            (kCVImageBufferGammaLevelKey, "GammaLevel"),
            (kCVImageBufferICCProfileKey, "ICCProfile"),
            (kCVImageBufferCGColorSpaceKey, "CGColorSpace"),
            (kCVImageBufferAlphaChannelModeKey, "AlphaChannelMode"),
            (kCVImageBufferAmbientViewingEnvironmentKey, "AmbientViewingEnvironment"),
            (kCVImageBufferContentLightLevelInfoKey, "ContentLightLevelInfo"),
            (kCVImageBufferMasteringDisplayColorVolumeKey, "MasteringDisplayColorVolume")
        ]

        printSubsection("knownAttachmentKeys")
        for (key, label) in knownAttachmentKeys {
            if let value = CVBufferCopyAttachment(pixelBuffer, key, nil) {
                printField(label, formatPropertyValue(value))
            } else {
                printField(label, "nil")
            }
        }
    }

    private static func printAttachmentGroup(
        _ pixelBuffer: CVPixelBuffer,
        mode: CVAttachmentMode,
        label: String
    ) {
        printSubsection(label)
        guard let attachments = CVBufferCopyAttachments(pixelBuffer, mode) as? [String: Any] else {
            printField("count", 0)
            return
        }

        printField("count", attachments.count)
        for key in attachments.keys.sorted() {
            printField(key, formatPropertyValue(attachments[key]))
        }
    }

    private static func printIOSurfaceProperties(for pixelBuffer: CVPixelBuffer, verbose: Bool) {
        printSection("IOSurface")

        guard let ioSurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            printField("backing", "none (CVPixelBufferGetIOSurface returned nil)")
            return
        }

        printField("width", IOSurfaceGetWidth(ioSurface))
        printField("height", IOSurfaceGetHeight(ioSurface))
        printField("bytesPerElement", IOSurfaceGetBytesPerElement(ioSurface))
        printField("bytesPerRow", IOSurfaceGetBytesPerRow(ioSurface))
        printField("allocSize", IOSurfaceGetAllocSize(ioSurface))
        printField(
            "pixelFormat",
            "0x\(String(IOSurfaceGetPixelFormat(ioSurface), radix: 16)) (\(fourCCToString(IOSurfaceGetPixelFormat(ioSurface))))"
        )
        if verbose {
            printField("seed", IOSurfaceGetSeed(ioSurface))
            printField("id", IOSurfaceGetID(ioSurface))
            printField("useCount", IOSurfaceGetUseCount(ioSurface))
            printField("isInUse", IOSurfaceIsInUse(ioSurface))
            printField("baseAddress", formatPointer(IOSurfaceGetBaseAddress(ioSurface)))
        }

        printSubsection("IOSurfaceCopyValues")
        if let values = IOSurfaceCopyAllValues(ioSurface) as? [String: Any] {
            printField("count", values.count)
            for key in values.keys.sorted() {
                printField(key, formatPropertyValue(values[key]))
            }
        } else {
            printField("count", 0)
        }
    }

    private static func formatPointer(_ pointer: UnsafeMutableRawPointer?) -> String {
        guard let pointer else {
            return "nil"
        }
        return String(format: "%p", Int(bitPattern: pointer))
    }

    private static func formatPropertyValue(_ value: Any?) -> String {
        guard let value else {
            return "nil"
        }

        switch value {
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return string
        case let data as Data:
            return "Data(\(data.count) bytes)"
        case let array as [Any]:
            return array.map { formatPropertyValue($0) }.joined(separator: ", ")
        case let dictionary as [String: Any]:
            let pairs = dictionary.keys.sorted().map { key in
                "\(key)=\(formatPropertyValue(dictionary[key]))"
            }
            return "{\(pairs.joined(separator: ", "))}"
        case let dictionary as [AnyHashable: Any]:
            let pairs = dictionary.keys.map { key in
                "\(String(describing: key))=\(formatPropertyValue(dictionary[key]))"
            }.sorted()
            return "{\(pairs.joined(separator: ", "))}"
        default:
            return String(describing: value)
        }
    }

    private static func waitForPlayerItemReady(
        _ item: AVPlayerItem,
        timeout: TimeInterval
    ) async -> AVPlayerItem.Status {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if item.status != .unknown {
                return item.status
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return item.status
    }

    private static func printMetadataItems(_ items: [AVMetadataItem], label: String) async {
        printSubsection(label)
        printField("count", items.count)
        for (index, item) in items.enumerated() {
            let key = item.key as? String ?? item.commonKey?.rawValue ?? "unknown"
            let stringValue = try? await item.load(.stringValue)
            let loadedValue = try? await item.load(.value)
            let value = stringValue ?? loadedValue.map { String(describing: $0) } ?? "nil"
            printField("[\(index)].\(key)", value)
        }
    }

    private static func formatStageDuration(since start: Date) -> String {
        String(format: "%.3fs", Date().timeIntervalSince(start))
    }

    private static func printSection(_ title: String) {
        print()
        print("=== \(title) ===")
    }

    private static func printSubsection(_ title: String) {
        print()
        print("-- \(title) --")
    }

    private static func printField(_ label: String, _ value: Any) {
        print("\(label): \(value)")
    }

    private static func formatTime(_ time: CMTime) -> String {
        guard time.isValid, !time.isIndefinite else {
            return "invalid"
        }
        return String(format: "%.3fs", time.seconds)
    }

    private static func formatSize(_ size: CGSize) -> String {
        String(format: "%.0fx%.0f", size.width, size.height)
    }

    private static func formatTransform(_ transform: CGAffineTransform) -> String {
        String(
            format: "[a=%.3f b=%.3f c=%.3f d=%.3f tx=%.3f ty=%.3f]",
            transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty
        )
    }

    private static func playerItemStatusName(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .readyToPlay:
            return "readyToPlay"
        case .failed:
            return "failed"
        @unknown default:
            return "unknown-default"
        }
    }

    private static func fourCCToString(_ value: FourCharCode) -> String {
        let chars: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: chars, encoding: .ascii) ?? "?\(value)"
    }
}

Task {
    await PlaylistParser.run()
    exit(0)
}
dispatchMain()
