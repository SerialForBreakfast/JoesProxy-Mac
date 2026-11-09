import XCTest
@testable import JoesProxy

/// Synthetic contract only. These field names are not a target-app adapter or playback evidence.
final class DiagnosticChannelAuthoringTests: XCTestCase {
    private let source = Data(#"{"channels":[{"id":"sibling","programmes":[],"enabled":true}],"cursor":"preserve","total":1}"#.utf8)
    private let mediaURL = "https://media.example.test/diagnostic/master.m3u8"

    private func scope(_ path: String, client: String = "192.0.2.10") -> CapturedMockScope {
        .init(host: "api.example.test", scheme: .https, port: 443, path: path, clients: .address(client))
    }

    private func draft() -> CollectionMockDraft {
        var programmes: [BookmarkJSONValue] = []
        for index in 0..<3 {
            let start = 1_800_000_000 + index * 600
            var fields: [String: BookmarkJSONValue] = [:]
            fields["id"] = .string("programme-\(index)")
            fields["channelID"] = .string("diagnostic")
            fields["start"] = .number(String(start))
            fields["end"] = .number(String(start + 600))
            fields["detail"] = .string("/programmes/\(index)?region=test")
            fields["playback"] = .string("/playback/\(index)?region=test")
            fields["manifest"] = .string(mediaURL)
            programmes.append(.object(fields))
        }
        return .init(collectionPointer: "/channels",
            item: .object(["id": .string("diagnostic"), "programmes": .array(programmes), "enabled": .bool(true)]),
            templateIndex: nil, edits: [], identityPointers: ["/id"], countPointers: ["/total"], position: .prepend)
    }

    private func related(client: String = "192.0.2.10", mismatchedProgramme: Bool = false) throws -> [CapturedRelatedResponse] {
        try (0..<3).flatMap { index in
            try ["programmes", "playback"].map { kind in
                let item: [String: Any] = ["id": mismatchedProgramme && index == 2 ? "wrong" : "programme-\(index)",
                    "channelID": "diagnostic", "manifest": mediaURL, "clear": true,
                    "untouched": ["enabled": false, "nullable": NSNull()]]
                return CapturedRelatedResponse(source: try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]),
                    scope: scope("/\(kind)/\(index)?region=test", client: client), edits: [], images: [],
                    identityLinks: [
                        .init(pointer: "/id", primaryPointer: "/channels/0/programmes/\(index)/id"),
                        .init(pointer: "/channelID", primaryPointer: "/channels/0/id"),
                        .init(pointer: "/manifest", primaryPointer: "/channels/0/programmes/\(index)/manifest")])
            }
        }
    }

    private func prepare(_ service: CollectionMockAuthoringService, key: String = "channel",
                         responses: [CapturedRelatedResponse]? = nil) async throws -> PreparedCapturedMockPackage {
        try await service.prepareCapturedPackage(ownerID: "synthetic-owner", idempotencyKey: key,
            name: "Diagnostic channel", source: source, draft: draft(), scope: scope("/guide?region=test"),
            images: [], appVersion: "test", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            relatedResponses: try responses ?? related())
    }

    func testThreeProgrammesPrepareOneScopedRevisionWithoutCopyingMedia() async throws {
        let package = try await prepare(CollectionMockAuthoringService())
        XCTAssertEqual(package.manifest.responseEffects.count, 7)
        XCTAssertEqual(package.assetDataByID.count, 7)
        XCTAssertTrue(package.manifest.hlsSubstitutions.isEmpty,
            "Authoring URLs is not proof that a media route has been activated")
        XCTAssertTrue(package.manifest.responseEffects.allSatisfy {
            $0.sourceClientAddress == "192.0.2.10" && $0.path.hasSuffix("?region=test")
        })
        let original = try CollectionMockCompiler.parse(source)
        let root = try CollectionMockCompiler.parse(XCTUnwrap(package.assetDataByID["response"]))
        XCTAssertEqual(try value("/channels/1", root), try value("/channels/0", original))
        XCTAssertEqual(try value("/cursor", root), try value("/cursor", original))
        XCTAssertEqual(try value("/total", root), .number("2"))
        for index in 0..<3 {
            for offset in 0..<2 {
                let reference = offset == 0 ? "detail" : "playback"
                XCTAssertEqual(try value("/channels/0/programmes/\(index)/\(reference)", root),
                    .string(package.manifest.responseEffects[1 + index * 2 + offset].path))
                let response = try CollectionMockCompiler.parse(XCTUnwrap(package.assetDataByID["related-\(index * 2 + offset)"]))
                XCTAssertEqual(try value("/id", response), try value("/channels/0/programmes/\(index)/id", root))
                XCTAssertEqual(try value("/manifest", response), .string(mediaURL))
                XCTAssertEqual(try value("/untouched/enabled", response), .bool(false))
                XCTAssertEqual(try value("/untouched/nullable", response), .null)
            }
        }
        XCTAssertLessThan(package.assetDataByID.values.reduce(0) { $0 + $1.count }, 16_384)
        XCTAssertTrue(package.manifest.assets.allSatisfy { $0.contentType == "application/json" })
    }

    func testRepeatedPreparationReusesRevisionWithinSingleEntryCapacity() async throws {
        let service = CollectionMockAuthoringService(maximumRevisions: 1)
        let first = try await prepare(service)
        for _ in 0..<32 {
            let repeated = try await prepare(service)
            XCTAssertEqual(repeated.manifest.id, first.manifest.id)
            XCTAssertEqual(repeated.assetDataByID, first.assetDataByID)
        }
        do {
            _ = try await prepare(service, key: "another-revision")
            XCTFail("A new revision must not bypass bounded retention")
        } catch { XCTAssertEqual(error as? CollectionMockAuthoringError, .capacityExceeded) }
    }

    func testProgrammeReferencesResolveToOnePreparedMultilingualFixture() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS/multilingual-text-vod-v1")
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .warmDVR
        let prepared = try XCTUnwrap(HLSWebVTTFixture.prepare(directory: directory, configuration: configuration))
        let specification = try XCTUnwrap(JSONDecoder().decode(HLSFixtureProfileDescriptor.self,
            from: Data(contentsOf: directory.appendingPathComponent("profile.json"))).textFixture)
        let package = try await prepare(CollectionMockAuthoringService())
        let base = try XCTUnwrap(URL(string: mediaURL))
        let master = String(decoding: try XCTUnwrap(prepared.resources[base.lastPathComponent]), as: UTF8.self)
        XCTAssertEqual(specification.tracks.count, 7)
        for track in specification.tracks {
            XCTAssertTrue(master.contains("URI=\"\(track.playlistPath)\""))
            let playlistURL = try XCTUnwrap(URL(string: track.playlistPath, relativeTo: base)?.absoluteURL)
            XCTAssertEqual(playlistURL.host, base.host)
            let playlist = String(decoding: try XCTUnwrap(prepared.resources[track.playlistPath]), as: UTF8.self)
            for segment in HLSStaticPlaylistParser.parse(playlist).segments {
                let url = try XCTUnwrap(URL(string: segment.uri, relativeTo: playlistURL)?.absoluteURL)
                let path = String(url.path.dropFirst("/diagnostic/".count))
                XCTAssertNotNil(prepared.resources[path])
                XCTAssertEqual(prepared.tracks[path]?.language, track.language)
            }
        }
        XCTAssertFalse(prepared.mediaFiles.isEmpty)
        XCTAssertLessThanOrEqual(prepared.resources.values.reduce(0) { $0 + $1.count }, 256 * 1024)
        XCTAssertTrue(Set(package.assetDataByID.keys).isDisjoint(with: Set(prepared.mediaFiles.keys)),
            "The channel package must not duplicate binary media for each programme")
        // URL resolution and prepared bytes do not establish virtual-origin routing or device playback.
    }

    func testMismatchAndWrongClientRejectWholePreparationWithoutConsumingCapacity() async throws {
        let service = CollectionMockAuthoringService(maximumRevisions: 1)
        for responses in [try related(mismatchedProgramme: true), try related(client: "192.0.2.11")] {
            do {
                _ = try await prepare(service, responses: responses)
                XCTFail("Every resource must agree on client and declared identity")
            } catch { XCTAssertNotNil(CapturedMockPreparationFailure.describe(error, field: "relatedResponses")) }
        }
        let corrected = try await prepare(service)
        XCTAssertEqual(corrected.manifest.responseEffects.count, 7)
    }

    func testFreshGuideRefreshPreservesSiblingAndDoesNotDuplicateChannel() throws {
        let plan = try CollectionMockCompiler.prepare(source: source, draft: draft())
        for index in 0..<64 {
            let fresh = Data("{\"channels\":[{\"id\":\"sibling-\(index)\"}],\"total\":1,\"cursor\":\"page-\(index)\"}".utf8)
            guard case .applied(let body, _, let count) = try CollectionMockCompiler.apply(source: fresh, plan: plan) else {
                return XCTFail("Fresh guide should receive one diagnostic channel")
            }
            XCTAssertEqual(count, 2)
            let root = try CollectionMockCompiler.parse(body)
            XCTAssertEqual(try value("/channels/1/id", root), .string("sibling-\(index)"))
            XCTAssertEqual(try value("/cursor", root), .string("page-\(index)"))
            XCTAssertEqual(try CollectionMockCompiler.apply(source: body, plan: plan), .alreadyPresent)
        }
        XCTAssertThrowsError(try CollectionMockCompiler.apply(source: Data(#"{"channels":{},"total":1}"#.utf8), plan: plan))
    }

    func testCurrentHLSRouteDoesNotInheritJSONClientScope() async throws {
        let routes = HLSSubstitutionRouteStore(effectBundleGate: EffectBundleActivationGate())
        let id = UUID(), runID = UUID()
        let mount = "/.joesproxy/hls-substitution/\(id.uuidString.lowercased())/"
        try await routes.install(.init(id: id, owner: .localUser, profileID: "multilingual-text-vod-v1",
            origin: .init(scheme: .https, host: "media.example.test"),
            scope: .selectedPlaylist(path: "/diagnostic/master.m3u8"), mountPath: mount,
            fixtureRunID: runID, state: .active, startedAt: Date(), expiresAt: nil,
            stoppedAt: nil, metrics: .init()))
        for client in ["192.0.2.10", "192.0.2.11"] {
            for path in ["/diagnostic/master.m3u8", "/diagnostic/master.m3u8?region=other",
                         "\(mount)text/en/stream.m3u8"] {
                let request = CapturedRequest(method: "GET", scheme: .https, host: "media.example.test",
                    port: 443, path: path, headers: [], bodyData: nil, bodySize: nil, clientAddress: client)
                let decision = await routes.decision(for: request)
                XCTAssertEqual(decision?.fixtureRunID, runID,
                    "Current limitation: JSON client scope cannot be claimed for HLS entry or children")
            }
        }
        await routes.remove(experimentID: id)
    }

    @MainActor
    func testPreparedChannelImportsInactiveAdvancesSleepsRestartsAndExpires() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = repositoryRoot.appendingPathComponent(".build/diagnostic-channel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = EffectBundleActivationGate()
        let store = ResponseOverrideStore(effectBundleGate: gate)
        let routes = HLSSubstitutionRouteStore(effectBundleGate: gate)
        let runs = HLSFixtureRunStore(persistenceURL: root.appendingPathComponent("runs.json"),
            profileRootURL: repositoryRoot.appendingPathComponent("Fixtures/HLS"),
            originRegistry: HLSFixtureOriginRegistry())
        runs.load()
        let hls = HLSSubstitutionCoordinator(runStore: runs, routeStore: routes,
            responseOverrideStore: store, persistenceURL: root.appendingPathComponent("hls.json"))
        let repository = EffectBundleRepository(persistenceURL: root.appendingPathComponent("bundles.json"),
            packagesRootURL: root.appendingPathComponent("packages"))
        var uptime: TimeInterval = 100
        let coordinator = EffectBundleActivationCoordinator(repository: repository, responseOverrideStore: store,
            hlsCoordinator: hls, activationGate: gate, runtimeRootURL: root.appendingPathComponent("runtime"),
            uptime: { uptime }, schedulesTimers: false)
        let package = try await prepare(CollectionMockAuthoringService())
        var manifest = package.manifest
        let phaseEffects = (0..<3).map { index in
            package.manifest.responseEffects.map { original in
                var effect = original
                if index > 0 { effect.id = UUID() }
                return effect
            }
        }
        manifest.responseEffects = phaseEffects.flatMap { $0 }
        manifest.phases = phaseEffects.enumerated().map { index, effects in
            .init(id: UUID(), label: "Programme \(index)", durationSeconds: 30,
                responseEffectIDs: effects.map(\.id), hlsSubstitutionIDs: [], timestampBindings: [])
        }
        let archive = root.appendingPathComponent("channel.jproxy-effects")
        try EffectBundlePackageEngine().writePackage(manifest: manifest,
            assetDataByID: package.assetDataByID, to: archive)
        _ = try repository.importPackage(at: archive, owner: .localUser)
        func request(_ path: String, client: String = "192.0.2.10") -> CapturedRequest {
            .init(method: "GET", scheme: .https, host: "api.example.test", port: 443,
                path: path, headers: [], bodyData: nil, bodySize: nil, clientAddress: client)
        }
        for effect in package.manifest.responseEffects {
            if case .noMatch = try await store.ruleDecision(for: request(effect.path)) {} else {
                XCTFail("Import must not activate a route")
            }
        }
        do {
            _ = try await coordinator.activate(id: package.manifest.id, ttl: 60)
        } catch { return XCTFail("Initial channel activation failed: \(error)") }
        let firstPhase = try XCTUnwrap(coordinator.phaseSnapshots[manifest.id])
        // These assertions exercise the real matcher/materializer, not downstream delivery.
        for (index, effect) in package.manifest.responseEffects.enumerated() {
            guard case .mapLocal(let resolved) = try await store.ruleDecision(for: request(effect.path)) else {
                XCTFail("Every reviewed resource must resolve")
                continue
            }
            let assetID = index == 0 ? "response" : "related-\(index - 1)"
            XCTAssertEqual(resolved.bodyData, package.assetDataByID[assetID])
            XCTAssertEqual(resolved.authoredResource?.revisionID, package.manifest.id)
            for rejected in [request(effect.path, client: "192.0.2.11"),
                             request(effect.path.replacingOccurrences(of: "region=test", with: "region=other"))] {
                if case .noMatch = try await store.ruleDecision(for: rejected) {} else {
                    XCTFail("Client and query scope must remain narrow")
                }
            }
        }
        let second: EffectBundleTimeline.Snapshot?
        do {
            second = try await coordinator.advance(id: manifest.id, activationID: firstPhase.activationID,
                expectedPhaseID: firstPhase.phaseID)
        } catch { return XCTFail("First programme advance failed: \(error)") }
        XCTAssertEqual(second?.phaseIndex, 1)
        do {
            _ = try await coordinator.advance(id: manifest.id, activationID: firstPhase.activationID,
                expectedPhaseID: firstPhase.phaseID)
            XCTFail("A retried Advance cannot skip a programme")
        } catch { XCTAssertEqual(error as? EffectBundleError, .stalePhase) }
        await coordinator.handleSleepState(isSleeping: true)
        XCTAssertFalse(gate.allows(bundleID: manifest.id))
        XCTAssertEqual(repository.record(id: manifest.id)?.state, .stopped,
            "Sleep must complete cleanup even when the injected root URL has no directory hint")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime")
            .appendingPathComponent(manifest.id.uuidString.lowercased()).path))
        await coordinator.handleSleepState(isSleeping: false)
        XCTAssertFalse(gate.allows(bundleID: manifest.id), "Wake must not reactivate the channel")
        do {
            _ = try await coordinator.activate(id: manifest.id, ttl: 60)
        } catch { return XCTFail("Activation after sleep cleanup failed: \(error)") }
        let restarted = try XCTUnwrap(coordinator.phaseSnapshots[manifest.id])
        XCTAssertNotEqual(restarted.activationID, firstPhase.activationID)
        XCTAssertEqual(restarted.phaseIndex, 0)
        do {
            _ = try await coordinator.advance(id: manifest.id, activationID: firstPhase.activationID,
                expectedPhaseID: firstPhase.phaseID)
            XCTFail("An old activation cannot control the new run")
        } catch { XCTAssertEqual(error as? EffectBundleError, .stalePhase) }
        uptime += 60
        let expired = try await coordinator.advance(id: manifest.id, activationID: restarted.activationID,
            expectedPhaseID: restarted.phaseID)
        XCTAssertNil(expired)
        for effect in package.manifest.responseEffects {
            if case .noMatch = try await store.ruleDecision(for: request(effect.path)) {} else {
                XCTFail("Expiry must remove every channel resource")
            }
        }
        XCTAssertFalse(gate.allows(bundleID: package.manifest.id))
        XCTAssertEqual(repository.record(id: package.manifest.id)?.state, .expired)
    }

    private func value(_ pointer: String, _ root: BookmarkJSONValue) throws -> BookmarkJSONValue {
        try CollectionMockCompiler.value(at: CollectionMockCompiler.pointer(pointer), in: root)
    }
}
