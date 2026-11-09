import XCTest
@testable import JoesProxy

final class CapturedMockPackageCompilerTests: XCTestCase {
    func testScopedQueryPreparationStripsOnlyReviewedNamesAndRequiresNewSchema() throws {
        var scopedDraft = draft
        scopedDraft.ignoredQueryNames = ["token", "correlation"]
        let queryScope = CapturedMockScope(host: scope.host, scheme: scope.scheme, port: scope.port,
            path: "/items.json?userId=7&profileId=2&token=secret&correlation=old", clients: scope.clients)
        let package = try CapturedMockPackageCompiler.prepare(id: UUID(), name: "Query scope",
            source: source, draft: scopedDraft, scope: queryScope, images: [], appVersion: "test", createdAt: Date())
        let effect = try XCTUnwrap(package.manifest.responseEffects.first)
        XCTAssertEqual(effect.path, "/items.json?profileId=2&userId=7")
        XCTAssertEqual(effect.ignoredQueryNames, scopedDraft.ignoredQueryNames)
        XCTAssertEqual(effect.matchMode, .ignoreQuery)
        XCTAssertEqual(effect.sourceClientAddress, "192.0.2.10")
        let decoded = try JSONDecoder().decode(EffectBundleManifest.self, from: JSONEncoder().encode(package.manifest))
        XCTAssertEqual(decoded.responseEffects.first?.ignoredQueryNames, scopedDraft.ignoredQueryNames)
        var downgraded = decoded
        downgraded.schemaVersion = 2
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(downgraded))
        let unscoped = CapturedMockScope(host: scope.host, scheme: scope.scheme, port: scope.port,
            path: queryScope.path, clients: .allClients)
        XCTAssertThrowsError(try CapturedMockPackageCompiler.prepare(id: UUID(), name: "Invalid scope",
            source: source, draft: scopedDraft, scope: unscoped, images: [], appVersion: "test", createdAt: Date()))
    }

    func testRelativeMappingChangesRequireNewRevision() async throws {
        let request = CapturedRequest(method: "GET", scheme: .https, host: SyntheticAssetOriginServer.defaultHost,
            port: 443, path: "/fixtures/images/test_pattern.png", headers: [], bodyData: nil, bodySize: nil)
        let png = try XCTUnwrap(SyntheticAssetOriginServer.shared.response(for: request)?.bodyData)
        let service = CollectionMockAuthoringService()
        let binding = CapturedMockImageBinding(itemPointer: "/image", bytes: png, originalURL: nil,
            deliveryURL: URL(string: "https://images.example.test/thumbs/v1.png"), imageReference: "files/v1.png")
        let first = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "relative",
            name: "Synthetic", source: source, draft: draft, scope: scope, images: [binding], appVersion: "test", createdAt: Date())
        let retry = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "relative",
            name: "Synthetic", source: source, draft: draft, scope: scope, images: [binding], appVersion: "test", createdAt: Date())
        XCTAssertEqual(first.manifest.id, retry.manifest.id)
        for changeReference in [true, false] {
            var changed = binding
            if changeReference { changed.imageReference = "files/v2.png" }
            else { changed.deliveryURL = URL(string: "https://images.example.test/thumbs/v2.png") }
            do {
                _ = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "relative",
                    name: "Synthetic", source: source, draft: draft, scope: scope, images: [changed], appVersion: "test", createdAt: Date())
                XCTFail("Changed reference or matcher must not reuse a reviewed revision")
            } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .idempotencyConflict) }
        }
    }

    func testRelativeReferenceHasExplicitScopedDeliveryAndUnchangedSiblings() throws {
        let request = CapturedRequest(method: "GET", scheme: .https, host: SyntheticAssetOriginServer.defaultHost,
            port: 443, path: "/fixtures/images/test_pattern.png", headers: [], bodyData: nil, bodySize: nil)
        let png = try XCTUnwrap(SyntheticAssetOriginServer.shared.response(for: request)?.bodyData)
        var binding = CapturedMockImageBinding(itemPointer: "/image", bytes: png, originalURL: nil,
            deliveryURL: URL(string: "https://images.example.test/thumbs/mock-v1.png?width=360"),
            imageReference: "files/mock-v1.png")
        let package = try prepare(images: [binding])
        let image = try XCTUnwrap(package.images.first)
        XCTAssertEqual(image.imageReference, "files/mock-v1.png")
        XCTAssertEqual(package.assetDataByID[image.assetID], png)
        let body = try XCTUnwrap(package.assetDataByID["response"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["image"] as? String, "old")
        XCTAssertEqual(items[1]["image"] as? String, "files/mock-v1.png")
        let effect = try XCTUnwrap(package.manifest.responseEffects.last)
        XCTAssertEqual(effect.path, "/thumbs/mock-v1.png?width=360")
        XCTAssertEqual(effect.sourceClientAddress, "192.0.2.10")
        XCTAssertTrue(package.reviewAdvisories.contains { $0.code == .relativeImageMappingUnverified })
        for invalid in ["//elsewhere.test/image", "../escape.png", "files/%2e%2e/escape.png", "https://elsewhere.test/a", ""] {
            binding.imageReference = invalid
            XCTAssertThrowsError(try prepare(images: [binding]))
        }
        binding.imageReference = nil
        XCTAssertThrowsError(try prepare(images: [binding]))
    }
    private let source = Data(#"{"items":[{"id":"original","image":"old"}],"total":1}"#.utf8)
    private var draft: CollectionMockDraft {
        CollectionMockDraft(collectionPointer: "/items", item: nil, templateIndex: 0,
            edits: [.init(pointer: "/id", value: .string("synthetic"))],
            identityPointers: ["/id"], countPointers: ["/total"], position: .append)
    }
    private var scope: CapturedMockScope {
        CapturedMockScope(host: "api.example.test", scheme: .https, port: 443,
            path: "/items.json", clients: .address("192.0.2.10"))
    }
    private func prepare(images: [CapturedMockImageBinding] = []) throws -> PreparedCapturedMockPackage {
        try CapturedMockPackageCompiler.prepare(id: UUID(), name: "Synthetic list", source: source,
            draft: draft, scope: scope, images: images, appVersion: "test", createdAt: Date(timeIntervalSince1970: 0))
    }

    func testReviewedIntentMetadataDoesNotExposeFieldValues() throws {
        let package = try prepare()
        let changes = try XCTUnwrap(package.manifest.authoring?.reviewedChanges)
        XCTAssertTrue(changes.contains("Insert reviewed item at /items/1"))
        XCTAssertTrue(changes.contains("Set reviewed field at /items/1/id"))
        XCTAssertTrue(changes.contains("Adjust reviewed count at /total"))
        XCTAssertFalse(changes.joined().contains("synthetic"))
        XCTAssertEqual(package.manifest.authoring?.reviewedChangesTruncated, false)
    }

    func testImageAndJSONUseSameVersionedAsset() throws {
        let request = CapturedRequest(method: "GET", scheme: .https, host: SyntheticAssetOriginServer.defaultHost,
            port: 443, path: "/fixtures/images/test_pattern.png", headers: [], bodyData: nil, bodySize: nil)
        let png = try XCTUnwrap(SyntheticAssetOriginServer.shared.response(for: request)?.bodyData)
        let package = try prepare(images: [.init(itemPointer: "/image", bytes: png, originalURL: nil)])
        let image = try XCTUnwrap(package.images.first)
        XCTAssertEqual(image.contentType, "image/png")
        XCTAssertTrue(image.url.contains(image.sha256))
        XCTAssertTrue(image.url.contains(package.manifest.id.uuidString.lowercased()))
        XCTAssertEqual(package.assetDataByID[image.assetID], png)
        let body = try XCTUnwrap(package.assetDataByID["response"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["image"] as? String, "old")
        XCTAssertEqual(items[1]["image"] as? String, image.url)
        XCTAssertTrue(package.manifest.responseEffects.allSatisfy {
            $0.statusCode == 200 && $0.matchMode == .exactPath && $0.sourceClientAddress == "192.0.2.10"
        })
        let authoredRequest = CapturedRequest(method: "GET", scheme: .https, host: SyntheticAssetOriginServer.defaultHost,
            port: 443, path: try XCTUnwrap(URL(string: image.url)?.path), headers: [], bodyData: nil, bodySize: nil)
        XCTAssertNil(SyntheticAssetOriginServer.shared.response(for: authoredRequest), "Built-in fixture must not shadow authored bytes")
        XCTAssertThrowsError(try prepare(images: [.init(itemPointer: "/image", bytes: png,
            originalURL: URL(string: "https://assets.joesproxy.invalid/fixtures/images/test_pattern.png"))])) {
            XCTAssertEqual($0 as? CapturedMockPackageError, .invalidScope)
        }
    }

    func testInvalidImageDoesNotProducePackage() {
        XCTAssertThrowsError(try prepare(images: [.init(itemPointer: "/image", bytes: Data("not an image".utf8), originalURL: nil)])) {
            XCTAssertEqual($0 as? CapturedMockPackageError, .invalidImage)
        }
    }

    func testVersionOneStillDecodesWithoutAuthoringMetadata() throws {
        var manifest = try prepare().manifest
        manifest.schemaVersion = 1
        manifest.authoring = nil
        let decoded = try JSONDecoder().decode(EffectBundleManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertNil(decoded.authoring)
        XCTAssertNoThrow(try EffectBundleValidator.validateManifest(decoded))
        manifest.schemaVersion = EffectBundleSchema.currentVersion + 1
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(manifest))
    }

    func testInMemoryPackageRoundTripAndDigestFailure() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/MockPackageTests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try prepare()
        let engine = EffectBundlePackageEngine()
        let destination = root.appendingPathComponent("fixture.jproxy-effects")
        try engine.writePackage(manifest: package.manifest, assetDataByID: package.assetDataByID, to: destination)
        let loaded = try engine.inspectPackage(at: destination)
        XCTAssertEqual(loaded.manifest, package.manifest)
        var changed = package.assetDataByID
        changed["response"] = Data("wrong bytes".utf8)
        XCTAssertThrowsError(try engine.writePackage(manifest: package.manifest, assetDataByID: changed,
            to: root.appendingPathComponent("invalid.jproxy-effects")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("invalid.jproxy-effects").path))
    }

    func testPackageRetryPreservesRevisionAndRejectsScopeChange() async throws {
        let service = CollectionMockAuthoringService()
        let first = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "key", name: "Example",
            source: source, draft: draft, scope: scope, images: [], appVersion: "test", createdAt: Date(timeIntervalSince1970: 0))
        let retry = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "key", name: "Example",
            source: source, draft: draft, scope: scope, images: [], appVersion: "test", createdAt: Date())
        XCTAssertEqual(first.manifest, retry.manifest)
        let broadScope = CapturedMockScope(host: scope.host, scheme: scope.scheme, port: scope.port,
            path: scope.path, clients: .allClients)
        do {
            _ = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "key", name: "Example",
                source: source, draft: draft, scope: broadScope, images: [], appVersion: "test", createdAt: Date())
            XCTFail("Scope change must require a new reviewed revision")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .idempotencyConflict) }
        do {
            _ = try await service.inspectCapturedPackage(id: first.manifest.id, ownerID: "other")
            XCTFail("Revision must remain owner-scoped")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionNotFound) }
    }
}
