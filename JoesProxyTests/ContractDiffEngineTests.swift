//
//  ContractDiffEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for recursive JSON shape diffing, breaking change classification, and regression suites.
//

import XCTest
@testable import JoesProxy

final class ContractDiffEngineTests: XCTestCase {

    func testBreakingChangeOnRemovedField() {
        let baselineJSON = """
        {
            "id": "usr_123",
            "name": "Alice",
            "email": "alice@example.com"
        }
        """.data(using: .utf8)!

        let liveJSON = """
        {
            "id": "usr_123",
            "name": "Alice"
        }
        """.data(using: .utf8)!

        let baseProfile = JSONStructuralProfiler.profile(bodyData: baselineJSON)
        let liveProfile = JSONStructuralProfiler.profile(bodyData: liveJSON)

        let diffs = ContractDiffEngine.diff(baseline: baseProfile.shape, live: liveProfile.shape)
        XCTAssertEqual(diffs.count, 1)

        let diff = diffs.first
        XCTAssertEqual(diff?.jsonPath, "$.email")
        XCTAssertEqual(diff?.severity, .breaking)
        if case .removedField(let expected) = diff?.kind {
            XCTAssertEqual(expected, "string")
        } else {
            XCTFail("Expected .removedField")
        }
    }

    func testCompatibleAdditionOfNewOptionalField() {
        let baselineJSON = """
        {
            "id": "usr_123",
            "name": "Alice"
        }
        """.data(using: .utf8)!

        let liveJSON = """
        {
            "id": "usr_123",
            "name": "Alice",
            "avatarUrl": "https://cdn.example.com/avatar.jpg"
        }
        """.data(using: .utf8)!

        let baseProfile = JSONStructuralProfiler.profile(bodyData: baselineJSON)
        let liveProfile = JSONStructuralProfiler.profile(bodyData: liveJSON)

        let diffs = ContractDiffEngine.diff(baseline: baseProfile.shape, live: liveProfile.shape)
        XCTAssertEqual(diffs.count, 1)

        let diff = diffs.first
        XCTAssertEqual(diff?.jsonPath, "$.avatarUrl")
        XCTAssertEqual(diff?.severity, .compatibleAddition)
        if case .addedField(let actual) = diff?.kind {
            XCTAssertEqual(actual, "string")
        } else {
            XCTFail("Expected .addedField")
        }
    }

    func testBreakingTypeMutationAndUnexpectedNull() {
        let baselineJSON = """
        {
            "id": "usr_123",
            "age": 30,
            "isActive": true
        }
        """.data(using: .utf8)!

        let liveJSON = """
        {
            "id": 12345,
            "age": "30",
            "isActive": null
        }
        """.data(using: .utf8)!

        let baseProfile = JSONStructuralProfiler.profile(bodyData: baselineJSON)
        let liveProfile = JSONStructuralProfiler.profile(bodyData: liveJSON)

        let diffs = ContractDiffEngine.diff(baseline: baseProfile.shape, live: liveProfile.shape)
        XCTAssertEqual(diffs.count, 3)

        // id: string -> number
        let idDiff = diffs.first(where: { $0.jsonPath == "$.id" })
        XCTAssertEqual(idDiff?.severity, .breaking)

        // age: number -> string
        let ageDiff = diffs.first(where: { $0.jsonPath == "$.age" })
        XCTAssertEqual(ageDiff?.severity, .breaking)

        // isActive: bool -> null
        let activeDiff = diffs.first(where: { $0.jsonPath == "$.isActive" })
        XCTAssertEqual(activeDiff?.severity, .breaking)
        if case .unexpectedNull = activeDiff?.kind {
            // expected
        } else {
            XCTFail("Expected .unexpectedNull for isActive")
        }
    }

    func testSessionPairwiseComparisonAndRegressionSuite() {
        let baselineSession = makeSession(
            path: "/v1/user",
            status: 200,
            json: "{\"userId\":\"u1\",\"role\":\"admin\"}"
        )

        let liveCompliantSession = makeSession(
            path: "/v1/user",
            status: 200,
            json: "{\"userId\":\"u2\",\"role\":\"editor\",\"extra\":true}"
        )

        let liveBrokenSession = makeSession(
            path: "/v1/user",
            status: 500,
            json: "{\"error\":\"server_failure\"}"
        )

        // 1. Compliant Session comparison
        let report1 = ContractDiffEngine.compareSessions(baseline: baselineSession, live: liveCompliantSession)
        XCTAssertTrue(report1.isCompliant)
        XCTAssertEqual(report1.breakingChangeCount, 0)
        XCTAssertEqual(report1.compatibleAdditionCount, 1)

        // 2. Broken Session comparison
        let report2 = ContractDiffEngine.compareSessions(baseline: baselineSession, live: liveBrokenSession)
        XCTAssertFalse(report2.isCompliant)
        XCTAssertGreaterThan(report2.breakingChangeCount, 0)

        // 3. Regression Suite
        let suite = ContractDiffEngine.runRegressionSuite(
            baselineSessions: [baselineSession],
            liveSessions: [liveCompliantSession]
        )
        XCTAssertTrue(suite.isSuitePassed)
        XCTAssertEqual(suite.totalEndpointsTested, 1)
        XCTAssertEqual(suite.compliantEndpointsCount, 1)
        XCTAssertEqual(suite.breakingEndpointsCount, 0)
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        status: Int,
        json: String
    ) -> SessionRecord {
        let bodyData = json.data(using: .utf8)
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
            statusCode: status,
            headers: [
                HTTPHeaderField(name: "Content-Type", value: "application/json"),
                HTTPHeaderField(name: "Content-Length", value: "\(bodyData?.count ?? 0)")
            ],
            bodyData: bodyData,
            bodySize: bodyData?.count
        )

        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}
