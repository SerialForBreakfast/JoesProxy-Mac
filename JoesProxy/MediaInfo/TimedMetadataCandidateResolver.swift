//
//  TimedMetadataCandidateResolver.swift
//  JoesProxy
//
//  Manifest-aware ID3 analysis candidate resolution for Media Info.
//

import Foundation

/// Why Media Info considers ID3 timed-metadata analysis relevant for the selected session.
enum TimedMetadataAnalysisTrigger: String, Sendable, Equatable {
    case hlsMediaPlaylist = "HLS Media Playlist"
    case hlsMasterPlaylist = "HLS Master Playlist"
    case capturedMediaSegment = "Captured Media Segment"
    case unavailable = "Unavailable"
}

/// One captured media segment eligible for offline ID3 inspection.
struct TimedMetadataCandidate: Sendable, Equatable {
    let sessionID: UUID
    let segmentSequence: Int?
    let relativePlaybackTime: TimeInterval?
    let matchedURI: String?
}

/// Manifest-aware summary of which captured segments can be inspected for ID3 markers.
struct TimedMetadataAnalysisContext: Sendable, Equatable {
    /// Upper bound on segments analyzed in one user-initiated batch to keep Media Info responsive.
    static let maximumBatchSize = 200

    let trigger: TimedMetadataAnalysisTrigger
    let isAnalysisAvailable: Bool
    let referencedSegmentCount: Int
    let capturedSegmentCount: Int
    let candidates: [TimedMetadataCandidate]
    let notes: [String]

    /// Human-readable capture coverage for playlist-driven analysis.
    var capturedCoverageSummary: String {
        guard referencedSegmentCount > 0 else {
            return "\(capturedSegmentCount) captured segment(s)"
        }
        return "\(capturedSegmentCount)/\(referencedSegmentCount) playlist segments captured"
    }
}

/// Resolves ID3 analysis candidates from HLS manifests and correlated captured segment sessions.
///
/// Concurrency: this type is stateless and `Sendable`; callers run batch parsing off the main actor.
enum TimedMetadataCandidateResolver {
    /// Resolves only the selected Media Info item. It never expands a playlist into related captures.
    static func selectedItemContext(
        for session: SessionRecord,
        parsedHLSManifestSessions: [ParsedHLSManifestSession],
        sessions: [SessionRecord]
    ) -> TimedMetadataAnalysisContext {
        guard case .video = MediaDetector.mediaType(for: session) else {
            return unavailableContext(
                trigger: .unavailable,
                notes: ["Open Media Info for an individual captured media segment to inspect ID3 metadata."]
            )
        }

        return capturedSegmentContext(
            segmentSession: session,
            parsedHLSManifestSessions: parsedHLSManifestSessions,
            sessions: sessions
        )
    }

    static func context(
        for session: SessionRecord,
        parsedHLSManifestSessions: [ParsedHLSManifestSession],
        sessions: [SessionRecord]
    ) -> TimedMetadataAnalysisContext {
        switch MediaDetector.mediaType(for: session) {
        case .hls:
            guard let manifest = parsedManifest(for: session) else {
                return unavailableContext(
                    trigger: .unavailable,
                    notes: ["The captured HLS manifest body could not be decoded for ID3 candidate resolution."]
                )
            }

            if manifest.isMasterPlaylist {
                return masterPlaylistContext(
                    masterSession: session,
                    manifest: manifest,
                    parsedHLSManifestSessions: parsedHLSManifestSessions,
                    sessions: sessions
                )
            }

            return mediaPlaylistContext(
                manifest: manifest,
                parsedHLSManifestSessions: parsedHLSManifestSessions,
                sessions: sessions
            )
        case .video:
            return capturedSegmentContext(
                segmentSession: session,
                parsedHLSManifestSessions: parsedHLSManifestSessions,
                sessions: sessions
            )
        case .hlsDiscovery, .dash, .image, .adXml, .none:
            return unavailableContext(trigger: .unavailable, notes: [])
        }
    }

    /// Snapshot only referenced records before crossing into a background worker.
    static func capturedSessions(for candidates: [TimedMetadataCandidate], in sessions: [SessionRecord]) -> [SessionRecord] {
        let ids = Set(candidates.map(\.sessionID))
        return sessions.filter { ids.contains($0.id) }
    }

