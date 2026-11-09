import Foundation

/// Thrown by ProxyCapture assertion methods when an assertion fails.
public struct ProxyAssertionFailure: Error, CustomStringConvertible, Sendable {
    /// The assertion that was checked (e.g. `assertCDNHit(matching: "cdn.")`).
    public let condition: String
    /// Human-readable description of what was actually observed.
    public let actual: String
    /// URLs of requests that matched the assertion's pattern, for context.
    public let matchingURLs: [URL]

    public var description: String { "\(condition): \(actual)" }
}
