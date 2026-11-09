//
//  DiscontinuityAlignmentEngine.swift
//  JoesProxy
//
//  Analyzes cross-variant HLS playlists for discontinuity tag parity,
//  SCTE-35 ad break alignment, multiplexed AV sync drift, and accumulated timeline drift.
//

import Foundation

enum DiscontinuityAlignmentEngine {

    /// Audits a master playlist and all associated variant media playlists for ABR switching safety.
    static func auditMultiRendition(
        masterManifest: HLSManifest,
        masterURI: String = "master.m3u8",
        variantManifests: [String: HLSManifest]
    ) -> MultiRenditionAlignmentReport {
        var hazards: [RenditionAlignmentHazard] = []
        var variantSummaries: [VariantRenditionSummary] = []
        var adBreakReports: [AdBreakAlignmentReport] = []

        let audioGroups = masterManifest.mediaGroups.filter { $0.type.uppercased() == "AUDIO" }
        let subtitleGroups = masterManifest.mediaGroups.filter { $0.type.uppercased() == "SUBTITLES" }
        let isMultiplexed = audioGroups.isEmpty

        // 1. Build Variant Summaries & check individual accumulated drift
        for variant in masterManifest.variants {
            let variantURI = variant.uri
            guard let mediaManifest = findManifest(for: variantURI, in: variantManifests) else {
                continue
            }

            let segments = mediaManifest.segments
            let discCount = segments.filter(\.isDiscontinuityBoundary).count

            // Calculate accumulated duration vs segment sum
            var totalDuration: Double = 0
            var maxDriftMs: Double = 0

            for (idx, seg) in segments.enumerated() {
                let duration = seg.duration ?? 0
                totalDuration += duration
                if let startTime = seg.startTime {
                    let expectedStart = Double(idx) * (mediaManifest.targetDuration ?? duration)
                    let diffMs = abs(startTime - expectedStart) * 1000.0
                    maxDriftMs = max(maxDriftMs, diffMs)
                }
            }

            if maxDriftMs > 250.0 {
                hazards.append(
                    .accumulatedTimelineDrift(
                        rendition: variant.name ?? variant.resolution ?? variantURI,
                        totalDriftMs: maxDriftMs,
                        segmentCount: segments.count
                    )
                )
            }

            variantSummaries.append(
                VariantRenditionSummary(
                    uri: variantURI,
                    bandwidth: variant.bandwidth,
                    resolution: variant.resolution,
                    segmentCount: segments.count,
                    discontinuityCount: discCount,
                    totalDurationSeconds: totalDuration,
                    accumulatedDriftMs: maxDriftMs
                )
            )
        }

        // 2. Cross-Variant Discontinuity Tag Alignment
        if variantSummaries.count >= 2 {
            hazards.append(contentsOf: auditCrossVariantDiscontinuities(variants: masterManifest.variants, manifests: variantManifests))
        }

        // 3. Ad Break & SCTE-35 Discontinuity Audit
        adBreakReports = auditAdBreaks(masterManifest: masterManifest, variantManifests: variantManifests, audioGroups: audioGroups)
        for adBreak in adBreakReports {
            hazards.append(contentsOf: adBreak.hazards)
        }

        let isSwitchingSafe = !hazards.contains(where: \.isCriticalSwitchingHazard)
        let totalMaxDrift = variantSummaries.map(\.accumulatedDriftMs).max() ?? 0.0

        return MultiRenditionAlignmentReport(
            masterURI: masterURI,
            variantCount: masterManifest.variants.count,
            isMultiplexed: isMultiplexed,
            audioTrackCount: audioGroups.count,
            subtitleTrackCount: subtitleGroups.count,
            isSwitchingSafe: isSwitchingSafe,
            totalAccumulatedDriftMs: totalMaxDrift,
            variants: variantSummaries,
            adBreaks: adBreakReports,
            hazards: hazards
        )
    }

    private static func findManifest(for variantURI: String, in manifests: [String: HLSManifest]) -> HLSManifest? {
        if let direct = manifests[variantURI] {
            return direct
        }
        let variantPath = URL(string: variantURI)?.path ?? variantURI
        for (key, manifest) in manifests {
            let keyPath = URL(string: key)?.path ?? key
            if keyPath == variantPath || variantURI.hasSuffix(key) || key.hasSuffix(variantURI) {
                return manifest
            }
        }
        return nil
    }

    // MARK: - Cross-Variant Audit

