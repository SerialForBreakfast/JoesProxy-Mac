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
        let index = ManifestIndex(target: target, sessions: allSessions)
        guard let targetURL = MediaDetector.absoluteURL(for: target.request) else { return .empty }
        let selected = index.manifest(for: targetURL)
        let manifestSession = selected?.session
        let ladder = selected?.ladder ?? []
        let manifestKind = selected?.kind ?? "Unknown Stream"
        let defaultSegmentDuration = selected?.targetDuration ?? 6
        let segmentSessions = allSessions.filter { session in
            guard !Task.isCancelled, let url = MediaDetector.absoluteURL(for: session.request),
                  !index.isPlaylist(url), isSegment(session, url: url, index: index) else { return false }
            if let selected {
                return index.belongs(url, to: selected)
            }
            return session.id == target.id
        }.sorted { $0.timing.startedAt < $1.timing.startedAt }
        guard !Task.isCancelled else { return .empty }

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
            guard !Task.isCancelled else { return .empty }
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

    private struct Manifest {
        let session: SessionRecord
        let url: URL
        let ladder: [StreamingBitrateVariant]
        let kind: String
        let targetDuration: Double
    }

    private struct ManifestIndex {
        var manifests: [URL: Manifest] = [:]
        var parents: [URL: Set<URL>] = [:]
        var playlistsBySegment: [URL: Set<URL>] = [:]
        var byDirectory: [URL: Set<URL>] = [:]

        init(target: SessionRecord, sessions: [SessionRecord]) {
            for session in sessions {
                if Task.isCancelled { return }
                var type = MediaDetector.waterfallMediaType(for: session)
                if session.id == target.id && type == .none {
                    type = MediaDetector.mediaType(for: session)
                }
                guard type == .hls || type == .dash,
                      let url = MediaDetector.absoluteURL(for: session.request),
                      let bytes = session.response.flatMap(MediaDetector.decodedResponseBody),
                      let text = String(data: bytes, encoding: .utf8),
                      let manifest = parseManifest(session, url: url, type: type, text: text)
                else { continue }
                // Preserve the selected capture when a live playlist URL has multiple snapshots.
                if manifests[url]?.session.id != target.id { manifests[url] = manifest }
                if !manifest.ladder.isEmpty {
                    byDirectory[Self.directory(url), default: []].insert(url)
                }
            }
        }

        private static func directory(_ url: URL) -> URL {
            url.absoluteURL.deletingLastPathComponent().absoluteString.components(separatedBy: "?").first
                .flatMap(URL.init(string:)) ?? url
        }

        func isPlaylist(_ url: URL) -> Bool { manifests[url] != nil || parents[url] != nil }

        private func owners(of url: URL) -> Set<URL> {
            if let playlists = playlistsBySegment[url] {
                return playlists.reduce(into: []) { result, playlist in
                    result.formUnion(parents[playlist] ?? [playlist])
                }
            }
            var directory = Self.directory(url)
            while true {
                if let candidates = byDirectory[directory] { return candidates }
                if directory.path.isEmpty || directory.path == "/" { break }
                let parent = Self.directory(directory)
                if parent == directory { break }
                directory = parent
            }
            return []
        }

        func manifest(for url: URL) -> Manifest? {
            if let direct = manifests[url] { return direct }
            let matches = owners(of: url)
            guard matches.count == 1, let owner = matches.first else { return nil }
            return manifests[owner]
        }

        func belongs(_ url: URL, to manifest: Manifest) -> Bool {
            if playlistsBySegment[url]?.contains(manifest.url) == true { return true }
            return owners(of: url) == [manifest.url]
        }

        private mutating func parseManifest(_ session: SessionRecord, url: URL, type: MediaType, text: String) -> Manifest? {
            if type == .hls, text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
                let manifest = HLSParser.parse(text, baseURL: url)
                for reference in manifest.variants.map(\.uri) + manifest.mediaGroups.compactMap(\.uri) {
                    if let child = URL(string: reference) {
                        parents[child, default: []].insert(url)
                        byDirectory[Self.directory(child), default: []].insert(url)
                    }
                }
                for reference in manifest.segments.map(\.uri) + [manifest.initializationSegmentURI].compactMap({ $0 }) {
                    if let segment = URL(string: reference) { playlistsBySegment[segment, default: []].insert(url) }
                }
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
                return Manifest(session: session, url: url, ladder: variants, kind: kind, targetDuration: manifest.targetDuration ?? 6)
            }
            if type == .dash, let manifest = DASHParser.parse(text) {
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
                return Manifest(session: session, url: url, ladder: variants, kind: "DASH MPD Manifest", targetDuration: 6)
            }
            return nil
        }
    }

    private static func isSegment(_ session: SessionRecord, url: URL, index: ManifestIndex) -> Bool {
        if index.playlistsBySegment[url] != nil { return true }
        if case .video = MediaDetector.waterfallMediaType(for: session) { return true }
        return ["aac", "vtt"].contains(url.pathExtension.lowercased())
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
