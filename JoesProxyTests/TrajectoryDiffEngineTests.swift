//
//  TrajectoryDiffEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for multi-session trajectory sequence alignment,
//  dynamic parameter normalization, and behavioral divergence detection.
//

import XCTest
@testable import JoesProxy

final class TrajectoryDiffEngineTests: XCTestCase {

    func testTrajectorySequenceAlignmentAndMatching() {
        let base1 = makeSession(method: "GET", path: "/auth", status: 200)
        let base2 = makeSession(method: "GET", path: "/config", status: 200)
        let base3 = makeSession(method: "GET", path: "/feed", status: 200)

        let cand1 = makeSession(method: "GET", path: "/auth", status: 200)
        let cand2 = makeSession(method: "GET", path: "/config", status: 200)
        let cand3 = makeSession(method: "GET", path: "/feed", status: 200)

        let report = TrajectoryDiffEngine.diffTrajectories(
            baseline: [base1, base2, base3],
            candidate: [cand1, cand2, cand3]
        )

        XCTAssertEqual(report.alignedSteps.count, 3)
        XCTAssertEqual(report.similarityScore, 100.0)
        XCTAssertNil(report.divergencePointIndex)
        XCTAssertNil(report.divergencePointSummary)
    }

    func testTrajectoryDivergenceOnStatusCodeMismatch() {
        let base1 = makeSession(method: "GET", path: "/auth", status: 200)
        let base2 = makeSession(method: "GET", path: "/feed", status: 200)

        let cand1 = makeSession(method: "GET", path: "/auth", status: 401)
        let cand2 = makeSession(method: "POST", path: "/telemetry/error", status: 200)

        let report = TrajectoryDiffEngine.diffTrajectories(
            baseline: [base1, base2],
            candidate: [cand1, cand2]
        )

        XCTAssertEqual(report.divergencePointIndex, 1)
        XCTAssertNotNil(report.divergencePointSummary)
        XCTAssertEqual(report.alignedSteps.first?.stepType, .statusCodeMismatch)
        XCTAssertLessThan(report.similarityScore, 100.0)
    }

    func testTrajectoryDynamicParamNormalization() {
        let base = makeSession(method: "GET", path: "/api/feed?ts=11111&nonce=abc", status: 200)
        let cand = makeSession(method: "GET", path: "/api/feed?ts=22222&nonce=xyz", status: 200)

        let report = TrajectoryDiffEngine.diffTrajectories(
            baseline: [base],
            candidate: [cand]
        )

        XCTAssertEqual(report.alignedSteps.count, 1)
        XCTAssertEqual(report.alignedSteps.first?.stepType, .matched)
        XCTAssertEqual(report.alignedSteps.first?.requestSignature, "GET /api/feed")
        XCTAssertEqual(report.similarityScore, 100.0)
    }

    // MARK: - Helper

    private func makeSession(method: String, path: String, status: Int, bodyJSON: String? = nil) -> SessionRecord {
        let req = CapturedRequest(
            method: method,
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: path,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: nil,
            bodySize: nil
        )

        let data = (bodyJSON ?? "{\"status\":\"ok\"}").data(using: .utf8)
        let resp = CapturedResponse(
            statusCode: status,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: data,
            bodySize: data?.count
        )

        return SessionRecord(
            request: req,
            response: resp,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}
