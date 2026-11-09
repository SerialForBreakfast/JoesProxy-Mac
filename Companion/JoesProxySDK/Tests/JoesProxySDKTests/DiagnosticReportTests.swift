import Foundation
import Testing
import JoesProxySDK
import ProxySDKTesting

@Suite("DiagnosticReport")
struct DiagnosticReportTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let end = Date(timeIntervalSince1970: 1_800_001_000)

    private func makeReport(events: [NetworkEvent]) -> DiagnosticReport {
        DiagnosticReport(
            label: "CheckoutFlow",
            captureStart: Self.start,
            captureEnd: Self.end,
            events: events
        )
    }

    @Test func emptyReportHasZeroValues() {
        let report = makeReport(events: [])
        #expect(report.requestCount == 0)
        #expect(report.errorRate == 0)
        #expect(report.p50LatencySeconds == 0)
        #expect(report.p95LatencySeconds == 0)
        #expect(report.cdnHitRate == 0)
        #expect(report.totalRetryCount == 0)
        #expect(report.thirdPartySummary.isEmpty)
    }

    @Test func errorRateCountsStatusCodesAndFailedPhase() {
        let events: [NetworkEvent] = [
            NetworkEventFixture.make(statusCode: 200),
            NetworkEventFixture.make(statusCode: 404),
            NetworkEventFixture.make(statusCode: 500),
            NetworkEventFixture.make(statusCode: nil, phase: .failed),
        ]
        let report = makeReport(events: events)
        // 3 of 4 are errors (404, 500, failed)
        #expect(abs(report.errorRate - 0.75) < 0.001)
    }

    @Test func p95LatencyComputedFromAllEvents() {
        // 10 events: 9 × 0.1s + 1 × 1.0s
        // sorted: [0.1×9, 1.0]; p95 index = ceil(10 × 0.95) - 1 = ceil(9.5) - 1 = 9 → 1.0s
        var events = (0..<9).map { _ in NetworkEventFixture.make(total: 0.1) }
        events.append(NetworkEventFixture.make(total: 1.0))
        let report = makeReport(events: events)
        #expect(abs(report.p95LatencySeconds - 1.0) < 0.001)
    }

    @Test func p50LatencyComputedCorrectly() {
        // sorted: [0.1, 0.2, 0.3, 0.4, 0.5]; p50 index = ceil(5 × 0.5) - 1 = 2 → 0.3
        let events = [0.1, 0.2, 0.3, 0.4, 0.5].map { NetworkEventFixture.make(total: $0) }
        let report = makeReport(events: events)
        #expect(abs(report.p50LatencySeconds - 0.3) < 0.001)
    }

    @Test func cdnHitRateCountsHitCacheStatus() {
        let events: [NetworkEvent] = [
            NetworkEventFixture.make(cacheStatus: .hit),
            NetworkEventFixture.make(cacheStatus: .hit),
            NetworkEventFixture.make(cacheStatus: .miss),
            NetworkEventFixture.make(cacheStatus: nil),
        ]
        let report = makeReport(events: events)
        #expect(abs(report.cdnHitRate - 0.5) < 0.001)
    }

    @Test func totalRetryCountSumsAllRetries() {
        let events: [NetworkEvent] = [
            NetworkEventFixture.make(retryCount: 0),
            NetworkEventFixture.make(retryCount: 2),
            NetworkEventFixture.make(retryCount: 3),
        ]
        let report = makeReport(events: events)
        #expect(report.totalRetryCount == 5)
    }

    @Test func thirdPartySummaryGroupsBySourceSDK() {
        let events: [NetworkEvent] = [
            NetworkEventFixture.make(sourceSDK: "Braze"),
            NetworkEventFixture.make(sourceSDK: "Braze"),
            NetworkEventFixture.make(sourceSDK: "Amplitude"),
            NetworkEventFixture.make(sourceSDK: nil),
        ]
        let report = makeReport(events: events)
        #expect(report.thirdPartySummary["Braze"] == 2)
        #expect(report.thirdPartySummary["Amplitude"] == 1)
        #expect(report.thirdPartySummary.count == 2)
    }

    @Test func jsonDataIsValidAndRoundTrips() throws {
        let report = makeReport(events: [
            NetworkEventFixture.make(statusCode: 200, total: 0.3),
        ])
        let data = try report.jsonData()
        #expect(!data.isEmpty)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticReport.self, from: data)
        #expect(decoded.label == report.label)
        #expect(decoded.requestCount == report.requestCount)
        #expect(abs(decoded.p95LatencySeconds - report.p95LatencySeconds) < 0.001)
    }

    @Test func jsonDataContainsExpectedKeys() throws {
        let report = makeReport(events: [NetworkEventFixture.make()])
        let data = try report.jsonData()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["label"] as? String == "CheckoutFlow")
        #expect(json?["requestCount"] as? Int == 1)
        #expect(json?["errorRate"] != nil)
        #expect(json?["cdnHitRate"] != nil)
    }
}
