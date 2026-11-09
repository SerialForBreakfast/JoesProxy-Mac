//
//  DataLineageEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for forward watermark correlation, passive reverse lineage search,
//  and full analytics beacon attribution mapping.
//

import XCTest
@testable import JoesProxy

final class DataLineageEngineTests: XCTestCase {

    override func setUp() async throws {
        await ProvenanceRegistry.shared.clear()
    }

    func testForwardWatermarkTokenDetection() async {
        let token = "JP_SRC_feed_a1b2c3"
        let sourceSessionID = UUID()
        let sourceNode = DataLineageNode(
            sessionID: sourceSessionID,
            endpointURL: "https://api.example.com/api/v2/feed",
            httpMethod: "GET",
            timestamp: Date().addingTimeInterval(-2.0),
            keypath: "$.items[0].id",
            value: "asset_999"
        )
        await ProvenanceRegistry.shared.register(token: token, node: sourceNode)

        let sinkSession = makeSession(
            path: "/track/beacon?content_id=asset_999__JP_SRC_feed_a1b2c3",
            method: "GET"
        )

        let report = await DataLineageEngine.auditAnalytics(
            sinkSession: sinkSession,
            upstreamSessions: []
        )

        XCTAssertEqual(report.totalTrackingParameters, 1)
        XCTAssertEqual(report.attributedCount, 1)
        XCTAssertEqual(report.unattributedCount, 0)
        XCTAssertEqual(report.attributionPercentage, 100.0)

        guard let flow = report.flows.first else { return }
        XCTAssertEqual(flow.flowType, .watermarkedToken)
        XCTAssertEqual(flow.sourceNode.endpointURL, "https://api.example.com/api/v2/feed")
        XCTAssertEqual(flow.sourceNode.keypath, "$.items[0].id")
        XCTAssertEqual(flow.sinkNode.keypath, "query.content_id")
        XCTAssertEqual(flow.watermarkToken, token)
        XCTAssertEqual(flow.matchConfidence, 1.0)
    }

    func testPassiveReverseLineageSearchInUnwatermarkedSessionStore() async {
        // Upstream Source Session
        let sourceJSON = """
        {
            "data": {
                "campaign": "summer_promo_2026",
                "asset_id": 48210
            }
        }
        """
        let sourceSession = makeSession(
            path: "/api/v1/config",
            responseBodyText: sourceJSON
        )

        // Sink Analytics Session
        let sinkJSON = """
        {
            "event": "button_click",
            "campaign_id": "summer_promo_2026"
        }
        """
        let sinkSession = makeSession(
            path: "/v1/analytics/event",
            method: "POST",
            requestBodyText: sinkJSON
        )

        let report = await DataLineageEngine.auditAnalytics(
            sinkSession: sinkSession,
            upstreamSessions: [sourceSession]
        )

        XCTAssertEqual(report.totalTrackingParameters, 2)
        XCTAssertGreaterThanOrEqual(report.attributedCount, 1)

        let campaignFlow = report.flows.first(where: { $0.sinkNode.keypath == "$.campaign_id" })
        XCTAssertNotNil(campaignFlow)
        XCTAssertEqual(campaignFlow?.flowType, .exactValueMatch)
        XCTAssertEqual(campaignFlow?.sourceNode.endpointURL, "https://api.example.com/api/v1/config")
        XCTAssertEqual(campaignFlow?.sourceNode.keypath, "$.data.campaign")
        XCTAssertEqual(campaignFlow?.sourceNode.value, "summer_promo_2026")
    }

    func testURLDecodedAndSubstringMatching() {
        let sourceJSON = """
        {
            "stream_uri": "https://cdn.example.com/shows/breaking"
        }
        """
        let sourceSession = makeSession(
            path: "/api/shows/info",
            responseBodyText: sourceJSON
        )

        let results = DataLineageEngine.searchReverseLineage(
            targetValue: "https%3A%2F%2Fcdn.example.com%2Fshows%2Fbreaking",
            candidateSessions: [sourceSession]
        )

        XCTAssertFalse(results.isEmpty)
        guard let first = results.first else { return }
        XCTAssertEqual(first.flowType, .urlDecodedMatch)
        XCTAssertEqual(first.sourceNode.keypath, "$.stream_uri")
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        method: String = "GET",
        requestBodyText: String? = nil,
        responseBodyText: String? = nil
    ) -> SessionRecord {
        let reqData = requestBodyText?.data(using: .utf8)
        let respData = responseBodyText?.data(using: .utf8)

        let request = CapturedRequest(
            method: method,
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: [],
            bodyData: reqData,
            bodySize: reqData?.count
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
