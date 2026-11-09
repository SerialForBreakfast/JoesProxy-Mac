import Foundation

/// A page-scoped observation, not an atomic snapshot of routing and capture.
struct EffectBundleJoinedInspection: Encodable, Sendable {
    static let maximumBytes = 65_536

    struct Resource: Encodable, Sendable {
        let resourceID: UUID
        let assetIDs: [String]
        let observedReceiptCount: Int
        let deliveredReceiptCount: Int
    }

    struct Asset: Encodable, Sendable {
        let id: String
        let sha256: String
        let byteCount: Int
        let contentType: String?
    }

    struct AdmissionCoverage: Encodable, Sendable {
        let rejectedCaptures: Int
        let metadataOnlyCaptures: Int
        let paused: Bool
        let latestGapStartedAt: Date?
        let latestGapEndedAt: Date?
        let window: EffectBundleDeliveryEvidence.ObservationWindow?
        let historyState: String
        let overlappingGaps: [CaptureAdmissionBudget.Gap]
        let overlappingRejectedCapturesUpperBound: Int
        let scope = "Capture-wide admission only, not client-specific or proof of complete capture. At most 64 intervals; counts include whole overlapping intervals, not exact rejections within the window. Marker times describe receipt changes, not request start times. A byte-trimmed page may cover a shorter receipt prefix than this window."

        init(snapshot: CaptureAdmissionBudget.Snapshot, window: EffectBundleDeliveryEvidence.ObservationWindow?) {
            rejectedCaptures = snapshot.rejectedCaptures
            metadataOnlyCaptures = snapshot.metadataOnlyCaptures
            paused = snapshot.paused
            latestGapStartedAt = snapshot.gapStartedAt
            latestGapEndedAt = snapshot.lastGapEndedAt
            self.window = window
            if let start = window?.start, let end = window?.end {
                overlappingGaps = snapshot.gaps.filter {
                    $0.start.uptime <= end.uptime && ($0.end?.uptime ?? snapshot.observed.uptime) >= start.uptime
                }
                if start.uptime > end.uptime || end.uptime > snapshot.observed.uptime {
                    historyState = "incomparableObservationWindow"
                } else if start.uptime < snapshot.historyStarted.uptime {
                    historyState = "windowPredatesAdmissionHistory"
                } else if let evicted = snapshot.evictedThrough, start.uptime <= evicted.uptime {
                    historyState = "admissionHistoryEvicted"
                } else {
                    historyState = overlappingGaps.isEmpty ? "noAdmissionGapInWindow" : "admissionGapsInWindow"
                }
            } else {
                overlappingGaps = []
                historyState = window == nil ? "receiptWindowUnavailable" : "receiptMarkerTimeUnavailable"
            }
            overlappingRejectedCapturesUpperBound = overlappingGaps.reduce(0) { $0 + $1.rejectedCaptures }
        }
    }

    struct Artwork: Encodable, Sendable {
        let reviewed: CapturedMockImagePreview
        let referenceState: String
        let aspectRatio: Double
        let historicalMatchedRequestCount: Int?
        let otherClientRequestCount: Int?
        let redirectResponseCount: Int?
        let redirectSessionIDs: [UUID]
        let observedReceiptCount: Int
        let deliveredReceiptCount: Int
        let reviewedHashDeliveredCount: Int
        let redirectEvidence: String
        let nextAction: String
        let scope = "Historical matcher counts use the bounded preflight; delivery counts use this receipt page. Redirect status is not a resolved destination or a proven chain. Session handles require separately authorized reads."
    }

    let bundleID: UUID?
    let revisionID: UUID
    let observedAt: Date
    var preflight: CapturedMockPreflight?
    var preflightState: String
    let deliveryState: String
    var coverageQualification: String
    var preflightCoverageQualification: String? = nil
    var preflightIncomplete: Bool? = nil
    var admissionCoverage: AdmissionCoverage?
    var assets: [Asset]
    var assetsTruncated: Bool
    var artwork: [Artwork] = []
    var artworkTruncated = false
    var labReadiness: EffectBundlePresentation.LabReadiness? = nil
    var deliveryEvidence: EffectBundleDeliveryEvidence?
    var resources: [Resource]
    var resourcesTruncated: Bool
    let lifecycleChangedDuringRead: Bool
    var dimensionsState = "unavailableFromRetainedMetadata"
    let targetOutcome = "unknown"
    let scope = "Metadata only; preflight and delivery are separate observations. Resource counts cover this receipt page only and may span historical activations. Delivery does not confirm rendering. Missing dimensions or references are not inferred or loaded from disk."

