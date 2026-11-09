//
//  HLSManifestCorrelationResolver.swift
//  JoesProxy
//
//  Correlates captured binary sessions with captured HLS manifests by referenced URI.
//

import Foundation

struct ParsedHLSManifestSession: Sendable {
    let sessionID: UUID
    let host: String
    let path: String
    let manifest: HLSManifest
}

enum HLSManifestCorrelationResolver {
    static func correlate(session: SessionRecord, within sessions: [SessionRecord]) -> HLSManifestCorrelation? {
        correlate(session: session, within: parsedManifestSessions(from: sessions))
    }

    static func correlate(session: SessionRecord, within parsedManifestSessions: [ParsedHLSManifestSession]) -> HLSManifestCorrelation? {
        guard let currentURL = MediaDetector.absoluteURL(for: session.request),
              case .video = MediaDetector.mediaType(for: session) else {
            return nil
        }

        var initMatches: [ManifestReferenceMatch] = []
        var mediaMatches: [ManifestReferenceMatch] = []

        for candidate in parsedManifestSessions where candidate.sessionID != session.id {
            if let initURI = candidate.manifest.initializationSegmentURI,
               let strategy = matchStrategy(currentURL: currentURL, referencedURI: initURI) {
                initMatches.append(
                    ManifestReferenceMatch(
                        manifestSessionID: candidate.sessionID,
                        manifestHost: candidate.host,
                        manifestPath: candidate.path,
                        matchedReference: initURI,
                        strategy: strategy
                    )
                )
            }

            for segment in candidate.manifest.segments {
                guard let strategy = matchStrategy(currentURL: currentURL, referencedURI: segment.uri) else {
                    continue
                }
                mediaMatches.append(
                    ManifestReferenceMatch(
                        manifestSessionID: candidate.sessionID,
                        manifestHost: candidate.host,
                        manifestPath: candidate.path,
                        matchedReference: segment.uri,
                        strategy: strategy
                    )
                )
                break
            }
        }

        if !initMatches.isEmpty {
            return HLSManifestCorrelation(
                referenceKind: .initSegment,
                matches: sortedMatches(initMatches)
            )
        }

        if !mediaMatches.isEmpty {
            return HLSManifestCorrelation(
                referenceKind: .mediaSegment,
                matches: sortedMatches(mediaMatches)
            )
        }

        return nil
    }

    private static func matchStrategy(currentURL: URL, referencedURI: String) -> ManifestReferenceMatch.Strategy? {
        guard let referencedURL = URL(string: referencedURI) else {
            return nil
        }
        return MediaManifestReferenceMatcher.matchStrategy(currentURL: currentURL, candidateURL: referencedURL)
    }

    private static func sortedMatches(_ matches: [ManifestReferenceMatch]) -> [ManifestReferenceMatch] {
        matches.sorted {
            if $0.manifestPath == $1.manifestPath {
                return $0.matchedReference < $1.matchedReference
            }
            return $0.manifestPath < $1.manifestPath
        }
    }

    private static func parsedManifestSessions(from sessions: [SessionRecord]) -> [ParsedHLSManifestSession] {
        sessions.compactMap { candidate in
            guard MediaDetector.mediaType(for: candidate) == .hls,
                  let response = candidate.response,
                  let bodyData = MediaDetector.decodedResponseBody(for: response),
                  let manifestText = String(data: bodyData, encoding: .utf8) else {
                return nil
            }

            let baseURL = MediaDetector.absoluteURL(for: candidate.request)
            return ParsedHLSManifestSession(
                sessionID: candidate.id,
                host: candidate.request.host,
                path: candidate.request.path,
                manifest: HLSParser.parse(manifestText, baseURL: baseURL)
            )
        }
    }
}
