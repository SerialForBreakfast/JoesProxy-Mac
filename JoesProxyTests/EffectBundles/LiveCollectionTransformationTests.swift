import XCTest
@testable import JoesProxy

final class LiveCollectionTransformationTests: XCTestCase {
    private let source = Data(#"{"items":[{"id":"original"}],"total":1,"sibling":{"value":true}}"#.utf8)
    private let headers = [HTTPHeaderField(name: "Content-Type", value: "application/json"),
                           HTTPHeaderField(name: "ETag", value: "original"),
                           HTTPHeaderField(name: "Transfer-Encoding", value: "chunked")]

    private func plan() throws -> CompiledCollectionMock {
        try CollectionMockCompiler.prepare(source: source, draft: .init(collectionPointer: "/items",
            item: .object(["id": .string("synthetic")]), templateIndex: nil, edits: [],
            identityPointers: ["/id"], countPointers: ["/total"], position: .append))
    }

    func testFreshResponseAndHeadersChangeOnlyAfterSuccessfulTransformation() throws {
        let fresh = Data(#"{"items":[{"id":"fresh"}],"total":8,"sibling":{"value":false}}"#.utf8)
        let result = LiveResponseTransformation.transformCollection(method: "GET", statusCode: 200,
            headers: headers, body: fresh, plan: try plan())
        XCTAssertEqual(result.outcome, .applied(beforeCount: 1, afterCount: 2))
        XCTAssertEqual(try CollectionMockCompiler.parse(result.body), try CollectionMockCompiler.parse(
            Data(#"{"items":[{"id":"fresh"},{"id":"synthetic"}],"total":9,"sibling":{"value":false}}"#.utf8)))
        XCTAssertFalse(result.headers.contains { ["etag", "transfer-encoding"].contains($0.name.lowercased()) })
        XCTAssertTrue(result.headers.contains(.init(name: "Content-Length", value: String(result.body.count))))
        let duplicate = LiveResponseTransformation.transformCollection(method: "GET", statusCode: 200,
            headers: headers, body: result.body, plan: try plan())
        XCTAssertEqual(duplicate.outcome, .alreadyPresent)
        XCTAssertEqual(duplicate.body, result.body)
        XCTAssertEqual(duplicate.headers, headers)
    }

    func testFailuresKeepExactOriginalBytesAndHeaders() throws {
        let invalid = Data("not JSON".utf8)
        let result = LiveResponseTransformation.transformCollection(method: "GET", statusCode: 200,
            headers: headers, body: invalid, plan: try plan())
        XCTAssertEqual(result.outcome, .contractMismatch(.invalidJSON))
        XCTAssertEqual(result.body, invalid)
        XCTAssertEqual(result.headers, headers)
        for (method, status) in [("HEAD", 200), ("POST", 200), ("GET", 206), ("GET", 304), ("GET", 500)] {
            let skipped = LiveResponseTransformation.transformCollection(method: method, statusCode: status,
                headers: headers, body: source, plan: try plan())
            XCTAssertEqual(skipped.outcome, .ineligibleResponse)
            XCTAssertEqual(skipped.body, source)
            XCTAssertEqual(skipped.headers, headers)
        }
    }

    func testGzipRoundTripAndAmbiguousEncodingsFailOpen() throws {
        let compressed = try XCTUnwrap(LiveResponseTransformation.gzipCompress(source))
        let gzipHeaders = headers + [.init(name: "Content-Encoding", value: "gzip")]
        let result = LiveResponseTransformation.transformCollection(method: "GET", statusCode: 200,
            headers: gzipHeaders, body: compressed, plan: try plan())
        XCTAssertEqual(result.outcome, .applied(beforeCount: 1, afterCount: 2))
        let decoded = try XCTUnwrap(CapturedBodyDecoder.decode(bodyData: result.body, headers: result.headers))
        XCTAssertTrue(decoded.canUseAnalysisDataForInspection)
        XCTAssertEqual(try CollectionMockCompiler.apply(source: decoded.analysisData, plan: plan()), .alreadyPresent)
        for encodings in [["br"], ["gzip", "gzip"], ["gzip, identity"], [""]] {
            let fields = headers + encodings.map { HTTPHeaderField(name: "Content-Encoding", value: $0) }
            let skipped = LiveResponseTransformation.transformCollection(method: "GET", statusCode: 200,
                headers: fields, body: compressed, plan: try plan())
            XCTAssertEqual(skipped.outcome, .unsupportedEncoding)
            XCTAssertEqual(skipped.body, compressed)
            XCTAssertEqual(skipped.headers, fields)
        }
    }

    func testSizeLimitsPreserveInput() throws {
        let oversized = Data(repeating: 32, count: CollectionMockCompiler.maximumBodyBytes + 1)
        let result = LiveResponseTransformation.transformCollection(method: "GET", statusCode: 200,
            headers: headers, body: oversized, plan: try plan())
        XCTAssertEqual(result.outcome, .sizeLimit)
        XCTAssertEqual(result.body, oversized)
        XCTAssertEqual(result.headers, headers)
        let compressed = try XCTUnwrap(LiveResponseTransformation.gzipCompress(oversized))
        let fields = headers + [.init(name: "Content-Encoding", value: "gzip")]
        let expanded = LiveResponseTransformation.transformCollection(method: "GET", statusCode: 200,
            headers: fields, body: compressed, plan: try plan())
        XCTAssertEqual(expanded.outcome, .sizeLimit)
        XCTAssertEqual(expanded.body, compressed)
        XCTAssertEqual(expanded.headers, fields)
    }

    func testDefaultWorkerUsesRetainedPlanAndStoppedRevisionFailsOpen() async throws {
        let executor = LiveCollectionTransformationExecutor()
        let id = UUID()
        let started = await executor.begin(effectID: id, plan: try plan())
        let revision = try XCTUnwrap(started)
        let result = await executor.transform(revision: revision, method: "GET", statusCode: 200,
            headers: headers, body: source)
        XCTAssertEqual(result.outcome, .applied(beforeCount: 1, afterCount: 2))
        await executor.stop(effectID: id)
        let skipped = await executor.transform(revision: revision, method: "GET", statusCode: 200,
            headers: headers, body: source)
        XCTAssertEqual(skipped.outcome, .inactiveRevision)
        XCTAssertEqual(skipped.body, source)
    }

    func testExecutorDoesNotAddASecondCapacityLimitAndReplacementDiscardsOutstandingResults() async throws {
        let gate = WorkerGate()
        let executor = LiveCollectionTransformationExecutor(worker: { method, status, headers, body, plan in
            await gate.enter()
            return LiveResponseTransformation.transformCollection(method: method, statusCode: status,
                headers: headers, body: body, plan: plan)
        })
        let effectID = UUID()
        let plan = try plan()
        let started = await executor.begin(effectID: effectID, plan: plan)
        let revision = try XCTUnwrap(started)
        let body = source
        let fields = headers
        let first = Task { await executor.transform(revision: revision, method: "GET", statusCode: 200,
            headers: fields, body: body) }
        await gate.waitForEntries(1)
        let second = Task { await executor.transform(revision: revision, method: "GET", statusCode: 200,
            headers: fields, body: body) }
        await gate.waitForEntries(2)
        let third = Task { await executor.transform(revision: revision, method: "GET", statusCode: 200,
            headers: fields, body: body) }
        await gate.waitForEntries(3)
        _ = await executor.begin(effectID: effectID, plan: plan)
        await gate.release()
        let oldResults = await [first.value, second.value, third.value]
        for result in oldResults {
            XCTAssertEqual(result.outcome, .inactiveRevision)
            XCTAssertEqual(result.body, body)
            XCTAssertEqual(result.headers, fields)
        }
    }

    func testStopAndCancellationDiscardWorkerResults() async throws {
        for cancel in [false, true] {
            let gate = WorkerGate()
            let executor = LiveCollectionTransformationExecutor(worker: { method, status, headers, body, plan in
                await gate.enter()
                return LiveResponseTransformation.transformCollection(method: method, statusCode: status,
                    headers: headers, body: body, plan: plan)
            })
            let id = UUID()
            let compiled = try plan()
            let started = await executor.begin(effectID: id, plan: compiled)
            let revision = try XCTUnwrap(started)
            let body = source
            let fields = headers
            let task = Task { await executor.transform(revision: revision, method: "GET", statusCode: 200,
                headers: fields, body: body) }
            await gate.waitForEntries(1)
            if cancel { task.cancel() } else { await executor.stop(effectID: id) }
            await gate.release()
            let result = await task.value
            XCTAssertEqual(result.outcome, cancel ? .cancelled : .inactiveRevision)
            XCTAssertEqual(result.body, body)
            XCTAssertEqual(result.headers, fields)
        }
    }

    @MainActor
    func testExecutorDetachesCustomWorkerFromMainActorCaller() async throws {
        let probe = WorkerExecutionProbe()
        let executor = LiveCollectionTransformationExecutor(worker: { method, status, headers, body, plan in
            await probe.record(threadIsMain: Thread.isMainThread)
            return LiveResponseTransformation.transformCollection(method: method, statusCode: status,
                headers: headers, body: body, plan: plan)
        })
        let effectID = UUID()
        let revision = try XCTUnwrap(executor.begin(effectID: effectID, plan: try plan()))

        _ = await executor.transform(revision: revision, method: "GET", statusCode: 200,
            headers: headers, body: source)

        let observations = await probe.mainThreadObservations()
        XCTAssertEqual(observations, [false],
            "Collection computation must not inherit the caller's main-actor execution context")
    }
}

private actor WorkerGate {
    private var entries = 0
    private var workers: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func enter() async {
        entries += 1
        let ready = observers.filter { $0.0 <= entries }
        observers.removeAll { $0.0 <= entries }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { workers.append($0) }
    }

    func waitForEntries(_ count: Int) async {
        if entries >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func release() {
        let pending = workers
        workers.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor WorkerExecutionProbe {
    private var observations: [Bool] = []

    func record(threadIsMain: Bool) {
        observations.append(threadIsMain)
    }

    func mainThreadObservations() -> [Bool] {
        observations
    }
}
