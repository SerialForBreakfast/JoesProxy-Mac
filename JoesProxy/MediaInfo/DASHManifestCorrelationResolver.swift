//
//  DASHManifestCorrelationResolver.swift
//  JoesProxy
//
//  Correlates captured binary sessions with captured DASH MPD manifests via segment templates.
//

import Foundation

struct ParsedDASHManifestSession: Sendable {
    let sessionID: UUID
    let host: String
    let path: String
    let manifestURL: URL?
    let manifest: DASHManifest
}

enum DASHManifestCorrelationResolver {
    static func correlate(session: SessionRecord, within sessions: [SessionRecord]) -> DASHManifestCorrelation? {
        correlate(session: session, within: parsedManifestSessions(from: sessions))
    }

    static func correlate(session: SessionRecord, within parsedManifestSessions: [ParsedDASHManifestSession]) -> DASHManifestCorrelation? {
        guard let currentURL = MediaDetector.absoluteURL(for: session.request),
              case .video = MediaDetector.mediaType(for: session) else {
            return nil
        }

        var initMatches: [ManifestReferenceMatch] = []
        var mediaMatches: [ManifestReferenceMatch] = []

        for candidate in parsedManifestSessions where candidate.sessionID != session.id {
            let references = manifestTemplateReferences(from: candidate.manifest)

            for reference in references {
                guard let strategy = match(
                    currentURL: currentURL,
                    template: reference.template,
                    baseURL: reference.baseURL,
                    manifestURL: candidate.manifestURL,
                    representationID: reference.representationID,
                    bandwidth: reference.bandwidth
                ) else {
                    continue
                }

                let match = ManifestReferenceMatch(
                    manifestSessionID: candidate.sessionID,
                    manifestHost: candidate.host,
                    manifestPath: candidate.path,
                    matchedReference: reference.template,
                    strategy: strategy
                )

                switch reference.kind {
                case .initSegment:
                    initMatches.append(match)
                case .mediaSegment:
                    mediaMatches.append(match)
                }
            }
        }

        if !initMatches.isEmpty {
            return DASHManifestCorrelation(referenceKind: .initSegment, matches: sortedMatches(initMatches))
        }

        if !mediaMatches.isEmpty {
            return DASHManifestCorrelation(referenceKind: .mediaSegment, matches: sortedMatches(mediaMatches))
        }

        return nil
    }

    private static func sortedMatches(_ matches: [ManifestReferenceMatch]) -> [ManifestReferenceMatch] {
        matches.sorted {
            if $0.manifestPath == $1.manifestPath {
                return $0.matchedReference < $1.matchedReference
            }
            return $0.manifestPath < $1.manifestPath
        }
    }

    private static func manifestTemplateReferences(from manifest: DASHManifest) -> [TemplateReference] {
        manifest.periods.flatMap { period in
            period.adaptationSets.flatMap { adaptationSet in
                adaptationSet.representations.flatMap { representation in
                    let template = representation.segmentTemplate ?? adaptationSet.segmentTemplate
                    let baseURL = representation.baseURL
                        ?? adaptationSet.baseURL
                        ?? manifest.baseURL
                    var references: [TemplateReference] = []
                    if let initialization = template?.initialization {
                        references.append(
                            TemplateReference(
                                kind: .initSegment,
                                template: initialization,
                                baseURL: baseURL,
                                representationID: representation.id,
                                bandwidth: representation.bandwidth
                            )
                        )
                    }
                    if let media = template?.media {
                        references.append(
                            TemplateReference(
                                kind: .mediaSegment,
                                template: media,
                                baseURL: baseURL,
                                representationID: representation.id,
                                bandwidth: representation.bandwidth
                            )
                        )
                    }
                    return references
                }
            }
        }
    }

