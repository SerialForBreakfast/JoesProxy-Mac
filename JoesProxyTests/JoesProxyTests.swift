import AppKit
import Combine
import XCTest
@testable import JoesProxy

final class ProxyViewModelTests: XCTestCase {
    @MainActor
    func testStartImmediatelyBecomesBusyAndCoalescesRepeatedTaps() async throws {
        let runtime = TestProxyRuntime()
        let identity = try makeRootIdentity(label: "Start-Admission")
        let model = makeViewModel(proxyRuntime: runtime,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed))
        var release: CheckedContinuation<Void, Never>?
        await withCheckedContinuation { started in
            runtime.startOperation = {
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.resume()
                }
            }
            model.startProxy()
            XCTAssertTrue(model.proxyState.isTransitioning)
            XCTAssertFalse(model.canStartProxy)
            model.startProxy()
            model.stopProxy()
        }
        model.startProxy()
        model.stopProxy()
        XCTAssertEqual(runtime.startCallCount, 1)
        XCTAssertEqual(runtime.stopCallCount, 0)
        release?.resume()
    }

    @MainActor
    func testRepeatedClearWhileSnapshotStallsPreservesCurrentCaptureAndSelection() async throws {
        let store = InMemorySessionStore()
        let first = makeSession(method: "GET", host: "example.test", path: "/accepted")
        store.append(first)
        let viewModel = makeViewModel(sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil,
                createdIdentity: try makeRootIdentity(label: "Clear-Admission")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled))
        let gate = ClearSnapshotWriteGate()
        defer { Task { await gate.open() } }
        viewModel.clearSnapshotWriterOverride = { await gate.write($0) }
        XCTAssertEqual(viewModel.clearAllSessions(), .cleared)
        XCTAssertTrue(viewModel.isClearSnapshotPending)
        let current = makeSession(method: "GET", host: "example.test", path: "/keep-until-ready")
        store.append(current)
        try await waitForFilteredSessions(viewModel, expectedCount: 1)
        viewModel.selectedSessionID = current.id
        viewModel.sessionSearchText = "keep-until-ready"
        for _ in 0..<100 { XCTAssertEqual(viewModel.clearAllSessions(), .busy) }
        XCTAssertEqual(store.sessions.map(\.id), [current.id])
        XCTAssertEqual(viewModel.selectedSessionID, current.id)
        XCTAssertEqual(viewModel.sessionSearchText, "keep-until-ready")
        await gate.open()
        await viewModel.waitForClearSnapshot()
        let saved = await gate.snapshots
        XCTAssertEqual(saved, [[first.id]], "Busy attempts must not enqueue or replace snapshots")
        XCTAssertFalse(viewModel.isClearSnapshotPending)
        XCTAssertEqual(viewModel.clearAllSessions(), .cleared)
        await viewModel.waitForClearSnapshot()
        let allSaved = await gate.snapshots
        XCTAssertEqual(allSaved, [[first.id], [current.id]])
        XCTAssertTrue(store.sessions.isEmpty)
    }

    @MainActor
    func testStorageIsolatedClearsDoNotCreateSnapshotTasks() throws {
        let store = InMemorySessionStore()
        let viewModel = makeViewModel(sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil,
                createdIdentity: try makeRootIdentity(label: "Clear-Isolation")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled))
        viewModel.rollingCapturePersistence = RollingCapturePersistenceCoordinator(sessionStore: store,
            configuration: MCPSelfValidationAppConfiguration(), proxyPortProvider: { 9090 }, storageAccessEnabled: false)
        for index in 0..<20 {
            store.append(makeSession(method: "GET", host: "example.test", path: "/\(index)"))
            XCTAssertEqual(viewModel.clearAllSessions(), .cleared)
            XCTAssertFalse(viewModel.isClearSnapshotPending)
        }
    }

    @MainActor
    func testClearAllImmediatelyClearsSelectionAndVisibleSessions() async throws {
        let store = InMemorySessionStore()
        let session = makeSession(method: "GET", host: "example.com", path: "/clear-me")
        store.append(session)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(
                currentIdentity: nil,
                createdIdentity: try makeRootIdentity(label: "Clear-All")
            ),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        try await waitForFilteredSessions(viewModel, expectedCount: 1)
        viewModel.selectedSessionID = session.id

        viewModel.clearAllSessions()
        await Task.yield()

        XCTAssertFalse(viewModel.hasSessions)
        XCTAssertTrue(viewModel.filteredSessions.isEmpty)
        XCTAssertNil(viewModel.selectedSessionID)
        XCTAssertNil(viewModel.selectedSession)
    }

    @MainActor
    func testClearAllSessionsMenuActionAndStateGating() async throws {
        let store = InMemorySessionStore()
        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(
                currentIdentity: nil,
                createdIdentity: try makeRootIdentity(label: "Clear-All-Menu")
            ),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        // Initially no sessions -> hasSessions is false
        XCTAssertFalse(viewModel.hasSessions)

        // Append a session -> hasSessions becomes true
        let session = makeSession(method: "GET", host: "example.com", path: "/test")
        store.append(session)
        try await waitForFilteredSessions(viewModel, expectedCount: 1)
        XCTAssertTrue(viewModel.hasSessions)

        // Clear all -> hasSessions becomes false
        viewModel.clearAllSessions()
        await Task.yield()
        XCTAssertFalse(viewModel.hasSessions)
        XCTAssertEqual(store.sessions.count, 0)
        XCTAssertEqual(viewModel.filteredSessions.count, 0)
    }

    @MainActor
    func testSelectedSessionStaysAnchoredWhenFiltersHideCurrentSelection() async throws {
        let store = InMemorySessionStore()
        let first = makeSession(method: "GET", host: "example.com", path: "/first")
        let second = makeSession(method: "POST", host: "api.example.com", path: "/second")
        store.append(first)
        store.append(second)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Selection-Filter")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.selectSessionFromUser(first.id)
        viewModel.sessionFilterCriteria = SessionFilterCriteria(hostContains: "api", method: nil, scheme: nil, statusMatch: nil)
        try await waitForFilteredSessions(viewModel, expectedCount: 1)

        XCTAssertEqual(viewModel.selectedSession?.id, first.id)
        XCTAssertEqual(viewModel.filteredSessions.map(\.id), [second.id])
    }

    @MainActor
    func testExportSelectedSessionsUsesCurrentSelectionOnly() throws {
        let store = InMemorySessionStore()
        let first = makeSession(method: "GET", host: "example.com", path: "/first")
        let second = makeSession(method: "POST", host: "api.example.com", path: "/second")
        store.append(first)
        store.append(second)

        let exportService = RecordingExportService()
        let viewModel = makeViewModel(
            sessionStore: store,
            exportService: exportService,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Selection-Export")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.selectedSessionID = second.id

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        try viewModel.exportSelectedSessions(to: destinationURL)

        XCTAssertEqual(exportService.exportedEnvelope?.sessionCount, 1)
        XCTAssertEqual(exportService.exportedEnvelope?.sessions.map(\.id), [second.id])
        XCTAssertEqual(exportService.destinationURL, destinationURL)
        XCTAssertEqual(viewModel.exportState, .succeeded(fileName: destinationURL.lastPathComponent))
    }

    @MainActor
    func testExportStateBecomesFailedWhenExporterThrows() throws {
        let store = InMemorySessionStore()
        store.append(makeSession(method: "GET", host: "example.com", path: "/first"))

        let exportService = RecordingExportService(exportError: TestError.message("Disk full"))
        let viewModel = makeViewModel(
            sessionStore: store,
            exportService: exportService,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Selection-Export-Failure")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        let expectedFailureMessage = NetworkFailureClassifier.presentation(
            for: TestError.message("Disk full"),
            surface: .fileExport
        ).userFacingMessage

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        XCTAssertThrowsError(try viewModel.exportAllSessions(to: destinationURL))
        XCTAssertEqual(viewModel.exportState, .failed(message: expectedFailureMessage))
    }

    @MainActor
    func testSessionFindPopulatesResultsWithoutModifyingFilteredSessions() async throws {
        let store = InMemorySessionStore()
        let hidden = makeSession(method: "POST", host: "hidden.example.com", path: "/hidden", requestBody: "secret-token")
        let visible = makeSession(method: "GET", host: "visible.example.com", path: "/visible")
        store.append(hidden)
        store.append(visible)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Find-Filter")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        viewModel.sessionFilterCriteria = SessionFilterCriteria(hostContains: "visible", method: nil, scheme: nil, statusMatch: nil)
        try await waitForFilteredSessions(viewModel, expectedCount: 1)
        XCTAssertEqual(viewModel.filteredSessions.map(\.id), [visible.id])
        let filteredBeforeFind = viewModel.filteredSessions.map(\.id)

        viewModel.sessionFindQuery = "secret-token"
        viewModel.runSessionFind()

        try await waitForSessionFindResults(viewModel, expectedCount: 1)
        XCTAssertEqual(viewModel.sessionFindResults.map(\.sessionID), [hidden.id])
        XCTAssertEqual(viewModel.filteredSessions.map(\.id), filteredBeforeFind)
    }

    @MainActor
    func testSearchFindsUpdatedHeaderValueAfterSessionUpdate() async throws {
        let store = InMemorySessionStore()
        var session = makeSession(method: "GET", host: "api.example.com", path: "/env")
        session.request = CapturedRequest(
            method: "GET",
            scheme: .https,
            inspectionKind: .interceptedTLS,
            host: "api.example.com",
            port: 443,
            path: "/env",
            headers: [HTTPHeaderField(name: "X-Env", value: "staging-zone")],
            bodyData: nil,
            bodySize: nil
        )
        store.append(session)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Search-Invalidate")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        // Prime the lazily built search-text blob for the original header value.
        viewModel.sessionSearchText = "staging-zone"
        try await waitForFilteredSessions(viewModel, expectedCount: 1)

        // Update the session's header (as an override / lifecycle update would).
        var updated = session
        updated.request = CapturedRequest(
            method: "GET",
            scheme: .https,
            inspectionKind: .interceptedTLS,
            host: "api.example.com",
            port: 443,
            path: "/env",
            headers: [HTTPHeaderField(name: "X-Env", value: "production-zone")],
            bodyData: nil,
            bodySize: nil
        )
        store.update(updated)

        // The stale blob must not keep matching the old value…
        try await waitForFilteredSessions(viewModel, expectedCount: 0)

        // …and the new value must be searchable.
        viewModel.sessionSearchText = "production-zone"
        try await waitForFilteredSessions(viewModel, expectedCount: 1)
    }

    @MainActor
    func testBodyTextCacheEvictsOldestGenerationsWhenBudgetOverflows() async throws {
        let store = InMemorySessionStore()
        let older = makeSession(
            method: "POST",
            host: "api.example.com",
            path: "/older",
            requestBody: "alpha-" + String(repeating: "a", count: 30) // 36 bytes cached
        )
        store.append(older)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Find-Cache-Evict")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        // Budget fits one entry: 36 ≤ 40, but 36 + 30 overflows and must evict
        // the older generation (target after eviction: 80% of 40 = 32 bytes).
        viewModel.bodyTextCacheBudgetBytesOverride = 40

        viewModel.sessionFindQuery = "alpha"
        viewModel.runSessionFind()
        try await waitForSessionFindResults(viewModel, expectedCount: 1)
        try await waitForCachedBodyTextIDs(viewModel, expected: [older.id])

        let newer = makeSession(
            method: "POST",
            host: "api.example.com",
            path: "/newer",
            requestBody: "bravo-" + String(repeating: "b", count: 24) // 30 bytes cached
        )
        store.append(newer)
        try await waitForFilteredSessions(viewModel, expectedCount: 2)

        viewModel.sessionFindQuery = "bravo"
        viewModel.runSessionFind()
        try await waitForCachedBodyTextIDs(viewModel, expected: [newer.id])
    }

    @MainActor
    private func waitForCachedBodyTextIDs(
        _ viewModel: ProxyViewModel,
        expected: Set<SessionRecord.ID>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            if viewModel.cachedBodyTextSessionIDs == expected {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(
            "Timed out waiting for body-text cache \(expected); got \(viewModel.cachedBodyTextSessionIDs)",
            file: file,
            line: line
        )
    }

    @MainActor
    func testSelectingSessionFindResultUpdatesSelectedSessionID() async throws {
        let store = InMemorySessionStore()
        let matching = makeSession(method: "POST", host: "api.example.com", path: "/login", requestBody: "find-me")
        store.append(matching)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Find-Selection")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        viewModel.sessionFindQuery = "find-me"
        viewModel.runSessionFind()
        try await waitForSessionFindResults(viewModel, expectedCount: 1)

        viewModel.selectSessionFindResult(try XCTUnwrap(viewModel.sessionFindResults.first))

        XCTAssertEqual(viewModel.selectedSessionID, matching.id)
        XCTAssertEqual(viewModel.selectedSession?.id, matching.id)
        XCTAssertEqual(viewModel.activeFindResultSessionID, matching.id)
        XCTAssertEqual(viewModel.activeFindResultLocation, .requestBody)
        XCTAssertNotNil(viewModel.activeFindNavigationID)
        XCTAssertEqual(
            viewModel.sessionFindBodyMatchContext(for: matching.id, location: .requestBody),
            SessionFindBodyMatchContext(query: "find-me", matchCount: 1)
        )
        XCTAssertNil(viewModel.sessionFindBodyMatchContext(for: matching.id, location: .responseBody))
    }

    @MainActor
    func testSelectingSessionFindResultAgainUpdatesNavigationToken() async throws {
        let store = InMemorySessionStore()
        let matching = makeSession(method: "POST", host: "api.example.com", path: "/login", requestBody: "find-me again find-me")
        store.append(matching)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Find-Repeat-Selection")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        viewModel.sessionFindQuery = "find-me"
        viewModel.runSessionFind()
        try await waitForSessionFindResults(viewModel, expectedCount: 1)

        let result = try XCTUnwrap(viewModel.sessionFindResults.first)
        viewModel.selectSessionFindResult(result)
        let firstToken = viewModel.activeFindNavigationID
        viewModel.selectSessionFindResult(result)

        XCTAssertNotNil(firstToken)
        XCTAssertNotEqual(viewModel.activeFindNavigationID, firstToken)
        XCTAssertEqual(
            viewModel.sessionFindBodyMatchContext(for: matching.id, location: .requestBody),
            SessionFindBodyMatchContext(query: "find-me", matchCount: 2)
        )
    }

    @MainActor
    func testChangingSessionFindQueryClearsStaleResults() async throws {
        let store = InMemorySessionStore()
        let matching = makeSession(method: "POST", host: "api.example.com", path: "/login", requestBody: "find-me")
        store.append(matching)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Find-Clear")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        viewModel.sessionFindQuery = "find-me"
        viewModel.runSessionFind()
        try await waitForSessionFindResults(viewModel, expectedCount: 1)

        viewModel.sessionFindQuery = "different"

        XCTAssertTrue(viewModel.sessionFindResults.isEmpty)
        XCTAssertEqual(viewModel.sessionFindState, .idle)
        XCTAssertNil(viewModel.activeFindResultSessionID)
        XCTAssertNil(viewModel.activeFindResultLocation)
        XCTAssertNil(viewModel.activeFindNavigationID)
        XCTAssertNil(viewModel.sessionFindBodyMatchContext(for: matching.id, location: .requestBody))
    }

    @MainActor
    func testSessionFindCapsVisibleResultsUntilShowMore() async throws {
        let store = InMemorySessionStore()
        let matchingResponseBody = "find-me"
        let matchingResponse = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "text/plain")],
            bodyData: Data(matchingResponseBody.utf8),
            bodySize: matchingResponseBody.utf8.count
        )

        for index in 0..<250 {
            store.append(
                makeSession(
                    method: "GET",
                    host: "api.example.com",
                    path: "/item/\(index)",
                    response: matchingResponse
                )
            )
        }

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Find-Pagination")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.sessionFindQuery = "find-me"
        viewModel.runSessionFind()
        try await waitForSessionFindResults(viewModel, expectedCount: 250)

        XCTAssertEqual(viewModel.sessionFindDisplayedResults.count, 200)
        XCTAssertEqual(viewModel.sessionFindHiddenResultCount, 50)

        viewModel.showMoreSessionFindResults()

        XCTAssertEqual(viewModel.sessionFindDisplayedResults.count, 250)
        XCTAssertEqual(viewModel.sessionFindHiddenResultCount, 0)
    }

    @MainActor
    func testSessionSortAppliesSelectedFieldAndDirection() async throws {
        let store = InMemorySessionStore()
        let zHost = makeSession(method: "GET", host: "zeta.example.com", path: "/z", startedAt: Date(timeIntervalSince1970: 20))
        let aHost = makeSession(method: "POST", host: "alpha.example.com", path: "/a", startedAt: Date(timeIntervalSince1970: 10))
        store.append(aHost)
        store.append(zHost)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Selection-Sort")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        try await waitForFilteredSessions(viewModel, expectedCount: 2)

        // filteredSessions stores oldest-first in fast path; check display layer for user-facing order.
        XCTAssertEqual(viewModel.sessionTableDisplayedSessions.map(\.id), [zHost.id, aHost.id])

        viewModel.sessionSortField = .host
        viewModel.isSessionSortAscending = true

        XCTAssertEqual(viewModel.sessionTableDisplayedSessions.map(\.id), [aHost.id, zHost.id])
    }

    @MainActor
    func testDefaultTimeSortUsesCaptureOrderNewestFirst() async throws {
        let store = InMemorySessionStore()
        let first = makeSession(method: "GET", host: "alpha.example.com", path: "/a", startedAt: Date(timeIntervalSince1970: 10))
        let second = makeSession(method: "GET", host: "beta.example.com", path: "/b", startedAt: Date(timeIntervalSince1970: 20))
        let third = makeSession(method: "GET", host: "gamma.example.com", path: "/c", startedAt: Date(timeIntervalSince1970: 30))
        store.append(first)
        store.append(second)
        store.append(third)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Capture-Order")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        try await waitForFilteredSessions(viewModel, expectedCount: 3)

        // filteredSessions stores oldest-first; sessionTableDisplayedSessions reverses for display.
        XCTAssertEqual(viewModel.sessionSortField, .startedAt)
        XCTAssertFalse(viewModel.isSessionSortAscending)
        XCTAssertEqual(viewModel.sessionTableDisplayedSessions.map(\.id), [third.id, second.id, first.id])

        viewModel.isSessionSortAscending = true

        XCTAssertEqual(viewModel.sessionTableDisplayedSessions.map(\.id), [first.id, second.id, third.id])
    }

    @MainActor
    func testViewModelLoadsPersistedTextSizePreferenceFromConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "TextSize-Load")
        configuration.appTextSizeRawValue = AppTextSize.extraLarge.rawValue

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "TextSize-Load")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        XCTAssertEqual(viewModel.appTextSize, .extraLarge)
    }

    @MainActor
    func testViewModelLoadsPersistedSortPreferencesFromConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Sort-Load")
        configuration.sessionSortFieldRawValue = ProxyViewModel.SessionSortField.host.rawValue
        configuration.isSessionSortAscending = true

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Sort-Load")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        XCTAssertEqual(viewModel.sessionSortField, .host)
        XCTAssertTrue(viewModel.isSessionSortAscending)
    }

    @MainActor
    func testViewModelAppliesAutoScrollPreferenceAtLaunch() throws {
        let configuration = TestAppConfiguration(certificateLabel: "AutoFollow-Load")
        configuration.isSessionAutoScrollEnabled = true

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "AutoFollow-Load")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        XCTAssertTrue(viewModel.isSessionAutoScrollEnabled)
        XCTAssertEqual(viewModel.sessionFollowState, .followingLive)
    }

    @MainActor
    func testRunSetupVerificationMarksProxyStoppedWhenRuntimeIsStopped() throws {
        let runtime = TestProxyRuntime()
        let identity = try makeRootIdentity(label: "Verify-Stopped")
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed)
        )

        viewModel.runSetupVerification()

        XCTAssertEqual(viewModel.setupVerificationState, .proxyStopped)
    }

    @MainActor
    func testRunSetupVerificationMarksInspectedWhenInspectedHTTPSSessionExists() throws {
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))
        let store = InMemorySessionStore()
        store.append(
            makeSession(
                method: "GET",
                host: "api.example.com",
                path: "/v1/test",
                inspectionKind: .interceptedTLS
            )
        )
        let identity = try makeRootIdentity(label: "Verify-Inspected")
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed)
        )

        viewModel.runSetupVerification()

        XCTAssertEqual(viewModel.setupVerificationState, .inspected)
    }

    @MainActor
    func testRunSetupVerificationMarksTunneledWhenOnlyTunneledHTTPSSessionsExist() throws {
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))
        let store = InMemorySessionStore()
        store.append(
            makeSession(
                method: "GET",
                host: "api.example.com",
                path: "/v1/test",
                inspectionKind: .tunneledTLS,
                response: nil
            )
        )
        let identity = try makeRootIdentity(label: "Verify-Tunneled")
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed)
        )

        viewModel.runSetupVerification()

        XCTAssertEqual(viewModel.setupVerificationState, .tunneled)
    }

    @MainActor
    func testRunSetupVerificationMarksNoTrafficObservedWhenProxyIsRunningWithoutHTTPSSessions() throws {
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))
        let identity = try makeRootIdentity(label: "Verify-None")
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed)
        )

        viewModel.runSetupVerification()

        XCTAssertEqual(viewModel.setupVerificationState, .noTrafficObserved)
    }

    @MainActor
    func testViewModelLoadsPersistedExplorerPreferencesFromConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Explorer-Load")
        configuration.sessionBrowserModeRawValue = SessionBrowserMode.explorer.rawValue
        configuration.sessionExplorerGroupingRawValue = SessionExplorerGrouping.byEndpoint.rawValue
        configuration.sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.domainFamilies.rawValue
        configuration.sessionExplorerExpandedNodeIDs = ["host:api.example.com", "host:api.example.com|path:v1"]

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Explorer-Load")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        XCTAssertEqual(viewModel.sessionBrowserMode, .explorer)
        XCTAssertEqual(viewModel.sessionExplorerGrouping, .byEndpoint)
        XCTAssertEqual(viewModel.sessionExplorerHostGrouping, .domainFamilies)
        XCTAssertEqual(viewModel.sessionExplorerExpandedNodeIDs, ["host:api.example.com", "host:api.example.com|path:v1"])
    }

    @MainActor
    func testViewModelLoadsPersistedTimelineBrowserModeFromConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Timeline-Load")
        configuration.sessionBrowserModeRawValue = SessionBrowserMode.timeline.rawValue

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Timeline-Load")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        XCTAssertEqual(viewModel.sessionBrowserMode, .timeline)
    }

    @MainActor
    func testViewModelDefersExplorerRebuildUntilExplorerIsVisible() async throws {
        let store = InMemorySessionStore()
        let first = makeSession(method: "GET", host: "api.example.com", path: "/v1/users/123")
        let second = makeSession(method: "POST", host: "api.example.com", path: "/v1/users/456")

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Explorer-Lazy")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        XCTAssertEqual(viewModel.sessionBrowserMode, .table)
        XCTAssertTrue(viewModel.sessionExplorerTree.isEmpty)

        store.append(first)
        store.append(second)

        try await waitForFilteredSessions(viewModel, expectedCount: 2)

        XCTAssertEqual(viewModel.filteredSessions.count, 2)
        XCTAssertTrue(
            viewModel.sessionExplorerTree.isEmpty,
            "Explorer state should stay cold while the browser is in table mode."
        )

        viewModel.sessionBrowserMode = .explorer
        try await waitForExplorerVisibleRows(viewModel)

        XCTAssertFalse(viewModel.sessionExplorerTree.isEmpty)
        XCTAssertFalse(viewModel.sessionExplorerVisibleRows.isEmpty)
    }

    @MainActor
    func testViewModelLoadsPersistedResponseOverridesFromConfiguration() async throws {
        let configuration = TestAppConfiguration(certificateLabel: "Overrides-Load")
        let persistedStore = ResponseOverrideStore()
        let session = makeSession(method: "GET", host: "api.example.com", path: "/v1/profile")
        _ = try await persistedStore.addCapturedResponseOverride(from: session)
        configuration.responseOverridesData = try await persistedStore.persistedData()

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Overrides-Load")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        await viewModel.initialResponseOverrideLoadTask.value

        XCTAssertEqual(viewModel.responseOverrides.count, 1)
        XCTAssertEqual(viewModel.responseOverrides.first?.host, "api.example.com")
        XCTAssertEqual(viewModel.responseOverrides.first?.path, "/v1/profile")
    }

    @MainActor
    func testViewModelReflectsResponseOverrideCreatedOutsideViewModel() async throws {
        let configuration = TestAppConfiguration(certificateLabel: "Overrides-External")
        let responseOverrideStore = ResponseOverrideStore()
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: responseOverrideStore,
            certificateAuthority: FakeCertificateAuthority(
                currentIdentity: nil,
                createdIdentity: try makeRootIdentity(label: "Overrides-External")
            ),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        await viewModel.initialResponseOverrideLoadTask.value
        let session = makeSession(method: "GET", host: "cdn.example.com", path: "/seal.png")
        _ = try await responseOverrideStore.addCapturedResponseOverride(from: session)

        for _ in 0..<20 where viewModel.responseOverrides.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.responseOverrides.count, 1)
        XCTAssertEqual(viewModel.responseOverrides.first?.host, "cdn.example.com")
    }

    @MainActor
    func testViewModelCreatesBookmarkRewriteRuleAndPersistsOverrides() async throws {
        let configuration = TestAppConfiguration(certificateLabel: "Bookmark-Rewrite")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Rewrite")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        let bookmark = Bookmark(
            name: "Rewrite Profile",
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/v1/profile",
                headers: [HTTPHeaderField(name: "Authorization", value: "Bearer saved")],
                bodyData: Data("bookmark-body".utf8),
                bodySize: "bookmark-body".utf8.count
            )
        )

        try await Task.sleep(nanoseconds: 50_000_000)
        await viewModel.createBookmarkRewriteRule(from: bookmark)

        XCTAssertEqual(viewModel.responseOverrides.count, 1)
        XCTAssertEqual(viewModel.responseOverrides.first?.sourceKind, .bookmarkRewrite)
        XCTAssertEqual(viewModel.responseOverrides.first?.bookmarkRewriteRequest?.path, "/v1/profile")
        XCTAssertNotNil(configuration.responseOverridesData)
    }

    @MainActor
    func testViewModelPersistsUpdatedTextSizePreferenceToConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "TextSize-Save")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "TextSize-Save")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.appTextSize = .accessibility

        XCTAssertEqual(configuration.appTextSizeRawValue, AppTextSize.accessibility.rawValue)
    }

    @MainActor
    func testViewModelRefreshesTextSizeWhenConfigurationChangesExternally() throws {
        let configuration = TestAppConfiguration(certificateLabel: "TextSize-External")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "TextSize-External")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        configuration.appTextSizeRawValue = AppTextSize.large.rawValue
        waitForMainQueueDrain()

        XCTAssertEqual(viewModel.appTextSize, .large)
    }

    @MainActor
    func testSettingsTextSizeEditsReachLiveInspectorWithPersistentConfiguration() async throws {
        let suite = "com.JoesProxyApp.Tests.LiveTextSize.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        let runtime = TestProxyRuntime()
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: runtime,
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil,
                createdIdentity: try makeRootIdentity(label: "Live-Text-Size")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        let settings = SettingsViewModel(configuration: configuration, proxyRuntime: runtime)
        for size in [AppTextSize.small, .accessibility, .standard] {
            settings.appTextSize = size
            let deadline = ContinuousClock.now + .seconds(2)
            while viewModel.appTextSize != size && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(viewModel.appTextSize, size)
            XCTAssertEqual(UserDefaultsAppConfiguration(userDefaults: defaults).appTextSizeRawValue, size.rawValue)
        }
    }

    @MainActor
    func testViewModelPersistsUpdatedSortPreferencesToConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Sort-Save")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Sort-Save")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.sessionSortField = .duration
        viewModel.isSessionSortAscending = true

        XCTAssertEqual(configuration.sessionSortFieldRawValue, ProxyViewModel.SessionSortField.duration.rawValue)
        XCTAssertTrue(configuration.isSessionSortAscending)
    }

    @MainActor
    func testViewModelPersistsFollowLiveCompatibilityPreferenceToConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "FollowLive-Save")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "AutoFollow-Save")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.isSessionAutoScrollEnabled = true
        XCTAssertTrue(configuration.isSessionAutoScrollEnabled)

        viewModel.isSessionAutoScrollEnabled = false

        XCTAssertFalse(configuration.isSessionAutoScrollEnabled)
        XCTAssertEqual(viewModel.sessionFollowState, .staticInspection)
    }

    @MainActor
    func testViewModelRefreshesProxyPortDraftWhenConfigurationChangesExternally() async throws {
        let configuration = TestAppConfiguration(certificateLabel: "Port-External")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Port-External")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        // Preference reload is debounced on RunLoop.main, not the dispatch queue drained by other tests.
        let updated = expectation(description: "External port reaches the published draft")
        let observation = viewModel.$proxyPortDraft.filter { $0 == "9191" }.first()
            .sink { _ in updated.fulfill() }
        defer { observation.cancel() }
        configuration.proxyPort = 9191
        await fulfillment(of: [updated], timeout: 5)

        XCTAssertEqual(viewModel.proxyPortDraft, "9191")
    }

    @MainActor
    func testSettingsViewModelDisablesPortEditingWhileProxyRuns() {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Runtime")
        let runtime = TestProxyRuntime()
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: runtime)

        XCTAssertTrue(viewModel.canEditProxyPort)

        runtime.stateSubject.send(.running(port: configuration.proxyPort))
        waitForMainQueueDrain()

        XCTAssertFalse(viewModel.canEditProxyPort)
    }

    @MainActor
    func testSettingsViewModelRejectsInvalidPortWithoutPersisting() {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Port")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())

        viewModel.proxyPortDraft = "0"
        viewModel.applyProxyPortDraft()

        XCTAssertEqual(configuration.proxyPort, 8080)
        XCTAssertEqual(viewModel.proxyPortValidationMessage, "Enter a whole-number port from 1 to 65535.")
    }

    @MainActor
    func testSettingsViewModelPersistsInspectorCopyPrivacyPreference() {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Copy-Privacy")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())

        viewModel.isInspectorCopyRedactionEnabled = false

        XCTAssertFalse(configuration.isInspectorCopyRedactionEnabled)
    }

    @MainActor
    func testSettingsViewModelReloadsInspectorCopyPrivacyPreferenceFromConfiguration() async throws {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Copy-Privacy-Reload")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())

        for expected in [false, true, false] {
            configuration.isInspectorCopyRedactionEnabled = expected
            try await waitForSettingsUpdate {
                viewModel.isInspectorCopyRedactionEnabled == expected
            }
            XCTAssertEqual(viewModel.isInspectorCopyRedactionEnabled, expected)
            XCTAssertEqual(configuration.isInspectorCopyRedactionEnabled, expected)
        }
    }

    @MainActor
    func testSettingsViewModelPersistsQuitWarningPreference() {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Quit-Warning")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())

        viewModel.warnsBeforeQuittingWithUnsavedSessions = false

        XCTAssertFalse(configuration.warnsBeforeQuittingWithUnsavedSessions)
    }

    @MainActor
    func testSettingsViewModelReloadsQuitWarningPreferenceFromConfiguration() async throws {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Quit-Warning-Reload")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())

        for expected in [false, true, false] {
            configuration.warnsBeforeQuittingWithUnsavedSessions = expected
            try await waitForSettingsUpdate {
                viewModel.warnsBeforeQuittingWithUnsavedSessions == expected
            }
            XCTAssertEqual(viewModel.warnsBeforeQuittingWithUnsavedSessions, expected)
            XCTAssertEqual(configuration.warnsBeforeQuittingWithUnsavedSessions, expected)
        }
    }

    func testUserDefaultsConfigurationDefaultsToQuitWarningEnabled() {
        let suiteName = "com.JoesProxyApp.Tests.QuitWarning.Default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertTrue(configuration.warnsBeforeQuittingWithUnsavedSessions)
    }

    func testUserDefaultsConfigurationDefaultsToMenuBarItemDisabled() {
        let suiteName = "com.JoesProxyApp.Tests.MenuBarItem.Default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertFalse(configuration.showSystemProxyMenuBarItem)
    }

    func testUserDefaultsConfigurationDefaultsToAutoScrollPreference() {
        let suiteName = "com.JoesProxyApp.Tests.FollowLive.Default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertTrue(configuration.isSessionAutoScrollEnabled)
    }

    func testUserDefaultsConfigurationPersistsQuitWarningPreference() {
        let suiteName = "com.JoesProxyApp.Tests.QuitWarning.Persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.warnsBeforeQuittingWithUnsavedSessions = false
        let reloaded = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertFalse(reloaded.warnsBeforeQuittingWithUnsavedSessions)
    }

    func testUserDefaultsConfigurationResetRestoresQuitWarningPreference() {
        let suiteName = "com.JoesProxyApp.Tests.QuitWarning.Reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.warnsBeforeQuittingWithUnsavedSessions = false
        configuration.resetToDefaults()

        XCTAssertTrue(configuration.warnsBeforeQuittingWithUnsavedSessions)
    }

    func testUserDefaultsConfigurationResetRestoresAutoScrollPreference() {
        let suiteName = "com.JoesProxyApp.Tests.FollowLive.Reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.isSessionAutoScrollEnabled = false
        configuration.resetToDefaults()

        XCTAssertTrue(configuration.isSessionAutoScrollEnabled)
    }

    func testUserDefaultsConfigurationHonorsLegacySuppressedQuitWarning() {
        let suiteName = "com.JoesProxyApp.Tests.QuitWarning.Legacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "com.JoesProxyApp.suppressQuitWarning")

        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)

        XCTAssertFalse(configuration.warnsBeforeQuittingWithUnsavedSessions)
    }

    @MainActor
    func testAppDelegateTerminatesImmediatelyWhenNoUnsavedSessions() {
        let delegate = AppDelegate()
        var didPresentAlert = false
        delegate.hasUnsavedSessions = { false }
        delegate.shouldWarnBeforeQuit = { true }
        delegate.presentQuitPreservationAlertForTesting = {
            didPresentAlert = true
            return AppDelegate.QuitPreservationAlertResult(decision: .cancel, suppressFutureWarnings: false)
        }

        let reply = delegate.applicationShouldTerminate(.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertFalse(didPresentAlert)
    }

    @MainActor
    func testAppDelegateTerminatesImmediatelyWhenQuitWarningDisabled() {
        let delegate = AppDelegate()
        var didPresentAlert = false
        delegate.hasUnsavedSessions = { true }
        delegate.shouldWarnBeforeQuit = { false }
        delegate.presentQuitPreservationAlertForTesting = {
            didPresentAlert = true
            return AppDelegate.QuitPreservationAlertResult(decision: .cancel, suppressFutureWarnings: false)
        }

        let reply = delegate.applicationShouldTerminate(.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertFalse(didPresentAlert)
    }

    @MainActor
    func testAppDelegateCancelKeepsAppRunning() {
        let delegate = makeQuitPreservationDelegate(decision: .cancel, saveSucceeds: true)

        let reply = delegate.applicationShouldTerminate(.shared)

        XCTAssertEqual(reply, .terminateCancel)
    }

    @MainActor
    func testAppDelegateQuitWithoutSavingTerminates() {
        let delegate = makeQuitPreservationDelegate(decision: .quitWithoutSaving, saveSucceeds: false)

        let reply = delegate.applicationShouldTerminate(.shared)

        XCTAssertEqual(reply, .terminateNow)
    }

    @MainActor
    func testAppDelegateSaveRecordingTerminatesWhenSaveSucceeds() {
        var saveCallCount = 0
        let delegate = makeQuitPreservationDelegate(decision: .saveRecording, saveSucceeds: true) {
            saveCallCount += 1
        }

        let reply = delegate.applicationShouldTerminate(.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(saveCallCount, 1)
    }

    @MainActor
    func testAppDelegateSaveRecordingCancelsWhenSaveFailsOrIsCancelled() {
        var saveCallCount = 0
        let delegate = makeQuitPreservationDelegate(decision: .saveRecording, saveSucceeds: false) {
            saveCallCount += 1
        }

        let reply = delegate.applicationShouldTerminate(.shared)

        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertEqual(saveCallCount, 1)
    }

    @MainActor
    func testAppDelegateSuppressFutureWarningsUpdatesConfigurationPreference() {
        var warningPreference = true
        let delegate = makeQuitPreservationDelegate(
            decision: .quitWithoutSaving,
            saveSucceeds: false,
            suppressFutureWarnings: true
        )
        delegate.setShouldWarnBeforeQuit = { warningPreference = $0 }

        let reply = delegate.applicationShouldTerminate(.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertFalse(warningPreference)
    }

    @MainActor
    func testCombinedRetentionSettingsRoundTripAndRejectOverflow() {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Combined")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())
        viewModel.captureRetentionPolicyMode = .bounded
        viewModel.captureRetentionLimitDraft = "5000"
        viewModel.captureRetentionBodyLimitDraft = "250"
        viewModel.applyCaptureRetentionPolicy()
        XCTAssertEqual(configuration.captureRetentionPolicy, .bounded(maxSessions: 5000, maxBodyBytes: 250 * 1_048_576))
        let reloaded = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())
        XCTAssertEqual(reloaded.captureRetentionPolicyMode, .bounded)
        XCTAssertEqual(reloaded.captureRetentionLimitDraft, "5000")
        XCTAssertEqual(reloaded.captureRetentionBodyLimitDraft, "250")
        viewModel.captureRetentionBodyLimitDraft = String(Int.max)
        viewModel.applyCaptureRetentionPolicy()
        XCTAssertNotNil(viewModel.captureRetentionValidationMessage)
        XCTAssertEqual(configuration.captureRetentionPolicy, .bounded(maxSessions: 5000, maxBodyBytes: 250 * 1_048_576))
    }

    @MainActor
    func testSettingsViewModelPersistsSessionCountRetentionPreference() {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Retention-Sessions")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())

        viewModel.captureRetentionPolicyMode = .keepLastSessions
        viewModel.captureRetentionLimitDraft = "2500"
        viewModel.applyCaptureRetentionPolicy()

        XCTAssertEqual(configuration.captureRetentionPolicy, .keepLastSessions(2500))
        XCTAssertNil(viewModel.captureRetentionValidationMessage)
    }

    @MainActor
    func testSettingsViewModelPersistsBodyCapRetentionPreference() {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Retention-Body")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())

        viewModel.captureRetentionPolicyMode = .keepLastBodyMegabytes
        viewModel.captureRetentionLimitDraft = "300"
        viewModel.applyCaptureRetentionPolicy()

        XCTAssertEqual(configuration.captureRetentionPolicy, .keepLastBodyBytes(300 * 1_048_576))
        XCTAssertNil(viewModel.captureRetentionValidationMessage)
    }

    @MainActor
    func testSettingsViewModelReloadsRetentionPreferenceFromConfiguration() async throws {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Retention-Reload")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())

        configuration.captureRetentionPolicy = .keepLastBodyBytes(150 * 1_048_576)
        try await waitForSettingsUpdate {
            viewModel.captureRetentionPolicyMode == .keepLastBodyMegabytes
                && viewModel.captureRetentionLimitDraft == "150"
        }

        XCTAssertEqual(viewModel.captureRetentionPolicyMode, .keepLastBodyMegabytes)
        XCTAssertEqual(viewModel.captureRetentionLimitDraft, "150")
    }

    @MainActor
    func testSettingsViewModelUsesClearStoredBodyRetentionCopy() {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Retention-Copy")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())

        viewModel.captureRetentionPolicyMode = .keepLastBodyMegabytes

        XCTAssertEqual(SettingsViewModel.RetentionPolicyMode.keepLastBodyMegabytes.title, "Only Keep Recent Bodies")
        XCTAssertEqual(viewModel.captureRetentionValueLabel, "Body Data to Keep (MB)")
        XCTAssertEqual(
            viewModel.captureRetentionHelpText,
            "Keep all session metadata, but remove the oldest stored request and response bodies once the configured body-data limit is exceeded."
        )
    }

    @MainActor
    func testSettingsViewModelUsesClearSessionRetentionCopy() {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Retention-Session-Copy")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())

        viewModel.captureRetentionPolicyMode = .keepLastSessions

        XCTAssertEqual(SettingsViewModel.RetentionPolicyMode.keepLastSessions.title, "Only Keep Recent Sessions")
        XCTAssertEqual(viewModel.captureRetentionValueLabel, "Sessions to Keep")
        XCTAssertEqual(
            viewModel.captureRetentionHelpText,
            "Keep only the newest sessions in memory. Older sessions are removed as new traffic arrives."
        )
    }

    @MainActor
    func testSettingsViewModelRejectsInvalidRetentionWithoutPersisting() {
        let configuration = TestAppConfiguration(certificateLabel: "Settings-Retention-Invalid")
        let viewModel = SettingsViewModel(configuration: configuration, proxyRuntime: TestProxyRuntime())

        viewModel.captureRetentionPolicyMode = .keepLastSessions
        viewModel.captureRetentionLimitDraft = "0"
        viewModel.applyCaptureRetentionPolicy()

        XCTAssertEqual(configuration.captureRetentionPolicy, .unlimited)
        XCTAssertEqual(viewModel.captureRetentionValidationMessage, "Enter a whole-number session count greater than 0.")
    }

    @MainActor
    func testCaptureHealthSamplesProcessMetricsOnSessionChange() async throws {
        let sessionStore = InMemorySessionStore()
        let processMetricsSampler = TestProcessMetricsSampler(samples: [
            AppProcessMetrics(cpuPercent: 12.5, residentMemoryBytes: 123_456),
            AppProcessMetrics(cpuPercent: 12.5, residentMemoryBytes: 123_456)
        ])
        let viewModel = makeViewModel(
            sessionStore: sessionStore,
            certificateAuthority: FakeCertificateAuthority(
                currentIdentity: nil,
                createdIdentity: try makeRootIdentity(label: "Capture-Health-Metrics")
            ),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled),
            processMetricsSampler: processMetricsSampler
        )

        sessionStore.append(makeSession(method: "GET", host: "api.example.com", path: "/health"))

        try await waitForCaptureHealth(
            viewModel,
            residentMemoryBytes: 123_456,
            cpuPercent: 12.5
        )

        XCTAssertGreaterThanOrEqual(processMetricsSampler.sampleCallCount, 1)
        XCTAssertEqual(viewModel.captureHealth.sessionCount, 1)
    }

    @MainActor
    func testDismissGuidedSetupDoesNotCompleteFirstRunWithoutEvidence() {
        let configuration = TestAppConfiguration(certificateLabel: "GuidedSetup-Dismiss")
        let presentationState = AppPresentationState(configuration: configuration)

        presentationState.presentGuidedSetup(section: .welcome, mode: .firstRun)
        presentationState.dismissGuidedSetup()

        XCTAssertNil(presentationState.guidedSetupContext)
        XCTAssertFalse(configuration.hasCompletedInitialGuidedSetupPresentation)
        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .notStarted)
    }

    @MainActor
    func testPresentGuidedRepairRoutesAllBlockingStatesToHTTPSAndTrust() {
        let presentationState = AppPresentationState()
        let blockingStates: [GuidedSetupBlockingState] = [.notSetUp, .installedTrustRequired, .needsCleanup]

        for blockingState in blockingStates {
            presentationState.presentGuidedRepair(for: blockingState)

            XCTAssertEqual(
                presentationState.guidedSetupContext,
                GuidedSetupContext(section: .httpsAndTrust, mode: .repair(blockingState))
            )

            presentationState.dismissGuidedSetup()
        }
    }

    @MainActor
    func testTransitionFromGuidedSetupPresentsCertificateSetup() {
        let presentationState = AppPresentationState()
        presentationState.presentGuidedSetup(section: .httpsAndTrust, mode: .replay)

        presentationState.transitionFromGuidedSetup(to: .certificateSetup)

        XCTAssertNil(presentationState.guidedSetupContext)

        let expectation = expectation(description: "Guided setup transition completes")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        XCTAssertTrue(presentationState.isCertificateSetupPresented)
    }

    @MainActor
    func testGuidedSetupChecklistVerificationStateReflectsTunneledTraffic() throws {
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))
        let store = InMemorySessionStore()
        store.append(
            makeSession(
                method: "GET",
                host: "api.example.com",
                path: "/v1/test",
                inspectionKind: .tunneledTLS
            )
        )
        let identity = try makeRootIdentity(label: "GuidedSetup-Tunneled")
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed)
        )

        viewModel.runSetupVerification()
        let verification = viewModel.guidedSetupChecklistItems.first(where: { $0.id == "verification" })

        XCTAssertEqual(viewModel.setupVerificationState, .tunneled)
        XCTAssertEqual(verification?.state, .warning)
        XCTAssertEqual(verification?.primaryAction, .verifyCapture)
    }

    @MainActor
    func testGuidedSetupChecklistVerificationStateReflectsNoTrafficObserved() throws {
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))
        let identity = try makeRootIdentity(label: "GuidedSetup-NoTraffic")
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed)
        )

        viewModel.runSetupVerification()
        let verification = viewModel.guidedSetupChecklistItems.first(where: { $0.id == "verification" })

        XCTAssertEqual(viewModel.setupVerificationState, .noTrafficObserved)
        XCTAssertEqual(verification?.state, .neutral)
        XCTAssertEqual(verification?.primaryAction, .verifyCapture)
    }

    @MainActor
    func testAppPresentationStatePresentsReplayGuidedSetupAtRequestedSection() {
        let presentationState = AppPresentationState()

        presentationState.presentGuidedSetup(section: .exploreTraffic)

        XCTAssertEqual(
            presentationState.guidedSetupContext,
            GuidedSetupContext(section: .exploreTraffic, mode: .replay)
        )
    }

    @MainActor
    func testAppPresentationStatePresentsRepairFlowForBlockingState() {
        let presentationState = AppPresentationState()

        presentationState.presentGuidedRepair(for: .installedTrustRequired)

        XCTAssertEqual(
            presentationState.guidedSetupContext,
            GuidedSetupContext(section: .httpsAndTrust, mode: .repair(.installedTrustRequired))
        )
    }

    @MainActor
    func testAppPresentationStateShowsInitialPathChoiceUntilAPathIsChosen() {
        let configuration = TestAppConfiguration(certificateLabel: "GuidedSetup-Initial")
        let presentationState = AppPresentationState(configuration: configuration)

        presentationState.presentInitialGuidedSetupIfNeeded()

        XCTAssertTrue(presentationState.isFirstRunPathChoicePresented)
        XCTAssertNil(presentationState.guidedSetupContext)
        XCTAssertFalse(configuration.hasCompletedInitialGuidedSetupPresentation)
        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .notStarted)

        presentationState.chooseStartFirstCapture()
        presentationState.presentInitialGuidedSetupIfNeeded()

        XCTAssertFalse(presentationState.isFirstRunPathChoicePresented)
        XCTAssertEqual(configuration.onboardingProgressRecord.lifecycle, .inProgress)
        XCTAssertFalse(configuration.hasCompletedInitialGuidedSetupPresentation)
    }

    @MainActor
    func testAppPresentationStateDoesNotAutoShowInitialGuidedSetupAfterCompletion() {
        let configuration = TestAppConfiguration(certificateLabel: "GuidedSetup-Completed")
        configuration.hasCompletedInitialGuidedSetupPresentation = true
        let presentationState = AppPresentationState(configuration: configuration)

        presentationState.presentInitialGuidedSetupIfNeeded()

        XCTAssertFalse(presentationState.isFirstRunPathChoicePresented)
        XCTAssertNil(presentationState.guidedSetupContext)
    }

    @MainActor
    func testAppPresentationStateAllowsReplayAfterInitialGuidedSetupCompletion() {
        let configuration = TestAppConfiguration(certificateLabel: "GuidedSetup-Replay")
        configuration.hasCompletedInitialGuidedSetupPresentation = true
        let presentationState = AppPresentationState(configuration: configuration)

        presentationState.presentGuidedSetup(section: .startCapturing, mode: .replay)

        XCTAssertEqual(
            presentationState.guidedSetupContext,
            GuidedSetupContext(section: .startCapturing, mode: .replay)
        )
    }

    @MainActor
    func testAppPresentationStatePresentHelpHubWithTopicSetsFocusedTopic() {
        let presentationState = AppPresentationState()

        presentationState.presentHelpHub(topic: .certificateSetup)

        XCTAssertTrue(presentationState.isHelpHubPresented)
        XCTAssertEqual(presentationState.helpHubTopic, .certificateSetup)
    }

    @MainActor
    func testAppPresentationStatePresentHelpHubWithoutTopicClearsFocusedTopic() {
        let presentationState = AppPresentationState()

        presentationState.presentHelpHub(topic: .trafficStates)
        presentationState.presentHelpHub()

        XCTAssertTrue(presentationState.isHelpHubPresented)
        XCTAssertNil(presentationState.helpHubTopic)
    }

    @MainActor
    func testGuidedSetupChecklistItemsReflectReadyRunningAndObservedTraffic() throws {
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))
        let store = InMemorySessionStore()
        store.append(makeSession(method: "GET", host: "example.com", path: "/"))
        let identity = try makeRootIdentity(label: "GuidedSetup-Ready")
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed)
        )

        viewModel.runSetupVerification()
        let items = viewModel.guidedSetupChecklistItems(
            currentNetworkSnapshot: ProxyViewModel.SetupNetworkSnapshot(
                proxyPort: 8080,
                lanIP: "192.168.1.5",
                bonjourName: "Mac.local"
            )
        )

        XCTAssertEqual(items.map(\.title), [
            "Root CA and certificate trust",
            "Proxy listener",
            "Traffic captured",
            "HTTPS inspection verified",
            "Device traffic detected"
        ])
        XCTAssertEqual(items.map(\.state), [.complete, .complete, .complete, .complete, .complete])
        XCTAssertNil(viewModel.guidedSetupNextActionItem)
    }

    @MainActor
    func testGuidedSetupChecklistItemsReflectActionNeededAndNeutralStates() throws {
        let runtime = TestProxyRuntime()
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            certificateAuthority: FakeCertificateAuthority(
                currentIdentity: nil,
                createdIdentity: try makeRootIdentity(label: "GuidedSetup-NeedsAction")
            ),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        let items = viewModel.guidedSetupChecklistItems(
            currentNetworkSnapshot: ProxyViewModel.SetupNetworkSnapshot(
                proxyPort: 8080,
                lanIP: "192.168.1.5",
                bonjourName: "Mac.local"
            )
        )

        XCTAssertEqual(items.map(\.state), [.needsAction, .needsAction, .needsAction, .waiting, .neutral])
        XCTAssertEqual(viewModel.guidedSetupNextActionItem?.id, "certificate")
        XCTAssertEqual(
            items.first?.primaryAction,
            .openCertificateSetup
        )
    }

    @MainActor
    func testGuidedSetupChecklistMarksRoutingStaleWhenNetworkSnapshotChanges() throws {
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 9191))
        let identity = try makeRootIdentity(label: "GuidedSetup-Stale")
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed)
        )
        viewModel.recordSetupNetworkSnapshot(
            ProxyViewModel.SetupNetworkSnapshot(
                proxyPort: 8080,
                lanIP: "192.168.1.5",
                bonjourName: "OldMac.local"
            )
        )

        let items = viewModel.guidedSetupChecklistItems(
            currentNetworkSnapshot: ProxyViewModel.SetupNetworkSnapshot(
                proxyPort: 9191,
                lanIP: "192.168.1.9",
                bonjourName: "NewMac.local"
            )
        )

        XCTAssertEqual(items.first(where: { $0.id == "traffic" })?.state, .stale)
        XCTAssertEqual(items.first(where: { $0.id == "device" })?.state, .stale)
        XCTAssertTrue(items.first(where: { $0.id == "traffic" })?.detail.contains("port changed from 8080 to 9191") ?? false)
    }

    @MainActor
    func testCaptureSetupNetworkSnapshotUsesInjectedNetworkInfoProvider() throws {
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))
        let identity = try makeRootIdentity(label: "GuidedSetup-InjectedNetwork")
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed),
            localNetworkInfoProvider: StaticLocalNetworkInfoProvider(
                networkInfo: LocalNetworkInfo(lanIP: "10.0.0.44", bonjourName: "Injected.local")
            )
        )

        viewModel.captureSetupNetworkSnapshot()

        XCTAssertEqual(
            viewModel.setupNetworkSnapshot,
            ProxyViewModel.SetupNetworkSnapshot(
                proxyPort: 8080,
                lanIP: "10.0.0.44",
                bonjourName: "Injected.local"
            )
        )
    }

    @MainActor
    func testGuidedSetupChecklistVerificationNextActionUsesProxyStoppedState() throws {
        let runtime = TestProxyRuntime()
        let identity = try makeRootIdentity(label: "GuidedSetup-ProxyStopped")
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed)
        )

        viewModel.runSetupVerification()
        let verification = viewModel.guidedSetupChecklistItems.first(where: { $0.id == "verification" })

        XCTAssertEqual(verification?.state, .needsAction)
        XCTAssertEqual(verification?.primaryAction, .startProxy)
        XCTAssertEqual(verification?.primaryActionTitle, "Start Proxy")
    }

    @MainActor
    func testViewModelPersistsUpdatedExplorerPreferencesToConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Explorer-Save")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Explorer-Save")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.sessionBrowserMode = .explorer
        viewModel.sessionExplorerGrouping = .byEndpoint
        viewModel.sessionExplorerHostGrouping = .domainFamilies
        viewModel.sessionExplorerExpandedNodeIDs = ["host:api.example.com", "host:api.example.com|path:v1"]

        XCTAssertEqual(configuration.sessionBrowserModeRawValue, SessionBrowserMode.explorer.rawValue)
        XCTAssertEqual(configuration.sessionExplorerGroupingRawValue, SessionExplorerGrouping.byEndpoint.rawValue)
        XCTAssertEqual(configuration.sessionExplorerHostGroupingRawValue, SessionExplorerHostGrouping.domainFamilies.rawValue)
        XCTAssertEqual(configuration.sessionExplorerExpandedNodeIDs, ["host:api.example.com", "host:api.example.com|path:v1"])
    }

    @MainActor
    func testViewModelPersistsUpdatedTimelineBrowserModeToConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Timeline-Save")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Timeline-Save")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.sessionBrowserMode = .timeline

        XCTAssertEqual(configuration.sessionBrowserModeRawValue, SessionBrowserMode.timeline.rawValue)
    }

    @MainActor
    func testFollowLiveSelectsLatestVisibleSessionWhenNewTrafficArrives() throws {
        let store = InMemorySessionStore()
        let first = makeSession(method: "GET", host: "example.com", path: "/first")
        let second = makeSession(method: "GET", host: "example.com", path: "/second")
        store.append(first)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "AutoFollow-Selection")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.isSessionAutoScrollEnabled = true
        XCTAssertEqual(viewModel.sessionFollowState, .followingLive)

        let expectation = XCTestExpectation(description: "latest session selected")
        let cancellable = viewModel.$selectedSessionID.sink { selectedSessionID in
            if selectedSessionID == second.id {
                expectation.fulfill()
            }
        }

        store.append(second)

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
        XCTAssertEqual(viewModel.selectedSession?.id, second.id)
    }

    @MainActor
    func testStaticInspectionDoesNotSelectNewTraffic() async throws {
        let store = InMemorySessionStore()
        let first = makeSession(method: "GET", host: "example.com", path: "/first")
        let second = makeSession(method: "GET", host: "example.com", path: "/second")
        store.append(first)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Static-Inspection")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.setFollowLiveEnabled(false)
        viewModel.selectSessionFromUser(first.id)
        store.append(second)
        let deadline = ContinuousClock.now + .seconds(2)
        while !viewModel.sessionTableDisplayedSummaries.contains(where: { $0.id == second.id }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(viewModel.sessionFollowState, .staticInspection)
        XCTAssertEqual(viewModel.selectedSessionID, first.id)
        XCTAssertTrue(
            viewModel.sessionTableDisplayedSummaries.contains { $0.id == second.id },
            "new traffic must keep appearing in the table even while static inspection holds the selection"
        )
    }

    @MainActor
    func testManualSelectionPausesFollowLive() async throws {
        let store = InMemorySessionStore()
        let first = makeSession(method: "GET", host: "example.com", path: "/first")
        let second = makeSession(method: "GET", host: "example.com", path: "/second")
        let third = makeSession(method: "GET", host: "example.com", path: "/third")
        store.append(first)
        store.append(second)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Follow-Pause")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.setFollowLiveEnabled(true)
        try await waitForSelectedSession(viewModel, expected: second.id)

        viewModel.selectSessionFromUser(first.id)
        store.append(third)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(viewModel.sessionFollowState, .paused)
        XCTAssertEqual(viewModel.selectedSessionID, first.id)
        XCTAssertTrue(
            viewModel.sessionTableDisplayedSummaries.contains { $0.id == third.id },
            "new traffic must keep appearing in the table even while paused holds the selection"
        )
        // Verify manual pause is transient and does not clear the user's default configuration preference
        XCTAssertTrue(viewModel.configuration.isSessionAutoScrollEnabled)
    }

    @MainActor
    func testSessionFollowStateResetsOnCaptureStartAndClearSessions() async throws {
        let store = InMemorySessionStore()
        let runtime = TestProxyRuntime()
        let configuration = TestAppConfiguration(certificateLabel: "Follow-Lifecycle")
        configuration.isSessionAutoScrollEnabled = true

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: runtime,
            sessionStore: store,
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Follow-Lifecycle")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        XCTAssertEqual(viewModel.sessionFollowState, ProxyViewModel.SessionFollowState.followingLive)

        // Pause via user selection
        let first = makeSession(method: "GET", host: "example.com", path: "/first")
        store.append(first)
        viewModel.selectSessionFromUser(first.id)
        XCTAssertEqual(viewModel.sessionFollowState, ProxyViewModel.SessionFollowState.paused)

        // Clearing all sessions resets to following live when configured
        viewModel.clearAllSessions()
        XCTAssertEqual(viewModel.sessionFollowState, ProxyViewModel.SessionFollowState.followingLive)

        // Pausing again and starting proxy resets to following live
        viewModel.pauseFollowLiveForUserInteraction()
        XCTAssertEqual(viewModel.sessionFollowState, ProxyViewModel.SessionFollowState.paused)

        runtime.stateSubject.send(.running(port: 9090))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.sessionFollowState, ProxyViewModel.SessionFollowState.followingLive)
    }

    @MainActor
    func testFilterHiddenSelectedSessionStaysSelectedInStaticInspection() async throws {
        let store = InMemorySessionStore()
        let hidden = makeSession(method: "GET", host: "hidden.example.com", path: "/manifest")
        let visible = makeSession(method: "POST", host: "visible.example.com", path: "/license")
        store.append(hidden)
        store.append(visible)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Static-Hidden")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.setFollowLiveEnabled(false)
        viewModel.selectSessionFromUser(hidden.id)
        viewModel.sessionFilterCriteria.method = "POST"
        try await waitForFilteredSessions(viewModel, expectedCount: 1)

        XCTAssertEqual(viewModel.sessionFollowState, .staticInspection)
        XCTAssertEqual(viewModel.selectedSessionID, hidden.id)
        XCTAssertEqual(viewModel.selectedSession?.id, hidden.id)
    }

    @MainActor
    func testRemovedSelectedSessionClearsInStaticInspection() async throws {
        let store = InMemorySessionStore()
        let first = makeSession(method: "GET", host: "example.com", path: "/first")
        let second = makeSession(method: "GET", host: "example.com", path: "/second")
        store.append(first)
        store.append(second)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Static-Removed")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.selectSessionFromUser(first.id)
        store.remove(ids: [first.id])
        try await waitForClearedSelection(viewModel)

        XCTAssertNil(viewModel.selectedSessionID)
    }

    @MainActor
    func testJumpToLatestSelectsNewestAndResumesFollowLive() async throws {
        let store = InMemorySessionStore()
        let first = makeSession(method: "GET", host: "example.com", path: "/first")
        let second = makeSession(method: "GET", host: "example.com", path: "/second")
        let third = makeSession(method: "GET", host: "example.com", path: "/third")
        store.append(first)
        store.append(second)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Follow-Jump")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.selectSessionFromUser(first.id)
        viewModel.jumpToLatestSession()
        try await waitForSelectedSession(viewModel, expected: second.id)

        store.append(third)
        try await waitForSelectedSession(viewModel, expected: third.id)

        XCTAssertEqual(viewModel.sessionFollowState, .followingLive)
    }

    @MainActor
    func testSearchChangePausesFollowLive() async throws {
        let store = InMemorySessionStore()
        let first = makeSession(method: "GET", host: "example.com", path: "/first")
        let second = makeSession(method: "GET", host: "example.com", path: "/second")
        let third = makeSession(method: "GET", host: "example.com", path: "/third")
        store.append(first)
        store.append(second)

        let viewModel = makeViewModel(
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Follow-Search")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.setFollowLiveEnabled(true)
        try await waitForSelectedSession(viewModel, expected: second.id)

        viewModel.sessionSearchText = "example"
        try await Task.sleep(nanoseconds: 350_000_000)
        store.append(third)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(viewModel.sessionFollowState, .paused)
        XCTAssertEqual(viewModel.selectedSessionID, second.id)
    }

    @MainActor
    func testProgrammaticExplorerExpansionDoesNotPauseFollowLive() throws {
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Explorer-Programmatic-Expand")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.setFollowLiveEnabled(true)
        viewModel.expandExplorerAncestors(["host:api.example.com"])

        XCTAssertEqual(viewModel.sessionFollowState, .followingLive)
        XCTAssertEqual(viewModel.sessionExplorerExpandedNodeIDs, ["host:api.example.com"])
    }

    @MainActor
    func testUserExplorerExpansionPausesFollowLive() throws {
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Explorer-User-Expand")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.setFollowLiveEnabled(true)
        viewModel.sessionExplorerExpandedNodeIDs = ["host:api.example.com"]

        XCTAssertEqual(viewModel.sessionFollowState, .paused)
    }

    @MainActor
    func testFollowLiveDoesNotReSelectWhenAlreadyOnNewestSession() async throws {
        let store = InMemorySessionStore()
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))

        var session = makeSession(method: "GET", host: "example.com", path: "/live")
        store.append(session)

        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "AutoFollow-Guard")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        viewModel.isSessionAutoScrollEnabled = true

        try await waitForSelectedSession(viewModel, expected: session.id)

        session.response = CapturedResponse(
            statusCode: 200,
            headers: [],
            bodyData: Data("ok".utf8),
            bodySize: 2
        )
        session.state = .completed
        session.timing.completedAt = Date()
        store.update(session)

        try await waitForSelectedSession(viewModel, expected: session.id)
    }

    @MainActor
    private func waitForSelectedSession(
        _ viewModel: ProxyViewModel,
        expected: SessionRecord.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            if viewModel.selectedSessionID == expected {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(
            "Timed out waiting for selected session \(expected); got \(String(describing: viewModel.selectedSessionID))",
            file: file,
            line: line
        )
    }

    @MainActor
    private func waitForClearedSelection(
        _ viewModel: ProxyViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            if viewModel.selectedSessionID == nil {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(
            "Timed out waiting for cleared selection; got \(String(describing: viewModel.selectedSessionID))",
            file: file,
            line: line
        )
    }

    @MainActor
    /// Named for what it actually verifies: windowing while capture is running, then "Show older
    /// sessions" catching `visibleLimit` up to the total. This used to also be the only test
    /// covering stop-gating, but its final assertions passed regardless of whether stopping the
    /// proxy actually disabled windowing — `showMoreSessionTableSessions()` above already set
    /// `visibleLimit == totalCount` (501), so windowing was already inactive before `.stopped`
    /// was even sent. See `testSessionTableWindowingDisablesWhenCaptureStopsWithoutManualExpansion`
    /// for a test that isolates the stop transition itself.
    func testSessionTableWindowsDuringActiveCaptureThenExpandsViaShowMore() async throws {
        let store = InMemorySessionStore()
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))

        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Table-Window")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        for index in 0..<501 {
            store.append(makeSession(method: "GET", host: "api.example.com", path: "/item/\(index)"))
        }

        try await waitForFilteredSessions(viewModel, expectedCount: 501)

        XCTAssertTrue(viewModel.isSessionTableWindowingActive)
        XCTAssertEqual(viewModel.sessionTableDisplayedSessions.count, 500)
        XCTAssertEqual(viewModel.sessionTableHiddenSessionCount, 1)

        viewModel.showMoreSessionTableSessions()
        XCTAssertEqual(viewModel.sessionTableDisplayedSessions.count, 501)
        XCTAssertEqual(viewModel.sessionTableHiddenSessionCount, 0)
    }

    @MainActor
    /// Isolates the stop transition itself, without a preceding "Show older sessions" call
    /// masking whether stopping actually disables windowing.
    func testSessionTableWindowingDisablesWhenCaptureStopsWithoutManualExpansion() async throws {
        let store = InMemorySessionStore()
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))

        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Table-Window-Stop")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        for index in 0..<600 {
            store.append(makeSession(method: "GET", host: "api.example.com", path: "/item/\(index)"))
        }
        try await waitForFilteredSessions(viewModel, expectedCount: 600)

        XCTAssertTrue(viewModel.isSessionTableWindowingActive)
        XCTAssertEqual(viewModel.sessionTableDisplayedSessions.count, 500)
        XCTAssertEqual(viewModel.sessionTableHiddenSessionCount, 100)

        runtime.stateSubject.send(.stopped)
        // Proxy state flows through receive(on: DispatchQueue.main) — drain the main queue.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(viewModel.isSessionTableWindowingActive)
        XCTAssertEqual(viewModel.sessionTableDisplayedSessions.count, 600)
        XCTAssertEqual(viewModel.sessionTableHiddenSessionCount, 0)
    }

    @MainActor
    /// End-to-end pin coverage through the public API, mirroring
    /// `CaptureWorkspaceSelectionPinningTests` at the workspace level but through
    /// `selectSessionFromUser`/`sessionTableDisplayedSessions` for integration confidence.
    func testSelectedSessionStaysVisibleAcrossWindowEvictionViaPinning() async throws {
        let store = InMemorySessionStore()
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))

        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Table-Window-Pin")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        let watched = makeSession(method: "GET", host: "api.example.com", path: "/watched")
        store.append(watched)
        for index in 0..<50 {
            store.append(makeSession(method: "GET", host: "api.example.com", path: "/filler/\(index)"))
        }
        try await waitForFilteredSessions(viewModel, expectedCount: 51)

        viewModel.selectSessionFromUser(watched.id)

        for index in 0..<600 {
            store.append(makeSession(method: "GET", host: "api.example.com", path: "/flood/\(index)"))
        }
        try await waitForFilteredSessions(viewModel, expectedCount: 651)

        XCTAssertEqual(viewModel.sessionFollowState, .paused)
        XCTAssertEqual(viewModel.selectedSessionID, watched.id)
        XCTAssertTrue(
            viewModel.sessionTableDisplayedSessions.contains { $0.id == watched.id },
            "a selected session must stay visible even after 500+ rows of newer traffic arrive"
        )
        XCTAssertEqual(
            viewModel.sessionTableDisplayedSessions.count, 501,
            "the table must keep windowing normally (500 + 1 pinned row), not freeze"
        )
    }

    @MainActor
    func testIncrementalVisibleSessionRefreshPreservesNewestFirstOrder() async throws {
        let store = InMemorySessionStore()
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 8080))

        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            sessionStore: store,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Incremental-Refresh")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        let first = makeSession(method: "GET", host: "api.example.com", path: "/first", startedAt: Date(timeIntervalSince1970: 10))
        let second = makeSession(method: "GET", host: "api.example.com", path: "/second", startedAt: Date(timeIntervalSince1970: 20))
        store.append(first)
        store.append(second)

        try await waitForFilteredSessions(viewModel, expectedCount: 2)

        // filteredSessions stores oldest-first; sessionTableDisplayedSessions reverses for newest-first display.
        XCTAssertEqual(viewModel.sessionTableDisplayedSessions.map(\.request.path), ["/second", "/first"])
    }

    @MainActor
    func testAddBookmarkFromSessionPersistsAndSelectsBookmark() throws {
        let store = InMemorySessionStore()
        let session = makeSession(method: "GET", host: "api.example.com", path: "/events")
        store.append(session)
        let bookmarkStore = InMemoryBookmarkStore()

        let viewModel = makeViewModel(
            sessionStore: store,
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Add")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.addBookmark(from: session)

        XCTAssertEqual(viewModel.bookmarkCount, 1)
        XCTAssertEqual(viewModel.selectedBookmark?.request.host, "api.example.com")
        XCTAssertEqual(viewModel.selectedBookmark?.request.path, "/events")
        XCTAssertEqual(bookmarkStore.loadBookmarks().count, 1)
    }

    @MainActor
    func testAddBookmarkFromSessionPersistsSavedResponse() throws {
        let responseBody = Data(#"{"appConfig":{"ad_variant_keys_enabled":"true"}}"#.utf8)
        let session = makeSession(
            method: "GET",
            host: "api.example.com",
            path: "/apps-api/v2.0/ipad/app/status.json?locale=en",
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: responseBody,
                bodySize: responseBody.count
            )
        )
        let bookmarkStore = InMemoryBookmarkStore()

        let viewModel = makeViewModel(
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Response")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.addBookmark(from: session)

        XCTAssertNotNil(viewModel.selectedBookmark?.savedResponse)
        XCTAssertEqual(viewModel.selectedBookmark?.savedResponse?.statusCode, 200)
        XCTAssertEqual(viewModel.selectedBookmark?.savedResponse?.bodyData, responseBody)
        XCTAssertEqual(viewModel.selectedBookmark?.responseMatchMode, .ignoreQuery)
    }

    func testLegacyBookmarkJSONDecodesWithoutResponseRewriteFields() throws {
        let legacyBookmark = """
        [
          {
            "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            "name": "Legacy Bookmark",
            "request": {
              "method": "GET",
              "scheme": "https",
              "inspectionKind": "plain",
              "host": "api.example.com",
              "port": 443,
              "path": "/events",
              "headers": [],
              "bodySize": null
            },
            "createdAt": "2026-01-01T00:00:00Z"
          }
        ]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([Bookmark].self, from: legacyBookmark)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].savedResponse)
        XCTAssertTrue(decoded[0].responseRewrites.isEmpty)
        XCTAssertEqual(decoded[0].responseRewriteMode, .savedSnapshot)
        XCTAssertEqual(decoded[0].responseMatchMode, .ignoreQuery)
    }

    @MainActor
    func testEnableBookmarkResponseRewriteRequiresProxyRunningAndRules() async throws {
        let responseBody = Data(#"{"appConfig":{"flag":"true"}}"#.utf8)
        let bookmark = Bookmark(
            name: "Status",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/status.json",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            savedResponse: BookmarkSavedResponse(
                statusCode: 200,
                headers: [],
                bodyData: responseBody,
                savedAt: Date()
            ),
            responseRewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: "appConfig.flag",
                    overrideValue: .string("false")
                )
            ]
        )
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 9090))

        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Rewrite-Enable")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        XCTAssertTrue(viewModel.canEnableBookmarkResponseRewrite(id: bookmark.id))
        await viewModel.enableBookmarkResponseRewrite(id: bookmark.id)
        XCTAssertTrue(viewModel.isBookmarkResponseRewriteEnabled(id: bookmark.id))

        runtime.stateSubject.send(.stopped)
        try await waitForProxyState(viewModel) {
            if case .stopped = $0 { return true }
            return false
        }
        XCTAssertFalse(viewModel.canEnableBookmarkResponseRewrite(id: bookmark.id))
    }

    @MainActor
    func testEnableBookmarkResponseRewriteSetsActivityEnabledAt() async throws {
        let bookmark = Bookmark(
            name: "Status",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/status.json",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            savedResponse: BookmarkSavedResponse(
                statusCode: 200,
                headers: [],
                bodyData: Data(#"{"flag":"true"}"#.utf8),
                savedAt: Date()
            ),
            responseRewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: "flag",
                    overrideValue: .string("false")
                )
            ]
        )
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 9090))
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            bookmarkStore: InMemoryBookmarkStore(bookmarks: [bookmark]),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Rewrite-Activity")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        await viewModel.enableBookmarkResponseRewrite(id: bookmark.id)

        XCTAssertNotNil(viewModel.bookmarkResponseRewriteActivity(for: bookmark.id)?.enabledAt)
        XCTAssertFalse(viewModel.bookmarkResponseRewriteActivity(for: bookmark.id)?.hasIntercepted ?? true)
    }

    @MainActor
    func testBookmarkResponseRewriteTrafficHintsSurfaceMismatchedPaths() async throws {
        let bookmark = Bookmark(
            name: "Movie List",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/movies/123.json",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            savedResponse: BookmarkSavedResponse(
                statusCode: 200,
                headers: [],
                bodyData: Data(#"{"title":"Movie"}"#.utf8),
                savedAt: Date()
            ),
            responseRewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: "title",
                    overrideValue: .string("Override")
                )
            ]
        )
        let sessionStore = InMemorySessionStore()
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 9090))
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            sessionStore: sessionStore,
            bookmarkStore: InMemoryBookmarkStore(bookmarks: [bookmark]),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Rewrite-Hints")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        await viewModel.enableBookmarkResponseRewrite(id: bookmark.id)
        sessionStore.append(
            makeSession(
                method: "GET",
                host: "api.example.com",
                path: "/movie/metadata/123.json",
                startedAt: Date()
            )
        )
        try await waitForFilteredSessions(viewModel, expectedCount: 1)

        let hints = viewModel.bookmarkResponseRewriteTrafficHints(for: bookmark.id)
        XCTAssertEqual(hints, ["/movie/metadata/123.json"])
    }

    @MainActor
    func testUpdateBookmarkResponseRewritePathRecomputesOriginalSnapshot() throws {
        let responseBody = Data(#"{"movie":{"title":"Original"}}"#.utf8)
        let rewriteID = UUID()
        let bookmark = Bookmark(
            name: "Movie",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/movie.json",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            savedResponse: BookmarkSavedResponse(
                statusCode: 200,
                headers: [],
                bodyData: responseBody,
                savedAt: Date()
            ),
            responseRewrites: [
                BookmarkResponseFieldRewrite(
                    id: rewriteID,
                    jsonPath: "title",
                    originalValueSnapshot: nil,
                    overrideValue: .string("Override")
                )
            ]
        )
        let viewModel = makeViewModel(
            bookmarkStore: InMemoryBookmarkStore(bookmarks: [bookmark]),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Rewrite-Path")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.updateBookmarkResponseRewritePath(
            rewriteID: rewriteID,
            jsonPath: "movie.title",
            for: bookmark.id
        )

        let updatedRewrite = viewModel.bookmarks.first?.responseRewrites.first
        XCTAssertEqual(updatedRewrite?.jsonPath, "movie.title")
        XCTAssertEqual(updatedRewrite?.originalValueSnapshot, "Original")
    }

    @MainActor
    func testUpdateBookmarkResponseRewriteOverridePersistsValue() async throws {
        let responseBody = Data(#"{"title":"Original"}"#.utf8)
        let bookmark = Bookmark(
            name: "Movie",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/movie.json",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            savedResponse: BookmarkSavedResponse(
                statusCode: 200,
                headers: [],
                bodyData: responseBody,
                savedAt: Date()
            ),
            responseRewrites: [
                BookmarkResponseFieldRewrite(
                    jsonPath: "title",
                    originalValueSnapshot: "Original",
                    overrideValue: .string("First")
                )
            ]
        )
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])
        let viewModel = makeViewModel(
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Rewrite-Override")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.selectedBookmarkID = bookmark.id
        viewModel.updateBookmarkResponseRewriteOverride(
            rewriteID: bookmark.responseRewrites[0].id,
            overrideValueText: "Updated Title",
            for: bookmark.id
        )

        XCTAssertEqual(viewModel.selectedBookmark?.responseRewrites.first?.overrideValue, .string("Updated Title"))
        let applicability = viewModel.bookmarkResponseRewriteApplicability(for: bookmark.id)
        XCTAssertEqual(applicability?.applicable, 1)
        XCTAssertEqual(applicability?.enabled, 1)
    }

    @MainActor
    func testRenameBookmarkPersistsUpdatedName() throws {
        let bookmark = Bookmark(
            name: "Old Name",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events",
                headers: [],
                bodyData: nil,
                bodySize: nil
            )
        )
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])

        let viewModel = makeViewModel(
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Rename")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.selectedBookmarkID = bookmark.id
        viewModel.updateBookmarkName("Current Events", for: bookmark.id)

        XCTAssertEqual(viewModel.selectedBookmark?.name, "Current Events")
        XCTAssertEqual(bookmarkStore.loadBookmarks().first?.name, "Current Events")
    }

    @MainActor
    func testUpdateBookmarkRequestPersistsEditedPathAndHeaders() throws {
        let bookmark = Bookmark(
            name: "GET api.example.com/events?sessionToken=old",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events?sessionToken=old",
                headers: [HTTPHeaderField(name: "Authorization", value: "Bearer old-token")],
                bodyData: Data("{\"sessionToken\":\"old\"}".utf8),
                bodySize: "{\"sessionToken\":\"old\"}".count
            )
        )
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])

        let viewModel = makeViewModel(
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Request-Edit")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        let updatedRequest = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/events?sessionToken=new",
            headers: [
                HTTPHeaderField(name: "Authorization", value: "Bearer new-token"),
                HTTPHeaderField(name: "X-Debug", value: "1")
            ],
            bodyData: Data("{\"sessionToken\":\"new\"}".utf8),
            bodySize: "{\"sessionToken\":\"new\"}".count
        )

        viewModel.updateBookmarkRequest(updatedRequest, for: bookmark.id)

        XCTAssertEqual(viewModel.selectedBookmark?.request.path, "/events?sessionToken=new")
        XCTAssertEqual(viewModel.selectedBookmark?.request.headers.count, 2)
        XCTAssertEqual(
            String(data: viewModel.selectedBookmark?.request.bodyData ?? Data(), encoding: .utf8),
            "{\"sessionToken\":\"new\"}"
        )
        XCTAssertEqual(bookmarkStore.loadBookmarks().first?.request.path, "/events?sessionToken=new")
        XCTAssertEqual(bookmarkStore.loadBookmarks().first?.request.headers.last?.name, "X-Debug")
        XCTAssertEqual(bookmarkStore.loadBookmarks().first?.request.bodySize, "{\"sessionToken\":\"new\"}".count)
        XCTAssertEqual(viewModel.selectedBookmark?.name, "GET api.example.com/events?sessionToken=new")
    }

    @MainActor
    func testBeginBookmarkUpdateFindsLatestMatchingSessions() throws {
        let bookmark = Bookmark(
            name: "Events",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events?sessionToken=old",
                headers: [HTTPHeaderField(name: "Authorization", value: "Bearer old")],
                bodyData: nil,
                bodySize: nil
            )
        )
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])
        let sessionStore = InMemorySessionStore()
        let older = makeSession(
            method: "GET",
            host: "api.example.com",
            path: "/events?sessionToken=older",
            startedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = makeSession(
            method: "GET",
            host: "api.example.com",
            path: "/events?sessionToken=new",
            startedAt: Date(timeIntervalSince1970: 20)
        )
        let differentPath = makeSession(
            method: "GET",
            host: "api.example.com",
            path: "/profile",
            startedAt: Date(timeIntervalSince1970: 30)
        )
        sessionStore.append(older)
        sessionStore.append(newer)
        sessionStore.append(differentPath)

        let viewModel = makeViewModel(
            sessionStore: sessionStore,
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Update-Match")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.beginBookmarkUpdate(id: bookmark.id)

        XCTAssertEqual(viewModel.bookmarkUpdateContext?.bookmarkID, bookmark.id)
        XCTAssertEqual(viewModel.bookmarkUpdateContext?.candidateSessionIDs, [newer.id, older.id])
        XCTAssertEqual(viewModel.selectedSessionID, newer.id)
    }

    @MainActor
    func testApplyBookmarkUpdateAuthAndCookiesMergesTokenFieldsWithoutReplacingTransportHeaders() throws {
        let bookmark = Bookmark(
            name: "Events",
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events?sessionToken=old&view=compact",
                headers: [
                    HTTPHeaderField(name: "Authorization", value: "Bearer old"),
                    HTTPHeaderField(name: "Cookie", value: "session=old"),
                    HTTPHeaderField(name: "Host", value: "api.example.com")
                ],
                bodyData: Data("{\"sessionToken\":\"old\",\"name\":\"stable\"}".utf8),
                bodySize: "{\"sessionToken\":\"old\",\"name\":\"stable\"}".count
            )
        )
        let sourceSession = SessionRecord(
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events?sessionToken=new&view=compact",
                headers: [
                    HTTPHeaderField(name: "Authorization", value: "Bearer new"),
                    HTTPHeaderField(name: "Cookie", value: "session=new"),
                    HTTPHeaderField(name: "Host", value: "override.example.com")
                ],
                bodyData: Data("{\"sessionToken\":\"new\",\"name\":\"stable\"}".utf8),
                bodySize: "{\"sessionToken\":\"new\",\"name\":\"stable\"}".count
            ),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])
        let sessionStore = InMemorySessionStore()
        sessionStore.append(sourceSession)

        let viewModel = makeViewModel(
            sessionStore: sessionStore,
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Update-Apply")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.applyBookmarkUpdate(
            bookmarkID: bookmark.id,
            sourceSessionID: sourceSession.id,
            preset: .authAndCookies
        )

        let updatedBookmark = try XCTUnwrap(viewModel.selectedBookmark)
        XCTAssertEqual(updatedBookmark.request.headers.first(where: { $0.name == "Authorization" })?.value, "Bearer new")
        XCTAssertEqual(updatedBookmark.request.headers.first(where: { $0.name == "Cookie" })?.value, "session=new")
        XCTAssertEqual(updatedBookmark.request.headers.first(where: { $0.name == "Host" })?.value, "api.example.com")
        XCTAssertEqual(updatedBookmark.request.path, "/events?sessionToken=new&view=compact")
        XCTAssertEqual(
            String(data: updatedBookmark.request.bodyData ?? Data(), encoding: .utf8),
            "{\"name\":\"stable\",\"sessionToken\":\"new\"}"
        )
    }

    @MainActor
    func testBookmarkUpdateRejectsTunneledSourceSession() throws {
        let bookmark = Bookmark(
            name: "Events",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events",
                headers: [],
                bodyData: nil,
                bodySize: nil
            )
        )
        let sourceSession = SessionRecord(
            request: CapturedRequest(
                method: "CONNECT",
                scheme: .https,
                inspectionKind: .tunneledTLS,
                inspectionReason: "Built-in compatibility bypass",
                host: "gateway.icloud.com",
                port: 443,
                path: "/",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: nil,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])
        let sessionStore = InMemorySessionStore()
        sessionStore.append(sourceSession)

        let viewModel = makeViewModel(
            sessionStore: sessionStore,
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Update-Tunneled")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        XCTAssertFalse(viewModel.canUseSessionForBookmarkUpdate(sourceSession.id))
        XCTAssertNotNil(viewModel.bookmarkUpdateLimitationMessage(for: sourceSession.id))

        viewModel.applyBookmarkUpdate(
            bookmarkID: bookmark.id,
            sourceSessionID: sourceSession.id,
            preset: .replaceEntireRequest
        )

        XCTAssertEqual(viewModel.selectedBookmark?.request.host, "api.example.com")
        XCTAssertEqual(
            viewModel.lastErrorMessage,
            "This session was tunneled without TLS decryption, so its request details are not safe to merge into a bookmark."
        )
    }

    @MainActor
    func testRefreshBookmarkAuthFromLatestMatchingSessionUsesNewestCompatibleMatch() throws {
        let bookmark = Bookmark(
            name: "Events",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events?sessionToken=old",
                headers: [
                    HTTPHeaderField(name: "Authorization", value: "Bearer old"),
                    HTTPHeaderField(name: "Cookie", value: "session=old")
                ],
                bodyData: nil,
                bodySize: nil
            )
        )
        let olderSource = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events?sessionToken=older",
                headers: [
                    HTTPHeaderField(name: "Authorization", value: "Bearer older"),
                    HTTPHeaderField(name: "Cookie", value: "session=older")
                ],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
            state: .completed,
            timing: SessionTiming(startedAt: Date(timeIntervalSince1970: 10))
        )
        let newestSource = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events?sessionToken=new",
                headers: [
                    HTTPHeaderField(name: "Authorization", value: "Bearer new"),
                    HTTPHeaderField(name: "Cookie", value: "session=new")
                ],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
            state: .completed,
            timing: SessionTiming(startedAt: Date(timeIntervalSince1970: 20))
        )
        let sessionStore = InMemorySessionStore()
        sessionStore.append(olderSource)
        sessionStore.append(newestSource)
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])

        let viewModel = makeViewModel(
            sessionStore: sessionStore,
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Refresh-FastPath")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        let refreshed = viewModel.refreshBookmarkAuthFromLatestMatchingSession(id: bookmark.id)

        XCTAssertTrue(refreshed)
        XCTAssertEqual(viewModel.selectedBookmark?.request.headers.first(where: { $0.name == "Authorization" })?.value, "Bearer new")
        XCTAssertEqual(viewModel.selectedBookmark?.request.headers.first(where: { $0.name == "Cookie" })?.value, "session=new")
        XCTAssertEqual(viewModel.selectedBookmark?.request.path, "/events?sessionToken=new")
        XCTAssertEqual(viewModel.selectedSessionID, newestSource.id)
    }

    @MainActor
    func testRefreshBookmarkAuthFromLatestMatchingSessionFailsWhenNoCompatibleSessionExists() throws {
        let bookmark = Bookmark(
            name: "Events",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events",
                headers: [],
                bodyData: nil,
                bodySize: nil
            )
        )
        let tunneledSource = SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .tunneledTLS,
                inspectionReason: "Built-in compatibility bypass",
                host: "api.example.com",
                port: 443,
                path: "/events",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: nil,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
        let sessionStore = InMemorySessionStore()
        sessionStore.append(tunneledSource)
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])

        let viewModel = makeViewModel(
            sessionStore: sessionStore,
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Refresh-NoMatch")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        let refreshed = viewModel.refreshBookmarkAuthFromLatestMatchingSession(id: bookmark.id)

        XCTAssertFalse(refreshed)
        XCTAssertEqual(
            viewModel.lastErrorMessage,
            "This session was tunneled without TLS decryption, so its request details are not safe to merge into a bookmark."
        )
    }

    @MainActor
    func testApplyBookmarkUpdateCustomMergesOnlySelectedFields() throws {
        let bookmark = Bookmark(
            name: "Events",
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events?sessionToken=old&view=compact",
                headers: [
                    HTTPHeaderField(name: "Authorization", value: "Bearer old"),
                    HTTPHeaderField(name: "X-Feature", value: "off")
                ],
                bodyData: Data("{\"sessionToken\":\"old\",\"name\":\"stable\",\"debug\":false}".utf8),
                bodySize: "{\"sessionToken\":\"old\",\"name\":\"stable\",\"debug\":false}".count
            )
        )
        let sourceSession = SessionRecord(
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events?sessionToken=new&view=expanded",
                headers: [
                    HTTPHeaderField(name: "Authorization", value: "Bearer new"),
                    HTTPHeaderField(name: "X-Feature", value: "on")
                ],
                bodyData: Data("{\"sessionToken\":\"new\",\"name\":\"changed\",\"debug\":true}".utf8),
                bodySize: "{\"sessionToken\":\"new\",\"name\":\"changed\",\"debug\":true}".count
            ),
            response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])
        let sessionStore = InMemorySessionStore()
        sessionStore.append(sourceSession)

        let viewModel = makeViewModel(
            sessionStore: sessionStore,
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Update-Custom")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.applyBookmarkUpdate(
            bookmarkID: bookmark.id,
            sourceSessionID: sourceSession.id,
            preset: .custom,
            customOptions: BookmarkCustomMergeOptions(
                headerNames: ["Authorization"],
                queryItemNames: ["sessionToken"],
                jsonBodyKeys: ["sessionToken"]
            )
        )

        let updatedBookmark = try XCTUnwrap(viewModel.selectedBookmark)
        XCTAssertEqual(updatedBookmark.request.headers.first(where: { $0.name == "Authorization" })?.value, "Bearer new")
        XCTAssertEqual(updatedBookmark.request.headers.first(where: { $0.name == "X-Feature" })?.value, "off")
        XCTAssertEqual(updatedBookmark.request.path, "/events?sessionToken=new&view=compact")
        XCTAssertEqual(
            String(data: updatedBookmark.request.bodyData ?? Data(), encoding: .utf8),
            "{\"debug\":false,\"name\":\"stable\",\"sessionToken\":\"new\"}"
        )
    }

    @MainActor
    func testDeleteSelectedBookmarkRemovesItAndFallsBackToNextBookmark() throws {
        let firstBookmark = Bookmark(
            name: "First",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/first",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let secondBookmark = Bookmark(
            name: "Second",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/second",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [firstBookmark, secondBookmark])

        let viewModel = makeViewModel(
            bookmarkStore: bookmarkStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Delete")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.selectedBookmarkID = secondBookmark.id
        viewModel.deleteSelectedBookmark()

        XCTAssertEqual(viewModel.bookmarkCount, 1)
        XCTAssertEqual(viewModel.selectedBookmark?.id, firstBookmark.id)
        XCTAssertEqual(bookmarkStore.loadBookmarks().map(\.id), [firstBookmark.id])
    }

    @MainActor
    func testExecuteBookmarkRequiresRunningProxy() async throws {
        let bookmark = Bookmark(
            name: "Events",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events",
                headers: [],
                bodyData: nil,
                bodySize: nil
            )
        )
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])
        let bookmarkExecutor = RecordingBookmarkExecutor()
        let viewModel = makeViewModel(
            bookmarkStore: bookmarkStore,
            bookmarkExecutor: bookmarkExecutor,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Execute-Stopped")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        let result = await viewModel.executeBookmark(id: bookmark.id)

        XCTAssertFalse(result)
        XCTAssertTrue(bookmarkExecutor.executedBookmarks.isEmpty)
        XCTAssertEqual(
            viewModel.bookmarkExecutionState,
            .failed(bookmarkID: bookmark.id, message: "Start the proxy to execute bookmarks.")
        )
    }

    @MainActor
    func testExecuteBookmarkRejectsInvalidEditedRequestBeforeExecutorRuns() async throws {
        let bookmark = Bookmark(
            name: "Broken",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api example.com",
                port: 443,
                path: "/events",
                headers: [HTTPHeaderField(name: "Bad Header", value: "1")],
                bodyData: nil,
                bodySize: nil
            )
        )
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 9090))
        let bookmarkExecutor = RecordingBookmarkExecutor()
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            bookmarkStore: InMemoryBookmarkStore(bookmarks: [bookmark]),
            bookmarkExecutor: bookmarkExecutor,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Execute-Invalid")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        let result = await viewModel.executeBookmark(id: bookmark.id)

        XCTAssertFalse(result)
        XCTAssertTrue(bookmarkExecutor.executedBookmarks.isEmpty)
        XCTAssertEqual(
            viewModel.bookmarkExecutionState,
            .failed(bookmarkID: bookmark.id, message: "Hosts cannot contain spaces.")
        )
        XCTAssertFalse(viewModel.canExecuteSelectedBookmark)
        XCTAssertEqual(viewModel.selectedBookmarkExecutionMessage, "Hosts cannot contain spaces.")
    }

    @MainActor
    func testExecuteBookmarkUpdatesLastExecutedAndSelectsMatchedSession() async throws {
        let bookmark = Bookmark(
            name: "Events",
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/events",
                headers: [HTTPHeaderField(name: "Accept", value: "application/json")],
                bodyData: nil,
                bodySize: nil
            )
        )
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 9090))
        let sessionStore = InMemorySessionStore()
        let bookmarkStore = InMemoryBookmarkStore(bookmarks: [bookmark])
        let bookmarkExecutor = RecordingBookmarkExecutor()
        bookmarkExecutor.executionHandler = { bookmark, _, _ in
            let startedAt = Date()
            sessionStore.append(
                SessionRecord(
                    request: bookmark.request,
                    response: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil),
                    state: .completed,
                    timing: SessionTiming(startedAt: startedAt, completedAt: startedAt.addingTimeInterval(0.15))
                )
            )
            return BookmarkExecutionResult(startedAt: startedAt)
        }

        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            sessionStore: sessionStore,
            bookmarkStore: bookmarkStore,
            bookmarkExecutor: bookmarkExecutor,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Execute-Running")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        let result = await viewModel.executeBookmark(id: bookmark.id)

        XCTAssertTrue(result)
        XCTAssertEqual(bookmarkExecutor.executedBookmarks.first?.proxyPort, 9090)
        XCTAssertEqual(viewModel.selectedSession?.request.host, "api.example.com")
        XCTAssertNotNil(viewModel.selectedBookmark?.lastExecutedAt)
        XCTAssertEqual(viewModel.bookmarkExecutionState, .idle)
    }

    @MainActor
    func testExecuteBookmarkNormalizesEditedPathHeadersAndBodyBeforeReplay() async throws {
        let bookmark = Bookmark(
            name: "Events",
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                host: " API.EXAMPLE.COM ",
                port: 443,
                path: "events?sessionToken=updated",
                headers: [
                    HTTPHeaderField(name: "Content-Type", value: "application/json"),
                    HTTPHeaderField(name: "X-Session ", value: " abc123 "),
                    HTTPHeaderField(name: "", value: "")
                ],
                bodyData: Data("{\"sessionToken\":\"updated\"}".utf8),
                bodySize: "{\"sessionToken\":\"updated\"}".count
            )
        )
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.running(port: 9090))
        let bookmarkExecutor = RecordingBookmarkExecutor()
        let viewModel = makeViewModel(
            proxyRuntime: runtime,
            bookmarkStore: InMemoryBookmarkStore(bookmarks: [bookmark]),
            bookmarkExecutor: bookmarkExecutor,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Bookmark-Execute-Normalized")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        let result = await viewModel.executeBookmark(id: bookmark.id)

        XCTAssertFalse(result)
        let executedBookmark = try XCTUnwrap(bookmarkExecutor.executedBookmarks.first?.bookmark)
        XCTAssertTrue(bookmarkExecutor.executedBookmarks.first?.proxyPort == 9090)
        XCTAssertEqual(executedBookmark.request.host, "api.example.com")
        XCTAssertEqual(executedBookmark.request.path, "/events?sessionToken=updated")
        XCTAssertEqual(
            executedBookmark.request.headers,
            [
                HTTPHeaderField(name: "Content-Type", value: "application/json"),
                HTTPHeaderField(name: "X-Session", value: "abc123")
            ]
        )
        XCTAssertEqual(
            String(data: executedBookmark.request.bodyData ?? Data(), encoding: .utf8),
            "{\"sessionToken\":\"updated\"}"
        )
        XCTAssertEqual(
            viewModel.bookmarkExecutionState,
            .failed(
                bookmarkID: bookmark.id,
                message: "The request completed, but JoesProxy could not match the captured session yet."
            )
        )
    }

    @MainActor
    func testViewModelLoadsPersistedSplitFractionFromConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Split-Load")
        configuration.sessionInspectorSplitFraction = 0.68

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Split-Load")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        XCTAssertEqual(viewModel.sessionInspectorSplitFraction, 0.68, accuracy: 0.0001)
    }

    @MainActor
    func testViewModelLoadsPersistedHTTPSRulesFromConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Rules-Load")
        configuration.httpsBypassDomains = ["media.example.com"]
        configuration.httpsInterceptDomains = ["api.example.com"]

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Rules-Load")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        XCTAssertEqual(viewModel.httpsBypassDomains, ["media.example.com"])
        XCTAssertEqual(viewModel.httpsInterceptDomains, ["api.example.com"])
    }

    @MainActor
    func testViewModelPersistsUpdatedSplitFractionToConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Split-Save")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Split-Save")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.sessionInspectorSplitFraction = 0.58

        XCTAssertEqual(configuration.sessionInspectorSplitFraction, 0.58, accuracy: 0.0001)
    }

    @MainActor
    func testViewModelPersistsUpdatedHTTPSRulesToConfiguration() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Rules-Save")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Rules-Save")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.addHTTPSBypassDomain("media.example.com")
        viewModel.addHTTPSInterceptDomain("api.example.com")

        XCTAssertEqual(configuration.httpsBypassDomains, ["media.example.com"])
        XCTAssertEqual(configuration.httpsInterceptDomains, ["api.example.com"])
    }

    @MainActor
    func testApplyProxyPortDraftPersistsValidPort() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Port-Valid")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Port-Valid")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.proxyPortDraft = "9191"

        try viewModel.applyProxyPortDraft()

        XCTAssertEqual(configuration.proxyPort, 9191)
        XCTAssertEqual(viewModel.proxyPortDraft, "9191")
    }

    @MainActor
    func testApplyProxyPortDraftRejectsInvalidPort() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Port-Invalid")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Port-Invalid")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.proxyPortDraft = "70000"

        XCTAssertThrowsError(try viewModel.applyProxyPortDraft())
        XCTAssertEqual(configuration.proxyPort, 8080)
    }

    @MainActor
    func testApplyProxyPortDraftClearsFailedStateAndLastError() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Port-Recover")
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.failed(message: "Port 8080 is already in use."))

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: runtime,
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Port-Recover")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        viewModel.lastErrorMessage = "Port 8080 is already in use."
        viewModel.proxyPortDraft = "9191"

        try viewModel.applyProxyPortDraft()

        XCTAssertEqual(viewModel.proxyState, .stopped)
        XCTAssertNil(viewModel.lastErrorMessage)
        XCTAssertEqual(configuration.proxyPort, 9191)
    }

    @MainActor
    func testStartProxyRejectsInvalidPortBeforeRuntimeStart() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Port-Start-Invalid")
        let runtime = TestProxyRuntime()
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: runtime,
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Port-Start-Invalid")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        viewModel.proxyPortDraft = "0"

        viewModel.startProxy()
        let expectedFailureMessage = NetworkFailureClassifier.presentation(for: ProxyError.invalidPort).userFacingMessage

        XCTAssertEqual(runtime.startCallCount, 0)
        XCTAssertEqual(viewModel.proxyState, .failed(message: expectedFailureMessage))
        XCTAssertEqual(viewModel.lastErrorMessage, expectedFailureMessage)
        XCTAssertEqual(configuration.proxyPort, 8080)
    }

    @MainActor
    func testResetPersistedPreferencesRestoresDefaultPortAndSort() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Reset-Defaults")
        configuration.proxyPort = 9191
        configuration.appTextSizeRawValue = AppTextSize.accessibility.rawValue
        configuration.sessionSortFieldRawValue = ProxyViewModel.SessionSortField.duration.rawValue
        configuration.isSessionSortAscending = true
        configuration.isSessionAutoScrollEnabled = false
        configuration.sessionBrowserModeRawValue = SessionBrowserMode.explorer.rawValue
        configuration.sessionExplorerGroupingRawValue = SessionExplorerGrouping.byEndpoint.rawValue
        configuration.sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.domainFamilies.rawValue
        configuration.sessionExplorerExpandedNodeIDs = ["host:api.example.com"]
        configuration.sessionInspectorSplitFraction = 0.54
        configuration.httpsBypassDomains = ["media.example.com"]
        configuration.httpsInterceptDomains = ["api.example.com"]
        configuration.captureRetentionPolicy = .keepLastSessions(2500)
        let runtime = TestProxyRuntime()
        runtime.stateSubject.send(.failed(message: "Port 9191 is already in use."))

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: runtime,
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Reset-Defaults")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        viewModel.lastErrorMessage = "Port 9191 is already in use."

        viewModel.resetPersistedPreferences()

        XCTAssertEqual(configuration.proxyPort, NetworkConstants.defaultPort)
        XCTAssertEqual(configuration.appTextSizeRawValue, AppTextSize.standard.rawValue)
        XCTAssertEqual(configuration.sessionSortFieldRawValue, ProxyViewModel.SessionSortField.startedAt.rawValue)
        XCTAssertFalse(configuration.isSessionSortAscending)
        XCTAssertTrue(configuration.isSessionAutoScrollEnabled)
        XCTAssertEqual(configuration.sessionBrowserModeRawValue, SessionBrowserMode.table.rawValue)
        XCTAssertEqual(configuration.sessionExplorerGroupingRawValue, SessionExplorerGrouping.byHost.rawValue)
        XCTAssertEqual(configuration.sessionExplorerHostGroupingRawValue, SessionExplorerHostGrouping.exactHosts.rawValue)
        XCTAssertEqual(configuration.sessionExplorerExpandedNodeIDs, [])
        XCTAssertEqual(configuration.sessionInspectorSplitFraction, 0.62, accuracy: 0.0001)
        XCTAssertEqual(configuration.httpsBypassDomains, [])
        XCTAssertEqual(configuration.httpsInterceptDomains, [])
        XCTAssertEqual(configuration.captureRetentionPolicy, .unlimited)
        XCTAssertEqual(viewModel.proxyPortDraft, String(NetworkConstants.defaultPort))
        XCTAssertEqual(viewModel.appTextSize, .standard)
        XCTAssertEqual(viewModel.sessionSortField, .startedAt)
        XCTAssertFalse(viewModel.isSessionSortAscending)
        XCTAssertTrue(viewModel.isSessionAutoScrollEnabled)
        XCTAssertEqual(viewModel.sessionFollowState, .followingLive)
        XCTAssertEqual(viewModel.sessionBrowserMode, .table)
        XCTAssertEqual(viewModel.sessionExplorerGrouping, .byHost)
        XCTAssertEqual(viewModel.sessionExplorerHostGrouping, .exactHosts)
        XCTAssertEqual(viewModel.sessionExplorerExpandedNodeIDs, [])
        XCTAssertEqual(viewModel.sessionInspectorSplitFraction, 0.62, accuracy: 0.0001)
        XCTAssertEqual(viewModel.httpsBypassDomains, [])
        XCTAssertEqual(viewModel.httpsInterceptDomains, [])
        XCTAssertEqual(viewModel.proxyState, .stopped)
        XCTAssertNil(viewModel.lastErrorMessage)
    }

    @MainActor
    func testDefaultProxyRuntimeUsesUpdatedConfigurationPortForStartingAndRunningStates() async throws {
        let initialPort = UInt16.random(in: 20_000...30_000)
        let updatedPort = UInt16.random(in: 30_001...40_000)
        let configuration = TestAppConfiguration(certificateLabel: "Port-Runtime")
        configuration.proxyPort = initialPort

        let server = ProxyServer(port: initialPort)
        let runtime = DefaultProxyRuntime(configuration: configuration, server: server)
        configuration.proxyPort = updatedPort

        var observedStates: [ProxyRuntimeState] = []
        let runningExpectation = expectation(description: "runtime reached running state")
        let cancellable = runtime.statePublisher.sink { state in
            observedStates.append(state)
            if case .running(let port) = state, port == updatedPort {
                runningExpectation.fulfill()
            }
        }

        await runtime.start()
        await fulfillment(of: [runningExpectation], timeout: 2.0)

        XCTAssertTrue(observedStates.contains(.starting(port: updatedPort)))
        XCTAssertTrue(observedStates.contains(.running(port: updatedPort)))
        XCTAssertEqual(server.port, updatedPort)
        XCTAssertEqual(configuration.proxyPort, updatedPort)

        cancellable.cancel()
        await runtime.stop()
    }

    func testProxyServerDefaultsToLANReachableBindHost() {
        let server = ProxyServer(port: NetworkConstants.defaultPort)

        XCTAssertEqual(server.bindHost, NetworkConstants.defaultBindHost)
    }

    func testTLSInterceptionPolicyBypassesBuiltInAppleDomains() {
        XCTAssertEqual(
            TLSInterceptionPolicy.decision(for: "bag.itunes.apple.com", rules: .init()),
            .bypass(reason: "Built-in compatibility bypass: .apple.com")
        )
        XCTAssertEqual(
            TLSInterceptionPolicy.decision(for: "apps.mzstatic.com", rules: .init()),
            .bypass(reason: "Built-in compatibility bypass: .mzstatic.com")
        )
        XCTAssertEqual(
            TLSInterceptionPolicy.decision(for: "api.example.com", rules: .init()),
            .intercept(reason: "Default HTTPS inspection")
        )
    }

    func testTLSInterceptionPolicyUsesCustomRulesForNonProtectedHosts() {
        let rules = TLSInterceptionRules(
            bypassDomains: ["media.example.com"],
            interceptDomains: ["api.example.com"]
        )

        XCTAssertEqual(
            TLSInterceptionPolicy.decision(for: "media.example.com", rules: rules),
            .bypass(reason: "Matched bypass rule: media.example.com")
        )
        XCTAssertEqual(
            TLSInterceptionPolicy.decision(for: "api.example.com", rules: rules),
            .intercept(reason: "Matched intercept rule: api.example.com")
        )
    }

    @MainActor
    func testInterceptRuleCannotOverrideBuiltInCompatibilityBypass() throws {
        let configuration = TestAppConfiguration(certificateLabel: "Rules-Built-In")
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Rules-Built-In")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        viewModel.addHTTPSInterceptDomain("bag.itunes.apple.com")

        XCTAssertEqual(viewModel.httpsInterceptDomains, [])
        XCTAssertEqual(
            viewModel.lastErrorMessage,
            "bag.itunes.apple.com is covered by a built-in compatibility bypass and will continue to tunnel."
        )
    }

    func testSessionExplorerBuilderGroupsByHostAndNormalizesDynamicPathSegments() throws {
        let olderSession = makeSession(
            method: "GET",
            host: "api.example.com",
            path: "/v1/users/123/profile",
            startedAt: Date(timeIntervalSince1970: 10)
        )
        let newerSession = makeSession(
            method: "POST",
            host: "api.example.com",
            path: "/v1/users/456/profile?expand=full",
            startedAt: Date(timeIntervalSince1970: 20)
        )

        let tree = SessionExplorerBuilder.build(
            from: [SessionSummary(record: olderSession), SessionSummary(record: newerSession)],
            grouping: .byHost,
            hostGrouping: .exactHosts
        )

        let hostNode = try XCTUnwrap(tree.roots.first)
        XCTAssertEqual(hostNode.title, "api.example.com")
        XCTAssertEqual(hostNode.aggregateCount, 2)

        let v1Node = try XCTUnwrap(hostNode.children.first(where: { $0.title == "v1" }))
        let usersNode = try XCTUnwrap(v1Node.children.first(where: { $0.title == "users" }))
        let identifierNode = try XCTUnwrap(usersNode.children.first(where: { $0.title == ":id" }))
        let profileNode = try XCTUnwrap(identifierNode.children.first(where: { $0.title == "profile" }))

        XCTAssertEqual(profileNode.aggregateCount, 2)
        XCTAssertEqual(Set(profileNode.children.compactMap { $0.summary?.id }), [olderSession.id, newerSession.id])
    }

    func testSessionExplorerBuilderGroupsByEndpointAndAggregatesFailures() throws {
        let successSession = makeSession(
            method: "GET",
            host: "api.example.com",
            path: "/v1/orders/123",
            startedAt: Date(timeIntervalSince1970: 10)
        )
        var failedSession = makeSession(
            method: "GET",
            host: "worker.example.com",
            path: "/v1/orders/987",
            startedAt: Date(timeIntervalSince1970: 20)
        )
        failedSession.response = CapturedResponse(statusCode: 503, headers: [], bodyData: nil, bodySize: nil)

        let tree = SessionExplorerBuilder.build(
            from: [SessionSummary(record: successSession), SessionSummary(record: failedSession)],
            grouping: .byEndpoint,
            hostGrouping: .exactHosts
        )

        let v1Node = try XCTUnwrap(tree.roots.first(where: { $0.title == "v1" }))
        let ordersNode = try XCTUnwrap(v1Node.children.first(where: { $0.title == "orders" }))
        let identifierNode = try XCTUnwrap(ordersNode.children.first(where: { $0.title == ":id" }))

        XCTAssertEqual(identifierNode.aggregateCount, 2)
        XCTAssertEqual(identifierNode.failedCount, 1)
        XCTAssertEqual(identifierNode.children.map(\.title), ["api.example.com", "worker.example.com"])
        XCTAssertEqual(tree.leafNodeID(for: successSession.id), "session:\(successSession.id.uuidString)")
    }

    func testSessionExplorerBuilderGroupsHostsUnderDomainFamilies() throws {
        let appleConfigSession = makeSession(
            method: "GET",
            host: "configuration.apple.com",
            path: "/lookup",
            startedAt: Date(timeIntervalSince1970: 10)
        )
        let appleGatewaySession = makeSession(
            method: "POST",
            host: "gateway.icloud.com",
            path: "/bag",
            startedAt: Date(timeIntervalSince1970: 20)
        )
        let apiSession = makeSession(
            method: "GET",
            host: "api.example.com",
            path: "/v1/events",
            startedAt: Date(timeIntervalSince1970: 30)
        )

        let tree = SessionExplorerBuilder.build(
            from: [
                SessionSummary(record: appleConfigSession),
                SessionSummary(record: appleGatewaySession),
                SessionSummary(record: apiSession)
            ],
            grouping: .byHost,
            hostGrouping: .domainFamilies
        )

        let appleFamilyNode = try XCTUnwrap(tree.roots.first(where: { $0.title == "apple.com" }))
        XCTAssertEqual(appleFamilyNode.role, .domainFamily)
        XCTAssertEqual(appleFamilyNode.aggregateCount, 1)

        let appleHostNode = try XCTUnwrap(appleFamilyNode.children.first(where: { $0.title == "configuration.apple.com" }))
        XCTAssertEqual(appleHostNode.role, .host)
        XCTAssertEqual(appleHostNode.aggregateCount, 1)

        let icloudFamilyNode = try XCTUnwrap(tree.roots.first(where: { $0.title == "icloud.com" }))
        XCTAssertEqual(icloudFamilyNode.role, .domainFamily)
        XCTAssertEqual(icloudFamilyNode.children.map(\.title), ["gateway.icloud.com"])

        let exampleFamilyNode = try XCTUnwrap(tree.roots.first(where: { $0.title == "example.com" }))
        XCTAssertEqual(exampleFamilyNode.children.map(\.title), ["api.example.com"])
    }

    func testSessionExplorerTreeVisibleRowsOnlyIncludesExpandedChildren() throws {
        let firstSession = makeSession(
            method: "GET",
            host: "api.example.com",
            path: "/v1/users/123",
            startedAt: Date(timeIntervalSince1970: 10)
        )
        let secondSession = makeSession(
            method: "GET",
            host: "api.example.com",
            path: "/v1/orders/456",
            startedAt: Date(timeIntervalSince1970: 20)
        )

        let tree = SessionExplorerBuilder.build(
            from: [SessionSummary(record: firstSession), SessionSummary(record: secondSession)],
            grouping: .byHost,
            hostGrouping: .exactHosts
        )

        let collapsedRows = tree.visibleRows(expandedNodeIDs: [])
        XCTAssertEqual(collapsedRows.map(\.node.title), ["api.example.com"])

        let expandedRows = tree.visibleRows(
            expandedNodeIDs: [
                "host:api.example.com",
                "host:api.example.com|path:v1"
            ]
        )
        XCTAssertEqual(expandedRows.map(\.node.title), ["api.example.com", "v1", "orders", "users"])
        XCTAssertEqual(expandedRows.map(\.depth), [0, 1, 2, 2])
    }

    func testIOSDeviceTrustProfileExporterCreatesConfigurationProfileWithRootCertificatePayload() throws {
        let identity = try makeRootIdentity(label: "JoesProxy Root CA")
        let configuration = TestAppConfiguration(certificateLabel: identity.label)
        let certificateAuthority = FakeCertificateAuthority(currentIdentity: nil, createdIdentity: identity)
        let exporter = IOSDeviceTrustProfileExporter(
            configuration: configuration,
            certificateAuthority: certificateAuthority
        )
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mobileconfig")

        defer {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        try exporter.exportTrustProfile(to: destinationURL)

        let data = try Data(contentsOf: destinationURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let payloadType = plist["PayloadType"] as? String
        let payloadDisplayName = plist["PayloadDisplayName"] as? String
        let payloadContent = try XCTUnwrap(plist["PayloadContent"] as? [[String: Any]])
        let certificatePayload = try XCTUnwrap(payloadContent.first)

        XCTAssertEqual(payloadType, "Configuration")
        XCTAssertEqual(payloadDisplayName, "JoesProxy iOS Trust Profile")
        XCTAssertEqual(certificatePayload["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(certificatePayload["PayloadDisplayName"] as? String, identity.label)
        XCTAssertEqual(certificatePayload["PayloadContent"] as? Data, identity.certificateData)
        XCTAssertEqual(certificateAuthority.loadOrCreateCallCount, 1)
    }

    @MainActor
    func testExportIOSTrustProfileRecordsMetadataOnlySnapshot() throws {
        let identity = try makeRootIdentity(label: "Snapshot-iOS")
        let snapshotStore = InMemoryProfileSnapshotStore()
        let viewModel = makeViewModel(
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed),
            profileSnapshotStore: snapshotStore
        )
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mobileconfig")

        try viewModel.exportIOSTrustProfile(to: destinationURL)

        let snapshot = try XCTUnwrap(snapshotStore.loadSnapshots().first)
        XCTAssertEqual(snapshot.kind, .iosTrustProfile)
        XCTAssertEqual(snapshot.hostStrategy, .bonjourLocal)
        XCTAssertEqual(snapshot.resolvedHost, "TestMac.local")
        XCTAssertEqual(snapshot.proxyPort, 8080)
        XCTAssertEqual(snapshot.certificateLabel, identity.label)
        XCTAssertEqual(snapshot.certificateSHA256Fingerprint, ProfileSnapshotFactory.certificateFingerprint(from: identity.certificateData))
        XCTAssertEqual(snapshot.payloadIdentifiers, ["com.apple.security.root"])
    }

    @MainActor
    func testExportTVOSManagedProfileUsesBonjourHostAndRecordsSnapshot() throws {
        let identity = try makeRootIdentity(label: "Snapshot-tvOS")
        let snapshotStore = InMemoryProfileSnapshotStore()
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .installed),
            profileSnapshotStore: snapshotStore
        )
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mobileconfig")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        try viewModel.exportTVOSManagedProfile(to: destinationURL)

        let data = try Data(contentsOf: destinationURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let payloadContent = try XCTUnwrap(plist["PayloadContent"] as? [[String: Any]])
        let proxyPayload = try XCTUnwrap(payloadContent.first { $0["PayloadType"] as? String == "com.apple.proxy.http.global" })
        XCTAssertEqual(proxyPayload["ProxyServer"] as? String, "TestMac.local")
        XCTAssertEqual(proxyPayload["ProxyServerPort"] as? Int, 8080)

        let snapshot = try XCTUnwrap(snapshotStore.loadSnapshots().first)
        XCTAssertEqual(snapshot.kind, .tvOSManagedProxyProfile)
        XCTAssertEqual(snapshot.resolvedHost, "TestMac.local")
        XCTAssertEqual(snapshot.payloadIdentifiers, ["com.apple.proxy.http.global", "com.apple.security.root"])
    }

    @MainActor
    func testProfileSnapshotDiagnosisMarksPriorCertificateStaleAfterCertificateChanges() throws {
        let oldIdentity = try makeRootIdentity(label: "Snapshot-Old")
        let newIdentity = try makeRootIdentity(label: "Snapshot-New")
        let resolution = ProfileHostResolution(
            strategy: .bonjourLocal,
            requestedStrategy: .bonjourLocal,
            host: "TestMac.local",
            networkInfo: LocalNetworkInfo(lanIP: "192.168.1.5", bonjourName: "TestMac.local"),
            usedFallback: false
        )
        let staleSnapshot = ProfileSnapshotFactory.makeSnapshot(
            kind: .tvOSManagedProxyProfile,
            identity: oldIdentity,
            resolution: resolution,
            proxyPort: 8080,
            profileServerURL: nil,
            certificateLabel: oldIdentity.label
        )
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: newIdentity, createdIdentity: newIdentity),
            certificateStore: MutableCertificateStore(identity: newIdentity),
            trustInstaller: MutableTrustInstaller(status: .installed),
            profileSnapshotStore: InMemoryProfileSnapshotStore(snapshots: [staleSnapshot])
        )

        XCTAssertEqual(viewModel.profileSnapshotDiagnosis.health, .certificateChanged)
    }

    @MainActor
    func testWorkflowStateIsNotSetUpWhenNoStoredCAExists() throws {
        let certificateAuthority = FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "State-Create"))
        let certificateStore = MutableCertificateStore(identity: nil)
        let trustInstaller = MutableTrustInstaller(status: .notInstalled)
        let viewModel = makeViewModel(
            certificateAuthority: certificateAuthority,
            certificateStore: certificateStore,
            trustInstaller: trustInstaller
        )

        XCTAssertEqual(viewModel.certificateWorkflowState, .notSetUp)
        XCTAssertEqual(viewModel.certificatePrimaryActionTitle, "Create JoesProxy Root CA")
    }

    @MainActor
    func testWorkflowStateIsNotSetUpWhenStoredCAExistsButCertificateIsNotInstalled() throws {
        let identity = try makeRootIdentity(label: "State-Install")
        let certificateAuthority = FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity)
        let certificateStore = MutableCertificateStore(identity: identity)
        let trustInstaller = MutableTrustInstaller(status: .notInstalled)
        let viewModel = makeViewModel(
            certificateAuthority: certificateAuthority,
            certificateStore: certificateStore,
            trustInstaller: trustInstaller
        )

        XCTAssertEqual(viewModel.certificateWorkflowState, .notSetUp)
        XCTAssertEqual(viewModel.certificatePrimaryActionTitle, "Install In Login Keychain")
    }

    @MainActor
    func testWorkflowStateIsInstalledTrustRequiredWhenCertificateNeedsTrust() throws {
        let identity = try makeRootIdentity(label: "State-Trust")
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .trustRequired(reason: "Not trusted"))
        )

        XCTAssertEqual(viewModel.certificateWorkflowState, .installedTrustRequired)
        XCTAssertEqual(viewModel.certificatePrimaryActionTitle, "Check Again")
    }

    @MainActor
    func testWorkflowStateIsNeedsCleanupWhenTrustStatusIsInvalid() throws {
        let identity = try makeRootIdentity(label: "State-Cleanup")
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: MutableTrustInstaller(status: .invalid(reason: "Duplicate certificates"))
        )

        XCTAssertEqual(viewModel.certificateWorkflowState, .needsCleanup)
        XCTAssertEqual(viewModel.certificatePrimaryActionTitle, "Reset Certificate State")
    }

    @MainActor
    func testLifecycleCertificateStatusReaderDefersTrustCheckAndPublishesSnapshot() async throws {
        let identity = try makeRootIdentity(label: "State-Async")
        let trustInstaller = MutableTrustInstaller(status: .trustRequired(reason: "Synchronous check"))
        let statusReader = ImmediateCertificateStatusReader(
            snapshot: CertificateStatusSnapshot(rootCertificate: identity, trustStatus: .installed)
        )
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity),
            certificateStore: MutableCertificateStore(identity: identity),
            trustInstaller: trustInstaller,
            certificateStatusReader: statusReader
        )

        XCTAssertNil(viewModel.rootCertificate)
        XCTAssertEqual(viewModel.certificateWorkflowState, .notSetUp)
        XCTAssertEqual(trustInstaller.installationStatusCallCount, 0)
        XCTAssertEqual(viewModel.trustStatus, .notInstalled)

        viewModel.scheduleCertificateStatusRefresh()
        viewModel.scheduleCertificateStatusRefresh()
        for _ in 0..<20 where viewModel.trustStatus != .installed {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(viewModel.rootCertificate, identity)
        XCTAssertEqual(viewModel.trustStatus, .installed)
        XCTAssertEqual(trustInstaller.installationStatusCallCount, 0)
        let statusReadCount = await statusReader.callCount
        XCTAssertEqual(statusReadCount, 1)
    }

    @MainActor
    func testPerformPrimaryCertificateActionCreatesThenInstallsAcrossNotSetUpFlow() throws {
        let identity = try makeRootIdentity(label: "State-PrimaryAction")
        let certificateAuthority = FakeCertificateAuthority(currentIdentity: nil, createdIdentity: identity)
        let certificateStore = MutableCertificateStore(identity: nil)
        let trustInstaller = MutableTrustInstaller(status: .notInstalled)
        let viewModel = makeViewModel(
            certificateAuthority: certificateAuthority,
            certificateStore: certificateStore,
            trustInstaller: trustInstaller
        )

        viewModel.performPrimaryCertificateAction()

        XCTAssertEqual(certificateAuthority.loadOrCreateCallCount, 1)
        XCTAssertEqual(viewModel.certificatePrimaryActionTitle, "Install In Login Keychain")

        viewModel.performPrimaryCertificateAction()

        XCTAssertEqual(trustInstaller.installCallCount, 1)
    }

    @MainActor
    func testResetCertificateStateReportsPartialCleanupWhenManualWorkRemains() throws {
        let identity = try makeRootIdentity(label: "State-Reset")
        let certificateAuthority = FakeCertificateAuthority(currentIdentity: identity, createdIdentity: identity)
        let certificateStore = MutableCertificateStore(identity: identity)
        let trustInstaller = MutableTrustInstaller(
            status: .invalid(reason: "Duplicate certificates"),
            removeError: TestError.message("Keychain removal failed")
        )
        let viewModel = makeViewModel(
            certificateAuthority: certificateAuthority,
            certificateStore: certificateStore,
            trustInstaller: trustInstaller
        )

        viewModel.resetCertificateState()

        XCTAssertEqual(viewModel.trustAlertContext?.title, "Manual Cleanup Still Required")
        XCTAssertTrue(viewModel.lastErrorMessage?.contains("manual cleanup still required") == true)
        XCTAssertTrue(viewModel.lastErrorMessage?.contains("Installed certificate cleanup: Keychain removal failed") == true)
    }

    @MainActor
    func testCancelAndResetClearPendingRenewalKeychainMaterial() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        let store = MultiLabelCertificateStore()
        let provider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: store
        )
        let root = try provider.loadOrCreateRootCertificate()
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-renewal-meta-\(UUID().uuidString).json")
        let distributionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-renewal-dist-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: metadataURL)
            try? FileManager.default.removeItem(at: distributionURL)
        }
        let metadataStore = CAInstanceMetadataStore(persistenceURL: metadataURL)
        metadataStore.load()
        _ = try metadataStore.upsert(CAInstanceMetadata.makeCurrent(from: root))
        let distributionStore = CertificateDistributionRecordStore(persistenceURL: distributionURL)
        distributionStore.load()

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: provider,
            certificateStore: store,
            trustInstaller: MutableTrustInstaller(status: .installed),
            caInstanceMetadataStore: metadataStore,
            certificateDistributionRecordStore: distributionStore
        )
        viewModel.refreshCertificateStatus(didCreateNewRoot: false)

        _ = try viewModel.prepareCertificateRenewal()
        let activeShortCode = try XCTUnwrap(viewModel.certificateIdentity?.shortCode)
        let pendingLabel = PersistentCertificateAuthorityProvider.pendingRenewalLabel(
            baseLabel: configuration.certificateLabel,
            shortCode: activeShortCode
        )
        XCTAssertNotNil(store.loadRootCertificate(label: pendingLabel))

        try viewModel.cancelCertificateRenewal()
        XCTAssertNil(store.loadRootCertificate(label: pendingLabel))
        XCTAssertNil(viewModel.pendingCertificateRenewal)
        XCTAssertEqual(viewModel.certificateIdentity?.renewalState, .none)

        _ = try viewModel.prepareCertificateRenewal()
        XCTAssertNotNil(store.loadRootCertificate(label: pendingLabel))
        viewModel.resetCertificateState()
        XCTAssertNil(store.loadRootCertificate(label: pendingLabel))
        XCTAssertNil(store.loadRootCertificate(label: configuration.certificateLabel))
        XCTAssertTrue(metadataStore.pendingRenewalInstances().isEmpty)
    }

    @MainActor
    func testExportSharedRootPackageSetsOwnerOnlyPermissions() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        let store = MultiLabelCertificateStore()
        let provider = PersistentCertificateAuthorityProvider(
            configuration: configuration,
            certificateStore: store
        )
        _ = try provider.loadOrCreateRootCertificate()
        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: ResponseOverrideStore(),
            certificateAuthority: provider,
            certificateStore: store,
            trustInstaller: MutableTrustInstaller(status: .installed)
        )
        viewModel.refreshCertificateStatus(didCreateNewRoot: false)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-shared-root-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }
        try viewModel.exportSharedRootPackage(to: destination)

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.uint16Value & 0o777, 0o600)
    }

    @MainActor
    func testResetPersistedPreferencesClearsResponseOverridesToDefaults() async throws {
        let configuration = TestAppConfiguration(certificateLabel: "Overrides-Reset")
        let responseOverrideStore = ResponseOverrideStore()
        let session = makeSession(method: "GET", host: "api.example.com", path: "/reset")
        _ = try await responseOverrideStore.addCapturedResponseOverride(from: session)
        configuration.responseOverridesData = try await responseOverrideStore.persistedData()

        let viewModel = ProxyViewModel(
            configuration: configuration,
            httpsProxyMode: .intercepting,
            proxyRuntime: TestProxyRuntime(),
            sessionStore: InMemorySessionStore(),
            exportService: RecordingExportService(),
            bookmarkStore: InMemoryBookmarkStore(),
            bookmarkExecutor: RecordingBookmarkExecutor(),
            harExportService: RecordingExportService(),
            iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter(),
            responseOverrideStore: responseOverrideStore,
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "Overrides-Reset")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )

        await viewModel.initialResponseOverrideLoadTask.value
        XCTAssertEqual(viewModel.responseOverrides.count, 1)

        viewModel.resetPersistedPreferences()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !viewModel.responseOverrides.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(viewModel.responseOverrides.count, 0)
        XCTAssertNil(configuration.responseOverridesData)
    }

    @MainActor
    private func makeViewModel(
        proxyRuntime: TestProxyRuntime? = nil,
        sessionStore: InMemorySessionStore = InMemorySessionStore(),
        exportService: RecordingExportService = RecordingExportService(),
        bookmarkStore: InMemoryBookmarkStore = InMemoryBookmarkStore(),
        bookmarkExecutor: RecordingBookmarkExecutor = RecordingBookmarkExecutor(),
        harExportService: RecordingExportService = RecordingExportService(),
        iosDeviceTrustProfileExporter: RecordingIOSTrustProfileExporter = RecordingIOSTrustProfileExporter(),
        certificateAuthority: FakeCertificateAuthority,
        certificateStore: MutableCertificateStore,
        trustInstaller: MutableTrustInstaller,
        responseOverrideStore: ResponseOverrideStore = ResponseOverrideStore(),
        bookmarkResponseInterceptStore: BookmarkResponseInterceptStore = BookmarkResponseInterceptStore(),
        processMetricsSampler: any ProcessMetricsSampling = TestProcessMetricsSampler(),
        localNetworkInfoProvider: any LocalNetworkInfoProviding = StaticLocalNetworkInfoProvider(
            networkInfo: LocalNetworkInfo(lanIP: "192.168.1.5", bonjourName: "TestMac.local")
        ),
        profileSnapshotStore: (any ProfileSnapshotStoring)? = nil,
        certificateStatusReader: (any CertificateStatusReading)? = nil
    ) -> ProxyViewModel {
        let resolvedProxyRuntime = proxyRuntime ?? TestProxyRuntime()
        return ProxyViewModel(
            configuration: TestAppConfiguration(certificateLabel: certificateAuthority.createdIdentity.label),
            httpsProxyMode: .intercepting,
            proxyRuntime: resolvedProxyRuntime,
            sessionStore: sessionStore,
            exportService: exportService,
            bookmarkStore: bookmarkStore,
            bookmarkExecutor: bookmarkExecutor,
            harExportService: harExportService,
            iosDeviceTrustProfileExporter: iosDeviceTrustProfileExporter,
            responseOverrideStore: responseOverrideStore,
            bookmarkResponseInterceptStore: bookmarkResponseInterceptStore,
            certificateAuthority: certificateAuthority,
            certificateStore: certificateStore,
            trustInstaller: trustInstaller,
            certificateStatusReader: certificateStatusReader,
            processMetricsSampler: processMetricsSampler,
            localNetworkInfoProvider: localNetworkInfoProvider,
            profileSnapshotStore: profileSnapshotStore
        )
    }

    private func makeSession(
        method: String,
        host: String,
        path: String,
        startedAt: Date = Date(),
        inspectionKind: SessionInspectionKind = .plain,
        requestBody: String? = nil,
        response: CapturedResponse? = CapturedResponse(
            statusCode: 200,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: method,
                scheme: .https,
                inspectionKind: inspectionKind,
                host: host,
                port: 443,
                path: path,
                headers: [HTTPHeaderField(name: "Host", value: host)],
                bodyData: requestBody?.data(using: .utf8),
                bodySize: requestBody?.data(using: .utf8)?.count
            ),
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: startedAt, completedAt: startedAt.addingTimeInterval(0.2))
        )
    }

    @MainActor
    private func waitForFilteredSessions(
        _ viewModel: ProxyViewModel,
        expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            if viewModel.filteredSessions.count == expectedCount {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Timed out waiting for \(expectedCount) filtered sessions", file: file, line: line)
    }

    @MainActor
    private func waitForSessionFindResults(
        _ viewModel: ProxyViewModel,
        expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            if viewModel.sessionFindResults.count == expectedCount {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Timed out waiting for \(expectedCount) find results", file: file, line: line)
    }

    @MainActor
    private func waitForExplorerVisibleRows(
        _ viewModel: ProxyViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            if !viewModel.sessionExplorerTree.isEmpty && !viewModel.sessionExplorerVisibleRows.isEmpty {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Timed out waiting for explorer visible rows", file: file, line: line)
    }

    @MainActor
    private func waitForCaptureHealth(
        _ viewModel: ProxyViewModel,
        residentMemoryBytes: UInt64,
        cpuPercent: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            let metrics = viewModel.captureHealth.processMetrics
            if metrics.residentMemoryBytes == residentMemoryBytes,
               metrics.cpuPercent == cpuPercent {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Timed out waiting for capture health process metrics", file: file, line: line)
    }

    @MainActor
    private func waitForProxyState(
        _ viewModel: ProxyViewModel,
        matches predicate: (ProxyRuntimeState) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            if predicate(viewModel.proxyState) {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Timed out waiting for proxy state", file: file, line: line)
    }

    // MARK: - Synthetic collection injection wrapper (Compact Mode active-effects management panel)

    /// `SyntheticCollectionInjectionEngine.shared`'s own register/remove/clearAll behavior is
    /// already covered by `SyntheticCollectionInjectionEngineTests` — these only prove
    /// `ProxyViewModel`'s thin reactive wrapper around that process-wide singleton (the read/mutate
    /// surface the "Synthetic Collection Injection" section of `ResponseOverridesSheet` renders
    /// from) reads and writes through correctly.

    private func makeSyntheticInjectionPlan(name: String = "Mock EPG Test Channel") -> SyntheticCollectionInjectionPlan {
        SyntheticCollectionInjectionPlan(
            name: name,
            urlPattern: "*/epg/channels*",
            collectionKeypath: "$.channels"
        )
    }

    @MainActor
    func testRefreshSyntheticInjectionPlansReadsWhateverIsCurrentlyRegistered() throws {
        SyntheticCollectionInjectionEngine.shared.clearAllPlans()
        defer { SyntheticCollectionInjectionEngine.shared.clearAllPlans() }
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "SynthInject-Refresh")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        XCTAssertTrue(viewModel.syntheticInjectionPlans.isEmpty, "nothing registered yet")

        SyntheticCollectionInjectionEngine.shared.registerPlan(makeSyntheticInjectionPlan())
        XCTAssertTrue(viewModel.syntheticInjectionPlans.isEmpty, "stale until an explicit refresh — matches the sheet's own poll pattern")

        viewModel.refreshSyntheticInjectionPlans()
        XCTAssertEqual(viewModel.syntheticInjectionPlans.map(\.name), ["Mock EPG Test Channel"])
    }

    @MainActor
    func testSetSyntheticInjectionPlanEnabledReRegistersTheFlippedPlan() throws {
        SyntheticCollectionInjectionEngine.shared.clearAllPlans()
        defer { SyntheticCollectionInjectionEngine.shared.clearAllPlans() }
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "SynthInject-Toggle")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        let plan = makeSyntheticInjectionPlan()
        SyntheticCollectionInjectionEngine.shared.registerPlan(plan)
        viewModel.refreshSyntheticInjectionPlans()
        XCTAssertEqual(viewModel.syntheticInjectionPlans.first?.isEnabled, true)

        viewModel.setSyntheticInjectionPlanEnabled(false, id: plan.id)

        XCTAssertEqual(viewModel.syntheticInjectionPlans.first?.isEnabled, false, "view model's own array reflects it immediately")
        XCTAssertEqual(
            SyntheticCollectionInjectionEngine.shared.allPlans().first?.isEnabled,
            false,
            "the engine itself was actually updated, not just the view model's cached copy"
        )
    }

    @MainActor
    func testSetSyntheticInjectionPlanEnabledForUnknownIDIsANoOp() throws {
        SyntheticCollectionInjectionEngine.shared.clearAllPlans()
        defer { SyntheticCollectionInjectionEngine.shared.clearAllPlans() }
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "SynthInject-Unknown")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        SyntheticCollectionInjectionEngine.shared.registerPlan(makeSyntheticInjectionPlan())
        viewModel.refreshSyntheticInjectionPlans()

        viewModel.setSyntheticInjectionPlanEnabled(false, id: UUID())

        XCTAssertEqual(viewModel.syntheticInjectionPlans.first?.isEnabled, true, "unrelated ID must not touch the real plan")
    }

    @MainActor
    func testRemoveSyntheticInjectionPlanDeletesFromTheEngineAndRefreshes() throws {
        SyntheticCollectionInjectionEngine.shared.clearAllPlans()
        defer { SyntheticCollectionInjectionEngine.shared.clearAllPlans() }
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "SynthInject-Remove")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        let plan = makeSyntheticInjectionPlan()
        SyntheticCollectionInjectionEngine.shared.registerPlan(plan)
        viewModel.refreshSyntheticInjectionPlans()
        XCTAssertEqual(viewModel.syntheticInjectionPlans.count, 1)

        viewModel.removeSyntheticInjectionPlan(id: plan.id)

        XCTAssertTrue(viewModel.syntheticInjectionPlans.isEmpty)
        XCTAssertTrue(SyntheticCollectionInjectionEngine.shared.allPlans().isEmpty)
    }

    @MainActor
    func testClearAllSyntheticInjectionPlansRemovesEveryPlan() throws {
        SyntheticCollectionInjectionEngine.shared.clearAllPlans()
        defer { SyntheticCollectionInjectionEngine.shared.clearAllPlans() }
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "SynthInject-ClearAll")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        SyntheticCollectionInjectionEngine.shared.registerPlan(makeSyntheticInjectionPlan(name: "Plan A"))
        SyntheticCollectionInjectionEngine.shared.registerPlan(makeSyntheticInjectionPlan(name: "Plan B"))
        viewModel.refreshSyntheticInjectionPlans()
        XCTAssertEqual(viewModel.syntheticInjectionPlans.count, 2)

        viewModel.clearAllSyntheticInjectionPlans()

        XCTAssertTrue(viewModel.syntheticInjectionPlans.isEmpty)
        XCTAssertTrue(SyntheticCollectionInjectionEngine.shared.allPlans().isEmpty)
    }

    @MainActor
    func testRefreshSyntheticInjectionPlansSortsByNameForAStableDisplayOrder() throws {
        SyntheticCollectionInjectionEngine.shared.clearAllPlans()
        defer { SyntheticCollectionInjectionEngine.shared.clearAllPlans() }
        let viewModel = makeViewModel(
            certificateAuthority: FakeCertificateAuthority(currentIdentity: nil, createdIdentity: try makeRootIdentity(label: "SynthInject-Sort")),
            certificateStore: MutableCertificateStore(identity: nil),
            trustInstaller: MutableTrustInstaller(status: .notInstalled)
        )
        SyntheticCollectionInjectionEngine.shared.registerPlan(makeSyntheticInjectionPlan(name: "Zebra Feed"))
        SyntheticCollectionInjectionEngine.shared.registerPlan(makeSyntheticInjectionPlan(name: "Alpha Feed"))

        viewModel.refreshSyntheticInjectionPlans()

        XCTAssertEqual(viewModel.syntheticInjectionPlans.map(\.name), ["Alpha Feed", "Zebra Feed"])
    }
}

// MARK: - ProfileHostingServerTests

final class ProfileHostingServerTests: XCTestCase {
    /// Port reserved for profile server unit tests. Chosen to avoid conflict with the proxy
    /// listener (default 8080) and the live profile server (8765).
    private static let testPort: UInt16 = 18765

    /// Holds a reference to the server started in each test so `tearDown` can stop it.
    private var currentServer: ProfileHostingServer?

    override func tearDown() async throws {
        await currentServer?.stop()
        currentServer = nil
        // Allow time for the OS to release the port before the next test runs.
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    // MARK: Lifecycle

    func testStartSetsNonNilServerURL() async throws {
        let server = makeServer()
        currentServer = server
        try await server.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 150_000_000)

        let url = await server.serverURL
        XCTAssertNotNil(url, "serverURL must be set after a successful start")
    }

    func testStopClearsServerURL() async throws {
        let server = makeServer()
        try await server.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 100_000_000)
        await server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)

        let url = await server.serverURL
        XCTAssertNil(url, "serverURL must be nil after stop")
    }

    func testStopReleasesPortForRebind() async throws {
        let serverA = makeServer()
        try await serverA.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 100_000_000)
        await serverA.stop()
        // Give the OS time to fully release the port before re-binding.
        try await Task.sleep(nanoseconds: 500_000_000)

        let serverB = makeServer()
        currentServer = serverB
        // Should not throw — port must have been released cleanly.
        // If start() throws the test itself fails via the propagated error.
        try await serverB.start(port: Self.testPort)
        let url = await serverB.serverURL
        XCTAssertNotNil(url, "Second server must start after first server stops")
    }

    // MARK: Routes

    func testRootPathReturnsHTMLWithBothDownloadLinks() async throws {
        let server = makeServer()
        currentServer = server
        try await server.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession(configuration: .ephemeral).data(
            from: URL(string: "http://127.0.0.1:\(Self.testPort)/")!
        )
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let body = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertTrue(body.contains("/profile"), "Landing page must include a link to /profile")
        XCTAssertTrue(body.contains("/cert"),    "Landing page must include a link to /cert")
    }

    func testProfilePathReturnsAppleAspenConfigMIMEType() async throws {
        let identity = try makeRootIdentity(label: "ProfileServer-Profile")
        let server = makeServer(identity: identity)
        currentServer = server
        try await server.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession(configuration: .ephemeral).data(
            from: URL(string: "http://127.0.0.1:\(Self.testPort)/profile")!
        )
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertTrue(
            contentType.contains("application/x-apple-aspen-config"),
            "Expected .mobileconfig MIME type, got '\(contentType)'"
        )
        XCTAssertFalse(data.isEmpty, "Profile response body must not be empty")
    }

    /// Regression coverage for a real device (iPad, iPadOS 18.7.8) where a non-Safari browser
    /// downloaded `/profile` and saved it as a generic file that iOS's Files app then opened as
    /// plain XML instead of recognizing it as an installable configuration profile. `/profile`
    /// alone has no filename or extension for a client to fall back on if it isn't specifically
    /// honoring `Content-Type: application/x-apple-aspen-config` the way Safari does.
    /// `/profile.mobileconfig` gives any client an extension-bearing URL to save from directly.
    func testProfileMobileconfigPathReturnsSameResponseAsProfilePath() async throws {
        let identity = try makeRootIdentity(label: "ProfileServer-ProfileMobileconfig")
        let server = makeServer(identity: identity)
        currentServer = server
        try await server.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession(configuration: .ephemeral).data(
            from: URL(string: "http://127.0.0.1:\(Self.testPort)/profile.mobileconfig")!
        )
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertTrue(
            contentType.contains("application/x-apple-aspen-config"),
            "Expected .mobileconfig MIME type, got '\(contentType)'"
        )
        XCTAssertFalse(data.isEmpty, "Profile response body must not be empty")
    }

    /// A saved file's extension is the fallback signal for OS-level type recognition once a
    /// client has already left Safari's Content-Type-based interception path (e.g. Chrome on
    /// iOS saving to Files) — an explicit filename here is the difference between the OS seeing
    /// "JoesProxy.mobileconfig" and seeing an untyped temp name it can't map to a profile at all.
    func testProfilePathIncludesContentDispositionWithMobileconfigFilename() async throws {
        let identity = try makeRootIdentity(label: "ProfileServer-ContentDisposition")
        let server = makeServer(identity: identity)
        currentServer = server
        try await server.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 150_000_000)

        let (_, response) = try await URLSession(configuration: .ephemeral).data(
            from: URL(string: "http://127.0.0.1:\(Self.testPort)/profile.mobileconfig")!
        )
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition") ?? ""

        XCTAssertTrue(
            disposition.contains("filename=\"JoesProxy.mobileconfig\""),
            "Expected an explicit .mobileconfig filename, got Content-Disposition '\(disposition)'"
        )
    }

    func testCertPathReturnsX509MIMETypeAndCertificateBytes() async throws {
        let identity = try makeRootIdentity(label: "ProfileServer-Cert")
        let server = makeServer(identity: identity)
        currentServer = server
        try await server.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession(configuration: .ephemeral).data(
            from: URL(string: "http://127.0.0.1:\(Self.testPort)/cert")!
        )
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertTrue(
            contentType.contains("application/x-x509-ca-cert"),
            "Expected .cer MIME type, got '\(contentType)'"
        )
        XCTAssertEqual(data, identity.certificateData, "Response body must be the raw DER certificate bytes")
    }

    func testCertPathIncludesContentDispositionWithCerFilename() async throws {
        let identity = try makeRootIdentity(label: "ProfileServer-CertContentDisposition")
        let server = makeServer(identity: identity)
        currentServer = server
        try await server.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 150_000_000)

        let (_, response) = try await URLSession(configuration: .ephemeral).data(
            from: URL(string: "http://127.0.0.1:\(Self.testPort)/cert")!
        )
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition") ?? ""

        XCTAssertTrue(
            disposition.contains("filename=\"JoesProxy-Root-CA.cer\""),
            "Expected an explicit .cer filename, got Content-Disposition '\(disposition)'"
        )
    }

    func testRootPathLinksToTheExtensionBearingProfilePath() async throws {
        let server = makeServer()
        currentServer = server
        try await server.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, _) = try await URLSession(configuration: .ephemeral).data(
            from: URL(string: "http://127.0.0.1:\(Self.testPort)/")!
        )
        let body = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(
            body.contains(#"href="/profile.mobileconfig""#),
            "Landing page must link the extension-bearing path, not the bare /profile alias"
        )
    }

    // MARK: Error paths

    func testCertPathReturns503WhenNoCertificateIsAvailable() async throws {
        // identity: nil → FakeCertificateAuthority.currentRootCertificate() returns nil
        let server = makeServer(identity: nil)
        currentServer = server
        try await server.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 150_000_000)

        let (_, response) = try await URLSession(configuration: .ephemeral).data(
            from: URL(string: "http://127.0.0.1:\(Self.testPort)/cert")!
        )
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 503)
    }

    func testProfilePathReturns503WhenExporterThrows() async throws {
        let identity = try makeRootIdentity(label: "ProfileServer-ExportError")
        let server = makeServer(
            identity: identity,
            exportError: TestError.message("Simulated profile export failure")
        )
        currentServer = server
        try await server.start(port: Self.testPort)
        try await Task.sleep(nanoseconds: 150_000_000)

        let (_, response) = try await URLSession(configuration: .ephemeral).data(
            from: URL(string: "http://127.0.0.1:\(Self.testPort)/profile")!
        )
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 503)
    }

    // MARK: - Helpers

    private func makeServer(
        identity: RootCertificateIdentity? = nil,
        exportError: Error? = nil
    ) -> ProfileHostingServer {
        let fallbackIdentity = try! makeRootIdentity(label: "ProfileServer-Fallback")
        let ca = FakeCertificateAuthority(
            currentIdentity: identity,
            createdIdentity: identity ?? fallbackIdentity
        )
        let exporter = WritingIOSTrustProfileExporter(exportError: exportError)
        return ProfileHostingServer(certificateAuthority: ca, profileExporter: exporter)
    }
}

// MARK: - QRCodeViewTests

final class QRCodeViewTests: XCTestCase {

    func testMakeQRCodeImageReturnsNonNilForValidURLString() {
        let view = QRCodeView(urlString: "http://192.168.1.5:8765", size: 200)
        let image = view.makeQRCodeImage(for: "http://192.168.1.5:8765", size: 200)
        XCTAssertNotNil(image, "A valid URL string must produce a QR code image")
    }

    func testMakeQRCodeImageDimensionsMatchRequestedSize() {
        let requestedSize: CGFloat = 160
        let view = QRCodeView(urlString: "http://10.0.0.1:8765", size: requestedSize)
        let image = view.makeQRCodeImage(for: "http://10.0.0.1:8765", size: requestedSize)

        let nsImage = try! XCTUnwrap(image)
        XCTAssertEqual(nsImage.size.width,  requestedSize, accuracy: 1,
                       "Image width must match the requested size")
        XCTAssertEqual(nsImage.size.height, requestedSize, accuracy: 1,
                       "Image height must match the requested size")
    }

    func testMakeQRCodeImageReturnsNilForEmptyString() {
        let view = QRCodeView(urlString: "", size: 200)
        let image = view.makeQRCodeImage(for: "", size: 200)
        XCTAssertNil(image, "Empty URL string must return nil without crashing")
    }

    func testMakeQRCodeImageProducesDistinctImagesForDifferentSizes() throws {
        let view = QRCodeView(urlString: "http://192.168.0.100:8765/profile", size: 200)
        let sizes: [CGFloat] = [64, 128, 200, 300]
        for size in sizes {
            let image = view.makeQRCodeImage(for: "http://192.168.0.100:8765/profile", size: size)
            let nsImage = try XCTUnwrap(image, "Expected non-nil image for size \(size)")
            XCTAssertEqual(nsImage.size.width,  size, accuracy: 1)
            XCTAssertEqual(nsImage.size.height, size, accuracy: 1)
        }
    }
}

@MainActor
private final class TestProxyRuntime: ProxyRuntime {
    var startOperation: (() async -> Void)?
    let stateSubject = CurrentValueSubject<ProxyRuntimeState, Never>(.stopped)
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    var currentState: ProxyRuntimeState { stateSubject.value }
    var statePublisher: AnyPublisher<ProxyRuntimeState, Never> { stateSubject.eraseToAnyPublisher() }

    func start() async {
        startCallCount += 1
        await startOperation?()
    }

    func stop() async {
        stopCallCount += 1
    }

    func sdkEventServerStatus() async -> SDKEventServerStatus {
        .stopped
    }
}

private final class TestProcessMetricsSampler: ProcessMetricsSampling {
    private var samples: [AppProcessMetrics]
    private(set) var sampleCallCount = 0

    init(samples: [AppProcessMetrics] = [.empty]) {
        self.samples = samples
    }

    func sample() -> AppProcessMetrics {
        sampleCallCount += 1
        guard !samples.isEmpty else {
            return .empty
        }
        return samples.removeFirst()
    }
}

private final class RecordingExportService: ExportService {
    private(set) var exportedEnvelope: SessionExportEnvelope?
    private(set) var destinationURL: URL?
    private let exportError: Error?

    init(exportError: Error? = nil) {
        self.exportError = exportError
    }

    func export(_ envelope: SessionExportEnvelope, to destinationURL: URL) throws {
        if let exportError {
            throw exportError
        }

        exportedEnvelope = envelope
        self.destinationURL = destinationURL
    }
}

private final class RecordingIOSTrustProfileExporter: IOSDeviceTrustProfileExporting {
    private(set) var destinationURL: URL?
    private let exportError: Error?

    init(exportError: Error? = nil) {
        self.exportError = exportError
    }

    func exportTrustProfile(to destinationURL: URL) throws {
        if let exportError {
            throw exportError
        }

        self.destinationURL = destinationURL
    }
}

private final class InMemoryProfileSnapshotStore: ProfileSnapshotStoring {
    private var snapshots: [GeneratedProfileSnapshot]

    init(snapshots: [GeneratedProfileSnapshot] = []) {
        self.snapshots = snapshots
    }

    func loadSnapshots() -> [GeneratedProfileSnapshot] {
        snapshots
    }

    func appendSnapshot(_ snapshot: GeneratedProfileSnapshot) throws {
        snapshots.insert(snapshot, at: 0)
    }
}

private final class RecordingBookmarkExecutor: BookmarkExecuting {
    private(set) var executedBookmarks: [(bookmark: Bookmark, proxyPort: UInt16, stripCredentials: Bool)] = []
    var executionHandler: ((Bookmark, UInt16, Bool) async throws -> BookmarkExecutionResult)?

    func execute(
        bookmark: Bookmark,
        proxyPort: UInt16,
        stripCredentials: Bool
    ) async throws -> BookmarkExecutionResult {
        executedBookmarks.append((bookmark, proxyPort, stripCredentials))

        if let executionHandler {
            return try await executionHandler(bookmark, proxyPort, stripCredentials)
        }

        return BookmarkExecutionResult(startedAt: Date())
    }
}

private final class FakeCertificateAuthority: CertificateAuthorityProviding {
    private(set) var currentIdentity: RootCertificateIdentity?
    let createdIdentity: RootCertificateIdentity
    private(set) var loadOrCreateCallCount = 0

    init(currentIdentity: RootCertificateIdentity?, createdIdentity: RootCertificateIdentity) {
        self.currentIdentity = currentIdentity
        self.createdIdentity = createdIdentity
    }

    func currentRootCertificate() -> RootCertificateIdentity? {
        currentIdentity
    }

    func loadOrCreateRootCertificate() throws -> RootCertificateIdentity {
        loadOrCreateCallCount += 1
        currentIdentity = createdIdentity
        return createdIdentity
    }

    func issueLeafCertificate(for host: String) throws -> IssuedLeafCertificate {
        throw TestError.message("Not used in tests")
    }
}

private final class MutableCertificateStore: CertificateStore {
    var identity: RootCertificateIdentity?
    var removeError: Error?

    init(identity: RootCertificateIdentity?, removeError: Error? = nil) {
        self.identity = identity
        self.removeError = removeError
    }

    func loadRootCertificate(label: String) -> RootCertificateIdentity? {
        guard identity?.label == label else {
            return nil
        }
        return identity
    }

    func saveRootCertificate(_ identity: RootCertificateIdentity) throws {
        self.identity = identity
    }

    func removeRootCertificate(label: String) throws {
        if let removeError {
            throw removeError
        }
        if identity?.label == label {
            identity = nil
        }
    }
}

/// Multi-label store for renewal Keychain lifecycle tests (active + pending labels).
private final class MultiLabelCertificateStore: CertificateStore {
    private var roots: [String: RootCertificateIdentity] = [:]

    func loadRootCertificate(label: String) -> RootCertificateIdentity? {
        roots[label]
    }

    func saveRootCertificate(_ identity: RootCertificateIdentity) throws {
        roots[identity.label] = identity
    }

    func removeRootCertificate(label: String) throws {
        roots.removeValue(forKey: label)
    }
}

private final class MutableTrustInstaller: TrustInstalling {
    var status: TrustInstallationStatus
    var removeError: Error?
    private(set) var installCallCount = 0
    private(set) var installationStatusCallCount = 0

    init(status: TrustInstallationStatus, removeError: Error? = nil) {
        self.status = status
        self.removeError = removeError
    }

    func installationStatus(for label: String) -> TrustInstallationStatus {
        installationStatusCallCount += 1
        return status
    }

    func install(_ identity: RootCertificateIdentity) throws {
        installCallCount += 1
        status = .trustRequired(reason: "Not trusted")
    }

    func removeCertificate(label: String) throws {
        status = .notInstalled
        if let removeError {
            throw removeError
        }
    }
}

private actor ImmediateCertificateStatusReader: CertificateStatusReading {
    let snapshot: CertificateStatusSnapshot
    private(set) var callCount = 0

    init(snapshot: CertificateStatusSnapshot) {
        self.snapshot = snapshot
    }

    func readStatus() async -> CertificateStatusSnapshot {
        callCount += 1
        return snapshot
    }
}

private actor ClearSnapshotWriteGate {
    private(set) var snapshots: [[SessionRecord.ID]] = []
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func write(_ sessions: [SessionRecord]) async {
        snapshots.append(sessions.map(\.id))
        if !isOpen { await withCheckedContinuation { continuation = $0 } }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class TestAppConfiguration: AppConfiguration {
    var proxyPort: UInt16 = 8080 { didSet { didChangeSubject.send(()) } }
    var logLevel: AppLogLevel = .info { didSet { didChangeSubject.send(()) } }
    var verboseHTTPSLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var isFindDebugLoggingEnabled = false { didSet { didChangeSubject.send(()) } }
    var appTextSizeRawValue = AppTextSize.standard.rawValue { didSet { didChangeSubject.send(()) } }
    var isInspectorCopyRedactionEnabled = true { didSet { didChangeSubject.send(()) } }
    var sessionSortFieldRawValue = ProxyViewModel.SessionSortField.startedAt.rawValue { didSet { didChangeSubject.send(()) } }
    var isSessionSortAscending = false { didSet { didChangeSubject.send(()) } }
    var isSessionAutoScrollEnabled = true { didSet { didChangeSubject.send(()) } }
    var sessionBrowserModeRawValue = SessionBrowserMode.table.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerGroupingRawValue = SessionExplorerGrouping.byHost.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.exactHosts.rawValue { didSet { didChangeSubject.send(()) } }
    var sessionExplorerExpandedNodeIDs: [String] = [] { didSet { didChangeSubject.send(()) } }
    var sessionInspectorSplitFraction = 0.62 { didSet { didChangeSubject.send(()) } }
    var httpsBypassDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var httpsInterceptDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var isNoCachingEnabled = false { didSet { didChangeSubject.send(()) } }
    var noCachingDomains: [String] = [] { didSet { didChangeSubject.send(()) } }
    var isSystemProxyManagementEnabled = false { didSet { didChangeSubject.send(()) } }
    var systemProxyStrictCapture = false { didSet { didChangeSubject.send(()) } }
    var hasAcknowledgedSystemProxyRouting = false { didSet { didChangeSubject.send(()) } }
    var showSystemProxyMenuBarItem = true { didSet { didChangeSubject.send(()) } }
    var runInMenuBarOnly = false
    var onboardingProgressRecord = OnboardingProgressRecord(lifecycle: .notStarted) { didSet { didChangeSubject.send(()) } }
    var preferredWorkingView: WorkingViewPreference = .inspector { didSet { didChangeSubject.send(()) } }
    var hasCompletedInitialGuidedSetupPresentation = false { didSet { didChangeSubject.send(()) } }
    var warnsBeforeQuittingWithUnsavedSessions = true { didSet { didChangeSubject.send(()) } }
    var sdkEventServerEnabled = false { didSet { didChangeSubject.send(()) } }
    var sdkEventServerPort: UInt16 { 9091 }
    var networkThrottleConfiguration = NetworkThrottleConfiguration.defaults { didSet { didChangeSubject.send(()) } }
    var profileHostStrategyRawValue = ProfileHostStrategy.bonjourLocal.rawValue { didSet { didChangeSubject.send(()) } }
    var manualProfileHost = "" { didSet { didChangeSubject.send(()) } }
    var responseOverridesData: Data? { didSet { didChangeSubject.send(()) } }
    var captureRetentionPolicy: CaptureRetentionPolicy = .unlimited { didSet { didChangeSubject.send(()) } }
    let certificateLabel: String
    private let didChangeSubject = PassthroughSubject<Void, Never>()

    var didChangePublisher: AnyPublisher<Void, Never> {
        didChangeSubject.eraseToAnyPublisher()
    }

    init(certificateLabel: String) {
        self.certificateLabel = certificateLabel
    }

    func resetToDefaults() {
        proxyPort = NetworkConstants.defaultPort
        logLevel = .info
        verboseHTTPSLoggingEnabled = false
        isFindDebugLoggingEnabled = false
        appTextSizeRawValue = AppTextSize.standard.rawValue
        isInspectorCopyRedactionEnabled = true
        sessionSortFieldRawValue = ProxyViewModel.SessionSortField.startedAt.rawValue
        isSessionSortAscending = false
        isSessionAutoScrollEnabled = true
        sessionBrowserModeRawValue = SessionBrowserMode.table.rawValue
        sessionExplorerGroupingRawValue = SessionExplorerGrouping.byHost.rawValue
        sessionExplorerHostGroupingRawValue = SessionExplorerHostGrouping.exactHosts.rawValue
        sessionExplorerExpandedNodeIDs = []
        sessionInspectorSplitFraction = 0.62
        httpsBypassDomains = []
        httpsInterceptDomains = []
        isNoCachingEnabled = false
        noCachingDomains = []
        isSystemProxyManagementEnabled = false
        systemProxyStrictCapture = false
        hasAcknowledgedSystemProxyRouting = false
        showSystemProxyMenuBarItem = true
        runInMenuBarOnly = false
        onboardingProgressRecord = OnboardingProgressRecord(lifecycle: .notStarted)
        preferredWorkingView = .inspector
        hasCompletedInitialGuidedSetupPresentation = false
        warnsBeforeQuittingWithUnsavedSessions = true
        sdkEventServerEnabled = false
        networkThrottleConfiguration = .defaults
        profileHostStrategyRawValue = ProfileHostStrategy.bonjourLocal.rawValue
        manualProfileHost = ""
        responseOverridesData = nil
        captureRetentionPolicy = .unlimited
    }
}

private enum TestError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

private struct StaticLocalNetworkInfoProvider: LocalNetworkInfoProviding {
    let networkInfo: LocalNetworkInfo

    func current() -> LocalNetworkInfo {
        networkInfo
    }
}

private func makeRootIdentity(label: String) throws -> RootCertificateIdentity {
    try SwiftCertificateFactory().generateRootIdentity(label: label, commonName: label)
}

@MainActor
private func makeQuitPreservationDelegate(
    decision: AppDelegate.QuitPreservationDecision,
    saveSucceeds: Bool,
    suppressFutureWarnings: Bool = false,
    onSave: (() -> Void)? = nil
) -> AppDelegate {
    let delegate = AppDelegate()
    delegate.hasUnsavedSessions = { true }
    delegate.shouldWarnBeforeQuit = { true }
    delegate.setShouldWarnBeforeQuit = { _ in }
    delegate.saveRecordingBeforeQuit = {
        onSave?()
        return saveSucceeds
    }
    delegate.presentQuitPreservationAlertForTesting = {
        AppDelegate.QuitPreservationAlertResult(
            decision: decision,
            suppressFutureWarnings: suppressFutureWarnings
        )
    }
    return delegate
}

@MainActor
private func waitForSettingsUpdate(
    _ condition: () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    // Settings reloads are RunLoop-debounced, not ordered by a DispatchQueue drain marker.
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out waiting for settings to reload from configuration", file: file, line: line)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForMainQueueDrain(
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let expectation = XCTestExpectation(description: "Main queue drain")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    let result = XCTWaiter.wait(for: [expectation], timeout: 5.0)
    XCTAssertEqual(result, .completed, file: file, line: line)
}

// MARK: - WritingIOSTrustProfileExporter (ProfileHostingServerTests helper)

/// A test double for `IOSDeviceTrustProfileExporting` that writes a minimal stub payload to
/// the destination URL, allowing `ProfileHostingServer.profileResponse()` to read real bytes
/// back and produce a non-empty HTTP response.
private final class WritingIOSTrustProfileExporter: IOSDeviceTrustProfileExporting {
    private let exportError: Error?
    private static let stubPayload = Data("stub-profile-payload".utf8)

    init(exportError: Error? = nil) {
        self.exportError = exportError
    }

    func exportTrustProfile(to destinationURL: URL) throws {
        if let exportError { throw exportError }
        try Self.stubPayload.write(to: destinationURL)
    }
}

// MARK: - SystemProxyRoutingModelTests

@MainActor
final class SystemProxyRoutingModelTests: XCTestCase {
    func testFirstEnableRaisesConsentWithoutArming() {
        let configuration = TestAppConfiguration(certificateLabel: "RoutingModel-Test")
        let model = SystemProxyRoutingModel(configuration: configuration)

        model.isRoutingEnabled = true

        XCTAssertTrue(model.pendingConsent)
        XCTAssertFalse(configuration.isSystemProxyManagementEnabled)
        XCTAssertFalse(model.isRoutingEnabled)
    }

    func testConfirmConsentArmsRoutingAndPersistsAcknowledgement() {
        let configuration = TestAppConfiguration(certificateLabel: "RoutingModel-Test")
        let model = SystemProxyRoutingModel(configuration: configuration)

        model.isRoutingEnabled = true
        model.confirmConsent()

        XCTAssertFalse(model.pendingConsent)
        XCTAssertTrue(configuration.hasAcknowledgedSystemProxyRouting)
        XCTAssertTrue(configuration.isSystemProxyManagementEnabled)
        XCTAssertTrue(model.isRoutingEnabled)
    }

    func testCancelConsentLeavesRoutingDisabled() {
        let configuration = TestAppConfiguration(certificateLabel: "RoutingModel-Test")
        let model = SystemProxyRoutingModel(configuration: configuration)

        model.isRoutingEnabled = true
        model.cancelConsent()

        XCTAssertFalse(model.pendingConsent)
        XCTAssertFalse(configuration.hasAcknowledgedSystemProxyRouting)
        XCTAssertFalse(model.isRoutingEnabled)
    }

    func testToggleAppliesDirectlyAfterAcknowledgement() {
        let configuration = TestAppConfiguration(certificateLabel: "RoutingModel-Test")
        configuration.hasAcknowledgedSystemProxyRouting = true
        let model = SystemProxyRoutingModel(configuration: configuration)

        model.isRoutingEnabled = true
        XCTAssertTrue(configuration.isSystemProxyManagementEnabled)
        XCTAssertFalse(model.pendingConsent)

        model.isRoutingEnabled = false
        XCTAssertFalse(configuration.isSystemProxyManagementEnabled)
    }

    func testExternalConfigurationChangePublishes() {
        let configuration = TestAppConfiguration(certificateLabel: "RoutingModel-Test")
        configuration.hasAcknowledgedSystemProxyRouting = true
        let model = SystemProxyRoutingModel(configuration: configuration)

        let expectation = XCTestExpectation(description: "objectWillChange fires on external config change")
        let cancellable = model.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        // Simulates the toggle being flipped from another surface (Settings, walkthrough).
        configuration.isSystemProxyManagementEnabled = true

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(model.isRoutingEnabled)
        cancellable.cancel()
    }

    func testConsentMessageReflectsStrictCaptureMode() {
        let configuration = TestAppConfiguration(certificateLabel: "RoutingModel-Test")
        let model = SystemProxyRoutingModel(configuration: configuration)

        XCTAssertEqual(model.consentMessage, SystemProxyRoutingCopy.consentMessage(strictCapture: false))

        configuration.systemProxyStrictCapture = true
        XCTAssertEqual(model.consentMessage, SystemProxyRoutingCopy.consentMessage(strictCapture: true))
    }
}
