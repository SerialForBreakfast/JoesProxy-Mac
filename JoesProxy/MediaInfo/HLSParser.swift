//
//  HLSParser.swift
//  JoesProxy
//
//  Parses HLS m3u8 manifests per RFC 8216.
//

import Foundation

enum HLSParser {

    /// Parses manifest text. Base URL used to resolve relative URIs.
    static func parse(_ manifest: String, baseURL: URL? = nil) -> HLSManifest {
        var isMaster = false
        var version: Int?
        var variants: [HLSVariant] = []
        var mediaGroups: [HLSMediaGroup] = []
        var targetDuration: Double?
        var segmentCount = 0
        var segments: [HLSSegment] = []
        var initializationSegmentURI: String?
        var keys: [HLSKey] = []
        var adMarkers: [HLSAdMarker] = []
        var programDateTimes: [String] = []
        var contentSteering: HLSContentSteering?
        var currentPlaybackTime = 0.0
        var isInsideAdBreak = false
        var pendingSegmentDuration: Double?
        var pendingByteRange: String?
        var pendingProgramDateTime: String?
        var nextSegmentIsDiscontinuityBoundary = false

        var currentStreamInf: (
            bandwidth: Int?,
            averageBandwidth: Int?,
            resolution: String?,
            codecs: String?,
            name: String?,
            frameRate: Double?,
            videoRange: String?,
            hdcpLevel: String?,
            audioGroupID: String?,
            subtitlesGroupID: String?,
            videoGroupID: String?,
            closedCaptionsGroupID: String?
        )?

        let lines = manifest.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                currentStreamInf = (
                    bandwidth: attrs["BANDWIDTH"].flatMap { Int($0) },
                    averageBandwidth: attrs["AVERAGE-BANDWIDTH"].flatMap { Int($0) },
                    resolution: attrs["RESOLUTION"],
                    codecs: attrs["CODECS"],
                    name: attrs["NAME"],
                    frameRate: attrs["FRAME-RATE"].flatMap { Double($0) },
                    videoRange: attrs["VIDEO-RANGE"],
                    hdcpLevel: attrs["HDCP-LEVEL"],
                    audioGroupID: attrs["AUDIO"],
                    subtitlesGroupID: attrs["SUBTITLES"],
                    videoGroupID: attrs["VIDEO"],
                    closedCaptionsGroupID: attrs["CLOSED-CAPTIONS"]
                )
                isMaster = true
            } else if currentStreamInf != nil, !line.hasPrefix("#"), !line.isEmpty {
                let uri = resolveURI(line, base: baseURL)
                variants.append(HLSVariant(
                    uri: uri,
                    bandwidth: currentStreamInf?.bandwidth,
                    averageBandwidth: currentStreamInf?.averageBandwidth,
                    resolution: currentStreamInf?.resolution,
                    codecs: currentStreamInf?.codecs,
                    name: currentStreamInf?.name,
                    frameRate: currentStreamInf?.frameRate,
                    videoRange: currentStreamInf?.videoRange,
                    hdcpLevel: currentStreamInf?.hdcpLevel,
                    audioGroupID: currentStreamInf?.audioGroupID,
                    subtitlesGroupID: currentStreamInf?.subtitlesGroupID,
                    videoGroupID: currentStreamInf?.videoGroupID,
                    closedCaptionsGroupID: currentStreamInf?.closedCaptionsGroupID
                ))
                currentStreamInf = nil
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                let resolvedURI = attrs["URI"]
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                    .map { resolveURI($0, base: baseURL) }
                mediaGroups.append(
                    HLSMediaGroup(
                        type: attrs["TYPE"] ?? "UNKNOWN",
                        groupID: attrs["GROUP-ID"],
                        name: attrs["NAME"],
                        language: attrs["LANGUAGE"],
                        associatedLanguage: attrs["ASSOC-LANGUAGE"],
                        characteristics: attrs["CHARACTERISTICS"]?
                            .split(separator: ",")
                            .map(String.init) ?? [],
                        channels: attrs["CHANNELS"],
                        uri: resolvedURI,
                        isDefault: parseYesNo(attrs["DEFAULT"]),
                        autoSelect: parseYesNo(attrs["AUTOSELECT"]),
                        isForced: parseYesNo(attrs["FORCED"])
                    )
                )
            } else if line.hasPrefix("#EXT-X-VERSION:") {
                version = Int(line.dropFirst("#EXT-X-VERSION:".count).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("#EXTINF:") {
                let durationText = String(line.dropFirst("#EXTINF:".count))
                    .split(separator: ",", maxSplits: 1)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespaces)
                pendingSegmentDuration = durationText.flatMap(Double.init)
            } else if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                let keyPrefix = line.contains("SESSION-KEY") ? "#EXT-X-SESSION-KEY:" : "#EXT-X-KEY:"
                let attrs = parseAttributes(String(line.dropFirst(keyPrefix.count)))
                let uriValue = attrs["URI"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let uri = uriValue.map { resolveURI($0, base: baseURL) }
                keys.append(HLSKey(
                    method: attrs["METHOD"] ?? "NONE",
                    uri: uri,
                    iv: attrs["IV"],
                    keyFormat: attrs["KEYFORMAT"]
                ))
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                let uriValue = attrs["URI"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                initializationSegmentURI = uriValue.map { resolveURI($0, base: baseURL) }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#EXT-X-CONTENT-STEERING:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-CONTENT-STEERING:".count)))
                contentSteering = HLSContentSteering(
                    serverURI: attrs["SERVER-URI"].map { resolveURI($0, base: baseURL) },
                    pathwayID: attrs["PATHWAY-ID"],
                    reloadURI: attrs["RELOAD-URI"].map { resolveURI($0, base: baseURL) }
                )
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                let programDateTime = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
                    .trimmingCharacters(in: .whitespaces)
                pendingProgramDateTime = programDateTime
                programDateTimes.append(programDateTime)
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") {
                nextSegmentIsDiscontinuityBoundary = true
            } else if line.hasPrefix("#EXT-X-CUE-OUT:") {
                let rest = String(line.dropFirst("#EXT-X-CUE-OUT:".count)).trimmingCharacters(in: .whitespaces)
                let duration = Double(rest)
                isInsideAdBreak = true
                adMarkers.append(
                    HLSAdMarker(
                        type: "CUE-OUT",
                        duration: duration,
                        id: nil,
                        startTime: currentPlaybackTime,
                        plannedDuration: duration,
                        scte35Out: nil,
                        scte35In: nil,
                        assetValue: nil,
                        rawAttributes: [:]
                    )
                )
            } else if line.hasPrefix("#EXT-X-CUE-OUT-CONT:") {
                let attrs = parseLooseKeyValueAttributes(String(line.dropFirst("#EXT-X-CUE-OUT-CONT:".count)))
                let duration = attrs["Duration"].flatMap(Double.init)
                let elapsed = attrs["ElapsedTime"].flatMap(Double.init)
                adMarkers.append(
                    HLSAdMarker(
                        type: "CUE-OUT-CONT",
                        duration: duration,
                        id: attrs["ID"],
                        startTime: currentPlaybackTime - (elapsed ?? 0),
                        plannedDuration: duration,
                        scte35Out: attrs["SCTE35"],
                        scte35In: nil,
                        assetValue: nil,
                        rawAttributes: attrs
                    )
                )
            } else if line.hasPrefix("#EXT-X-CUE-IN") {
                isInsideAdBreak = false
                adMarkers.append(
                    HLSAdMarker(
                        type: "CUE-IN",
                        duration: nil,
                        id: nil,
                        startTime: currentPlaybackTime,
                        plannedDuration: nil,
                        scte35Out: nil,
                        scte35In: nil,
                        assetValue: nil,
                        rawAttributes: [:]
                    )
                )
            } else if line.hasPrefix("#EXT-X-DATERANGE:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-DATERANGE:".count)))
                let duration = attrs["DURATION"].flatMap { Double($0) }
                let hasSCTE35Out = attrs["SCTE35-OUT"] != nil
                let hasSCTE35In = attrs["SCTE35-IN"] != nil
                if hasSCTE35Out {
                    isInsideAdBreak = true
                }
                if hasSCTE35In {
                    isInsideAdBreak = false
                }
                adMarkers.append(
                    HLSAdMarker(
                        type: "DATERANGE",
                        duration: duration,
                        id: attrs["ID"],
                        startTime: currentPlaybackTime,
                        plannedDuration: attrs["PLANNED-DURATION"].flatMap(Double.init) ?? duration,
                        scte35Out: attrs["SCTE35-OUT"],
                        scte35In: attrs["SCTE35-IN"],
                        assetValue: attrs["X-ASSET-URI"] ?? attrs["X-ASSET-LIST"] ?? attrs["X-ASSET-ID"],
                        rawAttributes: attrs
                    )
                )
            } else if line.hasPrefix("#EXT-X-ASSET:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-ASSET:".count)))
                adMarkers.append(
                    HLSAdMarker(
                        type: "ASSET",
                        duration: nil,
                        id: attrs["ID"],
                        startTime: currentPlaybackTime,
                        plannedDuration: nil,
                        scte35Out: nil,
                        scte35In: nil,
                        assetValue: attrs["URI"] ?? attrs["X-ASSET-ID"],
                        rawAttributes: attrs
                    )
                )
            } else if line.hasPrefix("#EXT-X-SPLICEPOINT-SCTE35:") {
                let payload = String(line.dropFirst("#EXT-X-SPLICEPOINT-SCTE35:".count)).trimmingCharacters(in: .whitespaces)
                adMarkers.append(
                    HLSAdMarker(
                        type: "SPLICEPOINT-SCTE35",
                        duration: nil,
                        id: nil,
                        startTime: currentPlaybackTime,
                        plannedDuration: nil,
                        scte35Out: payload,
                        scte35In: nil,
                        assetValue: nil,
                        rawAttributes: [:]
                    )
                )
            } else if !line.hasPrefix("#"), !line.isEmpty {
                let uri = resolveURI(line, base: baseURL)
                let segment = HLSSegment(
                    uri: uri,
                    duration: pendingSegmentDuration,
                    startTime: pendingSegmentDuration != nil ? currentPlaybackTime : nil,
                    host: URL(string: uri)?.host,
                    byteRange: pendingByteRange,
                    programDateTime: pendingProgramDateTime,
                    isDiscontinuityBoundary: nextSegmentIsDiscontinuityBoundary,
                    isAdSegment: isInsideAdBreak
                )
                segments.append(segment)
                segmentCount += 1
                if let pendingSegmentDuration {
                    currentPlaybackTime += pendingSegmentDuration
                }
                pendingSegmentDuration = nil
                pendingByteRange = nil
                pendingProgramDateTime = nil
                nextSegmentIsDiscontinuityBoundary = false
            }
        }

        return HLSManifest(
            isMasterPlaylist: isMaster,
            version: version,
            variants: variants,
            mediaGroups: mediaGroups,
            targetDuration: targetDuration,
            segmentCount: segmentCount,
            segments: segments,
            initializationSegmentURI: initializationSegmentURI,
            keys: keys,
            adMarkers: adMarkers,
            adBreaks: buildAdBreaks(from: adMarkers),
            programDateTimes: programDateTimes,
            contentSteering: contentSteering
        )
    }

    private static func parseAttributes(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        var current = ""
        var entries: [String] = []
        var isInsideQuotes = false

        for character in s {
            if character == "\"" {
                isInsideQuotes.toggle()
            }

            if character == ",", !isInsideQuotes {
                let entry = current.trimmingCharacters(in: .whitespaces)
                if !entry.isEmpty {
                    entries.append(entry)
                }
                current = ""
            } else {
                current.append(character)
            }
        }

        let trailingEntry = current.trimmingCharacters(in: .whitespaces)
        if !trailingEntry.isEmpty {
            entries.append(trailingEntry)
        }

        for entry in entries {
            let pair = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else {
                continue
            }

            let key = pair[0].trimmingCharacters(in: .whitespaces)
            let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespaces))
            result[key] = value
        }

        return result
    }

    private static func resolveURI(_ uri: String, base: URL?) -> String {
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            return uri
        }
        guard let base else { return uri }
        if uri.hasPrefix("/") {
            return base.scheme.map { "\($0)://\(base.host ?? "")\(uri)" } ?? uri
        }
        return URL(string: uri, relativeTo: base)?.absoluteURL.absoluteString ?? uri
    }

    private static func parseYesNo(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).uppercased() == "YES"
    }

    private static func parseLooseKeyValueAttributes(_ string: String) -> [String: String] {
        string
            .split(separator: ",")
            .reduce(into: [String: String]()) { result, item in
                let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 {
                    result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces)
                }
            }
    }

    private static func buildAdBreaks(from markers: [HLSAdMarker]) -> [HLSAdBreak] {
        var result: [HLSAdBreak] = []
        var openBreak: (id: String?, cueType: String, startTime: Double, duration: Double?, markerCount: Int)?

        for marker in markers {
            switch marker.type {
            case "CUE-OUT":
                if let startTime = marker.startTime {
                    openBreak = (marker.id, marker.type, startTime, marker.duration, 1)
                }
            case "CUE-OUT-CONT":
                if var currentBreak = openBreak {
                    currentBreak.markerCount += 1
                    currentBreak.duration = currentBreak.duration ?? marker.duration
                    openBreak = currentBreak
                    result.removeLastIfPresentMatching(id: currentBreak.id, cueType: currentBreak.cueType, startTime: currentBreak.startTime)
                    result.append(
                        HLSAdBreak(
                            id: currentBreak.id,
                            cueType: currentBreak.cueType,
                            startTime: currentBreak.startTime,
                            endTime: currentBreak.duration.map { currentBreak.startTime + $0 },
                            duration: currentBreak.duration,
                            markerCount: currentBreak.markerCount
                        )
                    )
                }
            case "CUE-IN":
                if let currentBreak = openBreak, let startTime = marker.startTime {
                    result.append(
                        HLSAdBreak(
                            id: currentBreak.id,
                            cueType: currentBreak.cueType,
                            startTime: currentBreak.startTime,
                            endTime: startTime,
                            duration: startTime - currentBreak.startTime,
                            markerCount: currentBreak.markerCount + 1
                        )
                    )
                    openBreak = nil
                }
            case "DATERANGE":
                if let startTime = marker.startTime,
                   marker.scte35Out != nil || marker.duration != nil || marker.plannedDuration != nil {
                    result.append(
                        HLSAdBreak(
                            id: marker.id,
                            cueType: marker.type,
                            startTime: startTime,
                            endTime: (marker.duration ?? marker.plannedDuration).map { startTime + $0 },
                            duration: marker.duration ?? marker.plannedDuration,
                            markerCount: 1
                        )
                    )
                }
            default:
                continue
            }
        }

        return deduplicatedAdBreaks(result)
    }

    private static func deduplicatedAdBreaks(_ breaks: [HLSAdBreak]) -> [HLSAdBreak] {
        var seen = Set<String>()
        return breaks.filter { adBreak in
            let key = "\(adBreak.id ?? "nil")|\(adBreak.cueType)|\(adBreak.startTime)"
            return seen.insert(key).inserted
        }
    }
}

private extension Array where Element == HLSAdBreak {
    mutating func removeLastIfPresentMatching(id: String?, cueType: String, startTime: Double) {
        guard let last else {
            return
        }

        if last.id == id, last.cueType == cueType, last.startTime == startTime {
            removeLast()
        }
    }
}
