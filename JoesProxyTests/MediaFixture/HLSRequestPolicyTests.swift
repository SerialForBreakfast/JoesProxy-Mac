import XCTest
@testable import JoesProxy

final class HLSRequestPolicyTests: XCTestCase {
    func testScopedDefinitionRequiresNewSchemaAndSurvivesSerialization() throws {
        let media = EffectBundleHLSSubstitution(id: UUID(), profileID: "synthetic", profileVersion: "1",
            profileAssetIDs: [], profileRootLogicalPath: "media", origin: .init(scheme: .https, host: "media.example.test"),
            scope: .selectedPlaylist(path: "/master.m3u8?variant=1"), playbackConfiguration: .conformant,
            requestPolicy: .init(clientAddress: "192.0.2.10", missingTextTrackID: "es"))
        var manifest = EffectBundleManifest(schemaVersion: 7, id: UUID(), name: "Scoped media", notes: "",
            createdAt: Date(), appVersion: "test", privacy: .exactContent, defaultTTLSeconds: 60,
            assets: [], responseEffects: [], hlsSubstitutions: [media])
        try EffectBundleValidator.validateManifest(manifest)
        XCTAssertEqual(try JSONDecoder().decode(EffectBundleManifest.self,
            from: JSONEncoder().encode(manifest)), manifest)
        manifest.schemaVersion = 6
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(manifest))
        manifest.hlsSubstitutions[0].requestPolicy = nil
        XCTAssertNoThrow(try EffectBundleValidator.validateManifest(manifest))
        manifest.schemaVersion = EffectBundleSchema.currentVersion + 1
        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(manifest))
    }
    func testMissingTrackFaultDoesNotMatchSiblingMediaOrQueryText() {
        for path in ["text/es/stream.m3u8", "/text/es/segment-0.vtt?jp_hls_sequence=12",
                     "__jp_media/revision/text/es/segment-0.vtt"] {
            XCTAssertTrue(HLSRequestPolicy.failsTextRequest(path, trackID: "es"))
        }
        for path in ["video-720/segment.ts?reference=/text/es/file.vtt", "text/en/stream.m3u8",
                     "audio-en/stream.m3u8", "master.m3u8", "text/es-other/segment.vtt"] {
            XCTAssertFalse(HLSRequestPolicy.failsTextRequest(path, trackID: "es"))
        }
    }
    private func experiment(client: String?) -> HLSSubstitutionExperiment {
        let id = UUID()
        return .init(id: id, owner: .localUser, profileID: "multilingual-text-vod-v1",
            origin: .init(scheme: .https, host: "media.example.test"),
            scope: .selectedPlaylist(path: "/master.m3u8?a=1&b=2"),
            mountPath: "/.joesproxy/hls-substitution/\(id.uuidString.lowercased())/",
            fixtureRunID: UUID(), state: .active, startedAt: Date(), expiresAt: nil,
            stoppedAt: nil, metrics: .init(),
            requestPolicy: client.map { .init(clientAddress: $0, missingTextTrackID: "es") })
    }

    private func request(_ path: String, client: String?) -> CapturedRequest {
        .init(method: "GET", scheme: .https, host: "media.example.test", port: 443,
              path: path, headers: [], bodyData: nil, bodySize: nil, clientAddress: client)
    }

    func testScopedEntryChildrenAndRemoval() async throws {
        let store = HLSSubstitutionRouteStore(effectBundleGate: EffectBundleActivationGate())
        let item = experiment(client: "192.0.2.10")
        try await store.install(item)
        for path in ["/master.m3u8?b=2&a=1", item.mountPath + "text/es/stream.m3u8",
                     item.mountPath + "text/es/segment-0.vtt?jp_hls_sequence=12"] {
            let accepted = await store.decision(for: request(path, client: "192.0.2.10"))
            XCTAssertEqual(accepted?.experimentID, item.id)
            for client in [nil, "192.0.2.11"] as [String?] {
                let rejected = await store.decision(for: request(path, client: client))
                XCTAssertNil(rejected)
            }
        }
        for path in ["/master.m3u8", "/master.m3u8?a=1&b=3", "/master.m3u8?a=1&b=2&b=2"] {
            let rejected = await store.decision(for: request(path, client: "192.0.2.10"))
            XCTAssertNil(rejected)
        }
        await store.remove(experimentID: item.id)
        let removed = await store.decision(for: request(item.mountPath + "text/es/stream.m3u8", client: "192.0.2.10"))
        XCTAssertNil(removed)
    }

    func testDisjointClientsAndLegacyConflicts() async throws {
        let store = HLSSubstitutionRouteStore(effectBundleGate: EffectBundleActivationGate())
        let first = experiment(client: "192.0.2.10")
        let second = experiment(client: "192.0.2.11")
        try await store.install(first)
        let disjoint = await store.conflictingExperimentIDs(origin: second.origin, scope: second.scope,
            requestPolicy: second.requestPolicy)
        XCTAssertTrue(disjoint.isEmpty)
        let legacy = await store.conflictingExperimentIDs(origin: second.origin, scope: second.scope)
        XCTAssertEqual(legacy, [first.id])
        try await store.install(second)
        let decision = await store.decision(for: request("/master.m3u8?a=1&b=2", client: "192.0.2.11"))
        XCTAssertEqual(decision?.experimentID, second.id)
    }

    func testExactQuerySemanticsAndLegacyDecoding() throws {
        let policy = HLSRequestPolicy(clientAddress: "192.0.2.10", missingTextTrackID: nil)
        XCTAssertTrue(HLSRequestPolicy.entryMatches("/master.m3u8?b=2&a=%31",
            scope: .selectedPlaylist(path: "/master.m3u8?a=1&b=2"), policy: policy))
        XCTAssertFalse(HLSRequestPolicy.entryMatches("/master.m3u8?a=",
            scope: .selectedPlaylist(path: "/master.m3u8?a"), policy: policy))
        XCTAssertNil(CapturedQueryMatcher.canonicalPath("/master.m3u8?a=1", ignoring: []),
            "The existing exempt-query API must keep rejecting an empty exemption list")
        XCTAssertThrowsError(try policy.validate(scope: .host))
        let scoped = experiment(client: "192.0.2.10")
        XCTAssertEqual(try JSONDecoder().decode(HLSSubstitutionExperiment.self,
            from: JSONEncoder().encode(scoped)), scoped)
        let legacy = experiment(client: nil)
        let decoded = try JSONDecoder().decode(HLSSubstitutionExperiment.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.requestPolicy)
    }
}
