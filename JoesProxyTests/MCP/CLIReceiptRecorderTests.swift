import Foundation
import XCTest

final class CLIReceiptRecorderTests: XCTestCase {
    private func recorder(_ path: String) throws -> CLIReceiptRecorder {
        try XCTUnwrap(CLIReceiptRecorder(invocation: CLIInvocation.parse(["session", "show", "synthetic",
            "--receipt-output", path, "--receipt-workflow", "fixture", "--receipt-version", "1",
            "--receipt-environment", "synthetic-http"])))
    }

    func testRoundTripFailuresUnknownMetricsAndNoOverwrite() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("build/ReceiptTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("receipt.json").path
        let recorder = try recorder(path)
        recorder.record(operation: "tools/call", bytes: nil, succeeded: false, elapsed: 0.01, reused: nil, retryOf: nil)
        recorder.record(operation: "tools/call", bytes: 123, succeeded: true, elapsed: 0.02, reused: true, retryOf: recorder.lastID)
        try recorder.write()
        let original = try Data(contentsOf: recorder.destination)
        XCTAssertThrowsError(try recorder.write())
        XCTAssertEqual(try Data(contentsOf: recorder.destination), original)
        let receipt = try CLIReceiptRecorder.read(path)
        XCTAssertEqual(receipt.workflow.attempts.count, 2)
        XCTAssertEqual(receipt.workflow.attempts[1].retryOf, "1")
        XCTAssertEqual(receipt.workflow.attempts[1].analysisExecutions, 0)
        XCTAssertNil(receipt.workflow.attempts[0].analysisExecutions)
        let invocation = try CLIInvocation.parse(["efficiency", "compare", "--baseline-receipt", path, "--candidate-receipt", path])
        let result = try CLIWorkflowCostReport.execute(invocation)
        XCTAssertTrue(result.success)
        let report = try CLIWorkflowCostReport.report(JSONEncoder().encode(CLIWorkflowCostReport.Input(
            schemaVersion: 2, baseline: receipt.workflow, candidate: receipt.workflow)))
        let totals = try XCTUnwrap(report["candidate"] as? [String: Any])
        XCTAssertEqual(totals["calls"] as? Int, 2)
        XCTAssertEqual(totals["failures"] as? Int, 1)
        XCTAssertEqual(totals["retries"] as? Int, 1)
        XCTAssertEqual(totals["reportedAnalysisReuses"] as? Int, 1)
        XCTAssertTrue(totals["responseBytes"] is NSNull)
        XCTAssertTrue(totals["analysisExecutions"] is NSNull)
        XCTAssertTrue(totals["providerUsage"] is NSNull)
        XCTAssertEqual(report["qualified"] as? Bool, false)
    }

    func testCollectionBoundAndConfigurationFailClosed() throws {
        XCTAssertNil(try CLIReceiptRecorder(invocation: CLIInvocation.parse(["help"])))
        XCTAssertThrowsError(try CLIReceiptRecorder(invocation: CLIInvocation.parse(["help", "--receipt-output", "unused"])))
        let recorder = try recorder("unused")
        for _ in 0..<1005 {
            recorder.record(operation: "tools/call", bytes: 2, succeeded: true, elapsed: 0, reused: false, retryOf: nil)
        }
        XCTAssertEqual(recorder.attempts.count, 1000)
        XCTAssertEqual(recorder.omittedAttempts, 5)
        XCTAssertNil(recorder.attempts.last?.analysisExecutions, "A non-reused reply does not disclose server work")
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { _ = try CLIReceiptRecorder(invocation: CLIInvocation.parse(["help"])) }
        let disabled = ProcessInfo.processInfo.systemUptime - start
        let enabledStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 {
            let sample = try self.recorder("unused")
            sample.record(operation: "tools/call", bytes: 2, succeeded: true, elapsed: 0, reused: nil, retryOf: nil)
        }
        print("RECEIPT_OVERHEAD samples=1000 disabledSeconds=\(disabled) enabledSeconds=\(ProcessInfo.processInfo.systemUptime - enabledStart) scope=parse_and_collect trendOnly=true")
    }

    func testVersionTwoUnknownsDoNotWeakenVersionOne() throws {
        let recorder = try recorder("unused")
        recorder.record(operation: "tools/call", bytes: 10, succeeded: true, elapsed: 0, reused: nil, retryOf: nil)
        let workflow = CLIWorkflowCostReport.Workflow(context: recorder.context, attempts: recorder.attempts)
        var input = CLIWorkflowCostReport.Input(schemaVersion: 2, baseline: workflow, candidate: workflow)
        let report = try CLIWorkflowCostReport.report(JSONEncoder().encode(input))
        XCTAssertTrue((report["candidateMinusBaseline"] as? [String: Any])?["analysisExecutions"] is NSNull)
        input.schemaVersion = 1
        XCTAssertThrowsError(try CLIWorkflowCostReport.report(JSONEncoder().encode(input)))
    }
}
