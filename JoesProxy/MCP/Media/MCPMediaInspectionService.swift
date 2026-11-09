import CryptoKit
import Foundation

struct MCPMediaInspectionSource: Sendable {
    var sessionID: SessionRecord.ID
    var data: Data
    var fileExtension: String
    var displayName: String
    var reportedOriginalBytes: Int?
    var bodyTruncated: Bool

    init(
        sessionID: SessionRecord.ID,
        data: Data,
        fileExtension: String,
        displayName: String,
        reportedOriginalBytes: Int? = nil,
        bodyTruncated: Bool = false
    ) {
        self.sessionID = sessionID
        self.data = data
        self.fileExtension = fileExtension
        self.displayName = displayName
        self.reportedOriginalBytes = reportedOriginalBytes
        self.bodyTruncated = bodyTruncated
    }
}

@MainActor
protocol MCPMediaOperationServicing: AnyObject {
    func inspectionSource(
        sessionID: SessionRecord.ID,
        analyses: [MCPMediaAnalysisKind]
    ) throws -> MCPMediaInspectionSource

    func inspect(
        source: MCPMediaInspectionSource,
        analyses: [MCPMediaAnalysisKind],
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        progress: @MainActor (Double, String) -> Void
    ) async throws -> MCPMediaInspectionResultDTO
}

@MainActor
final class MCPMediaInspectionService: MCPMediaOperationServicing {
    struct RelatedItem: Sendable {
        var sessionID: SessionRecord.ID
        var relationship: String
        var matchStrategy: String
    }

    struct RelatedResult: Sendable {
        var items: [RelatedItem]
        var status: String
        var candidateCount: Int
        var skippedBodyReasons: [String: Int]
        var attemptedStrategies: [String]
        var indexedThroughSequence: UInt64
    }

    private struct CachedRelatedResult {
        var indexedThroughSequence: UInt64
        var result: RelatedResult
    }

    private let sessionStore: any SessionStore
    private let snapshotService: MCPSessionSnapshotService
    private var correlationEpoch: MCPCaptureEpoch = .initial
    private var correlationIndexedThrough: UInt64 = 0
    private var indexedHLSManifests: [ParsedHLSManifestSession] = []
    private var indexedDASHManifests: [ParsedDASHManifestSession] = []
    private var correlationSkippedBodyReasons: [String: Int] = [:]
    private var pendingCorrelationSessions: [SessionRecord.ID: String] = [:]
    private var relatedResultCache: [SessionRecord.ID: CachedRelatedResult] = [:]

    init(sessionStore: any SessionStore, snapshotService: MCPSessionSnapshotService) {
        self.sessionStore = sessionStore
        self.snapshotService = snapshotService
    }

