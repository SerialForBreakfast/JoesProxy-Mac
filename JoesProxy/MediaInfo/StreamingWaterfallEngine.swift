//
//  StreamingWaterfallEngine.swift
//  JoesProxy
//
//  Analyzes captured video sessions (HLS & DASH) to produce a Streaming Quality Waterfall report.
//

import Foundation

enum StreamingWaterfallEngine {

    /// Analyzes the target session and all surrounding capture sessions to build a StreamingQualityWaterfallReport.
    static func analyze(
        target: SessionRecord,
        allSessions: [SessionRecord]
    ) -> StreamingQualityWaterfallReport {
        // 1. Identify manifest and extract bitrate ladder
        let (manifestSession, ladder, manifestKind, defaultSegmentDuration) = resolveManifestAndLadder(
            target: target,
            allSessions: allSessions
        )

        // 2. Identify and filter related media segments
        let segmentSessions = resolveRelatedSegmentSessions(
            target: target,
            manifestSession: manifestSession,
            allSessions: allSessions
        )

        guard !segmentSessions.isEmpty else {
            return StreamingQualityWaterfallReport(
                manifestSessionID: manifestSession?.id,
                manifestKind: manifestKind,
                bitrateLadder: ladder,
                segments: [],
                switchingEvents: [],
                bufferProjection: [],
                ttff: nil,
                totalPlayableDuration: 0,
                averageBitrateBps: 0,
                slowSegmentCount: 0,
                oscillationCount: 0,
                estimatedStallCount: 0,
                cdnCacheHitRatio: nil
            )
        }

        // 3. Process segments chronologically
        var analyzedSegments: [StreamingWaterfallSegment] = []
        var totalBytes = 0
        var totalPlayableDuration: TimeInterval = 0
        var slowSegmentCount = 0
        var cacheHits = 0
        var totalCacheTracked = 0

        for (index, session) in segmentSessions.enumerated() {
            let path = session.request.path.lowercased()
            let mediaType: StreamingSegmentMediaType
            if path.contains("init") || (session.request.path.contains(".mp4") && (session.response?.bodyData?.count ?? 0) < 5000) {
                mediaType = .initSegment
            } else if path.contains("audio") || path.contains("_a.") || path.contains("-a-") {
                mediaType = .audio
            } else if path.contains("sub") || path.contains(".vtt") {
                mediaType = .subtitle
            } else {
                mediaType = .video
            }

            let byteCount = session.response?.bodyData?.count
                ?? session.response?.headers.first(where: { $0.name.caseInsensitiveCompare("content-length") == .orderedSame }).flatMap { Int($0.value) }
                ?? 0

            let downloadDuration = max(0.001, session.timing.duration ?? 0.5)
            let downloadSpeedBps = (Double(byteCount) * 8.0) / downloadDuration
            let segmentDuration = defaultSegmentDuration

            let matchedVariant = matchVariant(for: session, in: ladder)
            let isSlow = downloadDuration > segmentDuration && mediaType == .video
            if isSlow {
                slowSegmentCount += 1
            }

            let isHit = checkCacheHit(headers: session.response?.headers ?? [])
            if let isHit {
                totalCacheTracked += 1
                if isHit { cacheHits += 1 }
            }

            totalBytes += byteCount
            if mediaType == .video {
                totalPlayableDuration += segmentDuration
            }

            analyzedSegments.append(
                StreamingWaterfallSegment(
                    sessionID: session.id,
                    uri: session.request.path,
                    sequenceNumber: index + 1,
                    mediaType: mediaType,
                    variantBandwidth: matchedVariant?.bandwidth,
                    variantResolution: matchedVariant?.resolution,
                    segmentDuration: segmentDuration,
                    downloadDuration: downloadDuration,
                    byteCount: byteCount,
                    downloadSpeedBps: downloadSpeedBps,
                    startedAt: session.timing.startedAt,
                    completedAt: session.timing.startedAt.addingTimeInterval(downloadDuration),
                    ttfb: nil,
                    isSlowDownload: isSlow,
                    isCacheHit: isHit
                )
            )
        }

        // 4. Compute buffer projection and stall estimates
        var bufferProjection: [StreamingBufferPoint] = []
        var currentBuffer: Double = 0
        var stallCount = 0
        var previousCompletion: Date?

        for seg in analyzedSegments where seg.mediaType == .video {
            if let prev = previousCompletion {
                let elapsed = seg.startedAt.timeIntervalSince(prev)
                if elapsed > 0 {
                    currentBuffer = max(0, currentBuffer - elapsed)
                }
            }

            // During download, buffer drains
            currentBuffer = max(0, currentBuffer - seg.downloadDuration)
            if currentBuffer <= 0.1 && bufferProjection.count > 1 {
                stallCount += 1
            }

            // Once downloaded, segment duration adds to buffer
            currentBuffer += seg.segmentDuration
            previousCompletion = seg.completedAt

            bufferProjection.append(
                StreamingBufferPoint(
                    timestamp: seg.completedAt,
                    estimatedBufferSeconds: currentBuffer,
                    isStallRisk: currentBuffer < 2.5
                )
            )
        }

        // 5. Detect Quality Switches & Oscillations
        var switchingEvents: [StreamingQualitySwitchEvent] = []
        var switchCount = 0
        var previousBandwidth: Int?
        var previousResolution: String?
        var recentSwitches: [Date] = []

        for seg in analyzedSegments where seg.mediaType == .video {
            if let bw = seg.variantBandwidth {
                if let prevBw = previousBandwidth, prevBw != bw {
                    let switchType: StreamingSwitchType
                    if bw > prevBw {
                        switchType = .stepUp
                    } else if Double(bw) < Double(prevBw) * 0.5 {
                        switchType = .emergencyDrop
                    } else {
                        switchType = .stepDown
                    }

                    switchingEvents.append(
                        StreamingQualitySwitchEvent(
                            timestamp: seg.startedAt,
                            fromBandwidth: prevBw,
                            toBandwidth: bw,
                            fromResolution: previousResolution,
                            toResolution: seg.variantResolution,
                            switchType: switchType,
                            triggerSessionID: seg.sessionID
                        )
                    )
                    switchCount += 1
                    recentSwitches.append(seg.startedAt)
                }
                previousBandwidth = bw
                previousResolution = seg.variantResolution
            }
        }

        // Count oscillations (3 or more switches within a 30s rolling window)
        var oscillationCount = 0
        if recentSwitches.count >= 3 {
            for i in 0..<(recentSwitches.count - 2) {
                if recentSwitches[i + 2].timeIntervalSince(recentSwitches[i]) <= 30.0 {
                    oscillationCount += 1
                }
            }
        }

        // 6. Time to First Frame (TTFF)
        var ttff: TimeInterval?
        if let firstSegment = analyzedSegments.first(where: { $0.mediaType == .video }) {
            let start = manifestSession?.timing.startedAt ?? analyzedSegments.first?.startedAt ?? firstSegment.startedAt
            ttff = max(0, firstSegment.completedAt.timeIntervalSince(start))
        }

        let averageBitrate = totalPlayableDuration > 0
            ? (Double(totalBytes) * 8.0) / totalPlayableDuration
            : 0.0

        let hitRatio = totalCacheTracked > 0
            ? Double(cacheHits) / Double(totalCacheTracked)
            : nil

        return StreamingQualityWaterfallReport(
            manifestSessionID: manifestSession?.id,
            manifestKind: manifestKind,
            bitrateLadder: ladder,
            segments: analyzedSegments,
            switchingEvents: switchingEvents,
            bufferProjection: bufferProjection,
            ttff: ttff,
            totalPlayableDuration: totalPlayableDuration,
            averageBitrateBps: averageBitrate,
            slowSegmentCount: slowSegmentCount,
            oscillationCount: oscillationCount,
            estimatedStallCount: stallCount,
            cdnCacheHitRatio: hitRatio
        )
    }