    /// Runs offline ID3 inspection; cancellation is forwarded into the parser.
    static func analyze(
        candidates: [TimedMetadataCandidate],
        sessions: [SessionRecord],
        parser: TimedMetadataID3Parser = TimedMetadataID3Parser(),
        shouldCancel: () -> Bool = { false }
    ) -> [TimedMetadataDetectionResult] {
        candidates.compactMap { candidate in
            guard !shouldCancel(),
                  let segmentSession = sessions.first(where: { $0.id == candidate.sessionID }),
                  let response = segmentSession.response,
                  let bodyData = MediaDetector.decodedResponseBody(for: response) else {
                return nil
            }

            let result = parser.analyze(
                data: bodyData,
                assetID: segmentSession.id,
                assetURL: MediaDetector.absoluteURL(for: segmentSession.request),
                segmentSequence: candidate.segmentSequence,
                relativePlaybackTime: candidate.relativePlaybackTime,
                shouldCancel: shouldCancel
            )
            return shouldCancel() ? nil : result
        }
    }

    private static func mediaPlaylistContext(
        manifest: HLSManifest,
        parsedHLSManifestSessions: [ParsedHLSManifestSession],
        sessions: [SessionRecord]
    ) -> TimedMetadataAnalysisContext {
        let resolution = candidatesForMediaPlaylist(
            manifest: manifest,
            sessions: sessions
        )
        var notes = resolution.notes
        notes.append("Timed metadata analysis uses captured segment bytes; the playlist itself does not prove ID3 is present.")

        let limited = limitCandidates(resolution.candidates, notes: &notes)
        return TimedMetadataAnalysisContext(
            trigger: .hlsMediaPlaylist,
            isAnalysisAvailable: !limited.isEmpty,
            referencedSegmentCount: manifest.segments.count,
            capturedSegmentCount: limited.count,
            candidates: limited,
            notes: notes
        )
    }

    private static func masterPlaylistContext(
        masterSession: SessionRecord,
        manifest: HLSManifest,
        parsedHLSManifestSessions: [ParsedHLSManifestSession],
        sessions: [SessionRecord]
    ) -> TimedMetadataAnalysisContext {
        let referencedPlaylistURIs = referencedChildPlaylistURIs(from: manifest)
        let childManifestSessions = parsedHLSManifestSessions.filter { parsed in
            guard !parsed.manifest.isMasterPlaylist,
                  let manifestSession = sessions.first(where: { $0.id == parsed.sessionID }),
                  let manifestURL = MediaDetector.absoluteURL(for: manifestSession.request) else {
                return false
            }

            return referencedPlaylistURIs.contains { referencedURI in
                guard let referencedURL = URL(string: referencedURI) else { return false }
                return MediaManifestReferenceMatcher.matchStrategy(
                    currentURL: manifestURL,
                    candidateURL: referencedURL
                ) != nil
            }
        }

        var candidates: [TimedMetadataCandidate] = []
        var referencedSegmentCount = 0
        var notes: [String] = []

        for child in childManifestSessions {
            referencedSegmentCount += child.manifest.segments.count
            let resolution = candidatesForMediaPlaylist(manifest: child.manifest, sessions: sessions)
            candidates.append(contentsOf: resolution.candidates)
            notes.append(contentsOf: resolution.notes)
        }

        if childManifestSessions.isEmpty {
            notes.append(
                "This is a master playlist. Capture one or more referenced media playlists to inspect their segments for ID3 markers."
            )
        } else if candidates.isEmpty {
            notes.append(
                "Captured media playlists were found, but none of their referenced segments are available in this recording."
            )
        }

        notes.append("Timed metadata analysis uses captured segment bytes; playlists do not prove ID3 is present.")

        var seenSessionIDs = Set<UUID>()
        candidates = candidates.filter { seenSessionIDs.insert($0.sessionID).inserted }
        candidates.sort {
            let lhsSequence = $0.segmentSequence ?? Int.max
            let rhsSequence = $1.segmentSequence ?? Int.max
            if lhsSequence == rhsSequence {
                return ($0.matchedURI ?? "") < ($1.matchedURI ?? "")
            }
            return lhsSequence < rhsSequence
        }

        let limited = limitCandidates(candidates, notes: &notes)
        return TimedMetadataAnalysisContext(
            trigger: .hlsMasterPlaylist,
            isAnalysisAvailable: !limited.isEmpty,
            referencedSegmentCount: referencedSegmentCount,
            capturedSegmentCount: limited.count,
            candidates: limited,
            notes: notes
        )
    }

