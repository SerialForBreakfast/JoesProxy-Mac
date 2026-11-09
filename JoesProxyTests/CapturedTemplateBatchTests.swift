import XCTest
@testable import JoesProxy

final class CapturedTemplateBatchTests: XCTestCase {
    private let source = Data(#"{"total":2,"items":[{"id":"original","image":"old","nested":{"value":null}},{"other":true}]}"#.utf8)
    private let scope = CapturedMockScope(host: "example.test", scheme: .https, port: 443,
        path: "/items", clients: .address("192.0.2.1"))
    private let json = #"{"collectionPointer":"/items","templateIndex":0,"identityPointers":["/id"],"identityPresence":"wherePresent","countPointers":["/total"],"position":"prepend","expansionItems":[{"edits":[{"pointer":"/id","value":"first"}],"images":[{"pointer":"/image","assetID":"image-0"}]},{"edits":[{"pointer":"/id","value":"second"}],"images":[{"pointer":"/image","assetID":"image-1"}]}]}"#

    func testBatchArtworkRetryIsolationAndSchemaCompatibility() async throws {
        let request = CapturedRequest(method: "GET", scheme: .https, host: SyntheticAssetOriginServer.defaultHost,
            port: 443, path: "/fixtures/images/test_pattern.png", headers: [], bodyData: nil, bodySize: nil)
        let png = try XCTUnwrap(SyntheticAssetOriginServer.shared.response(for: request)?.bodyData)
        let images = ["one", "two"].map {
            CapturedMockImageBinding(itemPointer: nil, bytes: png, originalURL: nil,
                deliveryURL: URL(string: "https://images.example.test/\($0).png"), imageReference: "images/\($0).png")
        }
        let draft = try CollectionMockDraftDecoder.decode(Data(json.utf8))
        let service = CollectionMockAuthoringService(maximumRevisions: 1)
        let first = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "batch", name: "Batch",
            source: source, draft: draft, scope: scope, images: images, appVersion: "test", createdAt: Date())
        let retry = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "batch", name: "Batch",
            source: source, draft: draft, scope: scope, images: images, appVersion: "test", createdAt: Date())
        XCTAssertEqual(first.manifest.id, retry.manifest.id)
        XCTAssertEqual(first.assetDataByID, retry.assetDataByID)
        XCTAssertEqual(first.manifest.authoring?.beforeCount, 2)
        XCTAssertEqual(first.manifest.authoring?.afterCount, 4)
        let root = try CollectionMockCompiler.parse(XCTUnwrap(first.assetDataByID["response"]))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "0", "image"], in: root), .string("images/one.png"))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "1", "image"], in: root), .string("images/two.png"))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "1", "nested", "value"], in: root), .null)
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "2", "id"], in: root), .string("original"))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "3"], in: root), .object(["other": .bool(true)]))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["total"], in: root), .number("4"))
        var manifest = try JSONDecoder().decode(EffectBundleManifest.self, from: JSONEncoder().encode(first.manifest))
        try EffectBundleValidator.validateManifest(manifest)
        manifest.schemaVersion = 7
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(manifest))
        do {
            _ = try await service.inspectCapturedPackage(id: first.manifest.id, ownerID: "other")
            XCTFail("Cross-owner inspection must fail")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionNotFound) }
        var changed = draft
        changed.expansionItems?.reverse()
        do {
            _ = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "batch", name: "Batch",
                source: source, draft: changed, scope: scope, images: images, appVersion: "test", createdAt: Date())
            XCTFail("Changed order must conflict")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .idempotencyConflict) }
        XCTAssertThrowsError(try CollectionMockCompiler.prepare(source: source, draft: draft),
            "Live single-item transformations must not silently ignore a batch")
    }

    func testFailureDoesNotConsumeCapacityAndCancellationDoesNotPublish() async throws {
        let service = CollectionMockAuthoringService(maximumRevisions: 1)
        var draft = try CollectionMockDraftDecoder.decode(Data(json.utf8))
        draft.expansionItems = [.init(edits: [.init(pointer: "/id", value: .string("new"))]),
                                .init(edits: [.init(pointer: "/id", value: .string("original"))])]
        do {
            _ = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "batch", name: "Batch",
                source: source, draft: draft, scope: scope, images: [], appVersion: "test", createdAt: Date())
            XCTFail("A late collision must reject the whole batch")
        } catch { XCTAssertEqual(error as? CollectionMockError, .duplicateIdentity) }
        draft.expansionItems = [.init(edits: [.init(pointer: "/id", value: .string("new"))])]
        let input = draft
        let bytes = source
        let target = scope
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "batch", name: "Batch",
                source: bytes, draft: input, scope: target, images: [], appVersion: "test", createdAt: Date())
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled preparation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        let prepared = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "batch", name: "Batch",
            source: source, draft: draft, scope: scope, images: [], appVersion: "test", createdAt: Date())
        XCTAssertEqual(prepared.manifest.authoring?.afterCount, 3)
        var legacy = prepared.manifest
        legacy.schemaVersion = 7
        XCTAssertNoThrow(try EffectBundleValidator.validateManifest(legacy))
    }

    func testDecoderAndBindingsRejectMalformedBatches() throws {
        for text in [json.replacingOccurrences(of: "image-1", with: "invented"),
                     json.replacingOccurrences(of: "\"templateIndex\":0", with: "\"item\":{}"),
                     json.replacingOccurrences(of: "\"edits\":", with: "\"unknown\":"),
                     #"{"collectionPointer":"/items","templateIndex":0,"identityPointers":["/id"],"expansionItems":[]}"#] {
            XCTAssertThrowsError(try CollectionMockDraftDecoder.decode(Data(text.utf8)))
        }
        let draft = try CollectionMockDraftDecoder.decode(Data(json.utf8))
        XCTAssertThrowsError(try CapturedMockPackageCompiler.prepare(id: UUID(), name: "Missing artwork", source: source,
            draft: draft, scope: scope, images: [], appVersion: "test", createdAt: Date()))
    }
}
