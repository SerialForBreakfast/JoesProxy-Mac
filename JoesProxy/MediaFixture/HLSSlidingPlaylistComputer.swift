import Foundation

/// One segment from a statically-authored (VOD-shaped) fixture stream playlist.
struct HLSStaticSegment: Equatable, Sendable {
    let uri: String
    let duration: Double
    /// Whether an `#EXT-X-DISCONTINUITY` tag immediately preceded this segment in the source
    /// playlist — preserved in the sliding window so discontinuity-flavored profiles (P2-06) still
    /// carry it through.
    let hasDiscontinuityBefore: Bool
    /// The `#EXT-X-KEY` line immediately preceding this segment in the source playlist, if any —
    /// carried through verbatim so key-rotation profiles (P2-06) still carry it through.
    let keyLine: String?
}

/// Parses a statically-authored (`generate-profile.sh`-produced) VOD playlist into its ordered
/// segment list. Read-only — this never re-serializes a full playlist itself; that's
/// `HLSSlidingPlaylistComputer.render`'s job, working from parsed segments plus a computed window.
enum HLSStaticPlaylistParser {
    struct Parsed: Equatable, Sendable {
        let targetDuration: Int
        let segments: [HLSStaticSegment]
    }

    static func parse(_ text: String) -> Parsed {
        var segments: [HLSStaticSegment] = []
        var pendingDuration: Double?
        var pendingDiscontinuity = false
        var pendingKeyLine: String?
        var targetDuration = 6

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Int(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? targetDuration
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-KEY:") {
                pendingKeyLine = line
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? "0"
                pendingDuration = Double(value)
            } else if !line.isEmpty, !line.hasPrefix("#") {
                if let duration = pendingDuration {
                    segments.append(
                        HLSStaticSegment(
                            uri: line,
                            duration: duration,
                            hasDiscontinuityBefore: pendingDiscontinuity,
                            keyLine: pendingKeyLine
                        )
                    )
                }
                pendingDuration = nil
                pendingDiscontinuity = false
                // Deliberately NOT cleared: an `#EXT-X-KEY` applies to every following segment
                // until superseded by another `#EXT-X-KEY`, per RFC 8216 §4.3.2.4 — matches how a
                // real key-rotation profile's playlist is structured.
            }
        }
        return Parsed(targetDuration: targetDuration, segments: segments)
    }
}

/// Computes a deterministic, clock-driven "live" sliding window over a fixed, finite segment set —
/// never a real-time encode. Time is injected (`startedAt`/`now`), making this pure and unit-
/// testable without wall-clock sleeps: two calls with the same inputs always produce the same
/// window.
enum HLSSlidingPlaylistComputer {
    /// Segments included in each served playlist — small and fixed, matching a typical live HLS
    /// client's expected window size rather than exposing the whole fixture asset at once.
    static let windowSegmentCount = 4

    /// `virtualIndex` climbs forever; `segment` cycles through the finite real files via modulo.
    /// Two different `virtualIndex` values legitimately reference the same real segment file once
    /// the fixture's finite content has looped.
    struct WindowEntry: Equatable, Sendable {
        let segment: HLSStaticSegment
        let virtualIndex: Int
        let isLoopBoundaryBefore: Bool
    }

    struct Window: Equatable, Sendable {
        let mediaSequence: Int
        /// Present for explicit `liveLoop` publication. This is the newest segment whose full
        /// duration has elapsed on the publication timeline; every advertised entry is therefore
        /// retrievable immediately. Legacy compatibility windows leave this unspecified.
        let newestPublishedSequence: Int?
        /// Discontinuity sequence number of the first Media Segment in this window (RFC 8216
        /// `#EXT-X-DISCONTINUITY-SEQUENCE`). Climbs across loops the same way `mediaSequence` does.
        let discontinuitySequence: Int
        let targetDuration: Int
        let entries: [WindowEntry]
        let firstSegmentProgramDateTime: Date?
        let configuration: HLSPlaybackConfiguration
        var isComplete = false

        var oldestAdvertisedSequence: Int? { entries.first?.virtualIndex }
        var advertisedDuration: TimeInterval { entries.reduce(0) { $0 + $1.segment.duration } }
        var earliestProgramDateTime: Date? { firstSegmentProgramDateTime }
        var liveEdgeProgramDateTime: Date? {
            firstSegmentProgramDateTime?.addingTimeInterval(advertisedDuration)
        }
    }