    func summary(
        sessionID: SessionRecord.ID,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPMediaSummaryDTO {
        guard let indexed = snapshotService.indexedSession(id: sessionID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Media session was not found.")
        }
        let record = indexed.record
        let mediaType = MediaDetector.mediaType(for: record)
        guard mediaType != .none else {
            throw MCPStructuredError(code: .malformedRequest, message: "The selected session is not recognized media.")
        }
        let response = record.response
        var aggregateCounts: [String: Int] = [:]
        var manifestKind: String?
        let containerKind = mediaType == .hls || mediaType == .dash
            ? nil
            : inferredContainerKind(for: record)

        if let body = decodedBody(record), let text = String(data: body, encoding: .utf8) {
            switch mediaType {
            case .hls:
                let manifest = HLSParser.parse(text, baseURL: nil)
                manifestKind = manifest.isMasterPlaylist ? "hls_master" : "hls_media"
                aggregateCounts = [
                    "variants": manifest.variants.count,
                    "renditions": manifest.mediaGroups.count,
                    "segments": manifest.segments.count,
                    "keys": manifest.keys.count,
                    "adMarkers": manifest.adMarkers.count
                ]
            case .dash:
                if let manifest = DASHParser.parse(text) {
                    manifestKind = "dash"
                    let adaptations = manifest.periods.flatMap(\.adaptationSets)
                    aggregateCounts = [
                        "periods": manifest.periods.count,
                        "adaptationSets": adaptations.count,
                        "representations": adaptations.flatMap(\.representations).count,
                        "protectionSchemes": manifest.contentProtection.count
                    ]
                }
            default:
                break
            }
        }

        return MCPMediaSummaryDTO(
            sessionID: record.id.uuidString,
            captureSequence: indexed.captureSequence,
            mediaType: mediaTypeName(mediaType),
            mimeCategory: response.flatMap(contentType),
            bodyAvailable: response?.bodyData?.isEmpty == false,
            bodyDeferred: response?.bodyDeferred ?? false,
            bodyOmitted: response?.recordingBodyOmissionReason != nil,
            bodyTruncated: response?.bodyTruncated ?? false,
            capturedBodyBytes: response?.bodyData?.count,
            startedAt: record.timing.startedAt,
            durationSeconds: record.timing.duration,
            manifestKind: manifestKind,
            containerKind: containerKind,
            aggregateCounts: aggregateCounts,
            disclosure: disclosure(policyRevision: policyRevision)
        )
    }

    func mediaReadiness(
        sessionID: SessionRecord.ID,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPMediaReadinessDTO {
        guard let indexed = snapshotService.indexedSession(id: sessionID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Media session was not found.")
        }
        let record = indexed.record
        let mediaType = MediaDetector.mediaType(for: record)
        guard mediaType != .none else {
            throw MCPStructuredError(code: .malformedRequest, message: "The selected session is not recognized media.")
        }

        let bodyEligibility = bodyEligibility(for: record)
        MCPLog.media.info(
            "Classified media session \(record.id.uuidString, privacy: .public) as \(self.mediaTypeName(mediaType), privacy: .public) with body state \(bodyEligibility.rawValue, privacy: .public)."
        )
        let capturedBytes = decodedBody(record)?.count ?? 0
        let bodyAvailable = capturedBytes > 0
        let supportedAnalyses = analysisEligibility(for: record, mediaType: mediaType, bodyAvailable: bodyAvailable)
        var supportedTools: [String] = ["media_summary", "media_readiness", "media_context"]
        if bodyAvailable {
            switch mediaType {
            case .hls, .dash:
                supportedTools.append(contentsOf: ["media_manifest_structure", "media_related_sessions"])
            case .video, .hlsDiscovery:
                supportedTools.append("media_related_sessions")
            default:
                break
            }
            if supportedAnalyses.contains(where: { $0.eligible && $0.kind != MCPMediaAnalysisKind.liveMediaEngine.rawValue }) {
                supportedTools.append("media_inspection_start")
            }
        }
        if MediaDetector.primaryMediaURL(for: record) != nil {
            supportedTools.append("live_media_probe_start")
        }

        let workflow = recommendedWorkflow(for: mediaType, bodyAvailable: bodyAvailable, record: record)
        let requiresShareable = workflow?.requiresApproval == true

        return MCPMediaReadinessDTO(
            sessionID: record.id.uuidString,
            mediaType: mediaTypeName(mediaType),
            bodyEligibility: bodyEligibility,
            supportedTools: supportedTools,
            supportedAnalyses: supportedAnalyses,
            recommendedWorkflowID: workflow?.id,
            recommendedNextTools: workflow?.steps ?? ["media_summary"],
            requiresShareableProfile: requiresShareable,
            disclosure: disclosure(policyRevision: policyRevision)
        )
    }

    func mediaContext(
        sessionID: SessionRecord.ID,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPMediaContextDTO {
        guard let record = sessionStore.record(for: sessionID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Media session was not found.")
        }
        let mediaType = MediaDetector.mediaType(for: record)
        guard mediaType != .none else {
            throw MCPStructuredError(code: .malformedRequest, message: "The selected session is not recognized media.")
        }

        let labels = MediaSessionContextResolver.labels(for: record, structure: nil)
            .map { MCPMediaContextLabelDTO(title: $0.title, summary: $0.summary) }
        let hlsDiscovery = MediaDetector.hlsDiscovery(for: record).map {
            sanitizedHLSDiscovery($0, requestHost: record.request.host)
        }
        let deliverySummary = MediaDeliveryHeaderSummary.from(
            response: record.response,
            mediaType: mediaType,
            structure: nil
        )
        let deliveryHeaders = deliverySummary?.items.map {
            MCPMediaDeliveryHeaderDTO(name: $0.name, value: $0.value)
        } ?? []

        return MCPMediaContextDTO(
            sessionID: record.id.uuidString,
            contextLabels: labels,
            hlsDiscovery: hlsDiscovery,
            deliveryHeaders: deliveryHeaders,
            mimeCategory: record.response.flatMap(contentType),
            containerKind: mediaType == .hls || mediaType == .dash ? nil : inferredContainerKind(for: record),
            disclosure: disclosure(
                policyRevision: policyRevision,
                removedFields: ["rawURLs", "queryValues", "signedTokens", "manifestText"]
            )
        )
    }

    func manifestStructure(
        sessionID: SessionRecord.ID,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPMediaManifestStructureDTO {
        guard let record = sessionStore.record(for: sessionID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Media session was not found.")
        }
        guard let data = decodedBody(record),
              let text = String(data: data, encoding: .utf8) else {
            throw ineligibleBodyError(record)
        }

        switch MediaDetector.mediaType(for: record) {
        case .hls:
            let manifest = HLSParser.parse(text, baseURL: nil)
            let variantLocators = (try? HLSCODECSEditTransformer.variantLocators(in: data)) ?? []
            let captureSequence = snapshotService.indexedSession(id: sessionID)?.captureSequence ?? 0
            let bodyDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let codecs = manifest.variants.compactMap(\.codecs)
                .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            let itemLimit = 100
            let truncated = manifest.variants.count > itemLimit || manifest.mediaGroups.count > itemLimit
            let unsupportedVariantCount = text
                .split(whereSeparator: \.isNewline)
                .filter {
                    let line = $0.trimmingCharacters(in: .whitespaces)
                    return line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
                        || line.hasPrefix("#EXT-X-IMAGE-STREAM-INF:")
                }
                .count
            return MCPMediaManifestStructureDTO(
                sessionID: sessionID.uuidString,
                kind: "hls",
                playlistKind: manifest.isMasterPlaylist ? "master" : "media",
                version: manifest.version,
                presentationType: nil,
                duration: nil,
                targetDurationSeconds: manifest.targetDuration,
                counts: [
                    "variants": manifest.variants.count,
                    "renditions": manifest.mediaGroups.count,
                    "segments": manifest.segments.count,
                    "keys": manifest.keys.count,
                    "adMarkers": manifest.adMarkers.count,
                    "adBreaks": manifest.adBreaks.count,
                    "discontinuities": manifest.segments.count(where: \.isDiscontinuityBoundary)
                ],
                unsupportedVariantCount: unsupportedVariantCount,
                codecs: Array(Set(codecs)).sorted(),
                resolutions: Array(Set(manifest.variants.compactMap(\.resolution))).sorted(),
                bandwidths: Array(Set(manifest.variants.compactMap(\.bandwidth))).sorted(),
                protectionSchemes: Array(Set(manifest.keys.compactMap(\.keyFormat))).sorted(),
                hasContentSteering: manifest.contentSteering != nil,
                hasSegmentTemplate: false,
                hlsVariants: manifest.variants.prefix(itemLimit).enumerated().map { index, variant in
                    MCPHLSVariantDTO(
                        variantRef: hlsVariantReference(
                            sessionID: sessionID,
                            captureSequence: captureSequence,
                            bodyDigest: bodyDigest,
                            ordinal: index,
                            lineDigest: variantLocators.indices.contains(index)
                                ? variantLocators[index].streamInfoLineDigest
                                : nil,
                            uriDigest: variantLocators.indices.contains(index)
                                ? variantLocators[index].followingURIlineDigest
                                : nil
                        ),
                        bandwidth: variant.bandwidth,
                        averageBandwidth: variant.averageBandwidth,
                        resolution: variant.resolution,
                        codecs: variant.codecs?.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        } ?? [],
                        frameRate: variant.frameRate,
                        videoRange: variant.videoRange,
                        hdcpLevel: variant.hdcpLevel
                    )
                },
                hlsRenditions: manifest.mediaGroups.prefix(itemLimit).map {
                    MCPHLSRenditionDTO(
                        type: $0.type,
                        language: $0.language,
                        isDefault: $0.isDefault,
                        autoSelect: $0.autoSelect,
                        isForced: $0.isForced
                    )
                },
                dashRepresentations: [],
                segmentTemplates: [],
                disclosure: disclosure(
                    policyRevision: policyRevision,
                    removedFields: ["manifestText", "urls", "queryValues", "keyURIs", "keyIVs"],
                    partialReason: truncated ? "Manifest item details were truncated to 100 entries per collection." : nil,
                    truncated: truncated
                )
            )
        case .dash:
            guard let manifest = DASHParser.parse(text) else {
                throw MCPStructuredError(code: .malformedRequest, message: "The captured DASH manifest could not be parsed.")
            }
            let adaptations = manifest.periods.flatMap(\.adaptationSets)
            let representations = adaptations.flatMap(\.representations)
            let codecs = adaptations.compactMap(\.codecs) + representations.compactMap(\.codecs)
            let resolutions = representations.compactMap { representation -> String? in
                guard let width = representation.width, let height = representation.height else { return nil }
                return "\(width)x\(height)"
            }
            let hasTemplate = adaptations.contains { $0.segmentTemplate != nil }
                || representations.contains { $0.segmentTemplate != nil }
            let itemLimit = 100
            let representationItems = adaptations.flatMap { adaptation in
                adaptation.representations.map { representation in
                    MCPDASHRepresentationDTO(
                        contentType: adaptation.contentType,
                        language: adaptation.lang,
                        mimeType: representation.mimeType ?? adaptation.mimeType,
                        codecs: representation.codecs ?? adaptation.codecs,
                        bandwidth: representation.bandwidth,
                        width: representation.width,
                        height: representation.height,
                        frameRate: representation.frameRate,
                        audioSamplingRate: representation.audioSamplingRate
                    )
                }
            }
            let templates = adaptations.compactMap(\.segmentTemplate)
                + representations.compactMap(\.segmentTemplate)
            let truncated = representationItems.count > itemLimit || templates.count > itemLimit
            return MCPMediaManifestStructureDTO(
                sessionID: sessionID.uuidString,
                kind: "dash",
                playlistKind: nil,
                version: nil,
                presentationType: manifest.type,
                duration: manifest.mediaPresentationDuration,
                targetDurationSeconds: nil,
                counts: [
                    "periods": manifest.periods.count,
                    "adaptationSets": adaptations.count,
                    "representations": representations.count,
                    "protectionSchemes": manifest.contentProtection.count,
                    "eventStreams": adaptations.flatMap(\.eventStreams).count
                ],
                unsupportedVariantCount: 0,
                codecs: Array(Set(codecs)).sorted(),
                resolutions: Array(Set(resolutions)).sorted(),
                bandwidths: Array(Set(representations.compactMap(\.bandwidth))).sorted(),
                protectionSchemes: Array(Set(manifest.contentProtection.map(\.schemeIdUri))).sorted(),
                hasContentSteering: false,
                hasSegmentTemplate: hasTemplate,
                hlsVariants: [],
                hlsRenditions: [],
                dashRepresentations: Array(representationItems.prefix(itemLimit)),
                segmentTemplates: Array(templates.prefix(itemLimit)).map {
                    MCPDASHSegmentTemplateDTO(
                        timescale: $0.timescale,
                        duration: $0.duration,
                        startNumber: $0.startNumber,
                        hasInitializationPattern: $0.initialization != nil,
                        hasMediaPattern: $0.media != nil
                    )
                },
                disclosure: disclosure(
                    policyRevision: policyRevision,
                    removedFields: ["manifestText", "urls", "queryValues", "pssh", "keyIDs"],
                    partialReason: truncated
                        ? "Representation or segment-template details were truncated to 100 entries per collection."
                        : nil,
                    truncated: truncated
                )
            )
        default:
            throw MCPStructuredError(code: .malformedRequest, message: "The selected session is not a captured HLS or DASH manifest.")
        }
    }

    private func hlsVariantReference(
        sessionID: SessionRecord.ID,
        captureSequence: UInt64,
        bodyDigest: String,
        ordinal: Int,
        lineDigest: String?,
        uriDigest: String?
    ) -> String {
        let source = "\(sessionID.uuidString)|\(captureSequence)|\(bodyDigest)|\(ordinal)|\(lineDigest ?? "unavailable")|\(uriDigest ?? "unavailable")"
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "hls-variant-\(digest.prefix(20))"
    }

    func relatedSessions(sessionID: SessionRecord.ID) throws -> RelatedResult {
        guard let selected = sessionStore.record(for: sessionID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Media session was not found.")
        }
        updateCorrelationIndex()
        if let cached = relatedResultCache[sessionID],
           cached.indexedThroughSequence == correlationIndexedThrough {
            return cached.result
        }
        let sessions = sessionStore.sessions
        var items: [RelatedItem] = []
        var attemptedStrategies: [String] = []
        let selectedMediaType = MediaDetector.mediaType(for: selected)
        if selectedMediaType == .none {
            return cacheRelatedResult(
                sessionID: sessionID,
                items: [],
                status: "ineligible",
                attemptedStrategies: ["media_classification"]
            )
        }

        switch selectedMediaType {
        case .hls:
            attemptedStrategies.append("hls_manifest_references")
            guard let response = selected.response,
                  let data = MediaDetector.decodedResponseBody(for: response),
                  let text = String(data: data, encoding: .utf8) else {
                return cacheRelatedResult(
                    sessionID: sessionID,
                    items: [],
                    status: "ineligible",
                    attemptedStrategies: attemptedStrategies
                )
            }
            let candidate = ParsedHLSManifestSession(
                sessionID: selected.id,
                host: selected.request.host,
                path: selected.request.path,
                manifest: HLSParser.parse(text, baseURL: MediaDetector.absoluteURL(for: selected.request))
            )
            for session in sessions where session.id != selected.id {
                guard let correlation = HLSManifestCorrelationResolver.correlate(
                    session: session,
                    within: [candidate]
                ) else { continue }
                items.append(contentsOf: correlation.matches.map {
                    RelatedItem(
                        sessionID: session.id,
                        relationship: correlation.referenceKind.rawValue,
                        matchStrategy: $0.strategy.rawValue
                    )
                })
            }
        case .dash:
            attemptedStrategies.append("dash_segment_templates")
            guard let response = selected.response,
                  let data = MediaDetector.decodedResponseBody(for: response),
                  let text = String(data: data, encoding: .utf8),
                  let manifest = DASHParser.parse(text) else {
                return cacheRelatedResult(
                    sessionID: sessionID,
                    items: [],
                    status: "ineligible",
                    attemptedStrategies: attemptedStrategies
                )
            }
            let candidate = ParsedDASHManifestSession(
                sessionID: selected.id,
                host: selected.request.host,
                path: selected.request.path,
                manifestURL: MediaDetector.absoluteURL(for: selected.request),
                manifest: manifest
            )
            for session in sessions where session.id != selected.id {
                guard let correlation = DASHManifestCorrelationResolver.correlate(
                    session: session,
                    within: [candidate]
                ) else { continue }
                items.append(contentsOf: correlation.matches.map {
                    RelatedItem(
                        sessionID: session.id,
                        relationship: correlation.referenceKind.rawValue,
                        matchStrategy: $0.strategy.rawValue
                    )
                })
            }
        default:
            attemptedStrategies.append(contentsOf: ["hls_manifest_references", "dash_segment_templates"])
            if let hls = HLSManifestCorrelationResolver.correlate(session: selected, within: indexedHLSManifests) {
                items.append(contentsOf: hls.matches.map {
                    RelatedItem(
                        sessionID: $0.manifestSessionID,
                        relationship: hls.referenceKind.rawValue,
                        matchStrategy: $0.strategy.rawValue
                    )
                })
            }
            if let dash = DASHManifestCorrelationResolver.correlate(session: selected, within: indexedDASHManifests) {
                items.append(contentsOf: dash.matches.map {
                    RelatedItem(
                        sessionID: $0.manifestSessionID,
                        relationship: dash.referenceKind.rawValue,
                        matchStrategy: $0.strategy.rawValue
                    )
                })
            }
        }

        var seen: Set<String> = []
        let uniqueItems = items.filter {
            seen.insert("\($0.sessionID.uuidString):\($0.relationship):\($0.matchStrategy)").inserted
        }
        let hasSkippedBodies = correlationSkippedBodyReasons.values.contains(where: { $0 > 0 })
        let status = !uniqueItems.isEmpty ? "matched" : (hasSkippedBodies ? "partial" : "no_match")
        let result = RelatedResult(
            items: uniqueItems,
            status: status,
            candidateCount: indexedHLSManifests.count + indexedDASHManifests.count,
            skippedBodyReasons: correlationSkippedBodyReasons,
            attemptedStrategies: attemptedStrategies,
            indexedThroughSequence: correlationIndexedThrough
        )
        relatedResultCache[sessionID] = CachedRelatedResult(
            indexedThroughSequence: correlationIndexedThrough,
            result: result
        )
        MCPLog.media.info(
            "Correlation for session \(sessionID.uuidString, privacy: .public) completed with status \(status, privacy: .public), \(uniqueItems.count) disclosed match(es), indexed through \(self.correlationIndexedThrough)."
        )
        return result
    }

    private func cacheRelatedResult(
        sessionID: SessionRecord.ID,
        items: [RelatedItem],
        status: String,
        attemptedStrategies: [String]
    ) -> RelatedResult {
        let result = RelatedResult(
            items: items,
            status: status,
            candidateCount: indexedHLSManifests.count + indexedDASHManifests.count,
            skippedBodyReasons: correlationSkippedBodyReasons,
            attemptedStrategies: attemptedStrategies,
            indexedThroughSequence: correlationIndexedThrough
        )
        relatedResultCache[sessionID] = CachedRelatedResult(
            indexedThroughSequence: correlationIndexedThrough,
            result: result
        )
        return result
    }

    private func updateCorrelationIndex() {
        if correlationEpoch != snapshotService.captureEpoch {
            correlationEpoch = snapshotService.captureEpoch
            correlationIndexedThrough = 0
            indexedHLSManifests = []
            indexedDASHManifests = []
            correlationSkippedBodyReasons = [:]
            pendingCorrelationSessions = [:]
            relatedResultCache = [:]
        }
        let allSessions = snapshotService.allIndexedSessions
        let newSessions = allSessions.filter {
            $0.captureSequence > correlationIndexedThrough
        }
        let deferredSessions = allSessions.filter { pendingCorrelationSessions[$0.record.id] != nil }
        var seenSessionIDs: Set<SessionRecord.ID> = []
        let candidates = (newSessions + deferredSessions).filter { seenSessionIDs.insert($0.record.id).inserted }
        guard !candidates.isEmpty else { return }
        for indexed in candidates {
            let record = indexed.record
            if let previousReason = pendingCorrelationSessions.removeValue(forKey: record.id) {
                correlationSkippedBodyReasons[previousReason, default: 0] -= 1
                if correlationSkippedBodyReasons[previousReason] == 0 {
                    correlationSkippedBodyReasons.removeValue(forKey: previousReason)
                }
            }
            let mediaType = MediaDetector.mediaType(for: record)
            guard mediaType == .hls || mediaType == .dash else { continue }
            guard let response = record.response else {
                recordPendingCorrelation(record.id, reason: "response_missing")
                continue
            }
            if response.bodyDeferred {
                recordPendingCorrelation(record.id, reason: "body_deferred")
                continue
            }
            if response.recordingBodyOmissionReason != nil {
                recordPendingCorrelation(record.id, reason: "body_omitted")
                continue
            }
            guard let body = MediaDetector.decodedResponseBody(for: response),
                  let text = String(data: body, encoding: .utf8) else {
                recordPendingCorrelation(record.id, reason: "body_undecodable")
                continue
            }
            switch mediaType {
            case .hls:
                indexedHLSManifests.append(
                    ParsedHLSManifestSession(
                        sessionID: record.id,
                        host: record.request.host,
                        path: record.request.path,
                        manifest: HLSParser.parse(text, baseURL: MediaDetector.absoluteURL(for: record.request))
                    )
                )
            case .dash:
                guard let manifest = DASHParser.parse(text) else {
                    correlationSkippedBodyReasons["manifest_malformed", default: 0] += 1
                    continue
                }
                indexedDASHManifests.append(
                    ParsedDASHManifestSession(
                        sessionID: record.id,
                        host: record.request.host,
                        path: record.request.path,
                        manifestURL: MediaDetector.absoluteURL(for: record.request),
                        manifest: manifest
                    )
                )
            default:
                break
            }
        }
        correlationIndexedThrough = snapshotService.highWaterSequence
        relatedResultCache = [:]
    }

    private func recordPendingCorrelation(_ sessionID: SessionRecord.ID, reason: String) {
        pendingCorrelationSessions[sessionID] = reason
        correlationSkippedBodyReasons[reason, default: 0] += 1
    }

    func inspectionSource(
        sessionID: SessionRecord.ID,
        analyses: [MCPMediaAnalysisKind]
    ) throws -> MCPMediaInspectionSource {
        if analyses.contains(.liveMediaEngine) {
            throw MCPStructuredError(
                code: .policyDenied,
                message: "Live media probes require live_media_probe_start, not capture-only media inspection."
            )
        }
        guard let record = sessionStore.record(for: sessionID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Media session was not found.")
        }
        guard record.response?.bodyDeferred != true,
              record.response?.recordingBodyOmissionReason == nil,
              let data = decodedBody(record),
              !data.isEmpty else {
            throw ineligibleBodyError(record)
        }
        for analysis in analyses {
            let eligible: Bool
            switch analysis {
            case .binaryContainer:
                eligible = data.count >= 16 || hasTwoAlignedTransportPackets(data)
            case .transportStructure:
                eligible = hasTwoAlignedTransportPackets(data)
            case .id3TimedMetadata:
                eligible = hasValidatedID3Candidate(data) || hasTwoAlignedTransportPackets(data)
            case .gopFrames:
                eligible = data.count >= 64 * 1_024
            case .capturedMediaEngine:
                eligible = record.response?.bodyTruncated != true
            case .liveMediaEngine:
                eligible = false
            }
            guard eligible else {
                throw MCPStructuredError(
                    code: .malformedRequest,
                    message: "The captured prefix is too short or incomplete for \(analysis.rawValue).",
                    details: ["reason": "insufficient_prefix_bytes"]
                )
            }
        }
        if analyses.contains(.capturedMediaEngine) {
            let eligibility = AVMediaInspectionEligibility.evaluate(session: record)
            guard eligibility.capturedItemAvailable else {
                throw MCPStructuredError(
                    code: .malformedRequest,
                    message: "Captured media-engine inspection is unavailable for this item.",
                    details: ["reason": eligibility.capturedItemReason ?? "captured_item_ineligible"]
                )
            }
        }
        return MCPMediaInspectionSource(
            sessionID: sessionID,
            data: data,
            fileExtension: fileExtension(for: record),
            displayName: "Captured media item \(sessionID.uuidString)",
            reportedOriginalBytes: record.response?.bodySize,
            bodyTruncated: record.response?.bodyTruncated ?? false
        )
    }

    func inspect(
        source: MCPMediaInspectionSource,
        analyses: [MCPMediaAnalysisKind],
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        progress: @MainActor (Double, String) -> Void
    ) async throws -> MCPMediaInspectionResultDTO {
        try Task.checkCancellation()
        AgentWorkspaceDiagnostics.shared.recordExplicitAgentAnalysis()
        var binary: MCPMediaBinaryStructureDTO?
        var gop: MCPMediaGOPAnalysisDTO?
        var id3: MCPMediaID3AnalysisDTO?
        var mediaEngine: MCPMediaEngineInspectionDTO?
        var diagnostics: [MCPMediaParserDiagnosticsDTO] = []
        var warnings: [String] = []
        var resultTruncated = false
        var binaryInspectionPerformed = false
        let uniqueAnalyses = Array(Set(analyses)).sorted { $0.rawValue < $1.rawValue }

        for (index, analysis) in uniqueAnalyses.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(1, uniqueAnalyses.count)), analysis.rawValue)
            switch analysis {
            case .transportStructure, .binaryContainer:
                guard !binaryInspectionPerformed else { continue }
                binaryInspectionPerformed = true
                // BinaryMediaStructureProbe has no internal cancellation checkpoint, so a call
                // already in flight still runs to completion once started. The cancellation bridge
                // signals the worker and joins it; it does not detach abandoned parsing work.
                let structure = await runDetachedCancellable(priority: .utility) {
                    BinaryMediaStructureProbe().inspect(data: source.data)
                }
                try Task.checkCancellation()
                if let structure {
                    binary = binaryDTO(structure)
                    if structure.tsProgramNumbers.count > 100
                        || structure.tsStreamTypeCodes.count > 100
                        || structure.topLevelBoxes.count > 100 {
                        resultTruncated = true
                        warnings.append("Binary-container detail lists were truncated to 100 entries.")
                    }
                } else {
                    warnings.append("No supported transport or binary container structure was detected.")
                }
            case .gopFrames:
                let result = await runDetachedCancellable(priority: .utility) {
                    MPEGTransportStreamVideoAnalyzer().analyzeWithDiagnostics(
                        data: source.data,
                        shouldCancel: { Task.isCancelled }
                    )
                }
                try Task.checkCancellation()
                diagnostics.append(diagnosticsDTO(result.diagnostics))
                if let analysis = result.analysis {
                    gop = gopDTO(analysis)
                } else {
                    warnings.append("GOP analysis did not find classifiable video access units.")
                }
            case .id3TimedMetadata:
                let result = await runDetachedCancellable(priority: .utility) {
                    TimedMetadataID3Parser().analyze(
                        data: source.data,
                        assetID: source.sessionID,
                        assetURL: nil,
                        shouldCancel: { Task.isCancelled }
                    )
                }
                try Task.checkCancellation()
                diagnostics.append(diagnosticsDTO(result.diagnostics))
                if result.markers.count > 100
                    || result.markers.contains(where: { $0.frameIdentifiers.count > 32 }) {
                    resultTruncated = true
                    warnings.append("ID3 marker or frame-identifier details were truncated.")
                }
                id3 = MCPMediaID3AnalysisDTO(
                    containerType: result.containerType.rawValue,
                    markerCount: result.markers.count,
                    firstPresentationTimestamp90k: result.markers.compactMap(\.presentationTimestamp90k).min(),
                    lastPresentationTimestamp90k: result.markers.compactMap(\.presentationTimestamp90k).max(),
                    markers: result.markers.prefix(100).map {
                        MCPMediaID3MarkerDTO(
                            relativePlaybackTime: $0.relativePlaybackTime,
                            segmentRelativeTime: $0.segmentRelativeTime,
                            byteOffset: $0.byteOffset,
                            transportPID: $0.transportPID,
                            presentationTimestamp90k: $0.presentationTimestamp90k,
                            presentationTimestampSeconds: $0.presentationTimestamp90k.map { Double($0) / 90_000 },
                            id3MajorVersion: $0.id3MajorVersion,
                            tagSize: $0.tagSize,
                            frameIdentifiers: Array($0.frameIdentifiers.prefix(32)),
                            privateOwnerIdentifiers: Array($0.privateOwnerIdentifiers.prefix(16)),
                            decodeStatus: $0.payloadDecodeStatus.rawValue,
                            payloadPresent: $0.payloadSummary != nil,
                            payloadRedacted: true
                        )
                    }
                )
            case .capturedMediaEngine:
                let input = AVMediaInspectionInput(
                    source: .capturedItem,
                    url: nil,
                    capturedData: source.data,
                    capturedFileExtension: source.fileExtension,
                    displayName: source.displayName,
                    sampleTime: sampleTime,
                    initialWarnings: []
                )
                let report = await AVAssetMetadataService().inspect(input)
                try Task.checkCancellation()
                mediaEngine = mediaEngineDTO(report)
                if report.variants.count > 100
                    || report.videoTracks.count > 100
                    || report.audioTracks.count > 100 {
                    resultTruncated = true
                    warnings.append("Media-engine variant or track details were truncated to 100 entries.")
                }
                if report.isPartial {
                    warnings.append("Captured media-engine inspection returned partial results.")
                }
            case .liveMediaEngine:
                throw MCPStructuredError(
                    code: .policyDenied,
                    message: "Live media probes require live_media_probe_start, not capture-only media inspection."
                )
            }
        }
        progress(1, "complete")

        let result = MCPMediaInspectionResultDTO(
            sessionID: source.sessionID.uuidString,
            analyses: uniqueAnalyses,
            binaryStructure: binary,
            gop: gop,
            id3: id3,
            mediaEngine: mediaEngine,
            diagnostics: diagnostics,
            warnings: warnings,
            coverage: MCPMediaCoverageDTO(
                scope: source.bodyTruncated ? "prefix" : "complete",
                capturedBytes: source.data.count,
                reportedOriginalBytes: source.reportedOriginalBytes,
                inspectedBytes: diagnostics.map(\.bytesInspected).max() ?? source.data.count,
                complete: !source.bodyTruncated,
                limitation: source.bodyTruncated ? "Analysis covers the retained captured prefix only." : nil
            ),
            disclosure: disclosure(
                policyRevision: policyRevision,
                removedFields: [
                    "rawBody", "rawURLs", "id3Payloads", "decodedText", "temporaryPaths",
                    "pixelData", "ioSurfaceIdentifiers", "accessLogResources"
                ],
                partialReason: warnings.isEmpty && !source.bodyTruncated ? nil : "One or more requested analyses returned a partial or bounded result.",
                truncated: resultTruncated
            )
        )
        MCPLog.media.info(
            "Media inspection for session \(source.sessionID.uuidString, privacy: .public) completed with \(diagnostics.count) parser diagnostic record(s) and \(warnings.count) warning(s)."
        )
        return result
    }

