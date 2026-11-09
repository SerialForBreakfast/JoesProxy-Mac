import Foundation

/// Metadata-only wording shared by evidence UI and its acceptance fixtures.
struct EffectBundleObservationPresentation {
    let title: String
    let explanation: String
    let trackSummary: String?
    let technicalDetails: String

    init(_ observation: EffectBundleObservation) {
        let resource: String
        switch observation.kind {
        case .authoredResponse: resource = "Authored response"
        case .liveCollection: resource = "Collection response"
        case .hlsPlaylist: resource = observation.textTrack == nil ? "HLS playlist" : "Caption playlist"
        case .hlsSegment: resource = observation.textTrack == nil ? "HLS segment" : "Caption segment"
        }
        let delivery: String
        switch observation.delivery {
        case .pending:
            delivery = "Delivery pending"
            explanation = "A request was observed; downstream completion has not been recorded."
        case .downstreamWriteFailed:
            delivery = "Delivery failed"
            explanation = "The proxy's downstream write failed. Player receipt, selection and rendering are unconfirmed."
        case .notApplied:
            delivery = "Not applied"
            explanation = "This effect was not applied. This observation does not establish downstream delivery."
        case .downstreamWriteSucceeded:
            delivery = "Delivered by proxy"
            if observation.kind == .liveCollection && Self.skippedOutcomes.contains(observation.outcome) {
                explanation = "Transformation skipped (\(observation.outcome)); the unchanged upstream response was delivered. Target outcome is unconfirmed."
            } else {
                explanation = "The proxy completed its downstream write. This does not confirm player selection, rendering or playback."
            }
        }
        title = "\(resource) · \(delivery)"
        trackSummary = observation.textTrack.map {
            "Text: \($0.language) · \($0.role) · \($0.id). Player selection/rendering unconfirmed."
        }
        technicalDetails = """
        Outcome: \(observation.outcome) · \(observation.delivery.rawValue)
        Revision: \(observation.identity.revisionID)
        Activation: \(observation.identity.activationID)
        Phase: \(observation.identity.phaseID?.uuidString ?? "not recorded")
        Resource: \(observation.identity.resourceID)
        Capture: \(observation.sessionID?.uuidString ?? "unavailable")
        Prepared media: \(observation.preparedMediaID?.uuidString ?? "not recorded")
        Segment: \(observation.segmentSequence.map(String.init) ?? "not recorded")
        Text source revision: \(observation.textTrack?.sourceRevision ?? "not applicable")
        Observed: \(observation.observedAt.ISO8601Format())
        Completed: \(observation.completedAt?.ISO8601Format() ?? "pending or not applicable")
        """
    }

    // Unknown/future outcomes must not be inferred to have passed upstream through unchanged.
    private static let skippedOutcomes: Set<String> = [
        "alreadyPresent", "ineligibleResponse", "unsupportedEncoding", "sizeLimit", "decodeFailed",
        "contractMismatch", "encodingFailed", "capacityLimited", "inactiveRevision", "cancelled"
    ]
}
