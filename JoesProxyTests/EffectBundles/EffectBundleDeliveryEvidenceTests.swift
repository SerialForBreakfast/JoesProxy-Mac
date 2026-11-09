import XCTest
import NIOCore
import NIOEmbedded
@testable import JoesProxy

final class EffectBundleDeliveryEvidenceTests: XCTestCase {
    func testCaptionIdentitySurvivesLateCompletionPagingAndBoundedRetention() throws {
        let gate = EffectBundleActivationGate()
        let identity = EffectBundleObservation.Identity(bundleID: UUID(), revisionID: UUID(), activationID: UUID(), resourceID: UUID(), phaseID: UUID())
        let track = HLSWebVTTFixture.TrackIdentity(id: "es", language: "es", role: "subtitles", sourceRevision: "fixture-v1")
        let receipt = gate.observe(identity: identity, kind: .hlsSegment, outcome: "http_206", segmentSequence: 6,
            segmentPath: "text/es/segment-0.vtt", textTrack: track)
        gate.close(bundleID: identity.bundleID)
        gate.unregister(bundleID: identity.bundleID)
        gate.completeReceipt(id: receipt, succeeded: false, sessionID: UUID())
        let observed = try XCTUnwrap(gate.evidence(bundleID: identity.bundleID).observations.first)
        XCTAssertEqual(observed.textTrack, track)
        XCTAssertEqual(observed.identity, identity)
        XCTAssertEqual(observed.delivery, .downstreamWriteFailed)
        XCTAssertNil(observed.authored)
        XCTAssertEqual(try JSONDecoder().decode(EffectBundleObservation.self, from: JSONEncoder().encode(observed)), observed)
        for _ in 0..<300 { _ = gate.observe(identity: identity, kind: .hlsPlaylist, outcome: "http_200", textTrack: track) }
        XCTAssertEqual(gate.observationSnapshot(bundleID: identity.bundleID).count, 256)
        let page = gate.evidence(bundleID: identity.bundleID)
        XCTAssertEqual(page.observations.count, 32)
        XCTAssertTrue(page.retentionGap)
        XCTAssertLessThan(try JSONEncoder().encode(page).count, 65_536)
        XCTAssertFalse(gate.allows(bundleID: identity.bundleID))
    }
    func testDynamicEvidencePreservesAdmissionIdentityWithoutInventingHashes() throws {
        let gate = EffectBundleActivationGate()
        let identity = EffectBundleObservation.Identity(bundleID: UUID(), revisionID: UUID(),
            activationID: UUID(), resourceID: UUID(), phaseID: UUID())
        let receipt = gate.observe(identity: identity, kind: .liveCollection, outcome: "awaitingResponse")
        gate.close(bundleID: identity.bundleID)
        gate.unregister(bundleID: identity.bundleID)
        gate.updateOutcome(id: receipt, outcome: "capacityLimited")
        gate.completeReceipt(id: receipt, succeeded: true, sessionID: UUID())
        let page = gate.evidence(bundleID: identity.bundleID)
        XCTAssertTrue(page.receipts.isEmpty)
        let observation = try XCTUnwrap(page.observations.first)
        XCTAssertEqual(observation.identity, identity)
        XCTAssertEqual(observation.outcome, "capacityLimited")
        XCTAssertEqual(observation.delivery, .downstreamWriteSucceeded)
        XCTAssertNil(observation.authored)
        let encoded = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SHA256"))
    }

    func testTypedEvidencePaginationAccountsForDynamicAndAuthoredObservations() {
        let gate = EffectBundleActivationGate(), authored = resource()
        let identity = EffectBundleObservation.Identity(bundleID: authored.bundleID, revisionID: authored.revisionID,
            activationID: authored.activationID, resourceID: UUID())
        for _ in 0..<20 {
            _ = gate.observe(resource: authored, servedSHA256: authored.expectedSHA256)
            _ = gate.observe(identity: identity, kind: .hlsSegment, outcome: "http_206", segmentSequence: 4,
                segmentPath: "video/segment-4.ts")
        }
        let first = gate.evidence(bundleID: authored.bundleID)
        XCTAssertEqual(first.observations.count, 32)
        XCTAssertEqual(first.receipts.count, 16)
        XCTAssertTrue(first.observations.filter { $0.kind == .hlsSegment }.allSatisfy {
            $0.segmentPath == "video/segment-4.ts" && $0.segmentSequence == 4 && $0.authored == nil
        })
        let second = gate.evidence(bundleID: authored.bundleID, after: first.nextMarker)
        XCTAssertEqual(second.observations.count, 8)
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(Set((first.observations + second.observations).map(\.id)).count, 40)
    }

    func testDeliveryTracksFutureCompletionNotCaptureCompletion() {
        let gate = EffectBundleActivationGate(), identity = resource()
        let loop = EmbeddedEventLoop()
        for succeeds in [true, false] {
            let id = gate.observe(resource: identity, servedSHA256: identity.expectedSHA256)
            let promise = loop.makePromise(of: Void.self)
            gate.trackDelivery(promise.futureResult, receiptID: id)
            gate.completeReceipt(id: id, sessionID: UUID())
            XCTAssertEqual(gate.evidence(bundleID: identity.bundleID).receipts.last?.delivery, .pending)
            if succeeds { promise.succeed(()) } else { promise.fail(ChannelError.ioOnClosedChannel) }
            loop.run()
            XCTAssertEqual(gate.evidence(bundleID: identity.bundleID).receipts.last?.delivery,
                succeeds ? .downstreamWriteSucceeded : .downstreamWriteFailed)
        }
    }
    private func resource(bundleID: UUID = UUID(), activationID: UUID = UUID(), asset: String = "image") -> EffectBundleResourceIdentity {
        .init(bundleID: bundleID, revisionID: UUID(), activationID: activationID, resourceID: UUID(),
            assetID: asset, expectedSHA256: EffectBundleValidator.sha256Hex(Data([0, 255, 1])))
    }

