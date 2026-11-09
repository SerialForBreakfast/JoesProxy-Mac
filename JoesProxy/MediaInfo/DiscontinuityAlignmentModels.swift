//
//  DiscontinuityAlignmentModels.swift
//  JoesProxy
//
//  Domain models for SCTE-35 ad break alignment, multi-rendition discontinuity parity,
//  multiplexed AV sync drift, and accumulated timeline drift.
//

import Foundation

/// Specific playback or switching hazard detected during multi-rendition and discontinuity analysis.
enum RenditionAlignmentHazard: Codable, Equatable, Sendable {
    case discontinuityTagMismatch(renditionA: String, indexA: Int, renditionB: String, indexB: Int)
    case missingDiscontinuityTag(rendition: String, expectedTimeSeconds: Double)
    case segmentDurationDrift(renditionA: String, renditionB: String, segmentIndex: Int, driftMs: Double)
    case accumulatedTimelineDrift(rendition: String, totalDriftMs: Double, segmentCount: Int)
    case audioLayoutMismatchAcrossAdBoundary(beforeLayout: String, adLayout: String, offsetSeconds: Double)
    case multiplexedAudioVideoPTSDrift(avDriftMs: Double, segmentURI: String)

    var userFacingMessage: String {
        switch self {
        case .discontinuityTagMismatch(let rA, let idxA, let rB, let idxB):
            return "Discontinuity mismatch: '\(rA)' has tag at segment \(idxA), but '\(rB)' has tag at segment \(idxB)."
        case .missingDiscontinuityTag(let rendition, let expectedTime):
            return "Missing discontinuity tag in '\(rendition)' near timestamp \(String(format: "%.2fs", expectedTime))."
        case .segmentDurationDrift(let rA, let rB, let idx, let driftMs):
            return "Segment boundary duration drift between '\(rA)' and '\(rB)' at segment \(idx): \(String(format: "%.1fms", driftMs))."
        case .accumulatedTimelineDrift(let rendition, let totalDrift, let count):
            return "Accumulated timeline drift in '\(rendition)': \(String(format: "%.1fms", totalDrift)) across \(count) segments."
        case .audioLayoutMismatchAcrossAdBoundary(let before, let ad, let offset):
            return "Audio channel layout jump at \(String(format: "%.1fs", offset)): content (\(before)) transitioned to ad (\(ad)) without track signaling."
        case .multiplexedAudioVideoPTSDrift(let drift, let uri):
            return "Multiplexed AV PTS sync drift in '\(uri)': audio leads/lags video by \(String(format: "%.1fms", drift))."
        }
    }

    var isCriticalSwitchingHazard: Bool {
        switch self {
        case .discontinuityTagMismatch, .missingDiscontinuityTag:
            return true
        case .segmentDurationDrift(_, _, _, let driftMs):
            return driftMs > 100.0
        case .accumulatedTimelineDrift(_, let totalDrift, _):
            return totalDrift > 500.0
        case .audioLayoutMismatchAcrossAdBoundary:
            return true
        case .multiplexedAudioVideoPTSDrift(let drift, _):
            return drift > 80.0
        }
    }
}

/// SCTE-35 / SSAI ad break boundary report.
struct AdBreakAlignmentReport: Identifiable, Codable, Equatable, Sendable {
    var id: String { adBreakID }
    let adBreakID: String
    let startTimeSeconds: Double
    let durationSeconds: Double
    let scte35Payload: String?
    let hasDiscontinuityTag: Bool
    let channelLayoutBefore: String?
    let channelLayoutDuringAd: String?
    let timelineGapMs: Double
    let hazards: [RenditionAlignmentHazard]
}

/// Variant rendition timeline alignment summary.
struct VariantRenditionSummary: Identifiable, Codable, Equatable, Sendable {
    var id: String { uri }
    let uri: String
    let bandwidth: Int?
    let resolution: String?
    let segmentCount: Int
    let discontinuityCount: Int
    let totalDurationSeconds: Double
    let accumulatedDriftMs: Double
}

/// Full multi-rendition stream alignment report.
struct MultiRenditionAlignmentReport: Codable, Equatable, Sendable {
    let masterURI: String
    let variantCount: Int
    let isMultiplexed: Bool
    let audioTrackCount: Int
    let subtitleTrackCount: Int
    let isSwitchingSafe: Bool
    let totalAccumulatedDriftMs: Double
    let variants: [VariantRenditionSummary]
    let adBreaks: [AdBreakAlignmentReport]
    let hazards: [RenditionAlignmentHazard]
}