    enum VirtualSegmentAvailability: Equatable, Sendable {
        case advertised
        case retainedAfterEviction(until: Date)
        case unavailable
    }

    /// Counts markers strictly before the window, excluding the first entry's retained tag.
    /// Cycle/prefix accounting keeps work independent of the stream's running time.
    static func discontinuitySequence(atVirtualIndex virtualIndex: Int, segments: [HLSStaticSegment]) -> Int {
        discontinuitySequence(
            atVirtualIndex: virtualIndex,
            segments: segments,
            loopBoundaryTreatment: .omitDiscontinuity
        )
    }

    static func discontinuitySequence(
        atVirtualIndex virtualIndex: Int,
        segments: [HLSStaticSegment],
        loopBoundaryTreatment: HLSLoopBoundaryTreatment
    ) -> Int {
        guard !segments.isEmpty, virtualIndex > 0 else { return 0 }
        let cycles = virtualIndex / segments.count
        let remainder = virtualIndex % segments.count
        let authored = cycles * segments.filter(\.hasDiscontinuityBefore).count +
            segments.prefix(remainder).filter(\.hasDiscontinuityBefore).count
        // Rendering emits one tag when authored and loop-boundary markers coincide.
        let loopMarkers = loopBoundaryTreatment == .declareDiscontinuity &&
            !segments[0].hasDiscontinuityBefore ? (virtualIndex - 1) / segments.count : 0
        return authored + loopMarkers
    }

    /// - Parameters:
    ///   - segments: the fixture's real, finite, ordered segment list (from
    ///     `HLSStaticPlaylistParser`).
    ///   - targetDuration: `#EXT-X-TARGETDURATION` to advertise (from the same parse).
    ///   - startedAt: when this fixture run began — the origin the virtual timeline is measured
    ///     from.
    ///   - now: the instant to compute the window for. Injected so this is testable without a real
    ///     clock; production call sites pass `Date()`.
    static func window(
        segments: [HLSStaticSegment],
        targetDuration: Int,
        startedAt: Date,
        now: Date,
        configuration: HLSPlaybackConfiguration = .legacyCompatible
    ) -> Window {
        if configuration.presentationMode == .liveLoop {
            return trailingLiveWindow(
                segments: segments,
                targetDuration: targetDuration,
                startedAt: startedAt,
                now: now,
                configuration: configuration
            )
        }
        guard !segments.isEmpty else {
            return Window(
                mediaSequence: 0,
                newestPublishedSequence: nil,
                discontinuitySequence: 0,
                targetDuration: effectiveTargetDuration(targetDuration, configuration: configuration),
                entries: [],
                firstSegmentProgramDateTime: nil,
                configuration: configuration
            )
        }
        let cycleDuration = segments.reduce(0) { $0 + $1.duration }
        guard cycleDuration > 0 else {
            let entries = segments.enumerated().map {
                WindowEntry(segment: $0.element, virtualIndex: $0.offset, isLoopBoundaryBefore: false)
            }
            return Window(
                mediaSequence: 0,
                newestPublishedSequence: nil,
                discontinuitySequence: discontinuitySequence(
                    atVirtualIndex: 0,
                    segments: segments,
                    loopBoundaryTreatment: configuration.loopBoundaryTreatment
                ),
                targetDuration: effectiveTargetDuration(targetDuration, configuration: configuration),
                entries: entries,
                firstSegmentProgramDateTime: configuration.programDateTimeTreatment == .include ? startedAt : nil,
                configuration: configuration
            )
        }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        // Walk actual cumulative segment durations rather than an average, so segment selection
        // tracks true elapsed time even when segment durations vary (e.g. the
        // `misaligned-audio-boundary` profile).
        let loopCount = Int(elapsed / cycleDuration)
        let positionInLoop = elapsed - Double(loopCount) * cycleDuration
        var cumulativeDuration = 0.0
        var indexInLoop = segments.count - 1
        for (index, segment) in segments.enumerated() {
            if positionInLoop < cumulativeDuration + segment.duration {
                indexInLoop = index
                break
            }
            cumulativeDuration += segment.duration
        }
        let virtualSequence = loopCount * segments.count + indexInLoop
        let windowCount = configuration.windowSegmentCount
        let entries: [WindowEntry] = (0..<windowCount).map { offset in
            let virtualIndex = virtualSequence + offset
            let realIndex = ((virtualIndex % segments.count) + segments.count) % segments.count
            return WindowEntry(
                segment: segments[realIndex],
                virtualIndex: virtualIndex,
                isLoopBoundaryBefore: virtualIndex > 0 && realIndex == 0
            )
        }
        return Window(
            mediaSequence: virtualSequence,
            newestPublishedSequence: nil,
            discontinuitySequence: discontinuitySequence(
                atVirtualIndex: virtualSequence,
                segments: segments,
                loopBoundaryTreatment: configuration.loopBoundaryTreatment
            ),
            targetDuration: effectiveTargetDuration(targetDuration, configuration: configuration),
            entries: entries,
            firstSegmentProgramDateTime: configuration.programDateTimeTreatment == .include
                ? startedAt.addingTimeInterval(Double(loopCount) * cycleDuration + cumulativeDuration)
                : nil,
            configuration: configuration
        )
    }

