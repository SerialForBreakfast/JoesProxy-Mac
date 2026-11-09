import XCTest
@testable import JoesProxy

final class NoCachingPolicyTests: XCTestCase {

    // MARK: - applies(to:) — Global Toggle

    func testAppliesReturnsTrueWhenGloballyEnabled() {
        let policy = NoCachingPolicy(isGloballyEnabled: true, perDomainList: [])
        XCTAssertTrue(policy.applies(to: "api.example.com"))
        XCTAssertTrue(policy.applies(to: "other.com"))
    }

    func testAppliesReturnsFalseWhenGloballyDisabledAndNoDomainMatch() {
        let policy = NoCachingPolicy(isGloballyEnabled: false, perDomainList: [])
        XCTAssertFalse(policy.applies(to: "api.example.com"))
    }

    func testAppliesReturnsFalseForEmptyHost() {
        let policy = NoCachingPolicy(isGloballyEnabled: true, perDomainList: ["example.com"])
        XCTAssertFalse(policy.applies(to: ""))
    }

    // MARK: - applies(to:) — Per-Domain Matching

    func testAppliesReturnsTrueForExactDomainMatch() {
        let policy = NoCachingPolicy(isGloballyEnabled: false, perDomainList: ["example.com"])
        XCTAssertTrue(policy.applies(to: "example.com"))
    }

    func testAppliesReturnsTrueForSubdomainOfPlainDomainEntry() {
        // "example.com" in list should also match "api.example.com"
        let policy = NoCachingPolicy(isGloballyEnabled: false, perDomainList: ["example.com"])
        XCTAssertTrue(policy.applies(to: "api.example.com"))
    }

    func testAppliesReturnsTrueForDotPrefixedEntry() {
        // ".example.com" matches "example.com" and "api.example.com"
        let policy = NoCachingPolicy(isGloballyEnabled: false, perDomainList: [".example.com"])
        XCTAssertTrue(policy.applies(to: "example.com"))
        XCTAssertTrue(policy.applies(to: "api.example.com"))
        XCTAssertTrue(policy.applies(to: "www.api.example.com"))
    }

    func testAppliesReturnsFalseForNonMatchingDomain() {
        let policy = NoCachingPolicy(isGloballyEnabled: false, perDomainList: ["example.com"])
        XCTAssertFalse(policy.applies(to: "other.com"))
        XCTAssertFalse(policy.applies(to: "notexample.com"))
    }

    func testAppliesIsCaseInsensitive() {
        let policy = NoCachingPolicy(isGloballyEnabled: false, perDomainList: ["Example.COM"])
        XCTAssertTrue(policy.applies(to: "example.com"))
        XCTAssertTrue(policy.applies(to: "API.EXAMPLE.COM"))
    }

    func testAppliesReturnsTrueWhenGlobalAndDomainBothApply() {
        let policy = NoCachingPolicy(isGloballyEnabled: true, perDomainList: ["example.com"])
        XCTAssertTrue(policy.applies(to: "example.com"))
        XCTAssertTrue(policy.applies(to: "unrelated.com"))
    }

    func testWildcardPrefixTreatedSameAsDotPrefix() {
        // "*.example.com" should behave like ".example.com"
        let policy = NoCachingPolicy(isGloballyEnabled: false, perDomainList: ["*.example.com"])
        XCTAssertTrue(policy.applies(to: "api.example.com"))
        XCTAssertTrue(policy.applies(to: "example.com"))
    }

    // MARK: - applyToRequestHeaders

