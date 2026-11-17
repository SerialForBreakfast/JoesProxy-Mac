import Foundation

/// Fixed, credential-free diagnostics. No shell, curlrc, redirect, retry, or CA override.
struct SetupTrafficProbe: Sendable {
    enum Kind: String, CaseIterable { case http, https }
    enum Outcome: Equatable {
        case waiting, checking, passed(String), failed(String)
        var message: String {
            switch self {
            case .waiting: "Not tested"
            case .checking: "Checking…"
            case .passed(let message), .failed(let message): message
            }
        }
    }
    let kind: Kind
    let nonce: UUID
    var path: String { "/?joesproxy-setup=\(nonce.uuidString.lowercased())-\(kind.rawValue)" }
    var url: String { "\(kind.rawValue)://example.org\(path)" }

    func matches(method: String, host: String, scheme: String, path: String,
                 inspection: String, status: Int?, clientStatus: Int) -> Bool {
        method == "GET" && host.lowercased() == "example.org" && scheme == kind.rawValue &&
        (path == self.path || path == url) && inspection == (kind == .https ? "interceptedTLS" : "plain") &&
        status == clientStatus && (200..<300).contains(clientStatus)
    }

    func send(port: UInt16) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
                process.arguments = ["-q", "--silent", "--max-time", "10", "--retry", "0",
                    "--noproxy", "", "--proxy", "http://127.0.0.1:\(port)", "--http1.1",
                    "--header", "Connection: close", "--max-filesize", "65536",
                    "--output", "/dev/null", "--write-out", "%{http_code}", url]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw NSError(domain: "SetupTrafficProbe", code: Int(process.terminationStatus),
                                      userInfo: [NSLocalizedDescriptionKey: "Request failed (curl \(process.terminationStatus))."])
                    }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    guard let status = Int(String(decoding: data, as: UTF8.self)) else {
                        throw URLError(.badServerResponse)
                    }
                    continuation.resume(returning: status)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