    private static func match(
        currentURL: URL,
        template: String,
        baseURL: String?,
        manifestURL: URL?,
        representationID: String?,
        bandwidth: Int?
    ) -> ManifestReferenceMatch.Strategy? {
        let wildcard = "__JOESPROXY_WILDCARD__"
        let renderedTemplate = renderTemplate(
            template,
            wildcard: wildcard,
            representationID: representationID,
            bandwidth: bandwidth
        )

        let resolvedString = resolveReference(renderedTemplate, baseURL: baseURL, manifestURL: manifestURL)
        if !resolvedString.contains(wildcard), let resolvedURL = URL(string: resolvedString) {
            return MediaManifestReferenceMatcher.matchStrategy(currentURL: currentURL, candidateURL: resolvedURL)
        }

        guard let pattern = regexPattern(for: resolvedString, wildcard: wildcard),
              currentURL.absoluteString.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return .templatePattern
    }

    private static func renderTemplate(
        _ template: String,
        wildcard: String,
        representationID: String?,
        bandwidth: Int?
    ) -> String {
        var rendered = template.replacingOccurrences(of: "$$", with: "$")
        rendered = rendered.replacingOccurrences(of: "$RepresentationID$", with: representationID ?? wildcard)
        rendered = rendered.replacingOccurrences(of: "$Bandwidth$", with: bandwidth.map(String.init) ?? wildcard)

        let placeholderPatterns = [
            #"\$Number(%0\d+d)?\$"#,
            #"\$Time(%0\d+d)?\$"#,
            #"\$SubNumber(%0\d+d)?\$"#
        ]

        for pattern in placeholderPatterns {
            rendered = rendered.replacingOccurrences(
                of: pattern,
                with: wildcard,
                options: .regularExpression
            )
        }

        return rendered
    }

    private static func resolveReference(_ reference: String, baseURL: String?, manifestURL: URL?) -> String {
        if let absolute = URL(string: reference), absolute.scheme != nil {
            return absolute.absoluteString
        }

        let resolvedBaseURL = resolvedBaseURLString(baseURL, manifestURL: manifestURL)
        guard let resolvedBaseURL,
              let base = URL(string: resolvedBaseURL),
              let resolved = URL(string: reference, relativeTo: base)?.absoluteURL else {
            return reference
        }

        return resolved.absoluteString
    }

    private static func resolvedBaseURLString(_ baseURL: String?, manifestURL: URL?) -> String? {
        guard let baseURL else {
            return manifestURL?.absoluteString
        }

        if let absolute = URL(string: baseURL), absolute.scheme != nil {
            return absolute.absoluteString
        }

        guard let manifestURL,
              let resolved = URL(string: baseURL, relativeTo: manifestURL)?.absoluteURL else {
            return baseURL
        }

        return resolved.absoluteString
    }

    private static func regexPattern(for value: String, wildcard: String) -> String? {
        let pieces = value.components(separatedBy: wildcard).map(NSRegularExpression.escapedPattern(for:))
        guard !pieces.isEmpty else { return nil }
        return "^" + pieces.joined(separator: "[^?#]+") + "$"
    }

    private static func parsedManifestSessions(from sessions: [SessionRecord]) -> [ParsedDASHManifestSession] {
        sessions.compactMap { candidate in
            guard MediaDetector.mediaType(for: candidate) == .dash,
                  let response = candidate.response,
                  let bodyData = MediaDetector.decodedResponseBody(for: response),
                  let manifestText = String(data: bodyData, encoding: .utf8),
                  let manifest = DASHParser.parse(manifestText) else {
                return nil
            }

            return ParsedDASHManifestSession(
                sessionID: candidate.id,
                host: candidate.request.host,
                path: candidate.request.path,
                manifestURL: MediaDetector.absoluteURL(for: candidate.request),
                manifest: manifest
            )
        }
    }
}

private struct TemplateReference {
    let kind: MediaManifestReferenceKind
    let template: String
    let baseURL: String?
    let representationID: String?
    let bandwidth: Int?
}
