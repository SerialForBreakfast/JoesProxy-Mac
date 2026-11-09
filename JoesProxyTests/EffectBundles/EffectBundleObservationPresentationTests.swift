import XCTest
@testable import JoesProxy

final class EffectBundleObservationPresentationTests: XCTestCase {
    func testCaptionDeliverySeparatesTransportFromRenderingAndKeepsAdmissionAttribution() throws {
        let gate = EffectBundleActivationGate()
        let identity = EffectBundleObservation.Identity(bundleID: UUID(), revisionID: UUID(),
            activationID: UUID(), resourceID: UUID(), phaseID: UUID())
        let track = HLSWebVTTFixture.TrackIdentity(id: "ar", language: "ar", role: "subtitles", sourceRevision: "reviewed-v1")
        let id = gate.observe(identity: identity, kind: .hlsSegment, outcome: "http_206", segmentSequence: 8, textTrack: track)
        var item = try XCTUnwrap(gate.evidence(bundleID: identity.bundleID).observations.first)
        XCTAssertTrue(EffectBundleObservationPresentation(item).title.contains("pending"))
        gate.close(bundleID: identity.bundleID)
        gate.unregister(bundleID: identity.bundleID)
        gate.completeReceipt(id: id, succeeded: true)
        item = try XCTUnwrap(gate.evidence(bundleID: identity.bundleID).observations.first)
        let presentation = EffectBundleObservationPresentation(item)
        XCTAssertTrue(presentation.title.contains("Delivered by proxy"))
        XCTAssertTrue(presentation.explanation.contains("does not confirm"))
        XCTAssertTrue(presentation.technicalDetails.contains(identity.activationID.uuidString))
        XCTAssertTrue(presentation.technicalDetails.contains(try XCTUnwrap(identity.phaseID).uuidString))
        XCTAssertTrue(presentation.technicalDetails.contains("reviewed-v1"))
        XCTAssertFalse(presentation.technicalDetails.contains("SHA256"))
        XCTAssertFalse(gate.allows(bundleID: identity.bundleID))
    }

    func testSkippedTransformRequiresSuccessfulDeliveryAndKnownOutcomeToClaimUpstreamDelivered() {
        var item = EffectBundleObservation(id: UUID(), marker: 1,
            identity: .init(bundleID: UUID(), revisionID: UUID(), activationID: UUID(), resourceID: UUID()),
            kind: .liveCollection, observedAt: Date(timeIntervalSince1970: 0), outcome: "capacityLimited")
        for delivery in [EffectBundleDeliveryReceipt.Delivery.pending, .downstreamWriteFailed, .notApplied] {
            item.delivery = delivery
            XCTAssertFalse(EffectBundleObservationPresentation(item).explanation.contains("upstream response was delivered"))
        }
        item.delivery = .downstreamWriteSucceeded
        XCTAssertTrue(EffectBundleObservationPresentation(item).explanation.contains("unchanged upstream response was delivered"))
        for outcome in ["applied", "unknownFutureOutcome", "awaitingResponse"] {
            item.outcome = outcome
            XCTAssertFalse(EffectBundleObservationPresentation(item).explanation.contains("unchanged upstream"))
        }
    }

    func testStoppedCaptionHistoryPagesWithoutInventingMissingRequestsOrReopeningEffects() throws {
        let gate = EffectBundleActivationGate()
        let identity = EffectBundleObservation.Identity(bundleID: UUID(), revisionID: UUID(), activationID: UUID(), resourceID: UUID())
        for index in 0..<40 {
            let id = gate.observe(identity: identity, kind: .hlsSegment, outcome: "http_200", segmentSequence: index,
                textTrack: .init(id: "ja", language: "ja", role: "subtitles", sourceRevision: "v1"))
            gate.completeReceipt(id: id, succeeded: index != 1)
        }
        gate.close(bundleID: identity.bundleID)
        var page = gate.evidence(bundleID: identity.bundleID)
        XCTAssertEqual(page.observations.count, 32)
        XCTAssertTrue(page.hasMore)
        XCTAssertTrue(page.receipts.isEmpty)
        page = gate.evidence(bundleID: identity.bundleID, after: page.nextMarker)
        XCTAssertEqual(page.observations.map(\.segmentSequence), Array(32..<40).map(Optional.some))
        XCTAssertFalse(page.hasMore)
        let empty = gate.evidence(bundleID: identity.bundleID, after: page.nextMarker)
        XCTAssertTrue(empty.observations.isEmpty)
        XCTAssertTrue(empty.scope.contains("does not establish a cache hit"))
        XCTAssertFalse(gate.allows(bundleID: identity.bundleID))
    }
}
