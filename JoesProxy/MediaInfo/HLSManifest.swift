//
//  HLSManifest.swift
//  JoesProxy
//
//  Parsed HLS manifest metadata per RFC 8216.
//

import Foundation

/// Parsed HLS manifest (master or media playlist).
struct HLSManifest: Sendable {
    let isMasterPlaylist: Bool
    let version: Int?
    let variants: [HLSVariant]
    let mediaGroups: [HLSMediaGroup]
    let targetDuration: Double?
    let segmentCount: Int
    let segments: [HLSSegment]
    let initializationSegmentURI: String?
    let keys: [HLSKey]
    let adMarkers: [HLSAdMarker]
    let adBreaks: [HLSAdBreak]
    let programDateTimes: [String]
    let contentSteering: HLSContentSteering?
}

/// Parsed `#EXT-X-CONTENT-STEERING` tag metadata (no automatic JSON fetch).
struct HLSContentSteering: Sendable, Equatable {
    let serverURI: String?
    let pathwayID: String?
    let reloadURI: String?
}

/// Stream variant from EXT-X-STREAM-INF.
struct HLSVariant: Sendable {
    let uri: String
    let bandwidth: Int?
    let averageBandwidth: Int?
    let resolution: String?
    let codecs: String?
    let name: String?
    let frameRate: Double?
    let videoRange: String?
    let hdcpLevel: String?
    let audioGroupID: String?
    let subtitlesGroupID: String?
    let videoGroupID: String?
    let closedCaptionsGroupID: String?
}

/// EXT-X-MEDIA rendition group entry.
struct HLSMediaGroup: Sendable {
    let type: String
    let groupID: String?
    let name: String?
    let language: String?
    let associatedLanguage: String?
    let characteristics: [String]
    let channels: String?
    let uri: String?
    let isDefault: Bool
    let autoSelect: Bool
    let isForced: Bool
}

/// Media segment entry from a media playlist.
struct HLSSegment: Sendable {
    let uri: String
    let duration: Double?
    let startTime: Double?
    let host: String?
    let byteRange: String?
    let programDateTime: String?
    let isDiscontinuityBoundary: Bool
    let isAdSegment: Bool
}

/// EXT-X-KEY or EXT-X-SESSION-KEY.
struct HLSKey: Sendable {
    let method: String
    let uri: String?
    let iv: String?
    let keyFormat: String?
}

/// Ad break marker (EXT-X-DATERANGE, EXT-X-CUE-OUT, etc.).
struct HLSAdMarker: Sendable {
    let type: String
    let duration: Double?
    let id: String?
    let startTime: Double?
    let plannedDuration: Double?
    let scte35Out: String?
    let scte35In: String?
    let assetValue: String?
    let rawAttributes: [String: String]
}

/// Derived ad break window from HLS cue markers.
struct HLSAdBreak: Sendable {
    let id: String?
    let cueType: String
    let startTime: Double
    let endTime: Double?
    let duration: Double?
    let markerCount: Int
}

extension HLSManifest {
    var videoRanges: [String] {
        Array(Set(variants.compactMap(\.videoRange))).sorted()
    }

    var hdcpLevels: [String] {
        Array(Set(variants.compactMap(\.hdcpLevel))).sorted()
    }

    var vendorDateRangeAttributes: [String: [String]] {
        let pairs = adMarkers
            .filter { $0.type == "DATERANGE" }
            .flatMap { marker in
                marker.rawAttributes
                    .filter { $0.key.hasPrefix("X-") }
                    .map { ($0.key, $0.value) }
            }

        return Dictionary(grouping: pairs, by: \.0)
            .mapValues { entries in Array(Set(entries.map(\.1))).sorted() }
    }

    var referencedHosts: [String] {
        var hosts = Set<String>()

        for uri in variants.map(\.uri) {
            if let host = URL(string: uri)?.host {
                hosts.insert(host)
            }
        }

        for uri in mediaGroups.compactMap(\.uri) {
            if let host = URL(string: uri)?.host {
                hosts.insert(host)
            }
        }

        for uri in segments.map(\.uri) {
            if let host = URL(string: uri)?.host {
                hosts.insert(host)
            }
        }

        for uri in keys.compactMap(\.uri) {
            if let host = URL(string: uri)?.host {
                hosts.insert(host)
            }
        }

        if let initializationSegmentURI,
           let host = URL(string: initializationSegmentURI)?.host {
            hosts.insert(host)
        }

        return hosts.sorted()
    }
}
