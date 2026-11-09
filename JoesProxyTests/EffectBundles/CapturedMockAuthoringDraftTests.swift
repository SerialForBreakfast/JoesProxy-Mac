import XCTest
@testable import JoesProxy

@MainActor
final class CapturedMockAuthoringDraftTests: XCTestCase {
    func testEditSourceReplacementAndDiscardRetirePreparedHandles() async throws {
        let state = AppPresentationState(configuration: MCPSelfValidationAppConfiguration())
        let draft = state.capturedMockAuthoringDraft
        let service = CollectionMockAuthoringService(maximumRevisions: 1)
        XCTAssertNil(draft.selectSource(capture()))
        draft.clientAddress = "192.0.2.1"
        await draft.prepare(service: service)
        let first = try XCTUnwrap(draft.prepared?.manifest.id)
        draft.reviewed = true
        let edited = await draft.editPreparedRevision()
        XCTAssertTrue(edited)
        XCTAssertFalse(draft.reviewed)
        XCTAssertNil(draft.prepared)
        do {
            _ = try await service.inspectCapturedPackage(id: first, ownerID: EffectBundleOwner.localUser.ownerID)
            XCTFail("Edit must retire the old cache handle")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionRetired) }
        await draft.prepare(service: service)
        let second = try XCTUnwrap(draft.prepared?.manifest.id)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(draft.selectSource(capture()))
        await draft.prepare(service: service)
        let third = try XCTUnwrap(draft.prepared?.manifest.id)
        XCTAssertNotEqual(second, third, "Source replacement releases prior preparation before reserving capacity")
        let discarded = await state.discardCapturedMockAuthoringDraft()
        XCTAssertTrue(discarded)
        do {
            _ = try await service.inspectCapturedPackage(id: third, ownerID: EffectBundleOwner.localUser.ownerID)
            XCTFail("Discard must retire the prepared cache handle")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionRetired) }
    }
    func testGuidedBatchPreparationFreezesCountsAndRetainsFailedDraft() async throws {
        let draft = CapturedMockAuthoringDraft()
        var session = capture()
        let body = Data(#"{"items":[{"id":"original","keep":null}]}"#.utf8)
        session.response = CapturedResponse(statusCode: 200, headers: [], bodyData: body, bodySize: body.count)
        XCTAssertNil(draft.selectSource(session))
        draft.clientAddress = "192.0.2.1"
        draft.guidedDraft.useTemplate = true
        draft.guidedDraft.expandTemplate = true
        draft.guidedDraft.expansionItemsJSON = #"[{"edits":[{"pointer":"/id","value":"original"}]}]"#
        let failed = draft.guidedDraft
        let service = CollectionMockAuthoringService()
        await draft.prepare(service: service)
        XCTAssertNil(draft.prepared)
        XCTAssertEqual(draft.guidedDraft, failed)
        draft.guidedDraft.expansionItemsJSON = GuidedCollectionMockDraft().expansionItemsJSON
        await draft.prepare(service: service)
        let package = try XCTUnwrap(draft.prepared)
        XCTAssertEqual(package.manifest.authoring?.beforeCount, 1)
        XCTAssertEqual(package.manifest.authoring?.afterCount, 3)
        await draft.prepare(service: service)
        XCTAssertEqual(draft.prepared?.manifest.id, package.manifest.id)
        XCTAssertFalse(draft.reviewed)
    }
    func testDiscoveryRequiresExplicitSelectionAndResetsWithSource() async throws {
        let draft = CapturedMockAuthoringDraft()
        XCTAssertNil(draft.selectSource(capture()))
        draft.guidedDraft.collectionPointer = "/manual"
        let originalItem = draft.guidedDraft.itemJSON
        await draft.discoverCollections()
        XCTAssertEqual(draft.guidedDraft.collectionPointer, "/manual")
        let candidate = try XCTUnwrap(draft.collectionDiscovery?.collections.first)
        draft.selectCollection(candidate)
        XCTAssertEqual(draft.guidedDraft.collectionPointer, "/items")
        XCTAssertEqual(draft.guidedDraft.itemJSON, originalItem)
        draft.selectCollection(.init(pointer: "/invented", count: 0))
        XCTAssertEqual(draft.guidedDraft.collectionPointer, "/items")
        XCTAssertNil(draft.selectSource(capture()))
        XCTAssertNil(draft.collectionDiscovery)
    }

    private func capture(type: String = "application/json", complete: Bool = true) -> SessionRecord {
        let body = Data(#"{"items":[]}"#.utf8)
        return SessionRecord(request: CapturedRequest(method: "GET", scheme: .https,
            host: "example.test", port: 443, path: "/items", headers: [], bodyData: nil, bodySize: nil),
            response: CapturedResponse(statusCode: 200, headers: [.init(name: "Content-Type", value: type)],
                bodyData: body, bodySize: body.count, bodyTruncated: !complete),
            timing: SessionTiming(startedAt: Date()))
    }

    func testImageFailureShowsSharedGuidanceAndRetainsDraft() async {
        let draft = CapturedMockAuthoringDraft()
        XCTAssertNil(draft.selectSource(capture()))
        draft.clientAddress = "192.0.2.1"
        draft.imageBookmark = "synthetic-private-reference"
        await draft.prepare(service: CollectionMockAuthoringService())
        XCTAssertTrue(draft.errorMessage?.contains("images[0].localFileBookmarkRef") == true)
        XCTAssertFalse(draft.errorMessage?.contains("synthetic-private-reference") == true)
        XCTAssertEqual(draft.imageBookmark, "synthetic-private-reference")
        XCTAssertNil(draft.prepared)
        XCTAssertFalse(draft.busy)
        draft.imageBookmark = nil
        await draft.prepare(service: CollectionMockAuthoringService())
        XCTAssertNotNil(draft.prepared)
    }

    func testInvalidSourcePreservesExistingSourceAndDraft() {
        let draft = CapturedMockAuthoringDraft()
        let original = capture()
        XCTAssertNil(draft.selectSource(original))
        draft.guidedDraft.itemJSON = #"{"id":"custom"}"#
        draft.draftJSON = "advanced draft"
        draft.imageBookmark = "retained opaque reference"
        XCTAssertNotNil(draft.selectSource(nil, replacing: UUID()))
        XCTAssertNotNil(draft.selectSource(capture(type: "image/png"), replacing: UUID()))
        XCTAssertNotNil(draft.selectSource(capture(complete: false), replacing: UUID()))
        XCTAssertEqual(draft.source?.id, original.id)
        XCTAssertEqual(draft.guidedDraft.itemJSON, #"{"id":"custom"}"#)
        XCTAssertEqual(draft.draftJSON, "advanced draft")
        XCTAssertEqual(draft.imageBookmark, "retained opaque reference")
        XCTAssertNil(draft.replacementRevisionID)
    }

    func testSourceChangeInvalidatesReviewAndRequiresExplicitImageChoice() async throws {
        let draft = CapturedMockAuthoringDraft()
        XCTAssertNil(draft.selectSource(capture()))
        draft.clientAddress = "192.0.2.1"
        await draft.prepare(service: CollectionMockAuthoringService())
        XCTAssertNotNil(draft.prepared)
        draft.reviewed = true
        draft.imageBookmark = "retained reference"
        draft.replacementImageSelected = true
        let revision = UUID()
        XCTAssertNil(draft.selectSource(capture(), replacing: revision))
        XCTAssertEqual(draft.replacementRevisionID, revision)
        XCTAssertNil(draft.prepared)
        XCTAssertFalse(draft.reviewed)
        XCTAssertFalse(draft.replacementImageSelected)
        XCTAssertEqual(draft.imageBookmark, "retained reference")
        await draft.prepare(service: CollectionMockAuthoringService())
        XCTAssertNil(draft.prepared)
        XCTAssertNotNil(draft.errorMessage)
    }

    func testPreparationFailurePreservesInputsAndAllowsCorrection() async {
        let draft = CapturedMockAuthoringDraft()
        XCTAssertNil(draft.selectSource(capture()))
        draft.clientAddress = "192.0.2.1"
        draft.guidedDraft.itemJSON = "invalid JSON"
        let service = CollectionMockAuthoringService()
        await draft.prepare(service: service)
        XCTAssertEqual(draft.guidedDraft.itemJSON, "invalid JSON")
        XCTAssertNotNil(draft.errorMessage)
        XCTAssertFalse(draft.busy)
        draft.guidedDraft.itemJSON = #"{"id":"corrected","image":""}"#
        await draft.prepare(service: service)
        XCTAssertNotNil(draft.prepared)
        XCTAssertNil(draft.errorMessage)
    }

    func testFailedSaveKeepsReviewedRevisionAndTypedEdits() async throws {
        let draft = CapturedMockAuthoringDraft()
        XCTAssertNil(draft.selectSource(capture()))
        draft.clientAddress = "192.0.2.1"
        await draft.prepare(service: CollectionMockAuthoringService())
        let prepared = try XCTUnwrap(draft.prepared)
        draft.reviewed = true
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/DraftRecoveryTests/\(UUID().uuidString)")
        let repository = EffectBundleRepository(persistenceURL: root.appendingPathComponent("records.json"),
            packagesRootURL: root.appendingPathComponent("packages"))
        let saved = await draft.save(prepared, repository: repository, service: CollectionMockAuthoringService())
        XCTAssertFalse(saved, "Another service cannot recover a missing prepared revision")
        XCTAssertEqual(draft.prepared?.manifest.id, prepared.manifest.id)
        XCTAssertTrue(draft.reviewed)
        XCTAssertFalse(draft.busy)
        XCTAssertNotNil(draft.errorMessage)
        XCTAssertTrue(repository.records.isEmpty)
    }

    // MARK: - App-owned draft lifetime (182-2)

    func testPresentationOwnedDraftRetainsEditsUntilExplicitDiscard() async {
        let state = AppPresentationState(configuration: MCPSelfValidationAppConfiguration())
        let draft = state.capturedMockAuthoringDraft
        XCTAssertNil(draft.selectSource(capture()))
        draft.name = "Edited fixture"
        draft.guidedDraft.itemJSON = #"{"id":"typed"}"#

        // Reopening Traffic Modifications reads the same owner; nothing window-scoped is involved.
        XCTAssertTrue(state.capturedMockAuthoringDraft === draft)
        XCTAssertEqual(state.capturedMockAuthoringDraft.name, "Edited fixture")

        let discarded = await state.discardCapturedMockAuthoringDraft()
        XCTAssertTrue(discarded)
        let fresh = state.capturedMockAuthoringDraft
        XCTAssertFalse(fresh === draft)
        XCTAssertNil(fresh.source, "Discard releases the draft's copy of the selected capture")
        XCTAssertEqual(fresh.name, CapturedMockAuthoringDraft().name)
    }

    func testDiscardIsRefusedWhileAnOperationIsRunning() async {
        let state = AppPresentationState(configuration: MCPSelfValidationAppConfiguration())
        let draft = state.capturedMockAuthoringDraft
        XCTAssertNil(draft.selectSource(capture()))
        draft.busy = true

        let refused = await state.discardCapturedMockAuthoringDraft()
        XCTAssertFalse(refused)
        XCTAssertTrue(state.capturedMockAuthoringDraft === draft)
        XCTAssertNotNil(draft.source)

        draft.busy = false
        let discarded = await state.discardCapturedMockAuthoringDraft()
        XCTAssertTrue(discarded)
    }

    /// The editor retires the draft right after `save` returns `true`; that must not be refused by
    /// a still-set busy flag, or a saved revision would reappear with Save enabled.
    func testSuccessfulSaveLeavesDraftRetirable() async throws {
        let state = AppPresentationState(configuration: MCPSelfValidationAppConfiguration())
        let draft = state.capturedMockAuthoringDraft
        let service = CollectionMockAuthoringService()
        XCTAssertNil(draft.selectSource(capture()))
        draft.clientAddress = "192.0.2.1"
        await draft.prepare(service: service)
        let prepared = try XCTUnwrap(draft.prepared)
        draft.reviewed = true
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/DraftRecoveryTests/\(UUID().uuidString)")
        let repository = EffectBundleRepository(persistenceURL: root.appendingPathComponent("records.json"),
            packagesRootURL: root.appendingPathComponent("packages"))

        let saved = await draft.save(prepared, repository: repository, service: service)
        XCTAssertTrue(saved)
        XCTAssertEqual(repository.records.count, 1)
        do {
            _ = try await service.inspectCapturedPackage(id: prepared.manifest.id, ownerID: EffectBundleOwner.localUser.ownerID)
            XCTFail("Successful Save releases the preparation while preserving the imported bundle")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionRetired) }
        let discarded = await state.discardCapturedMockAuthoringDraft()
        XCTAssertTrue(discarded)
        XCTAssertNil(state.capturedMockAuthoringDraft.prepared)
        XCTAssertFalse(state.capturedMockAuthoringDraft.reviewed)
    }
}