    func payload() throws -> [String: Any] {
        let data = try encodedData()
        guard data.count <= Self.maximumBytes else { throw InspectionError.responseBudgetExceeded }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Optional metadata gives way before receipt pagination. A returned marker covers only
    /// returned receipts; a single oversized receipt fails rather than becoming invisible.
    func bounded() throws -> Self {
        var result = self
        while try result.encodedData().count > Self.maximumBytes {
            if !result.artwork.isEmpty {
                result.artwork.removeLast()
                result.artworkTruncated = true
            } else if !result.assets.isEmpty {
                result.assets.removeLast()
                result.assetsTruncated = true
            } else if !result.resources.isEmpty {
                result.resources.removeLast()
                result.resourcesTruncated = true
            } else if result.preflight != nil {
                result.preflight = nil
                result.preflightState = "unavailableResponseBudget"
            } else if let page = result.deliveryEvidence, page.observations.count > 1 {
                let observations = Array(page.observations.dropLast())
                result.deliveryEvidence = .init(receipts: observations.compactMap(\.authored), nextMarker: observations.last!.marker,
                    retentionGap: page.retentionGap, hasMore: true, observationState: page.observationState,
                    window: nil, observations: observations)
                result.admissionCoverage = nil
                result.coverageQualification = "responseBudgetTruncatedWindowUnavailable"
            } else if let page = result.deliveryEvidence, page.observations.isEmpty, page.receipts.count > 1 {
                let receipts = Array(page.receipts.dropLast())
                result.deliveryEvidence = .init(receipts: receipts, nextMarker: receipts.last!.marker,
                    retentionGap: page.retentionGap, hasMore: true, observationState: page.observationState,
                    window: nil)
                result.admissionCoverage = nil
                result.coverageQualification = "responseBudgetTruncatedWindowUnavailable"
            } else {
                throw InspectionError.responseBudgetExceeded
            }
        }
        return result
    }

    enum InspectionError: Error {
        case responseBudgetExceeded
        case revisionMismatch
    }
}

/// No file/body access. Callers authorize the subject before supplying its reviewed manifest.
/// Main-actor snapshots are copied before the matcher actor hop; ownership is rechecked afterward.
@MainActor
final class EffectBundleInspectionService {
    private let repository: EffectBundleRepository
    private let coordinator: EffectBundleActivationCoordinator
    private let matcher = ResponseOverrideStore(effectBundleGate: EffectBundleActivationGate())
    private let admissionSnapshot: () -> CaptureAdmissionBudget.Snapshot?

    init(repository: EffectBundleRepository, coordinator: EffectBundleActivationCoordinator,
         admissionSnapshot: @escaping () -> CaptureAdmissionBudget.Snapshot? = { nil }) {
        self.repository = repository
        self.coordinator = coordinator
        self.admissionSnapshot = admissionSnapshot
    }

