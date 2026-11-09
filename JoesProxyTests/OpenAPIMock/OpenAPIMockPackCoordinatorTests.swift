import XCTest
@testable import JoesProxy

/// AW-3 runtime: atomic activate/rollback, ownership, quotas, expiry, fail-open, relaunch.
@MainActor
final class OpenAPIMockPackCoordinatorTests: XCTestCase {
    private let packID = OpenAPIMockPackID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let bookmark = OpenAPIDocumentBookmark(data: Data([1, 2, 3, 4]))

    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OpenAPI", isDirectory: true)
    }

    func testCatalogActivateServesTemplateAndFailsOpenOnStream() async throws {
        let (coordinator, store) = makeCoordinator()
        let compiled = try compileCatalog()
        let pack = try await coordinator.activate(
            compiled: compiled,
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        XCTAssertTrue(pack.isServing)

        let item = await store.decision(for: request(path: "/v1/items/item-2"))
        XCTAssertEqual(item?.routeID, "GET /v1/items/{itemId}")
        XCTAssertEqual(item?.status, 200)
        XCTAssertEqual(item?.packID, packID)

        let stream = await store.decision(for: request(path: "/v1/stream"))
        XCTAssertNil(stream)
        let metrics = await store.metrics(packID: packID)
        XCTAssertEqual(metrics.hits, 1)
        XCTAssertEqual(metrics.misses, 1)
        XCTAssertEqual(metrics.operationHits["GET /v1/items/{itemId}"], 1)
    }

    func testNamedErrorVariantIsSelectableWithoutGuessingDefault() async throws {
        let (coordinator, store) = makeCoordinator()
        try await coordinator.activate(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        let missing = await store.decision(
            for: request(
                path: "/v1/items/item-missing",
                headers: [HTTPHeaderField(name: OpenAPIMockMatchRequest.variantHeaderName, value: "not_found")]
            )
        )
        XCTAssertEqual(missing?.status, 404)
        XCTAssertEqual(missing?.variant.name, "not_found")

        let defaultItem = await store.decision(for: request(path: "/v1/items/item-missing"))
        XCTAssertEqual(defaultItem?.status, 200)
    }

    func testDeterministicReplayReturnsSameBytes() async throws {
        let (coordinator, store) = makeCoordinator()
        try await coordinator.activate(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        let firstDecision = await store.decision(for: request(path: "/v1/health"))
        let secondDecision = await store.decision(for: request(path: "/v1/health"))
        let first = try XCTUnwrap(firstDecision)
        let second = try XCTUnwrap(secondDecision)
        XCTAssertEqual(first.body, second.body)
        XCTAssertEqual(first.variant.bodyDigest, second.variant.bodyDigest)
    }

    func testStopDropsRoutingBeforeStateChange() async throws {
        let (coordinator, store) = makeCoordinator()
        try await coordinator.activate(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        let stopped = try await coordinator.stop(id: packID, requestingOwnerID: OpenAPIMockPackCoordinator.localUserOwnerID)
        XCTAssertEqual(stopped.state, .stopped)
        let afterStop = await store.decision(for: request(path: "/v1/health"))
        XCTAssertNil(afterStop)
    }

    func testOwnershipIsolation() async throws {
        let (coordinator, _) = makeCoordinator()
        try await coordinator.activate(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        do {
            _ = try await coordinator.stop(id: packID, requestingOwnerID: "other-client")
            XCTFail("expected notOwner")
        } catch {
            XCTAssertEqual(error as? OpenAPIMockPackError, .notOwner)
        }
        let stillServingPack = await coordinator.pack(id: packID)
        let stillServing = try XCTUnwrap(stillServingPack)
        XCTAssertTrue(stillServing.isServing)
    }

    func testOwnerQuotaRejectsSecondActivePack() async throws {
        let (coordinator, _) = makeCoordinator()
        try await coordinator.activate(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        do {
            _ = try await coordinator.activate(
                compiled: try compileCatalog(),
                owner: .localUser,
                documentBookmark: bookmark,
                packID: OpenAPIMockPackID(rawValue: UUID())
            )
            XCTFail("expected ownerSlotBusy")
        } catch {
            XCTAssertEqual(error as? OpenAPIMockPackError, .ownerSlotBusy)
        }
    }

    func testReplaceConflictsDisablesOverlappingMapLocalAndRollsBackOnPersistFailure() async throws {
        let overrideStore = ResponseOverrideStore()
        let overlapping = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .http,
            host: "catalog.example.invalid",
            port: 80,
            path: "/v1/health",
            sourceKind: .inlineText,
            sourceDescription: "overlap",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data(#"{"blocked":true}"#.utf8))
        )
        try await overrideStore.addRule(overlapping)
        try await overrideStore.setEnabled(true, for: overlapping.id)

        let (coordinator, _) = makeCoordinator(responseOverrideStore: overrideStore)
        let pack = try await coordinator.activate(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            conflictStrategy: .replaceConflicts,
            packID: packID
        )
        XCTAssertTrue(pack.isServing)
        let disabledRule = await overrideStore.rules().first { $0.id == overlapping.id }
        let disabled = try XCTUnwrap(disabledRule)
        XCTAssertFalse(disabled.isEnabled)

        let fileManager = FileManager.default
        let blocker = fileManager.temporaryDirectory.appendingPathComponent("openapi-mock-not-dir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        let failingCoordinator = OpenAPIMockPackCoordinator(
            routeStore: OpenAPIMockRouteStore(),
            responseOverrideStore: overrideStore,
            persistenceURL: blocker.appendingPathComponent("store.json"),
            clock: Date.init
        )
        try await overrideStore.setEnabled(true, for: overlapping.id)
        do {
            _ = try await failingCoordinator.activate(
                compiled: try compileCatalog(),
                owner: .localUser,
                documentBookmark: bookmark,
                conflictStrategy: .replaceConflicts
            )
            XCTFail("expected persist failure")
        } catch {
            XCTAssertNotNil(error)
        }
        let restoredRule = await overrideStore.rules().first { $0.id == overlapping.id }
        let restored = try XCTUnwrap(restoredRule)
        XCTAssertTrue(restored.isEnabled)
        let leftover = await failingCoordinator.routeStore.servingPackIDs()
        XCTAssertTrue(leftover.isEmpty)
    }

    func testMissingFixtureRefusesInstall() async throws {
        let (coordinator, store) = makeCoordinator()
        var compiled = try compileCatalog()
        compiled.routes = compiled.routes.map { route in
            var copy = route
            copy.variantIDs = ["missing-variant"]
            return copy
        }
        do {
            _ = try await coordinator.activate(
                compiled: compiled,
                owner: .localUser,
                documentBookmark: bookmark,
                packID: packID
            )
            XCTFail("expected missingFixture")
        } catch {
            XCTAssertEqual(error as? OpenAPIMockPackError, .missingFixture)
        }
        let leftoverDecision = await store.decision(for: request(path: "/v1/health"))
        XCTAssertNil(leftoverDecision)
        XCTAssertTrue(coordinator.packs.isEmpty)
    }

    func testExpiryStopsRouting() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let (coordinator, store) = makeCoordinator(clock: { clock.now })
        try await coordinator.activate(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            ttl: 10,
            packID: packID
        )
        clock.now = clock.now.addingTimeInterval(11)
        await coordinator.synchronizeMetricsAndExpiry()
        let expiredPack = await coordinator.pack(id: packID)
        let expired = try XCTUnwrap(expiredPack)
        XCTAssertEqual(expired.state, .expired)
        let expiredDecision = await store.decision(for: request(path: "/v1/health"))
        XCTAssertNil(expiredDecision)
    }

    func testRelaunchRestoresStoppedDefinitionWithoutLiveEffect() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("openapi-mock-relaunch-\(UUID().uuidString)", isDirectory: true)
        let persistenceURL = base.appendingPathComponent("packs.json")
        let first = OpenAPIMockPackCoordinator(
            routeStore: OpenAPIMockRouteStore(),
            persistenceURL: persistenceURL
        )
        try await first.activate(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        let firstLoaded = await first.pack(id: packID)
        let firstPack = try XCTUnwrap(firstLoaded)
        XCTAssertTrue(firstPack.isServing)

        let reloaded = OpenAPIMockPackCoordinator(
            routeStore: OpenAPIMockRouteStore(),
            persistenceURL: persistenceURL
        )
        let restoredPack = await reloaded.pack(id: packID)
        let restored = try XCTUnwrap(restoredPack)
        XCTAssertEqual(restored.state, .stopped)
        let relaunchDecision = await reloaded.routeStore.decision(for: request(path: "/v1/health"))
        XCTAssertNil(relaunchDecision)

        let restarted = try await reloaded.restart(id: packID)
        XCTAssertTrue(restarted.isServing)
        let restartedDecision = await reloaded.routeStore.decision(for: request(path: "/v1/health"))
        XCTAssertNotNil(restartedDecision)
    }

    func testConcurrentReadsAreStable() async throws {
        let (coordinator, store) = makeCoordinator()
        try await coordinator.activate(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        let captured = request(path: "/v1/health")
        let bodies = await withTaskGroup(of: Data?.self, returning: [Data?].self) { group in
            for _ in 0..<24 {
                group.addTask {
                    await store.decision(for: captured)?.body
                }
            }
            var collected: [Data?] = []
            for await body in group {
                collected.append(body)
            }
            return collected
        }
        let unique = Set(bodies.compactMap { $0 })
        XCTAssertEqual(unique.count, 1)
        XCTAssertEqual(bodies.count, 24)
    }

    func testPreparePersistsInactiveWithoutIntercept() async throws {
        let (coordinator, store) = makeCoordinator()
        let pack = try await coordinator.prepare(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        XCTAssertEqual(pack.state, .inactive)
        XCTAssertFalse(pack.isServing)
        let preparedDecision = await store.decision(for: request(path: "/v1/health"))
        XCTAssertNil(preparedDecision)

        let started = try await coordinator.restart(id: packID)
        XCTAssertTrue(started.isServing)
        let startedDecision = await store.decision(for: request(path: "/v1/health"))
        XCTAssertNotNil(startedDecision)
    }

    func testDiscardRemovesNonServingPackAndRefusesServing() async throws {
        let (coordinator, store) = makeCoordinator()
        try await coordinator.prepare(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        try await coordinator.discard(id: packID, requestingOwnerID: OpenAPIMockPackCoordinator.localUserOwnerID)
        let discarded = await coordinator.pack(id: packID)
        XCTAssertNil(discarded)
        XCTAssertNil(coordinator.compiledPack(id: packID))

        try await coordinator.activate(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        do {
            try await coordinator.discard(id: packID, requestingOwnerID: OpenAPIMockPackCoordinator.localUserOwnerID)
            XCTFail("expected packIsServing")
        } catch {
            XCTAssertEqual(error as? OpenAPIMockPackError, .packIsServing)
        }
        let stillServing = await store.decision(for: request(path: "/v1/health"))
        XCTAssertNotNil(stillServing)
    }

    func testRefuseConflictsReturnsOverlappingRuleList() async throws {
        let overrideStore = ResponseOverrideStore()
        let overlapping = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .http,
            host: "catalog.example.invalid",
            port: 80,
            path: "/v1/health",
            sourceKind: .inlineText,
            sourceDescription: "overlap",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data(#"{"blocked":true}"#.utf8))
        )
        try await overrideStore.addRule(overlapping)
        try await overrideStore.setEnabled(true, for: overlapping.id)

        let (coordinator, store) = makeCoordinator(responseOverrideStore: overrideStore)
        let compiled = try compileCatalog()
        let preview = await coordinator.previewActivation(
            compiled: compiled,
            owner: .localUser,
            packID: packID
        )
        guard case .refusedConflicts(let rules) = preview else {
            return XCTFail("expected refusedConflicts")
        }
        XCTAssertEqual(rules.map(\.ruleID), [overlapping.id])
        XCTAssertEqual(rules.first?.method, "GET")
        XCTAssertEqual(rules.first?.pathDescription, "/v1/health")

        do {
            _ = try await coordinator.activate(
                compiled: compiled,
                owner: .localUser,
                documentBookmark: bookmark,
                packID: packID
            )
            XCTFail("expected overlappingRules")
        } catch OpenAPIMockPackError.overlappingRules(let thrown) {
            XCTAssertEqual(thrown.map(\.ruleID), [overlapping.id])
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let refusedDecision = await store.decision(for: request(path: "/v1/health"))
        XCTAssertNil(refusedDecision)
    }

    func testAttributionCarriesPackOperationAndVariantWithoutURLQuery() async throws {
        let (coordinator, store) = makeCoordinator()
        try await coordinator.activate(
            compiled: try compileCatalog(),
            owner: .localUser,
            documentBookmark: bookmark,
            packID: packID
        )
        let capturedDecision = await store.decision(for: request(path: "/v1/items/item-1?debug=1"))
        let decision = try XCTUnwrap(capturedDecision)
        let provenance = MCPProvenance(
            clientID: OpenAPIMockPackCoordinator.localUserOwnerID,
            operationID: packID.rawValue.uuidString,
            capability: .overrideInspect,
            createdAt: Date()
        )
        let attribution = MCPSessionAttributionService.attributionForActiveEffects(
            effectKinds: [.openAPIMockPack],
            provenance: provenance,
            openAPIMockPackID: decision.packID.rawValue.uuidString,
            openAPIMockOperation: decision.routeID,
            openAPIMockVariantID: decision.variant.id
        )
        XCTAssertEqual(attribution?.openAPIMockPackID, packID.rawValue.uuidString)
        XCTAssertEqual(attribution?.openAPIMockOperation, "GET /v1/items/{itemId}")
        XCTAssertFalse(attribution?.openAPIMockOperation?.contains("debug") ?? true)
        XCTAssertFalse(attribution?.openAPIMockVariantID?.contains("?") ?? true)
    }

    private final class TestClock {
        var now: Date
        init(now: Date) { self.now = now }
    }

    private func makeCoordinator(
        responseOverrideStore: ResponseOverrideStore? = nil,
        clock: @escaping () -> Date = Date.init
    ) -> (OpenAPIMockPackCoordinator, OpenAPIMockRouteStore) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("openapi-mock-tests-\(UUID().uuidString)", isDirectory: true)
        let store = OpenAPIMockRouteStore()
        let coordinator = OpenAPIMockPackCoordinator(
            routeStore: store,
            responseOverrideStore: responseOverrideStore,
            persistenceURL: base.appendingPathComponent("packs.json"),
            clock: clock
        )
        return (coordinator, store)
    }

    private func compileCatalog() throws -> OpenAPIMockCompiledPack {
        let data = try Data(contentsOf: fixturesURL.appendingPathComponent("catalog-v1.json"))
        return try OpenAPIMockCompiler.compile(
            OpenAPIMockCompileRequest(document: data, packID: packID, originOverride: nil)
        )
    }

    private func request(
        path: String,
        headers: [HTTPHeaderField] = []
    ) -> CapturedRequest {
        CapturedRequest(
            method: "GET",
            scheme: .http,
            host: "catalog.example.invalid",
            port: 80,
            path: path,
            headers: headers,
            bodyData: nil,
            bodySize: nil
        )
    }
}
