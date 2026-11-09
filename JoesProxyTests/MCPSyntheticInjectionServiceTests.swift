//
//  MCPSyntheticInjectionServiceTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Schema-Inferred Collection Injection and Asset Catalog tools.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPSyntheticInjectionServiceTests: XCTestCase {

    func testPlanListingCarriesBoundedContentFreeReceipts() throws {
        let store = InMemorySessionStore()
        let service = MCPSyntheticInjectionService(sessionStore: store,
            snapshotService: MCPSessionSnapshotService(sessionStore: store))
        let engine = SyntheticCollectionInjectionEngine.shared
        let plan = SyntheticCollectionInjectionPlan(name: "Receipt test", urlPattern: "/receipt-list",
            collectionKeypath: "$.items", boundAssetKind: nil, clientScope: .allClients)
        engine.registerPlan(plan)
        defer { engine.removePlan(id: plan.id) }
        let requestID = UUID(), sessionID = UUID()
        _ = engine.processResponse(responseData: Data(#"{"items":[{"id":"private-item-value"}]}"#.utf8),
            requestURL: "/receipt-list", requestHeaders: [], requestID: requestID)
        engine.updateReceipt(requestID: requestID, sessionID: sessionID, writeSucceeded: true)
        let listed = try service.listInjectionPlans(policyRevision: .initial)
        let diagnostic = try XCTUnwrap(listed.plans.first(where: { $0.id == plan.id.uuidString })?.diagnostics)
        XCTAssertEqual(diagnostic.receipts.first?.sessionID, sessionID)
        XCTAssertEqual(diagnostic.receipts.first?.deliveryState, .downstreamWriteSucceeded)
        let data = try JSONEncoder().encode(diagnostic)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-item-value"))
        XCTAssertEqual(try JSONDecoder().decode(SyntheticInjectionDiagnostics.self, from: data), diagnostic)
    }

    func testListSyntheticAssets() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPSyntheticInjectionService(sessionStore: store, snapshotService: snapshot)

        let result = try service.listSyntheticAssets(policyRevision: .initial)

        XCTAssertFalse(result.assets.isEmpty)
        XCTAssertTrue(result.assets.contains(where: { $0.id == "clear_live_hls" }))
        XCTAssertTrue(result.assets.contains(where: { $0.id == "test_pattern_image" }))
    }

    func testInjectSyntheticItemInCollectionEndpoint() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPSyntheticInjectionService(sessionStore: store, snapshotService: snapshot)

        let result = try service.injectSyntheticItemInCollection(
            name: "Mock EPG Test Channel",
            urlPattern: "*/epg/channels*",
            collectionKeypath: "$.channels",
            position: "prepend",
            boundAssetKind: "clearLiveHLS",
            customAssetURL: nil,
            fieldOverrides: ["name": "Simulator Clear Feed"],
            clientScope: "simulatorOnly",
            policyRevision: .initial
        )

        XCTAssertEqual(result.urlPattern, "*/epg/channels*")
        XCTAssertEqual(result.collectionKeypath, "$.channels")
        XCTAssertEqual(result.boundAssetURL, "https://assets.joesproxy.invalid/fixtures/hls/clear_live_profile.m3u8")
        XCTAssertTrue(result.clientScope.contains("Simulator"))
    }
}
