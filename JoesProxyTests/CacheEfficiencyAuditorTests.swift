import XCTest
@testable import JoesProxy

final class CacheEfficiencyAuditorTests: XCTestCase {

    func testAuditingCleanSessions() {
        let req = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v1/config",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        let resp = CapturedResponse(
            statusCode: 200,
            headers: [
                HTTPHeaderField(name: "Cache-Control", value: "max-age=300"),
                HTTPHeaderField(name: "ETag", value: "\"config1\"")
            ],
            bodyData: Data("{}".utf8),
            bodySize: 2,
            source: .upstream,
            sourceDescription: "Upstream"
        )
        let session = SessionRecord(
            request: req,
            response: resp,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )

        let report = CacheEfficiencyAuditor.audit(sessions: [session])
        XCTAssertEqual(report.totalSessionsEvaluated, 1)
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.potentialBandwidthWasteBytes, 0)
    }

    func testDetectingUncachedDuplicateRequests() {
        let req1 = CapturedRequest(method: "GET", scheme: .https, host: "api.example.com", port: 443, path: "/uncached", headers: [], bodyData: nil, bodySize: nil)
        let resp1 = CapturedResponse(statusCode: 200, headers: [], bodyData: Data(repeating: 1, count: 1000), bodySize: 1000, source: .upstream, sourceDescription: nil)
        let s1 = SessionRecord(request: req1, response: resp1, state: .completed, timing: SessionTiming(startedAt: Date()))

        let req2 = CapturedRequest(method: "GET", scheme: .https, host: "api.example.com", port: 443, path: "/uncached", headers: [], bodyData: nil, bodySize: nil)
        let resp2 = CapturedResponse(statusCode: 200, headers: [], bodyData: Data(repeating: 1, count: 1000), bodySize: 1000, source: .upstream, sourceDescription: nil)
        let s2 = SessionRecord(request: req2, response: resp2, state: .completed, timing: SessionTiming(startedAt: Date()))

        let report = CacheEfficiencyAuditor.audit(sessions: [s1, s2])
        XCTAssertEqual(report.totalSessionsEvaluated, 2)
        XCTAssertFalse(report.isClean)
        XCTAssertEqual(report.uncachedDuplicateRequests.count, 1)
        XCTAssertEqual(report.uncachedDuplicateRequests.first?.count, 2)
        XCTAssertEqual(report.potentialBandwidthWasteBytes, 1000)
    }

    func testDetectingMissingValidationTokensOnLargeAssets() {
        let req = CapturedRequest(method: "GET", scheme: .https, host: "cdn.example.com", port: 443, path: "/banner.png", headers: [], bodyData: nil, bodySize: nil)
        let largeBody = Data(repeating: 0xFF, count: 200 * 1024) // 200 KB
        let resp = CapturedResponse(statusCode: 200, headers: [], bodyData: largeBody, bodySize: largeBody.count, source: .upstream, sourceDescription: nil)
        let s = SessionRecord(request: req, response: resp, state: .completed, timing: SessionTiming(startedAt: Date()))

        let report = CacheEfficiencyAuditor.audit(sessions: [s])
        XCTAssertEqual(report.missingValidationTokens.count, 1)
        XCTAssertEqual(report.missingValidationTokens.first?.bodySizeBytes, 200 * 1024)
    }

    func testDetectingConflictingHeaders() {
        let req = CapturedRequest(method: "GET", scheme: .https, host: "api.example.com", port: 443, path: "/conflicted", headers: [], bodyData: nil, bodySize: nil)
        let resp = CapturedResponse(statusCode: 200, headers: [
            HTTPHeaderField(name: "Cache-Control", value: "no-store, max-age=60")
        ], bodyData: nil, bodySize: 0, source: .upstream, sourceDescription: nil)
        let s = SessionRecord(request: req, response: resp, state: .completed, timing: SessionTiming(startedAt: Date()))

        let report = CacheEfficiencyAuditor.audit(sessions: [s])
        XCTAssertEqual(report.conflictingHeaderSessions.count, 1)
    }
}
