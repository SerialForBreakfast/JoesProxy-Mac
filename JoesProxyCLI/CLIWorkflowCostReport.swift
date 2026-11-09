import Foundation
import CryptoKit

/// Offline receipt arithmetic only. No credentials, app launch, network, pricing lookup or inference.
enum CLIWorkflowCostReport {
    static let maximumBytes = 1_048_576

    struct Context: Codable, Equatable {
        var fixture: String
        var version: String
        var environment: String
        var measurementLayer: String
    }
    struct Attempt: Codable {
        var id: String
        var operation: String
        var outcome: String
        var retryOf: String?
        var responseBytes: Int?
        var analysisExecutions: Int?
        var latencyMilliseconds: Double?
        var analysisReused: Bool?
    }
    struct Usage: Codable {
        var receiptID: String
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var reportedCostMicros: Int?
        var currency: String?
    }
    struct Workflow: Codable {
        var context: Context
        var attempts: [Attempt]
        /// nil means unknown; an explicit empty list declares no provider calls.
        var providerUsage: [Usage]?
    }
    struct Input: Codable {
        var schemaVersion: Int
        var baseline: Workflow
        var candidate: Workflow
    }

    static func execute(_ invocation: CLIInvocation) throws -> CLIResultEnvelope {
        if invocation.command == ["efficiency", "compare"],
           let baseline = invocation.options["baseline-receipt"], let candidate = invocation.options["candidate-receipt"] {
            let input = Input(schemaVersion: 2, baseline: try CLIReceiptRecorder.read(baseline).workflow,
                candidate: try CLIReceiptRecorder.read(candidate).workflow)
            return CLIResultEnvelope(command: "efficiency compare", success: true,
                result: try report(JSONEncoder().encode(input)), warnings: [], errorCode: nil, errorMessage: nil)
        }
        guard invocation.command == ["efficiency", "report"], let path = invocation.options["file"] else {
            throw CLIError.invalidArguments("Use efficiency report --file <workflow.json> --json.")
        }
        let url = URL(fileURLWithPath: path)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CLIError.invalidArguments("Workflow input must be a regular local file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return CLIResultEnvelope(command: "efficiency report", success: true,
            result: try report(data), warnings: [], errorCode: nil, errorMessage: nil)
    }

    static func report(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes, let input = try? JSONDecoder().decode(Input.self, from: data),
              [1, 2].contains(input.schemaVersion) else { throw invalid() }
        if input.schemaVersion == 1,
           (input.baseline.attempts + input.candidate.attempts).contains(where: { $0.responseBytes == nil || $0.analysisExecutions == nil }) { throw invalid() }
        try validate(input.baseline)
        try validate(input.candidate)
        let baseline = totals(input.baseline), candidate = totals(input.candidate)
        var reasons: [String] = []
        if input.baseline.context != input.candidate.context { reasons.append("context_mismatch") }
        if input.baseline.attempts.contains(where: { $0.outcome == "failure" }) ||
            input.candidate.attempts.contains(where: { $0.outcome == "failure" }) { reasons.append("failed_attempts_present") }
        var delta: [String: Any] = [:]
        if reasons.isEmpty {
            for key in ["calls", "responseBytes", "analysisExecutions"] {
                if let after = candidate[key] as? Int, let before = baseline[key] as? Int { delta[key] = after - before }
                else { delta[key] = NSNull() }
            }
        }
        return ["schemaVersion": input.schemaVersion, "source": "offline_supplied_receipts", "qualified": reasons.isEmpty,
            "inputSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "qualifications": reasons, "baseline": baseline, "candidate": candidate,
            "candidateMinusBaseline": reasons.isEmpty ? delta : NSNull(),
            "providerCandidateMinusBaseline": reasons.isEmpty ? providerDelta(baseline, candidate) : NSNull(),
            "scope": "Supplied receipts are not independently verified. All attempts, failures and retries count. Matching context and successful calls do not prove semantic equivalence. Bytes are not tokens; costs are supplied actual receipts, never price estimates."]
    }