    /// Computes a trailing live window. `off` and `warmDVR` begin with a complete window of
    /// immutable history; `coldDVR` begins empty and grows as full segments are published.
    private static func trailingLiveWindow(
        segments: [HLSStaticSegment],
        targetDuration: Int,
        startedAt: Date,
        now: Date,
        configuration: HLSPlaybackConfiguration
    ) -> Window {
        guard !segments.isEmpty else {
            return Window(
                mediaSequence: 0,
                newestPublishedSequence: nil,
                discontinuitySequence: 0,
                targetDuration: effectiveTargetDuration(targetDuration, configuration: configuration),
                entries: [],
                firstSegmentProgramDateTime: nil,
                configuration: configuration
            )
        }

        let cycleDuration = segments.reduce(0) { $0 + $1.duration }
        guard cycleDuration > 0 else {
            let entries = segments.enumerated().map {
                WindowEntry(segment: $0.element, virtualIndex: $0.offset, isLoopBoundaryBefore: false)
            }
            return Window(
                mediaSequence: 0,
                newestPublishedSequence: entries.last?.virtualIndex,
                discontinuitySequence: discontinuitySequence(
                    atVirtualIndex: 0,
                    segments: segments,
                    loopBoundaryTreatment: configuration.loopBoundaryTreatment
                ),
                targetDuration: effectiveTargetDuration(targetDuration, configuration: configuration),
                entries: entries,
                firstSegmentProgramDateTime: configuration.programDateTimeTreatment == .include ? startedAt : nil,
                configuration: configuration
            )
        }

        let windowCount = configuration.windowSegmentCount
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let isCold = configuration.effectiveTimeShiftMode == .coldDVR
        let prepublishedCount = isCold ? 0 : windowCount
        let completedAfterStart = completedSegmentCount(
            elapsed: elapsed,
            startingAtVirtualIndex: prepublishedCount,
            segments: segments
        )
        var publishedCount = prepublishedCount + completedAfterStart
        if let jit = configuration.jitPublicationState {
            switch jit {
            case .current, .playlistPresentSegmentPending:
                break
            case .laggingByOneInterval:
                publishedCount = max(0, publishedCount - 1)
            case .overLagFault:
                publishedCount = max(0, publishedCount - 3)
            case .initiallyAbsent:
                let initialWindowDuration = Double(windowCount) * Double(targetDuration)
                if elapsed < initialWindowDuration {
                    publishedCount = 0
                }
            }
        }
        let newestPublishedSequence = publishedCount > 0 ? publishedCount - 1 : nil
        let mediaSequence = newestPublishedSequence.map { max(0, $0 - windowCount + 1) } ?? 0
        let entries: [WindowEntry] = newestPublishedSequence.map { newest in
            (mediaSequence...newest).map { virtualIndex in
                let realIndex = virtualIndex % segments.count
                return WindowEntry(
                    segment: segments[realIndex],
                    virtualIndex: virtualIndex,
                    isLoopBoundaryBefore: virtualIndex > 0 && realIndex == 0
                )
            }
        } ?? []
        let timelineOrigin = startedAt.addingTimeInterval(
            -durationBeforeVirtualIndex(prepublishedCount, segments: segments)
        )
        let firstProgramDateTime = timelineOrigin.addingTimeInterval(
            durationBeforeVirtualIndex(mediaSequence, segments: segments)
        )
        return Window(
            mediaSequence: mediaSequence,
            newestPublishedSequence: newestPublishedSequence,
            discontinuitySequence: discontinuitySequence(
                atVirtualIndex: mediaSequence,
                segments: segments,
                loopBoundaryTreatment: configuration.loopBoundaryTreatment
            ),
            targetDuration: effectiveTargetDuration(targetDuration, configuration: configuration),
            entries: entries,
            firstSegmentProgramDateTime: configuration.programDateTimeTreatment == .include
                ? firstProgramDateTime
                : nil,
            configuration: configuration
        )
    }

