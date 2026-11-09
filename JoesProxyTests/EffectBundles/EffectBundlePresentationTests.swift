import XCTest
@testable import JoesProxy

final class EffectBundlePresentationTests: XCTestCase {
    func testLabReadinessSeparatesLegacyScopeRoutingAndApproval() {
        var record = makeRecord()
        record.manifest.hlsSubstitutions = [.init(id: UUID(), profileID: "synthetic", profileVersion: "1",
            profileAssetIDs: [], profileRootLogicalPath: "media", origin: .init(scheme: .https, host: "media.example.test"),
            scope: .selectedPlaylist(path: "/master.m3u8"), playbackConfiguration: .conformant)]
        var result = EffectBundlePresentation.supervision(record, phase: nil, routingOpen: false)
        XCTAssertEqual(result.labReadiness?.compatibility, "legacyScopeRequiresRevision")
        record.manifest.hlsSubstitutions[0].requestPolicy = .init(clientAddress: "192.0.2.10", missingTextTrackID: nil)
        result = EffectBundlePresentation.supervision(record, phase: nil, routingOpen: false)
        XCTAssertEqual(result.labReadiness?.compatibility, "scopedMediaConfigured")
        XCTAssertEqual(result.labReadiness?.lifecycle, "configured")
        XCTAssertEqual(result.clientScopes, ["192.0.2.10"])
        result = EffectBundlePresentation.supervision(record, phase: nil, routingOpen: true)
        XCTAssertEqual(result.labReadiness?.lifecycle, "active")
        XCTAssertEqual(result.labReadiness?.approvalState, "inspectProposalApprovalSeparately")
        XCTAssertEqual(result.labReadiness?.targetOutcome, "unassessed")
        record.state = .cleanupRequired
        result = EffectBundlePresentation.supervision(record, phase: nil, routingOpen: false)
        XCTAssertEqual(result.labReadiness?.lifecycle, "cleanupRequired")
    }
    func testSupervisionDoesNotOfferActivationDuringCleanupOrAnOwnedTransition() {
        var record = makeRecord()
        var projection = EffectBundlePresentation.supervision(record, phase: nil, routingOpen: false)
        XCTAssertEqual(projection.nextActions, ["propose_activate_effect_bundle"])
        XCTAssertTrue(projection.authority.contains("local-user approval"))
        projection = EffectBundlePresentation.supervision(record, phase: nil, routingOpen: false, lifecycleBusy: true)
        XCTAssertEqual(projection.nextActions, ["effect_bundle_inspect"])
        record.state = .cleanupRequired
        projection = EffectBundlePresentation.supervision(record, phase: nil, routingOpen: false)
        XCTAssertTrue(projection.cleanupRequired)
        XCTAssertEqual(projection.nextActions, ["effect_bundle_stop", "effect_bundle_inspect"])
        record.state = .serving
        projection = EffectBundlePresentation.supervision(record, phase: nil, routingOpen: false)
        XCTAssertEqual(projection.nextActions, ["effect_bundle_inspect"])
        projection = EffectBundlePresentation.supervision(record, phase: nil, routingOpen: true)
        XCTAssertEqual(projection.nextActions, ["effect_bundle_inspect", "effect_bundle_stop"])
    }

    func testReviewRejectsRemovedRevisedOrAlreadyActivatedBundle() {
        let reviewed = makeRecord()
        XCTAssertTrue(EffectBundlePresentation.isCurrentReview(reviewed, current: reviewed))
        XCTAssertFalse(EffectBundlePresentation.isCurrentReview(reviewed, current: nil))
        var changed = reviewed
        changed.manifest.notes = "Revised configuration"
        XCTAssertFalse(EffectBundlePresentation.isCurrentReview(reviewed, current: changed))
        changed = reviewed
        changed.state = .serving
        XCTAssertFalse(EffectBundlePresentation.isCurrentReview(reviewed, current: changed))
        changed = reviewed
        changed.owner = .mcpClient(id: "synthetic", displayName: "Test agent")
        XCTAssertFalse(EffectBundlePresentation.isCurrentReview(reviewed, current: changed))
    }

    func testDuplicateNamesCanBeDistinguishedByBundleAndRevisionIDs() {
        let first = makeRecord()
        var second = first
        second.id = UUID()
        second.manifest.id = second.id
        second.manifest.authoring = nil
        XCTAssertTrue(EffectBundlePresentation.matches(first, query: first.id.uuidString.lowercased()))
        XCTAssertFalse(EffectBundlePresentation.matches(second, query: first.id.uuidString))
        let revision = first.manifest.authoring!.revisionID.uuidString
        XCTAssertTrue(EffectBundlePresentation.matches(first, query: revision))
        XCTAssertFalse(EffectBundlePresentation.matches(second, query: revision))
        XCTAssertTrue(EffectBundlePresentation.matches(first, query: " carousel "))
        XCTAssertTrue(EffectBundlePresentation.matches(second, query: "\n "))
    }

    func testSearchDoesNotTreatOwnerIdentityOrManagedPathsAsUserLabels() {
        let record = makeRecord()
        XCTAssertFalse(EffectBundlePresentation.matches(record, query: "private-storage-path"))
        XCTAssertFalse(EffectBundlePresentation.matches(record, query: "joesproxy-local-user"))
    }

    private func makeRecord() -> EffectBundleRecord {
        let id = UUID()
        let manifest = EffectBundleManifest(
            schemaVersion: EffectBundleSchema.currentVersion, id: id, name: "Diagnostic carousel",
            notes: "Image query corrected", createdAt: .distantPast, appVersion: "test",
            privacy: .exactContent, defaultTTLSeconds: 1_800, assets: [], responseEffects: [],
            hlsSubstitutions: [], authoring: .init(mode: .capturedFixture, revisionID: UUID(),
                sourceDigest: String(repeating: "a", count: 64), responseAssetID: "json",
                beforeCount: 1, afterCount: 2))
        return EffectBundleRecord(id: id, owner: .localUser, manifest: manifest,
            managedPackagePath: "private-storage-path", state: .stopped, importedAt: .distantPast,
            activatedAt: nil, expiresAt: nil, stoppedAt: nil, cleanupMessage: nil)
    }
}
