import XCTest
@testable import JoesProxy

final class ExperimentWorkflowGuidanceTests: XCTestCase {
    func testTypedMediaAndCollectionEvidenceIsNotMisreportedAsEmpty() {
        for kind in [EffectBundleObservation.Kind.liveCollection, .hlsPlaylist, .hlsSegment] {
            let gate = EffectBundleActivationGate()
            let identity = EffectBundleObservation.Identity(bundleID: UUID(), revisionID: UUID(),
                activationID: UUID(), resourceID: UUID())
            let receipt = gate.observe(identity: identity, kind: kind,
                outcome: kind == .liveCollection ? "awaitingResponse" : "http_200")
            let pending = ExperimentWorkflowGuidance.delivery(gate.evidence(bundleID: identity.bundleID))
            XCTAssertEqual(pending.stage, .evaluate)
            XCTAssertTrue(pending.reasonCodes.contains("deliveryPending"))
            XCTAssertFalse(pending.reasonCodes.contains("noRetainedObservation"))
            XCTAssertFalse(pending.reasonCodes.contains("liveTransformationNotApplied"))
            gate.completeReceipt(id: receipt, succeeded: false)
            let failed = ExperimentWorkflowGuidance.delivery(gate.evidence(bundleID: identity.bundleID))
            XCTAssertTrue(failed.reasonCodes.contains("downstreamWriteFailed"))
            XCTAssertFalse(failed.reasonCodes.contains("deliveryPending"))
        }
    }

    func testSkippedTransformationDoesNotConfuseUpstreamDeliveryWithAppliedMutation() {
        for outcome in ["alreadyPresent", "capacityLimited", "contractMismatch", "cancelled", "unsupportedEncoding"] {
            let gate = EffectBundleActivationGate()
            let identity = EffectBundleObservation.Identity(bundleID: UUID(), revisionID: UUID(),
                activationID: UUID(), resourceID: UUID())
            let receipt = gate.observe(identity: identity, kind: .liveCollection, outcome: outcome)
            gate.completeReceipt(id: receipt, succeeded: true)
            let evidence = gate.evidence(bundleID: identity.bundleID)
            XCTAssertTrue(evidence.receipts.isEmpty)
            XCTAssertEqual(evidence.observations.first?.delivery, .downstreamWriteSucceeded)
            let guidance = ExperimentWorkflowGuidance.delivery(evidence)
            XCTAssertTrue(guidance.reasonCodes.contains("liveTransformationNotApplied"))
            XCTAssertEqual(guidance.targetOutcome, "unknown")
            XCTAssertFalse(guidance.nextActions.contains { $0.tool == "apply_activate_effect_bundle" })
        }
    }

    func testLifecycleOverridesHistoricalEvidenceWithoutGrantingAuthority() {
        let gate = EffectBundleActivationGate(), bundle = UUID()
        let asset = resource(bundle: bundle, revision: UUID(), asset: "image")
        let receipt = gate.observe(resource: asset, servedSHA256: asset.expectedSHA256)
        gate.completeReceipt(id: receipt, succeeded: true)
        let evidence = gate.evidence(bundleID: bundle)
        XCTAssertEqual(ExperimentWorkflowGuidance.retained(state: .serving, evidence: evidence).stage, .evaluate)
        let inactive = ExperimentWorkflowGuidance.retained(state: .inactive, evidence: evidence)
        XCTAssertEqual(inactive.stage, .review)
        XCTAssertEqual(inactive.nextActions.last?.tool, "propose_activate_effect_bundle")
        XCTAssertEqual(inactive.nextActions.last?.authority, "existingApprovalPolicy")
        for state in [EffectBundleState.stopped, .expired, .cleanupRequired] {
            let guidance = ExperimentWorkflowGuidance.retained(state: state, evidence: evidence)
            XCTAssertEqual(guidance.stage, .cleanup)
            XCTAssertFalse(guidance.nextActions.contains { $0.tool == "propose_activate_effect_bundle" })
            XCTAssertEqual(guidance.targetOutcome, "unknown")
        }
        let raced = ExperimentWorkflowGuidance.retained(state: .serving, evidence: evidence, lifecycleChanged: true)
        XCTAssertEqual(raced.stage, .preflight)
        XCTAssertEqual(raced.nextActions.map(\.tool), ["effect_bundle_inspect"])
    }

    func testPreparationActivationAndStopDoNotOverstateTheirEvidence() {
        XCTAssertEqual(ExperimentWorkflowGuidance.prepared.stage, .review)
        XCTAssertFalse(ExperimentWorkflowGuidance.prepared.nextActions.contains { $0.tool == "apply_activate_effect_bundle" })
        XCTAssertEqual(ExperimentWorkflowGuidance.activated.reasonCodes, ["deliveryUnverified"])
        XCTAssertEqual(ExperimentWorkflowGuidance.stopped.stage, .cleanup)
        XCTAssertEqual(ExperimentWorkflowGuidance.stopped.reasonCodes, ["returnToNormalUnverified"])
        XCTAssertEqual(ExperimentWorkflowGuidance.stopped.targetOutcome, "unknown")
    }

    private func resource(bundle: UUID, revision: UUID, asset: String) -> EffectBundleResourceIdentity {
        .init(bundleID: bundle, revisionID: revision, activationID: UUID(), resourceID: UUID(),
              assetID: asset, expectedSHA256: EffectBundleValidator.sha256Hex(Data(asset.utf8)))
    }

