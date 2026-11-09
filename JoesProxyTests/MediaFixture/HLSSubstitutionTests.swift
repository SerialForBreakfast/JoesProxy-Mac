import XCTest
@testable import JoesProxy

@MainActor
final class HLSSubstitutionTests: XCTestCase {
    private final class TestClock {
        var now: Date
        init(now: Date) { self.now = now }
    }

    private func fixtureRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS")
    }

    private func makeCoordinator(
        clock: TestClock,
        responseOverrideStore: ResponseOverrideStore? = nil,
        persistenceURL: URL? = nil
    ) -> (HLSSubstitutionCoordinator, HLSFixtureRunStore) {
        let registry = HLSFixtureOriginRegistry()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-substitution-tests-\(UUID().uuidString)", isDirectory: true)
        let runStore = HLSFixtureRunStore(
            persistenceURL: base.appendingPathComponent("runs.json"),
            profileRootURL: fixtureRoot(),
            originRegistry: registry,
            clock: { clock.now }
        )
        runStore.load()
        let coordinator = HLSSubstitutionCoordinator(
            runStore: runStore,
            routeStore: HLSSubstitutionRouteStore(),
            responseOverrideStore: responseOverrideStore,
            persistenceURL: persistenceURL ?? base.appendingPathComponent("experiments.json"),
            clock: { clock.now }
        )
        return (coordinator, runStore)
    }

    private func makeRequest(
        method: String = "GET",
        scheme: SessionScheme = .https,
        host: String = "media.example.com",
        port: Int = 443,
        path: String
    ) -> CapturedRequest {
        CapturedRequest(
            method: method,
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
    }

    private func experiment(scope: HLSSubstitutionScope) -> HLSSubstitutionExperiment {
        HLSSubstitutionExperiment(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            owner: .localUser,
            profileID: "player-qa-widescreen-v1",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
            scope: scope,
            mountPath: "/.joesproxy/hls-substitution/11111111-1111-1111-1111-111111111111/",
            fixtureRunID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
            state: .active,
            startedAt: Date(),
            expiresAt: Date().addingTimeInterval(1_800),
            stoppedAt: nil,
            metrics: HLSSubstitutionMetrics()
        )
    }

    func testSelectedPlaylistIgnoresQueryAndRoutesChildrenBeforeEntryMatching() async throws {
        let store = HLSSubstitutionRouteStore()
        let test = experiment(scope: .selectedPlaylist(path: "/live/master.m3u8?token=old"))
        try await store.install(test)

        let entry = await store.decision(for: makeRequest(path: "/live/master.m3u8?token=new"))
        XCTAssertEqual(entry?.fixturePath, "master.m3u8")
        if case .entryPlaylist? = entry?.kind {} else { XCTFail("Expected entry playlist") }

        let child = await store.decision(for: makeRequest(path: "\(test.mountPath)video-720/stream.m3u8"))
        XCTAssertEqual(child?.fixturePath, "video-720/stream.m3u8")
        if case .childPlaylist? = child?.kind {} else { XCTFail("Expected child playlist") }

        let segment = await store.decision(for: makeRequest(path: "\(test.mountPath)video-720/seg-000.ts"))
        if case .segment? = segment?.kind {} else { XCTFail("Expected segment") }

        let versioned = await store.decision(for: makeRequest(path: "\(test.mountPath)video-720/seg-000.ts?jp_hls_sequence=42"))
        XCTAssertEqual(versioned?.fixturePath, "video-720/seg-000.ts?jp_hls_sequence=42")

        let metrics = await store.metrics(experimentID: test.id)
        XCTAssertEqual(metrics.entryPlaylistHits, 1)
        XCTAssertEqual(metrics.childPlaylistHits, 1)
        XCTAssertEqual(metrics.segmentHits, 2)
    }

    func testHostScopeMatchesCaseInsensitiveExtensionOnlyOnExactOrigin() async throws {
        let store = HLSSubstitutionRouteStore()
        try await store.install(experiment(scope: .host))
        let matching = await store.decision(for: makeRequest(path: "/one/MASTER.M3U8?x=1"))
        let otherHost = await store.decision(for: makeRequest(host: "other.example.com", path: "/master.m3u8"))
        let segment = await store.decision(for: makeRequest(path: "/segment.ts"))
        let post = await store.decision(for: makeRequest(method: "POST", path: "/master.m3u8"))
        XCTAssertNotNil(matching)
        XCTAssertNil(otherHost)
        XCTAssertNil(segment)
        XCTAssertNil(post)
    }

    func testMasterRewriteRootsVariantAndMediaURIsAndPreservesHeadLength() throws {
        let source = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,URI="audio/stream.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100
        video/stream.m3u8
        """
        let response = HLSFixtureResponse(
            status: 200,
            headers: ["Content-Type": "application/vnd.apple.mpegurl"],
            body: Data(source.utf8)
        )
        let rewritten = HLSSubstitutionManifestRouter.rewriteMaster(
            response,
            mountPath: "/.joesproxy/hls-substitution/test/",
            method: "GET"
        )
        let text = try XCTUnwrap(String(data: rewritten.body, encoding: .utf8))
        XCTAssertTrue(text.contains("URI=\"/.joesproxy/hls-substitution/test/audio/stream.m3u8\""))
        XCTAssertTrue(text.contains("/.joesproxy/hls-substitution/test/video/stream.m3u8"))
        XCTAssertEqual(rewritten.headers["Cache-Control"], "no-store")

        let cacheable = HLSSubstitutionManifestRouter.rewriteMaster(
            response,
            mountPath: "/.joesproxy/hls-substitution/test/",
            method: "GET",
            cacheControlHeader: "max-age=12"
        )
        XCTAssertEqual(cacheable.headers["Cache-Control"], "max-age=12")

        let head = HLSSubstitutionManifestRouter.rewriteMaster(
            response,
            mountPath: "/.joesproxy/hls-substitution/test/",
            method: "HEAD"
        )
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.headers["Content-Length"], String(text.utf8.count))
    }

    func testRecommendedProfileMetadataIsDiscoverable() throws {
        let store = HLSFixtureRunStore(
            persistenceURL: FileManager.default.temporaryDirectory.appendingPathComponent("hls-profile-test-\(UUID().uuidString).json"),
            profileRootURL: fixtureRoot(),
            originRegistry: nil
        )
        store.load()
        let profile = try XCTUnwrap(store.availableProfileDescriptors().first(where: { $0.id == "player-qa-widescreen-v1" }))
        XCTAssertTrue(profile.isRecommended)
        XCTAssertEqual(profile.renditions.map(\.height), [360, 720, 1080])
        XCTAssertTrue(profile.featureTags.contains("timecode"))
        let audioRenditions = try XCTUnwrap(profile.audioRenditions)
        XCTAssertEqual(audioRenditions.map(\.language), ["en", "en", "es", "de"])
        XCTAssertEqual(audioRenditions.filter(\.isDefault).map(\.name), ["English Program"])
        XCTAssertEqual(
            audioRenditions.first { $0.name == "English Audio Description" }?.characteristics,
            ["public.accessibility.describes-video"]
        )
    }

    func testCoordinatorStartsAndStopsFixtureAndRouteAsOneExperiment() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 10_000))
        let (coordinator, runStore) = makeCoordinator(clock: clock)
        let started = try await coordinator.start(
            owner: .localUser,
            profileID: "player-qa-widescreen-v1",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
            scope: .selectedPlaylist(path: "/live/master.m3u8")
        )
        XCTAssertTrue(started.isActive)
        XCTAssertEqual(started.playbackConfiguration, .conformant)
        XCTAssertEqual(runStore.activeRuns(ownedBy: HLSSubstitutionCoordinator.localUserOwnerID).count, 1)
        let activeRoute = await coordinator.routeStore.decision(for: makeRequest(path: "/live/master.m3u8"))
        XCTAssertEqual(activeRoute?.experimentID, started.id)

        let stopped = try await coordinator.stop(id: started.id)
        XCTAssertEqual(stopped.state, .stopped)
        let stoppedRoute = await coordinator.routeStore.decision(for: makeRequest(path: "/live/master.m3u8"))
        XCTAssertNil(stoppedRoute)
        XCTAssertTrue(runStore.activeRuns(ownedBy: HLSSubstitutionCoordinator.localUserOwnerID).isEmpty)
    }

    func testCoordinatorRequiresExplicitReplacementAndDisablesOrdinaryConflict() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 20_000))
        let overrideStore = ResponseOverrideStore()
        let conflictingRule = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "media.example.com",
            port: 443,
            path: "/live/master.m3u8",
            sourceKind: .inlineText,
            sourceDescription: "Existing response",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data())
        )
        try await overrideStore.addRule(conflictingRule)
        let (coordinator, _) = makeCoordinator(clock: clock, responseOverrideStore: overrideStore)
        do {
            _ = try await coordinator.start(
                owner: .localUser,
                profileID: "player-qa-widescreen-v1",
                origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
                scope: .selectedPlaylist(path: "/live/master.m3u8")
            )
            XCTFail("Expected conflict")
        } catch HLSSubstitutionError.conflictingExperiment {
        }

        let started = try await coordinator.start(
            owner: .localUser,
            profileID: "player-qa-widescreen-v1",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
            scope: .selectedPlaylist(path: "/live/master.m3u8"),
            conflictStrategy: .replaceExisting
        )
        XCTAssertTrue(started.isActive)
        let disabledRule = await overrideStore.rule(id: conflictingRule.id)
        XCTAssertEqual(disabledRule?.isEnabled, false)
        _ = try await coordinator.stop(id: started.id)
    }

    func testExpiryRemovesRouteAndFailsOpen() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 30_000))
        let (coordinator, runStore) = makeCoordinator(clock: clock)
        let started = try await coordinator.start(
            owner: .localUser,
            profileID: "player-qa-widescreen-v1",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
            scope: .host
        )
        clock.now = try XCTUnwrap(started.expiresAt).addingTimeInterval(1)
        await coordinator.synchronizeMetricsAndExpiry()
        let loadedExperiment = await coordinator.experiment(id: started.id)
        let expired = try XCTUnwrap(loadedExperiment)
        XCTAssertEqual(expired.state, .expired)
        let route = await coordinator.routeStore.decision(for: makeRequest(path: "/anything.m3u8"))
        XCTAssertNil(route)
        XCTAssertTrue(runStore.activeRuns(ownedBy: HLSSubstitutionCoordinator.localUserOwnerID).isEmpty)
    }

    func testReloadMarksFormerlyActiveExperimentStoppedWithoutInstallingRoute() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 40_000))
        let policy = HLSRequestPolicy(clientAddress: "192.0.2.10", missingTextTrackID: nil)
        let persistenceURL = fixtureRoot().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/MediaLabRegression/hls-substitution-reload-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: persistenceURL) }
        let (first, runStore) = makeCoordinator(clock: clock, persistenceURL: persistenceURL)
        let started = try await first.start(
            owner: .localUser,
            profileID: "player-qa-widescreen-v1",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
            scope: .selectedPlaylist(path: "/live/master.m3u8"), requestPolicy: policy
        )

        clock.now = clock.now.addingTimeInterval(10)
        let reloaded = HLSSubstitutionCoordinator(
            runStore: runStore,
            routeStore: HLSSubstitutionRouteStore(),
            persistenceURL: persistenceURL,
            clock: { clock.now }
        )
        let recovered = try XCTUnwrap(reloaded.experiments.first(where: { $0.id == started.id }))
        XCTAssertEqual(recovered.state, .stopped)
        XCTAssertEqual(recovered.requestPolicy, policy)
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: persistenceURL)) as? [String: Any])
        XCTAssertEqual(persisted["schemaVersion"] as? Int, 2, "Old readers must reject scoped persistence")
        XCTAssertNil(recovered.fixtureRunID)
        let route = await reloaded.routeStore.decision(for: makeRequest(path: "/live/master.m3u8"))
        XCTAssertNil(route)
        _ = try await first.stop(id: started.id)
        var legacyExperiment = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(started)) as? [String: Any])
        legacyExperiment.removeValue(forKey: "requestPolicy")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "experiments": [legacyExperiment]])
            .write(to: persistenceURL)
        let legacy = HLSSubstitutionCoordinator(runStore: runStore, routeStore: HLSSubstitutionRouteStore(),
            persistenceURL: persistenceURL, clock: { clock.now })
        XCTAssertEqual(legacy.experiments.first?.state, .stopped)
        XCTAssertNil(legacy.experiments.first?.requestPolicy)
    }

    // MARK: - Configurable TTL / keep-alive (P2, memlog/Research/Feedback-Master-Synthesis-1.7.0-Agent-Hardening.md §6)

    func testStartWithCustomDurationSetsExpectedExpiry() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 50_000))
        let (coordinator, _) = makeCoordinator(clock: clock)
        let started = try await coordinator.start(
            owner: .localUser,
            profileID: "player-qa-widescreen-v1",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
            scope: .host,
            duration: 3_600
        )
        XCTAssertEqual(started.expiresAt, clock.now.addingTimeInterval(3_600))
        _ = try await coordinator.stop(id: started.id)
    }

    /// A caller extending an actively-debugging substitution must not need to restart it: the route
    /// stays installed (same experiment, same mount) and the new expiry pushes real removal further
    /// out — the exact ceremony (re-prepare/re-approve every 30 minutes) the field session flagged.
    func testExtendPushesExpiryForwardWithoutRestartingRoute() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 60_000))
        let (coordinator, runStore) = makeCoordinator(clock: clock)
        let started = try await coordinator.start(
            owner: .localUser,
            profileID: "player-qa-widescreen-v1",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
            scope: .host
        )
        let originalExpiresAt = try XCTUnwrap(started.expiresAt)

        clock.now = originalExpiresAt.addingTimeInterval(-60)
        let extended = try await coordinator.extend(id: started.id, duration: 1_800)
        XCTAssertEqual(extended.expiresAt, clock.now.addingTimeInterval(1_800))
        XCTAssertTrue(try XCTUnwrap(extended.expiresAt) > originalExpiresAt)

        // Past the ORIGINAL expiry, the route must still resolve — extend, not restart.
        clock.now = originalExpiresAt.addingTimeInterval(1)
        await coordinator.synchronizeMetricsAndExpiry()
        let stillActive = await coordinator.experiment(id: started.id)
        XCTAssertEqual(stillActive?.state, .active)
        let route = await coordinator.routeStore.decision(for: makeRequest(path: "/anything.m3u8"))
        XCTAssertNotNil(route)

        // Past the NEW expiry, it fails open exactly like the unextended case.
        clock.now = try XCTUnwrap(extended.expiresAt).addingTimeInterval(1)
        await coordinator.synchronizeMetricsAndExpiry()
        let expired = await coordinator.experiment(id: started.id)
        XCTAssertEqual(expired?.state, .expired)
        let routeAfterExpiry = await coordinator.routeStore.decision(for: makeRequest(path: "/anything.m3u8"))
        XCTAssertNil(routeAfterExpiry)
        XCTAssertTrue(runStore.activeRuns(ownedBy: HLSSubstitutionCoordinator.localUserOwnerID).isEmpty)
    }

    func testExtendRejectsWrongOwner() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 70_000))
        let (coordinator, _) = makeCoordinator(clock: clock)
        let started = try await coordinator.start(
            owner: .localUser,
            profileID: "player-qa-widescreen-v1",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
            scope: .host
        )
        do {
            _ = try await coordinator.extend(id: started.id, requestingOwnerID: "someone-else", duration: 1_800)
            XCTFail("Expected notOwner")
        } catch HLSSubstitutionError.notOwner {
            // Expected.
        }
        _ = try await coordinator.stop(id: started.id)
    }

    func testExtendRejectsAlreadyStoppedExperiment() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 80_000))
        let (coordinator, _) = makeCoordinator(clock: clock)
        let started = try await coordinator.start(
            owner: .localUser,
            profileID: "player-qa-widescreen-v1",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
            scope: .host
        )
        _ = try await coordinator.stop(id: started.id)
        do {
            _ = try await coordinator.extend(id: started.id, duration: 1_800)
            XCTFail("Expected inactiveExperiment")
        } catch HLSSubstitutionError.inactiveExperiment {
            // Expected.
        }
    }

    /// Regression guard: extending an experiment must NOT weaken fail-open-on-quit. A relaunch still
    /// purges every persisted-active experiment unconditionally, regardless of how far its extended
    /// `expiresAt` reaches into the future.
    func testExtendedExperimentIsStillPurgedOnReload() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 90_000))
        let persistenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-substitution-extend-reload-\(UUID().uuidString).json")
        let (first, runStore) = makeCoordinator(clock: clock, persistenceURL: persistenceURL)
        let started = try await first.start(
            owner: .localUser,
            profileID: "player-qa-widescreen-v1",
            origin: HLSSubstitutionOrigin(scheme: .https, host: "media.example.com", port: 443),
            scope: .selectedPlaylist(path: "/live/master.m3u8")
        )
        _ = try await first.extend(id: started.id, duration: 86_400)

        clock.now = clock.now.addingTimeInterval(10)
        let reloaded = HLSSubstitutionCoordinator(
            runStore: runStore,
            routeStore: HLSSubstitutionRouteStore(),
            persistenceURL: persistenceURL,
            clock: { clock.now }
        )
        let recovered = try XCTUnwrap(reloaded.experiments.first(where: { $0.id == started.id }))
        XCTAssertEqual(recovered.state, .stopped)
        XCTAssertNil(recovered.fixtureRunID)
        let route = await reloaded.routeStore.decision(for: makeRequest(path: "/live/master.m3u8"))
        XCTAssertNil(route)
    }

    // MARK: - Stall-class heuristic (P2)

    func testStallClassIsMatcherMissWhenNoHitsOccurred() {
        XCTAssertEqual(HLSSubstitutionMetrics().stallClass, .matcherMiss)
    }

    func testStallClassIsWorkingNormallyWithHealthyRatio() {
        var metrics = HLSSubstitutionMetrics()
        metrics.entryPlaylistHits = 1
        metrics.childPlaylistHits = 2
        metrics.segmentHits = 40
        XCTAssertEqual(metrics.stallClass, .workingNormally)
    }

    func testStallClassIsWorkingNormallyBelowMinimumPlaylistSample() {
        // Only 2 combined playlist hits and zero segments — below the minimum sample size, so this
        // must not be flagged yet (an early, legitimate startup shouldn't look like a stall).
        var metrics = HLSSubstitutionMetrics()
        metrics.entryPlaylistHits = 1
        metrics.childPlaylistHits = 1
        metrics.segmentHits = 0
        XCTAssertEqual(metrics.stallClass, .workingNormally)
    }

    /// Mirrors the field session's own description: "polled playlists ~24x while downloading almost
    /// no segments."
    func testStallClassIsLikelyClientRejectOrStallWhenPlaylistDominatesSegments() {
        var metrics = HLSSubstitutionMetrics()
        metrics.entryPlaylistHits = 4
        metrics.childPlaylistHits = 20
        metrics.segmentHits = 1
        XCTAssertEqual(metrics.stallClass, .likelyClientRejectOrStall)
    }

    func testStallClassIsLikelyClientRejectOrStallWhenNoSegmentsAtAllDespitePlaylistVolume() {
        var metrics = HLSSubstitutionMetrics()
        metrics.entryPlaylistHits = 1
        metrics.childPlaylistHits = 5
        metrics.segmentHits = 0
        XCTAssertEqual(metrics.stallClass, .likelyClientRejectOrStall)
    }
}
