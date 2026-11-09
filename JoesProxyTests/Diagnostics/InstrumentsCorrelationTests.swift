import XCTest
@testable import JoesProxy

final class InstrumentsCorrelationTests: XCTestCase {

    func testCorrelatesLargePayloadWithMainThreadHang() {
        let startTime = Date()

        // 1. Captured session delivering a 500KB JSON payload at T+1.0s, ending at T+1.2s
        let req = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/catalog.json",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        let resp = CapturedResponse(
            statusCode: 200,
            headers: [],
            bodyData: Data(repeating: 0x20, count: 500_000),
            bodySize: 500_000,
            source: .upstream,
            sourceDescription: nil
        )
        let timing = SessionTiming(
            startedAt: startTime.addingTimeInterval(1.0),
            completedAt: startTime.addingTimeInterval(1.2)
        )
        let session = SessionRecord(request: req, response: resp, state: .completed, timing: timing)

        // 2. Trace metric showing a 380ms hang starting at T+1.25s (50ms after response completed)
        let hang = InstrumentsHangEvent(startTimeSeconds: 1.25, durationMs: 380.0, severity: "severe")
        let hotspot = InstrumentsHotspotFrame(symbol: "JSONDecoder.decode()", sampleCount: 850, weightPercentage: 78.0, binaryName: "Foundation")
        let metrics = InstrumentsMetricSummary(
            templateName: "Hangs / Hitches",
            durationSeconds: 5.0,
            topHotspots: [hotspot],
            detectedHangs: [hang],
            totalAllocationsBytes: 15_000_000,
            warnings: []
        )

        // 3. Run correlation
        let report = InstrumentsCorrelatedDiagnosticEngine.analyze(
            targetName: "TargetApp",
            durationSeconds: 5.0,
            tracePath: "/path/to/test.trace",
            sessionStartTime: startTime,
            capturedSessions: [session],
            traceMetrics: metrics
        )

        XCTAssertEqual(report.totalRequestsCaptured, 1)
        XCTAssertEqual(report.hostHangsCount, 1)
        XCTAssertEqual(report.findings.count, 2) // 1 payload hang + 1 json hotspot

        let mainThreadFinding = report.findings.first(where: { $0.severity == "SEVERE" })
        XCTAssertNotNil(mainThreadFinding)
        XCTAssertEqual(mainThreadFinding?.relatedEndpoint, "https://api.example.com/catalog.json")
        XCTAssertEqual(mainThreadFinding?.relatedHangDurationMs, 380.0)
        XCTAssertTrue(mainThreadFinding?.rootCause.contains("main thread") == true)
    }

    func testCorrelatesSlowMediaSegmentDelivery() {
        let startTime = Date()

        let req = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "cdn.example.com",
            port: 443,
            path: "/stream/seg-001.ts",
            headers: [],
            bodyData: nil,
            bodySize: nil
        )
        let resp = CapturedResponse(
            statusCode: 200,
            headers: [],
            bodyData: Data(repeating: 0x47, count: 200_000),
            bodySize: 200_000,
            source: .upstream,
            sourceDescription: nil
        )
        let timing = SessionTiming(
            startedAt: startTime.addingTimeInterval(2.0),
            completedAt: startTime.addingTimeInterval(4.5) // 2.5s segment delivery
        )
        let session = SessionRecord(request: req, response: resp, state: .completed, timing: timing)

        let metrics = InstrumentsMetricSummary(
            templateName: "Hangs / Hitches",
            durationSeconds: 5.0,
            topHotspots: [],
            detectedHangs: [],
            totalAllocationsBytes: nil,
            warnings: []
        )

        let report = InstrumentsCorrelatedDiagnosticEngine.analyze(
            targetName: "TargetApp",
            durationSeconds: 5.0,
            tracePath: "/path/to/test.trace",
            sessionStartTime: startTime,
            capturedSessions: [session],
            traceMetrics: metrics
        )

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].severity, "WARNING")
        XCTAssertTrue(report.findings[0].title.contains("Media Segment"))
    }
}
