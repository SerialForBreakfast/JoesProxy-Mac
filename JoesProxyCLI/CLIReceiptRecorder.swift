import Foundation

/// One serial CLI invocation; content-free transport attempts, never request arguments or URLs.
final class CLIReceiptRecorder {
    struct Receipt: Codable {
        var schemaVersion = 2
        var workflow: CLIWorkflowCostReport.Workflow
        var omittedAttempts: Int
    }
    private(set) var attempts: [CLIWorkflowCostReport.Attempt] = []
    private(set) var omittedAttempts = 0
    private var sequence = 0
    var lastID: String? { attempts.last?.id }
    let destination: URL
    let context: CLIWorkflowCostReport.Context

    init?(invocation: CLIInvocation) throws {
        guard let path = invocation.options["receipt-output"] else { return nil }
        guard let fixture = invocation.options["receipt-workflow"],
              let version = invocation.options["receipt-version"],
              let environment = invocation.options["receipt-environment"],
              [fixture, version, environment].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 128 }),
              !invocation.command.contains("watch") else {
            throw CLIError.invalidArguments("Receipt export requires --receipt-workflow, --receipt-version and --receipt-environment (1–128 UTF-8 bytes each); watch streams are not supported.")
        }
        destination = URL(fileURLWithPath: path)
        context = .init(fixture: fixture, version: version, environment: environment, measurementLayer: "httpResponseBody")
    }

    func record(operation: String, bytes: Int?, succeeded: Bool, elapsed: Double, reused: Bool?, retryOf: String?) {
        sequence += 1
        guard attempts.count < 1000 else { omittedAttempts += 1; return }
        attempts.append(.init(id: String(sequence), operation: operation, outcome: succeeded ? "success" : "failure",
            retryOf: retryOf, responseBytes: bytes, analysisExecutions: reused == true ? 0 : nil,
            latencyMilliseconds: max(0, elapsed * 1000), analysisReused: reused))
    }

    func write() throws {
        let receipt = Receipt(workflow: .init(context: context, attempts: attempts), omittedAttempts: omittedAttempts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(receipt)
        guard data.count <= CLIWorkflowCostReport.maximumBytes else { throw CLIError.invalidArguments("Receipt exceeds export budget.") }
        try data.write(to: destination, options: [.withoutOverwriting])
    }

    func markLastFailure() {
        guard omittedAttempts == 0, !attempts.isEmpty else { return }
        let index = attempts.count - 1
        attempts[index].outcome = "failure"
        attempts[index].analysisExecutions = nil
        attempts[index].analysisReused = nil
    }

    static func read(_ path: String) throws -> Receipt {
        let url = URL(fileURLWithPath: path)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CLIError.invalidArguments("Receipt must be a regular local file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: CLIWorkflowCostReport.maximumBytes + 1) ?? Data()
        guard data.count <= CLIWorkflowCostReport.maximumBytes,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.schemaVersion == 2, receipt.omittedAttempts == 0 else {
            throw CLIError.invalidArguments("Invalid or incomplete receipt; omitted attempts cannot form a qualified comparison.")
        }
        return receipt
    }
}