    func testIndependentJSONAndImageOutcomesAndLateSessionAttachment() throws {
        let gate = EffectBundleActivationGate(), bundle = UUID()
        let json = resource(bundleID: bundle, asset: "json"), image = resource(bundleID: bundle)
        let first = gate.observe(resource: json, servedSHA256: json.expectedSHA256)
        let second = gate.observe(resource: image, servedSHA256: image.expectedSHA256)
        let initial = gate.evidence(bundleID: bundle)
        XCTAssertEqual(initial.receipts.map(\.delivery), [.pending, .pending])
        gate.completeReceipt(id: first, succeeded: true)
        gate.completeReceipt(id: second, succeeded: false)
        let sessionID = UUID()
        gate.completeReceipt(id: first, sessionID: sessionID)
        gate.completeReceipt(id: first, succeeded: false)
        let updated = gate.evidence(bundleID: bundle, after: initial.nextMarker)
        XCTAssertEqual(updated.receipts.count, 2)
        let receipt = try XCTUnwrap(updated.receipts.first { $0.id == first })
        XCTAssertEqual(receipt.delivery, .downstreamWriteSucceeded)
        XCTAssertEqual(receipt.sessionID, sessionID)
        XCTAssertEqual(receipt.targetOutcome, "unknown")
        XCTAssertEqual(updated.receipts.first { $0.id == second }?.delivery, .downstreamWriteFailed)
        XCTAssertTrue(updated.receipts.allSatisfy { $0.matchesReviewedAsset == true })
    }

    func testOldRevisionReceiptsSurviveStopWithoutRelabeling() {
        let gate = EffectBundleActivationGate(), bundle = UUID()
        let old = resource(bundleID: bundle)
        let id = gate.observe(resource: old, servedSHA256: old.expectedSHA256)
        gate.close(bundleID: bundle)
        gate.unregister(bundleID: bundle)
        let new = resource(bundleID: bundle)
        _ = gate.observe(resource: new, servedSHA256: new.expectedSHA256)
        gate.completeReceipt(id: id, succeeded: true)
        XCTAssertEqual(gate.evidence(bundleID: bundle).receipts.first { $0.id == id }?.resource, old)
        XCTAssertEqual(gate.evidence(bundleID: UUID()).observationState, "noRetainedObservation")
    }

    func testBoundedPagesEvictionAndLateCallbacksDoNotResurrectHistory() {
        let gate = EffectBundleActivationGate(), identity = resource()
        let old = gate.observe(resource: identity, servedSHA256: identity.expectedSHA256)
        for _ in 0..<300 { _ = gate.observe(resource: identity, servedSHA256: identity.expectedSHA256) }
        gate.completeReceipt(id: old, succeeded: true)
        var page = gate.evidence(bundleID: identity.bundleID)
        XCTAssertTrue(page.retentionGap)
        var count = page.receipts.count
        XCTAssertEqual(count, 32)
        while page.hasMore {
            page = gate.evidence(bundleID: identity.bundleID, after: page.nextMarker)
            count += page.receipts.count
        }
        XCTAssertEqual(count, 256)
        XCTAssertTrue(gate.evidence(bundleID: identity.bundleID, after: .max).retentionGap)
    }

    func testActualHashMismatchAndContentFreeSerialization() throws {
        let gate = EffectBundleActivationGate(), identity = resource()
        _ = gate.observe(resource: identity, servedSHA256: EffectBundleValidator.sha256Hex(Data("changed".utf8)))
        let evidence = gate.evidence(bundleID: identity.bundleID)
        XCTAssertEqual(try XCTUnwrap(evidence.receipts.first).matchesReviewedAsset, false)
        let data = try JSONEncoder().encode(evidence)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("changed"))
        XCTAssertEqual(try JSONDecoder().decode(EffectBundleDeliveryEvidence.self, from: data), evidence)
    }

    func testFailedAssetReadIsAttributedWithoutDeliveryOrPrivatePaths() async throws {
        let gate = EffectBundleActivationGate(), identity = resource()
        let store = ResponseOverrideStore(effectBundleGate: gate)
        var rule = ResponseOverrideRule(id: identity.resourceID, requestMethod: "GET", requestScheme: .https,
            host: "example.invalid", port: 443, path: "/image.png", matchMode: .exactPath,
            sourceKind: .localFile, sourceDescription: "Synthetic unavailable asset", statusCode: 200, headers: [],
            bodySource: .file(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("absent-image.png")))
        rule.authoredResource = identity
        try await store.addRule(rule)
        let request = CapturedRequest(method: "GET", scheme: .https, host: "example.invalid", port: 443,
            path: "/image.png", headers: [], bodyData: nil, bodySize: nil)
        do { _ = try await store.ruleDecision(for: request); XCTFail("Expected file read failure") } catch { }
        let receipt = try XCTUnwrap(gate.evidence(bundleID: identity.bundleID).receipts.first)
        XCTAssertEqual(receipt.evaluation, .assetReadFailed)
        XCTAssertEqual(receipt.delivery, .notApplied)
        XCTAssertNil(receipt.servedSHA256)
        XCTAssertNil(receipt.matchesReviewedAsset)
        gate.completeReceipt(id: receipt.id, succeeded: true)
        XCTAssertEqual(gate.evidence(bundleID: identity.bundleID).receipts.first?.delivery, .notApplied)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self).contains("absent-image"))
    }
}