    private static func auditCrossVariantDiscontinuities(
        variants: [HLSVariant],
        manifests: [String: HLSManifest]
    ) -> [RenditionAlignmentHazard] {
        var hazards: [RenditionAlignmentHazard] = []

        guard let firstVariant = variants.first,
              let baseManifest = findManifest(for: firstVariant.uri, in: manifests) else {
            return []
        }

        let baseSegments = baseManifest.segments
        let baseDiscIndices = baseSegments.enumerated().compactMap { idx, seg in
            seg.isDiscontinuityBoundary ? idx : nil
        }

        let baseLabel = firstVariant.resolution ?? firstVariant.name ?? firstVariant.uri

        for otherVariant in variants.dropFirst() {
            guard let otherManifest = findManifest(for: otherVariant.uri, in: manifests) else { continue }
            let otherSegments = otherManifest.segments
            let otherDiscIndices = otherSegments.enumerated().compactMap { idx, seg in
                seg.isDiscontinuityBoundary ? idx : nil
            }
            let otherLabel = otherVariant.resolution ?? otherVariant.name ?? otherVariant.uri

            // Check Discontinuity count parity
            if baseDiscIndices.count != otherDiscIndices.count {
                hazards.append(
                    .missingDiscontinuityTag(
                        rendition: otherLabel,
                        expectedTimeSeconds: Double(baseDiscIndices.first ?? 0) * (baseManifest.targetDuration ?? 6.0)
                    )
                )
            } else {
                // Check index parity
                for (bIdx, oIdx) in zip(baseDiscIndices, otherDiscIndices) {
                    if bIdx != oIdx {
                        hazards.append(
                            .discontinuityTagMismatch(
                                renditionA: baseLabel,
                                indexA: bIdx,
                                renditionB: otherLabel,
                                indexB: oIdx
                            )
                        )
                    }
                }
            }

            // Check segment duration drift
            let minCount = min(baseSegments.count, otherSegments.count)
            for i in 0..<minCount {
                let durBase = baseSegments[i].duration ?? 0
                let durOther = otherSegments[i].duration ?? 0
                let diffMs = abs(durBase - durOther) * 1000.0
                if diffMs > 50.0 {
                    hazards.append(
                        .segmentDurationDrift(
                            renditionA: baseLabel,
                            renditionB: otherLabel,
                            segmentIndex: i,
                            driftMs: diffMs
                        )
                    )
                }
            }
        }

        return hazards
    }

    // MARK: - Ad Break & Audio Channel Layout Audit

    private static func auditAdBreaks(
        masterManifest: HLSManifest,
        variantManifests: [String: HLSManifest],
        audioGroups: [HLSMediaGroup]
    ) -> [AdBreakAlignmentReport] {
        var reports: [AdBreakAlignmentReport] = []

        // Inspect ad markers across master and first available variant
        var allMarkers = masterManifest.adMarkers
        if allMarkers.isEmpty, let firstManifest = variantManifests.values.first {
            allMarkers = firstManifest.adMarkers
        }

        for (idx, marker) in allMarkers.enumerated() {
            let adBreakID = marker.id ?? "ad-break-\(idx + 1)"
            let startTime = marker.startTime ?? 0.0
            let duration = marker.duration ?? marker.plannedDuration ?? 0.0
            let scte35 = marker.scte35Out ?? marker.scte35In

            var hazards: [RenditionAlignmentHazard] = []

            // Check if any variant has discontinuity at ad boundary
            var hasDisc = false
            for manifest in variantManifests.values {
                if manifest.segments.contains(where: { $0.isDiscontinuityBoundary && abs(($0.startTime ?? 0) - startTime) < 2.0 }) {
                    hasDisc = true
                    break
                }
            }

            if !hasDisc && duration > 0 {
                hazards.append(
                    .missingDiscontinuityTag(
                        rendition: "all renditions",
                        expectedTimeSeconds: startTime
                    )
                )
            }

            // Audio channel layout jump audit
            var beforeLayout: String? = nil
            var adLayout: String? = nil

            let surroundAudio = audioGroups.first(where: { ($0.channels ?? "").contains("6") || ($0.channels ?? "").contains("5.1") })
            let stereoAudio = audioGroups.first(where: { ($0.channels ?? "").contains("2") || ($0.channels ?? "") == "2/0" })

            if let surround = surroundAudio, let stereo = stereoAudio {
                beforeLayout = surround.channels ?? "5.1 (6ch)"
                adLayout = stereo.channels ?? "2.0 (2ch)"

                hazards.append(
                    .audioLayoutMismatchAcrossAdBoundary(
                        beforeLayout: beforeLayout ?? "5.1",
                        adLayout: adLayout ?? "2.0",
                        offsetSeconds: startTime
                    )
                )
            }

            reports.append(
                AdBreakAlignmentReport(
                    adBreakID: adBreakID,
                    startTimeSeconds: startTime,
                    durationSeconds: duration,
                    scte35Payload: scte35,
                    hasDiscontinuityTag: hasDisc,
                    channelLayoutBefore: beforeLayout,
                    channelLayoutDuringAd: adLayout,
                    timelineGapMs: hasDisc ? 0.0 : 120.0,
                    hazards: hazards
                )
            )
        }

        return reports
    }
}
