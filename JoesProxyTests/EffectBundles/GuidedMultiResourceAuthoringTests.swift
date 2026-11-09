import XCTest
@testable import JoesProxy

@MainActor
final class GuidedMultiResourceAuthoringTests: XCTestCase {
    private func capture(_ body: String, path: String = "/items", truncated: Bool = false) -> SessionRecord {
        SessionRecord(request: .init(method: "GET", scheme: .https, host: "api.example.test", port: 443,
            path: path, headers: [], bodyData: nil, bodySize: nil),
            response: .init(statusCode: 200, headers: [.init(name: "Content-Type", value: "application/json")],
                bodyData: Data(body.utf8), bodySize: body.utf8.count, bodyTruncated: truncated),
            timing: .init(startedAt: Date()))
    }

    private func configuredDraft() throws -> CapturedMockAuthoringDraft {
        let draft = CapturedMockAuthoringDraft()
        XCTAssertNil(draft.selectSource(capture(#"{"items":[{"id":1,"title":"Before","enabled":true}],"total":1}"#)))
        draft.clientAddress = "192.0.2.10"
        draft.guidedDraft.useTemplate = true
        draft.guidedDraft.edits = [.init(pointer: "/id", valueJSON: "2"),
                                  .init(pointer: "/title", valueJSON: #""After""#)]
        return draft
    }

    func testPreviewUsesCompilerAndReportsActualInsertedPointer() async throws {
        let draft = try configuredDraft()
        await draft.previewItem()
        let preview = try XCTUnwrap(draft.itemPreview)
        XCTAssertEqual(preview.insertedItemPointer, "/items/1")
        XCTAssertTrue(preview.before.contains("Before"))
        XCTAssertTrue(preview.after.contains("After"))
        XCTAssertTrue(preview.after.contains(#""enabled":true"#))
        XCTAssertNil(draft.prepared)
        draft.guidedDraft.prepend = true
        XCTAssertNil(draft.itemPreview)
        await draft.previewItem()
        XCTAssertEqual(draft.itemPreview?.insertedItemPointer, "/items/0")
    }

    func testInvalidIdentityPreviewRetainsInputWithoutPackage() async throws {
        let draft = try configuredDraft()
        draft.guidedDraft.edits = []
        await draft.previewItem()
        XCTAssertNil(draft.itemPreview)
        XCTAssertNotNil(draft.errorMessage)
        XCTAssertTrue(draft.guidedDraft.useTemplate)
        XCTAssertNil(draft.prepared)
    }

    func testRelatedFieldsAndIdentityPrepareOneInactivePackage() async throws {
        let draft = try configuredDraft()
        let detail = capture(#"{"id":1,"title":"Detail","enabled":true}"#, path: "/detail/1?region=test")
        draft.addRelatedSource(detail)
        draft.relatedDrafts[0].targetPath = "/detail/2?region=test"
        draft.relatedDrafts[0].edits = [.init(pointer: "/id", valueJSON: "2")]
        draft.relatedDrafts[0].identityLinks[0].primaryPointer = "/items/1/id"
        await draft.prepare(service: CollectionMockAuthoringService())
        let package = try XCTUnwrap(draft.prepared, draft.errorMessage ?? "No package")
        XCTAssertEqual(package.manifest.responseEffects.count, 2)
        XCTAssertEqual(package.manifest.responseEffects.last?.path, "/detail/2?region=test")
        let related = try CollectionMockCompiler.parse(XCTUnwrap(package.assetDataByID["related-0"]))
        XCTAssertEqual(related, .object(["id": .number("2"), "title": .string("Detail"), "enabled": .bool(true)]))
        XCTAssertEqual(package.manifest.authoring?.relatedResponses?.first?.sourceSessionID, detail.id)
        XCTAssertNil(package.manifest.authoring?.relatedResponses?.first?.targetSessionID)
        XCTAssertFalse(draft.reviewed)
    }

    func testRelatedMismatchDoesNotPublishPartialPackageOrLoseDraft() async throws {
        let draft = try configuredDraft()
        draft.addRelatedSource(capture(#"{"id":1}"#, path: "/detail/1"))
        draft.relatedDrafts[0].identityLinks[0].primaryPointer = "/items/1/id"
        let original = draft.relatedDrafts
        await draft.prepare(service: CollectionMockAuthoringService())
        XCTAssertNil(draft.prepared)
        XCTAssertEqual(draft.relatedDrafts, original)
        XCTAssertTrue(draft.errorMessage?.contains("relatedResponses[0]") == true)
        draft.relatedDrafts[0].edits = [.init(pointer: "/id", valueJSON: "2")]
        await draft.prepare(service: CollectionMockAuthoringService())
        XCTAssertNotNil(draft.prepared)
    }

    func testUnavailableRelatedBodyAndMissingImageFailBeforePackage() async throws {
        let draft = try configuredDraft()
        draft.addRelatedSource(capture(#"{"id":2,"art":"old"}"#, path: "/detail/2", truncated: true))
        draft.relatedDrafts[0].identityLinks[0].primaryPointer = "/items/1/id"
        await draft.prepare(service: CollectionMockAuthoringService())
        XCTAssertNil(draft.prepared)
        draft.relatedDrafts[0].imagePointer = "/art"
        XCTAssertThrowsError(try draft.relatedDrafts[0].input(clientAddress: draft.clientAddress, hasImage: false))
    }

    func testRelatedSelectionIsExplicitBoundedAndResetOnPrimaryChange() throws {
        let draft = try configuredDraft()
        let primary = try XCTUnwrap(draft.source)
        draft.addRelatedSource(primary)
        XCTAssertTrue(draft.relatedDrafts.isEmpty)
        for index in 0..<10 { draft.addRelatedSource(capture(#"{"id":2}"#, path: "/detail/\(index)")) }
        XCTAssertEqual(draft.relatedDrafts.count, 8)
        draft.addRelatedSource(draft.relatedDrafts[0].source)
        XCTAssertEqual(draft.relatedDrafts.count, 8)
        XCTAssertNotNil(draft.selectSource(nil))
        XCTAssertEqual(draft.relatedDrafts.count, 8)
        XCTAssertNil(draft.selectSource(capture(#"{"items":[]}"#)))
        XCTAssertTrue(draft.relatedDrafts.isEmpty)
    }

    func testTypedRelatedInputReusesDecoderWithoutChangingSiblingTypes() throws {
        var draft = GuidedRelatedMockDraft(source: capture(#"{"id":2,"enabled":false,"art":"old"}"#, path: "/detail/2"))
        draft.identityLinks[0].primaryPointer = "/items/1/id"
        draft.edits = [.init(pointer: "/enabled", valueJSON: "true")]
        draft.imagePointer = "/art"
        let decoded = try CapturedRelatedResponseDecoder.decode(draft.input(clientAddress: "192.0.2.10", hasImage: true))
        XCTAssertEqual(decoded.edits, [.init(pointer: "/enabled", value: .bool(true))])
        XCTAssertEqual(decoded.images, [.init(pointer: "/art", assetID: "image-0")])
        XCTAssertEqual(decoded.targetSessionID, draft.source.id)
    }

    func testPreviewIsBoundedAndRejectsIncompleteBodies() async throws {
        let draft = try configuredDraft()
        let text = String(repeating: "a", count: 8_000)
        let source = capture("{\"items\":[{\"id\":1,\"title\":\"\(text)\",\"enabled\":true}],\"total\":1}")
        XCTAssertNil(draft.selectSource(source))
        await draft.previewItem()
        let preview = try XCTUnwrap(draft.itemPreview)
        XCTAssertTrue(preview.truncated)
        XCTAssertLessThanOrEqual(preview.before.utf8.count, 4_096)
        XCTAssertLessThanOrEqual(preview.after.utf8.count, 4_096)
        let incomplete = try XCTUnwrap(capture("{}", truncated: true).response)
        XCTAssertThrowsError(try CapturedMockItemPreview.inspect(response: incomplete, draft: draft.guidedDraft))
    }

    func testOverlappingRelatedTargetRejectsWholePreparation() async throws {
        let draft = try configuredDraft()
        draft.addRelatedSource(capture(#"{"id":2}"#, path: "/detail/2"))
        draft.relatedDrafts[0].targetPath = "/items"
        draft.relatedDrafts[0].identityLinks[0].primaryPointer = "/items/1/id"
        await draft.prepare(service: CollectionMockAuthoringService())
        XCTAssertNil(draft.prepared)
        XCTAssertNotNil(draft.errorMessage)
        XCTAssertEqual(draft.relatedDrafts.count, 1)
    }

    func testBusyAuthoringRejectsCompetingOperations() async throws {
        let draft = try configuredDraft()
        draft.busy = true
        draft.addRelatedSource(capture(#"{"id":2}"#, path: "/detail/2"))
        await draft.previewItem()
        await draft.prepare(service: CollectionMockAuthoringService())
        XCTAssertTrue(draft.relatedDrafts.isEmpty)
        XCTAssertNil(draft.itemPreview)
        XCTAssertNil(draft.prepared)
        XCTAssertTrue(draft.busy)
    }

    func testRelatedInputRejectsOversizedValuesAndInvalidIdentityPaths() throws {
        var draft = GuidedRelatedMockDraft(source: capture(#"{"id":2}"#, path: "/detail/2"))
        draft.identityLinks[0].primaryPointer = "/items/1/id"
        draft.edits = [.init(pointer: "/id", valueJSON: String(repeating: "1", count: 65_537))]
        XCTAssertThrowsError(try draft.input(clientAddress: "192.0.2.10", hasImage: false))
        draft.edits = []
        draft.identityLinks[0].primaryPointer = "not-a-pointer"
        XCTAssertThrowsError(try draft.input(clientAddress: "192.0.2.10", hasImage: false))
    }

    func testCancelledPreviewDoesNotPublishOrLoseDraft() async throws {
        let draft = try configuredDraft()
        let original = draft.guidedDraft
        let operation = Task { await draft.previewItem() }
        operation.cancel()
        await operation.value
        XCTAssertNil(draft.itemPreview)
        XCTAssertNil(draft.errorMessage)
        XCTAssertFalse(draft.busy)
        XCTAssertEqual(draft.guidedDraft, original)
    }

    func testCancelledPreparationDoesNotPublishPackage() async throws {
        let draft = try configuredDraft()
        let operation = Task { await draft.prepare(service: CollectionMockAuthoringService()) }
        operation.cancel()
        await operation.value
        XCTAssertNil(draft.prepared)
        XCTAssertNil(draft.errorMessage)
        XCTAssertFalse(draft.busy)
        XCTAssertEqual(draft.guidedDraft.edits.count, 2)
    }
}
