import XCTest
@testable import JoesProxy

@MainActor
final class GuidedMockDriftTests: XCTestCase {
    private let arguments = ["--ui-test-fixture=guided-mock-authoring", "--ui-test-authoring-artwork",
                             "--ui-test-batch-authoring", "--ui-test-authoring-drift"]

    func testFaultInjectionRequiresEveryFixtureFlagBeforeFileAccess() {
        XCTAssertTrue(GuidedMockDriftUITestScenario.isEnabled(arguments: arguments))
        for omitted in arguments {
            let partial = arguments.filter { $0 != omitted }
            XCTAssertFalse(GuidedMockDriftUITestScenario.isEnabled(arguments: partial))
            XCTAssertThrowsError(try GuidedMockDriftUITestScenario(draft: CapturedMockAuthoringDraft(),
                arguments: partial, environment: [:])) {
                XCTAssertEqual($0 as? GuidedMockDriftUITestScenario.FixtureError, .disabled)
            }
        }
    }

    func testSourceRejectionRetainsReviewAndExplicitReplacementRequiresNewRevision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (draft, scenario) = try makeScenario(root: root)
        let service = CollectionMockAuthoringService(maximumRevisions: 1)
        await draft.prepare(service: service)
        let original = try XCTUnwrap(draft.prepared)
        let source = draft.source
        let edits = draft.guidedDraft
        let related = draft.relatedDrafts
        draft.reviewed = true
        scenario.selectSource(.incomplete)
        XCTAssertNotNil(draft.errorMessage)
        XCTAssertEqual(draft.source, source)
        XCTAssertEqual(draft.prepared?.manifest.id, original.manifest.id)
        XCTAssertTrue(draft.reviewed)
        XCTAssertEqual(draft.guidedDraft, edits)
        XCTAssertEqual(draft.relatedDrafts, related)
        scenario.selectSource(.sameIdentity)
        XCTAssertEqual(draft.source?.id, source?.id)
        XCTAssertNil(draft.prepared)
        XCTAssertFalse(draft.reviewed)
        XCTAssertEqual(draft.relatedDrafts, related)
        XCTAssertEqual(draft.guidedDraft, edits)
        await draft.prepare(service: service)
        let changed = try XCTUnwrap(draft.prepared, draft.errorMessage ?? "Missing changed preparation")
        XCTAssertNotEqual(changed.manifest.id, original.manifest.id)
        let response = try XCTUnwrap(changed.manifest.authoring?.responseAssetID)
        XCTAssertTrue(String(decoding: try XCTUnwrap(changed.assetDataByID[response]), as: UTF8.self).contains("Drifted source"))
        do {
            _ = try await service.inspectCapturedPackage(id: original.manifest.id, ownerID: EffectBundleOwner.localUser.ownerID)
            XCTFail("Repreparation must retire the previous handle")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionRetired) }
        scenario.selectSource(.differentIdentity)
        XCTAssertNotEqual(draft.source?.id, source?.id)
        XCTAssertTrue(draft.relatedDrafts.isEmpty)
        XCTAssertNil(draft.prepared)
        XCTAssertFalse(draft.reviewed)
        await draft.prepare(service: service)
        XCTAssertNotNil(draft.prepared, draft.errorMessage ?? "Missing independent capture preparation")
    }

    func testFixtureRejectsAnArtworkRootOutsideItsConfiguredArtifactDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (draft, _) = try makeScenario(root: root)
        XCTAssertThrowsError(try GuidedMockDriftUITestScenario(draft: draft, arguments: arguments,
            environment: ["JOESPROXY_UI_ARTIFACT_DIRECTORY": root.appendingPathComponent("other-artifacts").path])) {
            XCTAssertEqual($0 as? GuidedMockDriftUITestScenario.FixtureError, .invalidArtwork)
        }
        XCTAssertNil(draft.prepared)
        XCTAssertNil(draft.errorMessage)
    }

    func testMissingArtworkRecoveryPreservesEditsAndRequiresFreshReview() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (draft, scenario) = try makeScenario(root: root)
        let service = CollectionMockAuthoringService(maximumRevisions: 1)
        await draft.prepare(service: service)
        let original = try XCTUnwrap(draft.prepared)
        let edits = draft.guidedDraft
        draft.reviewed = true
        try scenario.removeArtwork()
        XCTAssertEqual(draft.prepared?.assetDataByID, original.assetDataByID)
        XCTAssertTrue(draft.reviewed)
        let edited = await draft.editPreparedRevision()
        XCTAssertTrue(edited)
        await draft.prepare(service: service)
        XCTAssertNil(draft.prepared)
        XCTAssertNotNil(draft.errorMessage)
        XCTAssertEqual(draft.guidedDraft, edits)
        XCTAssertEqual(draft.relatedDrafts.count, 1)
        try scenario.restoreArtwork()
        await draft.prepare(service: service)
        let restored = try XCTUnwrap(draft.prepared, draft.errorMessage ?? "Missing restored preparation")
        XCTAssertNotEqual(restored.manifest.id, original.manifest.id)
        XCTAssertEqual(restored.assetDataByID["image-0"], original.assetDataByID["image-0"])
        XCTAssertEqual(draft.relatedPreviews.count, 1)
        XCTAssertFalse(draft.reviewed)
    }

    func testChangedFileCannotChangeReviewedSaveButFreshPreparationReadsIt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (draft, scenario) = try makeScenario(root: root)
        let service = CollectionMockAuthoringService(maximumRevisions: 1)
        await draft.prepare(service: service)
        let original = try XCTUnwrap(draft.prepared)
        draft.reviewed = true
        try scenario.replaceArtworkBytes()
        XCTAssertEqual(draft.prepared?.assetDataByID, original.assetDataByID)
        XCTAssertEqual(draft.prepared?.images.first?.width, 2)
        let repository = EffectBundleRepository(persistenceURL: root.appendingPathComponent("records.json"),
            packagesRootURL: root.appendingPathComponent("packages"))
        let saved = await draft.save(original, repository: repository, service: service)
        XCTAssertTrue(saved)
        let retained = try repository.manifestAndPackageURL(id: original.manifest.id)
        XCTAssertEqual(repository.record(id: original.manifest.id)?.state, .inactive)
        for asset in retained.manifest.assets {
            XCTAssertEqual(try Data(contentsOf: retained.packageURL.appendingPathComponent(asset.packageRelativePath)),
                           original.assetDataByID[asset.id])
        }
        await draft.prepare(service: service)
        let changed = try XCTUnwrap(draft.prepared, draft.errorMessage ?? "Missing changed artwork")
        XCTAssertEqual(changed.images.first?.width, 3)
        XCTAssertEqual(changed.images.first?.height, 1)
        XCTAssertNotEqual(changed.assetDataByID["image-0"], original.assetDataByID["image-0"])
        XCTAssertNotEqual(changed.manifest.id, original.manifest.id)
        XCTAssertFalse(draft.reviewed)
    }

    private func makeRoot() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent("build/HostTestResults/drift-policy-\(UUID().uuidString)-artifacts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeScenario(root: URL) throws -> (CapturedMockAuthoringDraft, GuidedMockDriftUITestScenario) {
        let draft = CapturedMockAuthoringDraft()
        let environment = ["JOESPROXY_UI_ARTIFACT_DIRECTORY": root.path]
        GuidedMockAuthoringUITestFixture.configure(draft, arguments: arguments, environment: environment)
        let scenario = try GuidedMockDriftUITestScenario(draft: draft, arguments: arguments, environment: environment)
        return (draft, scenario)
    }
}