    /// Runs CPU-heavy work off the MainActor while still honoring the calling task's cancellation.
    /// `Task.detached` creates an unstructured task that never inherits cancellation automatically —
    /// without this bridge, cancelling `MCPOperationCoordinator`'s outer operation task (e.g. via
    /// `operation_cancel`, a client disconnect, or a capture/session clear) would silently have no
    /// effect on an already-in-flight parse: it would keep running to completion regardless, wasting
    /// CPU well after the coordinator has already reported the operation as cancelled.
    /// Internal (not private) so tests can exercise the cancellation bridge directly, independent
    /// of any specific parser's real-world timing.
    func runDetachedCancellable<T: Sendable>(
        priority: TaskPriority,
        _ work: @Sendable @escaping () -> T
    ) async -> T {
        let task = Task.detached(priority: priority, operation: work)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func decodedBody(_ record: SessionRecord) -> Data? {
        record.response.flatMap(MediaDetector.decodedResponseBody)
    }

    private func bodyEligibility(for record: SessionRecord) -> MCPMediaBodyEligibility {
        guard let response = record.response else { return .empty }
        if response.bodyDeferred { return .deferred }
        if response.recordingBodyOmissionReason != nil { return .omitted }
        if response.bodyTruncated { return .truncated }
        guard let data = decodedBody(record), !data.isEmpty else { return .empty }
        return .available
    }

    private func analysisEligibility(
        for record: SessionRecord,
        mediaType: MediaType,
        bodyAvailable: Bool
    ) -> [MCPMediaAnalysisEligibilityDTO] {
        let captureKinds: [MCPMediaAnalysisKind] = [
            .transportStructure, .gopFrames, .id3TimedMetadata, .binaryContainer, .capturedMediaEngine
        ]
        let data = decodedBody(record)
        let dataCount = data?.count ?? 0
        let coverage = MCPMediaCoverageDTO(
            scope: record.response?.bodyTruncated == true ? "prefix" : "complete",
            capturedBytes: dataCount,
            reportedOriginalBytes: record.response?.bodySize,
            inspectedBytes: dataCount,
            complete: record.response?.bodyTruncated != true,
            limitation: record.response?.bodyTruncated == true ? "Only the retained prefix can be inspected." : nil
        )
        return captureKinds.map { kind in
            let eligible: Bool
            let reason: String?
            if !bodyAvailable {
                return MCPMediaAnalysisEligibilityDTO(
                    kind: kind.rawValue,
                    eligible: false,
                    reason: bodyIneligibilityReason(record),
                    coverage: coverage
                )
            }
            switch kind {
            case .capturedMediaEngine:
                if !bodyAvailable || record.response?.bodyTruncated == true {
                    eligible = false
                    reason = record.response?.bodyTruncated == true ? "captured_body_truncated" : bodyIneligibilityReason(record)
                } else {
                    let eligibility = AVMediaInspectionEligibility.evaluate(session: record)
                    eligible = eligibility.capturedItemAvailable
                    reason = eligible ? nil : (eligibility.capturedItemReason ?? "captured_item_ineligible")
                }
            case .gopFrames:
                eligible = bodyAvailable && mediaType != .none && dataCount >= 64 * 1_024
                reason = eligible ? nil : (dataCount < 64 * 1_024 ? "insufficient_prefix_bytes" : bodyIneligibilityReason(record))
            case .id3TimedMetadata:
                eligible = bodyAvailable && mediaType != .none
                    && (data.map(hasValidatedID3Candidate) == true
                        || data.map(hasTwoAlignedTransportPackets) == true)
                reason = eligible ? nil : (dataCount < 10 ? "insufficient_prefix_bytes" : bodyIneligibilityReason(record))
            case .transportStructure:
                eligible = bodyAvailable && mediaType != .none
                    && data.map(hasTwoAlignedTransportPackets) == true
                reason = eligible ? nil : "insufficient_prefix_bytes"
            case .binaryContainer:
                eligible = bodyAvailable && mediaType != .none && dataCount >= 16
                reason = eligible ? nil : (dataCount < 16 ? "insufficient_prefix_bytes" : bodyIneligibilityReason(record))
            case .liveMediaEngine:
                eligible = false
                reason = "use_live_media_probe_start"
            }
            return MCPMediaAnalysisEligibilityDTO(kind: kind.rawValue, eligible: eligible, reason: reason, coverage: coverage)
        } + [
            MCPMediaAnalysisEligibilityDTO(
                kind: MCPMediaAnalysisKind.liveMediaEngine.rawValue,
                eligible: MediaDetector.primaryMediaURL(for: record) != nil,
                reason: MediaDetector.primaryMediaURL(for: record) == nil ? "no_probe_url" : nil,
                coverage: nil
            )
        ]
    }

    private func hasTwoAlignedTransportPackets(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(512))
        for packetSize in [188, 192, 204] {
            for offset in 0..<min(packetSize, 16) where offset + packetSize < bytes.count {
                if bytes[offset] == 0x47, bytes[offset + packetSize] == 0x47 {
                    return true
                }
            }
        }
        return false
    }