    /// Determines whether a unique virtual segment URL is currently advertised, retained for a
    /// client's in-flight request, or expired. Retention after eviction is at least the segment's
    /// own duration plus the longest fixed-size playlist duration that contained it.
    static func availability(
        ofVirtualIndex virtualIndex: Int,
        segments: [HLSStaticSegment],
        targetDuration: Int,
        startedAt: Date,
        now: Date,
        configuration: HLSPlaybackConfiguration
    ) -> VirtualSegmentAvailability {
        guard configuration.effectiveTimeShiftMode != .off,
              virtualIndex >= 0,
              !segments.isEmpty else {
            if configuration.jitPublicationState == .playlistPresentSegmentPending {
                let current = window(
                    segments: segments,
                    targetDuration: targetDuration,
                    startedAt: startedAt,
                    now: now,
                    configuration: configuration
                )
                if let newest = current.newestPublishedSequence, virtualIndex == newest {
                    return .unavailable
                }
            }
            return configuration.effectiveTimeShiftMode == .off ? .advertised : .unavailable
        }
        let current = window(
            segments: segments,
            targetDuration: targetDuration,
            startedAt: startedAt,
            now: now,
            configuration: configuration
        )
        if configuration.jitPublicationState == .playlistPresentSegmentPending,
           let newest = current.newestPublishedSequence,
           virtualIndex == newest {
            return .unavailable
        }
        if current.entries.contains(where: { $0.virtualIndex == virtualIndex }) {
            return .advertised
        }
        guard let newest = current.newestPublishedSequence, virtualIndex <= newest else {
            return .unavailable
        }
        let evictionIndex = virtualIndex + configuration.windowSegmentCount
        let evictionDate = publicationDate(
            ofVirtualIndex: evictionIndex,
            segments: segments,
            startedAt: startedAt,
            configuration: configuration
        )
        guard evictionDate <= now else { return .advertised }
        let playlistDuration = duration(
            fromVirtualIndex: virtualIndex,
            count: configuration.windowSegmentCount,
            segments: segments
        )
        let segmentDuration = segments[virtualIndex % segments.count].duration
        let retainedUntil = evictionDate.addingTimeInterval(segmentDuration + playlistDuration)
        return now <= retainedUntil ? .retainedAfterEviction(until: retainedUntil) : .unavailable
    }

    static func oldestRetainedButEvictedSequence(
        in window: Window,
        segments: [HLSStaticSegment],
        targetDuration: Int,
        startedAt: Date,
        now: Date
    ) -> Int? {
        guard let oldestAdvertised = window.oldestAdvertisedSequence, oldestAdvertised > 0 else { return nil }
        var oldestRetained: Int?
        let lowerBound = max(0, oldestAdvertised - (window.configuration.windowSegmentCount * 2 + 2))
        for virtualIndex in stride(from: oldestAdvertised - 1, through: lowerBound, by: -1) {
            if case .retainedAfterEviction = availability(
                ofVirtualIndex: virtualIndex,
                segments: segments,
                targetDuration: targetDuration,
                startedAt: startedAt,
                now: now,
                configuration: window.configuration
            ) {
                oldestRetained = virtualIndex
            } else if oldestRetained != nil {
                break
            }
        }
        return oldestRetained
    }

    /// Authored `EXTINF` durations are decimal literals truncated to six places (sample-accurate
    /// AAC segments in particular — see `sdr-six-second-positive-v1`'s `audio-en` rendition, whose
    /// per-segment durations are ~5.994667/6.016000s rather than a clean 6.0). At an evaluation
    /// instant that lands exactly on a nominal segment-grid boundary, summing those truncated
    /// literals can fall a few microseconds short of the boundary purely from decimal rounding,
    /// which would otherwise make this loop stop one whole segment early for that rendition while
    /// an exact-duration sibling (e.g. video, authored at a clean 6.000000s) crosses it — the two
    /// renditions would then describe different newest-published sequences for the same wall-clock
    /// instant. This tolerance absorbs that rounding without letting any real, perceptible-duration
    /// segment publish early.
    private static let segmentBoundaryEpsilon: TimeInterval = 0.001

