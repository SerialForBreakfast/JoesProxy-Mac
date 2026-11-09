//
//  AVAssetMetadata.swift
//  JoesProxy
//
//  Models for explicit, per-item AVFoundation media inspection.
//

import CoreGraphics
import Foundation

enum AVMediaInspectionSource: String, CaseIterable, Identifiable, Sendable {
    case capturedItem
    case liveURL

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capturedItem: return "Captured Item"
        case .liveURL: return "Live URL"
        }
    }

    var provenance: MediaInspectionProvenance {
        switch self {
        case .capturedItem: return .capturedResponse
        case .liveURL: return .liveSystemProbe
        }
    }
}

struct AVMediaInspectionEligibility: Equatable, Sendable {
    let capturedItemAvailable: Bool
    let capturedItemReason: String?
    let liveURLAvailable: Bool
    let liveURLReason: String?
    let containsSensitiveRequestHeaders: Bool
    let containsSensitiveURLQuery: Bool

    var containsSensitiveRequestData: Bool {
        containsSensitiveRequestHeaders || containsSensitiveURLQuery
    }

    var availableSources: [AVMediaInspectionSource] {
        AVMediaInspectionSource.allCases.filter {
            switch $0 {
            case .capturedItem: return capturedItemAvailable
            case .liveURL: return liveURLAvailable
            }
        }
    }

    static func evaluate(session: SessionRecord) -> AVMediaInspectionEligibility {
        let mediaType = MediaDetector.mediaType(for: session)
        let response = session.response
        let capturedReason: String?

        if mediaType == .hls || mediaType == .hlsDiscovery || mediaType == .dash {
            capturedReason = "Captured manifests use JoesProxy's manifest parser; local media-engine decoding requires a selected segment or media file."
        } else if response?.bodyDeferred == true {
            capturedReason = "The captured body is still loading."
        } else if response?.bodyTruncated == true {
            capturedReason = "The captured body is truncated and cannot be decoded reliably."
        } else if response?.recordingBodyOmissionReason != nil {
            capturedReason = "The recording does not contain this response body."
        } else if response?.bodyData?.isEmpty != false {
            capturedReason = "No captured response body is available."
        } else if case .video = mediaType {
            capturedReason = nil
        } else {
            capturedReason = "The selected response is not a supported self-contained media item."
        }

        let liveURL = MediaDetector.primaryMediaURL(for: session)
        let sensitiveNames = Set(["authorization", "cookie", "proxy-authorization", "x-api-key"])
        let hasSensitiveHeaders = session.request.headers.contains {
            sensitiveNames.contains($0.name.lowercased())
        }
        let sensitiveQueryNames = ["token", "access_token", "auth", "authorization", "signature", "sig", "key"]
        let hasSensitiveQuery = liveURL
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            .map { items in
                items.contains { item in
                    sensitiveQueryNames.contains(item.name.lowercased())
                }
            } ?? false

        return AVMediaInspectionEligibility(
            capturedItemAvailable: capturedReason == nil,
            capturedItemReason: capturedReason,
            liveURLAvailable: liveURL != nil && mediaType.isVideoOrStream,
            liveURLReason: liveURL == nil ? "The selected request does not have a usable media URL." : nil,
            containsSensitiveRequestHeaders: hasSensitiveHeaders,
            containsSensitiveURLQuery: hasSensitiveQuery
        )
    }
}

struct AVMediaInspectionInput: Sendable {
    let source: AVMediaInspectionSource
    let url: URL?
    let capturedData: Data?
    let capturedFileExtension: String?
    let displayName: String
    let sampleTime: TimeInterval
    let initialWarnings: [String]
    let capturedResponse: CapturedResponse?

    init(source: AVMediaInspectionSource, url: URL?, capturedData: Data?,
         capturedFileExtension: String?, displayName: String, sampleTime: TimeInterval,
         initialWarnings: [String], capturedResponse: CapturedResponse? = nil) {
        self.source = source
        self.url = url
        self.capturedData = capturedData
        self.capturedFileExtension = capturedFileExtension
        self.displayName = displayName
        self.sampleTime = sampleTime
        self.initialWarnings = initialWarnings
        self.capturedResponse = capturedResponse
    }
}

