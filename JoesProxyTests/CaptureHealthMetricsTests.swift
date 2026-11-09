import Foundation
import XCTest
@testable import JoesProxy

final class CaptureHealthMetricsTests: XCTestCase {
    private var lowThresholds: CaptureHealthThresholds {
        CaptureHealthThresholds(
            captureDuration: 60,
            sessionCount: 10,
            retainedBodyBytes: 1_024,
            residentMemoryBytes: 1_024,
            cpuPercent: 50
        )
    }

    func testHighCPUWithoutSessionsDoesNotExceedThreshold() {
        let metrics = CaptureHealthMetrics(
            sessionCount: 0,
            retainedBodyBytes: 0,
            droppedSessionCount: 0,
            captureStartedAt: Date(),
            processMetrics: AppProcessMetrics(
                cpuPercent: 167,
                residentMemoryBytes: 900_000_000
            )
        )

        XCTAssertFalse(metrics.hasCaptureSessionFootprint)
        XCTAssertFalse(metrics.exceedsLongCaptureThresholds(using: lowThresholds))
    }

    func testHighCPUWithSessionsExceedsThreshold() {
        let metrics = CaptureHealthMetrics(
            sessionCount: 3,
            retainedBodyBytes: 4_096,
            droppedSessionCount: 0,
            captureStartedAt: Date(),
            processMetrics: AppProcessMetrics(
                cpuPercent: 167,
                residentMemoryBytes: 100_000
            )
        )

        XCTAssertTrue(metrics.hasCaptureSessionFootprint)
        XCTAssertTrue(metrics.exceedsLongCaptureThresholds(using: lowThresholds))
    }

    func testSessionCountThresholdRequiresCaptureFootprint() {
        let metrics = CaptureHealthMetrics(
            sessionCount: 0,
            retainedBodyBytes: 0,
            droppedSessionCount: 0,
            captureStartedAt: Date(),
            processMetrics: AppProcessMetrics(
                cpuPercent: 0,
                residentMemoryBytes: 0
            )
        )

        XCTAssertFalse(metrics.exceedsLongCaptureThresholds(using: lowThresholds))
    }

    func testDroppedSessionsCountAsCaptureFootprint() {
        let metrics = CaptureHealthMetrics(
            sessionCount: 0,
            retainedBodyBytes: 0,
            droppedSessionCount: 2,
            captureStartedAt: Date(),
            processMetrics: AppProcessMetrics(
                cpuPercent: 95,
                residentMemoryBytes: 0
            )
        )

        XCTAssertTrue(metrics.hasCaptureSessionFootprint)
        XCTAssertTrue(metrics.exceedsLongCaptureThresholds(using: lowThresholds))
    }

    func testCurrentProcessMetricsSamplerReturnsNonZeroPhysicalFootprint() {
        let sampler = CurrentProcessMetricsSampler()
        let sample = sampler.sample()

        XCTAssertGreaterThan(sample.physicalFootprintBytes, 0, "Physical footprint must be non-zero for active process")
        XCTAssertGreaterThan(sample.peakResidentMemoryBytes, 0, "Peak resident memory must be non-zero for active process")
        XCTAssertEqual(sample.residentMemoryBytes, sample.physicalFootprintBytes)
    }
}