    private func hasValidatedID3Candidate(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(512 * 1_024))
        guard bytes.count >= 10 else { return false }
        for offset in 0...(bytes.count - 10) where bytes[offset] == 0x49
            && bytes[offset + 1] == 0x44
            && bytes[offset + 2] == 0x33
            && (bytes[offset + 3] == 3 || bytes[offset + 3] == 4)
            && bytes[offset + 4] == 0
            && bytes[(offset + 6)..<(offset + 10)].allSatisfy({ $0 & 0x80 == 0 }) {
            return true
        }
        return false
    }

    private func bodyIneligibilityReason(_ record: SessionRecord) -> String {
        if record.response?.bodyDeferred == true { return "captured_body_deferred" }
        if record.response?.bodyTruncated == true { return "captured_body_truncated" }
        if record.response?.recordingBodyOmissionReason != nil { return "captured_body_omitted" }
        return "captured_body_unavailable"
    }

    private func recommendedWorkflow(
        for mediaType: MediaType,
        bodyAvailable: Bool,
        record: SessionRecord
    ) -> MCPMediaWorkflowEntry? {
        switch mediaType {
        case .hls:
            return MCPCapabilitiesManifestBuilder.mediaWorkflows.first { $0.id == "hls_manifest_analysis" }
        case .dash:
            return MCPCapabilitiesManifestBuilder.mediaWorkflows.first { $0.id == "dash_manifest_analysis" }
        case .hlsDiscovery:
            if MediaDetector.primaryMediaURL(for: record) != nil {
                return MCPCapabilitiesManifestBuilder.mediaWorkflows.first { $0.id == "live_url_probe" }
            }
            return MCPCapabilitiesManifestBuilder.mediaWorkflows.first { $0.id == "classify_session" }
        case .video, .image, .adXml:
            if bodyAvailable {
                return MCPCapabilitiesManifestBuilder.mediaWorkflows.first { $0.id == "deep_capture_inspection" }
            }
            return MCPCapabilitiesManifestBuilder.mediaWorkflows.first { $0.id == "classify_session" }
        case .none:
            return nil
        }
    }

    private func sanitizedHLSDiscovery(
        _ discovery: HLSStreamDiscovery,
        requestHost: String
    ) -> MCPHLSDiscoverySummaryDTO {
        let host = discovery.manifestURL.host ?? requestHost
        let serializer = MCPDisclosureSerializer()
        return MCPHLSDiscoverySummaryDTO(
            manifestHostCategory: MCPHostCategory.classify(host: host).rawValue,
            manifestPathCategory: serializer.sanitizedPath(discovery.manifestURL.path),
            kind: discovery.kind.rawValue,
            manifestFormat: discovery.manifestFormat,
            hasContentID: discovery.contentID != nil,
            hasDRMLicenseURL: discovery.drmLicenseURL != nil
        )
    }

    private func ineligibleBodyError(_ record: SessionRecord) -> MCPStructuredError {
        let reason: String
        if record.response?.bodyDeferred == true {
            reason = "captured_body_deferred"
        } else if record.response?.bodyTruncated == true {
            reason = "captured_body_truncated"
        } else if record.response?.recordingBodyOmissionReason != nil {
            reason = "captured_body_omitted"
        } else {
            reason = "captured_body_unavailable"
        }
        return MCPStructuredError(
            code: .malformedRequest,
            message: "The captured media body is not eligible for this operation.",
            details: ["reason": reason]
        )
    }

    private func disclosure(
        policyRevision: MCPPolicyRevision,
        removedFields: [String] = ["rawURLs", "queryValues", "rawBodies"],
        partialReason: String? = nil,
        truncated: Bool = false
    ) -> MCPMediaDisclosureContextDTO {
        MCPMediaDisclosureContextDTO(
            captureEpoch: snapshotService.captureEpoch,
            policyRevision: policyRevision,
            generatedAt: Date(),
            removedFields: removedFields,
            partialResultReason: partialReason,
            truncated: truncated
        )
    }

    private func mediaTypeName(_ mediaType: MediaType) -> String {
        switch mediaType {
        case .image: return "image"
        case .hls: return "hls"
        case .hlsDiscovery: return "hls_discovery"
        case .dash: return "dash"
        case .video: return "video"
        case .adXml(let kind): return "ad_xml_\(String(describing: kind).lowercased())"
        case .none: return "none"
        }
    }

    private func contentType(_ response: CapturedResponse) -> String? {
        response.headers.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.split(separator: ";").first.map(String.init)
    }

    private func fileExtension(for record: SessionRecord) -> String {
        let pathExtension = URL(string: record.request.path)?.pathExtension
        return pathExtension?.isEmpty == false ? pathExtension! : "media"
    }

    private func inferredContainerKind(for record: SessionRecord) -> String? {
        let fileExtension = fileExtension(for: record).lowercased()
        switch fileExtension {
        case "ts", "m2ts":
            return "mpeg_transport_stream"
        case "mp4", "m4s", "m4v", "mov":
            return "iso_bmff"
        default:
            return nil
        }
    }

    private func binaryDTO(_ structure: BinaryMediaStructure) -> MCPMediaBinaryStructureDTO {
        MCPMediaBinaryStructureDTO(
            kind: structure.kind.rawValue,
            role: structure.role.rawValue,
            bytesInspected: structure.bytesInspected,
            transportPacketSize: structure.tsPacketSize,
            transportSyncPacketCount: structure.tsSyncPacketCount,
            programNumbers: Array(structure.tsProgramNumbers.prefix(100)),
            streamTypeCodes: structure.tsStreamTypeCodes.prefix(100).map { String(format: "0x%02X", $0) },
            scte35Present: structure.scte35PIDPresent,
            topLevelBoxTypes: structure.topLevelBoxes.prefix(100).map(\.type),
            likelyFragmented: structure.likelyFragmented,
            likelyEncrypted: structure.likelyEncrypted,
            segmentIndexPresent: structure.segmentIndexPresent,
            eventMessageCount: structure.eventMessages.count,
            eventMessages: structure.eventMessages.prefix(100).map { event in
                MCPMediaEventMessageDTO(
                    version: Int(event.version),
                    schemeIDURI: event.schemeIDURI.map { String($0.prefix(512)) },
                    timescale: event.timescale,
                    presentationTime: event.presentationTime,
                    presentationTimeSeconds: event.timescale.flatMap { timescale in
                        guard timescale > 0, let presentationTime = event.presentationTime else { return nil }
                        return Double(presentationTime) / Double(timescale)
                    },
                    eventDuration: event.eventDuration,
                    eventID: event.eventID,
                    messageDataSize: event.messageDataSize,
                    embeddedID3FrameIdentifiers: Array(event.embeddedID3FrameIdentifiers.prefix(32))
                )
            },
            protectionBoxCount: structure.psshCount
        )
    }

    private func gopDTO(_ analysis: MPEGTransportStreamVideoAnalysis) -> MCPMediaGOPAnalysisDTO {
        MCPMediaGOPAnalysisDTO(
            codec: analysis.codec.rawValue,
            bytesInspected: analysis.bytesInspected,
            accessUnitCount: analysis.accessUnitCount,
            iFrameCount: analysis.iFrameCount,
            pFrameCount: analysis.pFrameCount,
            bFrameCount: analysis.bFrameCount,
            unclassifiedFrameCount: analysis.unclassifiedFrameCount,
            keyFrameCount: analysis.keyFrameCount,
            observedFrameRate: analysis.observedFrameRate,
            presentationTimeSpan: analysis.presentationTimeSpan,
            averageGOPFrameCount: analysis.averageGOPFrameCount,
            maximumGOPFrameCount: analysis.maximumGOPFrameCount,
            averageKeyFrameInterval: analysis.averageKeyFrameInterval,
            maximumKeyFrameInterval: analysis.maximumKeyFrameInterval,
            suggestedSeekTolerance: analysis.suggestedSeekTolerance,
            inspectionLimited: analysis.isInspectionLimited
        )
    }

    private func diagnosticsDTO(_ diagnostics: MediaParserDiagnostics) -> MCPMediaParserDiagnosticsDTO {
        MCPMediaParserDiagnosticsDTO(
            parser: diagnostics.parser,
            outcome: diagnostics.outcome.rawValue,
            bytesAvailable: diagnostics.bytesAvailable,
            bytesInspected: diagnostics.bytesInspected,
            completedStages: diagnostics.completedStages,
            counters: diagnostics.counters,
            warnings: diagnostics.warnings
        )
    }

    private func mediaEngineDTO(_ report: AVMediaInspectionReport) -> MCPMediaEngineInspectionDTO {
        MCPMediaEngineInspectionDTO(
            partial: report.isPartial,
            durationSeconds: report.asset?.duration,
            playable: report.asset?.isPlayable,
            exportable: report.asset?.isExportable,
            protectedContent: report.asset?.hasProtectedContent,
            preciseTiming: report.asset?.providesPreciseDurationAndTiming,
            variantCount: report.variants.count,
            videoTrackCount: report.videoTracks.count,
            audioTrackCount: report.audioTracks.count,
            subtitleTrackCount: report.subtitleTracks.count,
            variants: report.variants.prefix(100).map {
                MCPMediaEngineVariantDTO(
                    peakBitRate: $0.peakBitRate,
                    averageBitRate: $0.averageBitRate,
                    videoRange: $0.videoRange,
                    videoCodecs: $0.videoCodecs,
                    width: $0.presentationWidth,
                    height: $0.presentationHeight,
                    nominalFrameRate: $0.nominalFrameRate,
                    audioFormats: $0.audioFormats
                )
            },
            videoTracks: report.videoTracks.prefix(100).map {
                MCPMediaEngineVideoTrackDTO(
                    width: $0.width,
                    height: $0.height,
                    estimatedDataRate: $0.estimatedDataRate,
                    nominalFrameRate: $0.nominalFrameRate,
                    codec: $0.codec
                )
            },
            audioTracks: report.audioTracks.prefix(100).map {
                MCPMediaEngineAudioTrackDTO(
                    channels: $0.channels,
                    sampleRate: $0.sampleRate,
                    language: $0.language,
                    codec: $0.codec
                )
            },
            subtitleLanguages: Array(Set(report.subtitleTracks.compactMap(\.language))).sorted(),
            mediaSelectionLanguages: Array(Set(
                report.mediaSelectionGroups.flatMap(\.options).compactMap(\.language)
            )).sorted(),
            player: report.player.map {
                MCPMediaEnginePlayerDTO(
                    status: $0.status,
                    presentationWidth: $0.presentationWidth,
                    presentationHeight: $0.presentationHeight,
                    likelyToKeepUp: $0.isPlaybackLikelyToKeepUp,
                    bufferEmpty: $0.isPlaybackBufferEmpty,
                    bufferFull: $0.isPlaybackBufferFull,
                    loadedRanges: $0.loadedTimeRanges.map {
                        MCPMediaTimeRangeDTO(start: $0.start, duration: $0.duration)
                    },
                    seekableRanges: $0.seekableTimeRanges.map {
                        MCPMediaTimeRangeDTO(start: $0.start, duration: $0.duration)
                    }
                )
            },
            decodedFrame: report.decodedFrame.map {
                MCPDecodedFrameDTO(
                    requestedTime: $0.requestedTime,
                    decodedTime: $0.decodedTime,
                    width: $0.width,
                    height: $0.height,
                    pixelFormat: $0.pixelFormat,
                    planar: $0.isPlanar,
                    planeCount: $0.planeCount,
                    bytesPerRow: $0.bytesPerRow,
                    estimatedByteSize: $0.estimatedByteSize,
                    planes: $0.planes.map {
                        MCPDecodedFramePlaneDTO(
                            index: $0.id,
                            width: $0.width,
                            height: $0.height,
                            bytesPerRow: $0.bytesPerRow
                        )
                    },
                    attachments: $0.attachments,
                    metalCompatible: $0.isMetalCompatible,
                    ioSurfaceBacked: $0.hasIOSurface,
                    ioSurfaceWidth: $0.ioSurfaceWidth,
                    ioSurfaceHeight: $0.ioSurfaceHeight,
                    ioSurfaceBytesPerRow: $0.ioSurfaceBytesPerRow,
                    ioSurfaceAllocationSize: $0.ioSurfaceAllocationSize
                )
            },
            stages: report.stages.map {
                MCPOperationStageDTO(
                    id: $0.id,
                    title: $0.title,
                    durationSeconds: $0.duration,
                    outcome: $0.outcome.rawValue,
                    message: nil
                )
            },
            warnings: report.isPartial ? ["Media engine inspection returned partial results."] : []
        )
    }

    func streamingWaterfall(
        sessionID: SessionRecord.ID,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPStreamingQualityWaterfallDTO {
        guard let indexed = snapshotService.indexedSession(id: sessionID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Media session was not found.")
        }
        let allRecords = snapshotService.allIndexedSessions.map { $0.record }
        let report = StreamingWaterfallEngine.analyze(target: indexed.record, allSessions: allRecords)

        let segmentDTOs = report.segments.map { seg in
            MCPStreamingSegmentDTO(
                sessionID: seg.sessionID.uuidString,
                uri: seg.uri,
                sequenceNumber: seg.sequenceNumber,
                mediaType: seg.mediaType.rawValue,
                variantBandwidth: seg.variantBandwidth,
                variantResolution: seg.variantResolution,
                segmentDurationSeconds: seg.segmentDuration,
                downloadDurationSeconds: seg.downloadDuration,
                byteCount: seg.byteCount,
                downloadSpeedBps: seg.downloadSpeedBps,
                isSlowDownload: seg.isSlowDownload,
                isCacheHit: seg.isCacheHit
            )
        }

        let switchDTOs = report.switchingEvents.map { ev in
            MCPStreamingSwitchEventDTO(
                timestamp: ev.timestamp,
                fromBandwidth: ev.fromBandwidth,
                toBandwidth: ev.toBandwidth,
                fromResolution: ev.fromResolution,
                toResolution: ev.toResolution,
                switchType: ev.switchType.rawValue,
                triggerSessionID: ev.triggerSessionID.uuidString
            )
        }

        return MCPStreamingQualityWaterfallDTO(
            sessionID: sessionID.uuidString,
            manifestKind: report.manifestKind,
            bitrateLadder: report.bitrateLadder,
            segmentCount: report.segments.count,
            totalPlayableDurationSeconds: report.totalPlayableDuration,
            averageBitrateBps: report.averageBitrateBps,
            ttffSeconds: report.ttff,
            slowSegmentCount: report.slowSegmentCount,
            oscillationCount: report.oscillationCount,
            estimatedStallCount: report.estimatedStallCount,
            cdnCacheHitRatio: report.cdnCacheHitRatio,
            segments: segmentDTOs,
            switchingEvents: switchDTOs,
            disclosure: disclosure(policyRevision: policyRevision)
        )
    }

    /// Uses the shared two-worker budget off-main, with no queue. Cancellation retains admission
    /// until synchronous ImageIO exits; the returned report describes the captured input snapshot.
    func visualAssetInspection(
        sessionID: UUID,
        policyRevision: MCPPolicyRevision
    ) async throws -> MCPVisualAssetInspectionDTO {
        guard let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Session ID \(sessionID) not found.")
        }

        let bodyData = session.response?.bodyData ?? Data()
        guard let report = await MediaInspectionWorkBudget.shared.run({ VisualWireInspectorEngine.analyze(imageData: bodyData) }) else {
            throw MCPStructuredError(code: .policyDenied, message: "Image inspection busy or cancelled; no work queued.")
        }

        let mimeType = session.response?.headers.first(where: { $0.name.caseInsensitiveCompare("content-type") == .orderedSame })?.value

        // Check if session is a VAST XML with companion ads
        var companionDTOs: [MCPVASTCompanionAdDTO]?
        if bodyData.count <= 1_048_576, let bodyText = String(data: bodyData, encoding: .utf8), let vastSummary = VASTParser.parse(bodyText) {
            var companions: [MCPVASTCompanionAdDTO] = []
            for ad in vastSummary.ads {
                for creative in ad.creatives {
                    for comp in creative.companions {
                        var resURL: String?
                        if let res = comp.resource {
                            switch res {
                            case .staticResource(_, let url):
                                resURL = url
                            case .iFrameResource(let url):
                                resURL = url
                            case .htmlResource(let content):
                                resURL = content
                            }
                        }
                        companions.append(
                            MCPVASTCompanionAdDTO(
                                id: comp.id,
                                width: comp.width,
                                height: comp.height,
                                resourceType: comp.resource?.resourceType.rawValue,
                                resourceURLOrContent: resURL,
                                clickThroughURL: comp.clickThroughURL
                            )
                        )
                    }
                }
            }
            companionDTOs = companions.isEmpty ? nil : companions
        }

        let paletteDTOs = report.dominantPalette.map {
            MCPColorSwatchDTO(hex: $0.hex, weight: $0.weight)
        }

        return MCPVisualAssetInspectionDTO(
            sessionID: sessionID.uuidString,
            mimeType: mimeType,
            pixelWidth: report.pixelWidth,
            pixelHeight: report.pixelHeight,
            aspectRatio: report.aspectRatio,
            aspectRatioString: report.aspectRatioString,
            bytesPerPixel: report.bytesPerPixel,
            dominantPalette: paletteDTOs,
            hasTransparency: report.hasTransparency,
            isFullyTransparent: report.isFullyTransparent,
            anomalies: report.anomalies.map(\.userFacingMessage),
            companionAds: companionDTOs,
            disclosure: disclosure(policyRevision: policyRevision),
            inspectedFrameCount: report.inspectedFrameCount,
            companionCoverage: bodyData.count > 1_048_576 ? "input_limit" : (companionDTOs == nil ? "not_detected_or_not_applicable" : "parsed"),
            totalFrameCount: report.totalFrameCount,
            orientation: report.orientation
        )
    }

    /// Performs SCTE-35 and multi-rendition discontinuity alignment inspection across variants.
    func scte35AdBreakInspection(
        masterManifestSessionID: UUID,
        variantSessionIDs: [UUID] = [],
        policyRevision: MCPPolicyRevision
    ) throws -> MCPMultiRenditionAlignmentDTO {
        guard let masterSession = sessionStore.sessions.first(where: { $0.id == masterManifestSessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Master manifest session ID \(masterManifestSessionID) not found.")
        }

        let masterBody = masterSession.response?.bodyData ?? Data()
        let masterText = String(data: masterBody, encoding: .utf8) ?? ""
        let baseURL = MediaDetector.absoluteURL(for: masterSession.request)
        let masterParsed = HLSParser.parse(masterText, baseURL: baseURL)

        var variantManifests: [String: HLSManifest] = [:]
        for vSessionID in variantSessionIDs {
            if let vSession = sessionStore.sessions.first(where: { $0.id == vSessionID }) {
                let vBody = vSession.response?.bodyData ?? Data()
                let vText = String(data: vBody, encoding: .utf8) ?? ""
                let vParsed = HLSParser.parse(vText, baseURL: MediaDetector.absoluteURL(for: vSession.request))
                variantManifests[vSession.request.path] = vParsed
            }
        }

        let report = DiscontinuityAlignmentEngine.auditMultiRendition(
            masterManifest: masterParsed,
            masterURI: masterSession.request.path,
            variantManifests: variantManifests
        )

        let variantDTOs = report.variants.map { v in
            MCPVariantRenditionSummaryDTO(
                uri: v.uri,
                bandwidth: v.bandwidth,
                resolution: v.resolution,
                segmentCount: v.segmentCount,
                discontinuityCount: v.discontinuityCount,
                totalDurationSeconds: v.totalDurationSeconds,
                accumulatedDriftMs: v.accumulatedDriftMs
            )
        }

        let adBreakDTOs = report.adBreaks.map { ad in
            MCPAdBreakAlignmentDTO(
                adBreakID: ad.adBreakID,
                startTimeSeconds: ad.startTimeSeconds,
                durationSeconds: ad.durationSeconds,
                scte35Payload: ad.scte35Payload,
                hasDiscontinuityTag: ad.hasDiscontinuityTag,
                channelLayoutBefore: ad.channelLayoutBefore,
                channelLayoutDuringAd: ad.channelLayoutDuringAd,
                timelineGapMs: ad.timelineGapMs,
                hazards: ad.hazards.map(\.userFacingMessage)
            )
        }

        return MCPMultiRenditionAlignmentDTO(
            masterURI: report.masterURI,
            variantCount: report.variantCount,
            isMultiplexed: report.isMultiplexed,
            audioTrackCount: report.audioTrackCount,
            subtitleTrackCount: report.subtitleTrackCount,
            isSwitchingSafe: report.isSwitchingSafe,
            totalAccumulatedDriftMs: report.totalAccumulatedDriftMs,
            variants: variantDTOs,
            adBreaks: adBreakDTOs,
            hazards: report.hazards.map(\.userFacingMessage),
            disclosure: disclosure(policyRevision: policyRevision)
        )
    }

    /// Inspects CTA-5004 CMCD and CTA-5006 CMSD telemetry across one or more sessions.
    func cmcdTelemetryInspection(
        sessionIDs: [UUID],
        policyRevision: MCPPolicyRevision
    ) throws -> MCPCMCDInspectionResultDTO {
        var reports: [MCPCMCDSessionReportDTO] = []
        var totalInspected = 0
        var criticalCount = 0
        var totalScore = 0.0

        for id in sessionIDs {
            guard let session = sessionStore.sessions.first(where: { $0.id == id }) else { continue }
            totalInspected += 1

            if let report = CMCDEngine.parse(
                requestHeaders: session.request.headers,
                responseHeaders: session.response?.headers ?? [],
                urlString: MediaDetector.absoluteURL(for: session.request)?.absoluteString ?? session.request.path,
                responseDurationSeconds: session.timing.duration,
                sessionID: session.id
            ) {
                let cmcdDTO = MCPCMCDTelemetryDTO(
                    encodedBitrateKbps: report.cmcd.encodedBitrateKbps,
                    objectDurationMs: report.cmcd.objectDurationMs,
                    objectType: report.cmcd.objectType?.title,
                    topBitrateKbps: report.cmcd.topBitrateKbps,
                    bufferLengthMs: report.cmcd.bufferLengthMs,
                    deadlineMs: report.cmcd.deadlineMs,
                    measuredThroughputKbps: report.cmcd.measuredThroughputKbps,
                    requestedThroughputKbps: report.cmcd.requestedThroughputKbps,
                    bufferStarvation: report.cmcd.bufferStarvation,
                    isStartup: report.cmcd.isStartup,
                    sessionID: report.cmcd.sessionID,
                    contentID: report.cmcd.contentID,
                    playbackRate: report.cmcd.playbackRate,
                    streamingFormat: report.cmcd.streamingFormat?.title,
                    streamType: report.cmcd.streamType?.title
                )

                var cmsdDTO: MCPCMSDTelemetryDTO? = nil
                if let cmsd = report.cmsd {
                    cmsdDTO = MCPCMSDTelemetryDTO(
                        estimatedThroughputKbps: cmsd.estimatedThroughputKbps,
                        responseDelayMs: cmsd.responseDelayMs,
                        roundTripTimeMs: cmsd.roundTripTimeMs,
                        maxBitrateKbps: cmsd.maxBitrateKbps
                    )
                }

                if report.anomalies.contains(where: { $0.isCritical }) {
                    criticalCount += 1
                }
                totalScore += report.healthScore

                reports.append(
                    MCPCMCDSessionReportDTO(
                        sessionID: session.id.uuidString,
                        requestPath: report.requestPath,
                        transportMethod: report.transportMethod.rawValue,
                        cmcd: cmcdDTO,
                        cmsd: cmsdDTO,
                        throughputHeadroomPercentage: report.throughputHeadroomPercentage,
                        healthScore: report.healthScore,
                        anomalies: report.anomalies.map { $0.userFacingMessage }
                    )
                )
            }
        }

        let avgScore = reports.isEmpty ? 100.0 : (totalScore / Double(reports.count))

        return MCPCMCDInspectionResultDTO(
            totalSessionsInspected: totalInspected,
            sessionsWithCMCDCount: reports.count,
            criticalAnomaliesCount: criticalCount,
            averageHealthScore: avgScore,
            reports: reports,
            disclosure: disclosure(policyRevision: policyRevision)
        )
    }

    /// Inspects WebVTT subtitle tracks for synchronization drift, broadcast line limits, and track defects.
    func webvttSubtitleInspection(
        sessionID: UUID,
        referenceVideoSessionID: UUID? = nil,
        policyRevision: MCPPolicyRevision
    ) throws -> MCPWebVTTTrackReportDTO {
        guard let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Subtitle session ID \(sessionID) not found.")
        }

        let bodyData = session.response?.bodyData ?? Data()
        guard let text = String(data: bodyData, encoding: .utf8), text.contains("WEBVTT") else {
            throw MCPStructuredError(code: .malformedRequest, message: "Session \(sessionID) does not contain valid WebVTT payload.")
        }

        var videoPTSOffset: Double? = nil
        if let videoID = referenceVideoSessionID, let videoSession = sessionStore.sessions.first(where: { $0.id == videoID }) {
            // Check if video session has known PTS offset or timing
            if let dur = videoSession.timing.duration, dur > 0 {
                videoPTSOffset = dur
            }
        }

        let isHls = session.request.path.contains(".vtt") || session.request.path.contains(".m3u8")
        let report = WebVTTEngine.parse(vttText: text, videoPTSOffsetSeconds: videoPTSOffset, isHlsSegment: isHls)

        let cueDTOs = report.cues.map { cue in
            MCPWebVTTCueDTO(
                id: cue.id,
                startTimeSeconds: cue.startTimeSeconds,
                endTimeSeconds: cue.endTimeSeconds,
                durationSeconds: cue.durationSeconds,
                startTimeString: cue.startTimeString,
                endTimeString: cue.endTimeString,
                maxLineLength: cue.maxLineLength,
                text: cue.text
            )
        }

        return MCPWebVTTTrackReportDTO(
            sessionID: session.id.uuidString,
            cueCount: report.cueCount,
            totalDurationSeconds: report.totalDurationSeconds,
            hasTimestampMap: report.hasTimestampMap,
            mpegtsOffsetPTS: report.mpegtsOffsetPTS,
            syncDriftMs: report.syncDriftMs,
            qualityScore: report.qualityScore,
            isSyncSafe: report.isSyncSafe,
            defects: report.defects.map { $0.userFacingMessage },
            cues: cueDTOs,
            disclosure: disclosure(policyRevision: policyRevision)
        )
    }

    /// Inspects DRM configuration, #EXT-X-KEY Content IDs, PSSH boxes, and license exchange transactions.
    func drmHandshakeInspection(
        manifestSessionID: UUID? = nil,
        licenseSessionIDs: [UUID] = [],
        mediaSessionIDs: [UUID] = [],
        policyRevision: MCPPolicyRevision
    ) throws -> MCPDRMAuditReportDTO {
        var manifestSessions: [SessionRecord] = []
        if let mID = manifestSessionID, let s = sessionStore.sessions.first(where: { $0.id == mID }) {
            manifestSessions.append(s)
        }

        let licenseSessions = sessionStore.sessions.filter { s in
            licenseSessionIDs.contains(s.id)
        }

        let mediaSessions = sessionStore.sessions.filter { s in
            mediaSessionIDs.contains(s.id)
        }

        let report = DRMAuditorEngine.audit(
            manifestSessions: manifestSessions,
            licenseSessions: licenseSessions,
            mediaSessions: mediaSessions
        )

        var keyInfoDTO: MCPDRMKeyInfoDTO? = nil
        if let k = report.keyInfo {
            keyInfoDTO = MCPDRMKeyInfoDTO(
                method: k.method,
                keyFormat: k.keyFormat,
                contentID: k.contentID,
                uri: k.uri,
                iv: k.iv
            )
        }

        let psshDTOs = report.psshBoxes.map { box in
            MCPPSSHBoxDTO(
                systemID: box.systemID,
                systemName: box.systemName,
                version: box.version,
                keyIDs: box.keyIDs,
                dataSize: box.dataSize
            )
        }

        let exchangeDTOs = report.licenseExchanges.map { ex in
            MCPDRMLicenseExchangeDTO(
                requestURL: ex.requestURL,
                drmSystem: ex.drmSystem.shortName,
                requestMethod: ex.requestMethod,
                statusCode: ex.statusCode,
                durationSeconds: ex.durationSeconds,
                contentID: ex.contentID,
                hasAuthToken: ex.hasAuthToken,
                isHTTPS: ex.isHTTPS
            )
        }

        return MCPDRMAuditReportDTO(
            drmSystem: report.drmSystem.title,
            keyInfo: keyInfoDTO,
            psshBoxes: psshDTOs,
            licenseExchanges: exchangeDTOs,
            defects: report.defects.map { $0.userFacingMessage },
            handshakeLatencyMs: report.handshakeLatencyMs,
            qualityScore: report.qualityScore,
            isHandshakeHealthy: report.isHandshakeHealthy,
            disclosure: disclosure(policyRevision: policyRevision)
        )
    }

    /// Inspects HTTP Range compliance, 206 Partial Content delivery, CDN cache hits, and bandwidth waste.
    func byteRangeEfficiencyInspection(
        sessionIDs: [UUID] = [],
        policyRevision: MCPPolicyRevision
    ) throws -> MCPByteRangeEfficiencyReportDTO {
        let candidateSessions: [SessionRecord]
        if sessionIDs.isEmpty {
            candidateSessions = sessionStore.sessions
        } else {
            candidateSessions = sessionStore.sessions.filter { sessionIDs.contains($0.id) }
        }

        let report = ByteRangeAuditorEngine.audit(sessions: candidateSessions)

        let txDTOs = report.transactions.map { tx in
            MCPByteRangeTransactionDTO(
                sessionID: tx.id,
                requestURL: tx.requestURL,
                requestMethod: tx.requestMethod,
                rangeHeader: tx.rangeRequest.displayString,
                contentRangeHeader: tx.contentRangeResponse?.displayString,
                statusCode: tx.statusCode,
                transferredBytes: tx.transferredBytes,
                requestedBytes: tx.requestedBytes,
                redundantBytes: tx.redundantBytes,
                wasteRatio: tx.wasteRatio,
                cacheStatus: tx.cacheStatus.title,
                cacheAgeSeconds: tx.cacheAgeSeconds,
                edgePOP: tx.edgePOP
            )
        }

        return MCPByteRangeEfficiencyReportDTO(
            totalTransactions: report.totalTransactions,
            partialContent206Count: report.partialContent206Count,
            fullContent200Count: report.fullContent200Count,
            totalRequestedBytes: report.totalRequestedBytes,
            totalTransferredBytes: report.totalTransferredBytes,
            totalRedundantBytes: report.totalRedundantBytes,
            overallWastePercentage: report.overallWastePercentage,
            cacheHitRatio: report.cacheHitRatio,
            defects: report.defects.map { $0.userFacingMessage },
            transactions: txDTOs,
            efficiencyScore: report.efficiencyScore,
            isEfficient: report.isEfficient,
            disclosure: disclosure(policyRevision: policyRevision)
        )
    }
}