struct AVMediaInspectionReport: Sendable {
    let source: AVMediaInspectionSource
    let sourceDescription: String
    let isPartial: Bool
    let asset: AVMediaAssetSummary?
    let variants: [AVMediaVariantInfo]
    let videoTracks: [VideoTrackInfo]
    let audioTracks: [AudioTrackInfo]
    let subtitleTracks: [SubtitleTrackInfo]
    let mediaSelectionGroups: [AVMediaSelectionGroupInfo]
    let player: AVMediaPlayerSummary?
    let decodedFrame: AVDecodedFrameInfo?
    let accessEvents: [AVMediaAccessEvent]
    let errors: [AVMediaProbeError]
    let stages: [AVMediaInspectionStageResult]
    let warnings: [String]
}

struct AVMediaAssetSummary: Sendable {
    let duration: TimeInterval?
    let isPlayable: Bool
    let isExportable: Bool
    let hasProtectedContent: Bool
    let providesPreciseDurationAndTiming: Bool
}

struct AVMediaVariantInfo: Identifiable, Sendable {
    let id: Int
    let playlistURL: String?
    let peakBitRate: Double?
    let averageBitRate: Double?
    let videoRange: String?
    let videoCodecs: [String]
    let presentationWidth: Int?
    let presentationHeight: Int?
    let nominalFrameRate: Double?
    let audioFormats: [String]
}

struct VideoTrackInfo: Sendable {
    let width: Int
    let height: Int
    let estimatedDataRate: Float
    let nominalFrameRate: Float
    let codec: String?
}

struct AudioTrackInfo: Sendable {
    let channels: Int?
    let sampleRate: Float?
    let language: String?
    let codec: String?
}

struct SubtitleTrackInfo: Sendable {
    let language: String?
    let displayName: String?
}

struct AVMediaSelectionGroupInfo: Identifiable, Sendable {
    let id: String
    let characteristic: String
    let defaultOption: String?
    let options: [AVMediaSelectionOptionInfo]
}

struct AVMediaSelectionOptionInfo: Identifiable, Sendable {
    let id: Int
    let displayName: String
    let mediaType: String
    let language: String?
    let isPlayable: Bool
}

struct AVMediaPlayerSummary: Sendable {
    let status: String
    let presentationWidth: Int
    let presentationHeight: Int
    let isPlaybackLikelyToKeepUp: Bool
    let isPlaybackBufferEmpty: Bool
    let isPlaybackBufferFull: Bool
    let loadedTimeRanges: [AVMediaTimeRangeInfo]
    let seekableTimeRanges: [AVMediaTimeRangeInfo]
}

struct AVMediaTimeRangeInfo: Identifiable, Sendable {
    let id: Int
    let start: TimeInterval
    let duration: TimeInterval
}

struct AVDecodedFrameInfo: Sendable {
    let requestedTime: TimeInterval
    let decodedTime: TimeInterval
    let width: Int
    let height: Int
    let pixelFormat: String
    let isPlanar: Bool
    let planeCount: Int
    let bytesPerRow: Int
    let estimatedByteSize: Int
    let planes: [AVPixelPlaneInfo]
    let attachments: [String: String]
    let isMetalCompatible: Bool
    let hasIOSurface: Bool
    let ioSurfaceWidth: Int?
    let ioSurfaceHeight: Int?
    let ioSurfaceBytesPerRow: Int?
    let ioSurfaceAllocationSize: Int?
}

struct AVPixelPlaneInfo: Identifiable, Sendable {
    let id: Int
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

struct AVMediaAccessEvent: Identifiable, Sendable {
    let id: Int
    let resource: String?
    let mediaRequestCount: Int
    let observedBitRate: Double
    let indicatedBitRate: Double
    let stalls: Int
    let transferredBytes: Int64
}

struct AVMediaProbeError: Identifiable, Sendable {
    let id: Int
    let domain: String
    let statusCode: Int
    let comment: String?
    let resource: String?
}

struct AVMediaInspectionStageResult: Identifiable, Sendable {
    enum Outcome: String, Sendable {
        case completed
        case failed
        case timedOut
        case cancelled
        case skipped
    }

    let id: String
    let title: String
    let duration: TimeInterval
    let outcome: Outcome
    let message: String?
}