    func testRequestHeadersAddsCacheControlNoCacheWhenAbsent() {
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "Accept", value: "application/json")
        ]
        let result = NoCachingPolicy.applyToRequestHeaders(headers)
        XCTAssertTrue(result.contains { $0.name == "Cache-Control" && $0.value == "no-cache" })
    }

    func testRequestHeadersOverridesExistingCacheControl() {
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "Cache-Control", value: "max-age=3600")
        ]
        let result = NoCachingPolicy.applyToRequestHeaders(headers)
        let cacheControlValues = result.filter { $0.name.caseInsensitiveCompare("Cache-Control") == .orderedSame }
        XCTAssertEqual(cacheControlValues.count, 1)
        XCTAssertEqual(cacheControlValues[0].value, "no-cache")
    }

    func testRequestHeadersAddsPragmaNoCacheWhenAbsent() {
        let headers: [HTTPHeaderField] = []
        let result = NoCachingPolicy.applyToRequestHeaders(headers)
        XCTAssertTrue(result.contains { $0.name == "Pragma" && $0.value == "no-cache" })
    }

    func testRequestHeadersRemovesIfNoneMatch() {
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "If-None-Match", value: "\"abc123\"")
        ]
        let result = NoCachingPolicy.applyToRequestHeaders(headers)
        XCTAssertFalse(result.contains { $0.name.caseInsensitiveCompare("If-None-Match") == .orderedSame })
    }

    func testRequestHeadersRemovesIfModifiedSince() {
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "If-Modified-Since", value: "Wed, 21 Oct 2015 07:28:00 GMT")
        ]
        let result = NoCachingPolicy.applyToRequestHeaders(headers)
        XCTAssertFalse(result.contains { $0.name.caseInsensitiveCompare("If-Modified-Since") == .orderedSame })
    }

    func testRequestHeadersPreservesUnrelatedHeaders() {
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "Accept", value: "application/json"),
            HTTPHeaderField(name: "Authorization", value: "Bearer token123"),
            HTTPHeaderField(name: "Content-Type", value: "application/x-www-form-urlencoded")
        ]
        let result = NoCachingPolicy.applyToRequestHeaders(headers)
        XCTAssertTrue(result.contains { $0.name == "Accept" && $0.value == "application/json" })
        XCTAssertTrue(result.contains { $0.name == "Authorization" && $0.value == "Bearer token123" })
        XCTAssertTrue(result.contains { $0.name == "Content-Type" })
    }

    func testRequestHeadersAllConditionalsRemovedAndControlsAdded() {
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "If-None-Match", value: "\"v1\""),
            HTTPHeaderField(name: "If-Modified-Since", value: "Mon, 01 Jan 2024 00:00:00 GMT"),
            HTTPHeaderField(name: "Cache-Control", value: "no-store"),
            HTTPHeaderField(name: "Pragma", value: "no-cache"),
            HTTPHeaderField(name: "Host", value: "example.com")
        ]
        let result = NoCachingPolicy.applyToRequestHeaders(headers)
        XCTAssertFalse(result.contains { $0.name.caseInsensitiveCompare("If-None-Match") == .orderedSame })
        XCTAssertFalse(result.contains { $0.name.caseInsensitiveCompare("If-Modified-Since") == .orderedSame })
        XCTAssertTrue(result.contains { $0.name.caseInsensitiveCompare("Cache-Control") == .orderedSame && $0.value == "no-cache" })
        XCTAssertTrue(result.contains { $0.name.caseInsensitiveCompare("Pragma") == .orderedSame && $0.value == "no-cache" })
        XCTAssertTrue(result.contains { $0.name == "Host" })
    }

    // MARK: - applyToResponseHeaders

    func testResponseHeadersOverridesCacheControl() {
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "Cache-Control", value: "max-age=86400, public")
        ]
        let result = NoCachingPolicy.applyToResponseHeaders(headers)
        let cacheControlValues = result.filter { $0.name.caseInsensitiveCompare("Cache-Control") == .orderedSame }
        XCTAssertEqual(cacheControlValues.count, 1)
        XCTAssertEqual(cacheControlValues[0].value, "no-store, no-cache, must-revalidate")
    }

    func testResponseHeadersAddsCacheControlWhenAbsent() {
        let headers: [HTTPHeaderField] = []
        let result = NoCachingPolicy.applyToResponseHeaders(headers)
        XCTAssertTrue(result.contains { $0.name == "Cache-Control" && $0.value == "no-store, no-cache, must-revalidate" })
    }

    func testResponseHeadersAddsPragmaNoCache() {
        let headers: [HTTPHeaderField] = []
        let result = NoCachingPolicy.applyToResponseHeaders(headers)
        XCTAssertTrue(result.contains { $0.name == "Pragma" && $0.value == "no-cache" })
    }

    func testResponseHeadersOverridesExpiresToZero() {
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "Expires", value: "Wed, 21 Oct 2026 07:28:00 GMT")
        ]
        let result = NoCachingPolicy.applyToResponseHeaders(headers)
        let expiresValues = result.filter { $0.name.caseInsensitiveCompare("Expires") == .orderedSame }
        XCTAssertEqual(expiresValues.count, 1)
        XCTAssertEqual(expiresValues[0].value, "0")
    }

    func testResponseHeadersRemovesETag() {
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "ETag", value: "\"abc123\"")
        ]
        let result = NoCachingPolicy.applyToResponseHeaders(headers)
        XCTAssertFalse(result.contains { $0.name.caseInsensitiveCompare("ETag") == .orderedSame })
    }

    func testResponseHeadersRemovesLastModified() {
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "Last-Modified", value: "Tue, 15 Nov 2024 12:00:00 GMT")
        ]
        let result = NoCachingPolicy.applyToResponseHeaders(headers)
        XCTAssertFalse(result.contains { $0.name.caseInsensitiveCompare("Last-Modified") == .orderedSame })
    }

    func testResponseHeadersPreservesUnrelatedHeaders() {
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "Content-Type", value: "application/json"),
            HTTPHeaderField(name: "Content-Encoding", value: "gzip"),
            HTTPHeaderField(name: "X-Request-Id", value: "abc-123")
        ]
        let result = NoCachingPolicy.applyToResponseHeaders(headers)
        XCTAssertTrue(result.contains { $0.name == "Content-Type" && $0.value == "application/json" })
        XCTAssertTrue(result.contains { $0.name == "Content-Encoding" && $0.value == "gzip" })
        XCTAssertTrue(result.contains { $0.name == "X-Request-Id" && $0.value == "abc-123" })
    }

    func testResponseHeadersFullMutation() {
        // Comprehensive: all cache headers replaced, unrelated preserved
        let headers: [HTTPHeaderField] = [
            HTTPHeaderField(name: "Content-Type", value: "text/html"),
            HTTPHeaderField(name: "Cache-Control", value: "public, max-age=3600"),
            HTTPHeaderField(name: "Expires", value: "Wed, 21 Oct 2026 07:28:00 GMT"),
            HTTPHeaderField(name: "ETag", value: "\"v2\""),
            HTTPHeaderField(name: "Last-Modified", value: "Mon, 01 Jan 2024 00:00:00 GMT"),
            HTTPHeaderField(name: "Pragma", value: "cache")
        ]
        let result = NoCachingPolicy.applyToResponseHeaders(headers)
        XCTAssertTrue(result.contains { $0.name == "Content-Type" && $0.value == "text/html" })
        XCTAssertTrue(result.contains { $0.name == "Cache-Control" && $0.value == "no-store, no-cache, must-revalidate" })
        XCTAssertTrue(result.contains { $0.name == "Pragma" && $0.value == "no-cache" })
        XCTAssertTrue(result.contains { $0.name == "Expires" && $0.value == "0" })
        XCTAssertFalse(result.contains { $0.name.caseInsensitiveCompare("ETag") == .orderedSame })
        XCTAssertFalse(result.contains { $0.name.caseInsensitiveCompare("Last-Modified") == .orderedSame })
        // Each overridden header appears exactly once
        XCTAssertEqual(result.filter { $0.name == "Cache-Control" }.count, 1)
        XCTAssertEqual(result.filter { $0.name == "Pragma" }.count, 1)
        XCTAssertEqual(result.filter { $0.name == "Expires" }.count, 1)
    }
}
