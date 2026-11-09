import Foundation
import XCTest

final class CLIWorkflowCostReportTests: XCTestCase {
    private func input() -> CLIWorkflowCostReport.Input {
        let context = CLIWorkflowCostReport.Context(fixture: "synthetic", version: "1", environment: "Debug/local", measurementLayer: "MCPResult")
        let attempt = CLIWorkflowCostReport.Attempt(id: "1", operation: "brief", outcome: "success", responseBytes: 100, analysisExecutions: 1, latencyMilliseconds: 2)
        let workflow = CLIWorkflowCostReport.Workflow(context: context, attempts: [attempt])
        return .init(schemaVersion: 1, baseline: workflow, candidate: workflow)
    }

    func testUnknownUsageIsNotZeroAndFailureRetryCostsRemainIncluded() throws {
        var value = input()
        value.candidate.attempts[0].outcome = "failure"
        value.candidate.attempts.append(.init(id: "2", operation: "brief", outcome: "success", retryOf: "1", responseBytes: 30, analysisExecutions: 0))
        let report = try CLIWorkflowCostReport.report(JSONEncoder().encode(value))
        XCTAssertEqual(report["qualified"] as? Bool, false)
        XCTAssertTrue(report["candidateMinusBaseline"] is NSNull)
        let candidate = try XCTUnwrap(report["candidate"] as? [String: Any])
        XCTAssertEqual(candidate["calls"] as? Int, 2)
        XCTAssertEqual(candidate["responseBytes"] as? Int, 130)
        XCTAssertEqual(candidate["retries"] as? Int, 1)
        XCTAssertTrue(candidate["providerUsage"] is NSNull)
        XCTAssertTrue(candidate["latencyMillisecondsTotal"] is NSNull)
    }

    func testSuppliedUsageCostsAndMixedCurrencies() throws {
        var value = input()
        value.candidate.providerUsage = [.init(receiptID: "r1", model: "synthetic-model-v1", inputTokens: 12, outputTokens: 3, reportedCostMicros: 20, currency: "USD")]
        var report = try CLIWorkflowCostReport.report(JSONEncoder().encode(value))
        var usage = try XCTUnwrap((report["candidate"] as? [String: Any])?["providerUsage"] as? [String: Any])
        XCTAssertEqual(usage["reportedCostMicros"] as? Int, 20)
        XCTAssertEqual(usage["inputTokens"] as? Int, 12)
        value.candidate.providerUsage?.append(.init(receiptID: "r2", model: "synthetic-model-v1", inputTokens: 1, outputTokens: 1, reportedCostMicros: 10, currency: "EUR"))
        report = try CLIWorkflowCostReport.report(JSONEncoder().encode(value))
        usage = try XCTUnwrap((report["candidate"] as? [String: Any])?["providerUsage"] as? [String: Any])
        XCTAssertTrue(usage["reportedCostMicros"] is NSNull)
    }

    func testProviderDeltaRequiresMatchedModelsAndPreservesProvenance() throws {
        var value = input()
        value.baseline.providerUsage = [.init(receiptID: "b", model: "synthetic-v1", inputTokens: 100, outputTokens: 10, reportedCostMicros: 100, currency: "USD")]
        value.candidate.providerUsage = [.init(receiptID: "c", model: "synthetic-v1", inputTokens: 20, outputTokens: 5, reportedCostMicros: 30, currency: "USD")]
        let data = try JSONEncoder().encode(value)
        let report = try CLIWorkflowCostReport.report(data)
        let delta = try XCTUnwrap(report["providerCandidateMinusBaseline"] as? [String: Any])
        XCTAssertEqual(delta["inputTokens"] as? Int, -80)
        XCTAssertEqual(delta["reportedCostMicros"] as? Int, -70)
        XCTAssertEqual((report["inputSHA256"] as? String)?.count, 64)
        XCTAssertEqual((report["baseline"] as? [String: Any])?["context"] as? [String: String],
            ["fixture": "synthetic", "version": "1", "environment": "Debug/local", "measurementLayer": "MCPResult"])
        value.candidate.providerUsage?[0].model = "different-v2"
        XCTAssertTrue(try CLIWorkflowCostReport.report(JSONEncoder().encode(value))["providerCandidateMinusBaseline"] is NSNull)
    }

    func testRejectsMalformedBoundsDuplicateIDsAndUnknownRetry() throws {
        var value = input()
        value.candidate.attempts[0].responseBytes = -1
        XCTAssertThrowsError(try CLIWorkflowCostReport.report(JSONEncoder().encode(value)))
        value = input()
        value.candidate.attempts.append(value.candidate.attempts[0])
        XCTAssertThrowsError(try CLIWorkflowCostReport.report(JSONEncoder().encode(value)))
        value = input()
        value.candidate.attempts[0].retryOf = "unknown"
        XCTAssertThrowsError(try CLIWorkflowCostReport.report(JSONEncoder().encode(value)))
        XCTAssertThrowsError(try CLIWorkflowCostReport.report(Data(repeating: 32, count: 1_048_577)))
        value = input()
        value.candidate.context.version = "2"
        XCTAssertEqual(try CLIWorkflowCostReport.report(JSONEncoder().encode(value))["qualified"] as? Bool, false)
    }
}
