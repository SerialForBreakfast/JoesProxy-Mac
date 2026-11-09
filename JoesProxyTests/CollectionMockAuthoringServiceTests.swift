import XCTest
@testable import JoesProxy

final class CollectionMockAuthoringServiceTests: XCTestCase {
    private let source = Data(#"{"items":[]}"#.utf8)
    private var draft: CollectionMockDraft {
        CollectionMockDraft(collectionPointer: "/items", item: .object(["id": .string("new")]),
            templateIndex: nil, edits: [], identityPointers: ["/id"], countPointers: [], position: .append)
    }

    func testIdenticalRetryReturnsImmutableRevision() async throws {
        let service = CollectionMockAuthoringService()
        let first = try await service.prepare(ownerID: "owner", idempotencyKey: "retry", source: source, draft: draft)
        let second = try await service.prepare(ownerID: "owner", idempotencyKey: "retry", source: source, draft: draft)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.beforeCount, 0)
        XCTAssertEqual(first.afterCount, 1)
        XCTAssertEqual(first.bodyDigest.count, 64)
    }

    func testChangedRequestCannotReuseIdempotencyKey() async throws {
        let service = CollectionMockAuthoringService()
        _ = try await service.prepare(ownerID: "owner", idempotencyKey: "retry", source: source, draft: draft)
        do {
            _ = try await service.prepare(ownerID: "owner", idempotencyKey: "retry", source: Data(#"{"items":[],"extra":1}"#.utf8), draft: draft)
            XCTFail("Changed request must be rejected")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .idempotencyConflict) }
    }

    func testOwnerIsolationAndCapacity() async throws {
        let service = CollectionMockAuthoringService(maximumRevisions: 1)
        let revision = try await service.prepare(ownerID: "one", idempotencyKey: "same", source: source, draft: draft)
        do {
            _ = try await service.inspect(id: revision.id, ownerID: "two")
            XCTFail("Cross-owner read must fail")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionNotFound) }
        do {
            _ = try await service.prepare(ownerID: "two", idempotencyKey: "same", source: source, draft: draft)
            XCTFail("Capacity must be enforced")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .capacityExceeded) }
    }
}
