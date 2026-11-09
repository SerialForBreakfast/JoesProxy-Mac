import Foundation
import Testing
import JoesProxySDK
import ProxySDKTesting

// MARK: - CDN Hit

@Suite("assertCDNHit")
struct CDNHitAssertionTests {
    @Test func passesWhenMatchingRequestHasCacheHit() throws {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://cdn.example.com/image.png")!, cacheStatus: .hit),
        ])
        try cap.assertCDNHit(matching: "cdn.example.com")
    }

    @Test func throwsWhenNoMatchingRequestHasCacheHit() {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://cdn.example.com/image.png")!, cacheStatus: .miss),
        ])
        #expect(throws: ProxyAssertionFailure.self) {
            try cap.assertCDNHit(matching: "cdn.example.com")
        }
    }

    @Test func noopWhenNoEventsMatchPattern() throws {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://api.example.com/users")!, cacheStatus: .miss),
        ])
        try cap.assertCDNHit(matching: "cdn.example.com")
    }

    @Test func noopWithEmptyCapture() throws {
        try ProxyCapture.makeFixture(events: []).assertCDNHit(matching: "cdn.")
    }
}

// MARK: - No Cache Miss

@Suite("assertNoCacheMiss")
struct NoCacheMissAssertionTests {
    @Test func passesWhenNoMatchingMisses() throws {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://cdn.example.com/a.png")!, cacheStatus: .hit),
        ])
        try cap.assertNoCacheMiss(matching: "cdn.example.com")
    }

    @Test func throwsWhenMatchingMissExists() {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://cdn.example.com/a.png")!, cacheStatus: .hit),
            NetworkEventFixture.make(url: URL(string: "https://cdn.example.com/b.png")!, cacheStatus: .miss),
        ])
        #expect(throws: ProxyAssertionFailure.self) {
            try cap.assertNoCacheMiss(matching: "cdn.example.com")
        }
    }

    @Test func noopWithEmptyCapture() throws {
        try ProxyCapture.makeFixture(events: []).assertNoCacheMiss(matching: "cdn.")
    }
}

// MARK: - No Retries

@Suite("assertNoRetries")
struct NoRetriesAssertionTests {
    @Test func passesWhenNoEventHasRetries() throws {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(retryCount: 0),
            NetworkEventFixture.make(retryCount: 0),
        ])
        try cap.assertNoRetries()
    }

    @Test func throwsWhenAnyEventHasRetries() {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(retryCount: 0),
            NetworkEventFixture.make(retryCount: 1),
        ])
        #expect(throws: ProxyAssertionFailure.self) {
            try cap.assertNoRetries()
        }
    }

    @Test func patternFilterLimitsScope() throws {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://api.example.com/data")!, retryCount: 2),
            NetworkEventFixture.make(url: URL(string: "https://cdn.example.com/img.png")!, retryCount: 0),
        ])
        // Retry is on api., assertion checks only cdn. — should pass.
        try cap.assertNoRetries(matching: "cdn.example.com")
    }

    @Test func noopWithEmptyCapture() throws {
        try ProxyCapture.makeFixture(events: []).assertNoRetries()
    }
}

// MARK: - HTTP/2

@Suite("assertHTTP2")
struct HTTP2AssertionTests {
    @Test func passesWhenAllRequestsUseHTTP2() throws {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(httpProtocol: "HTTP/2"),
            NetworkEventFixture.make(httpProtocol: "HTTP/2"),
        ])
        try cap.assertHTTP2()
    }

    @Test func throwsWhenAnyRequestUsesHTTP1() {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(httpProtocol: "HTTP/2"),
            NetworkEventFixture.make(url: URL(string: "https://legacy.example.com/v1")!, httpProtocol: "HTTP/1.1"),
        ])
        #expect(throws: ProxyAssertionFailure.self) {
            try cap.assertHTTP2()
        }
    }

    @Test func patternFilterLimitsScope() throws {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://api.example.com/users")!, httpProtocol: "HTTP/1.1"),
            NetworkEventFixture.make(url: URL(string: "https://cdn.example.com/img.png")!, httpProtocol: "HTTP/2"),
        ])
        // HTTP/1.1 is on api.; assertion only checks cdn. — should pass.
        try cap.assertHTTP2(matching: "cdn.example.com")
    }

    @Test func noopWithEmptyCapture() throws {
        try ProxyCapture.makeFixture(events: []).assertHTTP2()
    }
}

// MARK: - TLS (reserved pass-through)

@Suite("assertAllTLS12OrBetter")
struct TLSAssertionTests {
    @Test func alwaysPassesInSchemaV1() throws {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(),
            NetworkEventFixture.make(statusCode: 500),
        ])
        try cap.assertAllTLS12OrBetter()
    }

    @Test func noopWithEmptyCapture() throws {
        try ProxyCapture.makeFixture(events: []).assertAllTLS12OrBetter()
    }
}

// MARK: - Parallel

