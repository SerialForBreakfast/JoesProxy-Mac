import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class ArtifactSourceRegistryTests: XCTestCase {
    private func searchFixture(worker: ArtifactAnalysisWorker, repeats: Int = 3) async throws -> (ArtifactSourceRegistry, ArtifactSourceRegistry.Request) {
        let registry = ArtifactSourceRegistry(worker: worker, approvals: MCPApprovalStore())
        let owner = ArtifactSourceRegistry.Owner(clientID: "search-client", generation: 1, policyRevision: .initial, profile: .shareable)
        registry.currentOwner = { _ in owner }
        registry.currentSearchPermission = { _ in true }
        let request = try registry.register(key: UUID().uuidString, kind: .text, scopes: ["metadata-v1", "search-v1"],
            ttl: 600, owner: owner, argumentDigest: "fixture", sessionID: nil)
        registry.prepare(id: request.id, selection: .synthetic(Data(String(repeating: "abc", count: repeats).utf8)))
        await registry.waitForPreparation(id: request.id)
        try registry.share(id: request.id)
        return (registry, try registry.publish(id: request.id, owner: owner))
    }

    func testSearchRechecksPermissionAfterWorkerAndRetiresLeases() async throws {
        let gate = ArtifactTestGate()
        let counter = ArtifactWorkCounter()
        defer { gate.open() }
        let worker = ArtifactAnalysisWorker(beforeWork: {
            counter.increment()
            if counter.value == 2 { gate.wait() }
        })
        let (registry, request) = try await searchFixture(worker: worker)
        let query = try ArtifactSearchQuery(inventory: false, arguments: ["dataset": "sourceUTF8", "literal": "abc", "limit": 1])
        let search = Task { @MainActor in
            try await registry.searchSessions.run(registry: registry, request: request, query: query, token: nil) { _ in 100 }
        }
        for _ in 0..<100 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(gate.entered)
        registry.currentSearchPermission = { _ in false }
        gate.open()
        do { _ = try await search.value; XCTFail("Retired authority published a page") }
        catch { XCTAssertEqual(error as? ArtifactAnalysisFailure, .sourceUnavailable) }
        XCTAssertNil(registry.request(id: request.id)?.snapshot)
    }

    func testReplayExpiresWhenItsReferenceSlotsAreEvicted() async throws {
        let (registry, request) = try await searchFixture(worker: ArtifactAnalysisWorker(), repeats: 80)
        let query = try ArtifactSearchQuery(inventory: false, arguments: ["dataset": "sourceUTF8", "literal": "abc", "limit": 50])
        func page(_ token: String?) async throws -> [String: Any] {
            try await registry.searchSessions.run(registry: registry, request: request, query: query, token: token) { _ in 100 }
        }
        let first = try await page(nil)
        let cursor = try XCTUnwrap(first["nextCursor"] as? String)
        _ = try await page(cursor)
        for _ in 0..<6 { _ = try await page(nil) }
        do { _ = try await page(cursor); XCTFail("Replayed retired references") }
        catch { XCTAssertEqual(error as? ArtifactAnalysisFailure, .cursorExpired) }
    }

    func testSearchCursorCapacityExpiryAndSourceOwnership() async throws {
        let (registry, request) = try await searchFixture(worker: ArtifactAnalysisWorker())
        let query = try ArtifactSearchQuery(inventory: false, arguments: ["dataset": "sourceUTF8", "literal": "abc", "limit": 1])
        func page(_ token: String?) async throws -> [String: Any] {
            try await registry.searchSessions.run(registry: registry, request: request, query: query, token: token) { _ in 100 }
        }
        var cursors: [String] = []
        for _ in 0..<9 {
            let first = try await page(nil)
            cursors.append(try XCTUnwrap(first["nextCursor"] as? String))
        }
        do { _ = try await page(cursors[0]); XCTFail("Evicted cursor succeeded") }
        catch { XCTAssertEqual(error as? ArtifactAnalysisFailure, .cursorExpired) }
        registry.searchSessions.prune(now: Date().addingTimeInterval(301))
        do { _ = try await page(cursors[8]); XCTFail("Expired cursor succeeded") }
        catch { XCTAssertEqual(error as? ArtifactAnalysisFailure, .cursorExpired) }
        let other = ArtifactSourceRegistry.Owner(clientID: "other", generation: 1, policyRevision: .initial, profile: .shareable)
        XCTAssertThrowsError(try registry.inspect(handle: XCTUnwrap(request.handle), owner: other))
    }

    private func makeRegistry() -> (ArtifactSourceRegistry, ArtifactSourceRegistry.Owner) {
        let registry = ArtifactSourceRegistry(worker: ArtifactAnalysisWorker(), approvals: MCPApprovalStore())
        let owner = ArtifactSourceRegistry.Owner(clientID: "synthetic-client", generation: 1, policyRevision: .initial, profile: .shareable)
        registry.currentOwner = { $0 == owner.clientID ? owner : nil }
        registry.currentCalculationPermission = { _ in true }
        return (registry, owner)
    }

    private func register(_ registry: ArtifactSourceRegistry, owner: ArtifactSourceRegistry.Owner,
                          key: String = UUID().uuidString, digest: String = "synthetic-query") throws -> ArtifactSourceRegistry.Request {
        try registry.register(key: key, kind: .json, scopes: ["metadata-v1", "calculations-v1"], ttl: 60,
            owner: owner, argumentDigest: digest + key, sessionID: "synthetic-session")
    }

    private func ready(_ registry: ArtifactSourceRegistry, owner: ArtifactSourceRegistry.Owner) async throws -> ArtifactSourceRegistry.Request {
        let request = try register(registry, owner: owner)
        registry.prepare(id: request.id, selection: .synthetic(Data("[0.1,0.2]".utf8)))
        await registry.waitForPreparation(id: request.id)
        XCTAssertEqual(registry.request(id: request.id)?.state, "review")
        try registry.share(id: request.id)
        return try registry.publish(id: request.id, owner: owner)
    }

    func testSelectionCannotPublishBeforeExplicitReview() async throws {
        let (registry, owner) = makeRegistry()
        let request = try register(registry, owner: owner)
        XCTAssertThrowsError(try registry.publish(id: request.id, owner: owner))
        XCTAssertThrowsError(try registry.share(id: request.id))
        registry.prepare(id: request.id, selection: .synthetic(Data("[]".utf8)))
        await registry.waitForPreparation(id: request.id)
        XCTAssertThrowsError(try registry.publish(id: request.id, owner: owner))
        XCTAssertNil(registry.request(id: request.id)?.handle)
        try registry.share(id: request.id)
        let published = try registry.publish(id: request.id, owner: owner)
        XCTAssertNotNil(published.handle)
        XCTAssertEqual(published.snapshot?.originalBytes, Data("[]".utf8))
    }

    func testIdempotencyConflictOwnerIsolationAndRelease() async throws {
        let (registry, owner) = makeRegistry()
        let request = try await ready(registry, owner: owner)
        XCTAssertEqual(try register(registry, owner: owner, key: request.key).handle, request.handle)
        XCTAssertThrowsError(try register(registry, owner: owner, key: request.key, digest: "changed"))
        let other = ArtifactSourceRegistry.Owner(clientID: "other", generation: 1, policyRevision: .initial, profile: .shareable)
        XCTAssertThrowsError(try registry.inspect(handle: XCTUnwrap(request.handle), owner: other))
        XCTAssertThrowsError(try registry.release(handle: XCTUnwrap(request.handle), clientID: other.clientID))
        try registry.release(handle: XCTUnwrap(request.handle), clientID: owner.clientID)
        try registry.release(handle: XCTUnwrap(request.handle), clientID: owner.clientID)
        XCTAssertNil(registry.request(id: request.id)?.snapshot)
        XCTAssertThrowsError(try registry.inspect(handle: XCTUnwrap(request.handle), owner: owner))
    }

    func testCancellationBeforeLateWorkerCompletionCannotRestoreDraft() async throws {
        let (registry, owner) = makeRegistry()
        let request = try register(registry, owner: owner)
        registry.prepare(id: request.id, selection: .synthetic(Data("[]".utf8)))
        registry.retire(id: request.id)
        await registry.waitForPreparation(id: request.id)
        XCTAssertEqual(registry.request(id: request.id)?.state, "cancelled")
        XCTAssertNil(registry.request(id: request.id)?.snapshot)
        XCTAssertEqual(registry.request(id: request.id)?.reservedBytes, 0)
        XCTAssertFalse(registry.worker.busy)
    }

    func testRevocationExpiryCredentialAndCalculationDenial() async throws {
        let (registry, owner) = makeRegistry()
        let request = try await ready(registry, owner: owner)
        registry.currentCalculationPermission = { _ in false }
        registry.prune()
        XCTAssertEqual(registry.request(id: request.id)?.state, "revoked")
        registry.currentCalculationPermission = { _ in true }
        let next = try await ready(registry, owner: owner)
        registry.prune(now: Date().addingTimeInterval(61))
        XCTAssertEqual(registry.request(id: next.id)?.state, "expired")
        let last = try await ready(registry, owner: owner)
        registry.currentOwner = { _ in nil }
        registry.prune()
        XCTAssertNil(registry.request(id: last.id)?.snapshot)
    }

    func testPendingQuotaAndBoundedTombstoneExpiry() throws {
        let (registry, owner) = makeRegistry()
        let first = try register(registry, owner: owner)
        _ = try register(registry, owner: owner, digest: "other-query")
        XCTAssertThrowsError(try register(registry, owner: owner, digest: "third-query"))
        registry.retire(id: first.id)
        registry.prune(now: Date().addingTimeInterval(3601))
        XCTAssertTrue(registry.requests.isEmpty)
    }

    func testMemoryPressureRetiresIdleCopyAndPreservesPinnedWork() async throws {
        let (registry, owner) = makeRegistry()
        let request = try await ready(registry, owner: owner)
        registry.setInUse(request.id, true)
        registry.retireIdleSourceForMemoryPressure()
        XCTAssertNotNil(registry.request(id: request.id)?.snapshot)
        registry.setInUse(request.id, false)
        registry.retireIdleSourceForMemoryPressure()
        XCTAssertEqual(registry.request(id: request.id)?.state, "memory_pressure")
    }

    func testMetadataProfileCannotRequestCalculationScope() throws {
        let (registry, _) = makeRegistry()
        let owner = ArtifactSourceRegistry.Owner(clientID: "metadata", generation: 1, policyRevision: .initial, profile: .metadataOnly)
        XCTAssertThrowsError(try register(registry, owner: owner))
    }
}
