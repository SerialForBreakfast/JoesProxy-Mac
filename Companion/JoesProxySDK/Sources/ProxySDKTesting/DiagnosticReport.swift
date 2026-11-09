import Foundation
import JoesProxySDK

/// A CI-friendly snapshot of network behavior captured during a `ProxyCapture` window.
///
/// Obtain via `ProxyCapture.diagnosticReport()`. Attach to test results as a JSON artifact:
/// ```swift
/// let data = try capture.diagnosticReport().jsonData()
/// // XCTest: add(XCTAttachment(data: data, uniformTypeIdentifier: "public.json"))
/// ```
public struct DiagnosticReport: Codable, Sendable {
    public let label: String
    public let captureStart: Date
    public let captureEnd: Date
    public let requestCount: Int
    /// Fraction of requests that completed with a 4xx/5xx status or `.failed` phase.
    public let errorRate: Double
    public let p50LatencySeconds: Double
    public let p95LatencySeconds: Double
    /// Fraction of requests that had `cacheStatus == .hit`.
    public let cdnHitRate: Double
    public let totalRetryCount: Int
    /// Count of requests per `sourceSDK` label (third-party SDK attribution).
    public let thirdPartySummary: [String: Int]

    public init(label: String, captureStart: Date, captureEnd: Date, events: [NetworkEvent]) {
        self.label = label
        self.captureStart = captureStart
        self.captureEnd = captureEnd
        self.requestCount = events.count

        let errorCount = events.filter {
            if let sc = $0.statusCode { return sc >= 400 }
            return $0.phase == .failed
        }.count
        self.errorRate = events.isEmpty ? 0 : Double(errorCount) / Double(events.count)

        let latencies = events.map(\.timing.total).sorted()
        self.p50LatencySeconds = Self.percentile(latencies, fraction: 0.50)
        self.p95LatencySeconds = Self.percentile(latencies, fraction: 0.95)

        let hitCount = events.filter { $0.cacheStatus == .hit }.count
        self.cdnHitRate = events.isEmpty ? 0 : Double(hitCount) / Double(events.count)

        self.totalRetryCount = events.reduce(0) { $0 + $1.retryCount }

        var summary: [String: Int] = [:]
        for event in events {
            if let sdk = event.sourceSDK {
                summary[sdk, default: 0] += 1
            }
        }
        self.thirdPartySummary = summary
    }

    /// Returns a pretty-printed JSON representation suitable for CI artifacts.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(ceil(Double(sorted.count) * fraction)) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }
}