    static func completedSegmentCount(
        elapsed: TimeInterval,
        startingAtVirtualIndex start: Int,
        segments: [HLSStaticSegment]
    ) -> Int {
        let cycleDuration = segments.reduce(0) { $0 + $1.duration }
        guard elapsed >= 0, cycleDuration > 0 else { return 0 }
        let completedCycles = Int(elapsed / cycleDuration)
        var completed = completedCycles * segments.count
        var remaining = elapsed - Double(completedCycles) * cycleDuration
        while completed < (completedCycles + 1) * segments.count {
            let duration = segments[(start + completed) % segments.count].duration
            guard duration > 0, remaining >= duration - segmentBoundaryEpsilon else { break }
            remaining -= duration
            completed += 1
        }
        return completed
    }

    private static func publicationDate(
        ofVirtualIndex virtualIndex: Int,
        segments: [HLSStaticSegment],
        startedAt: Date,
        configuration: HLSPlaybackConfiguration
    ) -> Date {
        let prepublishedCount = configuration.effectiveTimeShiftMode == .coldDVR
            ? 0
            : configuration.windowSegmentCount
        if virtualIndex < prepublishedCount { return startedAt }
        let elapsed = durationBeforeVirtualIndex(virtualIndex + 1, segments: segments)
            - durationBeforeVirtualIndex(prepublishedCount, segments: segments)
        return startedAt.addingTimeInterval(elapsed)
    }

    private static func duration(
        fromVirtualIndex start: Int,
        count: Int,
        segments: [HLSStaticSegment]
    ) -> TimeInterval {
        guard count > 0, !segments.isEmpty else { return 0 }
        return (start..<(start + count)).reduce(0) { total, virtualIndex in
            total + segments[virtualIndex % segments.count].duration
        }
    }

    private static func durationBeforeVirtualIndex(_ virtualIndex: Int, segments: [HLSStaticSegment]) -> TimeInterval {
        guard virtualIndex > 0, !segments.isEmpty else { return 0 }
        let cycleDuration = segments.reduce(0) { $0 + $1.duration }
        let cycles = virtualIndex / segments.count
        let remainder = virtualIndex % segments.count
        return Double(cycles) * cycleDuration + segments.prefix(remainder).reduce(0) { $0 + $1.duration }
    }

    /// Renders a `Window` as playlist text. Every entry with a `keyLine` gets that exact line
    /// re-emitted immediately before it — deliberately non-deduplicated (repeating an identical
    /// `#EXT-X-KEY` line before every segment it applies to is valid HLS and keeps this renderer
    /// stateless per segment, rather than tracking "did the last-emitted key already match").
    static func render(_ window: Window) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(window.targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(window.mediaSequence)",
            "#EXT-X-DISCONTINUITY-SEQUENCE:\(window.discontinuitySequence)"
        ]
        if let programDateTime = window.firstSegmentProgramDateTime {
            lines.append("#EXT-X-PROGRAM-DATE-TIME:\(ISO8601DateFormatter().string(from: programDateTime))")
        }
        for entry in window.entries {
            if let keyLine = entry.segment.keyLine {
                lines.append(keyLine)
            }
            let isLoopBoundary = window.configuration.loopBoundaryTreatment == .declareDiscontinuity &&
                entry.isLoopBoundaryBefore
            if entry.segment.hasDiscontinuityBefore || isLoopBoundary {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            lines.append("#EXTINF:\(formattedDuration(entry.segment.duration)),")
            if window.configuration.segmentURIIdentity == .uniquePerMediaSequence {
                let separator = entry.segment.uri.contains("?") ? "&" : "?"
                lines.append("\(entry.segment.uri)\(separator)jp_hls_sequence=\(entry.virtualIndex)")
            } else {
                lines.append(entry.segment.uri)
            }
        }
        if window.isComplete { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func effectiveTargetDuration(
        _ source: Int,
        configuration: HLSPlaybackConfiguration
    ) -> Int {
        switch configuration.targetDurationTreatment {
        case .source: return source
        case .underreportByOneSecond: return max(1, source - 1)
        }
    }

    private static func formattedDuration(_ duration: Double) -> String {
        String(format: "%.3f", duration)
    }
}
