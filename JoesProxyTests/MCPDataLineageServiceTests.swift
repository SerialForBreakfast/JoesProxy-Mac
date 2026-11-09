//
//  MCPDataLineageServiceTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Data Lineage and Analytics Attribution tools.
//

import XCTest
@testable import JoesProxy

@MainActor
final class MCPDataLineageServiceTests: XCTestCase {

    func testMCPDataLineageTraceEndpoint() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPDataLineageService(sessionStore: store, snapshotService: snapshot)

        let session = makeSession(
            path: "/api/v2/items",
            responseBody: "{\"item_code\": \"sku_apple_watch_9\"}"
        )
        store.append(session)

        let result = try service.traceDataLineage(
            targetValue: "sku_apple_watch_9",
            candidateSessionIDs: [session.id],
            policyRevision: .initial
        )

        XCTAssertEqual(result.candidateSessionsInspected, 1)
        XCTAssertEqual(result.matchingFlowsCount, 1)
        guard let flow = result.flows.first else { return }
        XCTAssertEqual(flow.sourceNode.keypath, "$.item_code")
        XCTAssertEqual(flow.sourceNode.value, "sku_apple_watch_9")
    }

    func testMCPAnalyticsAttributionEndpoint() async throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPDataLineageService(sessionStore: store, snapshotService: snapshot)

        // 1. Upstream Catalog API
        let s1 = makeSession(
            path: "/api/shows/popular",
            responseBody: "{\"show_id\": \"show_stranger_things\", \"category\": \"sci-fi\"}"
        )
        store.append(s1)

        // 2. Downstream Analytics Beacon
        let s2 = makeSession(
            path: "/beacon/event?target_id=show_stranger_things",
            responseBody: "{\"status\": \"recorded\"}"
        )
        store.append(s2)

        let result = try await service.auditAnalyticsAttribution(
            sinkSessionID: s2.id,
            candidateSourceSessionIDs: [s1.id],
            policyRevision: .initial
        )

        XCTAssertEqual(result.totalTrackingParameters, 1)
        XCTAssertEqual(result.attributedCount, 1)
        XCTAssertEqual(result.unattributedCount, 0)
        XCTAssertEqual(result.attributionPercentage, 100.0)

        guard let flow = result.flows.first else { return }
        XCTAssertEqual(flow.sourceNode.keypath, "$.show_id")
        XCTAssertEqual(flow.sinkNode.keypath, "query.target_id")
        XCTAssertEqual(flow.sourceNode.value, "show_stranger_things")
    }

    func testMCPProposeProvenanceWatermarkEndpoint() throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPDataLineageService(sessionStore: store, snapshotService: snapshot)

        let result = try service.proposeProvenanceWatermark(
            name: "Catalog Feed Watermark",
            urlPattern: "*/api/catalog/*",
            targetKeypaths: ["$.items[*].id"],
            strategy: "suffix",
            policyRevision: .initial
        )

        XCTAssertEqual(result.urlPattern, "*/api/catalog/*")
        XCTAssertTrue(result.isEnabled)
        XCTAssertEqual(result.targetKeypaths, ["$.items[*].id"])
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        responseBody: String
    ) -> SessionRecord {
        let respData = responseBody.data(using: .utf8)
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        let response = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: respData,
            bodySize: respData?.count
        )

        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}