@Suite("assertParallel")
struct ParallelAssertionTests {
    @Test func passesWhenIntervalsOverlap() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // Both complete at base, each takes 0.5s → same [base-0.5, base] window.
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(
                url: URL(string: "https://cdn.example.com/a.js")!,
                total: 0.5,
                timestamp: base
            ),
            NetworkEventFixture.make(
                url: URL(string: "https://api.example.com/data")!,
                total: 0.5,
                timestamp: base
            ),
        ])
        try cap.assertParallel(["cdn.example.com", "api.example.com"])
    }

    @Test func throwsWhenRequestsAreSequential() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(
                url: URL(string: "https://cdn.example.com/a.js")!,
                total: 0.5,
                timestamp: base
            ),
            // Starts 1s after the first one completes — no overlap.
            NetworkEventFixture.make(
                url: URL(string: "https://api.example.com/data")!,
                total: 0.5,
                timestamp: base.addingTimeInterval(1.5)
            ),
        ])
        #expect(throws: ProxyAssertionFailure.self) {
            try cap.assertParallel(["cdn.example.com", "api.example.com"])
        }
    }

    @Test func noopWithEmptyCapture() throws {
        try ProxyCapture.makeFixture(events: []).assertParallel(["cdn.", "api."])
    }

    @Test func noopWhenFewerThanTwoPatternsHaveMatchingEvents() throws {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://cdn.example.com/a.js")!),
        ])
        // "api.example.com" matches nothing — only 1 interval resolved, assertion skips.
        try cap.assertParallel(["cdn.example.com", "api.example.com"])
    }
}

// MARK: - Allowed Domains

@Suite("assertOnlyAllowedDomains")
struct AllowedDomainsAssertionTests {
    @Test func passesWhenAllDomainsAreAllowed() throws {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://api.example.com/v1")!),
            NetworkEventFixture.make(url: URL(string: "https://cdn.example.com/img.png")!),
        ])
        try cap.assertOnlyAllowedDomains(["api.example.com", "cdn.example.com"])
    }

    @Test func throwsWhenUnlistedDomainIsRequested() {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://api.example.com/v1")!),
            NetworkEventFixture.make(url: URL(string: "https://tracker.thirdparty.com/px")!),
        ])
        #expect(throws: ProxyAssertionFailure.self) {
            try cap.assertOnlyAllowedDomains(["api.example.com"])
        }
    }

    @Test func wildcardMatchesSubdomains() throws {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://api.stripe.com/v1/charges")!),
            NetworkEventFixture.make(url: URL(string: "https://js.stripe.com/v3/stripe.js")!),
        ])
        try cap.assertOnlyAllowedDomains(["*.stripe.com"])
    }

    @Test func wildcardDoesNotMatchApexDomain() {
        let cap = ProxyCapture.makeFixture(events: [
            NetworkEventFixture.make(url: URL(string: "https://stripe.com/")!),
        ])
        #expect(throws: ProxyAssertionFailure.self) {
            try cap.assertOnlyAllowedDomains(["*.stripe.com"])
        }
    }

    @Test func noopWithEmptyCapture() throws {
        try ProxyCapture.makeFixture(events: []).assertOnlyAllowedDomains(["api.example.com"])
    }
}

// MARK: - P95 Latency

@Suite("assertP95Latency")
struct P95LatencyAssertionTests {
    @Test func passesWhenP95IsUnderThreshold() throws {
        let cap = ProxyCapture.makeFixture(events: (0..<20).map { _ in
            NetworkEventFixture.make(total: 0.1)
        })
        try cap.assertP95Latency(under: 0.2)
    }

    @Test func throwsWhenP95ExceedsThreshold() {
        // 9 fast events + 1 slow; p95 = index ceil(10*0.95)-1 = 9 → 1.0s
        var events = (0..<9).map { _ in NetworkEventFixture.make(total: 0.1) }
        events.append(NetworkEventFixture.make(total: 1.0))
        let cap = ProxyCapture.makeFixture(events: events)
        #expect(throws: ProxyAssertionFailure.self) {
            try cap.assertP95Latency(under: 0.5)
        }
    }

    @Test func patternFilterLimitsScope() throws {
        var events = (0..<10).map { _ in
            NetworkEventFixture.make(url: URL(string: "https://api.example.com/slow")!, total: 2.0)
        }
        events += (0..<10).map { _ in
            NetworkEventFixture.make(url: URL(string: "https://cdn.example.com/fast.png")!, total: 0.05)
        }
        let cap = ProxyCapture.makeFixture(events: events)
        // Slow api. events are excluded; cdn. p95 is 0.05s — well under 0.1s.
        try cap.assertP95Latency(under: 0.1, matching: "cdn.example.com")
    }

    @Test func noopWithEmptyCapture() throws {
        try ProxyCapture.makeFixture(events: []).assertP95Latency(under: 1.0)
    }

    @Test func noopWithOnlyOneEvent() throws {
        let cap = ProxyCapture.makeFixture(events: [NetworkEventFixture.make(total: 5.0)])
        // Fewer than 2 events — insufficient data, passes silently.
        try cap.assertP95Latency(under: 0.001)
    }
}
