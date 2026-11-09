import XCTest
@testable import JoesProxy

@MainActor
final class GuidedMockArtworkTests: XCTestCase {
    func testArtworkAcceptanceFixtureSharesImageAndRecoversAfterExplicitUnbinding() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent("build/HostTestResults/artwork-policy-\(UUID().uuidString)-artifacts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = CapturedMockAuthoringDraft()
        GuidedMockAuthoringUITestFixture.configure(draft,
            arguments: ["--ui-test-batch-authoring", "--ui-test-authoring-artwork"],
            environment: ["JOESPROXY_UI_ARTIFACT_DIRECTORY": root.path])
        XCTAssertNil(draft.errorMessage)
        let service = CollectionMockAuthoringService(maximumRevisions: 1)
        await draft.prepare(service: service)
        let package = try XCTUnwrap(draft.prepared, draft.errorMessage ?? "Missing fixture")
        let image = try XCTUnwrap(package.images.first)
        XCTAssertEqual(package.images.count, 1)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        let responseID = try XCTUnwrap(package.manifest.authoring?.responseAssetID)
        let bytes = try XCTUnwrap(package.assetDataByID[responseID])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[1]["image"] as? String, image.url)
        XCTAssertEqual(items[0]["image"] as? String, "original")
        XCTAssertEqual(items[2]["image"] as? String, "original")
        let preview = try XCTUnwrap(draft.relatedPreviews.first)
        let related = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preview.after.utf8)) as? [String: Any])
        XCTAssertEqual(related["image"] as? String, image.url)
        XCTAssertEqual(related["title"] as? String, "After")
        let edited = await draft.editPreparedRevision()
        XCTAssertTrue(edited)
        draft.additionalArtwork.removeAll()
        await draft.prepare(service: service)
        XCTAssertNil(draft.prepared)
        XCTAssertTrue(draft.errorMessage?.contains("artworkUnavailable") == true)
        XCTAssertEqual(draft.relatedDrafts[0].artworkBindings.count, 1)
        draft.relatedDrafts[0].artworkBindings.removeAll()
        draft.guidedDraft.expansionItemsJSON = #"[{"edits":[{"pointer":"/id","value":2}]},{"edits":[{"pointer":"/id","value":3}]}]"#
        await draft.prepare(service: service)
        let corrected = try XCTUnwrap(draft.prepared, draft.errorMessage ?? "Missing correction")
        XCTAssertTrue(corrected.images.isEmpty)
        XCTAssertFalse(draft.reviewed)
        XCTAssertNotEqual(corrected.manifest.id, package.manifest.id)
    }
    func testUIFixturePreparesTwoResourcesWithoutReviewOrActivation() async throws {
        let draft = CapturedMockAuthoringDraft()
        GuidedMockAuthoringUITestFixture.configure(draft)
        await draft.prepare(service: CollectionMockAuthoringService())
        let package = try XCTUnwrap(draft.prepared, draft.errorMessage ?? "Missing prepared fixture")
        XCTAssertEqual(package.manifest.responseEffects.count, 2)
        XCTAssertEqual(draft.relatedPreviews.count, 1)
        XCTAssertFalse(draft.reviewed)
        XCTAssertTrue(draft.relatedPreviews[0].after.contains("After"))
    }
    private func source(_ title: String = "Before") -> SessionRecord {
        let bytes = Data("{\"id\":2,\"title\":\"\(title)\",\"logo\":\"old\",\"hero\":\"old\",\"enabled\":true}".utf8)
        return .init(request: .init(method: "GET", scheme: .https, host: "api.example.test", port: 443,
            path: "/detail/2", headers: [], bodyData: nil, bodySize: nil),
            response: .init(statusCode: 200, headers: [], bodyData: bytes, bodySize: bytes.count),
            timing: .init(startedAt: Date()))
    }

    func testArtworkIdentitySurvivesCompilerIndexChanges() throws {
        let logo = GuidedMockArtwork(name: "Logo", bookmark: "opaque-logo")
        let hero = GuidedMockArtwork(name: "Hero", bookmark: "opaque-hero")
        let primary = CapturedMockImageFile(itemPointer: "/image", bookmarkRef: "opaque-primary", originalURL: nil)
        let first = try GuidedMockArtworkInputs(primary: primary, additional: [logo, hero])
        let second = try GuidedMockArtworkInputs(primary: nil, additional: [hero])
        XCTAssertEqual(first.assetIDs[hero.id], "image-2")
        XCTAssertEqual(second.assetIDs[hero.id], "image-0")
        XCTAssertNil(second.assetIDs[logo.id])
        var related = GuidedRelatedMockDraft(source: source())
        related.identityLinks[0].primaryPointer = "/items/0/id"
        related.artworkBindings = [.init(artworkID: hero.id, pointer: "/hero")]
        let decoded = try CapturedRelatedResponseDecoder.decode(related.input(clientAddress: "192.0.2.1",
            hasImage: false, artworkAssetIDs: second.assetIDs))
        XCTAssertEqual(decoded.images.first?.assetID, "image-0")
        related.artworkBindings.append(.init(artworkID: logo.id, pointer: "/logo"))
        XCTAssertThrowsError(try related.input(clientAddress: "192.0.2.1", hasImage: false,
            artworkAssetIDs: second.assetIDs)) { error in
            XCTAssertEqual((error as? CapturedMockPreparationFailure)?.reason, "artworkUnavailable")
        }
    }

    func testArtworkQuotaAndDuplicateIdentityFailBeforeFileAccess() {
        let image = GuidedMockArtwork(name: "Image", bookmark: "opaque")
        XCTAssertThrowsError(try GuidedMockArtworkInputs(primary: nil, additional: [image, image]))
        XCTAssertThrowsError(try GuidedMockArtworkInputs(primary: nil,
            additional: (0..<17).map { .init(name: "Image \($0)", bookmark: "opaque") }))
    }

    func testMultipleBindingsCompileFinalPreviewWithoutChangingSiblings() async throws {
        let logo = GuidedMockArtwork(name: "Logo", bookmark: "opaque")
        let hero = GuidedMockArtwork(name: "Hero", bookmark: "opaque")
        let inputs = try GuidedMockArtworkInputs(primary: nil, additional: [logo, hero])
        var related = GuidedRelatedMockDraft(source: source())
        related.identityLinks[0].primaryPointer = "/items/0/id"
        related.edits = [.init(pointer: "/title", valueJSON: #""After""#)]
        related.artworkBindings = [.init(artworkID: logo.id, pointer: "/logo"), .init(artworkID: hero.id, pointer: "/hero")]
        let input = try related.input(clientAddress: "192.0.2.1", hasImage: false, artworkAssetIDs: inputs.assetIDs)
        let request = CapturedRequest(method: "GET", scheme: .https, host: SyntheticAssetOriginServer.defaultHost,
            port: 443, path: "/fixtures/images/test_pattern.png", headers: [], bodyData: nil, bodySize: nil)
        let png = try XCTUnwrap(SyntheticAssetOriginServer.shared.response(for: request)?.bodyData)
        let package = try await CollectionMockAuthoringService().prepareCapturedPackage(ownerID: "test", idempotencyKey: "art",
            name: "Synthetic", source: Data(#"{"items":[]}"#.utf8),
            draft: .init(collectionPointer: "/items", item: .object(["id": .number("2")]), templateIndex: nil,
                edits: [], identityPointers: ["/id"], countPointers: [], position: .prepend),
            scope: .init(host: "api.example.test", scheme: .https, port: 443, path: "/items", clients: .address("192.0.2.1")),
            images: [
                .init(itemPointer: nil, bytes: png, originalURL: nil,
                      deliveryURL: URL(string: "https://images.example.test/logo.png"), imageReference: "files/logo.png"),
                .init(itemPointer: nil, bytes: png, originalURL: nil,
                      deliveryURL: URL(string: "https://images.example.test/hero.png"), imageReference: "files/hero.png")
            ], appVersion: "test", createdAt: Date(), relatedResponses: [try CapturedRelatedResponseDecoder.decode(input)])
        let preview = try XCTUnwrap(CapturedRelatedMockPreview.make(inputs: [input], package: package).first)
        XCTAssertTrue(preview.before.contains("Before"))
        XCTAssertTrue(preview.after.contains("After"))
        XCTAssertTrue(preview.after.contains("logo.png"))
        XCTAssertTrue(preview.after.contains("hero.png"))
        XCTAssertTrue(preview.after.contains(#""enabled":true"#))
        XCTAssertFalse(preview.truncated)
        XCTAssertEqual(package.assetDataByID["image-0"], png)
        XCTAssertEqual(package.assetDataByID["image-1"], png)
        let large = CapturedRelatedResponseInput(sessionID: input.sessionID, response: try XCTUnwrap(source(String(repeating: "x", count: 8_000)).response),
            scope: input.scope, editsJSON: input.editsJSON, targetSessionID: input.targetSessionID)
        let bounded = try XCTUnwrap(CapturedRelatedMockPreview.make(inputs: [large], package: package).first)
        XCTAssertTrue(bounded.truncated)
        XCTAssertEqual(bounded.before.utf8.count, 4096)
    }
}