    func inspect(manifest: EffectBundleManifest, ownerID: String, retained: Bool,
                 after: UInt64 = 0, snapshot: () -> CapturedMockPreflightSnapshot?) async throws -> EffectBundleJoinedInspection {
        let before = retained ? try repository.metadataRecord(id: manifest.id, requestingOwnerID: ownerID) : nil
        guard before == nil || before?.manifest == manifest else {
            throw EffectBundleJoinedInspection.InspectionError.revisionMismatch
        }
        try Task.checkCancellation()
        let capture = snapshot()
        let preflight: CapturedMockPreflight?
        if let capture { preflight = try await matcher.preflight(manifest: manifest, snapshot: capture) }
        else { preflight = nil }
        try Task.checkCancellation()
        let current = retained ? try repository.metadataRecord(id: manifest.id, requestingOwnerID: ownerID) : nil
        guard current == nil || current?.manifest == manifest else {
            throw EffectBundleJoinedInspection.InspectionError.revisionMismatch
        }
        let evidence = retained ? try coordinator.deliveryEvidence(id: manifest.id, requestingOwnerID: ownerID, after: after) : nil
        let revision = manifest.authoring?.revisionID ?? manifest.id
        let resourceIDs = manifest.responseEffects.map(\.id) + manifest.hlsSubstitutions.filter { $0.replacesSubstitutionID == nil }.map(\.id)
        let resources = resourceIDs.prefix(32).map { id in
            let receipts = evidence?.observations.filter {
                $0.identity.bundleID == manifest.id && $0.identity.revisionID == revision && $0.identity.resourceID == id
            } ?? []
            return EffectBundleJoinedInspection.Resource(resourceID: id,
                assetIDs: Array((manifest.responseEffects.first { $0.id == id }?.bodySource.assetIDs ?? []).prefix(16)), observedReceiptCount: receipts.count,
                deliveredReceiptCount: receipts.filter { $0.delivery == .downstreamWriteSucceeded }.count)
        }
        let admission = admissionSnapshot().map {
            EffectBundleJoinedInspection.AdmissionCoverage(snapshot: $0, window: evidence?.window)
        }
        let coverage: String
        if let admission {
            coverage = admission.rejectedCaptures > 0 || admission.metadataOnlyCaptures > 0 ? "captureWideAdmissionGaps" : "latestAdmissionCountersOnly"
        } else {
            coverage = "admissionCoverageUnavailable"
        }
        var result = EffectBundleJoinedInspection(bundleID: retained ? manifest.id : nil,
            revisionID: revision, observedAt: Date(), preflight: preflight,
            preflightState: preflight == nil ? "unavailable" : "available",
            deliveryState: retained ? "available" : "notApplicable",
            coverageQualification: coverage,
            admissionCoverage: admission,
            assets: manifest.assets.prefix(32).map { .init(id: $0.id, sha256: $0.sha256,
                byteCount: $0.byteCount, contentType: $0.contentType) },
            assetsTruncated: manifest.assets.count > 32,
            deliveryEvidence: evidence, resources: resources,
            resourcesTruncated: manifest.responseEffects.count + manifest.hlsSubstitutions.filter { $0.replacesSubstitutionID == nil }.count > 32 || manifest.responseEffects.prefix(32).contains { $0.bodySource.assetIDs.count > 16 },
            lifecycleChangedDuringRead: before != current)
        result.preflightCoverageQualification = preflight?.coverageQualification
        if let current {
            result.labReadiness = try coordinator.supervision(id: current.id, requestingOwnerID: ownerID).labReadiness
        }
        result.preflightIncomplete = preflight?.incomplete
        if let artwork = manifest.authoring?.artwork {
            result.dimensionsState = "reviewedMetadata"
            result.artwork = artwork.prefix(16).map { image in
                let historical = preflight.flatMap { report -> [CapturedMockPreflight.Resource]? in
                    let matches = report.resources.filter { $0.assetIDs.contains(image.assetID) }
                    let expected = manifest.responseEffects.filter { $0.bodySource.assetIDs.contains(image.assetID) }.count
                    guard !matches.isEmpty, matches.count == expected,
                          !matches.contains(where: { $0.reason == "requiresAdditionalEvidence" }) else { return nil }
                    return matches
                }
                let receipts = evidence?.receipts.filter {
                    $0.resource.bundleID == manifest.id && $0.resource.revisionID == revision
                        && $0.resource.assetID == image.assetID
                } ?? []
                let redirects = historical?.reduce(0) { $0 + $1.redirectResponseCount }
                let delivered = receipts.filter { $0.delivery == .downstreamWriteSucceeded }
                let redirectState = historical == nil ? "historicalMetadataUnavailable"
                    : redirects == 0 ? "noRedirectStatusInBoundedMatches" : "redirectStatusObservedDestinationRequiresAuthorizedHeaders"
                let next = (redirects ?? 0) > 0
                    ? "Read response headers for a listed redirect session using the existing headerRead approval path; review Location and subsequent same-client requests. No destination was inferred."
                    : delivered.isEmpty
                        ? "Check the reviewed delivery matcher, client scope and coverage, then request a target refresh explicitly. No observation is not proof of caching."
                        : "Ask the target operator to confirm the visible image and aspect ratio; proxy delivery alone cannot confirm rendering."
                return .init(reviewed: image,
                    referenceState: image.imageReference == nil || image.imageReference == image.url
                        ? "reviewedAbsoluteReference" : "reviewedClientMappingRequired",
                    aspectRatio: Double(image.width) / Double(image.height),
                    historicalMatchedRequestCount: historical.map { $0.reduce(0) { $0 + $1.matchedCount } },
                    otherClientRequestCount: historical.map { $0.reduce(0) { $0 + $1.otherClientCount } },
                    redirectResponseCount: redirects,
                    redirectSessionIDs: Array((historical ?? []).flatMap(\.redirectSessionIDs).prefix(3)),
                    observedReceiptCount: receipts.count, deliveredReceiptCount: delivered.count,
                    reviewedHashDeliveredCount: delivered.filter { $0.servedSHA256 == image.sha256 }.count,
                    redirectEvidence: redirectState, nextAction: next)
            }
            result.artworkTruncated = artwork.count > 16
        }
        return try result.bounded()
    }
}
