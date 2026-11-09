import XCTest
@testable import JoesProxy

final class CacheFreshnessEvaluatorTests: XCTestCase {

    func testMaxAgeParsing() {
        let headers = [
            HTTPHeaderField(name: "Cache-Control", value: "public, max-age=300, immutable"),
            HTTPHeaderField(name: "ETag", value: "\"abcd1234\"")
        ]
        let summary = CacheFreshnessEvaluator.evaluate(responseHeaders: headers)
        
        if case .maxAge(let seconds, let isPublic, let isImmutable) = summary.policyKind {
            XCTAssertEqual(seconds, 300)
            XCTAssertTrue(isPublic)
            XCTAssertTrue(isImmutable)
        } else {
            XCTFail("Expected .maxAge policy")
        }
        XCTAssertEqual(summary.effectiveTTLSeconds, 300)
        XCTAssertEqual(summary.etag, "\"abcd1234\"")
        XCTAssertEqual(summary.displayBadgeText, "Immutable (5m)")
        XCTAssertEqual(summary.badgeTintName, "green")
    }

    func testNoStoreDirectives() {
        let headers = [
            HTTPHeaderField(name: "Cache-Control", value: "no-store, no-cache, must-revalidate")
        ]
        let summary = CacheFreshnessEvaluator.evaluate(responseHeaders: headers)
        XCTAssertEqual(summary.policyKind, .noStore)
        XCTAssertEqual(summary.effectiveTTLSeconds, 0)
        XCTAssertTrue(summary.revalidationRequired)
        XCTAssertEqual(summary.displayBadgeText, "No-Store")
        XCTAssertEqual(summary.badgeTintName, "orange")
    }

    func testRevalidateWithETag() {
        let headers = [
            HTTPHeaderField(name: "Cache-Control", value: "no-cache"),
            HTTPHeaderField(name: "ETag", value: "\"12345\"")
        ]
        let summary = CacheFreshnessEvaluator.evaluate(responseHeaders: headers)
        XCTAssertEqual(summary.policyKind, .noCache)
        XCTAssertEqual(summary.displayBadgeText, "Revalidate (ETag)")
        XCTAssertEqual(summary.badgeTintName, "orange")
    }

    func test304ValidatedStatus() {
        let headers = [
            HTTPHeaderField(name: "ETag", value: "\"12345\"")
        ]
        let summary = CacheFreshnessEvaluator.evaluate(responseHeaders: headers, statusCode: 304)
        XCTAssertEqual(summary.displayBadgeText, "304 Validated")
        XCTAssertEqual(summary.badgeTintName, "green")
    }

    func testCDNHitStatus() {
        let headers = [
            HTTPHeaderField(name: "CF-Cache-Status", value: "HIT"),
            HTTPHeaderField(name: "Cache-Control", value: "max-age=60")
        ]
        let summary = CacheFreshnessEvaluator.evaluate(responseHeaders: headers)
        XCTAssertEqual(summary.cdnStatus, "Cloudflare: HIT")
        XCTAssertEqual(summary.displayBadgeText, "CDN HIT")
        XCTAssertEqual(summary.badgeTintName, "green")
    }

    func testConflictingDirectivesDetection() {
        let headers = [
            HTTPHeaderField(name: "Cache-Control", value: "no-store, max-age=3600")
        ]
        let summary = CacheFreshnessEvaluator.evaluate(responseHeaders: headers)
        XCTAssertEqual(summary.policyKind, .noStore)
        XCTAssertFalse(summary.conflictingDirectives.isEmpty)
        XCTAssertTrue(summary.conflictingDirectives.first?.contains("combines no-store with max-age") == true)
    }

    func testStaleCalculationWithAgeHeader() {
        let headers = [
            HTTPHeaderField(name: "Cache-Control", value: "max-age=300"),
            HTTPHeaderField(name: "Age", value: "350")
        ]
        let summary = CacheFreshnessEvaluator.evaluate(responseHeaders: headers)
        XCTAssertTrue(summary.isStale)
        XCTAssertEqual(summary.displayBadgeText, "Stale")
        XCTAssertEqual(summary.badgeTintName, "red")
    }
}
