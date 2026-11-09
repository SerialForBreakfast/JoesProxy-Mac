//
//  MediaSessionContextResolver.swift
//  JoesProxy
//
//  Derives product-facing labels and streaming context hints for Media Info.
//

import Foundation

struct MediaSessionLabel: Identifiable, Equatable, Sendable {
    let title: String
    let summary: String

    var id: String { title }
}

enum MediaSessionContextResolver {
    static func labels(
        for session: SessionRecord,
        structure: BinaryMediaStructure?,
        hlsManifestCorrelation: HLSManifestCorrelation? = nil,
        dashManifestCorrelation: DASHManifestCorrelation? = nil,
        timedMetadataContext: TimedMetadataAnalysisContext? = nil
    ) -> [MediaSessionLabel] {
        let mediaType = MediaDetector.mediaType(for: session)
        var labels: [MediaSessionLabel] = []

        switch mediaType {
        case .hls:
            labels.append(
                MediaSessionLabel(
                    title: "Manifest",
                    summary: "This session captured an HLS manifest response."
                )
            )
        case .dash:
            labels.append(
                MediaSessionLabel(
                    title: "Manifest",
                    summary: "This session captured a DASH MPD response."
                )
            )
        case .hlsDiscovery:
            labels.append(
                MediaSessionLabel(
                    title: "API-Discovered Stream",
                    summary: "This session exposed a stream manifest URL in API JSON rather than returning the manifest body directly."
                )
            )
        case .adXml(let kind):
            labels.append(
                MediaSessionLabel(
                    title: "Ad XML",
                    summary: "This session captured a \(kind.rawValue.uppercased()) XML ad response."
                )
            )
        case .video:
            if let structure {
                switch structure.role {
                case .initializationAsset:
                    labels.append(
                        MediaSessionLabel(
                            title: "Init Segment",
                            summary: "This binary response looks like an initialization asset, typically referenced by `EXT-X-MAP` or an equivalent stream setup step."
                        )
                    )
                case .mediaFragment, .transportSegment:
                    labels.append(
                        MediaSessionLabel(
                            title: "Media Segment",
                            summary: "This binary response looks like a playable media segment referenced by a streaming manifest."
                        )
                    )
                case .completeAsset:
                    labels.append(
                        MediaSessionLabel(
                            title: "Complete Asset",
                            summary: "This response looks like a standalone media file rather than a streaming fragment."
                        )
                    )
                case .unknown:
                    break
                }
            }
        case .image, .none:
            break
        }

        if let note = streamingContextNote(for: session, structure: structure) {
            labels.append(
                MediaSessionLabel(
                    title: "Streaming Context",
                    summary: note
                )
            )
        }

        if let hlsManifestCorrelation {
            let hostSummary = hlsManifestCorrelation.manifestHosts.joined(separator: ", ")
            let pathSummary = correlationPathSummary(hlsManifestCorrelation.matches)
            labels.append(
                MediaSessionLabel(
                    title: "Referenced By Captured HLS Manifest",
                    summary: "\(hlsManifestCorrelation.referenceKind.rawValue) matched \(hlsManifestCorrelation.manifestSessionIDs.count) captured HLS manifest session(s)" + pathSummary + (hostSummary.isEmpty ? "." : " from \(hostSummary).")
                )
            )
        }

        if let dashManifestCorrelation {
            let hostSummary = dashManifestCorrelation.manifestHosts.joined(separator: ", ")
            let pathSummary = correlationPathSummary(dashManifestCorrelation.matches)
            labels.append(
                MediaSessionLabel(
                    title: "Referenced By Captured DASH Manifest",
                    summary: "\(dashManifestCorrelation.referenceKind.rawValue) matched \(dashManifestCorrelation.manifestSessionIDs.count) captured DASH manifest session(s)" + pathSummary + (hostSummary.isEmpty ? "." : " from \(hostSummary).")
                )
            )
        }

        if case .video = mediaType, hlsManifestCorrelation == nil, dashManifestCorrelation == nil {
            labels.append(
                MediaSessionLabel(
                    title: "Manifest Correlation",
                    summary: "No matching captured HLS or DASH manifest was found for this binary response in the current session set."
                )
            )
        }

        if let timedMetadataContext, timedMetadataContext.isAnalysisAvailable {
            labels.append(
                MediaSessionLabel(
                    title: "ID3 Timed Metadata",
                    summary: "Offline ID3 analysis is available for \(timedMetadataContext.capturedCoverageSummary) in the ID3 tab."
                )
            )
        } else if let timedMetadataContext,
                  timedMetadataContext.trigger != .unavailable,
                  !timedMetadataContext.notes.isEmpty {
            labels.append(
                MediaSessionLabel(
                    title: "ID3 Timed Metadata",
                    summary: timedMetadataContext.notes.joined(separator: " ")
                )
            )
        }

        return labels
    }

    static func streamingContextNote(for session: SessionRecord, structure: BinaryMediaStructure?) -> String? {
        let mediaType = MediaDetector.mediaType(for: session)
        switch mediaType {
        case .hls:
            return "Use this manifest alongside captured init segments and media segments to understand bitrate ladders, segment URLs, keys, and ad timing."
        case .dash:
            return "Use this MPD alongside captured init assets and fragments to understand representations, segment templates, and content protection."
        case .hlsDiscovery:
            return "This API response is the bridge between playback setup and the actual manifest/segment requests."
        case .video:
            guard let structure else { return nil }
            switch structure.role {
            case .initializationAsset:
                return "Initialization assets usually pair with manifest-level segment references and set up tracks/codecs before media fragments arrive."
            case .mediaFragment, .transportSegment:
                return "Media segments are most useful when read next to the manifest that referenced them, especially for DRM, ad markers, and timeline context."
            case .completeAsset:
                return "This looks more like a standalone media asset than a segmented stream response."
            case .unknown:
                return nil
            }
        case .adXml:
            return "Use this captured ad XML alongside manifest ad markers and creative fetches to understand client-side or stitched ad delivery."
        case .image, .none:
            return nil
        }
    }

    private static func correlationPathSummary(_ matches: [ManifestReferenceMatch]) -> String {
        let paths = Array(Set(matches.map(\.manifestPath))).sorted()
        guard !paths.isEmpty else {
            return "."
        }

        let preview = paths.prefix(2).joined(separator: ", ")
        if paths.count > 2 {
            return " in \(preview), and \(paths.count - 2) more"
        }

        return " in \(preview)"
    }
}