    private static func capturedSegmentContext(
        segmentSession: SessionRecord,
        parsedHLSManifestSessions: [ParsedHLSManifestSession],
        sessions: [SessionRecord]
    ) -> TimedMetadataAnalysisContext {
        guard let response = segmentSession.response else {
            return unavailableContext(
                trigger: .capturedMediaSegment,
                notes: ["This media segment has no captured response body to inspect."]
            )
        }

        guard MediaDetector.decodedResponseBody(for: response) != nil else {
            return unavailableContext(
                trigger: .capturedMediaSegment,
                notes: ["This media segment body is unavailable or could not be decoded for analysis."]
            )
        }

        let metadata = segmentMetadata(
            for: segmentSession,
            parsedHLSManifestSessions: parsedHLSManifestSessions
        )
        let candidate = TimedMetadataCandidate(
            sessionID: segmentSession.id,
            segmentSequence: metadata?.sequence,
            relativePlaybackTime: metadata?.startTime,
            matchedURI: metadata?.uri
        )

        var notes = ["Analyzing the selected captured media segment."]
        if metadata == nil {
            notes.append("No matching captured HLS manifest was found; playback timing may be unavailable.")
        }

        return TimedMetadataAnalysisContext(
            trigger: .capturedMediaSegment,
            isAnalysisAvailable: true,
            referencedSegmentCount: 1,
            capturedSegmentCount: 1,
            candidates: [candidate],
            notes: notes
        )
    }

    private static func candidatesForMediaPlaylist(
        manifest: HLSManifest,
        sessions: [SessionRecord]
    ) -> (candidates: [TimedMetadataCandidate], notes: [String]) {
        var candidates: [TimedMetadataCandidate] = []
        var seenSessionIDs = Set<UUID>()
        var notes: [String] = []

        for (index, segment) in manifest.segments.enumerated() {
            guard let segmentURL = URL(string: segment.uri),
                  let capturedSession = capturedVideoSession(matching: segmentURL, in: sessions),
                  seenSessionIDs.insert(capturedSession.id).inserted else {
                continue
            }

            guard capturedSession.response != nil,
                  MediaDetector.decodedResponseBody(for: capturedSession.response!) != nil else {
                notes.append("Segment \(segment.uri) was referenced but its captured body is unavailable.")
                continue
            }

            candidates.append(
                TimedMetadataCandidate(
                    sessionID: capturedSession.id,
                    segmentSequence: index,
                    relativePlaybackTime: segment.startTime,
                    matchedURI: segment.uri
                )
            )
        }

        return (candidates, notes)
    }

    private static func segmentMetadata(
        for segmentSession: SessionRecord,
        parsedHLSManifestSessions: [ParsedHLSManifestSession]
    ) -> (sequence: Int, startTime: Double?, uri: String)? {
        guard let currentURL = MediaDetector.absoluteURL(for: segmentSession.request) else {
            return nil
        }

        for manifestSession in parsedHLSManifestSessions {
            for (index, segment) in manifestSession.manifest.segments.enumerated() {
                guard let segmentURL = URL(string: segment.uri),
                      MediaManifestReferenceMatcher.matchStrategy(
                        currentURL: currentURL,
                        candidateURL: segmentURL
                      ) != nil else {
                    continue
                }
                return (index, segment.startTime, segment.uri)
            }
        }

        return nil
    }

    private static func capturedVideoSession(matching url: URL, in sessions: [SessionRecord]) -> SessionRecord? {
        sessions.first { candidate in
            guard case .video = MediaDetector.mediaType(for: candidate),
                  let currentURL = MediaDetector.absoluteURL(for: candidate.request) else {
                return false
            }
            return MediaManifestReferenceMatcher.matchStrategy(currentURL: currentURL, candidateURL: url) != nil
        }
    }

    private static func parsedManifest(for session: SessionRecord) -> HLSManifest? {
        guard MediaDetector.mediaType(for: session) == .hls,
              let response = session.response,
              let bodyData = MediaDetector.decodedResponseBody(for: response),
              let manifestText = String(data: bodyData, encoding: .utf8) else {
            return nil
        }

        return HLSParser.parse(
            manifestText,
            baseURL: MediaDetector.absoluteURL(for: session.request)
        )
    }

    private static func referencedChildPlaylistURIs(from manifest: HLSManifest) -> [String] {
        var uris = manifest.variants.map(\.uri)
        uris.append(contentsOf: manifest.mediaGroups.compactMap(\.uri))
        return Array(Set(uris))
    }

    private static func limitCandidates(
        _ candidates: [TimedMetadataCandidate],
        notes: inout [String]
    ) -> [TimedMetadataCandidate] {
        guard candidates.count > TimedMetadataAnalysisContext.maximumBatchSize else {
            return candidates
        }

        notes.append(
            "Analysis is limited to the first \(TimedMetadataAnalysisContext.maximumBatchSize) captured segments in this batch."
        )
        return Array(candidates.prefix(TimedMetadataAnalysisContext.maximumBatchSize))
    }

    private static func unavailableContext(
        trigger: TimedMetadataAnalysisTrigger,
        notes: [String]
    ) -> TimedMetadataAnalysisContext {
        TimedMetadataAnalysisContext(
            trigger: trigger,
            isAnalysisAvailable: false,
            referencedSegmentCount: 0,
            capturedSegmentCount: 0,
            candidates: [],
            notes: notes
        )
    }
}