    // MARK: - Private Helpers

    private static func resolveManifestAndLadder(
        target: SessionRecord,
        allSessions: [SessionRecord]
    ) -> (manifestSession: SessionRecord?, ladder: [StreamingBitrateVariant], kind: String, targetDuration: Double) {
        let mediaType = MediaDetector.mediaType(for: target)

        // Case A: Target is an HLS manifest
        if mediaType == .hls || mediaType == .hlsDiscovery || target.request.path.contains(".m3u8") {
            let manifestText = target.response?.bodyData.flatMap { String(data: $0, encoding: .utf8) }
            if let text = manifestText {
                let baseURL = URL(string: "\(target.request.scheme.rawValue)://\(target.request.host)\(target.request.path)")
                let manifest = HLSParser.parse(text, baseURL: baseURL)
                let variants: [StreamingBitrateVariant] = manifest.variants.map { v in
                    StreamingBitrateVariant(
                        bandwidth: v.bandwidth ?? v.averageBandwidth ?? 0,
                        averageBandwidth: v.averageBandwidth,
                        resolution: v.resolution,
                        codecs: v.codecs,
                        frameRate: v.frameRate,
                        name: v.name
                    )
                }.sorted(by: { $0.bandwidth < $1.bandwidth })

                let kind = manifest.isMasterPlaylist ? "HLS Master Playlist" : "HLS Media Playlist"
                return (target, variants, kind, manifest.targetDuration ?? 6.0)
            }
        }

        // Case B: Target is a DASH manifest
        if mediaType == .dash || target.request.path.contains(".mpd") {
            let manifestText = target.response?.bodyData.flatMap { String(data: $0, encoding: .utf8) }
            if let text = manifestText, let manifest = DASHParser.parse(text) {
                var variants: [StreamingBitrateVariant] = []
                for period in manifest.periods {
                    for set in period.adaptationSets {
                        for rep in set.representations {
                            let resolution: String?
                            if let w = rep.width, let h = rep.height {
                                resolution = "\(w)x\(h)"
                            } else {
                                resolution = nil
                            }
                            variants.append(
                                StreamingBitrateVariant(
                                    bandwidth: rep.bandwidth ?? 0,
                                    averageBandwidth: nil,
                                    resolution: resolution,
                                    codecs: rep.codecs ?? set.codecs,
                                    frameRate: rep.frameRate.flatMap { Double($0) },
                                    name: rep.id
                                )
                            )
                        }
                    }
                }
                variants.sort(by: { $0.bandwidth < $1.bandwidth })
                return (target, variants, "DASH MPD Manifest", 6.0)
            }
        }

        // Case C: Target is a media segment; find related manifest session
        let manifests = allSessions.filter {
            let t = MediaDetector.mediaType(for: $0)
            return t == .hls || t == .dash || $0.request.path.contains(".m3u8") || $0.request.path.contains(".mpd")
        }

        for m in manifests {
            let res = resolveManifestAndLadder(target: m, allSessions: allSessions)
            if !res.ladder.isEmpty {
                return (m, res.ladder, res.kind, res.targetDuration)
            }
        }

        return (nil, [], "Unknown Stream", 6.0)
    }

