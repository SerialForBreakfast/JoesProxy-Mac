import XCTest
@testable import JoesProxy

@MainActor
final class AgentQueryServicesTests: XCTestCase {
    func testCancellationReachesAlreadyRunningWorkerWithoutCancellingSibling() async throws {
        let service = AgentQueryServices(sessionStore: InMemorySessionStore()).media
        let started = WorkerStartSignal()
        let consumer = Task { @MainActor in
            await service.runDetachedCancellable(priority: .utility) {
                started.mark()
                let deadline = Date().addingTimeInterval(2)
                while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                return Task.isCancelled
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while !started.value && Date() < deadline { await Task.yield() }
        XCTAssertTrue(started.value)
        consumer.cancel()
        let wasCancelled = await consumer.value
        XCTAssertTrue(wasCancelled)
        let siblingWasCancelled = await service.runDetachedCancellable(priority: .utility) { Task.isCancelled }
        XCTAssertFalse(siblingWasCancelled)
    }
    private func session(_ path: String) -> SessionRecord {
        SessionRecord(request: CapturedRequest(method: "GET", scheme: .https,
            host: "example.test", port: 443, path: path, headers: [], bodyData: nil, bodySize: nil),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
            timing: SessionTiming(startedAt: Date()))
    }

    func testSharedQueriesSeeUpdatesWithoutInspectorAndHonorBounds() throws {
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(10))
        let first = session("/first")
        store.append(first)
        let queries = AgentQueryServices(sessionStore: store)
        let second = session("/second")
        store.append(second)
        let page = try queries.snapshots.page(request: .init(limit: 1, cursor: nil,
            queryDigest: "synthetic", orderingDigest: "capture", filter: nil),
            clientID: "synthetic-client", policyRevision: .initial)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertNotNil(queries.snapshots.indexedSession(id: first.id))
        XCTAssertNotNil(queries.snapshots.indexedSession(id: second.id))
        store.remove(ids: [first.id])
        XCTAssertNil(queries.snapshots.indexedSession(id: first.id))
        XCTAssertThrowsError(try queries.media.summary(sessionID: first.id, policyRevision: .initial))
        store.clear()
        XCTAssertTrue(queries.snapshots.recentSessions(limit: 10).isEmpty)
    }

    func testCancelledAnalysisDoesNotPreventAnotherConsumersAnalysis() async throws {
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(10))
        let record = session("/retained")
        store.append(record)
        let queries = AgentQueryServices(sessionStore: store)
        let source = MCPMediaInspectionSource(sessionID: record.id, data: Data(),
                                             fileExtension: "bin", displayName: "Synthetic")
        var release: CheckedContinuation<Void, Never>?
        let cancelledConsumer = Task { @MainActor in
            await withCheckedContinuation { release = $0 }
            return try await queries.media.inspect(source: source, analyses: [], sampleTime: 0,
                policyRevision: .initial, progress: { _, _ in })
        }
        while release == nil { await Task.yield() }
        cancelledConsumer.cancel()
        release?.resume()
        do {
            _ = try await cancelledConsumer.value
            XCTFail("Cancelled consumer must not complete")
        } catch is CancellationError { }
        _ = try await queries.media.inspect(source: source, analyses: [], sampleTime: 0,
            policyRevision: .initial, progress: { _, _ in })
        XCTAssertEqual(queries.snapshots.indexedSession(id: record.id)?.record.id, record.id)
        XCTAssertEqual(queries.snapshots.recentSessions(limit: 1).count, 1)
    }
}

private final class WorkerStartSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    var value: Bool { lock.withLock { started } }
    func mark() { lock.withLock { started = true } }
}
