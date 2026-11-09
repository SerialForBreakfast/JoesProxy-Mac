import Foundation
import JoesProxySDK

// MARK: - Assertions

extension ProxyCapture {

    // MARK: CDN

    /// Asserts that at least one request matching `pattern` was served from CDN cache.
    ///
    /// Passes silently when no captured events match the pattern (noop with no proxy).
    public func assertCDNHit(matching pattern: String) throws {
        let matching = capturedEvents.filter { urlMatches($0.url, pattern: pattern) }
        guard !matching.isEmpty else { return }
        let hits = matching.filter { $0.cacheStatus == .hit }
        if hits.isEmpty {
            throw ProxyAssertionFailure(
                condition: "assertCDNHit(matching: \"\(pattern)\")",
                actual: "0 of \(matching.count) matching request(s) had cacheStatus .hit",
                matchingURLs: matching.map(\.url)
            )
        }
    }

    /// Asserts that no request matching `pattern` was a CDN cache miss.
    ///
    /// Passes silently when no captured events match the pattern (noop with no proxy).
    public func assertNoCacheMiss(matching pattern: String) throws {
        let misses = capturedEvents.filter {
            urlMatches($0.url, pattern: pattern) && $0.cacheStatus == .miss
        }
        if !misses.isEmpty {
            throw ProxyAssertionFailure(
                condition: "assertNoCacheMiss(matching: \"\(pattern)\")",
                actual: "\(misses.count) request(s) had cacheStatus .miss",
                matchingURLs: misses.map(\.url)
            )
        }
    }

    // MARK: Retries

    /// Asserts that no captured request had retries.
    public func assertNoRetries() throws {
        try assertNoRetries(matching: nil)
    }

    /// Asserts that no request matching `pattern` had retries.
    ///
    /// Pass `nil` to check all captured requests.
    public func assertNoRetries(matching pattern: String?) throws {
        let retried = capturedEvents.filter { event in
            let patternOK = pattern.map { urlMatches(event.url, pattern: $0) } ?? true
            return patternOK && event.retryCount > 0
        }
        if !retried.isEmpty {
            let suffix = pattern.map { " (matching: \"\($0)\")" } ?? ""
            throw ProxyAssertionFailure(
                condition: "assertNoRetries\(suffix)",
                actual: "\(retried.count) request(s) had retryCount > 0",
                matchingURLs: retried.map(\.url)
            )
        }
    }

    // MARK: HTTP version

    /// Asserts that all requests (optionally filtered by `pattern`) used HTTP/2.
    ///
    /// Passes silently when no captured events match the pattern (noop with no proxy).
    public func assertHTTP2(matching pattern: String? = nil) throws {
        let nonHTTP2 = capturedEvents.filter { event in
            let patternOK = pattern.map { urlMatches(event.url, pattern: $0) } ?? true
            return patternOK && event.connectionInfo.httpProtocol != "HTTP/2"
        }
        if !nonHTTP2.isEmpty {
            let suffix = pattern.map { " (matching: \"\($0)\")" } ?? ""
            let found = nonHTTP2.first?.connectionInfo.httpProtocol ?? "unknown"
            throw ProxyAssertionFailure(
                condition: "assertHTTP2\(suffix)",
                actual: "\(nonHTTP2.count) request(s) used \(found) instead of HTTP/2",
                matchingURLs: nonHTTP2.map(\.url)
            )
        }
    }

    // MARK: TLS

    /// Asserts that all captured requests used TLS 1.2 or better.
    ///
    /// - Note: TLS version is not present in schema v1. This assertion always passes.
    ///   It is reserved for a future schema version that includes TLS metadata.
    public func assertAllTLS12OrBetter() throws {
        // Reserved: TLS version field is not in schema v1.
    }

    // MARK: Parallelism

    /// Asserts that all named URL patterns issued requests in overlapping time windows (i.e. in parallel).
    ///
    /// Uses the last completed event matching each pattern. If fewer than 2 patterns have matching
    /// completed events, the assertion passes silently.
    public func assertParallel(_ patterns: [String]) throws {
        guard patterns.count >= 2 else { return }

        var intervals: [(pattern: String, url: URL, start: Date, end: Date)] = []
        for pattern in patterns {
            guard let event = capturedEvents.last(where: {
                $0.phase == .completed && urlMatches($0.url, pattern: pattern)
            }) else { continue }
            let end = event.timestamp
            let start = end.addingTimeInterval(-event.timing.total)
            intervals.append((pattern: pattern, url: event.url, start: start, end: end))
        }

        guard intervals.count >= 2 else { return }

        for i in 0..<intervals.count {
            for j in (i + 1)..<intervals.count {
                let a = intervals[i], b = intervals[j]
                let overlap = a.start < b.end && b.start < a.end
                if !overlap {
                    throw ProxyAssertionFailure(
                        condition: "assertParallel(\(patterns.map { "\"\($0)\"" }.joined(separator: ", ")))",
                        actual: "\"\(a.pattern)\" [\(a.start)–\(a.end)] and \"\(b.pattern)\" [\(b.start)–\(b.end)] did not overlap",
                        matchingURLs: [a.url, b.url]
                    )
                }
            }
        }
    }

    // MARK: Domain allowlist

    /// Asserts that every captured request went to a domain in `allowlist`.
    ///
    /// Wildcard prefixes are supported: `"*.stripe.com"` matches `api.stripe.com` but not `stripe.com`.
    public func assertOnlyAllowedDomains(_ allowlist: [String]) throws {
        let forbidden = capturedEvents.filter { event in
            guard let host = event.url.host else { return false }
            return !allowlist.contains { domainMatches(host: host, pattern: $0) }
        }
        if !forbidden.isEmpty {
            throw ProxyAssertionFailure(
                condition: "assertOnlyAllowedDomains([\(allowlist.map { "\"\($0)\"" }.joined(separator: ", "))])",
                actual: "\(forbidden.count) request(s) went to unlisted domains",
                matchingURLs: forbidden.map(\.url)
            )
        }
    }

    // MARK: Latency

    /// Asserts that the 95th-percentile total latency is under `threshold` seconds.
    ///
    /// Passes silently when fewer than 2 matching events are captured (insufficient data).
    public func assertP95Latency(under threshold: TimeInterval, matching pattern: String? = nil) throws {
        let filtered = capturedEvents.filter { event in
            pattern.map { urlMatches(event.url, pattern: $0) } ?? true
        }
        guard filtered.count >= 2 else { return }
        let sorted = filtered.map(\.timing.total).sorted()
        let p95 = percentile(sorted, fraction: 0.95)
        if p95 > threshold {
            let suffix = pattern.map { " (matching: \"\($0)\")" } ?? ""
            throw ProxyAssertionFailure(
                condition: "assertP95Latency(under: \(String(format: "%.3f", threshold))s\(suffix))",
                actual: "p95 was \(String(format: "%.3f", p95))s over \(filtered.count) request(s)",
                matchingURLs: filtered.map(\.url)
            )
        }
    }

    // MARK: Helpers

    /// Matches `url.host + url.path` against a simple substring pattern.
    private func urlMatches(_ url: URL, pattern: String) -> Bool {
        let full = (url.host ?? "") + url.path
        return full.contains(pattern)
    }

    /// Wildcard domain matching. `*.stripe.com` matches sub-domains only.
    private func domainMatches(host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host.hasSuffix(".\(suffix)")
        }
        return host == pattern
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(ceil(Double(sorted.count) * fraction)) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }
}
