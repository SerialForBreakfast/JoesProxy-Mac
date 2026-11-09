import XCTest
@testable import JoesProxy

final class CapturedMockImageFileTests: XCTestCase {
    func testImageBookmarkPreparationFreezesBytesAndRewritesJSON() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/CapturedMockImageFileTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = CapturedRequest(method: "GET", scheme: .https, host: SyntheticAssetOriginServer.defaultHost,
            port: 443, path: "/fixtures/images/test_pattern.png", headers: [], bodyData: nil, bodySize: nil)
        let png = try XCTUnwrap(SyntheticAssetOriginServer.shared.response(for: request)?.bodyData)
        let file = root.appendingPathComponent("misleading.txt")
        try png.write(to: file)
        let bookmark = try file.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let binding = CapturedMockImageFile(itemPointer: "/image", bookmarkRef: bookmark.base64EncodedString(), originalURL: nil)
        let service = CollectionMockAuthoringService()
        let response = CapturedResponse(statusCode: 200, headers: [], bodyData: Data(#"{"items":[]}"#.utf8), bodySize: nil)
        let draft = Data(#"{"collectionPointer":"/items","item":{"id":"new","image":"placeholder"},"identityPointers":["/id"]}"#.utf8)
        let scope = CapturedMockScope(host: "api.example.test", scheme: .https, port: 443, path: "/items", clients: .address("192.0.2.10"))
        let package = try await service.prepareCapturedResponse(ownerID: "owner", idempotencyKey: "key", name: "Synthetic",
            response: response, draftJSON: draft, scope: scope, appVersion: "test", imageFiles: [binding])
        let image = try XCTUnwrap(package.images.first)
        XCTAssertEqual(image.contentType, "image/png", "Sniff content instead of trusting filename")
        XCTAssertEqual(package.assetDataByID[image.assetID], png)
        XCTAssertTrue(image.url.contains(image.sha256))
        let body = try XCTUnwrap(package.assetDataByID["response"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["image"] as? String, image.url)
        try Data("changed file".utf8).write(to: file)
        let stored = try await service.inspectCapturedPackage(id: package.manifest.id, ownerID: "owner")
        XCTAssertEqual(stored.assetDataByID[image.assetID], png)
        do {
            _ = try await service.prepareCapturedResponse(ownerID: "owner", idempotencyKey: "key", name: "Synthetic",
                response: response, draftJSON: draft, scope: scope, appVersion: "test", imageFiles: [binding])
            XCTFail("Changed source cannot alter a reviewed revision")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .idempotencyConflict) }
    }

    func testInvalidAndOversizedBookmarksFailWithoutPaths() {
        for reference in ["not a bookmark", String(repeating: "a", count: 65537)] {
            XCTAssertThrowsError(try CapturedMockImageFile(itemPointer: "/image", bookmarkRef: reference, originalURL: nil).read()) {
                XCTAssertEqual($0 as? CapturedMockImageFile.ImageFileError, .invalidReference)
            }
        }
    }
}
