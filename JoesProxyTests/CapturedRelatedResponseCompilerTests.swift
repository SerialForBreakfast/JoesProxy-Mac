import XCTest
@testable import JoesProxy

final class CapturedRelatedResponseCompilerTests: XCTestCase {
    func testRelatedCompilationIdentifiesIdentityLinkAndKeepsPackageUnchanged() throws {
        let package = try CapturedMockPackageCompiler.prepare(id: UUID(), name: "Synthetic",
            source: source, draft: draft, scope: scope("/items"), images: [], appVersion: "test", createdAt: Date())
        let wrong = CapturedRelatedResponse(source: Data(#"{"id":"synthetic-secret"}"#.utf8),
            scope: scope("/different"), edits: [], images: [],
            identityLinks: [.init(pointer: "/id", primaryPointer: "/items/0/id")])
        XCTAssertThrowsError(try CapturedRelatedResponseCompiler.append([related(), wrong], to: package)) { error in
            let failure = error as? CapturedMockPreparationFailure
            XCTAssertEqual(failure?.field, "relatedResponses[1].identityLinks[0]")
            XCTAssertEqual(failure?.reason, "missingIdentity")
            XCTAssertFalse(failure?.message.contains("synthetic-secret") ?? true)
        }
        XCTAssertEqual(package.manifest.responseEffects.count, 1)
        XCTAssertNil(package.assetDataByID["related-0"])
    }
    func testDetailOnlyArtworkKeepsBinaryFidelityWithoutAddingPrimaryFields() async throws {
        let request = CapturedRequest(method: "GET", scheme: .https, host: SyntheticAssetOriginServer.defaultHost,
            port: 443, path: "/fixtures/images/test_pattern.png", headers: [], bodyData: nil, bodySize: nil)
        let png = try XCTUnwrap(SyntheticAssetOriginServer.shared.response(for: request)?.bodyData)
        let sourceID = UUID()
        let targetID = UUID()
        var detail = CapturedRelatedResponse(
            source: Data(#"{"id":1,"title":"Template","art":{"logo":"old","hero":"old"},"unchanged":true}"#.utf8),
            scope: scope("/detail/2?profile=2&nonce=old"), edits: [
                .init(pointer: "/id", value: .number("2")), .init(pointer: "/title", value: .string("JoesProxy"))],
            images: [.init(pointer: "/art/logo", assetID: "image-0"), .init(pointer: "/art/hero", assetID: "image-1")],
            identityLinks: [.init(pointer: "/id", primaryPointer: "/items/0/id")],
            sourceSessionID: sourceID, targetSessionID: targetID, ignoredQueryNames: ["nonce"])
        let images = [
            CapturedMockImageBinding(itemPointer: nil, bytes: png, originalURL: nil,
                deliveryURL: URL(string: "https://images.example.test/logo.png?format=webp"), imageReference: "files/logo.png"),
            CapturedMockImageBinding(itemPointer: nil, bytes: png, originalURL: nil,
                deliveryURL: URL(string: "https://images.example.test/hero.png?format=webp"), imageReference: "files/hero.png")]
        let service = CollectionMockAuthoringService()
        let package = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "detail-art",
            name: "Synthetic", source: source, draft: draft, scope: scope("/items"), images: images,
            appVersion: "test", createdAt: Date(), relatedResponses: [detail])
        XCTAssertEqual(package.assetDataByID["image-0"], png)
        XCTAssertEqual(package.assetDataByID["image-1"], png)
        let primary = try CollectionMockCompiler.parse(XCTUnwrap(package.assetDataByID["response"]))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["items", "0"], in: primary), .object(["id": .number("2")]))
        let root = try CollectionMockCompiler.parse(XCTUnwrap(package.assetDataByID["related-0"]))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["art", "logo"], in: root), .string("files/logo.png"))
        XCTAssertEqual(try CollectionMockCompiler.value(at: ["art", "hero"], in: root), .string("files/hero.png"))
        XCTAssertEqual(package.manifest.responseEffects.last?.path, "/detail/2?profile=2")
        XCTAssertEqual(package.manifest.authoring?.relatedResponses?.first?.sourceSessionID, sourceID)
        XCTAssertEqual(package.manifest.authoring?.relatedResponses?.first?.targetSessionID, targetID)
        detail.targetSessionID = UUID()
        do {
            _ = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "detail-art",
                name: "Synthetic", source: source, draft: draft, scope: scope("/items"), images: images,
                appVersion: "test", createdAt: Date(), relatedResponses: [detail])
            XCTFail("Changed target provenance must not reuse a revision")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .idempotencyConflict) }
        do {
            _ = try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "unused",
                name: "Synthetic", source: source, draft: draft, scope: scope("/items"), images: images,
                appVersion: "test", createdAt: Date())
            XCTFail("Unbound detail-only images must fail")
        } catch { XCTAssertEqual(error as? CapturedMockPackageError, .invalidImage) }
    }
    func testRelatedInputUsesTypedJSONAndRejectsUnknownFields() throws {
        let id = UUID()
        let response = CapturedResponse(statusCode: 200, headers: [],
            bodyData: Data(#"{"id":2,"enabled":false}"#.utf8), bodySize: nil)
        let input = CapturedRelatedResponseInput(sessionID: id, response: response, scope: scope("/detail/2"),
            editsJSON: Data(#"{"edits":[{"pointer":"/enabled","value":true}],"identityLinks":[{"pointer":"/id","primaryPointer":"/items/0/id"}]}"#.utf8))
        let decoded = try CapturedRelatedResponseDecoder.decode(input)
        XCTAssertEqual(decoded.sourceSessionID, id)
        XCTAssertEqual(decoded.edits.first?.value, .bool(true))
        for invalid in [
            #"{"edits":[{"pointer":"/enabled","value":true,"extra":1}]}"#,
            #"{"images":[{"pointer":"/image","file":"local.png"}]}"#,
            #"{"identityLinks":[{"pointer":"/id"}]}"#,
            #"{"host":"elsewhere.example.test"}"#
        ] {
            XCTAssertThrowsError(try CapturedRelatedResponseDecoder.decode(.init(sessionID: id,
                response: response, scope: input.scope, editsJSON: Data(invalid.utf8))))
        }
        let unavailable = CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil)
        XCTAssertThrowsError(try CapturedRelatedResponseDecoder.decode(.init(sessionID: id,
            response: unavailable, scope: input.scope, editsJSON: input.editsJSON)))
    }
    private let source = Data(#"{"items":[{"id":1}]}"#.utf8)
    private var draft: CollectionMockDraft {
        .init(collectionPointer: "/items", item: .object(["id": .number("2")]), templateIndex: nil,
            edits: [], identityPointers: ["/id"], countPointers: [], position: .prepend)
    }
    private func scope(_ path: String, client: String = "192.0.2.10") -> CapturedMockScope {
        .init(host: "api.example.test", scheme: .https, port: 443, path: path, clients: .address(client))
    }
    private func related(title: String = "JoesProxy", client: String = "192.0.2.10",
                         path: String = "/detail/2") -> CapturedRelatedResponse {
        .init(source: Data(#"{"id":2,"title":"Template","unchanged":true}"#.utf8),
            scope: scope(path, client: client), edits: [.init(pointer: "/title", value: .string(title))],
            images: [], identityLinks: [.init(pointer: "/id", primaryPointer: "/items/0/id")])
    }
    func testRelatedResponseIsImmutableAndKeepsSiblingFields() async throws {
        let service = CollectionMockAuthoringService()
        let first = try await service.prepareCapturedPackage(ownerID: "test", idempotencyKey: "revision",
            name: "Synthetic", source: source, draft: draft, scope: scope("/items"), images: [],
            appVersion: "test", createdAt: Date(), relatedResponses: [related()])
        XCTAssertEqual(first.manifest.responseEffects.count, 2)
        let metadata = try XCTUnwrap(first.manifest.authoring?.relatedResponses?.first)
        XCTAssertEqual(metadata.assetID, "related-0")
        XCTAssertEqual(metadata.sourceDigest, EffectBundleValidator.sha256Hex(related().source))
        XCTAssertEqual(metadata.changedPointers, ["/title"])
        let roundTrip = try JSONDecoder().decode(EffectBundleManifest.self, from: JSONEncoder().encode(first.manifest))
        XCTAssertEqual(roundTrip.authoring?.relatedResponses, first.manifest.authoring?.relatedResponses)
        var downgraded = first.manifest
        downgraded.schemaVersion = 2
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(downgraded))
        var invalidMetadata = first.manifest
        invalidMetadata.authoring?.relatedResponses = [.init(assetID: "missing", sourceSessionID: nil,
            sourceDigest: metadata.sourceDigest, changedPointers: [], images: [], identityLinks: metadata.identityLinks)]
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(invalidMetadata))
        let body = try XCTUnwrap(first.assetDataByID["related-0"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "JoesProxy")
        XCTAssertEqual(json["unchanged"] as? Bool, true)
        let retry = try await service.prepareCapturedPackage(ownerID: "test", idempotencyKey: "revision",
            name: "Synthetic", source: source, draft: draft, scope: scope("/items"), images: [],
            appVersion: "test", createdAt: Date(), relatedResponses: [related()])
        XCTAssertEqual(first.manifest.id, retry.manifest.id)
        do {
            _ = try await service.prepareCapturedPackage(ownerID: "test", idempotencyKey: "revision",
                name: "Synthetic", source: source, draft: draft, scope: scope("/items"), images: [],
                appVersion: "test", createdAt: Date(), relatedResponses: [related(title: "Changed")])
            XCTFail("A changed related response must require a new revision")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .idempotencyConflict) }
    }
    func testConflictingEndpointAndDifferentClientAreRejected() throws {
        let package = try CapturedMockPackageCompiler.prepare(id: UUID(), name: "Synthetic",
            source: source, draft: draft, scope: scope("/items"), images: [], appVersion: "test", createdAt: Date())
        XCTAssertThrowsError(try CapturedRelatedResponseCompiler.append([related(client: "192.0.2.11")], to: package))
        XCTAssertThrowsError(try CapturedRelatedResponseCompiler.append([related(path: "/items?variant=2")], to: package))
        XCTAssertThrowsError(try CapturedRelatedResponseCompiler.append([related(), related()], to: package))
        let wrongIdentity = CapturedRelatedResponse(source: Data(#"{"id":99}"#.utf8),
            scope: scope("/detail/2"), edits: [], images: [],
            identityLinks: [.init(pointer: "/id", primaryPointer: "/items/0/id")])
        XCTAssertThrowsError(try CapturedRelatedResponseCompiler.append([wrongIdentity], to: package))
        let overlapping = CapturedRelatedResponse(source: Data(#"{"id":2,"art":{"logo":"old"}}"#.utf8),
            scope: scope("/detail/2"), edits: [
                .init(pointer: "/art", value: .object(["logo": .string("new")])),
                .init(pointer: "/art/logo", value: .string("other"))], images: [],
            identityLinks: [.init(pointer: "/id", primaryPointer: "/items/0/id")])
        XCTAssertThrowsError(try CapturedRelatedResponseCompiler.append([overlapping], to: package))
    }
}
