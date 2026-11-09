import Foundation

/// Shared HTTP GET through the local proxy for UI smoke tests.
///
/// HTTP only (`localhost` or `http://example.com/`). Does not invoke `proxy_smoke_test.sh`.
enum ProxyHTTPCaptureHelper {
    /// Runs a single `curl` GET via `http://127.0.0.1:<proxyPort>`.
    ///
    /// Concurrency: blocking process wait on the calling test thread. Call from `@MainActor`
    /// UI tests after the proxy reports running; do not run concurrently with another host lane.
    static func curlGET(
        url: String,
        proxyPort: UInt16,
        timeoutSeconds: Int = 10,
        includeBody: Bool = false
    ) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--silent",
            "--show-error",
            "--max-time", "\(timeoutSeconds)",
            "--noproxy", "",
            "--proxy", "http://127.0.0.1:\(proxyPort)",
            url
        ]
        if !includeBody { process.arguments?.insert(contentsOf: ["--output", "/dev/null"], at: 0) }
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}
