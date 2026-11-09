import XCTest
@testable import JoesProxy

/// AN-3: scoped observation index, absence evidence, cursors, and redaction.
@MainActor
final class DiagnosticRunObservationTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    func testScopeIsolationIgnoresAmbientTraffic() async throws {
        let (coordinator, index) = makeStack()
        let run = try await startHTTPRun(coordinator, path: "/v1/health")
        await ingest(event(host: "other.test", path: "/v1/health"), index: index, coordinator: coordinator)
        await ingest(event(path: "/v1/health"), index: index, coordinator: coordinator)
        let page = try await coordinator.listObservations(
            id: run.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertEqual(page.records.map(\.kind), [.hit])
        XCTAssertEqual(page.records.first?.host, "example.test")
        XCTAssertEqual(coordinator.run(id: run.id)?.observationSummary.matchedRequestCount, 1)
    }

    func testMatcherMissIsDistinctFromHitAndAmbient() async throws {
        let (coordinator, index) = makeStack()
        let run = try await startHTTPRun(coordinator, path: "/v1/health")
        await ingest(event(path: "/v1/other"), index: index, coordinator: coordinator)
        await ingest(event(host: "ambient.test", path: "/v1/health"), index: index, coordinator: coordinator)
        let page = try await coordinator.listObservations(
            id: run.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertEqual(page.records.map(\.kind), [.matcherMiss])
        XCTAssertEqual(coordinator.run(id: run.id)?.observationSummary.matcherMissCount, 1)
        XCTAssertEqual(coordinator.run(id: run.id)?.observationSummary.matchedRequestCount, 0)
    }

    func testPrefixIsSegmentAware() async throws {
        let (coordinator, index) = makeStack()
        let run = try await startHTTPRun(coordinator, path: "/v1/items", pathMatch: .prefix)
        await ingest(event(path: "/v1/items/42", sessionID: UUID()), index: index, coordinator: coordinator)
        await ingest(event(path: "/v1/items-old", sessionID: UUID()), index: index, coordinator: coordinator)
        let page = try await coordinator.listObservations(
            id: run.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertEqual(page.records.map(\.kind), [.hit, .matcherMiss])
    }

    func testMarkerWindowAbsenceVersusMiss() async throws {
        let (coordinator, index) = makeStack()
        let run = try await startHTTPRun(coordinator, path: "/v1/health")
        let markerA = UUID()
        let markerB = UUID()
        await ingest(markerEvent(id: markerA, at: clock), index: index, coordinator: coordinator)
        clock = clock.addingTimeInterval(1)
        await ingest(event(path: "/v1/other", sessionID: UUID(), at: clock), index: index, coordinator: coordinator)
        clock = clock.addingTimeInterval(1)
        await ingest(markerEvent(id: markerB, at: clock), index: index, coordinator: coordinator)

        let missPage = try await coordinator.listObservations(
            id: run.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            afterMarker: markerA,
            beforeMarker: markerB
        )
        XCTAssertEqual(missPage.records.map(\.kind), [.matcherMiss])

        let run2 = try await startHTTPRun(coordinator, path: "/v1/health", summary: "second")
        let markerC = UUID()
        let markerD = UUID()
        await ingest(markerEvent(id: markerC, at: clock), index: index, coordinator: coordinator)
        clock = clock.addingTimeInterval(1)
        await ingest(event(host: "ambient.test", path: "/v1/health", sessionID: UUID(), at: clock), index: index, coordinator: coordinator)
        clock = clock.addingTimeInterval(1)
        await ingest(markerEvent(id: markerD, at: clock), index: index, coordinator: coordinator)
        let absencePage = try await coordinator.listObservations(
            id: run2.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            afterMarker: markerC,
            beforeMarker: markerD
        )
        XCTAssertEqual(absencePage.records.map(\.kind), [.absence])
    }

    func testCursorExpiresAfterCaptureEpochChange() async throws {
        let (coordinator, index) = makeStack()
        let run = try await startHTTPRun(coordinator, path: "/v1/health")
        await ingest(event(path: "/v1/health", epoch: .initial), index: index, coordinator: coordinator)
        let first = try await coordinator.listObservations(
            id: run.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            limit: 1
        )
        let cursor = try XCTUnwrap(first.nextCursor ?? DiagnosticObservationCursor(
            runID: run.id,
            ownerID: DiagnosticRunOwner.localUserOwnerID,
            captureEpoch: .initial,
            lastSequence: first.records.last?.sequence ?? 0
        ))
        let epochResult = await index.noteCaptureEpochChange(
            to: MCPCaptureEpoch(rawValue: "capture-epoch-1"),
            reason: .captureEpochChanged,
            at: clock
        )
        coordinator.applyObservationSummaries(epochResult.updatedSummaries)
        do {
            _ = try await coordinator.listObservations(
                id: run.id,
                requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
                cursor: cursor
            )
            XCTFail("expected cursorExpired")
        } catch {
            XCTAssertEqual(error as? DiagnosticRunError, .cursorExpired)
        }
        let fresh = try await coordinator.listObservations(
            id: run.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertEqual(fresh.evidenceUnavailableReason, .captureEpochChanged)
        XCTAssertTrue(fresh.records.contains { $0.kind == .captureUnavailable })
    }

    func testNotificationCoalescingAndDisconnect() async throws {
        let (coordinator, index) = makeStack()
        let run = try await startHTTPRun(coordinator, path: "/v1/health")
        let subscriberID = try await coordinator.subscribeObservations(
            id: run.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        await ingest(event(path: "/v1/health", sessionID: UUID()), index: index, coordinator: coordinator)
        await ingest(event(path: "/v1/health", sessionID: UUID()), index: index, coordinator: coordinator)
        let notification = await coordinator.drainObservationNotifications(subscriberID: subscriberID)
        XCTAssertEqual(notification?.runID, run.id)
        XCTAssertEqual(notification?.droppedEventCount, 0)
        let secondDrain = await coordinator.drainObservationNotifications(subscriberID: subscriberID)
        XCTAssertNil(secondDrain)

        await coordinator.unsubscribeObservations(subscriberID)
        await ingest(event(path: "/v1/health", sessionID: UUID()), index: index, coordinator: coordinator)
        let afterUnsubscribe = await coordinator.drainObservationNotifications(subscriberID: subscriberID)
        XCTAssertNil(afterUnsubscribe)
    }

    func testBackpressureDropsNewestAndIncrementsCount() async throws {
        let index = DiagnosticRunObservationIndex()
        let installer = DiagnosticRunObservationWatchInstaller(index: index)
        let coordinator = DiagnosticRunCoordinator(
            store: DiagnosticRunStore(
                persistenceURL: temporaryStoreURL(),
                clock: { [unowned self] in self.clock }
            ),
            watchInstaller: installer,
            observationIndex: index,
            clock: { [unowned self] in self.clock }
        )
        await coordinator.bootstrap()
        let run = try await startHTTPRun(coordinator, path: "/v1/health")
        for _ in 0..<(DiagnosticRunBudget.maxLiveObservationsPerRun + 3) {
            await ingest(event(path: "/v1/health", sessionID: UUID()), index: index, coordinator: coordinator)
        }
        let page = try await coordinator.listObservations(
            id: run.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            limit: DiagnosticRunBudget.observationPageMax
        )
        XCTAssertEqual(page.droppedObservationCount, 3)
        XCTAssertEqual(
            coordinator.run(id: run.id)?.observationSummary.matchedRequestCount,
            DiagnosticRunBudget.maxLiveObservationsPerRun + 3
        )
    }

    func testObservationsRedactBodiesHeadersAndQuery() async throws {
        let (coordinator, index) = makeStack()
        let run = try await startHTTPRun(coordinator, path: "/v1/health")
        var capture = event(path: "/v1/health")
        capture.path = DiagnosticRunScopeMatcher.pathExcludingQuery("/v1/health?token=secret")
        await ingest(capture, index: index, coordinator: coordinator)
        let page = try await coordinator.listObservations(
            id: run.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        let record = try XCTUnwrap(page.records.first)
        XCTAssertEqual(record.path, "/v1/health")
        XCTAssertFalse(record.path?.contains("?") == true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("bodyData"))
        XCTAssertFalse(json.contains("Authorization"))
        XCTAssertFalse(json.contains("token=secret"))
        XCTAssertFalse(json.contains("headers"))
    }

    func testCloseRecordsAbsenceWhenNoTrafficMatched() async throws {
        let (coordinator, index) = makeStack()
        let run = try await startHTTPRun(coordinator, path: "/v1/health")
        await ingest(event(host: "ambient.test", path: "/v1/health"), index: index, coordinator: coordinator)
        let closed = try await coordinator.close(
            id: run.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID,
            requestedTerminal: .inconclusive,
            conclusion: DiagnosticRunConclusion(
                outcome: .inconclusive,
                reasonCode: .noRequest,
                summary: "No matching request in the window.",
                confidence: .medium,
                concludedAt: clock,
                evidenceDigest: "abc"
            )
        )
        XCTAssertEqual(closed.status, .inconclusive)
        let page = try await coordinator.listObservations(
            id: run.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
        XCTAssertTrue(page.records.contains { $0.kind == .absence })
    }

    func testOwnershipIsolationOnObservationRead() async throws {
        let (coordinator, _) = makeStack()
        let run = try await startHTTPRun(coordinator, path: "/v1/health")
        do {
            _ = try await coordinator.listObservations(
                id: run.id,
                requestingOwnerID: "other-client"
            )
            XCTFail("expected notOwner")
        } catch {
            XCTAssertEqual(error as? DiagnosticRunError, .notOwner)
        }
    }

    func testCapturedSessionStaleEpochRejectedAtInstall() async throws {
        let sessionStore = InMemorySessionStore()
        let session = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "example.test",
                port: 443,
                path: "/v1/health",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: 0),
            state: .completed,
            timing: SessionTiming(startedAt: clock, completedAt: clock)
        )
        sessionStore.append(session)
        let fingerprint = try DiagnosticRunValidation.requestFingerprint(
            method: "GET",
            scheme: .https,
            host: "example.test",
            port: 443,
            path: "/v1/health"
        )
        let index = DiagnosticRunObservationIndex()
        let installer = DiagnosticRunObservationWatchInstaller(
            index: index,
            sessionStore: sessionStore
        )
        let snapshot = MCPSessionSnapshotService(sessionStore: sessionStore)
        installer.snapshotService = snapshot
        let coordinator = DiagnosticRunCoordinator(
            store: DiagnosticRunStore(
                persistenceURL: temporaryStoreURL(),
                clock: { [unowned self] in self.clock }
            ),
            watchInstaller: installer,
            observationIndex: index,
            clock: { [unowned self] in self.clock }
        )
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: DiagnosticRunHypothesis(
                summary: "Follow this session fingerprint.",
                expectedObservation: "Same request is observed again.",
                source: .localUser
            ),
            scopes: [.capturedSession(DiagnosticCapturedSessionScope(
                sessionID: session.id,
                captureEpoch: MCPCaptureEpoch(rawValue: "not-the-current-epoch"),
                requestFingerprint: fingerprint
            ))]
        )
        do {
            _ = try await coordinator.startWatching(
                id: draft.id,
                requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
            )
            XCTFail("expected staleTarget")
        } catch {
            guard case DiagnosticRunError.staleTarget = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(coordinator.run(id: draft.id)?.status, .draft)
        }
    }

    // MARK: - Helpers

    private func makeStack() -> (DiagnosticRunCoordinator, DiagnosticRunObservationIndex) {
        let index = DiagnosticRunObservationIndex()
        let installer = DiagnosticRunObservationWatchInstaller(index: index)
        let coordinator = DiagnosticRunCoordinator(
            store: DiagnosticRunStore(
                persistenceURL: temporaryStoreURL(),
                clock: { [unowned self] in self.clock }
            ),
            watchInstaller: installer,
            observationIndex: index,
            clock: { [unowned self] in self.clock }
        )
        return (coordinator, index)
    }

    private func startHTTPRun(
        _ coordinator: DiagnosticRunCoordinator,
        path: String,
        pathMatch: DiagnosticPathMatch = .exact,
        summary: String = "Observe health."
    ) async throws -> DiagnosticRun {
        await coordinator.bootstrap()
        let draft = try coordinator.createDraft(
            owner: .localUser,
            hypothesis: DiagnosticRunHypothesis(
                summary: summary,
                expectedObservation: "Matching GET is observed.",
                source: .localUser
            ),
            scopes: [.http(DiagnosticHTTPScope(
                method: "GET",
                scheme: .https,
                host: "example.test",
                port: 443,
                path: path,
                pathMatch: pathMatch
            ))]
        )
        return try await coordinator.startWatching(
            id: draft.id,
            requestingOwnerID: DiagnosticRunOwner.localUserOwnerID
        )
    }

    private func event(
        host: String = "example.test",
        path: String = "/v1/health",
        sessionID: UUID = UUID(),
        epoch: MCPCaptureEpoch = .initial,
        at: Date? = nil
    ) -> DiagnosticRunCaptureEvent {
        DiagnosticRunCaptureEvent(
            sessionID: sessionID,
            captureSequence: 1,
            captureEpoch: epoch,
            method: "GET",
            scheme: .https,
            host: host,
            port: 443,
            path: path,
            statusCode: 200,
            latencyMilliseconds: 12,
            observedAt: at ?? clock,
            isMarker: false,
            attributionIDs: []
        )
    }

    private func markerEvent(id: UUID, at: Date) -> DiagnosticRunCaptureEvent {
        DiagnosticRunCaptureEvent(
            sessionID: id,
            captureSequence: 1,
            captureEpoch: .initial,
            method: CaptureMarkerConstants.method,
            scheme: .https,
            host: CaptureMarkerConstants.host,
            port: 443,
            path: CaptureMarkerConstants.markerPath(name: "probe"),
            statusCode: 204,
            latencyMilliseconds: 0,
            observedAt: at,
            isMarker: true,
            attributionIDs: []
        )
    }

    private func ingest(
        _ event: DiagnosticRunCaptureEvent,
        index: DiagnosticRunObservationIndex,
        coordinator: DiagnosticRunCoordinator
    ) async {
        let result = await index.ingest(event)
        coordinator.applyObservationSummaries(result.updatedSummaries)
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("joesproxy-diagnostic-obs-\(UUID().uuidString).json")
    }
}
