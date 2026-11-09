import AppKit
import ImageIO
import XCTest
@testable import JoesProxy

@MainActor
final class MockIconArtworkTests: XCTestCase {
    func testSealFallbackPreservesOwnedOriginalAndRejectsInvalidPNG() throws {
        let seal = try MockIconRenderer.seal()
        let original = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("assets/JoeSealOfApproval.PNG")
        XCTAssertEqual(seal.png, try Data(contentsOf: original))
        XCTAssertEqual(try MockIconRenderer.render(symbol: "unavailable-symbol").png, seal.png)
        XCTAssertEqual(try MockIconRenderer.render(symbol: "book", ink: .white, opaque: true).png, seal.png)
        XCTAssertThrowsError(try MockIconRenderer.render(symbol: "book", pixels: 8192))
        XCTAssertThrowsError(try CapturedMockImageFile(itemPointer: nil, bookmarkRef: "", originalURL: nil,
            generatedPNG: Data("not a PNG".utf8)).read())
        XCTAssertThrowsError(try CapturedMockImageFile(itemPointer: nil, bookmarkRef: "ambiguous", originalURL: nil,
            generatedPNG: seal.png).read())
    }

    func testCatalogRasterizesExactDimensionsAndAlpha() throws {
        XCTAssertEqual(MockIconCatalog.entries.count, 5844)
        XCTAssertEqual(Set(MockIconCatalog.entries.map(\.id)).count, 5844)
        for entry in MockIconCatalog.entries {
            XCTAssertFalse(entry.id.hasPrefix("brand-"))
            XCTAssertNotEqual(entry.category, "Brand")
            let result = try MockIconRenderer.render(symbol: entry.id, pixels: 128)
            guard !result.usedFallback else { XCTFail("Cannot render \(entry.id)"); return }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: result.png))
            XCTAssertEqual(bitmap.pixelsWide, 128)
            XCTAssertEqual(bitmap.pixelsHigh, 128)
            XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
            let pixels = try XCTUnwrap(bitmap.bitmapData)
            XCTAssertEqual(bitmap.samplesPerPixel, 4)
            XCTAssertTrue(stride(from: 3, to: bitmap.bytesPerRow * bitmap.pixelsHigh, by: 4)
                .contains { pixels[$0] > 0 }, "Empty rendering: \(entry.id)")
            XCTAssertNoThrow(try CapturedMockImageFile(itemPointer: nil, bookmarkRef: "", originalURL: nil,
                generatedPNG: result.png).read())
        }
        let opaque = try MockIconRenderer.render(symbol: "book", pixels: 64, ink: .blue, opaque: true)
        XCTAssertEqual(NSBitmapImageRep(data: opaque.png)?.colorAt(x: 0, y: 0)?.alphaComponent, 1)
        XCTAssertTrue(MockIconCatalog.matching("unmatched nonsense").isEmpty)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(opaque.png as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let pngProperties = try XCTUnwrap(properties[kCGImagePropertyPNGDictionary as String] as? [String: Any])
        let notice = try XCTUnwrap(pngProperties[kCGImagePropertyPNGDescription as String] as? String)
        XCTAssertTrue(notice.contains("MIT License"))
        XCTAssertTrue(notice.contains(MockIconCatalog.license))
    }

    func testCatalogRetrievalIsBoundedAndUsesOnlySelectedFields() throws {
        let projection = try MockIconSuggestionInput.project(
            #"{"category":"mountain hiking","ignored":"car camera money"}"#, fields: ["category"])
        let candidates = MockIconCatalog.candidates(for: projection)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertLessThanOrEqual(candidates.count, 32)
        XCTAssertTrue(candidates.contains { $0.id == "mountain" })
        XCTAssertEqual(candidates.map(\.id), MockIconCatalog.candidates(for: projection).map(\.id))
        XCTAssertTrue(MockIconCatalog.candidates(for: "zxqv").isEmpty)
        XCTAssertEqual(candidates.map(\.id), MockIconCatalog.candidates(for: "mountain hiking").map(\.id))
        XCTAssertTrue(MockIconCatalog.matching("hiking").contains { $0.id == "mountain" })
    }

    func testReplacementPreservesIdentityBindingsAndRejectsInvalidBytes() throws {
        let draft = CapturedMockAuthoringDraft()
        GuidedMockAuthoringUITestFixture.configure(draft, arguments: [], environment: [:])
        let original = try MockIconRenderer.render(symbol: "book")
        XCTAssertTrue(draft.addGeneratedArtwork(original))
        XCTAssertTrue(draft.addGeneratedArtwork(original))
        let id = draft.additionalArtwork[0].id
        draft.additionalArtwork[0].primaryPointer = "/image"
        draft.relatedDrafts[0].artworkBindings = [.init(artworkID: id, pointer: "/image")]
        draft.guidedDraft.expansionItemsJSON = #"[{"images":[{"pointer":"/image","assetID":"image-0"}]}]"#
        let before = draft.additionalArtwork
        let bindings = draft.relatedDrafts[0].artworkBindings
        let json = draft.guidedDraft.expansionItemsJSON
        XCTAssertFalse(draft.replaceArtwork(id: id, name: "Invalid", png: Data("invalid".utf8)))
        XCTAssertEqual(draft.additionalArtwork, before)
        let seal = try MockIconRenderer.seal()
        draft.reviewed = true
        XCTAssertTrue(draft.replaceArtwork(id: id, name: seal.name, png: seal.png))
        XCTAssertEqual(draft.additionalArtwork.map(\.id), before.map(\.id))
        XCTAssertEqual(draft.additionalArtwork[0].primaryPointer, "/image")
        XCTAssertEqual(draft.additionalArtwork[0].generatedPNG, seal.png)
        XCTAssertEqual(draft.additionalArtwork[1], before[1])
        XCTAssertEqual(draft.relatedDrafts[0].artworkBindings.map(\.artworkID), bindings.map(\.artworkID))
        XCTAssertEqual(draft.relatedDrafts[0].artworkBindings.map(\.pointer), bindings.map(\.pointer))
        XCTAssertEqual(draft.guidedDraft.expansionItemsJSON, json)
        XCTAssertFalse(draft.reviewed)
        let usage = draft.artworkUsageDescription(id: id)
        XCTAssertTrue(usage.contains("image-0"))
        XCTAssertTrue(usage.contains("/detail/2"))
        XCTAssertTrue(usage.contains("Batch items: 1"))
        draft.busy = true
        XCTAssertFalse(draft.replaceArtwork(id: id, name: original.name, png: original.png))
        XCTAssertEqual(draft.additionalArtwork[0].generatedPNG, seal.png)
    }

    func testPreparedArtworkIsFrozenAndSavedInactiveAfterDraftRetirement() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/MockIconPersistence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppPresentationState(configuration: MCPSelfValidationAppConfiguration())
        let draft = state.capturedMockAuthoringDraft
        GuidedMockAuthoringUITestFixture.configure(draft)
        let icon = try MockIconRenderer.render(symbol: "mountain")
        XCTAssertTrue(draft.addGeneratedArtwork(icon))
        let identity = try XCTUnwrap(draft.additionalArtwork.first?.id)
        draft.additionalArtwork[0].primaryPointer = "/image"
        draft.advanced = true
        draft.relatedDrafts = []
        draft.draftJSON = #"{"collectionPointer":"/items","item":{"id":2,"title":"After","image":"placeholder"},"identityPointers":["/id"],"position":"append"}"#
        let service = CollectionMockAuthoringService()
        await draft.prepare(service: service)
        let prepared = try XCTUnwrap(draft.prepared, draft.errorMessage ?? "No preparation")
        XCTAssertFalse(draft.addGeneratedArtwork(try MockIconRenderer.seal()))
        XCTAssertFalse(draft.replaceArtwork(id: identity, name: "Blocked", png: try MockIconRenderer.seal().png))
        XCTAssertEqual(draft.additionalArtwork.first?.id, identity)
        XCTAssertTrue(prepared.assetDataByID.values.contains(icon.png))
        draft.additionalArtwork.removeAll()
        XCTAssertTrue(prepared.assetDataByID.values.contains(icon.png), "Prepared bytes must not reference mutable draft artwork")
        let repository = EffectBundleRepository(persistenceURL: root.appendingPathComponent("index.json"),
            packagesRootURL: root.appendingPathComponent("packages"))
        draft.reviewed = true
        let saved = await draft.save(prepared, repository: repository, service: service)
        XCTAssertTrue(saved)
        let discarded = await state.discardCapturedMockAuthoringDraft()
        XCTAssertTrue(discarded)
        let reopened = EffectBundleRepository(persistenceURL: root.appendingPathComponent("index.json"),
            packagesRootURL: root.appendingPathComponent("packages"))
        let record = try XCTUnwrap(reopened.record(id: prepared.manifest.id))
        XCTAssertEqual(record.state, .inactive)
        XCTAssertFalse(record.isServing)
        let retained = try reopened.manifestAndPackageURL(id: record.id)
        for asset in retained.manifest.assets {
            XCTAssertEqual(try Data(contentsOf: retained.packageURL.appendingPathComponent(asset.packageRelativePath)),
                           prepared.assetDataByID[asset.id])
        }
    }

    func testGeneratedArtworkRemovalAndQuota() throws {
        let draft = CapturedMockAuthoringDraft()
        let image = try MockIconRenderer.render(symbol: "book", pixels: 64)
        for _ in 0..<16 { XCTAssertTrue(draft.addGeneratedArtwork(image)) }
        XCTAssertFalse(draft.addGeneratedArtwork(image))
        let first = draft.additionalArtwork[0].id
        draft.additionalArtwork.removeFirst()
        XCTAssertTrue(draft.addGeneratedArtwork(image))
        XCTAssertFalse(draft.additionalArtwork.contains { $0.id == first })
        draft.busy = true
        XCTAssertFalse(draft.addGeneratedArtwork(image))
    }

    func testReplacedArtworkSavesNewBytesWithoutChangingOldPackage() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/MockIconReplacement-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = CapturedMockAuthoringDraft()
        GuidedMockAuthoringUITestFixture.configure(draft, arguments: [], environment: [:])
        draft.advanced = true
        draft.relatedDrafts = []
        draft.draftJSON = #"{"collectionPointer":"/items","item":{"id":2,"image":""},"identityPointers":["/id"],"position":"append"}"#
        let old = try MockIconRenderer.render(symbol: "book")
        let replacement = try MockIconRenderer.seal()
        XCTAssertTrue(draft.addGeneratedArtwork(old))
        let slot = draft.additionalArtwork[0].id
        draft.additionalArtwork[0].primaryPointer = "/image"
        let service = CollectionMockAuthoringService()
        let repository = EffectBundleRepository(persistenceURL: root.appendingPathComponent("index.json"),
            packagesRootURL: root.appendingPathComponent("packages"))
        await draft.prepare(service: service)
        let first = try XCTUnwrap(draft.prepared, draft.errorMessage ?? "No preparation")
        draft.reviewed = true
        let savedFirst = await draft.save(first, repository: repository, service: service)
        XCTAssertTrue(savedFirst)
        XCTAssertTrue(draft.replaceArtwork(id: slot, name: replacement.name, png: replacement.png))
        await draft.prepare(service: service)
        let second = try XCTUnwrap(draft.prepared, draft.errorMessage ?? "No replacement preparation")
        XCTAssertNotEqual(first.manifest.id, second.manifest.id)
        let unreviewed = await draft.save(second, repository: repository, service: service)
        XCTAssertFalse(unreviewed)
        draft.reviewed = true
        let savedSecond = await draft.save(second, repository: repository, service: service)
        XCTAssertTrue(savedSecond)
        let reopened = EffectBundleRepository(persistenceURL: root.appendingPathComponent("index.json"),
            packagesRootURL: root.appendingPathComponent("packages"))
        for (package, bytes) in [(first, old.png), (second, replacement.png)] {
            let record = try XCTUnwrap(reopened.record(id: package.manifest.id))
            XCTAssertEqual(record.state, .inactive)
            let retained = try reopened.manifestAndPackageURL(id: record.id)
            let asset = try XCTUnwrap(retained.manifest.assets.first { $0.id == "image-0" })
            XCTAssertEqual(try Data(contentsOf: retained.packageURL.appendingPathComponent(asset.packageRelativePath)), bytes)
        }
    }
}
