import XCTest
@testable import JoesProxy

final class EffectBundleRecoveryPolicyTests: XCTestCase {
    private let available = EffectBundleRecoveryAvailability(receiptExists: true, resourceExists: true,
        captureExists: true, bundleServing: true)

    private func receipt(evaluation: EffectBundleDeliveryReceipt.Evaluation = .responseResolved,
                         delivery: EffectBundleDeliveryReceipt.Delivery = .pending) -> EffectBundleDeliveryReceipt {
        let identity = EffectBundleResourceIdentity(bundleID: UUID(), revisionID: UUID(), activationID: UUID(),
            resourceID: UUID(), assetID: "synthetic-image", expectedSHA256: String(repeating: "a", count: 64))
        var receipt = EffectBundleDeliveryReceipt(id: UUID(), marker: 1, resource: identity,
            servedSHA256: nil, matchesReviewedAsset: nil, observedAt: Date())
        receipt.sessionID = UUID()
        receipt.evaluation = evaluation
        receipt.delivery = delivery
        return receipt
    }

    func testMismatchesOfferInspectionNotMutation() {
        let mismatch = EffectBundleRecoveryPolicy.resolve(receipt(evaluation: .matcherMismatch, delivery: .notApplied), availability: available)
        XCTAssertEqual(mismatch.primary.action, .inspectRequest)
        XCTAssertTrue(mismatch.secondary.contains { $0.action == .reviewMatcher })
        let scope = EffectBundleRecoveryPolicy.resolve(receipt(evaluation: .clientScopeMismatch, delivery: .notApplied), availability: available)
        XCTAssertEqual(scope.primary.action, .reviewClientScope)
        XCTAssertTrue(scope.primary.isEnabled)
    }

    func testPendingAndFailedWritesDoNotReplay() {
        let pending = EffectBundleRecoveryPolicy.resolve(receipt(), availability: available)
        XCTAssertEqual(pending.primary.action, .refreshEvidence)
        let failed = EffectBundleRecoveryPolicy.resolve(receipt(delivery: .downstreamWriteFailed), availability: available)
        XCTAssertEqual(failed.primary.action, .inspectRequest)
        XCTAssertTrue(failed.secondary.contains { $0.action == .observeNextRequest })
    }

    func testAssetFailureRequiresMatchingRetainedResourceForCheck() {
        let receipt = receipt(evaluation: .assetReadFailed, delivery: .notApplied)
        let presentation = EffectBundleRecoveryPolicy.resolve(receipt, availability: available)
        XCTAssertEqual(presentation.primary.action, .checkAsset)
        XCTAssertTrue(presentation.primary.isEnabled)
        var stale = available
        stale.resourceExists = false
        XCTAssertFalse(EffectBundleRecoveryPolicy.resolve(receipt, availability: stale).primary.isEnabled)
    }

    func testEvictionAndLateCaptureIdentityHaveDifferentRecoveryPaths() {
        var context = available
        var receipt = receipt()
        receipt.sessionID = nil
        let missingID = EffectBundleRecoveryPolicy.choice(.inspectRequest, receipt: receipt, availability: context)
        XCTAssertFalse(missingID.isEnabled)
        receipt.sessionID = UUID()
        context.captureExists = false
        let evicted = EffectBundleRecoveryPolicy.choice(.inspectRequest, receipt: receipt, availability: context)
        XCTAssertFalse(evicted.isEnabled)
        XCTAssertNotEqual(missingID.unavailableReason, evicted.unavailableReason)
        XCTAssertTrue(EffectBundleRecoveryPolicy.choice(.reviewMatcher, receipt: receipt, availability: context).isEnabled)
        context.receiptExists = false
        XCTAssertFalse(EffectBundleRecoveryPolicy.choice(.reviewMatcher, receipt: receipt, availability: context).isEnabled)
        XCTAssertTrue(EffectBundleRecoveryPolicy.choice(.refreshEvidence, receipt: nil, availability: context).isEnabled)
    }

    func testStoppedBundleKeepsHistoricalReviewButCannotStartObservation() {
        var context = available
        context.bundleServing = false
        let receipt = receipt()
        XCTAssertFalse(EffectBundleRecoveryPolicy.choice(.observeNextRequest, receipt: receipt, availability: context).isEnabled)
        XCTAssertTrue(EffectBundleRecoveryPolicy.choice(.reviewMatcher, receipt: receipt, availability: context).isEnabled)
        context.resourceExists = false
        XCTAssertFalse(EffectBundleRecoveryPolicy.choice(.reviewClientScope, receipt: receipt, availability: context).isEnabled)
        XCTAssertTrue(EffectBundleRecoveryPolicy.choice(.reviewIntegrity, receipt: receipt, availability: context).isEnabled)
    }

    func testNewObservationMarkerDoesNotAlterReceiptsOrActivateBundle() {
        let gate = EffectBundleActivationGate()
        let receipt = receipt()
        let id = gate.observe(resource: receipt.resource, servedSHA256: nil, evaluation: .assetReadFailed)
        let marker = gate.observationMarker()
        XCTAssertFalse(gate.allows(bundleID: receipt.resource.bundleID))
        XCTAssertTrue(gate.evidence(bundleID: receipt.resource.bundleID, after: marker).receipts.isEmpty)
        XCTAssertEqual(gate.retainedReceipt(id: id, bundleID: receipt.resource.bundleID)?.evaluation, .assetReadFailed)
        gate.completeReceipt(id: id, sessionID: UUID())
        XCTAssertEqual(gate.evidence(bundleID: receipt.resource.bundleID, after: marker).receipts.count, 1)
    }
}