    private static func validate(_ workflow: Workflow) throws {
        let context = workflow.context
        guard [context.fixture, context.version, context.environment, context.measurementLayer].allSatisfy(short),
              !workflow.attempts.isEmpty, workflow.attempts.count <= 1000 else { throw invalid() }
        var seen = Set<String>()
        for attempt in workflow.attempts {
            guard short(attempt.id), short(attempt.operation), !seen.contains(attempt.id),
                  ["success", "failure"].contains(attempt.outcome), attempt.responseBytes.map(bounded) ?? true,
                  attempt.analysisExecutions.map({ (0...1000).contains($0) }) ?? true else { throw invalid() }
            if let retry = attempt.retryOf, !seen.contains(retry) { throw invalid() }
            if let latency = attempt.latencyMilliseconds,
               !latency.isFinite || latency < 0 || latency > 86_400_000 { throw invalid() }
            seen.insert(attempt.id)
        }
        if let usage = workflow.providerUsage {
            guard usage.count <= 1000 else { throw invalid() }
            var receiptIDs = Set<String>()
            for receipt in usage {
                guard short(receipt.receiptID), short(receipt.model), receiptIDs.insert(receipt.receiptID).inserted,
                      bounded(receipt.inputTokens), bounded(receipt.outputTokens) else { throw invalid() }
                if let cost = receipt.reportedCostMicros {
                    guard bounded(cost), let currency = receipt.currency, currency.utf8.count == 3,
                          currency.utf8.allSatisfy({ (65...90).contains($0) }) else { throw invalid() }
                } else if receipt.currency != nil { throw invalid() }
            }
        }
    }

    private static func totals(_ workflow: Workflow) -> [String: Any] {
        let attempts = workflow.attempts
        let latencies = attempts.compactMap(\.latencyMilliseconds).sorted()
        var result: [String: Any] = [
            "context": ["fixture": workflow.context.fixture, "version": workflow.context.version,
                "environment": workflow.context.environment, "measurementLayer": workflow.context.measurementLayer],
            "calls": attempts.count, "failures": attempts.filter { $0.outcome == "failure" }.count,
            "retries": attempts.filter { $0.retryOf != nil }.count,
            "reportedAnalysisReuses": attempts.filter { $0.analysisReused == true }.count,
            "analysisReuseSignalCount": attempts.filter { $0.analysisReused != nil }.count,
            "responseBytes": attempts.allSatisfy { $0.responseBytes != nil } ? attempts.reduce(0) { $0 + ($1.responseBytes ?? 0) } as Any : NSNull(),
            "analysisExecutions": attempts.allSatisfy { $0.analysisExecutions != nil } ? attempts.reduce(0) { $0 + ($1.analysisExecutions ?? 0) } as Any : NSNull(),
            "latencySampleCount": latencies.count,
            "latencyMillisecondsTotal": latencies.count == attempts.count ? latencies.reduce(0, +) as Any : NSNull(),
            "latencyP50Milliseconds": latencies.isEmpty ? NSNull() : latencies[(latencies.count - 1) / 2] as Any,
            "latencyP95Milliseconds": latencies.isEmpty ? NSNull() : latencies[Int(ceil(Double(latencies.count) * 0.95)) - 1] as Any,
            "providerUsage": NSNull()
        ]
        if let usage = workflow.providerUsage {
            let currencies = Set(usage.compactMap(\.currency))
            let completeCost = !usage.isEmpty && usage.allSatisfy { $0.reportedCostMicros != nil } && currencies.count == 1
            result["providerUsage"] = [
                "receiptCount": usage.count, "models": Array(Set(usage.map(\.model))).sorted(),
                "inputTokens": usage.reduce(0) { $0 + $1.inputTokens },
                "outputTokens": usage.reduce(0) { $0 + $1.outputTokens },
                "reportedCostMicros": completeCost ? usage.reduce(0) { $0 + ($1.reportedCostMicros ?? 0) } as Any : NSNull(),
                "currency": completeCost ? currencies.first! as Any : NSNull(),
                "costCoverage": completeCost ? "complete" : "unknown_or_mixed_currency"
            ] as [String: Any]
        }
        return result
    }

    private static func providerDelta(_ baseline: [String: Any], _ candidate: [String: Any]) -> Any {
        guard let before = baseline["providerUsage"] as? [String: Any],
              let after = candidate["providerUsage"] as? [String: Any],
              let models = before["models"] as? [String], models == after["models"] as? [String],
              let beforeInput = before["inputTokens"] as? Int, let afterInput = after["inputTokens"] as? Int,
              let beforeOutput = before["outputTokens"] as? Int, let afterOutput = after["outputTokens"] as? Int else {
            return NSNull()
        }
        var result: [String: Any] = ["inputTokens": afterInput - beforeInput,
            "outputTokens": afterOutput - beforeOutput, "reportedCostMicros": NSNull(), "currency": NSNull()]
        if let currency = before["currency"] as? String, currency == after["currency"] as? String,
           let beforeCost = before["reportedCostMicros"] as? Int, let afterCost = after["reportedCostMicros"] as? Int {
            result["reportedCostMicros"] = afterCost - beforeCost
            result["currency"] = currency
        }
        return result
    }

    private static func short(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 128 }
    private static func bounded(_ value: Int) -> Bool { (0...1_000_000_000_000).contains(value) }
    private static func invalid() -> CLIError {
        .invalidArguments("Invalid workflow receipt: require schemaVersion 1 or 2, matching typed fields, bounded nonnegative metrics and unique attempt/usage IDs. Maximum input 1 MiB and 1000 entries per list.")
    }
}
