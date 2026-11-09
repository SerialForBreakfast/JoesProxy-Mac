import XCTest
@testable import JoesProxy

@MainActor
final class TransportAssetUITestScenarioTests: XCTestCase {
    func testUnrelatedFixtureDoesNotStartOrWrite() async {
        let scenario = TransportAssetUITestScenario()
        let store = InMemorySessionStore()
        await scenario.run(fixture: .demoSessions, store: store, root: URL(fileURLWithPath: "/invalid"))
        XCTAssertFalse(scenario.completed)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testLoopbackBytesReceiptsFaultClassificationAndCleanup() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/TransportAssetTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scenario = TransportAssetUITestScenario()
        let store = InMemorySessionStore()
        await scenario.run(fixture: .streamingAssets, store: store, root: root)
        XCTAssertTrue(scenario.completed, scenario.status)
        XCTAssertEqual(store.sessions.count, 5)
        let evidence = EffectBundleActivationGate.shared.evidence(bundleID: scenario.bundleID)
        XCTAssertEqual(evidence.receipts.count, 6)
        XCTAssertEqual(evidence.receipts.filter { $0.evaluation == .matcherMismatch }.count, 4,
                       "Sibling HLS requests must not claim the retained JSON resource was served")
        XCTAssertTrue(evidence.receipts.contains { $0.delivery == .downstreamWriteSucceeded && $0.matchesExpectedDelivery == true })
        XCTAssertTrue(evidence.receipts.contains { $0.evaluation == .assetReadFailed && $0.delivery == .notApplied && $0.servedSHA256 == nil })
        let manifest = try XCTUnwrap(store.sessions.first { $0.request.path.hasSuffix("playlist.m3u8") })
        XCTAssertEqual(manifest.response?.bodyData, TransportAssetUITestScenario.playlist)
        XCTAssertEqual(TimelineClassificationService().classify(manifest).lane, .manifest)
        let failure = try XCTUnwrap(store.sessions.first { $0.request.path.hasSuffix("segment-1.ts") })
        XCTAssertEqual(failure.response?.statusCode, 503)
        XCTAssertEqual(TimelineClassificationService().classify(failure).lane, .errorsRetries)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await scenario.run(fixture: .streamingAssets, store: store, root: root)
        XCTAssertEqual(store.sessions.count, 5, "Repeated view presentation must not generate more traffic")
    }

    func testReservedAddressDoesNotExposeLocalAlias() {
        let info = SyntheticLocalNetworkInfoProvider(bonjourName: nil).current()
        XCTAssertEqual(info.lanIP, "192.0.2.10")
        XCTAssertNil(info.bonjourName)
    }
}
