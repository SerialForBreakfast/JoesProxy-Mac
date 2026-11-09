import XCTest
@testable import JoesProxy

final class ProxySessionRecorderTests: XCTestCase {
    func testLongLivedReservationsKeepMetadataFallbackBoundedThroughStalledDelivery() async throws {
        let gate = RecorderDeliveryGate()
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store, beforeStoreDelivery: { await gate.wait() })
        let longLived = try XCTUnwrap(recorder.admitPlaybackFirst(request: makeRequest(path: "/long-lived"),
            responseBodyLimit: 50 * 1_024 * 1_024))
        let longLivedValue = await longLived.session.value
        let pressure = try XCTUnwrap(longLivedValue)
        let admission = try XCTUnwrap(recorder.admitPlaybackFirst(request: makeRequest(path: "/stream"),
            responseBodyLimit: 50 * 1_024 * 1_024))
        XCTAssertEqual(admission.responseBodyLimit, 0)
        let value = await admission.session.value
        let id = try XCTUnwrap(value)
        await recorder.flush()
        await gate.waitForEntry()
        await recorder.completeSession(id: id, response: CapturedResponse(statusCode: 200,
            headers: [], bodyData: nil, bodySize: 10_000_000, bodyTruncated: true))
        XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 2, "Delivery still owns its reservation")
        XCTAssertLessThanOrEqual(recorder.admission.snapshot.reservedBytes, 128 * 1_024 * 1_024)
        await gate.open()
        await recorder.waitForPendingStoreFlush()
        XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 1)
        let record = await MainActor.run { store.record(for: id) }
        XCTAssertEqual(record?.responseCaptureLimitedByPressure, true)
        XCTAssertNil(record?.response?.bodyData)
        XCTAssertEqual(record?.response?.bodySize, 10_000_000)
        await recorder.failSession(id: pressure, message: "Long-lived stream disconnected")
        await recorder.waitForPendingStoreFlush()
        XCTAssertFalse(recorder.admission.snapshot.paused)
        XCTAssertEqual(recorder.admission.snapshot.reservedBytes, 0)
        // Duplicate completion and disconnect must not resurrect/re-reserve a completed request.
        await recorder.failSession(id: id, message: "Late disconnect")
        await recorder.finishCaptureRun()
        XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 0)
    }

    func testReservedLateCompletionAfterClearReleasesWithoutResurrectingHistory() async throws {
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)
        let task = try XCTUnwrap(recorder.admitSession(request: makeRequest(path: "/late-clear"),
            responseBodyLimit: 50 * 1_024 * 1_024))
        let value = await task.value
        let id = try XCTUnwrap(value)
        await recorder.waitForPendingStoreFlush()
        await MainActor.run { store.clear() }
        await recorder.completeSession(id: id, response: CapturedResponse(statusCode: 200,
            headers: [], bodyData: Data([1]), bodySize: 1))
        await recorder.waitForPendingStoreFlush()
        let count = await MainActor.run { store.sessions.count }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 0)
        XCTAssertEqual(recorder.admission.snapshot.reservedBytes, 0)
    }
    func testLargeLimitRecoversWhileCompletedRecordWaitsForStoreDelivery() async throws {
        let gate = RecorderDeliveryGate()
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store, beforeStoreDelivery: { await gate.wait() })
        let task = try XCTUnwrap(recorder.admitSession(request: makeRequest(path: "/large-limit"),
            responseBodyLimit: 50 * 1_024 * 1_024))
        let value = await task.value
        let id = try XCTUnwrap(value)
        await recorder.flush()
        await gate.waitForEntry()
        XCTAssertNil(recorder.admitSession(request: makeRequest(path: "/rejected"),
            responseBodyLimit: 50 * 1_024 * 1_024))
        XCTAssertTrue(recorder.admission.snapshot.paused)
        await recorder.completeSession(id: id, response: CapturedResponse(statusCode: 200,
            headers: [], bodyData: Data([1, 2, 3]), bodySize: 3))
        let queued = recorder.admission.snapshot
        XCTAssertFalse(queued.paused, "Completion must recover without another request")
        XCTAssertEqual(queued.pendingCaptures, 1, "Store still owns pending capture work")
        XCTAssertEqual(queued.storeDeliveryCount, 1)
        XCTAssertLessThan(queued.reservedBytes, 128 * 1_024)
        await gate.open()
        await recorder.waitForPendingStoreFlush()
        XCTAssertEqual(recorder.admission.snapshot.reservedBytes, 0)
        let body = await MainActor.run { store.record(for: id)?.response?.bodyData }
        XCTAssertEqual(body, Data([1, 2, 3]))
    }

    func testRepeatedLargeLimitCompletionAndStopDrainsReservations() async throws {
        let recorder = ProxySessionRecorder(sessionStore: InMemorySessionStore())
        for cycle in 0..<20 {
            await recorder.startCaptureRun()
            let task = try XCTUnwrap(recorder.admitSession(request: makeRequest(path: "/cycle/\(cycle)"),
                responseBodyLimit: 50 * 1_024 * 1_024))
            let value = await task.value
            let id = try XCTUnwrap(value)
            if cycle.isMultiple(of: 2) {
                await recorder.completeSession(id: id, response: CapturedResponse(statusCode: 200,
                    headers: [], bodyData: Data([42]), bodySize: 1))
            } else {
                await recorder.failSession(id: id, message: "Synthetic disconnect")
            }
            await recorder.finishCaptureRun()
            XCTAssertEqual(recorder.admission.snapshot.reservedBytes, 0)
            XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 0)
            XCTAssertFalse(recorder.admission.snapshot.paused)
        }
    }
    func testLiveCompletionCannotResurrectClearedSession() async {
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)
        let id = await recorder.beginSession(request: makeRequest(path: "/clear"))
        await recorder.waitForPendingStoreFlush()
        await MainActor.run { store.clear() }
        await recorder.completeSession(id: id, response: CapturedResponse(statusCode: 200,
            headers: [], bodyData: Data(repeating: 1, count: 32), bodySize: 32))
        await recorder.waitForPendingStoreFlush()
        let count = await MainActor.run { store.sessions.count }
        XCTAssertEqual(count, 0)
    }

    func testLiveCompletionCannotResurrectEvictedSession() async {
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(1))
        let recorder = ProxySessionRecorder(sessionStore: store)
        let old = await recorder.beginSession(request: makeRequest(path: "/old"))
        let newest = await recorder.beginSession(request: makeRequest(path: "/new"))
        await recorder.waitForPendingStoreFlush()
        await recorder.completeSession(id: old, response: CapturedResponse(statusCode: 200,
            headers: [], bodyData: Data([1]), bodySize: 1))
        await recorder.waitForPendingStoreFlush()
        let ids = await MainActor.run { store.sessions.map(\.id) }
        XCTAssertEqual(ids, [newest])
    }

    func testRuntimeAdmissionReservationReleasedAfterCompletionDelivery() async throws {
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)
        let task = recorder.scheduleSession(request: makeRequest(path: "/reserved"), responseBodyLimit: 1_024)
        let possibleID = await task.value
        let id = try XCTUnwrap(possibleID)
        XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 1)
        await recorder.completeSession(id: id, response: CapturedResponse(statusCode: 200,
            headers: [], bodyData: Data([1]), bodySize: 1))
        await recorder.waitForPendingStoreFlush()
        XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 0)
        XCTAssertEqual(recorder.admission.snapshot.reservedBytes, 0)
    }

    func testCompleteSessionPrunesInFlightRecord() async {
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)

        let sessionID = await recorder.beginSession(request: makeRequest(path: "/complete"))
        let countAfterBegin = await recorder.inFlightSessionCount
        XCTAssertEqual(countAfterBegin, 1)

        await recorder.completeSession(
            id: sessionID,
            response: CapturedResponse(
                statusCode: 200,
                headers: [],
                bodyData: nil,
                bodySize: nil
            )
        )
        await recorder.waitForPendingStoreFlush()

        let countAfterComplete = await recorder.inFlightSessionCount
        XCTAssertEqual(countAfterComplete, 0)
        let session = await MainActor.run { store.sessions.first }
        XCTAssertEqual(session?.state, .completed)
        XCTAssertEqual(session?.response?.statusCode, 200)
    }

    func testFailSessionPrunesInFlightRecord() async {
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)

        let sessionID = await recorder.beginSession(request: makeRequest(path: "/fail"))
        let countAfterBegin = await recorder.inFlightSessionCount
        XCTAssertEqual(countAfterBegin, 1)

        await recorder.failSession(id: sessionID, message: "upstream unavailable")
        await recorder.waitForPendingStoreFlush()

        let countAfterFailure = await recorder.inFlightSessionCount
        XCTAssertEqual(countAfterFailure, 0)
        let expectedFailureMessage = NetworkFailureClassifier.presentation(forMessage: "upstream unavailable").userFacingMessage
        let session = await MainActor.run { store.sessions.first }
        XCTAssertEqual(session?.state, .failed)
        XCTAssertEqual(session?.failure?.message, expectedFailureMessage)
    }

    func testCompletingManySmallTextResponsesDoesNotLeaveInFlightRecords() async {
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)
        var expectedRetainedBodyBytes = 0

        for index in 0..<500 {
            let sessionID = await recorder.beginSession(request: makeRequest(path: "/events/\(index)"))
            let responseBody = Data("{\"index\":\(index)}".utf8)
            expectedRetainedBodyBytes += responseBody.count

            await recorder.completeSession(
                id: sessionID,
                response: CapturedResponse(
                    statusCode: 200,
                    headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                    bodyData: responseBody,
                    bodySize: responseBody.count
                )
            )
        }
        await recorder.waitForPendingStoreFlush()

        let inFlightCount = await recorder.inFlightSessionCount
        XCTAssertEqual(inFlightCount, 0)
        let sessions = await MainActor.run { store.sessions }
        let retainedBytes = await MainActor.run { store.retainedBodyBytes }
        XCTAssertEqual(sessions.count, 500)
        XCTAssertTrue(sessions.allSatisfy { $0.state == .completed })
        XCTAssertEqual(retainedBytes, expectedRetainedBodyBytes)
    }

    func testShutdownDrainsReservationsAndLateCompletionCannotReopenRun() async throws {
        let store = InMemorySessionStore()
        let recorder = ProxySessionRecorder(sessionStore: store)
        let task = try XCTUnwrap(recorder.admitSession(request: makeRequest(path: "/shutdown"), responseBodyLimit: 1_024))
        let value = await task.value
        let id = try XCTUnwrap(value)
        await recorder.finishCaptureRun()
        XCTAssertEqual(recorder.admission.snapshot.pendingCaptures, 0)
        XCTAssertNil(recorder.admitSession(request: makeRequest(path: "/stopped"), responseBodyLimit: 0))
        await recorder.completeSession(id: id, response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil))
        await recorder.waitForPendingStoreFlush()
        XCTAssertEqual(store.record(for: id)?.state, .failed)
        await recorder.startCaptureRun()
        let next = recorder.admitSession(request: makeRequest(path: "/next"), responseBodyLimit: 0)
        XCTAssertNotNil(next)
        _ = await next?.value
        await recorder.finishCaptureRun()
        XCTAssertEqual(recorder.admission.snapshot.reservedBytes, 0)
    }

    private func makeRequest(path: String) -> CapturedRequest {
        CapturedRequest(
            method: "GET",
            scheme: .http,
            host: "example.com",
            port: 80,
            path: path,
            headers: [HTTPHeaderField(name: "Host", value: "example.com")],
            bodyData: nil,
            bodySize: nil
        )
    }
}

private actor RecorderDeliveryGate {
    private var opened = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }

    func waitForEntry() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
