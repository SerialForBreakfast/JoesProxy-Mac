import Combine
import XCTest
@testable import JoesProxy

final class SessionStoreTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    func testHeaderAccountingSurvivesBodyStrippingAndTracksCanonicalMutations() {
        let store = InMemorySessionStore(retentionPolicy: .keepLastBodyBytes(1))
        let first = SessionRecord(request: CapturedRequest(method: "GET", scheme: .http,
            host: "example.test", port: 80, path: "/one",
            headers: [HTTPHeaderField(name: "X-Test", value: "one")], bodyData: nil, bodySize: nil),
            timing: SessionTiming(startedAt: Date()))
        store.append(first)
        XCTAssertEqual(store.retainedHeaderFieldCount, 1)
        var updated = first
        updated.response = CapturedResponse(statusCode: 200,
            headers: [HTTPHeaderField(name: "X-Test", value: "two"),
                      HTTPHeaderField(name: "X-Test", value: "three")],
            bodyData: Data(repeating: 1, count: 32), bodySize: 32)
        store.update([updated, updated])
        XCTAssertEqual(store.retainedHeaderFieldCount, 3)
        XCTAssertEqual(store.retainedBodyBytes, 0)
        store.append(updated)
        XCTAssertEqual(store.retainedHeaderFieldCount, 3, "Duplicate IDs replace rather than add headers")
        store.load(sessions: [first])
        XCTAssertEqual(store.retainedHeaderFieldCount, 1)
        store.remove(ids: [first.id])
        XCTAssertEqual(store.retainedHeaderFieldCount, 0)
        store.load(sessions: [updated])
        XCTAssertEqual(store.retainedHeaderFieldCount, 3)
        let second = SessionRecord(request: first.request, timing: first.timing)
        store.retentionPolicy = .keepLastSessions(1)
        store.append(second)
        XCTAssertEqual(store.retainedHeaderFieldCount, 1)
        store.clear()
        XCTAssertEqual(store.retainedHeaderFieldCount, 0)
    }

    func testAppendUpdateAndClearSessions() {
        let store = InMemorySessionStore()
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .http,
                host: "example.com",
                port: 80,
                path: "/status",
                headers: [HTTPHeaderField(name: "Host", value: "example.com")],
                bodyData: nil,
                bodySize: nil
            ),
            timing: SessionTiming(startedAt: Date())
        )

        store.append(session)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.request.host, "example.com")

        var completedSession = session
        completedSession.response = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: Data("{\"ok\":true}".utf8),
            bodySize: 128
        )
        completedSession.state = .completed
        completedSession.timing = SessionTiming(
            startedAt: session.timing.startedAt,
            completedAt: session.timing.startedAt.addingTimeInterval(0.25)
        )

        store.update(completedSession)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.response?.statusCode, 200)
        XCTAssertEqual(store.sessions.first?.state, .completed)

        store.clear()
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testSessionSummaryReflectsCanonicalRecordFields() {
        let startedAt = Date()
        let record = SessionRecord(
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/v1/items",
                headers: [HTTPHeaderField(name: "Host", value: "api.example.com")],
                bodyData: Data("{\"name\":\"item\"}".utf8),
                bodySize: 256
            ),
            response: CapturedResponse(
                statusCode: 201,
                headers: [HTTPHeaderField(name: "Content-Length", value: "64")],
                bodyData: Data("{\"id\":1}".utf8),
                bodySize: 64
            ),
            state: .completed,
            timing: SessionTiming(startedAt: startedAt, completedAt: startedAt.addingTimeInterval(0.5))
        )

        let summary = SessionSummary(record: record)

        XCTAssertEqual(summary.method, "POST")
        XCTAssertEqual(summary.scheme, .https)
        XCTAssertEqual(summary.inspectionKind, .plain)
        XCTAssertEqual(summary.host, "api.example.com")
        XCTAssertEqual(summary.statusCode, 201)
        XCTAssertEqual(summary.state, .completed)
        XCTAssertEqual(summary.path, "/v1/items")
        XCTAssertEqual(summary.duration ?? 0.0, 0.5, accuracy: 0.001)
    }

    /// AJ-3: the table/explorer badge reads `SessionSummary.mcpAttribution`, so it must mirror the
    /// canonical record's response attribution exactly — including when there is none.
    func testSessionSummaryCarriesMCPAttribution() {
        let attribution = MCPCaptureAttribution(
            provenance: MCPProvenance(
                clientID: "client-1",
                operationID: "op-1",
                capability: .changeThrottle,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            effectKinds: [.throttle],
            scenarioID: nil,
            measurementContext: nil
        )
        let attributedRecord = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/attributed",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [],
                bodyData: nil,
                bodySize: nil,
                mcpAttribution: attribution
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date().addingTimeInterval(0.1))
        )
        XCTAssertEqual(SessionSummary(record: attributedRecord).mcpAttribution, attribution)

        let plainRecord = SessionRecord(
            request: attributedRecord.request,
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
            state: .completed,
            timing: attributedRecord.timing
        )
        XCTAssertNil(SessionSummary(record: plainRecord).mcpAttribution)
    }

    func testSessionSummaryPreservesTunneledInspectionKind() {
        let record = SessionRecord(
            request: CapturedRequest(
                method: "CONNECT",
                scheme: .https,
                inspectionKind: .tunneledTLS,
                host: "bag.itunes.apple.com",
                port: 443,
                path: "bag.itunes.apple.com:443",
                headers: [HTTPHeaderField(name: "Host", value: "bag.itunes.apple.com:443")],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Connection", value: "close")],
                bodyData: nil,
                bodySize: nil
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date().addingTimeInterval(0.1))
        )

        let summary = SessionSummary(record: record)

        XCTAssertEqual(summary.inspectionKind, .tunneledTLS)
    }

    func testRemoveSelectedSessionsLeavesNonSelectedSessionsIntact() {
        let store = InMemorySessionStore()
        let first = makeSession(host: "api.example.com", path: "/first")
        let second = makeSession(host: "api.example.com", path: "/second")
        let third = makeSession(host: "api.example.com", path: "/third")

        store.append(first)
        store.append(second)
        store.append(third)

        store.remove(ids: [first.id, third.id])

        XCTAssertEqual(store.sessions.map(\.id), [second.id])
    }

    func testUpdateUsesCurrentIndexAfterRemoval() {
        let store = InMemorySessionStore()
        let first = makeSession(host: "api.example.com", path: "/first")
        let second = makeSession(host: "api.example.com", path: "/second")
        let third = makeSession(host: "api.example.com", path: "/third")

        store.append(first)
        store.append(second)
        store.append(third)
        store.remove(ids: [first.id])

        var updatedSecond = second
        updatedSecond.response = CapturedResponse(
            statusCode: 204,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        updatedSecond.state = .completed

        store.update(updatedSecond)

        XCTAssertEqual(store.sessions.map(\.id), [second.id, third.id])
        XCTAssertEqual(store.sessions.first?.response?.statusCode, 204)
        XCTAssertNil(store.sessions.last?.response)
    }

    func testUpdateUsesCurrentIndexAfterRetentionTrim() {
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(2))
        let first = makeSession(host: "api.example.com", path: "/first")
        let second = makeSession(host: "api.example.com", path: "/second")
        let third = makeSession(host: "api.example.com", path: "/third")

        store.append(first)
        store.append(second)
        store.append(third)

        var updatedSecond = second
        updatedSecond.response = CapturedResponse(
            statusCode: 201,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        updatedSecond.state = .completed

        store.update(updatedSecond)

        XCTAssertEqual(store.sessions.map(\.id), [second.id, third.id])
        XCTAssertEqual(store.sessions.first?.response?.statusCode, 201)
        XCTAssertNil(store.sessions.last?.response)
        XCTAssertEqual(store.droppedSessionCount, 1)
    }

    func testUpdateUsesCorrectIndexAfterMultipleRetentionDrops() {
        // Appending 6 sessions into a cap-2 store triggers 4 individual drops,
        // exercising the indexOffset accumulation path that replaced rebuildSessionIndex().
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(2))

        var sessions: [SessionRecord] = (0..<6).map {
            makeSession(host: "example.com", path: "/s\($0)")
        }
        sessions.forEach { store.append($0) }

        // After 6 appends into a cap-2 store, only the last two remain.
        XCTAssertEqual(store.sessions.map(\.id), [sessions[4].id, sessions[5].id])
        XCTAssertEqual(store.droppedSessionCount, 4)

        // Update the second-to-last session (sessions[4]) and confirm it lands correctly.
        var updated = sessions[4]
        updated.response = CapturedResponse(statusCode: 299, headers: [], bodyData: nil, bodySize: nil)
        updated.state = .completed
        store.update(updated)

        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions.first?.id, sessions[4].id)
        XCTAssertEqual(store.sessions.first?.response?.statusCode, 299)
        XCTAssertEqual(store.sessions.last?.id, sessions[5].id)
        XCTAssertNil(store.sessions.last?.response)
    }

    func testSessionStorePublishesIncrementalChanges() {
        let store = InMemorySessionStore()
        let first = makeSession(host: "api.example.com", path: "/first")
        let second = makeSession(host: "api.example.com", path: "/second")
        let third = makeSession(host: "api.example.com", path: "/third")
        var updatedFirst = first
        updatedFirst.response = CapturedResponse(
            statusCode: 200,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        var updatedThird = third
        updatedThird.response = CapturedResponse(
            statusCode: 201,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        var changes: [SessionStoreChange] = []
        let expectation = XCTestExpectation(description: "store changes observed")
        expectation.expectedFulfillmentCount = 7

        store.sessionChangesPublisher
            .sink { change in
                changes.append(change)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        store.append(first)
        store.update(updatedFirst)
        store.update([updatedFirst])
        store.remove(ids: [first.id])
        store.load(sessions: [second])
        store.update([updatedThird])
        store.clear()

        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(changes[0], .appended(first, droppedIDs: []))
        XCTAssertEqual(changes[1], .updated(updatedFirst, inserted: false))
        XCTAssertEqual(changes[2], .updatedBatch([updatedFirst], insertedIDs: []))
        XCTAssertEqual(changes[3], .removed(ids: [first.id]))
        XCTAssertEqual(changes[4], .loaded(sessions: [second], reason: "capture_loaded"))
        XCTAssertEqual(changes[5], .updatedBatch([updatedThird], insertedIDs: [third.id]))
        XCTAssertEqual(changes[6], .cleared)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testBatchUpdateReplacesExistingSessionsAndTracksBodyBytesOnce() {
        let store = InMemorySessionStore()
        let first = makeSession(host: "api.example.com", path: "/first", responseBody: Data("old".utf8))
        let second = makeSession(host: "api.example.com", path: "/second", responseBody: Data("second".utf8))
        let third = makeSession(host: "api.example.com", path: "/third", responseBody: Data("third".utf8))
        let updatedFirst = makeSession(id: first.id, host: "api.example.com", path: "/first", responseBody: Data("updated".utf8))

        var changes: [SessionStoreChange] = []
        let expectation = XCTestExpectation(description: "batch update observed")
        expectation.expectedFulfillmentCount = 3

        store.sessionChangesPublisher
            .sink { change in
                changes.append(change)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        store.append(first)
        store.append(second)
        store.update([updatedFirst, third])

        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(store.sessions.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(store.sessions[0].response?.bodyData, Data("updated".utf8))
        XCTAssertEqual(store.retainedBodyBytes, "updated".utf8.count + "second".utf8.count + "third".utf8.count)
        XCTAssertEqual(changes[2], .updatedBatch([updatedFirst, third], insertedIDs: [third.id]))
    }

    func testAppendPublishesDroppedIDsWhenRetentionTrimsSessions() {
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(2))
        let first = makeSession(host: "api.example.com", path: "/first")
        let second = makeSession(host: "api.example.com", path: "/second")
        let third = makeSession(host: "api.example.com", path: "/third")

        var changes: [SessionStoreChange] = []
        let expectation = XCTestExpectation(description: "store changes observed")
        expectation.expectedFulfillmentCount = 3

        store.sessionChangesPublisher
            .sink { change in
                changes.append(change)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        store.append(first)
        store.append(second)
        store.append(third)

        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(changes[0], .appended(first, droppedIDs: []))
        XCTAssertEqual(changes[1], .appended(second, droppedIDs: []))
        XCTAssertEqual(changes[2], .appended(third, droppedIDs: [first.id]))
        XCTAssertEqual(store.sessions.map(\.id), [second.id, third.id])
    }

    func testCombinedRetentionDropsSessionsThenStripsBodiesAndHandlesLateUpdates() throws {
        let store = InMemorySessionStore()
        let records = (0..<4).map { index in
            makeSession(host: "api.example.com", path: "/item/\(index)",
                requestBody: Data("abcd".utf8), responseBody: Data("efgh".utf8))
        }
        records.forEach { store.append($0) }
        store.retentionPolicy = .bounded(maxSessions: 2, maxBodyBytes: 8)
        XCTAssertEqual(store.sessions.map(\.id), records.suffix(2).map(\.id))
        XCTAssertEqual(store.droppedSessionCount, 2)
        XCTAssertEqual(store.retainedBodyBytes, 8)
        XCTAssertNil(store.sessions[0].request.bodyData)
        XCTAssertEqual(store.sessions[0].request.bodySize, 4)
        store.update(records[2])
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertLessThanOrEqual(store.retainedBodyBytes, 8)
        let encoded = try JSONEncoder().encode(store.retentionPolicy)
        XCTAssertEqual(try JSONDecoder().decode(CaptureRetentionPolicy.self, from: encoded), store.retentionPolicy)
        store.retentionPolicy = .bounded(maxSessions: 0, maxBodyBytes: 0)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.retainedBodyBytes, 0)
    }

    func testKeepLastBodyBytesStripsOldestBodiesAndPreservesBodyMetadata() {
        let store = InMemorySessionStore(retentionPolicy: .keepLastBodyBytes(8))
        let first = makeSession(
            host: "api.example.com",
            path: "/first",
            requestBody: Data("abcdef".utf8),
            responseBody: Data("ghijkl".utf8),
            bodyTruncated: true,
            responseSource: .localOverride,
            responseSourceDescription: "Mapped from local file"
        )
        let second = makeSession(
            host: "api.example.com",
            path: "/second",
            requestBody: Data("mn".utf8),
            responseBody: Data("op".utf8)
        )

        store.append(first)
        store.append(second)

        XCTAssertLessThanOrEqual(store.retainedBodyBytes, 8)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertNil(store.sessions[0].request.bodyData)
        XCTAssertEqual(store.sessions[0].request.bodySize, 6)
        XCTAssertTrue(store.sessions[0].request.bodyTruncated)
        XCTAssertNil(store.sessions[0].response?.bodyData)
        XCTAssertEqual(store.sessions[0].response?.bodySize, 6)
        XCTAssertTrue(store.sessions[0].response?.bodyTruncated == true)
        XCTAssertEqual(store.sessions[0].response?.source, .localOverride)
        XCTAssertEqual(store.sessions[0].response?.sourceDescription, "Mapped from local file")
        XCTAssertEqual(store.sessions[1].request.bodyData, Data("mn".utf8))
        XCTAssertEqual(store.sessions[1].response?.bodyData, Data("op".utf8))
    }

    func testKeepLastBodyBytesPublishesBodiesStrippedWithStrippedRecords() {
        // Budget fits the first session (12 body bytes) alone; the second append
        // (+4 bytes = 16) exceeds it and strips the first session's bodies.
        let store = InMemorySessionStore(retentionPolicy: .keepLastBodyBytes(14))
        var strippedBatches: [[SessionRecord]] = []
        let cancellable = store.sessionChangesPublisher.sink { change in
            if case .bodiesStripped(let sessions) = change {
                strippedBatches.append(sessions)
            }
        }
        defer { cancellable.cancel() }

        let first = makeSession(
            host: "api.example.com",
            path: "/first",
            requestBody: Data("abcdef".utf8),
            responseBody: Data("ghijkl".utf8)
        )
        let second = makeSession(
            host: "api.example.com",
            path: "/second",
            requestBody: Data("mn".utf8),
            responseBody: Data("op".utf8)
        )

        store.append(first)
        XCTAssertTrue(strippedBatches.isEmpty, "No stripping while under budget")

        store.append(second)

        XCTAssertEqual(strippedBatches.count, 1)
        let stripped = try? XCTUnwrap(strippedBatches.first?.first)
        XCTAssertEqual(stripped?.id, first.id)
        XCTAssertNil(stripped?.request.bodyData, "Published record must be the post-strip copy")
        XCTAssertNil(stripped?.response?.bodyData)
        XCTAssertEqual(stripped?.request.bodySize, 6, "Body size metadata preserved")
        XCTAssertEqual(stripped?.request.recordingBodyOmissionReason, .retentionEvicted)
        XCTAssertEqual(stripped?.response?.recordingBodyOmissionReason, .retentionEvicted)
        XCTAssertEqual(store.evictedBodyCount, 2)
        XCTAssertEqual(store.droppedSessionCount, 0)
        store.retentionPolicy = .keepLastBodyBytes(14)
        XCTAssertEqual(store.evictedBodyCount, 2)
        store.retentionPolicy = .keepLastSessions(1)
        XCTAssertEqual(store.droppedSessionCount, 1)
        XCTAssertEqual(store.evictedBodyCount, 2)
        store.clear()
        XCTAssertEqual(store.evictedBodyCount, 0)
        XCTAssertEqual(store.droppedSessionCount, 0)
    }

    func testKeepLastBodyBytesBoundsRetainedBodiesAcrossHighVolumeCapture() {
        let store = InMemorySessionStore(retentionPolicy: .keepLastBodyBytes(64))

        for index in 0..<1_000 {
            store.append(
                makeSession(
                    host: "api.example.com",
                    path: "/events/\(index)",
                    requestBody: Data("req-\(index)".utf8),
                    responseBody: Data("res-\(index)".utf8)
                )
            )
        }

        XCTAssertEqual(store.sessions.count, 1_000)
        XCTAssertEqual(store.droppedSessionCount, 0)
        XCTAssertLessThanOrEqual(store.retainedBodyBytes, 64)
        XCTAssertNil(store.sessions.first?.request.bodyData)
        XCTAssertNil(store.sessions.first?.response?.bodyData)
        XCTAssertNotNil(store.sessions.last?.request.bodyData)
        XCTAssertNotNil(store.sessions.last?.response?.bodyData)
    }

    func testKeepLastBodyBytesHighVolumeCaptureStaysWithinWallTimeBudget() {
        let store = InMemorySessionStore(retentionPolicy: .keepLastBodyBytes(256))
        let startedAt = Date()

        for index in 0..<5_000 {
            store.append(
                makeSession(
                    host: "api.example.com",
                    path: "/events/\(index)",
                    requestBody: Data("request-body-\(index)".utf8),
                    responseBody: Data("response-body-\(index)".utf8)
                )
            )
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertEqual(store.sessions.count, 5_000)
        XCTAssertLessThanOrEqual(store.retainedBodyBytes, 256)
        XCTAssertLessThan(elapsed, 2.0)
    }

    func testLateBodyUpdatesReenterRetentionAndPublishOnlyCanonicalBodies() {
        let store = InMemorySessionStore(retentionPolicy: .keepLastBodyBytes(4))
        let first = makeSession(host: "api.example.test", path: "/first")
        let second = makeSession(host: "api.example.test", path: "/second", responseBody: Data(repeating: 1, count: 8))
        store.append(first)
        store.append(second)
        var received: [SessionRecord] = []
        let subscription = store.sessionChangesPublisher.sink {
            if case .updated(let record, _) = $0 { received.append(record) }
        }
        defer { subscription.cancel() }
        var completed = first
        completed.response = CapturedResponse(statusCode: 200, headers: [], bodyData: Data(repeating: 2, count: 8), bodySize: 8)
        store.update(completed)
        XCTAssertEqual(store.retainedBodyBytes, 0)
        XCTAssertNil(store.record(for: first.id)?.response?.bodyData)
        XCTAssertEqual(store.record(for: first.id)?.response?.bodySize, 8)
        XCTAssertNil(received.last?.response?.bodyData)
        store.update([completed, second])
        XCTAssertLessThanOrEqual(store.retainedBodyBytes, 4)
    }

    func testUpdateInsertionAndLoadEnforceCountRetention() {
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(1))
        let first = makeSession(host: "api.example.test", path: "/first")
        let second = makeSession(host: "api.example.test", path: "/second")
        store.update([first, second])
        XCTAssertEqual(store.sessions.map(\.id), [second.id])
        store.load(sessions: [first, second])
        XCTAssertEqual(store.sessions.map(\.id), [second.id])
    }

    func testChangingRetentionImmediatelyStripsExistingBodies() {
        let store = InMemorySessionStore()
        let session = makeSession(host: "api.example.test", path: "/body", responseBody: Data(repeating: 1, count: 8))
        store.append(session)
        store.retentionPolicy = .keepLastBodyBytes(4)
        XCTAssertEqual(store.retainedBodyBytes, 0)
        XCTAssertNil(store.record(for: session.id)?.response?.bodyData)
    }

    private func makeSession(
        id: UUID = UUID(),
        host: String,
        path: String,
        requestBody: Data? = nil,
        responseBody: Data? = nil,
        bodyTruncated: Bool = false,
        responseSource: CapturedResponseSource = .upstream,
        responseSourceDescription: String? = nil
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            request: CapturedRequest(
                method: "GET",
                scheme: .http,
                host: host,
                port: 80,
                path: path,
                headers: [HTTPHeaderField(name: "Host", value: host)],
                bodyData: requestBody,
                bodySize: requestBody?.count,
                bodyTruncated: bodyTruncated
            ),
            response: responseBody.map {
                CapturedResponse(
                    statusCode: 200,
                    headers: [],
                    bodyData: $0,
                    bodySize: $0.count,
                    source: responseSource,
                    sourceDescription: responseSourceDescription,
                    bodyTruncated: bodyTruncated
                )
            },
            timing: SessionTiming(startedAt: Date())
        )
    }

    // MARK: - HANG-1: does sustained retention-eviction pressure exercise the caller-fallback path?

    /// `append`'s per-session eviction under `.sessionLimit` retention calls
    /// `DeferredRelease.schedule(dropped)` on every single append once the limit is reached — and
    /// every real call site does so from inside `ProxySessionRecorder`'s `MainActor.run` batch
    /// drain (`drainStoreQueue()`), not a background context. This measures, against the real
    /// process-wide `DeferredRelease` queue (not a test double — the actual mechanism the incident
    /// would have exercised), whether a realistic ~10,000-session sustained-eviction workload ever
    /// saturates the queue's 8-slot limit and falls back to releasing on the calling thread.
    ///
    /// `DeferredRelease.metrics` is global process state; this test only asserts on the *delta*
    /// across the workload, so pollution from other tests running earlier in the same process
    /// cannot produce a false pass or false fail here.
    func testSustainedRetentionEvictionAgainstRealDeferredReleaseQueue() {
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(500))
        let before = DeferredRelease.metrics

        // Steady-state single-session eviction, the actual incident shape (continuous streaming,
        // not a bulk Clear) — one session appended, one oldest session evicted, 10,000 times.
        for i in 0..<10_000 {
            store.append(makeSession(host: "example.test", path: "/segment/\(i)"))
        }

        let after = DeferredRelease.metrics
        let scheduledDelta = after.scheduledCount - before.scheduledCount
        let fallbackDelta = after.callerFallbackCount - before.callerFallbackCount
        let fallbackDurationDelta = after.totalCallerFallbackDuration - before.totalCallerFallbackDuration

        XCTAssertEqual(store.sessions.count, 500, "retention actually enforced across the run")
        XCTAssertEqual(
            scheduledDelta + fallbackDelta, 9_500,
            "one eviction per append past the 500-session limit (10,000 - 500), regardless of which path each one took"
        )
        // HANG-1 finding (measured, not assumed): under this workload the 8-slot queue does
        // saturate — a handful of the 9,500 evictions fall back to synchronous caller-thread
        // release — but the measured cost is sub-microsecond total (~1µs across all fallbacks in
        // repeated runs), because a single small `SessionRecord`'s deinit is cheap regardless of
        // which thread runs it. The mechanism is real; at this payload size it is not expensive.
        // This is a regression guard, not a repeat of the one-time discovery: it fails only if a
        // future change makes the fallback path itself become slow, not merely if it fires at all.
        XCTAssertLessThan(
            fallbackDurationDelta, 0.05,
            "caller-thread fallback releases became unexpectedly expensive for small session records"
        )
    }

    /// Same mechanism, but with response bodies shaped like real streaming traffic rather than
    /// empty ones — the incident report describes active HLS-style playback, not an idle capture.
    /// This is the test that actually answers "could this mechanism explain a multi-second hang,"
    /// not just "does the fallback path get exercised at all."
    func testSustainedRetentionEvictionWithRealisticBodySizesAgainstRealDeferredReleaseQueue() {
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(500))
        let before = DeferredRelease.metrics

        // ~180KB is a representative HLS media-segment response size; small manifests are smaller,
        // but this is a deliberately realistic-to-generous per-session body, not a worst case.
        // Each session gets a genuinely distinct buffer, not one shared COW value repeated 10,000
        // times — real captured responses never share buffer identity, and a shared buffer would
        // make every eviction but the very last a cheap refcount decrement rather than a real free.
        for i in 0..<10_000 {
            let segmentBody = Data(repeating: UInt8(i % 256), count: 180 * 1024)
            store.append(makeSession(host: "example.test", path: "/segment/\(i)", responseBody: segmentBody))
        }

        let after = DeferredRelease.metrics
        let fallbackDurationDelta = after.totalCallerFallbackDuration - before.totalCallerFallbackDuration

        // HANG-1 finding (measured): 180KB response bodies produce essentially the same
        // sub-microsecond fallback cost as empty bodies (~0.8µs measured, vs. ~0.9µs for the empty
        // case above) — releasing one `Data` buffer is a single free-class operation, not
        // proportional to its byte count, so per-session body size does not turn this mechanism
        // into a plausible explanation for a multi-second hang. HANG-1's `SessionStore`/
        // `DeferredReleaseQueue` lead is measured and ruled out at realistic single-record scale;
        // `clear()`'s all-sessions-at-once retirement (a fundamentally larger single payload) is
        // the one still-open variant of this same lead, not yet measured here.
        XCTAssertEqual(store.sessions.count, 500)
        XCTAssertLessThan(
            fallbackDurationDelta, 0.05,
            "caller-thread fallback releases became unexpectedly expensive for realistic streaming body sizes"
        )
    }

    /// HANG-1, the `clear()` variant: unlike per-record eviction (many small retirements), `clear()`
    /// hands `DeferredRelease.schedule` exactly one retirement holding *every* currently-retained
    /// session at once — for a ~10,000-session Compact capture, that is a single, much larger
    /// payload than anything the append-eviction measurements above covered. This uses a local
    /// `DeferredReleaseQueue` (not the process-wide `DeferredRelease` singleton `SessionStore`
    /// actually calls) specifically so the queue can be deterministically saturated first — forcing
    /// exactly the scenario a real Clear would hit if it happened to land while the shared queue's
    /// 8 slots were already busy with unrelated retirements from concurrent capture activity.
    func testClearVariantMeasuresCallerFallbackCostForATenThousandSessionRetirement() {
        struct RetiredStorageShape: Sendable {
            let sessions: [SessionRecord]
            let indexByID: [SessionRecord.ID: Int]
        }
        // Never drains — the one slot stays occupied for the whole test, so the second schedule()
        // call below is guaranteed to fall back, deterministically, without a race.
        let queue = DeferredReleaseQueue(limit: 1) { _ in }
        queue.schedule(0)
        XCTAssertEqual(queue.pendingCount, 1, "the slot is occupied before the real retirement arrives")

        var sessions: [SessionRecord] = []
        sessions.reserveCapacity(10_000)
        var indexByID: [SessionRecord.ID: Int] = [:]
        for i in 0..<10_000 {
            // A genuinely distinct 180KB buffer per session, not one shared COW value repeated
            // 10,000 times — real captured responses never share buffer identity across requests,
            // and an earlier version of this test that did share one buffer measured an
            // implausibly cheap release (freeing one shared buffer once, not ~1.8GB of real memory).
            let segmentBody = Data(repeating: UInt8(i % 256), count: 180 * 1024)
            let session = makeSession(host: "example.test", path: "/segment/\(i)", responseBody: segmentBody)
            sessions.append(session)
            indexByID[session.id] = i
        }
        let retirement = RetiredStorageShape(sessions: sessions, indexByID: indexByID)

        queue.schedule(retirement)

        XCTAssertEqual(queue.metrics.scheduledCount, 1, "only the placeholder was admitted; it occupies the one slot")
        XCTAssertEqual(queue.metrics.callerFallbackCount, 1, "the 10,000-session retirement fell back, as designed by this test")
        // HANG-1 clear() finding: unlike the sub-microsecond per-record case, releasing an entire
        // ~10,000-session-with-bodies array plus its index dictionary in one call is a fundamentally
        // bigger single release. This assertion is a real regression bound, not a guessed one: 50ms
        // synchronous main-actor work is already a user-visible stutter, and this is testing whether
        // this exact mechanism can plausibly reach that — not whether it merely exists.
        NSLog("HANG-1 clear() variant measured: caller-fallback release of a 10,000-session retirement took %.6fs", queue.metrics.maxCallerFallbackDuration)
        XCTAssertLessThan(
            queue.metrics.maxCallerFallbackDuration, 0.05,
            "releasing a full ~10,000-session retirement on the caller thread took \(queue.metrics.maxCallerFallbackDuration)s — long enough to be a user-visible stutter if this ever runs on the main actor"
        )
    }
}
