import XCTest
@testable import JoesProxy

@MainActor
final class PreparedMockRepositoryTests: XCTestCase {
    func testRevisionInspectionExposesScopeWithoutBodyValues() async throws {
        let service = CollectionMockAuthoringService()
        let package = try await prepare(service)
        let metadata = MCPEffectBundleService.revisionInspection(package, retainedRecord: nil)
        XCTAssertEqual(metadata["state"] as? String, "prepared")
        XCTAssertEqual(metadata["isServing"] as? Bool, false)
        XCTAssertEqual(metadata["targetOutcome"] as? String, "unknown")
        let effects = try XCTUnwrap(metadata["responseEffects"] as? [[String: Any]])
        XCTAssertEqual(effects.first?["clientScope"] as? String, "192.0.2.10")
        XCTAssertEqual(effects.first?["path"] as? String, "/items")
        let assets = try XCTUnwrap(metadata["assets"] as? [[String: Any]])
        XCTAssertEqual(assets.first?["sha256"] as? String, package.manifest.assets.first?.sha256)
        let text = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: metadata), encoding: .utf8))
        XCTAssertFalse(text.contains("bodyData"))
        XCTAssertFalse(text.contains("logicalPath"))
        XCTAssertFalse(text.contains("\"new\""), "Synthetic item values are not metadata")
    }
    func testCapturedResponsePreparationRejectsIncompleteBodies() async throws {
        let service = CollectionMockAuthoringService()
        let scope = CapturedMockScope(host: "api.example.test", scheme: .https, port: 443,
            path: "/items", clients: .address("192.0.2.10"))
        let draft = Data(#"{"collectionPointer":"/items","item":{"id":"new"},"identityPointers":["/id"]}"#.utf8)
        for truncated in [false, true] {
            let response = CapturedResponse(statusCode: 200, headers: [], bodyData: Data(#"{"items":[]}"#.utf8),
                bodySize: nil, bodyTruncated: truncated)
            do {
                let package = try await service.prepareCapturedResponse(ownerID: "owner", idempotencyKey: "request",
                    name: "Synthetic", response: response, draftJSON: draft, scope: scope, appVersion: "test")
                XCTAssertFalse(truncated)
                XCTAssertEqual(package.manifest.authoring?.afterCount, 1)
            } catch {
                XCTAssertTrue(truncated)
                XCTAssertEqual(error as? CollectionMockAuthoringError, .invalidRequest)
            }
        }
    }
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/PreparedMockRepositoryTests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func repository(_ root: URL) -> EffectBundleRepository {
        EffectBundleRepository(persistenceURL: root.appendingPathComponent("records.json"),
            packagesRootURL: root.appendingPathComponent("packages"))
    }

    private func prepare(_ service: CollectionMockAuthoringService) async throws -> PreparedCapturedMockPackage {
        let draft = try CollectionMockDraftDecoder.decode(Data(#"{"collectionPointer":"/items","item":{"id":"new"},"identityPointers":["/id"]}"#.utf8))
        return try await service.prepareCapturedPackage(ownerID: "owner", idempotencyKey: "request", name: "Synthetic list",
            source: Data(#"{"items":[]}"#.utf8), draft: draft,
            scope: CapturedMockScope(host: "api.example.test", scheme: .https, port: 443,
                path: "/items", clients: .address("192.0.2.10")), images: [], appVersion: "test", createdAt: Date())
    }

    func testPublicationIsInactiveAndRetryPreservesLifecycle() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = repository(root)
        let service = CollectionMockAuthoringService()
        let package = try await prepare(service)
        let owner = EffectBundleOwner.mcpClient(id: "owner", displayName: "Synthetic client")
        let record = try await repository.importPreparedRevision(id: package.manifest.id, owner: owner, authoringService: service)
        XCTAssertEqual(record.state, .inactive)
        XCTAssertFalse(record.isServing)
        XCTAssertEqual(try repository.inspect(id: record.id).assetCount, 1)
        let expiry = Date(timeIntervalSince1970: 100)
        _ = try repository.markServing(id: record.id, activatedAt: Date(timeIntervalSince1970: 1), expiresAt: expiry)
        let retry = try await repository.importPreparedRevision(id: record.id, owner: owner, authoringService: service)
        XCTAssertEqual(repository.records.count, 1)
        XCTAssertEqual(retry.state, .serving)
        XCTAssertEqual(retry.expiresAt, expiry)
        let restarted = self.repository(root)
        XCTAssertEqual(restarted.record(id: record.id)?.state, .stopped)
        XCTAssertFalse(try XCTUnwrap(restarted.record(id: record.id)).isServing)
    }

    func testOtherOwnerCannotPublishRevision() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = repository(root)
        let service = CollectionMockAuthoringService()
        let package = try await prepare(service)
        do {
            _ = try await repository.importPreparedRevision(id: package.manifest.id,
                owner: .mcpClient(id: "other", displayName: "Other"), authoringService: service)
            XCTFail("Cross-owner publication must fail")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionNotFound) }
        XCTAssertTrue(repository.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("packages").path))
    }

    func testCancelledPublicationDoesNotCreateRecord() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = repository(root)
        let service = CollectionMockAuthoringService()
        let package = try await prepare(service)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.importPreparedRevision(id: package.manifest.id,
                owner: .mcpClient(id: "owner", displayName: "Owner"), authoringService: service)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled publication must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(repository.records.isEmpty)
    }
}
