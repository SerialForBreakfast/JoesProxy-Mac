import Foundation

struct InstrumentsCommandExecutionResult: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
    var exitCode: Int32
    var standardOutput: String
    var standardError: String
}

protocol InstrumentsCommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> InstrumentsCommandExecutionResult
}

struct ProcessInstrumentsCommandRunner: InstrumentsCommandRunning {
    func run(executableURL: URL, arguments: [String]) async throws -> InstrumentsCommandExecutionResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()

            // Drain stdout and stderr before waiting to avoid pipe deadlock
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return InstrumentsCommandExecutionResult(
                executableURL: executableURL,
                arguments: arguments,
                exitCode: process.terminationStatus,
                standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
                standardError: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }.value
    }
}
