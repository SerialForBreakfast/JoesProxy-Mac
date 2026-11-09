import XCTest
@testable import JoesProxy

@MainActor
final class MediaMemoryHardeningTests: XCTestCase {
    func testAnalysisSaturationRejectsNewWorkAndCancellationHoldsSlotUntilExit() async {
        let budget = MediaInspectionWorkBudget()
        let entered = expectation(description: "Both parser slots occupied")
        entered.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        let first = Task {
            await budget.run { entered.fulfill(); release.wait(); return 1 }
        }
        let second = Task {
            await budget.run { entered.fulfill(); release.wait(); return 2 }
        }
        await fulfillment(of: [entered], timeout: 5)
        first.cancel()
        let rejected = await budget.run { 3 }
        XCTAssertNil(rejected)
        release.signal()
        release.signal()
        let cancelled = await first.value
        _ = await second.value
        XCTAssertNil(cancelled)
        let resumed = await budget.run { 4 }
        XCTAssertEqual(resumed, 4)
    }

    func testUnrelatedCaptureDoesNotInvalidateManifestIndex() {
        let store = InMemorySessionStore()
        let index = MediaInspectionIndex(store: store)
        let manifest = makeSession(path: "/live.m3u8", text: "#EXTM3U\n")
        store.append(manifest)
        let revision = index.revision
        for number in 0..<1_000 { store.append(makeSession(path: "/segment-\(number).ts", text: "binary")) }
        XCTAssertEqual(index.revision, revision)
        XCTAssertEqual(index.sessions.map(\.id), [manifest.id])
    }

    func testManifestPagesAreBoundedAndOlderCapturesRemainReachable() {
        let store = InMemorySessionStore()
        for number in 0..<140 { store.append(makeSession(path: "/\(number).m3u8", text: "#EXTM3U\n")) }
        let firstID = store.sessions[0].id
        let index = MediaInspectionIndex(store: store)
        XCTAssertEqual(index.sessions.count, 128)
        XCTAssertTrue(index.hasOmittedCandidates)
        index.showOlder()
        XCTAssertTrue(index.sessions.contains { $0.id == firstID })
        index.showLatest()
        XCTAssertEqual(index.sessions.count, 128)
        store.clear()
        XCTAssertTrue(index.sessions.isEmpty)
    }

    func testSameLengthChangedManifestInvalidatesCacheButIdenticalInputDoesNot() async {
        let cache = MediaManifestCache()
        var session = makeSession(path: "/live.m3u8", text: "#EXTM3U\n#EXT-X-TARGETDURATION:6\n")
        _ = await cache.parse([session])
        _ = await cache.parse([session])
        let once = await cache.parseCount
        XCTAssertEqual(once, 1)
        let changed = Data("#EXTM3U\n#EXT-X-TARGETDURATION:9\n".utf8)
        session.response = CapturedResponse(statusCode: 200, headers: [], bodyData: changed, bodySize: changed.count)
        _ = await cache.parse([session])
        let twice = await cache.parseCount
        XCTAssertEqual(twice, 2)
    }

    func testClearRetiresParsedManifestsWithoutAnotherInspectionRequest() async {
        let store = InMemorySessionStore()
        let index = MediaInspectionIndex(store: store)
        store.append(makeSession(path: "/live.m3u8", text: "#EXTM3U\n#EXT-X-TARGETDURATION:6\n"))
        index.manifestModel.request(index.sessions)
        await index.manifestModel.waitForPendingWork()
        XCTAssertEqual(index.manifestModel.result.hls.count, 1)

        store.clear()

        XCTAssertTrue(index.manifestModel.result.hls.isEmpty)
        XCTAssertTrue(index.manifestModel.result.dash.isEmpty)
        await index.manifestModel.waitForPendingWork()
        XCTAssertTrue(index.manifestModel.result.hls.isEmpty)
    }

    func testReplacementCaptureRejectsPendingOldManifestResult() async {
        let store = InMemorySessionStore()
        let index = MediaInspectionIndex(store: store)
        store.append(makeSession(path: "/old.m3u8", text: "#EXTM3U\n#EXT-X-TARGETDURATION:6\n"))
        index.manifestModel.request(index.sessions)
        let replacement = makeSession(path: "/new.m3u8", text: "#EXTM3U\n#EXT-X-TARGETDURATION:9\n")
        store.load(sessions: [replacement], epochChangeReason: "test replacement")
        XCTAssertTrue(index.manifestModel.result.hls.isEmpty)
        index.manifestModel.request(index.sessions)
        await index.manifestModel.waitForPendingWork()
        XCTAssertEqual(index.manifestModel.result.hls.map(\.sessionID), [replacement.id])
    }

    private func makeSession(path: String, text: String) -> SessionRecord {
        let body = Data(text.utf8)
        return SessionRecord(request: CapturedRequest(method: "GET", scheme: .http,
            host: "media.example.test", port: 80, path: path, headers: [], bodyData: nil, bodySize: nil),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: body, bodySize: body.count),
            timing: SessionTiming(startedAt: Date()))
    }
}
