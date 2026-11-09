import XCTest
@testable import JoesProxy

@MainActor
final class CapturedMockPreflightTests: XCTestCase {
    private func package() throws -> PreparedCapturedMockPackage {
        try CapturedMockPackageCompiler.prepare(id: UUID(), name: "Synthetic",
            source: Data(#"{"items":[]}"#.utf8),
            draft: .init(collectionPointer: "/items", item: .object(["id": .string("new")]),
                templateIndex: nil, edits: [], identityPointers: ["/id"], countPointers: [], position: .append),
            scope: .init(host: "example.test", scheme: .https, port: 443, path: "/items", clients: .address("192.0.2.1")),
            images: [], appVersion: "test", createdAt: Date())
    }

    private func record(_ path: String, client: String = "192.0.2.1", truncated: Bool = false) -> SessionRecord {
        .init(request: .init(method: "GET", scheme: .https, host: "example.test", port: 443,
            path: path, headers: [.init(name: "Authorization", value: "synthetic-secret")],
            bodyData: Data("synthetic-secret".utf8), bodySize: 16, clientAddress: client),
            response: .init(statusCode: 200, headers: [], bodyData: Data("synthetic-secret".utf8),
                bodySize: 16, bodyTruncated: truncated), timing: .init(startedAt: Date()))
    }

    func testMetadataSnapshotIsBoundedAndDoesNotRetainBodiesOrHeaders() throws {
        let store = InMemorySessionStore()
        store.load(sessions: (0..<1_100).map { record("/items/\($0)") })
        let snapshot = CapturedMockPreflightSnapshot.capture(from: store)
        XCTAssertEqual(snapshot.observations.count, 1_000)
        XCTAssertEqual(snapshot.retainedCount, 1_100)
        XCTAssertEqual(snapshot.observations.first?.request.path, "/items/100")
        XCTAssertTrue(snapshot.observations.allSatisfy { $0.request.bodyData == nil && $0.request.headers.isEmpty })
        store.append(record("/" + String(repeating: "x", count: 17_000)))
        let limited = CapturedMockPreflightSnapshot.capture(from: store)
        XCTAssertEqual(limited.metadataSkippedCount, 1)
        XCTAssertEqual(limited.observations.count, 999)
    }

    func testExactMatcherSeparatesClientsAndDoesNotActivateOrExposeTraffic() async throws {
        let store = InMemorySessionStore()
        store.load(sessions: [record("/items", truncated: true), record("/items", client: "192.0.2.2"), record("/items/other")])
        let matcher = ResponseOverrideStore(effectBundleGate: EffectBundleActivationGate())
        let package = try package()
        let report = try await matcher.preflight(manifest: package.manifest, snapshot: .capture(from: store))
        let resource = try XCTUnwrap(report.resources.first)
        XCTAssertEqual(resource.matchedCount, 1)
        XCTAssertEqual(resource.otherClientCount, 1)
        XCTAssertEqual(resource.siblingMatchCount, 0)
        XCTAssertEqual(resource.unavailableBodyCount, 1)
        XCTAssertFalse(report.incomplete)
        XCTAssertEqual(report.coverageQualification, "partialBodyEvidence")
        XCTAssertEqual(report.revisionID, package.manifest.id)
        let rules = await matcher.rules()
        XCTAssertTrue(rules.isEmpty)
        let encoded = try JSONSerialization.data(withJSONObject: report.payload)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("synthetic-secret"))
        XCTAssertFalse(text.contains("192.0.2.2"))
        XCTAssertFalse(text.contains("example.test"))
    }

    func testQueryExemptionsPreserveOtherParametersAndFlagConsequences() async throws {
        let store = InMemorySessionStore()
        store.load(sessions: [record("/items?profile=1&nonce=new"), record("/items?profile=2&nonce=new"),
            record("/items?profile=1&nonce=new", client: "192.0.2.2")])
        var manifest = try package().manifest
        manifest.responseEffects[0].path = "/items?profile=1&nonce=old"
        manifest.responseEffects[0].matchMode = .ignoreQuery
        manifest.responseEffects[0].ignoredQueryNames = ["nonce"]
        let matcher = ResponseOverrideStore(effectBundleGate: EffectBundleActivationGate())
        let report = try await matcher.preflight(manifest: manifest, snapshot: .capture(from: store))
        XCTAssertEqual(report.resources.first?.matchedCount, 1)
        XCTAssertEqual(report.resources.first?.otherClientCount, 1)
        XCTAssertEqual(report.resources.first?.siblingMatchCount, 1)
        XCTAssertEqual(report.resources.first?.reason, "additionalPathsMatched")
    }

