//
//  WebVTTModels.swift
//  JoesProxy
//
//  Domain models for WebVTT subtitle and closed caption parsing,
//  sync drift calculation, and track defect validation.
//

import Foundation

/// Individual WebVTT subtitle or closed caption cue.
struct WebVTTCue: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var cueIdentifier: String?
    var startTimeSeconds: Double
    var endTimeSeconds: Double
    var settings: String?
    var text: String
    var lines: [String]

    var durationSeconds: Double {
        max(0.0, endTimeSeconds - startTimeSeconds)
    }

    var maxLineLength: Int {
        lines.map(\.count).max() ?? text.count
    }

    var startTimeString: String {
        formatTimestamp(startTimeSeconds)
    }

    var endTimeString: String {
        formatTimestamp(endTimeSeconds)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let totalMs = Int((seconds * 1000).rounded())
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let s = totalSec % 60
        let totalMin = totalSec / 60
        let m = totalMin % 60
        let h = totalMin / 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
        } else {
            return String(format: "%02d:%02d.%03d", m, s, ms)
        }
    }
}

/// Parsed WebVTT header block.
struct WebVTTHeader: Codable, Equatable, Sendable {
    var rawHeader: String
    var mpegtsOffset: Int?
    var localOffsetSeconds: Double?
    var regionDefinitions: [String] = []
    var styleBlocks: [String] = []
}

/// Specific subtitle or closed caption defect identified during validation.
enum WebVTTDefect: Codable, Equatable, Sendable {
    case overlappingCues(cueIndexA: Int, cueIndexB: Int, overlapMs: Double)
    case zeroOrNegativeDuration(cueIndex: Int, durationMs: Double)
    case excessiveDuration(cueIndex: Int, durationSeconds: Double)
    case excessiveLineLength(cueIndex: Int, maxChars: Int, limit: Int)
    case excessiveLineCount(cueIndex: Int, count: Int, limit: Int)
    case unclosedOrMalformedTag(cueIndex: Int, tag: String)
    case characterEncodingIssue(cueIndex: Int, snippet: String)
    case emptyCuePayload(cueIndex: Int)
    case missingTimestampMapHeader
    case syncDriftFromVideo(driftMs: Double, expectedPtsSeconds: Double, actualCueStartSeconds: Double)

    var userFacingMessage: String {
        switch self {
        case .overlappingCues(let a, let b, let overlapMs):
            return "Overlapping cues: cue #\(a + 1) and cue #\(b + 1) overlap by \(String(format: "%.0fms", overlapMs)), causing visual flicker."
        case .zeroOrNegativeDuration(let idx, let ms):
            return "Invalid duration at cue #\(idx + 1): non-positive duration (\(String(format: "%.0fms", ms)))."
        case .excessiveDuration(let idx, let dur):
            return "Excessive cue duration at cue #\(idx + 1): displayed for \(String(format: "%.1fs", dur)) (standard maximum is 8.0s)."
        case .excessiveLineLength(let idx, let len, let limit):
            return "Broadcast line length violation at cue #\(idx + 1): line contains \(len) characters (CTA-608/708 limit is \(limit))."
        case .excessiveLineCount(let idx, let count, let limit):
            return "Excessive line count at cue #\(idx + 1): cue contains \(count) lines (recommended limit is \(limit) lines)."
        case .unclosedOrMalformedTag(let idx, let tag):
            return "Malformed or unclosed tag at cue #\(idx + 1): '\(tag)'."
        case .characterEncodingIssue(let idx, let snippet):
            return "Character encoding defect (mojibake) at cue #\(idx + 1): '\(snippet)'."
        case .emptyCuePayload(let idx):
            return "Empty cue text payload at cue #\(idx + 1)."
        case .missingTimestampMapHeader:
            return "Missing X-TIMESTAMP-MAP header in HLS WebVTT segment (required for MPEG-TS PTS alignment)."
        case .syncDriftFromVideo(let driftMs, let expected, let actual):
            return "Subtitle sync drift: cue starts at \(String(format: "%.2fs", actual)) vs expected video PTS \(String(format: "%.2fs", expected)) (\(String(format: "%+.0fms", driftMs)) offset)."
        }
    }

    var isCritical: Bool {
        switch self {
        case .overlappingCues, .zeroOrNegativeDuration, .unclosedOrMalformedTag, .characterEncodingIssue, .syncDriftFromVideo:
            return true
        case .excessiveDuration, .excessiveLineLength, .excessiveLineCount, .emptyCuePayload, .missingTimestampMapHeader:
            return false
        }
    }
}

/// Comprehensive inspection report for a WebVTT track.
struct WebVTTTrackReport: Codable, Equatable, Sendable {
    var cueCount: Int
    var totalDurationSeconds: Double
    var header: WebVTTHeader
    var hasTimestampMap: Bool
    var mpegtsOffsetPTS: Int?
    var syncDriftMs: Double?
    var defects: [WebVTTDefect]
    var cues: [WebVTTCue]
    var qualityScore: Double // 0 to 100
    var isSyncSafe: Bool

    var criticalDefectsCount: Int {
        defects.filter(\.isCritical).count
    }
}
