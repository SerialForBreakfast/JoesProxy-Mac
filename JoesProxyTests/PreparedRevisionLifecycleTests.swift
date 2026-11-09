import XCTest
@testable import JoesProxy

final class PreparedRevisionLifecycleTests: XCTestCase {
    private let source = Data(#"{"items":[]}"#.utf8)
    private var draft: CollectionMockDraft {
        .init(collectionPointer: "/items", item: .object(["id": .string("new")]), templateIndex: nil,
              edits: [], identityPointers: ["/id"], countPointers: [], position: .append)
    }

    func testRetirementReleasesByteBudgetAndPreventsOldKeyResurrection() async throws {
        let sample = try await CollectionMockAuthoringService().prepare(ownerID: "owner", idempotencyKey: "sample",
            source: source, draft: draft)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cost = sample.body.count + (try encoder.encode(sample.plan).count)
        let service = CollectionMockAuthoringService(maximumRevisions: 10, maximumRetainedBytes: cost)
        let first = try await service.prepare(ownerID: "owner", idempotencyKey: "first", source: source, draft: draft)
        do {
            _ = try await service.prepare(ownerID: "owner", idempotencyKey: "second", source: source, draft: draft)
            XCTFail("Byte budget must reject a second retained revision")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .capacityExceeded) }
        async let retirement = service.retire(id: first.id, ownerID: "owner")
        async let retry = service.retire(id: first.id, ownerID: "owner")
        let results = try await [retirement, retry]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let second = try await service.prepare(ownerID: "owner", idempotencyKey: "second", source: source, draft: draft)
        XCTAssertNotEqual(first.id, second.id)
        do {
            _ = try await service.prepare(ownerID: "owner", idempotencyKey: "first", source: source, draft: draft)
            XCTFail("Delayed prepare must not resurrect a retired key")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionRetired) }
        do {
            _ = try await service.inspect(id: first.id, ownerID: "owner")
            XCTFail("Retired content cannot be inspected")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionRetired) }
        do {
            _ = try await service.retire(id: first.id, ownerID: "other")
            XCTFail("Wrong owner must not discover retired handles")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionNotFound) }
        do {
            _ = try await service.retire(id: second.id, ownerID: "other")
            XCTFail("Wrong owner must not retire live handles")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionNotFound) }
        let retained = try await service.inspect(id: second.id, ownerID: "owner")
        XCTAssertEqual(retained, second)
    }

    func testHistoryBoundNeverEvictsRetiredKeysOrBlocksRelease() async throws {
        let service = CollectionMockAuthoringService(maximumRevisions: 1, maximumRequestHistory: 2)
        for key in ["first", "second"] {
            let revision = try await service.prepare(ownerID: "owner", idempotencyKey: key, source: source, draft: draft)
            try await service.retire(id: revision.id, ownerID: "owner")
        }
        do {
            _ = try await service.prepare(ownerID: "owner", idempotencyKey: "third", source: source, draft: draft)
            XCTFail("History must remain bounded")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .requestHistoryFull) }
        do {
            _ = try await service.prepare(ownerID: "owner", idempotencyKey: "first", source: source, draft: draft)
            XCTFail("History exhaustion must not evict earlier tombstones")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionRetired) }
    }

    func testHandlesAreProcessLocalAndRetirementDoesNotPublish() async throws {
        let service = CollectionMockAuthoringService()
        let revision = try await service.prepare(ownerID: "owner", idempotencyKey: "key", source: source, draft: draft)
        let restarted = CollectionMockAuthoringService()
        do {
            _ = try await restarted.inspect(id: revision.id, ownerID: "owner")
            XCTFail("A new service cannot recover an in-memory handle")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .revisionNotFound) }
        let replacement = try await restarted.prepare(ownerID: "owner", idempotencyKey: "key", source: source, draft: draft)
        XCTAssertNotEqual(revision.id, replacement.id)
    }
}
