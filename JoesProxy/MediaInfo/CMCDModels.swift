//
//  CMCDModels.swift
//  JoesProxy
//
//  Domain models for CTA-5004 Common Media Client Data (CMCD)
//  and CTA-5006 Common Media Server Data (CMSD) telemetry validation.
//

import Foundation

/// Object types defined in CTA-5004 (`ot` parameter).
enum CMCDObjectType: String, Codable, Sendable, CaseIterable {
    case muxed = "m"
    case video = "v"
    case audio = "a"
    case caption = "c"
    case timedText = "tt"
    case key = "k"
    case initSegment = "i"
    case other = "o"

    var title: String {
        switch self {
        case .muxed: return "Muxed (Audio+Video)"
        case .video: return "Video Only"
        case .audio: return "Audio Only"
        case .caption: return "Closed Caption"
        case .timedText: return "Timed Text / Subtitle"
        case .key: return "DRM License / Key"
        case .initSegment: return "Initialization Segment"
        case .other: return "Other"
        }
    }
}

/// Streaming formats defined in CTA-5004 (`sf` parameter).
enum CMCDStreamingFormat: String, Codable, Sendable, CaseIterable {
    case dash = "d"
    case hls = "h"
    case smooth = "s"
    case other = "o"

    var title: String {
        switch self {
        case .dash: return "DASH"
        case .hls: return "HLS"
        case .smooth: return "Smooth Streaming"
        case .other: return "Other"
        }
    }
}

/// Stream types defined in CTA-5004 (`st` parameter).
enum CMCDStreamType: String, Codable, Sendable, CaseIterable {
    case vod = "v"
    case live = "l"

    var title: String {
        switch self {
        case .vod: return "VOD"
        case .live: return "Live Stream"
        }
    }
}

/// Transport mode used by the player to convey CMCD data.
enum CMCDTransportMethod: String, Codable, Sendable {
    case header = "Custom HTTP Headers"
    case queryString = "URL Query Parameter"
    case mixed = "Headers and Query Parameters"
}

/// Parsed CTA-5004 client telemetry parameters.
struct CMCDTelemetry: Codable, Equatable, Sendable {
    var encodedBitrateKbps: Int?         // br
    var objectDurationMs: Int?           // d
    var objectType: CMCDObjectType?      // ot
    var topBitrateKbps: Int?             // tb
    var bufferLengthMs: Int?             // bl
    var deadlineMs: Int?                 // dl
    var measuredThroughputKbps: Int?     // mtp
    var requestedThroughputKbps: Int?    // rtp
    var bufferStarvation: Bool?          // bs
    var isStartup: Bool?                 // su
    var nextObjectRequest: String?       // nor
    var nextRangeRequest: String?        // nrr
    var sessionID: String?               // sid
    var contentID: String?               // cid
    var playbackRate: Double?            // pr
    var streamingFormat: CMCDStreamingFormat? // sf
    var streamType: CMCDStreamType?      // st
    var version: Int?                    // v
    var rawCustomKeys: [String: String] = [:]

    var isEmpty: Bool {
        encodedBitrateKbps == nil &&
        objectDurationMs == nil &&
        objectType == nil &&
        topBitrateKbps == nil &&
        bufferLengthMs == nil &&
        deadlineMs == nil &&
        measuredThroughputKbps == nil &&
        requestedThroughputKbps == nil &&
        bufferStarvation == nil &&
        isStartup == nil &&
        sessionID == nil &&
        contentID == nil &&
        rawCustomKeys.isEmpty
    }
}

/// Parsed CTA-5006 server telemetry parameters.
struct CMSDTelemetry: Codable, Equatable, Sendable {
    var estimatedThroughputKbps: Int?    // etp
    var responseDelayMs: Int?            // rd
    var roundTripTimeMs: Int?            // rtt
    var maxBitrateKbps: Int?             // mb
    var rawCustomKeys: [String: String] = [:]

    var isEmpty: Bool {
        estimatedThroughputKbps == nil &&
        responseDelayMs == nil &&
        roundTripTimeMs == nil &&
        maxBitrateKbps == nil &&
        rawCustomKeys.isEmpty
    }
}

/// Specific QoE anomaly or telemetry fault detected on a media request.
enum CMCDQoEAnomaly: Codable, Equatable, Sendable {
    case criticalBufferDrop(bufferLengthMs: Int, thresholdMs: Int)
    case throughputUnderflow(measuredThroughputKbps: Int, requestedBitrateKbps: Int)
    case playbackStarvationReported
    case deadlineMissed(deadlineMs: Int, actualDownloadTimeMs: Int)
    case malformedTelemetryParameter(key: String, reason: String)
    case missingRequiredTelemetry(keys: [String])

    var userFacingMessage: String {
        switch self {
        case .criticalBufferDrop(let bl, let threshold):
            return "Critical buffer drop: player buffer is \(String(format: "%.1fs", Double(bl) / 1000.0)) (below \(String(format: "%.1fs", Double(threshold) / 1000.0)) safety threshold)."
        case .throughputUnderflow(let mtp, let br):
            return "Throughput underflow: measured throughput (\(mtp) kbps) is less than requested segment bitrate (\(br) kbps), risking buffer starvation."
        case .playbackStarvationReported:
            return "Playback starvation: player reported active buffer underrun/stall (bs=true)."
        case .deadlineMissed(let dl, let actual):
            return "Deadline missed: segment download took \(actual)ms exceeding client decoding deadline (\(dl)ms)."
        case .malformedTelemetryParameter(let key, let reason):
            return "Malformed telemetry parameter '\(key)': \(reason)."
        case .missingRequiredTelemetry(let keys):
            return "Missing recommended CMCD parameters: \(keys.joined(separator: ", "))."
        }
    }

    var isCritical: Bool {
        switch self {
        case .criticalBufferDrop, .throughputUnderflow, .playbackStarvationReported, .deadlineMissed:
            return true
        case .malformedTelemetryParameter, .missingRequiredTelemetry:
            return false
        }
    }
}

/// Audit report for a single session carrying CMCD or CMSD telemetry.
struct CMCDSessionReport: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var requestPath: String
    var transportMethod: CMCDTransportMethod
    var cmcd: CMCDTelemetry
    var cmsd: CMSDTelemetry?
    var anomalies: [CMCDQoEAnomaly]
    var healthScore: Double // 0.0 (critical failure) to 100.0 (optimal health)

    var throughputHeadroomPercentage: Double? {
        guard let mtp = cmcd.measuredThroughputKbps, let br = cmcd.encodedBitrateKbps, br > 0 else {
            return nil
        }
        let diff = Double(mtp - br)
        return (diff / Double(br)) * 100.0
    }
}