    private static func resolveRelatedSegmentSessions(
        target: SessionRecord,
        manifestSession: SessionRecord?,
        allSessions: [SessionRecord]
    ) -> [SessionRecord] {
        let host = manifestSession?.request.host ?? target.request.host

        return allSessions.filter { session in
            // Exclude manifests themselves from the segment list
            if session.id == manifestSession?.id || session.request.path.contains(".m3u8") || session.request.path.contains(".mpd") {
                return false
            }
            guard session.request.host == host || session.request.host.contains(host) || host.contains(session.request.host) else {
                return false
            }
            let mediaType = MediaDetector.mediaType(for: session)
            let path = session.request.path.lowercased()
            return mediaType.isVideoOrStream
                || path.contains(".ts")
                || path.contains(".m4s")
                || path.contains(".mp4")
                || path.contains(".aac")
                || path.contains(".vtt")
        }.sorted(by: { $0.timing.startedAt < $1.timing.startedAt })
    }

    private static func matchVariant(
        for session: SessionRecord,
        in ladder: [StreamingBitrateVariant]
    ) -> StreamingBitrateVariant? {
        guard !ladder.isEmpty else { return nil }
        let path = session.request.path.lowercased()

        // 1. Match by resolution in path (e.g. 1080p, 720p, 1920x1080, 720, 1080)
        for variant in ladder {
            if let res = variant.resolution?.lowercased() {
                if path.contains(res) { return variant }
                let height = res.split(separator: "x").last.map(String.init) ?? res
                if path.contains(height) || path.contains("\(height)p") {
                    return variant
                }
            }
        }

        // 2. Match by bandwidth in path (e.g. 4500k, 2500000)
        for variant in ladder {
            if path.contains("\(variant.bandwidth)") || path.contains("\(variant.bandwidth / 1000)k") {
                return variant
            }
        }

        // 3. Fallback: estimate from byte count if available
        let bytes = session.response?.bodyData?.count ?? 0
        if bytes > 0 {
            let estimatedBandwidth = (Double(bytes) * 8.0) / 6.0
            return ladder.min(by: { abs(Double($0.bandwidth) - estimatedBandwidth) < abs(Double($1.bandwidth) - estimatedBandwidth) })
        }

        return ladder.first
    }

    private static func checkCacheHit(headers: [HTTPHeaderField]) -> Bool? {
        for header in headers {
            let name = header.name.lowercased()
            let value = header.value.lowercased()
            if name == "x-cache" || name == "cf-cache-status" || name == "x-varnish" {
                if value.contains("hit") { return true }
                if value.contains("miss") { return false }
            }
            if name == "age", let ageVal = Int(value), ageVal > 0 {
                return true
            }
        }
        return nil
    }
}
