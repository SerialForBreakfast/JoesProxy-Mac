import XCTest
@testable import JoesProxy

@MainActor
final class InactiveAuthoringPersistenceTests: XCTestCase {
    func testReviewedArtworkBundleReopensExactlyAfterDraftAndCacheRetirement() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent("build/HostTestResults/inactive-save-\(UUID().uuidString)-artifacts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppPresentationState(configuration: MCPSelfValidationAppConfiguration())
        let draft = state.capturedMockAuthoringDraft
        GuidedMockAuthoringUITestFixture.configure(draft,
            arguments: ["--ui-test-batch-authoring", "--ui-test-authoring-artwork"],
            environment: ["JOESPROXY_UI_ARTIFACT_DIRECTORY": root.path])
        let service = CollectionMockAuthoringService(maximumRevisions: 1)
        await draft.prepare(service: service)
        let prepared = try XCTUnwrap(draft.prepared, draft.errorMessage ?? "Missing preparation")
        let index = root.appendingPathComponent("records.json")
        let packages = root.appendingPathComponent("packages")
        let repository = EffectBundleRepository(persistenceURL: index, packagesRootURL: packages)
        let unreviewed = await draft.save(prepared, repository: repository, service: service)
        XCTAssertFalse(unreviewed)
        XCTAssertTrue(repository.records.isEmpty)
        draft.reviewed = true
        let saved = await draft.save(prepared, repository: repository, service: service)
        XCTAssertTrue(saved)
        let repeated = await draft.save(prepared, repository: repository, service: service)
        XCTAssertFalse(repeated, "A completed UI save cannot resubmit its retired preparation")
        let discarded = await state.discardCapturedMockAuthoringDraft()
        XCTAssertTrue(discarded)
        XCTAssertNil(state.capturedMockAuthoringDraft.source)
        let reopened = EffectBundleRepository(persistenceURL: index, packagesRootURL: packages)
        XCTAssertEqual(reopened.records.count, 1)
        let record = try XCTUnwrap(reopened.record(id: prepared.manifest.id))
        XCTAssertEqual(record.owner, .localUser)
        XCTAssertEqual(record.state, .inactive)
        XCTAssertFalse(record.isServing)
        XCTAssertNil(record.activatedAt)
        XCTAssertNil(record.expiresAt)
        let retained = try reopened.manifestAndPackageURL(id: record.id)
        XCTAssertEqual(retained.manifest, prepared.manifest)
        for asset in retained.manifest.assets {
            let bytes = try Data(contentsOf: retained.packageURL.appendingPathComponent(asset.packageRelativePath))
            XCTAssertEqual(bytes, prepared.assetDataByID[asset.id], "Saved assets must retain the exact reviewed bytes")
        }
        do {
            _ = try await service.inspectCapturedPackage(id: record.id, ownerID: EffectBundleOwner.localUser.ownerID)
            XCTFail("Persistence must not depend on keeping the preparation alive")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionRetired) }
        _ = try reopened.inspect(id: record.id)
    }
}
