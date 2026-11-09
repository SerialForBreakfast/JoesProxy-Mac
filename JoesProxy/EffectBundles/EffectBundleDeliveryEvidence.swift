import Foundation

/// Transport facts only. Dynamic responses intentionally have no invented asset digest.
struct EffectBundleObservation: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case authoredResponse, liveCollection, hlsPlaylist, hlsSegment }
    struct Identity: Codable, Equatable, Sendable {
        let bundleID: UUID
        let revisionID: UUID
        let activationID: UUID
        let resourceID: UUID
        var phaseID: UUID?
    }
    let id: UUID
    var marker: UInt64
    let identity: Identity
    let kind: Kind
    let observedAt: Date
    var sessionID: UUID?
    var outcome: String
    var delivery: EffectBundleDeliveryReceipt.Delivery = .pending
    var completedAt: Date?
    var preparedMediaID: UUID?
    var segmentSequence: Int?
    var segmentPath: String?
    var textTrack: HLSWebVTTFixture.TrackIdentity?
    var authored: EffectBundleDeliveryReceipt?
}

struct EffectBundleResourceIdentity: Codable, Equatable, Sendable {
    let bundleID: UUID
    let revisionID: UUID
    let activationID: UUID
    let resourceID: UUID
    let assetID: String
    let expectedSHA256: String
    var phaseID: UUID? = nil
    var materializedSHA256: String? = nil
}

struct EffectBundleDeliveryReceipt: Codable, Equatable, Identifiable, Sendable {
    enum Delivery: String, Codable, Sendable { case pending, downstreamWriteSucceeded, downstreamWriteFailed, notApplied }
    enum Evaluation: String, Codable, Sendable { case responseResolved, matcherMismatch, clientScopeMismatch, assetReadFailed }
    let id: UUID
    var marker: UInt64
    let resource: EffectBundleResourceIdentity
    let servedSHA256: String?
    let matchesReviewedAsset: Bool?
    var matchesMaterializedAsset: Bool? = nil
    var evaluation: Evaluation = .responseResolved
    let observedAt: Date
    var sessionID: UUID?
    var delivery: Delivery = .pending
    var completedAt: Date?
    private(set) var targetOutcome = "unknown"

    var matchesExpectedDelivery: Bool? { matchesMaterializedAsset ?? matchesReviewedAsset }
}

struct EffectBundleDeliveryEvidence: Codable, Equatable, Sendable {
    struct ObservationWindow: Codable, Equatable, Sendable {
        let timelineID: UUID
        let afterMarker: UInt64
        let throughMarker: UInt64
        let start: CaptureObservationInstant?
        let end: CaptureObservationInstant
        let startState: String
    }
    let receipts: [EffectBundleDeliveryReceipt]
    let nextMarker: UInt64
    let retentionGap: Bool
    let hasMore: Bool
    let observationState: String
    var window: ObservationWindow? = nil
    var observations: [EffectBundleObservation] = []
    private(set) var scope = "Process-local bounded transport evidence. Authored receipts are a compatibility projection. Write success is not rendering/playback confirmation. No observation does not establish a cache hit."
}