    func testSyntheticListingDeliveryDoesNotEstablishImageOrTargetSuccess() throws {
        let gate = EffectBundleActivationGate(), bundle = UUID(), revision = UUID()
        let listing = resource(bundle: bundle, revision: revision, asset: "listing")
        let marker = gate.evidence(bundleID: bundle).nextMarker
        let receipt = gate.observe(resource: listing, servedSHA256: listing.expectedSHA256)
        gate.completeReceipt(id: receipt, succeeded: true)
        let evidence = gate.evidence(bundleID: bundle, after: marker)
        let guidance = ExperimentWorkflowGuidance.delivery(evidence)
        XCTAssertEqual(evidence.receipts.map(\.resource.assetID), ["listing"])
        XCTAssertEqual(guidance.stage, .evaluate)
        XCTAssertEqual(guidance.targetOutcome, "unknown")
        XCTAssertTrue(guidance.reasonCodes.contains("targetOutcomeUnknown"))
        // A separately observed target rejection must not mutate transport evidence to failure.
        XCTAssertEqual(evidence.receipts.first?.delivery, .downstreamWriteSucceeded)
        XCTAssertEqual(evidence.receipts.first?.targetOutcome, "unknown")
        XCTAssertNil(guidance.nextActions.last?.tool)
        XCTAssertEqual(guidance.nextActions.last?.authority, "separateTargetInteractionPermission")
    }

    func testClientMismatchAndLateOldRevisionRemainAttributed() {
        let gate = EffectBundleActivationGate(), bundle = UUID()
        let old = resource(bundle: bundle, revision: UUID(), asset: "image")
        let current = resource(bundle: bundle, revision: UUID(), asset: "image")
        let oldReceipt = gate.observe(resource: old, servedSHA256: old.expectedSHA256)
        let marker = gate.evidence(bundleID: bundle).nextMarker
        _ = gate.observe(resource: current, servedSHA256: nil, evaluation: .clientScopeMismatch)
        gate.completeReceipt(id: oldReceipt, succeeded: true)
        let page = gate.evidence(bundleID: bundle, after: marker)
        XCTAssertEqual(page.receipts.first { $0.id == oldReceipt }?.resource.revisionID, old.revisionID)
        XCTAssertFalse(page.receipts.contains { $0.resource.revisionID == current.revisionID && $0.delivery == .downstreamWriteSucceeded })
        let guidance = ExperimentWorkflowGuidance.delivery(page)
        XCTAssertTrue(guidance.reasonCodes.contains("clientScopeMismatch"))
        XCTAssertFalse(guidance.nextActions.contains { $0.tool == "apply_activate_effect_bundle" })
        XCTAssertEqual(guidance.targetOutcome, "unknown")
    }

    func testIntegrityFailureSuggestsOwnedStopWithoutClaimingCleanup() {
        let gate = EffectBundleActivationGate(), bundle = UUID()
        _ = gate.observe(resource: resource(bundle: bundle, revision: UUID(), asset: "image"),
                         servedSHA256: nil, evaluation: .assetReadFailed)
        let guidance = ExperimentWorkflowGuidance.delivery(gate.evidence(bundleID: bundle))
        XCTAssertTrue(guidance.reasonCodes.contains("assetReadFailed"))
        XCTAssertEqual(guidance.nextActions.last?.tool, "effect_bundle_stop")
        XCTAssertEqual(guidance.nextActions.last?.authority, "existingOwnerPolicy")
        XCTAssertEqual(guidance.stage, .evaluate)
    }

    func testPartialCleanupAndUnverifiedTerminalNeverAdvanceToReport() {
        let partial = ExperimentWorkflowGuidance.run(status: .cleanupRequired, cleanupVerified: false)
        XCTAssertEqual(partial.stage, .cleanup)
        XCTAssertEqual(partial.nextActions.first?.tool, "diagnostic_run_retry_cleanup")
        for status in [DiagnosticRunStatus.passed, .failed, .inconclusive, .expired] {
            XCTAssertEqual(ExperimentWorkflowGuidance.run(status: status, cleanupVerified: false).stage, .cleanup)
            XCTAssertEqual(ExperimentWorkflowGuidance.run(status: status, cleanupVerified: true).stage, .report)
        }
    }

    func testPagedEvidenceHasBoundedContentFreeGuidance() throws {
        let gate = EffectBundleActivationGate(), bundle = UUID()
        let identity = resource(bundle: bundle, revision: UUID(), asset: "synthetic-private-body-sentinel")
        for _ in 0..<300 { _ = gate.observe(resource: identity, servedSHA256: nil) }
        let page = gate.evidence(bundleID: bundle)
        let guidance = ExperimentWorkflowGuidance.delivery(page)
        XCTAssertTrue(guidance.reasonCodes.contains("retentionGap"))
        XCTAssertTrue(guidance.reasonCodes.contains("moreEvidencePages"))
        XCTAssertEqual(guidance.nextActions.count, 1)
        XCTAssertLessThanOrEqual(guidance.reasonCodes.count, 10)
        let bytes = try JSONSerialization.data(withJSONObject: guidance.payload, options: [.sortedKeys])
        XCTAssertLessThan(bytes.count, 2_048, "Guidance must remain bounded independently of traffic volume.")
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(identity.assetID))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(identity.bundleID.uuidString))
        XCTAssertEqual(try JSONDecoder().decode(ExperimentWorkflowGuidance.self,
            from: JSONEncoder().encode(guidance)), guidance)
    }

    func testEmptyObservationDoesNotInventCacheOrActivationState() {
        let gate = EffectBundleActivationGate()
        let guidance = ExperimentWorkflowGuidance.delivery(gate.evidence(bundleID: UUID()))
        XCTAssertEqual(guidance.stage, .observe)
        XCTAssertEqual(guidance.reasonCodes, ["noRetainedObservation", "targetOutcomeUnknown"])
        XCTAssertEqual(guidance.targetOutcome, "unknown")
    }
}