    func testMissingRequestAndUnsupportedPredicatesNeverClaimCacheOrReadiness() async throws {
        let store = InMemorySessionStore()
        let matcher = ResponseOverrideStore(effectBundleGate: EffectBundleActivationGate())
        var manifest = try package().manifest
        let missing = try await matcher.preflight(manifest: manifest, snapshot: .capture(from: store))
        XCTAssertEqual(missing.resources.first?.reason, "noRequestObserved")
        manifest.responseEffects[0].matchHeaderName = "Authorization"
        manifest.responseEffects[0].matchHeaderValue = "synthetic-secret"
        store.append(record("/items"))
        let unsupported = try await matcher.preflight(manifest: manifest, snapshot: .capture(from: store))
        XCTAssertEqual(unsupported.resources.first?.reason, "requiresAdditionalEvidence")
        XCTAssertEqual(unsupported.resources.first?.matchedCount, 0)
        XCTAssertTrue(unsupported.incomplete)
    }

    func testRedirectEvidenceIsStatusOnlyAndBoundedToMatchingClient() async throws {
        let store = InMemorySessionStore()
        let redirects = (0..<6).map { _ -> SessionRecord in
            var value = record("/items")
            value.response = .init(statusCode: 307, headers: [.init(name: "Location", value: "https://private.invalid/token")],
                bodyData: nil, bodySize: nil)
            return value
        }
        var notModified = record("/items")
        notModified.response = .init(statusCode: 304, headers: [], bodyData: nil, bodySize: nil)
        var otherClient = record("/items", client: "192.0.2.2")
        otherClient.response = .init(statusCode: 302, headers: [], bodyData: nil, bodySize: nil)
        store.load(sessions: redirects + [notModified, otherClient])
        let matcher = ResponseOverrideStore(effectBundleGate: EffectBundleActivationGate())
        let report = try await matcher.preflight(manifest: package().manifest, snapshot: .capture(from: store))
        let resource = try XCTUnwrap(report.resources.first)
        XCTAssertEqual(resource.redirectResponseCount, 6)
        XCTAssertEqual(resource.redirectSessionIDs, Array(redirects.prefix(3)).map(\.id))
        XCTAssertEqual(resource.otherClientCount, 1)
        let output = String(decoding: try JSONSerialization.data(withJSONObject: report.payload), as: UTF8.self)
        XCTAssertFalse(output.contains("private.invalid"))
        XCTAssertFalse(output.contains("synthetic-secret"))
    }

    func testPreflightDoesNotBypassLiveActivationGates() async throws {
        let store = InMemorySessionStore()
        let session = record("/items")
        store.append(session)
        let matcher = ResponseOverrideStore(effectBundleGate: EffectBundleActivationGate())
        let manifest = try package().manifest
        let effect = manifest.responseEffects[0]
        let rule = ResponseOverrideRule(id: effect.id, requestMethod: "GET", requestScheme: .https,
            host: effect.host, port: 443, path: effect.path, sourceKind: .capturedResponse,
            sourceDescription: "Synthetic", statusCode: 200, headers: [], bodySource: .inline(Data()),
            isEnabled: false, sourceClientAddress: effect.sourceClientAddress)
        try await matcher.addRule(rule)
        let report = try await matcher.preflight(manifest: manifest, snapshot: .capture(from: store))
        XCTAssertEqual(report.resources.first?.matchedCount, 1)
        let decision = try await matcher.ruleDecision(for: session.request)
        guard case .noMatch = decision else { return XCTFail("Preflight must not enable a rule") }
        let unchanged = await matcher.rule(id: rule.id)
        XCTAssertEqual(unchanged?.isEnabled, false)
        XCTAssertEqual(unchanged?.hitCount, 0)
    }

    func testRetentionAndResourceLimitsRemainVisibleAndSamplesAreBounded() async throws {
        let store = InMemorySessionStore(retentionPolicy: .keepLastSessions(4))
        for _ in 0..<10 { store.append(record("/items")) }
        var manifest = try package().manifest
        manifest.responseEffects = (0..<40).map { _ in
            var effect = manifest.responseEffects[0]
            effect.id = UUID()
            return effect
        }
        let matcher = ResponseOverrideStore(effectBundleGate: EffectBundleActivationGate())
        let report = try await matcher.preflight(manifest: manifest, snapshot: .capture(from: store))
        XCTAssertEqual(report.droppedCount, 6)
        XCTAssertEqual(report.resources.count, 32)
        XCTAssertTrue(report.resourcesTruncated)
        XCTAssertTrue(report.incomplete)
        XCTAssertEqual(report.coverageQualification, "incompleteRetainedEvidence")
        XCTAssertEqual(report.resources.first?.matchedCount, 4)
        XCTAssertEqual(report.resources.first?.sampleSessionIDs.count, 3)
    }
}
