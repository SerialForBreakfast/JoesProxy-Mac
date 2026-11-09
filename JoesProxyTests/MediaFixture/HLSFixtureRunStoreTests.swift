import XCTest
@testable import JoesProxy

@MainActor
final class HLSFixtureRunStoreTests: XCTestCase {
    private func baselineProfileDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MediaFixture/
            .deletingLastPathComponent() // JoesProxyTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Fixtures/HLS/baseline-aligned-codecs")
    }

    private func profilesRoot() -> URL {
        baselineProfileDirectory().deletingLastPathComponent()
    }

    private func makeStore(
        registry: HLSFixtureOriginRegistry = HLSFixtureOriginRegistry(),
        clock: @escaping () -> Date = Date.init
    ) throws -> HLSFixtureRunStore {
        let profileRoot = profilesRoot()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: baselineProfileDirectory().path),
            "Fixtures/HLS/baseline-aligned-codecs not present — run generate-profile.sh first."
        )
        let persistenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-fixture-run-store-\(UUID().uuidString).json")
        let store = HLSFixtureRunStore(
            persistenceURL: persistenceURL,
            profileRootURL: profileRoot,
            originRegistry: registry,
            clock: clock
        )
        store.load()
        return store
    }

    func testStartRegistersReservedHostAndStopUnregisters() async throws {
        let registry = HLSFixtureOriginRegistry()
        let store = try makeStore(registry: registry)
        let record = try await store.startRun(clientID: "client-a", profileID: "baseline-aligned-codecs")
        XCTAssertTrue(record.isActive)
        XCTAssertTrue(record.reservedHost.hasSuffix(".hls.joesproxy.invalid"))
        let entry = await registry.activeEntry(forHost: record.reservedHost)
        XCTAssertEqual(entry?.runID, record.id)

        let stopped = try await store.stopRun(id: record.id, clientID: "client-a")
        XCTAssertFalse(stopped.isActive)
        let after = await registry.activeEntry(forHost: record.reservedHost)
        XCTAssertNil(after)
    }

    func testStartCarriesExplicitPresentationModeIntoRecordAndServer() async throws {
        let store = try makeStore()
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .vodStatic

        let record = try await store.startRun(
            clientID: "client-a",
            profileID: "baseline-aligned-codecs",
            playbackConfiguration: configuration
        )

        XCTAssertEqual(record.playbackConfiguration, configuration)
        XCTAssertEqual(store.liveServer(id: record.id)?.playbackConfiguration, configuration)
    }

    func testExpiryTearsDownConfiguredLiveRunAndReservedOrigin() async throws {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let registry = HLSFixtureOriginRegistry()
        let store = try makeStore(registry: registry, clock: { currentTime })
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        let record = try await store.startRun(
            clientID: "client-a",
            profileID: "baseline-aligned-codecs",
            playbackConfiguration: configuration,
            duration: 1
        )

        currentTime = record.expiresAt
        try await store.expireOverdueRuns(now: currentTime)

        XCTAssertFalse(try XCTUnwrap(store.run(id: record.id)).isActive)
        XCTAssertNil(store.liveServer(id: record.id))
        let activeOrigin = await registry.activeEntry(forHost: record.reservedHost)
        XCTAssertNil(activeOrigin)
    }

    func testLegacyRunRecordWithoutPlaybackConfigurationStillDecodes() throws {
        let json = """
        {
          "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "clientID": "legacy-client",
          "profileID": "baseline-aligned-codecs",
          "profileVersion": "1",
          "reservedHost": "fixture-legacy.hls.joesproxy.invalid",
          "startedAt": 0,
          "expiresAt": 1800,
          "isActive": false
        }
        """

        let record = try JSONDecoder().decode(HLSFixtureRunRecord.self, from: Data(json.utf8))

        XCTAssertNil(record.playbackConfiguration)
        XCTAssertEqual(record.profileID, "baseline-aligned-codecs")
    }

    /// Characterization test written before adding the fixture-redirect Map Local capability:
    /// proves the pre-existing reserved-host registration/teardown lifecycle is unaffected by the
    /// new run-ID index added alongside it in `HLSFixtureOriginRegistry`, and that the new index
    /// mirrors the same lifecycle (registered on start, nil after stop).
    func testActiveEntryByRunIDMirrorsHostLifecycle() async throws {
        let registry = HLSFixtureOriginRegistry()
        let store = try makeStore(registry: registry)
        let record = try await store.startRun(clientID: "client-a", profileID: "baseline-aligned-codecs")

        let byHost = await registry.activeEntry(forHost: record.reservedHost)
        let byRunID = await registry.activeEntry(forRunID: record.id)
        XCTAssertEqual(byHost?.runID, record.id)
        XCTAssertEqual(byRunID?.runID, record.id)

        _ = try await store.stopRun(id: record.id, clientID: "client-a")

        let afterByHost = await registry.activeEntry(forHost: record.reservedHost)
        let afterByRunID = await registry.activeEntry(forRunID: record.id)
        XCTAssertNil(afterByHost)
        XCTAssertNil(afterByRunID)
    }

    func testEnforcesPerClientActiveQuota() async throws {
        let store = try makeStore()
        _ = try await store.startRun(clientID: "client-a", profileID: "baseline-aligned-codecs")
        _ = try await store.startRun(clientID: "client-a", profileID: "baseline-aligned-codecs")
        do {
            _ = try await store.startRun(clientID: "client-a", profileID: "baseline-aligned-codecs")
            XCTFail("Expected quotaExceeded")
        } catch HLSFixtureRunStoreError.quotaExceeded {
            // expected
        }
        _ = try await store.startRun(clientID: "client-b", profileID: "baseline-aligned-codecs")
    }

    func testStopAllOwnedClearsActiveRuns() async throws {
        let registry = HLSFixtureOriginRegistry()
        let store = try makeStore(registry: registry)
        let first = try await store.startRun(clientID: "client-a", profileID: "baseline-aligned-codecs")
        let second = try await store.startRun(clientID: "client-a", profileID: "baseline-aligned-codecs")
        try await store.stopAll(ownedBy: "client-a")
        XCTAssertEqual(store.activeRuns(ownedBy: "client-a").count, 0)
        let firstAfter = await registry.activeEntry(forHost: first.reservedHost)
        let secondAfter = await registry.activeEntry(forHost: second.reservedHost)
        XCTAssertNil(firstAfter)
        XCTAssertNil(secondAfter)
    }

    func testNotOwnerCannotStop() async throws {
        let store = try makeStore()
        let record = try await store.startRun(clientID: "owner", profileID: "baseline-aligned-codecs")
        do {
            _ = try await store.stopRun(id: record.id, clientID: "intruder")
            XCTFail("Expected notOwner")
        } catch HLSFixtureRunStoreError.notOwner {
            // expected
        }
    }

    func testPersistenceReloadMarksPriorActiveRunsStopped() async throws {
        let persistenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-fixture-run-store-reload-\(UUID().uuidString).json")
        let profileRoot = profilesRoot()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: baselineProfileDirectory().path),
            "Fixtures/HLS/baseline-aligned-codecs not present."
        )
        let registry = HLSFixtureOriginRegistry()
        let first = HLSFixtureRunStore(
            persistenceURL: persistenceURL,
            profileRootURL: profileRoot,
            originRegistry: registry
        )
        first.load()
        let record = try await first.startRun(clientID: "client-a", profileID: "baseline-aligned-codecs")
        XCTAssertTrue(record.isActive)

        let second = HLSFixtureRunStore(
            persistenceURL: persistenceURL,
            profileRootURL: profileRoot,
            originRegistry: HLSFixtureOriginRegistry()
        )
        second.load()
        let reloaded = try XCTUnwrap(second.run(id: record.id))
        XCTAssertFalse(reloaded.isActive)
        XCTAssertNotNil(reloaded.stoppedAt)
    }

    /// Reproduces a live crash found 2026-08-07 during defect-profile fixture-redirect
    /// verification: `stopRun` captured `index` before calling `pruneTerminal`, which can remove
    /// OTHER terminal entries positioned earlier in `runs` — their own `terminalRetention` window
    /// can elapse independently, during the very run being stopped here's lifetime. Removing even
    /// one earlier entry shifts the array and invalidates the stale `index`, so `return
    /// runs[index]` crashed with an out-of-range fatal error. Reproduction: an earlier run (`early`)
    /// is stopped while fresh, a second run (`target`) starts before `early` goes stale (so
    /// `startRun`'s own pre-append prune doesn't remove it yet), the clock advances past
    /// `terminalRetention` only after `target` has started, then `target` is stopped — its
    /// `stopRun` call's `pruneTerminal` now removes `early` (positioned before `target` in
    /// `runs`), which crashed the app live before the fix in `HLSFixtureRunStore.stopRun`.
    func testStopRunSurvivesPruningOfEarlierStaleEntry() async throws {
        var currentTime = Date()
        let store = try makeStore(clock: { currentTime })

        let early = try await store.startRun(clientID: "client-a", profileID: "baseline-aligned-codecs")
        _ = try await store.stopRun(id: early.id, clientID: "client-a")

        let target = try await store.startRun(clientID: "client-a", profileID: "baseline-aligned-codecs")
        XCTAssertEqual(store.runs(ownedBy: "client-a").count, 2, "early's terminal entry must still be present before target starts")

        // Advance the clock past terminalRetention only now, so `early` becomes prunable during
        // `target`'s own stop — not before `target` was appended.
        currentTime = currentTime.addingTimeInterval(HLSFixtureRunStore.terminalRetention + 1)

        let stopped = try await store.stopRun(id: target.id, clientID: "client-a")
        XCTAssertEqual(stopped.id, target.id)
        XCTAssertFalse(stopped.isActive)
        XCTAssertNotNil(stopped.stoppedAt)
        XCTAssertEqual(store.runs(ownedBy: "client-a").map(\.id), [target.id], "early's stale terminal entry should have been pruned")
    }

    func testAvailableProfilesListsBaseline() throws {
        let store = try makeStore()
        let profiles = store.availableProfiles()
        XCTAssertTrue(profiles.contains(where: { $0.id == "baseline-aligned-codecs" }))
    }
}
